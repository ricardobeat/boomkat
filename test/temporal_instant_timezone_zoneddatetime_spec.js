// Temporal.Instant + time zones + Temporal.ZonedDateTime spec-locked
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

// epochSeconds/epochMicroseconds and fromEpochSeconds/fromEpochMicroseconds
// were removed from the proposal; milliseconds and nanoseconds are the two the
// spec keeps.
var epoch = new Temporal.Instant(0n);
assertEq(epoch.epochMilliseconds, 0, "epoch.epochMilliseconds");
assertEq(epoch.epochNanoseconds, 0n, "epoch.epochNanoseconds");
assertEq(epoch.toString(), "1970-01-01T00:00:00Z", "epoch.toString"); // auto precision, no fraction

// Fractional-second precision (auto trims trailing zeros; a fixed width or
// smallestUnit truncates, the Temporal default roundingMode).
var frac = new Temporal.Instant(1000000001n);         // 1s + 1ns
assertEq(frac.toString(), "1970-01-01T00:00:01.000000001Z", "frac auto (1ns)");
assertEq(frac.toString({ fractionalSecondDigits: 9 }), "1970-01-01T00:00:01.000000001Z", "frac 9 digits");
assertEq(frac.toString({ fractionalSecondDigits: 3 }), "1970-01-01T00:00:01.000Z", "frac fixed 3 digits");
assertEq(frac.toString({ smallestUnit: "millisecond" }), "1970-01-01T00:00:01.000Z", "frac ms unit");
var frac500 = new Temporal.Instant(1000500000000n);    // 500ms past the epoch minute
assertEq(frac500.toString(), "1970-01-01T00:16:40.5Z", "frac auto (500ms trim)");
assertEq(frac500.toString({ smallestUnit: "nanosecond" }), "1970-01-01T00:16:40.500000000Z", "frac ns unit");

var one = new Temporal.Instant(1000000000n);       // epoch + 1 s
assertEq(one.epochMilliseconds, 1000, "one.epochMilliseconds");
assertEq(one.epochNanoseconds, 1000000000n, "one.epochNanoseconds");

// Negative instants (regression: the ctor released a borrowed BigInt, so a
// negated register literal was freed while the Instant still referenced it).
var negBig = new Temporal.Instant(-1500000000n);   // -1.5 s
assertEq(negBig.epochNanoseconds, -1500000000n, "negBig.epochNanoseconds");
assertEq(negBig.toString(), "1969-12-31T23:59:58.5Z", "negative instant toString (floor)");
assertEq(Temporal.Instant.fromEpochMilliseconds(1000).equals(one), true, "fromEpochMilliseconds(1000)");
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

// largestUnit scales the chosen unit; sub-units are truncated toward zero.
var hdiff = new Temporal.Instant(3601500000000n).since(one, { largestUnit: "seconds" });
assertEq(hdiff.seconds, 3600, "largestUnit seconds .seconds");
assertEq(hdiff.milliseconds, 500, "largestUnit seconds .milliseconds");

// ToTemporalInstant: string argument is parsed as ISO instant.
var fromstr = new Temporal.Instant(0n).since("1970-01-01T00:00:01Z");
assertEq(fromstr.seconds, -1, "since accepts ISO string");

// ToTemporalInstant: non-objects / non-strings throw TypeError; empty /
// unparseable strings throw RangeError.
var threwType = false, threwRange = false;
try { new Temporal.Instant(0n).since(undefined); } catch (e) { threwType = e instanceof TypeError; }
try { new Temporal.Instant(0n).since(""); } catch (e) { threwRange = e instanceof RangeError; }
assertEq(threwType, true, "since(undefined) -> TypeError");
assertEq(threwRange, true, "since('') -> RangeError");


// valueOf throws (not coercible to primitive).
var threw = false;
try { var _v = one + 1; } catch (e) { threw = true; }
assertEq(threw, true, "Instant valueOf throws");

