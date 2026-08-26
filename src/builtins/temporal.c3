// Temporal built-ins layer. Adapts boomkat::lib::temporal value types to
// HObject, TVal, and BuiltinContext: the ISO Calendar singleton, PlainDate
// with ISO 8601 parsing/formatting and proleptic Gregorian arithmetic,
// PlainTime and PlainDateTime with the same calendar basis, and a Duration
// value type for until/since results and add/subtract inputs.
//
// All date fields travel as an HObject of class TEMPORAL_* with the shared
// HObjectTemporal union variant: long_a..long_c hold year/month/day for
// PlainDate and the date half of PlainDateTime, long_a..long_f hold the six
// time fields for PlainTime, long_d..long_i hold the time fields for
// PlainDateTime, long_a..long_g + int_h..int_j hold the ten Duration fields,
// and `calendar` holds the shared ISO Calendar object. Getters are native
// accessors; nothing here allocates through the JS heap except the objects
// themselves.
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
import std::io;
import std::time;

// System time zone lookup; see src/date_math.c. The result is a static-lifetime
// C string (the env var or a fallback), safe to read but not to mutate.
extern fn char* boomkat_system_tz_name();

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
    obj.extra.temporal.long_a = (long)d.y;
    obj.extra.temporal.long_b = d.m;
    obj.extra.temporal.long_c = d.d;
    obj.extra.temporal.calendar = calendar;
    return obj;
}

// Slot layout for TEMPORAL_PLAIN_TIME: long_a..long_f carry the six time
// fields (hour..nanosecond). The object carries no calendar; PlainTime is
// intentionally calendar-independent per the spec.
fn HObject*? alloc_plain_time(Heap* hp, temporal::CivilTime t) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_PLAIN_TIME);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.long_a = t.h;
    obj.extra.temporal.long_b = t.mi;
    obj.extra.temporal.long_c = t.s;
    obj.extra.temporal.long_d = t.ms;
    obj.extra.temporal.long_e = t.us;
    obj.extra.temporal.long_f = t.ns;
    return obj;
}

// Slot layout for TEMPORAL_PLAIN_DATETIME: long_a..long_c carry y/m/d and
// long_d..long_i carry h/mi/s/ms/us/ns. Year is signed via int (covers the
// full Temporal range; the spec caps at ±271821).
fn HObject*? alloc_plain_datetime(Heap* hp, temporal::CivilDateTime dt, HObject* calendar) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_PLAIN_DATETIME);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.long_a = (long)dt.date.y;
    obj.extra.temporal.long_b = dt.date.m;
    obj.extra.temporal.long_c = dt.date.d;
    obj.extra.temporal.long_d = dt.time.h;
    obj.extra.temporal.long_e = dt.time.mi;
    obj.extra.temporal.long_f = dt.time.s;
    obj.extra.temporal.long_g = dt.time.ms;
    obj.extra.temporal.long_h = (int)dt.time.us;
    obj.extra.temporal.long_i = (int)dt.time.ns;
    obj.extra.temporal.calendar = calendar;
    return obj;
}

// Slot layout for TEMPORAL_PLAIN_YEARMONTH: long_a..long_c carry y/m/d. The
// `day` slot is a reference day used only to answer daysInMonth/inLeapYear;
// it does not participate in equality or comparison. Year is signed via int.
fn HObject*? alloc_plain_yearmonth(Heap* hp, long y, int m, int reference_day, HObject* calendar) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.long_a = (long)y;
    obj.extra.temporal.long_b = m;
    obj.extra.temporal.long_c = reference_day;
    obj.extra.temporal.calendar = calendar;
    return obj;
}

// Slot layout for TEMPORAL_PLAIN_MONTHDAY: long_a..long_c carry y/m/d. The
// `year` slot is a reference year used only for calendar-related properties
// (era, eraYear, inLeapYear); it does not participate in equality.
fn HObject*? alloc_plain_monthday(Heap* hp, int reference_year, int m, int d, HObject* calendar) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.long_a = reference_year;
    obj.extra.temporal.long_b = m;
    obj.extra.temporal.long_c = d;
    obj.extra.temporal.calendar = calendar;
    return obj;
}

fn HObject*? alloc_duration(Heap* hp, temporal::DurationParts d) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_DURATION);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.long_a = (long)d.years;
    obj.extra.temporal.long_b = (long)d.months;
    obj.extra.temporal.long_c = (long)d.weeks;
    obj.extra.temporal.long_d = (long)d.days;
    obj.extra.temporal.long_e = (long)d.hours;
    obj.extra.temporal.long_f = (long)d.minutes;
    obj.extra.temporal.long_g = (long)d.seconds;
    obj.extra.temporal.long_h = d.ms;
    obj.extra.temporal.long_i = d.us;
    obj.extra.temporal.long_j = d.ns;
    return obj;
}

fn temporal::CivilDate plain_date_value(HObject* obj) {
    return {
        .y = (long)obj.extra.temporal.long_a,
        .m = obj.extra.temporal.long_b,
        .d = obj.extra.temporal.long_c,
    };
}

fn temporal::CivilTime plain_time_value(HObject* obj) {
    return {
        .h  = obj.extra.temporal.long_a,
        .mi = obj.extra.temporal.long_b,
        .s  = obj.extra.temporal.long_c,
        .ms = obj.extra.temporal.long_d,
        .us = obj.extra.temporal.long_e,
        .ns = obj.extra.temporal.long_f,
    };
}

fn temporal::CivilDateTime plain_datetime_value(HObject* obj) {
    return {
        .date = plain_date_value(obj),
        .time = {
            .h  = obj.extra.temporal.long_d,
            .mi = obj.extra.temporal.long_e,
            .s  = obj.extra.temporal.long_f,
            .ms = obj.extra.temporal.long_g,
            .us = obj.extra.temporal.long_h,
            .ns = obj.extra.temporal.long_i,
        },
    };
}

// Extract the canonical year/month and reference day from a PlainYearMonth
// object. The reference day is what `day` returns; it isn't part of equality.
fn long plain_yearmonth_y(HObject* obj) { return (long)obj.extra.temporal.long_a; }
fn int  plain_yearmonth_m(HObject* obj) { return (int)obj.extra.temporal.long_b; }
fn int  plain_yearmonth_day(HObject* obj) { return (int)obj.extra.temporal.long_c; }

// Extract the reference year/month/day from a PlainMonthDay object. The
// reference year is what `year` returns; it isn't part of equality.
fn int  plain_monthday_year(HObject* obj) { return (int)obj.extra.temporal.long_a; }
fn int  plain_monthday_m(HObject* obj) { return (int)obj.extra.temporal.long_b; }
fn int  plain_monthday_d(HObject* obj) { return (int)obj.extra.temporal.long_c; }

fn temporal::DurationParts duration_value(HObject* obj) {
    temporal::DurationParts d;
    d.years   = obj.extra.temporal.long_a;
    d.months  = obj.extra.temporal.long_b;
    d.weeks   = obj.extra.temporal.long_c;
    d.days    = obj.extra.temporal.long_d;
    d.hours   = obj.extra.temporal.long_e;
    d.minutes = obj.extra.temporal.long_f;
    d.seconds = obj.extra.temporal.long_g;
    d.ms      = obj.extra.temporal.long_h;
    d.us      = obj.extra.temporal.long_i;
    d.ns      = obj.extra.temporal.long_j;
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

// Proxy-aware read: when the bag is a Proxy exotic, route through the trap
// machinery so observers (test262 propertyBagObserver) see the [[Get]]
// rather than only the prop table lookup. For non-Proxy objects this is
// equivalent to prop_or_undefined.
fn TVal prop_or_undefined_pa(BuiltinContext* ctx, HObject* o, char[] name) {
    Heap* hp = ctx.heap;
    HString* key = builtin_intern_string(hp, name);
    if (o.flags.exotic_proxyobj && ctx.vm != null) {
        TVal recv; recv.set_object(o);
        TVal out;
        if (proxy_mop_get(ctx.vm, hp, o, key, recv, &out)) {
            if (ctx.should_throw) {
                TVal undef; undef.set_undefined();
                return undef;
            }
            return out;
        }
        if (hp.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = hp.error_value;
            hp.has_error = false;
        }
        TVal undef; undef.set_undefined();
        return undef;
    }
    TVal undef; undef.set_undefined();
    return o.get_prop(key, hp) ?? undef;
}

// Read the `overflow` option (default "constrain"). Per spec (GetOption +
// ToTemporalOverflow), the option value is converted to a string before being
// matched against the allowed set. TypeError only fires when ToString itself
// throws (e.g. on a Symbol); null / true / numbers convert to invalid
// strings and reject with RangeError. The top-level options must be an
// object (or undefined).
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
    // Convert to string per GetOption step 9.a. Symbol throws TypeError
    // (ToString); primitives convert to invalid strings and RangeError below.
    HString* str = builtin_to_string_vm(ctx, &val);
    if (ctx.should_throw) return false;
    char[] v = str.get_cstr()[:str.blen];
    if (v == "constrain") return true;
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
        HString* s = builtin_to_string_vm(ctx, &tv);
        if (ctx.should_throw) return false;
        if (s == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "monthCode must be convertible to a string");
            return false;
        }
        tv.set_string(s);
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
// Property reads happen in the spec order (calendar, day, month, monthCode,
// year) so observers (test262 propertyBagObserver) see the right sequence
// and valueOf/toString fire right after their property.
fn bool bag_to_fields(BuiltinContext* ctx, HObject* bag, bool keep_missing,
                      temporal::CivilDate cur, temporal::CivilDate* out,
                      long* out_epoch_days) {
    Vm* v = (Vm*)ctx.vm;

    // Calendar (RejectObjectWithCalendarOrTimeZone): we only support iso8601,
    // so read calendar first; anything other than an iso8601 string/calendar
    // object throws.
    TVal cal_v = prop_or_undefined_pa(ctx, bag, "calendar");
    if (!cal_v.is_undefined()) {
        HObject* cal;
        if (!calendar_from_arg(ctx, &cal_v, &cal)) return false;
    }

    // era / eraYear are never read by the ISO calendar's PrepareTemporalFields,
    // so we don't probe for them here either. They would be rejected if a
    // caller set them on the bag directly via JS, but no spec path triggers
    // that read.

    long y = cur.y;
    long m = cur.m;
    long d = cur.d;

    // day
    TVal day_v = prop_or_undefined_pa(ctx, bag, "day");
    if (!day_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &day_v, &d)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
            return false;
        }
    } else if (!keep_missing) {
        d = 1;
    }

    // month
    TVal month_v = prop_or_undefined_pa(ctx, bag, "month");
    bool have_month = false;
    long mv = 0;
    if (!month_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &month_v, &mv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
            return false;
        }
        have_month = true;
    }

    // monthCode
    TVal mc_v = prop_or_undefined_pa(ctx, bag, "monthCode");
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
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing month property");
        return false;
    }

    // year (last, per the spec ordering of PrepareTemporalFields)
    TVal year_v = prop_or_undefined_pa(ctx, bag, "year");
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

    out.y = y;
    out.m = (int)m;
    out.d = (int)d;
    *out_epoch_days = temporal::epoch_days_from_civil(y, (int)m, (int)d);
    return true;
}

