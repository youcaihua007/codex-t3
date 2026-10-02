# 发布指南

源码公开和公众应用发行是两个步骤。源码包不含作者账号、编译产物或开发者证书。当前本地 1.0 应用已完成 ad-hoc 签名验证，但尚未完成 Developer ID 签名、公证和其他系统版本实机验证。

## 源码仓库

1. 确认仓库名称、发布者、许可证与版权信息；当前准备的是 MIT。
2. 将本目录作为仓库根目录，检查 `.gitignore` 和待提交文件。不要将整个旧工作目录上传。
3. 在 GitHub 上创建仓库，上传源码后启用私密漏洞报告。Actions 只运行测试 / 构建 / 上传构建附件，不创建公众 Release。
4. 建议在首个 Release 中说明实际测试范围：macOS 27 / Apple Silicon；Intel 仅编译通过，macOS 14–26 未验证。部署目标不等于实机兼容性保证。

## 构建与签名

本地开发：

```sh
python3 Scripts/test.py
python3 Scripts/test-sandbox-bridge.py
python3 Scripts/build.py --arch universal --derived-data /tmp/codex-t3-release
```

若要通过默认 Gatekeeper 检查，需要自己的 Apple Developer ID Application 证书并完成公证。GitHub 分发本身不要求这些，也不需要上架 App Store。未公证包应写清首次打开可能被拦截及 Apple 的手动允许步骤。证书与私钥保存在钥匙串，不能写入源码仓库。可使用脚本参数传入已经存在于钥匙串的签名身份和团队 ID：

```sh
python3 Scripts/build.py --arch universal --derived-data /tmp/codex-t3-release   --identity "Developer ID Application: YOUR NAME (YOUR_TEAM_ID)" --team YOUR_TEAM_ID
```

项目启用了 hardened runtime。签名后分别核对主程序和嵌套组件的 Developer ID、entitlements 与 runtime 选项。当前 ad-hoc 构建的验证不能代替这一验证。Apple 的流程见 [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)。

## 公证与发行包

在本机钥匙串配置自己的 notarytool 凭据 profile，再执行：

```sh
python3 Scripts/package.py "/tmp/codex-t3-release/Build/Products/Release/Codex T3.app"
xcrun notarytool submit dist/Codex-T3-1.0-universal.zip --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple "/tmp/codex-t3-release/Build/Products/Release/Codex T3.app"
xcrun stapler validate "/tmp/codex-t3-release/Build/Products/Release/Codex T3.app"
spctl --assess --type execute --verbose=2 "/tmp/codex-t3-release/Build/Products/Release/Codex T3.app"
python3 Scripts/package.py "/tmp/codex-t3-release/Build/Products/Release/Codex T3.app"
```

最后一次打包是为了包含 stapled ticket；它会重新生成 SHA-256 文件。公证返回成功后才可宣称已公证。命令里的版本文件名应随版本更新。不要将 Apple 凭据填入命令记录或 Issues。

生成面向用户的拖拽安装 DMG，打包工具仅用于开发，不进入 App：

```sh
python3 -m venv /tmp/codex-t3-packaging
/tmp/codex-t3-packaging/bin/python -m pip install -r Scripts/requirements-packaging.txt
/tmp/codex-t3-packaging/bin/python Scripts/package-dmg.py "/tmp/codex-t3-release/Build/Products/Release/Codex T3.app"
```

DMG 打包环境需要 Python 3.10+。窗口提供 App、Applications 快捷方式和中英文拖拽指引；README、源码及开发工具不混入安装盘，MIT 许可证保存在 App 资源中。更新用 ZIP 也只包含 App。检查 DMG 校验、可挂载性、Finder 实际布局、复制到 Applications 后运行及退出安装盘后的小组件。

Developer ID 分发时先给 App 完成公证并 staple，再重新生成 ZIP 和 DMG。需要将 DMG 本身也公证时，对最终 DMG 执行 notarytool submit 与 stapler staple，随后重新生成它的 SHA-256；不能沿用 staple 前的校验值。

上传 DMG 与对应 SHA-256、更新 ZIP 与对应 SHA-256 作为 GitHub Release 附件，源码留在仓库；不要把 `.app` 直接提交到 git 历史。未公证的本地测试包不要标为已公证。

## 图标资源

主程序和扩展均使用 `Source/Assets.xcassets/AppIconT3.appiconset`，含全部 10 个 macOS 尺寸变体。平面原始图稿为 `Source/IconArtwork.png`，不作为重复资源拷入应用。修改原始图稿后执行：

```sh
xcrun swift Scripts/generate-icons.swift "$PWD"
```

