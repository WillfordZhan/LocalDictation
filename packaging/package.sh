#!/bin/bash
set -euo pipefail
PACKAGE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${1:?usage: package.sh /absolute/LocalDictation.app /absolute/output-directory}"
RELEASE_DIR="${2:?output directory required}"
[[ -x "$APP_PATH/Contents/Resources/Python/bin/python3" ]] || { echo '缺少内置Python，不能生成分发包' >&2; exit 1; }
[[ -f "$APP_PATH/Contents/Resources/backend/model-manifest.json" ]] || { echo '缺少固定模型清单' >&2; exit 1; }
codesign --verify --strict "$APP_PATH"
python3 "$PACKAGE_DIR/validate_runtime.py" "$APP_PATH/Contents/Resources/Python"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")
mkdir -p "$RELEASE_DIR"
ARCHIVE="$RELEASE_DIR/LocalDictation-$VERSION-AppleSilicon.zip"
[[ ! -e "$ARCHIVE" ]] || { echo '目标安装包已存在，请使用新的发布目录' >&2; exit 1; }
# ditto preserves the complete signed bundle and its relative interpreter links.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE"
cp "$PACKAGE_DIR/INSTALL.md" "$RELEASE_DIR/安装说明.md"
# Public checksums contain only the downloadable filename, so they work after
# extraction into any directory and never expose the builder's local path.
(cd "$RELEASE_DIR" && shasum -a 256 "$(basename "$ARCHIVE")") > "$ARCHIVE.sha256"
printf '已生成内置运行环境的安装包：%s\n' "$ARCHIVE"
