const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../../Shared (Extension)/Resources/media-core.js');
const {createDownloadEngine} = require('../../Shared (Extension)/Resources/download-engine.js');
const image = (name = 'full.jpg', width = 1080) => ({url: `https://scontent.cdninstagram.com/${name}`, width, height: width});
const postURL = 'https://www.instagram.com/p/ABCdef12/';

test('post links are canonicalized and cannot point at other hosts', () => {
    assert.equal(core.canonicalPostURL(`${postURL}?utm_source=feed`, 'instagram'), postURL);
    assert.equal(core.canonicalPostURL('https://twitter.com/alice/status/12345/video/1', 'x'), 'https://x.com/alice/status/12345');
    assert.equal(core.canonicalPostURL('https://x.com/i/web/status/12345', 'x'), 'https://x.com/i/web/status/12345');
    for (const url of ['https://instagram.com.evil.test/p/ABC/', 'http://instagram.com/p/ABC/', 'https://user:pass@instagram.com/p/ABC/', 'https://www.instagram.com/accounts/login/']) assert.equal(core.canonicalPostURL(url), null);
});

test('media allowlist rejects lookalike hosts, credentials and unsafe schemes', () => {
    for (const url of ['https://scontent.cdninstagram.com/a.jpg', 'https://video.twimg.com/a.mp4', 'https://pbs.twimg.com/a.jpg']) assert.ok(core.allowedMediaURL(url));
    for (const url of ['https://cdninstagram.com.evil.test/a.jpg', 'https://arbitrary.twimg.com/a.mp4', 'https://user@pbs.twimg.com/a.jpg', 'http://pbs.twimg.com/a.jpg', 'file:///tmp/a.jpg', 'https://pbs.twimg.com:444/a.jpg']) assert.equal(core.allowedMediaURL(url), false);
});

test('Instagram shortcode conversion retains integers larger than JavaScript safe integer', () => {
    assert.equal(core.shortcodeToMediaID('BAA'), '4096');
    assert.equal(core.shortcodeToMediaID('___________'), ((1n << 66n) - 1n).toString());
    assert.equal(core.shortcodeToMediaID('invalid!'), null);
});

test('API carousel metadata contains all images and videos and picks full-size images', () => {
    const metadata = core.instagramMetadata({items: [{code: 'ABCdef12', media_type: 8, carousel_media_count: 3, carousel_media: [
        {media_type: 1, image_versions2: {candidates: [image('small.jpg', 150), image('large.jpg', 1080)]}},
        {media_type: 2, video_versions: [{url: 'https://scontent.cdninstagram.com/video.mp4', width: 720, height: 1280}]},
        {media_type: 1, image_versions2: {candidates: [image('last.jpg')]}}
    ]}]}, 'ABCdef12');
    assert.equal(metadata.complete, true);
    assert.equal(metadata.expectedMediaCount, 3);
    assert.equal(metadata.hasVideo, true);
    assert.equal(metadata.media[0].url, image('large.jpg').url);
    assert.deepEqual(metadata.media.map(item => item.kind), ['image', 'video', 'image']);
});

test('GraphQL carousel JSON is matched to the requested post rather than recommendations', () => {
    const graphNode = shortcode => ({shortcode, __typename: 'GraphSidecar', edge_sidecar_to_children: {edges: [
        {node: {__typename: 'GraphImage', display_url: image(`${shortcode}.jpg`).url}},
        {node: {__typename: 'GraphVideo', is_video: true}}
    ]}});
    const metadata = core.instagramMetadata({recommended: graphNode('other'), data: {nested: graphNode('ABCdef12')}}, 'ABCdef12');
    assert.equal(metadata.media[0].url, image('ABCdef12.jpg').url);
    assert.equal(metadata.media[1].kind, 'video');
    assert.equal(metadata.complete, true);
    assert.equal(core.instagramMetadata({data: graphNode('other')}, 'ABCdef12'), null);
});

