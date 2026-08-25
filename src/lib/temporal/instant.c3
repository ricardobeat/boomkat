// Temporal.Instant value type.
//
// An Instant is a BigInt number of nanoseconds since the Unix epoch. The
// engine's existing HBigInt type backs the storage; this module provides
// pure spec-algorithm helpers (add, subtract, comparison) so the builtins
// layer can stay thin.
//
// Memory layout: the heap object (HObjectTemporal variant) carries the
// BigInt in the `big_ns` slot; the `int_a..int_j` slots are unused. The
// GC walker marks `big_ns` via the standard HObjectTemporal path.
module boomkat::lib::temporal;

import boomkat::hbigint;
import boomkat::heap;
import std::math;

// Allocate a fresh Instant with the given nanoseconds value. The Instant
// value-type is just an HBigInt*; the wrapping HObject lives in the
// builtins layer. This module exposes the arithmetic only.
struct Instant {
    hbigint::HBigInt* ns;
}

// True if the value would fit in a long (int64). Useful for the
// epochSeconds / epochMilliseconds getters that must return Number.
fn bool Instant.fits_in_long(&self) {
    // 2 limbs => fits in 128 bits, must range check. For pragmatic
    // purposes we just check len < 2.
    return self.ns != null && self.ns.len <= 2;
}

// Add `delta_ns` (positive or negative) to `a`, returning a new HBigInt.
// The caller owns the returned reference.
fn hbigint::HBigInt*? instant_add(hbigint::HBigInt* a, hbigint::HBigInt* delta_ns, Heap* hp) {
    if (a == null || delta_ns == null) return null;
    if (delta_ns.is_zero()) return hbigint::hbigint_copy(hp, a)!;
    return hbigint::hbigint_addsub(hp, a, delta_ns, false);
}

// Subtract `delta_ns` from `a` (effectively a + (-delta_ns)).
fn hbigint::HBigInt*? instant_sub(hbigint::HBigInt* a, hbigint::HBigInt* delta_ns, Heap* hp) {
    if (a == null || delta_ns == null) return null;
    if (delta_ns.is_zero()) return hbigint::hbigint_copy(hp, a)!;
    return hbigint::hbigint_addsub(hp, a, delta_ns, true);
}

// Three-way comparison: -1 / 0 / +1 for a < b / a == b / a > b.
fn int instant_cmp(hbigint::HBigInt* a, hbigint::HBigInt* b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    return hbigint::hbigint_cmp(a, b);
}
