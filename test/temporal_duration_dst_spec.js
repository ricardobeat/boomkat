// Spec coverage for Duration arithmetic against a zoned relativeTo, where a
// calendar day is not 24 hours.
//
// test262 does not exercise this: every Duration.total test with a zoned
// relativeTo uses UTC or a fixed offset, where the local axis and the instant
// axis coincide and a day is always exactly 24 hours. That makes the zoned and
// unzoned code paths agree, so a Duration.total that ignores the time zone
// still scores green. These assertions fail against such an implementation.
//
// Reference points (America/New_York):
//   2024-03-10 spring forward — that local day is 23 hours
//   2024-11-03 fall back      — that local day is 25 hours

function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        throw new Error(msg + ": got " + JSON.stringify(actual) + ", expected " + JSON.stringify(expected));
    }
}

const NY = "America/New_York";
const spring = Temporal.ZonedDateTime.from("2024-03-09T00:00:00[" + NY + "]");
const fall   = Temporal.ZonedDateTime.from("2024-11-02T00:00:00[" + NY + "]");
const utc    = new Temporal.ZonedDateTime(0n, "UTC");

// The day lengths the rest of the file depends on. If these are wrong, the
// tz database or ZonedDateTime.until is broken, not Duration.
assertEq(spring.until(spring.add({ days: 1 }), { largestUnit: "hour" }).hours, 24, "day 1 is 24h");
assertEq(spring.add({ days: 1 }).until(spring.add({ days: 2 }), { largestUnit: "hour" }).hours, 23,
         "spring-forward day is 23h");
assertEq(fall.add({ days: 1 }).until(fall.add({ days: 2 }), { largestUnit: "hour" }).hours, 25,
         "fall-back day is 25h");

// total({unit:"day"}) — the leftover is a fraction of that day's own length,
// not of a flat 24 hours. 1d12h spans a full 24h day, then 12h into the next.
const d1h12 = new Temporal.Duration(0, 0, 0, 1, 12);
assertEq(d1h12.total({ unit: "day", relativeTo: spring }), 1 + 12 / 23,
         "spring: 12h into a 23h day");
assertEq(d1h12.total({ unit: "day", relativeTo: fall }), 1 + 12 / 25,
         "fall: 12h into a 25h day");
assertEq(d1h12.total({ unit: "day", relativeTo: utc }), 1.5,
         "UTC has no transitions, so the day stays 24h");

// The sign of the fraction follows the direction of travel.
assertEq(new Temporal.Duration(0, 0, 0, -1, -12).total({ unit: "day", relativeTo: spring }), -1.5,
         "negative: the day before the start is a full 24h");

// A whole number of days stays whole regardless of their lengths.
assertEq(new Temporal.Duration(0, 0, 0, 2).total({ unit: "day", relativeTo: spring }), 2,
         "2 days across a spring-forward is still 2");
assertEq(new Temporal.Duration(0, 0, 0, 2).total({ unit: "day", relativeTo: fall }), 2,
         "2 days across a fall-back is still 2");

// Units of hour and below are uniform on the instant axis: a transition
// changes what the wall clock reads, never how much time elapsed.
assertEq(d1h12.total({ unit: "hour", relativeTo: spring }), 36, "hours are elapsed time");
assertEq(d1h12.total({ unit: "hour", relativeTo: fall }), 36, "hours ignore the transition");
assertEq(new Temporal.Duration(0, 0, 0, 0, 5).total({ unit: "day", relativeTo: spring }), 5 / 24,
         "sub-day duration on a normal day");

// A duration landing exactly on the transition boundary.
assertEq(new Temporal.Duration(0, 0, 0, 1, 2).total({ unit: "day", relativeTo: spring }), 1 + 2 / 23,
         "2h into the short day");

// Adding days moves the wall clock, so the offset changes but the local time
// of day is preserved across the transition.
const after = spring.add({ days: 2 });
assertEq(spring.offset, "-05:00", "start is standard time");
assertEq(after.offset, "-04:00", "spring forward changed the offset");
// Adding calendar days moves the local wall clock, so the time of day is
// preserved even though the elapsed time was 47 hours, not 48.
assertEq(after.hour, spring.hour, "local time of day preserved across the transition");
assertEq(spring.until(after, { largestUnit: "hour" }).hours, 47, "2 calendar days = 47h here");

print("OK");
