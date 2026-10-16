// The calendars DateTimeFormat computes beyond the Gregorian ones: Chinese and Dangi (Korean)
// lunisolar, Hebrew, and islamic-civil. The lunisolar month boundaries come from low-precision
// solar and lunar longitudes (Duffett-Smith, as in ICU's astro.cpp), searched in the astronomy
// zone: UTC+8 for the Chinese calendar, Korea's historical zone for Dangi. The month and year rules
// follow ICU's chnsecal.cpp.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::lib::temporal;
import std::math;

const double LUNAR_PI = 3.14159265358979323846;
const double LUNAR_TWO_PI = LUNAR_PI * 2.0;
const double LUNAR_DAY_MS = 86400000.0;
const double LUNAR_MINUTE_MS = 60000.0;
const double LUNAR_JD_EPOCH = 2447891.5;
const double LUNAR_JULIAN_EPOCH_MS = -210866760000000.0;
const double LUNAR_TROPICAL_YEAR = 365.242191;
const double LUNAR_SYNODIC_MONTH = 29.530588853;
const long LUNAR_SYNODIC_GAP = 25;
const long LUNAR_CYCLE_EPOCH = -2636;
const double LUNAR_SUN_ETA_G = 279.403303 * LUNAR_PI / 180;
const double LUNAR_SUN_OMEGA_G = 282.768422 * LUNAR_PI / 180;
const double LUNAR_SUN_E = 0.016713;
const double LUNAR_MOON_L0 = 318.351648 * LUNAR_PI / 180;
const double LUNAR_MOON_P0 = 36.340410 * LUNAR_PI / 180;
const double LUNAR_MOON_N0 = 318.510107 * LUNAR_PI / 180;
const double LUNAR_MOON_I = 5.145366 * LUNAR_PI / 180;

struct LunarMonth {
    long month;      // 1..12, as the calendar numbers it
    long ordinal;    // months since the Chinese new year, 0..12
    bool leap;
    bool has_leap;   // the winter solstice to the next one holds a leap month
    long this_moon;  // days of the new moon that starts this month
}

// The Chinese date of a local day: related Gregorian year, month, leap flag and day of month.
struct LunarDate {
    long related_year;
    long month;
    bool leap;
    long day;
}

fn double lunar_normalize(double value, double range) {
    return value - range * math::floor(value / range);
}

fn double lunar_norm2pi(double angle) { return lunar_normalize(angle, LUNAR_TWO_PI); }

fn double lunar_normpi(double angle) {
    return lunar_normalize(angle + LUNAR_PI, LUNAR_TWO_PI) - LUNAR_PI;
}

// Solves Kepler's equation for the true anomaly (Duffett-Smith p. 90).
fn double lunar_true_anomaly(double mean, double eccentricity) {
    double e = mean;
    double delta;
    do {
        delta = e - eccentricity * math::sin(e) - mean;
        e = e - delta / (1 - eccentricity * math::cos(e));
    } while (math::abs(delta) > 1e-5);
    return 2.0 * math::atan(math::tan(e / 2) * math::sqrt((1 + eccentricity) / (1 - eccentricity)));
}

// The sun's ecliptic longitude at a Julian day, and its mean anomaly through out.
fn double lunar_sun_longitude(double jday, double* mean_anomaly) {
    double day = jday - LUNAR_JD_EPOCH;
    double epoch_angle = lunar_norm2pi(LUNAR_TWO_PI / LUNAR_TROPICAL_YEAR * day);
    *mean_anomaly = lunar_norm2pi(epoch_angle + LUNAR_SUN_ETA_G - LUNAR_SUN_OMEGA_G);
    return lunar_norm2pi(lunar_true_anomaly(*mean_anomaly, LUNAR_SUN_E) + LUNAR_SUN_OMEGA_G);
}

