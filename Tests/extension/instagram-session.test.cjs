const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const session = require('../../Shared (Extension)/Resources/instagram-session.js');
const resource = name => fs.readFileSync(require.resolve('../../Shared (Extension)/Resources/' + name), 'utf8');
const normalized = value => JSON.parse(JSON.stringify(value));
const cookie = (overrides = {}) => ({
    name: 'sessionid', value: 'user-session', domain: 'instagram.com', path: '/', secure: true, httpOnly: true,
    ...overrides
});
const readCookies = cookies => session.readSession({getAll: async () => cookies});

test('explicit cookie API handoff includes HttpOnly login and all six approved names with Unix expiration', async () => {
    const expirationDate = Date.now() / 1000 + 3600;
    const names = ['sessionid', 'csrftoken', 'ds_user_id', 'mid', 'ig_did', 'rur'];
    const cookies = names.map(name => cookie({name, expirationDate, domain: '.Instagram.COM', storeId: 'discard', hostOnly: false}));
    let query;
    const selected = await session.readSession({getAll: async options => { query = options; return cookies; }});
    assert.deepEqual(query, {url: 'https://www.instagram.com/'});
    assert.deepEqual(selected, names.map(name => cookie({name, expires: expirationDate})));
    assert.equal(selected[0].httpOnly, true);
    assert.equal('expirationDate' in selected[0], false);
    assert.equal('storeId' in selected[0], false);
});

test('only exact Instagram domains and root-path cookies survive the login handoff', async () => {
    const selected = await readCookies([
        cookie(),
        cookie({name: 'csrftoken', domain: 'www.instagram.com'}),
        cookie({name: 'mid', domain: 'instagram.com'}),
        cookie({name: 'ig_did', domain: '.www.instagram.com'}),
        cookie({name: 'analytics_id'}),
        cookie({name: 'csrftoken', domain: 'instagram.com.evil'}),
        cookie({name: 'csrftoken', domain: 'cdn.instagram.com'}),
        cookie({name: 'csrftoken', domain: 'evilinstagram.com'}),
        cookie({name: 'csrftoken', domain: '..instagram.com'}),
        cookie({name: 'mid', path: '/accounts'}),
        cookie({name: 'sessionid', domain: 'x.com'}),
        null
    ]);
    assert.deepEqual(selected.map(item => [item.name, item.domain]), [
        ['sessionid', 'instagram.com'], ['csrftoken', 'www.instagram.com'], ['mid', 'instagram.com'], ['ig_did', 'www.instagram.com']
    ]);
});

test('unavailable cookie API and API failures provide safe retry errors without a document.cookie fallback', async () => {
    for (const api of [undefined, {}, {getAll: true}, {getAll: async () => { throw new Error('private login details'); }}]) {
        await assert.rejects(session.readSession(api), {message: 'instagramCookiesUnavailable'});
    }
    await assert.rejects(readCookies([]), {message: 'instagramSessionMissing'});
    await assert.rejects(readCookies([cookie({name: 'csrftoken'})]), {message: 'instagramSessionMissing'});
});

test('expired, malformed, and unbounded session cookies are not imported', async () => {
    for (const overrides of [
        {value: ''}, {value: 'space value'}, {value: 'tab\tvalue'}, {value: 'line\nvalue'},
        {value: 'nul\u0000value'}, {value: 'del\u007fvalue'}, {value: 'semicolon;value'}, {value: 123},
        {value: 'a'.repeat(8193)}, {secure: 'true'}, {secure: false}, {httpOnly: undefined},
        {expirationDate: Date.now() / 1000 - 60}, {expirationDate: NaN}, {expirationDate: Infinity}, {expirationDate: 'future'},
        {expirationDate: 2 ** 63}, {expirationDate: Number.MAX_VALUE}
    ]) {
        await assert.rejects(readCookies([cookie(overrides)]), {message: 'instagramSessionMissing'});
    }
    await assert.rejects(readCookies({}), {message: 'invalidInstagramSession'});
    await assert.rejects(readCookies(Array(101).fill(cookie())), {message: 'invalidInstagramSession'});
});

test('session-cookie limits measure UTF-8 bytes and total payload bytes', async () => {
    const boundary = 'é'.repeat(4096);
    const selected = await readCookies([cookie({value: boundary})]);
    assert.equal(new TextEncoder().encode(selected[0].value).length, 8192);
    await assert.rejects(readCookies([cookie({value: boundary + 'é'})]), {message: 'instagramSessionMissing'});
    const names = ['sessionid', 'csrftoken', 'ds_user_id', 'mid'];
    assert.equal((await readCookies(names.map(name => cookie({name, value: boundary})))).length, 4);
    await assert.rejects(readCookies([...names.map(name => cookie({name, value: boundary})), cookie({name: 'ig_did', value: 'x'})]), {message: 'invalidInstagramSession'});
});

