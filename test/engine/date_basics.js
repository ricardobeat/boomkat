// Date basics
// Tests Date construction, getters, arithmetic, Date.now.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Construct from values (year, monthIndex, day)
// Month is 0-indexed: January=0
var d1 = new Date(2024, 0, 15); // Jan 15, 2024
assert(d1.getFullYear() === 2024, "getFullYear 2024");
assert(d1.getMonth() === 0, "getMonth January=0");
assert(d1.getDate() === 15, "getDate 15");
assert(d1.getDay() >= 0 && d1.getDay() <= 6, "getDay in range");

// Construct from timestamp
var d2 = new Date(0); // Unix epoch
assert(d2.getUTCFullYear() === 1970, "epoch year");
assert(d2.getUTCMonth() === 0, "epoch month");
assert(d2.getUTCDate() === 1, "epoch day");

// Date.now() returns a large number
var now = Date.now();
assert(typeof now === "number", "Date.now is number");
assert(now > 1000000000000, "Date.now > 1 trillion (ms since 1970)");
assert(now < 10000000000000, "Date.now < 10 trillion");

// Construct from date string
var d3 = new Date("2025-06-15T12:00:00Z");
assert(d3.getUTCFullYear() === 2025, "string year");
assert(d3.getUTCMonth() === 5, "string month June=5");
assert(d3.getUTCDate() === 15, "string day");

// Date arithmetic via timestamps
var dayMs = 24 * 60 * 60 * 1000;
var tomorrow = new Date(d1.getTime() + dayMs);
assert(tomorrow.getDate() === 16, "tomorrow is 16");

// Setters
var d4 = new Date(2024, 0, 1);
d4.setFullYear(2025);
d4.setMonth(11); // December
d4.setDate(25);
assert(d4.getFullYear() === 2025, "setFullYear");
assert(d4.getMonth() === 11, "setMonth");
assert(d4.getDate() === 25, "setDate");

// Month rollover: day 32 of January -> Feb 1
var d5 = new Date(2024, 0, 32);
assert(d5.getMonth() === 1, "Jan 32 -> Feb");
assert(d5.getDate() === 1, "Jan 32 -> Feb 1");

// toISOString
var d6 = new Date(Date.UTC(2024, 5, 15, 14, 30, 0));
assert(d6.toISOString() === "2024-06-15T14:30:00.000Z", "toISOString");

// getTime / setTime
var d7 = new Date(2024, 0, 1);
var ts = d7.getTime();
assert(typeof ts === "number", "getTime is number");
var d8 = new Date();
d8.setTime(ts);
assert(d8.getTime() === ts, "setTime roundtrip");

// Seconds and milliseconds
var d9 = new Date(2024, 0, 1, 12, 30, 45, 500);
assert(d9.getHours() === 12, "hours");
assert(d9.getMinutes() === 30, "minutes");
assert(d9.getSeconds() === 45, "seconds");
assert(d9.getMilliseconds() === 500, "milliseconds");

print("engine/date_basics: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