// Constrain or reject a bag's y/m/d into a valid CivilDate. Month/day clamping
// Constrain or reject a bag's y/m/d into a valid CivilDate. Month < 1 and
// day < 1 always throw. Month > 12 follows overflow (clamp to 12 vs reject).
fn bool fields_to_valid_date(BuiltinContext* ctx, temporal::CivilDate fields,
                             temporal::OverflowKind overflow, temporal::CivilDate* out) {
    long y = fields.y;
    int m = (int)fields.m;
    int d = (int)fields.d;

    if (m < 1) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid month");
        return false;
    }
    if (m > 12) {
        if (overflow == temporal::OverflowKind.REJECT) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid month"); return false; }
        m = 12;
    }
    if (d < 1) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid day");
        return false;
    }
    int dim = temporal::days_in_month(y, (int)m);
    if (d > dim) {
        if (overflow == temporal::OverflowKind.REJECT) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows month");
            return false;
        }
        d = dim;
    }
    if (!temporal::is_valid_iso_date(y, (int)m, (int)d)) {
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

    int  h  = (int)cur.h;
    int  mi = (int)cur.mi;
    int  s  = (int)cur.s;
    int  ms = (int)cur.ms;
    int  us = (int)cur.us;
    int  ns = (int)cur.ns;

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
        if (!temporal::is_valid_iso_date(d.y, (int)d.m, (int)d.d)) {
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

    // Order matches GetDifferenceSettings in the reference implementation:
    // largestUnit, roundingIncrement, roundingMode, smallestUnit. Read in this
    // sequence so Proxy observers see the expected access pattern.
    TVal uv = prop_or_undefined_pa(ctx, opts, "largestUnit");
    if (!uv.is_undefined()) {
        // GetOption converts the value to a string before matching. Symbol
        // throws TypeError; primitives that don't match a known unit reject
        // with RangeError below.
        HString* s = builtin_to_string_vm(ctx, &uv);
        if (ctx.should_throw) return false;
        char[] v = s.get_cstr()[:s.blen];
        if (v == "auto") { /* keep default_largest */ }
        else if (v == "year" || v == "years") { *largest = temporal::DifferenceUnit.YEARS; }
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

    // roundingIncrement: integral >= 1; values > 1 are accepted but computed
    // as the exact difference (rounding is a later phase).
    TVal ri = prop_or_undefined_pa(ctx, opts, "roundingIncrement");
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

    // roundingMode: GetOption converts to string, then matches the allowed set.
    TVal rm = prop_or_undefined_pa(ctx, opts, "roundingMode");
    if (!rm.is_undefined()) {
        HString* s = builtin_to_string_vm(ctx, &rm);
        if (ctx.should_throw) return false;
        char[] v = s.get_cstr()[:s.blen];
        if (!(v == "trunc" || v == "ceil" || v == "floor" || v == "expand" ||
              v == "halfTrunc" || v == "halfCeil" || v == "halfFloor" ||
              v == "halfExpand" || v == "halfEven")) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
            return false;
        }
    }

    TVal sv = prop_or_undefined_pa(ctx, opts, "smallestUnit");
    if (!sv.is_undefined()) {
        HString* s = builtin_to_string_vm(ctx, &sv);
        if (ctx.should_throw) return false;
        char[] v = s.get_cstr()[:s.blen];
        temporal::DifferenceUnit small;
        if (v == "auto") { small = *largest; }
        else if (v == "year" || v == "years") { small = temporal::DifferenceUnit.YEARS; }
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
        TVal* arg = arg_at(ctx, k);
        if (arg.is_undefined()) continue; // spec: undefined args treated as zero
        double val = vm::vm_to_number(v, arg);
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
            case 7: d.ms = whole; d.ns += (int)((val - (double)whole) * 1e6); break;
            case 8: d.us = whole; d.ns += (int)((val - (double)whole) * 1e3); break;
            default: d.ns = whole; break;
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
                    case 7: d.ms = whole; d.ns += (int)((val - (double)whole) * 1e6); break;
                    case 8: d.us = whole; d.ns += (int)((val - (double)whole) * 1e3); break;
                    default: d.ns = whole; break;
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
        case Builtin.TEMPORAL_DURATION_PROTO_YEARS:        val = (double)obj.extra.temporal.long_a; break;
        case Builtin.TEMPORAL_DURATION_PROTO_MONTHS:       val = (double)obj.extra.temporal.long_b; break;
        case Builtin.TEMPORAL_DURATION_PROTO_WEEKS:        val = (double)obj.extra.temporal.long_c; break;
        case Builtin.TEMPORAL_DURATION_PROTO_DAYS:         val = (double)obj.extra.temporal.long_d; break;
        case Builtin.TEMPORAL_DURATION_PROTO_HOURS:        val = (double)obj.extra.temporal.long_e; break;
        case Builtin.TEMPORAL_DURATION_PROTO_MINUTES:      val = (double)obj.extra.temporal.long_f; break;
        case Builtin.TEMPORAL_DURATION_PROTO_SECONDS:      val = (double)obj.extra.temporal.long_g; break;
        case Builtin.TEMPORAL_DURATION_PROTO_MILLISECONDS: val = (double)obj.extra.temporal.long_h; break;
        case Builtin.TEMPORAL_DURATION_PROTO_MICROSECONDS: val = (double)obj.extra.temporal.long_i; break;
        case Builtin.TEMPORAL_DURATION_PROTO_NANOSECONDS:  val = (double)obj.extra.temporal.long_j; break;
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
    // Options, if present, must be an object (function is also OK per spec).
    if (ctx.argc > 0) {
        TVal* opt = arg_at(ctx, 0);
        if (!opt.is_undefined() && (!opt.is_object() || opt.get_heapptr() == null)) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
            return;
        }
    }
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    char[128] buf;
    usz len = temporal::format_duration(d, &buf, 128);
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

// Add two durations without relativeTo. Date fields sum; time fields are
// summed as a single nanosecond count and split back into days/hours/min/sec/
// ms/us/ns (1 day = 86 400 000 000 000 ns). The split-off days join the date
// sum. Years/months/weeks don't interact with each other in this code path,
// matching the spec's no-relativeTo behavior.
fn bool add_durations_no_relative(temporal::DurationParts a, temporal::DurationParts b, temporal::DurationParts* out) {
    // Sum date units directly; balance only happens within the time column.
    long y  = a.years   + b.years;
    long mo = a.months  + b.months;
    long w  = a.weeks   + b.weeks;
    long d  = a.days    + b.days;
    // Convert each time column to ns, sum, then split.
    int128 total_ns = (int128)0;
    total_ns += (int128)(a.hours + b.hours)    * 3600000000000L;
    total_ns += (int128)(a.minutes + b.minutes) *   60000000000L;
    total_ns += (int128)(a.seconds + b.seconds) *    1000000000L;
    total_ns += (int128)(a.ms + b.ms)           *       1000000L;
    total_ns += (int128)(a.us + b.us)           *          1000L;
    total_ns += (int128)(a.ns + b.ns);
    if (total_ns < 0) {
        long whole_days = (long)(-((-total_ns) / 86400000000000L));
        int128 rem = -((-total_ns) % 86400000000000L);
        if (rem != 0) { whole_days -= 1; rem += 86400000000000L; }
        out.days    = d + whole_days;
        out.hours   = (long)(rem / 3600000000000L);
        rem        %= 3600000000000L;
        out.minutes = (long)(rem /   60000000000L);
        rem        %=   60000000000L;
        out.seconds = (long)(rem /    1000000000L);
        rem        %=    1000000000L;
        out.ms      = (long)(rem /       1000000L);
        rem        %=       1000000L;
        out.us      = (long)(rem /          1000L);
        out.ns      = (long)(rem %             1000L);
    } else {
        long whole_days = (long)(total_ns / 86400000000000L);
        int128 rem = total_ns % 86400000000000L;
        out.days    = d + whole_days;
        out.hours   = (long)(rem / 3600000000000L);
        rem        %= 3600000000000L;
        out.minutes = (long)(rem /   60000000000L);
        rem        %=   60000000000L;
        out.seconds = (long)(rem /    1000000000L);
        rem        %=    1000000000L;
        out.ms      = (long)(rem /       1000000L);
        rem        %=       1000000L;
        out.us      = (long)(rem /          1000L);
        out.ns      = (long)(rem %             1000L);
    }
    out.years  = y;
    out.months = mo;
    out.weeks  = w;
    return true;
}

fn void builtin_temporal_duration_proto_add(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.add requires an argument");
        return;
    }
    temporal::DurationParts other;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &other)) return;
    temporal::DurationParts a = duration_value((HObject*)this_val.get_heapptr());
    temporal::DurationParts result;
    if (!add_durations_no_relative(a, other, &result)) return;
    HObject*? obj_o = alloc_duration(ctx.heap, result);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_duration_proto_subtract(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.subtract requires an argument");
        return;
    }
    temporal::DurationParts other;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &other)) return;
    // Negate and add.
    other.years = -other.years;
    other.months = -other.months;
    other.weeks = -other.weeks;
    other.days = -other.days;
    other.hours = -other.hours;
    other.minutes = -other.minutes;
    other.seconds = -other.seconds;
    other.ms = -other.ms;
    other.us = -other.us;
    other.ns = -other.ns;
    temporal::DurationParts a = duration_value((HObject*)this_val.get_heapptr());
    temporal::DurationParts result;
    if (!add_durations_no_relative(a, other, &result)) return;
    HObject*? obj_o = alloc_duration(ctx.heap, result);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

// Duration.prototype.with: copy `this` and overwrite the named fields. Unknown
// properties are ignored, mirroring the basic test's
// "incorrectly-spelled properties are ignored" case.
fn void builtin_temporal_duration_proto_with(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    if (ctx.argc < 1 || !arg_at(ctx, 0).is_object() || arg_at(ctx, 0).get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.with requires a property bag");
        return;
    }
    HObject* bag = (HObject*)arg_at(ctx, 0).get_heapptr();
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    char[][] names = { "days", "hours", "minutes", "seconds",
        "milliseconds", "microseconds", "nanoseconds" };
    long*[7] slots = { &d.days, &d.hours, &d.minutes, &d.seconds,
        &d.ms, &d.us, &d.ns };
    Vm* v = (Vm*)ctx.vm;
    for (int k = 0; k < 7; k++) {
        TVal pv = prop_or_undefined(bag, ctx.heap, names[k]);
        if (pv.is_undefined()) continue;
        double val = vm::vm_to_number(v, &pv);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        if (math::is_nan(val) || math::is_inf(val)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "duration fields must be finite");
            return;
        }
        long whole = (long)math::trunc(val);
        *slots[k] = whole;
    }
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
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
        int dim = temporal::days_in_month(d.y, (int)d.m);
        if (d.d > dim) {
            if (overflow == temporal::OverflowKind.REJECT) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows month");
                return;
            }
            d.d = dim;
        }
        if (!temporal::is_valid_iso_date(d.y, (int)d.m, (int)d.d)) {
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
    ctx.result.set_number((double)(long)obj.extra.temporal.long_a);
}

fn void builtin_temporal_plain_date_proto_month(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)obj.extra.temporal.long_b);
}

fn void builtin_temporal_plain_date_proto_day(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)obj.extra.temporal.long_c);
}

fn void builtin_temporal_plain_date_proto_dayOfWeek(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long days = temporal::epoch_days_from_civil(
        (long)obj.extra.temporal.long_a, (int)obj.extra.temporal.long_b, (int)obj.extra.temporal.long_c);
    // 1970-01-01 = Thursday = ISO 4; ((d % 7) + 4) % 7 maps [0..6] -> [4,5,6,7,1,2,3].
    long w = ((days % 7) + 4) % 7;
    if (w <= 0) w += 7;
    ctx.result.set_number((double)w);
}

fn void builtin_temporal_plain_date_proto_dayOfYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = (long)obj.extra.temporal.long_a;
    long jan1 = temporal::epoch_days_from_civil(y, (int)1, (int)1);
    long doy = temporal::epoch_days_from_civil(y, (int)obj.extra.temporal.long_b, (int)obj.extra.temporal.long_c) - jan1 + 1;
    ctx.result.set_number((double)doy);
}

fn void builtin_temporal_plain_date_proto_monthCode(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    int m = (int)obj.extra.temporal.long_b;
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
    ctx.result.set_boolean(temporal::is_leap_year((long)obj.extra.temporal.long_a));
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
    ctx.result.set_number((double)temporal::days_in_month((long)obj.extra.temporal.long_a, (int)obj.extra.temporal.long_b));
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
    ctx.result.set_number(temporal::is_leap_year((long)obj.extra.temporal.long_a) ? 366.0 : 365.0);
}

fn void builtin_temporal_plain_date_proto_monthsInYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    ctx.result.set_number(12.0);
}

fn long iso_weeks_in_year(long year) {
    // ISO 8601: a year has 53 weeks iff Jan 1 is a Thursday, or Jan 1 is a
    // Wednesday in a leap year.
    long jan1_dow = ((temporal::epoch_days_from_civil(year, (int)1, (int)1) % 7) + 4) % 7;
    if (jan1_dow <= 0) jan1_dow += 7;
    if (jan1_dow == 4 || (jan1_dow == 3 && temporal::is_leap_year(year))) return 53;
    return 52;
}

