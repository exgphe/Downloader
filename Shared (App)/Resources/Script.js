"use strict";
const chinese = navigator.language.toLowerCase().startsWith("zh");
const copy = chinese ? {
    title: "留住喜欢的瞬间。", subtitle: "将 Instagram 图片、视频和 X 视频，直接保存到照片。",
    destination: "→ 照片", setup: "设置一次，轻点即可保存。", enable: "启用 Safari 扩展",
    enableHint: "开启 Downloader，并允许访问 Instagram 和 X。", settings: "打开设置",
    photos: "允许保存到照片", photosHint: "Downloader 只需要添加图片和视频的权限。",
    authorize: "允许添加到照片", video: "连接视频服务",
    videoHint: "在 Safari 工具栏中打开 Downloader，填写 yt-dlp 服务地址和访问令牌。保存图片无需此服务。",
    use: "浏览帖子时，点击 Instagram 发送按钮或 X 分享按钮右侧新增的下载按钮，保存帖子的全部媒体。",
    footer: "macOS · iOS · visionOS"
} : {};
for (const element of document.querySelectorAll("[data-copy]")) {
    if (copy[element.dataset.copy]) element.textContent = copy[element.dataset.copy];
}
if (chinese) document.documentElement.lang = "zh-Hans";
function show(platform, enabled) {
    document.body.dataset.platform = platform;
    const status = document.getElementById("extension-status");
    if (platform === "mac") {
        document.getElementById("settings").textContent = chinese ? "打开 Safari 扩展设置" : "Open Safari extension settings";
        if (typeof enabled === "boolean") status.textContent = enabled
            ? (chinese ? "扩展已开启。请在 Safari 中允许访问 Instagram 和 X。" : "Extension enabled. Allow access to Instagram and X in Safari.")
            : (chinese ? "请在 Safari 设置 → 扩展中开启 Downloader。" : "Turn on Downloader in Safari → Settings → Extensions.");
    } else {
        document.getElementById("mobile-steps").textContent = chinese
            ? "前往系统设置 → App → Safari → 扩展，开启 Downloader，并允许访问两个网站。"
            : "In system Settings → Apps → Safari → Extensions, enable Downloader and allow both websites.";
        document.getElementById("settings").textContent = chinese ? "打开 Downloader 设置" : "Open Downloader settings";
    }
}
function showPhotosStatus(status) {
    const messages = chinese
        ? {authorized: "已允许添加到照片。", denied: "照片权限被拒绝，请在系统设置中允许 Downloader 添加到照片。", notDetermined: "保存前需要获得照片权限。", unknown: "无法读取照片权限状态。"}
        : {authorized: "Adding to Photos is allowed.", denied: "Photos access denied. Allow Downloader to add to Photos in system Settings.", notDetermined: "Photos permission is needed before saving.", unknown: "Photos permission is unavailable."};
    document.getElementById("photos-status").textContent = messages[status] || messages.unknown;
    document.getElementById("authorize").disabled = status === "authorized";
}
function showError(message) { document.getElementById("error").textContent = message; }
document.getElementById("settings").addEventListener("click", () => webkit.messageHandlers.controller.postMessage("open-preferences"));
document.getElementById("authorize").addEventListener("click", () => webkit.messageHandlers.controller.postMessage("authorize-photos"));
