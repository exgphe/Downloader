const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const core = require('../../Shared (Extension)/Resources/media-core.js');
const content = fs.readFileSync(require.resolve('../../Shared (Extension)/Resources/content.js'), 'utf8');

// A small semantic DOM fixture implements only standard DOM operations used by injection.
// Its rows mirror the screenshot: Instagram actions have wrappers; X has one group.
class Element {
    constructor(tag, attributes = {}) {
        this.tagName = tag.toLowerCase();
        this.attributes = {...attributes};
        this.children = [];
        this.dataset = {};
        this.listeners = {};
        this.disabled = false;
        this.textContent = '';
        this.style = {getPropertyValue(name) { return this[name] || ''; }, setProperty(name, value) { this[name] = value; }};
    }
    get parentElement() { return this.parent || null; }
    get nextElementSibling() { return this.parent?.children[this.parent.children.indexOf(this) + 1] || null; }
    get href() { return this.attributes.href; }
    get isConnected() { return !!this.parent || this.tagName === 'document'; }
    append(...children) { for (const child of children) { child.remove(); child.parent = this; this.children.push(child); } }
    remove() { if (this.parent) { this.parent.children.splice(this.parent.children.indexOf(this), 1); this.parent = null; } }
    replaceChildren(...children) { this.children = []; this.append(...children); }
    after(child) { child.remove(); child.parent = this.parent; this.parent.children.splice(this.parent.children.indexOf(this) + 1, 0, child); }
    getAttribute(name) { return this.attributes[name] ?? null; }
    setAttribute(name, value) { this.attributes[name] = value; }
    hasAttribute(name) { return name in this.attributes; }
    removeAttribute(name) { delete this.attributes[name]; }
    getClientRects() { return [{}]; }
    getBoundingClientRect() { return this.bounds || {left: 0, right: 600, top: 0, bottom: 600, width: 600, height: 600}; }
    click() { if (this.onClick) this.onClick(); }
    addEventListener(name, callback) { this.listeners[name] = callback; }
    contains(element) { return element === this || this.children.some(child => child.contains(element)); }
    matches(selector) {
        return selector.split(',').some(part => {
            const parsed = part.trim().match(/^([a-z]+)?(?:\[([^=\]]+)(?:="?([^"\]]+)"?)?\])?$/);
            if (!parsed) return false;
            const [, tag, key, value] = parsed;
            return (!tag || tag === this.tagName) && (!key || this.hasAttribute(key)) && (!value || this.getAttribute(key) === value);
        });
    }
    closest(selector) { return this.matches(selector) ? this : this.parent?.closest(selector) || null; }
    querySelectorAll(selector) {
        const result = [];
        for (const child of this.children) {
            if (child.matches(selector)) result.push(child);
            result.push(...child.querySelectorAll(selector));
        }
        return result;
    }
    querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}
function element(tag, attributes = {}, ...children) { const node = new Element(tag, attributes); node.append(...children); return node; }
function instagramPost(code, label = 'Share Post') {
    const share = element('div', {role: 'button'}, element('svg', {'aria-label': label}));
    const wrapper = element('span', {}, share);
    const row = element('section', {}, element('span', {}, element('button', {'aria-label': 'Like'})), element('span', {}, element('button', {'aria-label': 'Comment'})), wrapper, element('span', {}, element('button', {'aria-label': 'Save'})));
    const link = element('a', {href: `https://www.instagram.com/p/${code}/`}, element('time'));
    row.style = {display: 'flex', flexDirection: 'row'};
    return {root: element('article', {}, link, element('img'), row), row, wrapper, share, link};
}
function xPost(id, hasVideo, label = 'Share post') {
    const share = element('button', {'aria-label': label});
    const wrapper = element('div', {}, share);
    const row = element('div', {role: 'group'}, element('div', {}, element('button', {'data-testid': 'reply', 'aria-label': 'Reply'})), element('div', {}, element('button', {'aria-label': 'Repost'})), element('div', {}, element('button', {'aria-label': 'Like'})), wrapper);
    const link = element('a', {href: `https://x.com/alice/status/${id}`}, element('time'));
    return {root: element('article', {'data-testid': 'tweet'}, link, ...(hasVideo ? [element('div', {'data-testid': 'videoPlayer'}, element('video'))] : [element('img')]), row), row, wrapper};
}
function run(platform, roots, url) {
    const document = element('document', {}, ...roots);
    document.documentElement = document;
    document.body = document;
    document.createElement = tag => new Element(tag);
    document.createElementNS = (namespace, tag) => { const node = new Element(tag); node.namespaceURI = namespace; return node; };
    const callbacks = [];
    const context = {
        DownloaderCore: core, document, location: {href: url || (platform === 'instagram' ? 'https://www.instagram.com/' : 'https://x.com/home')},
        browser: {i18n: {getMessage: key => key}, runtime: {onMessage: {addListener() {}}, sendMessage() { throw new Error('Unexpected download'); }}},
        MutationObserver: class {constructor(callback) { context.mutate = callback; } observe() {}},
        getComputedStyle: node => ({display: 'block', flexDirection: 'row', visibility: 'visible', opacity: '1', overflowX: 'visible', overflowY: 'visible', ...node.style}),
        addEventListener() {}, setTimeout: callback => { callbacks.push(callback); return callbacks.length; }, clearTimeout() {}, URL, console
    };
    // Capture real closure functions for focused fallback tests without exporting internals in production.
    vm.runInNewContext(content.replace('    scan();\n})();', '    globalThis.testInternals = {visibleSlide, traverseCarousel, instagramMedia};\n    scan();\n})();'), context);
    return {document, context, flush() { while (callbacks.length) callbacks.shift()(); }};
}

