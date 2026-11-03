// Region variants that CLDR ships a locale for resolve to the requested tag, others to the
// language. Expected values come from Node.js 24 (ICU 77): [request, DateTimeFormat, NumberFormat].
// Non-English rows exist only in an intl=full build, so the checks run only when `de` has one.
function eq(actual, expected, what) {
    if (actual !== expected) throw new Error(what + ': expected ' + expected + ', got ' + actual);
}
const rows = [
  ["de", "de", "de"],
  ["de-DE", "de-DE", "de-DE"],
  ["de-AT", "de-AT", "de-AT"],
  ["de-CH", "de-CH", "de-CH"],
  ["de-XX", "de", "de"],
  ["de-US", "de", "de"],
  ["fr-FR", "fr-FR", "fr-FR"],
  ["fr-CA", "fr-CA", "fr-CA"],
  ["fr-ZZ", "fr", "fr"],
  ["ja-JP", "ja-JP", "ja-JP"],
  ["ja-US", "ja", "ja"],
  ["pt-BR", "pt-BR", "pt-BR"],
  ["pt-PT", "pt-PT", "pt-PT"],
  ["pt-AO", "pt-AO", "pt-AO"],
  ["zh-CN", "zh-CN", "zh-CN"],
  ["zh-TW", "zh-TW", "zh-TW"],
  ["zh-HK", "zh-HK", "zh-HK"],
  ["zh-Hans", "zh-Hans", "zh-Hans"],
  ["zh-Hant", "zh-Hant", "zh-Hant"],
  ["zh-Hans-CN", "zh-Hans-CN", "zh-Hans-CN"],
  ["zh-Hant-TW", "zh-Hant-TW", "zh-Hant-TW"],
  ["zh-Hant-HK", "zh-Hant-HK", "zh-Hant-HK"],
  ["zh-Hans-SG", "zh-Hans-SG", "zh-Hans-SG"],
  ["zh-Hant-CN", "zh-Hant", "zh-Hant"],
  ["ru-RU", "ru-RU", "ru-RU"],
  ["ru-UA", "ru-UA", "ru-UA"],
  ["es-ES", "es-ES", "es-ES"],
  ["es-MX", "es-MX", "es-MX"],
  ["es-419", "es-419", "es-419"],
  ["es-Latn-ES", "es", "es"],
  ["sr", "sr", "sr"],
  ["sr-Latn", "sr-Latn", "sr-Latn"],
  ["sr-Latn-RS", "sr-Latn-RS", "sr-Latn-RS"],
  ["sr-Cyrl", "sr-Cyrl", "sr-Cyrl"],
  ["sr-RS", "sr-RS", "sr-RS"],
  ["en-GB", "en-GB", "en-GB"],
  ["en-US", "en-US", "en-US"],
  ["en-AU", "en-AU", "en-AU"],
  ["en-XX", "en", "en"],
  ["ar-EG", "ar-EG", "ar-EG"],
  ["ar-SA", "ar-SA", "ar-SA"],
  ["it-IT", "it-IT", "it-IT"],
  ["ko-KR", "ko-KR", "ko-KR"],
  ["sv-SE", "sv-SE", "sv-SE"],
  ["pl-PL", "pl-PL", "pl-PL"],
  ["tr-TR", "tr-TR", "tr-TR"],
  ["hi-IN", "hi-IN", "hi-IN"],
  ["th-TH", "th-TH", "th-TH"],
  ["sl-SI", "sl-SI", "sl-SI"],
  ["de-DE-u-nu-arab", "de-DE-u-nu-arab", "de-DE-u-nu-arab"],
  ["de-u-nu-arab", "de-u-nu-arab", "de-u-nu-arab"],
  ["fr-FR-u-nu-latn", "fr-FR-u-nu-latn", "fr-FR-u-nu-latn"],
  ["de-DE-u-ca-buddhist", "de-DE-u-ca-buddhist", "de-DE"],
  ["ja-JP-u-ca-japanese", "ja-JP-u-ca-japanese", "ja-JP"],
  ["de-DE-u-hc-h12", "de-DE-u-hc-h12", "de-DE"],
];
if (new Intl.NumberFormat('de').resolvedOptions().locale === 'de') {
    const others = {
        RelativeTimeFormat: (l) => new Intl.RelativeTimeFormat(l),
        ListFormat: (l) => new Intl.ListFormat(l),
        DurationFormat: (l) => new Intl.DurationFormat(l),
    };
    for (const [tag, dtf, nf] of rows) {
        eq(new Intl.DateTimeFormat(tag).resolvedOptions().locale, dtf, 'DateTimeFormat ' + tag);
        eq(new Intl.NumberFormat(tag).resolvedOptions().locale, nf, 'NumberFormat ' + tag);
        // Without keywords every service resolves alike.
        if (!tag.includes('-u-')) {
            for (const name in others) eq(others[name](tag).resolvedOptions().locale, nf, name + ' ' + tag);
        }
    }
    // supportedLocalesOf answers for the requested tag, whatever the region.
    eq(Intl.DateTimeFormat.supportedLocalesOf(['de-XX', 'de-DE']).join(), 'de-XX,de-DE', 'supportedLocalesOf');
    // An unsupported language falls back to the default locale.
    eq(new Intl.DateTimeFormat('xx-YY').resolvedOptions().locale, 'en-US', 'xx-YY');
    eq(new Intl.ListFormat('xx-YY').resolvedOptions().locale, 'en-US', 'ListFormat xx-YY');
}
