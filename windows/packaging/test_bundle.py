"""Portable inventory and license boundaries without executing Windows code."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from bundle import PTH, collect_python_licenses, extract
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


if __name__ == "__main__":
    unittest.main()
