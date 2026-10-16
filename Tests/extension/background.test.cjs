const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const resource = name => fs.readFileSync(require.resolve('../../Shared (Extension)/Resources/' + name), 'utf8');
const normalized = value => JSON.parse(JSON.stringify(value));

function background(resolvedMedia = [{kind: 'video', url: 'https://video.twimg.com/clip.mp4'}], options = {}) {
    let listener;
    const native = [];
    const progress = [];
    const removed = [];
    const storageWrites = [];
    const cookieReads = [];
    const logs = [];
    const entries = {resolverURL: 'https://obsolete.example', resolverToken: 'obsolete-secret'};
    const context = vm.createContext({
        URL,
        TextEncoder,
        console: Object.fromEntries(['log', 'info', 'warn', 'error', 'debug'].map(level => [level, (...args) => logs.push(args)])),
        fetch() { throw new Error('Video resolution must remain inside the native extension.'); },
        browser: {
            i18n: {getMessage: () => ''},
            storage: {local: {
                get: async key => key === null ? {...entries} : {[key]: entries[key]},
                set: async values => { storageWrites.push(normalized(values)); Object.assign(entries, values); },
                remove: async keys => { removed.push(...keys); keys.forEach(key => delete entries[key]); }
            }},
            cookies: {getAll: async options => { cookieReads.push(options); throw new Error('Background must not read browser cookies.'); }},
            tabs: {sendMessage: async (id, message) => progress.push({id, ...normalized(message)})},
            runtime: {
                getURL: path => 'safari-web-extension://downloader/' + path,
                onMessage: {addListener: callback => { listener = callback; }},
                sendNativeMessage: async (app, message) => {
                    native.push({app, ...normalized(message)});
                    if (options.nativeResponse) return options.nativeResponse(message);
                    if (message.type === 'status') return {ok: true, photosAuthorization: 'authorized', videoEngine: {available: true, version: '2026.09.23'}};
                    if (['importInstagramSession', 'instagramSession', 'clearInstagramSession'].includes(message.type)) {
                        return {ok: true, instagramSession: {hasSession: message.type === 'importInstagramSession'}};
                    }
                    if (message.type === 'resolvePost') return {ok: true, media: resolvedMedia};
                    return {ok: true, saved: 1};
                }
            }
        }
    });
    for (const name of ['media-core.js', 'download-engine.js', 'video-resolver.js', 'instagram-session.js']) vm.runInContext(resource(name), context);
    vm.runInContext(resource('background.js').replace(/^import .*;\n/gm, ''), context);
    return {send: (message, sender) => listener(message, sender), native, progress, removed, storageWrites, cookieReads, logs};
}

test('an X post resolves through native messaging before saving and reports completed progress', async () => {
    const extension = background();
    const postURL = 'https://x.com/alice/status/12345';
    const result = await extension.send({type: 'downloadPost', platform: 'x', postURL, complete: true, media: [], requiresVideoResolution: true}, {url: 'https://x.com/', tab: {id: 9}});
    assert.equal(result.saved, 1);
    assert.equal(result.ok, true);
    assert.deepEqual(extension.native.map(message => message.type), ['resolvePost', 'saveMedia']);
    assert.equal(extension.native[0].postURL, postURL);
    assert.equal(extension.native[1].referrer, postURL);
    assert.equal(extension.progress.at(-1).phase, 'complete');
    assert.equal(extension.progress.at(-1).id, 9);
    assert.deepEqual(extension.removed.sort(), ['resolverToken', 'resolverURL']);
});

test('authenticated Instagram carousel metadata saves photos and videos directly', async () => {
    const extension = background();
    const postURL = 'https://www.instagram.com/p/ABCdef12/';
    const media = [
        {kind: 'image', url: 'https://scontent.cdninstagram.com/photo.jpg'},
        {kind: 'video', url: 'https://scontent.cdninstagram.com/video.mp4'}
    ];
    const result = await extension.send({type: 'downloadPost', platform: 'instagram', postURL, complete: true, media, mediaSource: 'metadata', requiresVideoResolution: true}, {url: 'https://www.instagram.com/', tab: {id: 4}});
    assert.equal(result.saved, 2);
    assert.deepEqual(extension.native.map(message => message.type), ['saveMedia', 'saveMedia']);
    assert.deepEqual(extension.native.map(message => message.item.kind), ['image', 'video']);
});

test('all videos from an X post receive separate native Photos save confirmations', async () => {
    const media = [1, 2, 3].map(index => ({kind: 'video', url: 'https://video.twimg.com/clip-' + index + '.mp4'}));
    const extension = background(media);
    const postURL = 'https://x.com/alice/status/12345';
    const result = await extension.send({type: 'downloadPost', platform: 'x', postURL, complete: true, media: [], requiresVideoResolution: true}, {url: 'https://x.com/', tab: {id: 9}});
    assert.equal(result.ok, true);
    assert.equal(result.saved, 3);
    assert.equal(result.total, 3);
    assert.deepEqual(extension.native.filter(message => message.type === 'saveMedia').map(message => message.item.url), media.map(item => item.url));
});

