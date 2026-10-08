/* Use authenticated Instagram metadata when complete; otherwise resolve inside the native extension. */
(function (root) {
    "use strict";
    const core = root.DownloaderCore || (typeof require === "function" ? require("./media-core.js") : null);
    function createVideoResolver({sendNative, localize = (key, fallback) => fallback}) {
        return async function resolveVideos(postURL, request) {
            const declared = request?.media?.filter(item => item.kind === "video") || [];
            if (request?.platform === "instagram" && request.mediaSource === "metadata" &&
                declared.length > 0 && declared.length === request.expectedVideoCount &&
                declared.every(item => core.allowedMediaURL(item.url))) {
                return declared.map((item, index) => ({url: item.url, kind: "video", filename: "instagram-video-" + (index + 1) + ".mp4"}));
            }
            const result = await sendNative({type: "resolvePost", postURL});
            if (!result?.ok) throw new Error(typeof result?.error === "string" ? result.error.slice(0, 500) :
                localize("resolveFailed", "The built-in video engine could not process this post."));
            if (!Array.isArray(result.media) || !result.media.length || result.media.length > core.MAX_ITEMS) {
                throw new Error(localize("invalidVideoResult", "The built-in video engine returned an invalid media list."));
            }
            return result.media.map((item, index) => {
                if (item?.kind !== "video" || !core.allowedMediaURL(item.url)) {
                    throw new Error(localize("unsafeVideoURL", "The built-in video engine returned an unsupported media URL."));
                }
                return {url: item.url, kind: "video", filename: "video-" + (index + 1) + ".mp4"};
            });
        };
    }
    root.DownloaderVideoResolver = {createVideoResolver};
    if (typeof module === "object" && module.exports) module.exports = root.DownloaderVideoResolver;
})(globalThis);
