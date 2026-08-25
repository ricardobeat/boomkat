// Temporal.Instant + Temporal.TimeZone + Temporal.ZonedDateTime spec-locked
// tests. These exercise the constructors, from(), toString(), epoch getters,
// add/subtract/equals, time zone lookup, and zone/calendar id access. They are
// not exhaustive (test262 covers ~1600 tests); they hit the common shapes so a
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

// ============================================================================
// Temporal.Instant
// ============================================================================

assertEq(typeof Temporal.Instant, "function", "Instant is a function");

var epoch = new Temporal.Instant(0n);
assertEq(epoch.epochSeconds, 0, "epoch.epochSeconds");
assertEq(epoch.epochMilliseconds, 0, "epoch.epochMilliseconds");
assertEq(epoch.epochMicroseconds, 0, "epoch.epochMicroseconds");
assertEq(epoch.epochNanoseconds, 0n, "epoch.epochNanoseconds");
assertEq(epoch.toString(), "1970-01-01T00:00:00Z", "epoch.toString"); // auto precision, no fraction

var one = new Temporal.Instant(1000000000n);       // epoch + 1 s
assertEq(one.epochSeconds, 1, "one.epochSeconds");
assertEq(one.epochMilliseconds, 1000, "one.epochMilliseconds");
assertEq(one.epochMicroseconds, 1000000, "one.epochMicroseconds");
assertEq(one.epochNanoseconds, 1000000000n, "one.epochNanoseconds");

// from + fromEpoch* land on the same instant.
assertEq(Temporal.Instant.fromEpochSeconds(1).equals(one), true, "fromEpochSeconds(1).equals(one)");
assertEq(Temporal.Instant.fromEpochMilliseconds(1000).equals(one), true, "fromEpochMilliseconds(1000)");
assertEq(Temporal.Instant.fromEpochMicroseconds(1000000).equals(one), true, "fromEpochMicroseconds(1000000)");
assertEq(Temporal.Instant.fromEpochNanoseconds(1000000000n).equals(one), true, "fromEpochNanoseconds(1e9)");

// Negative instants.
var neg = new Temporal.Instant(-1n);
assertEq(neg.epochNanoseconds, -1n, "neg.epochNanoseconds");
assertFalse(neg.equals(epoch), "neg != epoch");

// compare
assertEq(Temporal.Instant.compare(epoch, one), -1, "compare(epoch, one)");
assertEq(Temporal.Instant.compare(one, one), 0, "compare(one, one)");
assertEq(Temporal.Instant.compare(one, epoch), 1, "compare(one, epoch)");

// add / subtract take a Duration. 1 second forward and back.
var dur = new Temporal.Duration(0, 0, 0, 0, 0, 0, 1, 0, 0, 0);
assertEq(one.add(dur).equals(new Temporal.Instant(2000000000n)), true, "one.add(1s)");
assertEq(one.subtract(dur).equals(epoch), true, "one.subtract(1s)");

// since / until compute the difference as a Duration (largestUnit "second").
var big = new Temporal.Instant(3000000000n);
var sdiff = big.since(one);
assertEq(sdiff.seconds, 2, "big.since(one).seconds");
assertEq(sdiff.milliseconds, 0, "big.since(one).ms");
var udiff = big.until(one);
assertEq(udiff.seconds, -2, "big.until(one).seconds");
var sub = new Temporal.Instant(1000001500n).since(one);
assertEq(sub.seconds, 0, "sub.seconds");
assertEq(sub.microseconds, 1, "sub.microseconds");
assertEq(sub.nanoseconds, 500, "sub.nanoseconds");

// valueOf throws (not coercible to primitive).
var threw = false;
try { var _v = one + 1; } catch (e) { threw = true; }
assertEq(threw, true, "Instant valueOf throws");

// ============================================================================
// Temporal.TimeZone
// ============================================================================

assertEq(typeof Temporal.TimeZone, "function", "TimeZone is a function");

var nyc = new Temporal.TimeZone("America/New_York");
assertEq(nyc.id, "America/New_York", "nyc.id");

// Winter (epoch = Jan 1970) -> EST, -5h.
assertEq(nyc.getOffsetNanosecondsFor(epoch), -18000000000000, "nyc winter offset (EST)");
// Summer (2024-07-14) -> EDT, -4h.
var summer = new Temporal.Instant(1721000000000000000n);
assertEq(nyc.getOffsetNanosecondsFor(summer), -14400000000000, "nyc summer offset (EDT)");

var berlin = new Temporal.TimeZone("Europe/Berlin");
assertEq(berlin.id, "Europe/Berlin", "berlin.id");
// Summer 2024 -> CEST, +2h.
assertEq(berlin.getOffsetNanosecondsFor(summer), 7200000000000, "berlin summer offset (CEST)");

var utc = new Temporal.TimeZone("UTC");
assertEq(utc.getOffsetNanosecondsFor(epoch), 0, "utc offset");

var tokyo = new Temporal.TimeZone("Asia/Tokyo");
assertEq(tokyo.getOffsetNanosecondsFor(epoch), 32400000000000, "tokyo offset (JST +9h)");

// Unknown zone throws RangeError.
threw = false;
try { var _bad = new Temporal.TimeZone("Not/AZone"); } catch (e) { threw = true; }
assertEq(threw, true, "unknown zone throws");

// ============================================================================
// Temporal.ZonedDateTime
// ============================================================================

assertEq(typeof Temporal.ZonedDateTime, "function", "ZonedDateTime is a function");

var zsummer = new Temporal.ZonedDateTime(1721000000000000000n, nyc);
assertEq(zsummer.timeZoneId, "America/New_York", "zsummer.timeZoneId");
assertEq(zsummer.calendarId, "iso8601", "zsummer.calendarId");
assertEq(zsummer.epochSeconds, 1721000000, "zsummer.epochSeconds");
assertEq(zsummer.epochNanoseconds, 1721000000000000000n, "zsummer.epochNanoseconds");
assertEq(zsummer.toString(), "2024-07-14T19:33:20-04:00[America/New_York]", "zsummer.toString");

function ure_zoned(name) { return new Temporal.TimeZone(name); }

var zutc = new Temporal.ZonedDateTime(1000000000n, ure_zoned("UTC"));
assertEq(zutc.toString(), "1970-01-01T00:00:01+00:00[UTC]", "zutc.toString");

assertTrue(zsummer.equals(zsummer), "zsummer equals self");
assertFalse(zsummer.equals(zutc), "zsummer != zutc");

// toJSON keeps the offset, drops the zone bracket.
assertEq(zsummer.toJSON(), "2024-07-14T19:33:20-04:00", "zsummer.toJSON");

console.log("Pass: " + pass + " Fail: " + fail);
if (fail > 0) process.exit(1);