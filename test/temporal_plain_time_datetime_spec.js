// Temporal.PlainTime + Temporal.PlainDateTime spec-locked tests. These cover
// the constructor, from(), toString(), getters, add/subtract, with, until/
// since, equals, compare, and option handling. They are not exhaustive
// (test262 covers ~1,240 tests); they exercise the most common shapes so a
// refactor that breaks the public surface fails the local suite.
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
function throwsRange(fn) {
    try { fn(); return false; } catch (e) { return e instanceof RangeError; }
}

// ============================================================================
// Temporal.PlainTime
// ============================================================================

// Constructor: integer fields only.
assertEq(new Temporal.PlainTime().toString(), "00:00:00", "PlainTime() = midnight");
assertEq(new Temporal.PlainTime(13).toString(), "13:00:00", "PlainTime(hour)");
assertEq(new Temporal.PlainTime(13, 45).toString(), "13:45:00", "PlainTime(hour, minute)");
assertEq(new Temporal.PlainTime(13, 45, 30).toString(), "13:45:30", "PlainTime(hour, minute, second)");
assertEq(new Temporal.PlainTime(13, 45, 30, 500).toString(), "13:45:30.5", "PlainTime ms");
assertEq(new Temporal.PlainTime(13, 45, 30, 500, 250).toString(), "13:45:30.50025", "PlainTime us");
assertEq(new Temporal.PlainTime(13, 45, 30, 500, 250, 750).toString(), "13:45:30.50025075", "PlainTime ns");

// Getters.
var t = new Temporal.PlainTime(13, 45, 30, 500, 250, 750);
assertEq(t.hour, 13, "get hour");
assertEq(t.minute, 45, "get minute");
assertEq(t.second, 30, "get second");
assertEq(t.millisecond, 500, "get ms");
assertEq(t.microsecond, 250, "get us");
assertEq(t.nanosecond, 750, "get ns");

// from() with strings.
assertEq(Temporal.PlainTime.from("13:45:30").toString(), "13:45:30", "from HH:MM:SS");
assertEq(Temporal.PlainTime.from("13:45:30.500250750").toString(), "13:45:30.50025075", "from with ns");
assertEq(Temporal.PlainTime.from("1330").toString(), "13:30:00", "from basic");
// Z designator is rejected by the grammar (DateTimeUTCOffset[~Z] forbids
// it). Numeric UTC offsets are silently dropped.
assertTrue(throwsRange(() => Temporal.PlainTime.from("14:30:00Z")), "from rejects Z");
assertEq(Temporal.PlainTime.from("14:30:00+05:00").toString(), "14:30:00", "from drops numeric offset");

// from() with object bag.
var tBag = Temporal.PlainTime.from({ hour: 9, minute: 30 });
assertEq(tBag.hour, 9, "from bag hour");
assertEq(tBag.minute, 30, "from bag minute");

// from() identity: a PlainTime returns itself.
var t1 = new Temporal.PlainTime(13, 45, 30);
assertFalse(Temporal.PlainTime.from(t1) === t1, "from identity: copies, does not return by reference");
assertTrue(Temporal.PlainTime.from(t1).equals(t1), "from identity: copy is equal by value");

// compare().
assertEq(Temporal.PlainTime.compare(t, t), 0, "compare equal");
var t2 = new Temporal.PlainTime(14, 0, 0);
assertTrue(Temporal.PlainTime.compare(t, t2) < 0, "compare less");
assertTrue(Temporal.PlainTime.compare(t2, t) > 0, "compare greater");

// equals().
assertTrue(t.equals(t), "equals self");
assertTrue(t.equals(Temporal.PlainTime.from(t.toString())), "equals round-trip");
assertFalse(t.equals(t2), "equals different");

// with().
assertEq(t.with({ hour: 10 }).toString(), "10:45:30.50025075", "with hour");
assertEq(t.with({ minute: 0 }).toString(), "13:00:30.50025075", "with minute");
assertEq(t.with({ hour: 10, minute: 0 }).toString(), "10:00:30.50025075", "with both");

// add() / subtract().
assertEq(t.add({ hours: 1 }).toString(), "14:45:30.50025075", "add 1h");
assertEq(t.add({ hours: 1, minutes: 30 }).toString(), "15:15:30.50025075", "add 1h30m");
assertEq(t.subtract({ hours: 1 }).toString(), "12:45:30.50025075", "subtract 1h");

// until() / since(): default largestUnit is "hours".
var tA = new Temporal.PlainTime(13, 0, 0);
var tB = new Temporal.PlainTime(15, 30, 0);
var diff = tA.until(tB);
assertEq(diff.hours, 2, "until default hours");
assertEq(diff.minutes, 30, "until default minutes");

