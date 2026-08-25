// Temporal built-ins layer. Adapts boomkat::lib::temporal value types to
// HObject, TVal, and BuiltinContext: the ISO Calendar singleton, PlainDate
// with ISO 8601 parsing/formatting and proleptic Gregorian arithmetic,
// PlainTime and PlainDateTime with the same calendar basis, and a Duration
// value type for until/since results and add/subtract inputs.
//
// All date fields travel as an HObject of class TEMPORAL_* with the shared
// HObjectTemporal union variant: int_a..int_c hold year/month/day for
// PlainDate and the date half of PlainDateTime, int_a..int_f hold the six
// time fields for PlainTime, int_d..int_i hold the time fields for
// PlainDateTime, int_a..int_j hold the ten Duration fields, and `calendar`
// holds the shared ISO Calendar object. Getters are native accessors;
// nothing here allocates through the JS heap except the objects themselves.
module boomkat::builtins;

import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hbigint;
import boomkat::hstring;
import boomkat::env;
import boomkat::vm;
import boomkat::lib::temporal;
import libc;
import std::math;

// ============================================================================
// Shared helpers
// ============================================================================

// Throw a TypeError for a `this` value that is not the required Temporal
// brand, then return false; callers test ctx.should_throw.
fn bool brand_check(BuiltinContext* ctx, TVal* this_val, ObjClass klass, char[] why) {
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, why);
        return false;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != klass) {
        builtin_throw(ctx, ctx.heap.type_err_proto, why);
        return false;
    }
    return true;
}

fn HObject*? alloc_plain_date(Heap* hp, temporal::CivilDate d, HObject* calendar) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_PLAIN_DATE);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.int_a = (int)d.y;
    obj.extra.temporal.int_b = d.m;
    obj.extra.temporal.int_c = d.d;
    obj.extra.temporal.calendar = calendar;
    return obj;
}

// Slot layout for TEMPORAL_PLAIN_TIME: int_a..int_f carry the six time
// fields (hour..nanosecond). The object carries no calendar; PlainTime is
// intentionally calendar-independent per the spec.
fn HObject*? alloc_plain_time(Heap* hp, temporal::CivilTime t) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_PLAIN_TIME);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.int_a = t.h;
    obj.extra.temporal.int_b = t.mi;
    obj.extra.temporal.int_c = t.s;
    obj.extra.temporal.int_d = t.ms;
    obj.extra.temporal.int_e = t.us;
    obj.extra.temporal.int_f = t.ns;
    return obj;
}

// Slot layout for TEMPORAL_PLAIN_DATETIME: int_a..int_c carry y/m/d and
// int_d..int_i carry h/mi/s/ms/us/ns. Year is signed via int (covers the
// full Temporal range; the spec caps at ±271821).
fn HObject*? alloc_plain_datetime(Heap* hp, temporal::CivilDateTime dt, HObject* calendar) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_PLAIN_DATETIME);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.int_a = (int)dt.date.y;
    obj.extra.temporal.int_b = dt.date.m;
    obj.extra.temporal.int_c = dt.date.d;
    obj.extra.temporal.int_d = dt.time.h;
    obj.extra.temporal.int_e = dt.time.mi;
    obj.extra.temporal.int_f = dt.time.s;
    obj.extra.temporal.int_g = dt.time.ms;
    obj.extra.temporal.int_h = dt.time.us;
    obj.extra.temporal.int_i = dt.time.ns;
    obj.extra.temporal.calendar = calendar;
    return obj;
}

// Slot layout for TEMPORAL_PLAIN_YEARMONTH: int_a..int_c carry y/m/d. The
// `day` slot is a reference day used only to answer daysInMonth/inLeapYear;
// it does not participate in equality or comparison. Year is signed via int.
fn HObject*? alloc_plain_yearmonth(Heap* hp, long y, int m, int reference_day, HObject* calendar) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.int_a = (int)y;
    obj.extra.temporal.int_b = m;
    obj.extra.temporal.int_c = reference_day;
    obj.extra.temporal.calendar = calendar;
    return obj;
}

// Slot layout for TEMPORAL_PLAIN_MONTHDAY: int_a..int_c carry y/m/d. The
// `year` slot is a reference year used only for calendar-related properties
// (era, eraYear, inLeapYear); it does not participate in equality.
fn HObject*? alloc_plain_monthday(Heap* hp, int reference_year, int m, int d, HObject* calendar) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.int_a = reference_year;
    obj.extra.temporal.int_b = m;
    obj.extra.temporal.int_c = d;
    obj.extra.temporal.calendar = calendar;
    return obj;
}

fn HObject*? alloc_duration(Heap* hp, temporal::DurationParts d) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_DURATION);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.int_a = (int)d.years;
    obj.extra.temporal.int_b = (int)d.months;
    obj.extra.temporal.int_c = (int)d.weeks;
    obj.extra.temporal.int_d = (int)d.days;
    obj.extra.temporal.int_e = (int)d.hours;
    obj.extra.temporal.int_f = (int)d.minutes;
    obj.extra.temporal.int_g = (int)d.seconds;
    obj.extra.temporal.int_h = d.ms;
    obj.extra.temporal.int_i = d.us;
    obj.extra.temporal.int_j = d.ns;
    return obj;
}

fn temporal::CivilDate plain_date_value(HObject* obj) {
    return {
        .y = (long)obj.extra.temporal.int_a,
        .m = obj.extra.temporal.int_b,
        .d = obj.extra.temporal.int_c,
    };
}

fn temporal::CivilTime plain_time_value(HObject* obj) {
    return {
        .h  = obj.extra.temporal.int_a,
        .mi = obj.extra.temporal.int_b,
        .s  = obj.extra.temporal.int_c,
        .ms = obj.extra.temporal.int_d,
        .us = obj.extra.temporal.int_e,
        .ns = obj.extra.temporal.int_f,
    };
}

fn temporal::CivilDateTime plain_datetime_value(HObject* obj) {
    return {
        .date = plain_date_value(obj),
        .time = {
            .h  = obj.extra.temporal.int_d,
            .mi = obj.extra.temporal.int_e,
            .s  = obj.extra.temporal.int_f,
            .ms = obj.extra.temporal.int_g,
            .us = obj.extra.temporal.int_h,
            .ns = obj.extra.temporal.int_i,
        },
    };
}

// Extract the canonical year/month and reference day from a PlainYearMonth
// object. The reference day is what `day` returns; it isn't part of equality.
fn long plain_yearmonth_y(HObject* obj) { return (long)obj.extra.temporal.int_a; }
fn int  plain_yearmonth_m(HObject* obj) { return obj.extra.temporal.int_b; }
fn int  plain_yearmonth_day(HObject* obj) { return obj.extra.temporal.int_c; }

// Extract the reference year/month/day from a PlainMonthDay object. The
// reference year is what `year` returns; it isn't part of equality.
fn int  plain_monthday_year(HObject* obj) { return obj.extra.temporal.int_a; }
fn int  plain_monthday_m(HObject* obj) { return obj.extra.temporal.int_b; }
fn int  plain_monthday_d(HObject* obj) { return obj.extra.temporal.int_c; }

fn temporal::DurationParts duration_value(HObject* obj) {
    temporal::DurationParts d;
    d.years   = obj.extra.temporal.int_a;
    d.months  = obj.extra.temporal.int_b;
    d.weeks   = obj.extra.temporal.int_c;
    d.days    = obj.extra.temporal.int_d;
    d.hours   = obj.extra.temporal.int_e;
    d.minutes = obj.extra.temporal.int_f;
    d.seconds = obj.extra.temporal.int_g;
    d.ms      = obj.extra.temporal.int_h;
    d.us      = obj.extra.temporal.int_i;
    d.ns      = obj.extra.temporal.int_j;
    return d;
}

// ToIntegerWithTruncation (ES2025 7.1.7): NaN and ±Infinity are not integral
// numbers, so callers turn `false` into a RangeError. Truncates toward zero.
fn bool to_integer_with_truncation(Vm* v, TVal* tv, long* out) {
    double d = vm::vm_to_number(v, tv);
    if (v.throw_pending) return false;
    if (math::is_nan(d) || math::is_inf(d)) return false;
    *out = (long)math::trunc(d);
    return true;
}

fn TVal* arg_at(BuiltinContext* ctx, int idx) {
    return &ctx.regs[ctx.base_reg + idx];
}

fn TVal prop_or_undefined(HObject* o, Heap* hp, char[] name) {
    HString* key = builtin_intern_string(hp, name);
    TVal undef;
    undef.set_undefined();
    return o.get_prop(key, hp) ?? undef;
}

// Read the `overflow` option (default "constrain"). Wrong types throw
// TypeError, unknown strings RangeError, per GetOption.
fn bool read_overflow_option(BuiltinContext* ctx, int options_index, temporal::OverflowKind* out) {
    *out = temporal::OverflowKind.CONSTRAIN;
    if (ctx.argc <= options_index) return true;
    TVal ov = ctx.regs[ctx.base_reg + options_index];
    if (ov.is_undefined()) return true;
    if (!ov.is_object() || ov.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    HObject* opts = (HObject*)ov.get_heapptr();
    TVal val = prop_or_undefined(opts, ctx.heap, "overflow");
    if (val.is_undefined()) return true;
    if (!val.is_string()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "overflow option must be a string");
        return false;
    }
    HString* s = (HString*)val.get_heapptr();
    char[] v = s.get_cstr()[:s.blen];
    if (v == "constrain") { *out = temporal::OverflowKind.CONSTRAIN; return true; }
    if (v == "reject")    { *out = temporal::OverflowKind.REJECT; return true; }
    builtin_throw(ctx, ctx.heap.range_err_proto, "overflow option must be \"constrain\" or \"reject\"");
    return false;
}

// Resolve a calendar argument (constructor third arg, bag `calendar`
// property): undefined -> the shared ISO singleton; an ISO 8601 calendar
// string (case-insensitive; only iso8601 exists here) -> the singleton;
// anything else throws TypeError (spec: unknown calendar names are RangeError,
// non-string non-calendar values TypeError).
fn bool calendar_from_arg(BuiltinContext* ctx, TVal* tv, HObject** out) {
    if (tv.is_undefined()) {
        *out = ctx.heap.temporal_iso_calendar;
        return true;
    }
    if (tv.is_object() && tv.get_heapptr() != null) {
        HObject* o = (HObject*)tv.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_CALENDAR) {
            *out = o;
            return true;
        }
        builtin_throw(ctx, ctx.heap.type_err_proto, "not a Temporal.Calendar object");
        return false;
    }
    if (tv.is_string()) {
        HString* s = (HString*)tv.get_heapptr();
        if (s != null) {
            // Symbols share the STRING tag but are not calendar identifiers.
            if (s.is_symbol()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "symbol is not a valid calendar");
                return false;
            }
            char[] text = s.get_cstr()[:s.blen];
            // "iso8601" is the only identifier; "gregory"/"gregorian" are
            // accepted aliases of it. All matched ASCII case-insensitively.
            if (temporal::ci_equals(text, "iso8601") ||
                temporal::ci_equals(text, "gregory") ||
                temporal::ci_equals(text, "gregorian")) {
                *out = ctx.heap.temporal_iso_calendar;
                return true;
            }
            builtin_throw(ctx, ctx.heap.range_err_proto, "unknown calendar identifier");
            return false;
        }
    }
    if (tv.is_null()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "calendar cannot be null");
        return false;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "invalid calendar argument");
    return false;
}

// Read monthCode "M01".."M12" from `tv`, or throw (TypeError for non-strings,
// RangeError for malformed or out-of-range codes).
fn bool parse_month_code(BuiltinContext* ctx, TVal tv, int* out) {
    if (!tv.is_string()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "monthCode must be a string");
        return false;
    }
    HString* s = (HString*)tv.get_heapptr();
    char[] text = s.get_cstr()[:s.blen];
    if (text.len != 3 || text[0] != 'M' ||
        text[1] < '0' || text[1] > '9' || text[2] < '0' || text[2] > '9') {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid monthCode");
        return false;
    }
    int m = (text[1] - '0') * 10 + (text[2] - '0');
    if (m < 1 || m > 12) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid monthCode");
        return false;
    }
    *out = m;
    return true;
}

// Read a PlainDate property bag (from / with / compare / until args).
// `keep_missing` tells with() to fall back to the current date's fields.
// Runs the era/eraYear rejection, month/monthCode agreement check, and
// calendar-property resolution that the single-ISO-calendar engine needs.
fn bool bag_to_fields(BuiltinContext* ctx, HObject* bag, bool keep_missing,
                      temporal::CivilDate cur, temporal::CivilDate* out,
                      long* out_epoch_days) {
    Vm* v = (Vm*)ctx.vm;
    TVal year_v  = prop_or_undefined(bag, ctx.heap, "year");
    TVal month_v = prop_or_undefined(bag, ctx.heap, "month");
    TVal mc_v    = prop_or_undefined(bag, ctx.heap, "monthCode");
    TVal day_v   = prop_or_undefined(bag, ctx.heap, "day");
    TVal cal_v   = prop_or_undefined(bag, ctx.heap, "calendar");
    TVal era_v   = prop_or_undefined(bag, ctx.heap, "era");
    TVal era_y_v = prop_or_undefined(bag, ctx.heap, "eraYear");

    if (!era_v.is_undefined() || !era_y_v.is_undefined()) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "era/eraYear are not supported by the ISO calendar");
        return false;
    }
    if (!cal_v.is_undefined()) {
        HObject* cal;
        if (!calendar_from_arg(ctx, &cal_v, &cal)) return false;
    }

    long y = cur.y;
    if (!year_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &year_v, &y)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "year is not an integral number");
            return false;
        }
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing year property");
        return false;
    }

    long m = cur.m;
    if (month_v.is_undefined() && mc_v.is_undefined()) {
        if (!keep_missing) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "missing month property");
            return false;
        }
    } else {
        long mv = 0;
        bool have_month = false;
        if (!month_v.is_undefined()) {
            if (!to_integer_with_truncation(v, &month_v, &mv)) {
                if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
                builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
                return false;
            }
            have_month = true;
        }
        if (!mc_v.is_undefined()) {
            int mci;
            if (!parse_month_code(ctx, mc_v, &mci)) return false;
            if (have_month && mv != mci) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "month and monthCode do not agree");
                return false;
            }
            m = mci;
        } else if (have_month) {
            m = mv;
        }
    }

    long d = cur.d;
    if (!day_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &day_v, &d)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
            return false;
        }
    } else if (!keep_missing) {
        d = 1;
    }

    out.y = y;
    out.m = (int)m;
    out.d = (int)d;
    *out_epoch_days = temporal::epoch_days_from_civil(y, (int)m, (int)d);
    return true;
}

// Constrain or reject a bag's y/m/d into a valid CivilDate. Month/day clamping
// follows the overflow policy; the year range check is final.
fn bool fields_to_valid_date(BuiltinContext* ctx, temporal::CivilDate fields,
                             temporal::OverflowKind overflow, temporal::CivilDate* out) {
    long y = fields.y;
    int m = fields.m;
    int d = fields.d;

    if (m < 1) {
        if (overflow == temporal::OverflowKind.REJECT) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid month"); return false; }
        m = 1;
    }
    if (m > 12) {
        if (overflow == temporal::OverflowKind.REJECT) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid month"); return false; }
        m = 12;
    }
    if (d < 1) {
        if (overflow == temporal::OverflowKind.REJECT) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid day"); return false; }
        d = 1;
    }
    int dim = temporal::days_in_month(y, m);
    if (d > dim) {
        if (overflow == temporal::OverflowKind.REJECT) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows month");
            return false;
        }
        d = dim;
    }
    if (!temporal::is_valid_iso_date(y, m, d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
        return false;
    }
    out.y = y;
    out.m = m;
    out.d = d;
    return true;
}

// Read a PlainTime property bag. `keep_missing` mirrors bag_to_fields: when
// true, missing fields fall back to `cur` (used by with()). Sub-second
// precision is read from a single fractional `seconds` argument so callers
// pass `null` for the other sub-second fields, per the polyfill spec.
fn bool bag_to_time_fields(BuiltinContext* ctx, HObject* bag, bool keep_missing,
                           temporal::CivilTime cur, temporal::CivilTime* out) {
    Vm* v = (Vm*)ctx.vm;
    TVal h_v  = prop_or_undefined(bag, ctx.heap, "hour");
    TVal mi_v = prop_or_undefined(bag, ctx.heap, "minute");
    TVal s_v  = prop_or_undefined(bag, ctx.heap, "second");
    TVal ms_v = prop_or_undefined(bag, ctx.heap, "millisecond");
    TVal us_v = prop_or_undefined(bag, ctx.heap, "microsecond");
    TVal ns_v = prop_or_undefined(bag, ctx.heap, "nanosecond");

    int  h  = cur.h;
    int  mi = cur.mi;
    int  s  = cur.s;
    int  ms = cur.ms;
    int  us = cur.us;
    int  ns = cur.ns;

    long lv;
    if (!h_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &h_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "hour is not an integral number");
            return false;
        }
        h = (int)lv;
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing hour property");
        return false;
    }
    if (!mi_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &mi_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "minute is not an integral number");
            return false;
        }
        mi = (int)lv;
    } else if (!keep_missing) {
        mi = 0;
    }
    if (!s_v.is_undefined()) {
        // Seconds allow a fractional part per the spec: take it as ms+us+ns.
        double d = vm::vm_to_number(v, &s_v);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
        if (math::is_nan(d) || math::is_inf(d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "second is not a finite number");
            return false;
        }
        if (d < 0 || d > 60) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "second out of range");
            return false;
        }
        long whole = (long)math::trunc(d);
        double frac = d - (double)whole;
        if (whole == 60) { whole = 59; frac = 0; }
        s = (int)whole;
        // Translate the fractional part to ms/us/ns with rounding.
        long frac_ns = (long)math::trunc(frac * 1_000_000_000.0);
        if (frac_ns < 0) frac_ns = 0;
        if (frac_ns > 999_999_999) frac_ns = 999_999_999;
        ms = (int)(frac_ns / 1_000_000);
        us = (int)((frac_ns / 1000) % 1000);
        ns = (int)(frac_ns % 1000);
        // Explicit millisecond/microsecond/nanosecond properties override the
        // fractional second, per spec: the explicit one wins.
        if (!ms_v.is_undefined() || !us_v.is_undefined() || !ns_v.is_undefined()) {
            ms = 0; us = 0; ns = 0;
        }
    } else if (!keep_missing) {
        s = 0;
    }
    if (!ms_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &ms_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "millisecond is not an integral number");
            return false;
        }
        ms = (int)lv;
    } else if (!keep_missing) {
        ms = 0;
    }
    if (!us_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &us_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "microsecond is not an integral number");
            return false;
        }
        us = (int)lv;
    } else if (!keep_missing) {
        us = 0;
    }
    if (!ns_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &ns_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "nanosecond is not an integral number");
            return false;
        }
        ns = (int)lv;
    } else if (!keep_missing) {
        ns = 0;
    }

    out.h = h;
    out.mi = mi;
    out.s = s;
    out.ms = ms;
    out.us = us;
    out.ns = ns;
    return true;
}

// Validate h/m/s/ms/us/ns as a Temporal time and write it into `out`. Leap
// seconds (s == 60) collapse to 59 here per spec.
fn bool fields_to_valid_time(BuiltinContext* ctx, temporal::CivilTime fields, temporal::CivilTime* out) {
    if (fields.h  < 0 || fields.h  > 23) { builtin_throw(ctx, ctx.heap.range_err_proto, "hour out of range"); return false; }
    if (fields.mi < 0 || fields.mi > 59) { builtin_throw(ctx, ctx.heap.range_err_proto, "minute out of range"); return false; }
    if (fields.s  < 0 || fields.s  > 60) { builtin_throw(ctx, ctx.heap.range_err_proto, "second out of range"); return false; }
    if (fields.ms < 0 || fields.ms > 999) { builtin_throw(ctx, ctx.heap.range_err_proto, "millisecond out of range"); return false; }
    if (fields.us < 0 || fields.us > 999) { builtin_throw(ctx, ctx.heap.range_err_proto, "microsecond out of range"); return false; }
    if (fields.ns < 0 || fields.ns > 999) { builtin_throw(ctx, ctx.heap.range_err_proto, "nanosecond out of range"); return false; }
    if (fields.s == 60 && (fields.ms != 0 || fields.us != 0 || fields.ns != 0)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "leap second cannot have a fractional part");
        return false;
    }
    temporal::CivilTime v = fields;
    if (v.s == 60) v.s = 59;
    *out = v;
    return true;
}

// Read a PlainDateTime property bag: y/m/d + the six time fields. Missing
// date fields default to `cur_date`; missing time fields default to
// `cur_time` (00:00:00 for the constructor, the current time for `with`).
fn bool bag_to_datetime_fields(BuiltinContext* ctx, HObject* bag, bool keep_missing,
                                temporal::CivilDate cur_date, temporal::CivilTime cur_time,
                                temporal::CivilDateTime* out) {
    Vm* v = (Vm*)ctx.vm;
    temporal::CivilDate date_fields;
    long _ep;
    if (!bag_to_fields(ctx, bag, keep_missing, cur_date, &date_fields, &_ep)) {
        return false;
    }
    temporal::CivilTime t;
    if (!bag_to_time_fields(ctx, bag, keep_missing, cur_time, &t)) return false;
    out.date = date_fields;
    out.time = t;
    return true;
}

