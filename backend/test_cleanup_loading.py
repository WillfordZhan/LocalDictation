"""Mac editor artifact admission with inert weights and mocked MLX modules."""
import json
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, Mock, patch

from server import LocalModels


class CleanupLoadingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="cleanup-load-fixture-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.asr = self.root / "asr"
        self.editor = self.root / "editor"
        self.asr.mkdir(); self.editor.mkdir()
        (self.asr / "weights.safetensors").write_bytes(b"inert-asr")
        self.model = Mock()
        self.tokenizer = Mock()
        self.load = Mock(return_value=(self.model, self.tokenizer))
        self.mx = MagicMock()
        modules = patch.dict(sys.modules, {
            "mlx": SimpleNamespace(core=self.mx), "mlx.core": self.mx,
            "mlx_lm": SimpleNamespace(load=self.load),
            "mlx_whisper.transcribe": SimpleNamespace(ModelHolder=SimpleNamespace(get_model=Mock())),
        })
        modules.start(); self.addCleanup(modules.stop)
        self.models = LocalModels(self.asr, self.editor)

    def indexed_weights(self):
        names = ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"]
        for name in names:
            (self.editor / name).write_bytes(b"inert-weight")
        self.write_index({"weight_map": {"layer.one": names[0], "layer.two": names[1]}})
        return names

    def write_index(self, value):
        (self.editor / "model.safetensors.index.json").write_text(json.dumps(value))

    def assert_rejected(self):
        self.load.reset_mock()
        with self.assertLogs("local-dictation", level="ERROR"):
            self.models.load()
        self.assertTrue(self.models.asr_ready)
        self.assertFalse(self.models.cleanup_ready)
        self.assertIsNone(self.models.model)
        self.assertIsNone(self.models.tokenizer)
        self.load.assert_not_called()

    def test_single_file_without_index_remains_supported(self):
        (self.editor / "model.safetensors").write_bytes(b"inert-weight")
        self.models.load()
        self.load.assert_called_once_with(str(self.editor))
        self.assertTrue(self.models.asr_ready and self.models.cleanup_ready)

    def test_complete_sharded_index_loads_without_single_file(self):
        self.indexed_weights()
        self.assertFalse((self.editor / "model.safetensors").exists())
        self.models.load()
        self.load.assert_called_once_with(str(self.editor))
        self.assertTrue(self.models.cleanup_ready)

    def test_cleanup_only_load_does_not_initialize_asr(self):
        self.indexed_weights()
        self.models.load_cleanup()
        self.assertTrue(self.models.cleanup_ready)
        self.assertFalse(self.models.asr_ready)
        self.assertIsNone(self.models.asr_model)
        self.load.assert_called_once_with(str(self.editor))
        self.mx.eval.assert_called_once_with(self.model.parameters())

    def test_temporary_cleanup_release_drops_model_and_private_cache(self):
        self.indexed_weights()
        self.models.load_cleanup()
        self.models._cleanup_prefix_cache = object()
        self.models._cleanup_prefix_key = ("fixture",)
        self.models.last_cleanup_metrics = {"generation_tokens": 1}
        self.models.release_cleanup()
        self.assertFalse(self.models.cleanup_ready)
        self.assertIsNone(self.models.model)
        self.assertIsNone(self.models.tokenizer)
        self.assertIsNone(self.models._cleanup_prefix_cache)
        self.assertIsNone(self.models._cleanup_prefix_key)
        self.assertIsNone(self.models.last_cleanup_metrics)
        self.mx.clear_cache.assert_called_once()

    def test_missing_shard_clears_previously_ready_editor(self):
        names = self.indexed_weights()
        self.models.load()
        self.assertTrue(self.models.cleanup_ready)
        (self.editor / names[1]).unlink()
        self.assert_rejected()

    def test_empty_shard_is_not_a_complete_model(self):
        names = self.indexed_weights()
        (self.editor / names[1]).write_bytes(b"")
        self.assert_rejected()

    def test_arbitrary_shards_without_index_are_rejected(self):
        self.indexed_weights()
        (self.editor / "model.safetensors.index.json").unlink()
        self.assert_rejected()

    def test_unindexed_stale_weights_are_not_loaded(self):
        self.indexed_weights()
        (self.editor / "model.safetensors").write_bytes(b"old-model")
        self.assert_rejected()

    def test_invalid_index_does_not_fall_back_to_single_file(self):
        (self.editor / "model.safetensors").write_bytes(b"inert-weight")
        for value in [[], {}, {"weight_map": {}}, {"weight_map": []},
                      {"weight_map": {"": "model.safetensors"}},
                      {"weight_map": {"layer": None}},
                      {"weight_map": {"layer": "../model.safetensors"}},
                      {"weight_map": {"layer": "/model.safetensors"}},
                      {"weight_map": {"layer": "other.safetensors"}}]:
            with self.subTest(value=value):
                self.write_index(value)
                self.assert_rejected()
        (self.editor / "model.safetensors.index.json").write_text("{broken")
        self.assert_rejected()

    def test_weight_symlink_cannot_borrow_external_file(self):
        names = self.indexed_weights()
        target = self.editor / names[1]
        external = self.root / "external.safetensors"
        external.write_bytes(b"external-weight")
        target.unlink(); target.symlink_to(external)
        self.assert_rejected()

    def test_index_symlink_is_not_followed(self):
        self.indexed_weights()
        index = self.editor / "model.safetensors.index.json"
        external = self.root / "external-index.json"
        index.rename(external); index.symlink_to(external)
        self.assert_rejected()

    def test_load_and_evaluation_failures_do_not_claim_readiness(self):
        self.indexed_weights()
        for phase in ("load", "evaluate"):
            with self.subTest(phase=phase):
                self.load.side_effect = RuntimeError("fixture load failure") if phase == "load" else None
                self.mx.eval.side_effect = [None, RuntimeError("fixture eval failure")] if phase == "evaluate" else None
                with self.assertLogs("local-dictation", level="ERROR"):
                    self.models.load()
                self.assertTrue(self.models.asr_ready)
                self.assertFalse(self.models.cleanup_ready)
                self.assertIsNone(self.models.model)


if __name__ == "__main__":
    unittest.main()
