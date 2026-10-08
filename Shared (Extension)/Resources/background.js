import "./media-core.js";
import "./download-engine.js";
import "./video-resolver.js";

const core = globalThis.DownloaderCore;
const NATIVE_APP = "wang.xiaolin.Downloader";
const activeTabs = new Map();
const localize = (key, fallback) => browser.i18n.getMessage(key) || fallback;
async function sendNative(message) {
    try { return await browser.runtime.sendNativeMessage(NATIVE_APP, message); }
    catch { throw new Error(localize("nativeUnavailable", "Downloader could not reach the native extension. Enable the extension and reopen Safari.")); }
}

const engine = globalThis.DownloaderEngine.createDownloadEngine({
    resolveVideos: globalThis.DownloaderVideoResolver.createVideoResolver({sendNative, localize}),
    async loadCheckpoint(postURL) {
        const key = `downloadCheckpoint:${postURL}`;
        return (await browser.storage.local.get(key))[key] || null;
    },
    async saveCheckpoint(postURL, checkpoint) {
        await browser.storage.local.set({[`downloadCheckpoint:${postURL}`]: checkpoint});
    },
    saveMedia(item, referrer) {
        return sendNative({type: "saveMedia", item, referrer});
    },
    onProgress(progress) {
        const target = activeTabs.get(progress.postURL);
        if (target !== undefined) browser.tabs.sendMessage(target, {type: "downloadProgress", ...progress}).catch(() => {});
    }
});

// Retain no expired retry history or signed CDN URLs in settings.
browser.storage.local.get(null).then(async entries => {
    const stale = Object.entries(entries).filter(([key, value]) => key.startsWith("downloadCheckpoint:") &&
        (!value?.created || Date.now() - value.created > 30 * 60 * 1000)).map(([key]) => key);
    // Remove obsolete external endpoint settings when upgrading.
    if ("resolverURL" in entries) stale.push("resolverURL");
    if ("resolverToken" in entries) stale.push("resolverToken");
    if (stale.length) await browser.storage.local.remove(stale);
}).catch(() => {});

browser.runtime.onMessage.addListener(async (request, sender) => {
    if (request?.type === "nativeStatus") {
        if (sender.tab || !sender.url?.startsWith(browser.runtime.getURL(""))) return {ok: false, error: "Unauthorized request."};
        try { return await sendNative({type: "status"}); }
        catch (error) { return {ok: false, error: error.message}; }
    }
    if (request?.type !== "downloadPost") return undefined;
    try {
        if (!Number.isInteger(sender.tab?.id)) throw new Error("A browser tab is required.");
        const validated = core.validatePostRequest(request, sender.url || sender.tab.url);
        activeTabs.set(validated.postURL, sender.tab.id);
        if (activeTabs.size > 100) activeTabs.delete(activeTabs.keys().next().value);
        return await engine.download(validated);
    } catch (error) { return {ok: false, saved: 0, error: error.message}; }
});
