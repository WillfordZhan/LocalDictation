"""Build-time helpers for a portable Windows bundle; never touch user storage."""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

BACKEND_FILES = ("server.py", "streaming.py", "prompt_store.py", "prompt-imports.json",
                 "windows_models.py", "windows_server.py", "windows_setup.py",
                 "windows-model-manifest.json", "requirements-windows.txt")
PTH = ".\nDLLs\nLib\nLib/site-packages\n../../backend\nimport site\n"


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def extract(archive, destination):
    with zipfile.ZipFile(archive) as source:
        for name in source.namelist():
            path = Path(name.replace("\\", "/"))
            if path.is_absolute() or ".." in path.parts or ":" in name:
                raise ValueError("Unsafe archive entry")
        source.extractall(destination)


def remove_caches(root):
    for path in list(root.rglob("__pycache__")):
        if path.is_dir():
            shutil.rmtree(path)
    for pattern in ("*.pyc", "*.pyo", "direct_url.json"):
        for path in root.rglob(pattern):
            path.unlink()


def prepare(args):
    inputs = json.loads((args.repo / "windows/packaging/inputs.json").read_text())
    for item in [inputs["python"], inputs["llama"], inputs["vc_redist"], *inputs["licenses"]]:
        if sha(args.cache / item["filename"]) != item["sha256"]:
            raise ValueError("Pinned input hash mismatch: " + item["filename"])
    python_unpacked = args.work / "python-unpacked"
    extract(args.cache / inputs["python"]["filename"], python_unpacked)
    runtime = args.root / "runtime/python"
    shutil.copytree(python_unpacked / "tools", runtime)
    # pip/setuptools in the NuGet tools package serve only the build interpreter.
    # Install the application dependencies afresh into an empty target directory.
    shutil.rmtree(runtime / "Lib/site-packages")
    (runtime / "Lib/site-packages").mkdir()
    for relative in ("Scripts", "include", "libs", "Lib/ensurepip", "Lib/test",
                     "Lib/idlelib/idle_test", "Lib/tkinter/test", "Lib/unittest/test",
                     "Lib/ctypes/test"):
        path = runtime / relative
        if path.exists():
            shutil.rmtree(path)
    (runtime / "python311._pth").write_text(PTH, encoding="ascii")
    (runtime / "Lib/sitecustomize.py").write_text(
        "# A portable installation never writes cache files beside its binaries.\n"
        "import sys\nsys.dont_write_bytecode = True\n", encoding="utf-8")

    llama_unpacked = args.work / "llama-unpacked"
    extract(args.cache / inputs["llama"]["filename"], llama_unpacked)
    servers = list(llama_unpacked.rglob("llama-server.exe"))
    if len(servers) != 1:
        raise ValueError("Expected exactly one llama-server.exe")
    shutil.copytree(servers[0].parent, args.root / "runtime/llama")
    shutil.copy2(args.cache / inputs["vc_redist"]["filename"], args.root / "runtime/vc_redist.x64.exe")
    backend = args.root / "backend"
    backend.mkdir()
    for name in BACKEND_FILES:
        shutil.copy2(args.repo / "backend" / name, backend / name)
    shutil.copy2(args.repo / "LICENSE", args.root / "LICENSE")
    license_root = args.root / "licenses"
    license_root.mkdir()
    shutil.copy2(runtime / "LICENSE.txt", license_root / "CPython-LICENSE.txt")
    for item in inputs["licenses"]:
        shutil.copy2(args.cache / item["filename"], license_root / item["filename"])
    shutil.copy2(args.repo / "windows/packaging/inputs.json", args.root / "runtime-inputs.json")
    print("Prepared Python, llama.cpp and backend without models or user data")


def license_filename(path):
    name = path.name.lower()
    return name.startswith(("license", "licence", "copying", "notice", "third-party", "third_party"))


def collect_python_licenses(root):
    site = root / "runtime/python/Lib/site-packages"
    # Some wheels omit their upstream license. Supplements are tied to the
    # exact distribution version and verified against pinned upstream hashes;
    # a version upgrade must supply its own notice instead of silently reusing it.
    inputs_path = root / "runtime-inputs.json"
    supplements = json.loads(inputs_path.read_text()).get("licenses", []) if inputs_path.exists() else []
    result = []
    for distribution in sorted(importlib.metadata.distributions(path=[str(site)]),
                               key=lambda item: item.metadata["Name"].lower()):
        name = distribution.metadata["Name"]
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", name + "-" + distribution.version)
        destination = root / "licenses/python" / safe
        candidates = []
        for entry in distribution.files or ():
            source = Path(distribution.locate_file(entry)).resolve()
            if source.is_relative_to(site.resolve()) and source.is_file() and (
                license_filename(source) or any(part.lower() == "licenses" for part in source.parts)
            ):
                candidates.append(source)
        copied = []
        for index, source in enumerate(sorted(set(candidates))):
            destination.mkdir(parents=True, exist_ok=True)
            target = destination / (str(index) + "-" + source.name)
            shutil.copy2(source, target)
            copied.append(target.relative_to(root).as_posix())
        metadata_license = distribution.metadata.get("License", "")
        if not copied and len(metadata_license.splitlines()) >= 4:
            destination.mkdir(parents=True, exist_ok=True)
            target = destination / "LICENSE-from-package-metadata.txt"
            target.write_text(metadata_license + "\n", encoding="utf-8")
            copied.append(target.relative_to(root).as_posix())
        if not copied:
            for item in supplements:
                if item.get("package", "").lower().replace("_", "-") != name.lower().replace("_", "-") or item.get("version") != distribution.version:
                    continue
                source = root / "licenses" / item["filename"]
                if not source.is_file() or sha(source) != item["sha256"]:
                    raise ValueError("Pinned license supplement changed: " + name)
                copied.append(source.relative_to(root).as_posix())
        if not copied:
            raise ValueError("Missing full license text in wheel: " + name + " " + distribution.version)
        result.append({"name": name, "version": distribution.version,
                       "license_expression": distribution.metadata.get("License-Expression", ""),
                       "licenses": copied})
    if not result:
        raise ValueError("No Python dependencies installed")
    return result


