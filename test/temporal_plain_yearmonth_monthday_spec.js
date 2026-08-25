// Temporal.PlainYearMonth + Temporal.PlainMonthDay spec-locked tests. These
// exercise the constructor, from(), toString(), getters, add/subtract, with,
// until/since, equals, compare, and option handling. They are not exhaustive
// (test262 covers ~460 tests); they hit the common shapes so a refactor that
// breaks the public surface fails the local suite.
"use strict";

var pass = 0, fail = 0;
function assertEq(actual, expected, name) {
    if (actual === expected) {
        pass++;
    } else {
        fail++;
        console.log("FAIL " + name + ": got " + JSON.stringify(actual) + " want " + JSON.stringify(expected));
    }
}
function assertTrue(cond, name) { assertEq(!!cond, true, name); }
function assertFalse(cond, name) { assertEq(!!cond, false, name); }

// ============================================================================
// Temporal.PlainYearMonth
// ============================================================================

// Constructor: integer y/m; optional reference day (1 by default).
assertEq(new Temporal.PlainYearMonth(2024, 3).toString(), "2024-03", "PlainYearMonth(y,m)");
assertEq(new Temporal.PlainYearMonth(2024, 3, 15).toString(), "2024-03", "PlainYearMonth day dropped from toString");
assertEq(new Temporal.PlainYearMonth(2024, 2, 29).day, 29, "Feb 29 in leap year OK");

// Getters.
var ym = new Temporal.PlainYearMonth(2024, 3);
assertEq(ym.year, 2024, "ym.year");
assertEq(ym.month, 3, "ym.month");
assertEq(ym.monthCode, "M03", "ym.monthCode");
assertEq(ym.day, 1, "ym.day default");
assertEq(ym.daysInMonth, 31, "ym.daysInMonth March");
assertEq(ym.daysInYear, 366, "ym.daysInYear leap");
assertEq(ym.monthsInYear, 12, "ym.monthsInYear");
assertEq(ym.inLeapYear, true, "ym.inLeapYear");
assertEq(ym.calendarId, "iso8601", "ym.calendarId");
assertEq(ym.era, undefined, "ym.era undefined");
assertEq(ym.eraYear, undefined, "ym.eraYear undefined");

// from() with strings.
assertEq(Temporal.PlainYearMonth.from("2024-06").toString(), "2024-06", "from YYYY-MM");
assertEq(Temporal.PlainYearMonth.from("202406").toString(), "2024-06", "from basic YYYYMM");

// from() with object bag.
var ymBag = Temporal.PlainYearMonth.from({ year: 2025, month: 1 });
assertEq(ymBag.year, 2025, "from bag year");
assertEq(ymBag.month, 1, "from bag month");

// from() with monthCode.
var ymMc = Temporal.PlainYearMonth.from({ year: 2025, monthCode: "M07" });
assertEq(ymMc.month, 7, "from bag monthCode M07");
assertEq(ymMc.monthCode, "M07", "ymMc.monthCode M07");

// from() identity: a PlainYearMonth returns itself.
var ym1 = new Temporal.PlainYearMonth(2024, 6);
assertTrue(Temporal.PlainYearMonth.from(ym1) === ym1, "from identity");

// compare().
assertEq(Temporal.PlainYearMonth.compare(ym, ym), 0, "compare equal");
var ym2 = new Temporal.PlainYearMonth(2025, 1);
assertTrue(Temporal.PlainYearMonth.compare(ym, ym2) < 0, "compare less");
assertTrue(Temporal.PlainYearMonth.compare(ym2, ym) > 0, "compare greater");

// equals().
assertTrue(ym.equals(ym), "equals self");
assertTrue(ym.equals(Temporal.PlainYearMonth.from(ym.toString())), "equals round-trip");
assertFalse(ym.equals(ym2), "equals different");

// with().
assertEq(ym.with({ year: 2030 }).toString(), "2030-03", "with year");
assertEq(ym.with({ month: 12 }).toString(), "2024-12", "with month");
assertEq(ym.with({ year: 2030, month: 6 }).toString(), "2030-06", "with year+month");

// add() / subtract(): only date units (years, months) are sensible here.
assertEq(ym.add({ months: 1 }).toString(), "2024-04", "add 1 month");
assertEq(ym.add({ months: 11 }).toString(), "2025-02", "add 11 months rolls year");
assertEq(ym.add({ years: 1 }).toString(), "2025-03", "add 1 year");
assertEq(ym.subtract({ years: 1 }).toString(), "2023-03", "subtract 1 year");