// The angle between the moon and the sun at a Julian day (Duffett-Smith p. 142 and p. 147): the
// moon's ecliptic longitude less the sun's, in [0, 2π). Zero at a new moon.
fn double lunar_moon_age(double jday) {
    double sun_mean;
    double sun = lunar_sun_longitude(jday, &sun_mean);
    double day = jday - LUNAR_JD_EPOCH;
    double mean_long = lunar_norm2pi(13.1763966 * LUNAR_PI / 180 * day + LUNAR_MOON_L0);
    double mean_anomaly = lunar_norm2pi(mean_long - 0.1114041 * LUNAR_PI / 180 * day - LUNAR_MOON_P0);
    double evection = 1.2739 * LUNAR_PI / 180 * math::sin(2 * (mean_long - sun) - mean_anomaly);
    double annual = 0.1858 * LUNAR_PI / 180 * math::sin(sun_mean);
    double a3 = 0.3700 * LUNAR_PI / 180 * math::sin(sun_mean);
    mean_anomaly += evection - annual - a3;
    double center = 6.2886 * LUNAR_PI / 180 * math::sin(mean_anomaly);
    double a4 = 0.2140 * LUNAR_PI / 180 * math::sin(2 * mean_anomaly);
    double moon_long = mean_long + evection + center - annual + a4;
    double variation = 0.6583 * LUNAR_PI / 180 * math::sin(2 * (moon_long - sun));
    moon_long += variation;
    double node = lunar_norm2pi(LUNAR_MOON_N0 - 0.0529539 * LUNAR_PI / 180 * day);
    node -= 0.16 * LUNAR_PI / 180 * math::sin(sun_mean);
    double y = math::sin(moon_long - node);
    double x = math::cos(moon_long - node);
    double eclip_long = math::atan2(y * math::cos(LUNAR_MOON_I), x) + node;
    return lunar_norm2pi(eclip_long - sun);
}

// The moon's age (moon = true) or the sun's longitude at a UTC time in milliseconds.
fn double lunar_angle(bool moon, double millis) {
    double jday = (millis - LUNAR_JULIAN_EPOCH_MS) / LUNAR_DAY_MS;
    if (moon) return lunar_moon_age(jday);
    double sun_mean;
    return lunar_sun_longitude(jday, &sun_mean);
}

// The UTC offset of the astronomy zone in milliseconds. China is fixed at UTC+8. Korea's zone steps
// in 1897, 1898 and 1912 (dangical.cpp), and its transition instants are approximate, as in ICU.
fn double lunar_offset(bool dangi, double millis) {
    if (!dangi) return 8 * 3600000.0;
    if (millis < (1897 - 1970) * 365 * LUNAR_DAY_MS) return 8 * 3600000.0;
    if (millis < (1898 - 1970) * 365 * LUNAR_DAY_MS) return 7 * 3600000.0;
    if (millis < (1912 - 1970) * 365 * LUNAR_DAY_MS) return 8 * 3600000.0;
    return 9 * 3600000.0;
}

fn double lunar_days_to_millis(bool dangi, double days) {
    double millis = days * LUNAR_DAY_MS;
    return millis - lunar_offset(dangi, millis);
}

fn double lunar_millis_to_days(bool dangi, double millis) {
    return math::floor((millis + lunar_offset(dangi, millis)) / LUNAR_DAY_MS);
}

// The first time after (or before) start at which the angle equals desired, refined by the
// secant-like step ICU uses. A step that grows restarts an eighth of a period further on.
fn double lunar_time_of_angle(bool moon, double desired, double period_days, double start, bool next) {
    double t = start;
    double last_angle = lunar_angle(moon, t);
    double delta_angle = lunar_norm2pi(desired - last_angle);
    double delta_t = (delta_angle + (next ? 0.0 : -LUNAR_TWO_PI)) * (period_days * LUNAR_DAY_MS) / LUNAR_TWO_PI;
    double last_delta_t = delta_t;
    t = t + math::ceil(delta_t);
    do {
        double angle = lunar_angle(moon, t);
        double factor = math::abs(delta_t / lunar_normpi(angle - last_angle));
        delta_t = lunar_normpi(desired - angle) * factor;
        if (math::abs(delta_t) > math::abs(last_delta_t)) {
            double delta = math::ceil(period_days * LUNAR_DAY_MS / 8.0);
            return lunar_time_of_angle(moon, desired, period_days, start + (next ? delta : -delta), next);
        }
        last_delta_t = delta_t;
        last_angle = angle;
        t = t + math::ceil(delta_t);
    } while (math::abs(delta_t) > LUNAR_MINUTE_MS);
    return t;
}

// The closest new moon on or after (or before) days, as a day number in the astronomy zone.
fn long lunar_new_moon_near(bool dangi, double days, bool after) {
    double millis = lunar_days_to_millis(dangi, days);
    double t = lunar_time_of_angle(true, 0.0, LUNAR_SYNODIC_MONTH, millis, after);
    return (long)lunar_millis_to_days(dangi, t);
}

