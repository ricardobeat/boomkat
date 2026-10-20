// The Temporal calendar operations over the year model of calendar_systems.c3, for every calendar
// other than ISO 8601: dates from days and back, month codes, BalanceNonISODate, NonISODateAdd,
// NonISODateUntil and the month-day reference dates (Intl era and monthCode proposal, §15.6).
module boomkat::lib::temporal;

// A month code: "M05" is { 5, false } and "M05L" is { 5, true }.
struct MonthCode {
    int number;
    bool leap;
}

// The Calendar Date Record of a day.
struct CalendarDate {
    long year;            // arithmetic year
    int month;            // ordinal month, 1-based
    MonthCode month_code;
    int day;
    int day_of_year;
    int days_in_month;
    int days_in_year;
    int months_in_year;
    bool in_leap_year;
    int era;              // index into calendar_eras(cal), -1 for a calendar without eras
    long era_year;
}

// Days beyond which no year of any calendar meets the ISO date limits, so arithmetic that lands
// there can stop before computing calendar years ever further away.
const long CALENDAR_DAYS_LIMIT = 100_000_000 + 400;
const long CALENDAR_YEARS_LIMIT = 300_000;

fn MonthCode CalendarYear.month_code(&self, int ordinal) {
    if (self.leap_month == 0 || ordinal < self.leap_month) return { ordinal, false };
    return { ordinal - 1, ordinal == self.leap_month };
}

fn int CalendarYear.days_in_month(&self, int ordinal) {
    return self.month_start[ordinal] - self.month_start[ordinal - 1];
}

fn int CalendarYear.length(&self) => self.month_start[self.months];

fn CalendarDate calendar_date(CalendarId cal, long epoch_days) {
    if (calendar_is_iso_based(cal)) return calendar_iso_date(cal, civil_date_from_epoch_days(epoch_days));
    long year = calendar_year_of(cal, epoch_days);
    CalendarYear info = calendar_year(cal, year);
    int offset = (int)(epoch_days - info.start);
    int month = 1;
    while (month < info.months && info.month_start[month] <= offset) month++;
    CalendarDate out;
    out.year = year;
    out.month = month;
    out.month_code = info.month_code(month);
    out.day = offset - info.month_start[month - 1] + 1;
    out.day_of_year = offset + 1;
    out.days_in_month = info.days_in_month(month);
    out.days_in_year = info.length();
    out.months_in_year = info.months;
    // Lunisolar leap years add a month; the others add a day to a 354-day lunar or 365-day solar year.
    bool lunar = cal == ISLAMIC_CIVIL || cal == ISLAMIC_TBLA || cal == ISLAMIC_UMALQURA;
    out.in_leap_year = calendar_is_lunisolar(cal) ? info.months == 13 : out.days_in_year > (lunar ? 354 : 365);
    calendar_date_era(cal, year, epoch_days, &out.era, &out.era_year);
    return out;
}

// CalendarISOToDate.
fn CalendarDate calendar_iso_date(CalendarId cal, CivilDate iso) {
    long days = epoch_days_from_civil(iso.y, (int)iso.m, (int)iso.d);
    if (!calendar_is_iso_based(cal)) return calendar_date(cal, days);
    CalendarDate out;
    out.year = iso.y - calendar_iso_year(cal, 0);
    out.month = (int)iso.m;
    out.month_code = { (int)iso.m, false };
    out.day = (int)iso.d;
    out.day_of_year = (int)(days - epoch_days_from_civil(iso.y, 1, 1)) + 1;
    out.days_in_month = days_in_month(iso.y, (int)iso.m);
    out.in_leap_year = is_leap_year(iso.y);
    out.days_in_year = out.in_leap_year ? 366 : 365;
    out.months_in_year = 12;
    calendar_date_era(cal, out.year, days, &out.era, &out.era_year);
    return out;
}

// The day an existing year, ordinal month and day name.
fn long calendar_epoch_days(CalendarId cal, long year, int month, int day) {
    CalendarYear info = calendar_year(cal, year);
    return info.start + info.month_start[month - 1] + day - 1;
}

fn int calendar_months_in_year(CalendarId cal, long year) {
    if (!calendar_is_lunisolar(cal)) {
        return cal == COPTIC || cal == ETHIOPIC || cal == ETHIOAA ? 13 : 12;
    }
    if (cal == HEBREW) return hebrew_leap_year(year) ? 13 : 12;
    return calendar_year(cal, year).months;
}

fn int calendar_days_in_month(CalendarId cal, long year, int month) {
    return calendar_year(cal, year).days_in_month(month);
}

// ============================================================================
// Month codes
// ============================================================================

