// The calendars Temporal and DateTimeFormat compute: ISO 8601 plus every CLDR calendar ECMA-402
// requires (Intl era and monthCode proposal, "Calendar types described in CLDR"). Each calendar
// describes a year by its first day, the offsets of its months and its leap month, if any; the
// spec's generic algorithms in calendar_ops.c3 run over that model.
//
// Years are arithmetic years, counted from the first day of the calendar's epoch year (the
// proposal's "Epoch years" table), so year 1 of the epoch era is 1 and the year before it is 0.
module boomkat::lib::temporal;

import std::math;

enum CalendarId : char {
    ISO8601,
    BUDDHIST,
    CHINESE,
    COPTIC,
    DANGI,
    ETHIOAA,
    ETHIOPIC,
    GREGORY,
    HEBREW,
    INDIAN,
    ISLAMIC_CIVIL,
    ISLAMIC_TBLA,
    ISLAMIC_UMALQURA,
    JAPANESE,
    PERSIAN,
    ROC,
}

// The canonical calendar type, as calendarId and the u-ca annotation report it.
fn String calendar_name(CalendarId cal) {
    switch (cal) {
        case ISO8601: return "iso8601";
        case BUDDHIST: return "buddhist";
        case CHINESE: return "chinese";
        case COPTIC: return "coptic";
        case DANGI: return "dangi";
        case ETHIOAA: return "ethioaa";
        case ETHIOPIC: return "ethiopic";
        case GREGORY: return "gregory";
        case HEBREW: return "hebrew";
        case INDIAN: return "indian";
        case ISLAMIC_CIVIL: return "islamic-civil";
        case ISLAMIC_TBLA: return "islamic-tbla";
        case ISLAMIC_UMALQURA: return "islamic-umalqura";
        case JAPANESE: return "japanese";
        case PERSIAN: return "persian";
        case ROC: return "roc";
    }
}

// CanonicalizeCalendar: the calendar a type names, ASCII case-insensitively, including the
// aliases AvailableCalendars lists ("ethiopic-amete-alem" and "islamicc").
fn bool calendar_from_name(char[] text, CalendarId* out) {
    if (ci_equals(text, "ethiopic-amete-alem")) {
        *out = ETHIOAA;
        return true;
    }
    if (ci_equals(text, "islamicc")) {
        *out = ISLAMIC_CIVIL;
        return true;
    }
    foreach (cal : CalendarId::values) {
        if (ci_equals(text, calendar_name(cal))) {
            *out = cal;
            return true;
        }
    }
    return false;
}

// The calendars whose months, days and leap years are the ISO 8601 ones.
fn bool calendar_is_iso_based(CalendarId cal) {
    switch (cal) {
        case ISO8601:
        case BUDDHIST:
        case GREGORY:
        case JAPANESE:
        case ROC:
            return true;
        default:
            return false;
    }
}

// The ISO year of the start of an arithmetic year of an ISO-based calendar.
fn long calendar_iso_year(CalendarId cal, long year) {
    switch (cal) {
        case BUDDHIST: return year - 543;
        case ROC: return year + 1911;
        default: return year;
    }
}

// Leap months add a thirteenth month; the Chinese and Dangi leap month follows any month, the
// Hebrew one (Adar I, M05L) is always the sixth.
fn bool calendar_is_lunisolar(CalendarId cal) {
    return cal == CHINESE || cal == DANGI || cal == HEBREW;
}

// ============================================================================
// Eras
// ============================================================================

// How an era counts its years from the arithmetic year (CalendarDateArithmeticYearForEraYear):
// EPOCH eras share the arithmetic count, NEGATIVE ones count backwards from year 0, and OFFSET
// ones start at arithmetic year `offset`.
enum EraKind : char {
    EPOCH,
    NEGATIVE,
    OFFSET,
}

struct EraInfo {
    String name;
    String other_name;   // an alias, or empty
    EraKind kind;
    long offset;
}

