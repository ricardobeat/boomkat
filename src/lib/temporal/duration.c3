// Temporal.Duration as a value type, plus the arithmetic the spec algorithms
// are written in terms of: validity, balancing, decomposition into a
// largest-unit form, and the correctly-rounded divisions that total() needs.
//
// A Duration is a bag of ten signed fields, not a point on a timeline, so most
// of this is integer arithmetic on nanosecond counts and needs no calendar at
// all. What does need one -- resolving a duration's date part against a
// starting date -- takes that date as an argument rather than reaching for a
// JS object.
//
// The sub-second fields are float64 rather than int64 on purpose: the spec
// lets them exceed 2^63 (a Duration may legally carry 8.7e21 microseconds),
// and IsValidDuration's range check is defined on the double round-trip. See
// is_valid_duration for the exact rule.
//
// Engine-side concerns stay in src/builtins/temporal.c3: coercing a JS value
// or property bag into a DurationParts, allocating the JS object, and raising
// the RangeErrors these functions signal by returning false.
module boomkat::lib::temporal;

import std::math;

struct DurationParts {
    long years;
    long months;
    long weeks;
    long days;
    long hours;
    long minutes;
    long seconds;
    double ms;
    double us;
    double ns;
}

fn bool is_valid_duration(DurationParts* d) {
    if (math::abs((double)d.years) >= 4294967296.0 ||
        math::abs((double)d.months) >= 4294967296.0 ||
        math::abs((double)d.weeks) >= 4294967296.0) {
        return false;
    }
    int overall_sign = 0;
    long*[7] comps = { &d.years, &d.months, &d.weeks, &d.days, &d.hours,
        &d.minutes, &d.seconds };
    for (int k = 0; k < 7; k++) {
        if (*comps[k] == 0) continue;
        int s = *comps[k] < 0 ? -1 : 1;
        if (overall_sign == 0) { overall_sign = s; }
        else if (overall_sign != s) { return false; }
    }
    double[3] sub = { d.ms, d.us, d.ns };
    for (int k = 0; k < 3; k++) {
        if (sub[k] == 0.0) continue;
        int s = sub[k] < 0.0 ? -1 : 1;
        if (overall_sign == 0) { overall_sign = s; }
        else if (overall_sign != s) { return false; }
    }
    // Spec IsValidDuration computes normalizedNs as:
    //   days*86400e9 + hours*3600e9 + mins*60e9 + secs*1e9
    //     + ℝ(𝔽(ms))*1e6 + ℝ(𝔽(us))*1000 + ℝ(𝔽(ns))
    // and rejects if abs(normalizedNs) >= 10^9 * 2^53. For integers <= 2^53
    // the ℝ(𝔽(...)) round-trip is exact, but a value like 9007199254740991926258
    // µs (produced by dividing a >1e24 ns total by 1000) is rounded up to the
    // nearest double — which can push the total over the threshold even though
    // the exact int128 sum does not. Round-trip via double before summing the
    // sub-second fields so the check matches the spec. Cast straight from
    // double to int128 to avoid an intermediate long overflow on values above
    // 2^63.
    int128 total_ns = (int128)0;
    total_ns += (int128)math::abs(d.days) * NS_PER_DAY;
    total_ns += (int128)math::abs(d.hours) * NS_PER_HOUR;
    total_ns += (int128)math::abs(d.minutes) * NS_PER_MIN;
    total_ns += (int128)math::abs(d.seconds) * NS_PER_SEC;
    double[3] sub_abs = { math::abs(d.ms), math::abs(d.us), math::abs(d.ns) };
    long[3] mult = { NS_PER_MS, 1000L, 1L };
    for (int k = 0; k < 3; k++) {
        int128 rounded = (int128)(double)sub_abs[k];
        total_ns += math::abs(rounded) * mult[k];
    }
    // 2^53 * 10^9 = 9007199254740992000000000
    if (total_ns >= (int128)9007199254740992L * (int128)NS_PER_SEC) {
        return false;
    }
    return true;
}

