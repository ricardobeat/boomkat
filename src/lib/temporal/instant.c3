// Temporal.Instant value type: a count of nanoseconds since the Unix epoch.
//
// The arithmetic is pure: an Instant is an int128, not an engine HBigInt, so
// this module imports no engine types. The builtins layer converts to and from
// the JS BigInt.
//
// The representable range is +/-8.64e21 ns (100,000,000 days), which needs 74
// bits. int128 leaves about 2e16 times that headroom, so sums and differences
// cannot overflow before the range check rejects them.
module boomkat::lib::temporal;

import std::time;

// The widest epoch offset Temporal can represent, per Temporal.Instant:
// 100,000,000 days either side of the epoch. The nanosecond form is derived
// from the day form so the two can never drift apart.
const long INSTANT_MAX_DAYS = 100_000_000L;
const int128 INSTANT_MAX_NS = (int128)INSTANT_MAX_DAYS * (int128)NS_PER_DAY;

// True when an epoch-day count is inside the representable range. Callers
// that have a date rather than an instant want
// `is_instant_representable_date` in civil.c3, which wraps this.
fn bool epoch_days_in_range(long days) {
    return days >= -INSTANT_MAX_DAYS && days <= INSTANT_MAX_DAYS;
}

// Nanoseconds since the Unix epoch. The zero value is the epoch itself.
struct Instant {
    int128 ns;
}

// True when `ns` is inside Temporal's representable range. The builtins layer
// throws RangeError on false; this module has no way to raise one.
fn bool instant_in_range(int128 ns) {
    return ns >= -INSTANT_MAX_NS && ns <= INSTANT_MAX_NS;
}

// True when the value fits in a long, which the epochSeconds and
// epochMilliseconds getters need in order to return a Number.
fn bool instant_fits_in_long(int128 ns) {
    return ns >= (int128)-0x8000_0000_0000_0000 && ns <= (int128)0x7FFF_FFFF_FFFF_FFFF;
}

// a + delta. An out-of-range result is the caller's to reject, not an
// arithmetic failure.
fn int128 instant_add(int128 a, int128 delta_ns) {
    return a + delta_ns;
}

// a - delta, with the same contract as instant_add.
fn int128 instant_sub(int128 a, int128 delta_ns) {
    return a - delta_ns;
}

// Three-way comparison: -1, 0, +1 for a < b, a == b, a > b.
fn int instant_cmp(int128 a, int128 b) {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

// ---- Wall-clock readings from the host ----

// Current epoch in whole seconds, floored toward -infinity.
fn long now_epoch_seconds() {
    long micros = (long)std::time::now();
    long secs = micros / 1_000_000L;
    if (micros < 0 && micros % 1_000_000L != 0) secs -= 1;
    return secs;
}

// Current epoch in whole milliseconds (same floor semantics).
fn long now_epoch_milliseconds() {
    long micros = (long)std::time::now();
    long ms = micros / 1000L;
    if (micros < 0 && micros % 1000L != 0) ms -= 1;
    return ms;
}

// Current epoch in nanoseconds, at microsecond precision.
fn int128 now_epoch_nanoseconds() {
    long micros = (long)std::time::now();
    return (int128)micros * 1000;
}
