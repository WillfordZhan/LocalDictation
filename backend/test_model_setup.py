"""Offline setup tests use tiny artifacts and never load inference models."""
from contextlib import ExitStack, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import diagnose
import download_models as downloader
from model_artifacts import RECEIPT_NAME, inspect_model, load_manifest, selected_models, write_receipt


def fixtures():
    manifest, payloads = {}, {}
    for number, identifier in enumerate(("qwen", "whisper", "cleanup", "cleanup-9b"), 1):
        files = []
        names = ("config.json", "weights-00001-of-00002.safetensors", "weights-00002-of-00002.safetensors") \
            if identifier == "cleanup-9b" else ("config.json", "weights.bin")
        for name in names:
            body = (identifier + ":" + name).encode()
            payloads[identifier, name] = body
            files.append({"path": name, "size": len(body), "sha256": hashlib.sha256(body).hexdigest()})
        manifest[identifier] = {"id": identifier, "repo_id": "test/" + identifier,
            "kind": "cleanup" if identifier.startswith("cleanup") else "asr",
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

    def run_download(self, asr="qwen", fetch=None, cleanup_model="cleanup"):
        return downloader.download_models(self.models, asr, self.events,
            cleanup_model=cleanup_model, manifest=self.manifest, fetch_file=fetch or self.fetch)

    def test_official_inventory_is_pinned_and_complete(self):
        catalog = load_manifest()
        self.assertEqual([m["id"] for m in selected_models("qwen", catalog)], ["qwen", "cleanup"])
        self.assertEqual(set(catalog), {"qwen", "whisper", "cleanup", "cleanup-9b"})
        self.assertEqual(len(catalog["qwen"]["files"]), 10)
        self.assertEqual(len(catalog["whisper"]["files"]), 3)
        self.assertEqual(sum(i["size"] for i in catalog["qwen"]["files"]), 2467857511)
        for choice, name in (("cleanup", "Qwen3.5-4B-4bit"), ("cleanup-9b", "Qwen3.5-9B-4bit")):
            model = selected_models("qwen", catalog, choice)[1]
            self.assertEqual(model["directory"], name)
            self.assertEqual(model["kind"], "cleanup")
            self.assertTrue(any(item["path"].endswith(".safetensors") for item in model["files"]))

    def test_selection_rejects_unknown_missing_or_wrong_kind_without_fallback(self):
        for choice in ("qwen", "unknown", "", None):
            with self.subTest(choice=choice), self.assertRaisesRegex(ValueError, "整理模型"):
                selected_models("qwen", self.manifest, choice)
        self.manifest["cleanup-9b"]["kind"] = "asr"
        with self.assertRaisesRegex(ValueError, "类型"):
            selected_models("qwen", self.manifest, "cleanup-9b")
        del self.manifest["cleanup-9b"]
        self.assertEqual(selected_models("qwen", self.manifest)[1]["id"], "cleanup")
        with self.assertRaisesRegex(ValueError, "清单"):
            self.run_download(cleanup_model="cleanup-9b")
        self.assertFalse(self.models.exists())
        self.assertFalse(self.calls)

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

    def test_explicit_9b_only_fetches_selected_pair_and_keeps_4b(self):
        other = self.models / self.manifest["cleanup"]["directory"]
        populate(other, self.manifest["cleanup"], self.payloads, receipt=True)
        before = {path.name: path.read_bytes() for path in other.iterdir()}
        result = self.run_download(cleanup_model="cleanup-9b")
        self.assertEqual([row["id"] for row in result], ["qwen", "cleanup-9b"])
        self.assertEqual({row[0] for row in self.calls}, {"qwen", "cleanup-9b"})
        self.assertEqual({path.name: path.read_bytes() for path in other.iterdir()}, before)
        self.assertTrue(inspect_model(self.models / "test-cleanup-9b", self.manifest["cleanup-9b"])["ready"])

    def test_download_cli_passes_selected_cleanup_and_rejects_other_models(self):
        for arguments, expected in (([], "cleanup"), (["--cleanup-model", "cleanup-9b"], "cleanup-9b")):
            with self.subTest(expected=expected), mock.patch.object(downloader, "download_models") as download:
                self.assertEqual(downloader.main(["--models-dir", str(self.models), *arguments]), 0)
                self.assertEqual(download.call_args.kwargs["cleanup_model"], expected)
        with mock.patch.object(downloader, "download_models") as download, \
             mock.patch("sys.stderr", new=io.StringIO()), self.assertRaises(SystemExit) as stopped:
            downloader.main(["--models-dir", str(self.models), "--cleanup-model", "qwen"])
        self.assertEqual(stopped.exception.code, 2)
        download.assert_not_called()

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
        with mock.patch.object(downloader, "download_models", side_effect=lambda directory, asr, events, **kwargs:
            real_download(directory, asr, events, manifest=self.manifest, fetch_file=cancel_fetch, **kwargs)), redirect_stdout(self.output):
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
        self.assertEqual(result["cleanup_model"], "cleanup")
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

    def test_saved_cleanup_selection_only_checks_current_tier_and_missing_shards(self):
        for model in self.manifest.values():
            populate(self.runtime / "models" / model["directory"], model, self.payloads, receipt=True)
        (self.runtime / "cleanup-model").write_text("cleanup-9b\n")
        result = self.report()
        self.assertEqual(result["cleanup_model"], "cleanup-9b")
        self.assertEqual([row["id"] for row in result["models"]], ["qwen", "cleanup-9b"])
        self.assertTrue(result["ready"])
        missing = "weights-00002-of-00002.safetensors"
        (self.runtime / "models/test-cleanup-9b" / missing).unlink()
        result = self.report()
        self.assertFalse(result["ready"])
        self.assertTrue(result["can_download"])
        self.assertEqual(result["models"][1]["invalid_files"], [missing])
        self.assertEqual(result["models"][1]["id"], "cleanup-9b")
        # A valid 4B installation cannot make the requested 9B look ready.
        self.assertTrue(self.report(cleanup_model="cleanup")["ready"])

    def test_invalid_or_unreadable_saved_cleanup_selection_is_explicitly_blocked(self):
        self.runtime.mkdir()
        selection = self.runtime / "cleanup-model"
        for value in ("", "qwen", "unknown"):
            with self.subTest(value=value):
                selection.write_text(value)
                result = self.report()
                self.assertEqual(result["cleanup_model"], value)
                self.assertTrue(result["blocked"])
                self.assertFalse(result["can_download"])
                self.assertEqual(next(row for row in result["checks"] if row["id"] == "cleanup_selection")["status"], "invalid")
        selection.unlink(); selection.mkdir()
        self.assertEqual(self.report()["cleanup_model"], "unreadable")

    def test_diagnostic_cli_uses_explicit_cleanup_selection(self):
        for args, expected in (([], None), (["--cleanup-model", "cleanup-9b"], "cleanup-9b")):
            with self.subTest(expected=expected), mock.patch.object(diagnose, "installation_report", return_value={"checks": []}) as report:
                diagnose.main(["--installation", "--runtime-dir", str(self.runtime), *args])
                self.assertEqual(report.call_args.kwargs["cleanup_model"], expected)

    def test_cleanup_selection_links_and_fifo_are_invalid_without_reading(self):
        self.runtime.mkdir()
        selection = self.runtime / "cleanup-model"
        target = self.runtime / "selection-target"
        for exists in (False, True):
            with self.subTest(target_exists=exists):
                if exists: target.write_text("cleanup-9b")
                selection.symlink_to(target)
                result = self.report()
                self.assertEqual(result["cleanup_model"], "unreadable")
                self.assertTrue(result["blocked"])
                self.assertEqual(self.report(cleanup_model="cleanup")["cleanup_model"], "cleanup")
                selection.unlink()
        os.mkfifo(selection)
        self.assertEqual(self.report()["cleanup_model"], "unreadable")


class StartupSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dictation-start-test-")
        self.addCleanup(self.temporary.cleanup)
        self.runtime = Path(self.temporary.name)
        self.python = self.runtime / "python"
        self.python.write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        self.python.chmod(0o700)
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith("LOCAL_DICTATION_")}
        self.environment.update(LOCAL_DICTATION_WORK_DIR=str(self.runtime), LOCAL_DICTATION_PYTHON=str(self.python))

    def start(self):
        return subprocess.run(["/bin/bash", str(Path(__file__).with_name("start.sh"))],
                              env=self.environment, capture_output=True, text=True, timeout=5)

    def test_missing_selection_defaults_and_saved_selection_survives_launcher(self):
        result = self.start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--cleanup-model\ncleanup\n", result.stdout)
        (self.runtime / "cleanup-model").write_text("cleanup-9b\n")
        result = self.start()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--cleanup-model\ncleanup-9b\n", result.stdout)
        self.environment["LOCAL_DICTATION_CLEANUP_MODEL"] = "cleanup"
        self.assertIn("--cleanup-model\ncleanup\n", self.start().stdout)

    def test_invalid_saved_or_environment_selection_never_launches_other_tier(self):
        selection = self.runtime / "cleanup-model"
        for value in ("", "qwen", "unknown"):
            with self.subTest(value=value):
                selection.write_text(value)
                result = self.start()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("整理模型", result.stderr)
        selection.write_text("cleanup-9b")
        self.environment["LOCAL_DICTATION_CLEANUP_MODEL"] = ""
        self.assertNotEqual(self.start().returncode, 0)
        self.environment.pop("LOCAL_DICTATION_CLEANUP_MODEL")
        selection.unlink(); selection.mkdir()
        self.assertIn("无法读取整理模型配置", self.start().stderr)

    def test_link_and_fifo_selection_fail_without_starting_or_blocking(self):
        selection = self.runtime / "cleanup-model"
        target = self.runtime / "selection-target"
        for exists in (False, True):
            with self.subTest(target_exists=exists):
                if exists: target.write_text("cleanup-9b")
                selection.symlink_to(target)
                result = self.start()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertIn("普通文件", result.stderr)
                selection.unlink()
        os.mkfifo(selection)
        result = self.start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("普通文件", result.stderr)
        self.environment["LOCAL_DICTATION_CLEANUP_MODEL"] = "cleanup"
        self.assertEqual(self.start().returncode, 0)


if __name__ == "__main__":
    unittest.main()