// The duration's time columns (hours and below) in nanoseconds, excluding
// days. Several spec algorithms need exactly this: AddTime and
// AddZonedDateTime treat days as a calendar quantity resolved against a zone
// or a date, so folding them in here at a flat 24 hours would be wrong.
// `duration_to_time_ns` is the same sum with days included, for the callers
// that do want a uniform-day total.
fn int128 duration_time_part_ns(DurationParts d) {
    int128 ns = (int128)0;
    ns += (int128)d.hours   * NS_PER_HOUR;
    ns += (int128)d.minutes * NS_PER_MIN;
    ns += (int128)d.seconds * NS_PER_SEC;
    ns += (int128)d.ms      * NS_PER_MS;
    ns += (int128)d.us      * NS_PER_US;
    ns += (int128)d.ns;
    return ns;
}

fn int128 duration_to_time_ns(DurationParts d) {
    return (int128)d.days * NS_PER_DAY + duration_time_part_ns(d);
}

fn TemporalUnit default_largest_unit(DurationParts d) {
    if (d.years != 0)   return TemporalUnit.YEAR;
    if (d.months != 0)  return TemporalUnit.MONTH;
    if (d.weeks != 0)   return TemporalUnit.WEEK;
    if (d.days != 0)    return TemporalUnit.DAY;
    if (d.hours != 0)   return TemporalUnit.HOUR;
    if (d.minutes != 0) return TemporalUnit.MINUTE;
    if (d.seconds != 0) return TemporalUnit.SECOND;
    if (d.ms != 0)      return TemporalUnit.MILLISECOND;
    if (d.us != 0)      return TemporalUnit.MICROSECOND;
    return TemporalUnit.NANOSECOND;
}

// Split a signed nanosecond count across the time units from `largest` down to
// nanoseconds. Callers round to smallestUnit first, which leaves the units
// below it zero.
//
// Division truncates toward zero, so a negative count gives uniformly negative
// fields, as a Duration requires.
fn DurationParts time_ns_split(long v, TemporalUnit largest) {
    DurationParts dp = {};
    if (largest <= TemporalUnit.HOUR) {
        dp.hours = v / NS_PER_HOUR;
        v %= NS_PER_HOUR;
    }
    if (largest <= TemporalUnit.MINUTE) {
        dp.minutes = v / NS_PER_MIN;
        v %= NS_PER_MIN;
    }
    if (largest <= TemporalUnit.SECOND) {
        dp.seconds = v / NS_PER_SEC;
        v %= NS_PER_SEC;
    }
    if (largest <= TemporalUnit.MILLISECOND) {
        dp.ms = (double)(v / NS_PER_MS);
        v %= NS_PER_MS;
    }
    if (largest <= TemporalUnit.MICROSECOND) {
        dp.us = (double)(v / 1000L);
        v %= 1000L;
    }
    dp.ns = (double)v;
    return dp;
}

fn void decompose_ns(long ns, TemporalUnit largest, DurationParts* out) {
    long abs_ns = ns < 0 ? -ns : ns;
    long sign = ns < 0 ? -1 : 1;
    long rem = abs_ns;
    out.years = 0;
    out.months = 0;
    out.weeks = 0;
    out.days = 0;
    out.hours = 0;
    out.minutes = 0;
    out.seconds = 0;
    out.ms = 0;
    out.us = 0;
    out.ns = 0;
    if (largest == TemporalUnit.DAY) {
        out.days = sign * (long)(rem / NS_PER_DAY);
        rem %= NS_PER_DAY;
    } else if (largest == TemporalUnit.WEEK) {
        long total_days = (long)(rem / NS_PER_DAY);
        rem %= NS_PER_DAY;
        out.weeks = sign * (total_days / 7);
        out.days = sign * (total_days % 7);
    }
    // Decompose time units only down to largest_unit.
    if (largest <= TemporalUnit.HOUR) {
        out.hours = sign * (long)(rem / NS_PER_HOUR);
        rem %= NS_PER_HOUR;
    }
    if (largest <= TemporalUnit.MINUTE) {
        out.minutes = sign * (long)(rem / NS_PER_MIN);
        rem %= NS_PER_MIN;
    }
    if (largest <= TemporalUnit.SECOND) {
        out.seconds = sign * (long)(rem / NS_PER_SEC);
        rem %= NS_PER_SEC;
    }
    if (largest <= TemporalUnit.MILLISECOND) {
        out.ms = (double)(sign * (long)(rem / NS_PER_MS));
        rem %= NS_PER_MS;
    }
    if (largest <= TemporalUnit.MICROSECOND) {
        out.us = (double)(sign * (long)(rem / 1000L));
        rem %= 1000L;
    }
    out.ns = (double)(sign * (long)rem);
}