test('incomplete or invalid carousel metadata is never reported as a complete collection', () => {
    for (const node of [
        {media_type: 8},
        {shortcode: 'ABCdef12', __typename: 'GraphSidecar', display_url: image().url},
        {shortcode: 'ABCdef12', __typename: 'GraphSidecar', edge_sidecar_to_children: {count: 3, edges: [{node: {__typename: 'GraphImage', display_url: image().url}}]}},
        {media_type: 8, carousel_media_count: 3, carousel_media: [{media_type: 1, display_url: image().url}]},
        {media_type: 8, carousel_media: [{media_type: 1, display_url: 'https://evil.test/image.jpg'}]}
    ]) assert.equal(core.instagramMetadata({items: [node]}, 'ABCdef12'), null);
});

test('resolver URL accepts HTTPS and loopback HTTP but blocks remote cleartext', () => {
    assert.equal(core.validateResolverURL('https://media.example.com/api/'), 'https://media.example.com/api');
    assert.equal(core.validateResolverURL('http://127.0.0.1:8765/'), 'http://127.0.0.1:8765');
    assert.equal(core.validateResolverURL('http://[::1]:8765/'), 'http://[::1]:8765');
    for (const value of ['http://192.168.1.50:8765', 'https://token@example.com', 'https://example.com?token=x', 'https://example.com/api%2fhidden', 'file:///tmp']) assert.equal(core.validateResolverURL(value), null);
});

test('resolver media stays in the job directory and same origin, including port', () => {
    const base = 'https://media.example.com/downloader';
    const id = 'aabbccdd-1234-1234-1234-123456789abc';
    const path = `/downloader/v1/jobs/${id}/media/clip.mp4`;
    assert.equal(core.serviceMediaURL(path, base, id), `https://media.example.com${path}`);
    for (const value of [`https://evil.test${path}`, `https://media.example.com:8443${path}`, `${path}?token=abc`, `${path.replace('clip.mp4', '%2e%2e/clip.mp4')}`, path.replace(id, 'other'), path.replace('clip.mp4', 'clip.jpg')]) assert.equal(core.serviceMediaURL(value, base, id), null);
});

test('downloads require authorized website sender, complete list and approved media', () => {
    const request = {type: 'downloadPost', platform: 'instagram', postURL, complete: true, media: [{kind: 'image', url: image().url}]};
    assert.equal(core.validatePostRequest(request, 'https://www.instagram.com/').postURL, postURL);
    assert.throws(() => core.validatePostRequest(request, 'https://evil.test/'), /cannot request/);
    assert.throws(() => core.validatePostRequest({...request, complete: false}, postURL), /every item/);
    assert.throws(() => core.validatePostRequest({...request, media: [{kind: 'image', url: 'https://evil.test/image.jpg'}]}, postURL), /approved/);
    assert.throws(() => core.validatePostRequest({...request, platform: 'x', postURL: 'https://x.com/alice/status/1'}, 'https://x.com/'), /no video/);
});

test('partial native failures retry only the failed media and reuse resolved videos', async () => {
    let resolves = 0;
    let failVideo = true;
    const calls = [];
    const engine = createDownloadEngine({
        resolveVideos: async () => { resolves++; return [{kind: 'video', url: 'https://service.test/clip.mp4'}]; },
        saveMedia: async item => {
            calls.push(item.kind);
            return item.kind === 'video' && failVideo ? {ok: false, error: 'Photos denied this video.'} : {ok: true, saved: 1};
        }
    });
    const request = {postURL, hasVideo: true, media: [{kind: 'image', url: image().url}]};
    assert.deepEqual(await engine.download(request), {ok: false, saved: 1, total: 2, failed: 1, error: 'Photos denied this video.', retryable: true});
    failVideo = false;
    assert.deepEqual(await engine.download(request), {ok: true, saved: 2, total: 2, failed: 0});
    assert.deepEqual(calls, ['image', 'video', 'video']);
    assert.equal(resolves, 1);
    await engine.download(request);
    assert.equal(calls.length, 3);
});

test('simultaneous clicks on one post share one native operation', async () => {
    let calls = 0;
    let release;
    const saved = new Promise(resolve => { release = resolve; });
    const engine = createDownloadEngine({resolveVideos: async () => [], saveMedia: async () => { calls++; await saved; return {ok: true, saved: 1}; }});
    const request = {postURL, hasVideo: false, media: [{kind: 'image', url: image().url}]};
    const first = engine.download(request);
    const second = engine.download(request);
    release();
    assert.deepEqual(await first, await second);
    assert.equal(calls, 1);
});

