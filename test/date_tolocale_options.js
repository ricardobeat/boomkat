// Date.prototype.toLocale{,Date,Time}String options bag.
//
// Every expectation here is pinned to timeZone "UTC" or asserted on structure,
// never on a formatted local string: the engine renders in the host zone by
// default, so a local expectation would pass only on the machine that wrote it.

var __failed = false;
var __checks = 0;

function assert(cond, msg) {
    __checks++;
    if (!cond) { console.log("FAIL: " + msg); __failed = true; }
}

function assertEq(actual, expected, msg) {
    __checks++;
    if (actual !== expected) {
        console.log("FAIL: " + msg + " -- got " + JSON.stringify(actual) +
                    ", want " + JSON.stringify(expected));
        __failed = true;
    }
}

function assertThrows(name, fn, msg) {
    __checks++;
    try {
        fn();
        console.log("FAIL: " + msg + " -- no throw, expected " + name);
        __failed = true;
    } catch (e) {
        if (e.name !== name) {
            console.log("FAIL: " + msg + " -- threw " + e.name + ", expected " + name);
            __failed = true;
        }
    }
}

var d = new Date(Date.UTC(2024, 0, 15, 14, 5, 6, 123));
function U(extra) {
    var o = { timeZone: "UTC" };
    for (var k in extra) o[k] = extra[k];
    return o;
}

// ---------------------------------------------------------------------------
// No arguments keeps the pre-options output
// ---------------------------------------------------------------------------

assertEq(d.toLocaleString(), d.toString(),
    "toLocaleString() with no args is toString()");
assertEq(d.toLocaleString(undefined), d.toString(),
    "explicit undefined locales behaves as absent");
assertEq(d.toLocaleString(undefined, undefined), d.toString(),
    "two explicit undefineds behave as absent");
assert(/^\d{4}-\d{2}-\d{2}$/.test(d.toLocaleDateString()),
    "toLocaleDateString() with no args is YYYY-MM-DD");
assert(/^\d{2}:\d{2}:\d{2}$/.test(d.toLocaleTimeString()),
    "toLocaleTimeString() with no args is HH:MM:SS");
assertEq(d.toLocaleDateString(undefined, undefined), d.toLocaleDateString(),
    "toLocaleDateString undefined args match no args");
assertEq(d.toLocaleTimeString(undefined, undefined), d.toLocaleTimeString(),
    "toLocaleTimeString undefined args match no args");

// ---------------------------------------------------------------------------
// Defaults, per ECMA-402 11.1.2 needDefaults
// ---------------------------------------------------------------------------

assertEq(d.toLocaleString("en-US", U({})), "1/15/2024, 2:05:06 PM",
    "default toLocaleString is numeric date plus 12-hour time");
assertEq(d.toLocaleDateString("en-US", U({})), "1/15/2024",
    "default toLocaleDateString is the date half only");
assertEq(d.toLocaleTimeString("en-US", U({})), "2:05:06 PM",
    "default toLocaleTimeString is the time half only");

// ---------------------------------------------------------------------------
// dateStyle and timeStyle
// ---------------------------------------------------------------------------

assertEq(d.toLocaleDateString("en-US", U({dateStyle: "full"})),
    "Monday, January 15, 2024", "dateStyle full");
assertEq(d.toLocaleDateString("en-US", U({dateStyle: "long"})),
    "January 15, 2024", "dateStyle long");
assertEq(d.toLocaleDateString("en-US", U({dateStyle: "medium"})),
    "Jan 15, 2024", "dateStyle medium");
assertEq(d.toLocaleDateString("en-US", U({dateStyle: "short"})),
    "1/15/24", "dateStyle short");

assertEq(d.toLocaleTimeString("en-US", U({timeStyle: "full"})),
    "2:05:06 PM Coordinated Universal Time", "timeStyle full");
assertEq(d.toLocaleTimeString("en-US", U({timeStyle: "long"})),
    "2:05:06 PM UTC", "timeStyle long");
assertEq(d.toLocaleTimeString("en-US", U({timeStyle: "medium"})),
    "2:05:06 PM", "timeStyle medium");
assertEq(d.toLocaleTimeString("en-US", U({timeStyle: "short"})),
    "2:05 PM", "timeStyle short");

assertEq(d.toLocaleString("en-US", U({dateStyle: "full", timeStyle: "long"})),
    "Monday, January 15, 2024 at 2:05:06 PM UTC", "dateStyle full + timeStyle long");