// The inverse of decompose_ns for values too large for int64 (any duration
// longer than ~292 years in nanoseconds). Like decompose_ns it walks the unit
// ladder from `largest` down; each field is ℝ(𝔽())-rounded and the middle
// int128 remainder avoids the 64-bit overflow that a `long` count would hit.
fn void decompose_ns_128(int128 ns, TemporalUnit largest, DurationParts* out) {
    long sign = ns < 0 ? -1 : 1;
    double sign_d = (double)sign;
    int128 rem = ns < 0 ? -ns : ns;
    out.years = 0;
    out.months = 0;
    out.weeks = 0;
    out.days = 0;
    out.hours = 0;
    out.minutes = 0;
    out.seconds = 0;
    out.ms = 0;
    out.us = 0;
    out.ns = 0;
    if (largest == TemporalUnit.DAY) {
        out.days = sign * (long)(rem / NS_PER_DAY);
        rem %= NS_PER_DAY;
    } else if (largest == TemporalUnit.WEEK) {
        int128 total_days = rem / NS_PER_DAY;
        rem %= NS_PER_DAY;
        out.weeks = sign * (long)(total_days / 7);
        out.days = sign * (long)(total_days % 7);
    }
    // Decompose time units only down to largest_unit.
    if (largest <= TemporalUnit.HOUR) {
        out.hours = sign * f64_field((long)(rem / NS_PER_HOUR));
        rem %= NS_PER_HOUR;
    }
    if (largest <= TemporalUnit.MINUTE) {
        out.minutes = sign * f64_field((long)(rem / NS_PER_MIN));
        rem %= NS_PER_MIN;
    }
    if (largest <= TemporalUnit.SECOND) {
        out.seconds = sign * f64_field((long)(rem / NS_PER_SEC));
        rem %= NS_PER_SEC;
    }
    // The largest field absorbs the full remaining magnitude once it's a
    // sub-second unit, which can exceed long's 63-bit range (e.g. ~8.7e21
    // microseconds, test262 precision-exact-in-balance-time-duration):
    // convert straight from int128 via ℝ(𝔽()) rather than routing through a
    // `long` that would silently wrap first.
    if (largest <= TemporalUnit.MILLISECOND) {
        out.ms = sign_d * (double)(rem / NS_PER_MS);
        rem %= NS_PER_MS;
    }
    if (largest <= TemporalUnit.MICROSECOND) {
        out.us = sign_d * (double)(rem / 1000L);
        rem %= 1000L;
    }
    out.ns = sign_d * (double)rem;
}

// Adds a duration's date part (years/months/weeks/days, with days folded in
// from time-only overflow) to `rel_date` and returns the total nanoseconds
// from `rel_date` (midnight) to the resulting date-time. Mirrors the
// relativeTo path of builtin_temporal_duration_proto_round.
fn bool duration_total_ns_from(CivilDate rel_date, DurationParts dur, int128* out) {
    int128 time_only_ns = duration_time_part_ns(dur);

    long target_time_days = (long)(time_only_ns / NS_PER_DAY);
    int128 target_time_rem = time_only_ns % NS_PER_DAY;
    if (time_only_ns < 0 && target_time_rem != 0) {
        target_time_days -= 1;
        target_time_rem += NS_PER_DAY;
    }

    long adj_days = dur.days + target_time_days;

    CivilDate target_date = rel_date;
    if (dur.years != 0) target_date = add_months(target_date, dur.years * 12, OverflowKind.CONSTRAIN);
    if (dur.months != 0) target_date = add_months(target_date, dur.months, OverflowKind.CONSTRAIN);
    if (dur.weeks != 0) target_date = add_days(target_date, dur.weeks * 7);
    if (adj_days != 0) target_date = add_days(target_date, adj_days);

    long rel_epoch = epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
    long tgt_epoch = epoch_days_from_civil(target_date.y, (int)target_date.m, (int)target_date.d);
    if (tgt_epoch > 100000000L || tgt_epoch < -100000000L) return false;
    *out = (int128)(tgt_epoch - rel_epoch) * NS_PER_DAY + target_time_rem;
    return true;
}

