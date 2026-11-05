"""Bounded in-memory speech sessions on the service's single model worker.

HTTP threads append PCM and inspect snapshots; they never execute model code.
Confirmed audio extents are disjoint. Every extent is decoded once and the whole
transcript is edited once after finish, so a later spoken correction keeps its
original context. No intermediate result is a delivery or a history record.
"""
from __future__ import annotations

from dataclasses import dataclass, field
import hashlib
import logging
import threading
import time
import uuid

LOG = logging.getLogger("local-dictation")
SAMPLE_RATE = 16000
TARGET_SAMPLES = 30 * SAMPLE_RATE
LOOKAHEAD_SAMPLES = 5 * SAMPLE_RATE
MAX_SAMPLES = 300 * SAMPLE_RATE
MAX_CHUNK_BYTES = 2 * 1024 * 1024
MAX_SESSIONS = 8
MAX_SESSION_RECORDS = 64
MAX_AUDIO_MEMORY = MAX_SESSIONS * MAX_SAMPLES * 2
MAX_PARTS = 8192
IDLE_TIMEOUT = 90.0
SESSION_TIMEOUT = 15 * 60.0
RESULT_RETENTION = 10 * 60.0
TERMINAL = frozenset(("completed", "cancelled", "failed"))


class StreamError(Exception):
    def __init__(self, status: int, message: str):
        self.status, self.message = status, message
        super().__init__(message)


def validate_session_id(value):
    if not isinstance(value, str):
        raise StreamError(400, "session_id 须为 UUID 字符串。")
    try:
        if str(uuid.UUID(value)) != value.lower():
            raise ValueError()
    except (ValueError, AttributeError):
        raise StreamError(400, "session_id 须为 UUID 字符串。") from None
    return value.lower()


def next_cut(pcm: bytes, finished: bool) -> int | None:
    """Match mlx-audio 0.6.3's 30 ± 5 s / 100 ms energy split exactly.

    Five seconds of right context makes the first boundary stable: receiving
    later samples cannot change it. The final short extent is left intact and
    Qwen's existing feature path performs its ordinary subsecond padding.
    Called on the model worker, never while holding the session/admission lock.
    """
    count = len(pcm) // 2
    if count <= TARGET_SAMPLES:
        return count if finished and count else None
    if not finished and count < TARGET_SAMPLES + LOOKAHEAD_SAMPLES:
        return None
    import numpy as np
    begin = TARGET_SAMPLES - LOOKAHEAD_SAMPLES
    end = min(count, TARGET_SAMPLES + LOOKAHEAD_SAMPLES)
    # Retain the pinned implementation's float32 square followed by float64
    # convolution and first-minimum tie policy, including all-silent windows.
    audio = np.frombuffer(pcm[begin * 2:end * 2], dtype="<i2").astype(np.float32) / 32768.0
    width = SAMPLE_RATE // 10
    if len(audio) > width:
        energy = np.convolve(audio ** 2, np.ones(width) / width, mode="valid")
        cut = begin + int(np.argmin(energy)) + width // 2
    else:
        cut = TARGET_SAMPLES
    return max(cut, SAMPLE_RATE)


@dataclass
class Session:
    id: str
    options: object
    fingerprint: object
    created_at: float
    last_input_at: float
    state: str = "recording"
    audio: bytearray = field(default_factory=bytearray)
    received: int = 0
    processed: int = 0
    parts: dict = field(default_factory=dict)
    texts: list = field(default_factory=list)
    tokens: int = 0
    asr_seconds: float = 0.0
    pre_stop_asr_seconds: float = 0.0
    pre_stop_processed: int = 0
    asr_calls: int = 0
    finish_at: float | None = None
    terminal_at: float | None = None
    scheduled: bool = False
    result: dict | None = None
    error: str | None = None
    error_status: int = 500
    done: threading.Event = field(default_factory=threading.Event)

    def snapshot(self):
        return {"session_id": self.id, "state": self.state,
                "received_samples": self.received, "processed_samples": self.processed,
                "raw_text": " ".join(self.texts).strip(),
                **({"error": self.error} if self.error else {})}


