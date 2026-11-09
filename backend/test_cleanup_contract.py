"""Final-text protocol tests; no local model, personal text or clipboard access."""
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

from prompt_store import PromptVersion
from server import (CLEANUP_OUTPUT_CONTRACT, DictationOptions, DictationService,
                    LocalModels, cleanup_messages, light_edit, make_handler,
                    parse_cleanup_output)


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