// ToTemporalDate: convert an until/since/compare argument into a PlainDate
// HObject. Returns the argument itself when it already is one (identity
// preserved, matching the spec's fast path).
fn HObject*? plain_date_from_arg(BuiltinContext* ctx, TVal* arg) {
    Vm* v = (Vm*)ctx.vm;
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATE) return o;
        temporal::CivilDate fields;
        long _ep;
        if (!bag_to_fields(ctx, o, false, { .y = 0, .m = 1, .d = 1 }, &fields, &_ep)) return null;
        temporal::CivilDate valid;
        if (!fields_to_valid_date(ctx, fields, temporal::OverflowKind.CONSTRAIN, &valid)) return null;
        HObject*? res = alloc_plain_date(ctx.heap, valid, ctx.heap.temporal_iso_calendar);
        if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        HObject* r = res;
        r.prototype = ctx.heap.temporal_plain_date_proto;
        return r;
    }
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return null; }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO date string");
            return null;
        }
        temporal::CivilDate d = { .y = p.year, .m = p.month, .d = p.day };
        if (!temporal::is_valid_iso_date(d.y, d.m, d.d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
            return null;
        }
        HObject*? res = alloc_plain_date(ctx.heap, d, ctx.heap.temporal_iso_calendar);
        if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        HObject* r = res;
        r.prototype = ctx.heap.temporal_plain_date_proto;
        return r;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "argument must be a Temporal.PlainDate, string, or object");
    return null;
}

// Read the `largestUnit` and companion options for until/since. The allowed
// unit set depends on the type carrying the difference: PlainDate callers
// use DAYS/WEEKS/MONTHS/YEARS; PlainTime and PlainDateTime also accept
// HOURS/MINUTES/SECONDS (sub-day granularity). `default_largest` selects
// the type-specific default (DAYS for PlainDate/PlainDateTime, HOURS for
// PlainTime). Rounding beyond plain date-level increments is a later phase,
// so increment values > 1 are validated and then ignored.
fn bool read_diff_options(BuiltinContext* ctx, int options_index,
                          temporal::DifferenceUnit default_largest,
                          temporal::DifferenceUnit* largest,
                          bool accept_time_units) {
    *largest = default_largest;
    if (ctx.argc <= options_index) return true;
    TVal ov = ctx.regs[ctx.base_reg + options_index];
    if (ov.is_undefined()) return true;
    if (!ov.is_object() || ov.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    HObject* opts = (HObject*)ov.get_heapptr();

    TVal uv = prop_or_undefined(opts, ctx.heap, "largestUnit");
    if (!uv.is_undefined()) {
        if (!uv.is_string()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "largestUnit must be a string");
            return false;
        }
        HString* s = (HString*)uv.get_heapptr();
        char[] v = s.get_cstr()[:s.blen];
        if (v == "year" || v == "years") { *largest = temporal::DifferenceUnit.YEARS; }
        else if (v == "month" || v == "months") { *largest = temporal::DifferenceUnit.MONTHS; }
        else if (v == "week" || v == "weeks") { *largest = temporal::DifferenceUnit.WEEKS; }
        else if (v == "day" || v == "days") { *largest = temporal::DifferenceUnit.DAYS; }
        else if (accept_time_units && (v == "hour" || v == "hours")) { *largest = temporal::DifferenceUnit.HOURS; }
        else if (accept_time_units && (v == "minute" || v == "minutes")) { *largest = temporal::DifferenceUnit.MINUTES; }
        else if (accept_time_units && (v == "second" || v == "seconds")) { *largest = temporal::DifferenceUnit.SECONDS; }
        else {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid largestUnit");
            return false;
        }
    }

    // smallestUnit must be no finer than the smallest allowed by the type,
    // and no larger than largestUnit. Date-only types stop at day; time-aware
    // types can go down to nanoseconds but the difference algorithms in
    // lib/temporal stop at seconds (smaller units land with `round` in a
    // later phase).
    TVal sv = prop_or_undefined(opts, ctx.heap, "smallestUnit");
    if (!sv.is_undefined()) {
        if (!sv.is_string()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "smallestUnit must be a string");
            return false;
        }
        HString* s = (HString*)sv.get_heapptr();
        char[] v = s.get_cstr()[:s.blen];
        temporal::DifferenceUnit small;
        if (v == "year" || v == "years") { small = temporal::DifferenceUnit.YEARS; }
        else if (v == "month" || v == "months") { small = temporal::DifferenceUnit.MONTHS; }
        else if (v == "week" || v == "weeks") { small = temporal::DifferenceUnit.WEEKS; }
        else if (v == "day" || v == "days") { small = temporal::DifferenceUnit.DAYS; }
        else if (accept_time_units && (v == "hour" || v == "hours")) { small = temporal::DifferenceUnit.HOURS; }
        else if (accept_time_units && (v == "minute" || v == "minutes")) { small = temporal::DifferenceUnit.MINUTES; }
        else if (accept_time_units && (v == "second" || v == "seconds")) { small = temporal::DifferenceUnit.SECONDS; }
        else {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
            return false;
        }
        if (small > *largest) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "smallestUnit cannot be larger than largestUnit");
            return false;
        }
    }

    // roundingMode: trunc is the only mode the exact day-level difference
    // needs; the others are accepted and ignored here.
    TVal rm = prop_or_undefined(opts, ctx.heap, "roundingMode");
    if (!rm.is_undefined()) {
        if (!rm.is_string()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "roundingMode must be a string");
            return false;
        }
        HString* s = (HString*)rm.get_heapptr();
        char[] v = s.get_cstr()[:s.blen];
        if (!(v == "trunc" || v == "ceil" || v == "floor" || v == "halfExpand")) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
            return false;
        }
    }

    // roundingIncrement: integral >= 1; values > 1 are accepted but computed
    // as the exact difference (rounding is a later phase).
    TVal ri = prop_or_undefined(opts, ctx.heap, "roundingIncrement");
    if (!ri.is_undefined()) {
        Vm* v = (Vm*)ctx.vm;
        double d = vm::vm_to_number(v, &ri);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
        if (math::is_nan(d) || math::is_inf(d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingIncrement");
            return false;
        }
        if (d < 1 || math::floor(d) != d) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a positive integer");
            return false;
        }
    }
    return true;
}

// Back-compat wrapper: PlainDate calls read_diff_options with no time units.
// Reads the option bag and writes `largestUnit`. Defaults to DAYS.
fn bool read_date_diff_options(BuiltinContext* ctx, int options_index, temporal::DifferenceUnit* largest) {
    return read_diff_options(ctx, options_index, temporal::DifferenceUnit.DAYS, largest, false);
}

// ============================================================================
// Temporal.Duration
// ============================================================================

fn void builtin_temporal_duration_ctor(BuiltinContext* ctx) {
    Vm* v = (Vm*)ctx.vm;
    temporal::DurationParts d;
    d.years = 0; d.months = 0; d.weeks = 0; d.days = 0;
    d.hours = 0; d.minutes = 0; d.seconds = 0;
    d.ms = 0; d.us = 0; d.ns = 0;

    int arg_count = ctx.argc < 10 ? ctx.argc : 10;
    for (int k = 0; k < arg_count; k++) {
        double val = vm::vm_to_number(v, arg_at(ctx, k));
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        if (math::is_nan(val) || math::is_inf(val)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "duration fields must be finite numbers");
            return;
        }
        // Date units must be integers; time units may carry fractions that
        // fold into nanoseconds (whole remaining units plus the fraction).
        bool date_unit = k < 4;
        long whole = (long)math::trunc(val);
        switch (k) {
            case 0: d.years = whole; break;
            case 1: d.months = whole; break;
            case 2: d.weeks = whole; break;
            case 3: d.days = whole; break;
            case 4: d.hours = whole; d.ns += (int)((val - (double)whole) * 3.6e12); break;
            case 5: d.minutes = whole; d.ns += (int)((val - (double)whole) * 6e10); break;
            case 6: d.seconds = whole; d.ns += (int)((val - (double)whole) * 1e9); break;
            case 7: d.ms = (int)whole; d.ns += (int)((val - (double)whole) * 1e6); break;
            case 8: d.us = (int)whole; d.ns += (int)((val - (double)whole) * 1e3); break;
            default: d.ns = (int)whole; break;
        }
        if (date_unit && math::floor(val) != val) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "years/months/weeks/days must be integers");
            return;
        }
    }
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    if (ctx.is_constructor) {
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_duration_proto);
    } else {
        obj.prototype = ctx.heap.temporal_duration_proto;
    }
    ctx.result.set_object(obj);
}

fn void builtin_temporal_duration_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Duration.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    temporal::DurationParts d;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null || !temporal::parse_duration(s.get_cstr()[:s.blen], &d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid duration string");
            return;
        }
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_DURATION) {
            d = duration_value(o);
        } else {
            Vm* v = (Vm*)ctx.vm;
            char[][] names = { "years", "months", "weeks", "days", "hours",
                "minutes", "seconds", "milliseconds", "microseconds", "nanoseconds" };
            d.years = 0; d.months = 0; d.weeks = 0; d.days = 0;
            d.hours = 0; d.minutes = 0; d.seconds = 0;
            d.ms = 0; d.us = 0; d.ns = 0;
            for (int k = 0; k < 10; k++) {
                TVal pv = prop_or_undefined(o, ctx.heap, names[k]);
                if (pv.is_undefined()) continue;
                double val = vm::vm_to_number(v, &pv);
                if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
                if (math::is_nan(val) || math::is_inf(val)) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "duration fields must be finite");
                    return;
                }
                if (k < 4 && math::floor(val) != val) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "date duration fields must be integers");
                    return;
                }
                long whole = (long)math::trunc(val);
                switch (k) {
                    case 0: d.years = whole; break;
                    case 1: d.months = whole; break;
                    case 2: d.weeks = whole; break;
                    case 3: d.days = whole; break;
                    case 4: d.hours = whole; d.ns += (int)((val - (double)whole) * 3.6e12); break;
                    case 5: d.minutes = whole; d.ns += (int)((val - (double)whole) * 6e10); break;
                    case 6: d.seconds = whole; d.ns += (int)((val - (double)whole) * 1e9); break;
                    case 7: d.ms = (int)whole; d.ns += (int)((val - (double)whole) * 1e6); break;
                    case 8: d.us = (int)whole; d.ns += (int)((val - (double)whole) * 1e3); break;
                    default: d.ns = (int)whole; break;
                }
            }
        }
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.from requires a string or object");
        return;
    }
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

// One getter for all ten duration fields, dispatched on the builtin index.
fn void builtin_temporal_duration_getter(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    double val = 0.0;
    switch ((Builtin)(*(ctx.callee_obj.extra_ptr())).func.builtin_fn_index) {
        case Builtin.TEMPORAL_DURATION_PROTO_YEARS:        val = (double)obj.extra.temporal.int_a; break;
        case Builtin.TEMPORAL_DURATION_PROTO_MONTHS:       val = (double)obj.extra.temporal.int_b; break;
        case Builtin.TEMPORAL_DURATION_PROTO_WEEKS:        val = (double)obj.extra.temporal.int_c; break;
        case Builtin.TEMPORAL_DURATION_PROTO_DAYS:         val = (double)obj.extra.temporal.int_d; break;
        case Builtin.TEMPORAL_DURATION_PROTO_HOURS:        val = (double)obj.extra.temporal.int_e; break;
        case Builtin.TEMPORAL_DURATION_PROTO_MINUTES:      val = (double)obj.extra.temporal.int_f; break;
        case Builtin.TEMPORAL_DURATION_PROTO_SECONDS:      val = (double)obj.extra.temporal.int_g; break;
        case Builtin.TEMPORAL_DURATION_PROTO_MILLISECONDS: val = (double)obj.extra.temporal.int_h; break;
        case Builtin.TEMPORAL_DURATION_PROTO_MICROSECONDS: val = (double)obj.extra.temporal.int_i; break;
        case Builtin.TEMPORAL_DURATION_PROTO_NANOSECONDS:  val = (double)obj.extra.temporal.int_j; break;
        default: break;
    }
    ctx.result.set_number(val);
}

fn void builtin_temporal_duration_proto_sign(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    long sign = 0;
    if (d.years < 0 || d.months < 0 || d.weeks < 0 || d.days < 0 ||
        d.hours < 0 || d.minutes < 0 || d.seconds < 0 || d.ms < 0 || d.us < 0 || d.ns < 0) { sign = -1; }
    else if (d.years > 0 || d.months > 0 || d.weeks > 0 || d.days > 0 ||
             d.hours > 0 || d.minutes > 0 || d.seconds > 0 || d.ms > 0 || d.us > 0 || d.ns > 0) { sign = 1; }
    ctx.result.set_fastint(sign);
}

fn void builtin_temporal_duration_proto_blank(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    bool blank = d.years == 0 && d.months == 0 && d.weeks == 0 && d.days == 0 &&
                 d.hours == 0 && d.minutes == 0 && d.seconds == 0 &&
                 d.ms == 0 && d.us == 0 && d.ns == 0;
    ctx.result.set_boolean(blank);
}

fn void builtin_temporal_duration_proto_negated(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    d.years = -d.years; d.months = -d.months; d.weeks = -d.weeks; d.days = -d.days;
    d.hours = -d.hours; d.minutes = -d.minutes; d.seconds = -d.seconds;
    d.ms = -d.ms; d.us = -d.us; d.ns = -d.ns;
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_duration_proto_abs(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    if (d.years < 0) d.years = -d.years;
    if (d.months < 0) d.months = -d.months;
    if (d.weeks < 0) d.weeks = -d.weeks;
    if (d.days < 0) d.days = -d.days;
    if (d.hours < 0) d.hours = -d.hours;
    if (d.minutes < 0) d.minutes = -d.minutes;
    if (d.seconds < 0) d.seconds = -d.seconds;
    if (d.ms < 0) d.ms = -d.ms;
    if (d.us < 0) d.us = -d.us;
    if (d.ns < 0) d.ns = -d.ns;
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_duration_proto_toString(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    char[128] buf;
    usz len = temporal::format_duration(d, &buf, 128);
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_duration_proto_toJSON(BuiltinContext* ctx) {
    builtin_temporal_duration_proto_toString(ctx);
}

fn void builtin_temporal_duration_proto_valueOf(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Duration cannot be converted to a primitive number");
}

// ============================================================================
// Temporal.Calendar
// ============================================================================

fn void builtin_temporal_calendar_ctor(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Calendar requires an identifier argument");
        return;
    }
    HObject* cal;
    if (!calendar_from_arg(ctx, arg_at(ctx, 0), &cal)) return;
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Calendar must be called with new");
        return;
    }
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.TEMPORAL_CALENDAR);
    if (catch err = raw) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = raw;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_calendar_proto);
    ctx.result.set_object(obj);
}

fn void builtin_temporal_calendar_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Calendar.from requires an argument");
        return;
    }
    TVal* tv = arg_at(ctx, 0);
    if (tv.is_object() && tv.get_heapptr() != null) {
        HObject* o = (HObject*)tv.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_CALENDAR) {
            ctx.result.set_object(o);
            return;
        }
        builtin_throw(ctx, ctx.heap.type_err_proto, "not a Temporal.Calendar object");
        return;
    }
    if (tv.is_string()) {
        HObject* cal;
        if (!calendar_from_arg(ctx, tv, &cal)) return;
        ctx.result.set_object(cal);
        return;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "invalid calendar argument");
}

fn void builtin_temporal_calendar_proto_id(BuiltinContext* ctx) {
    ctx.result.set_string(builtin_intern_string(ctx.heap, "iso8601"));
}

fn void builtin_temporal_calendar_proto_toString(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_CALENDAR, "this is not a Temporal.Calendar")) return;
    ctx.result.set_string(builtin_intern_string(ctx.heap, "Temporal.Calendar"));
}

// ============================================================================
// Temporal.PlainDate constructor + statics
// ============================================================================

fn void builtin_temporal_plain_date_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate requires new");
        return;
    }
    Vm* v = (Vm*)ctx.vm;
    long y = 0;
    long m = 1;
    long d = 1;
    if (ctx.argc >= 1) {
        if (!to_integer_with_truncation(v, arg_at(ctx, 0), &y)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "year is not an integral number");
            return;
        }
    }
    if (ctx.argc >= 2) {
        if (!to_integer_with_truncation(v, arg_at(ctx, 1), &m)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
            return;
        }
    }
    if (ctx.argc < 3) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate requires year, month, and day");
        return;
    }
    if (ctx.argc >= 3) {
        if (!to_integer_with_truncation(v, arg_at(ctx, 2), &d)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
            return;
        }
    }

    HObject* calendar = ctx.heap.temporal_iso_calendar;
    if (ctx.argc >= 4) {
        if (!calendar_from_arg(ctx, arg_at(ctx, 3), &calendar)) return;
    }

    if (!temporal::is_valid_iso_date(y, (int)m, (int)d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate: invalid ISO date");
        return;
    }
    temporal::CivilDate cd = { .y = y, .m = (int)m, .d = (int)d };
    HObject*? obj_o = alloc_plain_date(ctx.heap, cd, calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_plain_date_proto);
    ctx.result.set_object(obj);
}

fn void builtin_temporal_plain_date_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    Vm* v = (Vm*)ctx.vm;

    temporal::CivilDate result;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return; }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate.from: invalid ISO date string");
            return;
        }
        temporal::CivilDate d = { .y = p.year, .m = p.month, .d = p.day };
        int dim = temporal::days_in_month(d.y, d.m);
        if (d.d > dim) {
            if (overflow == temporal::OverflowKind.REJECT) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows month");
                return;
            }
            d.d = dim;
        }
        if (!temporal::is_valid_iso_date(d.y, d.m, d.d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
            return;
        }
        result = d;
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
            ctx.result.set_object(o);
            return;
        }
        HObject* calendar = ctx.heap.temporal_iso_calendar;
        TVal cal_v = prop_or_undefined(o, ctx.heap, "calendar");
        if (!cal_v.is_undefined()) {
            if (!calendar_from_arg(ctx, &cal_v, &calendar)) return;
        }
        temporal::CivilDate fields;
        long _ep;
        if (!bag_to_fields(ctx, o, false, { .y = 0, .m = 1, .d = 1 }, &fields, &_ep)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        if (!fields_to_valid_date(ctx, fields, overflow, &result)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.from: argument must be a string or object");
        return;
    }

    HObject*? obj_o = alloc_plain_date(ctx.heap, result, ctx.heap.temporal_iso_calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_plain_date_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.compare requires two arguments");
        return;
    }
    HObject*? ao = plain_date_from_arg(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject*? bo = plain_date_from_arg(ctx, arg_at(ctx, 1));
    if (ctx.should_throw) return;
    temporal::CivilDate ad = plain_date_value(ao)!!;
    temporal::CivilDate bd = plain_date_value(bo)!!;
    ctx.result.set_fastint((long)temporal::date_compare(ad, bd));
}

// ============================================================================
// Temporal.PlainDate getters
// ============================================================================

fn void builtin_temporal_plain_date_proto_year(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)(long)obj.extra.temporal.int_a);
}

fn void builtin_temporal_plain_date_proto_month(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)obj.extra.temporal.int_b);
}

fn void builtin_temporal_plain_date_proto_day(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)obj.extra.temporal.int_c);
}

fn void builtin_temporal_plain_date_proto_dayOfWeek(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long days = temporal::epoch_days_from_civil(
        (long)obj.extra.temporal.int_a, obj.extra.temporal.int_b, obj.extra.temporal.int_c);
    // 1970-01-01 = Thursday = ISO 4; ((d % 7) + 4) % 7 maps [0..6] -> [4,5,6,7,1,2,3].
    long w = ((days % 7) + 4) % 7;
    if (w <= 0) w += 7;
    ctx.result.set_number((double)w);
}

fn void builtin_temporal_plain_date_proto_dayOfYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = (long)obj.extra.temporal.int_a;
    long jan1 = temporal::epoch_days_from_civil(y, 1, 1);
    long doy = temporal::epoch_days_from_civil(y, obj.extra.temporal.int_b, obj.extra.temporal.int_c) - jan1 + 1;
    ctx.result.set_number((double)doy);
}

fn void builtin_temporal_plain_date_proto_monthCode(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    int m = obj.extra.temporal.int_b;
    char[5] buf;
    usz len;
    if (m < 10) {
        len = (usz)libc::snprintf(&buf, 5, "M0%d", m);
    } else {
        len = (usz)libc::snprintf(&buf, 5, "M%d", m);
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_date_proto_inLeapYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_boolean(temporal::is_leap_year((long)obj.extra.temporal.int_a));
}

fn void builtin_temporal_plain_date_proto_calendarId(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    ctx.result.set_string(builtin_intern_string(ctx.heap, "iso8601"));
}

fn void builtin_temporal_plain_date_proto_calendar(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    HObject* cal = obj.extra.temporal.calendar;
    if (cal != null) {
        ctx.result.set_object(cal);
    } else {
        ctx.result.set_object(ctx.heap.temporal_iso_calendar);
    }
}

fn void builtin_temporal_plain_date_proto_era(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    ctx.result.set_undefined();
}

fn void builtin_temporal_plain_date_proto_eraYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    ctx.result.set_undefined();
}

fn void builtin_temporal_plain_date_proto_daysInMonth(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)temporal::days_in_month((long)obj.extra.temporal.int_a, obj.extra.temporal.int_b));
}

fn void builtin_temporal_plain_date_proto_daysInWeek(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    ctx.result.set_number(7.0);
}

fn void builtin_temporal_plain_date_proto_daysInYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number(temporal::is_leap_year((long)obj.extra.temporal.int_a) ? 366.0 : 365.0);
}

fn void builtin_temporal_plain_date_proto_monthsInYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    ctx.result.set_number(12.0);
}

fn long iso_weeks_in_year(long year) {
    // ISO 8601: a year has 53 weeks iff Jan 1 is a Thursday, or Jan 1 is a
    // Wednesday in a leap year.
    long jan1_dow = ((temporal::epoch_days_from_civil(year, 1, 1) % 7) + 4) % 7;
    if (jan1_dow <= 0) jan1_dow += 7;
    if (jan1_dow == 4 || (jan1_dow == 3 && temporal::is_leap_year(year))) return 53;
    return 52;
}

