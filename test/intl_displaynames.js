function eq(a, b) { if (a !== b) throw new Error('expected ' + JSON.stringify(b) + ' got ' + JSON.stringify(a)); }
var lang = new Intl.DisplayNames('en', { type: 'language' });
var std = new Intl.DisplayNames('en', { type: 'language', languageDisplay: 'standard' });
eq(lang.of('en-US'), 'American English');
eq(std.of('en-US'), 'English (United States)');
eq(lang.of('zh-Hant'), 'Traditional Chinese');
eq(lang.of('de-AT-1996'), 'Austrian German (German orthography of 1996)');
eq(lang.of('sr-Cyrl-RS'), 'Serbian (Cyrillic, Serbia)');
eq(lang.of('iw'), 'Hebrew');
var region = new Intl.DisplayNames('en', { type: 'region' });
eq(region.of('us'), 'United States');
eq(region.of('419'), 'Latin America');
eq(new Intl.DisplayNames('en', { type: 'region', style: 'short' }).of('HK'), 'Hong Kong');
eq(new Intl.DisplayNames('en', { type: 'script' }).of('latn'), 'Latin');
eq(new Intl.DisplayNames('en', { type: 'currency' }).of('usd'), 'US dollar');
eq(new Intl.DisplayNames('en', { type: 'currency', style: 'narrow' }).of('cad'), '$');
eq(new Intl.DisplayNames('en', { type: 'calendar' }).of('gregory'), 'Gregorian Calendar');
eq(new Intl.DisplayNames('en', { type: 'dateTimeField' }).of('weekOfYear'), 'week');
eq(new Intl.DisplayNames('en', { type: 'dateTimeField', style: 'short' }).of('year'), 'yr.');
eq(new Intl.DisplayNames('en', { type: 'region', fallback: 'none' }).of('ZZ'), 'Unknown Region');
eq(new Intl.DisplayNames('en', { type: 'language', fallback: 'none' }).of('zz'), undefined);
eq(lang.of('zz'), 'zz');
try { lang.of('root'); throw new Error('no throw'); } catch (e) { eq(e instanceof RangeError, true); }
eq(JSON.stringify(lang.resolvedOptions()), '{"locale":"en","style":"long","type":"language","fallback":"code","languageDisplay":"dialect"}');
print('ok');