// IsValidMonthCodeForCalendar.
fn bool calendar_month_code_valid(CalendarId cal, MonthCode code) {
    if (!code.leap) {
        if (code.number >= 1 && code.number <= 12) return true;
        return code.number == 13 && (cal == COPTIC || cal == ETHIOPIC || cal == ETHIOAA);
    }
    switch (cal) {
        case CHINESE:
        case DANGI: return code.number >= 1 && code.number <= 12;
        case HEBREW: return code.number == 5;
        default: return false;
    }
}

// YearContainsMonthCode, for a code valid in the calendar.
fn bool calendar_year_has_month_code(CalendarId cal, long year, MonthCode code) {
    if (!code.leap) return true;
    if (cal == HEBREW) return hebrew_leap_year(year);
    CalendarYear info = calendar_year(cal, year);
    return info.leap_month != 0 && info.leap_month - 1 == code.number;
}

// ConstrainMonthCode for a code the year lacks: a missing Chinese or Dangi leap month becomes
// the month it would follow, and Adar I becomes Adar.
fn MonthCode calendar_constrain_month_code(CalendarId cal, MonthCode code) {
    if (cal == HEBREW) return { 6, false };
    return { code.number, false };
}

// MonthCodeToOrdinal, for a code the year contains.
fn int calendar_month_code_to_ordinal(CalendarId cal, long year, MonthCode code) {
    if (!calendar_is_lunisolar(cal)) return code.number;
    int leap_month = cal == HEBREW ? (hebrew_leap_year(year) ? 6 : 0) : calendar_year(cal, year).leap_month;
    if (leap_month == 0) return code.number;
    if (code.leap) return leap_month;
    return code.number < leap_month ? code.number : code.number + 1;
}

// Lexicographic month code order: "M05" < "M05L" < "M06".
fn int month_code_compare(MonthCode a, MonthCode b) {
    if (a.number != b.number) return a.number < b.number ? -1 : 1;
    if (a.leap != b.leap) return a.leap ? 1 : -1;
    return 0;
}

// The largest day a month code has in any year (NonISOMonthDayToISOReferenceDate).
fn int calendar_month_code_max_days(CalendarId cal, MonthCode code) {
    switch (cal) {
        case CHINESE:
        case DANGI:
        case ISLAMIC_UMALQURA:
            return 30;
        case COPTIC:
        case ETHIOPIC:
        case ETHIOAA:
            return code.number == 13 ? 6 : 30;
        case INDIAN:
            return code.number <= 6 ? 31 : 30;
        case PERSIAN:
            return code.number <= 6 ? 31 : 30;
        case ISLAMIC_CIVIL:
        case ISLAMIC_TBLA:
            return code.number % 2 == 1 || code.number == 12 ? 30 : 29;
        case HEBREW:
            // Heshvan and Kislev reach 30 in complete years; Adar I always has 30 days.
            if (code.leap) return 30;
            switch (code.number) {
                case 1: case 2: case 3: case 5: case 7: case 9: case 11: return 30;
                default: return 29;
            }
        default:
            return days_in_month(1972, code.number);
    }
}

// ============================================================================
// Balancing and arithmetic
// ============================================================================

struct CalendarYearMonth {
    long year;
    long month;
}

// The year-month part of BalanceNonISODate: `month` may lie outside its year in either
// direction. Twelve- and thirteen-month calendars balance arithmetically and the Hebrew one by
// its 19-year cycle of 235 months. Chinese and Dangi leap years follow no cycle, so a distant
// month is found as the new moon that many mean lunations on: true new moons stay within a day
// of the mean ones, so the first one after three days short of the estimate is the month.
fn CalendarYearMonth calendar_balance_year_month(CalendarId cal, long year, long month) {
    if (!calendar_is_lunisolar(cal)) {
        long per_year = calendar_months_in_year(cal, year);
        long shift = cal_floor_div(month - 1, per_year);
        return { year + shift, month - shift * per_year };
    }
    if (cal == HEBREW) {
        long cycles = cal_floor_div(month - 1, 235);
        year += 19 * cycles;
        month -= 235 * cycles;
    } else if (month > 26 || month < -13) {
        double estimate = (double)calendar_epoch_days(cal, year, 1, 1) + (double)(month - 1) * LUNAR_SYNODIC_MONTH;
        if (estimate > (double)CALENDAR_DAYS_LIMIT || estimate < (double)-CALENDAR_DAYS_LIMIT) {
            return { estimate > 0 ? CALENDAR_YEARS_LIMIT + 1 : -CALENDAR_YEARS_LIMIT - 1, 1 };
        }
        CalendarDate date = calendar_date(cal, lunar_new_moon_near(cal == DANGI, estimate - 3, true));
        return { date.year, date.month };
    }
    while (month <= 0) {
        year--;
        month += calendar_months_in_year(cal, year);
    }
    long months_in_year = calendar_months_in_year(cal, year);
    while (month > months_in_year) {
        month -= months_in_year;
        year++;
        months_in_year = calendar_months_in_year(cal, year);
    }
    return { year, month };
}