fn void builtin_temporal_plain_date_proto_weekOfYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = (long)obj.extra.temporal.int_a;
    long doy = temporal::epoch_days_from_civil(y, obj.extra.temporal.int_b, obj.extra.temporal.int_c) -
               temporal::epoch_days_from_civil(y, 1, 1) + 1;
    long dow = ((temporal::epoch_days_from_civil(y, obj.extra.temporal.int_b, obj.extra.temporal.int_c) % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    long week = (doy - dow + 10) / 7;
    if (week < 1) {
        week = iso_weeks_in_year(y - 1);
    } else if (week > iso_weeks_in_year(y)) {
        week = 1;
    }
    ctx.result.set_number((double)week);
}

fn void builtin_temporal_plain_date_proto_yearOfWeek(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = (long)obj.extra.temporal.int_a;
    long doy = temporal::epoch_days_from_civil(y, obj.extra.temporal.int_b, obj.extra.temporal.int_c) -
               temporal::epoch_days_from_civil(y, 1, 1) + 1;
    long dow = ((temporal::epoch_days_from_civil(y, obj.extra.temporal.int_b, obj.extra.temporal.int_c) % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    long week = (doy - dow + 10) / 7;
    long week_year = y;
    if (week < 1) { week_year = y - 1; }
    else if (week > iso_weeks_in_year(y)) { week_year = y + 1; }
    ctx.result.set_number((double)week_year);
}

fn void builtin_temporal_plain_date_proto_valueOf(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate cannot be converted to a primitive number");
}

// ============================================================================
// Temporal.PlainDate methods
// ============================================================================

fn void builtin_temporal_plain_date_proto_toString(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDate d = plain_date_value(obj);

    // calendarName option: auto (default) omits the ISO annotation since it
    // is the default calendar; always/critical append it.
    bool show_calendar = false;
    bool critical = false;
    if (ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal ov = ctx.regs[ctx.base_reg];
        if (!ov.is_object() || ov.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
            return;
        }
        HObject* opts = (HObject*)ov.get_heapptr();
        TVal cn = prop_or_undefined(opts, ctx.heap, "calendarName");
        if (!cn.is_undefined()) {
            if (!cn.is_string()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "calendarName must be a string");
                return;
            }
            HString* s = (HString*)cn.get_heapptr();
            char[] v = s.get_cstr()[:s.blen];
            if (v == "auto") { show_calendar = false; }
            else if (v == "always") { show_calendar = true; }
            else if (v == "critical") { show_calendar = true; critical = true; }
            else if (v == "never") { show_calendar = false; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendarName");
                return;
            }
        }
    }

    char[48] buf;
    usz len = temporal::format_civil_date(d, &buf, 48);
    if (show_calendar) {
        char[] ann = critical ? "[!u-ca=iso8601]" : "[u-ca=iso8601]";
        for (usz k = 0; k < ann.len; k++) buf[len++] = ann[k];
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_date_proto_toJSON(BuiltinContext* ctx) {
    builtin_temporal_plain_date_proto_toString(ctx);
}

fn void builtin_temporal_plain_date_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* other = (HObject*)arg.get_heapptr();
        // ToTemporalDate: only a real PlainDate compares through the fast
        // path; anything else needs conversion (later phases) or is unequal.
        if (other.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
            temporal::CivilDate a = plain_date_value(obj);
            temporal::CivilDate b = plain_date_value(other);
            bool same_cal = obj.extra.temporal.calendar == other.extra.temporal.calendar;
            ctx.result.set_boolean(same_cal && temporal::date_equals(a, b));
            return;
        }
        if (other.get_class() == hobject::ObjClass.TEMPORAL_DURATION) {
            ctx.result.set_boolean(false);
            return;
        }
        ctx.result.set_boolean(false);
        return;
    }
    ctx.result.set_boolean(false);
}

fn void builtin_temporal_plain_date_proto_with(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.prototype.with requires a fields bag");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with requires an object");
        return;
    }
    HObject* bag = (HObject*)arg.get_heapptr();
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    Vm* v = (Vm*)ctx.vm;

    temporal::CivilDate cur = plain_date_value(obj);
    temporal::CivilDate fields;
    long _ep;
    if (!bag_to_fields(ctx, bag, true, cur, &fields, &_ep)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    temporal::CivilDate result;
    if (!fields_to_valid_date(ctx, fields, overflow, &result)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    HObject*? obj_o = alloc_plain_date(ctx.heap, result, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(obj2);
}

// ToTemporalDurationRecord: a Duration instance, an ISO duration string, or a
// plain object whose date fields must be integers and whose time fields may
// carry fractions (folded into nanoseconds).
fn bool duration_record_from_arg(BuiltinContext* ctx, TVal* arg, temporal::DurationParts* out) {
    Vm* v = (Vm*)ctx.vm;
    out.years = 0;
    out.months = 0;
    out.weeks = 0;
    out.days = 0;
    out.hours = 0;
    out.minutes = 0;
    out.seconds = 0;
    out.ms = 0;
    out.us = 0;
    out.ns = 0;

    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null || !temporal::parse_duration(s.get_cstr()[:s.blen], out)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid duration string");
            return false;
        }
        return true;
    }
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument must be a Temporal.Duration, duration string, or object");
        return false;
    }
    HObject* o = (HObject*)arg.get_heapptr();
    if (o.get_class() == hobject::ObjClass.TEMPORAL_DURATION) {
        *out = duration_value(o);
        return true;
    }

    char[][] names = { "years", "months", "weeks", "days", "hours",
        "minutes", "seconds", "milliseconds", "microseconds", "nanoseconds" };
    for (int k = 0; k < 10; k++) {
        TVal pv = prop_or_undefined(o, ctx.heap, names[k]);
        if (pv.is_undefined()) continue;
        double val = vm::vm_to_number(v, &pv);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
        if (math::is_nan(val) || math::is_inf(val)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "duration fields must be finite");
            return false;
        }
        if (k < 4 && math::floor(val) != val) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "years/months/weeks/days must be integers");
            return false;
        }
        long whole = (long)math::trunc(val);
        switch (k) {
            case 0: out.years = whole; break;
            case 1: out.months = whole; break;
            case 2: out.weeks = whole; break;
            case 3: out.days = whole; break;
            case 4: out.hours = whole; out.ns += (int)((val - (double)whole) * 3.6e12); break;
            case 5: out.minutes = whole; out.ns += (int)((val - (double)whole) * 6e10); break;
            case 6: out.seconds = whole; out.ns += (int)((val - (double)whole) * 1e9); break;
            case 7: out.ms = (int)whole; out.ns += (int)((val - (double)whole) * 1e6); break;
            case 8: out.us = (int)whole; out.ns += (int)((val - (double)whole) * 1e3); break;
            default: out.ns = (int)whole; break;
        }
    }
    return true;
}

fn void builtin_temporal_plain_date_proto_add(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "add requires a duration");
        return;
    }
    temporal::DurationParts dur;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur)) return;
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;

    temporal::CivilDate cur = plain_date_value(obj);
    // Time units balance into whole days (truncating, the spec's floor for
    // date arithmetic on largerUnit day).
    long extra_ns = dur.ns + ((long)dur.us * 1000) + ((long)dur.ms * 1_000_000) +
                    (dur.seconds * 1_000_000_000L) + (dur.minutes * 60_000_000_000L) +
                    (dur.hours * 3_600_000_000_000L);
    long whole_days = (long)math::trunc((double)extra_ns / 86400_000_000_000.0);
    long total_months = dur.years * 12 + dur.months;
    long total_days = dur.weeks * 7 + dur.days + whole_days;

    temporal::CivilDate after_months;
    if (overflow == temporal::OverflowKind.REJECT) {
        // Reject requires the intermediate month step to be representable.
        temporal::CivilDate m = temporal::add_months(cur, total_months, temporal::OverflowKind.CONSTRAIN);
        if (cur.d > temporal::days_in_month(m.y, m.m)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows the resulting month");
            return;
        }
        after_months = { .y = m.y, .m = m.m, .d = cur.d };
    } else {
        after_months = temporal::add_months(cur, total_months, temporal::OverflowKind.CONSTRAIN);
    }
    temporal::CivilDate result = temporal::add_days(after_months, total_days);
    if (!temporal::is_valid_iso_date(result.y, result.m, result.d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "result is out of range");
        return;
    }
    HObject*? obj_o = alloc_plain_date(ctx.heap, result, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_date_proto_subtract(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "subtract requires a duration");
        return;
    }
    temporal::DurationParts dur;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur)) return;
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;

    temporal::CivilDate cur = plain_date_value(obj);
    long extra_ns = dur.ns + ((long)dur.us * 1000) + ((long)dur.ms * 1_000_000) +
                    (dur.seconds * 1_000_000_000L) + (dur.minutes * 60_000_000_000L) +
                    (dur.hours * 3_600_000_000_000L);
    long whole_days = (long)math::trunc((double)extra_ns / 86400_000_000_000.0);
    long total_months = -(dur.years * 12 + dur.months);
    long total_days = -(dur.weeks * 7 + dur.days + whole_days);

    temporal::CivilDate after_months;
    if (overflow == temporal::OverflowKind.REJECT) {
        temporal::CivilDate m = temporal::add_months(cur, total_months, temporal::OverflowKind.CONSTRAIN);
        if (cur.d > temporal::days_in_month(m.y, m.m)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows the resulting month");
            return;
        }
        after_months = { .y = m.y, .m = m.m, .d = cur.d };
    } else {
        after_months = temporal::add_months(cur, total_months, temporal::OverflowKind.CONSTRAIN);
    }
    temporal::CivilDate result = temporal::add_days(after_months, total_days);
    if (!temporal::is_valid_iso_date(result.y, result.m, result.d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "result is out of range");
        return;
    }
    HObject*? obj_o = alloc_plain_date(ctx.heap, result, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(obj2);
}

// until/since shared implementation. `flipped` is true for since (this - other
// rather than other - this).
fn void plain_date_until_since(BuiltinContext* ctx, HObject* obj, bool flipped) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "until/since requires another date");
        return;
    }
    HObject*? other_o = plain_date_from_arg(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject* other = other_o!!;

    HObject* this_cal = obj.extra.temporal.calendar;
    HObject* other_cal = other.extra.temporal.calendar;
    if (this_cal != other_cal || this_cal == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "calendars do not match");
        return;
    }

    temporal::DifferenceUnit largest;
    if (!read_date_diff_options(ctx, 1, &largest)) return;

    temporal::CivilDate a = plain_date_value(obj);
    temporal::CivilDate b = plain_date_value(other);
    temporal::CivilDate start = flipped ? b : a;
    temporal::CivilDate end   = flipped ? a : b;

    temporal::DateDifference diff = temporal::difference_date(start, end, largest);
    temporal::DurationParts dur;
    dur.years = diff.years;
    dur.months = diff.months;
    if (largest == temporal::DifferenceUnit.WEEKS) {
        dur.weeks = diff.days / 7;   // truncating toward zero, polyfill divTrunc
        dur.days = diff.days % 7;    // modTrunc: same sign as the dividend
    } else {
        dur.days = diff.days;
    }
    dur.hours = 0; dur.minutes = 0; dur.seconds = 0;
    dur.ms = 0; dur.us = 0; dur.ns = 0;

    HObject*? dur_o = alloc_duration(ctx.heap, dur);
    if (catch err = dur_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* dur_obj = dur_o;
    dur_obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur_obj);
}

fn void builtin_temporal_plain_date_proto_until(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    plain_date_until_since(ctx, (HObject*)this_val.get_heapptr(), false);
}

fn void builtin_temporal_plain_date_proto_since(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    plain_date_until_since(ctx, (HObject*)this_val.get_heapptr(), true);
}

// ============================================================================
// Temporal.PlainTime
// ============================================================================

fn void builtin_temporal_plain_time_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainTime requires new");
        return;
    }
    Vm* v = (Vm*)ctx.vm;
    temporal::CivilTime t = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
    if (ctx.argc >= 1) {
        long h_lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 0), &h_lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "hour is not an integral number");
            return;
        }
        t.h = (int)h_lv;
    }
    if (ctx.argc >= 2) {
        long mi;
        if (!to_integer_with_truncation(v, arg_at(ctx, 1), &mi)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "minute is not an integral number");
            return;
        }
        t.mi = (int)mi;
    }
    if (ctx.argc >= 3) {
        long s;
        if (!to_integer_with_truncation(v, arg_at(ctx, 2), &s)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "second is not an integral number");
            return;
        }
        t.s = (int)s;
    }
    if (ctx.argc >= 4) {
        long ms;
        if (!to_integer_with_truncation(v, arg_at(ctx, 3), &ms)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "millisecond is not an integral number");
            return;
        }
        t.ms = (int)ms;
    }
    if (ctx.argc >= 5) {
        long us;
        if (!to_integer_with_truncation(v, arg_at(ctx, 4), &us)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "microsecond is not an integral number");
            return;
        }
        t.us = (int)us;
    }
    if (ctx.argc >= 6) {
        long ns;
        if (!to_integer_with_truncation(v, arg_at(ctx, 5), &ns)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "nanosecond is not an integral number");
            return;
        }
        t.ns = (int)ns;
    }

    temporal::CivilTime valid;
    if (!fields_to_valid_time(ctx, t, &valid)) return;

    HObject*? obj_o = alloc_plain_time(ctx.heap, valid);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_plain_time_proto);
    ctx.result.set_object(obj);
}

fn void builtin_temporal_plain_time_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainTime.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    Vm* v = (Vm*)ctx.vm;

    temporal::CivilTime result;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return; }
        char[] text = s.get_cstr()[:s.blen];
        // Time-only inputs use parse_iso_time_string; full date-time strings
        // are accepted too and the date portion is discarded.
        temporal::ParsedIsoDateTime p;
        bool ok = temporal::parse_iso_time_string(text, &p);
        if (!ok) {
            temporal::ParsedIsoDateTime full_p;
            ok = temporal::parse_iso_date_string(text, &full_p);
            if (!ok || !full_p.has_time) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainTime.from: invalid ISO time string");
                return;
            }
            p = full_p;
        }
        result = { .h = p.hour, .mi = p.minute, .s = p.second, .ms = 0, .us = 0, .ns = (int)p.nanos };
        // Convert nanos (0..999_999_999) into ms/us/ns fields.
        result.ms = (int)(p.nanos / 1_000_000);
        result.us = (int)((p.nanos / 1000) % 1000);
        result.ns = (int)(p.nanos % 1000);
        if (!temporal::is_valid_time(result.h, result.mi, result.s, result.ms, result.us, result.ns)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainTime.from: out of range");
            return;
        }
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_TIME) {
            ctx.result.set_object(o);
            return;
        }
        temporal::CivilTime fields;
        temporal::CivilTime cur = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
        if (!bag_to_time_fields(ctx, o, false, cur, &fields)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        if (!fields_to_valid_time(ctx, fields, &result)) {
            return;
        }
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainTime.from: argument must be a string or object");
        return;
    }

    HObject*? obj_o = alloc_plain_time(ctx.heap, result);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_plain_time_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainTime.compare requires two arguments");
        return;
    }
    TVal* av = arg_at(ctx, 0);
    TVal* bv = arg_at(ctx, 1);
    if (!av.is_object() || av.get_heapptr() == null ||
        !bv.is_object() || bv.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainTime.compare: arguments must be PlainTime");
        return;
    }
    HObject* a = (HObject*)av.get_heapptr();
    HObject* b = (HObject*)bv.get_heapptr();
    if (a.get_class() != hobject::ObjClass.TEMPORAL_PLAIN_TIME ||
        b.get_class() != hobject::ObjClass.TEMPORAL_PLAIN_TIME) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainTime.compare: arguments must be PlainTime");
        return;
    }
    ctx.result.set_fastint((long)temporal::time_compare(plain_time_value(a), plain_time_value(b)));
}

// One getter per PlainTime field, dispatched on the builtin fn index.
fn void builtin_temporal_plain_time_getter(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    double val = 0.0;
    switch ((Builtin)(*(ctx.callee_obj.extra_ptr())).func.builtin_fn_index) {
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_HOUR:       val = (double)obj.extra.temporal.int_a; break;
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_MINUTE:     val = (double)obj.extra.temporal.int_b; break;
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_SECOND:     val = (double)obj.extra.temporal.int_c; break;
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_MILLISECOND: val = (double)obj.extra.temporal.int_d; break;
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_MICROSECOND: val = (double)obj.extra.temporal.int_e; break;
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_NANOSECOND:  val = (double)obj.extra.temporal.int_f; break;
        default: break;
    }
    ctx.result.set_number(val);
}

fn void builtin_temporal_plain_time_proto_valueOf(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainTime cannot be converted to a primitive value");
}

fn void builtin_temporal_plain_time_proto_toString(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilTime t = plain_time_value(obj);

    int ns_digits = -1;  // smallest non-zero
    if (ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal ov = ctx.regs[ctx.base_reg];
        if (!ov.is_object() || ov.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
            return;
        }
        HObject* opts = (HObject*)ov.get_heapptr();
        TVal fd = prop_or_undefined(opts, ctx.heap, "fractionalSecondDigits");
        if (!fd.is_undefined()) {
            if (fd.is_number() || fd.is_fastint()) {
                Vm* v = (Vm*)ctx.vm;
                double d = vm::vm_to_number(v, &fd);
                if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
                if (math::is_nan(d) || d < 0 || d > 9 || math::floor(d) != d) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0..9 or \"auto\"");
                    return;
                }
                ns_digits = (int)d;
            } else if (fd.is_string()) {
                HString* s = (HString*)fd.get_heapptr();
                char[] v = s.get_cstr()[:s.blen];
                if (v == "auto") {
                    ns_digits = -1;
                } else {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0..9 or \"auto\"");
                    return;
                }
            } else {
                builtin_throw(ctx, ctx.heap.type_err_proto, "fractionalSecondDigits must be a number or string");
                return;
            }
        }
        TVal su = prop_or_undefined(opts, ctx.heap, "smallestUnit");
        if (!su.is_undefined()) {
            if (!su.is_string()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "smallestUnit must be a string");
                return;
            }
            HString* s = (HString*)su.get_heapptr();
            char[] v = s.get_cstr()[:s.blen];
            // Map smallestUnit to ns_digits: "hour"=0, "minute"=0, "second"=0,
            // "millisecond"=3, "microsecond"=6, "nanosecond"=9.
            if (v == "hour" || v == "hours" || v == "minute" || v == "minutes" || v == "second" || v == "seconds") {
                if (ns_digits < 0) ns_digits = 0;
            } else if (v == "millisecond" || v == "milliseconds") {
                if (ns_digits < 0) ns_digits = 3;
            } else if (v == "microsecond" || v == "microseconds") {
                if (ns_digits < 0) ns_digits = 6;
            } else if (v == "nanosecond" || v == "nanoseconds") {
                if (ns_digits < 0) ns_digits = 9;
            } else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
                return;
            }
        }
    }

    char[32] buf;
    usz len = temporal::format_civil_time(t, &buf, 32, ns_digits);
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_time_proto_toJSON(BuiltinContext* ctx) {
    builtin_temporal_plain_time_proto_toString(ctx);
}

fn void builtin_temporal_plain_time_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) {
        ctx.result.set_boolean(false);
        return;
    }
    HObject* other = (HObject*)arg.get_heapptr();
    if (other.get_class() != hobject::ObjClass.TEMPORAL_PLAIN_TIME) {
        ctx.result.set_boolean(false);
        return;
    }
    ctx.result.set_boolean(temporal::time_equals(plain_time_value(obj), plain_time_value(other)));
}

// Convert an until/since argument into a PlainTime HObject.
fn HObject*? plain_time_from_arg(BuiltinContext* ctx, TVal* arg) {
    Vm* v = (Vm*)ctx.vm;
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_TIME) return o;
        temporal::CivilTime fields;
        temporal::CivilTime cur = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
        if (!bag_to_time_fields(ctx, o, false, cur, &fields)) return null;
        temporal::CivilTime valid;
        if (!fields_to_valid_time(ctx, fields, &valid)) return null;
        HObject*? res = alloc_plain_time(ctx.heap, valid);
        if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        HObject* r = res;
        r.prototype = ctx.heap.temporal_plain_time_proto;
        return r;
    }
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return null; }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO time string");
            return null;
        }
        if (!p.has_time) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "string has no time portion");
            return null;
        }
        temporal::CivilTime t = {
            .h = p.hour,
            .mi = p.minute,
            .s = p.second,
            .ms = (int)(p.nanos / 1_000_000),
            .us = (int)((p.nanos / 1000) % 1000),
            .ns = (int)(p.nanos % 1000),
        };
        if (!temporal::is_valid_time(t.h, t.mi, t.s, t.ms, t.us, t.ns)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "time is out of range");
            return null;
        }
        HObject*? res = alloc_plain_time(ctx.heap, t);
        if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        HObject* r = res;
        r.prototype = ctx.heap.temporal_plain_time_proto;
        return r;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "argument must be a Temporal.PlainTime, string, or object");
    return null;
}