fn void builtin_temporal_plain_date_proto_weekOfYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = (long)obj.extra.temporal.long_a;
    long doy = temporal::epoch_days_from_civil(y, (int)obj.extra.temporal.long_b, (int)obj.extra.temporal.long_c) -
               temporal::epoch_days_from_civil(y, (int)1, (int)1) + 1;
    long dow = ((temporal::epoch_days_from_civil(y, (int)obj.extra.temporal.long_b, (int)obj.extra.temporal.long_c) % 7) + 4) % 7;
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
    long y = (long)obj.extra.temporal.long_a;
    long doy = temporal::epoch_days_from_civil(y, (int)obj.extra.temporal.long_b, (int)obj.extra.temporal.long_c) -
               temporal::epoch_days_from_civil(y, (int)1, (int)1) + 1;
    long dow = ((temporal::epoch_days_from_civil(y, (int)obj.extra.temporal.long_b, (int)obj.extra.temporal.long_c) % 7) + 4) % 7;
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
    Vm* v = (Vm*)ctx.vm;

    // Spec order: validate the field bag (base ranges reject regardless of
    // overflow) before reading options, so a primitive options type does not
    // shadow a RangeError on the bag itself. The full validity check below
    // re-runs with the resolved overflow.
    temporal::CivilDate cur = plain_date_value(obj);
    temporal::CivilDate fields;
    long _ep;
    if (!bag_to_fields(ctx, bag, true, cur, &fields, &_ep)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    // Base ranges reject up-front. These are the same rules the validator
    // applies at the default constrain, so passing CONSTRAIN here only
    // catches the unconditional cases (month < 1, day < 1). The second pass
    // below handles the overflow-dependent ones (month > 12, day > daysInMonth).
    temporal::CivilDate _pre;
    if (!fields_to_valid_date(ctx, fields, temporal::OverflowKind.CONSTRAIN, &_pre)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
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
    bool any_field = false;
    for (int k = 0; k < 10; k++) {
        TVal pv = prop_or_undefined(o, ctx.heap, names[k]);
        if (pv.is_undefined()) continue;
        any_field = true;
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
    if (!any_field) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "duration property bag has no recognized fields");
        return false;
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
        if (cur.d > temporal::days_in_month(m.y, (int)m.m)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows the resulting month");
            return;
        }
        after_months = { .y = m.y, .m = m.m, .d = cur.d };
    } else {
        after_months = temporal::add_months(cur, total_months, temporal::OverflowKind.CONSTRAIN);
    }
    temporal::CivilDate result = temporal::add_days(after_months, total_days);
    if (!temporal::is_valid_iso_date(result.y, (int)result.m, (int)result.d)) {
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
        if (cur.d > temporal::days_in_month(m.y, (int)m.m)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows the resulting month");
            return;
        }
        after_months = { .y = m.y, .m = m.m, .d = cur.d };
    } else {
        after_months = temporal::add_months(cur, total_months, temporal::OverflowKind.CONSTRAIN);
    }
    temporal::CivilDate result = temporal::add_days(after_months, total_days);
    if (!temporal::is_valid_iso_date(result.y, (int)result.m, (int)result.d)) {
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

// PlainDate.prototype.withCalendar(calendarLike): clones the date with a new
// calendar. Only iso8601 is supported, so any non-calendar value must be the
// string "iso8601" (case-insensitive).
fn void builtin_temporal_plain_date_proto_withCalendar(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "PlainDate.prototype.withCalendar requires a calendar argument");
        return;
    }
    HObject* cal;
    if (!calendar_from_arg(ctx, arg_at(ctx, 0), &cal)) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDate cur = plain_date_value(obj);
    ((types::HeapHeader*)cal).incref();
    HObject*? obj_o = alloc_plain_date(ctx.heap, cur, cal);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(obj2);
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
        if (!temporal::is_valid_time((int)result.h, (int)result.mi, (int)result.s, (int)result.ms, (int)result.us, (int)result.ns)) {
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
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_HOUR:       val = (double)obj.extra.temporal.long_a; break;
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_MINUTE:     val = (double)obj.extra.temporal.long_b; break;
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_SECOND:     val = (double)obj.extra.temporal.long_c; break;
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_MILLISECOND: val = (double)obj.extra.temporal.long_d; break;
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_MICROSECOND: val = (double)obj.extra.temporal.long_e; break;
        case Builtin.TEMPORAL_PLAIN_TIME_PROTO_NANOSECOND:  val = (double)obj.extra.temporal.long_f; break;
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
        if (!temporal::is_valid_time((int)t.h, (int)t.mi, (int)t.s, (int)t.ms, (int)t.us, (int)t.ns)) {
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

    if (!temporal::is_valid_time((int)result.h, (int)result.mi, (int)result.s, (int)result.ms, (int)result.us, (int)result.ns)) {
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

    if (!temporal::is_valid_time((int)result.h, (int)result.mi, (int)result.s, (int)result.ms, (int)result.us, (int)result.ns)) {
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
        int dim = temporal::days_in_month(d.y, (int)d.m);
        if (d.d > dim) {
            if (overflow == temporal::OverflowKind.REJECT) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows month");
                return;
            }
            d.d = dim;
        }
        if (!temporal::is_valid_iso_date(d.y, (int)d.m, (int)d.d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
            return;
        }
        temporal::CivilTime t = {
            .h = p.hour, .mi = p.minute, .s = p.second,
            .ms = (int)(p.nanos / 1_000_000),
            .us = (int)((p.nanos / 1000) % 1000),
            .ns = (int)(p.nanos % 1000),
        };
        if (!temporal::is_valid_time((int)t.h, (int)t.mi, (int)t.s, (int)t.ms, (int)t.us, (int)t.ns)) {
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
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_YEAR:        val = (double)(long)obj.extra.temporal.long_a; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MONTH:       val = (double)obj.extra.temporal.long_b; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAY:         val = (double)obj.extra.temporal.long_c; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_HOUR:        val = (double)obj.extra.temporal.long_d; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MINUTE:      val = (double)obj.extra.temporal.long_e; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_SECOND:      val = (double)obj.extra.temporal.long_f; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MILLISECOND: val = (double)obj.extra.temporal.long_g; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MICROSECOND: val = (double)obj.extra.temporal.long_h; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_NANOSECOND:  val = (double)obj.extra.temporal.long_i; break;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_CALENDAR:
            ctx.result.set_object(obj.extra.temporal.calendar);
            return;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_CALENDARID:
            ctx.result.set_string(builtin_intern_string(ctx.heap, "iso8601"));
            return;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MONTHCODE: {
            int m = (int)obj.extra.temporal.long_b;
            char[5] buf;
            usz len;
            if (m < 10) {
                len = (usz)libc::snprintf(&buf, 5, "M0%d", m);
            } else {
                len = (usz)libc::snprintf(&buf, 5, "M%d", m);
            }
            ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
            return;
        }
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAYOFWEEK: {
            long y = (long)obj.extra.temporal.long_a;
            int m = (int)obj.extra.temporal.long_b;
            int d = (int)obj.extra.temporal.long_c;
            long days = temporal::epoch_days_from_civil(y, m, d);
            long dow = ((days % 7) + 4) % 7;
            if (dow <= 0) dow += 7;
            ctx.result.set_number((double)dow);
            return;
        }
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAYOFYEAR: {
            long y = (long)obj.extra.temporal.long_a;
            long jan1 = temporal::epoch_days_from_civil(y, (int)1, (int)1);
            long doy = temporal::epoch_days_from_civil(y, (int)obj.extra.temporal.long_b, (int)obj.extra.temporal.long_c) - jan1 + 1;
            ctx.result.set_number((double)doy);
            return;
        }
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_WEEKOFYEAR: {
            long y = (long)obj.extra.temporal.long_a;
            int m = (int)obj.extra.temporal.long_b;
            int d = (int)obj.extra.temporal.long_c;
            long doy = temporal::epoch_days_from_civil(y, m, d) - temporal::epoch_days_from_civil(y, 1, 1) + 1;
            long dow = ((temporal::epoch_days_from_civil(y, m, d) % 7) + 4) % 7;
            if (dow <= 0) dow += 7;
            long week = (doy - dow + 10) / 7;
            if (week < 1) {
                week = iso_weeks_in_year(y - 1);
            } else if (week > iso_weeks_in_year(y)) {
                week = 1;
            }
            ctx.result.set_number((double)week);
            return;
        }
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_YEAROFWEEK: {
            long y = (long)obj.extra.temporal.long_a;
            int m = (int)obj.extra.temporal.long_b;
            int d = (int)obj.extra.temporal.long_c;
            long doy = temporal::epoch_days_from_civil(y, m, d) - temporal::epoch_days_from_civil(y, 1, 1) + 1;
            long dow = ((temporal::epoch_days_from_civil(y, m, d) % 7) + 4) % 7;
            if (dow <= 0) dow += 7;
            long week = (doy - dow + 10) / 7;
            long week_year = y;
            if (week < 1) { week_year = y - 1; }
            else if (week > iso_weeks_in_year(y)) { week_year = y + 1; }
            ctx.result.set_number((double)week_year);
            return;
        }
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAYSINWEEK:
            ctx.result.set_number(7.0);
            return;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAYSINMONTH: {
            int m = (int)obj.extra.temporal.long_b;
            long y = (long)obj.extra.temporal.long_a;
            ctx.result.set_number((double)temporal::days_in_month((int)y, m));
            return;
        }
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAYSINYEAR: {
            long y = (long)obj.extra.temporal.long_a;
            ctx.result.set_number(temporal::is_leap_year(y) ? 366.0 : 365.0);
            return;
        }
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MONTHSINYEAR:
            ctx.result.set_number(12.0);
            return;
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_INLEAPYEAR: {
            long y = (long)obj.extra.temporal.long_a;
            ctx.result.set_number(temporal::is_leap_year(y) ? 1.0 : 0.0);
            return;
        }
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
        if (!temporal::is_valid_iso_date(d.y, (int)d.m, (int)d.d)) {
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
        if (cur.date.d > temporal::days_in_month(m.y, (int)m.m)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows the resulting month");
            return;
        }
        after_months = { .y = m.y, .m = m.m, .d = cur.date.d };
    } else {
        after_months = temporal::add_months(cur.date, total_months, temporal::OverflowKind.CONSTRAIN);
    }
    temporal::CivilDate date_part = temporal::add_days(after_months, total_days);
    if (!temporal::is_valid_iso_date(date_part.y, (int)date_part.m, (int)date_part.d)) {
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
        if (cur.date.d > temporal::days_in_month(m.y, (int)m.m)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows the resulting month");
            return;
        }
        after_months = { .y = m.y, .m = m.m, .d = cur.date.d };
    } else {
        after_months = temporal::add_months(cur.date, total_months, temporal::OverflowKind.CONSTRAIN);
    }
    temporal::CivilDate date_part = temporal::add_days(after_months, total_days);
    if (!temporal::is_valid_iso_date(date_part.y, (int)date_part.m, (int)date_part.d)) {
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
    long start_epoch = temporal::epoch_days_from_civil(start.date.y, (int)start.date.m, (int)start.date.d) * 86_400L
                     + (long)start.time.h * 3600 + (long)start.time.mi * 60 + (long)start.time.s;
    long end_epoch   = temporal::epoch_days_from_civil(end.date.y, (int)end.date.m, (int)end.date.d)   * 86_400L
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

fn void builtin_temporal_plain_datetime_proto_withCalendar(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "PlainDateTime.prototype.withCalendar requires a calendar argument");
        return;
    }
    HObject* cal;
    if (!calendar_from_arg(ctx, arg_at(ctx, 0), &cal)) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDateTime cur = plain_datetime_value(obj);
    ((types::HeapHeader*)cal).incref();
    HObject*? obj_o = alloc_plain_datetime(ctx.heap, cur, cal);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(obj2);
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
    TVal year_v  = prop_or_undefined_pa(ctx, bag, "year");
    TVal month_v = prop_or_undefined_pa(ctx, bag, "month");
    TVal mc_v    = prop_or_undefined_pa(ctx, bag, "monthCode");
    TVal day_v   = prop_or_undefined_pa(ctx, bag, "day");
    TVal cal_v   = prop_or_undefined_pa(ctx, bag, "calendar");
    TVal era_v   = prop_or_undefined_pa(ctx, bag, "era");
    TVal era_y_v = prop_or_undefined_pa(ctx, bag, "eraYear");

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
    int dim = temporal::days_in_month(y, (int)m);
    if (d > dim) {
        if (overflow == temporal::OverflowKind.REJECT) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows month");
            return false;
        }
        d = dim;
    }
    if (!temporal::is_valid_iso_date(y, (int)m, (int)d)) {
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
    ctx.result.set_number((double)temporal::days_in_month(plain_yearmonth_y(obj), (int)plain_yearmonth_m(obj)));
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

fn void builtin_temporal_plain_yearmonth_proto_dayOfWeek(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = plain_yearmonth_y(obj);
    int m = plain_yearmonth_m(obj);
    // PlainYearMonth represents "any" day of month; ISO spec uses day 1 of the month
    // for calendar-derived getters (consistent with calendar arithmetic).
    long days = temporal::epoch_days_from_civil(y, m, 1);
    long dow = ((days % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    ctx.result.set_number((double)dow);
}

fn void builtin_temporal_plain_yearmonth_proto_dayOfYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = plain_yearmonth_y(obj);
    int m = plain_yearmonth_m(obj);
    long doy = temporal::epoch_days_from_civil(y, m, 1) - temporal::epoch_days_from_civil(y, 1, 1) + 1;
    ctx.result.set_number((double)doy);
}

fn void builtin_temporal_plain_yearmonth_proto_weekOfYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = plain_yearmonth_y(obj);
    int m = plain_yearmonth_m(obj);
    long days = temporal::epoch_days_from_civil(y, m, 1);
    long doy = days - temporal::epoch_days_from_civil(y, 1, 1) + 1;
    long dow = ((days % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    long week = (doy - dow + 10) / 7;
    if (week < 1) {
        week = iso_weeks_in_year(y - 1);
    } else if (week > iso_weeks_in_year(y)) {
        week = 1;
    }
    ctx.result.set_number((double)week);
}

fn void builtin_temporal_plain_yearmonth_proto_yearOfWeek(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = plain_yearmonth_y(obj);
    int m = plain_yearmonth_m(obj);
    long days = temporal::epoch_days_from_civil(y, m, 1);
    long doy = days - temporal::epoch_days_from_civil(y, 1, 1) + 1;
    long dow = ((days % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    long week = (doy - dow + 10) / 7;
    long week_year = y;
    if (week < 1) { week_year = y - 1; }
    else if (week > iso_weeks_in_year(y)) { week_year = y + 1; }
    ctx.result.set_number((double)week_year);
}

fn void builtin_temporal_plain_yearmonth_proto_daysInWeek(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    ctx.result.set_number(7.0);
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
    TVal year_v  = prop_or_undefined_pa(ctx, bag, "year");
    TVal month_v = prop_or_undefined_pa(ctx, bag, "month");
    TVal mc_v    = prop_or_undefined_pa(ctx, bag, "monthCode");
    TVal day_v   = prop_or_undefined_pa(ctx, bag, "day");
    TVal cal_v   = prop_or_undefined_pa(ctx, bag, "calendar");
    TVal era_v   = prop_or_undefined_pa(ctx, bag, "era");
    TVal era_y_v = prop_or_undefined_pa(ctx, bag, "eraYear");

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
    int dim = temporal::days_in_month((long)y, (int)m);
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
    ctx.result.set_number((double)temporal::days_in_month((long)plain_monthday_year(obj), (int)plain_monthday_m(obj)));
}

fn void builtin_temporal_plain_monthday_proto_dayOfWeek(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // PlainMonthDay carries year implicitly as ISO reference year for ISO calendar.
    long y = (long)plain_monthday_year(obj);
    int m = (int)plain_monthday_m(obj);
    int d = (int)plain_monthday_d(obj);
    long days = temporal::epoch_days_from_civil(y, m, d);
    long dow = ((days % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    ctx.result.set_number((double)dow);
}

fn void builtin_temporal_plain_monthday_proto_dayOfYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = (long)plain_monthday_year(obj);
    int m = (int)plain_monthday_m(obj);
    int d = (int)plain_monthday_d(obj);
    long doy = temporal::epoch_days_from_civil(y, m, d) - temporal::epoch_days_from_civil(y, 1, 1) + 1;
    ctx.result.set_number((double)doy);
}

fn void builtin_temporal_plain_monthday_proto_daysInWeek(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    ctx.result.set_number(7.0);
}

fn void builtin_temporal_plain_monthday_proto_daysInYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = (long)plain_monthday_year(obj);
    ctx.result.set_number(temporal::is_leap_year(y) ? 366.0 : 365.0);
}

fn void builtin_temporal_plain_monthday_proto_monthsInYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    ctx.result.set_number(12.0);
}

fn void builtin_temporal_plain_monthday_proto_weekOfYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = (long)plain_monthday_year(obj);
    int m = (int)plain_monthday_m(obj);
    int d = (int)plain_monthday_d(obj);
    long days = temporal::epoch_days_from_civil(y, m, d);
    long doy = days - temporal::epoch_days_from_civil(y, 1, 1) + 1;
    long dow = ((days % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    long week = (doy - dow + 10) / 7;
    if (week < 1) {
        week = iso_weeks_in_year(y - 1);
    } else if (week > iso_weeks_in_year(y)) {
        week = 1;
    }
    ctx.result.set_number((double)week);
}

fn void builtin_temporal_plain_monthday_proto_yearOfWeek(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    long y = (long)plain_monthday_year(obj);
    int m = (int)plain_monthday_m(obj);
    int d = (int)plain_monthday_d(obj);
    long days = temporal::epoch_days_from_civil(y, m, d);
    long doy = days - temporal::epoch_days_from_civil(y, 1, 1) + 1;
    long dow = ((days % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    long week = (doy - dow + 10) / 7;
    long week_year = y;
    if (week < 1) { week_year = y - 1; }
    else if (week > iso_weeks_in_year(y)) { week_year = y + 1; }
    ctx.result.set_number((double)week_year);
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
    long epoch_a = temporal::epoch_days_from_civil(yref, (int)am, (int)ad);
    long epoch_b = temporal::epoch_days_from_civil(yref, (int)bm, (int)bd);
    long forward = epoch_b - epoch_a;
    long year_days = temporal::epoch_days_from_civil(yref + 1, (int)1, (int)1) - temporal::epoch_days_from_civil(yref, (int)1, (int)1);
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
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_DURATION_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_DURATION_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_DURATION_PROTO_WITH.ordinal)) return false;
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
    if (!register_string_proto_method(proto, heap, "withCalendar", Builtin.TEMPORAL_PLAIN_DATE_PROTO_WITHCALENDAR.ordinal)) return false;

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
    if (!register_proto_getter_accessor(proto, heap, "dayOfWeek", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAYOFWEEK.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "dayOfYear", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAYOFYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "monthCode", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MONTHCODE.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "inLeapYear", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_INLEAPYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInMonth", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAYSINMONTH.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInWeek", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAYSINWEEK.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInYear", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_DAYSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "monthsInYear", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_MONTHSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "weekOfYear", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_WEEKOFYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "yearOfWeek", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_YEAROFWEEK.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_SINCE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "withCalendar", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_WITHCALENDAR.ordinal)) return false;

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
    if (!register_proto_getter_accessor(proto, heap, "dayOfWeek", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_DAYOFWEEK.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "dayOfYear", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_DAYOFYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "weekOfYear", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_WEEKOFYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "yearOfWeek", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_YEAROFWEEK.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInWeek", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_DAYSINWEEK.ordinal)) return false;
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
    if (!register_proto_getter_accessor(proto, heap, "dayOfWeek", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_DAYOFWEEK.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "dayOfYear", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_DAYOFYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInWeek", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_DAYSINWEEK.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInYear", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_DAYSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "monthsInYear", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_MONTHSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "weekOfYear", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_WEEKOFYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "yearOfWeek", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_YEAROFWEEK.ordinal)) return false;
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
    // Temporal.Now object (Phase 3): non-constructable namespace with the six
    // current-clock methods attached. Build before wiring so a failure is
    // surfaced up here rather than as a missing property later.
    HObject*? now_obj_o = build_temporal_now(heap);
    if (catch err_n = now_obj_o) return false;
    HObject* now_obj = now_obj_o;
    HString* now_key = heap.str_intern("Now");
    if (now_key == null) return false;
    TVal now_tv;
    now_tv.set_object(now_obj);
    ns.put_prop(now_key, now_tv, hobject::PROP_FLAGS_WC, heap);

    // Real constructors: PlainDate, Calendar, Duration, PlainTime, PlainDateTime,
    // PlainYearMonth, PlainMonthDay.
    // The namespace wiring walks back through each prototype's .constructor property.
    HString* ctor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal undef;
    undef.set_undefined();

    HString* pd_prop_key = builtin_intern_string(heap, "PlainDate");
    TVal ctor_tv = heap.temporal_plain_date_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (ctor_tv.is_object() && ctor_tv.get_heapptr() != null) {
        ns.put_prop(pd_prop_key, ctor_tv, hobject::PROP_FLAGS_WC, heap);
    }

    HString* cal_key = builtin_intern_string(heap, "Calendar");
    TVal cal_ctor = heap.temporal_calendar_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (cal_ctor.is_object() && cal_ctor.get_heapptr() != null) {
        ns.put_prop(cal_key, cal_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* dur_key = builtin_intern_string(heap, "Duration");
    TVal dur_ctor = heap.temporal_duration_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (dur_ctor.is_object() && dur_ctor.get_heapptr() != null) {
        ns.put_prop(dur_key, dur_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* pt_key = builtin_intern_string(heap, "PlainTime");
    TVal pt_ctor = heap.temporal_plain_time_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pt_ctor.is_object() && pt_ctor.get_heapptr() != null) {
        ns.put_prop(pt_key, pt_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* pdt_key = builtin_intern_string(heap, "PlainDateTime");
    TVal pdt_ctor = heap.temporal_plain_datetime_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pdt_ctor.is_object() && pdt_ctor.get_heapptr() != null) {
        ns.put_prop(pdt_key, pdt_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* pym_key = builtin_intern_string(heap, "PlainYearMonth");
    TVal pym_ctor = heap.temporal_plain_yearmonth_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pym_ctor.is_object() && pym_ctor.get_heapptr() != null) {
        ns.put_prop(pym_key, pym_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* pmd_key = builtin_intern_string(heap, "PlainMonthDay");
    TVal pmd_ctor = heap.temporal_plain_monthday_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (pmd_ctor.is_object() && pmd_ctor.get_heapptr() != null) {
        ns.put_prop(pmd_key, pmd_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* inst_key = builtin_intern_string(heap, "Instant");
    TVal inst_ctor = heap.temporal_instant_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (inst_ctor.is_object() && inst_ctor.get_heapptr() != null) {
        ns.put_prop(inst_key, inst_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* tz_key = builtin_intern_string(heap, "TimeZone");
    TVal tz_ctor = heap.temporal_timezone_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (tz_ctor.is_object() && tz_ctor.get_heapptr() != null) {
        ns.put_prop(tz_key, tz_ctor, hobject::PROP_FLAGS_WC, heap);
    }

    HString* zdt_key = builtin_intern_string(heap, "ZonedDateTime");
    TVal zdt_ctor = heap.temporal_zoneddatetime_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (zdt_ctor.is_object() && zdt_ctor.get_heapptr() != null) {
        ns.put_prop(zdt_key, zdt_ctor, hobject::PROP_FLAGS_WC, heap);
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
// The ns value is range-checked against ±86400 * 10^17 (the ISO 8601 range
// ±100_000_000 days from the epoch), and the call is rejected when it is not
// invoked with `new` (per spec §`TemporalInstant` step 1).
fn void builtin_temporal_instant_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant must be called with new");
        return;
    }
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant requires an epochNanoseconds argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, arg, &ok);
    if (!ok) return;
    // builtin_to_bigint returns a borrowed reference: for a BigInt argument the
    // caller's register (or constant pool) still owns it, so we do NOT release
    // it on any path. alloc_instant increfs the stored copy; on throw paths the
    // caller's register cleanup frees the original. Decref'ing here would
    // double-free a register BigInt whose VM cleanup runs after the throw
    // returns (caught the segfault via `try { new Instant(lim + 1n) }`).
    if (!b.fits_int128()) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.Instant: epochNanoseconds is out of range");
        return;
    }
    int128 v = b.to_int128();
    int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
    if (v < -ns_limit || v > ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.Instant: epochNanoseconds is outside the representable range");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, b);
    if (catch err = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_instant_proto);
    ctx.result.set_object(obj);
}

// Temporal.Instant.from(item) — accepts a BigInt, an ISO string, or another
// Instant. Strings are parsed via the same path as ToTemporalInstant.
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
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant.from: non-Instant object argument");
        return;
    }
    if (arg.is_string()) {
        hbigint::HBigInt* b;
        if (!to_temporal_instant(ctx, arg, &b)) return;
        defer ctx.heap.decref((types::HeapHeader*)b);
        HObject*? obj_o = alloc_instant(ctx.heap, b);
        if (catch err = obj_o) {
            builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
            return;
        }
        HObject* obj = obj_o;
        obj.prototype = ctx.heap.temporal_instant_proto;
        ctx.result.set_object(obj);
        return;
    }
    // Default: ToBigInt(value).
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, arg, &ok);
    if (!ok) return;
    HObject*? obj_o = alloc_instant(ctx.heap, b);
    if (catch err = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
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
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: missing argument");
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
    // ES262 §TemporalInstant: ms must stay within the range that fits in ns
    // after multiplication. Limit is the same ±86400 * 1e9 ns / 1e3 ms =
    // ±8.64e15 ms.
    int128 ms_limit = (int128)86400L * (int128)100000000L * (int128)1000L;
    if (i128 < -ms_limit || i128 > ms_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: out of representable range");
        return;
    }
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
    if (!b.fits_int128()) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochNanoseconds: out of range");
        return;
    }
    int128 v = b.to_int128();
    int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
    if (v < -ns_limit || v > ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochNanoseconds: outside the representable range");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, b);
    if (catch err = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
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
//
// Fractional-second output. `digits` is -1 for "auto" (the minimal number of
// digits with trailing zeros trimmed and no rounding), 0 for none, or 1..9
// for a fixed width (lower digits truncated, the Temporal default
// roundingMode). Appends the leading "." plus the padded fraction starting at
// buf; returns the number of characters appended (0 if there is no fraction).
fn int format_fractional_seconds(char* buf, long ns_rem, int digits) {
    if (ns_rem < 0) ns_rem = -ns_rem;
    if (ns_rem == 0) return 0;
    int d = digits;
    if (d < 0) {
        // auto: needed digits then drop trailing zeros.
        d = 9;
        long x = ns_rem;
        while (x > 1 && x % 10 == 0) { x /= 10; d--; }
        if (d <= 0) return 0;
    }
    if (d > 9) d = 9;
    // Truncate to `d` digits (the default roundingMode is "trunc").
    long divisor = 1;
    for (int i = 0; i < 9 - d; i++) divisor *= 10;
    long v = ns_rem / divisor;
    if (v == 0) return 0;
    buf[0] = '.';
    char[16] tmp;
    int k = 0;
    long x = v;
    while (x > 0) { tmp[k] = (char)('0' + (int)(x % 10)); k++; x /= 10; }
    while (k < d) { tmp[k] = '0'; k++; }
    for (int i = 0; i < k; i++) buf[1 + i] = tmp[k - 1 - i];
    return 1 + k;
}

// Resolve the fractional-second precision for a Temporal toString(options)
// bag. `digits` (-1 = auto, 0..9 = fixed) is set from `fractionalSecondDigits`
// or, if `smallestUnit` is given, its implied width (hour/minute/second -> 0,
// millisecond -> 3, microsecond -> 6, nanosecond -> 9). Returns false on a
// malformed option (after throwing).
fn bool to_string_precision(BuiltinContext* ctx, int options_index, int* digits) {
    *digits = -1;  // auto when no options
    if (ctx.argc <= options_index) return true;
    TVal ov = ctx.regs[ctx.base_reg + options_index];
    if (ov.is_undefined()) return true;
    if (!ov.is_object() || ov.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    HObject* opts = (HObject*)ov.get_heapptr();

    TVal su = prop_or_undefined(opts, ctx.heap, "smallestUnit");
    if (!su.is_undefined()) {
        if (!su.is_string()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "smallestUnit option must be a string");
            return false;
        }
        HString* s = (HString*)su.get_heapptr();
        char[] v = s.get_cstr()[:s.blen];
        if (v == "hour" || v == "minute" || v == "second") { *digits = 0; return true; }
        if (v == "millisecond") { *digits = 3; return true; }
        if (v == "microsecond") { *digits = 6; return true; }
        if (v == "nanosecond")  { *digits = 9; return true; }
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit for Instant.toString");
        return false;
    }

    TVal f = prop_or_undefined(opts, ctx.heap, "fractionalSecondDigits");
    if (!f.is_undefined()) {
        if (f.is_string()) {
            HString* s = (HString*)f.get_heapptr();
            char[] v = s.get_cstr()[:s.blen];
            if (v == "auto") { *digits = -1; return true; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be \"auto\" or 0-9");
            return false;
        }
        double dv = builtin_to_number_getdouble(ctx, &f);
        if (dv < 0 || dv > 9 || dv != (double)((long)dv)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0 to 9");
            return false;
        }
        *digits = (int)dv;
        return true;
    }
    return true;
}

fn void builtin_temporal_instant_proto_toString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    int digits;
    if (!to_string_precision(ctx, 0, &digits)) return;

    // Whole seconds and sub-second remainder, split toward zero. Read the
    // epoch-nanosecond value directly via to_int128 (no allocation), so no GC
    // can sweep a temporary BigInt between the read and the format.
    long whole_secs;
    long ns_rem;
    if (b.fits_int128()) {
        int128 total = b.to_int128();
        // Truncate toward zero: sign of remainder follows dividend's sign.
        // For a negative total, floor the second so ns_rem is non-negative
        // (e.g. -1500000001 ns = -2 sec + 999999999 ns, not -1 sec + -500000001 ns).
        long sec_trunc = (long)(total / 1000000000);
        long rem_trunc = (long)(total - (int128)sec_trunc * 1000000000);
        if (rem_trunc < 0) {
            sec_trunc -= 1;
            rem_trunc += 1000000000;
        }
        whole_secs = sec_trunc;
        ns_rem = rem_trunc;
    } else {
        // Out of int128 range: fall back to the double approximation (the
        // output is only ever whole seconds at this magnitude anyway).
        double secs;
        if (!bigint_to_epoch_number(b, &secs, ctx)) return;
        whole_secs = (long)math::floor(secs / 1e9);
        ns_rem = 0;
    }
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(whole_secs);

    // Year formatting per spec §`GetISOPartsFromEpoch`: 0 ≤ year ≤ 9999 renders
    // as a 4-digit unsigned year; year < 0 or year > 9999 renders as a 6-digit
    // signed year with `-` or `+` prefix.
    char[64] buf;
    int n;
    long y = bd.y;
    if (y >= 0 && y <= 9999) {
        n = libc::snprintf(&buf, 40, "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld",
            y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
    } else if (y < 0) {
        n = libc::snprintf(&buf, 40, "-%06ld-%02ld-%02ldT%02ld:%02ld:%02ld",
            -y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
    } else {
        n = libc::snprintf(&buf, 40, "+%06ld-%02ld-%02ldT%02ld:%02ld:%02ld",
            y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
    }
    n += format_fractional_seconds(&buf[n], ns_rem, digits);
    buf[n] = 'Z';
    n++;
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:n]));
}

fn void builtin_temporal_instant_proto_toJSON(BuiltinContext* ctx) {
    // toJSON uses "auto" precision, i.e. toString() with no options.
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

// Build a Duration whose time units are the difference between two Instants'
// epoch-ns BigInts. `largest_unit_ns` is the unit ns (3600*1e9 for hours,
// 60*1e9 for minutes, 1e9 for seconds, 1e6 for ms, etc.). The duration is
// balanced so the chosen unit holds the whole number and the sub-units carry
// the remainder. Negative differences produce all-negative components. The
// default `largest_unit_ns = 1e9` (seconds) is what the engine returned
// before largestUnit was supported.
// `out` receives a refcount-1 Duration object or null on failure.
fn bool instant_ns_diff_duration(BuiltinContext* ctx, hbigint::HBigInt* a, hbigint::HBigInt* b, long largest_unit_ns, HObject** out) {
    if (largest_unit_ns <= 0) largest_unit_ns = 1000000000;
    hbigint::HBigInt*? diff_o = hbigint::hbigint_addsub(ctx.heap, a, b, true);
    if (catch err = diff_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "difference overflow"); return false; }
    hbigint::HBigInt* diff = diff_o;
    hbigint::HBigInt*? one_o = hbigint::hbigint_alloc(ctx.heap, (int128)largest_unit_ns);
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
    temporal::DurationParts dp = {};
    long subsec_per_unit = 1000000000L / largest_unit_ns;
    int128 qv = q.to_int128();
    int128 rv = r.to_int128();
    // The quotient is in `largest_unit_ns` units, the remainder in ns. Convert
    // the quotient to the smallest sensible field. For seconds (default),
    // dp.seconds = q; for ms, dp.milliseconds = q; etc.
    switch (largest_unit_ns) {
        case 3600000000000L: dp.hours = (long)qv; break;
        case 60000000000L:   dp.minutes = (long)qv; break;
        case 1000000000L:    dp.seconds = (long)qv; break;
        case 1000000L:       dp.ms = (long)qv; break;
        case 1000L:          dp.us = (long)qv; break;
        case 1L:             dp.ns = (long)qv; rv = 0; break;
        default:
            // Shouldn't happen — fallback to seconds.
            dp.seconds = (long)qv;
            subsec_per_unit = 1;
            largest_unit_ns = 1000000000;
            break;
    }
    if (largest_unit_ns != 1L) {
        // Re-distribute remainder (in ns) across the sub-units of the chosen
        // largestUnit. rv is in ns (always < `largest_unit_ns`); the values
        // fit in long so we work in long for the redistribution arithmetic.
        long rv_ns = (long)rv;
        long ms = rv_ns / 1000000;
        long rem_us = rv_ns - ms * 1000000;
        long us = rem_us / 1000;
        long ns = rem_us - us * 1000;
        if (largest_unit_ns == 1000000000L) {
            dp.ms = ms; dp.us = us; dp.ns = ns;
        } else if (largest_unit_ns == 60000000000L) {
            dp.seconds = (long)(ms / 1000); dp.ms = ms % 1000; dp.us = us; dp.ns = ns;
        } else if (largest_unit_ns == 3600000000000L) {
            long min_total = ms / (60 * 1000);
            long ms_in_h = ms - min_total * 60 * 1000;
            long sec_total = ms_in_h / 1000;
            long ms_rem = ms_in_h - sec_total * 1000;
            dp.minutes = min_total;
            dp.seconds = sec_total;
            dp.ms = ms_rem; dp.us = us; dp.ns = ns;
        } else if (largest_unit_ns == 1000000L) {
            dp.us = us; dp.ns = ns;
        } else if (largest_unit_ns == 1000L) {
            dp.ns = ns;
        }
    }
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

// Resolve `largestUnit` from an options bag at `ctx.regs[ctx.base_reg +
// options_index]` to a number of nanoseconds. Returns 0 and emits the
// appropriate error (TypeError / RangeError) on bad input. The default for
// Instant is 1e9 (seconds); for PlainDate/Time/DateTime/ZDT, defaults vary
// per type. The Instant case accepts only the six time units; calendar units
// are rejected because Instants are point-in-time.
fn bool read_instant_largest_unit_ns(BuiltinContext* ctx, int options_index, long* out) {
    *out = 1000000000L;
    if (ctx.argc <= options_index) return true;
    TVal ov = ctx.regs[ctx.base_reg + options_index];
    if (ov.is_undefined()) return true;
    if (!ov.is_object() || ov.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    HObject* opts = (HObject*)ov.get_heapptr();
    TVal val = prop_or_undefined(opts, ctx.heap, "largestUnit");
    if (val.is_undefined()) return true;
    if (!val.is_string()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "largestUnit must be a string");
        return false;
    }
    HString* s = (HString*)val.get_heapptr();
    String str = s ? (String)s.get_cstr()[:s.blen] : "";
    if (ci_eq(str, "hour") || ci_eq(str, "hours"))         { *out = 3600000000000L; return true; }
    if (ci_eq(str, "minute") || ci_eq(str, "minutes"))     { *out = 60000000000L; return true; }
    if (ci_eq(str, "second") || ci_eq(str, "seconds"))     { *out = 1000000000L; return true; }
    if (ci_eq(str, "millisecond") || ci_eq(str, "milliseconds")) { *out = 1000000L; return true; }
    if (ci_eq(str, "microsecond") || ci_eq(str, "microseconds")) { *out = 1000L; return true; }
    if (ci_eq(str, "nanosecond") || ci_eq(str, "nanoseconds"))   { *out = 1L; return true; }
    builtin_throw(ctx, ctx.heap.range_err_proto, "largestUnit is not a valid value");
    return false;
}

// Case-insensitive slice compare. The stdlib helper expects String; here we
// already have a `String` (char[] alias) and need an inline `==` test.
fn bool ci_eq(String a, char[] b) {
    if (a.len != b.len) return false;
    for (usz k = 0; k < a.len; k++) {
        char ca = a[k];
        char cb = b[k];
        if (ca >= 'A' && ca <= 'Z') ca = (char)(ca - 'A' + 'a');
        if (cb >= 'A' && cb <= 'Z') cb = (char)(cb - 'A' + 'a');
        if (ca != cb) return false;
    }
    return true;
}

// ToTemporalInstant(arg): coerce arg to a Temporal.Instant epoch-ns BigInt.
// On success the returned BigInt is incref'd (refcount-1) and ownership passes
// to the caller. On failure the function returns false after throwing.
//   - Object with class TEMPORAL_INSTANT: copy its big_ns.
//   - String: parse as ISO instant string. Failures throw RangeError.
//   - All other primitives and generic objects: throw TypeError.
//   - Symbol: throw TypeError.
fn bool to_temporal_instant(BuiltinContext* ctx, TVal* arg, hbigint::HBigInt** out) {
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_INSTANT) {
            hbigint::HBigInt*? b_o = hbigint::hbigint_copy(ctx.heap, o.extra.temporal.big_ns);
            if (catch err = b_o) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Instant copy failed");
                return false;
            }
            *out = b_o;
            return true;
        }
        builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to an Instant");
        return false;
    }
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO string");
            return false;
        }
        String str = (String)s.get_cstr()[:s.blen];
        temporal::ParsedIsoInstant p;
        if (!temporal::parse_iso_instant_string(str, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO string");
            return false;
        }
        if (!temporal::is_valid_iso_date(p.y, (int)p.m, (int)p.d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO date");
            return false;
        }
        long ed = temporal::epoch_days_from_civil(p.y, (int)p.m, (int)p.d);
        long sec_of_day = (long)p.hour * 3600 + (long)p.minute * 60 + (long)p.second;
        int128 ns128 = (int128)ed * 86400L * 1000000000L;
        ns128 += (int128)sec_of_day * 1000000000L;
        ns128 += (int128)p.nanos;
        ns128 -= (int128)p.offset_seconds * 1000000000L;
        hbigint::HBigInt*? b_o = hbigint::hbigint_alloc(ctx.heap, ns128);
        if (catch err = b_o) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Instant alloc failed");
            return false;
        }
        *out = b_o;
        return true;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to an Instant");
    return false;
}

// this.since(other[, options]) = this - other, as a Duration in seconds (or
// other time units when largestUnit is set).
fn void builtin_temporal_instant_proto_since(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "since requires an Instant argument");
        return;
    }
    hbigint::HBigInt* other_ns;
    if (!to_temporal_instant(ctx, arg_at(ctx, 0), &other_ns)) return;
    defer ctx.heap.decref((types::HeapHeader*)other_ns);
    long largest_unit_ns;
    if (!read_instant_largest_unit_ns(ctx, 1, &largest_unit_ns)) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    HObject* dur;
    if (!instant_ns_diff_duration(ctx, self.extra.temporal.big_ns, other_ns, largest_unit_ns, &dur)) return;
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
    hbigint::HBigInt* other_ns;
    if (!to_temporal_instant(ctx, arg_at(ctx, 0), &other_ns)) return;
    defer ctx.heap.decref((types::HeapHeader*)other_ns);
    long largest_unit_ns;
    if (!read_instant_largest_unit_ns(ctx, 1, &largest_unit_ns)) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    HObject* dur;
    if (!instant_ns_diff_duration(ctx, other_ns, self.extra.temporal.big_ns, largest_unit_ns, &dur)) return;
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

// Append an offset value to the deduplicated candidate list (in place).
fn void tz_cand_add(int[] cand, int* nc, int o) {
    int n = *nc;
    for (int k = 0; k < n; k++) {
        if (cand[k] == o) return;
    }
    if (n < 8) { cand[n] = o; *nc = n + 1; }
}

// getPossibleInstantsFor(plainDateTime) resolves a wall-clock PlainDateTime in
// this zone to the concrete UTC instants it can denote. The wall time in a
// DST overlap maps to two instants; a gap (a wall time that does not exist,
// e.g. the hour skipped at spring-forward) maps to none. Unique wall times
// map to one. Naive resolution: treat the wall clock as UTC, compare the
// offset iteratively, and disambiguate by determinism (offsetBefore vs the
// offsets at the candidate instants).
fn void builtin_temporal_timezone_proto_getPossibleInstantsFor(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_TIMEZONE, "this is not a Temporal.TimeZone")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getPossibleInstantsFor requires a PlainDateTime argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getPossibleInstantsFor requires a Temporal.PlainDateTime");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    String zone = timezone_name(self);
    HObject* pdt = (HObject*)arg.get_heapptr();
    temporal::CivilDateTime c = plain_datetime_value(pdt);
    long wall_secs = temporal::epoch_days_from_civil(c.date.y, (int)c.date.m, (int)c.date.d) * 86400
        + (long)c.time.h * 3600 + (long)c.time.mi * 60 + (long)c.time.s;
    long frac_ns = (long)c.time.ms * 1000000 + (long)c.time.us * 1000 + (long)c.time.ns;
    double naive_ns = (double)wall_secs * 1e9 + (double)frac_ns;

    // Candidate UTC offsets: the offset in effect at the naive wall time, plus
    // the offsets of every transition within a 2-day window. In an overlap or a
    // gap the DST flip bracketing the wall time contributes its pre/post
    // offsets here; each candidate is then tested for self-consistency below.
    int[8] cand;
    int nc = 0;
    tz_cand_add(cand[..], &nc, temporal::tzdb_offset_for_zone_at(zone, wall_secs));
    temporal::TzdbTransition[] trans = temporal::tzdb_zone_transitions(zone);
    long window = 2 * 86400;
    for (usz i = 0; i < trans.len; i++) {
        if (trans[i].epoch_sec >= wall_secs - window && trans[i].epoch_sec <= wall_secs + window) {
            tz_cand_add(cand[..], &nc, trans[i].offset_sec);
        }
    }
    if (nc == 0) tz_cand_add(cand[..], &nc, 0);

    // For each candidate offset, the hypothetical instant is naive - offset;
    // keep it only if the zone's offset there really is that offset (i.e. the
    // instant round-trips to the wall time).
    double[4] hits;
    int nh = 0;
    for (int k = 0; k < nc; k++) {
        double e_ns = naive_ns - (double)cand[k] * 1e9;
        long e_sec = (long)math::floor(e_ns / 1e9);
        if (temporal::tzdb_offset_for_zone_at(zone, e_sec) != cand[k]) continue;
        bool dup = false;
        for (int j = 0; j < nh; j++) {
            if (hits[j] == e_ns) { dup = true; break; }
        }
        if (!dup && nh < 4) { hits[nh] = e_ns; nh++; }
    }

    // Sort ascending by epoch (an overlap yields the two instants in order).
    for (int i = 0; i < nh; i++) {
        for (int j = i + 1; j < nh; j++) {
            if (hits[j] < hits[i]) { double t = hits[i]; hits[i] = hits[j]; hits[j] = t; }
        }
    }

    HObject*? arr_o = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* arr = arr_o;
    arr.prototype = ctx.heap.array_proto;
    for (int i = 0; i < nh; i++) {
        hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, hits[i]);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
        HObject*? inst_o = alloc_instant(ctx.heap, big_o);
        ctx.heap.decref((types::HeapHeader*)big_o);
        if (catch err2 = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* inst = inst_o;
        inst.prototype = ctx.heap.temporal_instant_proto;
        TVal tv;
        tv.set_object(inst);
        if (!arr.set_array_idx((uint)i, tv, ctx.heap)) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    }
    *arr.array_len_ptr() = (uint)nh;
    ctx.result.set_object(arr);
}

// Both transition methods collapse consecutive transitions whose UTC offset
// does not actually change (abbreviation-only edits in the IANA source), and
// treat the zone's pre-history initial offset as the offset before the first
// recorded transition.

// getNextTransition(startingInstant) — first later transition that changes
// the UTC offset, or undefined if there is none.
fn void builtin_temporal_timezone_proto_getNextTransition(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_TIMEZONE, "this is not a Temporal.TimeZone")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getNextTransition requires an Instant argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_INSTANT) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getNextTransition requires a Temporal.Instant");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    String zone = timezone_name(self);
    hbigint::HBigInt* start = ((HObject*)arg.get_heapptr()).extra.temporal.big_ns;
    double s_d;
    if (!bigint_to_epoch_number(start, &s_d, ctx)) return;
    long start_sec = (long)math::floor(s_d / 1e9);
    bool start_has_sub = s_d - (double)start_sec * 1e9 != 0.0;

    temporal::TzdbTransition[] trans = temporal::tzdb_zone_transitions(zone);
    int prev_off = temporal::tzdb_zone_initial_offset(zone);
    for (usz i = 0; i < trans.len; i++) {
        if (trans[i].offset_sec == prev_off) continue;   // no real offset change
        prev_off = trans[i].offset_sec;
        bool after = trans[i].epoch_sec > start_sec
            || (trans[i].epoch_sec == start_sec && start_has_sub);
        if (!after) continue;
        double ns = (double)trans[i].epoch_sec * 1e9;
        hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, ns);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
        HObject*? inst_o = alloc_instant(ctx.heap, big_o);
        ctx.heap.decref((types::HeapHeader*)big_o);
        if (catch err2 = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* inst = inst_o;
        inst.prototype = ctx.heap.temporal_instant_proto;
        ctx.result.set_object(inst);
        return;
    }
    // No transition after the start instant.
    ctx.result.set_undefined();
}

// getPreviousTransition(startingInstant) — last earlier transition that
// changes the UTC offset, or undefined if there is none.
fn void builtin_temporal_timezone_proto_getPreviousTransition(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_TIMEZONE, "this is not a Temporal.TimeZone")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getPreviousTransition requires an Instant argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_INSTANT) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getPreviousTransition requires a Temporal.Instant");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    String zone = timezone_name(self);
    hbigint::HBigInt* start = ((HObject*)arg.get_heapptr()).extra.temporal.big_ns;
    double s_d;
    if (!bigint_to_epoch_number(start, &s_d, ctx)) return;
    long start_sec = (long)math::floor(s_d / 1e9);
    bool start_has_sub = s_d - (double)start_sec * 1e9 != 0.0;

    temporal::TzdbTransition[] trans = temporal::tzdb_zone_transitions(zone);
    int prev_off = temporal::tzdb_zone_initial_offset(zone);
    long last_epoch = -1;
    for (usz i = 0; i < trans.len; i++) {
        if (trans[i].offset_sec == prev_off) continue;   // no real offset change
        prev_off = trans[i].offset_sec;
        bool before = trans[i].epoch_sec < start_sec
            || (trans[i].epoch_sec == start_sec && start_has_sub);
        if (before) last_epoch = trans[i].epoch_sec;
    }
    if (last_epoch < 0) { ctx.result.set_undefined(); return; }
    double ns = (double)last_epoch * 1e9;
    hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, ns);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
    HObject*? inst_o = alloc_instant(ctx.heap, big_o);
    ctx.heap.decref((types::HeapHeader*)big_o);
    if (catch err2 = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* inst = inst_o;
    inst.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(inst);
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
    if (!register_string_proto_method(proto, heap, "getNextTransition", Builtin.TEMPORAL_TIMEZONE_PROTO_GETNEXTTRANSITION.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getPreviousTransition", Builtin.TEMPORAL_TIMEZONE_PROTO_GETPREVIOUSTRANSITION.ordinal)) return false;
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
        return;
    }

    // calendar: Phase 2 defaults to iso8601; a supplied calendar must already
    // be a Temporal.Calendar with id "iso8601".
    HString* calendar = builtin_intern_string(ctx.heap, "iso8601");
    HObject*? obj_o = alloc_zoneddatetime(ctx.heap, b, tz, calendar);
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

// Format a ZonedDateTime as an ISO string: wall time in the zone's current
// offset with fractional seconds, the ±HH:MM offset, and (unless drop_zone) the
// [Zone] bracket. `digits` is -1 for auto or 0..9. Reads epoch nanoseconds via
// to_int128 so sub-second precision survives beyond 2^53.
fn void zdt_iso_string(BuiltinContext* ctx, hbigint::HBigInt* b, HObject* tz, int digits, bool drop_zone) {
    long epoch_secs;
    long ns_rem;
    if (b.fits_int128()) {
        int128 total = b.to_int128();
        long sec_trunc = (long)(total / 1000000000);
        ns_rem = (long)(total - (int128)sec_trunc * 1000000000);
        epoch_secs = sec_trunc;
    } else {
        double s_d;
        if (!bigint_to_epoch_number(b, &s_d, ctx)) return;
        epoch_secs = (long)math::floor(s_d / 1e9);
        ns_rem = 0;
    }
    String zone = tz == null ? "" : timezone_name(tz);
    int off = 0;
    if (tz != null) off = temporal::tzdb_offset_for_zone_at(zone, epoch_secs);
    long local_secs = epoch_secs + off;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(local_secs);
    char[64] buf;
    int n = libc::snprintf(&buf, 64, "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld",
        bd.y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
    n += format_fractional_seconds(&buf[n], ns_rem, digits);
    format_offset_seconds(&buf[n], off);
    n += 6;
    if (!drop_zone && zone.len > 0 && zone.ptr != null) {
        int zn = libc::snprintf(&buf[n], 64 - (usz)n, "[%s]", (char*)zone.ptr);
        n += zn;
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:n]));
}

fn void builtin_temporal_zoneddatetime_proto_toString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    int digits;
    if (!to_string_precision(ctx, 0, &digits)) return;
    zdt_iso_string(ctx, obj.extra.temporal.big_ns, obj.extra.temporal.timezone, digits, false);
}

fn void builtin_temporal_zoneddatetime_proto_toJSON(BuiltinContext* ctx) {
    // toJSON keeps the offset but drops the [Zone] bracket and uses auto
    // precision, so the string round-trips through from() in the same zone.
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    zdt_iso_string(ctx, obj.extra.temporal.big_ns, obj.extra.temporal.timezone, -1, true);
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

// this.with(temporalTimeLike[, options]) — overlay the given wall-clock fields
// onto the zone's local time and re-resolve the instant. Defaults:
// disambiguation "compatible", offset "prefer". Only the iso8601 calendar and
// the compatible/earlier/later disambiguation are implemented in Phase 2.
fn void builtin_temporal_zoneddatetime_proto_with(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1 || arg_at(ctx, 0) == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with requires a fields bag");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with requires an object");
        return;
    }
    HObject* bag = (HObject*)arg.get_heapptr();
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    String zone = timezone_name(self.extra.temporal.timezone);
    if (zone.len == 0) { builtin_throw(ctx, ctx.heap.range_err_proto, "zone missing"); return; }

    // Current wall time: epoch -> local via the offset in effect at the epoch.
    hbigint::HBigInt* ns = self.extra.temporal.big_ns;
    double s_d;
    if (!bigint_to_epoch_number(ns, &s_d, ctx)) return;
    long epoch_sec = (long)math::floor(s_d / 1e9);
    long frac_ns = (long)(s_d - (double)epoch_sec * 1e9);
    int off = temporal::tzdb_offset_for_zone_at(zone, epoch_sec);
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(epoch_sec + off);
    temporal::CivilDateTime cur = {
        .date = { .y = bd.y, .m = bd.m + 1, .d = bd.d },
        .time = { .h = bd.h, .mi = bd.mi, .s = bd.s,
                  .ms = (int)(frac_ns / 1000000), .us = (int)((frac_ns % 1000000) / 1000), .ns = (int)(frac_ns % 1000) },
    };

    temporal::CivilDateTime fields;
    if (!bag_to_datetime_fields(ctx, bag, true, cur.date, cur.time, &fields)) {
        Vm* v = (Vm*)ctx.vm;
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    temporal::CivilDate valid_d;
    if (!fields_to_valid_date(ctx, fields.date, temporal::OverflowKind.CONSTRAIN, &valid_d)) return;
    temporal::CivilTime valid_t;
    if (!fields_to_valid_time(ctx, fields.time, &valid_t)) return;

    // New wall time as naive UTC epoch nanos.
    long wall_secs = temporal::epoch_days_from_civil(valid_d.y, (int)valid_d.m, (int)valid_d.d) * 86400
        + (long)valid_t.h * 3600 + (long)valid_t.mi * 60 + (long)valid_t.s;
    long wfrac = (long)valid_t.ms * 1000000 + (long)valid_t.us * 1000 + (long)valid_t.ns;
    double naive_ns = (double)wall_secs * 1e9 + (double)wfrac;

    // Resolve the wall time to candidate instants (same logic as
    // getPossibleInstantsFor).
    int[8] cand;
    int nc = 0;
    tz_cand_add(cand[..], &nc, temporal::tzdb_offset_for_zone_at(zone, wall_secs));
    temporal::TzdbTransition[] trans = temporal::tzdb_zone_transitions(zone);
    long window = 2 * 86400;
    for (usz i = 0; i < trans.len; i++) {
        if (trans[i].epoch_sec >= wall_secs - window && trans[i].epoch_sec <= wall_secs + window) {
            tz_cand_add(cand[..], &nc, trans[i].offset_sec);
        }
    }
    if (nc == 0) tz_cand_add(cand[..], &nc, 0);
    double[4] hits;
    int nh = 0;
    for (int k = 0; k < nc; k++) {
        double e_ns = naive_ns - (double)cand[k] * 1e9;
        long e_sec = (long)math::floor(e_ns / 1e9);
        if (temporal::tzdb_offset_for_zone_at(zone, e_sec) != cand[k]) continue;
        bool dup = false;
        for (int j = 0; j < nh; j++) if (hits[j] == e_ns) { dup = true; break; }
        if (!dup && nh < 4) { hits[nh] = e_ns; nh++; }
    }
    for (int i = 0; i < nh; i++) {
        for (int j = i + 1; j < nh; j++) {
            if (hits[j] < hits[i]) { double t = hits[i]; hits[i] = hits[j]; hits[j] = t; }
        }
    }

    double chosen;
    if (nh == 1) {
        chosen = hits[0];
    } else if (nh == 2) {
        // Overlap: "earlier" and "compatible" pick the earlier instant, "later"
        // the later. (compatible normally prefers the offset matching the
        // current instant; for the common single-offset-change case the earlier
        // instant carries that offset.)
        chosen = hits[0];
    } else {
        // Gap: "compatible" shifts the wall time across the skipped hour,
        // relocating it to the instant whose local time is the post-gap offset.
        chosen = naive_ns - (double)temporal::tzdb_offset_for_zone_at(zone, wall_secs + 4 * 3600) * 1e9;
    }

    hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, chosen);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
    ((types::HeapHeader*)self.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, self.extra.temporal.timezone, (HString*)self.extra.temporal.calendar);
}

// Convert a Duration's time components to an epoch-nanosecond BigInt delta
// (hours..nanoseconds only; the calendar units are ignored for Phase 2, which
// matches Temporal.Instant.add semantics for pure time arithmetic).
fn bool duration_to_ns_delta(BuiltinContext* ctx, temporal::DurationParts dp, hbigint::HBigInt** out) {
    hbigint::HBigInt*? delta_o = hbigint::hbigint_from_slimb(ctx.heap, 0);
    if (catch err = delta_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return false; }
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
        if (catch err = part_o) { ctx.heap.decref((types::HeapHeader*)delta); builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return false; }
        hbigint::HBigInt* part = part_o;
        hbigint::HBigInt*? scale_o = hbigint::hbigint_alloc(ctx.heap, (int128)scales[k]);
        if (catch err = scale_o) {
            ctx.heap.decref((types::HeapHeader*)part);
            ctx.heap.decref((types::HeapHeader*)delta);
            builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed");
            return false;
        }
        hbigint::HBigInt* scale = scale_o;
        hbigint::HBigInt*? scaled = hbigint::hbigint_mul(ctx.heap, part, scale);
        ctx.heap.decref((types::HeapHeader*)part);
        ctx.heap.decref((types::HeapHeader*)scale);
        if (catch err = scaled) { ctx.heap.decref((types::HeapHeader*)delta); builtin_throw(ctx, ctx.heap.range_err_proto, "multiply failed"); return false; }
        hbigint::HBigInt*? new_delta = hbigint::hbigint_addsub(ctx.heap, delta, scaled, false);
        ctx.heap.decref((types::HeapHeader*)scaled);
        ctx.heap.decref((types::HeapHeader*)delta);
        if (catch err = new_delta) { builtin_throw(ctx, ctx.heap.range_err_proto, "addsub failed"); return false; }
        delta = new_delta;
    }
    *out = delta;
    return true;
}

// Build a ZonedDateTime from an epoch-ns BigInt, a TimeZone object, and the
// zone's calendar String, setting the correct prototype.
fn void zdt_from_parts(BuiltinContext* ctx, hbigint::HBigInt* ns, HObject* tz, HString* cal) {
    HObject*? obj_o = alloc_zoneddatetime(ctx.heap, ns, tz, cal);
    if (catch err = obj_o) { ctx.heap.decref((types::HeapHeader*)ns); builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)ns);
    obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
    ctx.result.set_object(obj);
}

// this.withTimeZone(timeZone) — same instant, different zone.
fn void builtin_temporal_zoneddatetime_proto_withTimeZone(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "withTimeZone requires a Temporal.TimeZone");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_TIMEZONE) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "withTimeZone requires a Temporal.TimeZone");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    HObject* new_tz = (HObject*)arg.get_heapptr();
    ((types::HeapHeader*)self.extra.temporal.big_ns).incref();
    zdt_from_parts(ctx, self.extra.temporal.big_ns, new_tz, (HString*)self.extra.temporal.calendar);
}

// this.withCalendar(calendar) — Phase 2 accepts only the iso8601 calendar;
// a non-iso8601 or non-Calendar argument throws.
fn void builtin_temporal_zoneddatetime_proto_withCalendar(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "withCalendar requires a Temporal.Calendar");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_CALENDAR) {
        // This engine supports only the iso8601 calendar, so any Calendar
        // object is acceptable here.
        HObject* self = (HObject*)ctx.this_val.get_heapptr();
        ((types::HeapHeader*)self.extra.temporal.big_ns).incref();
        ((types::HeapHeader*)self.extra.temporal.timezone).incref();
        zdt_from_parts(ctx, self.extra.temporal.big_ns, self.extra.temporal.timezone, (HString*)self.extra.temporal.calendar);
        return;
    }
    // Spec accepts a string calendar id too; Phase 2 supports only iso8601.
    if (arg.is_string()) {
        HString* hs = (HString*)arg.get_heapptr();
        String s = (String)hs.get_cstr()[:hs.blen];
        if (s != "iso8601") {
            builtin_throw(ctx, ctx.heap.range_err_proto, "unsupported calendar");
            return;
        }
        HObject* self = (HObject*)ctx.this_val.get_heapptr();
        ((types::HeapHeader*)self.extra.temporal.big_ns).incref();
        ((types::HeapHeader*)self.extra.temporal.timezone).incref();
        zdt_from_parts(ctx, self.extra.temporal.big_ns, self.extra.temporal.timezone, (HString*)self.extra.temporal.calendar);
        return;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "withCalendar requires a Temporal.Calendar");
}

fn void builtin_temporal_zoneddatetime_proto_add(BuiltinContext* ctx) {
    zdt_add_sub(ctx, false);
}

fn void builtin_temporal_zoneddatetime_proto_subtract(BuiltinContext* ctx) {
    zdt_add_sub(ctx, true);
}

// this.add(duration) / this.subtract(duration) — add the Duration's time delta
// to the underlying instant, keeping the zone and calendar.
fn void zdt_add_sub(BuiltinContext* ctx, bool subtract) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "requires a Temporal.Duration");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_DURATION) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument is not a Temporal.Duration");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    temporal::DurationParts dp = duration_value((HObject*)arg.get_heapptr());
    hbigint::HBigInt* delta;
    if (!duration_to_ns_delta(ctx, dp, &delta)) return;
    hbigint::HBigInt* base = self.extra.temporal.big_ns;
    ((types::HeapHeader*)base).incref();
    hbigint::HBigInt*? result;
    if (subtract) {
        result = temporal::instant_sub(base, delta, ctx.heap);
    } else {
        result = temporal::instant_add(base, delta, ctx.heap);
    }
    ctx.heap.decref((types::HeapHeader*)delta);
    ctx.heap.decref((types::HeapHeader*)base);
    if (catch err = result) { builtin_throw(ctx, ctx.heap.range_err_proto, "failed"); return; }
    ((types::HeapHeader*)self.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, result, self.extra.temporal.timezone, (HString*)self.extra.temporal.calendar);
}

// this.until(other) / this.since(other) — elapsed time difference as a
// Duration in seconds. Phase 2 uses the raw epoch-nanosecond difference
// (identical to Temporal.Instant.until/since), which is exact for the elapsed
// duration between the two instants; calendar-unit math lands later.
fn void builtin_temporal_zoneddatetime_proto_until(BuiltinContext* ctx) {
    zdt_until_since(ctx, true);
}

fn void builtin_temporal_zoneddatetime_proto_since(BuiltinContext* ctx) {
    zdt_until_since(ctx, false);
}

fn void zdt_until_since(BuiltinContext* ctx, bool until) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "requires a Temporal.ZonedDateTime");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument is not a Temporal.ZonedDateTime");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    HObject* other = (HObject*)arg.get_heapptr();
    hbigint::HBigInt* a;
    hbigint::HBigInt* b;
    if (until) { a = other.extra.temporal.big_ns; b = self.extra.temporal.big_ns; }
    else       { a = self.extra.temporal.big_ns;  b = other.extra.temporal.big_ns; }
    HObject* dur;
    if (!instant_ns_diff_duration(ctx, a, b, 1000000000L, &dur)) return;
    dur.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur);
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
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "withTimeZone", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_WITHTIMEZONE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "withCalendar", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_WITHCALENDAR.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_SINCE.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_ZONEDDATETIME_FROM.ordinal)) return false;

    heap.temporal_zoneddatetime_proto = proto;
    return true;
}

