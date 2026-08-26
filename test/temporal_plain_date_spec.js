// Spec coverage for Temporal.PlainDate and Temporal.Calendar.

function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        throw new Error(msg + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected));
    }
}
function assertThrows(fn, kind, msg) {
    let threw = false;
    try { fn(); } catch (e) { threw = true; if (kind && e.name !== kind && !(e instanceof kind)) throw new Error(msg + ": wrong error kind " + e); }
    if (!threw) throw new Error(msg + ": did not throw");
}

// Constructor
assertEq(new Temporal.PlainDate(2024, 7, 15).day, 15, "ctor");
assertThrows(() => new Temporal.PlainDate(2024), RangeError, "ctor requires month and day");
assertThrows(() => new Temporal.PlainDate(2024, 1), RangeError, "ctor requires day");
assertThrows(() => new Temporal.PlainDate(2023, 2, 29), RangeError, "Feb 29 not leap");
assertThrows(() => new Temporal.PlainDate(2024, 13, 1), RangeError, "month 13");
assertThrows(() => new Temporal.PlainDate(2024, 4, 31), RangeError, "Apr 31");

// Year 0 valid in proleptic Gregorian (1 BCE)
assertEq(new Temporal.PlainDate(0, 1, 1).year, 0, "year 0");
assertEq(new Temporal.PlainDate(0, 1, 1).toString(), "0000-01-01", "year 0 toString");

// Getters
const d = new Temporal.PlainDate(2024, 7, 15);
assertEq(d.year, 2024, "year");
assertEq(d.month, 7, "month");
assertEq(d.day, 15, "day");
assertEq(d.dayOfWeek, 1, "dow Mon=1");
assertEq(d.dayOfYear, 197, "doy");
assertEq(d.monthCode, "M07", "mc");
assertEq(d.inLeapYear, true, "leap");
assertEq(d.calendar.id, "iso8601", "cal");
assertEq(typeof d.era, "undefined", "era undef ISO");
assertEq(d.toString(), "2024-07-15", "toString");
assertEq(d.toJSON(), "2024-07-15", "toJSON");

// Extended years
assertEq(new Temporal.PlainDate(10000, 1, 1).toString(), "+010000-01-01", "year 10000");
assertEq(new Temporal.PlainDate(9999, 12, 31).toString(), "9999-12-31", "year 9999");
assertEq(new Temporal.PlainDate(-1, 1, 1).toString(), "-000001-01-01", "year -1");

// Day-of-week checks
assertEq(new Temporal.PlainDate(1970, 1, 1).dayOfWeek, 4, "epoch Thu");
assertEq(new Temporal.PlainDate(2000, 1, 1).dayOfWeek, 6, "2000-01-01 Sat");
assertEq(new Temporal.PlainDate(2024, 12, 25).dayOfWeek, 3, "Xmas 2024 Wed");
assertEq(new Temporal.PlainDate(2024, 3, 1).dayOfWeek, 5, "Mar 1 2024 Fri");
assertEq(new Temporal.PlainDate(2024, 2, 29).dayOfWeek, 4, "Feb 29 2024 Thu");

// Day-of-year
assertEq(new Temporal.PlainDate(2024, 1, 1).dayOfYear, 1, "Jan 1 doy");
assertEq(new Temporal.PlainDate(2024, 12, 31).dayOfYear, 366, "Dec 31 leap");
assertEq(new Temporal.PlainDate(2023, 12, 31).dayOfYear, 365, "Dec 31 non-leap");
assertEq(new Temporal.PlainDate(2024, 2, 29).dayOfYear, 60, "Feb 29 leap");

// In leap year
assertEq(new Temporal.PlainDate(2000, 1, 1).inLeapYear, true, "2000 leap (400-yr)");
assertEq(new Temporal.PlainDate(1900, 1, 1).inLeapYear, false, "1900 not leap (100-yr)");

// Month codes
assertEq(new Temporal.PlainDate(2024, 1, 1).monthCode, "M01", "M01");
assertEq(new Temporal.PlainDate(2024, 12, 1).monthCode, "M12", "M12");

// from()
assertEq(Temporal.PlainDate.from("2024-08-20").day, 20, "from string");
assertEq(Temporal.PlainDate.from("+010000-01-01").year, 10000, "from extended");
assertEq(Temporal.PlainDate.from("2024-08-20").toString(), "2024-08-20", "from string round-trip");

const obj = { year: 2025, month: 3, day: 14 };
const fromObj = Temporal.PlainDate.from(obj);
assertEq(fromObj.year, 2025, "from obj year");
assertEq(fromObj.month, 3, "from obj month");
assertEq(fromObj.day, 14, "from obj day");

const fromPD = Temporal.PlainDate.from(new Temporal.PlainDate(2024, 12, 31));
assertEq(fromPD.year, 2024, "from PD year");
assertEq(fromPD.month, 12, "from PD month");
assertEq(fromPD.day, 31, "from PD day");

