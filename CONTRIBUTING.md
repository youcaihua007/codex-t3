# 贡献指南

使用 Xcode 27 与 Python 3；修改源文件后运行：

```sh
python3 Scripts/test.py
python3 Scripts/test-sandbox-bridge.py
python3 Scripts/build.py --arch universal --derived-data /tmp/codex-t3-check
```

涉及窗口生命周期的修改还需在本机图形桌面运行 `python3 Scripts/test.py --ui`。涉及 WidgetKit / 沙盒 / 通信 / 签名的修改，必须安装构建产物并验证真实桌面组件，纯命令行测试不能替代这一步。

Tests 中使用合成账号、临时偏好域和 fake-codex.py。不要添加读取开发者实际登录资料的测试。不要把 `.app`、构建目录、备份、原始系统日志、签名私钥或真实账号截图提交到仓库。

额度 UI 以实际返回窗口为准，确保单窗口、缺失字段、失败、账号切换、退出登录和缓存状态仍可区分。尽量保留平面、克制的 T3 风格。修改协议处理时兼顾 Codex 版本差异，并给出可复现的合成样例。

提交说明应包含问题、行为变化、运行的验证和未验证的平台。MIT 许可证适用于贡献，除非文件另行注明。
