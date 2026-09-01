// Temporal unit and rounding-mode vocabulary: the `TemporalUnit` /
// `TemporalRoundMode` enums plus the pure predicates and rounding primitives
// the spec algorithms are written in terms of.
//
// These live beside the calendar code rather than in the engine layer because
// every Temporal type's rounding path is expressed with them -- Duration,
// PlainDate, PlainTime, PlainDateTime and ZonedDateTime alike -- and none of
// it needs a JS object to work. Rounding here is integer arithmetic on
// nanosecond counts; the JS-facing option parsing (which string maps to which
// enum member, and what to throw when it does not) stays in
// src/builtins/temporal.c3.
module boomkat::lib::temporal;

import std::math;

enum TemporalUnit : int {
    YEAR, MONTH, WEEK, DAY,
    HOUR, MINUTE, SECOND, MILLISECOND, MICROSECOND, NANOSECOND,
}

enum TemporalRoundMode : int {
    CEIL, FLOOR, EXPAND, TRUNC,
    HALF_CEIL, HALF_FLOOR, HALF_EXPAND, HALF_TRUNC, HALF_EVEN,
}

// spec's IsCalendarUnit: years/months/weeks only (used for plain-relativeTo
// "calendar unit" branches that should NOT include days)
fn bool is_cal_unit(TemporalUnit u) { return u <= TemporalUnit.WEEK; }

// spec's TemporalUnitCategory == "date": years/months/weeks/days
fn bool is_date_unit(TemporalUnit u) { return u <= TemporalUnit.DAY; }

fn long unit_ns_divisor(TemporalUnit u) {
    switch (u) {
        case TemporalUnit.HOUR:        return 3600000000000L;
        case TemporalUnit.MINUTE:      return   60000000000L;
        case TemporalUnit.SECOND:      return    1000000000L;
        case TemporalUnit.MILLISECOND: return       1000000L;
        case TemporalUnit.MICROSECOND: return          1000L;
        case TemporalUnit.NANOSECOND:  return             1L;
        default: return 0;
    }
}

fn long max_round_incr(TemporalUnit u) {
    switch (u) {
        case TemporalUnit.HOUR:        return 24;
        case TemporalUnit.MINUTE:      return 60;
        case TemporalUnit.SECOND:      return 60;
        case TemporalUnit.MILLISECOND: return 1000;
        case TemporalUnit.MICROSECOND: return 1000;
        case TemporalUnit.NANOSECOND:  return 1000;
        default: return 0;
    }
}

fn TemporalUnit larger_unit(TemporalUnit a, TemporalUnit b) { return a < b ? a : b; }

// 10^e nanoseconds, for e in [0, 9]: the rounding increment that a
// fractional-second digit count implies.
fn long ns_pow10(int e) {
    long v = 1;
    for (int i = 0; i < e; i++) v *= 10;
    return v;
}

fn bool parse_unit_str(char[] s, TemporalUnit* out) {
    if (s == "year"  || s == "years")      { *out = TemporalUnit.YEAR; return true; }
    if (s == "month" || s == "months")     { *out = TemporalUnit.MONTH; return true; }
    if (s == "week"  || s == "weeks")      { *out = TemporalUnit.WEEK; return true; }
    if (s == "day"   || s == "days")       { *out = TemporalUnit.DAY; return true; }
    if (s == "hour"  || s == "hours")      { *out = TemporalUnit.HOUR; return true; }
    if (s == "minute" || s == "minutes")   { *out = TemporalUnit.MINUTE; return true; }
    if (s == "second" || s == "seconds")   { *out = TemporalUnit.SECOND; return true; }
    if (s == "millisecond" || s == "milliseconds") { *out = TemporalUnit.MILLISECOND; return true; }
    if (s == "microsecond" || s == "microseconds") { *out = TemporalUnit.MICROSECOND; return true; }
    if (s == "nanosecond" || s == "nanoseconds")   { *out = TemporalUnit.NANOSECOND; return true; }
    return false;
}

fn bool parse_rm_str(char[] s, TemporalRoundMode* out) {
    if (s == "ceil")       { *out = TemporalRoundMode.CEIL; return true; }
    if (s == "floor")      { *out = TemporalRoundMode.FLOOR; return true; }
    if (s == "expand")     { *out = TemporalRoundMode.EXPAND; return true; }
    if (s == "trunc")      { *out = TemporalRoundMode.TRUNC; return true; }
    if (s == "halfCeil")   { *out = TemporalRoundMode.HALF_CEIL; return true; }
    if (s == "halfFloor")  { *out = TemporalRoundMode.HALF_FLOOR; return true; }
    if (s == "halfExpand") { *out = TemporalRoundMode.HALF_EXPAND; return true; }
    if (s == "halfTrunc")  { *out = TemporalRoundMode.HALF_TRUNC; return true; }
    if (s == "halfEven")   { *out = TemporalRoundMode.HALF_EVEN; return true; }
    return false;
}

