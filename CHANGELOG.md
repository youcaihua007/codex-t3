# Changelog

## 1.1 — 2026-10-02

构建 52，修复检测更新因 GitHub 公共 API 限流而失败的问题。

- 优先从最新正式 Release 读取小型更新清单，不消耗 REST API 的未登录检测限额；旧版本或 fork 没有清单时兼容原 API。
- 更新清单随 ZIP 自动生成，包含版本、包大小、下载链接与 SHA-256；继续验证仓库归属、压缩包结构、主程序及组件签名。
- 取消检测或退出应用后不再启动备用请求；不增加后台定时器、账号授权或设置项。
- 增加限流、清单缺失/损坏、取消/退出与失败备用请求的回归检查。

Build 52 fixes update checks failing when GitHub's public REST API is rate-limited. Checks now prefer a small manifest attached to the latest stable release, retain the API for older releases/forks, and preserve package integrity and signature checks. No extra background timer, account access or setting is required.

## 1.0 — 2026-10-02

首个公开版本，构建 51。此前 2.x 标号仅用于本地开发，未作为公开正式版本发行。

- 原生小、中尺寸 Codex 额度小组件，T3 平面风格、进度条、重置日期与重置卡到期信息。
- 跟随本机 Codex 登录，设置显示当前账号，自动刷新可选每 1、2、5 分钟。
- 独立菜单栏显示与通知开关，预警阈值、恢复提醒、账号切换和每周余量提醒。
- 软件界面随系统语言自动切换简体中文或英文；其他语言回退英文。
- 显示与启动中新增跟随系统、简体中文、English 语言选择，首次安装默认跟随系统，手动选择保存并同步到小组件和通知。
- 英文使用 Usage limits、Remaining allowance 和 Rate-limit resets 等官方术语；核对所有译文、单复数、阈值条件和组件显示长度。
- 关于页展示可点击的完整 GitHub 链接，更新与反馈来源在构建时固定。
- 清理旧的仓库编辑代码、启动调试查询和未使用的图标配置；发布构建优化体积并剥离冗余符号。

- 修复首次安装时组件通信对私有沙盒容器的依赖；改为双方签名校验的 Mach 消息，支持本机与 Rosetta 切片。
- 提供平面 T3 风格的 DMG 拖拽安装窗口；自动更新 ZIP 只包含 App，许可证内置。
