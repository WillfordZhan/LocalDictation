import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import unittest

from validate_runtime import validate


class RuntimeManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.write("bin/python3.11", b"synthetic interpreter")
        self.write("lib/python3.11/site.py", b"# source-only fixture\n")
        self.write("share/licenses/python-build-standalone/SOURCE.json", b"{}\n")
        self.write("share/licenses/dependency/LICENSE", b"Upstream license preserved.\n")
        (self.root / "bin/python3").symlink_to("python3.11")
        (self.root / "lib/current").symlink_to("python3.11", target_is_directory=True)
        self.refresh()

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def refresh(self):
        entries = []
        for directory, directories, files in os.walk(self.root, followlinks=False):
            for name in directories + files:
                path = Path(directory) / name
                relative = path.relative_to(self.root).as_posix()
                if relative == "runtime-manifest.json":
                    continue
                if path.is_symlink():
                    entries.append({"path": relative, "link": os.readlink(path)})
                elif path.is_file():
                    data = path.read_bytes()
                    entries.append({"path": relative, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
        (self.root / "runtime-manifest.json").write_text(json.dumps({"schema": 1, "files": entries}))

    def check(self):
        with contextlib.redirect_stdout(io.StringIO()):
            validate(self.root)

    def test_complete_source_runtime_preserves_internal_links_and_licenses(self):
        self.check()
        self.assertEqual(os.readlink(self.root / "bin/python3"), "python3.11")
        self.assertEqual(os.readlink(self.root / "lib/current"), "python3.11")
        self.assertEqual((self.root / "share/licenses/dependency/LICENSE").read_bytes(), b"Upstream license preserved.\n")

    def test_cache_directory_is_rejected_even_empty_or_manifest_listed(self):
        cache = self.root / "lib/python3.11/__pycache__"
        cache.mkdir()
        with self.assertRaisesRegex(ValueError, "Forbidden runtime bytecode/cache"):
            self.check()
        path = self.write("lib/python3.11/__pycache__/site.cpython-311.pyc", b"embedded builder path")
        for listed in (False, True):
            with self.subTest(listed=listed):
                if listed:
                    self.refresh()
                with self.assertRaisesRegex(ValueError, "Forbidden runtime bytecode/cache"):
                    self.check()
        self.assertTrue(path.exists(), "Validation must not silently remove the rejected file")

    def test_standalone_bytecode_rejected_with_or_without_manifest_entry(self):
        for filename in ("site.pyc", "optimized.pyo", "UPPER.PYC"):
            for listed in (False, True):
                with self.subTest(filename=filename, listed=listed):
                    path = self.write("lib/python3.11/" + filename, b"compiled fixture")
                    if listed:
                        self.refresh()
                    with self.assertRaisesRegex(ValueError, "Forbidden runtime bytecode/cache"):
                        self.check()
                    path.unlink()
                    self.refresh()

    def test_unlisted_regular_file_or_symlink_stops_publication(self):
        extra = self.write("share/private-build-note.txt", b"not in reviewed manifest")
        with self.assertRaisesRegex(ValueError, "Unlisted runtime file"):
            self.check()
        extra.unlink()
        link = self.root / "bin/unlisted-python"
        link.symlink_to("python3.11")
        with self.assertRaisesRegex(ValueError, "Unlisted runtime file"):
            self.check()

    def test_missing_changed_file_and_external_link_remain_rejected(self):
        source = self.root / "lib/python3.11/site.py"
        original = source.read_bytes()
        source.unlink()
        with self.assertRaisesRegex(ValueError, "Runtime file missing"):
            self.check()
        source.write_bytes(b"x" * len(original))
        with self.assertRaisesRegex(ValueError, "Runtime hash mismatch"):
            self.check()
        source.write_bytes(original)
        link = self.root / "bin/python3"
        link.unlink()
        link.symlink_to("/usr/bin/python3")
        self.refresh()
        with self.assertRaisesRegex(ValueError, "External runtime path"):
            self.check()

    def test_duplicate_or_escaping_manifest_paths_cannot_cover_extra_files(self):
        manifest_path = self.root / "runtime-manifest.json"
        original = json.loads(manifest_path.read_text())
        for extra in (original["files"][0], {"path": "../outside", "link": "x"},
                      {"path": "/absolute", "link": "x"}, {"path": "runtime-manifest.json", "link": "x"}):
            with self.subTest(path=extra["path"]):
                manifest_path.write_text(json.dumps({"schema": 1, "files": original["files"] + [extra]}))
                with self.assertRaisesRegex(ValueError, "Duplicate runtime manifest path|Invalid runtime manifest path"):
                    self.check()


if __name__ == "__main__":
    unittest.main()