// The modern Japanese eras, newest first, with the ISO date each begins. Meiji is the
// government's era only from 1873, the year Japan adopted the Gregorian calendar; dates before
// that use the Gregorian eras, which follow at indexes JAPANESE_ERA_CE and JAPANESE_ERA_CE + 1.
const int JAPANESE_ERA_CE = 5;
const CivilDate[5] JAPANESE_ERA_STARTS = {
    { 2019, 5, 1 }, { 1989, 1, 8 }, { 1926, 12, 25 }, { 1912, 7, 30 }, { 1873, 1, 1 },
};

// Every calendar's eras, the epoch era first; slices of it are returned, so it is not const.
EraInfo[22] calendar_era_table @local = {
    { "reiwa", "", OFFSET, 2019 },      // 0: japanese
    { "heisei", "", OFFSET, 1989 },
    { "showa", "", OFFSET, 1926 },
    { "taisho", "", OFFSET, 1912 },
    { "meiji", "", OFFSET, 1868 },
    { "ce", "ad", EPOCH, 0 },           // 5: gregory
    { "bce", "bc", NEGATIVE, 0 },
    { "be", "", EPOCH, 0 },             // 7: buddhist
    { "am", "", EPOCH, 0 },             // 8: coptic, hebrew
    { "aa", "", EPOCH, 0 },             // 9: ethioaa
    { "am", "", EPOCH, 0 },             // 10: ethiopic
    { "aa", "", OFFSET, -5499 },
    { "shaka", "", EPOCH, 0 },          // 12: indian
    { "ah", "", EPOCH, 0 },             // 13: islamic
    { "bh", "", NEGATIVE, 0 },
    { "ap", "", EPOCH, 0 },             // 15: persian
    { "roc", "", EPOCH, 0 },            // 16: roc
    { "broc", "", NEGATIVE, 0 },
    { "", "", EPOCH, 0 },
    { "", "", EPOCH, 0 },
    { "", "", EPOCH, 0 },
    { "", "", EPOCH, 0 },
};

// The eras of a calendar (CalendarSupportsEra is a non-empty result).
fn EraInfo[] calendar_eras(CalendarId cal) {
    switch (cal) {
        case BUDDHIST: return calendar_era_table[7:1];
        case COPTIC: return calendar_era_table[8:1];
        case ETHIOAA: return calendar_era_table[9:1];
        case ETHIOPIC: return calendar_era_table[10:2];
        case GREGORY: return calendar_era_table[5:2];
        case HEBREW: return calendar_era_table[8:1];
        case INDIAN: return calendar_era_table[12:1];
        case ISLAMIC_CIVIL:
        case ISLAMIC_TBLA:
        case ISLAMIC_UMALQURA: return calendar_era_table[13:2];
        case JAPANESE: return calendar_era_table[0:7];
        case PERSIAN: return calendar_era_table[15:1];
        case ROC: return calendar_era_table[16:2];
        default: return calendar_era_table[0:0];
    }
}

fn bool calendar_supports_era(CalendarId cal) => calendar_eras(cal).len > 0;

// CalendarHasMidYearEras.
fn bool calendar_has_mid_year_eras(CalendarId cal) => cal == JAPANESE;

// CanonicalizeEraInCalendar: the index of the era `text` names, by name or alias, or -1.
fn int calendar_era_index(CalendarId cal, char[] text) {
    foreach (i, era : calendar_eras(cal)) {
        if (text == era.name || (era.other_name.len > 0 && text == era.other_name)) return (int)i;
    }
    return -1;
}

// CalendarDateArithmeticYearForEraYear.
fn long calendar_era_arithmetic_year(CalendarId cal, int era, long era_year) {
    EraInfo info = calendar_eras(cal)[era];
    switch (info.kind) {
        case EPOCH: return era_year;
        case NEGATIVE: return 1 - era_year;
        case OFFSET: return info.offset + era_year - 1;
    }
}

