#!/usr/bin/env python3
"""Build a relocatable runtime, without models, user data or credentials.

The source is standalone CPython plus tested site-packages, never the original
venv interpreter. End users do not need Python, Homebrew, uv or developer tools.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

MACHO = {b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def copy_tree(source, target):
    try:
        subprocess.run(["/bin/cp", "-cR", str(source), str(target)], check=True, capture_output=True)
    except subprocess.CalledProcessError:
        shutil.rmtree(target, ignore_errors=True)
        shutil.copytree(source, target, symlinks=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-home", type=Path, required=True)
    parser.add_argument("--site-packages", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    root = args.output.resolve()
    if root.exists() and not args.verify_only:
        parser.error("output exists; choose a new staging directory")
    root.parent.mkdir(parents=True, exist_ok=True)
    site = root / "lib/python3.11/site-packages"
    if not args.verify_only:
        copy_tree(args.python_home.resolve(), root)
        shutil.rmtree(site)
        copy_tree(args.site_packages.resolve(), site)
    # Venv-only patches and bytecode contain builder-specific paths.
    for path in root.rglob("__pycache__"):
        shutil.rmtree(path)
    for name in ("_virtualenv.pth", "_virtualenv.py"):
        (site / name).unlink(missing_ok=True)
    for path in (root / "bin").iterdir():
        if not path.name.startswith("python"):
            path.unlink()
    if not (root / "share/licenses/python-build-standalone/SOURCE.json").is_file():
        # The stripped archive omits CPython's bundled-library licenses.
        subprocess.run([sys.executable, str(Path(__file__).with_name("fetch_python_licenses.py")),
                        "--python-home", str(root), "--cache-dir", str(root.parent / "python-license-cache")], check=True)
    external, native, entries = [], [], []
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        if relative == "runtime-manifest.json":
            continue
        if path.is_symlink():
            if not path.resolve().is_relative_to(root):
                raise RuntimeError(f"external symlink: {relative}")
            entries.append({"path": relative, "link": os.readlink(path)})
        elif path.is_file():
            with path.open("rb") as stream:
                magic = stream.read(4)
                stream.seek(0)
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            entries.append({"path": relative, "bytes": path.stat().st_size, "sha256": digest})
            if magic in MACHO:
                native.append(relative)
                output = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], text=True)
                command = None
                for line in output.splitlines():
                    part = line.strip()
                    if part.startswith("cmd "):
                        command = part.split()[1]
                    # LC_ID_DYLIB is a library's identity, not a dependency. It
                    # may contain the build path without being loaded from it.
                    if command in {"LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB"} and part.startswith("name "):
                        dependency = part[5:].split(" (offset", 1)[0]
                        if dependency.startswith("/") and not dependency.startswith(("/System/Library/", "/usr/lib/")):
                            external.append({"file": relative, "dependency": dependency})
    if external:
        raise RuntimeError("non-portable native dependencies: " + json.dumps(external))
    manifest = {"schema": 1, "python": "3.11.15", "architecture": "arm64", "files": entries,
                "native_files": native, "external_native_dependencies": external,
                "python_source": "python-build-standalone 20260807 (CPython 3.11.15)",
                "license_notice": "CPython and dependency licenses remain in share/ and each *.dist-info directory."}
    (root / "runtime-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    env = {"PATH": "/usr/bin:/bin", "HOME": str(root.parent), "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"}
    probe = """
import sys,ssl,platform,importlib.metadata,pathlib
assert sys.version_info[:3] == (3,11,15) and platform.machine() == 'arm64'
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if '==' in line and not line.startswith('#'):
        name,expected=line.split('=='); assert importlib.metadata.version(name)==expected, name
import numpy,scipy,mlx.core,mlx_lm,mlx_audio,mlx_whisper,torch,tokenizers
print(sys.version); print(sys.prefix)
"""
    requirements = Path(__file__).resolve().parent.parent / "backend/requirements.txt"
    subprocess.run([str(root / "bin/python3"), "-I", "-B", "-c", probe, str(requirements)], env=env, check=True)
    print(json.dumps({"output": str(root), "files": len(entries), "native_files": len(native),
                      "bytes": sum(row.get("bytes", 0) for row in entries)}, indent=2))


if __name__ == "__main__":
    main()
