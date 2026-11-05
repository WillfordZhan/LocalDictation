#!/bin/bash
set -euo pipefail
BACKEND_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
WORKSPACE_DIR="$(cd -- "$BACKEND_DIR/../../.." && pwd)"
TASK_WORK="${LOCAL_DICTATION_WORK_DIR:-$WORKSPACE_DIR/work}"
PYTHON_BIN="${LOCAL_DICTATION_PYTHON:-$TASK_WORK/local-dictation-venv/bin/python}"
ASR_BACKEND="${LOCAL_DICTATION_ASR_BACKEND:-}"
if [[ -z "$ASR_BACKEND" && -f "$TASK_WORK/asr-backend" ]]; then
  ASR_BACKEND="$(cat "$TASK_WORK/asr-backend")"
fi
ASR_BACKEND="${ASR_BACKEND:-whisper}"
case "$ASR_BACKEND" in whisper|qwen) ;; *) echo "不支持的语音模型：${ASR_BACKEND}（仅支持 whisper 或 qwen）。" >&2; exit 1 ;; esac
export HF_HOME="$TASK_WORK/huggingface-cache"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONNOUSERSITE=1
export NUMBA_CACHE_DIR="$TASK_WORK/cache/numba"
export XDG_CACHE_HOME="$TASK_WORK/cache"
unset PYTHONHOME PYTHONPATH VIRTUAL_ENV
if [[ ! -x "$PYTHON_BIN" ]]; then
  echo "本地模型环境尚未安装，请先运行 backend/setup.sh。" >&2
  exit 1
fi
exec "$PYTHON_BIN" "$BACKEND_DIR/server.py" --models-dir "$TASK_WORK/models" --asr-backend "$ASR_BACKEND" "$@"