// The day of the winter solstice (270 degrees of solar longitude) that follows December 1 of gyear.
fn long lunar_winter_solstice(bool dangi, long gyear) {
    double millis = lunar_days_to_millis(dangi, (double)temporal::epoch_days_from_civil(gyear, 12, 1));
    double t = lunar_time_of_angle(false, LUNAR_PI * 3 / 2, LUNAR_TROPICAL_YEAR, millis, true);
    return (long)lunar_millis_to_days(dangi, t);
}

// The major solar term (1..12) in force on a day: 1 at 330 degrees, 2 at 0, 3 at 30, and so on.
fn long lunar_major_term(bool dangi, long days) {
    double longitude = lunar_angle(false, lunar_days_to_millis(dangi, (double)days));
    long term = ((long)(6 * longitude / LUNAR_PI) + 2) % 12;
    return term < 1 ? term + 12 : term;
}

fn bool lunar_no_major_term(bool dangi, long new_moon) {
    long term1 = lunar_major_term(dangi, new_moon);
    long term2 = lunar_major_term(dangi, lunar_new_moon_near(dangi, (double)(new_moon + LUNAR_SYNODIC_GAP), true));
    return term1 == term2;
}

// Whether a month between two new moons (both inclusive) lacks a major solar term.
fn bool lunar_leap_between(bool dangi, long first, long last) {
    while (last >= first) {
        if (lunar_no_major_term(dangi, last)) return true;
        last = lunar_new_moon_near(dangi, (double)(last - LUNAR_SYNODIC_GAP), false);
    }
    return false;
}

fn long lunar_synodic_between(long day1, long day2) {
    double roundme = (double)(day2 - day1) / LUNAR_SYNODIC_MONTH;
    return (long)(roundme + (roundme >= 0 ? 0.5 : -0.5));
}

// The new moon that starts the Chinese year of gyear: the second new moon after the winter solstice
// before it, unless the year has an extra month before the next solstice.
fn long lunar_new_year(bool dangi, long gyear) {
    long solstice_before = lunar_winter_solstice(dangi, gyear - 1);
    long solstice_after = lunar_winter_solstice(dangi, gyear);
    long new_moon1 = lunar_new_moon_near(dangi, (double)(solstice_before + 1), true);
    long new_moon2 = lunar_new_moon_near(dangi, (double)(new_moon1 + LUNAR_SYNODIC_GAP), true);
    long new_moon11 = lunar_new_moon_near(dangi, (double)(solstice_after + 1), false);
    if (lunar_synodic_between(new_moon1, new_moon11) == 12 &&
        (lunar_no_major_term(dangi, new_moon1) || lunar_no_major_term(dangi, new_moon2))) {
        return lunar_new_moon_near(dangi, (double)(new_moon2 + LUNAR_SYNODIC_GAP), true);
    }
    return new_moon2;
}

// The month containing a day, following ICU's computeMonthInfo.
fn LunarMonth lunar_month(bool dangi, long gyear, long days) {
    LunarMonth out;
    long solstice_after = lunar_winter_solstice(dangi, gyear);
    long solstice_before;
    if (days < solstice_after) {
        solstice_before = lunar_winter_solstice(dangi, gyear - 1);
    } else {
        solstice_before = solstice_after;
        solstice_after = lunar_winter_solstice(dangi, gyear + 1);
    }
    long first_moon = lunar_new_moon_near(dangi, (double)(solstice_before + 1), true);
    long last_moon = lunar_new_moon_near(dangi, (double)(solstice_after + 1), false);
    out.this_moon = lunar_new_moon_near(dangi, (double)(days + 1), false);
    out.has_leap = lunar_synodic_between(first_moon, last_moon) == 12;
    out.month = lunar_synodic_between(first_moon, out.this_moon);
    long the_new_year = lunar_new_year(dangi, gyear);
    if (days < the_new_year) the_new_year = lunar_new_year(dangi, gyear - 1);
    if (out.has_leap && lunar_leap_between(dangi, first_moon, out.this_moon)) out.month--;
    if (out.month < 1) out.month += 12;
    out.ordinal = lunar_synodic_between(the_new_year, out.this_moon);
    if (out.ordinal < 0) out.ordinal += 12;
    out.leap = out.has_leap && lunar_no_major_term(dangi, out.this_moon) &&
        !lunar_leap_between(dangi, first_moon, lunar_new_moon_near(dangi, (double)(out.this_moon - LUNAR_SYNODIC_GAP), false));
    return out;
}