assertEq(d.toLocaleString("en-US", U({dateStyle: "short", timeStyle: "short"})),
    "1/15/24, 2:05 PM", "dateStyle short + timeStyle short");

// ---------------------------------------------------------------------------
// Component options
// ---------------------------------------------------------------------------

assertEq(d.toLocaleDateString("en-US", U({year: "numeric"})), "2024", "year numeric");
assertEq(d.toLocaleDateString("en-US", U({year: "2-digit"})), "24", "year 2-digit");
assertEq(d.toLocaleDateString("en-US", U({month: "numeric"})), "1", "month numeric");
assertEq(d.toLocaleDateString("en-US", U({month: "2-digit"})), "01", "month 2-digit");
assertEq(d.toLocaleDateString("en-US", U({month: "long"})), "January", "month long");
assertEq(d.toLocaleDateString("en-US", U({month: "short"})), "Jan", "month short");
assertEq(d.toLocaleDateString("en-US", U({month: "narrow"})), "J", "month narrow");
assertEq(d.toLocaleDateString("en-US", U({day: "numeric"})), "15", "day numeric");
assertEq(d.toLocaleDateString("en-US", U({day: "2-digit"})), "15", "day 2-digit");
assertEq(d.toLocaleDateString("en-US", U({weekday: "long"})), "Monday", "weekday long");
assertEq(d.toLocaleDateString("en-US", U({weekday: "short"})), "Mon", "weekday short");
assertEq(d.toLocaleDateString("en-US", U({weekday: "narrow"})), "M", "weekday narrow");

assertEq(d.toLocaleTimeString("en-US", U({hour: "numeric"})), "2 PM", "hour numeric");
assertEq(d.toLocaleTimeString("en-US", U({hour: "2-digit"})), "02 PM", "hour 2-digit");
assertEq(d.toLocaleTimeString("en-US", U({minute: "numeric"})), "5", "lone minute is unpadded");
assertEq(d.toLocaleTimeString("en-US", U({second: "numeric"})), "6", "lone second is unpadded");
assertEq(d.toLocaleTimeString("en-US", U({minute: "numeric", second: "numeric"})),
    "05:06", "minute and second together are padded");

assertEq(d.toLocaleDateString("en-US", U({year: "numeric", month: "long", day: "numeric"})),
    "January 15, 2024", "spelled month leads, year trails after a comma");
assertEq(d.toLocaleDateString("en-US",
        U({weekday: "long", year: "numeric", month: "long", day: "numeric"})),
    "Monday, January 15, 2024", "weekday precedes a spelled date");
assertEq(d.toLocaleDateString("en-US", U({year: "2-digit", month: "2-digit", day: "2-digit"})),
    "01/15/24", "numeric date is month-first and slash-separated");

// era
assertEq(d.toLocaleDateString("en-US", U({year: "numeric", era: "short"})),
    "2024 AD", "era short");
assertEq(d.toLocaleDateString("en-US", U({year: "numeric", era: "long"})),
    "2024 Anno Domini", "era long");
assertEq(d.toLocaleDateString("en-US", U({year: "numeric", era: "narrow"})),
    "2024 A", "era narrow");
var bc = new Date(Date.UTC(-1, 5, 1));
assertEq(bc.toLocaleDateString("en-US", U({year: "numeric", era: "short"})),
    "2 BC", "a non-positive proleptic year renders as BC");

// hour12 and hourCycle
assertEq(d.toLocaleTimeString("en-US", U({hour: "numeric", hour12: false})),
    "14", "hour12 false uses the 24-hour clock");
assertEq(d.toLocaleTimeString("en-US", U({hour: "numeric", minute: "numeric", hour12: false})),
    "14:05", "24-hour clock pads the hour");
assertEq(d.toLocaleTimeString("en-US", U({hour: "numeric", hour12: true})),
    "2 PM", "hour12 true uses the 12-hour clock");
assertEq(d.toLocaleTimeString("en-US", U({hour: "numeric", hourCycle: "h23"})),
    "14", "hourCycle h23 uses the 24-hour clock");
assertEq(d.toLocaleTimeString("en-US", U({hour: "numeric", hourCycle: "h12"})),
    "2 PM", "hourCycle h12 uses the 12-hour clock");
