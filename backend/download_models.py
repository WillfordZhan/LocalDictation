#!/usr/bin/env python3
"""Acquire and verify pinned model files; never publish an incomplete model."""
from __future__ import annotations

import argparse
import ctypes
import errno
import fcntl
import io
import json
import os
from pathlib import Path
import shutil
import signal
import sys
import threading
import time
import uuid

from model_artifacts import (artifact_path, file_matches, inspect_model,
                             selected_models, write_receipt)


class DownloadCancelled(BaseException):
    pass


class Events:
    def __init__(self, json_events=False, stream=None):
        self.json_events = json_events
        self.stream = stream or sys.stdout
        self.lock = threading.Lock()
        self.last_progress = {}

    def emit(self, event, **fields):
        with self.lock:
            if event == "progress":
                key = (fields.get("model_id"), fields.get("operation"))
                now = time.monotonic()
                if now - self.last_progress.get(key, -1) < 0.2:
                    return
                self.last_progress[key] = now
            value = {"schema": 1, "event": event, "stage": "model", **fields}
            if self.json_events:
                print(json.dumps(value, ensure_ascii=False), file=self.stream, flush=True)
            elif fields.get("message") and event != "progress":
                print(fields["message"], file=self.stream, flush=True)


def hf_fetch(model, item, stage, progress, force_download=False):
    # The network boundary is lazy: valid artifacts need no SDK or credentials.
    os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
    from huggingface_hub import hf_hub_download
    from tqdm.auto import tqdm

    class DownloadProgress(tqdm):
        # Downloads are sequential in this process. Avoid tqdm creating a
        # multiprocessing semaphore solely to protect our JSON callback.
        _lock = threading.RLock()

        def __init__(self, *args, **kwargs):
            kwargs.update(disable=False, leave=False, file=io.StringIO())
            super().__init__(*args, **kwargs)

        def display(self, *args, **kwargs):
            if getattr(self, "unit", None) == "B":
                progress(max(0, int(getattr(self, "n", 0))))

        def update(self, n=1):
            result = super().update(n)
            if getattr(self, "unit", None) == "B": progress(max(0, int(self.n)))
            return result

    return hf_hub_download(repo_id=model["repo_id"], filename=item["path"], revision=model["revision"],
        local_dir=str(stage), token=False, tqdm_class=DownloadProgress, force_download=force_download)


def exchange_directories(left, right):
    """Darwin atomically exchanges complete directories, or leaves both intact."""
    if sys.platform != "darwin":
        raise OSError(errno.ENOTSUP, "当前系统不支持安全交换已有模型目录。")
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # sys/stdio.h: RENAME_SWAP = 0x2, supported from macOS 10.12. Do not
    # fall back to two renames on unsupported volumes: they leave a crash gap.
    if rename(os.fsencode(left), os.fsencode(right), 0x2) != 0:
        code = ctypes.get_errno()
        raise OSError(code, "无法安全交换模型目录：" + os.strerror(code))


def publish_model(stage, destination):
    """Publish a complete model atomically; retain the old model after exchange."""
    if not destination.exists() and not destination.is_symlink():
        stage.rename(destination)
        return
    exchange_directories(stage, destination)
    # At this point destination is complete even if SIGKILL interrupts us. The
    # old model survives at stage until the optional backup rename succeeds.
    previous = destination.with_name(".previous-" + destination.name + "-" + uuid.uuid4().hex)
    try:
        stage.rename(previous)
    except OSError:
        pass  # Publication succeeded; retaining the backup at stage is safe.