// The mode giving the same result when applied to a negative value's magnitude.
// On a magnitude, "toward negative infinity" means "toward zero", so ceil and
// floor swap. trunc and expand are defined relative to zero and pass through.
fn TemporalRoundMode mode_for_negative_magnitude(TemporalRoundMode m) {
    switch (m) {
        case TemporalRoundMode.CEIL:       return TemporalRoundMode.FLOOR;
        case TemporalRoundMode.FLOOR:      return TemporalRoundMode.CEIL;
        case TemporalRoundMode.HALF_CEIL:  return TemporalRoundMode.HALF_FLOOR;
        case TemporalRoundMode.HALF_FLOOR: return TemporalRoundMode.HALF_CEIL;
        default: return m;
    }
}

// Round a signed nanosecond count to a multiple of `incr_ns`.
//
// until/since round by magnitude: "trunc" moves toward zero in both directions.
// The rounding therefore runs on the absolute value, with the sign reapplied at
// the end, and the direction-sensitive modes (ceil, floor and their half-*
// forms) mirrored for a negative count.
fn long round_long_ns(long v, long incr_ns, TemporalRoundMode mode) {
    bool neg = v < 0;
    long mag = neg ? -v : v;
    if (neg) mode = mode_for_negative_magnitude(mode);

    long q = mag / incr_ns;
    long r = mag - q * incr_ns;
    if (r != 0) {
        switch (mode) {
            case TemporalRoundMode.TRUNC:
            case TemporalRoundMode.FLOOR: break;
            case TemporalRoundMode.EXPAND:
            case TemporalRoundMode.CEIL: q += 1; break;
            default: {
                long twice = r * 2;
                if (twice > incr_ns) {
                    q += 1;
                } else if (twice == incr_ns) {
                    switch (mode) {
                        case TemporalRoundMode.HALF_TRUNC:
                        case TemporalRoundMode.HALF_FLOOR: break;
                        case TemporalRoundMode.HALF_EXPAND:
                        case TemporalRoundMode.HALF_CEIL: q += 1; break;
                        case TemporalRoundMode.HALF_EVEN: if ((q & 1) != 0) q += 1; break;
                        default: break;
                    }
                }
                break;
            }
        }
    }
    long out = q * incr_ns;
    return neg ? -out : out;
}

// int128 counterpart of round_long_ns, for nanosecond counts that exceed the
// 64-bit range (~292 years). Same magnitude-first rounding, sign reapplied at
// the end, direction-sensitive modes mirrored for a negative count.
fn int128 round_long_ns_128(int128 v, int128 incr_ns, TemporalRoundMode mode) {
    bool neg = v < 0;
    int128 mag = neg ? -v : v;
    if (neg) mode = mode_for_negative_magnitude(mode);

    int128 q = mag / incr_ns;
    int128 r = mag - q * incr_ns;
    if (r != 0) {
        switch (mode) {
            case TemporalRoundMode.TRUNC:
            case TemporalRoundMode.FLOOR: break;
            case TemporalRoundMode.EXPAND:
            case TemporalRoundMode.CEIL: q += 1; break;
            default: {
                int128 twice = r * 2;
                if (twice > incr_ns) {
                    q += 1;
                } else if (twice == incr_ns) {
                    switch (mode) {
                        case TemporalRoundMode.HALF_TRUNC:
                        case TemporalRoundMode.HALF_FLOOR: break;
                        case TemporalRoundMode.HALF_EXPAND:
                        case TemporalRoundMode.HALF_CEIL: q += 1; break;
                        case TemporalRoundMode.HALF_EVEN: if ((q & 1) != 0) q += 1; break;
                        default: break;
                    }
                }
                break;
            }
        }
    }
    int128 out = q * incr_ns;
    return neg ? -out : out;
}