fn bool calendar_year_in_range(long year) @inline => year <= CALENDAR_YEARS_LIMIT && year >= -CALENDAR_YEARS_LIMIT;

// NonISODateAdd: the day `years`, `months`, `weeks` and `days` after a day, or false when
// `overflow` rejects a month code or day the target month lacks, or the result leaves the
// calendar's computable range. The caller checks ISODateWithinLimits on the result.
fn bool calendar_date_add(CalendarId cal, long epoch_days, long years, long months, long weeks, long days,
                          OverflowKind overflow, long* out) {
    CalendarDate parts = calendar_date(cal, epoch_days);
    long y0 = parts.year + years;
    if (!calendar_year_in_range(y0)) return false;
    MonthCode code = parts.month_code;
    if (!calendar_year_has_month_code(cal, y0, code)) {
        if (overflow == REJECT) return false;
        code = calendar_constrain_month_code(cal, code);
    }
    long m0 = calendar_month_code_to_ordinal(cal, y0, code);
    CalendarYearMonth target = calendar_balance_year_month(cal, y0, m0 + months);
    if (!calendar_year_in_range(target.year)) return false;
    int day = parts.day;
    int days_in_month = calendar_days_in_month(cal, target.year, (int)target.month);
    if (day > days_in_month) {
        if (overflow == REJECT) return false;
        day = days_in_month;
    }
    long result = calendar_epoch_days(cal, target.year, (int)target.month, day) + 7 * weeks + days;
    if (result > CALENDAR_DAYS_LIMIT || result < -CALENDAR_DAYS_LIMIT) return false;
    *out = result;
    return true;
}

// CompareSurpasses with a month code (`use_code`) or an ordinal month.
fn bool calendar_compare_surpasses(long sign, long year, bool use_code, MonthCode code, long month, long day, CalendarDate* target) {
    if (year != target.year) return sign * (year - target.year) > 0;
    if (use_code) {
        int c = month_code_compare(code, target.month_code);
        if (c != 0) return sign * c > 0;
    } else if (month != target.month) {
        return sign * (month - target.month) > 0;
    }
    if (day != target.day) return sign * (day - target.day) > 0;
    return false;
}

// NonISODateSurpasses without weeks or days, which the caller counts as whole days.
fn bool calendar_date_surpasses(CalendarId cal, long sign, CalendarDate* from, CalendarDate* to, long years, long months) {
    long y0 = from.year + years;
    if (calendar_compare_surpasses(sign, y0, true, from.month_code, 0, from.day, to)) return true;
    MonthCode code = from.month_code;
    if (!calendar_year_has_month_code(cal, y0, code)) code = calendar_constrain_month_code(cal, code);
    long m0 = calendar_month_code_to_ordinal(cal, y0, code);
    CalendarYearMonth added = calendar_balance_year_month(cal, y0, m0 + months);
    return calendar_compare_surpasses(sign, added.year, false, {}, added.month, from.day, to);
}

// NonISODateUntil as years, months and days; a weeks result is the caller's split of the days.
// The year count starts one short of the difference in years, which no candidate before it can
// surpass, so distant dates need not be walked a year at a time. The days are counted from the
// regulated date the years and months reach, which is what the spec's day-by-day search finds.
fn DateDifference calendar_date_until(CalendarId cal, long one, long two, DifferenceUnit largest) {
    DateDifference out;
    if (one == two) return out;
    long sign = one < two ? 1 : -1;
    CalendarDate from = calendar_date(cal, one);
    CalendarDate to = calendar_date(cal, two);
    long years = 0;
    if (largest == YEARS) {
        long gap = (to.year - from.year) * sign;
        if (gap > 1) years = (gap - 1) * sign;
        while (!calendar_date_surpasses(cal, sign, &from, &to, years + sign, 0)) years += sign;
    }
    long months = 0;
    if (largest == YEARS || largest == MONTHS) {
        if (largest == MONTHS) {
            // A run of years holds within a month or two of the mean count of months, so a
            // head start of 16 short of the estimate cannot surpass.
            double per_year = calendar_is_lunisolar(cal) ? 12.3682667 : (double)calendar_months_in_year(cal, from.year);
            long gap = ((long)((double)(to.year - from.year) * per_year) + (long)(to.month - from.month)) * sign;
            if (gap > 16) months = (gap - 16) * sign;
        }
        while (!calendar_date_surpasses(cal, sign, &from, &to, years, months + sign)) months += sign;
    }
    long anchor = one;
    if (years != 0 || months != 0) {
        long y0 = from.year + years;
        MonthCode code = from.month_code;
        if (!calendar_year_has_month_code(cal, y0, code)) code = calendar_constrain_month_code(cal, code);
        CalendarYearMonth reached = calendar_balance_year_month(cal, y0, calendar_month_code_to_ordinal(cal, y0, code) + months);
        int day = from.day;
        int days_in_month = calendar_days_in_month(cal, reached.year, (int)reached.month);
        if (day > days_in_month) day = days_in_month;
        anchor = calendar_epoch_days(cal, reached.year, (int)reached.month, day);
    }
    out.years = years;
    out.months = months;
    out.days = two - anchor;
    return out;
}

