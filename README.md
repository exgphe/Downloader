# Downloader

跨 macOS、iOS、visionOS 的本地媒体下载 App 与 Safari Web Extension。Safari 在 Instagram 帖子的发送键右侧、X 视频帖子的分享键右侧加入下载按钮，收集整帖媒体并保存到「照片」。主 App、系统分享面板和快捷指令也接受 YouTube、Instagram、X 链接。

所有解析在设备上完成。App 与扩展内嵌 CPython、yt-dlp、gallery-dl 和 yt-dlp-ejs；YouTube 播放器挑战由 JavaScriptCore 执行，不需要 Node、Deno、外部下载服务或 Python 子进程。Python 只提取媒体清单，Swift 负责传输、合流和 PhotoKit 保存。

App 图标使用简洁的下载箭头：iOS / macOS 共用向量 `AppIcon.icon`，支持 Icon Composer 与 Liquid Glass 外观；visionOS 使用三层 Asset Catalog 图标。母版与重新生成说明见 [图标设计](Artwork/AppIcon/README.md)。

## 使用

- 主 App：粘贴链接，选择「照片」或「文件」，点击下载。任务列表支持进度、取消与重试。
- 「照片」：选择照片库兼容的最高画质，视频使用 H.264 / HEVC 与 AAC；分离音视频无损合流为 MP4。
- 「文件」：保留最高源画质，包括 VP9 / AV1。分离音视频无损合流为 MKV，完整单文件保留原容器。完成后可以导出或分享文件；iOS 下载目录也通过「文件」App 暴露。
- 系统分享菜单：分享 YouTube、Instagram 或 X 链接并选择 Downloader，自动开始解析、下载并保存到「照片」，无需再次点击下载。解析时保持面板打开；进入传输阶段后可以用系统关闭按钮关闭面板，系统后台传输会继续。需要「文件」模式时，在主 App 或快捷指令中选择。
- 快捷指令：使用「Download media」动作传入链接与保存位置。照片真正保存后才返回成功；文件以 `IntentFile[]` 返回，可接「存储文件」动作。短任务可以不打开主 App，长任务受快捷指令运行时间限制。
- Safari：开启扩展并允许访问 Instagram / X，使用帖子内的下载按钮。Safari 继续优先使用完整网页元数据；主 App 与系统分享的 Instagram 路径使用 gallery-dl。

## 同步 Instagram 登录

如果主 App 或分享面板提示 Instagram 需要登录：

1. 手动打开 Safari，在地址栏输入 `https://www.instagram.com/`，登录需要使用的账号。Instagram App 内的登录会话不能直接使用。
2. 允许 Downloader 扩展访问 Instagram，在 Safari 的 Downloader 弹窗中点击「同步 Instagram 登录」。需使用 Safari 18 或更新版本（iOS 18+），旧版 Safari 的 Cookie API 不能读取 HttpOnly 登录 Cookie。
3. 返回 Downloader 或 Instagram 分享面板，重试下载。遇到 Instagram 验证或会话失效时，先在 Safari 完成验证，再重新同步。

只有点击同步时才读取 Cookie；扩展只导入六种必要的 Instagram Cookie。会话保存在 App、Safari 和分享扩展共用的本机 Data Protection Keychain，使用 `AfterFirstUnlockThisDeviceOnly`，不通过 iCloud 同步，不写入下载记录、浏览器设置、Cookie 文件或日志。内嵌 gallery-dl 从钥匙串读取会话，凭据仅发送到 HTTPS 的 `instagram.com` 和 `www.instagram.com`；后台媒体 CDN 下载不携带登录 Cookie。YouTube / X 不读取此会话。

App 和 Safari 弹窗显示的是「已同步」，服务端仍可能拒绝或撤销会话。切换账号、Safari 配置文件或登录过期后请重新同步；无痕浏览会话不会自动包含。可以在主 App 或弹窗中清除已同步登录。visionOS Safari 的 Cookie 读取和完整设备流程仍需真机验证。

