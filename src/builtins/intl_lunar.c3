// Calendar-specific names and lunisolar year parts. Calendar arithmetic lives in lib/temporal.
module boomkat::builtins;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::lib::temporal;
import std::math;

// The calendar a BCP 47 calendar type selects, when DateTimeFormat supports it.
fn bool intl_calendar(char[] name, CalendarId* out) {
    return temporal::calendar_from_name(name, out);
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
    if (state.calendar == HEBREW) {
        // CLDR-15510: Hebrew months use names at every width.
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
    if (state.calendar == ISLAMIC_CIVIL || state.calendar == ISLAMIC_TBLA || state.calendar == ISLAMIC_UMALQURA) {
        if (width < 3) {
            date_buf_append_num(buf, len, dt.month + 1, width);
        } else {
            date_buf_append(buf, len, (char[])LUNAR_MONTH_NAMES_HIJRI_EN[dt.month]);
        }
        return;
    }
    if (state.calendar != CHINESE && state.calendar != DANGI) {
        if (width < 3) { date_buf_append_num(buf, len, dt.month + 1, width); return; }
        String[] names;
        int months = state.calendar == COPTIC || state.calendar == ETHIOPIC || state.calendar == ETHIOAA ? 13 : 12;
        switch (state.calendar) {
            case COPTIC: names = CALENDAR_MONTH_NAMES_COPTIC[..];
            case ETHIOPIC: case ETHIOAA: names = CALENDAR_MONTH_NAMES_ETHIOPIC[..];
            case INDIAN: names = CALENDAR_MONTH_NAMES_INDIAN[..];
            case PERSIAN: names = CALENDAR_MONTH_NAMES_PERSIAN[..];
            default: return;
        }
        int block = width == 3 ? 1 : width == 5 ? 2 : 0;
        date_buf_append(buf, len, (char[])names[(long)(block * months) + dt.month]);
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
