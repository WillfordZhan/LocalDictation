"""Windows CPU model adapter for the shared dictation service.

Whisper runs in-process on the service's single model worker. llama.cpp is an
owned, loopback-only child; Windows Job Objects also stop it if Python crashes.
No cloud endpoint, system model manager or inference-time download is used.
"""
from __future__ import annotations

import atexit
import json
import logging
import os
from pathlib import Path
import secrets
import socket
import subprocess
import threading
import time
import urllib.request

from server import (DictationOptions, QWEN_ASR_MAX_TOKENS, RequestError,
                    cleanup_messages, echoes_vocabulary_context, has_audio_signal,
                    parse_cleanup_output)
from windows_setup import inspect_models, load_manifest, model_directory

LOG = logging.getLogger("local-dictation")
FINAL_TEXT_SCHEMA = {"type": "object", "properties": {"text": {"type": "string"}},
                     "required": ["text"], "additionalProperties": False}


def attach_kill_job(process):
    """Keep the job handle solely in the parent; closing it kills this child."""
    if os.name != "nt":
        return None
    import ctypes
    from ctypes import wintypes

    class Limits(ctypes.Structure):
        _fields_ = [("process_time", ctypes.c_longlong), ("job_time", ctypes.c_longlong),
                    ("flags", wintypes.DWORD), ("min_working_set", ctypes.c_size_t),
                    ("max_working_set", ctypes.c_size_t), ("active_processes", wintypes.DWORD),
                    ("affinity", ctypes.c_size_t), ("priority", wintypes.DWORD), ("scheduling", wintypes.DWORD)]

    class IOCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_ulonglong) for name in
                    ("read_ops", "write_ops", "other_ops", "read_bytes", "write_bytes", "other_bytes")]

    class Extended(ctypes.Structure):
        _fields_ = [("limits", Limits), ("io", IOCounters), ("process_memory", ctypes.c_size_t),
                    ("job_memory", ctypes.c_size_t), ("peak_process", ctypes.c_size_t), ("peak_job", ctypes.c_size_t)]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    job = kernel.CreateJobObjectW(None, None)
    if not job:
        raise OSError("无法创建本地模型进程容器。")
    child = None
    try:
        limits = Extended()
        limits.limits.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not kernel.SetInformationJobObject(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            raise OSError("无法设置本地模型进程退出规则。")
        child = kernel.OpenProcess(0x0101, False, process.pid)  # SET_QUOTA | TERMINATE
        if not child or not kernel.AssignProcessToJobObject(job, child):
            raise OSError("无法绑定本地模型进程。")
        return (kernel, job)
    except Exception:
        kernel.CloseHandle(job)
        raise
    finally:
        if child:
            kernel.CloseHandle(child)


class WindowsModels:
    def __init__(self, data_dir, llama_server, *, threads=None, cleanup_timeout=180.0):
        self.data_dir = Path(data_dir)
        catalog = {item["id"]: item for item in load_manifest()}
        self.asr_path = model_directory(self.data_dir, catalog["asr"])
        self.cleanup_path = model_directory(self.data_dir, catalog["cleanup"])
        self.cleanup_file = self.cleanup_path / next(item["path"] for item in catalog["cleanup"]["files"]
                                                     if item["path"].endswith(".gguf"))
        self.llama_server = Path(llama_server)
        self.threads = threads or min(8, max(1, (os.cpu_count() or 2) // 2))
        self.cleanup_timeout = cleanup_timeout
        self.asr_model = None
        self.asr_ready = self.cleanup_ready = False
        self.message = "正在加载本地模型。"
        self.last_cleanup_metrics = None
        self._process = None
        self._job = None
        self._closed = threading.Event()
        self._child_lock = threading.RLock()
        self._url = None
        self._key = secrets.token_urlsafe(32)
        # Proxy environment variables must not route private transcripts off
        # this machine. The child is reached through a literal loopback URL.
        self._http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        atexit.register(self.close)

    def _request(self, route, payload=None, timeout=5):
        headers = {"Authorization": "Bearer " + self._key}
        body = None
        if payload is not None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self._url + route, data=body, headers=headers)
        with self._http.open(request, timeout=timeout) as response:
            value = response.read(2 * 1024 * 1024 + 1)
        if len(value) > 2 * 1024 * 1024:
            raise ValueError("Local model response exceeded its size limit")
        return json.loads(value)

    def _start_cleanup(self):
        if not self.llama_server.is_file():
            raise RuntimeError("应用内置的文字整理运行环境缺失，请重新解压完整安装包。")
        with socket.socket() as lease:
            lease.bind(("127.0.0.1", 0))
            port = lease.getsockname()[1]
        self._url = f"http://127.0.0.1:{port}"
        arguments = [str(self.llama_server), "--model", str(self.cleanup_file),
                     "--host", "127.0.0.1", "--port", str(port), "--api-key", self._key,
                     "--threads", str(self.threads), "--ctx-size", "8192", "--parallel", "1",
                     "--n-gpu-layers", "0", "--jinja", "--no-webui", "--log-disable"]
        with self._child_lock:
            if self._closed.is_set():
                raise RuntimeError("服务正在退出。")
            # Native engine logs may contain generated tokens. Discard them;
            # Python logs only stage/timing/error type, never request text.
            self._process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            try:
                self._job = attach_kill_job(self._process)
            except Exception:
                self._process.terminate()
                self._process.wait(timeout=5)
                self._process = None
                raise
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline and not self._closed.is_set():
            if self._process is None or self._process.poll() is not None:
                raise RuntimeError("本地文字整理进程未能启动。")
            try:
                if self._request("/health", timeout=2).get("status") == "ok":
                    return
            except Exception:
                pass
            self._closed.wait(.25)
        raise TimeoutError("本地文字整理模型加载超时。")

    def load(self):
        if self._closed.is_set():
            return
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
        checks = {item["id"]: item for item in inspect_models(self.data_dir)["checks"]}
        if not checks["asr"]["ready"]:
            raise RuntimeError("语音识别模型尚未校验，请先运行一键配置。")
        from faster_whisper import WhisperModel
        self.asr_model = WhisperModel(str(self.asr_path), device="cpu", compute_type="int8",
                                     cpu_threads=self.threads, num_workers=1, local_files_only=True)
        self.asr_ready = True
        if self._closed.is_set():
            return
        self.message = "语音识别已就绪，正在加载文字整理模型。"
        try:
            if not checks["cleanup"]["ready"]:
                raise RuntimeError("文字整理模型尚未校验。")
            self._start_cleanup()
            self.cleanup_ready = True
            self.message = "本地识别和文字整理已就绪。"
        except Exception as exc:
            self._stop_child()
            LOG.warning("Windows cleanup unavailable (%s)", type(exc).__name__)
            self.message = "语音识别已就绪；文字整理不可用，将保留原始转写。"

    def transcribe(self, recording, options=DictationOptions()):
        return self.transcribe_segment(recording, options)[0]

    def transcribe_segment(self, recording, options, max_tokens=QWEN_ASR_MAX_TOKENS):
        import numpy as np
        samples = np.frombuffer(recording.frames, dtype="<i2").astype(np.float32) / 32768.0
        if recording.channels == 2:
            samples = samples.reshape(-1, 2).mean(axis=1)
        if recording.sample_rate != 16000:
            # The native client sends 16 kHz mono. NumPy interpolation keeps
            # the legacy WAV endpoint usable without adding a SciPy runtime.
            size = round(len(samples) * 16000 / recording.sample_rate)
            samples = np.interp(np.arange(size) * recording.sample_rate / 16000,
                                np.arange(len(samples)), samples).astype(np.float32)
        if not has_audio_signal(samples):
            return "", 0, 0
        if self.asr_model is None:
            raise RuntimeError("语音识别模型尚未加载。")

        def decode(vocabulary, budget):
            if budget <= 0:
                raise RequestError(422, "语音转写达到长度上限，请缩短录音后重试。")
            segments, _ = self.asr_model.transcribe(samples, language="zh" if options.language == "zh" else None,
                task="transcribe", beam_size=5, temperature=0.0, condition_on_previous_text=False,
                vad_filter=False, hotwords=" ".join(vocabulary) or None)
            texts, tokens = [], 0
            # Whisper's 448-token decoder window includes its prompt; do not
            # pass the session's 8192-token budget as per-window max_new_tokens.
            # Account for actual returned tokens across windows and retries.
            for segment in segments:
                tokens += len(segment.tokens)
                if tokens >= budget:
                    raise RequestError(422, "语音转写达到长度上限，未返回截断文字。请缩短录音后重试。")
                texts.append(segment.text)
            return "".join(texts).strip(), tokens

        text, tokens = decode(options.vocabulary, max_tokens)
        calls = 1
        if echoes_vocabulary_context(text, options.vocabulary):
            text, retry_tokens = decode((), max_tokens - tokens)
            tokens += retry_tokens
            calls += 1
        return text, tokens, calls

    def cleanup(self, raw_text, options=DictationOptions()):
        if self._closed.is_set() or not self.cleanup_ready:
            raise RuntimeError("Local cleanup is unavailable")
        self.last_cleanup_metrics = None
        started = time.monotonic()
        # The native CPU path has a bounded but longer deadline than Metal.
        # No retry or secondary model is used; any failure preserves ASR.
        budget = min(4096, max(128, len(raw_text) * 2 + 64))
        try:
            result = self._request("/v1/chat/completions", {
                "messages": cleanup_messages(raw_text, options), "temperature": 0,
                "max_tokens": budget, "stream": False, "cache_prompt": True,
                "response_format": {"type": "json_object", "schema": FINAL_TEXT_SCHEMA},
            }, timeout=self.cleanup_timeout)
        except TimeoutError:
            # An HTTP deadline alone does not prove the native decoder stopped.
            # Reap our child before the worker can accept another generation.
            self.cleanup_ready = False
            self.message = "文字整理超时，已保留原始转写。重新启动服务后可再试。"
            self._stop_child()
            raise
        if time.monotonic() - started > self.cleanup_timeout:
            raise TimeoutError("Cleanup exceeded its deadline")
        choices = result.get("choices", [])
        if len(choices) != 1 or choices[0].get("finish_reason") != "stop":
            raise ValueError("Cleanup response was not complete")
        text = parse_cleanup_output(choices[0].get("message", {}).get("content"))
        usage = result.get("usage", {})
        if usage.get("completion_tokens", 0) >= budget:
            raise ValueError("Cleanup exceeded its completion budget")
        self.last_cleanup_metrics = {"total_seconds": time.monotonic() - started,
                                     "generation_tokens": usage.get("completion_tokens", 0)}
        LOG.info("Windows cleanup completed in %.3fs", self.last_cleanup_metrics["total_seconds"])
        return text

    def _stop_child(self):
        with self._child_lock:
            process, self._process = self._process, None
            if self._job:
                kernel, handle = self._job
                self._job = None
                kernel.CloseHandle(handle)
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

    def close(self):
        self._closed.set()
        self.cleanup_ready = False
        self._stop_child()
