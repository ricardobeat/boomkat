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

// The widest epoch-nanosecond value Temporal can represent, per
// Temporal.Instant: 100,000,000 days either side of the epoch.
//   86400 s/day * 1e8 days * 1e9 ns/s
const int128 INSTANT_MAX_NS = (int128)86400 * (int128)100000000 * (int128)1000000000;

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
