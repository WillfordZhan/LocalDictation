"""Final-text protocol tests; no local model, personal text or clipboard access."""
import hashlib
import http.client
from http.server import ThreadingHTTPServer
import io
import json
from pathlib import Path
import sys
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import uuid
import wave

from prompt_store import PromptStoreError, PromptVersion
from server import (CLEANUP_OUTPUT_CONTRACT, MAX_CLEANUP_COMPARISON_CHARACTERS,
                    CleanupCompletionLimitError, CleanupEmptyOutputError, CleanupOutputError,
                    DictationOptions, DictationService, LocalModels, cleanup_change_outcome,
                    cleanup_messages, edit_with_outcome, light_edit, make_handler, parse_cleanup_output)


def model_fixture():
    models = LocalModels(Path("fixture-asr"), Path("fixture-editor"))
    models.model = object()
    models.tokenizer = SimpleNamespace(
        encode=lambda text: list(text),
        apply_chat_template=lambda *args, **kwargs: [1, 2, 3])
    # Cache implementation is covered separately. This fixture exercises the
    # actual generated-output adapter and shared fallback without GPU imports.
    models._cleanup_prompt = Mock(return_value=([1, 2, 3], None, False, 0))
    models.asr_ready = models.cleanup_ready = True
    return models


def response_chunks(output):
    split = len(output) // 2
    return iter([SimpleNamespace(text=part, generation_tokens=index + 1,
                                 finish_reason="stop" if index else None)
                 for index, part in enumerate((output[:split], output[split:]))])


def inference_modules(generator):
    return patch.dict(sys.modules, {
        "mlx_lm": SimpleNamespace(stream_generate=generator),
        "mlx_lm.sample_utils": SimpleNamespace(make_sampler=lambda **kwargs: None),
    })


class CleanupContractTests(unittest.TestCase):
    def test_valid_unicode_escapes_and_paragraphs_are_decoded_without_rewriting(self):
        body = '保留 "text" 和路径 C:\\data\\note.txt。\n\n1. 检查 API。\n2. 保留 `x < 2`。😀'
        for ascii_only in (False, True):
            with self.subTest(ensure_ascii=ascii_only):
                wire = json.dumps({"text": body}, ensure_ascii=ascii_only)
                self.assertEqual(parse_cleanup_output(" \n" + wire + "\t"), body)

    def test_only_outer_body_whitespace_is_trimmed(self):
        self.assertEqual(parse_cleanup_output('{"text":"  第一段。\\n\\n第二段。  "}'),
                         "第一段。\n\n第二段。")

    def test_literal_editorial_labels_are_valid_user_content(self):
        body = '请保留标题“修正说明”和“最终整理正文”。注：这是用户原话，不要删掉。'
        self.assertEqual(parse_cleanup_output(json.dumps({"text": body}, ensure_ascii=False)), body)

    def test_invalid_wire_shapes_are_rejected_without_extracting_a_substring(self):
        invalid = (
            "", "正文。", '说明：{“text”:“正文”}',
            '```json\n{"text":"正文"}\n```',
            '{"text":"正文"}\n修正说明：这是附注。',
            '{"text":"初稿"}{"text":"终稿"}',
            '{"text":"正文", "notes":"编辑过程"}',
            '{"text":"初稿", "text":"终稿"}',
            '{"text":"初稿", "te\\u0078t":"终稿"}',
            '{}', '[]', '[{"text":"正文"}]', '"正文"', 'null',
            '{"text":null}', '{"text":false}', '{"text":123}',
            '{"text":["正文"]}', '{"text":{"value":"正文"}}',
            '{"text":""}', '{"text":" \\n\\t"}', '{"text":"未完成',
            '{"text":"\\ud800"}', '{"text":"\\udc00"}',
        )
        for wire in invalid:
            with self.subTest(wire=repr(wire)):
                with self.assertRaises(ValueError):
                    parse_cleanup_output(wire)

    def test_contract_is_rendered_without_mutating_saved_style_or_examples(self):
        profile = PromptVersion.create({
            "name": "保留个人表达", "note": "fixture", "system_prompt": "只输出正文，保留语气。",
            "user_prefix": "请编辑：", "examples": [{"source": "嗯，继续。", "edited": "继续。"}],
        }, "fixture-editor")
        previous = (profile.system_prompt, profile.user_prefix, profile.examples, profile.content_sha256)
        messages = cleanup_messages("先暂时保留。", DictationOptions(cleanup_profile=profile))
        self.assertEqual(messages[0]["content"], profile.system_prompt + "\n\n" + CLEANUP_OUTPUT_CONTRACT)
        assistant = [message["content"] for message in messages if message["role"] == "assistant"]
        self.assertEqual([parse_cleanup_output(value) for value in assistant], ["继续。"])
        self.assertEqual((profile.system_prompt, profile.user_prefix, profile.examples, profile.content_sha256), previous)
        self.assertEqual(json.loads(messages[-1]["content"][len(profile.user_prefix):]),
                         {"transcript": "先暂时保留。", "vocabulary": []})

    def test_actual_model_adapter_returns_only_decoded_body_from_streamed_chunks(self):
        models = model_fixture()
        body = '先完成左边的表格。\n\n右侧布局我还要再看看，暂时不要发布。'
        generator = Mock(side_effect=lambda *args, **kwargs: response_chunks(json.dumps({"text": body})))
        with inference_modules(generator):
            text, applied, warning = light_edit("嗯，先完成左边的表格，右侧还要看看，先别发布。", models.cleanup)
        self.assertEqual((text, applied, warning), (body, True, None))
        generator.assert_called_once()

    def test_invalid_generation_falls_back_once_and_does_not_log_private_output(self):
        raw = "先做列表，时间轴以后再决定。"
        private_marker = "PRIVATE_MODEL_RESPONSE_SENTINEL"
        invalid = private_marker + '\n修正说明：无法判断。\n最终整理正文：先做列表。'
        generator = Mock(side_effect=lambda *args, **kwargs: response_chunks(invalid))
        with inference_modules(generator), self.assertLogs("local-dictation", level="ERROR") as logs:
            text, applied, warning = light_edit(raw, model_fixture().cleanup)
        self.assertEqual(text, raw)
        self.assertFalse(applied)
        self.assertTrue(warning)
        self.assertNotIn(private_marker, "\n".join(logs.output))
        generator.assert_called_once()


