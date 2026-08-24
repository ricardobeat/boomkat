// Civil-date arithmetic: proleptic Gregorian + ISO 8601 round-trip and the
// value-type primitives shared by Date and Temporal.
//
// This module is pure: it imports only std::* and boomkat::lib::bigmath (for
// Instant nanosecond arithmetic). No HObject, TVal, or BuiltinContext. The
// ECMAScript Date implementation lifts `civil_from_seconds` out of date.c3
// into here so Date and Temporal share one calendar implementation; the
// engine-specific wiring (double-precision ms, BuiltinContext, libc tz) stays
// in date.c3 and builtins/temporal.c3.
//
// Algorithms follow Howard Hinnant's days_from_civil / civil_from_days
// (http://howardhinnant.github.io/date_algorithms.html), which give a
// branch-free round-trip between y/m/d and epoch days across the full
// ECMAScript year range without relying on libc tzdata.
module boomkat::lib::temporal;

import std::math;

// ============================================================================
// Value types
// ============================================================================

// Proleptic Gregorian calendar date. `y` is the full year (signed long);
// `m` is 1-based (1=Jan, 12=Dec); `d` is 1-based (1..31). Use the validate
// helpers below before constructing from user input.
struct CivilDate {
    long y;
    int  m;
    int  d;
}

// Wall-clock time-of-day with sub-second precision. Fields are zero on
// absence; nanosecond resolution spans [0, 999_999_999].
struct CivilTime {
    int h;
    int mi;
    int s;
    int ms;
    int us;
    int ns;
}

// Composed date + time. Always carries both; for date-only or time-only
// Temporal types the absent half is zero (PlainDate) or year=1 (PlainTime).
struct CivilDateTime {
    CivilDate date;
    CivilTime time;
}

// Returned by `civil_from_seconds`. `wday` is 0-based with 0=Sunday, matching
// the existing Date convention so Date and Temporal agree on day-of-week
// arithmetic without translation.
struct BrokenDownTime {
    long y;
    int  m;     // 0-based (0=Jan, 11=Dec)
    int  d;
    int  wday;  // 0=Sunday
    int  h;
    int  mi;
    int  s;
}

// Calendar arithmetic overflow policy. REJECT means the constructor /
// arithmetic throws a RangeError when the result would be out of range;
// CONSTRAIN clamps day-of-month to the last valid day of the resulting
// month. Spec terminology from TemporalOptions.
enum OverflowKind : int {
    REJECT,
    CONSTRAIN,
}

// Result of difference_date / Temporal.PlainDate.prototype.until with the
// largestUnit = "days" or finer — years / months / days carry independent
// signs, matching the polyfill spec's "DifferenceDate" algorithm.
struct DateDifference {
    long years;
    long months;
    long days;
}

// ============================================================================
// Validation
// ============================================================================

// Temporal's date-level bounds (ES2025 Temporal, ISO calendar "IsValidISODate"):
// the proleptic Gregorian range whose epoch-day count stays within ±100,000,000
// days of the Unix epoch. -271821-04-19 and +275760-09-13 are the inclusive
// lower and upper edges.
const long ISO_DATE_MIN_YEAR  = -271821;
const int  ISO_DATE_MIN_MONTH = 4;
const int  ISO_DATE_MIN_DAY   = 19;
const long ISO_DATE_MAX_YEAR  = 275760;
const int  ISO_DATE_MAX_MONTH = 9;
const int  ISO_DATE_MAX_DAY   = 13;

// True if y/m/d is a valid proleptic Gregorian calendar date within the
// Temporal range. Out-of-range inputs (month 13, day 31 of February, dates
// outside -271821-04-19 .. +275760-09-13) return false. Negative years are
// valid ISO 8601 extended years.
fn bool is_valid_iso_date(long y, int m, int d) {
    if (m < 1 || m > 12) return false;
    if (d < 1) return false;
    if (y < ISO_DATE_MIN_YEAR || y > ISO_DATE_MAX_YEAR) return false;
    if (y == ISO_DATE_MIN_YEAR && (m < ISO_DATE_MIN_MONTH ||
        (m == ISO_DATE_MIN_MONTH && d < ISO_DATE_MIN_DAY))) return false;
    if (y == ISO_DATE_MAX_YEAR && (m > ISO_DATE_MAX_MONTH ||
        (m == ISO_DATE_MAX_MONTH && d > ISO_DATE_MAX_DAY))) return false;
    // Days in month for proleptic Gregorian. February gets 29 days so leap
    // years can be detected by `is_leap_year` below.
    int dim;
    switch (m) {
        case 1:
        case 3:
        case 5:
        case 7:
        case 8:
        case 10:
        case 12: dim = 31; break;
        case 4:
        case 6:
        case 9:
        case 11: dim = 30; break;
        case 2:  dim = 29; break;
        default: return false;
    }
    if (d > dim) return false;
    // Feb 29 only valid in a leap year.
    if (m == 2 && d == 29 && !is_leap_year(y)) return false;
    return true;
}