class StreamingSessions:
    def __init__(self, worker, lock, available, transcribe, complete, *, clock=time.monotonic,
                 max_tokens=8192):
        self.worker, self.lock, self.available = worker, lock, available
        self.transcribe, self.complete, self.clock = transcribe, complete, clock
        self.max_tokens = max_tokens
        self.sessions = {}
        self.jobs = 0
        self.closed = False

    def _terminate_locked(self, session, state, status, message):
        session.state, session.error_status, session.error = state, status, message
        session.terminal_at = self.clock()
        session.audio.clear()
        session.parts.clear()
        # Failed ASR must never look like a usable complete recording. The app
        # retains its original recording for explicit whole-recording fallback.
        if state == "cancelled":
            session.texts.clear()
        session.done.set()

    def _reap_locked(self):
        now = self.clock()
        for sid, session in list(self.sessions.items()):
            if session.state in TERMINAL:
                if not session.scheduled and now - session.terminal_at >= RESULT_RETENTION:
                    del self.sessions[sid]
            elif (now - session.created_at >= SESSION_TIMEOUT or
                  (session.finish_at is None and now - session.last_input_at >= IDLE_TIMEOUT)):
                self._terminate_locked(session, "failed", 410, "录音会话已过期，请重新开始。")
        # Completed results are small but bounded too. Preserve recent outcomes
        # for idempotent finish retries; evict only oldest terminal records.
        terminal = sorted((s for s in self.sessions.values() if s.state in TERMINAL and not s.scheduled),
                          key=lambda s: s.terminal_at)
        while len(self.sessions) >= MAX_SESSION_RECORDS and terminal:
            del self.sessions[terminal.pop(0).id]

    def _active_count_locked(self):
        return sum(s.state not in TERMINAL for s in self.sessions.values())

    def health(self):
        with self.lock:
            self._reap_locked()
            active = self._active_count_locked()
            return {"busy": bool(active or self.jobs), "active_streams": active,
                    "accepts_streaming": not self.closed and self.available() and active < MAX_SESSIONS}

    def start(self, sid, options, fingerprint):
        sid = validate_session_id(sid)
        with self.lock:
            self._reap_locked()
            existing = self.sessions.get(sid)
            if existing:
                if existing.fingerprint != fingerprint:
                    raise StreamError(409, "此会话已使用其他录音设置。")
                return existing.snapshot()
            if self.closed or not self.available():
                raise StreamError(503, "识别服务暂不可用，请稍后重试。")
            if self._active_count_locked() >= MAX_SESSIONS:
                raise StreamError(429, "待处理口述过多，请等待前面的录音完成。")
            now = self.clock()
            session = Session(sid, options, fingerprint, now, now)
            self.sessions[sid] = session
            return session.snapshot()

    def _get_locked(self, sid):
        sid = validate_session_id(sid)
        self._reap_locked()
        if sid not in self.sessions:
            raise StreamError(404, "录音会话不存在或已过期。")
        return self.sessions[sid]

    def snapshot(self, sid):
        with self.lock:
            return self._get_locked(sid).snapshot()

    def append(self, sid, offset, pcm):
        if type(offset) is not int or offset < 0:
            raise StreamError(400, "X-Audio-Offset 须为非负整数样本位置。")
        if not pcm or len(pcm) % 2 or len(pcm) > MAX_CHUNK_BYTES:
            raise StreamError(413, "音频分片须为不超过 2 MiB 的非空 16 位 PCM。")
        digest = hashlib.sha256(pcm).digest()
        with self.lock:
            session = self._get_locked(sid)
            if session.state in TERMINAL:
                raise StreamError(409, "此录音会话已经结束。")
            previous = session.parts.get(offset)
            if previous:
                if previous == (len(pcm), digest):
                    return session.snapshot()
                raise StreamError(409, "重复分片内容不一致，未修改已有录音。")
            if session.finish_at is not None:
                raise StreamError(409, "录音已提交，不能追加音频。")
            if offset != session.received:
                raise StreamError(409, "音频分片顺序不连续，请从已接收的位置重试。")
            if session.received + len(pcm) // 2 > MAX_SAMPLES:
                raise StreamError(413, "单段录音最长为 5 分钟，请分段口述。")
            if len(session.parts) >= MAX_PARTS:
                raise StreamError(413, "音频分片数量过多，请增加每次上传的分片长度。")
            if sum(len(s.audio) for s in self.sessions.values()) + len(pcm) > MAX_AUDIO_MEMORY:
                raise StreamError(429, "待处理音频较多，请稍后重试。")
            session.audio.extend(pcm)
            session.received += len(pcm) // 2
            session.parts[offset] = (len(pcm), digest)
            session.last_input_at = self.clock()
            self._schedule_locked(session)
            return session.snapshot()

    def finish(self, sid, total_samples):
        if type(total_samples) is not int or total_samples <= 0:
            raise StreamError(400, "total_samples 须为大于零的整数。")
        with self.lock:
            session = self._get_locked(sid)
            if session.received != total_samples:
                raise StreamError(409, "提交样本数与已接收音频不一致，尚未结束录音。")
            if session.finish_at is None and session.state not in TERMINAL:
                session.finish_at = self.clock()
                # A call crossing finish belongs wholly to post-stop compute.
                session.pre_stop_asr_seconds = session.asr_seconds
                session.pre_stop_processed = session.processed
                self._schedule_locked(session)
            done = session.done
        # Waiting belongs to this HTTP connection. Other request threads remain
        # free to receive the next recording; retries share this same event.
        # A disconnected client cannot leave a finish waiter alive forever.
        # Reaping cancels the logical session; an already running GPU call
        # remains counted as busy until the worker really returns.
        while not done.wait(1.0):
            with self.lock:
                self._reap_locked()
        with self.lock:
            if session.state == "completed":
                return session.result
            raise StreamError(session.error_status, session.error or "录音处理未完成。")

    def cancel(self, sid):
        with self.lock:
            session = self._get_locked(sid)
            if session.state not in TERMINAL:
                self._terminate_locked(session, "cancelled", 410, "录音已取消。")
            return session.snapshot()

    def _schedule_locked(self, session):
        if session.scheduled or session.state in TERMINAL:
            return
        pending = session.received - session.processed
        if session.finish_at is None and pending < TARGET_SAMPLES + LOOKAHEAD_SAMPLES:
            session.state = "recording"
            return
        session.scheduled, session.state = True, "queued"
        self.jobs += 1
        try:
            self.worker.submit(self._step, session)
        except RuntimeError:
            self.jobs -= 1
            session.scheduled = False
            self._terminate_locked(session, "failed", 503, "识别服务正在退出，请稍后重试。")

    def _step(self, session):
        try:
            with self.lock:
                if session.state in TERMINAL:
                    return
                processed = session.processed
                # A fixed prefix is sufficient for the next stable boundary.
                # Retaining all accepted bytes permits strict retry validation.
                pcm = bytes(session.audio[processed * 2:
                            min(session.received, processed + TARGET_SAMPLES + LOOKAHEAD_SAMPLES) * 2])
                finished = session.finish_at is not None
                edit = finished and not pcm
                session.state = "editing" if edit else "transcribing"
                raw = " ".join(session.texts).strip()
            if edit:
                result = self.complete(raw, session.received / SAMPLE_RATE,
                                       session.asr_seconds, session.options)
                with self.lock:
                    if session.state in TERMINAL:
                        return
                    now = self.clock()
                    result["streaming_metrics"] = {
                        "asr_calls": session.asr_calls,
                        "processed_audio_before_stop_seconds": round(session.pre_stop_processed / SAMPLE_RATE, 3),
                        "asr_before_stop_seconds": round(session.pre_stop_asr_seconds, 3),
                        "asr_after_stop_seconds": round(session.asr_seconds - session.pre_stop_asr_seconds, 3),
                        "stop_to_result_seconds": round(now - session.finish_at, 3),
                        "received_samples": session.received, "processed_samples": session.processed,
                    }
                    session.result, session.state, session.terminal_at = result, "completed", now
                    session.audio.clear()
                    session.parts.clear()
                    session.done.set()
                    LOG.info("Stream completed %.1fs audio: %d ASR calls, pre-stop %.2fs, tail %.2fs, edit %.2fs",
                             session.received / SAMPLE_RATE, session.asr_calls,
                             session.pre_stop_asr_seconds, session.asr_seconds - session.pre_stop_asr_seconds,
                             result["cleanup_seconds"])
            else:
                cut = next_cut(pcm, finished)
                if cut is None:
                    return
                started = self.clock()
                transcription = self.transcribe(pcm[:cut * 2], session.options,
                                                 self.max_tokens - session.tokens)
                text, tokens = transcription[:2]
                # Older adapters return a pair (one model call). Current ASR
                # reports zero for digital silence and two for context-echo
                # verification, so metrics reflect actual model work.
                calls = transcription[2] if len(transcription) > 2 else 1
                ended = self.clock()
                with self.lock:
                    if session.state in TERMINAL:
                        return
                    session.processed += cut
                    session.texts.append(text)
                    session.tokens += tokens
                    session.asr_calls += calls
                    session.asr_seconds += ended - started
        except Exception as exc:
            LOG.error("Stream inference failed (%s)", type(exc).__name__)
            with self.lock:
                if session.state not in TERMINAL:
                    status = getattr(exc, "status", 500)
                    # Internal exceptions can contain private model input. Only
                    # explicit protocol errors are suitable for the client.
                    message = getattr(exc, "message", "本地识别失败，可使用完整录音重试。")
                    self._terminate_locked(session, "failed", status, message)
        finally:
            with self.lock:
                self.jobs -= 1
                session.scheduled = False
                if session.state not in TERMINAL:
                    self._schedule_locked(session)

    def close(self):
        with self.lock:
            self.closed = True
            for session in self.sessions.values():
                if session.state not in TERMINAL:
                    self._terminate_locked(session, "cancelled", 503, "识别服务正在退出。")
