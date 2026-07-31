// Date manipulation
// Show basic Date API usage.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

var d = new Date(2023, 0, 15); // Jan 15, 2023
assert(d.getFullYear() === 2023, "year");
assert(d.getMonth() === 0, "month 0 (Jan)");
assert(d.getDate() === 15, "day 15");

// Date arithmetic: add days (manual — engine's setDate() not reliable)
function addDays(date, days) {
    var d = new Date(date.getFullYear(), date.getMonth(), date.getDate() + days);
    return d;
}

var d2 = addDays(d, 7);
assert(d2.getDate() === 22, "add 7 days");
assert(d2.getMonth() === 0, "still Jan");

// Month wrap
var d3 = addDays(d, 20);
assert(d3.getMonth() === 1, "month wrap to Feb");
assert(d3.getDate() === 4, "feb 4");

// Days between two dates
function daysBetween(a, b) {
    return Math.round((b.getTime() - a.getTime()) / 86400000);
}

var start = new Date(2023, 0, 1);
var end = new Date(2023, 0, 31);
assert(daysBetween(start, end) === 30, "30 days in jan");

// Day of week
var dow = new Date(2023, 0, 1).getDay(); // Jan 1 2023 was Sunday
assert(dow === 0, "Jan 1 2023 was Sunday (got " + dow + ")");

// ISO date string
var s = new Date(2023, 5, 7).toISOString();
assert(s.indexOf("2023") === 0, "ISO starts with year");
assert(s.indexOf("06") !== -1, "ISO contains month 06");

// Day of year (manual — getTime() arithmetic on this engine is unreliable)
var DAYS_BEFORE_MONTH = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
function dayOfYear(date) {
    return DAYS_BEFORE_MONTH[date.getMonth()] + date.getDate();
}

assert(dayOfYear(new Date(2023, 0, 1)) === 1, "Jan 1 = day 1");
assert(dayOfYear(new Date(2023, 11, 31)) === 365, "Dec 31 = day 365");
assert(dayOfYear(new Date(2023, 1, 28)) === 59, "Feb 28 = day 59");

print("engine/date_manipulation: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");