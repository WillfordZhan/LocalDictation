#!/bin/bash
# Run from Terminal after quitting LocalDictation and stopping its backend.
# Copy existing assets only; never download, stop processes, or delete models.
set -euo pipefail
umask 077

BACKEND_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
WORKSPACE_DIR="$(cd -- "$BACKEND_DIR/../../.." && pwd)"
SOURCE_WORK="${LOCAL_DICTATION_SOURCE_WORK_DIR:-$WORKSPACE_DIR/work}"
SOURCE_VENV="${LOCAL_DICTATION_SOURCE_VENV:-$SOURCE_WORK/local-dictation-venv}"
SOURCE_QWEN="${LOCAL_DICTATION_SOURCE_ASR_MODEL:-$SOURCE_WORK/models/Qwen3-ASR-1.7B-8bit}"
RUNTIME_DIR="${LOCAL_DICTATION_RUNTIME_DIR:-$HOME/Library/Application Support/LocalDictation/Runtime}"
LAST_STAGE=""
INSTALL_COMPLETE=false
PUBLISHED_TARGETS=()
PUBLISHED_STAGES=()
PUBLISHED_BACKUPS=()

fail() { echo "安装失败：$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail "此安装器用于 macOS。"
[[ ! -L "$RUNTIME_DIR" ]] || fail "Runtime 是符号链接，请使用真实目录以免仍访问 Documents。"
mkdir -p "$RUNTIME_DIR"
RUNTIME_DIR="$(cd -- "$RUNTIME_DIR" && pwd -P)"
if [[ -e "$RUNTIME_DIR/asr-backend" || -L "$RUNTIME_DIR/asr-backend" ]]; then
  [[ -f "$RUNTIME_DIR/asr-backend" && ! -L "$RUNTIME_DIR/asr-backend" ]] || fail "语音模型配置不是普通文件：$RUNTIME_DIR/asr-backend"
fi
ASR_BACKEND="${LOCAL_DICTATION_ASR_BACKEND:-}"
if [[ -z "$ASR_BACKEND" && -f "$RUNTIME_DIR/asr-backend" ]]; then
  ASR_BACKEND="$(cat "$RUNTIME_DIR/asr-backend")"
fi
ASR_BACKEND="${ASR_BACKEND:-whisper}"
case "$ASR_BACKEND" in whisper|qwen) ;; *) fail "不支持的语音模型：${ASR_BACKEND}（仅支持 whisper 或 qwen）。" ;; esac
LOCK_DIR="$RUNTIME_DIR/.install-lock"
mkdir "$LOCK_DIR" 2>/dev/null || fail "已有安装进行中或留下锁：${LOCK_DIR}；请确认没有安装进程后再处理该空目录。"
finish() {
  local status=$?
  trap - EXIT
  if [[ "$INSTALL_COMPLETE" != true && "$status" == 0 ]]; then status=1; fi
  if [[ "$INSTALL_COMPLETE" != true ]]; then
    # Publish only after all staging checks. If a final-location check or a
    # later rename fails, put new trees back in their stages and restore old
    # trees in reverse order. Nothing is recursively deleted during rollback.
    local i target stage backup
    for ((i=${#PUBLISHED_TARGETS[@]}-1; i>=0; i--)); do
      target="${PUBLISHED_TARGETS[$i]}"; stage="${PUBLISHED_STAGES[$i]}"; backup="${PUBLISHED_BACKUPS[$i]}"
      if [[ -e "$target" || -L "$target" ]]; then
        if ! mv "$target" "$stage"; then
          echo "回退未完成：新目录保留在 ${target}；旧目录仍在 ${backup}。" >&2
          continue
        fi
      fi
      if [[ -n "$backup" ]] && ! mv "$backup" "$target"; then
        echo "回退未完成：请从 $backup 恢复到 ${target}。" >&2
      fi
    done
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
  if [[ "$status" != 0 && -n "$LAST_STAGE" ]]; then
    echo "未完成的阶段目录保留在：${LAST_STAGE}；现有模型和环境未被删除。" >&2
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "安装目标：$RUNTIME_DIR"
echo "请确保 App 和后端已停止；本脚本不会停止任何进程，也不会下载文件。"
echo "语音模型选择：${ASR_BACKEND}（全部成功后才保存）。"

copy_tree() {
  local name="$1" source="$2" stage source_device target_device
  [[ -d "$source" && ! -L "$source" ]] || fail "找不到可复制的 ${source}；请先在交付目录运行 setup.sh。"
  stage="$(mktemp -d "$RUNTIME_DIR/.install-$name.XXXXXX")"
  LAST_STAGE="$stage"
  source_device="$(stat -f %d "$source")"
  target_device="$(stat -f %d "$RUNTIME_DIR")"
  if [[ "$source_device" != "$target_device" ]]; then
    echo "${name}：源和目标位于不同卷，克隆可能不可用。"
  fi
  echo "${name}：尝试 APFS 克隆（cp -cR）。"
  if /bin/cp -cR "$source" "$stage/$name" 2>"$stage/clone-error.log"; then
    echo "${name}：克隆复制完成。"
  else
    echo "${name}：克隆失败，改用普通复制；需要完整文件占用的磁盘空间。" >&2
    sed -n '1,8p' "$stage/clone-error.log" >&2
    echo "克隆失败的阶段目录保留在：$stage" >&2
    # Use a fresh stage rather than merging into a partially cloned tree.
    stage="$(mktemp -d "$RUNTIME_DIR/.install-$name-copy.XXXXXX")"
    LAST_STAGE="$stage"
    /bin/cp -R "$source" "$stage/$name" || fail "$name 普通复制失败；请检查可用空间和文件权限。"
    echo "${name}：普通复制完成（未使用克隆）。"
  fi
  COPIED_TREE="$stage/$name"
}

validate_venv() {
  local directory="$1"
  [[ -x "$directory/bin/python" ]] || fail "Python 环境不完整：$directory"
  # Isolated mode excludes PYTHONPATH and the current directory. Check actual
  # import locations, not just a successful import from the source environment.
  LOCAL_DICTATION_EXPECTED_VENV="$directory" LOCAL_DICTATION_EXPECTED_ASR_BACKEND="$ASR_BACKEND" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 \
    "$directory/bin/python" -I -B - <<'PY' || fail "迁移后的 Python/MLX 依赖校验失败；未下载或替换现有环境。"
import importlib.metadata
import os
from pathlib import Path
import sys
import mlx.core
import mlx_whisper
import mlx_lm

expected = Path(os.environ["LOCAL_DICTATION_EXPECTED_VENV"]).resolve()
if Path(sys.prefix).resolve() != expected:
    raise RuntimeError(f"Python prefix 未定位到迁移环境：{sys.prefix}")
modules = [mlx.core, mlx_whisper, mlx_lm]
packages = ["mlx", "mlx-whisper", "mlx-lm"]
if os.environ["LOCAL_DICTATION_EXPECTED_ASR_BACKEND"] == "qwen":
    import mlx_audio
    from mlx_audio.stt.models.qwen3_asr import Qwen3ASRModel
    if importlib.metadata.version("mlx-audio") != "0.6.3":
        raise RuntimeError("Qwen ASR 需要已验证的 mlx-audio 0.6.3；请使用对应隔离环境。")
    modules.append(mlx_audio)
    packages.append("mlx-audio")
for module in modules:
    location = Path(module.__file__).resolve()
    if not location.is_relative_to(expected):
        raise RuntimeError(f"依赖仍引用其他环境：{module.__name__}: {location}")
versions = ", ".join(f"{name} {importlib.metadata.version(name)}"
                     for name in packages)
print(f"Python 迁移校验通过：{sys.version.split()[0]}；{versions}")
print(f"环境路径：{expected}（仅导入依赖，未加载模型）")
PY
}

VENV_DIR="$RUNTIME_DIR/local-dictation-venv"
VENV_CANDIDATE="$VENV_DIR"
if [[ -e "$VENV_DIR" || -L "$VENV_DIR" ]]; then
  [[ -d "$VENV_DIR" && ! -L "$VENV_DIR" ]] || fail "已有环境不是普通目录：$VENV_DIR"
  if [[ -n "${LOCAL_DICTATION_SOURCE_VENV:-}" ]]; then
    [[ -d "$SOURCE_VENV" && ! -L "$SOURCE_VENV" ]] || fail "指定的 Python 源环境不可用：$SOURCE_VENV"
    if [[ "$(cd -- "$SOURCE_VENV" && pwd -P)" != "$VENV_DIR" ]]; then
      copy_tree local-dictation-venv "$SOURCE_VENV"
      VENV_CANDIDATE="$COPIED_TREE"
    fi
  else
    echo "复用已有 Python 环境。"
  fi
else
  copy_tree local-dictation-venv "$SOURCE_VENV"
  VENV_CANDIDATE="$COPIED_TREE"
fi
validate_venv "$VENV_CANDIDATE"
VALIDATION_PYTHON="$VENV_CANDIDATE/bin/python"

validate_models() {
  local directory="$1"
  LOCAL_DICTATION_EXPECTED_ASR_BACKEND="$ASR_BACKEND" "$VALIDATION_PYTHON" -I -B - "$directory" <<'PY' || fail "模型目录校验失败；保留已有文件，请检查后重试。"
import json
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
required = {
    "Qwen3-4B-Instruct-2507-4bit": (
        "model.safetensors", "config.json", "tokenizer.json", "tokenizer_config.json",
    ),
}
if os.environ["LOCAL_DICTATION_EXPECTED_ASR_BACKEND"] == "whisper":
    required["whisper-large-v3-turbo"] = ("weights.safetensors", "config.json")
for model, files in required.items():
    if (root / model).is_symlink():
        raise RuntimeError(f"模型目录仍是符号链接：{root / model}")
    for name in files:
        path = root / model / name
        if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
            raise RuntimeError(f"缺失、为空或引用外部路径的模型文件：{path}")
        if name.endswith(".json"):
            json.loads(path.read_text(encoding="utf-8"))
print("所选模型的必需文件和 JSON 配置检查通过（未加载模型权重）。")
PY
}

validate_qwen_model() {
  "$VALIDATION_PYTHON" -I -B - "$1" <<'PYQWEN' || fail "Qwen ASR 文件检查失败；未切换后端。"
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
if root.is_symlink() or not root.is_dir():
    raise RuntimeError(f"Qwen 模型路径不是普通目录：{root}")
for name in ("model.safetensors", "config.json", "tokenizer_config.json", "vocab.json",
             "merges.txt", "preprocessor_config.json", "chat_template.json"):
    path = root / name
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError(f"Qwen 必需文件缺失、为空或是符号链接：{path}")
    if name.endswith(".json"):
        json.loads(path.read_text(encoding="utf-8"))
config = json.loads((root / "config.json").read_text())
if config.get("model_type") != "qwen3_asr" or config.get("quantization", {}).get("bits") != 8:
    raise RuntimeError("目录不是预期的 Qwen3-ASR 8bit 模型。")
provenance = root / "local-dictation-source.json"
if provenance.exists():
    value = json.loads(provenance.read_text())
    if value.get("revision") != "a8379a2e2f9e313c9292cdf1af4055ab56d50d55":
        raise RuntimeError("Qwen ASR revision 与已验证版本不一致。")
print("Qwen ASR 必需文件、JSON 和模型类型检查通过（未加载模型权重）。")
PYQWEN
}

MODELS_DIR="$RUNTIME_DIR/models"
MODELS_CANDIDATE="$MODELS_DIR"
if [[ -e "$MODELS_DIR" || -L "$MODELS_DIR" ]]; then
  [[ -d "$MODELS_DIR" && ! -L "$MODELS_DIR" ]] || fail "已有模型路径不是普通目录：$MODELS_DIR"
  echo "复用已有模型目录。"
else
  # Copy only the selected ASR and common editor. Qwen is added from its
  # explicit source below; existing optional Whisper assets are never deleted.
  MODEL_STAGE="$(mktemp -d "$RUNTIME_DIR/.install-models.XXXXXX")"
  MODELS_CANDIDATE="$MODEL_STAGE/models"
  mkdir "$MODELS_CANDIDATE"
  MODEL_NAMES=(Qwen3-4B-Instruct-2507-4bit)
  if [[ "$ASR_BACKEND" == whisper ]]; then MODEL_NAMES+=(whisper-large-v3-turbo); fi
  for name in "${MODEL_NAMES[@]}"; do
    copy_tree "$name" "$SOURCE_WORK/models/$name"
    mv "$COPIED_TREE" "$MODELS_CANDIDATE/$name"
  done
fi
validate_models "$MODELS_CANDIDATE"

QWEN_CANDIDATE=""
QWEN_TARGET="$MODELS_DIR/Qwen3-ASR-1.7B-8bit"
if [[ "$ASR_BACKEND" == qwen ]]; then
  if [[ -e "$QWEN_TARGET" || -L "$QWEN_TARGET" ]]; then
    validate_qwen_model "$QWEN_TARGET"
    echo "复用已有 Qwen ASR 模型。"
  else
    copy_tree Qwen3-ASR-1.7B-8bit "$SOURCE_QWEN"
    QWEN_CANDIDATE="$COPIED_TREE"
    validate_qwen_model "$QWEN_CANDIDATE"
    if [[ "$MODELS_CANDIDATE" != "$MODELS_DIR" ]]; then
      mv "$QWEN_CANDIDATE" "$MODELS_CANDIDATE/Qwen3-ASR-1.7B-8bit"
      QWEN_CANDIDATE=""
    fi
  fi
fi

# Prepare every small backend file before replacing any live directory.
BACKEND_STAGE="$(mktemp -d "$RUNTIME_DIR/.install-backend.XXXXXX")"
LAST_STAGE="$BACKEND_STAGE"
mkdir "$BACKEND_STAGE/backend"
for name in server.py streaming.py prompt_store.py prompt-imports.json model_artifacts.py model-manifest.json start.sh setup.sh download_models.py requirements.txt diagnose.py install_runtime.sh test_server.py test_prompt_store.py; do
  [[ -f "$BACKEND_DIR/$name" ]] || fail "交付文件缺失：$BACKEND_DIR/$name"
  /bin/cp -p "$BACKEND_DIR/$name" "$BACKEND_STAGE/backend/$name"
done
# Documentation is useful when present, but a clean source checkout contains
# no local acceptance reports and must not depend on or install those reports.
if [[ -f "$BACKEND_DIR/README.md" ]]; then
  /bin/cp -p "$BACKEND_DIR/README.md" "$BACKEND_STAGE/backend/README.md"
fi
# Import the staged service with its own interpreter before publication. This
# verifies local module dependencies without loading models or creating stores.
"$VALIDATION_PYTHON" -B - "$BACKEND_STAGE/backend" <<'PYBACKEND' || fail "后端资源不完整；尚未发布新服务。"
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
import server
import prompt_store
import model_artifacts
import download_models
import diagnose
root = Path(sys.argv[1]).resolve()
for module in (server, prompt_store, model_artifacts, download_models, diagnose):
    if Path(module.__file__).resolve().parent != root:
        raise RuntimeError(f"后端模块未来自待安装目录：{module.__name__}")
print("后端资源导入检查通过（未加载模型或读取用户数据）。")
PYBACKEND
if [[ -e "$RUNTIME_DIR/backend" || -L "$RUNTIME_DIR/backend" ]]; then
  [[ -d "$RUNTIME_DIR/backend" && ! -L "$RUNTIME_DIR/backend" ]] || fail "已有 backend 不是普通目录。"
fi

publish_tree() {
  local source="$1" target="$2" name="$3" backup="" parent
  if [[ -e "$target" || -L "$target" ]]; then
    parent="$(mktemp -d "$RUNTIME_DIR/.previous-$name.XXXXXX")"
    backup="$parent/$name"
    mv "$target" "$backup"
  fi
  if ! mv "$source" "$target"; then
    if [[ -n "$backup" ]]; then mv "$backup" "$target" || true; fi
    fail "发布 $name 失败；旧版本保留在 ${backup:-原路径}。"
  fi
  PUBLISHED_TARGETS+=("$target")
  PUBLISHED_STAGES+=("$source")
  PUBLISHED_BACKUPS+=("$backup")
  if [[ -n "$backup" ]]; then echo "旧 $name 保留在：$backup"; fi
}

if [[ "$VENV_CANDIDATE" != "$VENV_DIR" ]]; then
  publish_tree "$VENV_CANDIDATE" "$VENV_DIR" local-dictation-venv
fi
if [[ "$MODELS_CANDIDATE" != "$MODELS_DIR" ]]; then
  publish_tree "$MODELS_CANDIDATE" "$MODELS_DIR" models
fi
if [[ -n "$QWEN_CANDIDATE" ]]; then
  publish_tree "$QWEN_CANDIDATE" "$QWEN_TARGET" Qwen3-ASR-1.7B-8bit
fi
publish_tree "$BACKEND_STAGE/backend" "$RUNTIME_DIR/backend" backend

# Recheck the final Python prefix. Old activation/pip shebangs can retain their
# source path, so the launcher always executes this interpreter directly.
validate_venv "$VENV_DIR"
VALIDATION_PYTHON="$VENV_DIR/bin/python"
validate_models "$MODELS_DIR"
if [[ "$ASR_BACKEND" == qwen ]]; then validate_qwen_model "$QWEN_TARGET"; fi
# The backend choice is the commit point: failures before this keep the previous
# choice and roll back any published directory. Atomic rename avoids partial text.
printf '%s\n' "$ASR_BACKEND" > "$BACKEND_STAGE/asr-backend"
mv "$BACKEND_STAGE/asr-backend" "$RUNTIME_DIR/asr-backend"
INSTALL_COMPLETE=true

echo "安装完成。Python、模型与后端位于：$RUNTIME_DIR"
echo "语音模型已选择：${ASR_BACKEND}；原 Whisper 模型与其他用户数据保留。"
echo "App 可使用 LOCAL_DICTATION_WORK_DIR=Runtime 目录启动 backend/start.sh。"
echo "原工作区的 work/ 文件保持不变；本脚本没有启动服务。"
