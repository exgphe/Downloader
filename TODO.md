- [x] 三端主 App 支持 YouTube URL 输入、下载与系统分享。照片选择最高兼容 H.264/HEVC + AAC，文件保留最高源画质（含 VP9/AV1）；分离流本地无损合流。新增任务进度、取消、重试和文件导出。
- [x] iOS 后台 URLSession 与任务持久化；iOS 26 持续后台处理、iOS 27 异步提交 API。系统取消停止任务，后台恢复等待合流与实际保存完成。
- [x] 三端 Share Extension 接收链接；Instagram 使用内嵌 gallery-dl，可在分享面板中下载和保存照片。Shortcuts 动作无需主动打开 App，文件返回给后续「存储文件」动作。
- [x] Instagram 单条 Story 图片 / 视频下载：App、分享菜单、快捷指令识别带 Story ID 的链接；Safari 优先提取匹配 ID 的媒体，使用同步登录的内置 gallery-dl 作为回退，过期或删除时明确报错。
- [x] 修复 Instagram 下载按钮错位：识别真实横向操作栏，跳过发送按钮内部的纵向容器；对齐纸飞机图标中心，并在页面重绘、窗口变化后校正。60 项扩展测试与 12 项真实 WebKit 离线布局检查通过；当前在线 Instagram 页面仍需加载新扩展后验收。
- [x] 修复 iPhone 分享时报媒体引擎不可用：将解析脚本移到独立 `python-bootstrap`，避免 `Python` / `python` 大小写碰撞；打包与启动加入精确路径检查，缺组件给出具体错误。
- [x] Instagram 登录同步：用户在 Safari 登录后，从 Downloader 弹窗主动同步 Cookie；本机共享 Keychain 供 App / Share 的内嵌 gallery-dl 使用。新增同步状态、清除与登录失败重试指引，限制凭据只发送到 Instagram 的两个 HTTPS 主机。读取 HttpOnly 需 Safari 18+。
- [x] 修复 iPhone 登录同步后下载图片时报下载目录错误：对既有容器与未创建目标使用一致的真实路径解析，兼容系统路径别名；文件落地前复查容器边界，后台恢复与确认清理也使用相同规则。真实 URLSession / 原生下载委托的 56 项无网络回归检查通过。
- [x] macOS Safari popup 固定 350px，修复原截图中的收缩与截断。原参考：![Screenshot](<Screenshot 2026-10-08 at 20.48.28.png>)
- [x] visionOS Safari popup 根据原生平台信息使用 480px 宽度，放大文字并将登录操作按钮提高到 44px；保留 macOS / iOS 350px。四语言 WebKit 布局检查覆盖正常状态与长错误消息，真机弹窗尺寸仍需安装新版后复验。

当前 Safari 注册了多份旧构建，实际弹窗仍显示旧缓存；新签名 App 包里的 CSS 已确认正确。需要从当前 Xcode 项目重新 Run，确认 Safari 使用当前构建后复验弹窗。此轮没有改动网站访问权限或其他扩展设置。

已验证：三端与移动端模拟器完整构建，macOS / visionOS 真实签名构建；实际公开 YouTube 元数据提取；原生 JavaScriptCore 签名挑战；gallery-dl 混合轮播清单；H.264/HEVC/VP9/AV1 合流的压缩包逐一一致；任务恢复、取消、失败重试与多进程打包检查。

登录同步已验证：51 项扩展测试、26 项媒体解析测试、65 项原生会话校验与隔离存储检查、实际 CPython / gallery-dl 会话注入、登录失败持久化与重试；三端签名构建通过，九个 target 的签名访问组与 Info 配置一致。会话测试使用模拟 Cookie，未读取用户真实登录凭据。

- [ ] 真机验收：Instagram App 分享内容、Photos 首次授权与完整轮播保存、分享面板关闭后的系统传输与宿主保存交接、iOS 后台任务 Live Activity 取消，以及不同设备的照片编解码器支持。
- [ ] 登录同步真机验收：iPhone Safari 登录→弹窗同步→Instagram App 分享重试；账号切换、失效验证、清除后重新同步，以及 visionOS Safari 的 Cookie API 支持。
- [ ] Story 真机验收：已同步 Safari 登录的 iPhone 分享单条 Story 图片 / 视频，确认照片保存；Safari 按钮随 Story 切换更新、过期与无权限内容报错。已通过三端无签名构建、Story API / GraphQL 模拟响应和真实内嵌 CPython 解析测试，尚未验证用户提供链接的在线内容。

后台执行受系统调度和分享扩展生命周期限制。解析时应保持分享面板打开；被系统终止或用户强制划掉 App 后可能需要重新打开并重试。登录、反爬、地区限制和直播/DRM 的支持范围见 [README](README.md)。