这是 [Apple 支持的 app-icon 资源目录格式](https://developer.apple.com/documentation/xcode/configuring-your-app-icon)，可避免小组件图库依赖分层图标的渲染。发布时仍需检查实际图库的显示，文件可解码不能代替这一检查。

如果组件内容正常，图库左侧应用图标却持续显示系统占位图，macOS 可能保留了开发阶段的旧图标索引。在本机 macOS 27 上已确认：资源直接渲染正常，而系统图标读取持续返回占位图；备份并重建当前用户图标索引后，系统读取恢复为 C＋点阵图标。可在普通桌面用户下手动运行：

```sh
python3 Scripts/repair-widget-icon.py --dry-run
python3 Scripts/repair-widget-icon.py
```

用户应用目录安装时加 `--app "$HOME/Applications/Codex T3.app"`。脚本先验证应用签名和缓存归属，备份索引到 `~/Library/Caches/CodexT3/IconRepair/`，只重建当前用户的系统图标索引，再让小组件界面重新加载。其他应用的图标可能短暂重新加载；账号、偏好和桌面组件布局不变。不使用 sudo，也不清理系统级图标数据库。该操作只用于明确出现旧占位图时，不在安装或启动中自动运行。完成后重新打开「编辑小组件」检查实际显示。不同系统的缓存布局尚未验证，未找到对应索引时脚本会停止。

## 安装验证

```sh
python3 Scripts/install.py "/tmp/codex-t3-release/Build/Products/Release/Codex T3.app"
```

在组件图库确认小、中两种尺寸均可添加；在桌面切换尺寸后确认新读数、每条额度的重置时间、进度条、预警百分比和刷新按钮正常。覆盖仅每周窗口、无额度、离线缓存及多组重置卡明细。设置账号正确，Mach 桥接正常且没有旧 HTTP / socket 服务。检查实际 WidgetKit 扩展加载成功，不能只检查主程序还在运行。确认图库应用列表显示 T3 图标，主程序和扩展均含编译后的图标资源。安装脚本仅停掉目标安装路径的本应用进程，保留设置与旧版备份，清理的是其他副本的注册记录。

从另一个干净账号或另一台电脑验证首次激活、Codex 自动查找、未登录、离线恢复与 Gatekeeper；在 Intel 和最低支持系统上验证后再扩大支持声明。

CI 使用 GitHub 的 `xcode-27` macOS 27 ARM runner（当前为公开预览），运行非 UI 回归、真实沙盒通信测试并交叉构建通用应用，生成 ZIP 和 DMG 构建附件。它不能验证桌面 WidgetKit 激活、Intel 实机运行或 Developer ID 公证。

## 内置更新来源

项目默认内置 `https://github.com/youcaihua007/codex-t3`。关于页只显示项目链接，不提供填写、保存或更改控件；内置来源优先于旧版手动设置。维护 fork 时使用 `--repository https://github.com/OWNER/REPO` 在构建时指定自己的公开仓库。GitHub Actions 使用自身仓库地址。发布时保留 Issues 与 bug report / suggestion 模板。

应用按 GitHub 最新非草稿、非预发布 Release 检测更新。tag 使用 `v1.0` 或 `1.0` 一类数字版本号；每次更新必须递增版本，主程序和组件的 Info.plist 版本一致。首次安装提供 DMG，内置更新仍需上传标准命名的通用应用 ZIP 和 `.zip.sha256`；不要只上传源代码 ZIP。缺少兼容架构应用包或校验信息时，应用将引导手动下载。

安装在用户可写的应用目录时，内置 helper 等待主程序退出、停止自身旧组件、替换应用、重新注册并启动新实例；替换或启动请求失败时恢复旧副本。当前没有自动管理员权限提升。用户设置保留。Developer ID 发行时同团队与 Apple 证书锚点需保持一致；ad-hoc 发行依赖内置 GitHub 仓库的 HTTPS 发布信任。

首次从真实 GitHub Release 更新尚需在仓库和发布附件建立后实测；隔离测试使用拦截的 HTTP 响应和临时签名应用，不代替不同电脑、Gatekeeper 或 Intel 实机验证。

## 1.0 验收记录

1.0（构建 51）为首个公开版本。此前 2.x 是本地开发标号。已完成九组回归、真实沙盒身份与通信验证、独立源码构建、DMG/ZIP 完整性验证；另有 macOS 27.0 / M4 清理旧副本后重新安装恢复桌面组件的反馈，旧副本或缓存的具体影响未确定。

主程序和组件共用 `Source/en.lproj` 与 `Source/zh-Hans.lproj` 的本地化资源，首次安装按系统语言选取；未支持的语言回退英文。「显示与启动」可选择跟随系统、简体中文或 English，保存的选择同步至小组件及通知。验收两种语言的四个设置页、通知示例、小/中尺寸与缺失数据状态，并检查切换与重启后的选择。发布构建使用 `-Osize`、whole-module optimization 与符号剥离；图标原稿为 `Source/IconArtwork.png`，不作为重复资源拷入应用。