test('Instagram download button is immediately after the send wrapper, before bookmark', () => {
    const post = instagramPost('ABC123');
    run('instagram', [post.root]);
    const button = post.root.querySelector('[data-downloader-button]');
    assert.ok(button);
    assert.equal(post.row.children[post.row.children.indexOf(post.wrapper) + 1], button);
    assert.equal(button.getAttribute('aria-label'), 'downloadToPhotos');
    assert.equal(button.dataset.postUrl, 'https://www.instagram.com/p/ABC123/');
});

test('dynamic rescans create one button per post and reset reused SPA post rows', () => {
    const first = instagramPost('ABC123', '发送');
    const fixture = run('instagram', [first.root]);
    fixture.context.mutate();
    fixture.flush();
    assert.equal(first.root.querySelectorAll('[data-downloader-button]').length, 1);
    const second = instagramPost('XYZ789', 'Partager');
    fixture.document.append(second.root);
    fixture.context.mutate();
    fixture.flush();
    assert.equal(second.root.querySelectorAll('[data-downloader-button]').length, 1);
    first.link.setAttribute('href', 'https://www.instagram.com/p/NEW456/');
    fixture.context.mutate();
    fixture.flush();
    assert.equal(first.root.querySelector('[data-downloader-button]').dataset.postUrl, 'https://www.instagram.com/p/NEW456/');
});

test('deep send wrappers with a count control do not trap the download in a column', () => {
    const post = instagramPost('ABC123');
    post.share.remove();
    const column = element('div', {}, post.share, element('button', {'aria-label': 'Share count'}));
    column.style = {display: 'flex', flexDirection: 'column'};
    let nested = column;
    for (let depth = 0; depth < 6; depth++) nested = element('div', {}, nested);
    post.wrapper.append(nested);
    const fixture = run('instagram', [post.root]);
    const button = post.root.querySelector('[data-downloader-button]');
    assert.ok(button);
    assert.equal(button.parentElement, post.row);
    assert.equal(post.wrapper.nextElementSibling, button);
    fixture.context.mutate();
    fixture.flush();
    assert.equal(post.root.querySelectorAll('[data-downloader-button]').length, 1);
    assert.equal(post.wrapper.nextElementSibling, button);
});

test('rerendered Instagram actions relocate the existing button and keep its state', () => {
    const post = instagramPost('ABC123');
    const fixture = run('instagram', [post.root]);
    const button = post.root.querySelector('[data-downloader-button]');
    button.dataset.state = 'complete';
    // React leaves our unknown node behind while moving its own action group.
    const actions = element('div');
    actions.style = {display: 'flex', flexDirection: 'row'};
    actions.append(...post.row.children.filter(child => child !== button));
    post.row.append(actions);
    fixture.context.mutate();
    fixture.flush();
    assert.equal(button.parentElement, actions);
    assert.equal(post.wrapper.nextElementSibling, button);
    assert.equal(button.dataset.state, 'complete');
    assert.equal(post.root.querySelectorAll('[data-downloader-button]').length, 1);
});

test('vertical Reel action rails remain supported', () => {
    const post = instagramPost('ABC123');
    post.row.style.flexDirection = 'column';
    post.root.style = {display: 'flex', flexDirection: 'row'};
    run('instagram', [post.root]);
    assert.equal(post.wrapper.nextElementSibling, post.root.querySelector('[data-downloader-button]'));
});

