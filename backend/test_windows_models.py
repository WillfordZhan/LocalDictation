"""Windows adapter boundaries without downloading weights or importing MLX."""
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from server import DictationOptions, Recording, RequestError, light_edit
from windows_models import WindowsModels, FINAL_TEXT_SCHEMA


class WindowsModelsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.models = WindowsModels(Path(self.temp.name), Path(self.temp.name) / "llama-server.exe")
        self.addCleanup(self.models.close)
        self.recording = Recording((b"\x00\x20" * 16 + b"\x00\xe0" * 16) * 500, 16000, 1, 1)

    def test_silence_does_not_call_asr(self):
        self.models.asr_model = Mock()
        self.assertEqual(self.models.transcribe_segment(Recording(b"\0\0" * 16000, 16000, 1, 1),
                                                       DictationOptions()), ("", 0, 0))
        self.models.asr_model.transcribe.assert_not_called()

    def test_asr_uses_local_cpu_options_and_counts_returned_tokens(self):
        asr = self.models.asr_model = Mock()
        asr.transcribe.return_value = (iter([SimpleNamespace(text="测试", tokens=[1, 2]),
                                            SimpleNamespace(text="完成。", tokens=[3, 4, 5])]), None)
        result = self.models.transcribe_segment(self.recording, DictationOptions(vocabulary=("FixtureTerm",)))
        self.assertEqual(result, ("测试完成。", 5, 1))
        kwargs = asr.transcribe.call_args.kwargs
        self.assertEqual(kwargs["language"], "zh")
        self.assertEqual(kwargs["hotwords"], "FixtureTerm")
        self.assertFalse(kwargs["condition_on_previous_text"])
        self.assertEqual(kwargs["temperature"], 0)
        self.assertNotIn("max_new_tokens", kwargs)

    def test_dictionary_echo_gets_one_audio_recheck_without_hotwords(self):
        asr = self.models.asr_model = Mock()
        asr.transcribe.side_effect = [
            (iter([SimpleNamespace(text="FixtureOne, FixtureTwo, FixtureThree", tokens=[1, 2])]), None),
            (iter([SimpleNamespace(text="实际声音。", tokens=[3, 4])]), None),
        ]
        result = self.models.transcribe_segment(self.recording,
            DictationOptions(vocabulary=("FixtureOne", "FixtureTwo", "FixtureThree")))
        self.assertEqual(result, ("实际声音。", 4, 2))
        self.assertIsNone(asr.transcribe.call_args.kwargs["hotwords"])
        self.assertEqual(asr.transcribe.call_count, 2)

    def test_session_budget_exhaustion_never_returns_partial_text(self):
        self.models.asr_model = Mock()
        self.models.asr_model.transcribe.return_value = (
            iter([SimpleNamespace(text="不完整文字", tokens=[1, 2, 3])]), None)
        with self.assertRaises(RequestError):
            self.models.transcribe_segment(self.recording, DictationOptions(), max_tokens=3)

    def test_cleanup_uses_shared_contract_and_returns_only_decoded_text(self):
        self.models.cleanup_ready = True
        self.models._request = Mock(return_value={"choices": [{"finish_reason": "stop",
            "message": {"content": json.dumps({"text": "正文。\n\n保留语气。"})}}],
            "usage": {"completion_tokens": 12}})
        self.assertEqual(self.models.cleanup("嗯，正文，保留语气。"), "正文。\n\n保留语气。")
        route, body = self.models._request.call_args.args
        self.assertEqual(route, "/v1/chat/completions")
        self.assertEqual(body["response_format"]["schema"], FINAL_TEXT_SCHEMA)
        self.assertEqual(body["temperature"], 0)
        self.models._request.assert_called_once()

    def test_malformed_or_truncated_cleanup_falls_back_without_retry(self):
        raw = "先做列表，再看看时间轴。"
        for response in (
            {"choices": [{"finish_reason": "length", "message": {"content": '{"text":"部分"}'}}]},
            {"choices": [{"finish_reason": "stop", "message": {"content": "修正说明：未知。"}}]},
            {"choices": []},
        ):
            with self.subTest(response=response), self.assertLogs("local-dictation", level="ERROR"):
                self.models.cleanup_ready = True
                self.models._request = Mock(return_value=response)
                text, applied, warning = light_edit(raw, self.models.cleanup)
                self.assertEqual(text, raw)
                self.assertFalse(applied)
                self.assertTrue(warning)
                self.models._request.assert_called_once()

    def test_timeout_preserves_original_and_does_not_retry(self):
        self.models.cleanup_ready = True
        self.models._request = Mock(side_effect=TimeoutError("no response"))
        with self.assertLogs("local-dictation", level="ERROR"):
            text, applied, warning = light_edit("先别发布。", self.models.cleanup)
        self.assertEqual(text, "先别发布。")
        self.assertFalse(applied)
        self.assertTrue(warning)
        self.models._request.assert_called_once()

    def test_close_stops_only_owned_child_and_is_idempotent(self):
        child = self.models._process = Mock()
        child.poll.return_value = None
        self.models.close()
        self.models.close()
        child.terminate.assert_called_once()
        child.wait.assert_called_once()
        self.assertFalse(self.models.cleanup_ready)
        with self.assertRaises(RuntimeError):
            self.models.cleanup("do not run")


if __name__ == "__main__":
    unittest.main()
