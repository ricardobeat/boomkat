// Civil-date arithmetic: proleptic Gregorian and ISO 8601 round-trips, and the
// value types shared by Date and Temporal. Engine types and libc tz stay out of
// this module; the wiring lives in date.c3 and builtins/temporal.c3.
//
// Date conversions use Howard Hinnant's days_from_civil / civil_from_days
// (http://howardhinnant.github.io/date_algorithms.html): branch-free, covering
// the full ECMAScript year range without libc tzdata.
module boomkat::lib::temporal;

import std::math;

// ============================================================================
// Value types
// ============================================================================

// Proleptic Gregorian calendar date. `y` is the full year (signed long);
// `m` is 1-based (1=Jan, 12=Dec); `d` is 1-based (1..31). `m` and `d` are long
// to match the CivilTime fields. Validate user input before constructing one.
struct CivilDate {
    long y;
    long m;
    long d;
}

fn long CivilDate.epoch_days(self) @inline => epoch_days_from_civil(self.y, (int)self.m, (int)self.d);

// Wall-clock time of day. Absent fields are zero; ns is in [0, 999_999_999].
// Fields are long so intermediates like `epoch_seconds + offset` cannot
// overflow at the spec boundary values.
struct CivilTime {
    long h;
    long mi;
    long s;
    long ms;
    long us;
    long ns;
}

// Composed date + time. Always carries both; for date-only or time-only
// Temporal types the absent half is zero (PlainDate) or year=1 (PlainTime).
struct CivilDateTime {
    CivilDate date;
    CivilTime time;
}

// Returned by `civil_from_seconds`. `wday` is 0-based with 0=Sunday, as in Date.
struct BrokenDownTime {
    long y;
    long m;     // 0-based (0=Jan, 11=Dec)
    long d;
    int  wday;  // 0=Sunday
    int  h;
    int  mi;
    int  s;
}

// Overflow option of Temporal. REJECT throws a RangeError when the result is out
// of range; CONSTRAIN clamps the day to the last valid day of the month.
enum OverflowKind : int {
    REJECT,
    CONSTRAIN,
}

// Result of difference_date. years, months and days carry independent signs, as
// in the polyfill's DifferenceDate.
struct DateDifference {
    long years;
    long months;
    long days;
}

// ============================================================================
// Validation
// ============================================================================

// Temporal's date-level bounds (IsValidISODate): epoch days within ±100,000,000
// of the Unix epoch. -271821-04-19 and +275760-09-13 are the inclusive edges.
const long ISO_DATE_MIN_YEAR  = -271821;
const int  ISO_DATE_MIN_MONTH = 4;
const int  ISO_DATE_MIN_DAY   = 19;
const long ISO_DATE_MAX_YEAR  = 275760;
const int  ISO_DATE_MAX_MONTH = 9;
const int  ISO_DATE_MAX_DAY   = 13;

// True if y/m is a valid year-month within the Temporal representable range.
// Used by PlainYearMonth and PlainMonthDay where the day is not yet known.
fn bool is_valid_iso_yearmonth(long y, int m) {
    if (m < 1 || m > 12) return false;
    if (y < ISO_DATE_MIN_YEAR || y > ISO_DATE_MAX_YEAR) return false;
    if (y == ISO_DATE_MIN_YEAR && m < ISO_DATE_MIN_MONTH) return false;
    if (y == ISO_DATE_MAX_YEAR && m > ISO_DATE_MAX_MONTH) return false;
    return true;
}

// True if the date+time falls within the PlainDateTime representable range.
// The boundaries are exclusive at midnight: -271821-04-19T00:00:00.000000000
// and +275760-09-14T00:00:00.000000000 are outside the range.
fn bool is_valid_plain_datetime(long y, int m, int d, int h, int mi, int s, int ms, int us, int ns) {
    if (!is_valid_iso_date(y, m, d)) return false;
    if (!is_valid_time(h, mi, s, ms, us, ns)) return false;
    // At the lower boundary, midnight (all-zero time) is excluded.
    if (y == ISO_DATE_MIN_YEAR && m == ISO_DATE_MIN_MONTH && d == ISO_DATE_MIN_DAY) {
        if (h == 0 && mi == 0 && s == 0 && ms == 0 && us == 0 && ns == 0) return false;
    }
    return true;
}

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
    // days_in_month already yields 29/28 for February by the leap year, so a
    // day past the month's length (including Feb 29 in a common year) fails.
    if (d > days_in_month(y, m)) return false;
    return true;
}

// Proleptic Gregorian leap year: divisible by 4, except by 100 unless also by 400.
fn bool is_leap_year(long y) {
    return ((y % 4 == 0) & (y % 100 != 0)) | (y % 400 == 0);
}

