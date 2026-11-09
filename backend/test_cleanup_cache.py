"""Fixed-prefix reuse and failure boundaries without loading MLX or a model."""
import copy
from dataclasses import replace
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from prompt_store import PromptVersion
from server import (DictationOptions, LocalModels, MAX_CLEANUP_PREFIX_TOKENS,
                    MAX_CLEANUP_PREFIX_BYTES, cleanup_messages)


class Tokenizer:
    def __init__(self, divergent=False, mismatch=False):
        self.divergent = divergent
        self.mismatch = mismatch

    def encode(self, text):
        return list(text.encode())

    def apply_chat_template(self, messages, *, tokenize, add_generation_prompt):
        text = "".join(f"<{m['role']}>{m['content']}</end>" for m in messages)
        if not add_generation_prompt and self.divergent:
            # Like templates that give the last example a special think marker.
            index = text.rfind("<assistant>") + len("<assistant>")
            text = text[:index] + "<think>" + text[index:]
        if not add_generation_prompt and self.mismatch:
            text = "!" + text
        return self.encode(text + ("<assistant>" if add_generation_prompt else ""))


class Cache:
    def __init__(self, nbytes=64):
        self.tokens = []
        self.nbytes = nbytes


class CleanupCacheTests(unittest.TestCase):
    def setUp(self):
        self.models = LocalModels(Path("asr"), Path("editor"))
        self.models.model = object()
        self.models.tokenizer = Tokenizer()
        self.profile = PromptVersion.create({"name": "test", "note": "", "system_prompt": "Keep meaning.",
            "user_prefix": "Edit: ", "examples": [{"source": "uh go", "edited": "go"}]}, "editor")
        self.options = DictationOptions(vocabulary=("PrivateWord",), cleanup_profile=self.profile)
        self.prefills = []
        self.generations = []
        self.fail_prefill = False
        self.fail_generation = False
        self.output_count = 1
        self.output_finish = "stop"
        self.cache_bytes = 64

        def prefill(tokens, model, *, max_tokens, prompt_cache):
            self.assertEqual(max_tokens, 0)
            self.prefills.append(list(tokens))
            if self.fail_prefill:
                raise RuntimeError("no cache support")
            prompt_cache[0].tokens.extend(tokens)
            yield from ()

        def generate(model, tokenizer, *, prompt, max_tokens, sampler, prompt_cache=None):
            actual = (list(prompt_cache[0].tokens) if prompt_cache else []) + list(prompt)
            self.generations.append({"tokens": actual, "max_tokens": max_tokens, "cache": prompt_cache})
            if prompt_cache:
                prompt_cache[0].tokens.extend(prompt)
                prompt_cache[0].tokens.extend(b"private output")
            if self.fail_generation:
                raise RuntimeError("generation failed")
            yield SimpleNamespace(text='{"text":"edited"}', generation_tokens=self.output_count,
                                  finish_reason=self.output_finish)

        mx = SimpleNamespace(array=list)
        self.modules = patch.dict(sys.modules, {
            "mlx": SimpleNamespace(core=mx), "mlx.core": mx,
            "mlx_lm": SimpleNamespace(stream_generate=generate),
            "mlx_lm.generate": SimpleNamespace(generate_step=prefill),
            "mlx_lm.models": SimpleNamespace(),
            "mlx_lm.models.cache": SimpleNamespace(make_prompt_cache=lambda _: [Cache(self.cache_bytes)]),
            "mlx_lm.sample_utils": SimpleNamespace(make_sampler=lambda **_: "greedy"),
        })
        self.modules.start()
        self.addCleanup(self.modules.stop)

    def full_prompt(self, text, options=None):
        return self.models.tokenizer.apply_chat_template(cleanup_messages(text, options or self.options),
                                                        tokenize=True, add_generation_prompt=True)

    def test_reuse_keeps_identical_request_and_only_fixed_state(self):
        for raw in ["first private sentence", "different later sentence"]:
            self.assertEqual(self.models.cleanup(raw, self.options), "edited")
            self.assertEqual(self.generations[-1]["tokens"], self.full_prompt(raw))
        self.assertEqual(len(self.prefills), 1)
        self.assertTrue(self.models.last_cleanup_metrics["cache_hit"])
        self.assertNotIn(b"private sentence", bytes(self.models._cleanup_prefix_cache[0].tokens))
        self.assertNotIn(b"PrivateWord", bytes(self.models._cleanup_prefix_cache[0].tokens))
        self.assertNotIn(b"private output", bytes(self.models._cleanup_prefix_cache[0].tokens))
        self.assertEqual(self.models._cleanup_prefix_cache[0].tokens, self.prefills[0])
        self.assertIsNot(self.generations[-1]["cache"], self.models._cleanup_prefix_cache)

    def test_vocabulary_change_reuses_prefix_without_stale_terms(self):
        self.models.cleanup("text", self.options)
        options = replace(self.options, vocabulary=("ReplacementTerm",))
        self.models.cleanup("text", options)
        self.assertEqual(len(self.prefills), 1)
        self.assertEqual(self.generations[-1]["tokens"], self.full_prompt("text", options))

    def test_confirmed_correction_data_reuses_fixed_cache_without_retaining_mapping(self):
        self.models.cleanup("SalesPrat", self.options)
        options = replace(self.options, corrections=(("SalesPrat", "SalesPart"),))
        self.models.cleanup("SalesPrat", options)
        self.assertEqual(len(self.prefills), 1)
        self.assertEqual(self.generations[-1]["tokens"], self.full_prompt("SalesPrat", options))
        self.assertNotIn(b"SalesPrat", bytes(self.models._cleanup_prefix_cache[0].tokens))
        self.assertNotIn(b"SalesPart", bytes(self.models._cleanup_prefix_cache[0].tokens))

    def test_profile_identity_content_model_and_tokenizer_invalidate(self):
        self.models.cleanup("text", self.options)
        for profile in [replace(self.profile, id="new-version"),
                        replace(self.profile, content_sha256="new-hash")]:
            self.models.cleanup("text", replace(self.options, cleanup_profile=profile))
            self.assertFalse(self.models.last_cleanup_metrics["cache_hit"])
        self.models.model = object()
        self.models.cleanup("text", self.options)
        self.models.tokenizer = Tokenizer()
        self.models.cleanup("text", self.options)
        self.assertEqual(len(self.prefills), 5)

    def test_template_last_example_difference_uses_safe_common_prefix(self):
        self.models.tokenizer = Tokenizer(divergent=True)
        self.models.cleanup("private", self.options)
        self.assertEqual(self.generations[-1]["tokens"], self.full_prompt("private"))
        self.assertNotIn(b"<think>", bytes(self.prefills[0]))
        self.assertGreater(self.models.last_cleanup_metrics["cached_tokens"], 0)

    def test_unmatched_template_uses_full_prompt(self):
        self.models.tokenizer = Tokenizer(mismatch=True)
        self.models.cleanup("private", self.options)
        self.assertEqual(len(self.prefills), 0)
        self.assertIsNone(self.models._cleanup_prefix_cache)
        self.assertEqual(self.generations[-1]["tokens"], self.full_prompt("private"))

    def test_cache_failure_falls_back_before_single_generation(self):
        self.fail_prefill = True
        self.assertEqual(self.models.cleanup("private", self.options), "edited")
        self.assertIsNone(self.models._cleanup_prefix_cache)
        self.assertEqual(len(self.generations), 1)
        self.assertEqual(self.generations[0]["tokens"], self.full_prompt("private"))

    def test_generation_failure_does_not_retry_and_clears_cache(self):
        self.fail_generation = True
        with self.assertRaisesRegex(RuntimeError, "generation failed"):
            self.models.cleanup("private", self.options)
        self.assertEqual(len(self.generations), 1)
        self.assertIsNone(self.models._cleanup_prefix_cache)
        self.assertIsNone(self.models.last_cleanup_metrics)

    def test_budget_and_truncation_policy_unchanged(self):
        self.models.cleanup("x" * 100, self.options)
        self.assertEqual(self.generations[-1]["max_tokens"], 264)
        self.models.cleanup("x" * 3000, self.options)
        self.assertEqual(self.generations[-1]["max_tokens"], 4096)
        self.output_finish = "length"
        with self.assertRaisesRegex(RuntimeError, "completion budget"):
            self.models.cleanup("private", self.options)
        self.assertIsNone(self.models._cleanup_prefix_cache)

    def test_prefill_uses_same_deadline_and_never_generates_after_expiry(self):
        with patch("server.time.monotonic", side_effect=[10.0, 40.01]):
            with self.assertRaises(TimeoutError):
                self.models.cleanup("private", self.options)
        self.assertEqual(len(self.generations), 0)
        self.assertIsNone(self.models._cleanup_prefix_cache)

    def test_long_prompt_only_limits_cache_not_request(self):
        profile = replace(self.profile, system_prompt="x" * (MAX_CLEANUP_PREFIX_TOKENS + 100))
        options = replace(self.options, cleanup_profile=profile)
        self.models.cleanup("private", options)
        self.assertEqual(len(self.prefills[0]), MAX_CLEANUP_PREFIX_TOKENS)
        self.assertEqual(self.generations[-1]["tokens"], self.full_prompt("private", options))

    def test_oversized_cache_is_used_once_but_not_retained(self):
        self.cache_bytes = MAX_CLEANUP_PREFIX_BYTES + 1
        self.models.cleanup("private", self.options)
        self.assertIsNone(self.models._cleanup_prefix_cache)
        self.assertEqual(self.generations[-1]["tokens"], self.full_prompt("private"))
        self.models.cleanup("next", self.options)
        self.assertEqual(len(self.prefills), 2)


if __name__ == "__main__":
    unittest.main()
