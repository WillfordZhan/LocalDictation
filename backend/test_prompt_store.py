"""Durability and immutability checks use only isolated temporary directories."""
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from prompt_store import (MAX_PROFILE_BYTES, PromptStore, PromptStoreError,
                          PromptValidationError, PromptVersion, json_bytes)


def draft(name="自然表达", system="忠实整理原话。"):
    return {"name": name, "note": "测试说明", "system_prompt": system,
            "user_prefix": "以下是素材：\n", "examples": [{"source": "嗯，我们继续。", "edited": "我们继续。"}]}


class PromptStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name) / "data"
        self.store = PromptStore(draft(), "test-local-model", self.directory)
        self.primary = self.directory / "cleanup-prompts.json"
        self.backup = self.directory / "cleanup-prompts.backup.json"

    def tearDown(self):
        self.temporary.cleanup()

    def reload(self):
        return PromptStore(draft("新的代码默认值", "不得覆盖存量"), "next-code-model", self.directory)

    def test_seed_is_exact_private_and_restart_does_not_replace_it(self):
        original = self.store.resolve()
        self.assertEqual(original.system_prompt, draft()["system_prompt"])
        self.assertEqual(original.user_prefix, draft()["user_prefix"])
        self.assertEqual(original.model_id, "test-local-model")
        self.assertEqual(original.origin, "builtin")
        self.assertEqual(self.primary.read_bytes(), self.backup.read_bytes())
        # Windows exposes a read-only bit through chmod/stat, not POSIX access
        # permissions. Keep the durability assertions active on both platforms.
        if os.name == "posix":
            self.assertEqual(self.primary.stat().st_mode & 0o777, 0o600)
            self.assertEqual(self.backup.stat().st_mode & 0o777, 0o600)
            self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.reload().resolve(), original)

    def test_save_is_immutable_and_activation_is_explicit(self):
        first = self.store.resolve()
        value = draft("更自然", "保留‘我觉得’，不编造结论。\n")
        saved = self.store.create(value, "model-at-save")
        value["examples"][0]["edited"] = "外部变量已改变"
        self.assertEqual(self.store.resolve(), first)
        self.assertEqual(saved.system_prompt, "保留‘我觉得’，不编造结论。\n")
        self.assertEqual(saved.examples[0][1], "我们继续。")
        self.assertEqual(saved.model_id, "model-at-save")
        self.store.activate(saved.id)
        self.assertEqual(self.store.resolve(), saved)
        loaded = self.reload()
        self.assertEqual(loaded.resolve(), saved)
        self.assertEqual(loaded.resolve(first.id), first)
        self.assertEqual(len(loaded.versions), 2)
        exported = loaded.catalog()
        exported["versions"][0]["system_prompt"] = "无法改存量"
        self.assertEqual(loaded.resolve(), saved)

    def test_unknown_version_never_falls_back(self):
        active = self.store.active_version_id
        with self.assertRaises(KeyError): self.store.resolve("missing")
        with self.assertRaises(KeyError): self.store.activate("missing")
        self.assertEqual(self.store.active_version_id, active)

    def test_corrupt_primary_recovers_mirror_and_preserves_original(self):
        saved = self.store.create(draft("已保存"), "model")
        self.store.activate(saved.id)
        self.primary.write_bytes(b"unreadable-primary")
        loaded = self.reload()
        self.assertEqual(loaded.resolve(), saved)
        self.assertIsNone(loaded.error)
        self.assertIsNotNone(loaded.recovery_message)
        preserved = list(self.directory.glob("cleanup-prompts.json.preserved-*"))
        self.assertEqual(len(preserved), 1)
        self.assertEqual(preserved[0].read_bytes(), b"unreadable-primary")
        self.assertEqual(self.primary.read_bytes(), self.backup.read_bytes())

    def test_both_bad_files_stay_intact_and_writes_are_blocked(self):
        self.primary.write_bytes(b"bad-primary")
        self.backup.write_bytes(b"bad-backup")
        loaded = self.reload()
        self.assertTrue(loaded.error)
        self.assertIsNone(loaded.catalog()["active_version_id"])
        with self.assertRaises(PromptStoreError): loaded.resolve()
        with self.assertRaises(PromptStoreError): loaded.create(draft(), "model")
        self.assertEqual(self.primary.read_bytes(), b"bad-primary")
        self.assertEqual(self.backup.read_bytes(), b"bad-backup")

    def test_integrity_mismatch_is_not_silently_accepted(self):
        value = json.loads(self.primary.read_text(encoding="utf-8"))
        value["versions"][0]["system_prompt"] = "被改过但校验值未更新"
        for path in (self.primary, self.backup): path.write_bytes(json_bytes(value))
        loaded = self.reload()
        self.assertTrue(loaded.error)
        self.assertEqual(json.loads(self.primary.read_text(encoding="utf-8")), value)

    def test_missing_mirror_is_repaired_without_new_version(self):
        first = self.store.resolve()
        self.backup.unlink()
        loaded = self.reload()
        self.assertEqual(loaded.resolve(), first)
        self.assertEqual(self.primary.read_bytes(), self.backup.read_bytes())

    def test_valid_primary_remains_usable_when_mirror_repair_and_writes_fail(self):
        candidate = self.store.create(draft("尚未激活"), "model")
        active = self.store.resolve()
        primary_bytes = self.primary.read_bytes()
        self.backup.unlink()
        with patch.object(PromptStore, "_persist", side_effect=OSError("read-only directory")):
            loaded = self.reload()
            self.assertIsNone(loaded.error)
            self.assertEqual(loaded.resolve(), active)
            self.assertEqual(loaded.catalog()["active_version_id"], active.id)
            self.assertIn("备份尚未修复", loaded.catalog()["recovery_message"])
            with self.assertRaises(PromptStoreError): loaded.create(draft("未保存"), "model")
            with self.assertRaises(PromptStoreError): loaded.activate(candidate.id)
            self.assertEqual(loaded.resolve(), active)
            self.assertEqual(len(loaded.versions), 2)
        self.assertEqual(self.primary.read_bytes(), primary_bytes)
        self.assertFalse(self.backup.exists())
        loaded.activate(candidate.id)
        self.assertEqual(loaded.resolve(), candidate)
        self.assertIsNone(loaded.persistence_warning)
        self.assertIn("存储已恢复", loaded.catalog()["recovery_message"])
        self.assertEqual(self.primary.read_bytes(), self.backup.read_bytes())

    def test_readable_backup_survives_failed_repair_and_preserves_damage_before_retry(self):
        active = self.store.resolve()
        backup_bytes = self.backup.read_bytes()
        damaged = b"unreadable original must survive"
        self.primary.write_bytes(damaged)
        with patch.object(PromptStore, "_preserve", side_effect=OSError("cannot preserve original yet")):
            loaded = self.reload()
            self.assertIsNone(loaded.error)
            self.assertEqual(loaded.resolve(), active)
            self.assertIn("恢复尚未写入", loaded.catalog()["recovery_message"])
            with self.assertRaises(PromptStoreError): loaded.create(draft("不能覆盖损坏文件"), "model")
            self.assertEqual(self.primary.read_bytes(), damaged)
            self.assertEqual(self.backup.read_bytes(), backup_bytes)
            self.assertEqual(len(loaded.versions), 1)
        saved = loaded.create(draft("重试保存"), "model")
        preserved = list(self.directory.glob("cleanup-prompts.json.preserved-*"))
        self.assertEqual(len(preserved), 1)
        self.assertEqual(preserved[0].read_bytes(), damaged)
        self.assertEqual(self.reload().resolve(saved.id), saved)
        self.assertEqual(loaded.resolve(), active)
        self.assertIsNone(loaded.persistence_warning)

    def test_unsaved_seed_is_not_reported_as_a_persisted_active_version(self):
        empty_directory = self.directory / "first-launch-unwritable"
        with patch.object(PromptStore, "_persist", side_effect=OSError("cannot initialize store")):
            loaded = PromptStore(draft(), "model", empty_directory)
        self.assertTrue(loaded.error)
        self.assertIsNone(loaded.catalog()["active_version_id"])
        with self.assertRaises(PromptStoreError): loaded.resolve()
        self.assertFalse(empty_directory.exists())

    def test_primary_commit_failure_keeps_memory_and_disk_selection(self):
        saved = self.store.create(draft("候选"), "model")
        old = self.store.resolve()
        old_bytes = self.primary.read_bytes()
        actual_replace = os.replace
        def fail_primary(source, destination):
            if Path(destination) == self.primary:
                raise OSError("simulated primary commit failure")
            return actual_replace(source, destination)
        with patch("prompt_store.os.replace", side_effect=fail_primary):
            with self.assertRaises(PromptStoreError): self.store.activate(saved.id)
            with self.assertRaises(PromptStoreError): self.store.create(draft("不能保存"), "model")
        self.assertEqual(self.store.resolve(), old)
        self.assertEqual(len(self.store.versions), 2)
        self.assertEqual(self.primary.read_bytes(), old_bytes)
        self.assertEqual(self.backup.read_bytes(), old_bytes)
        self.assertEqual(self.reload().resolve(), old)

    def test_validation_preserves_whitespace_and_all_examples(self):
        value = draft(system="  规则\n\n")
        value["user_prefix"] = ""
        value["examples"] = [{"source": f"原文{i}", "edited": f"输出{i}"} for i in range(100)]
        result = self.store.create(value, "model")
        self.assertEqual(result.system_prompt, "  规则\n\n")
        self.assertEqual(result.user_prefix, "")
        self.assertEqual(len(result.examples), 100)
        for change in ({"name": " "}, {"system_prompt": ""}, {"examples": [{"source": "a"}]},
                       {"examples": [{"source": "a", "edited": 1}]}, {"note": "\ud800"},
                       {"extra": True}):
            with self.subTest(change=change), self.assertRaises(PromptValidationError):
                self.store.create({**draft(), **change}, "model")
        with self.assertRaises(PromptValidationError):
            self.store.create(draft(system="a" * MAX_PROFILE_BYTES), "model")

    def test_import_is_idempotent_preserves_source_metadata_and_active(self):
        active = self.store.resolve()
        old = PromptVersion.create(draft("可确证旧规则"), None, version_id="verified-old-v1",
                                   origin="imported", created_at="2026-10-30T10:00:00Z")
        self.store.import_versions([old.as_dict()])
        self.store.import_versions([old.as_dict()])
        self.assertEqual(len(self.store.versions), 2)
        self.assertEqual(self.store.resolve(), active)
        self.assertEqual(self.reload().resolve(old.id), old)
        conflict = PromptVersion.create(draft("冲突"), None, version_id=old.id, origin="imported")
        with self.assertRaises(PromptValidationError): self.store.import_versions([conflict.as_dict()])

    def test_manifest_import_records_real_import_time_and_preserves_it_on_restart(self):
        before = datetime.now(timezone.utc).replace(microsecond=0)
        active = self.store.resolve()
        manifest = {**draft("可核验旧规则"), "id": "import-known-content", "model_id": "older-model", "origin": "imported"}
        self.store.import_versions([manifest])
        imported = self.store.resolve(manifest["id"])
        self.assertGreaterEqual(datetime.fromisoformat(imported.created_at.replace("Z", "+00:00")), before)
        self.assertEqual(imported.model_id, "older-model")
        loaded = self.reload()
        loaded.import_versions([manifest])
        self.assertEqual(loaded.resolve(imported.id), imported)
        self.assertEqual(loaded.resolve(), active)
        old_bytes = self.primary.read_bytes()
        with self.assertRaises(PromptValidationError):
            loaded.import_versions([{**manifest, "id": "new-import"}, {**manifest, "system_prompt": "冲突内容"}])
        self.assertEqual(self.primary.read_bytes(), old_bytes)
        self.assertEqual(len(loaded.versions), 2)

    def test_note_only_reimport_preserves_saved_metadata_without_writes(self):
        active = self.store.resolve()
        original = PromptVersion.create(
            {**draft("旧规则"), "note": "首次导入时保存的详细说明。"}, "older-model",
            version_id="import-note-only", origin="imported", created_at="2026-10-30T10:00:00Z")
        self.store.import_versions([original.as_dict()])
        before = self.primary.read_bytes()
        snapshot = {**original.as_dict(), "note": "新版安装包中的简短说明。"}
        manifest = {key: value for key, value in snapshot.items()
                    if key not in ("created_at", "content_sha256")}
        with patch.object(self.store, "_persist") as persist:
            self.store.import_versions([snapshot])
            self.store.import_versions([manifest])
            persist.assert_not_called()
        self.assertEqual(self.store.resolve(original.id), original)
        self.assertEqual(self.store.resolve(), active)
        self.assertEqual(len(self.store.versions), 2)
        self.assertEqual(self.primary.read_bytes(), before)
        self.assertEqual(self.backup.read_bytes(), before)
        self.assertEqual(self.reload().resolve(original.id), original)

    def test_note_difference_does_not_hide_content_or_other_metadata_conflicts(self):
        original = PromptVersion.create(draft("旧规则"), "older-model", version_id="import-conflict",
                                       origin="imported", created_at="2026-10-30T10:00:00Z")
        self.store.import_versions([original.as_dict()])
        active = self.store.resolve()
        before = self.primary.read_bytes()
        changes = {
            "name": "另一个名称",
            "system_prompt": "不同的正文编辑规则。",
            "user_prefix": "不同的素材前缀：",
            "examples": [{"source": "嗯，继续。", "edited": "继续。"}],
            "model_id": "different-model",
            "origin": "user",
            "created_at": "2026-10-31T10:00:00Z",
        }
        for field, value in changes.items():
            with self.subTest(field=field):
                changed = {**original.as_dict(), "note": "仅说明已更新", field: value}
                # Valid hashes must not let changed editing content bypass the
                # immutable version check; metadata conflicts are separate too.
                candidate = PromptVersion.create(
                    {key: changed[key] for key in ("name", "note", "system_prompt", "user_prefix", "examples")},
                    changed["model_id"], version_id=changed["id"], origin=changed["origin"],
                    created_at=changed["created_at"])
                with patch.object(self.store, "_persist") as persist:
                    with self.assertRaises(PromptValidationError):
                        self.store.import_versions([candidate.as_dict()])
                    persist.assert_not_called()
                self.assertEqual(self.store.resolve(original.id), original)
                self.assertEqual(self.store.resolve(), active)
                self.assertEqual(self.primary.read_bytes(), before)
                self.assertEqual(self.backup.read_bytes(), before)

    def test_note_only_reimport_still_revalidates_content_hash(self):
        original = self.store.resolve()
        changed = {**original.as_dict(), "note": "新版说明", "system_prompt": "未重新计算校验值的内容"}
        with patch.object(self.store, "_persist") as persist:
            with self.assertRaisesRegex(PromptValidationError, "内容校验不一致"):
                self.store.import_versions([changed])
            persist.assert_not_called()
        self.assertEqual(self.store.resolve(), original)

    def test_temporary_cleanup_failure_does_not_reverse_a_successful_commit(self):
        actual_unlink = Path.unlink
        def fail_temporary_cleanup(path, **kwargs):
            if ".tmp-" in path.name: raise OSError("temporary cleanup denied")
            return actual_unlink(path, **kwargs)
        with patch("prompt_store.Path.unlink", new=fail_temporary_cleanup):
            saved = self.store.create(draft("已提交"), "model")
            self.store.activate(saved.id)
        self.assertEqual(self.store.resolve(), saved)
        self.assertEqual(self.reload().resolve(), saved)

    def test_concurrent_saves_do_not_lose_versions(self):
        errors = []
        def save(index):
            try: self.store.create(draft(f"版本{index}"), "model")
            except Exception as exc: errors.append(exc)
        threads = [threading.Thread(target=save, args=(i,)) for i in range(8)]
        for thread in threads: thread.start()
        for thread in threads: thread.join()
        self.assertEqual(errors, [])
        self.assertEqual(len(self.reload().versions), 9)

    def test_memory_only_never_discovers_or_creates_files(self):
        missing = self.directory / "never-created"
        store = PromptStore(draft(), "test", missing, memory_only=True)
        candidate = store.create(draft("临时"), "test")
        store.activate(candidate.id)
        self.assertEqual(store.resolve(), candidate)
        self.assertFalse(missing.exists())


if __name__ == "__main__":
    unittest.main()