// ============================================================================
// Epoch days <-> civil date
// ============================================================================

// Proleptic Gregorian y/m/d (m and d 1-based) to epoch days since 1970-01-01.
// Out-of-range inputs give unspecified results; validate with is_valid_iso_date first.
fn long epoch_days_from_civil(long y, int m, int d) {
    long y2 = m <= 2 ? y - 1 : y;
    long era = (y2 >= 0 ? y2 : y2 - 399) / 400;
    long yoe = y2 - era * 400;
    long doy = (153L * (long)(m > 2 ? m - 3 : m + 9) + 2) / 5 + (long)d - 1;
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

// Epoch days to proleptic Gregorian y/m/d, with 1-based month and day.
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
        .m = (m - 1) + 1,                          // to 1-based (1=Jan)
        .d = d,
    };
}

// ============================================================================
// Epoch seconds -> broken-down wall time (UTC)
// ============================================================================

// Unix epoch seconds (may be negative) to UTC broken-down fields. `m` is 0-based
// (0=Jan) and `wday` is 0-based (0=Sunday), as in Date. Floors toward -infinity,
// so -1s is 1969-12-31 23:59:59.
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

// Epoch milliseconds to whole seconds, flooring toward -infinity: -1ms is second -1.
fn long ms_to_sec_floor(double time_val) {
    return (long)math::floor(time_val / 1000.0);
}

// Floor-divide epoch milliseconds by `unit_ms`, then reduce modulo `modulus`.
// Both steps floor toward -infinity; C `/` and `%` would truncate -1ms to 0.
fn long floor_mod_field(double time_val, long unit_ms, long modulus) {
    long q = (long)math::floor(time_val / (double)unit_ms);
    long r = q % modulus;
    if (r < 0) r += modulus;
    return r;
}

// ============================================================================
// CivilTime validation + arithmetic
// ============================================================================

// True if h/mi/s/ms/us/ns is a valid wall-clock time (IsValidTime): h in [0, 23],
// mi in [0, 59], s in [0, 60], and the sub-second fields total under 1_000_000_000.
// Callers collapse a leap second to 59. "24:00" is not valid here; parse_iso_date_string
// turns it into 00:00 of the next day first.
fn bool is_valid_time(int h, int mi, int s, int ms, int us, int ns) {
    if (h  < 0 || h  > 23) return false;
    if (mi < 0 || mi > 59) return false;
    if (s  < 0 || s  > 60) return false;
    if (ms < 0 || ms > 999) return false;
    if (us < 0 || us > 999) return false;
    if (ns < 0 || ns > 999) return false;
    if (s == 60 && (ms != 0 || us != 0 || ns != 0)) return false;
    return true;
}

// IsValidISODateTime: a valid date in the Temporal range and a valid time.
fn bool is_valid_iso_datetime(long y, long m, long d, long h, long mi, long s, long ms, long us, long ns) {
    if (m < 1 || m > 12 || d < 1 || d > 31) return false;
    if (h < 0 || h > 23 || mi < 0 || mi > 59 || s < 0 || s > 59 || ms < 0 || ms > 999 || us < 0 || us > 999 || ns < 0 || ns > 999) return false;
    if (!is_valid_iso_date(y, (int)m, (int)d)) return false;
    if (!is_valid_time((int)h, (int)mi, (int)s, (int)ms, (int)us, (int)ns)) return false;
    // The boundary is exclusive at midnight: the lower edge date's all-zero
    // time is outside the PlainDateTime range (its instant is below NS_MIN).
    if (m == ISO_DATE_MIN_MONTH && d == ISO_DATE_MIN_DAY && y == ISO_DATE_MIN_YEAR) {
        if (h == 0 && mi == 0 && s == 0 && ms == 0 && us == 0 && ns == 0) return false;
    }
    return true;
}

// True when `d` is representable as an Instant at midnight. Stricter than
// IsValidISODate on the negative side: the ISO range is asymmetric, but the
// Instant range is +/-1e8 days. -271821-04-19 is a valid ISO date whose epoch
// ns fall below the Instant minimum.
fn bool is_instant_representable_date(CivilDate d) {
    return epoch_days_in_range(epoch_days_from_civil(d.y, (int)d.m, (int)d.d));
}