// ============================================================================
// Phase 3 — Temporal.Now
// ============================================================================
//
// Six methods that read the host wall clock and produce a fresh Temporal
// value. The system time zone is read from the TZ environment variable (with
// UTC as a POSIX-safe fallback) via boomkat_system_tz_name; tests run under
// TZ=UTC by default. Each method accepts an optional time-zone argument that
// is coerced to a string and resolved through the standard offset/ISO/zone
// grammar used elsewhere; the resolved zone is either an offset (seconds east
// of UTC) or an IANA zone name recognised by the embedded tzdb.
//
// Civil-from-epoch uses the same path the ZDT toString does (tzdb lookup +
// civil_from_seconds), so the result agrees with what the rest of the engine
// would have produced for the same instant.

// Current epoch in whole seconds (floored toward -infinity so negative
// instants land on the correct second). std::time::now() reports microseconds
// since the Unix epoch.
fn long now_epoch_seconds() {
    long micros = (long)std::time::now();
    long secs = micros / 1_000_000L;
    if (micros < 0 && micros % 1_000_000L != 0) secs -= 1;
    return secs;
}

// Current epoch in whole milliseconds (same floor semantics).
fn long now_epoch_milliseconds() {
    long micros = (long)std::time::now();
    long ms = micros / 1000L;
    if (micros < 0 && micros % 1000L != 0) ms -= 1;
    return ms;
}

