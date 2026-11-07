import "./instagram-session.js";

const t = (key, substitutions) => browser.i18n.getMessage(key, substitutions) || key;
for (const element of document.querySelectorAll("[data-i18n]")) element.textContent = t(element.dataset.i18n);
document.documentElement.lang = browser.i18n.getUILanguage();
const photosStatus = document.getElementById("photos-status");
const photosDot = document.getElementById("photos-dot");
const videoStatus = document.getElementById("video-status");
const videoDot = document.getElementById("video-dot");

try {
    const result = await browser.runtime.sendMessage({type: "nativeStatus"});
    if (["macOS", "iOS", "visionOS"].includes(result?.platform)) {
        document.documentElement.dataset.platform = result.platform;
    }
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

const sessionStatus = document.getElementById("instagram-status");
const syncButton = document.getElementById("sync-instagram");
const forgetButton = document.getElementById("forget-instagram");
const sessionError = document.getElementById("instagram-error");
function showSession(result) {
    if (!result?.ok) throw new Error(result?.code || "instagramSessionFailed");
    const status = result.instagramSession || result;
    if (status.error || typeof status.hasSession !== "boolean") throw new Error("instagramSessionFailed");
    sessionStatus.textContent = t(status.hasSession ? "instagramSessionReady" : "instagramSessionNotSynced");
}
function showSessionError(error) {
    const key = ["instagramCookiesUnavailable", "instagramSessionMissing", "invalidInstagramSession"].includes(error?.message)
        ? error.message : "instagramSessionFailed";
    sessionError.textContent = t(key);
    sessionError.hidden = false;
}
async function sessionAction(action) {
    syncButton.disabled = forgetButton.disabled = true;
    sessionError.hidden = true;
    try { await action(); }
    catch (error) { showSessionError(error); }
    finally { syncButton.disabled = forgetButton.disabled = false; }
}
syncButton.addEventListener("click", () => sessionAction(async () => {
    // Reading credentials happens only inside this explicit click handler.
    const cookies = await globalThis.DownloaderInstagramSession.readSession(browser.cookies);
    const result = await browser.runtime.sendMessage({type: "importInstagramSession", cookies});
    showSession(result);
}));
forgetButton.addEventListener("click", () => sessionAction(async () => {
    showSession(await browser.runtime.sendMessage({type: "clearInstagramSession"}));
}));
try { showSession(await browser.runtime.sendMessage({type: "instagramSession"})); }
catch (error) {
    sessionStatus.textContent = t("instagramSessionUnavailable");
    showSessionError(error);
}
