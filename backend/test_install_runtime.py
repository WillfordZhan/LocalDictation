"""Run the real installer against a temporary venv and tiny inert model files.

MLX modules here are source stubs. This test never imports the installed GPU
packages, invokes a package manager, downloads models or opens user Runtime.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import venv


BACKEND = Path(__file__).resolve().parent


class RuntimeInstallTests(unittest.TestCase):
    def test_staged_backend_includes_prompt_resources_and_remains_importable(self):
        self.run_install("whisper")

    def test_qwen_install_does_not_require_or_copy_whisper(self):
        self.run_install("qwen")

    def test_selected_9b_installs_shards_without_copying_default_4b(self):
        self.run_install("qwen", cleanup_model="cleanup-9b")

    def test_invalid_or_empty_editor_selection_never_changes_history(self):
        for value in ("", "unknown", "qwen"):
            with self.subTest(value=value), tempfile.TemporaryDirectory(prefix="dictation-invalid-model-") as temporary:
                root = Path(temporary); runtime = root / "Runtime"; runtime.mkdir()
                history = root / "history.json"; history.write_bytes(b"keep")
                selection = runtime / "cleanup-model"; selection.write_text(value)
                env = {k: v for k, v in os.environ.items() if k != "LOCAL_DICTATION_CLEANUP_MODEL"}
                env["LOCAL_DICTATION_RUNTIME_DIR"] = str(runtime)
                result = subprocess.run(["/bin/bash", str(BACKEND / "install_runtime.sh")],
                    env=env, text=True, capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("不支持的润色模型", result.stderr)
                self.assertEqual(selection.read_text(), value)
                self.assertEqual(history.read_bytes(), b"keep")
                self.assertFalse((runtime / ".install-lock").exists())

    def test_public_source_without_local_readme_or_validation_installs(self):
        # Reproduce a clean published source tree instead of inheriting ignored
        # files from the developer's checkout. No models or user data are used.
        with tempfile.TemporaryDirectory(prefix="dictation-public-source-") as temporary:
            public_backend = Path(temporary) / "backend"
            public_backend.mkdir()
            for source in BACKEND.iterdir():
                if source.is_file() and (source.suffix in (".py", ".sh") or source.name in
                                         ("requirements.txt", "model-manifest.json", "prompt-imports.json")):
                    shutil.copyfile(source, public_backend / source.name)
            self.assertFalse((public_backend / "README.md").exists())
            self.assertFalse((public_backend / "validation.json").exists())
            self.run_install("qwen", backend=public_backend)

    def run_install(self, asr_backend, backend=BACKEND, cleanup_model="cleanup"):
        with tempfile.TemporaryDirectory(prefix="dictation-install-test-") as temporary:
            root = Path(temporary)
            source = root / "source"
            environment = source / "local-dictation-venv"
            venv.EnvBuilder(with_pip=False, symlinks=True).create(environment)
            site = environment / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages"
            for package, version in (("mlx", "0.32.4"), ("mlx_whisper", "0.4.3"), ("mlx_lm", "0.32.2"), ("mlx_audio", "0.6.3")):
                module = site / package
                module.mkdir(parents=True)
                (module / "__init__.py").write_text("# Inert installer test module.\n")
                if package == "mlx": (module / "core.py").write_text("# No GPU code.\n")
                if package == "mlx_audio":
                    asr = module / "stt/models/qwen3_asr"
                    asr.mkdir(parents=True)
                    (asr / "__init__.py").write_text("class Qwen3ASRModel: pass\n")
                info = site / f"{package}-{version}.dist-info"
                info.mkdir()
                (info / "METADATA").write_text(f"Metadata-Version: 2.1\nName: {package.replace('_', '-')}\nVersion: {version}\n")
            catalog = {m["id"]: m for m in json.loads((backend / "model-manifest.json").read_text())["models"]}
            model_files = {catalog[cleanup_model]["directory"]: tuple(f["path"] for f in catalog[cleanup_model]["files"])}
            if asr_backend == "whisper":
                model_files[catalog["whisper"]["directory"]] = tuple(f["path"] for f in catalog["whisper"]["files"])
            else:
                model_files["Qwen3-ASR-1.7B-8bit"] = ("model.safetensors", "config.json", "tokenizer_config.json", "vocab.json",
                    "merges.txt", "preprocessor_config.json", "chat_template.json")
            for model, names in model_files.items():
                directory = source / "models" / model
                directory.mkdir(parents=True)
                for name in names: (directory / name).write_bytes(b"{}" if name.endswith(".json") else b"test-weight")
                if model == "Qwen3-ASR-1.7B-8bit":
                    (directory / "config.json").write_text(json.dumps({"model_type": "qwen3_asr", "quantization": {"bits": 8}}))
            runtime = root / "Application Support" / "Runtime"
            history = runtime.parent / "history.json"
            history.parent.mkdir(parents=True)
            history.write_bytes(b"private history sentinel")
            result = subprocess.run(["/bin/bash", str(backend / "install_runtime.sh")],
                env={**os.environ, "LOCAL_DICTATION_SOURCE_WORK_DIR": str(source),
                     "LOCAL_DICTATION_RUNTIME_DIR": str(runtime), "LOCAL_DICTATION_ASR_BACKEND": asr_backend,
                     "LOCAL_DICTATION_CLEANUP_MODEL": cleanup_model},
                text=True, capture_output=True, timeout=45)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for name in ("server.py", "streaming.py", "prompt_store.py", "prompt-imports.json", "test_prompt_store.py", "model_artifacts.py", "model-manifest.json"):
                self.assertEqual((runtime / "backend" / name).read_bytes(), (backend / name).read_bytes())
            self.assertFalse((runtime / "backend/validation.json").exists())
            self.assertIn("后端资源导入检查通过", result.stdout)
            self.assertEqual(history.read_bytes(), b"private history sentinel")
            self.assertFalse((runtime.parent / "cleanup-prompts.json").exists())
            self.assertEqual((runtime / "asr-backend").read_text().strip(), asr_backend)
            self.assertEqual((runtime / "cleanup-model").read_text().strip(), cleanup_model)
            self.assertTrue((runtime / "models" / catalog[cleanup_model]["directory"]).is_dir())
            for other in ("cleanup", "cleanup-9b"):
                if other != cleanup_model:
                    self.assertFalse((runtime / "models" / catalog[other]["directory"]).exists())
            if asr_backend == "qwen": self.assertFalse((runtime / "models/whisper-large-v3-turbo").exists())
            self.assertFalse((runtime / ".install-lock").exists())
            verified = subprocess.run([str(runtime / "local-dictation-venv/bin/python"), "-B", "-c",
                "import server, prompt_store; print(server.default_prompt_draft()['name'])"],
                cwd=runtime / "backend", text=True, capture_output=True, timeout=10)
            self.assertEqual(verified.returncode, 0, verified.stderr)


if __name__ == "__main__":
    unittest.main()