class CleanupOutcomeTests(unittest.TestCase):
    long_source = (
        "我们先确认各个房间的照明和插座，再核对厨房设备的尺寸以及预留位置。"
        "客厅的灯光需要支持调节亮度，卧室则应避免光线直射床头。"
        "这些事项本周只做现场测量，还没有确定最终的采购清单。"
        "如果厨房的管线需要重新布置，请先提供估价，不要直接施工。"
        "另外，入户门的颜色还没有决定，我们会在看过样板以后再讨论。"
    )

    def test_identical_output_is_completed_but_neutrally_reported_even_when_short(self):
        for raw, edited in (("可以。", "可以。"), ("  暂时不要删除。\n", "暂时不要删除。")):
            generator = Mock(return_value=edited)
            text, applied, warning, outcome = edit_with_outcome(raw, generator)
            self.assertEqual(text, edited)
            self.assertTrue(applied)
            self.assertIsNone(warning)
            self.assertEqual(outcome, {"status": "unchanged", "reason": "identical"})
            generator.assert_called_once_with(raw)

    def test_near_identical_long_output_is_a_notice_not_failure_or_replacement(self):
        # A one-word change may be the only necessary edit. The heuristic must
        # never discard it, claim semantic failure or automatically retry.
        edited = self.long_source.replace("本周", "下周")
        generator = Mock(return_value=edited)
        text, applied, warning, outcome = edit_with_outcome(self.long_source, generator)
        self.assertEqual(text, edited)
        self.assertTrue(applied)
        self.assertIsNone(warning)
        self.assertEqual(outcome, {"status": "suspected_insufficient", "reason": "near_identical"})
        generator.assert_called_once()

    def test_whitespace_changes_do_not_hide_a_near_identical_long_output(self):
        self.assertEqual(cleanup_change_outcome(self.long_source, "\n".join(self.long_source.split("。"))),
                         {"status": "suspected_insufficient", "reason": "near_identical"})

    def test_short_changed_text_and_substantial_long_edit_have_no_suspicion(self):
        cases = (("明天三点开会。", "明天四点开会。"),
                 (self.long_source, "先测量房间和厨房，再确认灯光、设备和管线方案。"))
        for raw, edited in cases:
            self.assertEqual(cleanup_change_outcome(raw, edited),
                             {"status": "applied", "reason": "changed"})

    def test_similarity_cost_is_bounded_without_truncating_returned_text(self):
        raw = "文" * (MAX_CLEANUP_COMPARISON_CHARACTERS + 1)
        edited = raw + "末尾仍须保留。"
        with patch("server.SequenceMatcher", side_effect=AssertionError("oversized diff")):
            text, applied, _, outcome = edit_with_outcome(raw, lambda _: edited)
            self.assertEqual(text, edited)
            self.assertTrue(applied)
            self.assertEqual(outcome["status"], "applied")
            self.assertEqual(cleanup_change_outcome(raw, raw)["status"], "unchanged")

    def test_common_characters_are_not_treated_as_noise_in_near_copy_detection(self):
        raw = "这段内容仍然需要保留，只有最后的时间需要调整。" * 20
        edited = raw[:-3] + "确认。"
        self.assertEqual(cleanup_change_outcome(raw, edited)["status"], "suspected_insufficient")

    def test_dense_repetition_cannot_force_expensive_diff_or_discard_output(self):
        raw = "文" * 4096
        edited = "甲" + raw[1:]
        with patch("server.SequenceMatcher", side_effect=AssertionError("dense comparison")):
            text, applied, _, outcome = edit_with_outcome(raw, lambda _: edited)
        self.assertEqual(text, edited)
        self.assertTrue(applied)
        self.assertEqual(outcome["status"], "applied")

    def test_empty_transcript_is_skipped_without_model_request(self):
        generate = Mock()
        self.assertEqual(edit_with_outcome(" \n ", generate),
                         ("", False, None, {"status": "skipped", "reason": "empty_transcript"}))
        generate.assert_not_called()

    def test_failures_preserve_exact_raw_and_only_expose_categories_and_types(self):
        private = "PRIVATE_EXCEPTION_TRANSCRIPT_SENTINEL"
        errors = ((TimeoutError(private), "timeout"),
                  (CleanupCompletionLimitError(private), "completion_limit"),
                  (CleanupOutputError(private), "invalid_output"),
                  (CleanupEmptyOutputError(private), "empty_output"),
                  (MemoryError(private), "inference_error"))
        raw = "  先不要发布，确认以后再说。\n"
        for error, reason in errors:
            with self.subTest(reason=reason), self.assertLogs("local-dictation", level="ERROR") as logs:
                generate = Mock(side_effect=error)
                text, applied, warning, outcome = edit_with_outcome(raw, generate)
            self.assertEqual(text, raw)
            self.assertFalse(applied)
            self.assertTrue(warning)
            self.assertEqual(outcome, {"status": "failed", "reason": reason,
                                       "error_type": type(error).__name__})
            self.assertNotIn(private, "\n".join(logs.output))
            generate.assert_called_once_with(raw)

    def test_actual_adapter_distinguishes_timeout_limit_empty_and_invalid_output(self):
        cases = (("not JSON", None, None, "invalid_output", "CleanupOutputError"),
                 ('{"text":""}', None, None, "empty_output", "CleanupEmptyOutputError"),
                 ("", None, None, "empty_output", "CleanupEmptyOutputError"),
                 ('{"text":"尚未完成"}', "length", None, "completion_limit", "CleanupCompletionLimitError"),
                 ('{"text":"尚未完成"}', None, [10, 10, 41], "timeout", "TimeoutError"))
        for output, finish, times, reason, error_type in cases:
            with self.subTest(reason=reason, output=output):
                response = SimpleNamespace(text=output, generation_tokens=1, finish_reason=finish)
                generator = Mock(side_effect=lambda *args, **kwargs: iter([response]))
                model = model_fixture()
                timing = patch("server.time.monotonic", side_effect=times) if times else patch("server.time.monotonic", return_value=10)
                with inference_modules(generator), timing:
                    text, applied, _, outcome = edit_with_outcome("检查灯光。", model.cleanup)
                self.assertEqual(text, "检查灯光。")
                self.assertFalse(applied)
                self.assertEqual(outcome, {"status": "failed", "reason": reason, "error_type": error_type})
                generator.assert_called_once()

    def test_request_log_proves_selected_profile_without_logging_private_content(self):
        private = "PRIVATE_PROMPT_AND_TRANSCRIPT_SENTINEL"
        profile = PromptVersion.create({"name": "fixture", "note": "", "system_prompt": private,
            "user_prefix": "请编辑：", "examples": []}, "fixture-editor")
        options = DictationOptions(cleanup_profile=profile)
        model = model_fixture()
        generator = Mock(side_effect=lambda *args, **kwargs: response_chunks('{"text":"请检查。"}'))
        with inference_modules(generator), self.assertLogs("local-dictation", level="INFO") as logs:
            model.cleanup(private, options)
        logged = "\n".join(logs.output)
        system_hash = hashlib.sha256((private + "\n\n" + CLEANUP_OUTPUT_CONTRACT).encode()).hexdigest()
        for expected in ("model_id=fixture-editor", "prompt_version=" + profile.id,
                         "profile_sha256=" + profile.content_sha256, "system_sha256=" + system_hash,
                         "messages=2", "input_chars=" + str(len(private)), "prompt_tokens=3"):
            self.assertIn(expected, logged)
        self.assertNotIn(private, logged)
        generator.assert_called_once()


