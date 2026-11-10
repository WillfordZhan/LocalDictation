# Mac 分发构建

发行包包含可重定位的 CPython 3.11 与推理依赖，不包含模型、用户历史或签名私钥。模型首次运行时由固定清单下载。

准备独立 CPython 源目录及安装好 `backend/requirements.txt` 的 site-packages，再执行：

```sh
python3 packaging/build_runtime.py \
  --python-home /absolute/path/to/standalone-python \
  --site-packages /absolute/path/to/site-packages \
  --output "$PWD/build/python-unpublished"
python3 packaging/sanitize_runtime.py \
  --source "$PWD/build/python-unpublished" \
  --output "$PWD/build/python-public"
python3 packaging/validate_runtime.py "$PWD/build/python-public"
LOCAL_DICTATION_PYTHON_BUNDLE="$PWD/build/python-public" \
  bash macos/build.sh "$PWD/build/LocalDictation.app"
bash packaging/package.sh "$PWD/build/LocalDictation.app" "$PWD/releases/0.5.12"
```

`build_runtime.py` 检查本机动态库引用和解释器导入；`sanitize_runtime.py` 创建副本，移除本机构建来源、修正 CPython 元数据的重定位路径，并补齐固定版本依赖许可证。它不会修改源运行环境。实际推理仍需对打包后的模型组合单独验收。

打包后解压到新目录，再执行签名、运行环境完整性和启动检查。最终 ZIP 还需检查是否意外含有个人数据或密钥。发布前不要直接提交开发目录中的生成文件。

当前签名工具创建本地自签名身份，用于本机更新时保持权限识别；这不等同 Developer ID 签名或 Apple 公证。正式公证需要发布者自行持有 Apple Developer 身份，不能把签名私钥加入仓库。