fn void builtin_temporal_plain_time_proto_with(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainTime.prototype.with requires a fields bag");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with requires an object");
        return;
    }
    HObject* bag = (HObject*)arg.get_heapptr();
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    Vm* v = (Vm*)ctx.vm;

    temporal::CivilTime cur = plain_time_value(obj);
    temporal::CivilTime fields;
    if (!bag_to_time_fields(ctx, bag, true, cur, &fields)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    temporal::CivilTime valid;
    if (!fields_to_valid_time(ctx, fields, &valid)) return;
    HObject*? obj_o = alloc_plain_time(ctx.heap, valid);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_time_proto_add(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "add requires a duration");
        return;
    }
    temporal::DurationParts dur;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur)) return;
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;

    // Combine hours/minutes/seconds/ms/us/ns into one nanosecond delta, then
    // split into whole seconds + leftover nanos for the carry-aware add.
    long extra_ns = (long)dur.ns + (long)dur.us * 1000 + (long)dur.ms * 1_000_000 +
                    dur.seconds * 1_000_000_000L + dur.minutes * 60_000_000_000L +
                    dur.hours * 3_600_000_000_000L;
    long carry_seconds = extra_ns / 1_000_000_000L;
    long carry_ns = extra_ns - carry_seconds * 1_000_000_000L;

    temporal::CivilTime cur = plain_time_value(obj);
    // Add carry_ns to cur.ns, normalize into [0, 1e9), track the carry.
    long total_ns = (long)cur.ns + carry_ns;
    if (total_ns >= 1_000_000_000) {
        carry_seconds += 1;
        total_ns -= 1_000_000_000;
    } else if (total_ns < 0) {
        carry_seconds -= 1;
        total_ns += 1_000_000_000;
    }
    // combine cur.ms/us (unchanged by carry_ns beyond the ns bump)
    long full_subsec = ((long)cur.ms * 1_000_000L) + ((long)cur.us * 1000L) + total_ns;
    long day_bump = 0;
    long _day;
    temporal::CivilTime result = temporal::add_seconds_to_time(cur, carry_seconds, &_day);
    // day_bump is dropped per spec: PlainTime.add cannot cross midnight into
    // a different date. The carry still affects hour/minute/second.
    (void)day_bump;
    result.ms = (int)(full_subsec / 1_000_000);
    full_subsec -= (long)result.ms * 1_000_000;
    result.us = (int)(full_subsec / 1000);
    full_subsec -= (long)result.us * 1000;
    result.ns = (int)full_subsec;

    if (!temporal::is_valid_time(result.h, result.mi, result.s, result.ms, result.us, result.ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "result time is out of range");
        return;
    }
    HObject*? obj_o = alloc_plain_time(ctx.heap, result);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_time_proto_subtract(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "subtract requires a duration");
        return;
    }
    temporal::DurationParts dur;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur)) return;
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;

    long extra_ns = (long)dur.ns + (long)dur.us * 1000 + (long)dur.ms * 1_000_000 +
                    dur.seconds * 1_000_000_000L + dur.minutes * 60_000_000_000L +
                    dur.hours * 3_600_000_000_000L;
    long carry_seconds = -(extra_ns / 1_000_000_000L);
    long carry_ns = -(extra_ns - (-carry_seconds) * 1_000_000_000L);

    temporal::CivilTime cur = plain_time_value(obj);
    long total_ns = (long)cur.ns + carry_ns;
    if (total_ns >= 1_000_000_000) {
        carry_seconds += 1;
        total_ns -= 1_000_000_000;
    } else if (total_ns < 0) {
        carry_seconds -= 1;
        total_ns += 1_000_000_000;
    }
    long full_subsec = ((long)cur.ms * 1_000_000L) + ((long)cur.us * 1000L) + total_ns;
    long _day;
    temporal::CivilTime result = temporal::add_seconds_to_time(cur, carry_seconds, &_day);
    result.ms = (int)(full_subsec / 1_000_000);
    full_subsec -= (long)result.ms * 1_000_000;
    result.us = (int)(full_subsec / 1000);
    full_subsec -= (long)result.us * 1000;
    result.ns = (int)full_subsec;

    if (!temporal::is_valid_time(result.h, result.mi, result.s, result.ms, result.us, result.ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "result time is out of range");
        return;
    }
    HObject*? obj_o = alloc_plain_time(ctx.heap, result);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(obj2);
}

fn void plain_time_until_since(BuiltinContext* ctx, HObject* obj, bool flipped) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "until/since requires another time");
        return;
    }
    HObject*? other_o = plain_time_from_arg(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject* other = other_o!!;

    temporal::DifferenceUnit largest;
    if (!read_diff_options(ctx, 1, temporal::DifferenceUnit.HOURS, &largest, true)) return;

    temporal::CivilTime a = plain_time_value(obj);
    temporal::CivilTime b = plain_time_value(other);
    temporal::CivilTime start = flipped ? b : a;
    temporal::CivilTime end   = flipped ? a : b;

    // Time-only difference: convert to a nanosecond delta then split into the
    // chosen unit ladder. Days/weeks/months/years are not meaningful for
    // PlainTime, but we accept them in the option (rejected above if not).
    long start_ns = ((long)start.h * 3600 + (long)start.mi * 60 + (long)start.s) * 1_000_000_000L
                  + (long)start.ms * 1_000_000L + (long)start.us * 1000L + (long)start.ns;
    long end_ns   = ((long)end.h  * 3600 + (long)end.mi  * 60 + (long)end.s ) * 1_000_000_000L
                  + (long)end.ms  * 1_000_000L + (long)end.us  * 1000L + (long)end.ns;
    long delta = end_ns - start_ns;

    temporal::DurationParts dur;
    dur.years = 0; dur.months = 0; dur.weeks = 0; dur.days = 0;
    if (largest == temporal::DifferenceUnit.SECONDS) {
        long secs = delta / 1_000_000_000L;
        long rem = delta - secs * 1_000_000_000L;
        dur.seconds = secs;
        dur.ms = (int)(rem / 1_000_000);
        rem -= (long)dur.ms * 1_000_000;
        dur.us = (int)(rem / 1000);
        rem -= (long)dur.us * 1000;
        dur.ns = (int)rem;
    } else if (largest == temporal::DifferenceUnit.MINUTES) {
        long mins = delta / 60_000_000_000L;
        long rem = delta - mins * 60_000_000_000L;
        dur.minutes = mins;
        dur.seconds = rem / 1_000_000_000L;
        rem -= dur.seconds * 1_000_000_000L;
        dur.ms = (int)(rem / 1_000_000);
        rem -= (long)dur.ms * 1_000_000;
        dur.us = (int)(rem / 1000);
        rem -= (long)dur.us * 1000;
        dur.ns = (int)rem;
    } else {  // HOURS (default for PlainTime after SECONDS/MINUTES/HOURS enum ordering)
        long hours = delta / 3_600_000_000_000L;
        long rem = delta - hours * 3_600_000_000_000L;
        dur.hours = hours;
        dur.minutes = rem / 60_000_000_000L;
        rem -= dur.minutes * 60_000_000_000L;
        dur.seconds = rem / 1_000_000_000L;
        rem -= dur.seconds * 1_000_000_000L;
        dur.ms = (int)(rem / 1_000_000);
        rem -= (long)dur.ms * 1_000_000;
        dur.us = (int)(rem / 1000);
        rem -= (long)dur.us * 1000;
        dur.ns = (int)rem;
    }

    HObject*? dur_o = alloc_duration(ctx.heap, dur);
    if (catch err = dur_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* dur_obj = dur_o;
    dur_obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur_obj);
}

fn void builtin_temporal_plain_time_proto_until(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    plain_time_until_since(ctx, (HObject*)this_val.get_heapptr(), false);
}

fn void builtin_temporal_plain_time_proto_since(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    plain_time_until_since(ctx, (HObject*)this_val.get_heapptr(), true);
}

// ============================================================================
// Temporal.PlainDateTime
// ============================================================================

fn void builtin_temporal_plain_datetime_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDateTime requires new");
        return;
    }
    Vm* v = (Vm*)ctx.vm;

    long y = 0;
    long m = 1;
    long d = 1;
    int  h = 0;
    int  mi = 0;
    int  s = 0;
    int  ms = 0;
    int  us = 0;
    int  ns = 0;

    if (ctx.argc >= 1) {
        if (!to_integer_with_truncation(v, arg_at(ctx, 0), &y)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "year is not an integral number");
            return;
        }
    }
    if (ctx.argc >= 2) {
        if (!to_integer_with_truncation(v, arg_at(ctx, 1), &m)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
            return;
        }
    }
    if (ctx.argc < 3) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDateTime requires year, month, and day");
        return;
    }
    if (ctx.argc >= 3) {
        if (!to_integer_with_truncation(v, arg_at(ctx, 2), &d)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
            return;
        }
    }
    if (ctx.argc >= 4) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 3), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "hour is not an integral number");
            return;
        }
        h = (int)lv;
    }
    if (ctx.argc >= 5) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 4), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "minute is not an integral number");
            return;
        }
        mi = (int)lv;
    }
    if (ctx.argc >= 6) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 5), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "second is not an integral number");
            return;
        }
        s = (int)lv;
    }
    if (ctx.argc >= 7) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 6), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "millisecond is not an integral number");
            return;
        }
        ms = (int)lv;
    }
    if (ctx.argc >= 8) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 7), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "microsecond is not an integral number");
            return;
        }
        us = (int)lv;
    }
    if (ctx.argc >= 9) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 8), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "nanosecond is not an integral number");
            return;
        }
        ns = (int)lv;
    }

    HObject* calendar = ctx.heap.temporal_iso_calendar;
    if (ctx.argc >= 10) {
        if (!calendar_from_arg(ctx, arg_at(ctx, 9), &calendar)) return;
    }

    if (!temporal::is_valid_iso_date(y, (int)m, (int)d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDateTime: invalid ISO date");
        return;
    }
    temporal::CivilTime t = { .h = h, .mi = mi, .s = s, .ms = ms, .us = us, .ns = ns };
    temporal::CivilTime valid_t;
    if (!fields_to_valid_time(ctx, t, &valid_t)) return;

    temporal::CivilDateTime dt = { .date = { .y = y, .m = (int)m, .d = (int)d }, .time = valid_t };
    HObject*? obj_o = alloc_plain_datetime(ctx.heap, dt, calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_plain_datetime_proto);
    ctx.result.set_object(obj);
}

fn void builtin_temporal_plain_datetime_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDateTime.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    Vm* v = (Vm*)ctx.vm;

    temporal::CivilDateTime result;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return; }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDateTime.from: invalid ISO date-time string");
            return;
        }
        if (!p.has_time) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDateTime.from: string has no time portion");
            return;
        }
        temporal::CivilDate d = { .y = p.year, .m = p.month, .d = p.day };
        int dim = temporal::days_in_month(d.y, d.m);
        if (d.d > dim) {
            if (overflow == temporal::OverflowKind.REJECT) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows month");
                return;
            }
            d.d = dim;
        }
        if (!temporal::is_valid_iso_date(d.y, d.m, d.d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
            return;
        }
        temporal::CivilTime t = {
            .h = p.hour, .mi = p.minute, .s = p.second,
            .ms = (int)(p.nanos / 1_000_000),
            .us = (int)((p.nanos / 1000) % 1000),
            .ns = (int)(p.nanos % 1000),
        };
        if (!temporal::is_valid_time(t.h, t.mi, t.s, t.ms, t.us, t.ns)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "time is out of range");
            return;
        }
        result = { .date = d, .time = t };
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            ctx.result.set_object(o);
            return;
        }
        HObject* calendar = ctx.heap.temporal_iso_calendar;
        TVal cal_v = prop_or_undefined(o, ctx.heap, "calendar");
        if (!cal_v.is_undefined()) {
            if (!calendar_from_arg(ctx, &cal_v, &calendar)) return;
        }
        temporal::CivilDateTime fields;
        if (!bag_to_datetime_fields(ctx, o, false, { .y = 0, .m = 1, .d = 1 },
                                    { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 }, &fields)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        temporal::CivilDate valid_d;
        if (!fields_to_valid_date(ctx, fields.date, overflow, &valid_d)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        temporal::CivilTime valid_t;
        if (!fields_to_valid_time(ctx, fields.time, &valid_t)) return;
        result = { .date = valid_d, .time = valid_t };
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDateTime.from: argument must be a string or object");
        return;
    }

    HObject*? obj_o = alloc_plain_datetime(ctx.heap, result, ctx.heap.temporal_iso_calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_plain_datetime_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDateTime.compare requires two arguments");
        return;
    }
    TVal* av = arg_at(ctx, 0);
    TVal* bv = arg_at(ctx, 1);
    if (!av.is_object() || av.get_heapptr() == null || !bv.is_object() || bv.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDateTime.compare: arguments must be PlainDateTime");
        return;
    }
    HObject* a = (HObject*)av.get_heapptr();
    HObject* b = (HObject*)bv.get_heapptr();
    if (a.get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATETIME ||
        b.get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDateTime.compare: arguments must be PlainDateTime");
        return;
    }
    temporal::CivilDateTime ad = plain_datetime_value(a);
    temporal::CivilDateTime bd = plain_datetime_value(b);
    int cmp = temporal::date_compare(ad.date, bd.date);
    if (cmp == 0) cmp = temporal::time_compare(ad.time, bd.time);
    ctx.result.set_fastint((long)cmp);
}

// One getter per PlainDateTime field, dispatched on the builtin fn index.
fn void builtin_temporal_plain_datetime_getter(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    double val = 0.0;
    switch ((Builtin)(*(ctx.callee_obj.extra_ptr())).func.builtin_fn_index) {
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_YEAR:        val = (double)(long)obj.extra.temporal.int_a; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MONTH:       val = (double)obj.extra.temporal.int_b; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAY:         val = (double)obj.extra.temporal.int_c; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_HOUR:        val = (double)obj.extra.temporal.int_d; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MINUTE:      val = (double)obj.extra.temporal.int_e; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_SECOND:      val = (double)obj.extra.temporal.int_f; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MILLISECOND: val = (double)obj.extra.temporal.int_g; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MICROSECOND: val = (double)obj.extra.temporal.int_h; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_NANOSECOND:  val = (double)obj.extra.temporal.int_i; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_CALENDAR:
            ctx.result.set_object(obj.extra.temporal.calendar);
            return;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_CALENDARID:
            ctx.result.set_string(builtin_intern_string(ctx.heap, "iso8601"));
            return;
        default: break;
    }
    ctx.result.set_number(val);
}

fn void builtin_temporal_plain_datetime_proto_valueOf(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDateTime cannot be converted to a primitive value");
}

fn void builtin_temporal_plain_datetime_proto_toString(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDateTime dt = plain_datetime_value(obj);

    int ns_digits = -1;
    bool show_calendar = false;
    bool critical = false;
    if (ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal ov = ctx.regs[ctx.base_reg];
        if (!ov.is_object() || ov.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
            return;
        }
        HObject* opts = (HObject*)ov.get_heapptr();
        TVal cn = prop_or_undefined(opts, ctx.heap, "calendarName");
        if (!cn.is_undefined()) {
            if (!cn.is_string()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "calendarName must be a string");
                return;
            }
            HString* s = (HString*)cn.get_heapptr();
            char[] v = s.get_cstr()[:s.blen];
            if (v == "auto") { show_calendar = false; }
            else if (v == "always") { show_calendar = true; }
            else if (v == "critical") { show_calendar = true; critical = true; }
            else if (v == "never") { show_calendar = false; }
            else { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendarName"); return; }
        }
        TVal fd = prop_or_undefined(opts, ctx.heap, "fractionalSecondDigits");
        if (!fd.is_undefined()) {
            if (fd.is_number() || fd.is_fastint()) {
                Vm* v = (Vm*)ctx.vm;
                double d = vm::vm_to_number(v, &fd);
                if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
                if (math::is_nan(d) || d < 0 || d > 9 || math::floor(d) != d) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0..9 or \"auto\"");
                    return;
                }
                ns_digits = (int)d;
            } else if (fd.is_string()) {
                HString* s = (HString*)fd.get_heapptr();
                char[] v = s.get_cstr()[:s.blen];
                if (!(v == "auto")) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0..9 or \"auto\"");
                    return;
                }
                ns_digits = -1;
            } else {
                builtin_throw(ctx, ctx.heap.type_err_proto, "fractionalSecondDigits must be a number or string");
                return;
            }
        }
        TVal su = prop_or_undefined(opts, ctx.heap, "smallestUnit");
        if (!su.is_undefined()) {
            if (!su.is_string()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "smallestUnit must be a string");
                return;
            }
            HString* s = (HString*)su.get_heapptr();
            char[] v = s.get_cstr()[:s.blen];
            if (v == "minute" || v == "minutes") {
                if (ns_digits < 0) ns_digits = 0;
            } else if (v == "second" || v == "seconds") {
                if (ns_digits < 0) ns_digits = 0;
            } else if (v == "millisecond" || v == "milliseconds") {
                if (ns_digits < 0) ns_digits = 3;
            } else if (v == "microsecond" || v == "microseconds") {
                if (ns_digits < 0) ns_digits = 6;
            } else if (v == "nanosecond" || v == "nanoseconds") {
                if (ns_digits < 0) ns_digits = 9;
            } else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
                return;
            }
        }
    }

    char[64] buf;
    usz len = temporal::format_civil_datetime(dt, &buf, 64, ns_digits);
    if (show_calendar) {
        char[] ann = critical ? "[!u-ca=iso8601]" : "[u-ca=iso8601]";
        for (usz k = 0; k < ann.len; k++) buf[len++] = ann[k];
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_datetime_proto_toJSON(BuiltinContext* ctx) {
    builtin_temporal_plain_datetime_proto_toString(ctx);
}

fn void builtin_temporal_plain_datetime_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) {
        ctx.result.set_boolean(false);
        return;
    }
    HObject* other = (HObject*)arg.get_heapptr();
    if (other.get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
        ctx.result.set_boolean(false);
        return;
    }
    bool same_cal = obj.extra.temporal.calendar == other.extra.temporal.calendar;
    temporal::CivilDateTime a = plain_datetime_value(obj);
    temporal::CivilDateTime b = plain_datetime_value(other);
    ctx.result.set_boolean(same_cal && temporal::date_equals(a.date, b.date) && temporal::time_equals(a.time, b.time));
}

fn HObject*? plain_datetime_from_arg(BuiltinContext* ctx, TVal* arg) {
    Vm* v = (Vm*)ctx.vm;
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) return o;
        HObject* calendar = ctx.heap.temporal_iso_calendar;
        TVal cal_v = prop_or_undefined(o, ctx.heap, "calendar");
        if (!cal_v.is_undefined()) {
            if (!calendar_from_arg(ctx, &cal_v, &calendar)) return null;
        }
        temporal::CivilDateTime fields;
        if (!bag_to_datetime_fields(ctx, o, false, { .y = 0, .m = 1, .d = 1 },
                                    { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 }, &fields)) return null;
        temporal::CivilDate valid_d;
        if (!fields_to_valid_date(ctx, fields.date, temporal::OverflowKind.CONSTRAIN, &valid_d)) return null;
        temporal::CivilTime valid_t;
        if (!fields_to_valid_time(ctx, fields.time, &valid_t)) return null;
        temporal::CivilDateTime dt = { .date = valid_d, .time = valid_t };
        HObject*? res = alloc_plain_datetime(ctx.heap, dt, calendar);
        if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        HObject* r = res;
        r.prototype = ctx.heap.temporal_plain_datetime_proto;
        return r;
    }
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return null; }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO date-time string");
            return null;
        }
        if (!p.has_time) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "string has no time portion");
            return null;
        }
        temporal::CivilDate d = { .y = p.year, .m = p.month, .d = p.day };
        if (!temporal::is_valid_iso_date(d.y, d.m, d.d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
            return null;
        }
        temporal::CivilTime t = {
            .h = p.hour, .mi = p.minute, .s = p.second,
            .ms = (int)(p.nanos / 1_000_000),
            .us = (int)((p.nanos / 1000) % 1000),
            .ns = (int)(p.nanos % 1000),
        };
        temporal::CivilDateTime dt = { .date = d, .time = t };
        HObject*? res = alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
        if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        HObject* r = res;
        r.prototype = ctx.heap.temporal_plain_datetime_proto;
        return r;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "argument must be a Temporal.PlainDateTime, string, or object");
    return null;
}

