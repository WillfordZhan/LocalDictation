#!/usr/bin/env python3
"""Download pinned Windows models without importing an inference runtime.

Completed files are verified before atomic publication. Versioned directories
and a final receipt prevent a partial download from appearing ready to launch.
The application and user data are deliberately stored in separate locations.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import time
import urllib.error
import urllib.request
import uuid

MANIFEST_PATH = Path(__file__).with_name("windows-model-manifest.json")
RECEIPT = "verified-model.json"


def default_data_dir():
    return Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData/Local")) / "LocalDictation"


def load_manifest(path=MANIFEST_PATH):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema") != 1:
        raise ValueError("Windows 模型清单无效。")
    models = value.get("models", [])
    if {model.get("id") for model in models} != {"asr", "cleanup"} or len(models) != 2:
        raise ValueError("Windows 模型清单须包含识别和润色模型。")
    for model in models:
        directory = model["directory"]
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", directory) or directory in (".", ".."):
            raise ValueError("模型目录名无效。")
        if not re.fullmatch(r"[a-f0-9]{40}", model["revision"]):
            raise ValueError("模型版本无效。")
        seen = set()
        for item in model["files"]:
            path = PurePosixPath(item["path"])
            if (path.is_absolute() or not path.parts or any(p in (".", "..") for p in path.parts)
                    or "\\" in item["path"] or ":" in item["path"] or item["path"] in seen):
                raise ValueError("模型文件路径无效。")
            seen.add(item["path"])
            if type(item["size"]) is not int or item["size"] <= 0 or not re.fullmatch(r"[a-f0-9]{64}", item["sha256"]):
                raise ValueError("模型文件校验信息无效。")
            if "url" in item and not item["url"].startswith("https://"):
                raise ValueError("模型文件只允许 HTTPS 下载。")
        if not seen:
            raise ValueError("模型文件清单为空。")
    return models


def model_directory(data_dir, model):
    return Path(data_dir) / "Runtime" / "models" / model["directory"]


def safe_path(root, relative):
    root = Path(root)
    if root.is_symlink():
        raise ValueError("模型目录不能是符号链接。")
    path = root
    for part in PurePosixPath(relative).parts:
        path = path / part
        if path.is_symlink():
            raise ValueError("模型文件不能是符号链接。")
    return path


def sha256_file(path, progress=None):
    digest = hashlib.sha256()
    completed = 0
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
            completed += len(block)
            if progress:
                progress(completed)
    return digest.hexdigest()


def file_matches(path, item):
    return (path.is_file() and not path.is_symlink() and path.stat().st_size == item["size"]
            and sha256_file(path) == item["sha256"])


def receipt_content(directory, model):
    return {"schema": 1, "repo_id": model["repo_id"], "revision": model["revision"],
            "files": [{**item, "mtime_ns": safe_path(directory, item["path"]).stat().st_mtime_ns}
                      for item in model["files"]]}


def inspect_runtime():
    """Check DLL availability without importing a model or installing software."""
    missing = []
    if os.name == "nt":
        import ctypes
        for name in ("msvcp140.dll", "vcruntime140_1.dll"):
            try:
                # Do not search the current working directory for these system
                # runtime libraries; the app offers Microsoft's installer.
                ctypes.WinDLL(name, winmode=0x00000800)  # LOAD_LIBRARY_SEARCH_SYSTEM32
            except OSError:
                missing.append(name)
    ready = not missing
    return {"id": "vc_runtime", "name": "Microsoft Visual C++ 运行库", "ready": ready,
            "status": "ready" if ready else "missing", "required_bytes": 0,
            "message": "运行库已就绪。" if ready else "需要安装 Microsoft Visual C++ 运行库，点击安装运行库后重试。",
            "missing_libraries": missing}


def inspect_models(data_dir, manifest=None):
    models = load_manifest() if manifest is None else manifest
    checks = []
    for model in models:
        directory = model_directory(data_dir, model)
        missing = []
        for item in model["files"]:
            try:
                path = safe_path(directory, item["path"])
                if not path.is_file() or path.stat().st_size != item["size"]:
                    missing.append(item)
            except (OSError, ValueError):
                missing.append(item)
        verified = False
        if not missing:
            try:
                verified = json.loads(safe_path(directory, RECEIPT).read_text(encoding="utf-8")) == receipt_content(directory, model)
            except (OSError, ValueError):
                pass
        ready = not missing and verified
        checks.append({"id": model["id"], "name": model["name"], "ready": ready,
                       "status": "ready" if ready else "missing" if missing else "unverified",
                       "message": "已校验，可离线使用。" if ready else "需要下载模型。" if missing else "文件已存在，需要校验。",
                       "required_bytes": sum(item["size"] for item in missing), "path": str(directory)})
    models_ready = all(item["ready"] for item in checks)
    runtime = inspect_runtime()
    checks.append(runtime)
    ready = models_ready and runtime["ready"]
    return {"type": "report", "ready": ready, "status": "ready" if ready else "missing",
            "models_ready": models_ready, "runtime_ready": runtime["ready"],
            "runtime_missing": not runtime["ready"],
            "message": ("本地模型和运行库已就绪。" if ready else runtime["message"]
                        if not runtime["ready"] else "点击配置，下载或校验本地模型。"),
            "progress": 1.0 if models_ready else 0.0, "checks": checks,
            "models_dir": str(Path(data_dir) / "Runtime" / "models"),
            "total_bytes": sum(item["size"] for model in models for item in model["files"]),
            "required_bytes": sum(item["required_bytes"] for item in checks)}


@contextmanager
def download_lock(directory):
    directory.mkdir(parents=True, exist_ok=True)
    if directory.is_symlink():
        raise ValueError("模型目录不能是符号链接。")
    with (directory / ".download.lock").open("a+b") as stream:
        stream.seek(0)
        if stream.read(1) == b"":
            stream.write(b"0"); stream.flush()
        stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise OSError("已有模型配置正在运行，请等待完成。") from None
        try:
            yield
        finally:
            if os.name == "nt":
                stream.seek(0)
                msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)


def download_file(url, target, item, progress, opener=urllib.request.urlopen):
    """Resume only an exact byte range; hash every byte before replacing target."""
    partial = target.with_name(target.name + ".part")
    if partial.is_symlink():
        raise ValueError("下载临时文件不能是符号链接。")
    offset = partial.stat().st_size if partial.exists() else 0
    if offset > item["size"]:
        partial.unlink(); offset = 0
    if offset < item["size"]:
        headers = {"User-Agent": "LocalDictation-Windows/0.6", "Accept-Encoding": "identity"}
        if offset:
            headers["Range"] = f"bytes={offset}-"
        request = urllib.request.Request(url, headers=headers)
        with opener(request, timeout=45) as response:
            if response.status == 206:
                expected = f"bytes {offset}-{item['size'] - 1}/{item['size']}"
                if response.headers.get("Content-Range") != expected:
                    raise ValueError("下载响应的字节范围不匹配。")
            elif response.status == 200:
                offset = 0  # Range ignored: replace only the private partial file.
            else:
                raise ValueError("模型下载响应无效。")
            with partial.open("ab" if offset else "wb") as stream:
                for block in iter(lambda: response.read(1024 * 1024), b""):
                    if offset + len(block) > item["size"]:
                        raise ValueError("下载文件超过清单大小。")
                    stream.write(block); offset += len(block); progress(offset)
                stream.flush(); os.fsync(stream.fileno())
    if not file_matches(partial, item):
        if partial.exists() and partial.stat().st_size == item["size"]:
            partial.unlink()  # A corrupt complete file cannot be usefully resumed.
        raise ValueError("模型文件未通过 SHA-256 校验，请重试。")
    os.replace(partial, target)


def download_models(data_dir, emit, *, manifest=None, fetch=download_file, endpoint="https://huggingface.co"):
    models = load_manifest() if manifest is None else manifest
    models_dir = Path(data_dir) / "Runtime" / "models"
    total = sum(item["size"] for model in models for item in model["files"])
    completed = 0
    last_event = 0.0

    def progress(model, status, done, force=False):
        nonlocal last_event
        now = time.monotonic()
        if not force and now - last_event < .2:
            return
        last_event = now
        emit({"type": "progress", "status": status, "message": f"{'下载' if status == 'downloading' else '校验'} {model['name']}…",
              "progress": min(1.0, (completed + done) / total), "completed_bytes": completed + done,
              "total_bytes": total})

    with download_lock(models_dir):
        for model in models:
            directory = model_directory(data_dir, model)
            if directory.is_symlink():
                raise ValueError("模型目录不能是符号链接。")
            directory.mkdir(parents=True, exist_ok=True)
            for item in model["files"]:
                target = safe_path(directory, item["path"])
                target.parent.mkdir(parents=True, exist_ok=True)
                progress(model, "verifying", 0, True)
                if not file_matches(target, item):
                    if shutil.disk_usage(directory).free < item["size"]:
                        raise OSError("磁盘空间不足，已完成的下载会保留。")
                    url = item.get("url") or f"https://huggingface.co/{model['repo_id']}/resolve/{model['revision']}/{item['path']}"
                    if url.startswith("https://huggingface.co/"):
                        url = endpoint.rstrip("/") + url[len("https://huggingface.co"):]
                    fetch(url, target, item, lambda done: progress(model, "downloading", done))
                    if not file_matches(target, item):
                        raise ValueError("模型校验失败，未标记为可用。")
                completed += item["size"]
            temporary = directory / (RECEIPT + ".tmp-" + uuid.uuid4().hex)
            try:
                with temporary.open("x", encoding="utf-8") as stream:
                    json.dump(receipt_content(directory, model), stream, ensure_ascii=False)
                    stream.flush(); os.fsync(stream.fileno())
                os.replace(temporary, directory / RECEIPT)
            finally:
                temporary.unlink(missing_ok=True)
        report = inspect_models(data_dir, models)
        emit(report)
        return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=default_data_dir())
    parser.add_argument("--json", action="store_true", help="输出机器可读 JSON 报告")
    parser.add_argument("--download", action="store_true", help="下载并验证模型，输出 JSONL 进度")
    parser.add_argument("--endpoint", choices=("https://huggingface.co", "https://hf-mirror.com"),
                        default="https://huggingface.co", help="下载源；固定版本与 SHA-256 校验始终相同")
    args = parser.parse_args(argv)
    emit = lambda value: print(json.dumps(value, ensure_ascii=False), flush=True)
    try:
        if args.download:
            download_models(args.data_dir, emit, endpoint=args.endpoint)
        else:
            emit(inspect_models(args.data_dir))
        return 0
    except Exception as exc:
        # Only setup metadata is involved here, never audio or user dictation.
        emit({"type": "error", "ready": False, "status": "error", "progress": 0,
              "message": f"配置未完成：{exc}", "checks": []})
        return 1


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    raise SystemExit(main())