// Proleptic Gregorian leap year: divisible by 4, except divisible by 100,
// unless divisible by 400. Holds for negative years via the same rule
// (Hinnant's convention).
fn bool is_leap_year(long y) {
    return ((y % 4 == 0) & (y % 100 != 0)) | (y % 400 == 0);
}

// ============================================================================
// Epoch days <-> civil date
// ============================================================================

// Inverse of civil_from_days (Hinnant). Converts proleptic Gregorian y/m/d
// to epoch days since 1970-01-01 (Unix epoch). Branch-free for the common
// case; the negative-year adjustment is one ternary.
//
// `m` is 1-based (1=Jan, 12=Dec); `d` is 1-based (1..31). Out-of-range
// inputs produce mathematically defined but unspecified results; callers
// must validate first via is_valid_iso_date.
fn long epoch_days_from_civil(long y, int m, int d) {
    long y2 = m <= 2 ? y - 1 : y;
    long era = (y2 >= 0 ? y2 : y2 - 399) / 400;
    long yoe = y2 - era * 400;
    long doy = (153L * (long)(m > 2 ? m - 3 : m + 9) + 2) / 5 + (long)d - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

// Forward direction: epoch days -> proleptic Gregorian y/m/d. Inverse of
// epoch_days_from_civil. 1-based month out (1=Jan), 1-based day out (1..31).
fn CivilDate civil_date_from_epoch_days(long days) {
    // days-from-civil, inverted (Hinnant). Shift epoch to 0000-03-01.
    long z = days + 719468;
    long era = (z >= 0 ? z : z - 146096) / 146097;
    long doe = z - era * 146097;                       // [0, 146096]
    long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;  // [0, 399]
    long y = yoe + era * 400;
    long doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    long mp = (5 * doy + 2) / 153;                      // [0, 11] (Mar=0)
    long d = doy - (153 * mp + 2) / 5 + 1;              // [1, 31]
    long m = mp < 10 ? mp + 3 : mp - 9;                 // [1, 12]
    return {
        .y = y + (m <= 2 ? 1 : 0),
        .m = (int)(m - 1) + 1,                          // to 1-based (1=Jan)
        .d = (int)d,
    };
}

// ============================================================================
// Epoch seconds -> broken-down wall time (UTC)
// ============================================================================

// Convert Unix epoch seconds (since 1970-01-01 UTC, may be negative) into
// proleptic-Gregorian UTC broken-down fields. Pure integer calendar math
// (Hinnant's days-from-civil), reliable across the full ECMAScript year
// range without libc tzdata.
//
// `m` is 0-based (0=Jan) and `wday` is 0-based (0=Sunday) — same convention
// the previous Date implementation used so Date and Temporal agree without
// translation. Floors toward -infinity on negative epoch values, so -1s
// lands on 1969-12-31 23:59:59, not 1970-01-01 00:00:00.
fn BrokenDownTime civil_from_seconds(long secs) {
    BrokenDownTime r;

    // Split into whole days and the second-of-day, flooring toward -inf so
    // negative epoch times land on the correct civil day.
    long days = secs / 86400;
    long rem  = secs % 86400;
    if (rem < 0) { rem += 86400; days -= 1; }

    r.h   = (int)(rem / 3600);
    r.mi  = (int)((rem % 3600) / 60);
    r.s   = (int)(rem % 60);

    // Day of week: 1970-01-01 was a Thursday (4). Euclidean mod keeps it 0..6.
    long w = (days % 7 + 4) % 7;
    if (w < 0) { w += 7; }
    r.wday = (int)w;

    CivilDate d = civil_date_from_epoch_days(days);
    r.y = d.y;
    r.m = d.m - 1;                                     // to 0-based (0=Jan)
    r.d = d.d;
    return r;
}

// ============================================================================
// Milliseconds / seconds field math
// ============================================================================

// Convert an epoch time value in milliseconds to whole seconds, flooring
// toward -infinity (not truncating toward zero) so negative time values
// land on the correct second, e.g. -1ms is second -1, not second 0.
fn long ms_to_sec_floor(double time_val) {
    return (long)math::floor(time_val / 1000.0);
}

// Floor-divide an epoch ms time value by `unit_ms` and reduce modulo
// `modulus`, both flooring toward -infinity. Plain C `/` and `%` truncate
// toward zero, which silently skips the "was this negative" fixup for
// values like -1ms (truncates to 0 instead of flooring to -1).
fn long floor_mod_field(double time_val, long unit_ms, long modulus) {
    long q = (long)math::floor(time_val / (double)unit_ms);
    long r = q % modulus;
    if (r < 0) r += modulus;
    return r;
}
