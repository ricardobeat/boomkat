// Temporal.Now — namespace object, method presence, property descriptors,
// return types, and error paths for all six methods.
"use strict";

var pass = 0, fail = 0;
function assertEq(actual, expected, name) {
    if (actual === expected) { pass++; return; }
    fail++;
    console.log("FAIL " + name + ": expected " + JSON.stringify(expected) + " got " + JSON.stringify(actual));
}
function assertTrue(cond, name) { assertEq(!!cond, true, name); }
function assertFalse(cond, name) { assertEq(!!cond, false, name); }

// ==========================================================================
// Temporal.Now — namespace object
// ==========================================================================

assertTrue(typeof Temporal.Now === "object", "Now is an object");
assertFalse(Temporal.Now === null, "Now is not null");

// Well-known Symbol.toStringTag
assertEq(Temporal.Now[Symbol.toStringTag], "Temporal.Now", "toStringTag");

// ==========================================================================
// Method presence and property descriptors
// ==========================================================================

var methods = ["instant", "timeZoneId", "plainDateISO", "plainDateTimeISO",
               "plainTimeISO", "zonedDateTimeISO"];

for (var i = 0; i < methods.length; i++) {
    var m = methods[i];
    assertTrue(typeof Temporal.Now[m] === "function", m + " is a function");
    var desc = Object.getOwnPropertyDescriptor(Temporal.Now, m);
    assertTrue(desc.writable, m + " writable");
    assertFalse(desc.enumerable, m + " not enumerable");
    assertTrue(desc.configurable, m + " configurable");
    assertEq(typeof desc.value, "function", m + " value is function");
}

// Now itself is not enumerable on Temporal (per spec §17).
var nowDesc = Object.getOwnPropertyDescriptor(Temporal, "Now");
assertTrue(nowDesc != null, "Temporal.Now descriptor exists");
assertFalse(nowDesc.enumerable, "Temporal.Now not enumerable");

// ==========================================================================
// Temporal.Now.instant()
// ==========================================================================

var inst = Temporal.Now.instant();
assertTrue(inst instanceof Temporal.Instant, "instant() returns Instant");
assertTrue(typeof inst.toString() === "string", "instant toString is string");
assertTrue(inst.toString().length > 0, "instant toString non-empty");

// ==========================================================================
// Temporal.Now.timeZoneId()
// ==========================================================================

var tzId = Temporal.Now.timeZoneId();
assertTrue(typeof tzId === "string", "timeZoneId returns string");
assertTrue(tzId.length > 0, "timeZoneId non-empty");

// ==========================================================================
// Temporal.Now.plainDateISO()
// ==========================================================================

var pd = Temporal.Now.plainDateISO();
assertTrue(pd instanceof Temporal.PlainDate, "plainDateISO() returns PlainDate");
assertTrue(typeof pd.toString() === "string", "plainDateISO toString");

// With explicit IANA zone.
var pdUtc = Temporal.Now.plainDateISO("UTC");
assertTrue(pdUtc instanceof Temporal.PlainDate, "plainDateISO('UTC') returns PlainDate");

// ==========================================================================
// Temporal.Now.plainDateTimeISO()
// ==========================================================================

var pdt = Temporal.Now.plainDateTimeISO();
assertTrue(pdt instanceof Temporal.PlainDateTime, "plainDateTimeISO() returns PlainDateTime");
assertTrue(typeof pdt.toString() === "string", "plainDateTimeISO toString");

var pdtUtc = Temporal.Now.plainDateTimeISO("UTC");
assertTrue(pdtUtc instanceof Temporal.PlainDateTime, "plainDateTimeISO('UTC') returns PlainDateTime");

// ==========================================================================
// Temporal.Now.plainTimeISO()
// ==========================================================================

var pt = Temporal.Now.plainTimeISO();
assertTrue(pt instanceof Temporal.PlainTime, "plainTimeISO() returns PlainTime");
assertTrue(typeof pt.toString() === "string", "plainTimeISO toString");

var ptUtc = Temporal.Now.plainTimeISO("UTC");
assertTrue(ptUtc instanceof Temporal.PlainTime, "plainTimeISO('UTC') returns PlainTime");

// ==========================================================================
// Temporal.Now.zonedDateTimeISO()
// ==========================================================================

var zdt = Temporal.Now.zonedDateTimeISO();
assertTrue(zdt instanceof Temporal.ZonedDateTime, "zonedDateTimeISO() returns ZonedDateTime");
assertTrue(typeof zdt.toString() === "string", "zonedDateTimeISO toString");

var zdtUtc = Temporal.Now.zonedDateTimeISO("UTC");
assertTrue(zdtUtc instanceof Temporal.ZonedDateTime, "zonedDateTimeISO('UTC') returns ZonedDateTime");
assertEq(zdtUtc.timeZoneId, "UTC", "zonedDateTimeISO('UTC') timeZoneId is UTC");

// ZonedDateTime with offset zone.
var zdtOff = Temporal.Now.zonedDateTimeISO("+05:30");
assertTrue(zdtOff instanceof Temporal.ZonedDateTime, "zonedDateTimeISO('+05:30') returns ZonedDateTime");
assertEq(zdtOff.timeZoneId, "+05:30", "zonedDateTimeISO('+05:30') timeZoneId");

// ZonedDateTime with ISO string containing bracket zone.
var zdtBracket = Temporal.Now.zonedDateTimeISO("2024-01-01T00:00Z[UTC]");
assertTrue(zdtBracket instanceof Temporal.ZonedDateTime, "zonedDateTimeISO bracket returns ZonedDateTime");
assertEq(zdtBracket.timeZoneId, "UTC", "zonedDateTimeISO bracket timeZoneId");

// ==========================================================================
// Error paths — wrong types
// ==========================================================================

function assertThrows(ctor, fn, name) {
    var threw = false;
    try { fn(); } catch (e) { threw = e instanceof ctor; }
    assertTrue(threw, name);
}

// null, boolean, number, BigInt → TypeError
assertThrows(TypeError, function() { Temporal.Now.plainDateISO(null); }, "null → TypeError");
assertThrows(TypeError, function() { Temporal.Now.plainDateISO(true); }, "true → TypeError");
assertThrows(TypeError, function() { Temporal.Now.plainDateISO(1); }, "1 → TypeError");
assertThrows(TypeError, function() { Temporal.Now.plainDateISO(1n); }, "1n → TypeError");
assertThrows(TypeError, function() { Temporal.Now.plainDateISO({}); }, "{} → TypeError");
assertThrows(TypeError, function() { Temporal.Now.plainDateISO(Symbol()); }, "Symbol → TypeError");

// Empty string → RangeError
assertThrows(RangeError, function() { Temporal.Now.plainDateISO(""); }, "empty string → RangeError");
assertThrows(RangeError, function() { Temporal.Now.plainDateTimeISO(""); }, "empty string pdt → RangeError");
assertThrows(RangeError, function() { Temporal.Now.plainTimeISO(""); }, "empty string pt → RangeError");
assertThrows(RangeError, function() { Temporal.Now.zonedDateTimeISO(""); }, "empty string zdt → RangeError");

// Invalid zone name → RangeError
assertThrows(RangeError, function() { Temporal.Now.plainDateISO("Not/A/Zone"); }, "bogus zone → RangeError");

// Sub-minute offset → RangeError
assertThrows(RangeError, function() { Temporal.Now.zonedDateTimeISO("+01:30:45"); }, "sub-minute offset → RangeError");

// ==========================================================================
console.log("Pass: " + pass + " Fail: " + fail);
if (fail > 0) process.exit(1);