assertThrows(() => Temporal.PlainDate.from("not a date"), RangeError, "from invalid string");
assertThrows(() => Temporal.PlainDate.from(null), TypeError, "from null");

// compare()
assertEq(Temporal.PlainDate.compare(new Temporal.PlainDate(2024, 1, 1), new Temporal.PlainDate(2024, 1, 1)), 0, "compare eq");
assertEq(Temporal.PlainDate.compare(new Temporal.PlainDate(2023, 12, 31), new Temporal.PlainDate(2024, 1, 1)), -1, "compare less");
assertEq(Temporal.PlainDate.compare(new Temporal.PlainDate(2024, 1, 2), new Temporal.PlainDate(2024, 1, 1)), 1, "compare more");

// equals()
assertEq(new Temporal.PlainDate(2024, 1, 1).equals(new Temporal.PlainDate(2024, 1, 1)), true, "equals same");
assertEq(new Temporal.PlainDate(2024, 1, 1).equals(new Temporal.PlainDate(2024, 1, 2)), false, "equals diff");
// equals() runs ToTemporalDate on its argument, so a matching property bag is
// equal and an unconvertible value throws rather than comparing unequal.
assertEq(new Temporal.PlainDate(2024, 1, 1).equals({ year: 2024, month: 1, day: 1 }), true, "equals matching bag");
assertEq(new Temporal.PlainDate(2024, 1, 1).equals({ year: 2024, month: 1, day: 2 }), false, "equals non-matching bag");
assertEq(new Temporal.PlainDate(2024, 1, 1).equals("2024-01-01"), true, "equals matching string");
assertThrows(() => new Temporal.PlainDate(2024, 1, 1).equals(1), TypeError, "equals number throws");
assertThrows(() => new Temporal.PlainDate(2024, 1, 1).equals(), TypeError, "equals no argument throws");

// with()
const w1 = new Temporal.PlainDate(2024, 7, 15).with({ day: 1 });
assertEq(w1.day, 1, "with day");
assertEq(w1.month, 7, "with day month");

const w2 = new Temporal.PlainDate(2024, 7, 15).with({ month: 12 });
assertEq(w2.month, 12, "with month");
assertEq(w2.day, 15, "with month day");

const w3 = new Temporal.PlainDate(2024, 7, 15).with({ year: 2025, month: 1, day: 1 });
assertEq(w3.year, 2025, "with all year");
assertEq(w3.month, 1, "with all month");
assertEq(w3.day, 1, "with all day");

const w4 = new Temporal.PlainDate(2024, 1, 30).with({ month: 2 });
assertEq(w4.month, 2, "with constrain month");
assertEq(w4.day, 29, "with constrain Feb 29");

// add() / subtract()
const a1 = new Temporal.PlainDate(2024, 7, 15).add({ days: 10 });
assertEq(a1.day, 25, "add days");
const a2 = new Temporal.PlainDate(2024, 7, 15).add({ months: 3 });
assertEq(a2.month, 10, "add months");
const a3 = new Temporal.PlainDate(2024, 7, 15).add({ years: 1 });
assertEq(a3.year, 2025, "add years");
const a4 = new Temporal.PlainDate(2024, 7, 15).add({ years: 1, months: 2, weeks: 1, days: 3 });
assertEq(a4.year, 2025, "add mixed year");
assertEq(a4.month, 9, "add mixed month");
assertEq(a4.day, 25, "add mixed day");

const a5 = new Temporal.PlainDate(2024, 7, 15).subtract({ days: 5 });
assertEq(a5.day, 10, "sub days");

// Cross-month-day overflow REJECT
const a6 = new Temporal.PlainDate(2024, 1, 31).add({ months: 1 });
assertEq(a6.month, 2, "add Jan31+1mo constrain month");
assertEq(a6.day, 29, "add Jan31+1mo constrain day");

// until / since
const u1 = new Temporal.PlainDate(2024, 7, 15).until(new Temporal.PlainDate(2024, 7, 25));
assertEq(u1.days, 10, "until days");
const u2 = new Temporal.PlainDate(2024, 7, 25).until(new Temporal.PlainDate(2024, 7, 15));
assertEq(u2.days, -10, "until neg");
const s1 = new Temporal.PlainDate(2024, 7, 15).since(new Temporal.PlainDate(2024, 7, 25));
assertEq(s1.days, -10, "since neg");
const s2 = new Temporal.PlainDate(2024, 7, 25).since(new Temporal.PlainDate(2024, 7, 15));
assertEq(s2.days, 10, "since pos");

// Calendar.surface
assertEq(Temporal.Calendar.from("iso8601").id, "iso8601", "cal from");
assertEq(Temporal.Calendar.from("gregory").id, "iso8601", "gregory alias");
assertEq(Temporal.Calendar.from("gregorian").id, "iso8601", "gregorian alias");
assertThrows(() => Temporal.Calendar.from("hebrew"), RangeError, "cal unknown");

const cal = Temporal.Calendar.from("iso8601");
assertEq(typeof cal.toString(), "string", "cal toString returns string");

print("OK");
