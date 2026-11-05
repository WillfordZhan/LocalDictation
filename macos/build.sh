#!/bin/bash
set -euo pipefail
APP_SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_OUTPUT_DIR="${1:-$(cd "$APP_SOURCE_DIR/.." && pwd)/LocalDictation.app}"
# A caller can build into a staging directory while the user's current app
# remains open with unsaved dictation/history. Never replace a mapped executable.
if [[ -e "$APP_OUTPUT_DIR/Contents/MacOS/LocalDictation" ]] && /usr/sbin/lsof -t "$APP_OUTPUT_DIR/Contents/MacOS/LocalDictation" >/dev/null 2>&1; then
  printf '应用正在使用中，请先退出，或指定其他构建路径：%s\n' "$APP_OUTPUT_DIR" >&2
  exit 1
fi
mkdir -p "$APP_OUTPUT_DIR/Contents/MacOS" "$APP_OUTPUT_DIR/Contents/Resources"
swiftc -swift-version 5 -parse-as-library -O -target arm64-apple-macosx14.0 \
  -framework AppKit -framework AVFoundation -framework Carbon -framework ApplicationServices \
  "$APP_SOURCE_DIR"/*.swift -o "$APP_OUTPUT_DIR/Contents/MacOS/LocalDictation"
cp "$APP_SOURCE_DIR/Info.plist" "$APP_OUTPUT_DIR/Contents/Info.plist"
cp "$APP_SOURCE_DIR/assets/AppIcon.icns" "$APP_OUTPUT_DIR/Contents/Resources/AppIcon.icns"
# Keep the app's redistribution terms with the executable; runtime dependency
# notices are carried separately inside the validated Python bundle.
cp "$APP_SOURCE_DIR/../LICENSE" "$APP_OUTPUT_DIR/Contents/Resources/LICENSE"
cp "$APP_SOURCE_DIR/../THIRD_PARTY_NOTICES.md" "$APP_OUTPUT_DIR/Contents/Resources/THIRD_PARTY_NOTICES.md"
# Runtime and model downloads are deliberately separate: a release ships the
# interpreter and backend, while model/user data always stays outside the app.
BACKEND_SOURCE="$APP_SOURCE_DIR/../backend"
mkdir -p "$APP_OUTPUT_DIR/Contents/Resources/backend"
for source in "$BACKEND_SOURCE"/*.py "$BACKEND_SOURCE"/*.sh "$BACKEND_SOURCE"/requirements.txt "$BACKEND_SOURCE"/prompt-imports.json "$BACKEND_SOURCE"/model-manifest.json; do
  case "$(basename "$source")" in test_*|setup.sh|install_runtime.sh) continue ;; esac
  [[ -f "$source" ]] && cp "$source" "$APP_OUTPUT_DIR/Contents/Resources/backend/"
done
if [[ -n "${LOCAL_DICTATION_PYTHON_BUNDLE:-}" ]]; then
  [[ -x "$LOCAL_DICTATION_PYTHON_BUNDLE/bin/python3" && -f "$LOCAL_DICTATION_PYTHON_BUNDLE/runtime-manifest.json" ]] || { echo '内置Python尚未通过打包校验' >&2; exit 1; }
  RUNTIME_STAGE_ROOT="$(mktemp -d "$APP_OUTPUT_DIR.Python.XXXXXX")"
  RUNTIME_STAGE="$RUNTIME_STAGE_ROOT/Python"
  trap 'rm -rf "$RUNTIME_STAGE_ROOT"' EXIT
  cp -cR "$LOCAL_DICTATION_PYTHON_BUNDLE" "$RUNTIME_STAGE" || ditto "$LOCAL_DICTATION_PYTHON_BUNDLE" "$RUNTIME_STAGE"
  # Development/evaluation imports can leave bytecode with local co_filename
  # paths after the runtime manifest was built. Remove only generated caches
  # from this new staging copy, then require an exact manifest match.
  python3 -B - "$RUNTIME_STAGE" <<'PY'
from pathlib import Path
import shutil
import sys
root = Path(sys.argv[1])
for path in root.rglob("__pycache__"):
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
for pattern in ("*.pyc", "*.pyo"):
    for path in root.rglob(pattern):
        path.unlink()
PY
  python3 "$APP_SOURCE_DIR/../packaging/validate_runtime.py" "$RUNTIME_STAGE"
  # Only inactive build output is replaced. Never sign an old or partial
  # interpreter left by an earlier build in this directory.
  rm -rf "$APP_OUTPUT_DIR/Contents/Resources/Python"
  mv "$RUNTIME_STAGE" "$APP_OUTPUT_DIR/Contents/Resources/Python"
  rmdir "$RUNTIME_STAGE_ROOT"
  trap - EXIT
fi
# Reuse the local signing identity so macOS can recognize subsequent builds.
# Never silently fall back to ad-hoc signing: that invalidates saved permissions.
python3 "$APP_SOURCE_DIR/signing/local_signing.py" sign --app "$APP_OUTPUT_DIR"
"$APP_OUTPUT_DIR/Contents/MacOS/LocalDictation" --self-test
codesign --verify --strict "$APP_OUTPUT_DIR"
printf '已构建：%s\n' "$APP_OUTPUT_DIR"
