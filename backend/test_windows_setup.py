"""Windows model setup contract, including interrupted acquisition and receipts."""
import ctypes
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import windows_setup as setup


def item(name, body):
    return {"path": name, "size": len(body), "sha256": hashlib.sha256(body).hexdigest()}


class Response(io.BytesIO):
    def __init__(self, body, status=200, headers=None):
        super().__init__(body)
        self.status, self.headers = status, headers or {}


class WindowsSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.model = {"id": "asr", "name": "Fixture ASR", "directory": "asr-v1",
                      "repo_id": "fixture/asr", "revision": "a" * 40,
                      "files": [item("weights.bin", b"data"), item("LICENSE", b"MIT")]}
        self.other = {"id": "cleanup", "name": "Fixture cleanup", "directory": "cleanup-v1",
                      "repo_id": "fixture/cleanup", "revision": "b" * 40,
                      "files": [item("weights.bin", b"data")]}
        self.manifest = [self.model, self.other]

    def fetch(self, url, path, expected, progress):
        body = b"MIT" if path.name == "LICENSE" else b"data"
        path.write_bytes(body)
        progress(len(body))

    def test_readonly_missing_report_does_not_create_storage(self):
        target = self.root / "not-created"
        report = setup.inspect_models(target, self.manifest)
        self.assertFalse(report["ready"])
        self.assertEqual(report["required_bytes"], 11)
        self.assertFalse(target.exists())

    def test_verified_files_and_receipt_make_report_ready_then_detect_change(self):
        events = []
        result = setup.download_models(self.root, events.append, manifest=self.manifest, fetch=self.fetch)
        self.assertTrue(result["ready"])
        self.assertEqual(events[-1]["type"], "report")
        self.assertEqual(events[-1]["progress"], 1)
        file = setup.model_directory(self.root, self.model) / "weights.bin"
        file.write_bytes(b"oops")
        self.assertFalse(setup.inspect_models(self.root, self.manifest)["ready"])
        self.assertTrue(setup.download_models(self.root, lambda _: None, manifest=self.manifest,
                                             fetch=self.fetch)["ready"])

    def test_repeated_setup_verifies_and_reuses_without_network(self):
        setup.download_models(self.root, lambda _: None, manifest=self.manifest, fetch=self.fetch)
        with patch.object(setup, "download_file", side_effect=AssertionError("network not needed")):
            result = setup.download_models(self.root, lambda _: None, manifest=self.manifest,
                                            fetch=lambda *args: self.fail("network not needed"))
        self.assertTrue(result["ready"])

    def test_incomplete_or_corrupt_download_never_marks_model_ready(self):
        def corrupt(url, path, expected, progress):
            path.write_bytes(b"oops")
        with self.assertRaises(ValueError):
            setup.download_models(self.root, lambda _: None, manifest=self.manifest, fetch=corrupt)
        self.assertFalse(setup.inspect_models(self.root, self.manifest)["ready"])
        self.assertFalse((setup.model_directory(self.root, self.model) / setup.RECEIPT).exists())

    def test_exact_resume_and_hash_before_publication(self):
        target = self.root / "weights.bin"
        partial = target.with_name(target.name + ".part")
        partial.write_bytes(b"da")
        def opener(request, timeout):
            self.assertEqual(request.get_header("Range"), "bytes=2-")
            return Response(b"ta", 206, {"Content-Range": "bytes 2-3/4"})
        setup.download_file("https://fixture/model", target, item("weights.bin", b"data"),
                            lambda _: None, opener=opener)
        self.assertEqual(target.read_bytes(), b"data")
        self.assertFalse(partial.exists())

    def test_ignored_range_restarts_without_concatenating_wrong_bytes(self):
        target = self.root / "weights.bin"
        target.with_name(target.name + ".part").write_bytes(b"da")
        setup.download_file("https://fixture/model", target, item("weights.bin", b"data"),
                            lambda _: None, opener=lambda *args, **kwargs: Response(b"data"))
        self.assertEqual(target.read_bytes(), b"data")

    def test_bad_range_or_hash_cannot_replace_previous_file(self):
        target = self.root / "weights.bin"
        target.write_bytes(b"previous")
        partial = target.with_name(target.name + ".part")
        partial.write_bytes(b"da")
        for response in (Response(b"ta", 206, {"Content-Range": "bytes 1-2/4"}), Response(b"oops")):
            with self.assertRaises(ValueError):
                setup.download_file("https://fixture/model", target, item("weights.bin", b"data"),
                                    lambda _: None, opener=lambda *args, **kwargs: response)
            self.assertEqual(target.read_bytes(), b"previous")

    def test_explicit_mirror_keeps_revision_and_digest(self):
        requests = []
        def fetch(url, path, expected, progress):
            requests.append((url, expected["sha256"]))
            self.fetch(url, path, expected, progress)
        setup.download_models(self.root, lambda _: None, manifest=self.manifest, fetch=fetch,
                              endpoint="https://hf-mirror.com")
        self.assertTrue(all(url.startswith("https://hf-mirror.com/") for url, _ in requests))
        self.assertIn("/resolve/" + "a" * 40 + "/", requests[0][0])
        self.assertEqual(requests[0][1], self.model["files"][0]["sha256"])

    def test_lock_is_exclusive_and_released_after_failure(self):
        with setup.download_lock(self.root):
            with self.assertRaises(OSError):
                with setup.download_lock(self.root):
                    self.fail("nested acquisition must fail")
        with setup.download_lock(self.root):
            pass

    def test_manifest_rejects_unsafe_paths_and_wrong_hashes(self):
        path = self.root / "manifest.json"
        for filename in ("../outside", "C:/outside", "sub\\outside"):
            bad = json.loads(json.dumps(self.manifest))
            bad[0]["files"][0]["path"] = filename
            path.write_text(json.dumps({"schema": 1, "models": bad}))
            with self.assertRaises(ValueError):
                setup.load_manifest(path)

    def test_missing_runtime_does_not_block_verified_model_download_or_claim_ready(self):
        missing = {"id": "vc_runtime", "name": "Microsoft Visual C++ 运行库", "ready": False,
                   "status": "missing", "required_bytes": 0, "message": "需要安装运行库。",
                   "missing_libraries": ["vcruntime140_1.dll"]}
        with patch.object(setup, "inspect_runtime", return_value=missing):
            result = setup.download_models(self.root, lambda _: None, manifest=self.manifest, fetch=self.fetch)
            self.assertTrue(result["models_ready"])
            self.assertFalse(result["runtime_ready"])
            self.assertTrue(result["runtime_missing"])
            self.assertFalse(result["ready"])
            self.assertEqual(result["required_bytes"], 0)
            self.assertEqual(result["total_bytes"], 11)
            self.assertEqual(result["progress"], 1)
            self.assertEqual(result["checks"][-1]["id"], "vc_runtime")
            self.assertTrue(all(value["ready"] for value in result["checks"][:2]))

    def test_windows_runtime_check_reports_missing_dll_without_importing_inference(self):
        loader = Mock(side_effect=[object(), OSError("missing")])
        with patch("windows_setup.os.name", "nt"), patch("ctypes.WinDLL", loader, create=True):
            result = setup.inspect_runtime()
        self.assertFalse(result["ready"])
        self.assertEqual(result["missing_libraries"], ["vcruntime140_1.dll"])
        self.assertEqual([call.args[0] for call in loader.call_args_list],
                         ["msvcp140.dll", "vcruntime140_1.dll"])
        self.assertTrue(all(call.kwargs == {"winmode": 0x00000800} for call in loader.call_args_list))


if __name__ == "__main__":
    unittest.main()