def collect_nuget_licenses(repo, root):
    assets_path = repo / "windows/app/obj/project.assets.json"
    assets = json.loads(assets_path.read_text(encoding="utf-8"))
    folders = [Path(value) for value in assets["packageFolders"]]
    # Runtime packs may be restore downloads rather than package libraries.
    packages = {name.lower(): value.get("path", name.lower()) for name, value in assets["libraries"].items()
                if value.get("type") == "package"}
    for folder in folders:
        for identifier in ("microsoft.netcore.app.runtime.win-x64", "microsoft.windowsdesktop.app.runtime.win-x64"):
            parent = folder / identifier
            if parent.is_dir():
                for version in parent.iterdir():
                    if version.is_dir():
                        packages[identifier + "/" + version.name] = identifier + "/" + version.name
    result = []
    for package, relative in sorted(packages.items()):
        directory = next((folder / relative for folder in folders if (folder / relative).is_dir()), None)
        if directory is None:
            raise ValueError("Restored NuGet package missing: " + package)
        copied = []
        for source in directory.iterdir():
            if source.is_file() and license_filename(source):
                destination = root / "licenses/nuget" / package.replace("/", "-") / source.name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, destination)
                copied.append(destination.relative_to(root).as_posix())
        # NAudio packages share the pinned upstream MIT license distributed above.
        if not copied and package.startswith("naudio"):
            copied.append("licenses/NAudio-LICENSE")
        if not copied:
            raise ValueError("Missing NuGet license notices: " + package)
        result.append({"package": package, "licenses": copied})
    return result


def finish(args):
    remove_caches(args.root)
    site = args.root / "runtime/python/Lib/site-packages"
    # pip creates console wrappers using the build interpreter's absolute path.
    # The application uses modules directly, never any of these entry points.
    for name in ("Scripts", "bin"):
        path = site / name
        if path.is_dir():
            shutil.rmtree(path)
    python_licenses = collect_python_licenses(args.root)
    nuget_licenses = collect_nuget_licenses(args.repo, args.root)
    write_json(args.root / "THIRD_PARTY_COMPONENTS.json", {"python": python_licenses, "nuget": nuget_licenses})
    (args.root / "THIRD_PARTY_NOTICES.md").write_text(
        "# Third-party components\n\n"
        "LocalDictation is MIT licensed; see LICENSE. The bundle preserves the upstream notices "
        "for CPython, llama.cpp, NAudio, .NET and every installed Python wheel under licenses/.\n\n"
        "THIRD_PARTY_COMPONENTS.json records the versions and license files. runtime-inputs.json "
        "records pinned download URLs and SHA-256 values. The Microsoft Visual C++ Redistributable "
        "is included unchanged with its Microsoft signature and installer license terms; it runs only "
        "when the user explicitly chooses to install the required Windows runtime. Model weights are not in this bundle; "
        "their sources and licenses are listed in backend/windows-model-manifest.json.\n", encoding="utf-8")
    source_files = [args.repo / "backend" / name for name in BACKEND_FILES]
    source_files += [p for p in (args.repo / "windows/app").iterdir() if p.suffix in (".cs", ".xaml", ".csproj", ".manifest")]
    try:
        commit = subprocess.check_output(["git", "-C", str(args.repo), "rev-parse", "HEAD"], text=True).strip()
        dirty = bool(subprocess.check_output(["git", "-C", str(args.repo), "status", "--porcelain"], text=True))
    except (OSError, subprocess.CalledProcessError):
        commit, dirty = None, None
    write_json(args.root / "build-inputs.json", {
        "version": args.version, "architecture": "win-x64", "source_commit": commit, "source_tree_dirty": dirty,
        "source_files": [{"path": p.relative_to(args.repo).as_posix(), "sha256": sha(p)} for p in sorted(source_files)],
        "wheels": [{"filename": p.name, "sha256": sha(p)} for p in sorted((args.work / "wheels").glob("*.whl"))]})
    files = [{"path": p.relative_to(args.root).as_posix(), "bytes": p.stat().st_size, "sha256": sha(p)}
             for p in sorted(args.root.rglob("*")) if p.is_file() and p.name != "bundle-manifest.json"]
    write_json(args.root / "bundle-manifest.json", {"schema": 1, "version": args.version, "files": files})
    print("Collected licenses and hashed", len(files), "bundle files")


def archive(args):
    from validate_bundle import validate
    validate(args.root)
    output = args.root.parent / ("LocalDictation-" + args.version + "-Windows-x64.zip")
    if output.exists():
        raise FileExistsError("Archive already exists; choose a new output directory")
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as target:
        for path in sorted(args.root.rglob("*")):
            if path.is_file():
                target.write(path, "LocalDictation/" + path.relative_to(args.root).as_posix())
    with zipfile.ZipFile(output) as target:
        if target.testzip() is not None:
            raise ValueError("Final ZIP CRC failed")
    output.with_suffix(".zip.sha256").write_text(sha(output) + "  " + output.name + "\n", encoding="ascii")
    print("Packaged", output.name, output.stat().st_size, sha(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("prepare", "finish", "archive"))
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--repo", type=Path)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--version", default="0.6.0-preview.1")
    args = parser.parse_args()
    args.root = args.root.resolve()
    globals()[args.command](args)


if __name__ == "__main__":
    main()