test('resolver failure saves no partial image batch and allows a clean retry', async () => {
    let fail = true;
    let saved = 0;
    const engine = createDownloadEngine({resolveVideos: async () => { if (fail) throw new Error('Offline'); return [{kind: 'video', url: 'https://service.test/clip.mp4'}]; }, saveMedia: async () => { saved++; return {ok: true, saved: 1}; }});
    const request = {postURL, hasVideo: true, media: [{kind: 'image', url: image().url}]};
    assert.equal((await engine.download(request)).ok, false);
    assert.equal(saved, 0);
    fail = false;
    assert.equal((await engine.download(request)).saved, 2);
});

test('proxy-prefix-agnostic service media is rooted at the configured service base', () => {
    const id = 'aabbccdd-1234-1234-1234-123456789abc';
    assert.equal(core.serviceMediaURL(`/v1/jobs/${id}/media/video.mp4`, 'https://media.example.com/downloader', id), `https://media.example.com/downloader/v1/jobs/${id}/media/video.mp4`);
});

test('service omission of an Instagram video prevents a falsely complete photo batch', async () => {
    let saved = 0;
    const engine = createDownloadEngine({resolveVideos: async () => [{kind: 'video', url: 'https://service.test/video.mp4'}], saveMedia: async () => { saved++; return {ok: true, saved: 1}; }});
    const result = await engine.download({postURL, hasVideo: true, expectedVideoCount: 2, media: [{kind: 'image', url: image().url}]});
    assert.equal(result.ok, false);
    assert.match(result.error, /every video/);
    assert.equal(saved, 0);
});

test('retry refreshes expired video job URLs and changed image URLs without resaving successes', async () => {
    let time = 100;
    let resolves = 0;
    let failVideo = true;
    const calls = [];
    const engine = createDownloadEngine({now: () => time, resolveVideos: async () => [{kind: 'video', url: `https://service.test/job-${++resolves}/video.mp4`}], saveMedia: async item => {
        calls.push(item.url);
        return item.kind === 'video' && failVideo ? {ok: false, error: 'Network failed'} : {ok: true, saved: 1};
    }});
    const request = {postURL, hasVideo: true, expectedVideoCount: 1, media: [{kind: 'image', url: image('old.jpg').url}]};
    assert.equal((await engine.download(request)).saved, 1);
    time += 11 * 60 * 1000;
    failVideo = false;
    assert.equal((await engine.download({...request, media: [{kind: 'image', url: image('fresh.jpg').url}]})).saved, 2);
    assert.equal(resolves, 2);
    assert.deepEqual(calls, [image('old.jpg').url, 'https://service.test/job-1/video.mp4', 'https://service.test/job-2/video.mp4']);
});

test('partial retry checkpoint survives a Safari background restart without service credentials', async () => {
    let checkpoint;
    let fail = true;
    let resolves = 0;
    const calls = [];
    const dependencies = {resolveVideos: async () => { resolves++; return [{kind: 'video', url: 'https://service.test/clip.mp4', resolverService: {token: 'secret'}}]; },
        loadCheckpoint: async () => checkpoint,
        saveCheckpoint: async (url, value) => { checkpoint = value; },
        saveMedia: async item => { calls.push(item.kind); return item.kind === 'video' && fail ? {ok: false, error: 'Offline'} : {ok: true, saved: 1}; }};
    const request = {postURL, hasVideo: true, expectedVideoCount: 1, media: [{kind: 'image', url: image().url}]};
    assert.equal((await createDownloadEngine(dependencies).download(request)).saved, 1);
    assert.equal(JSON.stringify(checkpoint).includes('secret'), false);
    fail = false;
    assert.equal((await createDownloadEngine(dependencies).download(request)).saved, 2);
    assert.deepEqual(calls, ['image', 'video', 'video']);
    assert.equal(resolves, 2);
    const before = resolves;
    assert.equal((await createDownloadEngine(dependencies).download(request)).saved, 2);
    assert.equal(resolves, before);
});