class CleanupContractHTTPTests(unittest.TestCase):
    def setUp(self):
        self.raw = "嗯，任务列表先保留，时间轴还没决定。"
        self.body = "任务列表先保留，时间轴还没决定。"
        self.output = json.dumps({"text": self.body}, ensure_ascii=False)
        self.models = model_fixture()
        self.models.transcribe = Mock(return_value=self.raw)
        self.models.transcribe_segment = Mock(return_value=(self.raw, 4))
        self.generator = Mock(side_effect=lambda *args, **kwargs: response_chunks(self.output))
        self.module_patch = inference_modules(self.generator)
        self.module_patch.start()
        self.addCleanup(self.module_patch.stop)
        self.service = DictationService(self.models, memory_only_prompts=True)
        self.service.load_complete = True
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(self.service))
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={"poll_interval": .01}, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.service.streams.close()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.service.worker.shutdown(wait=True)

    def request(self, path, payload, headers=None):
        headers = dict(headers or {})
        if isinstance(payload, dict):
            payload = json.dumps(payload).encode()
            headers.setdefault("Content-Type", "application/json")
        client = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        try:
            client.request("POST", path, payload, headers)
            response = client.getresponse()
            return response.status, json.loads(response.read())
        finally:
            client.close()

    def test_outcome_contract_is_shared_by_recording_stream_and_reprocess(self):
        long_raw = CleanupOutcomeTests.long_source
        cases = ((self.raw, json.dumps({"text": self.body}), "applied", "changed", True),
                 (self.raw, json.dumps({"text": self.raw}), "unchanged", "identical", True),
                 (long_raw, json.dumps({"text": long_raw.replace("本周", "下周")}),
                  "suspected_insufficient", "near_identical", True),
                 (self.raw, "not JSON", "failed", "invalid_output", False),
                 (self.raw, '{"text":""}', "failed", "empty_output", False))
        for route in ("recording", "stream", "history"):
            for raw, wire, outcome, reason, applied in cases:
                with self.subTest(route=route, outcome=outcome, reason=reason):
                    self.raw = raw; self.output = wire
                    self.models.transcribe.return_value = raw
                    self.models.transcribe_segment.return_value = (raw, 4)
                    before = self.generator.call_count
                    status, result = self.complete(route)
                    self.assertEqual(status, 200, result)
                    self.assertEqual(result["cleanup_outcome"]["status"], outcome)
                    self.assertEqual(result["cleanup_outcome"]["reason"], reason)
                    self.assertEqual(result["cleanup_applied"], applied)
                    self.assertEqual(result["raw_text"], raw)
                    self.assertEqual(result["text"], json.loads(wire)["text"] if applied else raw)
                    self.assertEqual(self.generator.call_count, before + 1)
                    if outcome == "failed":
                        self.assertTrue(result["warning"])
                        self.assertIn("error_type", result["cleanup_outcome"])
                    else:
                        self.assertNotIn("warning", result)
                        self.assertNotIn("error_type", result["cleanup_outcome"])

    def test_complete_reports_disabled_unavailable_rules_model_and_empty_without_inference(self):
        cases = ((self.raw, DictationOptions(cleanup=False), True, "skipped", "disabled"),
                 (self.raw, DictationOptions(prompt_snapshot_error="规则不可用",
                                            prompt_snapshot_error_type="PromptStoreError"),
                  True, "failed", "prompt_unavailable"),
                 (self.raw, DictationOptions(), False, "failed", "model_unavailable"),
                 ("", DictationOptions(), True, "skipped", "empty_transcript"))
        for raw, options, ready, status, reason in cases:
            with self.subTest(reason=reason):
                self.models.cleanup_ready = ready
                result = self.service._complete(raw, 1, 0.1, options)
                self.assertEqual(result["cleanup_outcome"]["status"], status)
                self.assertEqual(result["cleanup_outcome"]["reason"], reason)
                self.assertFalse(result["cleanup_applied"])
                self.assertEqual(result["text"], raw)
                if reason == "prompt_unavailable":
                    self.assertEqual(result["cleanup_outcome"]["error_type"], "PromptStoreError")
        self.generator.assert_not_called()

    def test_prompt_capture_failure_keeps_error_type_and_explicit_retry_recaptures(self):
        with patch.object(self.service.prompts, "resolve", side_effect=PromptStoreError("规则读取失败")):
            options = self.service.capture_prompt(DictationOptions())
        result = self.service._complete(self.raw, 1, 0.1, options)
        self.assertEqual(result["cleanup_outcome"], {"status": "failed", "reason": "prompt_unavailable",
                                                    "error_type": "PromptStoreError"})
        self.generator.assert_not_called()
        result = self.service.reprocess(self.raw, options, self.service.prompts.active_version_id)
        self.assertEqual(result["cleanup_outcome"], {"status": "applied", "reason": "changed"})
        self.assertTrue(result["cleanup_applied"])
        self.assertNotIn("warning", result)
        self.generator.assert_called_once()

    def complete(self, route):
        if route == "history":
            return self.request("/cleanup/reprocess", {"raw_text": self.raw}, {
                "X-Cleanup-Prompt-Version": self.service.prompts.active_version_id})
        pcm = b"\x01\x00" * 1600
        if route == "stream":
            session = str(uuid.uuid4())
            status, value = self.request("/stream/start", {"session_id": session})
            self.assertEqual(status, 200, value)
            status, value = self.request(f"/stream/{session}/audio", pcm, {
                "Content-Type": "application/octet-stream", "X-Audio-Offset": "0"})
            self.assertEqual(status, 200, value)
            return self.request(f"/stream/{session}/finish", {"total_samples": 1600})
        wav = io.BytesIO()
        with wave.open(wav, "wb") as recording:
            recording.setnchannels(1)
            recording.setsampwidth(2)
            recording.setframerate(16000)
            recording.writeframes(pcm)
        return self.request("/dictate", wav.getvalue(), {"Content-Type": "audio/wav"})

    def test_all_delivery_routes_expose_only_body_and_preserve_raw_and_profile(self):
        for route in ("recording", "history", "stream"):
            with self.subTest(route=route):
                self.generator.reset_mock()
                status, result = self.complete(route)
                self.assertEqual(status, 200, result)
                self.assertEqual(result["text"], self.body)
                self.assertEqual(result["raw_text"], self.raw)
                self.assertTrue(result["cleanup_applied"])
                self.assertEqual(result["cleanup_profile"]["version_id"], self.service.prompts.active_version_id)
                self.assertNotIn("warning", result)
                self.generator.assert_called_once()

    def test_all_delivery_routes_fall_back_without_returning_meta_response(self):
        self.output = "初稿：列表保留。\n修正说明：以后再判断。\n最终整理正文：列表保留。"
        for route in ("recording", "history", "stream"):
            with self.subTest(route=route), self.assertLogs("local-dictation", level="ERROR"):
                self.generator.reset_mock()
                status, result = self.complete(route)
                self.assertEqual(status, 200, result)
                self.assertEqual(result["text"], self.raw)
                self.assertEqual(result["raw_text"], self.raw)
                self.assertFalse(result["cleanup_applied"])
                self.assertTrue(result["warning"])
                self.generator.assert_called_once()


if __name__ == "__main__":
    unittest.main()
