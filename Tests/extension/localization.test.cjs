const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const project = path.resolve(__dirname, '../..');
const resources = path.join(project, 'Shared (Extension)/Resources');
const localeRoot = path.join(resources, '_locales');
const readJSON = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const messages = locale => readJSON(path.join(localeRoot, locale, 'messages.json'));
const nativeLocale = locale => ({zh_CN: 'zh-Hans', zh_TW: 'zh-Hant', pt_BR: 'pt-BR'}[locale] || locale);

test('Safari locales cover every English message and preserve substitution arguments', () => {
    const manifest = readJSON(path.join(resources, 'manifest.json'));
    assert.equal(manifest.default_locale, 'en');
    const english = messages(manifest.default_locale);
    for (const locale of fs.readdirSync(localeRoot)) {
        const translated = messages(locale);
        assert.deepEqual(Object.keys(translated).sort(), Object.keys(english).sort(), locale);
        for (const [key, entry] of Object.entries(translated)) {
            assert.ok(entry.message.trim(), locale + ': ' + key);
            assert.deepEqual(entry.placeholders, english[key].placeholders, locale + ': ' + key);
            const names = value => (value.match(/\$\w+\$/g) || []).sort();
            assert.deepEqual(names(entry.message), names(english[key].message), locale + ': ' + key);
        }
    }
});

test('native UI, shared errors, menus and privacy prompts cover the Safari locales', () => {
    const catalogs = ['Shared (App)/Resources/Localizable', 'Share (Extension)/Localizable',
        'Shared (Core)/Download', 'macOS (App)/mul.lproj/Main', 'Share (Extension)/InfoPlist'];
    for (const platform of ['macOS', 'iOS', 'visionOS']) {
        catalogs.push(platform + ' (App)/InfoPlist', platform + ' (Extension)/InfoPlist');
    }
    const locales = fs.readdirSync(localeRoot).filter(l => l !== 'en').map(nativeLocale);
    for (const name of catalogs) {
        const catalog = readJSON(path.join(project, name + '.xcstrings'));
        assert.equal(catalog.sourceLanguage, 'en', name);
        for (const [key, entry] of Object.entries(catalog.strings)) {
            const source = entry.localizations?.en?.stringUnit?.value ?? key;
            if (!source || entry.shouldTranslate === false) continue;
            for (const locale of locales) {
                const target = entry.localizations?.[locale]?.stringUnit?.value;
                const label = [name, key, locale].join(' / ');
                assert.ok(target?.trim(), label);
                const argumentsIn = value => (value.match(/%lld|%@|\$\{\w+\}/g) || []).sort();
                assert.deepEqual(argumentsIn(target), argumentsIn(source), label);
            }
        }
    }
});