// ============================================================================
// Time zones
// ============================================================================
//
// Temporal.TimeZone was removed from the proposal: a zone is an IANA name
// string, and the offset/transition queries it used to carry are observed
// through ZonedDateTime.

// Winter (epoch = Jan 1970) -> EST, -5h; summer 2024 -> EDT, -4h.
function zonedAt(ns, zone) { return new Temporal.Instant(ns).toZonedDateTimeISO(zone); }

assertEq(zonedAt(0n, "America/New_York").offsetNanoseconds, -18000000000000, "nyc winter offset (EST)");
var summerNs = 1721000000000000000n;
assertEq(zonedAt(summerNs, "America/New_York").offsetNanoseconds, -14400000000000, "nyc summer offset (EDT)");
assertEq(zonedAt(summerNs, "Europe/Berlin").offsetNanoseconds, 7200000000000, "berlin summer offset (CEST)");
assertEq(zonedAt(0n, "UTC").offsetNanoseconds, 0, "utc offset");
assertEq(zonedAt(0n, "Asia/Tokyo").offsetNanoseconds, 32400000000000, "tokyo offset (JST +9h)");

// Unknown zone throws RangeError.
threw = false;
try { zonedAt(0n, "Not/AZone"); } catch (e) { threw = true; }
assertEq(threw, true, "unknown zone throws");

// Resolving a wall clock to an instant: a unique time in each offset.
assertEq(
  Temporal.PlainDateTime.from("2024-01-15T12:00").toZonedDateTime("America/New_York").toInstant().toString(),
  "2024-01-15T17:00:00Z", "winter instant (EST)");
assertEq(
  Temporal.PlainDateTime.from("2024-07-15T12:00").toZonedDateTime("America/New_York").toInstant().toString(),
  "2024-07-15T16:00:00Z", "summer instant (EDT)");
// The spring-forward gap (2024-03-10 02:30 does not exist in NY) resolves
// forward; the fall-back overlap (2024-11-03 01:30 happens twice) takes the
// earlier of the two by default.
assertEq(
  Temporal.PlainDateTime.from("2024-03-10T02:30").toZonedDateTime("America/New_York").toInstant().toString(),
  "2024-03-10T07:30:00Z", "spring-forward gap shifts forward");
assertEq(
  Temporal.PlainDateTime.from("2024-11-03T01:30").toZonedDateTime("America/New_York").toInstant().toString(),
  "2024-11-03T05:30:00Z", "fall-back overlap takes the earlier instant");

// getTimeZoneTransition skips abbreviation-only changes: only a real offset
// change counts.
assertEq(zonedAt(0n, "America/New_York").getTimeZoneTransition("next").toInstant().toString(),
         "1970-04-26T07:00:00Z", "next transition after epoch");
assertEq(zonedAt(summerNs, "America/New_York").getTimeZoneTransition("previous").toInstant().toString(),
         "2024-03-10T07:00:00Z", "prev transition before 2024-07");
assertEq(zonedAt(4102444800000000000n, "America/New_York").getTimeZoneTransition("next"), null,
         "no transition after 2100");
// A zone that never transitions has neither neighbour.
assertEq(zonedAt(0n, "UTC").getTimeZoneTransition("next"), null, "UTC has no next transition");
assertEq(zonedAt(0n, "UTC").getTimeZoneTransition("previous"), null, "UTC has no previous transition");

// ============================================================================
// Temporal.ZonedDateTime
// ============================================================================

assertEq(typeof Temporal.ZonedDateTime, "function", "ZonedDateTime is a function");

var zsummer = new Temporal.ZonedDateTime(1721000000000000000n, "America/New_York");
assertEq(zsummer.timeZoneId, "America/New_York", "zsummer.timeZoneId");
assertEq(zsummer.calendarId, "iso8601", "zsummer.calendarId");
assertEq(zsummer.epochMilliseconds, 1721000000000, "zsummer.epochMilliseconds");
assertEq(zsummer.epochNanoseconds, 1721000000000000000n, "zsummer.epochNanoseconds");
assertEq(zsummer.toString(), "2024-07-14T19:33:20-04:00[America/New_York]", "zsummer.toString");

