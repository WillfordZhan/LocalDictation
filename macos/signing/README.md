# 本地开发签名

自签名身份用于让同一开发者的后续构建保持稳定代码身份，不等同 Apple Developer ID 或公证。首次创建：

```sh
python3 macos/signing/local_signing.py initialize
```

随后 `macos/build.sh` 复用该身份签名。也可显式运行：

```sh
python3 macos/signing/local_signing.py sign --app /absolute/path/to/LocalDictation.app
```

身份材料保存在 `~/Library/Application Support/LocalDictation/Signing` 的私有目录中。不要将 keychain、密码、PEM、P12 或 identity 配置加入 Git、应用包或安装 ZIP。丢失或更换私钥后需要重新授予系统权限。

签名要求绑定 bundle identifier 和证书，不以仅 identifier 的宽松要求代替签名验证。工具使用专用 keychain，不修改系统信任、默认 keychain、搜索列表或 TCC 数据库。遇到访问失败时停止，不自动退回 ad-hoc 签名。

辅助功能、麦克风和输入监控仍需用户通过 macOS 正常授权。本地开发签名不保证 Gatekeeper 允许公开下载安装；正式分发应使用发布者自己的 Developer ID 和公证流程。