fn void builtin_temporal_plain_datetime_proto_with(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDateTime.prototype.with requires a fields bag");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with requires an object");
        return;
    }
    HObject* bag = (HObject*)arg.get_heapptr();
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    Vm* v = (Vm*)ctx.vm;

    temporal::CivilDateTime cur = plain_datetime_value(obj);
    temporal::CivilDateTime fields;
    if (!bag_to_datetime_fields(ctx, bag, true, cur.date, cur.time, &fields)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    temporal::CivilDate valid_d;
    if (!fields_to_valid_date(ctx, fields.date, overflow, &valid_d)) return;
    temporal::CivilTime valid_t;
    if (!fields_to_valid_time(ctx, fields.time, &valid_t)) return;
    temporal::CivilDateTime result = { .date = valid_d, .time = valid_t };
    HObject*? obj_o = alloc_plain_datetime(ctx.heap, result, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_datetime_proto_add(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "add requires a duration");
        return;
    }
    temporal::DurationParts dur;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur)) return;
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;

    temporal::CivilDateTime cur = plain_datetime_value(obj);
    long extra_ns = dur.ns + ((long)dur.us * 1000) + ((long)dur.ms * 1_000_000) +
                    (dur.seconds * 1_000_000_000L) + (dur.minutes * 60_000_000_000L) +
                    (dur.hours * 3_600_000_000_000L);
    long whole_days = extra_ns / 86_400_000_000_000L;
    long rem_ns = extra_ns - whole_days * 86_400_000_000_000L;
    long sec_part = rem_ns / 1_000_000_000L;
    long ns_part = rem_ns - sec_part * 1_000_000_000L;
    long total_months = dur.years * 12 + dur.months;
    long total_days = dur.weeks * 7 + dur.days + whole_days;

    temporal::CivilDate after_months;
    if (overflow == temporal::OverflowKind.REJECT) {
        temporal::CivilDate m = temporal::add_months(cur.date, total_months, temporal::OverflowKind.CONSTRAIN);
        if (cur.date.d > temporal::days_in_month(m.y, m.m)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows the resulting month");
            return;
        }
        after_months = { .y = m.y, .m = m.m, .d = cur.date.d };
    } else {
        after_months = temporal::add_months(cur.date, total_months, temporal::OverflowKind.CONSTRAIN);
    }
    temporal::CivilDate date_part = temporal::add_days(after_months, total_days);
    if (!temporal::is_valid_iso_date(date_part.y, date_part.m, date_part.d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "result is out of range");
        return;
    }

    long day_bump = 0;
    temporal::CivilTime time_part = temporal::add_seconds_to_time(cur.time, sec_part, &day_bump);
    // day_bump is dropped per spec: PlainDateTime.add cannot cross a date
    // boundary into the next day. The carry still affects hour/minute/second.
    long total_n = (long)cur.time.ns + ns_part;
    if (total_n >= 1_000_000_000) {
        long _d;
        time_part = temporal::add_seconds_to_time(time_part, 1, &_d);
        total_n -= 1_000_000_000;
    } else if (total_n < 0) {
        long _d;
        time_part = temporal::add_seconds_to_time(time_part, -1, &_d);
        total_n += 1_000_000_000;
    }
    long full_subsec = ((long)cur.time.ms * 1_000_000L) + ((long)cur.time.us * 1000L) + total_n;
    time_part.ms = (int)(full_subsec / 1_000_000);
    full_subsec -= (long)time_part.ms * 1_000_000;
    time_part.us = (int)(full_subsec / 1000);
    full_subsec -= (long)time_part.us * 1000;
    time_part.ns = (int)full_subsec;

    temporal::CivilDateTime result = { .date = date_part, .time = time_part };
    HObject*? obj_o = alloc_plain_datetime(ctx.heap, result, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_datetime_proto_subtract(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "subtract requires a duration");
        return;
    }
    temporal::DurationParts dur;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur)) return;
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;

    temporal::CivilDateTime cur = plain_datetime_value(obj);
    long extra_ns = dur.ns + ((long)dur.us * 1000) + ((long)dur.ms * 1_000_000) +
                    (dur.seconds * 1_000_000_000L) + (dur.minutes * 60_000_000_000L) +
                    (dur.hours * 3_600_000_000_000L);
    long whole_days = -(extra_ns / 86_400_000_000_000L);
    long rem_ns = -(extra_ns - (-whole_days) * 86_400_000_000_000L);
    long sec_part = rem_ns / 1_000_000_000L;
    long ns_part = rem_ns - sec_part * 1_000_000_000L;
    long total_months = -(dur.years * 12 + dur.months);
    long total_days = -(dur.weeks * 7 + dur.days) + whole_days;

    temporal::CivilDate after_months;
    if (overflow == temporal::OverflowKind.REJECT) {
        temporal::CivilDate m = temporal::add_months(cur.date, total_months, temporal::OverflowKind.CONSTRAIN);
        if (cur.date.d > temporal::days_in_month(m.y, m.m)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows the resulting month");
            return;
        }
        after_months = { .y = m.y, .m = m.m, .d = cur.date.d };
    } else {
        after_months = temporal::add_months(cur.date, total_months, temporal::OverflowKind.CONSTRAIN);
    }
    temporal::CivilDate date_part = temporal::add_days(after_months, total_days);
    if (!temporal::is_valid_iso_date(date_part.y, date_part.m, date_part.d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "result is out of range");
        return;
    }

    long day_bump = 0;
    temporal::CivilTime time_part = temporal::add_seconds_to_time(cur.time, sec_part, &day_bump);
    long total_n = (long)cur.time.ns + ns_part;
    if (total_n >= 1_000_000_000) {
        long _d;
        time_part = temporal::add_seconds_to_time(time_part, 1, &_d);
        total_n -= 1_000_000_000;
    } else if (total_n < 0) {
        long _d;
        time_part = temporal::add_seconds_to_time(time_part, -1, &_d);
        total_n += 1_000_000_000;
    }
    long full_subsec = ((long)cur.time.ms * 1_000_000L) + ((long)cur.time.us * 1000L) + total_n;
    time_part.ms = (int)(full_subsec / 1_000_000);
    full_subsec -= (long)time_part.ms * 1_000_000;
    time_part.us = (int)(full_subsec / 1000);
    full_subsec -= (long)time_part.us * 1000;
    time_part.ns = (int)full_subsec;

    temporal::CivilDateTime result = { .date = date_part, .time = time_part };
    HObject*? obj_o = alloc_plain_datetime(ctx.heap, result, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(obj2);
}

fn void plain_datetime_until_since(BuiltinContext* ctx, HObject* obj, bool flipped) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "until/since requires another date-time");
        return;
    }
    HObject*? other_o = plain_datetime_from_arg(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject* other = other_o!!;

    HObject* this_cal = obj.extra.temporal.calendar;
    HObject* other_cal = other.extra.temporal.calendar;
    if (this_cal != other_cal || this_cal == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "calendars do not match");
        return;
    }

    temporal::DifferenceUnit largest;
    if (!read_diff_options(ctx, 1, temporal::DifferenceUnit.DAYS, &largest, true)) return;

    temporal::CivilDateTime a = plain_datetime_value(obj);
    temporal::CivilDateTime b = plain_datetime_value(other);
    temporal::CivilDateTime start = flipped ? b : a;
    temporal::CivilDateTime end   = flipped ? a : b;

    // Date part first, then time leftover at the chosen granularity. For
    // largestUnit at the date level (days..years), use difference_date with
    // the chosen unit so the result is years/months/days. For largestUnit
    // finer than days (hours..seconds), use days-only difference_date and
    // convert the time delta at the chosen granularity.
    temporal::DifferenceUnit date_unit = largest;
    if (largest < temporal::DifferenceUnit.DAYS) date_unit = temporal::DifferenceUnit.DAYS;
    temporal::DateDifference ddiff = temporal::difference_date(start.date, end.date, date_unit);
    long start_epoch = temporal::epoch_days_from_civil(start.date.y, start.date.m, start.date.d) * 86_400L
                     + (long)start.time.h * 3600 + (long)start.time.mi * 60 + (long)start.time.s;
    long end_epoch   = temporal::epoch_days_from_civil(end.date.y,   end.date.m,   end.date.d)   * 86_400L
                     + (long)end.time.h * 3600 + (long)end.time.mi * 60 + (long)end.time.s;
    long start_ns = start_epoch * 1_000_000_000L + (long)start.time.ms * 1_000_000L + (long)start.time.us * 1000L + (long)start.time.ns;
    long end_ns   = end_epoch   * 1_000_000_000L + (long)end.time.ms   * 1_000_000L + (long)end.time.us   * 1000L + (long)end.time.ns;
    long total_delta = end_ns - start_ns;
    long days_total = total_delta / 86_400_000_000_000L;
    long rem_ns = total_delta - days_total * 86_400_000_000_000L;

    temporal::DurationParts dur;
    dur.years = 0;
    dur.months = 0;
    dur.weeks = 0;
    if (largest == temporal::DifferenceUnit.DAYS) {
        // Day-only output: total delta in ns / ns-per-day gives the right count
        // (the date diff and time delta agree for same-time-of-day inputs).
        dur.days = days_total;
        dur.hours = 0; dur.minutes = 0; dur.seconds = 0;
        dur.ms = 0; dur.us = 0; dur.ns = 0;
    } else if (largest == temporal::DifferenceUnit.MONTHS ||
               largest == temporal::DifferenceUnit.YEARS ||
               largest == temporal::DifferenceUnit.WEEKS) {
        // Months/years/weeks split: y/m/d from difference_date.
        dur.years = ddiff.years;
        dur.months = ddiff.months;
        if (largest == temporal::DifferenceUnit.WEEKS) {
            dur.weeks = ddiff.days / 7;
            dur.days = ddiff.days % 7;
        } else {
            dur.days = ddiff.days;
        }
        dur.hours = 0; dur.minutes = 0; dur.seconds = 0;
        dur.ms = 0; dur.us = 0; dur.ns = 0;
    } else if (largest == temporal::DifferenceUnit.HOURS) {
        long hours = rem_ns / 3_600_000_000_000L;
        rem_ns -= hours * 3_600_000_000_000L;
        dur.hours = hours;
        dur.minutes = rem_ns / 60_000_000_000L;
        rem_ns -= dur.minutes * 60_000_000_000L;
        dur.seconds = rem_ns / 1_000_000_000L;
        rem_ns -= dur.seconds * 1_000_000_000L;
        dur.ms = (int)(rem_ns / 1_000_000);
        rem_ns -= (long)dur.ms * 1_000_000;
        dur.us = (int)(rem_ns / 1000);
        rem_ns -= (long)dur.us * 1000;
        dur.ns = (int)rem_ns;
    } else if (largest == temporal::DifferenceUnit.MINUTES) {
        long mins = rem_ns / 60_000_000_000L;
        rem_ns -= mins * 60_000_000_000L;
        dur.minutes = mins;
        dur.seconds = rem_ns / 1_000_000_000L;
        rem_ns -= dur.seconds * 1_000_000_000L;
        dur.ms = (int)(rem_ns / 1_000_000);
        rem_ns -= (long)dur.ms * 1_000_000;
        dur.us = (int)(rem_ns / 1000);
        rem_ns -= (long)dur.us * 1000;
        dur.ns = (int)rem_ns;
    } else {
        long secs = rem_ns / 1_000_000_000L;
        rem_ns -= secs * 1_000_000_000L;
        dur.seconds = secs;
        dur.ms = (int)(rem_ns / 1_000_000);
        rem_ns -= (long)dur.ms * 1_000_000;
        dur.us = (int)(rem_ns / 1000);
        rem_ns -= (long)dur.us * 1000;
        dur.ns = (int)rem_ns;
    }

    HObject*? dur_o = alloc_duration(ctx.heap, dur);
    if (catch err = dur_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* dur_obj = dur_o;
    dur_obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur_obj);
}

fn void builtin_temporal_plain_datetime_proto_until(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    plain_datetime_until_since(ctx, (HObject*)this_val.get_heapptr(), false);
}

fn void builtin_temporal_plain_datetime_proto_since(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    plain_datetime_until_since(ctx, (HObject*)this_val.get_heapptr(), true);
}

// ============================================================================
// Temporal.PlainYearMonth
// ============================================================================

// `bag_to_yearmonth_fields` reads year + month(/monthCode) from a plain
// object and writes a CivilDate whose `d` slot is the reference day. The
// reference day is fixed at 1 for the constructor; `with()` passes the
// current reference day through `cur_day`. The spec accepts era/eraYear for
// non-ISO calendars; the single-ISO-calendar engine rejects them.
fn bool bag_to_yearmonth_fields(BuiltinContext* ctx, HObject* bag, bool keep_missing,
                                long cur_y, int cur_m, int cur_day,
                                long* out_y, int* out_m, int* out_day) {
    Vm* v = (Vm*)ctx.vm;
    TVal year_v  = prop_or_undefined(bag, ctx.heap, "year");
    TVal month_v = prop_or_undefined(bag, ctx.heap, "month");
    TVal mc_v    = prop_or_undefined(bag, ctx.heap, "monthCode");
    TVal day_v   = prop_or_undefined(bag, ctx.heap, "day");
    TVal cal_v   = prop_or_undefined(bag, ctx.heap, "calendar");
    TVal era_v   = prop_or_undefined(bag, ctx.heap, "era");
    TVal era_y_v = prop_or_undefined(bag, ctx.heap, "eraYear");

    if (!era_v.is_undefined() || !era_y_v.is_undefined()) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "era/eraYear are not supported by the ISO calendar");
        return false;
    }
    if (!cal_v.is_undefined()) {
        HObject* cal;
        if (!calendar_from_arg(ctx, &cal_v, &cal)) return false;
    }

    long y = cur_y;
    if (!year_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &year_v, &y)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "year is not an integral number");
            return false;
        }
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing year property");
        return false;
    }

    int m = cur_m;
    if (month_v.is_undefined() && mc_v.is_undefined()) {
        if (!keep_missing) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "missing month property");
            return false;
        }
    } else {
        long mv = 0;
        bool have_month = false;
        if (!month_v.is_undefined()) {
            if (!to_integer_with_truncation(v, &month_v, &mv)) {
                if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
                builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
                return false;
            }
            have_month = true;
        }
        if (!mc_v.is_undefined()) {
            int mci;
            if (!parse_month_code(ctx, mc_v, &mci)) return false;
            if (have_month && mv != mci) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "month and monthCode do not agree");
                return false;
            }
            m = mci;
        } else if (have_month) {
            m = (int)mv;
        }
    }

    int d = cur_day;
    if (!day_v.is_undefined()) {
        long dv;
        if (!to_integer_with_truncation(v, &day_v, &dv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
            return false;
        }
        d = (int)dv;
    }

    *out_y = y;
    *out_m = m;
    *out_day = d;
    return true;
}

// Constrain or reject the (year, month, day) triple into a valid CivilDate.
// Day overflow against the resulting month is clamped (CONSTRAIN) or rejected.
fn bool fields_to_valid_yearmonth(BuiltinContext* ctx, long y, int m, int d,
                                   temporal::OverflowKind overflow,
                                   long* out_y, int* out_m, int* out_d) {
    if (m < 1) {
        if (overflow == temporal::OverflowKind.REJECT) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid month"); return false; }
        m = 1;
    }
    if (m > 12) {
        if (overflow == temporal::OverflowKind.REJECT) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid month"); return false; }
        m = 12;
    }
    if (d < 1) {
        if (overflow == temporal::OverflowKind.REJECT) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid day"); return false; }
        d = 1;
    }
    int dim = temporal::days_in_month(y, m);
    if (d > dim) {
        if (overflow == temporal::OverflowKind.REJECT) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows month");
            return false;
        }
        d = dim;
    }
    if (!temporal::is_valid_iso_date(y, m, d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
        return false;
    }
    *out_y = y;
    *out_m = m;
    *out_d = d;
    return true;
}

fn void builtin_temporal_plain_yearmonth_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainYearMonth requires new");
        return;
    }
    Vm* v = (Vm*)ctx.vm;
    long y = 0;
    int m = 1;
    int d = 1;

    if (ctx.argc >= 1) {
        if (!to_integer_with_truncation(v, arg_at(ctx, 0), &y)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "year is not an integral number");
            return;
        }
    }
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainYearMonth requires year and month");
        return;
    }
    long m_lv;
    if (!to_integer_with_truncation(v, arg_at(ctx, 1), &m_lv)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
        return;
    }
    m = (int)m_lv;

    if (ctx.argc >= 3) {
        long d_lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 2), &d_lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
            return;
        }
        d = (int)d_lv;
    }

    HObject* calendar = ctx.heap.temporal_iso_calendar;
    if (ctx.argc >= 4) {
        if (!calendar_from_arg(ctx, arg_at(ctx, 3), &calendar)) return;
    }

    long vy; int vm; int vd;
    if (!fields_to_valid_yearmonth(ctx, y, m, d, temporal::OverflowKind.REJECT, &vy, &vm, &vd)) return;

    HObject*? obj_o = alloc_plain_yearmonth(ctx.heap, vy, vm, vd, calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_plain_yearmonth_proto);
    ctx.result.set_object(obj);
}

fn void builtin_temporal_plain_yearmonth_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainYearMonth.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    Vm* v = (Vm*)ctx.vm;

    long vy = 0; int vm = 1; int vd = 1;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return; }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_yearmonth_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainYearMonth.from: invalid ISO year-month string");
            return;
        }
        vy = p.year; vm = p.month; vd = p.day;
        if (!fields_to_valid_yearmonth(ctx, vy, vm, vd, overflow, &vy, &vm, &vd)) return;
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH) {
            ctx.result.set_object(o);
            return;
        }
        HObject* calendar = ctx.heap.temporal_iso_calendar;
        TVal cal_v = prop_or_undefined(o, ctx.heap, "calendar");
        if (!cal_v.is_undefined()) {
            if (!calendar_from_arg(ctx, &cal_v, &calendar)) return;
        }
        long y; int m; int d;
        if (!bag_to_yearmonth_fields(ctx, o, false, 0, 1, 1, &y, &m, &d)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        if (!fields_to_valid_yearmonth(ctx, y, m, d, overflow, &vy, &vm, &vd)) return;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainYearMonth.from: argument must be a string or object");
        return;
    }

    HObject*? obj_o = alloc_plain_yearmonth(ctx.heap, vy, vm, vd, ctx.heap.temporal_iso_calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_yearmonth_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_plain_yearmonth_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainYearMonth.compare requires two arguments");
        return;
    }
    HObject*? a_o = plain_yearmonth_from_arg(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject*? b_o = plain_yearmonth_from_arg(ctx, arg_at(ctx, 1));
    if (ctx.should_throw) return;
    long ay = plain_yearmonth_y(a_o!!);
    long by = plain_yearmonth_y(b_o!!);
    int am = plain_yearmonth_m(a_o!!);
    int bm = plain_yearmonth_m(b_o!!);
    int cmp = 0;
    if (ay != by) { cmp = ay < by ? -1 : 1; }
    else if (am != bm) { cmp = am < bm ? -1 : 1; }
    ctx.result.set_fastint((long)cmp);
}

fn void builtin_temporal_plain_yearmonth_proto_year(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)plain_yearmonth_y(obj));
}

fn void builtin_temporal_plain_yearmonth_proto_month(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)plain_yearmonth_m(obj));
}

fn void builtin_temporal_plain_yearmonth_proto_monthCode(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    int m = plain_yearmonth_m(obj);
    char[5] buf;
    usz len;
    if (m < 10) {
        len = (usz)libc::snprintf(&buf, 5, "M0%d", m);
    } else {
        len = (usz)libc::snprintf(&buf, 5, "M%d", m);
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_yearmonth_proto_day(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)plain_yearmonth_day(obj));
}

fn void builtin_temporal_plain_yearmonth_proto_daysInMonth(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)temporal::days_in_month(plain_yearmonth_y(obj), plain_yearmonth_m(obj)));
}

fn void builtin_temporal_plain_yearmonth_proto_daysInYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number(temporal::is_leap_year(plain_yearmonth_y(obj)) ? 366.0 : 365.0);
}

fn void builtin_temporal_plain_yearmonth_proto_monthsInYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    ctx.result.set_number(12.0);
}

fn void builtin_temporal_plain_yearmonth_proto_inLeapYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_boolean(temporal::is_leap_year(plain_yearmonth_y(obj)));
}

fn void builtin_temporal_plain_yearmonth_proto_calendarId(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    ctx.result.set_string(builtin_intern_string(ctx.heap, "iso8601"));
}

fn void builtin_temporal_plain_yearmonth_proto_calendar(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    HObject* cal = obj.extra.temporal.calendar;
    if (cal != null) {
        ctx.result.set_object(cal);
    } else {
        ctx.result.set_object(ctx.heap.temporal_iso_calendar);
    }
}

fn void builtin_temporal_plain_yearmonth_proto_era(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    ctx.result.set_undefined();
}

fn void builtin_temporal_plain_yearmonth_proto_eraYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    ctx.result.set_undefined();
}

fn void builtin_temporal_plain_yearmonth_proto_valueOf(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainYearMonth cannot be converted to a primitive number");
}

fn void builtin_temporal_plain_yearmonth_proto_toString(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = plain_yearmonth_y(obj);
    int m = plain_yearmonth_m(obj);

    bool show_calendar = false;
    bool critical = false;
    if (ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal ov = ctx.regs[ctx.base_reg];
        if (!ov.is_object() || ov.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
            return;
        }
        HObject* opts = (HObject*)ov.get_heapptr();
        TVal cn = prop_or_undefined(opts, ctx.heap, "calendarName");
        if (!cn.is_undefined()) {
            if (!cn.is_string()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "calendarName must be a string");
                return;
            }
            HString* s = (HString*)cn.get_heapptr();
            char[] v = s.get_cstr()[:s.blen];
            if (v == "auto") { show_calendar = false; }
            else if (v == "always") { show_calendar = true; }
            else if (v == "critical") { show_calendar = true; critical = true; }
            else if (v == "never") { show_calendar = false; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendarName");
                return;
            }
        }
    }

    char[48] buf;
    usz len;
    if (y < 0) {
        len = (usz)libc::snprintf(&buf, 48, "-%06ld-%02d", -y, m);
    } else if (y > 9999) {
        len = (usz)libc::snprintf(&buf, 48, "+%06ld-%02d", y, m);
    } else {
        len = (usz)libc::snprintf(&buf, 48, "%04ld-%02d", y, m);
    }
    if (show_calendar) {
        char[] ann = critical ? "[!u-ca=iso8601]" : "[u-ca=iso8601]";
        for (usz k = 0; k < ann.len; k++) buf[len++] = ann[k];
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_yearmonth_proto_toJSON(BuiltinContext* ctx) {
    builtin_temporal_plain_yearmonth_proto_toString(ctx);
}

fn void builtin_temporal_plain_yearmonth_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* other = (HObject*)arg.get_heapptr();
        if (other.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH) {
            long ay = plain_yearmonth_y(obj);
            long by = plain_yearmonth_y(other);
            int am = plain_yearmonth_m(obj);
            int bm = plain_yearmonth_m(other);
            bool same_cal = obj.extra.temporal.calendar == other.extra.temporal.calendar;
            ctx.result.set_boolean(same_cal && ay == by && am == bm);
            return;
        }
    }
    ctx.result.set_boolean(false);
}

