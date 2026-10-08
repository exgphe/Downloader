const t = (key, substitutions) => browser.i18n.getMessage(key, substitutions) || key;
for (const element of document.querySelectorAll("[data-i18n]")) element.textContent = t(element.dataset.i18n);
document.documentElement.lang = browser.i18n.getUILanguage();
const form = document.getElementById("settings-form");
const urlInput = document.getElementById("resolver-url");
const tokenInput = document.getElementById("resolver-token");
const status = document.getElementById("settings-status");
const save = document.getElementById("save");

const settings = await browser.storage.local.get(["resolverURL", "resolverToken"]);
urlInput.value = settings.resolverURL || "";
tokenInput.value = settings.resolverToken || "";

form.addEventListener("submit", async event => {
    event.preventDefault();
    status.textContent = "";
    status.dataset.error = "false";
    const value = urlInput.value.trim();
    const url = value ? globalThis.DownloaderCore.validateResolverURL(value) : "";
    const token = tokenInput.value.trim();
    if ((value && !url) || (!url && token) || (url && !token) || token.length > 4096 || /[\r\n]/.test(token)) {
        status.dataset.error = "true";
        status.textContent = t("invalidSettings");
        return;
    }
    save.disabled = true;
    try {
        if (url && browser.permissions?.request) {
            const parsed = new URL(url);
            const granted = await browser.permissions.request({origins: [`${parsed.protocol}//${parsed.hostname}/*`]});
            if (!granted) throw new Error(t("servicePermissionDenied"));
        }
        await browser.storage.local.set({resolverURL: url, resolverToken: token});
        urlInput.value = url;
        status.textContent = t("settingsSaved");
    } catch (error) {
        status.dataset.error = "true";
        status.textContent = error.message || t("settingsSaveFailed");
    } finally { save.disabled = false; }
});

try {
    const result = await browser.runtime.sendMessage({type: "nativeStatus"});
    const authorization = result?.photosAuthorization;
    const labels = {authorized: "photosReady", limited: "photosReady", notDetermined: "photosFirstSave", denied: "photosDenied", restricted: "photosRestricted"};
    document.getElementById("photos-status").textContent = result?.ok ? t(labels[authorization] || "photosFirstSave") : result?.error || t("nativeUnavailable");
    document.getElementById("photos-dot").dataset.status = result?.ok && ["authorized", "limited"].includes(authorization) ? "ready" : result?.ok && authorization === "notDetermined" ? "pending" : "blocked";
} catch { document.getElementById("photos-status").textContent = t("nativeUnavailable"); }
