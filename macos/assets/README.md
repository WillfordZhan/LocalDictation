# 回声 · Echo

本地口述的原创图标。连续笔画结合耳廓与手写形态，杏橙色句点表示声音落成文字。深墨绿与奶油白形成清晰对比；小尺寸识别依靠主轮廓，点缀与阴影不是必要信息。

`generate-icon.swift` 是可编辑的原生矢量绘制源，使用 AppKit 的 Bézier 曲线，没有外部字体、图片或绘图库依赖。`AppIcon.png` 为 1024 px 透明背景预览；`AppIcon.icns` 包含 macOS 的全部 16–1024 px 标准表示。

在仓库根目录重新生成：

```sh
swift macos/assets/generate-icon.swift macos/assets/AppIcon.png
swift macos/assets/generate-icon.swift macos/assets/AppIcon.icns
```

`macos/build.sh` 复制已经生成的 ICNS，不会在每次构建时重绘。更新源文件后需同时重新生成这两个产物。Dock/Finder 通过 `CFBundleIconFile` 读取图标，侧栏通过 `NSImage(named: "AppIcon")` 复用它。菜单栏仍使用原有录音状态符号。

设计参考（2026-11-11）：[Typeless](https://www.typeless.com/) 的精简符号、[Superwhisper](https://apps.apple.com/us/app/superwhisper/id6471464415) 的连续曲线、[Bear](https://apps.apple.com/us/app/bear-markdown-notes/id1091189122?mt=12) 的单一轮廓与对比色、[讯飞写作](https://apps.apple.com/cn/app/id6479692269) 的几何简化，以及 [Apple 图标设计指南](https://developer.apple.com/design/human-interface-guidelines/app-icons)。这些参考用于比较视觉表达；最终图形由本项目独立绘制，并随项目使用 MIT 许可证。