var zutc = new Temporal.ZonedDateTime(1000000000n, "UTC");
assertEq(zutc.toString(), "1970-01-01T00:00:01+00:00[UTC]", "zutc.toString");

assertTrue(zsummer.equals(zsummer), "zsummer equals self");
assertFalse(zsummer.equals(zutc), "zsummer != zutc");

// toJSON keeps the offset, drops the zone bracket.
assertEq(zsummer.toJSON(), "2024-07-14T19:33:20-04:00[America/New_York]", "zsummer.toJSON");

// withTimeZone keeps the instant, changes the zone.
var zutc2 = zsummer.withTimeZone("UTC");
assertEq(zutc2.timeZoneId, "UTC", "withTimeZone id");
assertEq(zutc2.epochNanoseconds, zsummer.epochNanoseconds, "withTimeZone preserves epoch");

// withCalendar (iso8601) keeps the instant and zone.
var zcal = zsummer.withCalendar("iso8601");
assertEq(zcal.calendarId, "iso8601", "withCalendar id");
assertEq(zcal.epochNanoseconds, zsummer.epochNanoseconds, "withCalendar preserves epoch");

// add / subtract take a Duration (time delta on the instant).
var zdur = new Temporal.Duration(0, 0, 0, 0, 0, 0, 1, 0, 0, 0);
assertEq(zsummer.add(zdur).epochNanoseconds, zsummer.epochNanoseconds + 1000000000n, "zdt add 1s");
assertEq(zsummer.subtract(zdur).epochNanoseconds, zsummer.epochNanoseconds - 1000000000n, "zdt subtract 1s");

// until / since give the elapsed difference as a Duration.
var zlater = new Temporal.ZonedDateTime(1721000001000000000n, "America/New_York");
var zu = zsummer.until(zlater);
assertEq(zu.seconds, 1, "zdt until seconds");
var zs = zsummer.since(zlater);
assertEq(zs.seconds, -1, "zdt since seconds");

// with overlays wall-clock fields and re-resolves the zone offset.
var zwith = zsummer.with({ hour: 9 });
assertEq(zwith.toString(), "2024-07-14T09:33:20-04:00[America/New_York]", "zdt with hour");
assertEq(zwith.timeZoneId, "America/New_York", "zdt with keeps zone");
var zwin = zsummer.with({ year: 2025, month: 1, day: 15, hour: 10, minute: 0 });
assertEq(zwin.toString(), "2025-01-15T10:00:20-05:00[America/New_York]", "zdt with winter offset (EST)");

// Temporal.Instant constructor: must be called with new; range-checked.
var threwNoNew = false;
try { Temporal.Instant(0n); } catch (e) { threwNoNew = e instanceof TypeError; }
assertEq(threwNoNew, true, "Instant() without new throws TypeError");
var limit = 8640000000000000000000n;
var threwOver = false;
try { new Temporal.Instant(limit + 1n); } catch (e) { threwOver = e instanceof RangeError; }
assertEq(threwOver, true, "new Instant(limit+1n) throws RangeError");

// Temporal.Instant.from accepts an ISO string.
var fromstr = Temporal.Instant.from("2022-07-01T12:34:56Z");
assertEq(fromstr.epochNanoseconds, 1656678896000000000n, "Instant.from ISO string ns");
var threwBadStr = false;
try { Temporal.Instant.from("not an iso"); } catch (e) { threwBadStr = e instanceof RangeError; }
assertEq(threwBadStr, true, "Instant.from(bad string) throws RangeError");

// Year formatting in toString: 4-digit unsigned for 0..9999, 6-digit signed
// for years outside that range.
assertEq(new Temporal.Instant(0n).toString(), "1970-01-01T00:00:00Z", "epoch toString");
assertEq(new Temporal.Instant(-13849764999999999n).toString(), "1969-07-24T16:50:35.000000001Z", "negative toString floor");

console.log("Pass: " + pass + " Fail: " + fail);
if (fail > 0) process.exit(1);