test('X video post gets download after share; image and text posts do not', () => {
    const video = xPost('123', true, 'Partager le post');
    const photo = xPost('456', false);
    run('x', [video.root, photo.root]);
    const button = video.root.querySelector('[data-downloader-button]');
    assert.ok(button);
    assert.equal(video.row.children[video.row.children.indexOf(video.wrapper) + 1], button);
    assert.equal(photo.root.querySelector('[data-downloader-button]'), null);
});

test('Story button identifies current Story and resets after automatic navigation', () => {
    const share = element('button', {'aria-label': 'Share'});
    const row = element('section', {}, element('button', {'aria-label': 'Like'}), share);
    row.style = {display: 'flex', flexDirection: 'row'};
    const media = element('img');
    media.src = 'https://scontent.cdninstagram.com/story.jpg';
    const viewer = element('div', {}, media, row);
    const fixture = run('instagram', [viewer], 'https://www.instagram.com/stories/imwinter/4013638722465314116/?utm_source=share');
    const button = viewer.querySelector('[data-downloader-button]');
    assert.ok(button);
    assert.equal(button.dataset.postUrl, 'https://www.instagram.com/stories/imwinter/4013638722465314116/');
    assert.equal(row.children[row.children.indexOf(share) + 1], button);
    fixture.context.location.href = 'https://www.instagram.com/stories/imwinter/4013638722465314117/';
    fixture.context.mutate();
    fixture.flush();
    assert.equal(button.dataset.postUrl, fixture.context.location.href);
    assert.equal(viewer.querySelectorAll('[data-downloader-button]').length, 1);
});

test('Story collection uses its numeric ID for the API and never traverses Next controls', async () => {
    const post = instagramPost('ABC123');
    const fixture = run('instagram', [post.root]);
    const postURL = 'https://www.instagram.com/stories/imwinter/4013638722465314116/';
    fixture.context.AbortController = AbortController;
    const calls = [];
    fixture.context.fetch = async (url, options) => {
        calls.push({url, options});
        return {ok: true, text: async () => JSON.stringify({items: [{pk: '4013638722465314116', media_type: 1,
            image_versions2: {candidates: [{url: 'https://scontent.cdninstagram.com/story.jpg', width: 1080, height: 1920}]}}]})};
    };
    const result = await fixture.context.testInternals.instagramMedia(post.root, postURL);
    assert.equal(result.source, 'metadata');
    assert.equal(calls[0].url, '/api/v1/media/4013638722465314116/info/');
    assert.equal(calls[0].options.credentials, 'include');
    const next = element('button', {'aria-label': 'Next'});
    let clicked = false;
    next.onClick = () => { clicked = true; };
    post.root.append(next);
    fixture.context.fetch = async () => ({ok: false});
    const fallback = await fixture.context.testInternals.instagramMedia(post.root, postURL);
    assert.equal(fallback.source, 'story');
    assert.equal(fallback.media.length, 0);
    assert.equal(clicked, false);
});

test('photo slide is not misclassified by a video hidden beyond the carousel clipping viewport', () => {
    const post = instagramPost('ABC123');
    const photo = element('img');
    photo.src = 'https://scontent.cdninstagram.com/photo.jpg?expires=123';
    const video = element('video');
    video.src = 'blob:next-slide';
    video.bounds = {left: 600, right: 1200, top: 0, bottom: 600, width: 600, height: 600};
    const viewport = element('div', {}, photo, video);
    viewport.style = {overflowX: 'hidden'};
    post.root.append(viewport);
    const fixture = run('instagram', [post.root]);
    const slide = fixture.context.testInternals.visibleSlide(post.root);
    assert.equal(slide.media.kind, 'image');
    assert.equal(slide.media.url, photo.src);
    assert.equal(slide.signature, 'image:https://scontent.cdninstagram.com/photo.jpg');
    photo.style = {visibility: 'hidden'};
    assert.equal(fixture.context.testInternals.visibleSlide(post.root), null);
    video.bounds = photo.getBoundingClientRect();
    video.style = {opacity: '0'};
    assert.equal(fixture.context.testInternals.visibleSlide(post.root).media.kind, 'video');
});

test('carousel navigation that leaves the same video visible fails instead of inventing another video', async () => {
    const post = instagramPost('ABC123');
    const video = element('video');
    video.src = 'blob:unchanged-video';
    const next = element('button', {'aria-label': 'Next'});
    // A broken or stale control never changes the visible slide.
    next.onClick = () => {};
    post.root.append(video, next);
    const fixture = run('instagram', [post.root]);
    const result = fixture.context.testInternals.traverseCarousel(post.root).then(() => 'incorrect success', error => error.message);
    for (let cycle = 0; cycle < 12; cycle++) {
        fixture.flush();
        await new Promise(resolve => setImmediate(resolve));
    }
    assert.equal(await result, 'carouselUnavailable');
});
