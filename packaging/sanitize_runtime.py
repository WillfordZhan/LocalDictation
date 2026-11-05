#!/usr/bin/env python3
"""Create a publishable runtime copy, without installer paths or credentials.

The source is never modified. Run before app signing: the output has a refreshed
runtime manifest and must be rebuilt/resigned if any bytes change afterwards.
"""
import argparse
import ast
import csv
import hashlib
import io
import json
import os
from pathlib import Path
import pprint
import shutil

from build_runtime import MACHO, copy_tree
from validate_runtime import validate

PREFIX_MARKER = "@LOCAL_DICTATION_RUNTIME@"
REBASE_COMMENT = "# Runtime prefixes are resolved after relocation; no builder home is retained."


def sanitize_sysconfig(path):
    """Rebase generated CPython installation paths, without executing metadata.

    CPython consumers still need valid include/library locations. Replacing a
    builder home with another absolute staging path would leak again and break
    relocation, so install-prefix values are resolved from this module at import.
    Unknown personal paths stop publication instead of being silently rewritten.
    """
    source = path.read_text(encoding="utf-8")
    module = ast.parse(source)
    assignments = [node for node in module.body if isinstance(node, ast.Assign)
                   and any(isinstance(target, ast.Name) and target.id == "build_time_vars"
                           for target in node.targets)]
    if len(assignments) != 1:
        raise ValueError("Unsupported sysconfig metadata: " + path.name)
    variables = ast.literal_eval(assignments[0].value)
    if not isinstance(variables, dict):
        raise ValueError("Invalid sysconfig dictionary: " + path.name)
    # Only the generated literal module, or our own already-sanitized format,
    # is accepted. Do not accidentally discard an upstream initialization hook.
    if REBASE_COMMENT not in source and module.body != assignments:
        raise ValueError("Unexpected executable sysconfig metadata: " + path.name)
    prefixes = {variables.get(key) for key in ("prefix", "exec_prefix")}
    prefixes.discard(None)
    if not prefixes or any(not isinstance(p, str) or p in ("", "/") for p in prefixes):
        raise ValueError("Invalid sysconfig install prefix: " + path.name)
    for key, value in variables.items():
        if isinstance(value, str):
            for prefix in sorted(prefixes, key=len, reverse=True):
                value = value.replace(prefix, PREFIX_MARKER)
            if "/Users/" in value or "/home/" in value:
                raise ValueError("Unclassified personal sysconfig path in key: " + key)
            variables[key] = value
    output = (
        "# Generated CPython configuration for the bundled runtime.\n"
        + REBASE_COMMENT + "\n"
        + "build_time_vars = " + pprint.pformat(variables, sort_dicts=True, width=100) + "\n\n"
        + "import os as _runtime_os\n"
        + "_runtime_prefix = _runtime_os.path.dirname(_runtime_os.path.dirname(\n"
        + "    _runtime_os.path.dirname(_runtime_os.path.abspath(__file__))))\n"
        + "for _key, _value in build_time_vars.items():\n"
        + "    if isinstance(_value, str):\n"
        + f"        build_time_vars[_key] = _value.replace({PREFIX_MARKER!r}, _runtime_prefix)\n"
        + "del _key, _value, _runtime_prefix, _runtime_os\n"
    )
    path.write_text(output, encoding="utf-8")


def remove_installer_origins(root):
    """Drop optional PEP 610 installer origin records, keeping all licenses.

    These describe the developer's installation source, not a runtime dependency;
    file URLs can expose local directories and authenticated URLs can carry keys.
    Published upstream license provenance is recorded separately and retained.
    """
    removed = []
    for path in sorted(root.glob("lib/python*/site-packages/*.dist-info/direct_url.json")):
        record = path.parent / "RECORD"
        if record.is_file():
            rows = list(csv.reader(io.StringIO(record.read_text(encoding="utf-8"))))
            expected = path.parent.name + "/direct_url.json"
            remaining = [row for row in rows if not row or row[0] != expected]
            buffer = io.StringIO(newline="")
            csv.writer(buffer, lineterminator="\n").writerows(remaining)
            record.write_text(buffer.getvalue(), encoding="utf-8")
        removed.append(str(path.relative_to(root)))
        path.unlink()
    return removed


def add_license_supplements(root, source):
    """Copy reviewed, pinned license texts; builds never fetch mutable URLs."""
    provenance = source / "SOURCES.json"
    if not provenance.is_file():
        raise ValueError("Missing pinned supplementary license provenance")
    data = json.loads(provenance.read_text(encoding="utf-8"))
    for entry in data["files"]:
        relative = Path(entry["path"])
        path = source / relative
        if relative.is_absolute() or ".." in relative.parts or path.is_symlink():
            raise ValueError("Invalid supplementary license path")
        if hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("Supplementary license hash mismatch: " + str(relative))
    target = root / "share/licenses/localdictation-supplements"
    target.mkdir(parents=True, exist_ok=True)
    for entry in data["files"]:
        relative = Path(entry["path"])
        (target / relative).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source / relative, target / relative)
    shutil.copyfile(provenance, target / "SOURCES.json")


def refresh_manifest(root):
    path = root / "runtime-manifest.json"
    manifest = json.loads(path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1:
        raise ValueError("Unsupported runtime manifest schema")
    entries, native = [], []
    for child in sorted(root.rglob("*")):
        relative = str(child.relative_to(root))
        if relative == "runtime-manifest.json":
            continue
        if child.is_symlink():
            if not child.resolve().is_relative_to(root):
                raise ValueError("External runtime symlink: " + relative)
            entries.append({"path": relative, "link": os.readlink(child)})
        elif child.is_file():
            with child.open("rb") as stream:
                magic = stream.read(4)
                stream.seek(0)
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            entries.append({"path": relative, "bytes": child.stat().st_size, "sha256": digest})
            if magic in MACHO:
                native.append(relative)
    manifest["files"] = entries
    manifest["native_files"] = native
    manifest["publication_sanitization"] = {
        "schema": 1, "installer_origins_removed": True, "runtime_prefixes_relocatable": True,
        "supplementary_licenses": "share/licenses/localdictation-supplements/SOURCES.json",
    }
    path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def sanitize(root, license_source):
    root = root.resolve(strict=True)
    removed = remove_installer_origins(root)
    configs = sorted(root.glob("lib/python*/_sysconfigdata*.py"))
    if not configs:
        raise ValueError("No generated CPython sysconfig found")
    for path in configs:
        sanitize_sysconfig(path)
    for path in list(root.rglob("__pycache__")):
        shutil.rmtree(path)
    add_license_supplements(root, license_source)
    refresh_manifest(root)
    validate(root)
    return {"removed_installer_records": removed,
            "rebased_sysconfig": [str(p.relative_to(root)) for p in configs]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    source, output = args.source.resolve(strict=True), args.output.resolve()
    if output.exists() or output.is_relative_to(source) or source.is_relative_to(output):
        parser.error("choose a new output directory outside the source runtime")
    validate(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    copy_tree(source, output)
    result = sanitize(output, Path(__file__).with_name("licenses"))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
