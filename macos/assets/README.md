# 声转字 · Voice to Text

三套原创图标沿用同一条连续声波与无框 T：左上声波从实心逐渐散为颗粒，在右下凝聚成文字。T 的右端和下半竖画保持清晰，便于 Dock 小尺寸识别。

| 样式 | 资源 | 特征 |
| --- | --- | --- |
| 点阵成型（B） | `AppIconDotFormation.png` / `.icns` | 浅色底，离散颗粒逐渐形成文字 |
| 柔雾显影（C，默认浅色） | `AppIconSoftMist.png` / `.icns` | 绿紫柔雾，颗粒与材质自然过渡 |
| 暗色辉光（D） | `AppIconDarkGlow.png` / `.icns` | 墨绿底，浅色声波颗粒凝聚成文字 |

`AppIcon.png` 与 `AppIcon.icns` 是默认 C 资源的逐字节副本。三张具名 PNG 保留经确认的 1024 × 1024 原始构图，外部透明；ICNS 包含标准 16、32、128、256、512 pt 的 1x/2x 表示，覆盖 16–1024 px。64 px 对应 `icon_32x32@2x.png`。

C 用于浅色外观，D 用于深色外观；B 保留为可选样式。具体外观跟随逻辑由应用管理，静态 `AppIcon` 始终使用 C。

`generate-icon.swift` 包含完整 AppKit 几何构图和固定随机种子，无外部字体、图片、下载或本机目录依赖。修改构图后，在仓库根目录一次重建全部资源：

```sh
swift macos/assets/generate-icon.swift --all
```

也可指定输出目录，用于验证或预览而不覆盖仓库内产物：

```sh
swift macos/assets/generate-icon.swift --all /tmp/localdictation-icons
```

保留原来的单文件调用方式，生成默认 C：

```sh
swift macos/assets/generate-icon.swift /tmp/AppIcon.png
swift macos/assets/generate-icon.swift /tmp/AppIcon.icns
```

这些图形由本项目独立绘制，随项目使用 MIT 许可证。资源生成器不修改已安装的应用、Dock 或图标偏好。