fn double round_num_to_incr(double x, double incr, TemporalRoundMode mode) {
    if (incr == 1) {
        // Round to nearest integer.
        switch (mode) {
            case TemporalRoundMode.CEIL:       return math::ceil(x);
            case TemporalRoundMode.FLOOR:      return math::floor(x);
            case TemporalRoundMode.EXPAND:     return (x >= 0) ? math::ceil(x) : math::floor(x);
            case TemporalRoundMode.TRUNC:      return (x >= 0) ? math::floor(x) : math::ceil(x);
            case TemporalRoundMode.HALF_CEIL:  { double f = math::floor(x); return (x - f >= 0.5) ? f + 1 : f; }
            case TemporalRoundMode.HALF_FLOOR: { double f = math::floor(x); return (x - f > 0.5) ? f + 1 : f; }
            case TemporalRoundMode.HALF_EXPAND: {
                if (x >= 0) { double f = math::floor(x); return (x - f >= 0.5) ? f + 1 : f; }
                double c = math::ceil(x); return (c - x >= 0.5) ? c - 1 : c;
            }
            case TemporalRoundMode.HALF_TRUNC: {
                if (x >= 0) { double f = math::floor(x); return (x - f > 0.5) ? f + 1 : f; }
                double c = math::ceil(x); return (c - x > 0.5) ? c - 1 : c;
            }
            case TemporalRoundMode.HALF_EVEN: {
                double f = math::floor(x);
                double frac = x - f;
                if (frac < 0.5) return f;
                if (frac > 0.5) return f + 1;
                return (math::floor(f / 2) * 2 == f) ? f : f + 1;
            }
        }
    }
    double q = x / incr;
    double r1, r2;
    if (x >= 0) {
        r1 = math::floor(q) * incr;
        r2 = r1 + incr;
    } else {
        r2 = math::ceil(q) * incr;
        r1 = r2 - incr;
    }
    double rem = x - r1;
    switch (mode) {
        case TemporalRoundMode.CEIL:       return r2;
        case TemporalRoundMode.FLOOR:      return r1;
        case TemporalRoundMode.EXPAND:     return (x >= 0) ? r2 : r1;
        case TemporalRoundMode.TRUNC:      return (x >= 0) ? r1 : r2;
        case TemporalRoundMode.HALF_CEIL:  return (rem >= incr / 2) ? r2 : r1;
        case TemporalRoundMode.HALF_FLOOR: return (rem > incr / 2) ? r2 : r1;
        case TemporalRoundMode.HALF_EXPAND: return ((x >= 0 ? rem >= incr / 2 : rem > incr / 2)) ? r2 : r1;
        case TemporalRoundMode.HALF_TRUNC: return ((x >= 0 ? rem > incr / 2 : rem >= incr / 2)) ? r2 : r1;
        case TemporalRoundMode.HALF_EVEN: {
            double half = incr / 2;
            if (rem < half) return r1;
            if (rem > half) return r2;
            // Tie: pick the multiple whose factor (qb) is even.
            double qb = math::floor(q);
            if (math::floor(qb / 2) * 2 == qb) return r1;
            return r2;
        }
    }
    return x;
}

// Mirror a rounding mode about zero, so rounding a negated difference lands on
// the same instant as rounding the difference itself.
fn TemporalRoundMode negate_round_mode(TemporalRoundMode m) {
    switch (m) {
        case TemporalRoundMode.CEIL:       return TemporalRoundMode.FLOOR;
        case TemporalRoundMode.FLOOR:      return TemporalRoundMode.CEIL;
        case TemporalRoundMode.HALF_CEIL:  return TemporalRoundMode.HALF_FLOOR;
        case TemporalRoundMode.HALF_FLOOR: return TemporalRoundMode.HALF_CEIL;
        default: return m;
    }
}

// Translate a sign-aware rounding mode into the as-if-positive mode that
// round_bigint_ns must use to produce the same result for a NEGATIVE value.
//
// round_bigint_ns works on the floor-normalized scale, where "down" is toward
// negative infinity. For a negative value, rounding toward zero is therefore
// "up" — so trunc behaves as ceil and expand as floor. The ceil/floor pair
// swaps for the same reason, and the half-* modes follow their tie direction.
fn TemporalRoundMode mode_for_negative(TemporalRoundMode m) {
    switch (m) {
        case TemporalRoundMode.TRUNC:       return TemporalRoundMode.CEIL;
        case TemporalRoundMode.EXPAND:      return TemporalRoundMode.FLOOR;
        case TemporalRoundMode.HALF_TRUNC:  return TemporalRoundMode.HALF_CEIL;
        case TemporalRoundMode.HALF_EXPAND: return TemporalRoundMode.HALF_FLOOR;
        default: return m;
    }
}

fn bool is_half_mode(TemporalRoundMode m) {
    return m >= TemporalRoundMode.HALF_CEIL;
}
