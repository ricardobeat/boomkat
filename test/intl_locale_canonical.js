function eq(a, b, m) { if (a !== b) throw new Error(m + ": " + JSON.stringify(a) + " !== " + JSON.stringify(b)); }
var cases = {
  "sh": "sr-Latn", "sh-Cyrl": "sr-Cyrl", "cnr": "sr-ME", "cnr-BA": "sr-BA",
  "ru-SU": "ru-RU", "hy-SU": "hy-AM", "sr-CS": "sr-RS", "az-NT": "az-SA", "und-810": "und-RU",
  "zh-guoyu": "zh", "art-lojban": "jbo", "ja-latn-hepburn-heploc": "ja-Latn-alalc97",
  "hy-arevmda": "hyw", "mo": "ro", "aar-x-private": "aa-x-private", "sgn-BR": "bzs",
  "und-u-ca-islamicc": "und-u-ca-islamic-civil", "und-u-ks-primary": "und-u-ks-level1",
  "und-u-tz-eire": "und-u-tz-iedub", "und-u-kb-yes": "und-u-kb", "und-NO-u-sd-no23": "und-NO-u-sd-no50",
  "en-t-iw": "en-t-he", "DE-T-M0-DIN-K0-QWERTZ": "de-t-k0-qwertz-m0-din",
  "und-Latn-t-und-hani-m0-names": "und-Latn-t-und-hani-m0-prprname",
  "EN-us-U-CO-phonebk-ca-gregory": "en-US-u-ca-gregory-co-phonebk",
  "en-u-attr-co-abc-ca-gregory": "en-u-attr-ca-gregory-co-abc",
  "en-b-bbb-a-aaa-x-private": "en-a-aaa-b-bbb-x-private",
};
for (var tag in cases) eq(Intl.getCanonicalLocales(tag)[0], cases[tag], tag);
["i-klingon", "en-GB-oed", "zh-min-nan", "en-u", "x-private"].forEach(function (tag) {
  try { Intl.getCanonicalLocales(tag); throw new Error("accepted " + tag); } catch (e) { eq(e instanceof RangeError, true, tag); }
});
