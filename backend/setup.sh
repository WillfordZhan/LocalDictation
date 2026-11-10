#!/bin/bash
set -euo pipefail
BACKEND_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
WORKSPACE_DIR="$(cd -- "$BACKEND_DIR/../../.." && pwd)"
TASK_WORK="${LOCAL_DICTATION_WORK_DIR:-$WORKSPACE_DIR/work}"
VENV_DIR="$TASK_WORK/local-dictation-venv"
if [[ -e "$TASK_WORK/asr-backend" || -L "$TASK_WORK/asr-backend" ]]; then
  if [[ ! -f "$TASK_WORK/asr-backend" || -L "$TASK_WORK/asr-backend" ]]; then
    echo "语音模型配置不是普通文件：$TASK_WORK/asr-backend" >&2
    exit 1
  fi
fi
ASR_BACKEND="${LOCAL_DICTATION_ASR_BACKEND:-}"
if [[ -z "$ASR_BACKEND" && -f "$TASK_WORK/asr-backend" ]]; then
  ASR_BACKEND="$(cat "$TASK_WORK/asr-backend")"
fi
ASR_BACKEND="${ASR_BACKEND:-whisper}"
case "$ASR_BACKEND" in whisper|qwen) ;; *) echo "不支持的语音模型：${ASR_BACKEND}（仅支持 whisper 或 qwen）。" >&2; exit 1 ;; esac
if [[ -e "$TASK_WORK/cleanup-model" || -L "$TASK_WORK/cleanup-model" ]]; then
  if [[ ! -f "$TASK_WORK/cleanup-model" || -L "$TASK_WORK/cleanup-model" ]]; then
    echo "润色模型配置不是普通文件：$TASK_WORK/cleanup-model" >&2
    exit 1
  fi
fi
if [[ "${LOCAL_DICTATION_CLEANUP_MODEL+x}" == x ]]; then
  CLEANUP_MODEL="$LOCAL_DICTATION_CLEANUP_MODEL"
elif [[ -f "$TASK_WORK/cleanup-model" ]]; then
  CLEANUP_MODEL="$(cat "$TASK_WORK/cleanup-model")"
else
  CLEANUP_MODEL=cleanup
fi
case "$CLEANUP_MODEL" in cleanup|cleanup-9b) ;; *) echo "不支持的润色模型：${CLEANUP_MODEL}。" >&2; exit 1 ;; esac
export HF_HOME="$TASK_WORK/huggingface-cache"
export HF_HUB_DISABLE_TELEMETRY=1

if command -v uv >/dev/null 2>&1; then
  UV_BIN="$(command -v uv)"
elif [[ -x "$HOME/.local/bin/uv" ]]; then
  UV_BIN="$HOME/.local/bin/uv"
else
  echo "未找到 uv。请安装 uv，或手工创建 Python 3.11+ 虚拟环境并安装 requirements.txt。" >&2
  exit 1
fi
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  "$UV_BIN" venv --python 3.11 "$VENV_DIR"
fi
"$UV_BIN" pip install --python "$VENV_DIR/bin/python" -r "$BACKEND_DIR/requirements.txt"
"$VENV_DIR/bin/python" "$BACKEND_DIR/download_models.py" --models-dir "$TASK_WORK/models" --asr-backend "$ASR_BACKEND" --cleanup-model "$CLEANUP_MODEL"
# Do not select an unavailable backend when installation/download fails.
CHOICE_STAGE="$(mktemp "$TASK_WORK/.asr-backend.XXXXXX")"
printf '%s\n' "$ASR_BACKEND" > "$CHOICE_STAGE"
mv "$CHOICE_STAGE" "$TASK_WORK/asr-backend"
# The model files are already verified; save the chosen editor for start.sh.
CLEANUP_STAGE="$(mktemp "$TASK_WORK/.cleanup-model.XXXXXX")"
printf '%s\n' "$CLEANUP_MODEL" > "$CLEANUP_STAGE"
mv "$CLEANUP_STAGE" "$TASK_WORK/cleanup-model"
