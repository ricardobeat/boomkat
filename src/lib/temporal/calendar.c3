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

// Days in the given proleptic Gregorian month. February returns 29 so
// leap-year validation is the caller's responsibility (see is_leap_year in
// civil.c3). `m` is 1-based.
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
        case 2:  return 29;
        default: return 0;
    }
}

// ============================================================================
// Date arithmetic
// ============================================================================

// Add `days` to a date. Purely arithmetic; the caller validates range.
fn CivilDate add_days(CivilDate d, long days) {
    return civil_date_from_epoch_days(epoch_days_from_civil(d.y, d.m, d.d) + days);
}

// Add `months` to a date, clamping the day-of-month to the end of the result
// month (Jan 31 + 1 month -> Feb 28/29). Year/month step is the ISO calendar's
// addIsoMonths: truncating div/mod then re-normalizing to 1..12, which carries
// negative deltas across year boundaries correctly (2020-01 minus 1 month ->
// 2019-12). REJECT callers pre-validate; this function always clamps.
fn CivilDate add_months(CivilDate d, long months, OverflowKind overflow) {
    long new_year = d.y + months / 12;
    long new_month = (long)d.m + months % 12;
    if (new_month < 1)  { new_year -= 1; new_month += 12; }
    else if (new_month > 12) { new_year += 1; new_month -= 12; }
    int dim = days_in_month(new_year, (int)new_month);
    int new_day = d.d;
    if (new_day > dim) new_day = dim;
    return { .y = new_year, .m = (int)new_month, .d = new_day };
}

// Largest unit for difference_date, mirroring the polyfill's diffCalendarDates:
// DAYS and WEEKS reduce to a whole epoch-day count; MONTHS and YEARS are
// calendar-slot arithmetic with the day borrow rules.
enum DifferenceUnit : int {
    DAYS,
    WEEKS,
    MONTHS,
    YEARS,
}

fn long diff_sign(CivilDate a, CivilDate b) {
    if (a.y != b.y) return a.y < b.y ? 1 : -1;
    if (a.m != b.m) return a.m < b.m ? 1 : -1;
    long da = epoch_days_from_civil(a.y, a.m, a.d);
    long db = epoch_days_from_civil(b.y, b.m, b.d);
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

    long start_days = epoch_days_from_civil(start.y, start.m, start.d);
    long end_days   = epoch_days_from_civil(end.y, end.m, end.d);
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
        // Back off a month if the anchor overshot the end. diffMonthSlots and
        // addMonths are exact inverses for the ISO calendar, so that only
        // happens on the day: Jan 31 -> Feb 28 is zero whole months + 3 days,
        // not 1 month minus 1 day.
        if (sign * (long)(start.d - end.d) > 0) {
            months -= sign;
            anchor = add_months(start, months, OverflowKind.CONSTRAIN);
        }
        r.months = months;
        r.days = end_days - epoch_days_from_civil(anchor.y, anchor.m, anchor.d);
        return r;
    }

    // largestUnit YEARS
    long y0 = start.y;
    long m0 = start.m;
    long d0 = start.d;
    long y1 = end.y;
    long m1 = end.m;
    long d1 = end.d;
    long year_diff = y1 - y0;
    long month_diff = m1 - m0;
    long day_diff = d1 - d0;

    if (year_diff != 0 || month_diff != 0) {
        long sign = year_diff != 0 ? (year_diff > 0 ? 1 : -1) : (month_diff > 0 ? 1 : -1);
        long dim1 = days_in_month(y1, (int)m1);
        long day_correct = 0;
        // A day that has already receded into the previous month is not a
        // whole month earned. Re-anchor the end one month back and widen the
        // day remainder by that month's length.
        if ((day_diff > 0 ? 1 : -1) == -sign) {
            long orig_dim = dim1;
            long ny = y1 + (-sign) / 12;
            long nm = m1 + (-sign) % 12;
            if (nm < 1)  { ny -= 1; nm += 12; }
            else if (nm > 12) { ny += 1; nm -= 12; }
            y1 = ny;
            m1 = nm;
            year_diff = y1 - y0;
            month_diff = m1 - m0;
            dim1 = days_in_month(y1, (int)m1);
            day_correct = sign < 0 ? -orig_dim : dim1;
        }
        long d0_trunc = d0 < dim1 ? d0 : dim1;
        day_diff = d1 - d0_trunc + day_correct;

        if (year_diff != 0) {
            month_diff = m1 - m0;
            if ((month_diff > 0 ? 1 : -1) == -sign) {
                long month_correct = sign < 0 ? -12 : 12;
                y1 -= sign;
                year_diff = y1 - y0;
                month_diff = m1 - m0 + month_correct;
            }
        }
    }

    r.years = year_diff;
    r.months = month_diff;
    r.days = day_diff;
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