def prepare_model(models_dir, model, events, fetch_file=hf_fetch):
    destination = models_dir / model["directory"]
    total = sum(item["size"] for item in model["files"])
    identity = {"model_id": model["directory"], "id": model["id"]}
    events.emit("start", **identity, operation="verify", total_bytes=total,
                message=f"正在检查 {model['directory']}…")
    existing = inspect_model(destination, model, deep=True, progress=lambda done, size:
        events.emit("progress", **identity, operation="verify", completed_bytes=done, total_bytes=size))
    if existing["ready"]:
        if not existing["receipt_valid"]: write_receipt(destination, model)
        events.emit("verified", **identity, reused=True, completed_bytes=total, total_bytes=total,
                    message=f"已校验并复用 {model['directory']}。")
        return {**identity, "path": str(destination), "revision": model["revision"], "reused": True}

    # A stable staging path retains completed files across retries. Hub 2.3
    # removes interrupted per-file transfers; do not promise byte-range resume.
    # The existing model directory is untouched until complete verification.
    stage = models_dir / ".downloads" / (model["directory"] + "-" + model["revision"])
    if stage.is_symlink() or stage.parent.is_symlink():
        raise ValueError("下载阶段目录不能是符号链接。")
    stage.mkdir(parents=True, exist_ok=True)
    completed = 0
    for item in model["files"]:
        target = artifact_path(stage, item["path"])
        target.parent.mkdir(parents=True, exist_ok=True)
        if file_matches(target, item):
            completed += item["size"]
            continue
        # Recover valid files from incomplete legacy assets without borrowing
        # symlinks or changing the remaining original files.
        try:
            original = artifact_path(destination, item["path"])
            if file_matches(original, item):
                shutil.copy2(original, target)
                completed += item["size"]
                continue
        except ValueError:
            pass
        if shutil.disk_usage(stage).free < total - completed:
            raise OSError("磁盘空间不足，已完成的下载保留，请释放空间后重试。")
        base = completed
        events.emit("start", **identity, operation="download", file=item["path"],
                    completed_bytes=base, total_bytes=total, message=f"正在下载 {model['directory']} / {item['path']}…")
        # A completed but corrupt staged file must bypass SDK cache reuse.
        # Missing targets use the SDK's normal transfer path. SDK 2.3 starts
        # an interrupted individual file again; completed files above are reused.
        fetch_file(model, item, stage, lambda done:
            events.emit("progress", **identity, operation="download", file=item["path"],
                        completed_bytes=base + min(done, item["size"]), total_bytes=total), target.exists())
        if not file_matches(target, item):
            raise ValueError(f"下载文件未通过 SHA-256 校验：{model['directory']} / {item['path']}；原模型未替换。")
        completed += item["size"]
    if not inspect_model(stage, model, deep=True)["ready"]:
        raise ValueError("模型最终校验失败，下载阶段目录已保留。")
    write_receipt(stage, model)
    publish_model(stage, destination)
    events.emit("verified", **identity, reused=False, completed_bytes=total, total_bytes=total,
                message=f"{model['directory']} 已下载并通过完整校验。")
    return {**identity, "path": str(destination), "revision": model["revision"], "reused": False}


def download_models(models_dir, asr_backend="qwen", events=None, *, manifest=None, fetch_file=hf_fetch):
    events = events or Events()
    models_dir = Path(models_dir)
    if models_dir.is_symlink(): raise ValueError("模型安装目录不能是符号链接。")
    models_dir.mkdir(parents=True, exist_ok=True)
    # flock is released by the OS on cancellation/crash; the file may remain.
    with (models_dir / ".download.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise OSError("已有模型下载正在进行，请等待或取消后重试。") from exc
        result = [prepare_model(models_dir, model, events, fetch_file)
                  for model in selected_models(asr_backend, manifest)]
    events.emit("complete", models=result, ready=True, message="所选语音识别与整理模型已就绪，可离线使用。")
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models-dir", type=Path, required=True)
    parser.add_argument("--asr-backend", choices=("whisper", "qwen"), default="qwen")
    parser.add_argument("--json-events", action="store_true", help="stdout 仅输出安装事件 JSONL")
    args = parser.parse_args(argv)
    events = Events(args.json_events)
    def cancelled(signum, frame): raise DownloadCancelled()
    previous = {number: signal.signal(number, cancelled) for number in (signal.SIGINT, signal.SIGTERM)}
    try:
        download_models(args.models_dir, args.asr_backend, events)
        return 0
    except DownloadCancelled:
        events.emit("cancelled", retryable=True, message="下载已取消，已完成的文件保留，重试时会跳过这些文件。")
        return 130
    except Exception as exc:
        events.emit("error", retryable=True, message=str(exc))
        return 1
    finally:
        for number, handler in previous.items(): signal.signal(number, handler)


if __name__ == "__main__":
    raise SystemExit(main())
