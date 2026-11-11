# 第三方组件

本项目的原创代码使用 MIT。下列运行环境、库与模型分别使用各自许可证；打包副本保留上游 LICENSE、COPYING、NOTICE 等文件，额外补齐内容及固定来源见 `packaging/licenses/SOURCES.json`。

- CPython 与 python-build-standalone：许可证与构建来源保存在运行环境 `share/licenses/`。
- MLX、MLX-LM、MLX-Audio、MLX-Whisper：Apple MLX 生态项目，使用各自上游许可证。仓库中仅包含调用代码。
- NumPy、SciPy、PyTorch、Transformers、Tokenizers、SentencePiece、Hugging Face Hub 及其他 Python 依赖：按发行版本保留相应许可文件。依赖清单见 `backend/requirements.txt`。
- Qwen3-ASR、Mac 上的 Qwen3.5、Windows 上的 Qwen3-Instruct 与 Whisper 模型：权重由用户首次配置时下载，未包含在 Git 或安装包中。固定仓库与版本见 `backend/model-manifest.json`，使用应遵循模型上游许可。

应用图标“回声”是本项目用 AppKit 原创绘制的连续曲线标志，生成源位于 `macos/assets/generate-icon.swift`，随项目使用 MIT 许可证。设计参考和再生成方式见 `macos/assets/README.md`。未包含 Typeless 的图标、提取源码或反编译制品。对其他口述工具的交互研究仅用于独立实现，不引入其非商业许可代码。
