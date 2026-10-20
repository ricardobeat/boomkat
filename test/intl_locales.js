// Non-English rows exist only in an intl=full build. Under the default build
// `de` resolves to English, so the checks below run only when the row is present.
function eq(actual, expected) {
    if (actual !== expected) throw new Error('Expected ' + expected + ', got ' + actual);
}
if (new Intl.NumberFormat('de').resolvedOptions().locale === 'de') {
    // A likely-subtag match retains the request; an unavailable region truncates to the language.
    eq(new Intl.NumberFormat('zh-TW').resolvedOptions().locale, 'zh-TW');
    eq(new Intl.NumberFormat('zh-HK').resolvedOptions().locale, 'zh');
    eq(new Intl.NumberFormat('zh-Hant').resolvedOptions().locale, 'zh-Hant');
    eq(new Intl.NumberFormat('fr-CA').resolvedOptions().locale, 'fr');
    eq(new Intl.NumberFormat('en-IN').format(1234567), '12,34,567');

    // Symbols and grouping come from the row.
    eq(new Intl.NumberFormat('de').format(1234567.891), '1.234.567,891');

    // Compact patterns: a zero-only pattern leaves the number unscaled (ja 10^3),
    // long style falls back to the short patterns, and quoted literals are unquoted.
    eq(new Intl.NumberFormat('ja', { notation: 'compact' }).format(9876), '9876');
    eq(new Intl.NumberFormat('ja', { notation: 'compact' }).format(98765), '9.9万');
    eq(new Intl.NumberFormat('zh-TW', { notation: 'compact', compactDisplay: 'long' }).format(987654321), '9.9\u5104');
    eq(new Intl.NumberFormat('ko', { notation: 'compact' }).format(987654321), '9.9억');

    // Unit suffixes use the denominator's narrow name and the row's compound pattern.
    eq(new Intl.NumberFormat('de', { style: 'unit', unit: 'kilometer-per-hour' }).format(-987), '-987 km/h');
    eq(new Intl.NumberFormat('de', { style: 'unit', unit: 'kilometer-per-hour', unitDisplay: 'long' }).format(-987), '-987 Kilometer pro Stunde');

    // CLDR plural rules: compact selection reads the unscaled value, with e as the magnitude.
    eq(new Intl.PluralRules('fr', { notation: 'compact' }).select(1e6), 'many');
    eq(new Intl.PluralRules('fr', { notation: 'compact' }).select(1e-6), 'one');
    eq(new Intl.PluralRules('pl').select(3), 'few');
}