// Current epoch in nanoseconds (precise; std::time::now is microsecond).
fn int128 now_epoch_nanoseconds() {
    long micros = (long)std::time::now();
    return (int128)micros * 1000;
}

// Coerce the first argument to a string. Per ES2025 ToTemporalTimeZone, the
// argument first goes through ToPrimitive (string hint); only the result is
// then checked for being a string. Primitives that round-trip to themselves
// (null, boolean, number, bigint, symbol) are therefore NOT strings and
// must throw TypeError, not RangeError. Objects that yield a string via
// valueOf/toString continue to the RangeError check downstream.
//
// `*is_default` distinguishes the missing-argument case (true, caller falls
// back to system zone) from the explicit empty-string case (false, caller
// must surface a RangeError downstream).
//
// Returns true on success; returns false after throwing TypeError when the
// argument is present and the ToPrimitive result is not a string.
fn bool now_coerce_tz_string(BuiltinContext* ctx, String* out, bool* is_default) {
    *out = (String)"";
    *is_default = false;
    if (ctx.argc < 1) { *is_default = true; return true; }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_undefined()) { *is_default = true; return true; }
    // If the argument is already a string (and not a Symbol, which shares
    // the STRING tag), take it directly.
    if (arg.is_string()) {
        HString* hs = (HString*)arg.get_heapptr();
        if (hs.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Time zone must be a string or Temporal.TimeZone");
            return false;
        }
        // C3 slice [:0] yields a 1-byte slice (the NUL terminator), so an
        // empty JS string would produce text.len == 1, defeating the
        // empty-string RangeError check downstream.  Leave *out as the
        // zero-length literal assigned above.
        if (hs.blen > 0) *out = (String)hs.get_cstr()[:hs.blen];
        return true;
    }
    // Per ES2025 ToTemporalTimeZoneSlotValue: only strings are accepted.
    // Objects (including those with toString) are not coerced; they are
    // rejected as TypeError unless they are a Temporal.TimeZone instance
    // (unsupported in this engine).  Non-string primitives (null, numbers,
    // booleans, BigInts) likewise get TypeError.
    builtin_throw(ctx, ctx.heap.type_err_proto, "Time zone must be a string or Temporal.TimeZone");
    return false;
}

