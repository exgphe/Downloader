const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../../Shared (Extension)/Resources/media-core.js');
const {createVideoResolver} = require('../../Shared (Extension)/Resources/video-resolver.js');
const postURL = 'https://www.instagram.com/p/ABCdef12/';
const video = (index = 1) => ({kind: 'video', url: 'https://scontent.cdninstagram.com/video-' + index + '.mp4'});
const request = (media = [video()]) => ({platform: 'instagram', mediaSource: 'metadata', expectedVideoCount: media.length, media});

test('complete authenticated Instagram metadata saves every direct video without native resolution', async () => {
    const resolve = createVideoResolver({sendNative() { throw new Error('Metadata should bypass yt-dlp.'); }});
    const media = [video(1), video(2)];
    assert.deepEqual((await resolve(postURL, request(media))).map(item => item.url), media.map(item => item.url));
});

test('one missing Instagram video URL requires a full native resolution rather than a partial batch', async () => {
    const calls = [];
    const media = [video(1), video(2)];
    const resolve = createVideoResolver({sendNative: async message => { calls.push(message); return {ok: true, media}; }});
    assert.equal((await resolve(postURL, request([video(1), {kind: 'video'}]))).length, 2);
    assert.deepEqual(calls, [{type: 'resolvePost', postURL}]);
});

test('page video URLs and X videos use the native engine', async () => {
    const calls = [];
    const resolve = createVideoResolver({sendNative: async message => { calls.push(message); return {ok: true, media: [video()]}; }});
    await resolve(postURL, {...request(), mediaSource: 'page'});
    const xURL = 'https://x.com/alice/status/12345';
    await resolve(xURL, {platform: 'x', mediaSource: 'metadata', expectedVideoCount: null, media: []});
    assert.deepEqual(calls.map(item => item.postURL), [postURL, xURL]);
});

test('untrusted direct metadata falls back and unsafe native output is rejected', async () => {
    let calls = 0;
    const resolve = createVideoResolver({sendNative: async () => { calls++; return {ok: true, media: [video()]}; }});
    await resolve(postURL, request([{kind: 'video', url: 'https://evil.test/clip.mp4'}]));
    assert.equal(calls, 1);
    for (const media of [
        [{kind: 'video', url: 'blob:https://x.com/123'}],
        [{kind: 'video', url: 'http://video.twimg.com/clip.mp4'}],
        [{kind: 'video', url: 'https://video.twimg.com.evil.test/clip.mp4'}],
        [{kind: 'image', url: video().url}],
        [null], [], Array.from({length: 21}, () => video())
    ]) {
        const unsafe = createVideoResolver({sendNative: async () => ({ok: true, media})});
        await assert.rejects(unsafe(postURL), /media/);
    }
});

test('native media cannot inject request headers or unsafe filenames into PhotoKit messages', async () => {
    const resolve = createVideoResolver({sendNative: async () => ({ok: true, media: [{
        ...video(), filename: '../../tmp/file.mp4', headers: {Authorization: 'secret'}
    }]})});
    assert.deepEqual(await resolve(postURL), [{...video(), filename: 'video-1.mp4'}]);
});

test('native extraction failures remain retryable user-facing errors', async () => {
    const resolve = createVideoResolver({sendNative: async () => ({ok: false, code: 'unsupported_format', error: 'This video has no supported MP4 format.'})});
    await assert.rejects(resolve(postURL), /no supported MP4/);
    const missing = createVideoResolver({sendNative: async () => null});
    await assert.rejects(missing(postURL), /built-in video engine/);
});

test('post validation preserves only Instagram metadata as eligible for direct video saving', () => {
    const base = {type: 'downloadPost', platform: 'instagram', postURL, complete: true, mediaSource: 'metadata', media: [video()]};
    assert.equal(core.validatePostRequest(base, postURL).mediaSource, 'metadata');
    assert.equal(core.validatePostRequest({...base, mediaSource: 'visible'}, postURL).mediaSource, 'page');
    const xURL = 'https://x.com/alice/status/12345';
    const x = core.validatePostRequest({...base, platform: 'x', postURL: xURL, media: [], requiresVideoResolution: true}, xURL);
    assert.equal(x.mediaSource, 'page');
    assert.equal(x.hasVideo, true);
});