API 与版本依据：[Cookie API 权限](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/API/cookies/getAll)、[Safari HttpOnly 兼容性数据](https://github.com/mdn/browser-compat-data/blob/main/webextensions/api/cookies.json)、[Apple 共享 Keychain](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps)。

## 后台处理与通信

主 App 和 Share Extension 共用 App Group `group.wang.xiaolin.Downloader`。媒体清单、各任务状态和传输结果分别持久化；解析完成后并行提交全部媒体流到后台 URLSession。扩展关闭后，系统可继续传输并把后台事件交给宿主。宿主等待已经完成传输的合流、照片保存及状态写入结束，再调用系统的完成回调。每项媒体保存成功后记录进度，重试会跳过成功项，并重新解析过期链接。

iOS 26 起使用 `BGContinuedProcessingTask` 延续用户在前台发起的任务；iOS 27 使用新的异步提交 API。系统取消会停止任务与传输。系统可拒绝提交、终止扩展或中断后续处理，因此不能保证无限后台执行。强制划掉 App 后可能需要重新打开 Downloader；若任务仍显示传输中，可取消后重试。

Apple 资料：[长时间后台任务](https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados)、[持续任务请求](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest)、[后台 URLSession](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)。Instagram 实际分享内容、PhotoKit 授权以及扩展到宿主的后台交接仍需真实 iPhone 验收。

Safari 的 `browser.runtime.sendNativeMessage` 到达 `SafariWebExtensionHandler` 的 `NSExtensionRequestHandling`，不会直接调用主 App。Safari 下载在原生 Safari 扩展中执行；App Group 共享数据本身不能保证启动 App。详见 [Apple Safari 消息文档](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)。

## 构建

需要 Xcode 与 uv。开发机 Python 和 Xcode 打包步骤均通过 uv 管理。首次准备固定版本依赖：

```sh
uv run --no-project --script Scripts/bootstrap_runtime.py
uv run --no-project --script Scripts/bootstrap_ffmpeg.py
```

Python 可用 `--platform macOS`、`--platform iOS`、`--platform visionOS` 限定平台；FFmpeg 可用 `--variant macos-arm64` 等限定切片。后续可加 `--offline`。版本、下载地址与 SHA-256 位于 `Dependencies/runtime-lock.json`；下载及构建产物不进入 Git。

| Scheme | 最低系统 | 嵌入扩展 |
| --- | --- | --- |
| Downloader (macOS) | macOS 12 | Safari + Share |
| Downloader (iOS) | iOS 17 | Safari + Share |
| Downloader (visionOS) | visionOS 26 | Safari + Share |

选择自己的签名团队，并让 App、Safari 和 Share 的 App Group 与 Keychain Sharing 一致。登录共享组为 `$(AppIdentifierPrefix)wang.xiaolin.Downloader.instagram-session`，Info 中的 `DownloaderKeychainAccessGroup` 必须展开成相同值；不要硬编码开发团队前缀。新增能力后从主 App Scheme 重新 Run，安装完整 App 与扩展。Python 框架与原生模块只放在宿主 `Frameworks`；各进程有独立资源目录。iOS / visionOS 模块使用 `.fwork` / `.origin` 指针加载，不在扩展中保留 `.so`，遵循 [Python 官方 iOS 嵌入布局](https://docs.python.org/3.13/using/ios.html)。打包使用父 App 的签名身份，在修改资源后重新签名各扩展并保留 entitlements。

请运行上表中的主 App Scheme，它会在嵌入扩展后为所有进程打包运行时。标准库、第三方包和解析脚本分别位于 `python`、`python-packages`、`python-bootstrap`，避免 Mac 构建卷把 `Python` 与 `python` 合并后在 iPhone 上失效。打包和原生启动检查都按目录实际名称核验大小写；缺少组件会明确指出原因。

无签名编译示例：

```sh
xcodebuild -project Downloader.xcodeproj -scheme 'Downloader (macOS)' \
  -destination 'generic/platform=macOS' -configuration Debug \
  -derivedDataPath /tmp/DownloaderBuild-macOS CODE_SIGNING_ALLOWED=NO build
```

移动端可用 `generic/platform=iOS`、`generic/platform=iOS Simulator`、`generic/platform=visionOS` 和 `generic/platform=visionOS Simulator`。固定版本的 visionOS Python 仅提供 arm64 模拟器切片；iOS 模拟器支持 arm64 / x86_64。

FFmpeg 8.0.1 仅启用本地容器读写和压缩包合流，没有编码器、解码器、网络、命令行工具或 GPL 组件。静态库以扩展兼容选项构建，各资源包保留 LGPL 许可证。锁文件提供对应源码，`Scripts/bootstrap_ffmpeg.py` 和各切片 `build.json` 保留完整构建参数。可以修改或替换源码、重建静态库，再通过本项目重新链接应用。CPython 与 Python 包的许可证也随资源打包。

## 检查

```sh
node --test Tests/extension/*.test.cjs
uv run --no-project Tests/test_embedded_resolver.py
uv run --no-project Tests/test_app_resolver.py
uv run --no-project Tests/test_runtime_packaging.py
uv run --no-project --script Scripts/test_embedded_runtime.py
uv run --no-project --script Scripts/test_embedded_media.py
uv run --no-project --script Scripts/test_media_remux.py
```

原生恢复测试使用可控的系统边界验证真实下载中心，避免网络与照片权限提示：

```sh
xcrun swiftc -module-cache-path /tmp/downloader-recovery-tests \
  'Shared (Core)/NativeMediaRequest.swift' 'Shared (Core)/DownloadModels.swift' \
  'Shared (Core)/DownloadStoragePolicy.swift' \
  'Shared (Core)/DownloadCenter.swift' Tests/DownloadCenterRecoveryTests.swift \
  -o /tmp/downloader-recovery-tests-bin
/tmp/downloader-recovery-tests-bin
xcrun swiftc -module-cache-path /tmp/downloader-session-tests \
  'Shared (Core)/NativeMediaRequest.swift' 'Shared (Core)/InstagramSessionStore.swift' \
  Tests/InstagramSessionTests.swift -o /tmp/downloader-session-tests-bin
/tmp/downloader-session-tests-bin
xcrun swiftc -module-cache-path /tmp/downloader-transfer-tests \
  'Shared (Core)/NativeMediaRequest.swift' 'Shared (Core)/DownloadModels.swift' \
  'Shared (Core)/DownloadStoragePolicy.swift' 'Shared (Core)/BackgroundDownloadSession.swift' \
  Tests/BackgroundDownloadStorageTests.swift -o /tmp/downloader-transfer-tests-bin
/tmp/downloader-transfer-tests-bin
xcrun swiftc -module-cache-path /tmp/downloader-share-tests \
  'Shared (Core)/NativeMediaRequest.swift' 'Shared (Core)/DownloadModels.swift' \
  'Share (Extension)/ShareDownloadModel.swift' Tests/ShareDownloadModelTests.swift \
  -o /tmp/downloader-share-tests-bin
/tmp/downloader-share-tests-bin
xcrun swiftc -module-cache-path /tmp/downloader-size-tests \
  'Shared (Core)/NativeMediaRequest.swift' 'Shared (Core)/MediaDownload.swift' \
  Tests/MediaDownloadSizeTests.swift -o /tmp/downloader-size-tests-bin
/tmp/downloader-size-tests-bin
```

来源与文件校验测试位于 `NativeMediaPolicyTests.swift`、`DownloadSourcePolicyTests.swift` 和 `NativeMediaValidationTests.swift`，共享源文件均位于 `Shared (Core)`。嵌入解释器测试验证 Swift → Python → JavaScriptCore 挑战执行、gallery-dl 混合轮播清单和连续/并发调用；合流测试调用产品静态库，用 ffprobe 检查音视频编码与数据保留。

`BackgroundDownloadStorageTests.swift` 直接验证产品后台下载类与 URLSession 下载委托，通过内存响应覆盖尚不存在的目标文件、系统路径别名、文件搬运和恢复清理。目标路径按最近存在祖先的真实位置校验，避免 `/var` / `/private/var` 等别名导致合法下载被拒绝；最终移动文件前再次检查目录边界，拒绝越界或失效符号链接。

`ShareDownloadModelTests.swift` 使用真实分享模型和 `NSItemProvider` 验证自动下载、重复加载、链接校验与失败重试；仅替换任务中心边界。`MediaDownloadSizeTests.swift` 把生成的 513 MiB 响应通过真实 Safari 下载类流式写入临时磁盘，并验证空文件仍被拒绝；测试不使用网络，完成后清理临时文件。后台下载测试也覆盖超过原 20 GB 上限的声明长度。

## 支持范围

- YouTube 选择可直接下载的完整视频 / 音频流；不支持直播、即将开始的直播、DRM、仅分片/HLS 的格式或整张播放列表。
- Instagram 可由用户主动同步 Safari 登录；Instagram App 的登录、Safari 账号切换与登出不会自动同步到 Downloader。公开内容也可能遇到 YouTube 验证、Instagram 登录限制、地区限制或限流。
- 下载流式写入磁盘，不设固定文件大小上限，实际可下载大小取决于设备可用空间。App / Share 后台资源超时为 24 小时，Safari 原路径保留 90 秒期限；Python 提取有网络与执行期限。
- Photos 编解码器支持取决于设备和系统；不兼容的格式可选择「文件」。图片优先保留原格式，Photos 不兼容的 WebP / AVIF 会在尺寸限制内转为 JPEG。
- 编译和模拟数据测试不能代替真实网站、照片库与设备后台生命周期验证。BeeWare 预编译 Python 没有 `MH_APP_EXTENSION_SAFE` 标记，发布前应以扩展兼容选项重建并完成设备验收。