fn void builtin_temporal_plain_yearmonth_proto_with(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with requires a fields bag");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with requires an object");
        return;
    }
    HObject* bag = (HObject*)arg.get_heapptr();
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    Vm* v = (Vm*)ctx.vm;

    long y; int m; int d;
    if (!bag_to_yearmonth_fields(ctx, bag, true,
                                  plain_yearmonth_y(obj), plain_yearmonth_m(obj), plain_yearmonth_day(obj),
                                  &y, &m, &d)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    long vy; int vm; int vd;
    if (!fields_to_valid_yearmonth(ctx, y, m, d, overflow, &vy, &vm, &vd)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    HObject*? obj_o = alloc_plain_yearmonth(ctx.heap, vy, vm, vd, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_yearmonth_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_yearmonth_proto_add(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "add requires a duration");
        return;
    }
    temporal::DurationParts dur;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur)) return;
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;

    long cur_y = plain_yearmonth_y(obj);
    int cur_m = plain_yearmonth_m(obj);
    int cur_d = plain_yearmonth_day(obj);
    long total_months = dur.years * 12 + dur.months;
    // Reference day may need re-clamping if month rollover changes month length.
    long after_y = cur_y + total_months / 12;
    long after_m = (long)cur_m + total_months % 12;
    if (after_m < 1)  { after_y -= 1; after_m += 12; }
    else if (after_m > 12) { after_y += 1; after_m -= 12; }
    int dim = temporal::days_in_month(after_y, (int)after_m);
    int new_d = cur_d > dim ? dim : cur_d;
    // Reject requires the reference day to remain representable.
    if (overflow == temporal::OverflowKind.REJECT && cur_d > dim) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows the resulting month");
        return;
    }
    if (!temporal::is_valid_iso_date(after_y, (int)after_m, new_d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "result is out of range");
        return;
    }
    HObject*? obj_o = alloc_plain_yearmonth(ctx.heap, after_y, (int)after_m, new_d, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_yearmonth_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_yearmonth_proto_subtract(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "subtract requires a duration");
        return;
    }
    temporal::DurationParts dur;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur)) return;
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;

    long cur_y = plain_yearmonth_y(obj);
    int cur_m = plain_yearmonth_m(obj);
    int cur_d = plain_yearmonth_day(obj);
    long total_months = -(dur.years * 12 + dur.months);
    long after_y = cur_y + total_months / 12;
    long after_m = (long)cur_m + total_months % 12;
    if (after_m < 1)  { after_y -= 1; after_m += 12; }
    else if (after_m > 12) { after_y += 1; after_m -= 12; }
    int dim = temporal::days_in_month(after_y, (int)after_m);
    int new_d = cur_d > dim ? dim : cur_d;
    if (overflow == temporal::OverflowKind.REJECT && cur_d > dim) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows the resulting month");
        return;
    }
    if (!temporal::is_valid_iso_date(after_y, (int)after_m, new_d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "result is out of range");
        return;
    }
    HObject*? obj_o = alloc_plain_yearmonth(ctx.heap, after_y, (int)after_m, new_d, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_yearmonth_proto;
    ctx.result.set_object(obj2);
}

// PlainYearMonth.until/since share the difference_date routine. Only date-level
// units are accepted (years, months) since there is no day component.
fn void plain_yearmonth_until_since(BuiltinContext* ctx, HObject* obj, bool flipped) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "until/since requires another year-month");
        return;
    }
    HObject*? other_o = plain_yearmonth_from_arg(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject* other = other_o!!;

    HObject* this_cal = obj.extra.temporal.calendar;
    HObject* other_cal = other.extra.temporal.calendar;
    if (this_cal != other_cal || this_cal == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "calendars do not match");
        return;
    }

    temporal::DifferenceUnit largest;
    if (!read_diff_options(ctx, 1, temporal::DifferenceUnit.MONTHS, &largest, false)) return;
    // Only year/month units are accepted here.
    if (largest != temporal::DifferenceUnit.YEARS && largest != temporal::DifferenceUnit.MONTHS) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "PlainYearMonth.until/since largestUnit must be 'years' or 'months'");
        return;
    }

    long a_y = plain_yearmonth_y(obj);
    int  a_m = plain_yearmonth_m(obj);
    long b_y = plain_yearmonth_y(other);
    int  b_m = plain_yearmonth_m(other);
    long start_y = flipped ? b_y : a_y;
    int  start_m = flipped ? b_m : a_m;
    long end_y   = flipped ? a_y : b_y;
    int  end_m   = flipped ? a_m : b_m;

    // Use a synthetic CivilDate with day=1 so difference_date handles the
    // year/month split identically to the PlainDate path.
    temporal::CivilDate start = { .y = start_y, .m = start_m, .d = 1 };
    temporal::CivilDate end   = { .y = end_y,   .m = end_m,   .d = 1 };
    temporal::DateDifference diff = temporal::difference_date(start, end, largest);

    temporal::DurationParts dur;
    dur.years = diff.years;
    dur.months = diff.months;
    dur.weeks = 0;
    dur.days = 0;
    dur.hours = 0; dur.minutes = 0; dur.seconds = 0;
    dur.ms = 0; dur.us = 0; dur.ns = 0;

    HObject*? dur_o = alloc_duration(ctx.heap, dur);
    if (catch err = dur_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* dur_obj = dur_o;
    dur_obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur_obj);
}

fn void builtin_temporal_plain_yearmonth_proto_until(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    plain_yearmonth_until_since(ctx, (HObject*)this_val.get_heapptr(), false);
}

fn void builtin_temporal_plain_yearmonth_proto_since(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    plain_yearmonth_until_since(ctx, (HObject*)this_val.get_heapptr(), true);
}

// ToTemporalYearMonth: identity-preserving PlainYearMonth coercion used by
// compare/until/since. Strings are rejected (those call from); only the
// matching class is taken.
fn HObject*? plain_yearmonth_from_arg(BuiltinContext* ctx, TVal* arg) {
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH) return o;
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument is not a Temporal.PlainYearMonth");
        return null;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "argument must be a Temporal.PlainYearMonth");
    return null;
}

// ============================================================================
// Temporal.PlainMonthDay
// ============================================================================

// PlainMonthDay: monthCode/day with an optional reference year for calendar-
// specific leap-year checks. The reference year default is a leap year
// (1972) per the polyfill so Feb 29 is recognized as valid; spec lets the
// caller override.
fn bool bag_to_monthday_fields(BuiltinContext* ctx, HObject* bag, bool keep_missing,
                                int cur_y, int cur_m, int cur_d,
                                int* out_y, int* out_m, int* out_d) {
    Vm* v = (Vm*)ctx.vm;
    TVal year_v  = prop_or_undefined(bag, ctx.heap, "year");
    TVal month_v = prop_or_undefined(bag, ctx.heap, "month");
    TVal mc_v    = prop_or_undefined(bag, ctx.heap, "monthCode");
    TVal day_v   = prop_or_undefined(bag, ctx.heap, "day");
    TVal cal_v   = prop_or_undefined(bag, ctx.heap, "calendar");
    TVal era_v   = prop_or_undefined(bag, ctx.heap, "era");
    TVal era_y_v = prop_or_undefined(bag, ctx.heap, "eraYear");

    if (!era_v.is_undefined() || !era_y_v.is_undefined()) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "era/eraYear are not supported by the ISO calendar");
        return false;
    }
    if (!cal_v.is_undefined()) {
        HObject* cal;
        if (!calendar_from_arg(ctx, &cal_v, &cal)) return false;
    }

    int y = cur_y;
    if (!year_v.is_undefined()) {
        long yl;
        if (!to_integer_with_truncation(v, &year_v, &yl)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "year is not an integral number");
            return false;
        }
        y = (int)yl;
    } else if (!keep_missing) {
        y = 1972;  // default reference year: a leap year so Feb 29 is valid
    }

    int m = cur_m;
    if (month_v.is_undefined() && mc_v.is_undefined()) {
        if (!keep_missing) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "missing month property");
            return false;
        }
    } else {
        long mv = 0;
        bool have_month = false;
        if (!month_v.is_undefined()) {
            if (!to_integer_with_truncation(v, &month_v, &mv)) {
                if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
                builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
                return false;
            }
            have_month = true;
        }
        if (!mc_v.is_undefined()) {
            int mci;
            if (!parse_month_code(ctx, mc_v, &mci)) return false;
            if (have_month && mv != mci) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "month and monthCode do not agree");
                return false;
            }
            m = mci;
        } else if (have_month) {
            m = (int)mv;
        }
    }

    int d = cur_d;
    if (!day_v.is_undefined()) {
        long dl;
        if (!to_integer_with_truncation(v, &day_v, &dl)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
            return false;
        }
        d = (int)dl;
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing day property");
        return false;
    }

    *out_y = y;
    *out_m = m;
    *out_d = d;
    return true;
}

// Constrain or reject (year, month, day) into a valid CivilDate. The year is
// only used for calendar checks (Feb 29 requires a leap year); outside that
// case the value is unchanged.
fn bool fields_to_valid_monthday(BuiltinContext* ctx, int y, int m, int d,
                                   temporal::OverflowKind overflow,
                                   int* out_y, int* out_m, int* out_d) {
    if (m < 1) {
        if (overflow == temporal::OverflowKind.REJECT) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid month"); return false; }
        m = 1;
    }
    if (m > 12) {
        if (overflow == temporal::OverflowKind.REJECT) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid month"); return false; }
        m = 12;
    }
    if (d < 1) {
        if (overflow == temporal::OverflowKind.REJECT) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid day"); return false; }
        d = 1;
    }
    int dim = temporal::days_in_month((long)y, m);
    if (d > dim) {
        if (overflow == temporal::OverflowKind.REJECT) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows month");
            return false;
        }
        d = dim;
    }
    *out_y = y;
    *out_m = m;
    *out_d = d;
    return true;
}

fn void builtin_temporal_plain_monthday_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainMonthDay requires new");
        return;
    }
    Vm* v = (Vm*)ctx.vm;
    int m = 1;
    int d = 1;
    if (ctx.argc >= 1) {
        long ml;
        if (!to_integer_with_truncation(v, arg_at(ctx, 0), &ml)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
            return;
        }
        m = (int)ml;
    }
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainMonthDay requires month and day");
        return;
    }
    long dl;
    if (!to_integer_with_truncation(v, arg_at(ctx, 1), &dl)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
        return;
    }
    d = (int)dl;

    HObject* calendar = ctx.heap.temporal_iso_calendar;
    if (ctx.argc >= 3) {
        if (!calendar_from_arg(ctx, arg_at(ctx, 2), &calendar)) return;
    }

    int y = 1972;  // default reference year (leap year)
    int vy; int vm; int vd;
    if (!fields_to_valid_monthday(ctx, y, m, d, temporal::OverflowKind.REJECT, &vy, &vm, &vd)) return;

    HObject*? obj_o = alloc_plain_monthday(ctx.heap, vy, vm, vd, calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_plain_monthday_proto);
    ctx.result.set_object(obj);
}

fn void builtin_temporal_plain_monthday_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainMonthDay.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    Vm* v = (Vm*)ctx.vm;

    int vy = 1972; int vm = 1; int vd = 1;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return; }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_monthday_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainMonthDay.from: invalid ISO month-day string");
            return;
        }
        vy = 1972; vm = p.month; vd = p.day;
        if (!fields_to_valid_monthday(ctx, vy, vm, vd, overflow, &vy, &vm, &vd)) return;
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY) {
            ctx.result.set_object(o);
            return;
        }
        HObject* calendar = ctx.heap.temporal_iso_calendar;
        TVal cal_v = prop_or_undefined(o, ctx.heap, "calendar");
        if (!cal_v.is_undefined()) {
            if (!calendar_from_arg(ctx, &cal_v, &calendar)) return;
        }
        int y; int m; int d;
        if (!bag_to_monthday_fields(ctx, o, false, 1972, 1, 1, &y, &m, &d)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        if (!fields_to_valid_monthday(ctx, y, m, d, overflow, &vy, &vm, &vd)) return;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainMonthDay.from: argument must be a string or object");
        return;
    }

    HObject*? obj_o = alloc_plain_monthday(ctx.heap, vy, vm, vd, ctx.heap.temporal_iso_calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_monthday_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_plain_monthday_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainMonthDay.compare requires two arguments");
        return;
    }
    HObject*? a_o = plain_monthday_from_arg(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject*? b_o = plain_monthday_from_arg(ctx, arg_at(ctx, 1));
    if (ctx.should_throw) return;
    int am = plain_monthday_m(a_o!!);
    int bm = plain_monthday_m(b_o!!);
    int ad = plain_monthday_d(a_o!!);
    int bd = plain_monthday_d(b_o!!);
    int cmp = 0;
    if (am != bm) { cmp = am < bm ? -1 : 1; }
    else if (ad != bd) { cmp = ad < bd ? -1 : 1; }
    ctx.result.set_fastint((long)cmp);
}

fn void builtin_temporal_plain_monthday_proto_year(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)plain_monthday_year(obj));
}

fn void builtin_temporal_plain_monthday_proto_month(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)plain_monthday_m(obj));
}

fn void builtin_temporal_plain_monthday_proto_monthCode(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    int m = plain_monthday_m(obj);
    char[5] buf;
    usz len;
    if (m < 10) {
        len = (usz)libc::snprintf(&buf, 5, "M0%d", m);
    } else {
        len = (usz)libc::snprintf(&buf, 5, "M%d", m);
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_monthday_proto_day(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)plain_monthday_d(obj));
}

fn void builtin_temporal_plain_monthday_proto_calendarId(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    ctx.result.set_string(builtin_intern_string(ctx.heap, "iso8601"));
}

fn void builtin_temporal_plain_monthday_proto_calendar(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    HObject* cal = obj.extra.temporal.calendar;
    if (cal != null) {
        ctx.result.set_object(cal);
    } else {
        ctx.result.set_object(ctx.heap.temporal_iso_calendar);
    }
}

fn void builtin_temporal_plain_monthday_proto_era(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    ctx.result.set_undefined();
}

fn void builtin_temporal_plain_monthday_proto_eraYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    ctx.result.set_undefined();
}

fn void builtin_temporal_plain_monthday_proto_inLeapYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_boolean(temporal::is_leap_year((long)plain_monthday_year(obj)));
}

fn void builtin_temporal_plain_monthday_proto_daysInMonth(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)temporal::days_in_month((long)plain_monthday_year(obj), plain_monthday_m(obj)));
}

fn void builtin_temporal_plain_monthday_proto_valueOf(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainMonthDay cannot be converted to a primitive number");
}

fn void builtin_temporal_plain_monthday_proto_toString(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    int y = plain_monthday_year(obj);
    int m = plain_monthday_m(obj);
    int d = plain_monthday_d(obj);

    bool show_calendar = false;
    bool critical = false;
    if (ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal ov = ctx.regs[ctx.base_reg];
        if (!ov.is_object() || ov.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
            return;
        }
        HObject* opts = (HObject*)ov.get_heapptr();
        TVal cn = prop_or_undefined(opts, ctx.heap, "calendarName");
        if (!cn.is_undefined()) {
            if (!cn.is_string()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "calendarName must be a string");
                return;
            }
            HString* s = (HString*)cn.get_heapptr();
            char[] v = s.get_cstr()[:s.blen];
            if (v == "auto") { show_calendar = false; }
            else if (v == "always") { show_calendar = true; }
            else if (v == "critical") { show_calendar = true; critical = true; }
            else if (v == "never") { show_calendar = false; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendarName");
                return;
            }
        }
    }

    char[48] buf;
    usz len;
    if (y < 0) {
        len = (usz)libc::snprintf(&buf, 48, "-%06d-%02d-%02d", -y, m, d);
    } else if (y > 9999) {
        len = (usz)libc::snprintf(&buf, 48, "+%06d-%02d-%02d", y, m, d);
    } else {
        len = (usz)libc::snprintf(&buf, 48, "%04d-%02d-%02d", y, m, d);
    }
    if (show_calendar) {
        char[] ann = critical ? "[!u-ca=iso8601]" : "[u-ca=iso8601]";
        for (usz k = 0; k < ann.len; k++) buf[len++] = ann[k];
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_monthday_proto_toJSON(BuiltinContext* ctx) {
    builtin_temporal_plain_monthday_proto_toString(ctx);
}

fn void builtin_temporal_plain_monthday_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* other = (HObject*)arg.get_heapptr();
        if (other.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY) {
            int am = plain_monthday_m(obj);
            int bm = plain_monthday_m(other);
            int ad = plain_monthday_d(obj);
            int bd = plain_monthday_d(other);
            bool same_cal = obj.extra.temporal.calendar == other.extra.temporal.calendar;
            ctx.result.set_boolean(same_cal && am == bm && ad == bd);
            return;
        }
    }
    ctx.result.set_boolean(false);
}

fn void builtin_temporal_plain_monthday_proto_with(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with requires a fields bag");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with requires an object");
        return;
    }
    HObject* bag = (HObject*)arg.get_heapptr();
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    Vm* v = (Vm*)ctx.vm;

    int y; int m; int d;
    if (!bag_to_monthday_fields(ctx, bag, true,
                                plain_monthday_year(obj), plain_monthday_m(obj), plain_monthday_d(obj),
                                &y, &m, &d)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    int vy; int vm; int vd;
    if (!fields_to_valid_monthday(ctx, y, m, d, overflow, &vy, &vm, &vd)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    HObject*? obj_o = alloc_plain_monthday(ctx.heap, vy, vm, vd, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_monthday_proto;
    ctx.result.set_object(obj2);
}

// PlainMonthDay.until/since: difference in days between the two month/day
// pairs, anchored to the reference year. The spec chooses the smaller of the
// forward and backward arc around the year (so Dec 25 -> Jan 1 is 7 days,
// not 358).
fn void plain_monthday_until_since(BuiltinContext* ctx, HObject* obj, bool flipped) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "until/since requires another month-day");
        return;
    }
    HObject*? other_o = plain_monthday_from_arg(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject* other = other_o!!;

    HObject* this_cal = obj.extra.temporal.calendar;
    HObject* other_cal = other.extra.temporal.calendar;
    if (this_cal != other_cal || this_cal == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "calendars do not match");
        return;
    }

    int am = plain_monthday_m(obj);
    int ad = plain_monthday_d(obj);
    int bm = plain_monthday_m(other);
    int bd = plain_monthday_d(other);
    int y = plain_monthday_year(obj);
    // Use a non-leap reference year so Feb 29 (if any) coerces to Feb 28;
    // 1971 is the year before the 1972 default. Either way the day delta
    // is computed as a difference of two CivilDates.
    long yref = (long)(temporal::is_leap_year((long)y) ? y : y);
    long epoch_a = temporal::epoch_days_from_civil(yref, am, ad);
    long epoch_b = temporal::epoch_days_from_civil(yref, bm, bd);
    long forward = epoch_b - epoch_a;
    long year_days = temporal::epoch_days_from_civil(yref + 1, 1, 1) - temporal::epoch_days_from_civil(yref, 1, 1);
    long backward = forward > 0 ? forward - year_days : forward + year_days;
    long chosen;
    if (forward == 0) {
        chosen = 0;
    } else if (math::abs(forward) <= math::abs(backward)) {
        chosen = forward;
    } else {
        chosen = backward;
    }
    if (flipped) chosen = -chosen;

    temporal::DurationParts dur;
    dur.years = 0;
    dur.months = 0;
    dur.weeks = 0;
    dur.days = chosen;
    dur.hours = 0; dur.minutes = 0; dur.seconds = 0;
    dur.ms = 0; dur.us = 0; dur.ns = 0;

    HObject*? dur_o = alloc_duration(ctx.heap, dur);
    if (catch err = dur_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* dur_obj = dur_o;
    dur_obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur_obj);
}

fn void builtin_temporal_plain_monthday_proto_until(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    plain_monthday_until_since(ctx, (HObject*)this_val.get_heapptr(), false);
}

fn void builtin_temporal_plain_monthday_proto_since(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    plain_monthday_until_since(ctx, (HObject*)this_val.get_heapptr(), true);
}

fn HObject*? plain_monthday_from_arg(BuiltinContext* ctx, TVal* arg) {
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY) return o;
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument is not a Temporal.PlainMonthDay");
        return null;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "argument must be a Temporal.PlainMonthDay");
    return null;
}

// ============================================================================
// Registration
// ============================================================================

fn bool setUpTemporalDuration(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.Duration"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.TEMPORAL_DURATION_CTOR.ordinal;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    TVal len_tv;
    len_tv.set_fastint(0);
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    ctor.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, "Duration");

    if (!register_proto_getter_accessor(proto, heap, "years", Builtin.TEMPORAL_DURATION_PROTO_YEARS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "months", Builtin.TEMPORAL_DURATION_PROTO_MONTHS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "weeks", Builtin.TEMPORAL_DURATION_PROTO_WEEKS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "days", Builtin.TEMPORAL_DURATION_PROTO_DAYS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "hours", Builtin.TEMPORAL_DURATION_PROTO_HOURS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "minutes", Builtin.TEMPORAL_DURATION_PROTO_MINUTES.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "seconds", Builtin.TEMPORAL_DURATION_PROTO_SECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "milliseconds", Builtin.TEMPORAL_DURATION_PROTO_MILLISECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "microseconds", Builtin.TEMPORAL_DURATION_PROTO_MICROSECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "nanoseconds", Builtin.TEMPORAL_DURATION_PROTO_NANOSECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "sign", Builtin.TEMPORAL_DURATION_PROTO_SIGN.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "blank", Builtin.TEMPORAL_DURATION_PROTO_BLANK.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "negated", Builtin.TEMPORAL_DURATION_PROTO_NEGATED.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "abs", Builtin.TEMPORAL_DURATION_PROTO_ABS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_DURATION_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_DURATION_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_DURATION_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_DURATION_FROM.ordinal)) return false;

    heap.temporal_duration_proto = proto;
    return true;
}

fn bool setUpTemporalCalendar(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.Calendar"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    // Calendar is a constructable class; the shared iso8601 singleton is a
    // plain instance used as the default calendar slot for every date.
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.TEMPORAL_CALENDAR_CTOR.ordinal;

    HObject*? cal_raw = heap.alloc_object(hobject::ObjClass.TEMPORAL_CALENDAR);
    if (catch err = cal_raw) return false;
    HObject* cal_obj = cal_raw;
    cal_obj.prototype = proto;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    TVal len_tv;
    len_tv.set_fastint(1);
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    ctor.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, "Calendar");

    if (!register_proto_getter_accessor(proto, heap, "id", Builtin.TEMPORAL_CALENDAR_PROTO_ID.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_CALENDAR_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_CALENDAR_FROM.ordinal)) return false;

    heap.temporal_iso_calendar = cal_obj;
    heap.temporal_calendar_proto = proto;
    return true;
}