// ============================================================================
// Month-day reference dates
// ============================================================================

// The Chinese and Dangi reference ISO years by month code (the proposal's "ISO Reference
// Years" table): [number][leap], for days 1-29 and for day 30. 0 marks a month-day that is
// not known to occur. M11L days 1-10 fall in 2033 and days 11-29 in 2034; the Chinese M03
// day 30 is in 1966 and the Dangi one in 1968.
const short[2][13] CHINESE_REFERENCE_DAYS_1_29 = {
    { 0, 0 }, { 1972, 0 }, { 1972, 1947 }, { 1972, 1966 }, { 1972, 1963 }, { 1972, 1971 }, { 1972, 1960 },
    { 1972, 1968 }, { 1972, 1957 }, { 1972, 2014 }, { 1972, 1984 }, { 1972, 2034 }, { 1972, 0 },
};
const short[2][13] CHINESE_REFERENCE_DAY_30 = {
    { 0, 0 }, { 1970, 0 }, { 1972, 0 }, { 1966, 1955 }, { 1970, 1944 }, { 1972, 1952 }, { 1971, 1941 },
    { 1972, 1938 }, { 1971, 0 }, { 1972, 0 }, { 1972, 0 }, { 1970, 0 }, { 1972, 0 },
};

// The ISO year whose latest occurrence of a Chinese or Dangi month-day is its reference date, or
// 0 when the month-day is not known to occur.
fn long chinese_reference_year(CalendarId cal, MonthCode code, int day) {
    int leap = code.leap ? 1 : 0;
    if (day == 30) {
        if (cal == DANGI && code.number == 3 && !code.leap) return 1968;
        return CHINESE_REFERENCE_DAY_30[code.number][leap];
    }
    if (code.number == 11 && code.leap && day <= 10) return 2033;
    return CHINESE_REFERENCE_DAYS_1_29[code.number][leap];
}

// Whether a Chinese or Dangi month-day has a reference year.
fn bool calendar_month_day_known(CalendarId cal, MonthCode code, int day) {
    if (cal != CHINESE && cal != DANGI) return true;
    return chinese_reference_year(cal, code, day) != 0;
}

const long REFERENCE_FIRST_DAY = -25567;   // 1900-01-01
const long REFERENCE_LAST_DAY = 1095;      // 1972-12-31

// The day of a month code and day in a calendar year, or false when the year lacks either.
fn bool calendar_month_day_in_year(CalendarId cal, long year, MonthCode code, int day, long* out) {
    if (!calendar_year_has_month_code(cal, year, code)) return false;
    int month = calendar_month_code_to_ordinal(cal, year, code);
    if (day > calendar_days_in_month(cal, year, month)) return false;
    *out = calendar_epoch_days(cal, year, month, day);
    return true;
}

// The reference ISO date of an existing month code and day: the latest such day from 1900 to
// 1972, else the earliest after 1972. Chinese and Dangi use the latest one in the tabled ISO
// year, which the caller has checked exists.
fn long calendar_month_day_reference(CalendarId cal, MonthCode code, int day) {
    long found;
    if (cal == CHINESE || cal == DANGI) {
        long iso_year = chinese_reference_year(cal, code, day);
        // The month falls in the calendar year that starts in the ISO year, or the one before.
        if (calendar_month_day_in_year(cal, iso_year, code, day, &found) && civil_date_from_epoch_days(found).y == iso_year) return found;
        calendar_month_day_in_year(cal, iso_year - 1, code, day, &found);
        return found;
    }
    for (long year = calendar_year_of(cal, REFERENCE_LAST_DAY); calendar_year_start(cal, year + 1) > REFERENCE_FIRST_DAY; year--) {
        if (calendar_month_day_in_year(cal, year, code, day, &found) && found <= REFERENCE_LAST_DAY && found >= REFERENCE_FIRST_DAY) return found;
    }
    for (long year = calendar_year_of(cal, REFERENCE_LAST_DAY); ; year++) {
        if (calendar_month_day_in_year(cal, year, code, day, &found) && found > REFERENCE_LAST_DAY) return found;
    }
}
