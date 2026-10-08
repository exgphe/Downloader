import "./media-core.js";
import "./download-engine.js";

const core = globalThis.DownloaderCore;
const NATIVE_APP = "wang.xiaolin.Downloader";
const activeTabs = new Map();
const localize = (key, fallback) => browser.i18n.getMessage(key) || fallback;
const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

async function fetchJSON(url, token, options = {}) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 20000);
    try {
        const response = await fetch(url, {
            ...options, signal: controller.signal, redirect: "error", credentials: "omit", cache: "no-store",
            headers: {"Authorization": `Bearer ${token}`, "Accept": "application/json", ...(options.body ? {"Content-Type": "application/json"} : {})}
        });
        if (!response.ok) throw new Error(response.status === 401 || response.status === 403 ?
            localize("serviceUnauthorized", "The video service rejected the access token.") : `Video service HTTP ${response.status}.`);
        const body = await response.text();
        if (body.length > 200000) throw new Error("The video service response is too large.");
        return JSON.parse(body);
    } catch (error) {
        if (error.name === "AbortError") throw new Error(localize("serviceTimeout", "Video processing timed out. Try again."));
        throw error;
    } finally { clearTimeout(timeout); }
}

async function resolveVideos(postURL) {
    const settings = await browser.storage.local.get(["resolverURL", "resolverToken"]);
    const base = core.validateResolverURL(settings.resolverURL);
    const token = typeof settings.resolverToken === "string" ? settings.resolverToken.trim() : "";
    if (!base || !token || token.length > 4096 || /[\r\n]/.test(token)) throw new Error(localize("configureService", "Set the video service URL and access token in the extension popup."));
    const created = await fetchJSON(`${base}/v1/jobs`, token, {method: "POST", body: JSON.stringify({postURL})});
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(created.id || "")) throw new Error("The video service returned an invalid job ID.");
    const deadline = Date.now() + 5 * 60 * 1000;
    let job = created;
    while (["queued", "running"].includes(job.state)) {
        if (Date.now() >= deadline) throw new Error(localize("serviceTimeout", "Video processing timed out. Try again."));
        await wait(1200);
        job = await fetchJSON(`${base}/v1/jobs/${created.id}`, token);
        if (job.id !== created.id) throw new Error("The video service returned a different job ID.");
    }
    if (job.state !== "complete") throw new Error(typeof job.error === "string" ? job.error.slice(0, 300) : localize("resolveFailed", "The video service could not process this post."));
    if (!Array.isArray(job.media) || !job.media.length || job.media.length > 20) throw new Error("The video service returned an invalid media list.");
    return job.media.map((item, index) => {
        const url = core.serviceMediaURL(item.url, base, created.id);
        if (item.kind !== "video" || !url) throw new Error("The video service returned an unsafe media URL.");
        return {url, kind: "video", filename: `video-${index + 1}.mp4`, resolverService: {url: base, token}};
    });
}

async function sendNative(message) {
    try { return await browser.runtime.sendNativeMessage(NATIVE_APP, message); }
    catch { throw new Error(localize("nativeUnavailable", "Downloader could not reach the native app. Enable the extension and reopen Safari.")); }
}

const engine = globalThis.DownloaderEngine.createDownloadEngine({
    resolveVideos,
    async loadCheckpoint(postURL) {
        const key = `downloadCheckpoint:${postURL}`;
        return (await browser.storage.local.get(key))[key] || null;
    },
    async saveCheckpoint(postURL, checkpoint) {
        await browser.storage.local.set({[`downloadCheckpoint:${postURL}`]: checkpoint});
    },
    saveMedia(item, referrer) {
        const {resolverService, ...media} = item;
        return sendNative({type: "saveMedia", item: media, referrer, ...(resolverService ? {service: resolverService} : {})});
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