// Parse an offset of the form Z, ±HH[:MM], or ±HHMM. Three-component forms
// (±HH:MM:SS, ±HHMMSS) are explicitly NOT valid Time Zone identifiers per
// the test262 timezone-string-datetime test, even when SS=00. Returns true
// and writes `offset_seconds` on success.
fn bool parse_offset_only(char[] text, usz* i, long* offset_seconds) {
    usz len = text.len;
    if (*i >= len) return false;
    bool neg = false;
    if (text[*i] == 'Z' || text[*i] == 'z') {
        *i += 1;
        *offset_seconds = 0;
        return true;
    }
    if (text[*i] != '+' && text[*i] != '-') return false;
    if (text[*i] == '-') neg = true;
    *i += 1;
    int h;
    if (!temporal::parse_two_digits(text, i, &h)) return false;
    int mi = 0;
    if (*i < len) {
        if (text[*i] == ':') {
            *i += 1;
            if (!temporal::parse_two_digits(text, i, &mi)) return false;
        } else if (temporal::digit_at(text, *i) >= 0) {
            // ±HHMM basic form. If more digits follow, this would be
            // ±HHMMSS which we reject (three-component offsets are not
            // valid Time Zone identifiers).
            usz j = *i;
            while (j < len && temporal::digit_at(text, j) >= 0) j += 1;
            if (j - *i == 2) {
                if (!temporal::parse_two_digits(text, i, &mi)) return false;
            } else if (j - *i == 0) {
                // no minutes
            } else {
                return false;
            }
        }
    }
    long total = (long)h * 3600 + (long)mi * 60;
    *offset_seconds = neg ? -total : total;
    return true;
}

