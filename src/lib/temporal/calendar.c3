// Proleptic Gregorian calendar arithmetic: add/subtract days, months, years
// from a CivilDate, compute the difference between two dates as years+months+
// days, and detect calendar singularities (end-of-month clamping).
//
// Pure: imports only stdlib and boomkat::lib::temporal (for the value types).
// The polyfill spec (fullcalendar/temporal-polyfill) gives the algorithm
// under "Balancing Arithmetic in Calendar Arithmetic"; Hinnant's
// days_from_civil handles the days count.
module boomkat::lib::temporal;

import std::math;

// ============================================================================
// Days-in-month lookup
// ============================================================================

// Days in the given proleptic Gregorian month of `y`. February returns 29 in
// a leap year and 28 otherwise, so the result is always a valid day count for
// that year. `m` is 1-based.
fn int days_in_month(long y, int m) {
    switch (m) {
        case 1:
        case 3:
        case 5:
        case 7:
        case 8:
        case 10:
        case 12: return 31;
        case 4:
        case 6:
        case 9:
        case 11: return 30;
        case 2:  return is_leap_year(y) ? 29 : 28;
        default: return 0;
    }
}

// ============================================================================
// Date arithmetic
// ============================================================================

// Add `days` to a date. Purely arithmetic; the caller validates range.
fn CivilDate add_days(CivilDate d, long days) {
    return civil_date_from_epoch_days(epoch_days_from_civil(d.y, (int)d.m, (int)d.d) + days);
}

// Add `months` to a date, clamping the day-of-month to the end of the result
// month (Jan 31 + 1 month -> Feb 28/29). Year/month step is the ISO calendar's
// addIsoMonths: years += months/12 (truncating toward 0) and months += months%12,
// then normalize month into 1..12, carrying the year. This matches the polyfill's
// iso8601 dateAdd, which composes years and months as separate fields and
// normalizes after, rather than the spec's floor() decomposition; the difference
// is one year for negative month spans that don't divide 12. REJECT callers
// pre-validate; this function always clamps.
fn CivilDate add_months(CivilDate d, long months, OverflowKind overflow) {
    long new_year = d.y + months / 12;
    long new_month = (long)d.m + months % 12;
    if (new_month < 1)  { new_year -= 1; new_month += 12; }
    else if (new_month > 12) { new_year += 1; new_month -= 12; }
    int dim = days_in_month(new_year, (int)new_month);
    int new_day = (int)d.d;
    if (new_day > dim) new_day = dim;
    return { .y = new_year, .m = (long)new_month, .d = (long)new_day };
}

// Largest unit for difference_date, mirroring the polyfill's diffCalendarDates:
// DAYS and WEEKS reduce to a whole epoch-day count; MONTHS and YEARS are
// calendar-slot arithmetic with the day borrow rules.
enum DifferenceUnit : int {
    SECONDS,
    MINUTES,
    HOURS,
    DAYS,
    WEEKS,
    MONTHS,
    YEARS,
}

fn long diff_sign(CivilDate a, CivilDate b) {
    if (a.y != b.y) return a.y < b.y ? 1 : -1;
    if (a.m != b.m) return a.m < b.m ? 1 : -1;
    long da = epoch_days_from_civil(a.y, (int)a.m, (int)a.d);
    long db = epoch_days_from_civil(b.y, (int)b.m, (int)b.d);
    if (da != db) return da < db ? 1 : -1;
    return 0;
}

// Difference end - start as years/months/days per `unit`. Port of the
// polyfill's diffCalendarDates for the ISO calendar (monthCodeNumber == month,
// no leap months, 12 months per year). For WEEKS the caller splits the day
// count into whole weeks (truncating div/mod) — both sides of that split are
// the same sign, matching diffCalendarDates' divTrunc/modTrunc.
fn DateDifference difference_date(CivilDate start, CivilDate end, DifferenceUnit unit) {
    DateDifference r;
    r.years = 0;
    r.months = 0;
    r.days = 0;

    long start_days = epoch_days_from_civil(start.y, (int)start.m, (int)start.d);
    long end_days   = epoch_days_from_civil(end.y, (int)end.m, (int)end.d);
    long days = end_days - start_days;
    if (days == 0) return r;

    if (unit == DifferenceUnit.DAYS || unit == DifferenceUnit.WEEKS) {
        r.days = days;
        return r;
    }

    if (unit == DifferenceUnit.MONTHS) {
        long sign = diff_sign(start, end);
        long months = (end.y - start.y) * 12 + (long)(end.m - start.m);
        CivilDate anchor = add_months(start, months, OverflowKind.CONSTRAIN);
        // Back off a month if the anchor overshot the end. Compare anchor
        // against end by epoch days, not start.d vs end.d — when the anchor
        // day was CONSTRAINED (Jan31+1m→Feb29), start.d > end.d is true
        // even though anchor == end.
        if (sign * (epoch_days_from_civil(anchor.y, (int)anchor.m, (int)anchor.d) - end_days) > 0) {
            months -= sign;
            anchor = add_months(start, months, OverflowKind.CONSTRAIN);
        }
        r.months = months;
        r.days = end_days - epoch_days_from_civil(anchor.y, (int)anchor.m, (int)anchor.d);
        return r;
    }

    // largestUnit YEARS — same anchor approach as MONTHS, then split into
    // years and remaining months.
    long sign = diff_sign(start, end);
    long all_months = (end.y - start.y) * 12 + (end.m - start.m);
    CivilDate anchor = add_months(start, all_months, OverflowKind.CONSTRAIN);
    long a_days = epoch_days_from_civil(anchor.y, (int)anchor.m, (int)anchor.d);
    if (sign != 0 && sign * (a_days - end_days) > 0) {
        all_months -= sign;
        anchor = add_months(start, all_months, OverflowKind.CONSTRAIN);
        a_days = epoch_days_from_civil(anchor.y, (int)anchor.m, (int)anchor.d);
    }
    r.years = all_months / 12;
    r.months = all_months % 12;
    r.days = end_days - a_days;
    return r;
}

// True iff the two dates fall on the same civil day.
fn bool date_equals(CivilDate a, CivilDate b) {
    return a.y == b.y && a.m == b.m && a.d == b.d;
}

// Three-way comparison in {-1, 0, 1}.
fn int date_compare(CivilDate a, CivilDate b) {
    if (a.y != b.y)  return a.y < b.y ? -1 : 1;
    if (a.m != b.m)  return a.m < b.m ? -1 : 1;
    if (a.d != b.d)  return a.d < b.d ? -1 : 1;
    return 0;
}
