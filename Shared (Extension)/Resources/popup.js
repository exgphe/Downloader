const t = (key, substitutions) => browser.i18n.getMessage(key, substitutions) || key;
for (const element of document.querySelectorAll("[data-i18n]")) element.textContent = t(element.dataset.i18n);
document.documentElement.lang = browser.i18n.getUILanguage();
const photosStatus = document.getElementById("photos-status");
const photosDot = document.getElementById("photos-dot");
const videoStatus = document.getElementById("video-status");
const videoDot = document.getElementById("video-dot");

try {
    const result = await browser.runtime.sendMessage({type: "nativeStatus"});
    const authorization = result?.photosAuthorization;
    const labels = {authorized: "photosReady", limited: "photosReady", notDetermined: "photosFirstSave", denied: "photosDenied", restricted: "photosRestricted"};
    photosStatus.textContent = result?.ok ? t(labels[authorization] || "photosFirstSave") : result?.error || t("nativeUnavailable");
    photosDot.dataset.status = result?.ok && ["authorized", "limited"].includes(authorization) ? "ready" : result?.ok && authorization === "notDetermined" ? "pending" : "blocked";
    const videoEngine = result?.videoEngine;
    videoStatus.textContent = result?.ok && videoEngine?.available
        ? (videoEngine.version ? t("videoEngineVersion", String(videoEngine.version)) : t("videoEngineReady"))
        : videoEngine?.error || result?.error || t("videoEngineUnavailable");
    videoDot.dataset.status = result?.ok && videoEngine?.available ? "ready" : "blocked";
} catch {
    photosStatus.textContent = videoStatus.textContent = t("nativeUnavailable");
    photosDot.dataset.status = videoDot.dataset.status = "blocked";
}