// Reference-day clamping: PlainYearMonth.add rolls Feb 29 in leap year to
// Feb 28 in non-leap year (CONSTRAIN behavior, the default).
var ymFebLeap = new Temporal.PlainYearMonth(2024, 2, 29);
assertEq(ymFebLeap.day, 29, "Feb 29 ref day in leap year");
assertEq(ymFebLeap.add({ years: 1 }).day, 28, "Feb 29 ref day clamps in non-leap year");

// until() / since(): default largestUnit is "months".
var a = new Temporal.PlainYearMonth(2020, 1);
var b = new Temporal.PlainYearMonth(2024, 6);
var diff = a.until(b);
assertEq(diff.years, 0, "until default months, years=0");
assertEq(diff.months, 53, "until default months=53");

var diffYears = a.until(b, { largestUnit: "years" });
assertEq(diffYears.years, 4, "until years=4");
assertEq(diffYears.months, 5, "until years, months=5");

// since() flips the sign.
var diffBack = a.since(b);
assertEq(diffBack.months, -53, "since months=-53");

// valueOf throws.
var threw = false;
try { ym.valueOf(); } catch (e) { threw = (e && e.constructor.name === "TypeError"); }
assertTrue(threw, "PlainYearMonth.valueOf throws TypeError");

// toJSON.
assertEq(ym.toJSON(), "2024-03", "toJSON = toString");

// Brand check: must not accept unrelated `this`.
var threwBrand = false;
try { Temporal.PlainYearMonth.prototype.toString.call({}); } catch (e) { threwBrand = (e && e.constructor.name === "TypeError"); }
assertTrue(threwBrand, "PlainYearMonth.prototype.toString brand check");

// Date-only difference_date with non-zero day never trips the calendar
// arithmetic for these month-only inputs.

// Constructor with bad month throws.
var threwCtor = false;
try { new Temporal.PlainYearMonth(2024, 13); } catch (e) { threwCtor = (e && e.constructor.name === "RangeError"); }
assertTrue(threwCtor, "Constructor rejects month 13");

// Constructor with Feb 29 in non-leap year throws (REJECT semantics).
var threwFeb = false;
try { new Temporal.PlainYearMonth(2023, 2, 29); } catch (e) { threwFeb = (e && e.constructor.name === "RangeError"); }
assertTrue(threwFeb, "Constructor rejects Feb 29 in non-leap year");

// Reject option from() with overflow="reject".
var threwReject = false;
try { Temporal.PlainYearMonth.from({ year: 2023, month: 2, day: 29 }, { overflow: "reject" }); } catch (e) { threwReject = (e && e.constructor.name === "RangeError"); }
assertTrue(threwReject, "from with reject overflow throws");

// Negative years use the ISO 8601 extended-year leading sign.
assertEq(new Temporal.PlainYearMonth(-44, 3).toString(), "-000044-03", "negative year formatting");

// Calendar annotation option.
assertEq(ym.toString({ calendarName: "always" }), "2024-03[u-ca=iso8601]", "calendarName always");
assertEq(ym.toString({ calendarName: "critical" }), "2024-03[!u-ca=iso8601]", "calendarName critical");
assertEq(ym.toString({ calendarName: "never" }), "2024-03", "calendarName never");

// ============================================================================
// Temporal.PlainMonthDay
// ============================================================================

// Constructor.
assertEq(new Temporal.PlainMonthDay(3, 15).toString(), "1972-03-15", "PlainMonthDay ctor (reference year default)");
assertEq(new Temporal.PlainMonthDay(2, 29).day, 29, "Feb 29 allowed (ref year is leap)");

// Getters.
var md = new Temporal.PlainMonthDay(3, 15);
assertEq(md.month, 3, "md.month");
assertEq(md.day, 15, "md.day");
assertEq(md.monthCode, "M03", "md.monthCode");
assertEq(md.year, 1972, "md.year reference");
assertEq(md.calendarId, "iso8601", "md.calendarId");
assertEq(md.era, undefined, "md.era undefined");
assertEq(md.eraYear, undefined, "md.eraYear undefined");

var mdFeb29 = new Temporal.PlainMonthDay(2, 29);
assertEq(mdFeb29.daysInMonth, 29, "Feb 29 daysInMonth");
assertEq(mdFeb29.inLeapYear, true, "Feb 29 inLeapYear");

// from() with strings (ISO 8601 form `--MM-DD` or bare `MM-DD`).
assertEq(Temporal.PlainMonthDay.from("02-29").toString(), "1972-02-29", "from 02-29");
assertEq(Temporal.PlainMonthDay.from("--02-29").toString(), "1972-02-29", "from --02-29");
assertEq(Temporal.PlainMonthDay.from("07-04").toString(), "1972-07-04", "from 07-04");