// The era and era year of a date; `era` is -1 for a calendar without eras.
fn void calendar_date_era(CalendarId cal, long year, long epoch_days, int* era, long* era_year) {
    *era = -1;
    *era_year = 0;
    switch (cal) {
        case JAPANESE:
            foreach (i, start : JAPANESE_ERA_STARTS) {
                if (epoch_days >= epoch_days_from_civil(start.y, (int)start.m, (int)start.d)) {
                    *era = (int)i;
                    *era_year = year - calendar_era_table[i].offset + 1;
                    return;
                }
            }
            *era = year > 0 ? JAPANESE_ERA_CE : JAPANESE_ERA_CE + 1;
        case ETHIOPIC:
        case GREGORY:
        case ISLAMIC_CIVIL:
        case ISLAMIC_TBLA:
        case ISLAMIC_UMALQURA:
        case ROC:
            *era = year > 0 ? 0 : 1;
        case BUDDHIST:
        case COPTIC:
        case ETHIOAA:
        case HEBREW:
        case INDIAN:
        case PERSIAN:
            *era = 0;
        default:
            return;
    }
    EraInfo info = calendar_eras(cal)[*era];
    switch (info.kind) {
        case EPOCH: *era_year = year;
        case NEGATIVE: *era_year = 1 - year;
        case OFFSET: *era_year = year - info.offset + 1;
    }
}

// ============================================================================
// Year model
// ============================================================================

// A calendar year: its first day, its months and its leap month.
struct CalendarYear {
    long start;               // days since 1970-01-01 of the year's first day
    int months;               // 12 or 13
    int leap_month;           // ordinal of the leap month, 0 when the year has none
    ushort[14] month_start;   // day offset of each month from `start`; [months] is the year length
}

const long JULIAN_DAY_UNIX_EPOCH = 2440588;
const long FIXED_DAY_UNIX_EPOCH = 719163;      // Rata Die of 1970-01-01
const long COPTIC_EPOCH_JD = 1824665;          // ICU coptic.cpp
const long ETHIOPIC_EPOCH_JD = 1723856;        // ICU ethpccal.cpp, the Amete Mihret epoch
const long ETHIOAA_YEAR_DELTA = 5500;          // Amete Alem year less Amete Mihret year
const long PERSIAN_EPOCH_JD = 1948320;         // ICU persian.cpp
const long ISLAMIC_TBLA_EPOCH_JD = 1948439;    // the astronomical epoch, a day before the civil one

fn long cal_floor_div(long a, long b) @inline => a >= 0 ? a / b : (a - b + 1) / b;

// The first day of a year of a calendar whose year length follows from arithmetic alone.
fn long calendar_arithmetic_year_start(CalendarId cal, long year) {
    switch (cal) {
        case COPTIC:
            return COPTIC_EPOCH_JD + 365 * year + cal_floor_div(year, 4) - JULIAN_DAY_UNIX_EPOCH;
        case ETHIOPIC:
            return ETHIOPIC_EPOCH_JD + 365 * year + cal_floor_div(year, 4) - JULIAN_DAY_UNIX_EPOCH;
        case ETHIOAA:
            return calendar_arithmetic_year_start(ETHIOPIC, year - ETHIOAA_YEAR_DELTA);
        case INDIAN: {
            long gyear = year + 78;
            return epoch_days_from_civil(gyear, 3, is_leap_year(gyear) ? 21 : 22);
        }
        case PERSIAN:
            return PERSIAN_EPOCH_JD + 365 * (year - 1) + cal_floor_div(8 * year + 21, 33) - JULIAN_DAY_UNIX_EPOCH;
        case ISLAMIC_CIVIL:
            return hijri_year_start(year) + HIJRI_EPOCH_JD - JULIAN_DAY_UNIX_EPOCH;
        case ISLAMIC_TBLA:
            return hijri_year_start(year) + ISLAMIC_TBLA_EPOCH_JD - JULIAN_DAY_UNIX_EPOCH;
        case ISLAMIC_UMALQURA:
            long start = calendar_arithmetic_year_start(ISLAMIC_CIVIL, year);
            if (year < UMALQURA_FIRST_YEAR || year > UMALQURA_LAST_YEAR) return start;
            return start + (long)((UMALQURA_YEARS[(usz)(year - UMALQURA_FIRST_YEAR)] >> 12) & 3) - 1;
        case HEBREW:
            return hebrew_new_year(year) - FIXED_DAY_UNIX_EPOCH;
        default:
            return epoch_days_from_civil(calendar_iso_year(cal, year), 1, 1);
    }
}