test('identical duplicates are deduplicated but conflicting sessions and cookie attributes reject the whole import', async () => {
    assert.deepEqual(await readCookies([cookie(), cookie({domain: '.Instagram.COM', storeId: 'extra'})]), [cookie()]);
    assert.equal((await readCookies([cookie(), cookie({domain: 'www.instagram.com'})])).length, 2);
    for (const cookies of [
        [cookie(), cookie({value: 'another-account'})],
        [cookie(), cookie({domain: 'www.instagram.com', value: 'another-account'})],
        [cookie(), cookie({httpOnly: false})],
        [cookie(), cookie({name: 'csrftoken'}), cookie({name: 'csrftoken', secure: false})],
        [cookie(), cookie({expirationDate: Date.now() / 1000 + 3600})],
        [cookie(), cookie({name: 'csrftoken', value: 'one'}), cookie({name: 'csrftoken', value: 'two'})]
    ]) {
        await assert.rejects(readCookies(cookies), {message: 'invalidInstagramSession'});
    }
});

test('dotted and undotted domains merge identical cookies and reject conflicts after canonicalization', async () => {
    assert.deepEqual(await readCookies([cookie(), cookie({domain: '.instagram.com'})]), [cookie()]);
    const wwwCookie = cookie({domain: 'www.instagram.com'});
    assert.deepEqual(await readCookies([wwwCookie, cookie({domain: '.www.instagram.com'})]), [wwwCookie]);
    for (const cookies of [
        [cookie(), cookie({domain: '.instagram.com', value: 'another-account'})],
        [cookie(), cookie({domain: '.instagram.com', httpOnly: false})],
        [cookie(), cookie({domain: '.instagram.com', expirationDate: Date.now() / 1000 + 3600})],
        [cookie(), cookie({name: 'csrftoken'}), cookie({name: 'csrftoken', domain: '.instagram.com', value: 'different'})]
    ]) {
        await assert.rejects(readCookies(cookies), {message: 'invalidInstagramSession'});
    }
});

test('session login requires secure transport while supporting other Instagram cookie attributes', async () => {
    const csrftoken = cookie({name: 'csrftoken', secure: false, httpOnly: false});
    assert.deepEqual(await readCookies([cookie(), csrftoken]), [cookie(), csrftoken]);
    await assert.rejects(readCookies([cookie({secure: false}), csrftoken]), {message: 'instagramSessionMissing'});
});

test('native requests revalidate normalized cookies and strip all unrelated fields', () => {
    const expires = Date.now() / 1000 + 3600;
    assert.deepEqual(session.nativeRequest({type: 'importInstagramSession', cookies: [cookie({expires, expirationDate: 1, storeId: 'extra'})], secret: 'extra'}), {
        type: 'importInstagramSession', cookies: [cookie({expires})]
    });
    for (const type of ['instagramSession', 'clearInstagramSession']) {
        assert.deepEqual(session.nativeRequest({type, cookies: [cookie()], secret: 'extra'}), {type});
    }
    assert.equal(session.nativeRequest({type: 'downloadPost'}), null);
    assert.equal(session.nativeRequest(undefined), null);
    assert.throws(() => session.nativeRequest({type: 'importInstagramSession', cookies: [cookie({expires: Date.now() / 1000 - 60})]}), {message: 'instagramSessionMissing'});
    for (const expires of [2 ** 63, Number.MAX_VALUE]) {
        assert.throws(() => session.nativeRequest({type: 'importInstagramSession', cookies: [cookie({expires})]}), {message: 'instagramSessionMissing'});
    }
});