assertEq(d.toLocaleTimeString("en-US", U({hour: "numeric", hour12: true, hourCycle: "h23"})),
    "2 PM", "an explicit hour12 overrides hourCycle");
var mid = new Date(Date.UTC(2024, 0, 15, 0, 30, 0));
assertEq(mid.toLocaleTimeString("en-US", U({hour: "numeric", minute: "numeric"})),
    "12:30 AM", "midnight is 12 AM on the 12-hour clock");
assertEq(mid.toLocaleTimeString("en-US", U({hour: "numeric", minute: "numeric", hour12: false})),
    "00:30", "midnight is 00 on the 24-hour clock");

// timeZoneName
assertEq(d.toLocaleTimeString("en-US", U({hour: "numeric", timeZoneName: "short"})),
    "2 PM UTC", "timeZoneName short names the UTC zone");
assertEq(d.toLocaleTimeString("en-US", U({hour: "numeric", timeZoneName: "long"})),
    "2 PM Coordinated Universal Time", "timeZoneName long spells UTC out");

// fractionalSecondDigits
assertEq(d.toLocaleTimeString("en-US", U({fractionalSecondDigits: 1})), "1", "fsd 1");
assertEq(d.toLocaleTimeString("en-US", U({fractionalSecondDigits: 2})), "12", "fsd 2");
assertEq(d.toLocaleTimeString("en-US", U({fractionalSecondDigits: 3})), "123", "fsd 3");
assertEq(d.toLocaleTimeString("en-US", U({second: "numeric", fractionalSecondDigits: 3})),
    "6.123", "fsd attaches to the seconds with a decimal point");

// A component from the other half is still honoured: 20.4.2 passes date/date
// to CreateDateTimeFormat, which only governs the defaults.
assertEq(d.toLocaleDateString("en-US", U({hour: "numeric"})), "1/15/2024, 2 PM",
    "toLocaleDateString still renders an explicitly requested hour");
assertEq(d.toLocaleTimeString("en-US", U({weekday: "short"})), "Mon 2:05:06 PM",
    "toLocaleTimeString still renders an explicitly requested weekday");

// ---------------------------------------------------------------------------
// timeZone
// ---------------------------------------------------------------------------