// The Chinese (or Dangi) date of a local day, counted in days since 1970-01-01.
fn LunarDate lunar_date(bool dangi, long days) {
    BrokenDownTime civil = temporal::civil_from_seconds(days * 86400);
    long gyear = civil.y;
    long gmonth = civil.m + 1;
    LunarMonth month = lunar_month(dangi, gyear, days);
    LunarDate out;
    // ICU's handleComputeFields: the related year is gyear - 1, plus one when the month is before
    // the eleventh or the Gregorian month is July or later.
    out.related_year = gyear - 1;
    if (month.month < 11 || gmonth >= 7) out.related_year++;
    out.month = month.month;
    out.leap = month.leap;
    out.day = days - month.this_moon + 1;
    return out;
}

const int CAL_CHINESE = 1;
const int CAL_DANGI = 2;
const int CAL_ISLAMIC_CIVIL = 3;
const int CAL_HEBREW = 4;

// The calendar a BCP 47 calendar type selects, 0 for the Gregorian-based ones that DateTimeFormat
// handles with its own field computation. "islamicc" is the deprecated alias of islamic-civil.
fn int intl_calendar_kind(char[] name) {
    if (mem_eq_bytes(name, "chinese")) return CAL_CHINESE;
    if (mem_eq_bytes(name, "dangi")) return CAL_DANGI;
    if (mem_eq_bytes(name, "islamic-civil") || mem_eq_bytes(name, "islamicc")) return CAL_ISLAMIC_CIVIL;
    if (mem_eq_bytes(name, "hebrew")) return CAL_HEBREW;
    return 0;
}

fn char[] intl_calendar_name(int kind) {
    switch (kind) {
        case CAL_CHINESE: return "chinese";
        case CAL_DANGI: return "dangi";
        case CAL_ISLAMIC_CIVIL: return "islamic-civil";
        case CAL_HEBREW: return "hebrew";
        default: return "";
    }
}

fn long lunar_floor_div(long a, long b) {
    return a >= 0 ? a / b : (a - b + 1) / b;
}

struct HijriDate {
    long year;
    long month;  // 0-based
    long day;
}

// The islamic civil (tabular) calendar of ICU's islamcal.cpp: 354-day years with 11 leap years in
// each 30-year cycle, counted from the civil epoch 16 July 622 (Julian calendar, JD 1948440).
const long HIJRI_EPOCH_JD = 1948440;

fn long hijri_year_start(long year) {
    return 354 * (year - 1) + lunar_floor_div(11 * year + 3, 30);
}

// The Hijri date of a local day, counted in days since 1970-01-01.
fn HijriDate islamic_civil_date(long days) {
    long n = days + 2440588 - HIJRI_EPOCH_JD;
    long year = lunar_floor_div(30 * n + 10646, 10631);
    double estimate = math::ceil((double)(n - 29 - hijri_year_start(year)) / 29.5);
    long month = estimate > 11 ? 11 : (long)estimate;
    long month_start = (long)math::ceil(29.5 * (double)month) + hijri_year_start(year);
    HijriDate out;
    out.year = year;
    out.month = month;
    out.day = n - month_start + 1;
    return out;
}

// The related year, then the sexagenary year name. English puts the name in parentheses, as CLDR's
// "r(U)" pattern does; Chinese joins them directly, so the locale's own year suffix follows.
fn bool intl_lunar_year_parts(BuiltinContext* ctx, IntlDateState* state, IntlDateFields* dt, HObject* parts, StrBuf* text, uint* count, char[] source) {
    char[32] num;
    usz num_len = 0;
    date_buf_append_num(num[..], &num_len, dt.year, 1);
    if (!intl_date_part(ctx, parts, text, "relatedYear", num[:num_len], count, source)) return false;
    long cycle = (dt.year - 4) % 60;
    if (cycle < 0) cycle += 60;
    if (state.zh_names) {
        return intl_date_part(ctx, parts, text, "yearName", (char[])LUNAR_YEAR_NAMES_ZH[cycle], count, source);
    }
    if (!intl_date_part(ctx, parts, text, "literal", "(", count, source)) return false;
    if (!intl_date_part(ctx, parts, text, "yearName", (char[])LUNAR_YEAR_NAMES_EN[cycle], count, source)) return false;
    return intl_date_part(ctx, parts, text, "literal", ")", count, source);
}