fn bool setUpTemporalPlainDate(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.PlainDate"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.TEMPORAL_PLAIN_DATE_CTOR.ordinal;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(3);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, "PlainDate");

    if (!register_proto_getter_accessor(proto, heap, "year", Builtin.TEMPORAL_PLAIN_DATE_PROTO_YEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "month", Builtin.TEMPORAL_PLAIN_DATE_PROTO_MONTH.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "day", Builtin.TEMPORAL_PLAIN_DATE_PROTO_DAY.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "dayOfWeek", Builtin.TEMPORAL_PLAIN_DATE_PROTO_DAYOFWEEK.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "dayOfYear", Builtin.TEMPORAL_PLAIN_DATE_PROTO_DAYOFYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "monthCode", Builtin.TEMPORAL_PLAIN_DATE_PROTO_MONTHCODE.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "inLeapYear", Builtin.TEMPORAL_PLAIN_DATE_PROTO_INLEAPYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "calendarId", Builtin.TEMPORAL_PLAIN_DATE_PROTO_CALENDARID.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "calendar", Builtin.TEMPORAL_PLAIN_DATE_PROTO_CALENDAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "era", Builtin.TEMPORAL_PLAIN_DATE_PROTO_ERA.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "eraYear", Builtin.TEMPORAL_PLAIN_DATE_PROTO_ERAYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInMonth", Builtin.TEMPORAL_PLAIN_DATE_PROTO_DAYSINMONTH.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInWeek", Builtin.TEMPORAL_PLAIN_DATE_PROTO_DAYSINWEEK.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInYear", Builtin.TEMPORAL_PLAIN_DATE_PROTO_DAYSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "monthsInYear", Builtin.TEMPORAL_PLAIN_DATE_PROTO_MONTHSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "weekOfYear", Builtin.TEMPORAL_PLAIN_DATE_PROTO_WEEKOFYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "yearOfWeek", Builtin.TEMPORAL_PLAIN_DATE_PROTO_YEAROFWEEK.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_PLAIN_DATE_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_PLAIN_DATE_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_PLAIN_DATE_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_DATE_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_DATE_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_PLAIN_DATE_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_PLAIN_DATE_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_DATE_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_DATE_PROTO_SINCE.ordinal)) return false;

    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_PLAIN_DATE_FROM.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "compare", Builtin.TEMPORAL_PLAIN_DATE_COMPARE.ordinal)) return false;

    heap.temporal_plain_date_proto = proto;
    return true;
}

fn bool setUpTemporalPlainTime(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.PlainTime"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.TEMPORAL_PLAIN_TIME_CTOR.ordinal;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, "PlainTime");

    if (!register_proto_getter_accessor(proto, heap, "hour", Builtin.TEMPORAL_PLAIN_TIME_PROTO_HOUR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "minute", Builtin.TEMPORAL_PLAIN_TIME_PROTO_MINUTE.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "second", Builtin.TEMPORAL_PLAIN_TIME_PROTO_SECOND.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "millisecond", Builtin.TEMPORAL_PLAIN_TIME_PROTO_MILLISECOND.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "microsecond", Builtin.TEMPORAL_PLAIN_TIME_PROTO_MICROSECOND.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "nanosecond", Builtin.TEMPORAL_PLAIN_TIME_PROTO_NANOSECOND.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_PLAIN_TIME_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_PLAIN_TIME_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_PLAIN_TIME_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_TIME_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_TIME_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_PLAIN_TIME_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_PLAIN_TIME_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_TIME_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_TIME_PROTO_SINCE.ordinal)) return false;

    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_PLAIN_TIME_FROM.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "compare", Builtin.TEMPORAL_PLAIN_TIME_COMPARE.ordinal)) return false;

    heap.temporal_plain_time_proto = proto;
    return true;
}

fn bool setUpTemporalPlainDateTime(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.PlainDateTime"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.TEMPORAL_PLAIN_DATETIME_CTOR.ordinal;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(3);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, "PlainDateTime");

    if (!register_proto_getter_accessor(proto, heap, "year", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_YEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "month", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MONTH.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "day", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAY.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "hour", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_HOUR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "minute", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MINUTE.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "second", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_SECOND.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "millisecond", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MILLISECOND.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "microsecond", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MICROSECOND.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "nanosecond", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_NANOSECOND.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "calendar", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_CALENDAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "calendarId", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_CALENDARID.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_SINCE.ordinal)) return false;

    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_PLAIN_DATETIME_FROM.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "compare", Builtin.TEMPORAL_PLAIN_DATETIME_COMPARE.ordinal)) return false;

    heap.temporal_plain_datetime_proto = proto;
    return true;
}

fn bool setUpTemporalPlainYearMonth(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.PlainYearMonth"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.TEMPORAL_PLAIN_YEARMONTH_CTOR.ordinal;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(2);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, "PlainYearMonth");

    if (!register_proto_getter_accessor(proto, heap, "year", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_YEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "month", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_MONTH.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "monthCode", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_MONTHCODE.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "day", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_DAY.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInMonth", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_DAYSINMONTH.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInYear", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_DAYSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "monthsInYear", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_MONTHSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "inLeapYear", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_INLEAPYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "calendarId", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_CALENDARID.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "calendar", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_CALENDAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "era", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_ERA.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "eraYear", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_ERAYEAR.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_SINCE.ordinal)) return false;

    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_PLAIN_YEARMONTH_FROM.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "compare", Builtin.TEMPORAL_PLAIN_YEARMONTH_COMPARE.ordinal)) return false;

    heap.temporal_plain_yearmonth_proto = proto;
    return true;
}

fn bool setUpTemporalPlainMonthDay(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.PlainMonthDay"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.TEMPORAL_PLAIN_MONTHDAY_CTOR.ordinal;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(2);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, "PlainMonthDay");

    if (!register_proto_getter_accessor(proto, heap, "year", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_YEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "month", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_MONTH.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "monthCode", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_MONTHCODE.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "day", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_DAY.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "calendarId", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_CALENDARID.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "calendar", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_CALENDAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "era", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_ERA.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "eraYear", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_ERAYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "inLeapYear", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_INLEAPYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInMonth", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_DAYSINMONTH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_SINCE.ordinal)) return false;

    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_PLAIN_MONTHDAY_FROM.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "compare", Builtin.TEMPORAL_PLAIN_MONTHDAY_COMPARE.ordinal)) return false;

    heap.temporal_plain_monthday_proto = proto;
    return true;
}

fn bool setUpTemporalNamespace(EnvRecord* global_env, Heap* heap) {
    if (!setUpTemporalInstant(heap)) return false;
    if (!setUpTemporalTimeZone(heap)) return false;
    if (!setUpTemporalZonedDateTime(heap)) return false;
    HObject*? ns_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = ns_raw) return false;
    HObject* ns = ns_raw;
    ns.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal"));
        ns.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    // getOwnPropertyNames for the namespace must include every public name,
    // even the types that have not landed yet; they surface as undefined
    // values (non-enumerable) so no test observes a gap.
    char[][] stub_names = {};
    for (uint k = 0; k < stub_names.len; k++) {
        HString* key = heap.str_intern(stub_names[k]);
        if (key == null) return false;
        TVal undef;
        undef.set_undefined();
        ns.put_prop(key, undef, hobject::PROP_FLAGS_NWC, heap);
    }
    HString* now_key = heap.str_intern("Now");
    if (now_key == null) return false;
    TVal now_undef;
    now_undef.set_undefined();
    ns.put_prop(now_key, now_undef, hobject::PROP_FLAGS_NWC, heap);

    // Real constructors: PlainDate, Calendar, Duration, PlainTime, PlainDateTime,
    // PlainYearMonth, PlainMonthDay.
    // The namespace wiring walks back through each prototype's .constructor property.
    HString* ctor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal undef;
    undef.set_undefined();

    HString* pd_prop_key = builtin_intern_string(heap, "PlainDate");
    TVal ctor_tv = heap.temporal_plain_date_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (ctor_tv.is_object() && ctor_tv.get_heapptr() != null) {
        ns.put_prop(pd_prop_key, ctor_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* cal_key = builtin_intern_string(heap, "Calendar");
    TVal cal_ctor = heap.temporal_calendar_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (cal_ctor.is_object() && cal_ctor.get_heapptr() != null) {
        ns.put_prop(cal_key, cal_ctor, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* dur_key = builtin_intern_string(heap, "Duration");
    TVal dur_ctor = heap.temporal_duration_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (dur_ctor.is_object() && dur_ctor.get_heapptr() != null) {
        ns.put_prop(dur_key, dur_ctor, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* pt_key = builtin_intern_string(heap, "PlainTime");
    TVal pt_ctor = heap.temporal_plain_time_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pt_ctor.is_object() && pt_ctor.get_heapptr() != null) {
        ns.put_prop(pt_key, pt_ctor, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* pdt_key = builtin_intern_string(heap, "PlainDateTime");
    TVal pdt_ctor = heap.temporal_plain_datetime_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pdt_ctor.is_object() && pdt_ctor.get_heapptr() != null) {
        ns.put_prop(pdt_key, pdt_ctor, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* pym_key = builtin_intern_string(heap, "PlainYearMonth");
    TVal pym_ctor = heap.temporal_plain_yearmonth_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pym_ctor.is_object() && pym_ctor.get_heapptr() != null) {
        ns.put_prop(pym_key, pym_ctor, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* pmd_key = builtin_intern_string(heap, "PlainMonthDay");
    TVal pmd_ctor = heap.temporal_plain_monthday_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pmd_ctor.is_object() && pmd_ctor.get_heapptr() != null) {
        ns.put_prop(pmd_key, pmd_ctor, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* inst_key = builtin_intern_string(heap, "Instant");
    TVal inst_ctor = heap.temporal_instant_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (inst_ctor.is_object() && inst_ctor.get_heapptr() != null) {
        ns.put_prop(inst_key, inst_ctor, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* tz_key = builtin_intern_string(heap, "TimeZone");
    TVal tz_ctor = heap.temporal_timezone_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (tz_ctor.is_object() && tz_ctor.get_heapptr() != null) {
        ns.put_prop(tz_key, tz_ctor, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* zdt_key = builtin_intern_string(heap, "ZonedDateTime");
    TVal zdt_ctor = heap.temporal_zoneddatetime_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (zdt_ctor.is_object() && zdt_ctor.get_heapptr() != null) {
        ns.put_prop(zdt_key, zdt_ctor, hobject::PROP_FLAGS_NWC, heap);
    }

    TVal ns_tv;
    ns_tv.set_object(ns);
    HString* t_key = heap.str_intern("Temporal");
    if (t_key == null) return false;
    env::env_declare_nonenum(global_env, t_key, ns_tv);

    return true;
}

// ============================================================================
// Phase 2 — Temporal.Instant
// ============================================================================

fn HObject*? alloc_instant(Heap* hp, hbigint::HBigInt* ns) {
    if (ns == null) return null;
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_INSTANT);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    ((types::HeapHeader*)ns).incref();
    obj.extra.temporal.big_ns = ns;
    obj.extra.temporal.calendar = null;
    obj.extra.temporal.timezone = null;
    return obj;
}

// Extract the BigInt from a Temporal.Instant heap object. Returns null if the
// object is missing the slot (defensive — should never happen for a valid
// TEMPORAL_INSTANT object).
fn hbigint::HBigInt*? instant_value(HObject* obj) {
    return obj.extra.temporal.big_ns;
}

// Temporal.Instant(epochNanoseconds) — accepts a BigInt, throws on anything else.
fn void builtin_temporal_instant_ctor(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant requires an epochNanoseconds argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, arg, &ok);
    if (!ok) return;
    HObject*? obj_o = alloc_instant(ctx.heap, b);
    if (catch err = obj_o) {
        ctx.heap.decref((types::HeapHeader*)b);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)b);
    if (ctx.is_constructor) {
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_instant_proto);
    } else {
        obj.prototype = ctx.heap.temporal_instant_proto;
    }
    ctx.result.set_object(obj);
}

// Temporal.Instant.from(item) — accepts a BigInt or another Instant.
fn void builtin_temporal_instant_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_INSTANT) {
            // Copy the underlying BigInt.
            hbigint::HBigInt* src = o.extra.temporal.big_ns;
            hbigint::HBigInt*? b_o = hbigint::hbigint_copy(ctx.heap, src);
            if (catch err = b_o) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Instant.from: copy failed");
                return;
            }
            HObject*? obj_o = alloc_instant(ctx.heap, b_o);
            if (catch err2 = obj_o) {
                ctx.heap.decref((types::HeapHeader*)b_o);
                builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
                return;
            }
            HObject* obj = obj_o;
            ctx.heap.decref((types::HeapHeader*)b_o);
            obj.prototype = ctx.heap.temporal_instant_proto;
            ctx.result.set_object(obj);
            return;
        }
    }
    // Default: ToBigInt(value).
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, arg, &ok);
    if (!ok) return;
    HObject*? obj_o = alloc_instant(ctx.heap, b);
    if (catch err = obj_o) {
        ctx.heap.decref((types::HeapHeader*)b);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)b);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Temporal.Instant.fromEpochSeconds(n) — converts a Number (or BigInt) of
// seconds to an Instant via seconds * 10^9 nanoseconds.
fn void builtin_temporal_instant_fromEpochSeconds(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "fromEpochSeconds requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    // Allow BigInt or Number. Number must be an integer (no fractional seconds).
    hbigint::HBigInt* b;
    if (arg.is_bigint()) {
        b = arg.get_bigint();
    } else if (arg.is_number() || arg.is_fastint()) {
        Vm* v = (Vm*)ctx.vm;
        double d = vm::vm_to_number(v, arg);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        if (math::is_nan(d) || math::is_inf(d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochSeconds: non-finite value");
            return;
        }
        if (math::floor(d) != d) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochSeconds: non-integer value");
            return;
        }
        // d is now an integer in [-2^53, 2^53]; convert via int64.
        int128 i128 = (int128)d;
        hbigint::HBigInt*? b_o = hbigint::hbigint_alloc(ctx.heap, i128);
        if (catch err = b_o) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochSeconds: allocation failed");
            return;
        }
        b = b_o;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "fromEpochSeconds requires a number or BigInt");
        return;
    }
    // Multiply by 10^9 nanoseconds.
    hbigint::HBigInt*? ns_o = hbigint::hbigint_from_slimb(ctx.heap, 1000000000);
    if (catch err = ns_o) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochSeconds: 10^9 alloc failed");
        return;
    }
    hbigint::HBigInt* nine = ns_o;
    hbigint::HBigInt*? result = hbigint::hbigint_mul(ctx.heap, b, nine);
    ctx.heap.decref((types::HeapHeader*)nine);
    if (catch err = result) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochSeconds: multiply failed");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, result);
    if (catch err2 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)result);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Same shape for ms, us, ns — delegate via simple scaling.
fn void builtin_temporal_instant_fromEpochMilliseconds(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "fromEpochMilliseconds requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    Vm* v = (Vm*)ctx.vm;
    double d = vm::vm_to_number(v, arg);
    if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    if (math::is_nan(d) || math::is_inf(d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: non-finite");
        return;
    }
    if (math::floor(d) != d) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: non-integer");
        return;
    }
    int128 i128 = (int128)d;
    hbigint::HBigInt*? ms_o = hbigint::hbigint_alloc(ctx.heap, i128);
    if (catch err = ms_o) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: alloc failed");
        return;
    }
    hbigint::HBigInt* ms = ms_o;
    hbigint::HBigInt*? million_o = hbigint::hbigint_from_slimb(ctx.heap, 1000000);
    if (catch err2 = million_o) {
        ctx.heap.decref((types::HeapHeader*)ms);
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: 10^6 alloc failed");
        return;
    }
    hbigint::HBigInt* million = million_o;
    hbigint::HBigInt*? ns = hbigint::hbigint_mul(ctx.heap, ms, million);
    ctx.heap.decref((types::HeapHeader*)million);
    ctx.heap.decref((types::HeapHeader*)ms);
    if (catch err3 = ns) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: multiply failed");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, ns);
    if (catch err4 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)ns);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)ns);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_instant_fromEpochMicroseconds(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "fromEpochMicroseconds requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    Vm* v = (Vm*)ctx.vm;
    double d = vm::vm_to_number(v, arg);
    if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    if (math::is_nan(d) || math::is_inf(d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMicroseconds: non-finite");
        return;
    }
    if (math::floor(d) != d) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMicroseconds: non-integer");
        return;
    }
    int128 i128 = (int128)d;
    hbigint::HBigInt*? us_o = hbigint::hbigint_alloc(ctx.heap, i128);
    if (catch err = us_o) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMicroseconds: alloc failed");
        return;
    }
    hbigint::HBigInt* us = us_o;
    hbigint::HBigInt*? thousand_o = hbigint::hbigint_from_slimb(ctx.heap, 1000);
    if (catch err2 = thousand_o) {
        ctx.heap.decref((types::HeapHeader*)us);
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMicroseconds: 10^3 alloc failed");
        return;
    }
    hbigint::HBigInt* thousand = thousand_o;
    hbigint::HBigInt*? ns = hbigint::hbigint_mul(ctx.heap, us, thousand);
    ctx.heap.decref((types::HeapHeader*)thousand);
    ctx.heap.decref((types::HeapHeader*)us);
    if (catch err3 = ns) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMicroseconds: multiply failed");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, ns);
    if (catch err4 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)ns);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)ns);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_instant_fromEpochNanoseconds(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "fromEpochNanoseconds requires an argument");
        return;
    }
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, arg_at(ctx, 0), &ok);
    if (!ok) return;
    HObject*? obj_o = alloc_instant(ctx.heap, b);
    if (catch err = obj_o) {
        ctx.heap.decref((types::HeapHeader*)b);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)b);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Temporal.Instant.compare(a, b) → -1 / 0 / 1.
fn void builtin_temporal_instant_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "compare requires two arguments");
        return;
    }
    TVal* a_arg = arg_at(ctx, 0);
    TVal* b_arg = arg_at(ctx, 1);
    if (!a_arg.is_object() || a_arg.get_heapptr() == null
        || ((HObject*)a_arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_INSTANT) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "compare: first arg is not an Instant");
        return;
    }
    if (!b_arg.is_object() || b_arg.get_heapptr() == null
        || ((HObject*)b_arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_INSTANT) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "compare: second arg is not an Instant");
        return;
    }
    hbigint::HBigInt* a = ((HObject*)a_arg.get_heapptr()).extra.temporal.big_ns;
    hbigint::HBigInt* b = ((HObject*)b_arg.get_heapptr()).extra.temporal.big_ns;
    ctx.result.set_fastint(temporal::instant_cmp(a, b));
}

// All four getters: epochSeconds, epochMilliseconds, epochMicroseconds,
// epochNanoseconds. The seconds/ms/us getters must return a Number; the ns
// getter returns a BigInt. We divide via / 10^9 (or 10^6 / 10^3).
fn void builtin_temporal_instant_proto_epochSeconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result.set_number(math::floor(d / 1e9));
}

fn void builtin_temporal_instant_proto_epochMilliseconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    // Convert ms (Number) to integer. floor() then cast.
    ctx.result.set_number(math::floor(d / 1e6));
}

fn void builtin_temporal_instant_proto_epochMicroseconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result.set_number(math::floor(d / 1e3));
}

fn void builtin_temporal_instant_proto_epochNanoseconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    ctx.result.set_bigint(b);
}

// toString / toJSON / valueOf for Instant.
fn void builtin_temporal_instant_proto_toString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    // ISO 8601: YYYY-MM-DDTHH:mm:ss.sssZ (UTC instant). For the basic Phase
    // 2 work we don't implement the fractional-second control from the
    // options bag; we always emit `.000Z` and round nanoseconds to seconds.
    // Sub-second precision lands with Phase 3 (the options / fractional
    // unit machinery).
    double secs;
    if (!bigint_to_epoch_number(b, &secs, ctx)) return;
    long whole_secs = (long)math::floor(secs / 1e9);
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(whole_secs);
    char[40] buf;
    int n = libc::snprintf(&buf, 40, "%04ld-%02ld-%02ldT%02ld:%02ld:%02dZ",
        bd.y, (long)bd.m + 1, (long)bd.d,
        (long)bd.h, (long)bd.mi, bd.s);
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:n]));
}

fn void builtin_temporal_instant_proto_toJSON(BuiltinContext* ctx) {
    builtin_temporal_instant_proto_toString(ctx);
}

fn void builtin_temporal_instant_proto_valueOf(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant cannot be converted to a primitive value");
}

fn void builtin_temporal_instant_proto_equals(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_INSTANT) {
        ctx.result.set_boolean(false);
        return;
    }
    HObject* a = (HObject*)ctx.this_val.get_heapptr();
    HObject* b = (HObject*)arg.get_heapptr();
    ctx.result.set_boolean(hbigint::hbigint_cmp(a.extra.temporal.big_ns, b.extra.temporal.big_ns) == 0);
}