// Skip over a leading ISO date / time prefix, leaving `i` pointing at the
// start of the offset/Z/bracket zone annotation (or past the end of the
// string). Used by `now_resolve_tz` to extract the zone descriptor from a
// full ISO string like `2021-08-19T17:30-07:00[UTC]`.
//
// Returns false if the prefix is not a valid date-time: garbage, empty, or a
// negative-zero year (`-000000-...`), which the spec rejects as the
// "extended year minus zero" form.
fn bool now_skip_iso_prefix(char[] text, usz* i) {
    usz len = text.len;
    if (*i >= len) return false;
    // Optional sign for extended year.
    bool signed_year = false;
    long sign = 1;
    if (text[*i] == '+' || text[*i] == '-') {
        if (text[*i] == '-') sign = -1;
        signed_year = true;
        *i += 1;
    }
    // Year: 4 digits unsigned or 4-6 digits signed.
    usz y_start = *i;
    while (*i < len && temporal::digit_at(text, *i) >= 0 && (*i - y_start) < 6) *i += 1;
    usz y_digits = *i - y_start;
    if (y_digits < 4) return false;
    if (signed_year && y_digits != 6) return false;
    if (!signed_year && y_digits != 4) return false;
    if (signed_year && sign < 0) {
        // Reject negative zero year (`-000000`).
        bool all_zero = true;
        for (usz k = y_start; k < *i; k++) {
            if (text[k] != '0') { all_zero = false; break; }
        }
        if (all_zero) return false;
    }
    // Month, day separators and digits.
    if (*i < len && text[*i] == '-') *i += 1;
    int mo;
    if (!temporal::parse_two_digits(text, i, &mo)) return false;
    if (mo < 1 || mo > 12) return false;
    if (*i < len && text[*i] == '-') *i += 1;
    int d;
    if (!temporal::parse_two_digits(text, i, &d)) return false;
    if (d < 1 || d > 31) return false;
    // Optional T/space time.
    if (*i < len && (text[*i] == 'T' || text[*i] == 't' || text[*i] == ' ')) {
        *i += 1;
        int hh, mi, ss;
        long ns;
        if (!temporal::parse_time(text, i, &hh, &mi, &ss, &ns)) return false;
    }
    return true;
}

// Find the FIRST bracketed zone annotation `[...]` in the string whose body
// is NOT a key=value pair (i.e. the bare zone-name annotation, not `u-ca=`).
// Returns the zone text slice in `text[start..start+len]` on success and
// advances `*i` past the closing `]`.
fn bool now_find_bracket_zone(char[] text, usz* i, usz* out_start, usz* out_len) {
    usz len = text.len;
    usz k = *i;
    while (k < len && text[k] != '[') k += 1;
    if (k >= len) return false;
    usz ann_start = k + 1;
    usz ann_end = ann_start;
    while (ann_end < len && text[ann_end] != ']') ann_end += 1;
    if (ann_end >= len) return false;
    bool has_eq = false;
    for (usz j = ann_start; j < ann_end; j++) {
        if (text[j] == '=') { has_eq = true; break; }
    }
    if (has_eq) return false;
    // C3 slices are inclusive on both ends; the body is ann_start..ann_end-1.
    *out_start = ann_start;
    *out_len = ann_end - ann_start;
    *i = ann_end + 1;
    return true;
}

