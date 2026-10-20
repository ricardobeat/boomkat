// The astronomical and arithmetic cores of the lunisolar and lunar calendars: Chinese and Dangi
// (Korean) months from low-precision solar and lunar longitudes (Duffett-Smith, as in ICU's
// astro.cpp), searched in each calendar's astronomy zone, with the month and year rules of ICU's
// chnsecal.cpp; the tabular Hijri calendar of ICU's islamcal.cpp; and the Hebrew calendar.
module boomkat::lib::temporal;

import std::math;

const double LUNAR_PI = 3.14159265358979323846;
const double LUNAR_TWO_PI = LUNAR_PI * 2.0;
const double LUNAR_DAY_MS = 86400000.0;
const double LUNAR_MINUTE_MS = 60000.0;
const double LUNAR_TROPICAL_YEAR = 365.242191;
const double LUNAR_SYNODIC_MONTH = 29.530588853;
const long LUNAR_SYNODIC_GAP = 25;
const long LUNAR_CYCLE_EPOCH = -2636;

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
    long ordinal;    // months since the Chinese new year, 0-based
    long this_moon;  // day number of the first day of the month
}

fn double lunar_normalize(double value, double range) {
    return value - range * math::floor(value / range);
}

fn double lunar_norm2pi(double angle) { return lunar_normalize(angle, LUNAR_TWO_PI); }

fn double lunar_normpi(double angle) {
    return lunar_normalize(angle + LUNAR_PI, LUNAR_TWO_PI) - LUNAR_PI;
}