// Add two durations without relativeTo. Date fields sum; time fields are
// summed as a single nanosecond count and split back into days/hours/min/sec/
// ms/us/ns (1 day = 86 400 000 000 000 ns). The split-off days join the date
// sum. Years/months/weeks don't interact with each other in this code path,
// matching the spec's no-relativeTo behavior.
fn bool add_durations_no_relative(DurationParts a, DurationParts b, DurationParts* out) {
    // Sum date units directly; balance only happens within the time column.
    long y  = a.years   + b.years;
    long mo = a.months  + b.months;
    long w  = a.weeks   + b.weeks;
    long d  = a.days    + b.days;
    // Convert each time column to ns, sum, then split. The per-field sums
    // must widen to int128 before adding: two fields near LONG_MAX (the
    // spec allows ms/us/ns up to ~9e18 each) overflow a long sum.
    int128 total_ns = (int128)0;
    total_ns += ((int128)a.hours + (int128)b.hours)    * NS_PER_HOUR;
    total_ns += ((int128)a.minutes + (int128)b.minutes) *   NS_PER_MIN;
    total_ns += ((int128)a.seconds + (int128)b.seconds) *    NS_PER_SEC;
    total_ns += ((int128)a.ms + (int128)b.ms)           *       NS_PER_MS;
    total_ns += ((int128)a.us + (int128)b.us)           *          1000L;
    total_ns += (int128)a.ns + (int128)b.ns;
    // Per spec, IsValidDuration rejects any duration whose time column
    // (after balancing days into seconds) exceeds ±2^53 seconds. Year/month/week
    // units are unbounded in the spec — only their absolute value needs to
    // remain within int64. We validate only the time column here; caller is
    // responsible for year/month range.
    int128 days_secs = (int128)d * 86400L;
    int128 combined_secs = days_secs + total_ns / NS_PER_SEC;
    int128 max_secs = (int128)9007199254740992L;  // 2^53
    if (combined_secs >= max_secs || combined_secs <= -max_secs) {
        // Caller decides whether to throw — signal failure.
        return false;
    }
    // Spec AddDuration with no relativeTo: any calendar unit (years, months,
    // weeks) in either operand is a RangeError.
    bool no_calendar_units = (y == 0 && mo == 0 && w == 0 && a.years == 0
        && b.years == 0 && a.months == 0 && b.months == 0
        && a.weeks == 0 && b.weeks == 0);
    if (!no_calendar_units) return false;

    // BalanceTimeDuration(norm, largestUnit) with largestUnit = the larger of
    // the two operands' default largest units: the time total truncates toward
    // zero into whole units of largestUnit and the same-sign remainder fills
    // the columns below it, so {minutes:100,...} - {minutes:10,...} reports
    // 91m while P50DT50H + itself balances 100 of the 101 hours into days.
    TemporalUnit largest = default_largest_unit(a);
    TemporalUnit largest_b = default_largest_unit(b);
    if (largest_b < largest) largest = largest_b;

    // Spec TemporalDurationFromInternal produces the *unbalanced* form:
    // units strictly larger than `largestUnit` stay zero, and the time total
    // is broken into units from `largestUnit` down to nanoseconds. For
    // `largestUnit = "hour"`, hours = floor(time/3600e9) ns and the result
    // keeps the sub-day units intact (24h stays 24h, not 1d). For
    // `largestUnit = "microsecond"`, µs = floor(time/1000) and ns = time%1000,
    // which lets IsValidDuration's 𝔽→ℝ round-trip catch a 1e24-ish ns column
    // whose µs field rounds above the 10^9 * 2^53 threshold (test262
    // Duration/add result-out-of-range-3). Validate this unbalanced form
    // before returning, so an out-of-range result throws via the spec path.
    out.years = 0;
    out.months = 0;
    out.weeks = 0;
    out.days = d;
    out.hours = 0; out.minutes = 0; out.seconds = 0;
    out.ms = 0; out.us = 0; out.ns = 0;
    int128 rem = total_ns;
    if (largest <= TemporalUnit.DAY) {
        out.days += (long)(rem / NS_PER_DAY);
        rem %= NS_PER_DAY;
    }
    if (largest <= TemporalUnit.HOUR) {
        out.hours = (long)(rem / NS_PER_HOUR);
        rem %= NS_PER_HOUR;
    }
    if (largest <= TemporalUnit.MINUTE) {
        out.minutes = (long)(rem / NS_PER_MIN);
        rem %= NS_PER_MIN;
    }
    if (largest <= TemporalUnit.SECOND) {
        out.seconds = (long)(rem / NS_PER_SEC);
        rem %= NS_PER_SEC;
    }
    if (largest <= TemporalUnit.MILLISECOND) {
        out.ms = (double)(rem / NS_PER_MS);
        rem %= NS_PER_MS;
    }
    if (largest <= TemporalUnit.MICROSECOND) {
        out.us = (double)(rem / 1000L);
        rem %= 1000L;
    }
    out.ns = (double)rem;
    if (!is_valid_duration(out)) {
        // Caller decides whether to throw — signal failure.
        return false;
    }
    return true;
}