// Add `seconds` (may be negative) to a CivilTime, wrapping midnight. `out_day_delta`
// receives the whole days carried (negative when rewinding). ms/us/ns pass through unchanged.
fn CivilTime add_seconds_to_time(CivilTime t, long seconds, long* out_day_delta) {
    long total = (long)t.h * 3600 + (long)t.mi * 60 + (long)t.s + seconds;
    long day = total / 86400;
    long rem = total % 86400;
    if (rem < 0) { rem += 86400; day -= 1; }
    *out_day_delta = day;
    return {
        .h  = (int)(rem / 3600),
        .mi = (int)((rem % 3600) / 60),
        .s  = (int)(rem % 60),
        .ms = t.ms,
        .us = t.us,
        .ns = t.ns,
    };
}

// Difference b - a in whole seconds, treating both as times on the same day.
// Sub-seconds are dropped; rounding happens in the prototype methods.
fn long diff_seconds(CivilTime a, CivilTime b) {
    return ((long)b.h  - (long)a.h ) * 3600
         + ((long)b.mi - (long)a.mi) * 60
         +  (long)b.s  - (long)a.s;
}

// Equality on CivilTime, including sub-seconds.
fn bool time_equals(CivilTime a, CivilTime b) {
    return a.h  == b.h  && a.mi == b.mi && a.s  == b.s
        && a.ms == b.ms && a.us == b.us && a.ns == b.ns;
}

// Compare two times: -1, 0 or +1. Sub-seconds break ties.
fn int time_compare(CivilTime a, CivilTime b) {
    if (a.h  != b.h ) return a.h  < b.h  ? -1 : 1;
    if (a.mi != b.mi) return a.mi < b.mi ? -1 : 1;
    if (a.s  != b.s ) return a.s  < b.s  ? -1 : 1;
    if (a.ms != b.ms) return a.ms < b.ms ? -1 : 1;
    if (a.us != b.us) return a.us < b.us ? -1 : 1;
    if (a.ns != b.ns) return a.ns < b.ns ? -1 : 1;
    return 0;
}

// ---- Time-of-day helpers used by the Temporal bindings ----

// Inverse of civil_time_to_ns; the input must lie in [0, day).
fn CivilTime civil_time_from_ns(long total) {
    CivilTime t;
    t.h  = total / 3600000000000L; total %= 3600000000000L;
    t.mi = total /   60000000000L; total %=   60000000000L;
    t.s  = total /    1000000000L; total %=    1000000000L;
    t.ms = total /       1000000L; total %=       1000000L;
    t.us = total /          1000L;
    t.ns = total %          1000L;
    return t;
}

fn long civil_time_to_ns(CivilTime t) {
    return ((long)t.h * 3600 + (long)t.mi * 60 + (long)t.s) * 1_000_000_000L
         + (long)t.ms * 1_000_000L + (long)t.us * 1000L + (long)t.ns;
}

// RegulateTime with constrain: clamps each field into range instead of rejecting.
// A second of 60 collapses to 59, as in fields_to_valid_time.
fn CivilTime regulate_time_constrain(CivilTime f) {
    CivilTime v = f;
    if (v.h < 0) { v.h = 0; } else if (v.h > 23) { v.h = 23; }
    if (v.mi < 0) { v.mi = 0; } else if (v.mi > 59) { v.mi = 59; }
    if (v.s < 0) { v.s = 0; } else if (v.s > 59) { v.s = 59; }
    if (v.ms < 0) { v.ms = 0; } else if (v.ms > 999) { v.ms = 999; }
    if (v.us < 0) { v.us = 0; } else if (v.us > 999) { v.us = 999; }
    if (v.ns < 0) { v.ns = 0; } else if (v.ns > 999) { v.ns = 999; }
    return v;
}

// The ISO day of the week of a day: Monday is 1, Sunday 7 (1970-01-01 was a Thursday).
fn long iso_day_of_week(long epoch_days) {
    long r = (epoch_days + 3) % 7;
    return (r < 0 ? r + 7 : r) + 1;
}

// ISO 8601: a year has 53 weeks iff it starts on a Thursday, or on a Wednesday in a leap year.
fn long iso_weeks_in_year(long year) {
    long jan1 = iso_day_of_week(epoch_days_from_civil(year, 1, 1));
    return jan1 == 4 || (jan1 == 3 && is_leap_year(year)) ? 53 : 52;
}

// The ISO 8601 week of a date, and the week-numbering year it belongs to.
fn long iso_week_of_year(CivilDate d, long* week_year) {
    long days = epoch_days_from_civil(d.y, (int)d.m, (int)d.d);
    long week = (days - epoch_days_from_civil(d.y, 1, 1) + 1 - iso_day_of_week(days) + 10) / 7;
    *week_year = d.y;
    if (week < 1) {
        *week_year = d.y - 1;
        return iso_weeks_in_year(d.y - 1);
    }
    if (week > iso_weeks_in_year(d.y)) {
        *week_year = d.y + 1;
        return 1;
    }
    return week;
}
