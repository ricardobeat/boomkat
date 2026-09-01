// Temporal.Instant value type: a count of nanoseconds since the Unix epoch.
//
// The arithmetic here is pure. An Instant is an int128 rather than the engine's
// HBigInt, which is what lets this module — and so the whole of
// boomkat::lib::temporal — compile without importing any engine type. The
// builtins layer owns the conversion to and from the JS BigInt that Temporal
// exposes, since that is a language-binding concern rather than a calendrical
// one.
//
// int128 is the right width and not a compromise. The spec's representable
// range is +/-8.64e21 ns (100,000,000 days), which needs 74 bits; int128 leaves
// roughly 2e16 times that headroom, so intermediate sums and differences cannot
// overflow before the range check rejects them. The engine already uses int128
// for the same quantity elsewhere -- see zdt_local_to_epoch_ns.
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

// a + delta. Cannot overflow int128 for in-range inputs; the caller range-checks
// the result, since going out of range is a spec error rather than an arithmetic
// one.
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

// Current epoch in whole seconds (floored toward -infinity so negative
// instants land on the correct second). std::time::now() reports microseconds
// since the Unix epoch.
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

// Current epoch in nanoseconds (precise; std::time::now is microsecond).
fn int128 now_epoch_nanoseconds() {
    long micros = (long)std::time::now();
    return (int128)micros * 1000;
}