// The count held in `dp`'s smallestUnit field, not the difference folded into
// that unit. A roundingIncrement of 5 months under largestUnit "years" snaps
// the months within the year (2y8m -> 2y5m); under largestUnit "months" the
// whole span sits in the months field and snaps there (32m -> 30m).
fn long smallest_unit_count(DurationParts dp, TemporalUnit unit) {
    switch (unit) {
        case TemporalUnit.YEAR:  return dp.years;
        case TemporalUnit.MONTH: return dp.months;
        case TemporalUnit.WEEK:  return dp.weeks;
        default:                 return dp.days;
    }
}

// Set the count of `unit`, leaving the coarser components alone.
fn void set_smallest_unit_count(DurationParts* dp, TemporalUnit unit, long n) {
    switch (unit) {
        case TemporalUnit.YEAR:  dp.years = n; break;
        case TemporalUnit.MONTH: dp.months = n; break;
        case TemporalUnit.WEEK:  dp.weeks = n; break;
        default:                 dp.days = n; break;
    }
}

// Zero every component finer than `unit`; rounding to it leaves no remainder.
fn void clear_below(DurationParts* dp, TemporalUnit unit) {
    if (unit <= TemporalUnit.YEAR)  dp.months = 0;
    if (unit <= TemporalUnit.MONTH) dp.weeks = 0;
    if (unit <= TemporalUnit.WEEK)  dp.days = 0;
    dp.hours = 0; dp.minutes = 0; dp.seconds = 0;
    dp.ms = 0; dp.us = 0; dp.ns = 0;
}

// Advance a date by the date-level components of a Duration.
fn CivilDate apply_date_part(CivilDate d, DurationParts dp) {
    CivilDate r = d;
    long months = dp.years * 12 + dp.months;
    if (months != 0) r = add_months(r, months, OverflowKind.CONSTRAIN);
    return add_days(r, dp.weeks * 7 + dp.days);
}

fn long total_days_between(CivilDate a, CivilDate b) {
    return epoch_days_from_civil(b.y, (int)b.m, (int)b.d)
         - epoch_days_from_civil(a.y, (int)a.m, (int)a.d);
}