async function popup(cookieAPI, options = {}) {
    const elements = new Map();
    const tags = new Map([...resource('popup.html').matchAll(/<[^>]*\bid="([^"]+)"[^>]*>/g)].map(match => [match[1], match[0]]));
    const messages = [];
    const logs = [];
    let documentCookieReads = 0;
    let storageAccesses = 0;
    function element(id) {
        if (!elements.has(id)) elements.set(id, {
            dataset: {}, listeners: {}, disabled: false,
            hidden: /(?:^|\s)hidden(?=\s|>)/.test(tags.get(id) || ''),
            addEventListener(type, callback) { this.listeners[type] = callback; }
        });
        return elements.get(id);
    }
    const document = {documentElement: {dataset: {}}, querySelectorAll: () => [], getElementById: element};
    Object.defineProperty(document, 'cookie', {get() { documentCookieReads++; throw new Error('document.cookie must never be read.'); }});
    const browser = {
        i18n: {getMessage: key => key, getUILanguage: () => 'en'},
        cookies: cookieAPI,
        runtime: {sendMessage: async message => {
            messages.push(normalized(message));
            if (message.type === 'nativeStatus') {
                if (options.nativeError) throw new Error('Native extension unavailable');
                return {ok: true, platform: options.platform, photosAuthorization: 'authorized', videoEngine: {available: true}};
            }
            if (message.type === 'instagramSession' && options.statusResponse !== undefined) return options.statusResponse;
            return {ok: true, instagramSession: {hasSession: message.type === 'importInstagramSession'}};
        }}
    };
    Object.defineProperty(browser, 'storage', {get() { storageAccesses++; throw new Error('Popup must not store login cookies.'); }});
    const context = vm.createContext({
        browser, document, TextEncoder,
        console: Object.fromEntries(['log', 'info', 'warn', 'error', 'debug'].map(level => [level, (...args) => logs.push(args)]))
    });
    vm.runInContext(resource('instagram-session.js'), context);
    await vm.runInContext('(async () => {\n' + resource('popup.js').replace(/^import .*;\n?/gm, '') + '\n})()', context);
    return {elements, messages, logs, document, documentCookieReads: () => documentCookieReads, storageAccesses: () => storageAccesses};
}

test('popup selects visionOS layout from native platform without reading cookies', async () => {
    for (const platform of ['visionOS', 'iOS', 'macOS', undefined, 'unexpected']) {
        const ui = await popup(undefined, {platform});
        assert.equal(ui.document.documentElement.dataset.platform, ['visionOS', 'iOS', 'macOS'].includes(platform) ? platform : undefined);
        assert.deepEqual(ui.messages, [{type: 'nativeStatus'}, {type: 'instagramSession'}]);
        assert.equal(ui.documentCookieReads(), 0);
    }
    const failed = await popup(undefined, {nativeError: true});
    assert.equal(failed.document.documentElement.dataset.platform, undefined);
    assert.equal(failed.elements.get('photos-status').textContent, 'nativeUnavailable');
    assert.equal(failed.elements.get('sync-instagram').disabled, false);
});

test('popup startup reads status only; cookie access happens once on the explicit sync click', async () => {
    const queries = [];
    const ui = await popup({getAll: async options => { queries.push(normalized(options)); return [cookie()]; }});
    assert.deepEqual(ui.messages, [{type: 'nativeStatus'}, {type: 'instagramSession'}]);
    assert.deepEqual(queries, []);
    assert.equal(ui.elements.get('forget-instagram').hidden, false);
    await ui.elements.get('sync-instagram').listeners.click();
    assert.deepEqual(queries, [{url: 'https://www.instagram.com/'}]);
    assert.deepEqual(ui.messages.at(-1), {type: 'importInstagramSession', cookies: [cookie()]});
    assert.equal(ui.elements.get('forget-instagram').hidden, false);
    await ui.elements.get('forget-instagram').listeners.click();
    assert.deepEqual(ui.messages.at(-1), {type: 'clearInstagramSession'});
    assert.equal(queries.length, 1);
    assert.equal(ui.elements.get('forget-instagram').hidden, false);
    assert.equal(ui.documentCookieReads(), 0);
    assert.equal(ui.storageAccesses(), 0);
    assert.deepEqual(ui.logs, []);
    assert.equal([...ui.elements.values()].some(element => element.textContent?.includes('user-session')), false);
});

test('popup with unavailable cookie API gives a safe error and does not try document.cookie or import', async () => {
    const ui = await popup(undefined);
    await ui.elements.get('sync-instagram').listeners.click();
    assert.equal(ui.elements.get('instagram-error').textContent, 'instagramCookiesUnavailable');
    assert.equal(ui.elements.get('instagram-error').hidden, false);
    assert.equal(ui.elements.get('sync-instagram').disabled, false);
    assert.deepEqual(ui.messages.map(message => message.type), ['nativeStatus', 'instagramSession']);
    assert.equal(ui.documentCookieReads(), 0);
    assert.equal(ui.storageAccesses(), 0);
    assert.deepEqual(ui.logs, []);
});

test('unavailable or malformed login status is not mistaken for signed out and can still be cleared without reading cookies', async () => {
    const secret = 'keychain-private-diagnostic';
    for (const statusResponse of [
        {ok: true, instagramSession: {hasSession: false, error: secret}},
        {ok: false, code: 'instagramSessionFailed', error: secret},
        {ok: true, instagramSession: {}},
        {ok: true, instagramSession: {hasSession: 'false'}}
    ]) {
        let cookieReads = 0;
        const ui = await popup({getAll: async () => { cookieReads++; throw new Error('Clear must not read cookies.'); }}, {statusResponse});
        assert.equal(ui.elements.get('instagram-status').textContent, 'instagramSessionUnavailable');
        assert.equal(ui.elements.get('instagram-error').textContent, 'instagramSessionFailed');
        assert.equal(ui.elements.get('instagram-error').hidden, false);
        assert.equal(ui.elements.get('forget-instagram').hidden, false);
        assert.equal(ui.elements.get('forget-instagram').disabled, false);
        await ui.elements.get('forget-instagram').listeners.click();
        assert.deepEqual(ui.messages, [{type: 'nativeStatus'}, {type: 'instagramSession'}, {type: 'clearInstagramSession'}]);
        assert.equal(ui.elements.get('instagram-status').textContent, 'instagramSessionNotSynced');
        assert.equal(ui.elements.get('forget-instagram').hidden, false);
        assert.equal(ui.elements.get('forget-instagram').disabled, false);
        assert.equal(ui.elements.get('instagram-error').hidden, true);
        assert.equal(cookieReads, 0);
        assert.equal(ui.documentCookieReads(), 0);
        assert.equal(ui.storageAccesses(), 0);
        assert.deepEqual(ui.logs, []);
        assert.equal([...ui.elements.values()].some(element => element.textContent?.includes(secret)), false);
    }
});
