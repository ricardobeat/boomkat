function eq(a, b, m) { if (a !== b) throw new Error(m + ": " + JSON.stringify(a) + " !== " + JSON.stringify(b)); }

eq(new Intl.NumberFormat("en", { numberingSystem: "deva" }).format(1234.5), "१,२३४.५", "NumberFormat option");
eq(new Intl.NumberFormat("en-u-nu-arab").format(5), "٥", "NumberFormat keyword");
eq(new Intl.NumberFormat("en-u-nu-arab").resolvedOptions().locale, "en-u-nu-arab", "keyword is kept");
eq(new Intl.NumberFormat("en-u-nu-latn", { numberingSystem: "arab" }).resolvedOptions().locale, "en", "option replaces keyword");
eq(new Intl.NumberFormat("en-u-nu-invalid", { numberingSystem: "invalid2" }).resolvedOptions().numberingSystem, "latn", "unsupported falls back");
eq(new Intl.NumberFormat("en", { numberingSystem: "hanidec" }).format(1234), "一,二三四", "scattered digits");
eq(new Intl.NumberFormat("en", { numberingSystem: "mathbold" }).format(7), "𝟕", "astral digits");
eq(new Intl.DateTimeFormat("en", { numberingSystem: "thai", timeZone: "UTC" }).format(new Date(0)), "๑/๑/๑๙๗๐", "DateTimeFormat");
eq(new Intl.RelativeTimeFormat("en", { numberingSystem: "arab" }).format(3, "day"), "in ٣ days", "RelativeTimeFormat");

var systems = Intl.supportedValuesOf("numberingSystem");
eq(systems.indexOf("latn") >= 0 && systems.indexOf("hanidec") >= 0, true, "supportedValuesOf includes simple systems");
eq(systems.join() === systems.slice().sort().join(), true, "sorted");
eq(Intl.supportedValuesOf("unit").indexOf("kilometer") >= 0, true, "units");
eq(Intl.supportedValuesOf("currency").indexOf("USD") >= 0, true, "currencies");
eq(Intl.supportedValuesOf("timeZone").indexOf("UTC") >= 0, true, "time zones");
eq(Intl.supportedValuesOf("timeZone").indexOf("Asia/Calcutta"), -1, "aliases are not listed");
eq(Intl.supportedValuesOf("calendar").indexOf("gregory") >= 0, true, "calendars");
try { Intl.supportedValuesOf("calendars"); throw new Error("no throw"); } catch (e) { eq(e instanceof RangeError, true, "invalid key"); }