var tzFmt = { timeZone: "UTC", hour12: false, year: "numeric", month: "2-digit",
              day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" };

// Instants straddling DST transitions in the common zones. Rendered in UTC
// they must equal the ISO string regardless of the host zone.
var instants = [
    Date.UTC(2024, 2, 10, 6, 59, 59), Date.UTC(2024, 2, 10, 7, 0, 0),
    Date.UTC(2024, 10, 3, 5, 59, 59), Date.UTC(2024, 10, 3, 6, 0, 0),
    Date.UTC(2024, 1, 17, 2, 59, 59), Date.UTC(2024, 1, 17, 3, 0, 0),
    Date.UTC(1970, 0, 1, 0, 0, 0), Date.UTC(2000, 0, 1, 0, 0, 0),
    Date.UTC(2024, 6, 4, 12, 0, 0)
];
for (var i = 0; i < instants.length; i++) {
    var t = new Date(instants[i]);
    var iso = t.toISOString();
    var want = iso.slice(5, 7) + "/" + iso.slice(8, 10) + "/" + iso.slice(0, 4) +
               ", " + iso.slice(11, 19);
    assertEq(t.toLocaleString("en-US", tzFmt), want,
        "timeZone UTC agrees with toISOString at " + iso);
}

// UTC aliases
var aliases = ["UTC", "utc", "GMT", "gmt", "Etc/UTC", "Etc/GMT", "Universal", "Zulu", "Z"];
for (var i = 0; i < aliases.length; i++) {
    var o = { timeZone: aliases[i], hour: "2-digit", minute: "2-digit", hour12: false };
    assertEq(d.toLocaleTimeString("en-US", o), "14:05",
        "timeZone " + aliases[i] + " is UTC");
}

// Numeric offsets
assertEq(d.toLocaleTimeString("en-US",
        { timeZone: "+05:30", hour: "2-digit", minute: "2-digit", hour12: false }),
    "19:35", "timeZone +05:30 shifts the clock forward");
assertEq(d.toLocaleTimeString("en-US",
        { timeZone: "-0300", hour: "2-digit", minute: "2-digit", hour12: false }),
    "11:05", "timeZone -0300 shifts the clock back");
assertEq(d.toLocaleTimeString("en-US",
        { timeZone: "+09", hour: "2-digit", minute: "2-digit", hour12: false }),
    "23:05", "timeZone +09 accepts the hour-only form");
assertEq(d.toLocaleTimeString("en-US",
        { timeZone: "-0300", hour: "2-digit", timeZoneName: "short", hour12: false }),
    "11 GMT-0300", "an offset zone names itself by its offset");

// A named IANA zone needs a database this engine does not carry. It is
// rejected rather than silently formatted in the wrong zone.
assertThrows("RangeError", function () {
    d.toLocaleString("en-US", { timeZone: "America/New_York" });
}, "a named IANA zone is a RangeError");
assertThrows("RangeError", function () {
    d.toLocaleString("en-US", { timeZone: "Europe/Berlin" });
}, "another named IANA zone is a RangeError");
assertThrows("RangeError", function () {
    d.toLocaleString("en-US", { timeZone: "Nowhere/Bad" });
}, "a nonsense zone is a RangeError");
assertThrows("RangeError", function () {
    d.toLocaleString("en-US", { timeZone: "+99" });
}, "an out-of-range offset is a RangeError");

// ---------------------------------------------------------------------------
// Invalid option values are RangeErrors
// ---------------------------------------------------------------------------

var badValues = [
    ["year", "banana"], ["year", "long"], ["month", "bad"], ["day", "long"],
    ["hour", "long"], ["minute", "narrow"], ["second", "short"],
    ["weekday", "numeric"], ["era", "numeric"], ["dateStyle", "giant"],
    ["timeStyle", "giant"], ["timeZoneName", "weird"], ["hourCycle", "h13"],
    ["localeMatcher", "nope"], ["formatMatcher", "nope"]
];
for (var i = 0; i < badValues.length; i++) {
    (function (key, val) {
        var o = {};
        o[key] = val;
        assertThrows("RangeError", function () { d.toLocaleString("en-US", o); },
            "option " + key + "=" + val + " is a RangeError");
    })(badValues[i][0], badValues[i][1]);
}
assertThrows("RangeError", function () {
    d.toLocaleString("en-US", { fractionalSecondDigits: 0 });
}, "fractionalSecondDigits 0 is out of range");
assertThrows("RangeError", function () {
    d.toLocaleString("en-US", { fractionalSecondDigits: 4 });
}, "fractionalSecondDigits 4 is out of range");

// A style together with an explicit component is a TypeError, not a RangeError.
assertThrows("TypeError", function () {
    d.toLocaleString("en-US", { dateStyle: "full", year: "numeric" });
}, "dateStyle with a component option is a TypeError");
assertThrows("TypeError", function () {
    d.toLocaleString("en-US", { timeStyle: "full", hour: "numeric" });
}, "timeStyle with a component option is a TypeError");
assertThrows("TypeError", function () {
    d.toLocaleDateString("en-US", { timeStyle: "full" });
}, "timeStyle on toLocaleDateString is a TypeError");
assertThrows("TypeError", function () {
    d.toLocaleTimeString("en-US", { dateStyle: "full" });
}, "dateStyle on toLocaleTimeString is a TypeError");

// ---------------------------------------------------------------------------
// locales validation, ECMA-402 9.2.1 / 6.2.1
// ---------------------------------------------------------------------------

var goodTags = ["en", "en-US", "EN-us", "und", "de-DE-u-co-phonebk", "zh-Hans-CN",
                "en-US-u-ca-gregory", "toString", "en-US-x-foo", "es-419",
                "sr-Latn-RS", "en-a-bbb-x-y", "en-US-u-nu-latn", "de-u-co",
                "th-TH-u-nu-thai", "en-US-POSIX", "qaa-Qaaa-QM-x-southern"];
for (var i = 0; i < goodTags.length; i++) {
    (function (tag) {
        __checks++;
        try {
            d.toLocaleString(tag);
        } catch (e) {
            console.log("FAIL: well-formed tag " + JSON.stringify(tag) +
                        " threw " + e.name);
            __failed = true;
        }
    })(goodTags[i]);
}

var badTags = ["x-private", "i", "1", "en-", "-en", "en--US", "en-US-", "en_US",
               "abcdefghi", "ab-CDE", "aaaaaaaaa", "en-GB-oed", "i-klingon",
               "zh-min-nan", "en-x-", "en-us-posix-posix", ""];
for (var i = 0; i < badTags.length; i++) {
    (function (tag) {
        assertThrows("RangeError", function () { d.toLocaleString(tag); },
            "malformed tag " + JSON.stringify(tag) + " is a RangeError");
    })(badTags[i]);
}

// An array of tags is validated element by element.
__checks++;
try {
    d.toLocaleString(["en-US", "de"]);
} catch (e) {
    console.log("FAIL: an array of well-formed tags threw " + e.name);
    __failed = true;
}
assertThrows("RangeError", function () { d.toLocaleString(["en-US", "!!"]); },
    "a malformed tag inside an array is a RangeError");
assertThrows("RangeError", function () { d.toLocaleString({length: 1, 0: "!!"}); },
    "locales is read as an array-like");

// Neither a String nor an Object is a TypeError, which is what stops NaN from
// being read as the tag "nan".
assertThrows("TypeError", function () { d.toLocaleString([null]); },
    "a null array element is a TypeError");
assertThrows("TypeError", function () { d.toLocaleString([5]); },
    "a numeric array element is a TypeError");
assertThrows("TypeError", function () { d.toLocaleString(null); },
    "null locales is a TypeError");

// A non-string primitive boxes into an object with no indices, so it is an
// empty list rather than an error.
__checks++;
try {
    d.toLocaleString(5);
} catch (e) {
    console.log("FAIL: numeric locales threw " + e.name);
    __failed = true;
}

// options coercion: null throws, a primitive boxes to an empty bag.
assertThrows("TypeError", function () { d.toLocaleString("en-US", null); },
    "null options is a TypeError");
assertEq(d.toLocaleString("en-US", 5), d.toLocaleString("en-US", {}),
    "a primitive options bag behaves as an empty one");

// ---------------------------------------------------------------------------
// The options bag is read in the order ECMA-402 11.1.2 lists
// ---------------------------------------------------------------------------

var seen = [];
var orderKeys = ["localeMatcher", "calendar", "numberingSystem", "hour12",
                 "hourCycle", "timeZone", "weekday", "era", "year", "month",
                 "day", "dayPeriod", "hour", "minute", "second",
                 "fractionalSecondDigits", "timeZoneName", "formatMatcher",
                 "dateStyle", "timeStyle"];
var probe = {};
for (var i = 0; i < orderKeys.length; i++) {
    (function (k) {
        Object.defineProperty(probe, k, {
            get: function () { seen.push(k); return undefined; },
            enumerable: true
        });
    })(orderKeys[i]);
}
d.toLocaleString("en-US", probe);
assertEq(seen.join(","), orderKeys.join(","),
    "the options bag is read in spec order");

// A getter that throws propagates out.
assertThrows("RangeError", function () {
    d.toLocaleString("en-US", { get year() { throw new RangeError("boom"); } });
}, "a throwing getter propagates");

// ---------------------------------------------------------------------------
// An invalid Date answers before the options bag is read
// ---------------------------------------------------------------------------

var bad = new Date(NaN);
assertEq(bad.toLocaleString(), "Invalid Date", "NaN date is Invalid Date");
assertEq(bad.toLocaleDateString("en-US", U({})), "Invalid Date",
    "NaN toLocaleDateString is Invalid Date");
assertEq(bad.toLocaleTimeString("en-US", U({})), "Invalid Date",
    "NaN toLocaleTimeString is Invalid Date");
assertEq(bad.toLocaleString("en-US", { year: "banana" }), "Invalid Date",
    "a NaN date short-circuits before a bad option value throws");
assertEq(bad.toLocaleString("!!"), "Invalid Date",
    "a NaN date short-circuits before a malformed tag throws");
var touched = false;
bad.toLocaleString("en-US", { get year() { touched = true; return "numeric"; } });
assert(!touched, "a NaN date never reads the options bag");

// ---------------------------------------------------------------------------
// Every result is an interned string usable for identity-based operations
// ---------------------------------------------------------------------------

var s1 = d.toLocaleDateString("en-US", U({dateStyle: "full"}));
var s2 = d.toLocaleDateString("en-US", U({dateStyle: "full"}));
assert(s1 === s2, "equal formats produce equal strings");
assert(s1.indexOf("January") === 8, "the result supports indexOf");
assertEq(s1.length, 24, "the result reports its length");

console.log("date toLocale options checks: " + __checks);
console.log(__failed ? "SOME TESTS FAILED" : "ALL DATE TOLOCALE OPTION TESTS PASSED");
