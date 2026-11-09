"""Portable inventory and license boundaries without executing Windows code."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from bundle import PTH, collect_python_licenses, extract, upstream_build_metadata
from validate_bundle import validate


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "bundle"
        self.root.mkdir()
        for relative in ("LocalDictation.exe", "coreclr.dll", "runtime/python/python.exe", "runtime/python/python311.dll",
                         "runtime/python/python311._pth", "runtime/llama/llama-server.exe", "backend/windows_server.py",
                         "backend/windows-model-manifest.json", "LICENSE", "THIRD_PARTY_COMPONENTS.json",
                         "licenses/CPython-LICENSE.txt", "licenses/NAudio-LICENSE", "licenses/llama-LICENSE",
                         "runtime/vc_redist.x64.exe"):
            path = self.root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(PTH if path.suffix == "._pth" else "fixture", encoding="utf-8")
        self.snapshot()

    def snapshot(self):
        entries = [{"path": p.relative_to(self.root).as_posix(), "bytes": p.stat().st_size,
                    "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                   for p in self.root.rglob("*") if p.is_file() and p.name != "bundle-manifest.json"]
        (self.root / "bundle-manifest.json").write_text(json.dumps({"schema": 1, "files": entries}))

    def test_complete_inventory_and_isolated_search_paths(self):
        self.assertEqual(len(validate(self.root)["files"]), 14)
        (self.root / "runtime/python/python311._pth").write_text(PTH.replace("DLLs\n", ""))
        self.snapshot()
        with self.assertRaisesRegex(ValueError, "search paths"):
            validate(self.root)

    def test_modified_files_and_unlisted_files_are_rejected(self):
        (self.root / "LocalDictation.exe").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "content changed"):
            validate(self.root)
        self.snapshot()
        (self.root / "unexpected.txt").write_text("extra")
        with self.assertRaisesRegex(ValueError, "inventory changed"):
            validate(self.root)

    def test_private_data_models_and_bytecode_cannot_be_declared_safe(self):
        for name in ("windows-history.json", "windows-history.json.backup", "cleanup-prompts.backup.json",
                     "private.key", "cache.pyc", "model.bin", "model.gguf"):
            with self.subTest(name=name):
                path = self.root / name
                path.write_text("fixture")
                self.snapshot()
                with self.assertRaises(ValueError):
                    validate(self.root)
                path.unlink()
        self.snapshot()

    def test_builder_home_is_not_allowed_in_text(self):
        (self.root / "builder.txt").write_text(str(Path.home()))
        self.snapshot()
        with self.assertRaisesRegex(ValueError, "Builder home"):
            validate(self.root)

    def test_unsafe_archive_paths_do_not_escape_target(self):
        archive = self.root.parent / "bad.zip"
        for name in ("../outside", "/absolute", "C:/absolute"):
            with self.subTest(name=name):
                with zipfile.ZipFile(archive, "w") as target:
                    target.writestr(name, "unsafe")
                with self.assertRaisesRegex(ValueError, "Unsafe"):
                    extract(archive, self.root / "unpacked")

    def test_python_license_is_copied_and_missing_text_fails(self):
        metadata = self.root / "runtime/python/Lib/site-packages/fixture-1.0.dist-info"
        (metadata / "licenses").mkdir(parents=True)
        (metadata / "METADATA").write_text("Metadata-Version: 2.1\nName: fixture\nVersion: 1.0\nLicense: MIT\n")
        (metadata / "RECORD").write_text("fixture-1.0.dist-info/licenses/LICENSE,,\n")
        license = metadata / "licenses/LICENSE"
        license.write_text("Full upstream license text and attribution.")
        result = collect_python_licenses(self.root)
        copied = self.root / result[0]["licenses"][0]
        self.assertEqual(copied.read_bytes(), license.read_bytes())
        license.unlink()
        with self.assertRaisesRegex(ValueError, "Missing full license"):
            collect_python_licenses(self.root)


    def test_upstream_license_supplement_is_version_and_hash_bound(self):
        metadata = self.root / "runtime/python/Lib/site-packages/fixture-1.0.dist-info"
        metadata.mkdir(parents=True)
        (metadata / "METADATA").write_text("Metadata-Version: 2.1\nName: fixture\nVersion: 1.0\nLicense: MIT\n")
        license = self.root / "licenses/fixture-LICENSE"
        license.write_text("Pinned upstream license text.")
        item = {"package": "fixture", "version": "1.0", "filename": license.name,
                "sha256": hashlib.sha256(license.read_bytes()).hexdigest()}
        inputs = self.root / "runtime-inputs.json"
        inputs.write_text(json.dumps({"licenses": [item]}))
        self.assertEqual(collect_python_licenses(self.root)[0]["licenses"], ["licenses/fixture-LICENSE"])
        license.write_text("modified")
        with self.assertRaisesRegex(ValueError, "supplement changed"):
            collect_python_licenses(self.root)
        item["version"] = "0.9"
        inputs.write_text(json.dumps({"licenses": [item]}))
        with self.assertRaisesRegex(ValueError, "Missing full license"):
            collect_python_licenses(self.root)


    def test_public_wheel_build_metadata_requires_exact_bytes_and_provenance(self):
        path = self.root / "runtime/python/Lib/site-packages/fixture/config.py"
        path.parent.mkdir(parents=True)
        path.write_text("# Upstream compiler metadata: " + str(Path.home()))
        wheels = self.root.parent / "wheels"
        wheels.mkdir()
        wheel = wheels / "fixture-1.0-py3-none-any.whl"
        with zipfile.ZipFile(wheel, "w") as archive:
            archive.writestr("fixture/config.py", path.read_bytes())
        origins = upstream_build_metadata(self.root, wheels)
        inputs = {"wheels": [{"filename": wheel.name, "sha256": hashlib.sha256(wheel.read_bytes()).hexdigest()}],
                  "upstream_build_metadata": origins}
        (self.root / "build-inputs.json").write_text(json.dumps(inputs))
        self.snapshot()
        validate(self.root)
        inputs["wheels"] = []
        (self.root / "build-inputs.json").write_text(json.dumps(inputs))
        self.snapshot()
        with self.assertRaisesRegex(ValueError, "Builder home"):
            validate(self.root)
        path.write_text(path.read_text() + " added by local build")
        with self.assertRaisesRegex(ValueError, "Non-upstream builder path"):
            upstream_build_metadata(self.root, wheels)


if __name__ == "__main__":
    unittest.main()