fn void calendar_year_set_months(CalendarYear* out, int[] lengths) {
    out.months = (int)lengths.len;
    int offset = 0;
    foreach (i, len : lengths) {
        out.month_start[i] = (ushort)offset;
        offset += len;
    }
    out.month_start[lengths.len] = (ushort)offset;
}

fn CalendarYear calendar_year_compute(CalendarId cal, long year) {
    CalendarYear out;
    if (cal == CHINESE || cal == DANGI) {
        calendar_lunisolar_year(cal == DANGI, year, &out);
        return out;
    }
    out.start = calendar_arithmetic_year_start(cal, year);
    switch (cal) {
        case COPTIC:
        case ETHIOPIC:
        case ETHIOAA: {
            int[13] lengths = { 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 0 };
            lengths[12] = (int)(calendar_arithmetic_year_start(cal, year + 1) - out.start) - 360;
            calendar_year_set_months(&out, lengths[..]);
        }
        case INDIAN: {
            int[12] lengths = { 30, 31, 31, 31, 31, 31, 30, 30, 30, 30, 30, 30 };
            if (is_leap_year(year + 78)) lengths[0] = 31;
            calendar_year_set_months(&out, lengths[..]);
        }
        case PERSIAN: {
            int[12] lengths = { 31, 31, 31, 31, 31, 31, 30, 30, 30, 30, 30, 0 };
            lengths[11] = (int)(calendar_arithmetic_year_start(cal, year + 1) - out.start) - 336;
            calendar_year_set_months(&out, lengths[..]);
        }
        case ISLAMIC_CIVIL:
        case ISLAMIC_TBLA:
        case ISLAMIC_UMALQURA: {
            int[12] lengths;
            if (cal == ISLAMIC_UMALQURA && year >= UMALQURA_FIRST_YEAR && year <= UMALQURA_LAST_YEAR) {
                ushort bits = UMALQURA_YEARS[(usz)(year - UMALQURA_FIRST_YEAR)];
                for (int m = 0; m < 12; m++) lengths[m] = (bits & (1 << m)) != 0 ? 30 : 29;
            } else {
                // Months alternate 30 and 29 days; a leap year's last month has 30.
                for (int m = 0; m < 12; m++) lengths[m] = m % 2 == 0 ? 30 : 29;
                lengths[11] = (int)(calendar_arithmetic_year_start(cal, year + 1) - out.start) - 325;
            }
            calendar_year_set_months(&out, lengths[..]);
        }
        case HEBREW: {
            long year_length = hebrew_new_year(year + 1) - hebrew_new_year(year);
            bool leap = hebrew_leap_year(year);
            int[13] lengths;
            int count = leap ? 13 : 12;
            for (int m = 0; m < count; m++) lengths[m] = (int)hebrew_month_length(year_length, leap, m);
            calendar_year_set_months(&out, lengths[:count]);
            if (leap) out.leap_month = 6;
        }
        default: {
            long iso_year = calendar_iso_year(cal, year);
            int[12] lengths;
            for (int m = 0; m < 12; m++) lengths[m] = days_in_month(iso_year, m + 1);
            calendar_year_set_months(&out, lengths[..]);
        }
    }
    return out;
}

