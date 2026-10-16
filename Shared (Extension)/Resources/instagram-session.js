/* Session values stay in this explicit popup-to-native handoff, never settings. */
(function (root) {
    "use strict";
    const names = new Set(["sessionid", "csrftoken", "ds_user_id", "mid", "ig_did", "rur"]);
    const types = new Set(["importInstagramSession", "instagramSession", "clearInstagramSession"]);

    function isPopupSender(sender, getURL) {
        return !!sender && !sender.tab && sender.url === getURL("popup.html");
    }

    function selectCookies(cookies, expiryField, now = Date.now() / 1000) {
        if (!Array.isArray(cookies) || cookies.length > 100) throw new Error("invalidInstagramSession");
        const selected = [];
        const seen = new Map();
        let bytes = 0;
        let sessionValue;
        for (const cookie of cookies) {
            if (!cookie || !names.has(cookie.name) || typeof cookie.domain !== "string") continue;
            const domain = cookie.domain.toLowerCase().replace(/^\./, "");
            if (!["instagram.com", "www.instagram.com"].includes(domain) || cookie.path !== "/") continue;
            if (typeof cookie.value !== "string" || !cookie.value || /[\x00-\x20\x7f;]/.test(cookie.value)) continue;
            const valueBytes = new TextEncoder().encode(cookie.value).length;
            if (valueBytes > 8192) continue;
            if (typeof cookie.secure !== "boolean" || typeof cookie.httpOnly !== "boolean") continue;
            if (cookie.name === "sessionid" && !cookie.secure) continue;
            const expires = cookie[expiryField];
            if (expires !== undefined && (typeof expires !== "number" || !Number.isFinite(expires) || expires <= now || expires >= 2 ** 63)) continue;
            const key = domain + ":" + cookie.name;
            const item = {name: cookie.name, value: cookie.value, domain, path: "/", secure: cookie.secure, httpOnly: cookie.httpOnly};
            if (expires !== undefined) item.expires = expires;
            if (cookie.name === "sessionid") {
                if (sessionValue !== undefined && sessionValue !== cookie.value) throw new Error("invalidInstagramSession");
                sessionValue = cookie.value;
            }
            if (seen.has(key)) {
                if (JSON.stringify(seen.get(key)) !== JSON.stringify(item)) throw new Error("invalidInstagramSession");
                continue;
            }
            seen.set(key, item);
            bytes += valueBytes;
            if (bytes > 32768 || selected.length >= 24) throw new Error("invalidInstagramSession");
            selected.push(item);
        }
        if (!selected.some(cookie => cookie.name === "sessionid")) throw new Error("instagramSessionMissing");
        return selected;
    }

    async function readSession(cookiesAPI) {
        if (typeof cookiesAPI?.getAll !== "function") throw new Error("instagramCookiesUnavailable");
        let cookies;
        try { cookies = await cookiesAPI.getAll({url: "https://www.instagram.com/"}); }
        catch { throw new Error("instagramCookiesUnavailable"); }
        return selectCookies(cookies, "expirationDate");
    }

    function nativeRequest(request) {
        if (!types.has(request?.type)) return null;
        if (request.type === "importInstagramSession") {
            return {type: request.type, cookies: selectCookies(request.cookies, "expires")};
        }
        return {type: request.type};
    }

    root.DownloaderInstagramSession = {isPopupSender, readSession, nativeRequest};
    if (typeof module === "object" && module.exports) module.exports = root.DownloaderInstagramSession;
})(globalThis);
