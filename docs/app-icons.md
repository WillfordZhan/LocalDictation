# Mac 外观与图标

应用设置提供“跟随系统 / 浅色 / 深色”。默认跟随系统；窗口没有固定外观，使用 `NSApp.effectiveAppearance`。只覆盖本应用的 `NSApp.appearance`，不更改 macOS 设置。

图标默认跟随应用外观，浅色使用柔雾显影（C），深色使用暗色辉光（D）。关闭图标跟随后，可手动选择点阵成型（B）、柔雾显影（C）或暗色辉光（D），不受界面深浅色限制。外观模式、手动图标和跟随开关保存到应用外的 `preferences.json`；切换不会重写历史、Prompt 或词典，也不会重建当前编辑页。

## 图标更新

安装包内置 C，并携带 B/C/D 的 PNG 和 ICNS。启动时恢复已保存的选择；应用更新替换包后，下次启动重新应用该选择。

- C 使用 `NSWorkspace.setIcon(nil, forFile:)` 移除自定义文件图标，恢复内置图标。
- B/D 使用同一公开 API 写入用户自定义图标；成功后在主线程更新 `NSApp.applicationIconImage` 和 Dock tile。
- 文件操作串行执行。快速外观变化合并到最新状态，不把旧主题覆盖回去。
- 文件更新失败不会只更新运行中的 Dock 后宣称成功。偏好保存失败会恢复之前实际生效的图标；补偿也失败时显示错误，下一次重试强制重新应用。
- 修改前后只读取本进程 `AXIsProcessTrusted()`。若从已授权变为未授权，恢复原文件图标并报错；不请求、重置或修改权限。现有未授权状态不妨碍修改外观。

不更改已封存的 Info.plist、ICNS 或可执行文件，不在运行时重签应用，也不自动重启 Dock、改 Dock 排列或更改登录项。

## 签名和验证边界

公开 API 将自定义图标保存在 Finder 元数据中，包括 FinderInfo 和 `Icon` 资源叉。隔离签名副本实验中，设置图标后普通 `codesign --verify --deep`、Security.framework 验证和原 designated requirement 仍通过；`codesign --verify --deep --strict` 会因 Finder 附加元数据报 `resource fork, Finder information, or similar detritus not allowed`。清除自定义图标后严格检查恢复通过。Security.framework 的 strict flag 在同一实验中返回成功，不能与命令行的严格包检查混称。

发行 ZIP 必须从未做用户自定义图标的干净构建产物打包，并通过严格签名检查。不要把用户已定制的安装目录直接作为发布产物；不要清理整个用户应用的扩展属性来绕过检查。

这些证据说明该 API 不改变代码身份，不代表已经证明所有 macOS 版本上的 TCC 和 Dock 缓存行为。单元测试使用注入的文件图标、Dock、权限和外观操作，覆盖失败、补偿与竞态；它们不会操作实际权限或系统外观，也不能代替实际 Dock 和 Finder 验收。

发布验收应在同一安装路径、已授权的应用中检查 B/C/D 的 Finder 图标、运行中 Dock、退出后的固定 Dock、重新打开和升级恢复；同时确认现有自动填入授权和历史保留。文件图标成功与 Dock 缓存及时重绘是两个观察点，不应把文件 API 返回成功当成 Dock 视觉证据。

## Apple 资料

- [NSWorkspace.setIcon](https://developer.apple.com/documentation/appkit/nsworkspace/seticon(_:forfile:options:))：设置文件图标，可在非主线程调用，但不能并发调用。
- [NSApplication.applicationIconImage](https://developer.apple.com/documentation/appkit/nsapplication/applicationiconimage)：运行中的应用图标，不替代持久文件图标。
- [NSApplication.effectiveAppearance](https://developer.apple.com/documentation/appkit/nsapplication/effectiveappearance)：应用当前有效外观。
- [QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html)：签名检查中的资源叉和 Finder 信息限制。
- [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)：签名封存、代码身份与验证要求。
