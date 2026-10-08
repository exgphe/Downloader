# Downloader

面向 macOS、iOS 和 visionOS 的 Safari Web Extension。Instagram 帖子的发送按钮右侧、X 视频帖子的分享按钮右侧会出现下载按钮。点击后收集帖子的媒体，通过原生 PhotoKit 保存到系统“照片”。

## 当前实现

- Instagram：图片、视频、混合轮播；优先读取当前登录会话下的帖子元数据，选取最大的图片版本。元数据不可用时读取页面中的结构化数据，再尝试逐页读取轮播并恢复原来的位置。无法确认完整时显示错误。
- X：仅为含视频的帖子添加按钮，支持动态时间线和帖子详情。
- 照片：仅申请添加权限，下载逐项写入临时文件，保存完成后清理。显示处理进度和失败原因；30 分钟内重试跳过已经保存的项目，后台重启后也可读取本地保存记录。
- 视频：随项目提供可自行运行的 yt-dlp 服务，处理视频下载、音轨合并和 H.264/AAC MP4 转换。Safari 扩展通过令牌访问该服务，再由设备原生保存到照片。
- 配置：Safari 工具栏弹窗中设置服务地址和令牌；提供英语、简体中文、繁体中文和法语扩展文案。

## 为什么需要视频服务

yt-dlp 是 Python 程序，iOS / visionOS 的 Safari 扩展无法直接启动普通 Python/命令行子进程。macOS 扩展也受到 App Sandbox 限制。本实现让三端共享一个可配置的视频服务；图片下载不依赖服务。这里的服务是随仓库提供的独立程序，需要先运行并在扩展中配置，没有预设的公共服务器。

服务会接收点击下载的视频帖子链接。照片链接直接交给原生层下载；扩展不会向服务发送 Safari 的登录 Cookie。私有视频需要时可在自己的服务器上配置 Cookie 文件，参见 [服务说明](Server/README.md)。

## 在 Xcode 中运行

打开 `Downloader.xcodeproj`，选择对应的共享 Scheme：

| Scheme | 最低系统 | 原生入口 |
| --- | --- | --- |
| Downloader (macOS) | macOS 12 | AppKit |
| Downloader (iOS) | iOS 17 | UIKit，iPhone / iPad |
| Downloader (visionOS) | visionOS 26 | SwiftUI 窗口 |

三个 Scheme 都嵌入对应平台的 Safari 扩展，共享扩展资源和原生下载代码。选择自己的签名团队后运行应用，按应用中的引导开启扩展、允许访问 Instagram 和 X，并允许添加到照片。macOS 的应用与扩展已配置网络和照片沙盒 entitlement。

在 Safari 中登录网站并刷新页面。首次下载时系统可能再次请求照片权限。macOS 本地开发若使用未签名扩展，需要在 Safari 开发设置中允许未签名扩展；设备安装和正式分发需要正常签名。

## 运行视频服务

机器需要 `uv`、`ffmpeg` 和 `ffprobe`。在 `Server` 目录运行：

```sh
uv sync --locked
export DOWNLOADER_TOKEN="$(openssl rand -hex 32)"
uv run downloader-video-service
```

服务默认监听 `127.0.0.1:8787`。在同一台 Mac 的 Safari 扩展弹窗中填写 `http://127.0.0.1:8787` 和上述令牌，并允许访问这个服务。可在启动服务前运行 `printenv DOWNLOADER_TOKEN` 查看令牌并复制到弹窗；令牌只应提供给自己的设备。

iPhone / iPad / Apple Vision Pro 必须填写设备可访问的 HTTPS 服务地址，例如自己服务器的 `https://downloads.example.com`，或者带有效证书的局域网服务。设备上的 `127.0.0.1` 指向设备自身。服务也支持置于反向代理路径下；代理应去掉该前缀再转发到服务。

详细配置、认证接口、Cookie 设置、容量限制和测试命令见 [Server/README.md](Server/README.md)。

## 检查

网页提取、下载编排和按钮注入的离线测试：

```sh
node --test Tests/extension/*.test.cjs
```

原生 URL / 来源 / 令牌校验测试：

```sh
xcrun swiftc -module-cache-path /tmp/downloader-native-tests \
  'Shared (Extension)/NativeMediaRequest.swift' \
  Tests/NativeMediaPolicyTests.swift -o /tmp/downloader-native-policy-tests
/tmp/downloader-native-policy-tests
```

原生文件验证测试（图片原始字节保留、格式转换和无效内容拒绝）：

```sh
xcrun swiftc -module-cache-path /tmp/downloader-native-tests \
  'Shared (Extension)/NativeMediaRequest.swift' \
  'Shared (Extension)/MediaDownload.swift' \
  'Shared (Extension)/NativePhotoSaver.swift' \
  Tests/NativeMediaValidationTests.swift -o /tmp/downloader-native-validation-tests
/tmp/downloader-native-validation-tests
```

无签名构建示例，可将 Scheme 和平台替换为 `iOS` 或 `visionOS`：

```sh
xcodebuild -project Downloader.xcodeproj -scheme 'Downloader (macOS)' \
  -destination 'generic/platform=macOS' -configuration Debug \
  -derivedDataPath /tmp/DownloaderBuild-macOS CODE_SIGNING_ALLOWED=NO build
```

## 实际验证范围

自动检查覆盖三端编译、媒体解析、下载重试、原生 URL 校验，以及服务认证/作业/传输逻辑。完整下载到照片仍需在已签名的设备上、使用真实登录会话验证。Instagram 和 X 会调整网页和接口，私有内容、过期链接、网站限流与 yt-dlp 提取器变化可能导致失败；界面会显示具体错误。视频处理默认限制五分钟，原生单个文件下载限制 90 秒 / 512 MB。

已经保存的媒体序号会在设备本地保留 30 分钟作为重试记录，不包含视频服务令牌或媒体地址；超过记录有效期再次点击会重新保存。请在下载完成前保留 Safari 运行。当前没有长期后台任务恢复或跨设备下载记录。
