"""Verify portable files without loading microphones, models or user history."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

PRIVATE_FILES = {"history.json", "history.backup.json", "preferences.json", "usage.json",
                 "cleanup-prompts.json", "cleanup-prompts.backup.json", "windows-history.json", "windows-preferences.json",
                 "id_ed25519", "id_rsa", ".env"}
TEXT_SUFFIXES = {".py", ".json", ".pth", ".cfg", ".txt", ".md", ".xml", ".config"}


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def validate(root):
    root = root.resolve(strict=True)
    manifest = json.loads((root / "bundle-manifest.json").read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or not manifest.get("files"):
        raise ValueError("Invalid bundle manifest")
    required = ("LocalDictation.exe", "coreclr.dll", "runtime/python/python.exe", "runtime/python/python311.dll",
                "runtime/python/python311._pth", "runtime/llama/llama-server.exe", "backend/windows_server.py",
                "backend/windows-model-manifest.json", "LICENSE", "THIRD_PARTY_COMPONENTS.json",
                "licenses/CPython-LICENSE.txt", "licenses/NAudio-LICENSE", "licenses/llama-LICENSE",
                "runtime/vc_redist.x64.exe")
    for relative in required:
        if not (root / relative).is_file():
            raise ValueError("Bundle file missing: " + relative)
    expected = set()
    for item in manifest["files"]:
        relative = item["path"]
        path = PurePosixPath(relative)
        if path.is_absolute() or ".." in path.parts or ":" in relative or str(path) != relative or relative in expected:
            raise ValueError("Unsafe or duplicate manifest path")
        expected.add(relative)
        target = root / relative
        if target.is_symlink() or not target.is_file() or target.stat().st_size != item["bytes"] or digest(target) != item["sha256"]:
            raise ValueError("Bundle content changed: " + relative)
    inputs_path = root / "build-inputs.json"
    inputs = json.loads(inputs_path.read_text(encoding="utf-8")) if inputs_path.exists() else {}
    wheels = {item["filename"]: item["sha256"] for item in inputs.get("wheels", [])}
    public_metadata = {item["path"]: item for item in inputs.get("upstream_build_metadata", [])}
    actual = set()
    for target in root.rglob("*"):
        relative = target.relative_to(root).as_posix()
        if target.is_symlink():
            raise ValueError("Bundle must not contain symlinks")
        if not target.is_file() or relative == "bundle-manifest.json":
            continue
        actual.add(relative)
        if any(target.name.lower() == name or target.name.lower().startswith(name + ".") for name in PRIVATE_FILES) or target.suffix.lower() in (".key", ".p12", ".pfx", ".pyc", ".pyo") or "__pycache__" in target.parts:
            raise ValueError("Private data or generated cache in bundle: " + relative)
        if target.suffix.lower() == ".gguf" or target.name == "model.bin":
            raise ValueError("Models must live outside the application")
        if target.suffix.lower() in TEXT_SUFFIXES:
            data = target.read_bytes()
            # Build-machine paths in text make a relocated runtime fragile and
            # can expose account names. Upstream examples may name public home
            # placeholders; reject the current build account, not all examples.
            home = str(Path.home()).encode()
            variants = (home, home.replace(b"\\", b"/"), home.replace(b"\\", b"\\\\"))
            if any(value and value in data for value in variants):
                origin = public_metadata.get(relative, {})
                # Only an unchanged file from a recorded wheel can carry a
                # public upstream builder path. Other local paths still fail.
                if (not relative.startswith("runtime/python/Lib/site-packages/")
                        or not origin or origin.get("sha256") != digest(target)
                        or origin.get("wheel") not in wheels
                        or wheels[origin["wheel"]] != origin.get("wheel_sha256")):
                    raise ValueError("Builder home path in bundle: " + relative)
            if b"-----BEGIN PRIVATE KEY-----" in data or b"-----BEGIN OPENSSH PRIVATE KEY-----" in data:
                raise ValueError("Private key content in bundle")
    if actual != expected:
        raise ValueError("Bundle inventory changed: " + str(sorted(actual ^ expected)[:5]))
    pth = (root / "runtime/python/python311._pth").read_text(encoding="ascii").splitlines()
    if pth != [".", "DLLs", "Lib", "Lib/site-packages", "../../backend", "import site"]:
        raise ValueError("Portable Python search paths changed")
    print(json.dumps({"bundle_files": len(expected), "integrity": "passed", "private_data": "absent"}))
    return manifest


def runtime_check(root):
    if sys.platform != "win32":
        raise RuntimeError("Runtime verification must run on Windows x64")
    python = root / "runtime/python/python.exe"
    snippet = (
        "import sys,json,ctypes,numpy,ctranslate2,faster_whisper,av,tokenizers,onnxruntime; "
        "import windows_server; "
        "assert sys.flags.isolated and sys.dont_write_bytecode; "
        "print(json.dumps({'runtime_imports':'passed','python':sys.version.split()[0]}))"
    )
    subprocess.run([str(python), "-B", "-c", snippet], check=True, timeout=90)
    llama = subprocess.run([str(root / "runtime/llama/llama-server.exe"), "--version"],
                           capture_output=True, text=True, timeout=30)
    if llama.returncode:
        raise RuntimeError("llama.cpp cannot start; check Microsoft Visual C++ runtime support")
    print(llama.stdout.strip() or llama.stderr.strip())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--runtime-check", action="store_true")
    args = parser.parse_args()
    validate(args.root)
    if args.runtime_check:
        runtime_check(args.root.resolve())