// Exact `num / div` rounded to the nearest double (ties to even). `div` must
// be positive; `num` may be negative, with the sign split off before the
// exact-magnitude division.
fn double divide_time_duration(int128 num, int128 div) {
    if (num == (int128)0) return 0.0;
    bool neg = num < (int128)0;
    int128 mag = neg ? -num : num;
    int128 d = div;
    int128 q = mag / d;
    int128 r = mag - q * d;
    double result;
    if (r == (int128)0) {
        result = (double)q;
    } else {
        int bits_q = bit_length_i128(q);
        int bits_r = bit_length_i128(r);
        int shift = 126 - (bits_q > bits_r ? bits_q : bits_r);
        if (shift < 1) shift = 1;
        int128 scaled_r = r << shift;
        int128 frac_q = scaled_r / d;
        int128 frac_r = scaled_r - frac_q * d;
        int128 combined = (q << shift) | frac_q;
        bool sticky = frac_r != (int128)0;
        int bits = bit_length_i128(combined);
        if (bits <= 53) {
            result = (double)combined / dtoa_pow2(shift);
        } else {
            int drop = bits - 53;
            int128 keep = combined >> drop;
            int128 rem = combined - (keep << drop);
            int128 half = (int128)1 << (drop - 1);
            bool round_up = rem > half ||
                (rem == half && (sticky || (keep & (int128)1) != (int128)0));
            if (round_up) keep += (int128)1;
            result = (double)keep * dtoa_pow2(drop - shift);
        }
    }
    return neg ? -result : result;
}

// DivideNormalizedTimeDuration(d, divisor): the spec divides the exact
// mathematical nanosecond total by divisor and converts to a Number in a
// single step (only one rounding, to nearest, ties-to-even). Neither
// `(double)num / (double)div` nor `whole + (double)rem / (double)div` matches
// that: the first rounds num to a double *before* dividing (losing precision
// once num exceeds 2^53, e.g. a >9e21ns total), and the second rounds the
// quotient and the remainder/div term separately, then adds two already-
// rounded doubles (wrong whenever the true fractional part sits near a
// halfway point between representable doubles, test262
// precision-exact-mathematical-values-6/7).
//
// This computes the quotient+remainder exactly in int128, then re-expands
// the remainder into `shift` extra fractional bits (also exact, since
// shifting and dividing integers loses nothing but a tracked sticky bit),
// giving a single fixed-point integer that carries every bit of `num/div`
// down to 2^-shift. Rounding that combined integer to 53 significant bits
// with round-half-to-even (using the sticky bit to break exact-half ties
// correctly) reproduces the one required rounding step.
//
// `shift` is chosen per call, not fixed, because a shift sized only for the
// quotient's magnitude can starve the fraction of precision when the result
// is small (a numerator as tiny as 1ns needs the shift to reach down near
// its own leading bit before 53 more bits of precision beyond it) — and the
// reverse fixed shift (large enough for tiny results) overflows int128 once
// the quotient itself is large. `shift` is capped by both operands' own bit
// widths so `quotient << shift` and `remainder << shift` each stay within
// int128's 127-bit magnitude: IsValidDuration bounds |num| to just under
// 2^53 * 10^9 (~2^83), and remainder is always < divisor (~2^47 at most, for
// days), so this never has to trade one operand's headroom for the other's.
fn int bit_length_i128(int128 v) {
    int bits = 0;
    int128 probe = v;
    while (probe != (int128)0) { probe >>= 1; bits++; }
    return bits;
}

// 2^n as a double, n in [-127, 127] for the exponents divide_time_duration needs.
fn double dtoa_pow2(int n) {
    if (n >= 0) return (double)((int128)1 << n);
    return 1.0 / (double)((int128)1 << (-n));
}

// ℝ(𝔽(x)): a Duration slot is a float64-representable number. The spec stores
// every component via this conversion in CreateTemporalDuration; below 2^53 it
// is the identity, and above it the value snaps to the nearest float64. That
// loss shows up only once a component exceeds 2^53 (a microseconds field for a
// 584-year since() is ~1.8e16), so a split carried out in exact int128 must
// round each field back through float64 to reproduce it.
fn long f64_field(long x) { return (long)(double)x; }
