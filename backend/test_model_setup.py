"""Offline setup tests use tiny artifacts and never load inference models."""
from contextlib import ExitStack, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import diagnose
import download_models as downloader
from model_artifacts import RECEIPT_NAME, inspect_model, load_manifest, selected_models, write_receipt


def fixtures():
    manifest, payloads = {}, {}
    for number, identifier in enumerate(("qwen", "whisper", "cleanup"), 1):
        files = []
        for name in ("config.json", "weights.bin"):
            body = (identifier + ":" + name).encode()
            payloads[identifier, name] = body
            files.append({"path": name, "size": len(body), "sha256": hashlib.sha256(body).hexdigest()})
        manifest[identifier] = {"id": identifier, "repo_id": "test/" + identifier,
            "revision": str(number) * 40, "directory": "test-" + identifier, "files": files}
    return manifest, payloads


def populate(directory, model, payloads, receipt=False):
    directory.mkdir(parents=True, exist_ok=True)
    for item in model["files"]:
        (directory / item["path"]).write_bytes(payloads[model["id"], item["path"]])
    if receipt: write_receipt(directory, model)


class ModelSetupTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dictation-model-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.models = self.root / "models"
        self.manifest, self.payloads = fixtures()
        self.calls = []
        self.output = io.StringIO()
        self.events = downloader.Events(True, self.output)
        network = mock.patch("socket.create_connection", side_effect=AssertionError("network forbidden"))
        network.start(); self.addCleanup(network.stop)

    def fetch(self, model, item, stage, progress, force_download=False):
        self.calls.append((model["id"], item["path"], force_download))
        (stage / item["path"]).write_bytes(self.payloads[model["id"], item["path"]])
        progress(item["size"])

    def run_download(self, asr="qwen", fetch=None):
        return downloader.download_models(self.models, asr, self.events,
            manifest=self.manifest, fetch_file=fetch or self.fetch)

    def test_official_inventory_is_pinned_and_complete(self):
        catalog = load_manifest()
        self.assertEqual([m["id"] for m in selected_models("qwen", catalog)], ["qwen", "cleanup"])
        self.assertEqual({key: len(model["files"]) for key, model in catalog.items()},
                         {"qwen": 10, "whisper": 3, "cleanup": 12})
        self.assertEqual(sum(i["size"] for i in catalog["qwen"]["files"]), 2467857511)
        self.assertEqual(sum(i["size"] for i in catalog["cleanup"]["files"]), 2278970666)

    def test_default_only_fetches_qwen_and_cleanup_and_preserves_optional_assets(self):
        optional = self.models / "test-whisper"
        optional.mkdir(parents=True); (optional / "private").write_bytes(b"leave me")
        result = self.run_download()
        self.assertEqual([row["id"] for row in result], ["qwen", "cleanup"])
        self.assertEqual(len(self.calls), 4)
        self.assertEqual((optional / "private").read_bytes(), b"leave me")
        for model in selected_models("qwen", self.manifest):
            self.assertTrue(inspect_model(self.models / model["directory"], model)["ready"])
        events = [json.loads(line) for line in self.output.getvalue().splitlines()]
        self.assertTrue(all(row["schema"] == 1 for row in events))
        self.assertEqual(events[-1]["event"], "complete")
        self.assertTrue(events[-1]["ready"])
        self.assertTrue(all(row["reused"] is False for row in events[-1]["models"]))
        self.assertLess(len(json.dumps(events[-1]).encode()), 2048)

    def test_explicit_whisper_reuses_verified_legacy_files_without_network(self):
        for model in selected_models("whisper", self.manifest):
            populate(self.models / model["directory"], model, self.payloads)
        result = self.run_download("whisper", fetch=mock.Mock(side_effect=AssertionError("no download")))
        self.assertTrue(all(row["reused"] for row in result))
        self.assertFalse((self.models / "test-qwen").exists())
        self.assertTrue((self.models / "test-whisper" / RECEIPT_NAME).is_file())

    def test_failure_keeps_installed_model_and_retry_reuses_completed_staged_files(self):
        old = self.models / "test-qwen"
        old.mkdir(parents=True); (old / "weights.bin").write_bytes(b"old usable revision")
        def interrupted(model, item, stage, progress, force_download=False):
            if item["path"] == "weights.bin":
                raise OSError("offline")
            self.fetch(model, item, stage, progress, force_download)
        with self.assertRaisesRegex(OSError, "offline"): self.run_download(fetch=interrupted)
        self.assertEqual((old / "weights.bin").read_bytes(), b"old usable revision")
        self.assertFalse((old / RECEIPT_NAME).exists())
        self.calls.clear(); self.run_download()
        self.assertNotIn(("qwen", "config.json", False), self.calls)
        self.assertEqual(len(self.calls), 3)
        previous = list(self.models.glob(".previous-test-qwen-*"))
        self.assertEqual(len(previous), 1)
        self.assertEqual((previous[0] / "weights.bin").read_bytes(), b"old usable revision")

    def test_corrupt_download_not_published_and_retry_forces_bad_cache_file(self):
        def corrupt(model, item, stage, progress, force_download=False):
            (stage / item["path"]).write_bytes(b"!" * item["size"])
        with self.assertRaisesRegex(ValueError, "SHA-256"): self.run_download(fetch=corrupt)
        self.assertFalse((self.models / "test-qwen").exists())
        self.run_download()
        self.assertEqual(self.calls[0], ("qwen", "config.json", True))

    def test_exchange_failure_leaves_both_models_intact(self):
        stage, old = self.root / "stage", self.root / "current"
        stage.mkdir(); old.mkdir()
        (stage / "file").write_bytes(b"new"); (old / "file").write_bytes(b"old")
        with mock.patch.object(downloader, "exchange_directories", side_effect=OSError("unsupported")), self.assertRaises(OSError):
            downloader.publish_model(stage, old)
        self.assertEqual((old / "file").read_bytes(), b"old")
        self.assertEqual((stage / "file").read_bytes(), b"new")

    def test_interruption_after_atomic_exchange_keeps_new_destination_and_old_stage(self):
        stage, old = self.root / "stage", self.root / "current"
        stage.mkdir(); old.mkdir()
        (stage / "file").write_bytes(b"new"); (old / "file").write_bytes(b"old")
        exchange = downloader.exchange_directories
        def interrupt(left, right):
            exchange(left, right)
            raise downloader.DownloadCancelled()
        with mock.patch.object(downloader, "exchange_directories", side_effect=interrupt), self.assertRaises(downloader.DownloadCancelled):
            downloader.publish_model(stage, old)
        self.assertEqual((old / "file").read_bytes(), b"new")
        self.assertEqual((stage / "file").read_bytes(), b"old")

    def test_sigterm_preserves_completed_files_and_releases_lock(self):
        real_download = downloader.download_models
        def cancel_fetch(model, item, stage, progress, force_download=False):
            if item["path"] == "weights.bin": os.kill(os.getpid(), signal.SIGTERM)
            self.fetch(model, item, stage, progress, force_download)
        with mock.patch.object(downloader, "download_models", side_effect=lambda directory, asr, events:
            real_download(directory, asr, events, manifest=self.manifest, fetch_file=cancel_fetch)), redirect_stdout(self.output):
            result = downloader.main(["--models-dir", str(self.models), "--json-events"])
        self.assertEqual(result, 130)
        self.assertEqual(json.loads(self.output.getvalue().splitlines()[-1])["event"], "cancelled")
        completed = list(self.models.glob(".downloads/*/config.json"))
        self.assertEqual(len(completed), 1)
        self.assertEqual(completed[0].read_bytes(), self.payloads["qwen", "config.json"])
        self.assertFalse((self.models / "test-qwen").exists())
        self.assertEqual(len(self.run_download()), 2)

    def test_low_disk_and_staging_symlink_never_write_old_assets(self):
        with mock.patch.object(downloader.shutil, "disk_usage", return_value=SimpleNamespace(free=0)):
            with self.assertRaisesRegex(OSError, "磁盘空间"): self.run_download()
        self.assertFalse(self.calls)
        other = self.root / "outside"; other.mkdir()
        staged = self.models / ".downloads"
        for child in staged.iterdir(): child.rmdir()
        staged.rmdir(); staged.symlink_to(other, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "符号链接"): self.run_download()
        self.assertFalse(list(other.iterdir()))

    def test_receipt_detects_stat_change_and_deep_check_detects_corrupt_bytes(self):
        model = self.manifest["qwen"]; directory = self.models / model["directory"]
        populate(directory, model, self.payloads, receipt=True)
        self.assertTrue(inspect_model(directory, model)["ready"])
        path = directory / "weights.bin"; size = path.stat().st_size
        path.write_bytes(b"?" * size)
        self.assertEqual(inspect_model(directory, model)["status"], "warning")
        self.assertFalse(inspect_model(directory, model, deep=True)["ready"])
        (directory / RECEIPT_NAME).write_text("[]")
        self.assertEqual(inspect_model(directory, model)["status"], "warning")

    def test_hf_adapter_pins_revision_disables_credentials_and_reports_bytes(self):
        calls, progress = [], []
        def sdk(**kwargs):
            calls.append(kwargs)
            bar = kwargs["tqdm_class"](total=10, unit="B", disable=True)
            bar.update(5); bar.close()
            return "done"
        model = self.manifest["qwen"]
        with mock.patch.dict("sys.modules", {"huggingface_hub": SimpleNamespace(hf_hub_download=sdk)}):
            result = downloader.hf_fetch(model, model["files"][0], self.root, progress.append, True)
        self.assertEqual(result, "done")
        self.assertEqual(calls[0]["revision"], model["revision"])
        self.assertIs(calls[0]["token"], False)
        self.assertIs(calls[0]["force_download"], True)
        self.assertIn(5, progress)


class InstallationReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dictation-diagnose-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runtime, self.backend = self.root / "runtime", self.root / "backend"
        self.backend.mkdir()
        for name in ("server.py", "streaming.py", "prompt_store.py", "prompt-imports.json", "start.sh", "download_models.py",
                     "model_artifacts.py", "model-manifest.json", "diagnose.py"):
            (self.backend / name).write_text("test fixture")
        (self.backend / "requirements.txt").write_text("example-package==1.2.3\n")
        self.python = self.root / "Python/bin/python3"
        self.python.parent.mkdir(parents=True); self.python.write_text("inert"); self.python.chmod(0o700)
        self.manifest, self.payloads = fixtures()
        self.stack = ExitStack(); self.addCleanup(self.stack.close)
        for target, value in (("platform.machine", "arm64"), ("platform.system", "Darwin"),
                              ("platform.mac_ver", ("14.0", (), ""))):
            self.stack.enter_context(mock.patch(target, return_value=value))
        self.metadata = {"machine": "arm64", "version": "3.11.14", "packages": {"example-package": "1.2.3"}}
        self.stack.enter_context(mock.patch.object(diagnose, "python_metadata", return_value=self.metadata))
        self.health = {"reachable": False, "identity_matches": False}
        self.stack.enter_context(mock.patch.object(diagnose, "check_health", side_effect=lambda: self.health))

    def report(self, **kwargs):
        return diagnose.installation_report(self.runtime, self.python, backend_dir=self.backend,
                                           manifest=self.manifest, **kwargs)

    def test_empty_installation_is_downloadable_without_writing(self):
        result = self.report()
        self.assertFalse(result["ready"]); self.assertFalse(result["blocked"])
        self.assertTrue(result["can_download"]); self.assertFalse(self.runtime.exists())
        self.assertEqual(result["asr_backend"], "qwen")
        self.assertEqual([row["id"] for row in result["models"]], ["qwen", "cleanup"])
        expected = sum(i["size"] for m in selected_models("qwen", self.manifest) for i in m["files"])
        self.assertEqual(result["required_download_bytes"], expected)

    def test_verified_assets_ready_without_running_service_or_permissions(self):
        for model in selected_models("qwen", self.manifest):
            populate(self.runtime / "models" / model["directory"], model, self.payloads, receipt=True)
        result = self.report()
        self.assertTrue(result["ready"]); self.assertFalse(result["can_download"])
        self.assertFalse(result["health"]["reachable"])
        self.assertEqual(result["verification"], "receipt_and_stat")
        self.assertTrue(self.report(deep=True)["ready"])

    def test_missing_python_or_mismatched_dependencies_block_download(self):
        self.metadata["packages"] = {}
        result = self.report(); self.assertTrue(result["blocked"]); self.assertFalse(result["can_download"])
        self.python.unlink()
        result = self.report(); self.assertTrue(result["blocked"]); self.assertFalse(result["can_download"])
        self.assertEqual(next(row for row in result["checks"] if row["id"] == "python")["status"], "missing")

    def test_busy_service_and_bad_selection_are_not_downloadable(self):
        self.health = {"reachable": True, "identity_matches": True, "busy": True}
        result = self.report(); self.assertFalse(result["can_download"]); self.assertTrue(result["service_busy"])
        self.assertIn("录音", result["download_block_reason"])
        self.runtime.mkdir(); (self.runtime / "asr-backend").write_text("unknown")
        result = self.report(); self.assertTrue(result["blocked"]); self.assertFalse(result["can_download"])

    def test_missing_requirements_never_duplicates_stable_ids(self):
        (self.backend / "requirements.txt").unlink()
        result = self.report(); ids = [row["id"] for row in result["checks"]]
        self.assertEqual(len(ids), len(set(ids)))
        self.assertTrue(result["blocked"])


if __name__ == "__main__":
    unittest.main()
