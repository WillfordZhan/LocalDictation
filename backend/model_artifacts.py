"""Pinned model inventory and CPU-only artifact verification shared by setup.

Hashes describe the published revision, not whatever happened to download. A
receipt permits inexpensive later checks only while file sizes and mtimes still
match; explicit downloads always verify the actual bytes before reuse/publish.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import uuid

MANIFEST_PATH = Path(__file__).with_name("model-manifest.json")
RECEIPT_NAME = "local-dictation-source.json"


def load_manifest(path=MANIFEST_PATH):
    value = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("schema") != 1 or not isinstance(value.get("models"), list):
        raise ValueError("模型清单结构无效。")
    found = {}
    for model in value["models"]:
        if model["id"] in found or not re.fullmatch(r"[a-f0-9]{40}", model["revision"]):
            raise ValueError("模型清单存在重复标识或无效 revision。")
        if PurePosixPath(model["directory"]).name != model["directory"] or model["directory"] in ("", ".", ".."):
            raise ValueError("模型目录必须是单个目录名。")
        paths = set()
        for item in model["files"]:
            relative = PurePosixPath(item["path"])
            if relative.is_absolute() or not relative.parts or any(part in (".", "..") for part in relative.parts):
                raise ValueError("模型文件路径无效。")
            if item["path"] in paths or type(item["size"]) is not int or item["size"] <= 0 or not re.fullmatch(r"[a-f0-9]{64}", item["sha256"]):
                raise ValueError("模型文件校验信息无效。")
            paths.add(item["path"])
        if not paths:
            raise ValueError("模型文件清单为空。")
        found[model["id"]] = model
    if set(found) != {"qwen", "whisper", "cleanup"}:
        raise ValueError("模型清单缺少必要的识别或整理模型。")
    return found


def selected_models(asr_backend, manifest=None):
    models = load_manifest() if manifest is None else manifest
    return [models[asr_backend], models["cleanup"]]


def artifact_path(directory, relative):
    directory = Path(directory)
    path = directory
    if directory.is_symlink():
        raise ValueError("模型目录不能使用外部符号链接。")
    for component in PurePosixPath(relative).parts:
        path = path / component
        if path.is_symlink():
            raise ValueError("模型文件不能使用外部符号链接。")
    return path


def file_matches(path, item, deep=True, progress=None):
    try:
        if not path.is_file() or path.is_symlink() or path.stat().st_size != item["size"]:
            return False
        if not deep:
            return True
        digest = hashlib.sha256()
        completed = 0
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
                digest.update(block)
                completed += len(block)
                if progress: progress(completed)
        return digest.hexdigest() == item["sha256"]
    except OSError:
        return False


def inspect_model(directory, model, *, deep=False, progress=None):
    directory = Path(directory)
    total = sum(item["size"] for item in model["files"])
    invalid, verified_bytes = [], 0
    for item in model["files"]:
        base = verified_bytes
        try:
            path = artifact_path(directory, item["path"])
            valid = file_matches(path, item, deep=deep,
                progress=(lambda done: progress(base + done, total)) if progress else None)
        except ValueError:
            valid = False
        if valid:
            verified_bytes += item["size"]
        else:
            invalid.append(item["path"])
    receipt_valid = False
    if not invalid:
        try:
            receipt = json.loads(artifact_path(directory, RECEIPT_NAME).read_text())
            expected = [{**item, "mtime_ns": artifact_path(directory, item["path"]).stat().st_mtime_ns}
                        for item in model["files"]]
            receipt_valid = (isinstance(receipt, dict) and receipt.get("schema") == 1 and receipt.get("revision") == model["revision"]
                             and receipt.get("repo_id") == model["repo_id"] and receipt.get("files") == expected)
        except (OSError, ValueError, TypeError):
            pass
    status = ("missing" if not directory.exists() else "invalid") if invalid else ("ok" if deep or receipt_valid else "warning")
    message = {"ok": "模型文件已校验。" if deep else "模型文件与校验记录一致。",
               "missing": "模型尚未下载。", "invalid": "部分模型文件缺失或未通过校验。",
               "warning": "模型文件已存在，需要本地完整校验；不必先重新下载。"}[status]
    return {"id": model["id"], "model_id": model["directory"], "repo_id": model["repo_id"],
            "revision": model["revision"], "status": status, "ready": status == "ok",
            "message": message, "path": str(directory), "total_bytes": total,
            "required_download_bytes": sum(item["size"] for item in model["files"] if item["path"] in invalid),
            "invalid_files": invalid, "verification": "sha256" if deep else "receipt_and_stat",
            "receipt_valid": receipt_valid}


def write_receipt(directory, model):
    directory = Path(directory)
    payload = {"schema": 1, "repo_id": model["repo_id"], "revision": model["revision"],
               "directory": model["directory"], "files": [
                   {**item, "mtime_ns": artifact_path(directory, item["path"]).stat().st_mtime_ns}
                   for item in model["files"]]}
    destination = directory / RECEIPT_NAME
    temporary = directory / (RECEIPT_NAME + ".tmp-" + uuid.uuid4().hex)
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            os.chmod(temporary, 0o600)
            json.dump(payload, stream, ensure_ascii=False, indent=2)
            stream.write("\n"); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        try: temporary.unlink(missing_ok=True)
        except OSError: pass