var diffBack = tA.since(tB);
assertEq(diffBack.hours, -2, "since default hours");
assertEq(diffBack.minutes, -30, "since default minutes");

// until() with largestUnit option.
var diffS = tA.until(tB, { largestUnit: "seconds" });
assertEq(diffS.hours, 0, "until seconds drops hours");
assertEq(diffS.seconds, 9000, "until seconds=9000");

// valueOf throws.
var threw = false;
try { t.valueOf(); } catch (e) { threw = (e && e.constructor.name === "TypeError"); }
assertTrue(threw, "valueOf throws TypeError");

// toJSON.
assertEq(t.toJSON(), "13:45:30.50025075", "toJSON = toString");

// Invalid constructor arguments.
var bad = false;
try { new Temporal.PlainTime(24); } catch (e) { bad = (e && e.constructor.name === "RangeError"); }
assertTrue(bad, "24:00:00 throws RangeError");

bad = false;
try { new Temporal.PlainTime(13, 60); } catch (e) { bad = (e && e.constructor.name === "RangeError"); }
assertTrue(bad, "minute=60 throws RangeError");

// ============================================================================
// Temporal.PlainDateTime
// ============================================================================

var dt = new Temporal.PlainDateTime(2024, 1, 15, 13, 45, 30);
assertEq(dt.year, 2024, "dt year");
assertEq(dt.month, 1, "dt month");
assertEq(dt.day, 15, "dt day");
assertEq(dt.hour, 13, "dt hour");
assertEq(dt.minute, 45, "dt minute");
assertEq(dt.second, 30, "dt second");
assertEq(dt.toString(), "2024-01-15T13:45:30", "dt toString");

var dt2 = Temporal.PlainDateTime.from("2024-03-20T08:00:00");
assertEq(dt2.toString(), "2024-03-20T08:00:00", "dt from string");

var dt3 = Temporal.PlainDateTime.from({ year: 2025, month: 6, day: 1, hour: 12 });
assertEq(dt3.toString(), "2025-06-01T12:00:00", "dt from object");

var dt4 = new Temporal.PlainDateTime(2024, 1, 15, 13, 45, 30, 500, 250, 750);
assertEq(dt4.toString(), "2024-01-15T13:45:30.50025075", "dt with sub-seconds");

// with(): fields carry over.
var dt5 = dt4.with({ year: 2025 });
assertEq(dt5.year, 2025, "dt with year");
assertEq(dt5.month, 1, "dt with month carried");
assertEq(dt5.nanosecond, 750, "dt with ns carried");

// add() / subtract().
var dt6 = dt.add({ months: 1, days: 1 });
assertEq(dt6.month, 2, "dt add month");
assertEq(dt6.day, 16, "dt add day");

var dt7 = dt.subtract({ months: 1 });
assertEq(dt7.month, 12, "dt subtract month wraps");
assertEq(dt7.year, 2023, "dt subtract year wraps");

// until() / since(): default largestUnit is "days".
var diffDt = dt.until(dt6);
assertEq(diffDt.days, 32, "dt until default days");

var diffDtM = dt.until(dt6, { largestUnit: "months" });
assertEq(diffDtM.months, 1, "dt until months");
assertEq(diffDtM.days, 1, "dt until days leftover");

// equals.
assertTrue(dt.equals(Temporal.PlainDateTime.from(dt.toString())), "dt equals round-trip");
assertFalse(dt.equals(dt2), "dt equals different");

// compare.
assertEq(Temporal.PlainDateTime.compare(dt, dt), 0, "dt compare equal");
assertTrue(Temporal.PlainDateTime.compare(dt, dt2) < 0, "dt compare less");

// calendar. Temporal.Calendar was removed from the proposal, so the calendar is
// observed as a string id rather than as an object.
assertEq(dt.calendarId, "iso8601", "dt.calendarId");
assertEq(dt.withCalendar("iso8601").calendarId, "iso8601", "dt withCalendar");

// valueOf throws.
threw = false;
try { dt.valueOf(); } catch (e) { threw = (e && e.constructor.name === "TypeError"); }
assertTrue(threw, "dt valueOf throws");

// Extended year formatting.
var dtExt = new Temporal.PlainDateTime(10000, 1, 1);
assertEq(dtExt.toString(), "+010000-01-01T00:00:00", "dt extended year positive");

var dtExt2 = new Temporal.PlainDateTime(-10000, 1, 1);
assertEq(dtExt2.toString(), "-010000-01-01T00:00:00", "dt extended year negative");

// calendarName option.
assertEq(dt.toString({ calendarName: "always" }), "2024-01-15T13:45:30[u-ca=iso8601]", "dt calendarName always");

console.log("Pass: " + pass + " Fail: " + fail);
if (fail > 0) process.exit(1);
