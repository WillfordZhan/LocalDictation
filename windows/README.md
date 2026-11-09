# Windows 预览版

Windows 版使用独立的原生界面、全局快捷键和系统托盘。录音通过本机 Whisper large-v3 turbo 识别，文字由本机 Qwen3-4B Instruct 整理；Mac 继续使用既有 MLX 运行环境。目标兼容 Windows 10/11 x64；本次验证使用 GitHub Windows 托管环境，Windows 10 实机仍待验收。CPU 即可运行，不要求 NVIDIA 显卡。具体系统支持还受内置 .NET 运行环境的官方支持范围约束，不能将目标兼容理解为所有 Windows 10 版本均已受支持或验证。

## 安装与使用

1. 完整解压 Windows ZIP 到可写目录，运行 `LocalDictation.exe`。不要只复制 EXE，`backend` 和 `runtime` 目录也必须保留。
2. 打开“模型与配置”，检查配置并下载模型。安装包包含 Python 和 .NET 运行环境，无需单独安装它们。首次模型下载约 4.1 GB，完成后可离线使用。
3. 如果提示缺少 Microsoft Visual C++ 运行库，点击对应安装按钮，确认微软安装程序及系统管理员授权。程序不会在后台自动申请管理员权限。
4. 在 Windows 隐私设置中允许桌面应用访问麦克风，然后选择输入框，用设置中的全局快捷键开始和结束录音。
5. 关闭主窗口后应用保留在系统托盘；需要结束程序时，从托盘菜单选择退出。

识别原文、最终正文、个人词典和 Prompt 保存在 `%LOCALAPPDATA%\LocalDictation\`，模型也位于应用外。更新时退出程序并替换应用目录，不要删除这个数据目录。无法自动填入时，可以从剪贴板手动按 Ctrl+V 粘贴；Windows 权限级别不同的应用之间可能无法发送按键。

Windows 版是预览实现，不代表已与 Mac 所有增强功能完全对齐。实际支持范围及验收状态以对应 Release 为准。首个安装包没有购买 Windows 代码签名证书，系统可能显示未知发布者；内置的微软运行库安装程序保留微软原始签名。

## 构建

在 Windows x64 上准备 **CPython 3.11 x64**（仅构建使用，带 pip）、**.NET 10 SDK** 和 Git。下面的命令不访问真实麦克风、不注册全局快捷键，也不会读取已有用户历史。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/packaging/build.ps1 `
  -PythonForBuild C:\tools\python\python.exe `
  -Dotnet C:\tools\dotnet\dotnet.exe `
  -OutputDirectory C:\build\LocalDictation `
  -CacheDirectory C:\build\download-cache `
  -Version 0.6.0-preview.1
```

输出目录必须不存在或为空。生成的 `LocalDictation-0.6.0-preview.1-Windows-x64.zip` 和校验文件位于输出目录旁边。`-SkipArchive` 可用于先构建目录，再做实机验证。构建依赖只安装到新应用目录；不会修改构建 Python 或系统 Python 中的依赖。

`packaging/inputs.json` 固定官方 CPython NuGet 包、llama.cpp CPU 包、微软运行库安装程序及许可证的下载来源和 SHA-256。缓存可以预先放入对应文件，但只有通过固定散列检查才会复用。Python 依赖使用 `backend/requirements-windows.txt`，实际 wheel 散列、源文件散列及 Git 状态写入包内 `build-inputs.json`。包内不会包含模型、用户历史或私钥，也不会新增本次构建机器的私有路径；公开 wheel 自带的上游编译元数据按原样保留并记录文件散列来源。

`runtime/python/python311._pth` 将 Python 模块搜索范围固定在应用内部。NuGet 包提供解压的 `Lib` 和 `DLLs`，不依赖 `python311.zip` 或用户环境变量。运行时不需要 pip，也不会向应用目录写入 Python 字节码。

## 验证与发布

构建脚本检查下载散列、微软运行库签名、依赖许可证、文件清单和隐私边界，并运行不触碰录音或剪贴板的原生自检。运行环境导入和 `llama-server --version` 也必须通过。检查结果不替代真实口述验收。

```powershell
C:\build\LocalDictation\runtime\python\python.exe -B `
  windows/packaging/validate_bundle.py C:\build\LocalDictation --runtime-check
```

发布前还要把 ZIP 解压到另一目录，复查清单和启动，并在明确授权的 Windows 桌面验证快捷键、关闭窗口后托盘驻留、录音设备、流式识别、润色、自动粘贴及重启后的历史保留。GitHub Actions Windows runner 可以验证编译、文件完整性、依赖导入、音频样本推理和独立测试窗口；真实麦克风与用户日常输入框兼容性仍需人工或获授权的桌面验收。

`THIRD_PARTY_COMPONENTS.json` 与 `licenses/` 保留 Python、.NET、NAudio、llama.cpp 及 wheel 依赖的许可说明。模型下载另附其上游许可，不把模型权重打进应用包。
