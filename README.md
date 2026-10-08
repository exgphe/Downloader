# Downloader

跨 macOS、iOS、visionOS 的 Safari Web Extension。在 Instagram 每个帖子的发送按钮右侧、X 视频帖子的分享按钮右侧添加下载按钮，按帖收集媒体并保存到系统「照片」。支持 Instagram 图片、视频和混合轮播，以及 X 多视频帖子。页面动态加载与单页导航后会重新检查按钮，避免重复插入。

视频解析在设备本地完成：应用打包 CPython 和 yt-dlp，原生扩展直接调用 Python API。图片与完整的 Instagram 视频元数据优先从 Safari 网页收集，媒体文件由 Swift 下载，再交给 PhotoKit。

## 通信与运行时

```text
Safari content script → background.js → sendNativeMessage
                                         ↓
                              SafariWebExtensionHandler
                                  ↓               ↓
                         CPython + yt-dlp    URLSession → PhotoKit
                            视频地址            保存到照片
```

Apple 的 [Safari Web Extension 消息文档](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension) 区分网页脚本、原生扩展与包含扩展的 App。`browser.runtime.sendNativeMessage` 到达原生扩展的 `NSExtensionRequestHandling`；它不直接调用主 App。App Group 可以共享数据，但不能保证启动或唤醒主 App。macOS 提供原生向扩展发送消息的额外 API，iOS 没有同等的直接推送能力。

本项目把解析与照片保存放在原生扩展中，因此无需唤醒主 App。主 App 提供设置引导并承载 `Frameworks`；扩展经父应用的运行时搜索路径加载框架。iOS / visionOS 的 Python 原生模块转换为独立框架，并使用 CPython 的 `.fwork` / `.origin` 机制加载，移动端扩展资源中不留 `.so` 文件。这符合 [Python 官方 iOS 嵌入布局](https://docs.python.org/3.13/using/ios.html)。

[a-shell](https://github.com/holzschu/a-shell) 证实 iOS 可以内嵌 Python 与 yt-dlp。本项目使用 [BeeWare Python Apple Support](https://github.com/beeware/Python-Apple-support)，通过 C API 初始化一个隔离解释器，在串行队列中管理 GIL。yt-dlp 只提取元数据，`download=False`，不会启动 shell、FFmpeg 或外部下载器。

## 开发与构建

需要 Xcode 和 uv。开发机 Python 由 uv 管理；终端和 Xcode 的打包脚本都通过 uv 执行。首次构建前准备固定版本的依赖：

```sh
uv run --no-project --script Scripts/bootstrap_runtime.py
```

可以用 `--platform macOS`、`--platform iOS` 或 `--platform visionOS` 只准备对应平台。版本与 SHA-256 在 `Dependencies/runtime-lock.json`：CPython 3.13.16（3.13-b16 框架）、yt-dlp 2026.8.19、certifi 2026.7.22。开发依赖目录被 Git 忽略；用户安装应用后无需安装 Python。

首次准备依赖需要访问 GitHub 和 PyPI。Xcode 构建阶段仅离线打包已经准备好的文件，选择正确设备或模拟器切片、裁剪架构、嵌入框架，并在修改扩展资源后重新签名。CPython 的许可证与 Python 包的 dist-info 许可证保留在扩展资源中。更换依赖时应更新锁文件、校验和并重新执行检查。

打开 `Downloader.xcodeproj`，选择相应 Scheme：

| Scheme | 最低系统 | 主应用 |
| --- | --- | --- |
| Downloader (macOS) | macOS 12 | AppKit |
| Downloader (iOS) | iOS 17 | UIKit，iPhone / iPad |
| Downloader (visionOS) | visionOS 26 | SwiftUI |

选择自己的签名团队后运行。根据应用引导开启 Safari 扩展，允许访问 Instagram 和 X，首次下载时允许添加到照片。macOS 本地开发的未签名扩展需要 Safari 开发设置允许未签名扩展。三端均需要正常签名才能进行完整设备测试。

无签名编译示例：

```sh
xcodebuild -project Downloader.xcodeproj -scheme 'Downloader (macOS)' \
  -destination 'generic/platform=macOS' -configuration Debug \
  -derivedDataPath /tmp/DownloaderBuild-macOS CODE_SIGNING_ALLOWED=NO build
```

将 Scheme 与平台改为 `iOS` 或 `visionOS` 可以编译移动端；模拟器目标分别为 `generic/platform=iOS Simulator` 与 `generic/platform=visionOS Simulator`。

固定版本的 visionOS Python 框架仅提供 arm64 模拟器切片，项目相应排除了 x86_64；iOS 模拟器支持 arm64 与 x86_64。

## 检查

```sh
node --test Tests/extension/*.test.cjs
uv run --no-project python Tests/test_embedded_resolver.py
uv run --no-project python Tests/test_runtime_packaging.py
uv run --no-project --script Scripts/test_embedded_runtime.py
```

原生媒体来源校验：

```sh
xcrun swiftc -module-cache-path /tmp/downloader-native-tests \
  'Shared (Extension)/NativeMediaRequest.swift' \
  Tests/NativeMediaPolicyTests.swift -o /tmp/downloader-native-policy-tests
/tmp/downloader-native-policy-tests
```

原生文件格式与图片转换验证：

```sh
xcrun swiftc -module-cache-path /tmp/downloader-native-tests \
  'Shared (Extension)/NativeMediaRequest.swift' \
  'Shared (Extension)/MediaDownload.swift' \
  'Shared (Extension)/NativePhotoSaver.swift' \
  Tests/NativeMediaValidationTests.swift -o /tmp/downloader-native-validation-tests
/tmp/downloader-native-validation-tests
```

自动检查覆盖按钮位置、动态注入、混合轮播、消息接口、失败重试、CDN 校验、Python 视频格式选择与运行时打包。还验证了实际打包的 macOS CPython 能加载 `_ssl`、certifi 与 yt-dlp，并处理连续和并发解析调用；提取使用离线数据，完整网站下载到照片仍须在 Safari 与已签名设备上验证。

## 当前边界

- yt-dlp 选择最高分辨率的直接 MP4 地址。只有 HLS、直播或分离音视频的内容会报不支持；某项视频不可解析时，不会将其跳过后报告整帖成功。
- 内嵌 Python 的 CookieJar 与 Safari 登录会话独立。Instagram 完整网页元数据可直接使用已经取得的视频地址；需要登录、受保护或年龄限制的内容若走 yt-dlp，可能失败。当前没有导出 Safari Cookie 的桥接。
- Instagram / X 的网页和接口变更、限流、过期链接都可能造成失败。视频解析使用 8 秒网络超时与 40 秒 Python 执行期限，但系统 DNS 阻塞不能保证严格的墙钟期限；原生单文件下载上限为 90 秒 / 512 MB。
- 已保存的媒体序号在设备本地保留 30 分钟用于重试，不保留签名 CDN 地址。下载完成前请保留 Safari 运行；当前没有长期后台恢复。
- BeeWare 预编译 Python 框架没有 `MH_APP_EXTENSION_SAFE` 标记。三端编译与 macOS 内嵌解释器运行成功不等于已通过扩展生命周期、内存限制或 App Store 检查。发布前应审计运行时并使用扩展兼容编译选项重建，完成真实设备验证。