// Chinese month text: "4bis" for a leap month, as CLDR's {0}bis pattern gives; names otherwise.
fn void intl_lunar_month_text(IntlDateState* state, IntlDateFields* dt, int width, char[] buf, usz* len) {
    if (state.calendar_kind == CAL_HEBREW) {
        if (width < 3) {
            date_buf_append_num(buf, len, dt.month + 1, width);
            return;
        }
        // Common years have no "Adar II", so their indices after Adar shift by one name.
        usz name = (usz)dt.month;
        if (!dt.leap) {
            name = dt.month == 5 ? 6 : dt.month > 5 ? (usz)dt.month + 1 : (usz)dt.month;
        } else if (dt.month == 6) {
            name = 13;
        }
        date_buf_append(buf, len, (char[])HEBREW_MONTH_NAMES_EN[name]);
        return;
    }
    if (state.calendar_kind == CAL_ISLAMIC_CIVIL) {
        if (width < 3) {
            date_buf_append_num(buf, len, dt.month + 1, width);
        } else {
            date_buf_append(buf, len, (char[])LUNAR_MONTH_NAMES_HIJRI_EN[dt.month]);
        }
        return;
    }
    if (width < 3 || (dt.leap && !state.zh_names)) {
        date_buf_append_num(buf, len, dt.month + 1, width < 3 ? width : 1);
        if (dt.leap) date_buf_append(buf, len, "bis");
        return;
    }
    if (dt.leap) date_buf_append(buf, len, "闰");
    date_buf_append(buf, len, state.zh_names ? (char[])LUNAR_MONTH_NAMES_ZH[dt.month] : (char[])LUNAR_MONTH_NAMES_EN[dt.month]);
}

// The Hebrew calendar (Reingold and Dershowitz, Calendrical Calculations): years are counted from
// 1 Tishri AM 1, which is RD -1373427. Months are numbered from Tishri, so Adar falls at index 5
// in common years and Adar I / Adar II at 5 and 6 in leap years.
const long HEBREW_EPOCH_RD = -1373427;

struct HebrewDate {
    long year;
    long month;   // 0-based from Tishri
    long day;
    bool leap;    // the year has 13 months
}

fn long lunar_floor_mod(long a, long b) {
    return a - b * lunar_floor_div(a, b);
}

fn bool hebrew_leap_year(long y) {
    return lunar_floor_mod(7 * y + 1, 19) < 7;
}

fn long hebrew_elapsed_days(long y) {
    long months = lunar_floor_div(235 * y - 234, 19);
    long parts = 12084 + 13753 * months;
    long day = 29 * months + lunar_floor_div(parts, 25920);
    return lunar_floor_mod(3 * (day + 1), 7) < 3 ? day + 1 : day;
}

fn long hebrew_new_year(long y) {
    long previous = hebrew_elapsed_days(y - 1);
    long current = hebrew_elapsed_days(y);
    long next = hebrew_elapsed_days(y + 1);
    long correction = next - current == 356 ? 2 : current - previous == 382 ? 1 : 0;
    return HEBREW_EPOCH_RD + current + correction;
}

// The length of a month by its Tishri-based index. Heshvan is 30 days only in complete years (355
// days) and Kislev is 29 only in deficient years (353 days). Adar I has 30 days and Adar II 29.
fn long hebrew_month_length(long year_length, bool leap, long idx) {
    long heshvan = year_length % 10 == 5 ? 30 : 29;
    long kislev = year_length % 10 == 3 ? 29 : 30;
    if (leap) {
        long[13] leap_lengths = { 30, heshvan, kislev, 29, 30, 30, 29, 30, 29, 30, 29, 30, 29 };
        return leap_lengths[idx];
    }
    long[12] common_lengths = { 30, heshvan, kislev, 29, 30, 29, 30, 29, 30, 29, 30, 29 };
    return common_lengths[idx];
}

// The Hebrew date of a day counted as a fixed date (RD, 1 January 1 of the Gregorian calendar = 1).
fn HebrewDate hebrew_date(long rd) {
    long y = (long)math::floor((double)(rd - HEBREW_EPOCH_RD) / 365.24682) + 1;
    while (hebrew_new_year(y + 1) <= rd) y++;
    while (hebrew_new_year(y) > rd) y--;
    long year_length = hebrew_new_year(y + 1) - hebrew_new_year(y);
    bool leap = hebrew_leap_year(y);
    long remaining = rd - hebrew_new_year(y);
    long idx = 0;
    while (remaining >= hebrew_month_length(year_length, leap, idx)) {
        remaining -= hebrew_month_length(year_length, leap, idx);
        idx++;
    }
    HebrewDate out;
    out.year = y;
    out.month = idx;
    out.day = remaining + 1;
    out.leap = leap;
    return out;
}
