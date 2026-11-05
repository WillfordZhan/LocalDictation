#!/usr/bin/env python3
"""Verify every runtime file before signing or packaging a release."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import os
import sys

def validate(root):
    root = root.resolve(strict=True)
    manifest_path = root / "runtime-manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("Invalid runtime manifest file")
    manifest = json.loads(manifest_path.read_text())
    if not isinstance(manifest, dict) or manifest.get("schema") != 1 or not isinstance(manifest.get("files"), list) or not manifest["files"]:
        raise ValueError("Invalid runtime manifest")

    def reject_bytecode(relative):
        parts = PurePosixPath(relative).parts
        if "__pycache__" in parts or PurePosixPath(relative).suffix.lower() in (".pyc", ".pyo"):
            # Python caches embed the compilation path. Even a refreshed
            # manifest must not make builder-specific bytecode publishable.
            raise ValueError("Forbidden runtime bytecode/cache: " + relative)

    expected = set()
    for entry in manifest["files"]:
        relative = entry.get("path") if isinstance(entry, dict) else None
        if not isinstance(relative, str) or not relative:
            raise ValueError("Invalid runtime manifest path")
        path = PurePosixPath(relative)
        if path.is_absolute() or ".." in path.parts or str(path) != relative or relative in (".", "runtime-manifest.json"):
            raise ValueError("Invalid runtime manifest path: " + relative)
        reject_bytecode(relative)
        if relative in expected:
            raise ValueError("Duplicate runtime manifest path: " + relative)
        expected.add(relative)

    # Verify inventory as well as hashes: imports during local evaluation can
    # append files after a runtime was sanitized. Do not follow directory links;
    # their link entries are verified below, and their targets have own entries.
    actual = set()
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            relative = path.relative_to(root).as_posix()
            reject_bytecode(relative)
            if path.is_symlink() or not path.is_dir():
                if relative != "runtime-manifest.json":
                    actual.add(relative)
    extra = actual - expected
    if extra:
        raise ValueError("Unlisted runtime file: " + sorted(extra)[0])
    missing = expected - actual
    if missing:
        raise ValueError("Runtime file missing: " + sorted(missing)[0])
    if not (root / "share/licenses/python-build-standalone/SOURCE.json").is_file():
        raise ValueError("Missing standalone Python third-party license provenance")
    for entry in manifest["files"]:
        path = root / entry["path"]
        if not path.resolve().is_relative_to(root):
            raise ValueError("External runtime path: " + entry["path"])
        if "link" in entry:
            if not path.is_symlink() or os.readlink(path) != entry["link"]:
                raise ValueError("Runtime link mismatch: " + entry["path"])
        else:
            if path.is_symlink() or not path.is_file() or path.stat().st_size != entry["bytes"]:
                raise ValueError("Runtime file missing or changed: " + entry["path"])
            with path.open("rb") as stream:
                if hashlib.file_digest(stream, "sha256").hexdigest() != entry["sha256"]:
                    raise ValueError("Runtime hash mismatch: " + entry["path"])
    print(f"Verified {len(manifest['files'])} runtime entries")

if __name__ == "__main__":
    validate(Path(sys.argv[1]))