// A Chinese or Dangi year: the new moons from one new year to the next, and the month among them
// ICU numbers as a leap month.
fn void calendar_lunisolar_year(bool dangi, long year, CalendarYear* out) {
    out.start = lunar_new_year(dangi, year);
    long next_year = lunar_new_year(dangi, year + 1);
    int months = (int)lunar_synodic_between(out.start, next_year);
    long moon = out.start;
    for (int m = 0; m < months; m++) {
        out.month_start[m] = (ushort)(moon - out.start);
        if (months == 13 && out.leap_month == 0) {
            long gyear = civil_date_from_epoch_days(moon).y;
            if (lunar_month(dangi, gyear, moon).leap) out.leap_month = m + 1;
        }
        moon = m + 1 < months ? lunar_new_moon_near(dangi, (double)(moon + LUNAR_SYNODIC_GAP), true) : next_year;
    }
    out.month_start[months] = (ushort)(next_year - out.start);
    out.months = months;
}

// The Chinese and Dangi years cost a few dozen solar and lunar position searches each, and the
// date arithmetic revisits the same few years, so the latest ones stay cached per thread.
struct CalendarYearCacheEntry {
    bool valid;
    CalendarId cal;
    long year;
    CalendarYear value;
}

const usz CALENDAR_YEAR_CACHE_SIZE = 16;
tlocal CalendarYearCacheEntry[CALENDAR_YEAR_CACHE_SIZE] calendar_year_cache @local;
tlocal usz calendar_year_cache_next @local;

fn CalendarYear calendar_year(CalendarId cal, long year) {
    if (cal != CHINESE && cal != DANGI) return calendar_year_compute(cal, year);
    foreach (&entry : calendar_year_cache) {
        if (entry.valid && entry.cal == cal && entry.year == year) return entry.value;
    }
    CalendarYear value = calendar_year_compute(cal, year);
    calendar_year_cache[calendar_year_cache_next] = { .valid = true, .cal = cal, .year = year, .value = value };
    calendar_year_cache_next = (calendar_year_cache_next + 1) % CALENDAR_YEAR_CACHE_SIZE;
    return value;
}

fn long calendar_year_start(CalendarId cal, long year) {
    if (cal == CHINESE || cal == DANGI) return calendar_year(cal, year).start;
    return calendar_arithmetic_year_start(cal, year);
}

// The arithmetic year that contains a day.
fn long calendar_year_of(CalendarId cal, long epoch_days) {
    long year;
    switch (cal) {
        case COPTIC:
        case ETHIOPIC:
        case ETHIOAA: {
            // ICU's jdToCE: whole four-year cycles, then the year within the cycle.
            long jd_epoch = cal == COPTIC ? COPTIC_EPOCH_JD : ETHIOPIC_EPOCH_JD;
            long n = epoch_days + JULIAN_DAY_UNIX_EPOCH - jd_epoch;
            long c4 = cal_floor_div(n, 1461);
            long r4 = n - 1461 * c4;
            year = 4 * c4 + (r4 / 365 - r4 / 1460);
            if (cal == ETHIOAA) year += ETHIOAA_YEAR_DELTA;
        }
        case INDIAN:
            year = civil_date_from_epoch_days(epoch_days).y - 78;
        case PERSIAN:
            year = 1 + cal_floor_div(33 * (epoch_days + JULIAN_DAY_UNIX_EPOCH - PERSIAN_EPOCH_JD) + 3, 12053);
        case ISLAMIC_CIVIL:
        case ISLAMIC_TBLA:
        case ISLAMIC_UMALQURA:
            year = cal_floor_div(30 * (epoch_days + JULIAN_DAY_UNIX_EPOCH - HIJRI_EPOCH_JD) + 10646, 10631);
        case HEBREW:
            year = (long)math::floor((double)(epoch_days + FIXED_DAY_UNIX_EPOCH - HEBREW_EPOCH_RD) / 365.24682) + 1;
        case CHINESE:
        case DANGI:
            year = civil_date_from_epoch_days(epoch_days).y;
        default:
            long iso_year = civil_date_from_epoch_days(epoch_days).y;
            return iso_year - calendar_iso_year(cal, 0);
    }
    while (calendar_year_start(cal, year) > epoch_days) year--;
    while (calendar_year_start(cal, year + 1) <= epoch_days) year++;
    return year;
}
