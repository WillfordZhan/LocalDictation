#!/usr/bin/env python3
"""Verify every runtime file before signing or packaging a release."""
import hashlib
import json
from pathlib import Path
import os
import sys

def validate(root):
    root = root.resolve(strict=True)
    manifest = json.loads((root / "runtime-manifest.json").read_text())
    if manifest.get("schema") != 1 or not manifest.get("files"):
        raise ValueError("Invalid runtime manifest")
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
