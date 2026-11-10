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
# The external selection survives app replacement. Empty or invalid saved
# values are configuration errors; silently switching tiers hides the problem.
if [[ ${LOCAL_DICTATION_CLEANUP_MODEL+x} ]]; then
  CLEANUP_MODEL="$LOCAL_DICTATION_CLEANUP_MODEL"
elif [[ -e "$TASK_WORK/cleanup-model" || -L "$TASK_WORK/cleanup-model" ]]; then
  if [[ ! -f "$TASK_WORK/cleanup-model" || -L "$TASK_WORK/cleanup-model" ]]; then
    echo "无法读取整理模型配置：$TASK_WORK/cleanup-model 必须是普通文件，不能是符号链接。" >&2
    exit 1
  fi
  if ! CLEANUP_MODEL="$(cat "$TASK_WORK/cleanup-model")"; then
    echo "无法读取整理模型配置：$TASK_WORK/cleanup-model。" >&2
    exit 1
  fi
else
  CLEANUP_MODEL="cleanup"
fi
case "$CLEANUP_MODEL" in cleanup|cleanup-9b) ;; *) echo "不支持的整理模型：${CLEANUP_MODEL}（仅支持 cleanup 或 cleanup-9b）。" >&2; exit 1 ;; esac
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
exec "$PYTHON_BIN" "$BACKEND_DIR/server.py" --models-dir "$TASK_WORK/models" --asr-backend "$ASR_BACKEND" --cleanup-model "$CLEANUP_MODEL" "$@"