// from() with object bag.
var mdBag = Temporal.PlainMonthDay.from({ month: 12, day: 25 });
assertEq(mdBag.month, 12, "from bag month");
assertEq(mdBag.day, 25, "from bag day");

// from() with monthCode.
var mdMc = Temporal.PlainMonthDay.from({ monthCode: "M08", day: 11 });
assertEq(mdMc.month, 8, "mdMc.month from monthCode M08");

// from() identity.
assertTrue(Temporal.PlainMonthDay.from(md) === md, "from identity");

// Apr 31 clamps to Apr 30 (CONSTRAIN).
var mdApr31 = Temporal.PlainMonthDay.from({ month: 4, day: 31 });
assertEq(mdApr31.day, 30, "Apr 31 clamps to 30");

// Apr 31 with reject throws.
var threwApr = false;
try { Temporal.PlainMonthDay.from({ month: 4, day: 31 }, { overflow: "reject" }); } catch (e) { threwApr = (e && e.constructor.name === "RangeError"); }
assertTrue(threwApr, "Apr 31 reject throws");

// compare() compares month first, then day.
assertEq(Temporal.PlainMonthDay.compare(md, md), 0, "compare equal");
var mdOther = new Temporal.PlainMonthDay(4, 1);
assertTrue(Temporal.PlainMonthDay.compare(md, mdOther) < 0, "compare March vs April");
assertTrue(Temporal.PlainMonthDay.compare(mdOther, md) > 0, "compare April vs March");

// equals(): reference year is ignored.
var mdSame = new Temporal.PlainMonthDay(3, 15);
assertTrue(md.equals(mdSame), "equals ignores reference year");
assertFalse(md.equals(mdOther), "equals different");

// with().
assertEq(md.with({ day: 1 }).toString(), "1972-03-01", "with day=1");
assertEq(md.with({ month: 6 }).toString(), "1972-06-15", "with month=6");
assertEq(md.with({ month: 6, day: 21 }).toString(), "1972-06-21", "with month+day");

// until() / since(): the smaller of the forward and backward arc.
var mdA = new Temporal.PlainMonthDay(12, 25);  // Dec 25
var mdB = new Temporal.PlainMonthDay(1, 1);    // Jan 1
var mdDiff = mdA.until(mdB);
assertEq(mdDiff.days, 7, "Dec 25 -> Jan 1 = 7 days (forward)");

var mdDiffBack = mdA.until(mdA.with({ month: 1 }));  // Dec 25 -> Jan 25
// Going forward (Dec 25 -> Jan 25 next year) = 31 days; going backward = 334.
// The spec picks the smaller absolute value: 31.
assertEq(mdDiffBack.days, 31, "Dec 25 -> Jan 25 = 31 days (smaller arc)");

// valueOf throws.
var threwMd = false;
try { md.valueOf(); } catch (e) { threwMd = (e && e.constructor.name === "TypeError"); }
assertTrue(threwMd, "PlainMonthDay.valueOf throws TypeError");

// toJSON.
assertEq(md.toJSON(), "1972-03-15", "PlainMonthDay toJSON");

// Brand check.
var threwMdBrand = false;
try { Temporal.PlainMonthDay.prototype.toString.call({}); } catch (e) { threwMdBrand = (e && e.constructor.name === "TypeError"); }
assertTrue(threwMdBrand, "PlainMonthDay.prototype.toString brand check");

// Calendar annotation option.
assertEq(md.toString({ calendarName: "always" }), "1972-03-15[u-ca=iso8601]", "md calendarName always");

// ============================================================================
// Namespaces and stubs
// ============================================================================

assertTrue(typeof Temporal.PlainYearMonth === "function", "Temporal.PlainYearMonth is a function");
assertTrue(typeof Temporal.PlainMonthDay === "function", "Temporal.PlainMonthDay is a function");
assertEq(typeof Temporal.Instant, "function", "Temporal.Instant is a function");
assertEq(typeof Temporal.Instant.prototype.toJSON, "function", "Temporal.Instant.prototype.toJSON");
assertEq(typeof Temporal.Instant.prototype.add, "function", "Temporal.Instant.prototype.add");
assertEq(typeof Temporal.TimeZone, "function", "Temporal.TimeZone is a function");
assertEq(typeof Temporal.TimeZone.prototype.getOffsetNanosecondsFor, "function", "getOffsetNanosecondsFor");
assertEq(typeof Temporal.ZonedDateTime, "function", "Temporal.ZonedDateTime is a function");
assertEq(typeof Temporal.Now, "undefined", "Temporal.Now still stub");

console.log("Pass: " + pass + " Fail: " + fail);
if (fail > 0) process.exit(1);
