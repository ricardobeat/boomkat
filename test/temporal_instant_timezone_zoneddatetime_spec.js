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

// getPossibleInstantsFor resolves a wall-clock PlainDateTime to instants.
var jan15 = new Temporal.PlainDateTime(2024, 1, 15, 12, 0, 0);
var winterInst = nyc.getPossibleInstantsFor(jan15);
assertEq(winterInst.length, 1, "winter unique instant count");
assertEq(winterInst[0].toString(), "2024-01-15T17:00:00Z", "winter instant (EST)");
var jul15 = new Temporal.PlainDateTime(2024, 7, 15, 12, 0, 0);
var summerInst = nyc.getPossibleInstantsFor(jul15);
assertEq(summerInst.length, 1, "summer unique instant count");
assertEq(summerInst[0].toString(), "2024-07-15T16:00:00Z", "summer instant (EDT)");
// Spring-forward gap 2024-03-10 02:30 does not exist in NY.
var gap = new Temporal.PlainDateTime(2024, 3, 10, 2, 30, 0);
assertEq(nyc.getPossibleInstantsFor(gap).length, 0, "spring-forward gap has no instants");
// Fall-back overlap 2024-11-03 01:30 happens twice.
var ov = new Temporal.PlainDateTime(2024, 11, 3, 1, 30, 0);
var ovInsts = nyc.getPossibleInstantsFor(ov);
assertEq(ovInsts.length, 2, "fall-back overlap has two instants");
assertEq(ovInsts[0].toString(), "2024-11-03T05:30:00Z", "overlap EDT instant");
assertEq(ovInsts[1].toString(), "2024-11-03T06:30:00Z", "overlap EST instant");

// getNextTransition / getPreviousTransition skip abbreviation-only changes.
var epoch = new Temporal.Instant(0n);
assertEq(nyc.getNextTransition(epoch).toString(), "1970-04-26T07:00:00Z", "next transition after epoch");
var in2024 = new Temporal.Instant(1721000000000000000n);
assertEq(nyc.getPreviousTransition(in2024).toString(), "2024-03-10T07:00:00Z", "prev transition before 2024-07");
var year2100 = new Temporal.Instant(4102444800000000000n);
assertEq(nyc.getNextTransition(year2100), undefined, "no transition after 2100");

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

// withTimeZone keeps the instant, changes the zone.
var zutc2 = zsummer.withTimeZone(utc);
assertEq(zutc2.timeZoneId, "UTC", "withTimeZone id");
assertEq(zutc2.epochSeconds, zsummer.epochSeconds, "withTimeZone preserves epoch");

// withCalendar (iso8601) keeps the instant and zone.
var isoCal = new Temporal.Calendar("iso8601");
var zcal = zsummer.withCalendar(isoCal);
assertEq(zcal.calendarId, "iso8601", "withCalendar id");
assertEq(zcal.epochSeconds, zsummer.epochSeconds, "withCalendar preserves epoch");

// add / subtract take a Duration (time delta on the instant).
var zdur = new Temporal.Duration(0, 0, 0, 0, 0, 0, 1, 0, 0, 0);
assertEq(zsummer.add(zdur).epochSeconds, zsummer.epochSeconds + 1, "zdt add 1s");
assertEq(zsummer.subtract(zdur).epochSeconds, zsummer.epochSeconds - 1, "zdt subtract 1s");

// until / since give the elapsed difference as a Duration.
var zlater = new Temporal.ZonedDateTime(1721000001000000000n, nyc);
var zu = zsummer.until(zlater);
assertEq(zu.seconds, 1, "zdt until seconds");
var zs = zsummer.since(zlater);
assertEq(zs.seconds, -1, "zdt since seconds");

console.log("Pass: " + pass + " Fail: " + fail);
if (fail > 0) process.exit(1);