// The sun's apparent ecliptic longitude in radians at a UTC time in milliseconds (Reingold and
// Dershowitz, Calendrical Calculations, after Meeus: 49 periodic terms, aberration and nutation).
fn double lunar_sun_angle(double millis) {
    double days_since_j2000 = millis / LUNAR_DAY_MS + 2440587.5 - 2451545.0;
    double c = (days_since_j2000 + lunar_delta_t(2000 + days_since_j2000 / 365.25) / 86400.0) / 36525.0;
    double[3][49] terms = {
        { 403406, 0.9287892, 270.54861 }, { 195207, 35999.1376958, 340.19128 }, { 119433, 35999.4089666, 63.91854 },
        { 112392, 35998.7287385, 331.26220 }, { 3891, 71998.20261, 317.843 }, { 2819, 71998.4403, 86.631 },
        { 1721, 36000.35726, 240.052 }, { 660, 71997.4812, 310.26 }, { 350, 32964.4678, 247.23 },
        { 334, -19.4410, 260.87 }, { 314, 445267.1117, 297.82 }, { 268, 45036.8840, 343.14 },
        { 242, 3.1008, 166.79 }, { 234, 22518.4434, 81.53 }, { 158, -19.9739, 3.50 },
        { 132, 65928.9345, 132.75 }, { 129, 9038.0293, 182.95 }, { 114, 3034.7684, 162.03 },
        { 99, 33718.148, 29.8 }, { 93, 3034.448, 266.4 }, { 86, -2280.773, 249.2 },
        { 78, 29929.992, 157.6 }, { 72, 31556.493, 257.8 }, { 68, 149.588, 185.1 },
        { 64, 9037.750, 69.9 }, { 46, 107997.405, 8.0 }, { 38, -4444.176, 197.1 },
        { 37, 151.771, 250.4 }, { 32, 67555.328, 65.3 }, { 29, 31556.080, 162.7 },
        { 28, -4561.540, 341.5 }, { 27, 107996.706, 291.6 }, { 27, 1221.655, 98.5 },
        { 25, 62894.167, 146.7 }, { 24, 31437.369, 110.0 }, { 21, 14578.298, 5.2 },
        { 21, -31931.757, 342.6 }, { 20, 34777.259, 230.9 }, { 18, 1221.999, 256.1 },
        { 17, 62894.511, 45.3 }, { 14, -4442.039, 242.9 }, { 13, 107997.909, 115.2 },
        { 13, 119.066, 151.8 }, { 13, 16859.071, 285.3 }, { 12, -4.578, 53.3 },
        { 10, 26895.292, 126.6 }, { 10, -39.127, 205.7 }, { 10, 12297.536, 85.9 },
        { 10, 90073.778, 146.1 },
    };
    double sum = 0;
    foreach (term : terms) sum += term[0] * math::sin((term[1] * c + term[2]) * LUNAR_PI / 180);
    double longitude = 282.7771834 + 36000.76953744 * c + 0.000005729577951308232 * sum;
    double aberration = 0.0000974 * math::cos((177.63 + 35999.01848 * c) * LUNAR_PI / 180) - 0.005575;
    double nutation = -0.004778 * math::sin((124.90 - 1934.134 * c + 0.002063 * c * c) * LUNAR_PI / 180)
        - 0.0003667 * math::sin((201.11 + 72001.5377 * c + 0.00057 * c * c) * LUNAR_PI / 180);
    return lunar_norm2pi((longitude + aberration + nutation) * LUNAR_PI / 180);
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

// The first time after (or before) start at which the sun's longitude equals desired, refined by the
// secant-like step ICU uses. A step that grows restarts an eighth of a period further on.
fn double lunar_time_of_angle(double desired, double period_days, double start, bool next) {
    double t = start;
    double last_angle = lunar_sun_angle(t);
    double delta_angle = lunar_norm2pi(desired - last_angle);
    double delta_t = (delta_angle + (next ? 0.0 : -LUNAR_TWO_PI)) * (period_days * LUNAR_DAY_MS) / LUNAR_TWO_PI;
    double last_delta_t = delta_t;
    t = t + math::ceil(delta_t);
    do {
        double angle = lunar_sun_angle(t);
        double factor = math::abs(delta_t / lunar_normpi(angle - last_angle));
        delta_t = lunar_normpi(desired - angle) * factor;
        if (math::abs(delta_t) > math::abs(last_delta_t)) {
            double delta = math::ceil(period_days * LUNAR_DAY_MS / 8.0);
            return lunar_time_of_angle(desired, period_days, start + (next ? delta : -delta), next);
        }
        last_delta_t = delta_t;
        last_angle = angle;
        t = t + math::ceil(delta_t);
    } while (math::abs(delta_t) > LUNAR_MINUTE_MS);
    return t;
}

// TT - UT in seconds for a decimal year (Espenak and Meeus polynomials, 1900 to 2150).
fn double lunar_delta_t(double y) {
    double t;
    if (y >= 1900 && y < 1920) { t = y - 1900; return -2.79 + t * (1.494119 + t * (-0.0598939 + t * (0.0061966 - t * 0.000197))); }
    if (y >= 1920 && y < 1941) { t = y - 1920; return 21.20 + t * (0.84493 + t * (-0.0761 + t * 0.0020936)); }
    if (y >= 1941 && y < 1961) { t = y - 1950; return 29.07 + 0.407 * t - t * t / 233 + t * t * t / 2547; }
    if (y >= 1961 && y < 1986) { t = y - 1975; return 45.45 + 1.067 * t - t * t / 260 - t * t * t / 718; }
    if (y >= 1986 && y < 2005) { t = y - 2000; return 63.86 + t * (0.3345 + t * (-0.060374 + t * (0.0017275 + t * (0.000651814 + t * 0.00002373599)))); }
    if (y >= 2005 && y < 2050) { t = y - 2000; return 62.92 + t * (0.32217 + t * 0.005589); }
    double u = (y - 1820) / 100;
    return -20 + 32 * u * u - (y >= 2050 && y < 2150 ? 0.5628 * (2150 - y) : 0.0);
}

// The UT instant (milliseconds) of the new moon with lunation number k (Meeus, Astronomical
// Algorithms ch. 49; k = 0 is the new moon of 2000-01-06).
fn double lunar_new_moon_time(long k) {
    double kk = (double)k;
    double t = kk / 1236.85;
    double t2 = t * t;
    double t3 = t2 * t;
    double e = 1 - 0.002516 * t - 0.0000074 * t2;
    double rad = LUNAR_PI / 180;
    double m = (2.5534 + 29.1053567 * kk - 0.0000014 * t2 - 0.00000011 * t3) * rad;
    double mp = (201.5643 + 385.81693528 * kk + 0.0107582 * t2 + 0.00001238 * t3 - 0.000000058 * t3 * t) * rad;
    double f = (160.7108 + 390.67050284 * kk - 0.0016118 * t2 - 0.00000227 * t3 + 0.000000011 * t3 * t) * rad;
    double om = (124.7746 - 1.56375588 * kk + 0.0020672 * t2 + 0.00000215 * t3) * rad;
    double jde = 2451550.09766 + 29.530588861 * kk + 0.00015437 * t2 - 0.00000015 * t3 + 0.00000000073 * t3 * t;
    // coefficient, then multiples of M, M', F and the node; e is raised to |M multiple|.
    double[5][25] terms = {
        { -0.40720, 0, 1, 0, 0 }, { 0.17241, 1, 0, 0, 0 }, { 0.01608, 0, 2, 0, 0 }, { 0.01039, 0, 0, 2, 0 },
        { 0.00739, -1, 1, 0, 0 }, { -0.00514, 1, 1, 0, 0 }, { 0.00208, 2, 0, 0, 0 }, { -0.00111, 0, 1, -2, 0 },
        { -0.00057, 0, 1, 2, 0 }, { 0.00056, 1, 2, 0, 0 }, { -0.00042, 0, 3, 0, 0 }, { 0.00042, 1, 0, 2, 0 },
        { 0.00038, 1, 0, -2, 0 }, { -0.00024, -1, 2, 0, 0 }, { -0.00017, 0, 0, 0, 1 }, { -0.00007, 2, 1, 0, 0 },
        { 0.00004, 0, 2, -2, 0 }, { 0.00004, 3, 0, 0, 0 }, { 0.00003, 1, 1, -2, 0 }, { 0.00003, 0, 2, 2, 0 },
        { -0.00003, 1, 1, 2, 0 }, { 0.00003, -1, 1, 2, 0 }, { -0.00002, -1, 1, -2, 0 }, { -0.00002, 1, 3, 0, 0 },
        { 0.00002, 0, 4, 0, 0 },
    };
    double correction = 0;
    foreach (term : terms) {
        double weight = math::pow(e, math::abs(term[1]));
        correction += term[0] * weight * math::sin(term[1] * m + term[2] * mp + term[3] * f + term[4] * om);
    }
    // Planetary arguments: constant, rate in k, then the coefficient.
    double[3][14] planets = {
        { 299.77, 0.107408, 0.000325 }, { 251.88, 0.016321, 0.000165 }, { 251.83, 26.651886, 0.000164 },
        { 349.42, 36.412478, 0.000126 }, { 84.66, 18.206239, 0.000110 }, { 141.74, 53.303771, 0.000062 },
        { 207.14, 2.453732, 0.000060 }, { 154.84, 7.306860, 0.000056 }, { 34.52, 27.261239, 0.000047 },
        { 207.19, 0.121824, 0.000042 }, { 291.34, 1.844379, 0.000040 }, { 161.72, 24.198154, 0.000037 },
        { 239.56, 25.513099, 0.000035 }, { 331.55, 3.592518, 0.000023 },
    };
    foreach (i, planet : planets) {
        double arg = planet[0] + planet[1] * kk - (i == 0 ? 0.009173 * t2 : 0.0);
        correction += planet[2] * math::sin(arg * rad);
    }
    jde += correction;
    double year = 2000 + (jde - 2451544.5) / 365.25;
    return (jde - 2440587.5) * LUNAR_DAY_MS - lunar_delta_t(year) * 1000.0;
}

// The closest new moon on or after (or before) days, as a day number in the astronomy zone.
fn long lunar_new_moon_near(bool dangi, double days, bool after) {
    double millis = lunar_days_to_millis(dangi, days);
    long k = (long)math::floor(((millis / LUNAR_DAY_MS + 2440587.5) - 2451550.09766) / LUNAR_SYNODIC_MONTH);
    if (after) {
        k--;
        while (lunar_new_moon_time(k) < millis) k++;
        return (long)lunar_millis_to_days(dangi, lunar_new_moon_time(k));
    }
    k += 2;
    while (lunar_new_moon_time(k) > millis) k--;
    return (long)lunar_millis_to_days(dangi, lunar_new_moon_time(k));
}

// The day of the winter solstice (270 degrees of solar longitude) that follows December 1 of gyear.
fn long lunar_winter_solstice(bool dangi, long gyear) {
    double millis = lunar_days_to_millis(dangi, (double)epoch_days_from_civil(gyear, 12, 1));
    double t = lunar_time_of_angle(LUNAR_PI * 3 / 2, LUNAR_TROPICAL_YEAR, millis, true);
    return (long)lunar_millis_to_days(dangi, t);
}

// The major solar term (1..12) in force on a day: 1 at 330 degrees, 2 at 0, 3 at 30, and so on.
fn long lunar_major_term(bool dangi, long days) {
    double longitude = lunar_sun_angle(lunar_days_to_millis(dangi, (double)days));
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
    BrokenDownTime civil = civil_from_seconds(days * 86400);
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
    out.ordinal = month.ordinal;
    out.this_moon = month.this_moon;
    return out;
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
