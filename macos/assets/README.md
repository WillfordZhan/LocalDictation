# LocalDictation 图标

当前应用默认使用原创「柔雾显影」：左上连续声波从实体逐渐散成颗粒，向右下聚拢为完整的 T。青绿到灰紫的柔和背景承载声音到文字的转化。

`AppIcon.png` 为 1024 px 透明外缘原图；`AppIcon.icns` 包含完整 macOS 16/32/64/128/256/512/1024 物理像素表示。Dock、Finder、应用侧栏使用同一套资源。

生成默认资源：

```sh
swift macos/assets/generate-icon.swift macos/assets/AppIcon.png
swift macos/assets/generate-icon.swift macos/assets/AppIcon.icns
```

源中保留「点阵成型」备选构图，`--all /absolute/output-directory` 可导出两款设计及默认资源。应用内切换设置在独立工作分支继续开发，本版仅更换默认图标。
