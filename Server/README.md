# 视频下载服务

Safari 扩展把 Instagram / X 帖子的地址发送给本服务。服务使用 yt-dlp 提取帖内全部视频，用 FFmpeg 合并音视频并生成适合照片图库的 H.264 / AAC MP4，再由原生应用保存到照片。Instagram 图片直接由扩展提取，不经过本服务。

Python / yt-dlp 运行在你管理的 macOS 或 Linux 机器上。iOS 和 visionOS 通过 HTTPS 访问服务，设备中无需安装 Python、yt-dlp 或 FFmpeg。

## 启动

需要 [uv](https://docs.astral.sh/uv/) 和带 H.264 / AAC 支持的 FFmpeg。macOS 可以先运行 `brew install ffmpeg`；Linux 使用发行版的 FFmpeg 包。

```sh
cd Server
uv sync --locked
export DOWNLOADER_TOKEN="$(uv run python -c 'import secrets; print(secrets.token_urlsafe(32))')"
uv run downloader-video-service
```

在扩展弹出窗口中配置视频服务地址与上述令牌。可在启动服务前运行 `printenv DOWNLOADER_TOKEN` 查看生成的令牌，并复制到自己设备的扩展弹窗。服务默认监听 `127.0.0.1:8787`，所有 API（包括视频文件）都要求 `Authorization: Bearer <令牌>`。令牌必须至少 32 字符，重启时应继续使用同一令牌；不要把令牌写入仓库或公开网页。

macOS 本机调试可使用 `http://127.0.0.1:8787`。iPhone / iPad / Vision Pro 上的 `127.0.0.1` 指向设备自身，须配置设备能够访问的 HTTPS 地址。

## HTTPS 与反向代理

可以在服务前使用 Caddy 等反向代理。配置有效域名和证书后，保持 Python 服务仅监听回环地址。例如 Caddy：

```caddyfile
video.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

扩展服务地址填写 `https://video.example.com`。如果部署在路径前缀下，代理必须去掉该前缀再转发：

```caddyfile
video.example.com {
    handle_path /downloader/* {
        reverse_proxy 127.0.0.1:8787
    }
}
```

此时服务地址填写 `https://video.example.com/downloader`。保留请求的 `Authorization`、`Range` 标头与响应的 `Content-Range`。如需局域网直接监听，可显式设置 `DOWNLOADER_HOST=0.0.0.0`，移动端仍应通过 HTTPS 访问。

## 登录与网站变更

公开帖子可能受到 Instagram / X 限流或登录要求影响。私密帖子只在服务端账户有访问权限时可下载。管理员可提供 Netscape 格式 cookie 文件：

```sh
chmod 600 /absolute/path/server-cookies.txt
export DOWNLOADER_COOKIE_FILE=/absolute/path/server-cookies.txt
uv run downloader-video-service
```

服务为每个作业复制 cookie 文件，并在作业结束后删除副本，不改写原始文件。扩展不会读取或上传 Safari 登录 cookies。请仅在自己管理、信任的服务上配置账户 cookies。

网站接口变化后可以更新 yt-dlp，并重启服务：

```sh
uv lock --upgrade-package yt-dlp
uv sync --locked
```

提取失败、缺失音轨、部分视频无法下载、超时或超出限制都会返回失败，避免把不完整的视频帖误报为成功。明确没有音轨的原始视频可以返回成功，其媒体项包含 `hasAudio: false`，作业带有 `warning`。

## API

所有请求都需要 bearer 认证；JSON 请求需要 `Content-Type: application/json`。

`POST /v1/jobs`：

```json
{"postURL":"https://www.instagram.com/p/SHORTCODE/"}
```

返回 HTTP 202：

```json
{"id":"UUID","state":"queued","media":[]}
```

`GET /v1/jobs/{id}` 返回 `queued`、`running`、`complete` 或 `failed`。成功示例：

```json
{
  "id": "UUID",
  "state": "complete",
  "media": [
    {
      "url": "/v1/jobs/UUID/media/video-001.mp4",
      "kind": "video",
      "filename": "video-001.mp4",
      "hasAudio": true
    }
  ]
}
```

`GET /v1/jobs/{id}/media/{filename}` 下载视频，支持单段 HTTP Range 和 HEAD。`GET /health` 返回服务状态。视频链接应拼接到配置的服务地址（包含其可选路径前缀），并继续附带 bearer 标头。

只接受 HTTPS Instagram `/p/`、`/reel/`、`/tv/` 帖子，以及 X `/用户/status/数字ID`、`/i/web/status/数字ID` 帖子。Twitter 域名别名会规范化为 X。不会接受任意网页、文件路径、播放列表或命令参数；只注册对应的 Instagram / Twitter 提取器。

401 表示令牌不正确，400 表示请求或帖子地址无效，429 表示队列/缓存已满，404 表示作业不存在或已过期。作业失败时 JSON 的 `error` 提供可操作的原因。

## 容量与缓存

| 环境变量 | 默认值 | 用途 |
| --- | --- | --- |
| `DOWNLOADER_HOST` | `127.0.0.1` | 监听地址 |
| `DOWNLOADER_PORT` | `8787` | 监听端口 |
| `DOWNLOADER_CACHE_DIR` | `.cache/jobs` | 私有作业缓存目录 |
| `DOWNLOADER_WORKERS` | `2` | 同时进行的视频作业数 |
| `DOWNLOADER_MAX_PENDING` | `8` | 运行中与等待中的作业总数 |
| `DOWNLOADER_MAX_JOBS` | `100` | 内存中保留的作业总数 |
| `DOWNLOADER_TTL_SECONDS` | `3600` | 完成/失败作业保留时间 |
| `DOWNLOADER_TIMEOUT_SECONDS` | `300` | 每个运行中作业的下载与转码总时限 |
| `DOWNLOADER_MAX_JOB_BYTES` | `536870912` | 单个作业磁盘占用上限（512 MiB） |
| `DOWNLOADER_MAX_CACHE_BYTES` | `2147483648` | 整体缓存上限（2 GiB） |
| `DOWNLOADER_MAX_MEDIA` | `20` | 单帖最多视频数，应与客户端的 20 项限制匹配 |
| `DOWNLOADER_COOKIE_FILE` | 未设置 | 管理员提供的服务端 cookie 文件 |

磁盘上限包含下载碎片、合并/转码时的中间文件和最终 MP4。超过限制会终止整个作业。作业运行在独立进程组中，超时/停止时同时终止 yt-dlp 与 FFmpeg；并发 HTTP 连接也有数量和超时限制。已结束作业约每 30 秒清理一次，API 访问同时检查过期状态。重启或正常退出会清理作业缓存；同一缓存目录只允许一个服务实例。

## 测试

```sh
uv run python -m unittest discover -s tests -v
```

测试使用本机回环端口，不访问 Instagram 或 X。覆盖令牌、受限 URL、队列/大小限制、失败清理、缓存锁、过期、媒体路径穿越与 HTTP Range。媒体集成测试生成短视频，模拟混合轮播帖的提取结果，实际执行 yt-dlp 和 FFmpeg 并验证所有输出的视频和音轨；未安装 FFmpeg 时该集成测试会跳过。

真实站点的登录状态、限流和 DOM/接口变化仍须在 Safari 中以实际帖子验证。
