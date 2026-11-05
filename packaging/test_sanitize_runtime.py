import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import sanitize_runtime
from validate_runtime import validate


class RuntimePublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.root = self.base / "runtime"
        self.config = self.root / "lib/python3.11/_sysconfigdata_test.py"
        self.config.parent.mkdir(parents=True)
        self.builder = "/" + "/".join(("Users", "example-builder", "private-build", "python"))
        self.config.write_text("build_time_vars = " + repr({
            "prefix": self.builder, "exec_prefix": self.builder,
            "LIBDIR": self.builder + "/lib", "INCLUDEPY": self.builder + "/include/python3.11",
            "DESTDIRS": self.builder + "/lib " + self.builder + "/bin",
            "MACOSX_DEPLOYMENT_TARGET": "13.0", "SIZEOF_VOID_P": 8,
        }) + "\n")
        self.dist = self.root / "lib/python3.11/site-packages/example-1.0.dist-info"
        self.dist.mkdir(parents=True)
        (self.dist / "direct_url.json").write_text(json.dumps({"url": "file://" + self.builder}))
        (self.dist / "LICENSE").write_text("Upstream license must remain byte-for-byte.\n")
        (self.dist / "RECORD").write_text(
            "example-1.0.dist-info/direct_url.json,,\nexample-1.0.dist-info/LICENSE,,\n")
        provenance = self.root / "share/licenses/python-build-standalone/SOURCE.json"
        provenance.parent.mkdir(parents=True)
        provenance.write_text("{}\n")
        (self.root / "runtime-manifest.json").write_text(json.dumps({"schema": 1, "files": []}))
        self.licenses = self.base / "licenses"
        self.licenses.mkdir()
        data = b"Pinned additional upstream license.\n"
        (self.licenses / "LICENSE").write_bytes(data)
        (self.licenses / "SOURCES.json").write_text(json.dumps({"schema": 1, "files": [
            {"path": "LICENSE", "sha256": hashlib.sha256(data).hexdigest()}
        ]}))
        sanitize_runtime.refresh_manifest(self.root)

    def run_sanitizer(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return sanitize_runtime.sanitize(self.root, self.licenses)

    def config_values(self, path):
        # Execute only our generated fixture, never third-party sysconfig input.
        spec = importlib.util.spec_from_file_location("publication_config_fixture", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.build_time_vars

    def test_installer_origin_removed_without_touching_license(self):
        before = (self.dist / "LICENSE").read_bytes()
        result = self.run_sanitizer()
        self.assertEqual(len(result["removed_installer_records"]), 1)
        self.assertFalse((self.dist / "direct_url.json").exists())
        self.assertNotIn("direct_url", (self.dist / "RECORD").read_text())
        self.assertEqual((self.dist / "LICENSE").read_bytes(), before)
        self.assertIn("LICENSE", (self.dist / "RECORD").read_text())

    def test_sysconfig_survives_relocation_and_removes_builder_path(self):
        self.run_sanitizer()
        self.assertNotIn(self.builder, self.config.read_text())
        relocated = self.base / "relocated-runtime"
        shutil.copytree(self.root, relocated)
        values = self.config_values(relocated / self.config.relative_to(self.root))
        self.assertEqual(values["prefix"], str(relocated))
        self.assertEqual(values["LIBDIR"], str(relocated / "lib"))
        self.assertEqual(values["INCLUDEPY"], str(relocated / "include/python3.11"))
        self.assertEqual(values["DESTDIRS"], str(relocated / "lib") + " " + str(relocated / "bin"))
        self.assertEqual(values["SIZEOF_VOID_P"], 8)
        self.assertEqual(values["MACOSX_DEPLOYMENT_TARGET"], "13.0")

    def test_unknown_personal_path_is_not_silently_rewritten(self):
        source = self.config.read_text().replace("'13.0'", repr("/" + "/".join(("Users", "other", "sdk"))))
        self.config.write_text(source)
        with self.assertRaisesRegex(ValueError, "Unclassified personal"):
            sanitize_runtime.sanitize_sysconfig(self.config)
        self.assertEqual(self.config.read_text(), source)

    def test_unexpected_executable_metadata_is_not_run(self):
        self.config.write_text(self.config.read_text() + "raise RuntimeError('must not run')\n")
        with self.assertRaisesRegex(ValueError, "Unexpected executable"):
            sanitize_runtime.sanitize_sysconfig(self.config)

    def test_generated_sysconfig_is_idempotent(self):
        sanitize_runtime.sanitize_sysconfig(self.config)
        before = self.config.read_bytes()
        sanitize_runtime.sanitize_sysconfig(self.config)
        self.assertEqual(self.config.read_bytes(), before)

    def test_license_hash_mismatch_stops_publication(self):
        (self.licenses / "LICENSE").write_text("mutated")
        with self.assertRaisesRegex(ValueError, "license hash mismatch"):
            self.run_sanitizer()

    def test_manifest_covers_added_licenses_and_new_hashes(self):
        self.run_sanitizer()
        with contextlib.redirect_stdout(io.StringIO()):
            validate(self.root)
        entries = json.loads((self.root / "runtime-manifest.json").read_text())["files"]
        paths = {row["path"] for row in entries}
        self.assertIn("share/licenses/localdictation-supplements/LICENSE", paths)
        self.assertFalse(any(path.endswith("direct_url.json") for path in paths))
        self.assertIn(str(self.config.relative_to(self.root)), paths)

    def test_cli_copies_source_and_refuses_overwrite(self):
        before = {str(p.relative_to(self.root)): p.read_bytes()
                  for p in self.root.rglob("*") if p.is_file()}
        output = self.base / "public"
        command = [sys.executable, str(Path(sanitize_runtime.__file__).resolve()),
                   "--source", str(self.root), "--output", str(output)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((output / self.dist.relative_to(self.root) / "direct_url.json").exists())
        self.assertEqual(before, {str(p.relative_to(self.root)): p.read_bytes()
                                  for p in self.root.rglob("*") if p.is_file()})
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("new output directory", result.stderr)


if __name__ == "__main__":
    unittest.main()