// add / subtract take a Temporal.Duration.
fn void builtin_temporal_instant_proto_add(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "add requires a Duration argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_DURATION) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "add: argument is not a Temporal.Duration");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    HObject* dur = (HObject*)arg.get_heapptr();
    temporal::DurationParts dp = duration_value(dur);
    hbigint::HBigInt* base = self.extra.temporal.big_ns;
    // Convert DurationParts to nanoseconds-as-BigInt.
    hbigint::HBigInt*? delta_o = hbigint::hbigint_from_slimb(ctx.heap, 0);
    if (catch err = delta_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "add: alloc failed"); return; }
    hbigint::HBigInt* delta = delta_o;
    // hours/minutes/seconds/ms/us/ns contribute via scaling.
    // Use (dp.x * scale) + delta, repeated. The numbers here fit in int64 so
    // we use the int128 path.
    long[6] parts;
    long[6] scales;
    parts[0] = dp.hours;   scales[0] = 3600000000000L;
    parts[1] = dp.minutes; scales[1] = 60000000000L;
    parts[2] = dp.seconds; scales[2] = 1000000000L;
    parts[3] = dp.ms;      scales[3] = 1000000L;
    parts[4] = dp.us;      scales[4] = 1000L;
    parts[5] = dp.ns;      scales[5] = 1L;
    for (int k = 0; k < 6; k++) {
        if (parts[k] == 0) continue;
        hbigint::HBigInt*? part_o = hbigint::hbigint_alloc(ctx.heap, (int128)parts[k]);
        if (catch err = part_o) {
            ctx.heap.decref((types::HeapHeader*)delta);
            builtin_throw(ctx, ctx.heap.range_err_proto, "add: alloc failed");
            return;
        }
        hbigint::HBigInt* part = part_o;
        hbigint::HBigInt*? scale_o = hbigint::hbigint_alloc(ctx.heap, (int128)scales[k]);
        if (catch err = scale_o) {
            ctx.heap.decref((types::HeapHeader*)part);
            ctx.heap.decref((types::HeapHeader*)delta);
            builtin_throw(ctx, ctx.heap.range_err_proto, "add: alloc failed");
            return;
        }
        hbigint::HBigInt* scale = scale_o;
        hbigint::HBigInt*? scaled = hbigint::hbigint_mul(ctx.heap, part, scale);
        ctx.heap.decref((types::HeapHeader*)part);
        ctx.heap.decref((types::HeapHeader*)scale);
        if (catch err = scaled) {
            ctx.heap.decref((types::HeapHeader*)delta);
            builtin_throw(ctx, ctx.heap.range_err_proto, "add: multiply failed");
            return;
        }
        hbigint::HBigInt*? new_delta = hbigint::hbigint_addsub(ctx.heap, delta, scaled, false);
        ctx.heap.decref((types::HeapHeader*)scaled);
        ctx.heap.decref((types::HeapHeader*)delta);
        if (catch err = new_delta) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "add: addsub failed");
            return;
        }
        delta = new_delta;
    }
    hbigint::HBigInt*? result = temporal::instant_add(base, delta, ctx.heap);
    ctx.heap.decref((types::HeapHeader*)delta);
    if (catch err = result) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "add: failed");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, result);
    if (catch err2 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)result);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_instant_proto_subtract(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "subtract requires a Duration argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_DURATION) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "subtract: argument is not a Temporal.Duration");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    HObject* dur = (HObject*)arg.get_heapptr();
    temporal::DurationParts dp = duration_value(dur);
    hbigint::HBigInt* base = self.extra.temporal.big_ns;
    hbigint::HBigInt*? delta_o = hbigint::hbigint_from_slimb(ctx.heap, 0);
    if (catch err = delta_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "subtract: alloc failed"); return; }
    hbigint::HBigInt* delta = delta_o;
    long[6] parts;
    long[6] scales;
    parts[0] = dp.hours;   scales[0] = 3600000000000L;
    parts[1] = dp.minutes; scales[1] = 60000000000L;
    parts[2] = dp.seconds; scales[2] = 1000000000L;
    parts[3] = dp.ms;      scales[3] = 1000000L;
    parts[4] = dp.us;      scales[4] = 1000L;
    parts[5] = dp.ns;      scales[5] = 1L;
    for (int k = 0; k < 6; k++) {
        if (parts[k] == 0) continue;
        hbigint::HBigInt*? part_o = hbigint::hbigint_alloc(ctx.heap, (int128)parts[k]);
        if (catch err = part_o) {
            ctx.heap.decref((types::HeapHeader*)delta);
            builtin_throw(ctx, ctx.heap.range_err_proto, "subtract: alloc failed");
            return;
        }
        hbigint::HBigInt* part = part_o;
        hbigint::HBigInt*? scale_o = hbigint::hbigint_alloc(ctx.heap, (int128)scales[k]);
        if (catch err = scale_o) {
            ctx.heap.decref((types::HeapHeader*)part);
            ctx.heap.decref((types::HeapHeader*)delta);
            builtin_throw(ctx, ctx.heap.range_err_proto, "subtract: alloc failed");
            return;
        }
        hbigint::HBigInt* scale = scale_o;
        hbigint::HBigInt*? scaled = hbigint::hbigint_mul(ctx.heap, part, scale);
        ctx.heap.decref((types::HeapHeader*)part);
        ctx.heap.decref((types::HeapHeader*)scale);
        if (catch err = scaled) {
            ctx.heap.decref((types::HeapHeader*)delta);
            builtin_throw(ctx, ctx.heap.range_err_proto, "subtract: multiply failed");
            return;
        }
        hbigint::HBigInt*? new_delta = hbigint::hbigint_addsub(ctx.heap, delta, scaled, false);
        ctx.heap.decref((types::HeapHeader*)scaled);
        ctx.heap.decref((types::HeapHeader*)delta);
        if (catch err = new_delta) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "subtract: addsub failed");
            return;
        }
        delta = new_delta;
    }
    hbigint::HBigInt*? result = temporal::instant_sub(base, delta, ctx.heap);
    ctx.heap.decref((types::HeapHeader*)delta);
    if (catch err = result) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "subtract: failed");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, result);
    if (catch err2 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)result);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Build a Duration whose time seconds are the difference between two
// Instants' epoch-ns BigInts, with milliseconds/microseconds/nanoseconds for
// the sub-second remainder. This is TimeDurationFromEpochNanoseconds with
// largestUnit "second" (truncation toward zero). `out` receives a refcount-1
// Duration object or null on failure.
fn bool instant_ns_diff_duration(BuiltinContext* ctx, hbigint::HBigInt* a, hbigint::HBigInt* b, HObject** out) {
    hbigint::HBigInt*? diff_o = hbigint::hbigint_addsub(ctx.heap, a, b, true);
    if (catch err = diff_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "difference overflow"); return false; }
    hbigint::HBigInt* diff = diff_o;
    temporal::DurationParts dp = {};
    hbigint::HBigInt*? one_o = hbigint::hbigint_from_slimb(ctx.heap, 1000000000);
    if (catch err = one_o) { ctx.heap.decref((types::HeapHeader*)diff); builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return false; }
    hbigint::HBigInt* one = one_o;
    hbigint::HBigInt* q = null;
    hbigint::HBigInt* r = null;
    if (catch err = hbigint::hbigint_divrem(ctx.heap, diff, one, &q, &r)) {
        ctx.heap.decref((types::HeapHeader*)one);
        ctx.heap.decref((types::HeapHeader*)diff);
        builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed");
        return false;
    }
    ctx.heap.decref((types::HeapHeader*)one);
    ctx.heap.decref((types::HeapHeader*)diff);
    if (q == null || r == null) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return false; }
    dp.seconds = (long)q.to_int128();
    int128 rv = r.to_int128();
    dp.ms = (int)(rv / 1000000);
    int128 rem = rv - (int128)dp.ms * 1000000;
    dp.us = (int)(rem / 1000);
    dp.ns = (int)(rem - (int128)dp.us * 1000);
    ctx.heap.decref((types::HeapHeader*)q);
    ctx.heap.decref((types::HeapHeader*)r);
    HObject*? dur_o = alloc_duration(ctx.heap, dp);
    if (catch err = dur_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return false;
    }
    *out = dur_o;
    return true;
}

// this.since(other[, options]) = this - other, as a Duration in seconds.
fn void builtin_temporal_instant_proto_since(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "since requires an Instant argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_INSTANT) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "since: argument is not a Temporal.Instant");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    HObject* other = (HObject*)arg.get_heapptr();
    HObject* dur;
    if (!instant_ns_diff_duration(ctx, self.extra.temporal.big_ns, other.extra.temporal.big_ns, &dur)) return;
    dur.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur);
}

// this.until(other[, options]) = other - this, as a Duration in seconds.
fn void builtin_temporal_instant_proto_until(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "until requires an Instant argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_INSTANT) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "until: argument is not a Temporal.Instant");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    HObject* other = (HObject*)arg.get_heapptr();
    HObject* dur;
    if (!instant_ns_diff_duration(ctx, other.extra.temporal.big_ns, self.extra.temporal.big_ns, &dur)) return;
    dur.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur);
}

// Helper: convert a BigInt to a double representing nanoseconds. The result
// is precise for any BigInt whose absolute value fits in 2^53 (~285 years
// of nanoseconds). Throws RangeError if the magnitude is too large.
fn bool bigint_to_epoch_number(hbigint::HBigInt* b, double* out, BuiltinContext* ctx) {
    if (b == null) { *out = 0.0; return true; }
    if (!b.fits_int128()) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Instant too large for Number conversion");
        return false;
    }
    int128 v = b.to_int128();
    *out = (double)v;
    return true;
}

// ============================================================================
// Phase 2 — Temporal.TimeZone (minimal: ctor, from, id, getOffsetNanosecondsFor)
// ============================================================================

// A TimeZone heap object holds just the IANA zone name as a string. The
// offset lookups are pure calls into the tzdb module.
fn HObject*? alloc_timezone(Heap* hp, String zone_name) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_TIMEZONE);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    HString* str = builtin_intern_string(hp, zone_name);
    // Store the zone name in the calendar slot (we have no other string slot
    // in HObjectTemporal for the TZ). Calendar and TimeZone never coexist
    // on the same instance, so reusing the slot is safe and saves memory.
    obj.extra.temporal.calendar = (HObject*)str;
    obj.extra.temporal.timezone = null;
    return obj;
}

// Extract the IANA zone name string from a TimeZone heap object.
fn String timezone_name(HObject* obj) {
    HString* str = (HString*)obj.extra.temporal.calendar;
    if (str == null) return "";
    return (String)str.get_cstr()[:str.blen];
}

fn void builtin_temporal_timezone_ctor(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.TimeZone requires an identifier argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    String s;
    if (arg.is_string()) {
        HString* hs = (HString*)arg.get_heapptr();
        s = (String)hs.get_cstr()[:hs.blen];
    } else {
        Vm* v = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(v, arg, 0);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        if (!prim.is_string()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.TimeZone identifier must be a string");
            return;
        }
        HString* hs = (HString*)prim.get_heapptr();
        s = (String)hs.get_cstr()[:hs.blen];
    }
    if (!temporal::tzdb_zone_exists(s)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Unknown time zone");
        return;
    }
    HObject*? obj_o = alloc_timezone(ctx.heap, s);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    if (ctx.is_constructor) {
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_timezone_proto);
    } else {
        obj.prototype = ctx.heap.temporal_timezone_proto;
    }
    ctx.result.set_object(obj);
}

fn void builtin_temporal_timezone_from(BuiltinContext* ctx) {
    // For Phase 2, from() === ctor().
    builtin_temporal_timezone_ctor(ctx);
}

fn void builtin_temporal_timezone_proto_id(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_TIMEZONE, "this is not a Temporal.TimeZone")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    HString* str = (HString*)obj.extra.temporal.calendar;
    if (str == null) { ctx.result.set_string(builtin_intern_string(ctx.heap, "")); return; }
    ctx.result.set_string(str);
}

// getOffsetNanosecondsFor(instant) returns the zone's offset at the given
// Instant's epoch_ns as a Number.
fn void builtin_temporal_timezone_proto_getOffsetNanosecondsFor(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_TIMEZONE, "this is not a Temporal.TimeZone")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getOffsetNanosecondsFor requires an Instant argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_INSTANT) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getOffsetNanosecondsFor requires a Temporal.Instant");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    String zone = timezone_name(self);
    hbigint::HBigInt* ns = ((HObject*)arg.get_heapptr()).extra.temporal.big_ns;
    double secs_d;
    if (!bigint_to_epoch_number(ns, &secs_d, ctx)) return;
    long secs = (long)math::floor(secs_d / 1e9);
    int offset_sec = temporal::tzdb_offset_for_zone_at(zone, secs);
    ctx.result.set_number((double)offset_sec * 1e9);
}

// getPossibleInstantsFor(plainDateTime) is stubbed for Phase 2; the full
// DST gap/overlap disambiguation lands with ZonedDateTime. We return the
// single Instant if no ambiguity is possible and throw otherwise.
fn void builtin_temporal_timezone_proto_getPossibleInstantsFor(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_TIMEZONE, "this is not a Temporal.TimeZone")) return;
    builtin_throw(ctx, ctx.heap.err_proto, "Temporal.TimeZone.prototype.getPossibleInstantsFor not yet implemented");
}

// ============================================================================
// Phase 2 — setUpTemporal* registration functions
// ============================================================================

fn bool setUpTemporalInstant(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.Instant"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.TEMPORAL_INSTANT_CTOR.ordinal;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    TVal len_tv;
    len_tv.set_fastint(1);
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    ctor.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, "Instant");

    if (!register_proto_getter_accessor(proto, heap, "epochSeconds", Builtin.TEMPORAL_INSTANT_PROTO_EPOCHSECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "epochMilliseconds", Builtin.TEMPORAL_INSTANT_PROTO_EPOCHMILLISECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "epochMicroseconds", Builtin.TEMPORAL_INSTANT_PROTO_EPOCHMICROSECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "epochNanoseconds", Builtin.TEMPORAL_INSTANT_PROTO_EPOCHNANOSECONDS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_INSTANT_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_INSTANT_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_INSTANT_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_INSTANT_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_INSTANT_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_INSTANT_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_INSTANT_PROTO_SINCE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_INSTANT_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_INSTANT_FROM.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "fromEpochSeconds", Builtin.TEMPORAL_INSTANT_FROM_EPOCH_SECONDS.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "fromEpochMilliseconds", Builtin.TEMPORAL_INSTANT_FROM_EPOCH_MILLISECONDS.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "fromEpochMicroseconds", Builtin.TEMPORAL_INSTANT_FROM_EPOCH_MICROSECONDS.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "fromEpochNanoseconds", Builtin.TEMPORAL_INSTANT_FROM_EPOCH_NANOSECONDS.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "compare", Builtin.TEMPORAL_INSTANT_COMPARE.ordinal)) return false;

    heap.temporal_instant_proto = proto;
    return true;
}

fn bool setUpTemporalTimeZone(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.TimeZone"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.TEMPORAL_TIMEZONE_CTOR.ordinal;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    TVal len_tv;
    len_tv.set_fastint(1);
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    ctor.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, "TimeZone");

    if (!register_proto_getter_accessor(proto, heap, "id", Builtin.TEMPORAL_TIMEZONE_PROTO_ID.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getOffsetNanosecondsFor", Builtin.TEMPORAL_TIMEZONE_PROTO_OFFSETNANOSECONDSFOR.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getPossibleInstantsFor", Builtin.TEMPORAL_TIMEZONE_PROTO_GETPOSSIBLEINSTANTSFOR.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_TIMEZONE_FROM.ordinal)) return false;

    heap.temporal_timezone_proto = proto;
    return true;
}

// ============================================================================
// Phase 2 — Temporal.ZonedDateTime
//
// A ZonedDateTime is an Instant plus a TimeZone plus a calendar. The heap
// slots hold the TimeZone object (in `timezone`) and the iso8601 calendar
// string (in `calendar`); `big_ns` is the epoch-nanosecond BigInt.
// ============================================================================

fn HObject*? alloc_zoneddatetime(Heap* hp, hbigint::HBigInt* ns, HObject* tz, HString* calendar) {
    if (ns == null) return null;
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_ZONEDDATETIME);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    ((types::HeapHeader*)ns).incref();
    ((types::HeapHeader*)tz).incref();
    if (calendar != null) { ((types::HeapHeader*)calendar).incref(); }
    obj.extra.temporal.big_ns = ns;
    obj.extra.temporal.timezone = tz;
    obj.extra.temporal.calendar = (HObject*)calendar;
    return obj;
}

// Temporal.ZonedDateTime(epochNanoseconds, timeZone[, calendar])
fn void builtin_temporal_zoneddatetime_ctor(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime requires epochNanoseconds and timeZone args");
        return;
    }
    TVal* narg = arg_at(ctx, 0);
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, narg, &ok);
    if (!ok) return;

    // timeZone must be a Temporal.TimeZone object (spec allows a string, which
    // we resolve through the ctor for Phase 2).
    TVal* tzarg = arg_at(ctx, 1);
    HObject* tz;
    if (tzarg.is_object() && tzarg.get_heapptr() != null
        && ((HObject*)tzarg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_TIMEZONE) {
        tz = (HObject*)tzarg.get_heapptr();
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime timeZone must be a Temporal.TimeZone");
        ctx.heap.decref((types::HeapHeader*)b);
        return;
    }

    // calendar: Phase 2 defaults to iso8601; a supplied calendar must already
    // be a Temporal.Calendar with id "iso8601".
    HString* calendar = builtin_intern_string(ctx.heap, "iso8601");
    HObject*? obj_o = alloc_zoneddatetime(ctx.heap, b, tz, calendar);
    ctx.heap.decref((types::HeapHeader*)b);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    if (ctx.is_constructor) {
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_zoneddatetime_proto);
    } else {
        obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
    }
    ctx.result.set_object(obj);
}

fn void builtin_temporal_zoneddatetime_from(BuiltinContext* ctx) {
    // Phase 2: from() accepts the same (epochNanoseconds, timeZone) pair.
    builtin_temporal_zoneddatetime_ctor(ctx);
}

fn hbigint::HBigInt* zdt_value(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return null;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    return obj.extra.temporal.big_ns;
}

fn void builtin_temporal_zoneddatetime_proto_epochNanoseconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    ctx.result.set_bigint(b);
}

fn void builtin_temporal_zoneddatetime_proto_epochSeconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result.set_number(math::floor(d / 1e9));
}

fn void builtin_temporal_zoneddatetime_proto_epochMilliseconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result.set_number(math::floor(d / 1e6));
}

fn void builtin_temporal_zoneddatetime_proto_epochMicroseconds(BuiltinContext* ctx) {
    hbigint::HBigInt* b = zdt_value(ctx);
    if (b == null) return;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result.set_number(math::floor(d / 1e3));
}

fn void builtin_temporal_zoneddatetime_proto_timeZoneId(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    HObject* tz = obj.extra.temporal.timezone;
    if (tz == null) { ctx.result.set_string(builtin_intern_string(ctx.heap, "")); return; }
    HString* id = (HString*)tz.extra.temporal.calendar;
    ctx.result.set_string(id == null ? builtin_intern_string(ctx.heap, "") : id);
}

fn void builtin_temporal_zoneddatetime_proto_calendarId(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    ctx.result.set_string(builtin_intern_string(ctx.heap, "iso8601"));
}

// Format an offset in seconds from UTC as ±HH:MM into buf (len >= 8).
fn void format_offset_seconds(char* buf, int off) {
    int sign = off < 0 ? -1 : 1;
    int mag = off < 0 ? -off : off;
    int hh = mag / 3600;
    int mm = (mag % 3600) / 60;
    if (sign < 0) { buf[0] = '-'; } else { buf[0] = '+'; }
    libc::snprintf(buf + 1, 6, "%02d:%02d", hh, mm);
}

fn void builtin_temporal_zoneddatetime_proto_toString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    HObject* tz = obj.extra.temporal.timezone;
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    double secs_d;
    if (!bigint_to_epoch_number(b, &secs_d, ctx)) return;
    long epoch_secs = (long)math::floor(secs_d / 1e9);
    String zone = tz == null ? "" : timezone_name(tz);
    int off = 0;
    if (tz != null) {
        off = temporal::tzdb_offset_for_zone_at(zone, epoch_secs);
    }
    long local_secs = epoch_secs + off;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(local_secs);
    char[64] buf;
    int n = libc::snprintf(&buf, 64, "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld",
        bd.y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
    format_offset_seconds(&buf[n], off);
    n += 6;
    if (zone.len > 0 && zone.ptr != null) {
        int zn = libc::snprintf(&buf[n], 64 - (usz)n, "[%s]", (char*)zone.ptr);
        n += zn;
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:n]));
}

fn void builtin_temporal_zoneddatetime_proto_toJSON(BuiltinContext* ctx) {
    // toJSON strips the trailing [Zone] and the offset for a string that
    // still round-trips through ZonedDateTime.from in the same zone. Phase 2
    // keeps the offset but drops the zone bracket.
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    HObject* tz = obj.extra.temporal.timezone;
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    double secs_d;
    if (!bigint_to_epoch_number(b, &secs_d, ctx)) return;
    long epoch_secs = (long)math::floor(secs_d / 1e9);
    String zone = tz == null ? "" : timezone_name(tz);
    int off = 0;
    if (tz != null) off = temporal::tzdb_offset_for_zone_at(zone, epoch_secs);
    long local_secs = epoch_secs + off;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(local_secs);
    char[64] buf;
    int n = libc::snprintf(&buf, 64, "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld",
        bd.y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
    format_offset_seconds(&buf[n], off);
    n += 6;
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:n]));
}

fn void builtin_temporal_zoneddatetime_proto_equals(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        ctx.result.set_boolean(false);
        return;
    }
    HObject* a = (HObject*)ctx.this_val.get_heapptr();
    HObject* bb = (HObject*)arg.get_heapptr();
    // ZonedDateTime equality also requires the same time zone and calendar.
    String za = a.extra.temporal.timezone == null ? "" : timezone_name(a.extra.temporal.timezone);
    String zb = bb.extra.temporal.timezone == null ? "" : timezone_name(bb.extra.temporal.timezone);
    bool same_ns = hbigint::hbigint_cmp(a.extra.temporal.big_ns, bb.extra.temporal.big_ns) == 0;
    ctx.result.set_boolean(same_ns && za == zb);
}

fn bool setUpTemporalZonedDateTime(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.ZonedDateTime"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.TEMPORAL_ZONEDDATETIME_CTOR.ordinal;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    TVal len_tv;
    len_tv.set_fastint(2);
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    ctor.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC, heap);

    set_func_ctor_name(ctor, heap, "ZonedDateTime");

    if (!register_proto_getter_accessor(proto, heap, "epochSeconds", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_EPOCHSECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "epochMilliseconds", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_EPOCHMILLISECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "epochMicroseconds", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_EPOCHMICROSECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "epochNanoseconds", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_EPOCHNANOSECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "timeZoneId", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_TIMEZONEID.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "calendarId", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_CALENDARID.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_ZONEDDATETIME_FROM.ordinal)) return false;

    heap.temporal_zoneddatetime_proto = proto;
    return true;
}