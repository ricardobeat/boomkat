function eq(a, b, m) { if (a !== b) throw new Error(m + ": " + JSON.stringify(a) + " !== " + JSON.stringify(b)); }
function list(a, b, m) { eq(a.join(), b.join(), m); }
function throws(E, f, m) { try { f(); } catch (e) { eq(e instanceof E, true, m); return; } throw new Error("no throw: " + m); }

var l = new Intl.Locale("de-latn-de-fonipa-1996-u-ca-gregory-co-phonebk-hc-h23-kf-true-kn-false-nu-latn");
eq(l.toString(), "de-Latn-DE-1996-fonipa-u-ca-gregory-co-phonebk-hc-h23-kf-kn-false-nu-latn", "toString");
eq(l.baseName, "de-Latn-DE-1996-fonipa", "baseName");
eq(l.language + l.script + l.region + l.variants, "deLatnDE1996-fonipa", "subtags");
eq(l.calendar + l.collation + l.hourCycle + l.numberingSystem, "gregoryphonebkh23latn", "keywords");
eq(l.caseFirst, "", "caseFirst true is empty");
eq(l.numeric, false, "numeric");
eq(new Intl.Locale("en").script, undefined, "missing script");

var o = new Intl.Locale("en-US", { language: "fr", variants: "Hepburn", calendar: "japanese", firstDayOfWeek: 1, numeric: true, hourCycle: "h11" });
eq(o.toString(), "fr-US-hepburn-u-ca-japanese-fw-mon-hc-h11-kn", "options");
eq(new Intl.Locale("und-Armn-SU", { language: "ru" }).toString(), "ru-Armn-AM", "canonicalizes before options");
throws(RangeError, function () { new Intl.Locale("en", { variants: "fonipa-Fonipa" }); }, "duplicate variants");
throws(RangeError, function () { new Intl.Locale("en-emodeng-Emodeng"); }, "duplicate variants in tag");
throws(TypeError, function () { Intl.Locale("en"); }, "requires new");
throws(TypeError, function () { new Intl.Locale(); }, "tag required");
throws(RangeError, function () { new Intl.Locale("en", { hourCycle: "h25" }); }, "hourCycle");

eq(new Intl.Locale("en-US").maximize().toString(), "en-Latn-US", "maximize");
eq(new Intl.Locale("zh-Hant").maximize().toString(), "zh-Hant-TW", "maximize script");
eq(new Intl.Locale("en-Latn-US-u-ca-gregory").minimize().toString(), "en-u-ca-gregory", "minimize keeps extensions");
eq(new Intl.Locale("und-CW").minimize().toString(), "pap", "minimize names its language");
eq(new Intl.Locale("jbo").maximize().toString(), "jbo-Latn-001", "alias target maximizes");

list(new Intl.Locale("en-US").getHourCycles(), ["h12", "h23"], "US hour cycles");
list(new Intl.Locale("en-GB").getHourCycles(), ["h23", "h12"], "GB hour cycles");
list(new Intl.Locale("en-US-u-hc-h24").getHourCycles(), ["h24"], "hc keyword");
list(new Intl.Locale("en-US-u-rg-gbzzzz").getHourCycles(), ["h23", "h12"], "region override");
list(new Intl.Locale("en-u-sd-gbeng").getHourCycles(), ["h23", "h12"], "subdivision region");
eq(new Intl.Locale("fa").getCalendars()[0], "persian", "likely region calendar");
list(new Intl.Locale("en-US").getCalendars(), ["gregory"], "calendars");
list(new Intl.Locale("zh").getCollations(), ["emoji", "eor", "pinyin", "stroke", "unihan", "zhuyin"], "collations");
list(new Intl.Locale("und").getCollations(), ["emoji", "eor"], "root collations");
list(new Intl.Locale("de-u-co-phonebk").getCollations(), ["phonebk"], "collation keyword");
list(new Intl.Locale("ar-EG").getNumberingSystems(), ["arab"], "numbering");
list(new Intl.Locale("ar").getNumberingSystems(), ["latn"], "numbering default");
eq(new Intl.Locale("en").getTimeZones(), undefined, "no region");
var zones = new Intl.Locale("de-DE").getTimeZones();
list(zones, ["Europe/Berlin", "Europe/Busingen"], "zones");
eq(new Intl.Locale("ar").getTextInfo().direction, "rtl", "rtl");
eq(new Intl.Locale("en").getTextInfo().direction, "ltr", "ltr");
var w = new Intl.Locale("en-US").getWeekInfo();
eq(w.firstDay, 7, "US first day");
list(w.weekend, [6, 7], "US weekend");
w = new Intl.Locale("ar-AF").getWeekInfo();
eq(w.firstDay, 6, "AF first day");
list(w.weekend, [4, 5], "AF weekend");
eq(new Intl.Locale("en-u-fw-wed").getWeekInfo().firstDay, 3, "fw keyword");

list(Intl.getCanonicalLocales(new Intl.Locale("ar")), ["ar"], "Locale object as list");
list(Intl.getCanonicalLocales([new Intl.Locale("fa"), "zh-guoyu"]), ["fa", "zh"], "Locale in array");
eq(Object.prototype.toString.call(l), "[object Intl.Locale]", "toStringTag");
class Sub extends Intl.Locale {}
eq(new Sub("en") instanceof Sub, true, "subclassing");