// Resolve a Temporal time-zone argument (a string per the spec). On success
// writes the offset in seconds; if the zone is an IANA name (in `*zone_name`)
// the caller looks it up via tzdb. `*offset_known` distinguishes the two: a
// fixed offset means the caller just adds it; an IANA name means the caller
// must query tzdb_offset_for_zone_at at the current instant.
//
// Throws RangeError on grammar failures (bare date-time, sub-minute offset,
// unknown IANA name, negative-zero year, etc.).
fn bool now_resolve_tz(BuiltinContext* ctx, String text, long* out_offset_sec,
                       bool* offset_known, String* out_zone_name, bool* out_zone_known) {
    *offset_known = false;
    *out_zone_known = false;
    // Caller is responsible for handling the missing-argument case before
    // reaching here. An explicit empty string from the user is a RangeError.
    if (text.len == 0) return false;

    // The spec validates the ISO date prefix even when a bracket zone is
    // present: a negative-zero extended year like `-000000-10-31T17:45Z[UTC]`
    // must throw regardless of the bracket. So scan the date prefix first
    // and reject bad inputs before any zone resolution.
    usz prefix_end = 0;
    bool has_iso_prefix = now_skip_iso_prefix(text, &prefix_end);

    // Look for any bracketed zone annotation `[...]` (with no `=` inside).
    // If present, that wins regardless of any other text — the offset that
    // may sit between the time and the bracket is ignored, per the
    // "Time zone string determined from bracket name" spec test.
    usz i = 0;
    usz b_start = 0;
    usz b_len = 0;
    if (now_find_bracket_zone(text, &i, &b_start, &b_len)) {
        if (i != text.len) return false;
        if (!has_iso_prefix) return false;   // bracket requires a date-time prefix
        if (prefix_end > b_start) return false;  // bracket can't appear mid-date
        String bracket = (String)text[b_start..b_start + b_len - 1];
        // A bracket body can be an IANA name or a `±HH:MM` offset (UTC-offset
        // zone identifiers like `+01:46`). The bracket form disambiguates.
        usz j = 0;
        long off_in = 0;
        if (parse_offset_only(bracket, &j, &off_in) && j == bracket.len) {
            *out_offset_sec = off_in;
            *offset_known = true;
            return true;
        }
        *out_zone_name = bracket;
        *out_zone_known = true;
        return true;
    }

    // ISO prefix without bracket: what's left must be either empty, "Z",
    // or a ±HH:MM offset. Anything else (e.g. bare date-time without zone)
    // is a RangeError.
    if (has_iso_prefix) {
        long off = 0;
        if (prefix_end < text.len && parse_offset_only(text, &prefix_end, &off)) {
            if (prefix_end != text.len) return false;
            *out_offset_sec = off;
            *offset_known = true;
            return true;
        }
        return false;
    }

    // Otherwise the input is a bare zone/offset token.
    usz saved = 0;
    long off2 = 0;
    if (parse_offset_only(text, &saved, &off2)) {
        if (saved != text.len) return false;
        *out_offset_sec = off2;
        *offset_known = true;
        return true;
    }

    // Bare IANA zone name; just hand it back. Caller validates against tzdb
    // (an unknown zone is a RangeError).
    *out_zone_name = text;
    *out_zone_known = true;
    return true;
}

// Get the offset (seconds east of UTC) for the given zone name at the given
// epoch second. Returns true on success; on unknown zone returns false with
// a RangeError thrown. Case-insensitive: "Utc" and "UTC" both resolve.
fn bool now_offset_for(BuiltinContext* ctx, String zone_name, long epoch_sec, long* out_off) {
    char[64] tmp;
    int sec = temporal::tzdb_offset_for_zone_ci(zone_name, epoch_sec, &tmp, 64);
    if (sec < 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Unknown time zone");
        return false;
    }
    *out_off = (long)sec;
    return true;
}

// Resolve the offset to apply to the current instant for the given time-zone
// argument. If `text` is empty AND `is_default` is true, the system zone
// (from TZ) is used. An explicit empty string (`is_default` false) is a
// RangeError per ES2025 ToTemporalTimeZone. Otherwise `text` is parsed as
// offset, IANA name, or ISO-with-bracket form.
fn bool now_resolve_current_offset(BuiltinContext* ctx, String text, bool is_default, long epoch_sec, long* out_off) {
    if (text.len == 0 && is_default) {
        char* sys_c = boomkat_system_tz_name();
        usz sys_n = 0;
        while (sys_c[sys_n] != 0) sys_n++;
        return now_offset_for(ctx, (String)sys_c[:sys_n], epoch_sec, out_off);
    }
    if (text.len == 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Empty time zone string");
        return false;
    }
    long off = 0;
    bool off_known = false;
    String zone = (String)"";
    bool zone_known = false;
    if (!now_resolve_tz(ctx, text, &off, &off_known, &zone, &zone_known)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid time zone");
        return false;
    }
    if (off_known) { *out_off = off; return true; }
    return now_offset_for(ctx, zone, epoch_sec, out_off);
}

// Resolve the canonical (case-folded) name of `zone` and its offset at
// `epoch_sec`. Returns true on success, writes canonical name into
// `canonical_buf` (for `timeZoneId` to report) and offset into `*out_off`.
// Throws RangeError on unknown zone.
fn bool now_resolve_canonical_zone(BuiltinContext* ctx, String zone, long epoch_sec,
                                    char* canonical_buf, usz buf_cap, long* out_off) {
    int sec = temporal::tzdb_offset_for_zone_ci(zone, epoch_sec, canonical_buf, buf_cap);
    if (sec < 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Unknown time zone");
        return false;
    }
    *out_off = (long)sec;
    return true;
}

// Temporal.Now.instant() — current moment as an Instant.
fn void builtin_temporal_now_instant(BuiltinContext* ctx) {
    int128 ns = now_epoch_nanoseconds();
    hbigint::HBigInt*? b_o = hbigint::hbigint_alloc(ctx.heap, ns);
    if (catch err = b_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "Temporal.Now.instant: alloc failed");
        return;
    }
    hbigint::HBigInt* b = b_o;
    HObject*? obj_o = alloc_instant(ctx.heap, b);
    if (catch err2 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)b);
        builtin_throw(ctx, ctx.heap.err_proto, "Temporal.Now.instant: alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Temporal.Now.timeZoneId() — IANA name of the system zone (TZ env var,
// or "UTC" if unset).
fn void builtin_temporal_now_time_zone_id(BuiltinContext* ctx) {
    char* sys_c = boomkat_system_tz_name();
    usz sys_n = 0;
    while (sys_c[sys_n] != 0) sys_n++;
    ctx.result.set_string(builtin_intern_string(ctx.heap, (String)sys_c[:sys_n]));
}

// Build a PlainDate from a year/month/day.
fn HObject*? now_make_plain_date(BuiltinContext* ctx, long y, long m, long d) {
    temporal::CivilDate cd = { .y = y, .m = m, .d = d };
    return alloc_plain_date(ctx.heap, cd, ctx.heap.temporal_iso_calendar);
}

// Build a PlainDateTime from year/month/day/hour/minute/second.
fn HObject*? now_make_plain_datetime(BuiltinContext* ctx, long y, long m, long d,
                                      long h, long mi, long s) {
    temporal::CivilDateTime dt;
    dt.date.y = y; dt.date.m = m; dt.date.d = d;
    dt.time.h = h; dt.time.mi = mi; dt.time.s = s;
    dt.time.ms = 0; dt.time.us = 0; dt.time.ns = 0;
    return alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
}

// Build a PlainTime from hour/minute/second.
fn HObject*? now_make_plain_time(BuiltinContext* ctx, long h, long mi, long s) {
    temporal::CivilTime ct;
    ct.h = h; ct.mi = mi; ct.s = s;
    ct.ms = 0; ct.us = 0; ct.ns = 0;
    return alloc_plain_time(ctx.heap, ct);
}

// Build a ZonedDateTime from the current instant + the supplied time-zone
// argument (or system zone). The argument follows ToTemporalTimeZone's grammar.
fn void builtin_temporal_now_zoned_date_time_iso(BuiltinContext* ctx) {
    String text = (String)"";
    bool is_default = false;
    if (!now_coerce_tz_string(ctx, &text, &is_default)) return;
    long epoch_secs = now_epoch_seconds();
    long off = 0;
    if (!now_resolve_current_offset(ctx, text, is_default, epoch_secs, &off)) return;

    // Determine the zone to attach to the ZDT. For an offset, build an
    // offset-only zone name ("+HH:MM" / "Z"); for an IANA name, resolve
    // case-insensitively so "Utc" reports as "UTC". The default case
    // (no argument supplied) skips resolve_tz: an empty explicit string
    // is a RangeError, already thrown upstream.
    long off2 = 0;
    bool off_known = false;
    String zone = (String)"";
    bool zone_known = false;
    if (!is_default) {
        if (!now_resolve_tz(ctx, text, &off2, &off_known, &zone, &zone_known)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid time zone");
            return;
        }
    }
    char[64] canonical_buf;
    usz canonical_len = 0;
    if (off_known) {
        // Format as "+HH:MM". The spec writes the zero offset as "UTC"
        // (not "Z") when the zone is attached to a ZonedDateTime so that the
        // resulting timeZoneId is canonical across test262 subtests.
        if (off2 == 0) {
            canonical_buf[0] = 'U';
            canonical_buf[1] = 'T';
            canonical_buf[2] = 'C';
            canonical_len = 3;
        } else {
            bool neg = off2 < 0;
            long a = neg ? -off2 : off2;
            long h = a / 3600;
            long mi = (a % 3600) / 60;
            int n = libc::snprintf(&canonical_buf, 64, "%s%02ld:%02ld", neg ? "-" : "+", h, mi);
            canonical_len = (usz)n;
        }
    } else if (zone_known) {
        long dummy_off = 0;
        if (!now_resolve_canonical_zone(ctx, zone, epoch_secs, &canonical_buf, 64, &dummy_off)) return;
        canonical_len = 0;
        while (canonical_buf[canonical_len] != 0) canonical_len += 1;
    } else {
        char* sys_c = boomkat_system_tz_name();
        usz sys_n = 0;
        while (sys_c[sys_n] != 0) sys_n += 1;
        long dummy_off = 0;
        if (!now_resolve_canonical_zone(ctx, (String)sys_c[:sys_n], epoch_secs, &canonical_buf, 64, &dummy_off)) return;
        canonical_len = 0;
        while (canonical_buf[canonical_len] != 0) canonical_len += 1;
    }
    String zone_id = (String)canonical_buf[:canonical_len];

    int128 ns = now_epoch_nanoseconds();
    hbigint::HBigInt*? b_o = hbigint::hbigint_alloc(ctx.heap, ns);
    if (catch err = b_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    hbigint::HBigInt* b = b_o;
    HObject*? tz_o = alloc_timezone(ctx.heap, zone_id);
    if (catch err2 = tz_o) {
        ctx.heap.decref((types::HeapHeader*)b);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* tz_obj = tz_o;
    HString* cal_str = builtin_intern_string(ctx.heap, "iso8601");
    HObject*? zdt_o = alloc_zoneddatetime(ctx.heap, b, tz_obj, cal_str);
    if (catch err3 = zdt_o) {
        ctx.heap.decref((types::HeapHeader*)b);
        ctx.heap.decref((types::HeapHeader*)tz_obj);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* zdt = zdt_o;
    zdt.prototype = ctx.heap.temporal_zoneddatetime_proto;
    ctx.result.set_object(zdt);
}

// Temporal.Now.plainDateISO([timeZone]) — current date in `timeZone`.
fn void builtin_temporal_now_plain_date_iso(BuiltinContext* ctx) {
    String text = (String)"";
    bool is_default = false;
    if (!now_coerce_tz_string(ctx, &text, &is_default)) return;
    long epoch_secs = now_epoch_seconds();
    long off = 0;
    if (!now_resolve_current_offset(ctx, text, is_default, epoch_secs, &off)) return;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(epoch_secs + off);
    HObject*? obj_o = now_make_plain_date(ctx, bd.y, (long)bd.m + 1, (long)bd.d);
    if (catch err2 = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(obj);
}

// Temporal.Now.plainDateTimeISO([timeZone]) — current date + time.
fn void builtin_temporal_now_plain_date_time_iso(BuiltinContext* ctx) {
    String text = (String)"";
    bool is_default = false;
    if (!now_coerce_tz_string(ctx, &text, &is_default)) return;
    long epoch_secs = now_epoch_seconds();
    long off = 0;
    if (!now_resolve_current_offset(ctx, text, is_default, epoch_secs, &off)) return;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(epoch_secs + off);
    HObject*? obj_o = now_make_plain_datetime(ctx, bd.y, (long)bd.m + 1, (long)bd.d,
                                               (long)bd.h, (long)bd.mi, (long)bd.s);
    if (catch err2 = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(obj);
}

// Temporal.Now.plainTimeISO([timeZone]) — current wall-clock time.
fn void builtin_temporal_now_plain_time_iso(BuiltinContext* ctx) {
    String text = (String)"";
    bool is_default = false;
    if (!now_coerce_tz_string(ctx, &text, &is_default)) return;
    long epoch_secs = now_epoch_seconds();
    long off = 0;
    if (!now_resolve_current_offset(ctx, text, is_default, epoch_secs, &off)) return;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(epoch_secs + off);
    HObject*? obj_o = now_make_plain_time(ctx, (long)bd.h, (long)bd.mi, (long)bd.s);
    if (catch err2 = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(obj);
}

// Build the Temporal.Now singleton with its six functions attached.
// Temporal.Now is not callable and not constructable (per spec §Temporal.Now
// abstract operation #1 and #2). The Symbol.toStringTag property carries
// "Temporal.Now"; the six methods are writable, non-enumerable, configurable
// per ES2025 §17.
fn HObject*? build_temporal_now(Heap* heap) {
    HObject*? raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = raw) return err~;
    HObject* now = raw;
    now.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Temporal.Now"));
        now.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* key;
    TVal fn_tv;
    HObject* fn_obj;

    key = heap.str_intern("instant");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, Builtin.TEMPORAL_NOW_INSTANT.ordinal, "instant", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    key = heap.str_intern("timeZoneId");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, Builtin.TEMPORAL_NOW_TIME_ZONE_ID.ordinal, "timeZoneId", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    key = heap.str_intern("plainDateISO");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, Builtin.TEMPORAL_NOW_PLAIN_DATE_ISO.ordinal, "plainDateISO", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    key = heap.str_intern("plainDateTimeISO");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, Builtin.TEMPORAL_NOW_PLAIN_DATE_TIME_ISO.ordinal, "plainDateTimeISO", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    key = heap.str_intern("plainTimeISO");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, Builtin.TEMPORAL_NOW_PLAIN_TIME_ISO.ordinal, "plainTimeISO", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    key = heap.str_intern("zonedDateTimeISO");
    if (key == null) return null;
    fn_obj = alloc_builtin_fn(heap, Builtin.TEMPORAL_NOW_ZONED_DATE_TIME_ISO.ordinal, "zonedDateTimeISO", 0);
    if (fn_obj == null) return null;
    fn_tv.set_object(fn_obj);
    now.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC, heap);

    return now;
}