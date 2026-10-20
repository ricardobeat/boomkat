// The non-ISO calendars Temporal.PlainDate can carry: chinese, dangi, hebrew and islamic-civil.
// A PlainDate always stores its ISO date; the calendar only changes what the getters report. The
// arithmetic comes from intl_lunar.c3, the same code DateTimeFormat formats with.
module boomkat::builtins @feat(!NO_TEMPORAL);

import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::lib::temporal;
import std::math;

const long TEMPORAL_UNIX_EPOCH_RD = 719163;       // fixed date (RD) of 1970-01-01
const long TEMPORAL_UNIX_EPOCH_JD = 2440588;      // Julian day number of 1970-01-01

// What the PlainDate getters report for a date in a non-ISO calendar.
struct CalendarFields {
    long year;
    long month;           // ordinal, 1-based
    long day;
    long month_number;    // the number in monthCode, "M04" or "M04L"
    bool leap_month;
    long days_in_month;
    long days_in_year;
    long months_in_year;
    bool in_leap_year;
    long year_start;      // day number (since 1970-01-01) of the year's first day
    bool has_era;
    char[] era;
    long era_year;
}

// The CAL_* kind of a calendar singleton, 0 for the ISO calendar.
fn int temporal_calendar_kind(Heap* heap, HObject* calendar) {
    for (int i = 0; i < 4; i++) {
        if (heap.temporal_alt_calendars[i] == calendar) return i + 1;
    }
    return 0;
}

fn CalendarFields temporal_calendar_fields(int kind, temporal::CivilDate date) {
    long days = temporal::epoch_days_from_civil(date.y, (int)date.m, (int)date.d);
    CalendarFields f;
    switch (kind) {
        case CAL_ISLAMIC_CIVIL: {
            HijriDate h = islamic_civil_date(days);
            bool leap = lunar_floor_mod(14 + 11 * h.year, 30) < 11;
            f.year = h.year;
            f.month = h.month + 1;
            f.day = h.day;
            f.month_number = f.month;
            f.days_in_month = 29 + (h.month + 1) % 2 + ((h.month == 11 && leap) ? 1 : 0);
            f.days_in_year = leap ? 355 : 354;
            f.months_in_year = 12;
            f.in_leap_year = leap;
            f.year_start = hijri_year_start(h.year) + HIJRI_EPOCH_JD - TEMPORAL_UNIX_EPOCH_JD;
            f.has_era = true;
            f.era = h.year > 0 ? "ah" : "bh";
            f.era_year = h.year > 0 ? h.year : 1 - h.year;
        }
        case CAL_HEBREW: {
            HebrewDate h = hebrew_date(days + TEMPORAL_UNIX_EPOCH_RD);
            long year_length = hebrew_new_year(h.year + 1) - hebrew_new_year(h.year);
            f.year = h.year;
            f.month = h.month + 1;
            f.day = h.day;
            // Month codes count from Tishri; Adar I is the leap month M05L.
            if (!h.leap || h.month < 5) {
                f.month_number = h.month + 1;
            } else if (h.month == 5) {
                f.month_number = 5;
                f.leap_month = true;
            } else {
                f.month_number = h.month;
            }
            f.days_in_month = hebrew_month_length(year_length, h.leap, h.month);
            f.days_in_year = year_length;
            f.months_in_year = h.leap ? 13 : 12;
            f.in_leap_year = h.leap;
            f.year_start = hebrew_new_year(h.year) - TEMPORAL_UNIX_EPOCH_RD;
            f.has_era = true;
            f.era = "am";
            f.era_year = h.year;
        }
        default: {
            bool dangi = kind == CAL_DANGI;
            LunarDate l = lunar_date(dangi, days);
            long new_year = lunar_new_year(dangi, l.related_year);
            long next_new_year = lunar_new_year(dangi, l.related_year + 1);
            long next_moon = lunar_new_moon_near(dangi, (double)(l.this_moon + LUNAR_SYNODIC_GAP), true);
            f.year = l.related_year;
            f.month = l.ordinal + 1;
            f.day = l.day;
            f.month_number = l.month;
            f.leap_month = l.leap;
            f.days_in_month = next_moon - l.this_moon;
            f.days_in_year = next_new_year - new_year;
            f.months_in_year = lunar_synodic_between(new_year, next_new_year);
            f.in_leap_year = f.months_in_year == 13;
            f.year_start = new_year;
        }
    }
    return f;
}

// Fills `out` and returns the calendar kind of a PlainDate; 0 means the ISO calendar and leaves
// `out` untouched.
fn int plain_date_calendar_fields(BuiltinContext* ctx, HObject* obj, CalendarFields* out) {
    int kind = temporal_calendar_kind(ctx.heap, obj.extra.temporal.calendar);
    if (kind != 0) *out = temporal_calendar_fields(kind, plain_date_value(obj));
    return kind;
}

// Throws for a PlainDate whose calendar the operation cannot honor, and returns true. Arithmetic,
// field merging and conversions need the calendar's own month and year rules; until they exist
// they refuse instead of answering in the ISO calendar.
fn bool plain_date_reject_alt_calendar(BuiltinContext* ctx, HObject* obj) {
    if (temporal_calendar_kind(ctx.heap, obj.extra.temporal.calendar) == 0) return false;
    builtin_throw(ctx, ctx.heap.range_err_proto, "this operation is not supported for a non-ISO calendar");
    return true;
}

// Resolves a calendar identifier string to its singleton: the ISO calendar or one of the non-ISO
// ones. Returns false when the text names neither.
fn bool temporal_calendar_singleton(Heap* heap, char[] text, HObject** out) {
    int kind = 0;
    if (temporal::ci_equals(text, "chinese")) {
        kind = CAL_CHINESE;
    } else if (temporal::ci_equals(text, "dangi")) {
        kind = CAL_DANGI;
    } else if (temporal::ci_equals(text, "islamic-civil") || temporal::ci_equals(text, "islamicc")) {
        kind = CAL_ISLAMIC_CIVIL;
    } else if (temporal::ci_equals(text, "hebrew")) {
        kind = CAL_HEBREW;
    }
    if (kind == 0) return false;
    *out = heap.temporal_alt_calendars[kind - 1];
    return true;
}

// Resolves the calendar argument of the PlainDate constructor and withCalendar: a non-ISO
// identifier string yields its singleton, a PlainDate yields its own calendar, and anything else
// follows the ISO-only rules.
fn bool plain_date_calendar_arg(BuiltinContext* ctx, TVal* tv, HObject** out, bool parse_iso_string) {
    if (tv.is_string()) {
        HString* s = (HString*)tv.get_heapptr();
        if (s != null && !s.is_symbol() && temporal_calendar_singleton(ctx.heap, s.get_cstr()[:s.blen], out)) return true;
    } else if (tv.is_object() && tv.get_heapptr() != null) {
        HObject* o = (HObject*)tv.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
            *out = o.extra.temporal.calendar;
            return true;
        }
    }
    if (parse_iso_string) return calendar_from_arg(ctx, tv, out);
    return to_temporal_calendar_identifier(ctx, tv, out);
}

// The identifier a calendar singleton reports through calendarId and the u-ca annotation.
fn char[] temporal_calendar_id(Heap* heap, HObject* calendar) {
    switch (temporal_calendar_kind(heap, calendar)) {
        case CAL_CHINESE: return "chinese";
        case CAL_DANGI: return "dangi";
        case CAL_ISLAMIC_CIVIL: return "islamic-civil";
        case CAL_HEBREW: return "hebrew";
        default: return "iso8601";
    }
}
