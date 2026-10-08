/* Native saving is injected to test retry behavior without Safari. */
(function (root) {
    "use strict";
    function createDownloadEngine({resolveVideos, saveMedia, onProgress = () => {}, loadCheckpoint = async () => null, saveCheckpoint = async () => {}, now = Date.now}) {
        const posts = new Map();
        async function download(request) {
            let state = posts.get(request.postURL);
            if (state?.pending) return state.pending;
            if (!state || now() - state.created > 30 * 60 * 1000) {
                state = {created: now(), saved: new Set(), videos: null, resolvedAt: 0, imageCount: null, videoCount: null, loaded: false};
                posts.set(request.postURL, state);
            }
            if (posts.size > 100) for (const [key, value] of posts) {
                if (!value.pending && key !== request.postURL) { posts.delete(key); break; }
            }
            const progress = value => onProgress({postURL: request.postURL, ...value});
            const execute = async () => {
                try {
                    if (!state.loaded) {
                        let checkpoint;
                        try { checkpoint = await loadCheckpoint(request.postURL); } catch { /* Storage unavailability must not block native saving. */ }
                        if (checkpoint && now() - checkpoint.created < 30 * 60 * 1000 && checkpoint.created <= now() &&
                            Array.isArray(checkpoint.saved) && checkpoint.saved.length <= 20 && checkpoint.saved.every(key => /^(image|video):\d{1,2}$/.test(key)) &&
                            Number.isInteger(checkpoint.imageCount) && checkpoint.imageCount >= 0 && checkpoint.imageCount <= 20 &&
                            Number.isInteger(checkpoint.videoCount) && checkpoint.videoCount >= 0 && checkpoint.videoCount <= 20) {
                            state.created = checkpoint.created;
                            state.saved = new Set(checkpoint.saved);
                            state.imageCount = checkpoint.imageCount;
                            state.videoCount = checkpoint.videoCount;
                        }
                        state.loaded = true;
                    }
                    // Refresh signed photo URLs from the new extraction while keeping stable item indices.
                    const images = request.media.filter(item => item.kind === "image");
                    if (state.imageCount !== null && state.imageCount !== images.length) throw new Error("The post changed. Reload the page before retrying.");
                    state.imageCount = images.length;
                    const knownVideoCount = state.videos?.length ?? state.videoCount ?? request.expectedVideoCount;
                    const unsavedVideos = request.hasVideo && (!Number.isInteger(knownVideoCount) ||
                        Array.from({length: knownVideoCount}, (_, index) => index).some(index => !state.saved.has(`video:${index}`)));
                    if (unsavedVideos && (!state.videos || now() - state.resolvedAt > 10 * 60 * 1000)) {
                        progress({phase: "resolving", saved: state.saved.size, total: images.length});
                        const videos = await resolveVideos(request.postURL);
                        if (request.hasVideo && !videos.length) throw new Error("The video service returned no videos.");
                        if (Number.isInteger(request.expectedVideoCount) && videos.length !== request.expectedVideoCount) throw new Error("The video service did not return every video in this post. Try again.");
                        if (state.videoCount !== null && videos.length !== state.videoCount) throw new Error("The video service returned a different video count. Try again.");
                        state.videos = videos;
                        state.videoCount = videos.length;
                        state.resolvedAt = now();
                    }
                    const items = [...images, ...(state.videos || [])];
                    if (items.length > 20) throw new Error("The post contains too many media items.");
                    const failed = [];
                    const kindIndices = {image: 0, video: 0};
                    for (let index = 0; index < items.length; index++) {
                        const item = items[index];
                        const key = `${item.kind}:${kindIndices[item.kind]++}`;
                        if (state.saved.has(key)) continue;
                        progress({phase: "saving", saved: state.saved.size, total: items.length});
                        try {
                            const result = await saveMedia(item, request.postURL);
                            if (!result?.ok || result.saved !== 1) throw new Error(result?.error || "Photos did not confirm that this item was saved.");
                            state.saved.add(key);
                            try { await saveCheckpoint(request.postURL, {created: state.created, saved: [...state.saved], imageCount: images.length, videoCount: state.videoCount || 0}); }
                            catch { /* The item is already in Photos even if its retry checkpoint cannot be stored. */ }
                        } catch (error) { failed.push({index, error: error.message || "Could not save this item."}); }
                    }
                    const result = {ok: !failed.length, saved: state.saved.size, total: images.length + (state.videoCount || 0), failed: failed.length,
                        ...(failed.length ? {error: failed[0].error, retryable: true} : {})};
                    progress({phase: failed.length ? "partial" : "complete", ...result});
                    return result;
                } catch (error) {
                    return {ok: false, saved: state.saved.size, total: (state.imageCount || 0) + (state.videos?.length || 0), error: error.message || "Download failed.", retryable: true};
                }
            };
            state.pending = execute();
            try { return await state.pending; } finally { state.pending = null; }
        }
        return {download};
    }
    root.DownloaderEngine = {createDownloadEngine};
    if (typeof module === "object" && module.exports) module.exports = root.DownloaderEngine;
})(globalThis);
