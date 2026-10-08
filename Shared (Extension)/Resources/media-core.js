/* Shared, dependency-free protocol and media validation. Also loaded by node:test. */
(function (root) {
    "use strict";
    const MAX_ITEMS = 20;
    function parsedURL(value) {
        if (typeof value !== "string" || value.length > 8192) return null;
        try {
            const url = new URL(value);
            return url.username || url.password ? null : url;
        } catch { return null; }
    }
    function platformForURL(value) {
        const url = parsedURL(value);
        if (!url || url.protocol !== "https:" || (url.port && url.port !== "443")) return null;
        if (["instagram.com", "www.instagram.com"].includes(url.hostname)) return "instagram";
        if (["x.com", "www.x.com", "twitter.com", "www.twitter.com"].includes(url.hostname)) return "x";
        return null;
    }
    function canonicalPostURL(value, platform) {
        const url = parsedURL(value);
        const actualPlatform = platformForURL(value);
        if (!url || !actualPlatform || (platform && actualPlatform !== platform)) return null;
        if (actualPlatform === "instagram") {
            const match = url.pathname.match(/^\/(p|reel|reels|tv)\/([A-Za-z0-9_-]{3,32})\/?$/);
            return match ? `https://www.instagram.com/${match[1] === "reels" ? "reel" : match[1]}/${match[2]}/` : null;
        }
        const match = url.pathname.match(/^\/(?:([A-Za-z0-9_]{1,15})\/status|i\/web\/status)\/(\d{1,25})(?:\/.*)?$/);
        return match ? `https://x.com/${match[1] || "i/web"}/status/${match[2]}` : null;
    }
    function allowedMediaURL(value) {
        const url = parsedURL(value);
        if (!url || url.protocol !== "https:" || (url.port && url.port !== "443")) return false;
        const host = url.hostname.toLowerCase();
        return host === "cdninstagram.com" || host.endsWith(".cdninstagram.com") ||
            host === "fbcdn.net" || host.endsWith(".fbcdn.net") ||
            host === "video.twimg.com" || host === "pbs.twimg.com";
    }
    function validateResolverURL(value) {
        const url = parsedURL(value);
        if (!url || url.search || url.hash) return null;
        const local = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
        if (url.protocol !== "https:" && !(local && url.protocol === "http:")) return null;
        if (/[%\\]/.test(url.pathname) || url.pathname.includes("//")) return null;
        return url.href.replace(/\/+$/, "");
    }
    function serviceMediaURL(value, baseURL, jobID) {
        const base = validateResolverURL(baseURL);
        if (!base || typeof value !== "string" || typeof jobID !== "string") return null;
        try {
            // The service is proxy-prefix-agnostic: /v1/... is relative to its configured base.
            const url = new URL(value.startsWith(`/v1/jobs/${jobID}/media/`) ? `${base}${value}` : value, `${base}/`);
            const baseParsed = new URL(base);
            if (url.origin !== baseParsed.origin || url.username || url.password || url.search || url.hash) return null;
            const expected = `${baseParsed.pathname.replace(/\/$/, "")}/v1/jobs/${jobID}/media/`;
            if (!url.pathname.startsWith(expected)) return null;
            const filename = url.pathname.slice(expected.length);
            if (!/^[A-Za-z0-9_.-]{1,180}\.mp4$/i.test(filename) || filename.includes("..")) return null;
            return url.href;
        } catch { return null; }
    }
    function shortcodeToMediaID(shortcode) {
        if (!/^[A-Za-z0-9_-]{3,32}$/.test(shortcode)) return null;
        const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        let result = 0n;
        for (const character of shortcode) result = result * 64n + BigInt(alphabet.indexOf(character));
        return result.toString();
    }
    function bestCandidate(candidates) {
        if (!Array.isArray(candidates)) return null;
        return candidates.filter(item => item && allowedMediaURL(item.url || item.src))
            .sort((a, b) => ((b.width || b.config_width || 0) * (b.height || b.config_height || 0)) - ((a.width || a.config_width || 0) * (a.height || a.config_height || 0)))[0] || null;
    }
    function mediaFromNode(node, index) {
        if (!node || typeof node !== "object") return null;
        const isVideo = node.media_type === 2 || node.is_video === true || node.__typename === "GraphVideo";
        const candidate = isVideo ? bestCandidate(node.video_versions) : bestCandidate(node.image_versions2?.candidates || node.display_resources);
        const value = candidate?.url || candidate?.src || (isVideo ? node.video_url : node.display_url);
        const kind = isVideo ? "video" : "image";
        return {kind, ...(allowedMediaURL(value) ? {url: value} : {}), filename: `instagram-${index + 1}.${isVideo ? "mp4" : "jpg"}`};
    }
    function instagramMetadata(payload, shortcode) {
        const candidates = [];
        if (payload?.items?.[0]) candidates.push(payload.items[0]);
        const stack = [payload];
        let visited = 0;
        while (stack.length && visited++ < 30000) {
            const item = stack.pop();
            if (!item || typeof item !== "object") continue;
            if ((item.shortcode === shortcode || item.code === shortcode) &&
                (item.carousel_media || item.edge_sidecar_to_children || item.image_versions2 || item.display_url || item.video_versions)) candidates.push(item);
            for (const child of Object.values(item)) if (child && typeof child === "object") stack.push(child);
        }
        for (const node of candidates) {
            if ((node.code || node.shortcode) && (node.code || node.shortcode) !== shortcode) continue;
            const children = node.carousel_media || node.edge_sidecar_to_children?.edges?.map(edge => edge.node);
            if ((node.media_type === 8 || node.__typename === "GraphSidecar") && !children) continue;
            const nodes = children || [node];
            if (!Array.isArray(nodes) || !nodes.length || nodes.length > MAX_ITEMS) continue;
            const declaredCounts = [node.carousel_media_count, node.edge_sidecar_to_children?.count].filter(count => count !== undefined && count !== null);
            if (declaredCounts.some(count => !Number.isInteger(count) || count !== nodes.length)) continue;
            const media = nodes.map(mediaFromNode);
            if (media.some(item => !item || (item.kind === "image" && !item.url))) continue;
            return {media, complete: true, expectedMediaCount: nodes.length, hasVideo: media.some(item => item.kind === "video"), source: "metadata"};
        }
        return null;
    }
    function validatePostRequest(request, senderURL) {
        if (!request || request.type !== "downloadPost") throw new Error("Invalid download request.");
        const platform = platformForURL(senderURL);
        if (!platform || request.platform !== platform) throw new Error("This website cannot request a download.");
        const postURL = canonicalPostURL(request.postURL, platform);
        if (!postURL) throw new Error("Invalid post URL.");
        if (request.complete !== true) throw new Error("Could not read every item in this post. Open the post, then try again.");
        if (!Array.isArray(request.media) || request.media.length > MAX_ITEMS) throw new Error("Invalid media list.");
        const media = request.media.map((item, index) => {
            if (!item || !["image", "video"].includes(item.kind)) throw new Error("Invalid media type.");
            if (item.kind === "image" && !allowedMediaURL(item.url)) throw new Error("An image URL is not from an approved media host.");
            if (item.url && !allowedMediaURL(item.url)) throw new Error("A media URL is not from an approved media host.");
            return {kind: item.kind, ...(item.url ? {url: item.url} : {}), filename: `${platform}-${index + 1}.${item.kind === "video" ? "mp4" : "jpg"}`};
        });
        const hasVideo = request.requiresResolver === true || media.some(item => item.kind === "video");
        if (!media.length && !hasVideo) throw new Error("No downloadable media found.");
        if (platform === "x" && !hasVideo) throw new Error("This X post has no video.");
        const expectedVideoCount = platform === "instagram" ? media.filter(item => item.kind === "video").length : null;
        return {platform, postURL, media, hasVideo, expectedVideoCount};
    }
    const core = {MAX_ITEMS, canonicalPostURL, platformForURL, allowedMediaURL, validateResolverURL, serviceMediaURL, shortcodeToMediaID, instagramMetadata, validatePostRequest};
    root.DownloaderCore = core;
    if (typeof module === "object" && module.exports) module.exports = core;
})(globalThis);
