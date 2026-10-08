(() => {
    "use strict";
    if (globalThis.__downloaderContentLoaded) return;
    globalThis.__downloaderContentLoaded = true;
    const core = globalThis.DownloaderCore;
    const platform = core.platformForURL(location.href);
    if (!platform) return;
    const BUTTON_ATTRIBUTE = "data-downloader-button";
    const active = new Map();
    const t = (key, substitutions) => browser.i18n.getMessage(key, substitutions) || key;
    const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
    const normalize = text => (text || "").trim().toLowerCase().replace(/[.!:：]+$/, "").replace(/\s+/g, " ");
    const SHARE_LABELS = new Set([
        "share", "share post", "share tweet", "send", "send post", "direct", "分享", "分享帖子", "分享贴文", "分享貼文", "发送", "发送帖子", "傳送", "發送", "轉發", "转发",
        "partager", "partager la publication", "partager le post", "partager le tweet", "envoyer", "teilen", "beitrag teilen", "senden", "compartir", "compartir publicación", "enviar", "condividi", "invia", "シェア", "投稿をシェア", "送信", "공유", "게시물 공유", "보내기", "compartilhar", "enviar publicação"
    ]);
    const NEXT_LABELS = new Set(["next", "next slide", "next photo", "suivant", "suivante", "weiter", "siguiente", "avanti", "下一步", "下一张", "下一張", "下一項", "次へ", "다음", "próximo"]);
    const PREVIOUS_LABELS = new Set(["previous", "previous slide", "previous photo", "go back", "back", "précédent", "précédente", "retour", "zurück", "anterior", "indietro", "上一步", "上一张", "上一張", "返回", "戻る", "이전"]);
    const labels = element => [element.getAttribute("aria-label"), element.getAttribute("title"), ...Array.from(element.querySelectorAll("[aria-label],title")).map(child => child.getAttribute("aria-label") || child.textContent)].map(normalize);
    const control = element => element.closest('button,[role="button"]');
    const enabled = element => element && !element.disabled && element.getAttribute("aria-disabled") !== "true" && element.getClientRects().length > 0;
    const matchingControl = (root, names) => Array.from(root.querySelectorAll('button,[role="button"]')).find(element => enabled(element) && !element.hasAttribute(BUTTON_ATTRIBUTE) && labels(element).some(label => names.has(label)));

    function permalink(root) {
        const links = Array.from(root.querySelectorAll("a[href]"));
        const timed = links.find(link => link.querySelector("time") && core.canonicalPostURL(link.href, platform));
        if (timed) return core.canonicalPostURL(timed.href, platform);
        for (const link of links) {
            const url = core.canonicalPostURL(link.href, platform);
            if (url && (platform === "x" || /\/(p|reel|tv)\//.test(new URL(link.href).pathname))) return url;
        }
        return core.canonicalPostURL(location.href, platform);
    }

    function instagramRoot(share) {
        const article = share.closest("article");
        if (article) return article;
        let node = share.parentElement;
        // Individual post pages and reel layouts sometimes omit <article>.
        for (let depth = 0; node && depth < 10; depth++, node = node.parentElement) {
            if (node.matches("body,main,[role=main]")) break;
            if (node.querySelector("video,img") && permalink(node) && node.querySelectorAll("video").length <= 1) return node;
        }
        return null;
    }

    function insertionAnchor(share, root) {
        // Instagram wraps each action in a sibling span; placing the button after that span
        // preserves the action row. X wraps buttons in equal-width action containers.
        let anchor = share;
        for (let depth = 0; depth < 4 && anchor.parentElement && anchor.parentElement !== root; depth++) {
            const parent = anchor.parentElement;
            const siblings = Array.from(parent.children).filter(child => child === anchor || child.querySelector('button,[role="button"]') || child.matches('button,[role="button"]'));
            if (siblings.length >= 2) break;
            if (parent.querySelectorAll('button,[role="button"]').length > 1) break;
            anchor = parent;
        }
        return anchor;
    }

    function icon(button, state = "download") {
        button.replaceChildren();
        const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
        svg.setAttribute("viewBox", "0 0 24 24");
        svg.setAttribute("aria-hidden", "true");
        const path = document.createElementNS(svg.namespaceURI, "path");
        path.setAttribute("d", state === "complete" ? "m5 12 4 4L19 6" : state === "error" ? "M12 7v6m0 4h.01M4 20h16L12 4Z" : "M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5");
        svg.append(path);
        button.append(svg);
        button.dataset.state = state;
    }

    let toast;
    let toastTimer;
    function notify(message, error = false) {
        if (!toast?.isConnected) {
            toast = document.createElement("div");
            toast.className = "downloader-notice";
            toast.setAttribute("role", "status");
            toast.setAttribute("aria-live", "polite");
            document.body.append(toast);
        }
        clearTimeout(toastTimer);
        toast.textContent = message;
        toast.dataset.error = String(error);
        toast.hidden = false;
        toastTimer = setTimeout(() => { toast.hidden = true; }, error ? 14000 : 6500);
    }

    function fullSizeURL(image) {
        const candidates = (image.getAttribute("srcset") || "").split(",").map(entry => {
            const [url, width] = entry.trim().split(/\s+/);
            return {url, width: parseInt(width, 10) || 0};
        }).filter(item => core.allowedMediaURL(item.url)).sort((a, b) => b.width - a.width);
        const value = candidates[0]?.url || image.currentSrc || image.src;
        return core.allowedMediaURL(value) ? value : null;
    }

    function visibleArea(element, root, ignoreOwnOpacity = false) {
        const bounds = element.getBoundingClientRect();
        if (bounds.width < 140 || bounds.height < 100) return 0;
        const clipping = {...Object.fromEntries(["left", "right", "top", "bottom"].map(key => [key, root.getBoundingClientRect()[key]]))};
        for (let node = element; node && root.contains(node); node = node.parentElement) {
            const style = getComputedStyle(node);
            if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse" ||
                (Number(style.opacity) === 0 && !(ignoreOwnOpacity && node === element)) || node.getAttribute("aria-hidden") === "true") return 0;
            const box = node.getBoundingClientRect();
            if (/hidden|clip|scroll|auto/.test(style.overflowX)) { clipping.left = Math.max(clipping.left, box.left); clipping.right = Math.min(clipping.right, box.right); }
            if (/hidden|clip|scroll|auto/.test(style.overflowY)) { clipping.top = Math.max(clipping.top, box.top); clipping.bottom = Math.min(clipping.bottom, box.bottom); }
            if (node === root) break;
        }
        const overlap = Math.max(0, Math.min(bounds.right, clipping.right) - Math.max(bounds.left, clipping.left)) *
            Math.max(0, Math.min(bounds.bottom, clipping.bottom) - Math.max(bounds.top, clipping.top));
        return overlap >= bounds.width * bounds.height * .55 ? overlap : 0;
    }

    function visibleSlide(root) {
        const videos = Array.from(root.querySelectorAll("video")).filter(video => video.closest("article") === root || !video.closest("article"))
            // Paused players can hide the <video> itself with opacity while showing its poster.
            .map(video => ({video, area: visibleArea(video, root, true)}))
            .filter(item => item.area).sort((a, b) => b.area - a.area);
        if (videos.length) {
            const video = videos[0].video;
            const source = video.currentSrc || video.src || video.querySelector("source")?.src;
            const poster = video.poster || video.parentElement?.querySelector("img")?.src;
            return {media: {kind: "video"}, signature: source || poster ? `video:${source || ""}:${poster || ""}` : null};
        }
        const ranked = Array.from(root.querySelectorAll("img")).filter(image => {
            return (image.closest("article") === root || !image.closest("article")) &&
                !/profile picture|profile photo|photo de profil|foto de perfil|头像|頭像/.test(normalize(image.alt)) &&
                !image.closest("header") && fullSizeURL(image);
        }).map(image => ({image, area: visibleArea(image, root)})).filter(item => item.area)
            .sort((a, b) => b.area - a.area);
        const url = ranked.length ? fullSizeURL(ranked[0].image) : null;
        // Signed query parameters and image size variants can change while one slide is loading.
        return url ? {media: {kind: "image", url}, signature: `image:${new URL(url).origin}${new URL(url).pathname}`} : null;
    }

    function visibleMedia(root) {
        const slide = visibleSlide(root);
        return slide ? [slide.media] : [];
    }

    async function metadataForPost(postURL) {
        const shortcode = new URL(postURL).pathname.split("/")[2];
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), 8000);
        try {
            const id = core.shortcodeToMediaID(shortcode);
            const response = await fetch(`/api/v1/media/${id}/info/`, {credentials: "include", signal: controller.signal,
                headers: {"X-IG-App-ID": "936619743392459", "Accept": "application/json"}});
            if (response.ok) {
                const body = await response.text();
                if (body.length <= 6000000) {
                    const metadata = core.instagramMetadata(JSON.parse(body), shortcode);
                    if (metadata) return metadata;
                }
            }
        } catch { /* Instagram can restrict its private API. Embedded data and the carousel are fallbacks. */ }
        finally { clearTimeout(timer); }
        for (const script of document.querySelectorAll('script[type="application/json"],script[type="application/ld+json"]')) {
            const text = script.textContent;
            if (!text || text.length > 6000000 || !text.includes(shortcode)) continue;
            try {
                const metadata = core.instagramMetadata(JSON.parse(text), shortcode);
                if (metadata) return metadata;
            } catch { /* Unrelated page JSON. */ }
        }
        return null;
    }

    async function traverseCarousel(root) {
        const deadline = Date.now() + 25000;
        let movedBack = 0;
        let position = 0;
        let failed = false;
        const collected = [];
        const seen = new Set();
        function check() {
            if (!root.isConnected || Date.now() > deadline) throw new Error(t("carouselUnavailable"));
        }
        async function move(button) {
            check();
            const before = visibleSlide(root)?.signature;
            if (!before) throw new Error(t("carouselUnavailable"));
            button.click();
            for (let attempt = 0; attempt < 8; attempt++) {
                await sleep(attempt ? 200 : 450);
                check();
                const after = visibleSlide(root)?.signature;
                if (after && before !== after) { await sleep(150); return; }
            }
            throw new Error(t("carouselUnavailable"));
        }
        try {
            let previous;
            while ((previous = matchingControl(root, PREVIOUS_LABELS))) {
                if (movedBack >= core.MAX_ITEMS - 1) throw new Error(t("carouselUnavailable"));
                await move(previous);
                movedBack++;
            }
            while (true) {
                check();
                let slide = visibleSlide(root);
                if (!slide) { await sleep(500); slide = visibleSlide(root); }
                if (!slide?.signature) throw new Error(t("carouselUnavailable"));
                const item = slide.media;
                const signature = slide.signature;
                if (seen.has(signature)) throw new Error(t("carouselUnavailable"));
                seen.add(signature);
                collected.push(item);
                const next = matchingControl(root, NEXT_LABELS);
                if (!next) break;
                if (collected.length >= core.MAX_ITEMS) throw new Error(t("carouselUnavailable"));
                await move(next);
                position++;
            }
        } catch (error) { failed = true; throw error; }
        finally {
            // Return to the slide visible when the user tapped Download, with a bounded best effort.
            if (root.isConnected) {
                let remaining = position - movedBack;
                for (let count = 0; remaining && count < core.MAX_ITEMS; count++) {
                    const button = matchingControl(root, remaining > 0 ? PREVIOUS_LABELS : NEXT_LABELS);
                    if (!button) break;
                    button.click();
                    await sleep(150);
                    remaining += remaining > 0 ? -1 : 1;
                }
            }
        }
        if (failed || !collected.length) throw new Error(t("carouselUnavailable"));
        return {media: collected, complete: true, hasVideo: collected.some(item => item.kind === "video"), source: "carousel"};
    }

    async function instagramMedia(root, postURL) {
        const metadata = await metadataForPost(postURL);
        if (metadata) return metadata;
        if (matchingControl(root, NEXT_LABELS) || matchingControl(root, PREVIOUS_LABELS)) {
            notify(t("readingCarousel"));
            return traverseCarousel(root);
        }
        const media = visibleMedia(root);
        if (!media.length) throw new Error(t("noMedia"));
        // Lazy-loaded carousel controls cannot be distinguished safely from a single visible slide.
        if (root.querySelector('ul > li:nth-child(2) img, [aria-roledescription="carousel"]')) throw new Error(t("carouselUnavailable"));
        return {media, complete: true, hasVideo: media.some(item => item.kind === "video"), source: "visible"};
    }

    async function download(button, root) {
        if (button.disabled) return;
        const postURL = permalink(root);
        if (!postURL) { notify(t("postURLUnavailable"), true); return; }
        button.disabled = true;
        button.setAttribute("aria-busy", "true");
        button.title = t("readingPost");
        icon(button, "busy");
        active.set(postURL, button);
        try {
            const extracted = platform === "instagram" ? await instagramMedia(root, postURL) : {media: [], complete: true, hasVideo: true};
            const result = await browser.runtime.sendMessage({type: "downloadPost", platform, postURL,
                media: extracted.media, complete: extracted.complete, requiresResolver: extracted.hasVideo});
            if (!result?.ok) {
                const partial = result?.saved ? `${t("partialSaved", [String(result.saved), String(result.total)])} ` : "";
                throw new Error(partial + (result?.error || t("downloadFailed")));
            }
            icon(button, "complete");
            button.title = t("savedCount", String(result.saved));
            notify(t("savedCount", String(result.saved)));
        } catch (error) {
            icon(button, "error");
            button.title = `${error.message}\n${t("retryDownload")}`;
            notify(error.message || t("downloadFailed"), true);
        } finally {
            button.disabled = false;
            button.removeAttribute("aria-busy");
            active.delete(postURL);
        }
    }

    function inject(share, root) {
        const postURL = permalink(root);
        if (!postURL) return;
        const existing = root.querySelector(`[${BUTTON_ATTRIBUTE}]`);
        const anchor = insertionAnchor(share, root);
        if (existing) {
            // SPA reuse can replace an article's post without replacing its action row.
            if (existing.dataset.postUrl !== postURL && !existing.disabled) {
                existing.dataset.postUrl = postURL;
                existing.title = t("downloadToPhotos");
                icon(existing);
            }
            return;
        }
        const button = document.createElement("button");
        button.type = "button";
        button.setAttribute(BUTTON_ATTRIBUTE, "");
        button.dataset.postUrl = postURL;
        button.className = `downloader-post-button downloader-${platform}`;
        button.setAttribute("aria-label", t("downloadToPhotos"));
        button.title = t("downloadToPhotos");
        icon(button);
        button.addEventListener("click", event => {
            event.preventDefault();
            event.stopPropagation();
            download(button, root);
        });
        anchor.after(button);
    }

    function scan() {
        if (platform === "instagram") {
            for (const candidate of document.querySelectorAll('svg[aria-label],button[aria-label],[role="button"][aria-label]')) {
                if (!SHARE_LABELS.has(normalize(candidate.getAttribute("aria-label")))) continue;
                const share = control(candidate);
                if (!share || !enabled(share) || share.hasAttribute(BUTTON_ATTRIBUTE)) continue;
                const root = instagramRoot(share);
                if (root) inject(share, root);
            }
        } else {
            for (const root of document.querySelectorAll('article[data-testid="tweet"],article[role="article"]')) {
                if (!root.querySelector('video,[data-testid="videoPlayer"]')) continue;
                const groups = Array.from(root.querySelectorAll('[role="group"]'));
                const actions = groups.find(group => group.querySelector('[data-testid="reply"]')) || root;
                const share = matchingControl(actions, SHARE_LABELS);
                if (share) inject(share, root);
            }
        }
    }

    browser.runtime.onMessage.addListener(message => {
        if (message?.type !== "downloadProgress") return;
        const button = active.get(message.postURL);
        if (!button) return;
        if (message.phase === "resolving") {
            button.title = t("processingVideo");
            notify(t("processingVideo"));
        } else if (message.phase === "saving") {
            button.title = t("savingProgress", [String(message.saved), String(message.total)]);
            notify(button.title);
        }
    });
    let scheduled = false;
    const schedule = () => {
        if (scheduled) return;
        scheduled = true;
        setTimeout(() => { scheduled = false; scan(); }, 200);
    };
    new MutationObserver(schedule).observe(document.documentElement, {childList: true, subtree: true, attributes: true, attributeFilter: ["aria-label", "data-testid", "src"]});
    addEventListener("popstate", schedule);
    addEventListener("pageshow", schedule);
    scan();
})();
