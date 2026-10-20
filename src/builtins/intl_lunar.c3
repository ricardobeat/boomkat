// The calendars DateTimeFormat computes beyond the Gregorian ones: Chinese and Dangi (Korean)
// lunisolar, Hebrew, and islamic-civil, and the Chinese year and month names. The calendar math
// is in lib/temporal (calendar_systems.c3 and lunisolar.c3).
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::lib::temporal;
import std::math;

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