test('only the extension popup can read native runtime status', async () => {
    const extension = background();
    const request = {type: 'nativeStatus'};
    assert.equal((await extension.send(request, {url: 'https://www.instagram.com/', tab: {id: 4}})).ok, false);
    assert.equal(extension.native.length, 0);
    const status = await extension.send(request, {url: 'safari-web-extension://downloader/popup.html'});
    assert.equal(status.videoEngine.available, true);
    assert.equal(status.videoEngine.version, '2026.09.23');
    assert.equal(extension.native[0].type, 'status');
});

const popupSender = {url: 'safari-web-extension://downloader/popup.html'};
const sessionCookie = (overrides = {}) => ({
    name: 'sessionid', value: 'explicit-user-session', domain: 'instagram.com', path: '/', secure: true, httpOnly: true,
    ...overrides
});

test('session import, status, clear, and runtime status require the exact popup sender without a tab', async () => {
    const extension = background();
    const senders = [
        undefined,
        {},
        {url: 'https://www.instagram.com/', tab: {id: 4}},
        {...popupSender, tab: {id: 4}},
        {url: 'safari-web-extension://downloader/options.html'},
        {url: 'safari-web-extension://downloader/popup.html?next=instagram'},
        {url: 'safari-web-extension://downloader/popup.html#sync'},
        {url: 'safari-web-extension://downloader/popup.html/other'},
        {url: 'safari-web-extension://downloader.evil/popup.html'},
        {url: 'safari-web-extension://other-extension/popup.html'}
    ];
    for (const type of ['importInstagramSession', 'instagramSession', 'clearInstagramSession', 'nativeStatus']) {
        for (const sender of senders) {
            const result = await extension.send({type, cookies: [sessionCookie()]}, sender);
            assert.equal(result.ok, false, `${type}: ${JSON.stringify(sender)}`);
        }
    }
    assert.equal(extension.native.length, 0);
    assert.deepEqual(extension.cookieReads, []);
    assert.deepEqual(extension.storageWrites, []);
});

test('popup session operations strip unrelated payload fields and never retain credentials in browser settings', async () => {
    const extension = background();
    const expires = Date.now() / 1000 + 3600;
    const cookie = sessionCookie({domain: '.Instagram.COM', expires, storeId: 'private', partitionKey: 'discard'});
    const imported = await extension.send({type: 'importInstagramSession', cookies: [cookie, sessionCookie({name: 'unrelated', value: 'discard'})], token: 'discard'}, popupSender);
    const status = await extension.send({type: 'instagramSession', cookies: [cookie], token: 'discard'}, popupSender);
    const cleared = await extension.send({type: 'clearInstagramSession', cookies: [cookie], token: 'discard'}, popupSender);
    assert.equal(imported.instagramSession.hasSession, true);
    assert.equal(status.ok, true);
    assert.equal(cleared.instagramSession.hasSession, false);
    assert.deepEqual(extension.native, [
        {app: 'wang.xiaolin.Downloader', type: 'importInstagramSession', cookies: [sessionCookie({expires})]},
        {app: 'wang.xiaolin.Downloader', type: 'instagramSession'},
        {app: 'wang.xiaolin.Downloader', type: 'clearInstagramSession'}
    ]);
    assert.deepEqual(extension.cookieReads, []);
    assert.deepEqual(extension.storageWrites, []);
    assert.deepEqual(extension.logs, []);
});

test('invalid or mixed-account imports cannot reach native messaging', async () => {
    const extension = background();
    for (const cookies of [
        null,
        Array(101).fill(sessionCookie()),
        [sessionCookie({domain: 'instagram.com.evil'})],
        [sessionCookie({path: '/accounts'})],
        [sessionCookie({value: 'contains;delimiter'})],
        [sessionCookie({expires: 2 ** 63})],
        [sessionCookie(), sessionCookie({domain: 'www.instagram.com', value: 'another-account'})],
        [sessionCookie(), sessionCookie({domain: '.instagram.com', httpOnly: false})],
        [sessionCookie(), sessionCookie({httpOnly: false})]
    ]) {
        const result = await extension.send({type: 'importInstagramSession', cookies}, popupSender);
        assert.equal(result.ok, false);
        assert.match(result.code, /^(invalidInstagramSession|instagramSessionMissing)$/);
    }
    assert.equal(extension.native.length, 0);
    assert.deepEqual(extension.storageWrites, []);
    assert.deepEqual(extension.logs, []);
});

test('native import failures expose only the safe session error, without credential-bearing diagnostics', async () => {
    const secret = 'explicit-user-session';
    const extension = background(undefined, {nativeResponse: () => { throw new Error(`failed to store ${secret}`); }});
    const result = await extension.send({type: 'importInstagramSession', cookies: [sessionCookie()]}, popupSender);
    assert.equal(result.ok, false);
    assert.equal(result.code, 'instagramSessionFailed');
    assert.equal(JSON.stringify(result).includes(secret), false);
    assert.deepEqual(extension.storageWrites, []);
    assert.deepEqual(extension.logs, []);
});
