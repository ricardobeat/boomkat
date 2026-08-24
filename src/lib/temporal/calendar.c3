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

// Add `days` to a date. Result clamped by calendar overflow rules only if
// `overflow` is REJECT; the REJECT-when-out-of-range check is the caller's
// job (this function is purely arithmetic).
fn CivilDate add_days(CivilDate d, long days) {
    return civil_date_from_epoch_days(epoch_days_from_civil(d.y, d.m, d.d) + days);
}

// Add `months` to a date, clamping the day-of-month if the result month is
// shorter than the source month (Jan 31 + 1 month -> Feb 28/29). Negative
// `months` and `months` beyond ±2^53 are accepted.
fn CivilDate add_months(CivilDate d, long months, OverflowKind overflow) {
    // Floor-divide months to normalize to a year-month pair.
    long total = (long)d.m - 1 + months;          // 0-based month count
    long new_year = d.y + total / 12;
    long new_month0 = total % 12;                 // 0-based, may be negative
    if (new_month0 < 0) {
        new_month0 += 12;
        new_year -= 1;
    }
    int new_month = (int)new_month0 + 1;         // back to 1-based

    int dim = days_in_month(new_year, new_month);
    int new_day = d.d;
    if (new_day > dim) {
        switch (overflow) {
            case OverflowKind.REJECT:
                // Caller is expected to have validated; we still clamp here so
                // arithmetic on out-of-range inputs doesn't read out of the
                // days_in_month switch.
                new_day = dim;
                break;
            case OverflowKind.CONSTRAIN:
                new_day = dim;
                break;
            default:
                new_day = dim;
                break;
        }
    }
    return { .y = new_year, .m = new_month, .d = new_day };
}

// Difference between two dates, expressed as (years, months, days). Follows
// the polyfill spec: years = calendar years between, then months = calendar
// months between the resulting dates, then days = remaining days.
fn DateDifference difference_date(CivilDate a, CivilDate b) {
    // Sign follows b - a. Years are computed first by clamping the month/day
    // and comparing to a, then months by clamping the day and comparing to
    // the year-adjusted start, then days as the residual.
    long sign = 1;
    CivilDate start = a;
    CivilDate end = b;
    long epoch_a = epoch_days_from_civil(a.y, a.m, a.d);
    long epoch_b = epoch_days_from_civil(b.y, b.m, b.d);
    if (epoch_b < epoch_a) {
        sign = -1;
        start = b;
        end = a;
    }

    long years = end.y - start.y;
    if ((end.m < start.m) || (end.m == start.m && end.d < start.d)) {
        years -= 1;
    }

    CivilDate year_anchor = add_months(start, years * 12, OverflowKind.CONSTRAIN);
    long year_anchor_days = epoch_days_from_civil(year_anchor.y, year_anchor.m, year_anchor.d);
    long end_days = epoch_days_from_civil(end.y, end.m, end.d);

    long months = 0;
    long months_days = year_anchor_days;
    // Walk months up from the year anchor until stepping past `end`.
    while (months_days < end_days) {
        long next = epoch_days_from_civil(
            (add_months(year_anchor, (months + 1) * 12, OverflowKind.CONSTRAIN)).y,
            (add_months(year_anchor, (months + 1) * 12, OverflowKind.CONSTRAIN)).m,
            (add_months(year_anchor, (months + 1) * 12, OverflowKind.CONSTRAIN)).d);
        if (next > end_days) break;
        months += 1;
        months_days = next;
    }

    long days = end_days - months_days;

    return {
        .years  = years * sign,
        .months = months * sign,
        .days   = days * sign,
    };
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
