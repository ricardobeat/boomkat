// Date tests for Duktape C3

var __failed = false;

function assert(cond, msg) {
    if (!cond) { console.log("FAIL: " + msg); __failed = true; }
}

// Test 1: Date() as function returns string
var ds = Date();
assert(typeof ds === 'string', "Date() as function returns string");

// Test 2: new Date() creates Date object
var d = new Date();
assert(typeof d === 'object', "new Date() creates object");
assert(d instanceof Date, "new Date() instanceof Date");

// Test 3: Date.now() returns number
var now = Date.now();
assert(typeof now === 'number', "Date.now() returns number");

// Test 4: new Date(value) with timestamp
var d2 = new Date(0);
assert(d2 instanceof Date, "new Date(0) creates Date");

// Test 5: Date.prototype.getTime()
var d3 = new Date(1640995200000);
assert(d3.getTime() === 1640995200000, "getTime() returns correct timestamp");

// Test 6: Date.prototype.valueOf() returns timestamp
assert(d3.valueOf() === 1640995200000, "valueOf() returns correct timestamp");

// Test 7: Date.prototype.toString() returns string
var ts = d3.toString();
assert(typeof ts === 'string', "toString() returns string");

// Test 8: Date.prototype.toJSON() returns string
var j = d3.toJSON();
assert(typeof j === 'string', "toJSON() returns string");

// Test 9: Date constructor with year/month
var d4 = new Date(2022, 0, 1);
assert(d4 instanceof Date, "new Date(2022,0,1) creates Date");
assert(d4.getFullYear() === 2022, "getFullYear() returns 2022");
assert(d4.getMonth() === 0, "getMonth() returns 0 (January)");
assert(d4.getDate() === 1, "getDate() returns 1");

// Test 10: Date.UTC()
var utc = Date.UTC(2022, 0, 1);
assert(typeof utc === 'number', "Date.UTC() returns number");
assert(utc > 0, "Date.UTC(2022,0,1) is positive");

// Test 11: getDay() returns 0-6
var day = d4.getDay();
assert(day >= 0 && day <= 6, "getDay() returns 0-6");

// Test 12: getHours/minutes/seconds work
var d5 = new Date(2022, 5, 15, 10, 30, 45);
assert(d5.getHours() === 10, "getHours() returns 10");
assert(d5.getMinutes() === 30, "getMinutes() returns 30");
assert(d5.getSeconds() === 45, "getSeconds() returns 45");

// Test 13: getMilliseconds()
var d6 = new Date(2022, 5, 15, 10, 30, 45, 500);
assert(d6.getMilliseconds() === 500, "getMilliseconds() returns 500");

// Test 14: Date.parse returns number (NaN for invalid)
var p = Date.parse("not a date");
assert(typeof p === 'number', "Date.parse() returns number");

// Test 15: Constructor with multiple args
var d8 = new Date(2023, 11, 25, 8, 15, 30, 100);
assert(d8.getFullYear() === 2023, "Multi-arg: year 2023");
assert(d8.getMonth() === 11, "Multi-arg: month 11 (Dec)");
assert(d8.getDate() === 25, "Multi-arg: day 25");
assert(d8.getHours() === 8, "Multi-arg: hours 8");
assert(d8.getMinutes() === 15, "Multi-arg: minutes 15");
assert(d8.getSeconds() === 30, "Multi-arg: seconds 30");
assert(d8.getMilliseconds() === 100, "Multi-arg: ms 100");

// Test 16: getTime on epoch date
var d9 = new Date(0);
assert(d9.getTime() === 0, "Epoch date getTime() returns 0");

// Test 17: Year < 100 constructor
var d10 = new Date(99, 0, 1);
assert(d10.getFullYear() === 1999, "Year 99 becomes 1999");

// Test 18: toJSON returns ISO-like string
var d11 = new Date(1640995200000);
var j2 = d11.toJSON();
assert(typeof j2 === 'string', "toJSON returns string");

// Test 19: Date.now() is monotonic
var n1 = Date.now();
var n2 = Date.now();
assert(n2 >= n1, "Date.now() is monotonic");

// Test 20: toString is local time, so it must not be asserted against a
// fixed year — west of UTC the epoch falls on 1969-12-31. Assert the parts
// that are timezone-independent instead: the GMT offset that toString always
// carries (§21.4.4.41 TimeZoneString), and the UTC accessors.
var d12 = new Date(0);
var ts2 = d12.toString();
assert(ts2.indexOf('GMT') >= 0, "toString contains GMT offset");
assert(d12.toUTCString() === "Thu, 01 Jan 1970 00:00:00 GMT",
       "toUTCString of epoch is exact");
assert(d12.getUTCFullYear() === 1970 && d12.getUTCMonth() === 0
       && d12.getUTCDate() === 1, "epoch is 1970-01-01 in UTC");
// The local-time year is either 1969 or 1970 depending on the offset sign.
var ly = d12.getFullYear();
assert(ly === 1969 || ly === 1970, "local year of epoch is 1969 or 1970");
assert(ts2.indexOf(String(ly)) >= 0, "toString year agrees with getFullYear");

console.log(__failed ? "SOME TESTS FAILED" : "ALL DATE TESTS PASSED");
