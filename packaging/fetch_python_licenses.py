#!/usr/bin/env python3
"""Recover upstream notices omitted by the matching install_only Python archive.

This release-specific build helper writes only share/licenses/python-build-standalone.
It does not extract another interpreter, import inference packages, or touch Runtime.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import urllib.parse
import urllib.request

VERSION = "3.11.15"
BUILD = "20260807"
TARGET = "aarch64-apple-darwin"
ARCHIVE = f"cpython-{VERSION}+{BUILD}-{TARGET}-pgo+lto-full.tar.zst"
ARCHIVE_SHA256 = "0d48b2684798ae30ab055f035720212bcb67ba6eda7e37c1426214e35e099186"
ARCHIVE_BYTES = 41_218_300
REPOSITORY = "https://github.com/astral-sh/python-build-standalone"
API_URL = "https://api.github.com/repos/astral-sh/python-build-standalone/releases/tags/" + BUILD


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def request(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={
        "User-Agent": "LocalDictation-license-build", "Accept": "application/vnd.github+json"}), timeout=30)


def safe_relative(value):
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or any(part in (".", "..", "") for part in value.split("/")):
        raise ValueError("Unsafe archive-relative path: " + value)
    return path


def read_member(archive, name):
    safe_relative(name)
    # tar writes the requested member to stdout, never to the filesystem.
    # Require one ordinary member to reject duplicates, links and directories.
    listing = subprocess.check_output(["/usr/bin/tar", "-tvf", str(archive), name], text=True, timeout=30).splitlines()
    if len(listing) != 1 or not listing[0].startswith("-"):
        raise ValueError("Expected one ordinary archive member: " + name)
    data = subprocess.check_output(["/usr/bin/tar", "-xOf", str(archive), name], timeout=30)
    if not data or len(data) > 4 * 1024 * 1024:
        raise ValueError("Unexpected declaration/license text size: " + name)
    data.decode("utf-8")
    return data


def collect_references(value, references, context="PYTHON.json"):
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ("license_path", "license_paths"):
                paths = [child] if isinstance(child, str) else child
                if not isinstance(paths, list) or not all(isinstance(path, str) for path in paths):
                    raise ValueError("Invalid upstream license paths")
                links = value.get("links", [])
                system_only = bool(links) and all(link.get("system") or link.get("framework") for link in links)
                for path in paths:
                    safe_relative(path)
                    references.setdefault(path, []).append({"context": context, "system_only": system_only, "links": links})
            else:
                collect_references(child, references, context + "/" + key)
    elif isinstance(value, list):
        for index, child in enumerate(value):
            collect_references(child, references, context + f"/{index}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-home", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, required=True)
    args = parser.parse_args()
    python_home = args.python_home.resolve(strict=True)
    if (python_home / "BUILD").read_text().strip() != BUILD:
        raise ValueError("Installed standalone BUILD does not match the pinned release")
    info = json.loads(subprocess.check_output([str(python_home / "bin/python3"), "-I", "-S", "-B", "-c",
        "import json,platform;print(json.dumps({'version':platform.python_version(),'machine':platform.machine()}))"], text=True, timeout=10))
    if info != {"version": VERSION, "machine": "arm64"}:
        raise ValueError("Installed Python version/architecture does not match")
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    with request(API_URL) as response:
        release = json.load(response)
    assets = [asset for asset in release["assets"] if asset["name"] == ARCHIVE]
    if release["tag_name"] != BUILD or len(assets) != 1:
        raise ValueError("Official release does not contain the expected archive")
    asset = assets[0]
    if asset.get("digest") != "sha256:" + ARCHIVE_SHA256 or asset["size"] != ARCHIVE_BYTES:
        raise ValueError("Official archive digest/size disagrees with the pinned release")
    url = asset["browser_download_url"]
    if not url.startswith(REPOSITORY + "/releases/download/" + BUILD + "/"):
        raise ValueError("Unexpected archive download origin")
    archive = args.cache_dir / ARCHIVE
    if not archive.is_file() or archive.stat().st_size != ARCHIVE_BYTES or sha256(archive) != ARCHIVE_SHA256:
        temporary = archive.with_suffix(archive.suffix + ".download")
        with request(url) as response, temporary.open("wb") as stream:
            while block := response.read(1024 * 1024):
                stream.write(block)
        if temporary.stat().st_size != ARCHIVE_BYTES or sha256(temporary) != ARCHIVE_SHA256:
            raise ValueError("Downloaded full archive failed size/SHA-256 verification")
        temporary.replace(archive)
    metadata_bytes = read_member(archive, "python/PYTHON.json")
    metadata = json.loads(metadata_bytes)
    if (metadata["python_version"], metadata["target_triple"], metadata["build_options"]) != (VERSION, TARGET, "pgo+lto"):
        raise ValueError("Full archive Python metadata disagrees with installed runtime")
    listing = subprocess.check_output(["/usr/bin/tar", "-tf", str(archive)], text=True, timeout=30).splitlines()
    names = set(listing)
    references = {}
    collect_references(metadata, references)
    missing = {path: owners for path, owners in references.items() if "python/" + path not in names}
    # Some upstream generic metadata names notices for a platform system library
    # without shipping that library or notice. Record that fact, never fabricate
    # license text. Missing notices for shipped/static libraries fail the build.
    if any(not all(owner["system_only"] for owner in owners) for owners in missing.values()):
        raise ValueError("Full archive lacks a referenced bundled-library license: " + json.dumps(missing))
    license_names = sorted(name for name in names if re.fullmatch(r"python/licenses/LICENSE\.[A-Za-z0-9_.+-]+\.txt", name))
    contents = {name.removeprefix("python/"): read_member(archive, name) for name in license_names}
    if not contents:
        raise ValueError("Full archive has no license text")
    destination = python_home / "share/licenses/python-build-standalone"
    component = python_home
    for part in destination.relative_to(python_home).parts:
        component /= part
        if component.is_symlink():
            raise ValueError("License destination must not contain symlinks")
    destination.mkdir(parents=True, exist_ok=True)
    payload = {"PYTHON.json": metadata_bytes, **contents}
    for relative, data in payload.items():
        target = destination / safe_relative(relative)
        if target.is_symlink() or target.parent.is_symlink():
            raise ValueError("License target must not contain symlinks")
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and target.read_bytes() != data:
            raise ValueError("Refusing to overwrite a different existing notice: " + relative)
        if not target.exists(): target.write_bytes(data)
    source = {"schema": 1, "retrieved_at": datetime.now(timezone.utc).isoformat(),
              "release_url": release["html_url"], "api_url": API_URL, "archive_url": url,
              "archive": ARCHIVE, "archive_bytes": ARCHIVE_BYTES, "archive_sha256": ARCHIVE_SHA256,
              "python_version": VERSION, "build": BUILD, "target_triple": TARGET, "build_options": "pgo+lto",
              "extraction": "Only PYTHON.json and ordinary license text members; no interpreter/build files extracted",
              "upstream_missing_system_only_notices": missing,
              "files": [{"path": path, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                        for path, data in sorted(payload.items())]}
    source_path = destination / "SOURCE.json"
    if not source_path.exists(): source_path.write_text(json.dumps(source, ensure_ascii=False, indent=2) + "\n")
    notice = ("# Standalone CPython third-party notices\n\n"
        f"Source: {release['html_url']}\n\nPython {VERSION}; build {BUILD}; {TARGET}; pgo+lto.\n\n"
        "PYTHON.json preserves the upstream component/link/license declarations. All license text files from the verified full archive are retained under licenses/. "
        "Some upstream notices may describe components not linked on this platform; the declaration specifies the actual links.\n\n"
        "Upstream metadata references LICENSE.zlib-ng.txt, absent from this full archive. Its only owner is the zlib extension linked to macOS system z (system:true); "
        "no zlib-ng binary is included by this runtime. SOURCE.json records the unmodified upstream inconsistency. "
        "No substitute license text is invented.\n")
    (destination / "README.md").write_text(notice)
    result = {"destination": str(destination), "license_files": len(contents), "referenced_notices": len(references),
              "missing_system_only_notices": list(missing), "archive_sha256": ARCHIVE_SHA256,
              "metadata_version": metadata["python_version"], "metadata_target": metadata["target_triple"]}
    (args.cache_dir / "extraction-result.json").write_text(json.dumps(result, indent=2) + "\n")
    (args.cache_dir / "release-source.json").write_text(json.dumps({"tag_name": release["tag_name"], "html_url": release["html_url"],
        "asset": {key: asset[key] for key in ("name", "size", "digest", "browser_download_url")}}, indent=2) + "\n")
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
