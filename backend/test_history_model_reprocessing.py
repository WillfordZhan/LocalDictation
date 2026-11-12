"""History model selection uses inert artifacts and no MLX or network downloads."""
import hashlib
import http.client
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

from model_artifacts import write_receipt
from server import DictationOptions, DictationService, LocalModels, make_handler


class HistoryModelReprocessingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="history-model-fixture-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.catalog = {}
        for identifier, name in (("cleanup", "Qwen3.5-4B-4bit"), ("cleanup-9b", "Qwen3.5-9B-4bit")):
            directory = self.root / name
            directory.mkdir()
            data = b"inert local weight fixture"
            (directory / "model.safetensors").write_bytes(data)
            model = {"id": identifier, "kind": "cleanup", "directory": name,
                     "repo_id": "fixture/" + name, "revision": "a" * 40,
                     "files": [{"path": "model.safetensors", "size": len(data),
                                "sha256": hashlib.sha256(data).hexdigest()}]}
            write_receipt(directory, model)
            self.catalog[identifier] = model
        self.four = self.catalog["cleanup"]["directory"]
        self.nine = self.catalog["cleanup-9b"]["directory"]
        self.manifest = patch("model_artifacts.load_manifest", return_value=self.catalog)
        self.manifest.start(); self.addCleanup(self.manifest.stop)
        self.live = LocalModels(self.root / "asr", self.root / self.nine, asr_backend="qwen")
        self.live.asr_ready = self.live.cleanup_ready = True
        self.live.model, self.live.tokenizer = object(), object()
        self.live._cleanup_prefix_cache = object()
        self.live._cleanup_prefix_key = ("live-cache",)
        self.original_state = (self.live.model, self.live.tokenizer,
                               self.live._cleanup_prefix_cache, self.live._cleanup_prefix_key)
        self.live.transcribe_segment = Mock(return_value=("新的口述。", 5, 1))
        self.events = []
        self.fail_load = False
        self.fail_edit = False
        self.load_entered = None
        self.load_release = None
        self.edit_entered = None
        self.edit_release = None

        def load(editor):
            self.events.append(("load", editor.cleanup_path.name, threading.get_ident()))
            self.assertFalse(editor.asr_ready)
            if self.load_entered:
                self.load_entered.set()
                if not self.load_release.wait(3): raise RuntimeError("test load was not released")
            if self.fail_load: raise RuntimeError("inert load failure")
            editor.model, editor.tokenizer = object(), object()
            editor.cleanup_ready = True

        def edit(editor, raw, options):
            self.events.append(("edit", editor.cleanup_path.name, threading.get_ident(), options))
            if self.edit_entered:
                self.edit_entered.set()
                if not self.edit_release.wait(3): raise RuntimeError("test edit was not released")
            if self.fail_edit: raise RuntimeError("inert generation failure")
            return "请保留原意，测试另一种表达。"

        def release(editor):
            self.events.append(("release", editor.cleanup_path.name, threading.get_ident()))
            editor.cleanup_ready = False
            editor.model = editor.tokenizer = None
            editor._clear_cleanup_prefix()

        for name, function in (("load_cleanup", load), ("cleanup", edit), ("release_cleanup", release)):
            mocked = patch.object(LocalModels, name, autospec=True, side_effect=function)
            mocked.start(); self.addCleanup(mocked.stop)
        self.service = DictationService(self.live, memory_only_prompts=True)
        self.service.load_complete = True
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        for event in (self.load_release, self.edit_release):
            if event: event.set()
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.service.streams.close()
        self.service.worker.shutdown()

    def request(self, method, path, payload=None, headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=4)
        body = json.dumps(payload, ensure_ascii=False).encode() if payload is not None else None
        connection.request(method, path, body, {"Content-Type": "application/json", **(headers or {})})
        response = connection.getresponse()
        result = response.status, json.loads(response.read())
        connection.close()
        return result

    def run_edit(self, model=None, *, version=None, body=None):
        payload = {"raw_text": "嗯，请保留原意，我想测试一下另一种表达。"}
        if model is not None: payload["model_id"] = model
        return self.request("POST", "/cleanup/reprocess", payload if body is None else body,
                            {"X-Cleanup-Prompt-Version": version or self.service.prompts.active_version_id})

    def assert_live_unchanged(self):
        self.assertIs(self.service.models, self.live)
        self.assertEqual(self.live.cleanup_path, self.root / self.nine)
        self.assertEqual((self.live.model, self.live.tokenizer,
                          self.live._cleanup_prefix_cache, self.live._cleanup_prefix_key), self.original_state)
        self.assertFalse((self.root / "cleanup-model").exists())

    def test_catalog_lists_only_verified_official_choices_without_loading(self):
        (self.root / "Experimental-Editor").mkdir()
        status, catalog = self.request("GET", "/cleanup/prompts")
        self.assertEqual(status, 200)
        self.assertEqual(catalog["current_model"]["id"], self.nine)
        self.assertEqual(catalog["reprocess_models"], [
            {"id": self.four, "kind": "local", "ready": True},
            {"id": self.nine, "kind": "local", "ready": True}])
        self.assertEqual(self.events, [])
        (self.root / self.four / "model.safetensors").unlink()
        unavailable = self.request("GET", "/cleanup/prompts")[1]["reprocess_models"][0]
        self.assertFalse(unavailable["ready"])
        self.assertTrue(unavailable["unavailable_reason"])

    def test_same_model_and_legacy_requests_reuse_live_editor(self):
        for selected in (None, self.nine):
            with self.subTest(selected=selected):
                self.events.clear()
                status, result = self.run_edit(selected)
                self.assertEqual(status, 200, result)
                self.assertTrue(result["cleanup_applied"])
                self.assertEqual(result["cleanup_profile"]["model_id"], self.nine)
                self.assertEqual(result["model_load_seconds"], 0)
                self.assertEqual([event[0] for event in self.events], ["edit"])
                self.assert_live_unchanged()

    def test_other_model_loads_edits_and_releases_on_same_worker_without_asr(self):
        worker_id = self.service.worker.submit(threading.get_ident).result()
        active = self.service.prompts.active_version_id
        status, result = self.run_edit(self.four)
        self.assertEqual(status, 200, result)
        self.assertTrue(result["cleanup_applied"])
        self.assertEqual(result["cleanup_profile"]["model_id"], self.four)
        self.assertEqual(result["cleanup_profile"]["version_id"], active)
        self.assertIsNone(result["asr_model"])
        self.assertGreaterEqual(result["model_load_seconds"], 0)
        self.assertEqual([event[0] for event in self.events], ["load", "edit", "release"])
        self.assertTrue(all(event[1] == self.four and event[2] == worker_id for event in self.events))
        self.live.transcribe_segment.assert_not_called()
        self.assertEqual(self.service.prompts.active_version_id, active)
        self.assert_live_unchanged()

    def test_unknown_paths_urls_and_missing_model_never_load_or_fallback(self):
        for invalid in ("../" + self.four, str(self.root / self.four), "https://example.invalid/model",
                        "Experimental-Editor", "cleanup", "", None, 4, {}, "x" * 129):
            with self.subTest(invalid=invalid):
                status, _ = self.run_edit(body={"raw_text": "原文。", "model_id": invalid})
                self.assertEqual(status, 400)
        (self.root / self.four / "model.safetensors").unlink()
        self.assertEqual(self.run_edit(self.four)[0], 503)
        self.assertEqual(self.events, [])
        self.assert_live_unchanged()

    def test_model_load_failure_keeps_selected_provenance_and_preserves_raw(self):
        self.fail_load = True
        status, result = self.run_edit(self.four)
        self.assertEqual(status, 200, result)
        self.assertFalse(result["cleanup_applied"])
        self.assertEqual(result["raw_text"], result["text"])
        self.assertEqual(result["cleanup_profile"]["model_id"], self.four)
        self.assertEqual(result["cleanup_outcome"], {
            "status": "failed", "reason": "model_load_failed", "error_type": "RuntimeError"})
        self.assertGreaterEqual(result["model_load_seconds"], 0)
        self.assertEqual([event[0] for event in self.events], ["load", "release"])
        self.assert_live_unchanged()
        self.assertFalse(self.service.reprocess_lock.locked())

    def test_generation_failure_releases_temporary_editor_without_fallback(self):
        self.fail_edit = True
        status, result = self.run_edit(self.four)
        self.assertEqual(status, 200, result)
        self.assertFalse(result["cleanup_applied"])
        self.assertEqual(result["cleanup_outcome"]["status"], "failed")
        self.assertEqual(result["cleanup_profile"]["model_id"], self.four)
        self.assertEqual([event[0] for event in self.events], ["load", "edit", "release"])
        self.assert_live_unchanged()

    def test_available_alternative_is_independent_of_live_editor_readiness(self):
        self.live.cleanup_ready = False
        catalog = self.request("GET", "/cleanup/prompts")[1]
        self.assertFalse(catalog["current_model"]["ready"])
        self.assertTrue(catalog["reprocess_models"][0]["ready"])
        status, result = self.run_edit(self.four)
        self.assertEqual(status, 200, result)
        self.assertTrue(result["cleanup_applied"])
        self.assertFalse(self.live.cleanup_ready)
        self.assert_live_unchanged()

    def test_prompt_snapshot_survives_activation_during_cold_load(self):
        selected = self.service.prompts.resolve()
        draft = {"name": "另一份规则", "note": "", "system_prompt": "保留自然语气。",
                 "user_prefix": "整理：", "examples": []}
        other = self.service.prompts.create(draft, self.nine)
        self.load_entered, self.load_release = threading.Event(), threading.Event()
        responses = []
        client = threading.Thread(target=lambda: responses.append(self.run_edit(self.four, version=selected.id)))
        client.start()
        try:
            self.assertTrue(self.load_entered.wait(1))
            self.service.prompts.activate(other.id)
        finally:
            self.load_release.set(); client.join(4)
        self.assertEqual(responses[0][0], 200)
        self.assertEqual(responses[0][1]["cleanup_profile"]["version_id"], selected.id)
        self.assertEqual(responses[0][1]["cleanup_profile"]["content_sha256"], selected.content_sha256)
        edit = next(event for event in self.events if event[0] == "edit")
        self.assertEqual(edit[3].cleanup_profile, selected)
        self.assertEqual(self.service.prompts.active_version_id, other.id)
        self.assert_live_unchanged()

    def test_recording_admission_during_alternate_edit_keeps_inference_serial(self):
        # Exercise actual session scheduling without importing DSP dependencies;
        # boundary quality belongs to the separate streaming tests.
        cut = patch("streaming.next_cut", side_effect=lambda pcm, finished:
                    16000 * 30 if len(pcm) // 2 >= 16000 * 35 else None)
        cut.start(); self.addCleanup(cut.stop)
        self.edit_entered, self.edit_release = threading.Event(), threading.Event()
        responses = []
        client = threading.Thread(target=lambda: responses.append(self.run_edit(self.four)))
        client.start()
        session_id = "12345678-1234-1234-1234-123456789abc"
        try:
            self.assertTrue(self.edit_entered.wait(1))
            self.assertTrue(self.service.health()["accepts_streaming"])
            self.assertEqual(self.run_edit(self.nine)[0], 409)
            self.service.streams.start(session_id, DictationOptions(cleanup=False), ())
            self.service.streams.append(session_id, 0, b"\1\0" * (16000 * 35))
            self.live.transcribe_segment.assert_not_called()
        finally:
            self.edit_release.set(); client.join(4)
        self.assertEqual(responses[0][0], 200)
        self.service.worker.submit(lambda: None).result(timeout=2)
        self.live.transcribe_segment.assert_called_once()
        self.service.streams.cancel(session_id)
        self.assert_live_unchanged()

    def test_queued_alternative_yields_to_recording_before_model_load(self):
        self.check_queued_change("recording", 409)

    def test_queued_alternative_rechecks_model_files_before_model_load(self):
        self.check_queued_change("model_removed", 503)

    def check_queued_change(self, change, expected_status):
        blocked, release, queued = threading.Event(), threading.Event(), threading.Event()
        def occupy_worker():
            blocked.set()
            if not release.wait(3): raise RuntimeError("test worker was not released")
        blocker = self.service.worker.submit(occupy_worker)
        self.assertTrue(blocked.wait(1))
        submit = self.service.worker.submit
        def observe_submit(function, *args, **kwargs):
            future = submit(function, *args, **kwargs)
            if function == self.service._reprocess: queued.set()
            return future
        replies = []
        session_id = "12345678-1234-1234-1234-123456789abc"
        with patch.object(self.service.worker, "submit", side_effect=observe_submit):
            client = threading.Thread(target=lambda: replies.append(self.run_edit(self.four)))
            client.start()
            try:
                self.assertTrue(queued.wait(1))
                if change == "recording":
                    self.service.streams.start(session_id, DictationOptions(), ())
                else:
                    (self.root / self.four / "model.safetensors").unlink()
            finally:
                release.set(); client.join(4); blocker.result(timeout=1)
        self.assertEqual(replies[0][0], expected_status, replies)
        self.assertEqual(self.events, [])
        self.assertFalse(self.service.reprocess_lock.locked())
        if change == "recording": self.service.streams.cancel(session_id)
        self.assert_live_unchanged()


if __name__ == "__main__":
    unittest.main()
