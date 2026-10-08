const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const resource = name => fs.readFileSync(require.resolve('../../Shared (Extension)/Resources/' + name), 'utf8');
const normalized = value => JSON.parse(JSON.stringify(value));

function background(resolvedMedia = [{kind: 'video', url: 'https://video.twimg.com/clip.mp4'}]) {
    let listener;
    const native = [];
    const progress = [];
    const removed = [];
    const entries = {resolverURL: 'https://obsolete.example', resolverToken: 'obsolete-secret'};
    const context = vm.createContext({
        URL,
        fetch() { throw new Error('Video resolution must remain inside the native extension.'); },
        browser: {
            i18n: {getMessage: () => ''},
            storage: {local: {
                get: async key => key === null ? {...entries} : {[key]: entries[key]},
                set: async values => Object.assign(entries, values),
                remove: async keys => { removed.push(...keys); keys.forEach(key => delete entries[key]); }
            }},
            tabs: {sendMessage: async (id, message) => progress.push({id, ...normalized(message)})},
            runtime: {
                getURL: () => 'safari-web-extension://downloader/',
                onMessage: {addListener: callback => { listener = callback; }},
                sendNativeMessage: async (app, message) => {
                    native.push({app, ...normalized(message)});
                    if (message.type === 'status') return {ok: true, photosAuthorization: 'authorized', videoEngine: {available: true, version: '2026.09.23'}};
                    if (message.type === 'resolvePost') return {ok: true, media: resolvedMedia};
                    return {ok: true, saved: 1};
                }
            }
        }
    });
    for (const name of ['media-core.js', 'download-engine.js', 'video-resolver.js']) vm.runInContext(resource(name), context);
    vm.runInContext(resource('background.js').replace(/^import .*;\n/gm, ''), context);
    return {send: (message, sender) => listener(message, sender), native, progress, removed};
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
