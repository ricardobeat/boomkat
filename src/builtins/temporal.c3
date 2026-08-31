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
    obj.extra.temporal.long_a = (long)(double)d.years;
    obj.extra.temporal.long_b = (long)(double)d.months;
    obj.extra.temporal.long_c = (long)(double)d.weeks;
    obj.extra.temporal.long_d = (long)(double)d.days;
    obj.extra.temporal.long_e = (long)(double)d.hours;
    obj.extra.temporal.long_f = (long)(double)d.minutes;
    obj.extra.temporal.long_g = (long)(double)d.seconds;
    obj.extra.temporal.long_h = (long)(double)d.ms;
    obj.extra.temporal.long_i = (long)(double)d.us;
    obj.extra.temporal.long_j = (long)(double)d.ns;
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
    // Non-Proxy path: walk the prototype chain honouring accessors, so a
    // property bag whose fields are getters (test262's propertyBagObserver,
    // and any ordinary `get years() {...}`) observes the [[Get]] and yields
    // the getter's return value rather than the raw accessor slot.
    hobject::PropLookupResult res = o.get_prop_or_accessor_proto(key, true, hp);
    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        return temporal_invoke_getter(o, res.acc.accessor_fn, ctx);
    } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        return res.data_val;
    }
    TVal undef; undef.set_undefined();
    return undef;
}

// Call a property-bag getter with the bag as `this`, propagating a throw
// into the surrounding JS try/catch via ctx.should_throw.
fn TVal temporal_invoke_getter(HObject* obj, TVal getter_fn, BuiltinContext* ctx) {
    TVal undef; undef.set_undefined();
    if (!getter_fn.is_object() || getter_fn.get_heapptr() == null) return undef;
    HObject* fn_obj = (HObject*)getter_fn.get_heapptr();
    if (!fn_obj.is_callable()) return undef;
    Heap* hp = ctx.heap;
    if (hp.call_fn == null || ctx.vm == null) return undef;
    TVal this_val; this_val.set_object(obj);
    TVal result = hp.call_fn(ctx.vm, getter_fn, null, 0, this_val);
    if (hp.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = hp.error_value;
        hp.has_error = false;
        hp.error_value.set_undefined();
        return undef;
    }
    return result;
}

// RejectObjectWithCalendarOrTimeZone: a fields bag passed to with() must be a
// plain object, never a Temporal object. This is checked by brand before any
// property is read, so a `calendar`/`timeZone` getter on the argument never
// runs (test262 calendar-temporal-object-throws asserts exactly that).
fn bool reject_temporal_object_bag(BuiltinContext* ctx, HObject* bag) {
    hobject::ObjClass c = bag.get_class();
    if (c == hobject::ObjClass.TEMPORAL_PLAIN_DATE ||
        c == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME ||
        c == hobject::ObjClass.TEMPORAL_PLAIN_TIME ||
        c == hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH ||
        c == hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY ||
        c == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a Temporal object as its fields bag");
        return false;
    }
    return true;
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
    // prop_or_undefined_pa goes through a Proxy's [[Get]] trap; the
    // order-of-operations tests in test262 wrap options in
    // TemporalHelpers.propertyBagObserver, a Proxy, and expect to see
    // `get options.overflow` in the log.
    TVal val = prop_or_undefined_pa(ctx, opts, "overflow");
    if (ctx.should_throw) return false;
    if (val.is_undefined()) return true;
    // Convert to string per GetOption step 9.a. Symbol throws TypeError
    // (ToString); primitives convert to invalid strings and RangeError below.
    // builtin_to_string_vm invokes @@toPrimitive / toString / valueOf as the
    // spec requires, so the proxy also sees the `toString` get/call pair the
    // test logs expect.
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
fn bool to_temporal_calendar_identifier(BuiltinContext* ctx, TVal* tv, HObject** out) {
    if (tv.is_undefined()) {
        *out = ctx.heap.temporal_iso_calendar;
        return true;
    }
    if (tv.is_object() && tv.get_heapptr() != null) {
        HObject* o = (HObject*)tv.get_heapptr();
        hobject::ObjClass cl = o.get_class();
        if (cl == hobject::ObjClass.TEMPORAL_CALENDAR
            || cl == hobject::ObjClass.TEMPORAL_PLAIN_DATE
            || cl == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME
            || cl == hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH
            || cl == hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY
            || cl == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            *out = ctx.heap.temporal_iso_calendar;
            return true;
        }
        builtin_throw(ctx, ctx.heap.type_err_proto, "not a Temporal.Calendar object");
        return false;
    }
    if (tv.is_string()) {
        HString* s = (HString*)tv.get_heapptr();
        if (s != null) {
            if (s.is_symbol()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "symbol is not a valid calendar");
                return false;
            }
            char[] text = s.get_cstr()[:s.blen];
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

// non-string non-calendar values TypeError).
fn bool calendar_from_arg(BuiltinContext* ctx, TVal* tv, HObject** out) {
    if (tv.is_undefined()) {
        *out = ctx.heap.temporal_iso_calendar;
        return true;
    }
    if (tv.is_object() && tv.get_heapptr() != null) {
        HObject* o = (HObject*)tv.get_heapptr();
        // Fast-path: any Temporal object that already carries a calendar
        // (PlainDate / PlainDateTime / PlainYearMonth / PlainMonthDay /
        // ZonedDateTime) exposes its calendar via the same HObjectTemporal
        // slot, so it short-circuits to the shared iso8601 singleton.
        hobject::ObjClass cl = o.get_class();
        if (cl == hobject::ObjClass.TEMPORAL_CALENDAR
            || cl == hobject::ObjClass.TEMPORAL_PLAIN_DATE
            || cl == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME
            || cl == hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH
            || cl == hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY
            || cl == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            *out = ctx.heap.temporal_iso_calendar;
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
            // Otherwise the calendar may be any Temporal ISO 8601 / Temporal
            // date / date-time / year-month / month-day / time string. The
            // bracket annotation can carry `[u-ca=iso8601]`, which we accept.
            // The plain ISO date / time forms (e.g. "2020-01-01",
            // "2020-01-01T00:00:00.000000000", "2020-01", "01-01") likewise
            // resolve to the iso8601 calendar.
            temporal::ParsedIsoDateTime pdt = { .year = 0 };
            if (temporal::parse_iso_date_string(text, &pdt)
                || temporal::parse_iso_yearmonth_string(text, &pdt)
                || temporal::parse_iso_monthday_string(text, &pdt)
                || temporal::parse_iso_time_string(text, &pdt)) {
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
    if (!tv.is_string() && !tv.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "monthCode must be a string");
        return false;
    }
    if (tv.is_string() && ((HString*)tv.get_heapptr()).is_symbol()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "monthCode must be a string");
        return false;
    }
    HString* s;
    if (tv.is_object()) {
        Vm* vm_ptr = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(vm_ptr, &tv, 1);
        if (vm_ptr.throw_pending) {
            ctx.should_throw = true;
            ctx.throw_value = vm_ptr.throw_value;
            vm_ptr.throw_pending = false;
            return false;
        }
        if (!prim.is_string() || ((HString*)prim.get_heapptr()).is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "monthCode must be a string");
            return false;
        }
        s = (HString*)prim.get_heapptr();
    } else {
        s = (HString*)tv.get_heapptr();
    }
    char[] text = s.get_cstr()[:s.blen];
    // Spec's monthCode grammar is `M01..M12` or `M01L..M12L` (leap-month
    // suffix). The syntactic check fires first; suitability (the
    // calendar-specific month value check) runs in
    // CalendarResolveFields / monthCodeFromFields, so a well-formed
    // `M99L` reaches that later check rather than throwing RangeError
    // here. test262 `monthcode-invalid.js`.
    if (text.len != 3 && text.len != 4) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid monthCode");
        return false;
    }
    if (text[0] != 'M') {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid monthCode");
        return false;
    }
    if (text[1] < '0' || text[1] > '9' || text[2] < '0' || text[2] > '9') {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid monthCode");
        return false;
    }
    if (text.len == 4 && text[3] != 'L') {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid monthCode");
        return false;
    }
    int m = (text[1] - '0') * 10 + (text[2] - '0');
    *out = m;
    return true;
}

// Read a PlainDate property bag (from / with / compare / until args).
// `keep_missing` tells with() to fall back to the current date's fields.
// `read_tz` controls whether the spec's RejectObjectWithCalendarOrTimeZone
// step fires a `get` trap for `timeZone` (true for `with`, false for `from`).
// Runs the era/eraYear rejection, month/monthCode agreement check, and
// calendar-property resolution that the single-ISO-calendar engine needs.
// Property reads happen in the spec order (calendar, day, month, monthCode,
// year) so observers (test262 propertyBagObserver) see the right sequence
// and valueOf/toString fire right after their property.
//
// The ISO monthCode suitability check (M01..M12, no `L` suffix) is NOT
// performed here — the caller runs check_iso_monthcode_suitability after
// read_overflow_option so the options bag is observed even when the field
// bag is invalid (test262 options-read-before-algorithmic-validation).
// `out_have_mc`, `out_mci`, and `out_mc_v` report the parsed monthCode so
// the caller can do that check.
fn bool bag_to_fields(BuiltinContext* ctx, HObject* bag, bool keep_missing, bool read_tz,
                      temporal::CivilDate cur, temporal::CivilDate* out,
                      long* out_epoch_days,
                      bool* out_have_mc, int* out_mci, TVal* out_mc_v,
                      bool* out_found_any = null) {
    Vm* v = (Vm*)ctx.vm;

    *out_have_mc = false;
    // Set when the bag carries at least one recognized date field. `with()`
    // rejects a bag with none (test262 PlainDateLike-must-contain-a-field).
    bool found_any = false;

    // Read `calendar` first so the spec's property-read order is observed
    // (test262's `order-of-operations`). In with-mode (`read_tz`), the bag is
    // RejectObjectWithCalendarOrTimeZone'd: a present calendar or timeZone is
    // a TypeError regardless of value. In from-mode a calendar is accepted
    // (the ISO calendar is the only valid one) and timeZone is never probed.
    {
        TVal cal_v = prop_or_undefined_pa(ctx, bag, "calendar");
        if (!cal_v.is_undefined()) {
            if (read_tz) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a calendar property");
                return false;
            }
            HObject* cal;
            if (!calendar_from_arg(ctx, &cal_v, &cal)) return false;
        }
    }
    if (read_tz) {
        TVal tz_v = prop_or_undefined_pa(ctx, bag, "timeZone");
        if (!tz_v.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a timeZone property");
            return false;
        }
    }

    // Era / eraYear are never read by the ISO calendar's PrepareTemporalFields,
    // so we don't probe for them here either. They would be rejected if a
    // caller set them on the bag directly via JS, but no spec path triggers
    // that read.

    long y = cur.y;
    long m = cur.m;
    long d = cur.d;

    // day
    TVal day_v = prop_or_undefined_pa(ctx, bag, "day");
    if (!day_v.is_undefined()) {
        found_any = true;
        if (!to_integer_with_truncation(v, &day_v, &d)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
            return false;
        }
        // Per spec, PrepareTemporalFields rejects day < 1 with a
        // RangeError. This runs even when `keep_missing` is true (e.g. in
        // `with()`) so the partial-date / day-range check fires BEFORE
        // the options type-check, matching the test262 expectation in
        // `options-wrong-type.js` (where `{day: -1}, null` must throw
        // RangeError, not TypeError).
        if (d < 1) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is out of range");
            return false;
        }
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing day property");
        return false;
    }

    // month
    TVal month_v = prop_or_undefined_pa(ctx, bag, "month");
    bool have_month = false;
    long mv = 0;
    if (!month_v.is_undefined()) {
        found_any = true;
        if (!to_integer_with_truncation(v, &month_v, &mv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
            return false;
        }
        if (mv < 1) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is out of range");
            return false;
        }
        have_month = true;
    }

    // monthCode — read and validate the syntax BEFORE year so a malformed
    // monthCode (e.g. "L99M") raises RangeError even when year is a Symbol
    // that would otherwise raise TypeError first. test262 `monthcode-invalid.js`.
    // The parsed value is reported to the caller via out_mc_v/out_mci so
    // check_iso_monthcode_suitability can run it after read_overflow_option.
    TVal mc_v = prop_or_undefined_pa(ctx, bag, "monthCode");
    long mci = 0;
    if (!mc_v.is_undefined()) {
        found_any = true;
        int mci_int;
        if (!parse_month_code(ctx, mc_v, &mci_int)) return false;
        mci = mci_int;
        *out_have_mc = true;
        *out_mci = mci_int;
        *out_mc_v = mc_v;
    }
    if (have_month && *out_have_mc && mv != mci) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "month and monthCode do not agree");
        return false;
    }
    if (*out_have_mc) {
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
        found_any = true;
        if (!to_integer_with_truncation(v, &year_v, &y)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "year is not an integral number");
            return false;
        }
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing year property");
        return false;
    }

    // The ISO calendar's CalendarResolveFields / monthCodeFromFields
    // suitability check runs AFTER read_overflow_option in the callers,
    // not here, so the options bag is observed even when the field bag
    // is invalid (test262 options-read-before-algorithmic-validation).

    out.y = y;
    out.m = (int)m;
    out.d = (int)d;
    *out_epoch_days = temporal::epoch_days_from_civil(y, (int)m, (int)d);
    if (out_found_any != null) *out_found_any = found_any;
    return true;
}

// Validate monthCode suitability for the ISO calendar. Called by the from/with
// methods AFTER read_overflow_option so the options bag is observed even when
// the field bag is invalid (test262 options-read-before-algorithmic-validation).
// `have_mc` reports whether the bag supplied a monthCode; when false this is a
// no-op. `mc_v` is the original TVal — Symbol values skip the L-suffix length
// check because the parse_month_code syntax check has already produced an int.
fn bool check_iso_monthcode_suitability(BuiltinContext* ctx, bool have_mc, int mci, TVal mc_v) {
    if (!have_mc) return true;
    if (mci < 1 || mci > 12) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "monthCode not valid for ISO 8601 calendar");
        return false;
    }
    HString* mc_s = (HString*)mc_v.get_heapptr();
    if (mc_s != null && !mc_s.is_symbol()) {
        String mc_text = (String)mc_s.get_cstr()[:mc_s.blen];
        if (mc_text.len == 4) {
            // "MxxL" — only valid for lunisolar calendars; ISO rejects.
            builtin_throw(ctx, ctx.heap.range_err_proto, "monthCode not valid for ISO 8601 calendar");
            return false;
        }
    }
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
// `require_any` when true throws TypeError if no time fields are present
// (PlainTime.from requires at least one; PlainDateTime.from does not).
fn bool bag_to_time_fields(BuiltinContext* ctx, HObject* bag, bool keep_missing,
                           temporal::CivilTime cur, temporal::CivilTime* out,
                           bool require_any = false) {
    Vm* v = (Vm*)ctx.vm;
    int  h  = (int)cur.h;
    int  mi = (int)cur.mi;
    int  s  = (int)cur.s;
    int  ms = (int)cur.ms;
    int  us = (int)cur.us;
    int  ns = (int)cur.ns;

    // Per spec (PrepareTemporalFields for PlainTime), the time bag is read
    // lexicographically: hour, microsecond, millisecond, minute, nanosecond,
    // second. The corresponding primitive valueOf fires immediately after
    // each property access (so propertyBagObserver sees the get/get valueOf/
    // call triple per field), and the explicit ms/us/ns read in earlier
    // positions lets the second-block override check see whether the bag
    // carried any of those three explicitly.
    //
    // All six time fields default to 0 when omitted from the bag —
    // Temporal.PlainDateTime.from({year, month, day}) is valid
    // (test262 argument-propertybag-optional-properties.js). Only fall back
    // to `cur` when the caller asked for with() semantics.

    long lv;
    bool found_any = false;

    // hour
    TVal h_v = prop_or_undefined_pa(ctx, bag, "hour");
    if (!h_v.is_undefined()) {
        found_any = true;
        if (!to_integer_with_truncation(v, &h_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "hour is not an integral number");
            return false;
        }
        h = (int)lv;
    } else if (!keep_missing) {
        h = 0;
    }

    // microsecond
    TVal us_v = prop_or_undefined_pa(ctx, bag, "microsecond");
    if (!us_v.is_undefined()) {
        found_any = true;
        if (!to_integer_with_truncation(v, &us_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "microsecond is not an integral number");
            return false;
        }
        us = (int)lv;
    } else if (!keep_missing) {
        us = 0;
    }

    // millisecond
    TVal ms_v = prop_or_undefined_pa(ctx, bag, "millisecond");
    if (!ms_v.is_undefined()) {
        found_any = true;
        if (!to_integer_with_truncation(v, &ms_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "millisecond is not an integral number");
            return false;
        }
        ms = (int)lv;
    } else if (!keep_missing) {
        ms = 0;
    }

    // minute
    TVal mi_v = prop_or_undefined_pa(ctx, bag, "minute");
    if (!mi_v.is_undefined()) {
        found_any = true;
        if (!to_integer_with_truncation(v, &mi_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "minute is not an integral number");
            return false;
        }
        mi = (int)lv;
    } else if (!keep_missing) {
        mi = 0;
    }

    // nanosecond
    TVal ns_v = prop_or_undefined_pa(ctx, bag, "nanosecond");
    if (!ns_v.is_undefined()) {
        found_any = true;
        if (!to_integer_with_truncation(v, &ns_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "nanosecond is not an integral number");
            return false;
        }
        ns = (int)lv;
    } else if (!keep_missing) {
        ns = 0;
    }

    // second — supports an optional fractional part that splits into
    // ms/us/ns; explicit millisecond/microsecond/nanosecond (which were
    // already read earlier in this function) override the split.
    TVal s_v = prop_or_undefined_pa(ctx, bag, "second");
    if (!s_v.is_undefined()) {
        found_any = true;
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
        s = (int)whole;
        if (frac != 0) {
            long frac_ns = (long)math::trunc(frac * 1_000_000_000.0);
            if (frac_ns < 0) frac_ns = 0;
            if (frac_ns > 999_999_999) frac_ns = 999_999_999;
            if (ms_v.is_undefined()) ms = (int)(frac_ns / 1_000_000);
            if (us_v.is_undefined()) us = (int)((frac_ns / 1000) % 1000);
            if (ns_v.is_undefined()) ns = (int)(frac_ns % 1000);
        }
    } else if (!keep_missing) {
        s = 0;
    }

    if (require_any && !found_any) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "object must have at least one time field");
        return false;
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
// seconds (s == 60) collapse to 59 here per spec. With CONSTRAIN, out-of-range
// fields are clamped to their valid maximum. `allow_leap_second` is true for
// ISO string inputs where second=60 is valid per the grammar; property bags
// always reject second=60.
fn bool fields_to_valid_time(BuiltinContext* ctx, temporal::CivilTime fields, temporal::CivilTime* out,
                             temporal::OverflowKind overflow, bool allow_leap_second) {
    if (overflow == temporal::OverflowKind.CONSTRAIN) {
        if (fields.h  < 0) fields.h  = 0;  if (fields.h  > 23) fields.h  = 23;
        if (fields.mi < 0) fields.mi = 0;  if (fields.mi > 59) fields.mi = 59;
        if (fields.s  < 0) fields.s  = 0;  if (fields.s  > 59) fields.s  = 59;
        if (fields.ms < 0) fields.ms = 0;  if (fields.ms > 999) fields.ms = 999;
        if (fields.us < 0) fields.us = 0;  if (fields.us > 999) fields.us = 999;
        if (fields.ns < 0) fields.ns = 0;  if (fields.ns > 999) fields.ns = 999;
    } else {
        if (fields.h  < 0 || fields.h  > 23) { builtin_throw(ctx, ctx.heap.range_err_proto, "hour out of range"); return false; }
        if (fields.mi < 0 || fields.mi > 59) { builtin_throw(ctx, ctx.heap.range_err_proto, "minute out of range"); return false; }
        if (fields.s  < 0 || fields.s  > 60) { builtin_throw(ctx, ctx.heap.range_err_proto, "second out of range"); return false; }
        if (fields.ms < 0 || fields.ms > 999) { builtin_throw(ctx, ctx.heap.range_err_proto, "millisecond out of range"); return false; }
        if (fields.us < 0 || fields.us > 999) { builtin_throw(ctx, ctx.heap.range_err_proto, "microsecond out of range"); return false; }
        if (fields.ns < 0 || fields.ns > 999) { builtin_throw(ctx, ctx.heap.range_err_proto, "nanosecond out of range"); return false; }
    }
    if (fields.s == 60) {
        if (!allow_leap_second) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "second out of range");
            return false;
        }
        if (fields.ms != 0 || fields.us != 0 || fields.ns != 0) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "leap second cannot have a fractional part");
            return false;
        }
    }
    temporal::CivilTime v = fields;
    if (v.s == 60) v.s = 59;
    *out = v;
    return true;
}

// How a property bag's fields are read. Calendar is always probed (validated
// for from-style reads, rejected on presence for with-style). `timeZone` and
// `offset` are probed only by the zoned modes.
enum TemporalBagMode {
    TBM_PLAIN,     // PlainDateTime.from / until-since bags: date+time fields only
    TBM_PLAIN_WITH,// PlainDateTime.with: calendar+timeZone probes, presence rejected
    TBM_ZDT,       // ZonedDateTime.from / Duration relativeTo: offset between
                   // nanosecond and second, timeZone between second and year
    TBM_ZDT_WITH,  // ZonedDateTime.with: probes plus the offset read
}

// A time-field read (hour/minute/microsecond/...): ToIntegerWithTruncation
// coerces the primitive immediately after the Get so observers see the
// valueOf call between the field's get and the next field's get. A missing
// field resolves to the caller's fallback under keep_missing, else to 0.
fn bool bag_time_int(BuiltinContext* ctx, HObject* bag, char[] name,
                     bool keep_missing, int fallback, int* out, char[] msg,
                     bool* out_present = null) {
    Vm* v = (Vm*)ctx.vm;
    TVal fv = prop_or_undefined_pa(ctx, bag, name);
    if (ctx.should_throw) return false;
    // `out_present` is an OR-accumulator across the bag's fields: we only ever
    // set it (never clear it), so an earlier field's "present" bit survives the
    // read of a later absent field; the caller initializes it false.
    if (fv.is_undefined()) { *out = keep_missing ? fallback : 0; return true; }
    if (out_present != null) *out_present = true;
    long lv;
    if (!to_integer_with_truncation(v, &fv, &lv)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
        builtin_throw(ctx, ctx.heap.range_err_proto, msg);
        return false;
    }
    *out = (int)lv;
    return true;
}

// Read an `offset` property for a zoned bag: string-coerce (firing the
// observer's toString), then enforce the TimeZoneOffsetString grammar that the
// Temporal offset property accepts. Reports presence and whole-second offset.
fn bool bag_offset_prop(BuiltinContext* ctx, HObject* bag, bool* out_has, long* out_sec) {
    Vm* v = (Vm*)ctx.vm;
    *out_has = false;
    TVal offset_v = prop_or_undefined_pa(ctx, bag, "offset");
    if (ctx.should_throw) return false;
    if (offset_v.is_undefined()) return true;
    if (offset_v.is_string()) {
        HString* ohs = (HString*)offset_v.get_heapptr();
        if (ohs != null && ohs.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "offset must not be a Symbol");
            return false;
        }
    } else if (offset_v.is_object() && offset_v.get_heapptr() != null) {
        // Object with toString/valueOf: builtin_to_string_vm coerces below.
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "offset must be a string");
        return false;
    }
    HString* off_s = builtin_to_string_vm(ctx, &offset_v);
    if (ctx.should_throw) return false;
    if (off_s == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "offset must be convertible to a string");
        return false;
    }
    char[] otxt = (String)off_s.get_cstr()[:off_s.blen];
    usz pi = 0;
    long off_sec = 0;
    if (!parse_offset_only(otxt, &pi, &off_sec) || pi != otxt.len) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset string");
        return false;
    }
    // The `offset` property follows the full TimeZoneOffsetString grammar
    // (seconds and fractions allowed), so parse_offset_only handles it.
    *out_has = true;
    *out_sec = off_sec;
    return true;
}

// Read a PlainDateTime / ZonedDateTime property bag with every field Get and
// its conversion interleaved in the spec's alphabetical order: calendar, day,
// hour, microsecond, millisecond, minute, month, monthCode, nanosecond,
// [offset], second, [timeZone], year. `calendar` is validated for the
// from-style modes and rejected on presence for the with-style modes (the
// RejectObjectWithCalendarOrTimeZone probe, which is a [[Get]] per test262
// order-of-operations). `require_date` makes the reader throw TypeError after
// the full read when year, month/monthCode, or day is absent (ToRelativeTemporalObject
// and ToTemporalZonedDateTime). `out_tz`/`out_has_tz`/`out_has_offset`/
// `out_offset_sec` report the zoned extras so callers can resolve the
// wall-time. The monthCode suitability check is NOT performed here — callers
// run check_iso_monthcode_suitability after reading the options bag; the
// parsed value is reported via out_have_mc/out_mci/out_mc_v.
fn bool bag_to_datetime_fields_ex(BuiltinContext* ctx, HObject* bag, TemporalBagMode mode,
                                  bool keep_missing, bool require_date,
                                  temporal::CivilDate cur_date, temporal::CivilTime cur_time,
                                  temporal::CivilDateTime* out,
                                  bool* out_found_any,
                                  bool* out_have_mc, int* out_mci, TVal* out_mc_v,
                                  bool* out_has_tz, HObject** out_tz,
                                  bool* out_has_offset, long* out_offset_sec) {
    Vm* v = (Vm*)ctx.vm;
    *out_have_mc = false;
    bool with_mode = (mode == TBM_PLAIN_WITH) || (mode == TBM_ZDT_WITH);
    bool zdt_mode  = (mode == TBM_ZDT)       || (mode == TBM_ZDT_WITH);

    long y = cur_date.y;
    int m  = (int)cur_date.m;
    int d  = (int)cur_date.d;
    int h  = (int)cur_time.h;
    int mi = (int)cur_time.mi;
    int s  = (int)cur_time.s;
    int ms = (int)cur_time.ms;
    int us = (int)cur_time.us;
    int ns = (int)cur_time.ns;
    bool have_us = false;
    bool have_ms = false;
    bool have_ns = false;
    // True when the bag carried at least one recognized field. `with()` rejects
    // a bag with none (test262 object-must-contain-at-least-one-property) while
    // ignoring unrecognized fields once anything recognized is present.
    bool found_any = false;

    // calendar
    TVal cal_v = prop_or_undefined_pa(ctx, bag, "calendar");
    if (ctx.should_throw) return false;
    if (!cal_v.is_undefined()) {
        if (with_mode) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a calendar property");
            return false;
        }
        HObject* cal;
        if (!calendar_from_arg(ctx, &cal_v, &cal)) return false;
    }

    // timeZone probe (with-style only)
    if (with_mode) {
        TVal tz_v = prop_or_undefined_pa(ctx, bag, "timeZone");
        if (ctx.should_throw) return false;
        if (!tz_v.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a timeZone property");
            return false;
        }
    }

    // day
    bool have_day = false;
    TVal day_v = prop_or_undefined_pa(ctx, bag, "day");
    if (ctx.should_throw) return false;
    if (!day_v.is_undefined()) {
        have_day = true;
        found_any = true;
        long dl;
        if (!to_integer_with_truncation(v, &day_v, &dl)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
            return false;
        }
        // PrepareTemporalFields rejects day < 1 even under keep_missing (so
        // `with({day: -1}, null)` throws RangeError, not TypeError).
        if (dl < 1) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is out of range");
            return false;
        }
        d = (int)dl;
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing day property");
        return false;
    }

    // hour, microsecond, millisecond, minute
    if (!bag_time_int(ctx, bag, "hour", keep_missing, h, &h, "hour is not an integral number", &found_any)) return false;
    TVal us_orig_v = prop_or_undefined_pa(ctx, bag, "microsecond");
    if (ctx.should_throw) return false;
    if (!us_orig_v.is_undefined()) {
        have_us = true;
        found_any = true;
        long lv;
        if (!to_integer_with_truncation(v, &us_orig_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "microsecond is not an integral number");
            return false;
        }
        us = (int)lv;
    } else if (!keep_missing) {
        us = 0;
    }
    TVal ms_orig_v = prop_or_undefined_pa(ctx, bag, "millisecond");
    if (ctx.should_throw) return false;
    if (!ms_orig_v.is_undefined()) {
        have_ms = true;
        found_any = true;
        long lv;
        if (!to_integer_with_truncation(v, &ms_orig_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "millisecond is not an integral number");
            return false;
        }
        ms = (int)lv;
    } else if (!keep_missing) {
        ms = 0;
    }
    if (!bag_time_int(ctx, bag, "minute", keep_missing, mi, &mi, "minute is not an integral number", &found_any)) return false;

    // month / monthCode (interleaved after minute per the alphabetical order)
    bool have_month = false;
    long month_lv = 0;
    TVal month_v = prop_or_undefined_pa(ctx, bag, "month");
    if (ctx.should_throw) return false;
    if (!month_v.is_undefined()) {
        have_month = true;
        found_any = true;
        if (!to_integer_with_truncation(v, &month_v, &month_lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
            return false;
        }
    }
    TVal mc_v = prop_or_undefined_pa(ctx, bag, "monthCode");
    if (ctx.should_throw) return false;
    if (!mc_v.is_undefined()) {
        found_any = true;
        int mci;
        if (!parse_month_code(ctx, mc_v, &mci)) return false;
        *out_have_mc = true;
        *out_mci = mci;
        *out_mc_v = mc_v;
        if (have_month && month_lv != mci) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "month and monthCode do not agree");
            return false;
        }
        m = mci;
    } else if (have_month) {
        m = (int)month_lv;
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing month property");
        return false;
    }

    // nanosecond
    TVal ns_orig_v = prop_or_undefined_pa(ctx, bag, "nanosecond");
    if (ctx.should_throw) return false;
    if (!ns_orig_v.is_undefined()) {
        have_ns = true;
        found_any = true;
        long lv;
        if (!to_integer_with_truncation(v, &ns_orig_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "nanosecond is not an integral number");
            return false;
        }
        ns = (int)lv;
    } else if (!keep_missing) {
        ns = 0;
    }

    // offset (zoned modes): between nanosecond and second
    if (zdt_mode) {
        bool has_off = false;
        long off_sec = 0;
        if (!bag_offset_prop(ctx, bag, &has_off, &off_sec)) return false;
        found_any = found_any || has_off;
        if (out_has_offset != null) *out_has_offset = has_off;
        if (out_offset_sec != null) *out_offset_sec = off_sec;
    }

    // second — supports an optional fractional part that splits into
    // ms/us/ns; explicitly set millisecond/microsecond/nanosecond (already
    // read above) override the split.
    TVal s_v = prop_or_undefined_pa(ctx, bag, "second");
    if (ctx.should_throw) return false;
    if (!s_v.is_undefined()) {
        found_any = true;
        double d_sec = vm::vm_to_number(v, &s_v);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
        if (math::is_nan(d_sec) || math::is_inf(d_sec)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "second is not a finite number");
            return false;
        }
        // Leave out-of-range seconds (including a leap 60) to regulation:
        // the overflow option decides in fields_to_valid_time whether to clamp
        // or reject. The reader must not hard-reject, or `with({second: 67})`
        // under constrain would throw instead of clamping to 59.
        long whole = (long)math::trunc(d_sec);
        double frac = d_sec - (double)whole;
        s = (int)whole;
        if (frac != 0) {
            long frac_ns_v = (long)math::trunc(frac * 1_000_000_000.0);
            if (frac_ns_v < 0) frac_ns_v = 0;
            if (frac_ns_v > 999_999_999) frac_ns_v = 999_999_999;
            if (!have_ms) ms = (int)(frac_ns_v / 1_000_000);
            if (!have_us) us = (int)((frac_ns_v / 1000) % 1000);
            if (!have_ns) ns = (int)(frac_ns_v % 1000);
        }
    } else if (!keep_missing) {
        s = 0;
    }

    // timeZone (from-style zoned): between second and year
    if (zdt_mode && !with_mode) {
        if (out_has_tz != null) *out_has_tz = false;
        TVal tz_v = prop_or_undefined_pa(ctx, bag, "timeZone");
        if (ctx.should_throw) return false;
        if (out_tz != null) *out_tz = null;
        if (!tz_v.is_undefined()) {
            if (try maybe_tz = to_temporal_tz(ctx, &tz_v)) {
                if (out_has_tz != null) *out_has_tz = true;
                if (out_tz != null) *out_tz = maybe_tz;
            } else {
                return false;
            }
        }
    }

    // year (last, per the spec ordering of PrepareTemporalFields)
    bool have_year = false;
    TVal year_v = prop_or_undefined_pa(ctx, bag, "year");
    if (ctx.should_throw) return false;
    if (!year_v.is_undefined()) {
        have_year = true;
        found_any = true;
        if (!to_integer_with_truncation(v, &year_v, &y)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "year is not an integral number");
            return false;
        }
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing year property");
        return false;
    }

    if (require_date && (!have_year || (!have_month && !*out_have_mc) || !have_day)) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing required date property");
        return false;
    }

    out.date.y = y;
    out.date.m = m;
    out.date.d = d;
    out.time.h = h;
    out.time.mi = mi;
    out.time.s = s;
    out.time.ms = ms;
    out.time.us = us;
    out.time.ns = ns;
    if (out_found_any != null) *out_found_any = found_any;
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
        // PlainDateTime → PlainDate fast path: extract the date directly
        // from internal slots, skipping property-bag reading (which can't
        // see internal slots). Per ToTemporalDate step 2.b.
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            temporal::CivilDate cd = plain_date_value(o);
            HObject*? res = alloc_plain_date(ctx.heap, cd, ctx.heap.temporal_iso_calendar);
            if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
            HObject* r = res;
            r.prototype = ctx.heap.temporal_plain_date_proto;
            return r;
        }
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
            zdt_wall_fields(o, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
            (void)wh; (void)wmi; (void)ws; (void)wms; (void)wus; (void)wns; (void)off;
            temporal::CivilDate cd = { .y = wy, .m = (int)wm, .d = (int)wd };
            HObject*? res = alloc_plain_date(ctx.heap, cd, ctx.heap.temporal_iso_calendar);
            if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
            HObject* r = res;
            r.prototype = ctx.heap.temporal_plain_date_proto;
            return r;
        }
        temporal::CivilDate fields;
        long _ep;
        bool have_mc;
        int mci;
        TVal mc_v;
        if (!bag_to_fields(ctx, o, false, false, { .y = 0, .m = 1, .d = 1 }, &fields, &_ep,
                           &have_mc, &mci, &mc_v)) return null;
        temporal::CivilDate valid;
        if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) return null;
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
        // Symbols are HString with is_symbol=true; the parser would
        // RangeError on the 0xFF prefix, but the spec rejects them up
        // front with TypeError.
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to a PlainDate");
            return null;
        }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO date string");
            return null;
        }
        // Per the Temporal grammar (DateTime[~Z]), a `Z` designator is not
        // permitted on a string being coerced to PlainDate. The time
        // component and any numeric offset are silently dropped.
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Z designator not valid for PlainDate");
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
    bool largest_auto = true;
    TVal uv = prop_or_undefined_pa(ctx, opts, "largestUnit");
    if (!uv.is_undefined()) {
        largest_auto = false;
        // GetOption converts the value to a string before matching. Symbol
        // throws TypeError; primitives that don't match a known unit reject
        // with RangeError below.
        HString* s = builtin_to_string_vm(ctx, &uv);
        if (ctx.should_throw) return false;
        char[] v = s.get_cstr()[:s.blen];
        if (v == "auto") { largest_auto = true; }
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
        // GetDifferenceSettings: when smallestUnit > current largestUnit
        // AND largestUnit was "auto" (or absent), bump largestUnit up to fit.
        // When the caller pinned both, reject as a likely mistake.
        if (small > *largest) {
            if (largest_auto) {
                *largest = small;
            } else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "smallestUnit cannot be larger than largestUnit");
                return false;
            }
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

fn bool duration_field_integral(BuiltinContext* ctx, double val) {
    if (math::is_nan(val) || math::is_inf(val)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration fields must be finite");
        return false;
    }
    if (math::floor(val) != val) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration fields must be integers");
        return false;
    }
    return true;
}

fn bool is_valid_duration(temporal::DurationParts* d) {
    if (math::abs((double)d.years) >= 4294967296.0 ||
        math::abs((double)d.months) >= 4294967296.0 ||
        math::abs((double)d.weeks) >= 4294967296.0) {
        return false;
    }
    int overall_sign = 0;
    long*[10] comps = { &d.years, &d.months, &d.weeks, &d.days, &d.hours,
        &d.minutes, &d.seconds, &d.ms, &d.us, &d.ns };
    for (int k = 0; k < 10; k++) {
        if (*comps[k] == 0) continue;
        int s = *comps[k] < 0 ? -1 : 1;
        if (overall_sign == 0) { overall_sign = s; }
        else if (overall_sign != s) { return false; }
    }
    int128 total_ns = (int128)d.days * (int128)86400_000_000_000L +
                      (int128)d.hours * (int128)3600_000_000_000L +
                      (int128)d.minutes * (int128)60_000_000_000L +
                      (int128)d.seconds * (int128)1000_000_000L +
                      (int128)d.ms * (int128)1000_000L +
                      (int128)d.us * (int128)1000L +
                      (int128)d.ns;
    int128 max_ns = (int128)9007199254740991L * (int128)1000_000_000L + (int128)999_999_999L;
    if (total_ns > max_ns || total_ns < -max_ns) {
        return false;
    }
    return true;
}

fn void builtin_temporal_duration_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Duration requires new");
        return;
    }
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
        if (!duration_field_integral(ctx, val)) return;
        long whole = (long)math::trunc(val);
        switch (k) {
            case 0: d.years = whole; break;
            case 1: d.months = whole; break;
            case 2: d.weeks = whole; break;
            case 3: d.days = whole; break;
            case 4: d.hours = whole; break;
            case 5: d.minutes = whole; break;
            case 6: d.seconds = whole; break;
            case 7: d.ms = whole; break;
            case 8: d.us = whole; break;
            default: d.ns = whole; break;
        }
    }
    if (!is_valid_duration(&d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid duration: components out of range or mixed signs");
        return;
    }
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_duration_proto);
    ctx.result.set_object(obj);
}

fn void builtin_temporal_duration_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Duration.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    temporal::DurationParts d;
    if (!duration_from_arg(ctx, arg, &d)) return;
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

// ToRelativeTemporalObject: read the `relativeTo` option out of `opts` (which
// may be null, meaning no options bag was supplied) and resolve it into a
// PlainDate or PlainDateTime object, writing null when the property is
// absent. Shared by Duration.compare / .round / .total, which all interpret
// relativeTo identically.
//
// Accepts:
//   * an existing PlainDate / PlainDateTime object (identity kept);
//   * a ZonedDateTime object (converted to its local wall-clock PlainDateTime,
//     since none of the three callers need the time zone itself -- they only
//     read the date fields off `long_a/long_b/long_c`);
//   * a property bag with year/month/day (+ optional time fields), which may
//     additionally carry `timeZone` (and `offset`), making it ZonedDateTime-
//     relative; the resolved local wall-clock is likewise converted to a
//     PlainDateTime;
//   * an ISO date or date-time string.
//
// Returns false with `ctx.should_throw` set on failure.
fn bool read_relative_to_option(BuiltinContext* ctx, HObject* opts, HObject** out_relative_to) {
    *out_relative_to = null;
    if (opts == null) return true;
    TVal rv = prop_or_undefined_pa(ctx, opts, "relativeTo");
    if (ctx.should_throw) return false;
    if (rv.is_undefined()) return true;

    if (rv.is_object() && rv.get_heapptr() != null) {
        HObject* ro = (HObject*)rv.get_heapptr();
        if (ro.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATE ||
            ro.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            *out_relative_to = ro;
            return true;
        }
        if (ro.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
            zdt_wall_fields(ro, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);
            temporal::CivilDateTime dt = {
                .date = { .y = wy, .m = wm, .d = wd },
                .time = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns },
            };
            HObject*? dt_o = alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
            if (catch err = dt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return false; }
            *out_relative_to = dt_o;
            return true;
        }

        // Property bag. ToRelativeTemporalObject reads every field via
        // PrepareTemporalFields in alphabetical order (calendar, day, hour,
        // ..., offset, second, timeZone, year); the unified reader resolves
        // `timeZone` and validates `offset` at their positions and reports
        // whether the bag is zoned. Missing date fields are a TypeError
        // (require_date); missing time fields default to 0.
        Vm* v = (Vm*)ctx.vm;
        temporal::CivilDateTime cur = { .date = { .y = 1970, .m = 1, .d = 1 }, .time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 } };
        temporal::CivilDateTime fields;
        bool _have_mc;
        int _mci;
        TVal _mc_v;
        bool has_tz = false;
        HObject* tz = null;
        bool has_offset_prop = false;
        long off_sec = 0;
        if (!bag_to_datetime_fields_ex(ctx, ro, TBM_ZDT, true, true, cur.date, cur.time, &fields,
                                       null, &_have_mc, &_mci, &_mc_v,
                                       &has_tz, &tz, &has_offset_prop, &off_sec)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return false;
        }
        temporal::CivilDate valid_d;
        if (!fields_to_valid_date(ctx, fields.date, temporal::OverflowKind.CONSTRAIN, &valid_d)) return false;
        temporal::CivilTime valid_t;
        if (!fields_to_valid_time(ctx, fields.time, &valid_t, temporal::OverflowKind.CONSTRAIN, true)) return false;

        if (tz == null) {
            // If no time fields were supplied on the property bag, build a PlainDate;
            // otherwise build a PlainDateTime.
            bool has_time_props = !prop_or_undefined(ro, ctx.heap, "hour").is_undefined() ||
                                  !prop_or_undefined(ro, ctx.heap, "minute").is_undefined() ||
                                  !prop_or_undefined(ro, ctx.heap, "second").is_undefined() ||
                                  !prop_or_undefined(ro, ctx.heap, "millisecond").is_undefined() ||
                                  !prop_or_undefined(ro, ctx.heap, "microsecond").is_undefined() ||
                                  !prop_or_undefined(ro, ctx.heap, "nanosecond").is_undefined();
            if (ctx.should_throw) return false;
            if (!has_time_props) {
                HObject*? d_o = alloc_plain_date(ctx.heap, valid_d, ctx.heap.temporal_iso_calendar);
                if (catch err = d_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return false; }
                *out_relative_to = d_o;
                return true;
            }
            temporal::CivilDateTime dt = { .date = valid_d, .time = valid_t };
            HObject*? dt_o = alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
            if (catch err = dt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return false; }
            *out_relative_to = dt_o;
            return true;
        }

        // ZonedDateTime-relative bag: resolve the wall time to an instant
        // using the offset (explicit `offset` property, or the offset
        // implied by an offset-form time zone identifier), then convert
        // back to the zone's local wall-clock PlainDateTime -- callers only
        // read the date fields.
        if (!has_offset_prop) {
            String tzid_str = timezone_name(tz);
            usz k = 0;
            long tz_off = 0;
            if (parse_offset_only((char[])tzid_str, &k, &tz_off) && k == tzid_str.len) {
                off_sec = tz_off;
                has_offset_prop = true;
            }
        } else {
            String tzid_str = timezone_name(tz);
            usz k = 0;
            long tz_off = 0;
            if (parse_offset_only((char[])tzid_str, &k, &tz_off) && k == tzid_str.len) {
                if (tz_off != off_sec) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo: offset property does not agree with time zone");
                    return false;
                }
            }
        }
        long wall_secs = temporal::epoch_days_from_civil(valid_d.y, (int)valid_d.m, (int)valid_d.d) * 86400
            + (long)valid_t.h * 3600 + (long)valid_t.mi * 60 + (long)valid_t.s;
        long frac_ns = (long)valid_t.ms * 1000000 + (long)valid_t.us * 1000 + (long)valid_t.ns;
        // Combine in int128: double arithmetic here would drop every bit
        // below 2^53 and corrupt the sub-microsecond digits.
        int128 epoch_ns_128 = (int128)wall_secs * (int128)1000000000L + (int128)frac_ns
            - (int128)off_sec * (int128)1000000000L;
        hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns_128);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return false; }
        hbigint::HBigInt* epoch_ns = big_o;
        HString* cal_str = builtin_intern_string(ctx.heap, "iso8601");
        HObject*? zdt_o = alloc_zoneddatetime(ctx.heap, epoch_ns, tz, cal_str);
        ctx.heap.decref((types::HeapHeader*)epoch_ns);
        if (catch err = zdt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return false; }
        HObject* zdt = zdt_o;
        *out_relative_to = zdt;
        return true;
    }

    if (rv.is_string()) {
        HString* rs = builtin_to_string_vm(ctx, &rv);
        if (ctx.should_throw) return false;
        char[] rtxt = rs.get_cstr()[:rs.blen];
        bool has_bracket = false;
        for (usz ci = 0; ci < rtxt.len; ci++) {
            if (rtxt[ci] == '[') { has_bracket = true; break; }
        }
        if (has_bracket) {
            TVal saved_res = *ctx.result;
            ctx.regs[ctx.base_reg + 0] = rv;
            ctx.argc = 1;
            builtin_temporal_zoneddatetime_from(ctx);
            if (ctx.should_throw) return false;
            if (ctx.result.is_object() && ctx.result.get_heapptr() != null) {
                HObject* zdt = (HObject*)ctx.result.get_heapptr();
                *ctx.result = saved_res;
                *out_relative_to = zdt;
                return true;
            }
            *ctx.result = saved_res;
        }
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(rtxt, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid relativeTo string");
            return false;
        }
        // A date-time + Z (UTC designator) without an IANA bracket
        // annotation is ambiguous — reject it.
        if (p.offset_kind == temporal::OffsetKind.Z && !has_bracket) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date-time + Z without an IANA annotation");
            return false;
        }
        if (p.has_time) {
            if (!temporal::is_valid_iso_datetime(p.year, p.month, p.day, p.hour, p.minute, p.second,
                                                 p.nanos / 1000000, (p.nanos / 1000) % 1000, p.nanos % 1000)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo datetime outside valid ISO range");
                return false;
            }
            temporal::CivilDateTime dt = {
                .date = { .y = p.year, .m = p.month, .d = p.day },
                .time = { .h = p.hour, .mi = p.minute, .s = p.second,
                          .ms = p.nanos / 1000000, .us = (p.nanos / 1000) % 1000,
                          .ns = p.nanos % 1000 },
            };
            HObject*? dt_o = alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
            if (catch err = dt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return false; }
            *out_relative_to = dt_o;
        } else {
            if (!temporal::is_valid_iso_date(p.year, p.month, p.day)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo date outside valid ISO range");
                return false;
            }
            temporal::CivilDate dd = { .y = p.year, .m = p.month, .d = p.day };
            HObject*? dt_o = alloc_plain_date(ctx.heap, dd, ctx.heap.temporal_iso_calendar);
            if (catch err = dt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return false; }
            *out_relative_to = dt_o;
        }
        return true;
    }

    builtin_throw(ctx, ctx.heap.type_err_proto, "relativeTo must be a string or object");
    return false;
}

fn void builtin_temporal_duration_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Duration.compare requires two arguments");
        return;
    }
    temporal::DurationParts da;
    if (!duration_from_arg(ctx, arg_at(ctx, 0), &da)) return;
    temporal::DurationParts db;
    if (!duration_from_arg(ctx, arg_at(ctx, 1), &db)) return;

    // Options bag: must be an object or undefined.
    HObject* opts = null;
    if (ctx.argc >= 3 && !arg_at(ctx, 2).is_undefined()) {
        TVal* ov = arg_at(ctx, 2);
        if (!ov.is_object() || ov.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object or undefined");
            return;
        }
        opts = (HObject*)ov.get_heapptr();
    }

    // relativeTo
    HObject* relative_to = null;
    if (!read_relative_to_option(ctx, opts, &relative_to)) return;

    if (da.years == db.years && da.months == db.months && da.weeks == db.weeks && da.days == db.days &&
        da.hours == db.hours && da.minutes == db.minutes && da.seconds == db.seconds &&
        da.ms == db.ms && da.us == db.us && da.ns == db.ns) {
        ctx.result.set_number(0);
        return;
    }

    if (relative_to == null) {
        if (is_cal_unit(default_largest_unit(da)) || is_cal_unit(default_largest_unit(db))) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo is required to compare durations with calendar units");
            return;
        }
        int128 na = duration_to_time_ns(da);
        int128 nb = duration_to_time_ns(db);
        long cmp = na < nb ? -1 : (na > nb ? 1 : 0);
        ctx.result.set_number((double)cmp);
        return;
    }

    // With relativeTo: add each duration's date part to relativeTo's date and
    // compute total nanoseconds relative to that same origin, then compare.
    CivilDate rel_date;
    if (relative_to.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
        zdt_wall_fields(relative_to, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);
        rel_date = { .y = wy, .m = wm, .d = wd };
    } else {
        rel_date = { .y = relative_to.extra.temporal.long_a,
                     .m = relative_to.extra.temporal.long_b,
                     .d = relative_to.extra.temporal.long_c };
    }

    if (!is_cal_unit(default_largest_unit(da)) && !is_cal_unit(default_largest_unit(db))) {
        int128 na = duration_to_time_ns(da);
        int128 nb = duration_to_time_ns(db);
        long cmp = na < nb ? -1 : (na > nb ? 1 : 0);
        ctx.result.set_number((double)cmp);
        return;
    }

    int128 total_a = duration_total_ns_from(rel_date, da);
    int128 total_b = duration_total_ns_from(rel_date, db);
    long cmp = total_a < total_b ? -1 : (total_a > total_b ? 1 : 0);
    ctx.result.set_number((double)cmp);
}

// Adds a duration's date part (years/months/weeks/days, with days folded in
// from time-only overflow) to `rel_date` and returns the total nanoseconds
// from `rel_date` (midnight) to the resulting date-time. Mirrors the
// relativeTo path of builtin_temporal_duration_proto_round.
fn int128 duration_total_ns_from(CivilDate rel_date, temporal::DurationParts dur) {
    int128 time_only_ns = (int128)0;
    time_only_ns += (int128)dur.hours   * 3600000000000L;
    time_only_ns += (int128)dur.minutes *   60000000000L;
    time_only_ns += (int128)dur.seconds *    1000000000L;
    time_only_ns += (int128)dur.ms      *       1000000L;
    time_only_ns += (int128)dur.us      *          1000L;
    time_only_ns += (int128)dur.ns;

    long target_time_days = (long)(time_only_ns / 86400000000000L);
    int128 target_time_rem = time_only_ns % 86400000000000L;
    if (time_only_ns < 0 && target_time_rem != 0) {
        target_time_days -= 1;
        target_time_rem += 86400000000000L;
    }

    long adj_days = dur.days + target_time_days;

    CivilDate target_date = rel_date;
    if (dur.years != 0) target_date = temporal::add_months(target_date, dur.years * 12, temporal::OverflowKind.CONSTRAIN);
    if (dur.months != 0) target_date = temporal::add_months(target_date, dur.months, temporal::OverflowKind.CONSTRAIN);
    if (dur.weeks != 0) target_date = temporal::add_days(target_date, dur.weeks * 7);
    if (adj_days != 0) target_date = temporal::add_days(target_date, adj_days);

    long rel_epoch = temporal::epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
    long tgt_epoch = temporal::epoch_days_from_civil(target_date.y, (int)target_date.m, (int)target_date.d);
    return (int128)(tgt_epoch - rel_epoch) * 86400000000000L + target_time_rem;
}

// Shared coercion from a string, Duration, or property bag into a Duration.
// Returns true on success; on failure throws and writes `ctx.should_throw`.
// Reused by the + / - / until / since / round operations on every Temporal
// type that takes a Duration argument.
fn bool duration_from_arg(BuiltinContext* ctx, TVal* arg, temporal::DurationParts* out) {
    // Duration.from and Duration.compare need the full ToTemporalDuration
    // validation: integral fields, sign consistency, and a recognized field.
    return duration_record_from_arg(ctx, arg, out);
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

// Resolve the fractional-second precision, rounding mode, and rounding
// increment (in nanoseconds) for Duration.prototype.toString(options).
// Unlike to_string_precision (shared by Instant/ZonedDateTime, which also
// accept smallestUnit "minute" and larger units are always a RangeError for
// them too), Duration.toString restricts smallestUnit to the time units at
// or below "second" — "minute", "hour", and any calendar unit are a
// RangeError here. Options are read in the spec's alphabetical order:
// fractionalSecondDigits, roundingMode, smallestUnit.
fn bool duration_to_string_precision(BuiltinContext* ctx, int* digits, TemporalRoundMode* rm, long* incr_ns) {
    *digits = -1;   // auto
    *rm = TemporalRoundMode.TRUNC;
    *incr_ns = 1;
    if (ctx.argc < 1) return true;
    TVal ov = ctx.regs[ctx.base_reg + 0];
    if (ov.is_undefined()) return true;
    if (!ov.is_object() || ov.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    HObject* opts = (HObject*)ov.get_heapptr();

    TVal f = prop_or_undefined_pa(ctx, opts, "fractionalSecondDigits");
    if (ctx.should_throw) return false;
    if (!f.is_undefined()) {
        // GetStringOrNumberOption branches on the ORIGINAL value's type: a
        // Number is used numerically (floored, then range-checked), while
        // anything else is stringified and must match a valid string option
        // — here only "auto". A non-Number is never numerically parsed, so
        // e.g. 2n and {} are RangeErrors even though they stringify to "2"
        // and "[object Object]".
        if (f.is_numeric()) {
            double dv = f.get_number_or_fastint();
            double n = math::floor(dv);
            if (math::is_nan(dv) || n < 0 || n > 9) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be \"auto\" or 0-9");
                return false;
            }
            *digits = (int)n;
            // A numeric digit count also fixes the rounding increment, not
            // just the rendered precision: {fractionalSecondDigits: 6,
            // roundingMode: "ceil"} must round to 1us even without
            // smallestUnit.
            *incr_ns = (*digits == 9) ? 1 : ns_pow10(9 - *digits);
        } else {
            HString* s = builtin_to_string_vm(ctx, &f);
            if (ctx.should_throw) return false;
            if (s == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "fractionalSecondDigits must be a number or \"auto\"");
                return false;
            }
            char[] v = s.get_cstr()[:s.blen];
            if (v == "auto") { *digits = -1; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be \"auto\" or 0-9");
                return false;
            }
        }
    }

    TVal rmv = prop_or_undefined_pa(ctx, opts, "roundingMode");
    if (ctx.should_throw) return false;
    if (!rmv.is_undefined()) {
        HString* rm_s = builtin_to_string_vm(ctx, &rmv);
        if (ctx.should_throw) return false;
        if (rm_s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "roundingMode must be a string"); return false; }
        char[] v = rm_s.get_cstr()[:rm_s.blen];
        if (v == "ceil") { *rm = TemporalRoundMode.CEIL; }
        else if (v == "floor") { *rm = TemporalRoundMode.FLOOR; }
        else if (v == "expand") { *rm = TemporalRoundMode.EXPAND; }
        else if (v == "trunc") { *rm = TemporalRoundMode.TRUNC; }
        else if (v == "halfCeil") { *rm = TemporalRoundMode.HALF_CEIL; }
        else if (v == "halfFloor") { *rm = TemporalRoundMode.HALF_FLOOR; }
        else if (v == "halfExpand") { *rm = TemporalRoundMode.HALF_EXPAND; }
        else if (v == "halfTrunc") { *rm = TemporalRoundMode.HALF_TRUNC; }
        else if (v == "halfEven") { *rm = TemporalRoundMode.HALF_EVEN; }
        else { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode"); return false; }
    }

    TVal su = prop_or_undefined_pa(ctx, opts, "smallestUnit");
    if (ctx.should_throw) return false;
    if (!su.is_undefined()) {
        HString* su_s = builtin_to_string_vm(ctx, &su);
        if (ctx.should_throw) return false;
        if (su_s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "smallestUnit option must be a string"); return false; }
        char[] v = su_s.get_cstr()[:su_s.blen];
        // ToSecondsStringPrecisionRecord's [[Increment]]/[[Unit]] mapping,
        // restricted to units <= second (minute/hour and any calendar unit
        // are a RangeError for Duration.toString per spec step "If
        // smallestUnit is either hour or minute, throw a RangeError").
        if (v == "second" || v == "seconds")           { *digits = 0; *incr_ns = 1000000000L; }
        else if (v == "millisecond" || v == "milliseconds") { *digits = 3; *incr_ns = 1000000L; }
        else if (v == "microsecond" || v == "microseconds") { *digits = 6; *incr_ns = 1000L; }
        else if (v == "nanosecond" || v == "nanoseconds")   { *digits = 9; *incr_ns = 1L; }
        else { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit"); return false; }
    }
    return true;
}

fn void builtin_temporal_duration_proto_toString(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    int digits;
    TemporalRoundMode rm;
    long incr_ns;
    if (!duration_to_string_precision(ctx, &digits, &rm, &incr_ns)) return;

    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());

    // No rounding requested (fractionalSecondDigits: "auto" and no
    // smallestUnit, i.e. RoundTimeDuration's increment is 1ns) -> format
    // with the requested (possibly still fixed, e.g. "auto") precision
    // without touching the stored value.
    if (incr_ns == 1) {
        char[160] buf;
        usz len = temporal::format_duration_precision(d, digits, &buf, 160);
        ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
        return;
    }

    // Round the time portion (RoundTimeDuration): combine hours..ns into a
    // single nanosecond count (using int128 so large values don't lose
    // precision through double math), round to a multiple of incr_ns, then
    // rebalance back into hours/minutes/seconds/ms/us/ns. Unlike duration
    // arithmetic, this never folds overflow into days — CombineDateAndTime
    // Duration leaves the date part untouched, and toString's smallestUnit
    // can only be second/millisecond/microsecond/nanosecond (never hour or
    // minute), so the largest unit stays within the time portion here.
    int128 total_ns = (int128)0;
    total_ns += (int128)d.hours   * 3600000000000L;
    total_ns += (int128)d.minutes *   60000000000L;
    total_ns += (int128)d.seconds *    1000000000L;
    total_ns += (int128)d.ms      *       1000000L;
    total_ns += (int128)d.us      *          1000L;
    total_ns += (int128)d.ns;

    int128 sign_i = total_ns < 0 ? (int128)(-1) : (int128)1;
    int128 mag = total_ns < 0 ? -total_ns : total_ns;
    int128 incr = (int128)incr_ns;
    int128 q = mag / incr;
    int128 remv = mag % incr;
    if (remv != 0) {
        bool round_up;
        switch (rm) {
            case TemporalRoundMode.TRUNC:
            case TemporalRoundMode.FLOOR: round_up = false; break;
            case TemporalRoundMode.EXPAND:
            case TemporalRoundMode.CEIL: round_up = true; break;
            default: {
                // Half-* modes: compare remainder against half the
                // increment. mode_for_negative_magnitude flips ceil/floor
                // bias for a negative-signed duration so half-ceil/half-floor
                // remain magnitude-symmetric around zero (mirrors
                // round_long_ns's handling elsewhere in this file).
                TemporalRoundMode eff = sign_i < 0 ? mode_for_negative_magnitude(rm) : rm;
                int128 twice = remv * 2;
                if (twice < incr) { round_up = false; }
                else if (twice > incr) { round_up = true; }
                else {
                    switch (eff) {
                        case TemporalRoundMode.HALF_TRUNC:
                        case TemporalRoundMode.HALF_FLOOR: round_up = false; break;
                        case TemporalRoundMode.HALF_EXPAND:
                        case TemporalRoundMode.HALF_CEIL: round_up = true; break;
                        case TemporalRoundMode.HALF_EVEN: round_up = (q & 1) != 0; break;
                        default: round_up = false; break;
                    }
                }
                break;
            }
        }
        if (round_up) q += 1;
    }
    int128 rounded_ns = q * incr * sign_i;

    // Rebalance rounded_ns back into days/hours/minutes/seconds/ms/us/ns
    // per TemporalDurationFromInternal(internalDuration, roundedLargestUnit)
    // where roundedLargestUnit = LargerOfTwoTemporalUnits(
    // DefaultTemporalLargestUnit(<pre-rounding duration>), second):
    //   - date category (years/months/weeks/days present, i.e. any of
    //     those is non-zero): time balances all the way to hours, AND
    //     hour-overflow folds into the date part's days (verified against
    //     the reference polyfill: {days:5, seconds:90000, ms:900} with
    //     smallestUnit "second"/halfExpand -> "P6DT1H1S", i.e. 25.9h
    //     contributes +1 day).
    //   - hour category (no date fields, but hours present): time balances
    //     to hours only (no day fold).
    //   - minute category (no date/hour fields, but minutes present): time
    //     balances to minutes only (no hour fold — {minutes:1,
    //     seconds:90000} stays "PT1501M0S", not "PT25H1M0S").
    //   - otherwise (only seconds/ms/us/ns present, or an all-zero
    //     duration): time collapses fully into seconds (no minute fold —
    //     {seconds:59,ms:900} rounding past 60s stays "PT60S", not
    //     "PT1M0S").
    bool has_date_unit = d.years != 0 || d.months != 0 || d.weeks != 0 || d.days != 0;
    bool has_hour = d.hours != 0;
    bool has_minute = d.minutes != 0;

    temporal::DurationParts rd = d;
    int128 rmag = rounded_ns < 0 ? -rounded_ns : rounded_ns;
    long rsign = rounded_ns < 0 ? -1 : 1;
    if (has_date_unit) {
        long extra_days = rsign * (long)(rmag / 86400000000000L); rmag %= 86400000000000L;
        rd.days   += extra_days;
        rd.hours   = rsign * (long)(rmag / 3600000000000L); rmag %= 3600000000000L;
        rd.minutes = rsign * (long)(rmag /   60000000000L); rmag %=   60000000000L;
    } else if (has_hour) {
        rd.hours   = rsign * (long)(rmag / 3600000000000L); rmag %= 3600000000000L;
        rd.minutes = rsign * (long)(rmag /   60000000000L); rmag %=   60000000000L;
    } else if (has_minute) {
        rd.hours   = 0;
        rd.minutes = rsign * (long)(rmag /   60000000000L); rmag %=   60000000000L;
    } else {
        rd.hours   = 0;
        rd.minutes = 0;
    }
    rd.seconds = rsign * (long)(rmag /    1000000000L); rmag %=    1000000000L;
    rd.ms      = rsign * (long)(rmag /       1000000L); rmag %=       1000000L;
    rd.us      = rsign * (long)(rmag /          1000L); rmag %=          1000L;
    rd.ns      = rsign * (long)(rmag);

    // Per spec, after rounding the time portion must remain within ±2^53
    // seconds (RegulateTimeDuration / IsValidDuration). Calendar-unit
    // overflows (year/month/week) are unbounded, but seconds here is a
    // value derived solely from the time portion. Fold any pre-existing
    // date-unit days into the bound check too, so {days: N, seconds: x}
    // with x + N*86400 ≥ 2^53 also throws.
    int128 sec_total = (int128)rd.seconds + (int128)rd.days * 86400L;
    int128 max_secs = (int128)9007199254740992L;  // 2^53
    if (sec_total >= max_secs || sec_total <= -max_secs) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration out of range");
        return;
    }

    char[160] buf;
    usz len = temporal::format_duration_precision(rd, digits, &buf, 160);
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
    // Convert each time column to ns, sum, then split. The per-field sums
    // must widen to int128 before adding: two fields near LONG_MAX (the
    // spec allows ms/us/ns up to ~9e18 each) overflow a long sum.
    int128 total_ns = (int128)0;
    total_ns += ((int128)a.hours + (int128)b.hours)    * 3600000000000L;
    total_ns += ((int128)a.minutes + (int128)b.minutes) *   60000000000L;
    total_ns += ((int128)a.seconds + (int128)b.seconds) *    1000000000L;
    total_ns += ((int128)a.ms + (int128)b.ms)           *       1000000L;
    total_ns += ((int128)a.us + (int128)b.us)           *          1000L;
    total_ns += (int128)a.ns + (int128)b.ns;
    // Per spec, IsValidDuration rejects any duration whose time column
    // (after balancing days into seconds) exceeds ±2^53 seconds. Year/month/week
    // units are unbounded in the spec — only their absolute value needs to
    // remain within int64. We validate only the time column here; caller is
    // responsible for year/month range.
    int128 days_secs = (int128)d * 86400L;
    int128 combined_secs = days_secs + total_ns / 1000000000L;
    int128 max_secs = (int128)9007199254740992L;  // 2^53
    if (combined_secs >= max_secs || combined_secs <= -max_secs) {
        // Caller decides whether to throw — signal failure.
        return false;
    }
    // Spec AddDuration with no relativeTo: any calendar unit (years, months,
    // weeks) in either operand is a RangeError.
    bool no_calendar_units = (y == 0 && mo == 0 && w == 0 && a.years == 0
        && b.years == 0 && a.months == 0 && b.months == 0
        && a.weeks == 0 && b.weeks == 0);
    if (!no_calendar_units) return false;

    // BalanceTimeDuration(norm, largestUnit) with largestUnit = the larger of
    // the two operands' default largest units: the time total truncates toward
    // zero into whole units of largestUnit and the same-sign remainder fills
    // the columns below it, so {minutes:100,...} - {minutes:10,...} reports
    // 91m while P50DT50H + itself balances 100 of the 101 hours into days.
    TemporalUnit largest = default_largest_unit(a);
    TemporalUnit largest_b = default_largest_unit(b);
    if (largest_b < largest) largest = largest_b;
    out.years = 0;
    out.months = 0;
    out.weeks = 0;
    out.days = d;
    out.hours = 0; out.minutes = 0; out.seconds = 0;
    out.ms = 0; out.us = 0; out.ns = 0;
    int128 rem = total_ns;
    if (largest <= TemporalUnit.DAY) {
        out.days += (long)(rem / 86400000000000L);
        rem %= 86400000000000L;
    }
    if (largest <= TemporalUnit.HOUR) {
        out.hours = (long)(rem / 3600000000000L);
        rem %= 3600000000000L;
    }
    if (largest <= TemporalUnit.MINUTE) {
        out.minutes = (long)(rem / 60000000000L);
        rem %= 60000000000L;
    }
    if (largest <= TemporalUnit.SECOND) {
        out.seconds = (long)(rem / 1000000000L);
        rem %= 1000000000L;
    }
    if (largest <= TemporalUnit.MILLISECOND) {
        out.ms = (long)(rem / 1000000L);
        rem %= 1000000L;
    }
    if (largest <= TemporalUnit.MICROSECOND) {
        out.us = (long)(rem / 1000L);
        rem %= 1000L;
    }
    out.ns = (long)rem;
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
    if (!add_durations_no_relative(a, other, &result)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Duration arithmetic produced an out-of-range result");
        return;
    }
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
    if (!add_durations_no_relative(a, other, &result)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Duration arithmetic produced an out-of-range result");
        return;
    }
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
    if (!reject_temporal_object_bag(ctx, bag)) return;
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    // Spec reads fields in alphabetical order: days, hours, microseconds,
    // milliseconds, minutes, months, nanoseconds, seconds, weeks, years.
    // All 10 must be probed even when absent so a Proxy observer sees every
    // get call (order-of-operations test fixture depends on this).
    char[][] names = { "days", "hours", "microseconds", "milliseconds",
        "minutes", "months", "nanoseconds", "seconds", "weeks", "years" };
    long*[10] slots = { &d.days, &d.hours, &d.us, &d.ms,
        &d.minutes, &d.months, &d.ns, &d.seconds, &d.weeks, &d.years };
    Vm* v = (Vm*)ctx.vm;
    bool found_any = false;
    for (int k = 0; k < 10; k++) {
        TVal pv = prop_or_undefined_pa(ctx, bag, names[k]);
        if (ctx.should_throw) return;
        if (pv.is_undefined()) continue;
        found_any = true;
        double val = vm::vm_to_number(v, &pv);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        if (!duration_field_integral(ctx, val)) return;
        long whole = (long)math::trunc(val);
        *slots[k] = whole;
    }
    if (!found_any) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.with requires at least one recognized property");
        return;
    }
    if (!is_valid_duration(&d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid duration result");
        return;
    }
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_duration_proto_toJSON(BuiltinContext* ctx) {
    // toJSON takes no options and always formats at "auto" precision, so the
    // caller's arguments must not reach the toString delegate.
    ctx.argc = 0;
    builtin_temporal_duration_proto_toString(ctx);
}

fn void builtin_temporal_duration_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    ctx.argc = 0;
    builtin_temporal_duration_proto_toString(ctx);
}

fn void builtin_temporal_duration_proto_valueOf(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Duration cannot be converted to a primitive number");
}

// ============================================================================
// Duration.prototype.round / .total — unit, rounding, helpers
// ============================================================================

enum TemporalUnit : int {
    YEAR, MONTH, WEEK, DAY,
    HOUR, MINUTE, SECOND, MILLISECOND, MICROSECOND, NANOSECOND,
}

enum TemporalRoundMode : int {
    CEIL, FLOOR, EXPAND, TRUNC,
    HALF_CEIL, HALF_FLOOR, HALF_EXPAND, HALF_TRUNC, HALF_EVEN,
}

// spec's IsCalendarUnit: years/months/weeks only (used for plain-relativeTo
// "calendar unit" branches that should NOT include days)
fn bool is_cal_unit(TemporalUnit u) { return u <= TemporalUnit.WEEK; }

// spec's TemporalUnitCategory == "date": years/months/weeks/days
fn bool is_date_unit(TemporalUnit u) { return u <= TemporalUnit.DAY; }

fn long unit_ns_divisor(TemporalUnit u) {
    switch (u) {
        case TemporalUnit.HOUR:        return 3600000000000L;
        case TemporalUnit.MINUTE:      return   60000000000L;
        case TemporalUnit.SECOND:      return    1000000000L;
        case TemporalUnit.MILLISECOND: return       1000000L;
        case TemporalUnit.MICROSECOND: return          1000L;
        case TemporalUnit.NANOSECOND:  return             1L;
        default: return 0;
    }
}

fn long max_round_incr(TemporalUnit u) {
    switch (u) {
        case TemporalUnit.HOUR:        return 24;
        case TemporalUnit.MINUTE:      return 60;
        case TemporalUnit.SECOND:      return 60;
        case TemporalUnit.MILLISECOND: return 1000;
        case TemporalUnit.MICROSECOND: return 1000;
        case TemporalUnit.NANOSECOND:  return 1000;
        default: return 0;
    }
}

fn TemporalUnit larger_unit(TemporalUnit a, TemporalUnit b) { return a < b ? a : b; }

// Throws unless the increment is a legal divisor of the next-higher unit
// (divides it evenly, and is not the full unit). Calendar units have no fixed
// length, so any positive integer is accepted there. Returns false after
// throwing.
fn bool validate_rounding_increment(BuiltinContext* ctx, TemporalUnit unit, double increment) {
    if (increment < 1.0 || increment > 1e9) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
        return false;
    }
    long max_incr = max_round_incr(unit);
    if (max_incr > 0) {
        if ((double)max_incr / increment != math::floor((double)max_incr / increment)
            || increment == (double)max_incr) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
            return false;
        }
    }
    return true;
}

fn TemporalUnit default_largest_unit(temporal::DurationParts d) {
    if (d.years != 0)   return TemporalUnit.YEAR;
    if (d.months != 0)  return TemporalUnit.MONTH;
    if (d.weeks != 0)   return TemporalUnit.WEEK;
    if (d.days != 0)    return TemporalUnit.DAY;
    if (d.hours != 0)   return TemporalUnit.HOUR;
    if (d.minutes != 0) return TemporalUnit.MINUTE;
    if (d.seconds != 0) return TemporalUnit.SECOND;
    if (d.ms != 0)      return TemporalUnit.MILLISECOND;
    if (d.us != 0)      return TemporalUnit.MICROSECOND;
    return TemporalUnit.NANOSECOND;
}

// Split a signed nanosecond count across the time units from `largest` down to
// nanoseconds. Callers round to smallestUnit first, which leaves the units
// below it zero.
//
// Division truncates toward zero, so a negative count gives uniformly negative
// fields, as a Duration requires.
fn temporal::DurationParts time_ns_split(long v, TemporalUnit largest) {
    temporal::DurationParts dp = {};
    if (largest <= TemporalUnit.HOUR) {
        dp.hours = v / 3_600_000_000_000L;
        v %= 3_600_000_000_000L;
    }
    if (largest <= TemporalUnit.MINUTE) {
        dp.minutes = v / 60_000_000_000L;
        v %= 60_000_000_000L;
    }
    if (largest <= TemporalUnit.SECOND) {
        dp.seconds = v / 1_000_000_000L;
        v %= 1_000_000_000L;
    }
    if (largest <= TemporalUnit.MILLISECOND) {
        dp.ms = v / 1_000_000L;
        v %= 1_000_000L;
    }
    if (largest <= TemporalUnit.MICROSECOND) {
        dp.us = v / 1000L;
        v %= 1000L;
    }
    dp.ns = v;
    return dp;
}

// Round a signed nanosecond count to a multiple of `incr_ns`.
//
// until/since round by magnitude: "trunc" moves toward zero in both directions.
// The rounding therefore runs on the absolute value, with the sign reapplied at
// the end, and the direction-sensitive modes (ceil, floor and their half-*
// forms) mirrored for a negative count.
fn long round_long_ns(long v, long incr_ns, TemporalRoundMode mode) {
    bool neg = v < 0;
    long mag = neg ? -v : v;
    if (neg) mode = mode_for_negative_magnitude(mode);

    long q = mag / incr_ns;
    long r = mag - q * incr_ns;
    if (r != 0) {
        switch (mode) {
            case TemporalRoundMode.TRUNC:
            case TemporalRoundMode.FLOOR: break;
            case TemporalRoundMode.EXPAND:
            case TemporalRoundMode.CEIL: q += 1; break;
            default: {
                long twice = r * 2;
                if (twice > incr_ns) {
                    q += 1;
                } else if (twice == incr_ns) {
                    switch (mode) {
                        case TemporalRoundMode.HALF_TRUNC:
                        case TemporalRoundMode.HALF_FLOOR: break;
                        case TemporalRoundMode.HALF_EXPAND:
                        case TemporalRoundMode.HALF_CEIL: q += 1; break;
                        case TemporalRoundMode.HALF_EVEN: if ((q & 1) != 0) q += 1; break;
                        default: break;
                    }
                }
                break;
            }
        }
    }
    long out = q * incr_ns;
    return neg ? -out : out;
}

// int128 counterpart of round_long_ns, for nanosecond counts that exceed the
// 64-bit range (~292 years). Same magnitude-first rounding, sign reapplied at
// the end, direction-sensitive modes mirrored for a negative count.
fn int128 round_long_ns_128(int128 v, int128 incr_ns, TemporalRoundMode mode) {
    bool neg = v < 0;
    int128 mag = neg ? -v : v;
    if (neg) mode = mode_for_negative_magnitude(mode);

    int128 q = mag / incr_ns;
    int128 r = mag - q * incr_ns;
    if (r != 0) {
        switch (mode) {
            case TemporalRoundMode.TRUNC:
            case TemporalRoundMode.FLOOR: break;
            case TemporalRoundMode.EXPAND:
            case TemporalRoundMode.CEIL: q += 1; break;
            default: {
                int128 twice = r * 2;
                if (twice > incr_ns) {
                    q += 1;
                } else if (twice == incr_ns) {
                    switch (mode) {
                        case TemporalRoundMode.HALF_TRUNC:
                        case TemporalRoundMode.HALF_FLOOR: break;
                        case TemporalRoundMode.HALF_EXPAND:
                        case TemporalRoundMode.HALF_CEIL: q += 1; break;
                        case TemporalRoundMode.HALF_EVEN: if ((q & 1) != 0) q += 1; break;
                        default: break;
                    }
                }
                break;
            }
        }
    }
    int128 out = q * incr_ns;
    return neg ? -out : out;
}

// The mode giving the same result when applied to a negative value's magnitude.
// On a magnitude, "toward negative infinity" means "toward zero", so ceil and
// floor swap. trunc and expand are defined relative to zero and pass through.
fn TemporalRoundMode mode_for_negative_magnitude(TemporalRoundMode m) {
    switch (m) {
        case TemporalRoundMode.CEIL:       return TemporalRoundMode.FLOOR;
        case TemporalRoundMode.FLOOR:      return TemporalRoundMode.CEIL;
        case TemporalRoundMode.HALF_CEIL:  return TemporalRoundMode.HALF_FLOOR;
        case TemporalRoundMode.HALF_FLOOR: return TemporalRoundMode.HALF_CEIL;
        default: return m;
    }
}

// Inverse of civil_time_to_ns; the input must lie in [0, day).
fn temporal::CivilTime civil_time_from_ns(long total) {
    temporal::CivilTime t;
    t.h  = total / 3600000000000L; total %= 3600000000000L;
    t.mi = total /   60000000000L; total %=   60000000000L;
    t.s  = total /    1000000000L; total %=    1000000000L;
    t.ms = total /       1000000L; total %=       1000000L;
    t.us = total /          1000L;
    t.ns = total %          1000L;
    return t;
}

// 10^e nanoseconds, for e in [0, 9]: the rounding increment that a
// fractional-second digit count implies.
fn long ns_pow10(int e) {
    long v = 1;
    for (int i = 0; i < e; i++) v *= 10;
    return v;
}

fn bool parse_unit_str(char[] s, TemporalUnit* out) {
    if (s == "year"  || s == "years")      { *out = TemporalUnit.YEAR; return true; }
    if (s == "month" || s == "months")     { *out = TemporalUnit.MONTH; return true; }
    if (s == "week"  || s == "weeks")      { *out = TemporalUnit.WEEK; return true; }
    if (s == "day"   || s == "days")       { *out = TemporalUnit.DAY; return true; }
    if (s == "hour"  || s == "hours")      { *out = TemporalUnit.HOUR; return true; }
    if (s == "minute" || s == "minutes")   { *out = TemporalUnit.MINUTE; return true; }
    if (s == "second" || s == "seconds")   { *out = TemporalUnit.SECOND; return true; }
    if (s == "millisecond" || s == "milliseconds") { *out = TemporalUnit.MILLISECOND; return true; }
    if (s == "microsecond" || s == "microseconds") { *out = TemporalUnit.MICROSECOND; return true; }
    if (s == "nanosecond" || s == "nanoseconds")   { *out = TemporalUnit.NANOSECOND; return true; }
    return false;
}

fn bool parse_rm_str(char[] s, TemporalRoundMode* out) {
    if (s == "ceil")       { *out = TemporalRoundMode.CEIL; return true; }
    if (s == "floor")      { *out = TemporalRoundMode.FLOOR; return true; }
    if (s == "expand")     { *out = TemporalRoundMode.EXPAND; return true; }
    if (s == "trunc")      { *out = TemporalRoundMode.TRUNC; return true; }
    if (s == "halfCeil")   { *out = TemporalRoundMode.HALF_CEIL; return true; }
    if (s == "halfFloor")  { *out = TemporalRoundMode.HALF_FLOOR; return true; }
    if (s == "halfExpand") { *out = TemporalRoundMode.HALF_EXPAND; return true; }
    if (s == "halfTrunc")  { *out = TemporalRoundMode.HALF_TRUNC; return true; }
    if (s == "halfEven")   { *out = TemporalRoundMode.HALF_EVEN; return true; }
    return false;
}

fn double round_num_to_incr(double x, double incr, TemporalRoundMode mode) {
    if (incr == 1) {
        // Round to nearest integer.
        switch (mode) {
            case TemporalRoundMode.CEIL:       return math::ceil(x);
            case TemporalRoundMode.FLOOR:      return math::floor(x);
            case TemporalRoundMode.EXPAND:     return (x >= 0) ? math::ceil(x) : math::floor(x);
            case TemporalRoundMode.TRUNC:      return (x >= 0) ? math::floor(x) : math::ceil(x);
            case TemporalRoundMode.HALF_CEIL:  { double f = math::floor(x); return (x - f >= 0.5) ? f + 1 : f; }
            case TemporalRoundMode.HALF_FLOOR: { double f = math::floor(x); return (x - f > 0.5) ? f + 1 : f; }
            case TemporalRoundMode.HALF_EXPAND: {
                if (x >= 0) { double f = math::floor(x); return (x - f >= 0.5) ? f + 1 : f; }
                double c = math::ceil(x); return (c - x >= 0.5) ? c - 1 : c;
            }
            case TemporalRoundMode.HALF_TRUNC: {
                if (x >= 0) { double f = math::floor(x); return (x - f > 0.5) ? f + 1 : f; }
                double c = math::ceil(x); return (c - x > 0.5) ? c - 1 : c;
            }
            case TemporalRoundMode.HALF_EVEN: {
                double f = math::floor(x);
                double frac = x - f;
                if (frac < 0.5) return f;
                if (frac > 0.5) return f + 1;
                return (math::floor(f / 2) * 2 == f) ? f : f + 1;
            }
        }
    }
    double q = x / incr;
    double r1, r2;
    if (x >= 0) {
        r1 = math::floor(q) * incr;
        r2 = r1 + incr;
    } else {
        r2 = math::ceil(q) * incr;
        r1 = r2 - incr;
    }
    double rem = x - r1;
    switch (mode) {
        case TemporalRoundMode.CEIL:       return r2;
        case TemporalRoundMode.FLOOR:      return r1;
        case TemporalRoundMode.EXPAND:     return (x >= 0) ? r2 : r1;
        case TemporalRoundMode.TRUNC:      return (x >= 0) ? r1 : r2;
        case TemporalRoundMode.HALF_CEIL:  return (rem >= incr / 2) ? r2 : r1;
        case TemporalRoundMode.HALF_FLOOR: return (rem > incr / 2) ? r2 : r1;
        case TemporalRoundMode.HALF_EXPAND: return ((x >= 0 ? rem >= incr / 2 : rem > incr / 2)) ? r2 : r1;
        case TemporalRoundMode.HALF_TRUNC: return ((x >= 0 ? rem > incr / 2 : rem >= incr / 2)) ? r2 : r1;
        case TemporalRoundMode.HALF_EVEN: {
            double half = incr / 2;
            if (rem < half) return r1;
            if (rem > half) return r2;
            // Tie: pick the multiple whose factor (qb) is even.
            double qb = math::floor(q);
            if (math::floor(qb / 2) * 2 == qb) return r1;
            return r2;
        }
    }
    return x;
}

fn int128 duration_to_time_ns(temporal::DurationParts d) {
    int128 ns = (int128)0;
    ns += (int128)d.days    * 86400000000000L;
    ns += (int128)d.hours   * 3600000000000L;
    ns += (int128)d.minutes *   60000000000L;
    ns += (int128)d.seconds *    1000000000L;
    ns += (int128)d.ms      *       1000000L;
    ns += (int128)d.us      *          1000L;
    ns += (int128)d.ns;
    return ns;
}

fn void decompose_ns(long ns, TemporalUnit largest, temporal::DurationParts* out) {
    long abs_ns = ns < 0 ? -ns : ns;
    long sign = ns < 0 ? -1 : 1;
    long rem = abs_ns;
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
    if (largest == TemporalUnit.DAY) {
        out.days = sign * (long)(rem / 86400000000000L);
        rem %= 86400000000000L;
    } else if (largest == TemporalUnit.WEEK) {
        long total_days = (long)(rem / 86400000000000L);
        rem %= 86400000000000L;
        out.weeks = sign * (total_days / 7);
        out.days = sign * (total_days % 7);
    }
    // Decompose time units only down to largest_unit.
    if (largest <= TemporalUnit.HOUR) {
        out.hours = sign * (long)(rem / 3600000000000L);
        rem %= 3600000000000L;
    }
    if (largest <= TemporalUnit.MINUTE) {
        out.minutes = sign * (long)(rem / 60000000000L);
        rem %= 60000000000L;
    }
    if (largest <= TemporalUnit.SECOND) {
        out.seconds = sign * (long)(rem / 1000000000L);
        rem %= 1000000000L;
    }
    if (largest <= TemporalUnit.MILLISECOND) {
        out.ms = sign * (long)(rem / 1000000L);
        rem %= 1000000L;
    }
    if (largest <= TemporalUnit.MICROSECOND) {
        out.us = sign * (long)(rem / 1000L);
        rem %= 1000L;
    }
    out.ns = sign * (long)rem;
}

// ℝ(𝔽(x)): a Duration slot is a float64-representable number. The spec stores
// every component via this conversion in CreateTemporalDuration; below 2^53 it
// is the identity, and above it the value snaps to the nearest float64. That
// loss shows up only once a component exceeds 2^53 (a microseconds field for a
// 584-year since() is ~1.8e16), so a split carried out in exact int128 must
// round each field back through float64 to reproduce it.
fn long f64_field(long x) { return (long)(double)x; }

// The inverse of decompose_ns for values too large for int64 (any duration
// longer than ~292 years in nanoseconds). Like decompose_ns it walks the unit
// ladder from `largest` down; each field is ℝ(𝔽())-rounded and the middle
// int128 remainder avoids the 64-bit overflow that a `long` count would hit.
fn void decompose_ns_128(int128 ns, TemporalUnit largest, temporal::DurationParts* out) {
    long sign = ns < 0 ? -1 : 1;
    int128 rem = ns < 0 ? -ns : ns;
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
    if (largest == TemporalUnit.DAY) {
        out.days = sign * (long)(rem / 86400000000000L);
        rem %= 86400000000000L;
    } else if (largest == TemporalUnit.WEEK) {
        int128 total_days = rem / 86400000000000L;
        rem %= 86400000000000L;
        out.weeks = sign * (long)(total_days / 7);
        out.days = sign * (long)(total_days % 7);
    }
    // Decompose time units only down to largest_unit.
    if (largest <= TemporalUnit.HOUR) {
        out.hours = sign * f64_field((long)(rem / 3600000000000L));
        rem %= 3600000000000L;
    }
    if (largest <= TemporalUnit.MINUTE) {
        out.minutes = sign * f64_field((long)(rem / 60000000000L));
        rem %= 60000000000L;
    }
    if (largest <= TemporalUnit.SECOND) {
        out.seconds = sign * f64_field((long)(rem / 1000000000L));
        rem %= 1000000000L;
    }
    if (largest <= TemporalUnit.MILLISECOND) {
        out.ms = sign * f64_field((long)(rem / 1000000L));
        rem %= 1000000L;
    }
    if (largest <= TemporalUnit.MICROSECOND) {
        out.us = sign * f64_field((long)(rem / 1000L));
        rem %= 1000L;
    }
    out.ns = sign * f64_field((long)rem);
}

// ============================================================================
// Temporal.Duration.prototype.round
// ============================================================================

fn void builtin_temporal_duration_proto_round(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    if (ctx.argc < 1 || arg_at(ctx, 0).is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.round requires an argument");
        return;
    }
    temporal::DurationParts dur = duration_value((HObject*)this_val.get_heapptr());

    TVal* round_to = arg_at(ctx, 0);
    bool string_shorthand = round_to.is_string();
    if (!string_shorthand && !round_to.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.round requires an object or string argument");
        return;
    }
    HObject* opts = null;
    TemporalUnit smallest_unit = TemporalUnit.NANOSECOND;
    bool smallest_was_set = false;
    TemporalUnit largest_unit = TemporalUnit.NANOSECOND;
    bool largest_was_set = false;
    double rounding_increment = 1;
    TemporalRoundMode rounding_mode = TemporalRoundMode.HALF_EXPAND;
    HObject* relative_to = null;
    bool largest_provided = false;

    if (string_shorthand) {
        HString* ss = builtin_to_string_vm(ctx, round_to);
        if (ctx.should_throw) return;
        if (!parse_unit_str(ss.get_cstr()[:ss.blen], &smallest_unit)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
            return;
        }
        smallest_was_set = true;
    } else {
        opts = (HObject*)round_to.get_heapptr();
        if (opts == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object or string");
            return;
        }
        // largestUnit
        TVal lu_tv = prop_or_undefined_pa(ctx, opts, "largestUnit");
        if (!lu_tv.is_undefined()) {
            largest_provided = true;
            HString* lu_s = builtin_to_string_vm(ctx, &lu_tv);
            if (ctx.should_throw) return;
            char[] lu_str = lu_s.get_cstr()[:lu_s.blen];
            if (lu_str != "auto") {
                largest_was_set = true;
                if (!parse_unit_str(lu_str, &largest_unit)) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid largestUnit");
                    return;
                }
            }
        }
        // relativeTo
        if (!read_relative_to_option(ctx, opts, &relative_to)) return;
        // roundingIncrement
        TVal ri_tv = prop_or_undefined_pa(ctx, opts, "roundingIncrement");
        if (!ri_tv.is_undefined()) {
            Vm* v = (Vm*)ctx.vm;
            double ri_val = vm::vm_to_number(v, &ri_tv);
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            if (math::is_nan(ri_val) || math::is_inf(ri_val)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a positive integer");
                return;
            }
            rounding_increment = math::floor(ri_val);
            if (rounding_increment < 1) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a positive integer");
                return;
            }
        }
        // roundingMode
        TVal rm_tv = prop_or_undefined_pa(ctx, opts, "roundingMode");
        if (!rm_tv.is_undefined()) {
            HString* rm_s = builtin_to_string_vm(ctx, &rm_tv);
            if (ctx.should_throw) return;
            if (!parse_rm_str(rm_s.get_cstr()[:rm_s.blen], &rounding_mode)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return;
            }
        }
        // smallestUnit
        TVal su_tv = prop_or_undefined_pa(ctx, opts, "smallestUnit");
        if (!su_tv.is_undefined()) {
            smallest_was_set = true;
            HString* su_s = builtin_to_string_vm(ctx, &su_tv);
            if (ctx.should_throw) return;
            if (!parse_unit_str(su_s.get_cstr()[:su_s.blen], &smallest_unit)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
                return;
            }
        }
    }

    TemporalUnit existing = default_largest_unit(dur);
    TemporalUnit default_lu = larger_unit(existing, smallest_unit);
    if (!largest_was_set) largest_unit = default_lu;

    if (!smallest_was_set && !largest_provided) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "at least one of smallestUnit or largestUnit must be provided");
        return;
    }
    if (larger_unit(largest_unit, smallest_unit) != largest_unit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "largestUnit must not be smaller than smallestUnit");
        return;
    }
    if (!validate_rounding_increment(ctx, smallest_unit, rounding_increment)) return;
    if (rounding_increment > 1 && largest_unit != smallest_unit && is_date_unit(smallest_unit)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement > 1 is not allowed with calendar smallestUnit unless largestUnit equals smallestUnit");
        return;
    }

    bool is_blank = dur.years == 0 && dur.months == 0 && dur.weeks == 0 && dur.days == 0 &&
                    dur.hours == 0 && dur.minutes == 0 && dur.seconds == 0 &&
                    dur.ms == 0 && dur.us == 0 && dur.ns == 0;
    if (is_blank && !is_cal_unit(smallest_unit) && smallest_unit != TemporalUnit.DAY &&
                    !is_cal_unit(largest_unit) && largest_unit != TemporalUnit.DAY) {
        temporal::DurationParts zero_dur = {};
        HObject*? obj_o = alloc_duration(ctx.heap, zero_dur);
        if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* obj = obj_o;
        obj.prototype = ctx.heap.temporal_duration_proto;
        ctx.result.set_object(obj);
        return;
    }

    // No-relativeTo: time-only path.
    if (relative_to == null) {
        if (is_cal_unit(existing) || is_cal_unit(largest_unit)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo is required for calendar units");
            return;
        }
        int128 time_ns = duration_to_time_ns(dur);
        // Spec's RoundTimeDuration is an integer operation on the time
        // duration (RoundNumberToIncrement on nanoseconds); rounding stays in
        // int128 so a duration longer than ~292 years does not overflow a
        // 64-bit count, and the ℝ(𝔽()) precision loss lands at decomposition.
        long divisor = (smallest_unit == TemporalUnit.DAY) ? 86400000000000L : unit_ns_divisor(smallest_unit);
        int128 incr_ns = (int128)((long)rounding_increment * divisor);
        if (incr_ns <= 0) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement too large");
            return;
        }
        int128 rounded_ns;
        if (incr_ns == 1) {
            rounded_ns = time_ns;
        } else {
            rounded_ns = round_long_ns_128(time_ns, incr_ns, rounding_mode);
        }
        temporal::DurationParts result;
        decompose_ns_128(rounded_ns, largest_unit, &result);
        HObject*? obj_o = alloc_duration(ctx.heap, result);
        if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* obj = obj_o;
        obj.prototype = ctx.heap.temporal_duration_proto;
        ctx.result.set_object(obj);
        return;
    }

    // With relativeTo: calendar-aware rounding path.
    // Spec algorithm for plainRelativeTo:
    // 1. ToInternalDurationRecordWith24HourDays(duration) → {date, time}
    // 2. AddTime(MidnightTimeRecord(), time) → targetTime
    // 3. AdjustDateDurationRecord(date, targetTime.days)
    // 4. CalendarDateAdd(calendar, relativeTo, dateDuration) → targetDate
    // 5. isoDateTime = (relativeTo, MidnightTimeRecord)
    // 6. targetDateTime = (targetDate, targetTime.time)
    // 7. DifferencePlainDateTimeWithRounding(isoDateTime, targetDateTime, ...)
    //
    // For ISO calendar this simplifies to: compute total ns between the two
    // date-times, round, decompose.

    // Extract relativeTo date fields.
    CivilDate rel_date;
    temporal::CivilTime rel_time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
    bool is_zdt = (relative_to.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME);
    if (is_zdt) {
        long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
        zdt_wall_fields(relative_to, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);
        rel_date = { .y = wy, .m = wm, .d = wd };
        rel_time = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns };
        hbigint::HBigInt* start_big = (hbigint::HBigInt*)relative_to.extra.temporal.big_ns;
        int128 start_ns = start_big.to_int128();
        int128 dur_time_ns = duration_to_time_ns(dur);
        int128 target_instant_ns = start_ns + dur_time_ns;
        int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
        if (target_instant_ns > ns_limit || target_instant_ns < -ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
            return;
        }
    } else {
        rel_date = { .y = relative_to.extra.temporal.long_a,
                     .m = relative_to.extra.temporal.long_b,
                     .d = relative_to.extra.temporal.long_c };
        if (relative_to.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            rel_time = plain_datetime_value(relative_to).time;
        }
    }

    if (!is_cal_unit(smallest_unit) && smallest_unit != TemporalUnit.DAY) {
        long rel_days = temporal::epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
        if (rel_days < -100000000L || rel_days > 100000000L) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo is outside representable range after conversion to DateTime");
            return;
        }
    }

    // Step 1: Compute time-only (no days) for AddTime.
    int128 time_only_ns = (int128)0;
    time_only_ns += (int128)dur.hours   * 3600000000000L;
    time_only_ns += (int128)dur.minutes *   60000000000L;
    time_only_ns += (int128)dur.seconds *    1000000000L;
    time_only_ns += (int128)dur.ms      *       1000000L;
    time_only_ns += (int128)dur.us      *          1000L;
    time_only_ns += (int128)dur.ns;

    // Step 2: AddTime(Midnight, time_only) → targetTime
    long target_time_days = (long)(time_only_ns / 86400000000000L);
    int128 target_time_rem = time_only_ns % 86400000000000L;
    if (time_only_ns < 0 && target_time_rem != 0) {
        target_time_days -= 1;
        target_time_rem += 86400000000000L;
    }

    // Step 3: AdjustDateDurationRecord(date, date.days + targetTime.days)
    // dateDuration = {years, months, weeks, dur.days + target_time_days}
    long adj_days = dur.days + target_time_days;

    // Step 4: Add dateDuration to rel_date → targetDate
    CivilDate target_date = rel_date;
    if (dur.years != 0) target_date = temporal::add_months(target_date, dur.years * 12, temporal::OverflowKind.CONSTRAIN);
    if (dur.months != 0) target_date = temporal::add_months(target_date, dur.months, temporal::OverflowKind.CONSTRAIN);
    if (dur.weeks != 0) target_date = temporal::add_days(target_date, dur.weeks * 7);
    if (adj_days != 0) target_date = temporal::add_days(target_date, adj_days);
    long rel_days = temporal::epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
    long tgt_days = temporal::epoch_days_from_civil(target_date.y, (int)target_date.m, (int)target_date.d);
    if (rel_days < -100000000L || rel_days > 100000000L || tgt_days < -100000000L || tgt_days > 100000000L) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "ISO date outside representable range");
        return;
    }

    long rem = (long)target_time_rem;
    long h  = rem / 3600000000000L; rem = (long)(rem % 3600000000000L);
    long mi = rem / 60000000000L;   rem = (long)(rem % 60000000000L);
    long s  = rem / 1000000000L;    rem = (long)(rem % 1000000000L);
    long ms = rem / 1000000L;       rem = (long)(rem % 1000000L);
    long us = rem / 1000L;
    long ns = rem % 1000L;
    if (!temporal::is_valid_iso_datetime(target_date.y, target_date.m, target_date.d, h, mi, s, ms, us, ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "date out of range");
        return;
    }

    // Steps 5-6: isoDateTime = (rel_date, midnight), targetDateTime = (target_date, target_time_rem)

    // Step 7: Round the difference. Delegate to the PlainDateTime path: the
    // same algorithm that backs PlainDateTime.prototype.round and until/since,
    // which already balances calendar units at largestUnit and handles the
    // day-borrow for a negative time-of-day remainder.
    temporal::CivilDateTime iso_dt = { .date = rel_date, .time = {} };
    temporal::CivilDateTime target_dt = { .date = target_date,
        .time = { .h = h, .mi = mi, .s = s, .ms = ms, .us = us, .ns = ns } };
    DiffSettings rds = { .largest = largest_unit, .smallest = smallest_unit,
                         .mode = rounding_mode, .increment = rounding_increment };
    temporal::DurationParts result;
    if (!datetime_difference(ctx, iso_dt, target_dt, rds, &result)) return;

    HObject*? obj_o = alloc_duration(ctx.heap, result);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

// ============================================================================
// Temporal.Duration.prototype.total
// ============================================================================

fn void builtin_temporal_duration_proto_total(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    if (ctx.argc < 1 || arg_at(ctx, 0).is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.total requires an argument");
        return;
    }
    temporal::DurationParts dur = duration_value((HObject*)this_val.get_heapptr());

    TVal* total_of = arg_at(ctx, 0);
    bool string_shorthand = total_of.is_string();
    if (!string_shorthand && !total_of.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.total requires an object or string argument");
        return;
    }
    HObject* opts = null;
    TemporalUnit unit = TemporalUnit.NANOSECOND;
    HObject* relative_to = null;

    if (string_shorthand) {
        HString* ss = builtin_to_string_vm(ctx, total_of);
        if (ctx.should_throw) return;
        if (!parse_unit_str(ss.get_cstr()[:ss.blen], &unit)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid unit");
            return;
        }
    } else {
        opts = (HObject*)total_of.get_heapptr();
        if (opts == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object or string");
            return;
        }
        // Per spec, options are read in alphabetical order before any
        // algorithmic validation: relativeTo first, then unit. Reading them
        // in any other order surfaces unit-validation errors before the
        // caller has observed relativeTo, breaking options-read-before-
        // algorithmic-validation tests.
        if (!read_relative_to_option(ctx, opts, &relative_to)) return;
        TVal unit_tv = prop_or_undefined_pa(ctx, opts, "unit");
        if (ctx.should_throw) return;
        if (unit_tv.is_undefined()) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "unit is required");
            return;
        }
        HString* unit_s = builtin_to_string_vm(ctx, &unit_tv);
        if (ctx.should_throw) return;
        if (!parse_unit_str(unit_s.get_cstr()[:unit_s.blen], &unit)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid unit");
            return;
        }
    }

    bool is_blank = dur.years == 0 && dur.months == 0 && dur.weeks == 0 && dur.days == 0 &&
                    dur.hours == 0 && dur.minutes == 0 && dur.seconds == 0 &&
                    dur.ms == 0 && dur.us == 0 && dur.ns == 0;
    if (is_blank) {
        ctx.result.set_number(0.0);
        return;
    }

    TemporalUnit existing = default_largest_unit(dur);
    if (relative_to == null) {
        if (is_cal_unit(existing) || is_cal_unit(unit)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo is required for calendar units");
            return;
        }
        int128 time_ns = duration_to_time_ns(dur);
        long div_ns = unit == TemporalUnit.DAY
            ? 86400000000000L
            : unit_ns_divisor(unit);
        // Integer quotient + float64 remainder, so the total reflects the
        // nanoseconds that the integer→float64 conversion would lose above
        // 2^53 ns (Duration.prototype.total must expose the FP-loss result,
        // matching the spec's `whole + remainder` shape).
        long whole = (long)(time_ns / (int128)div_ns);
        int128 rem = time_ns - (int128)whole * (int128)div_ns;
        double rem_d = (double)rem / (double)div_ns;
        ctx.result.set_number((double)whole + rem_d);
        return;
    }
    // Always compute and validate target datetime with relative_to:
    CivilDate rel_date;
    temporal::CivilTime rel_time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
    bool is_zdt = (relative_to.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME);
    if (is_zdt) {
        long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
        zdt_wall_fields(relative_to, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);
        rel_date = { .y = wy, .m = wm, .d = wd };
        rel_time = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns };
        hbigint::HBigInt* start_big = (hbigint::HBigInt*)relative_to.extra.temporal.big_ns;
        int128 start_ns = start_big.to_int128();
        int128 dur_time_ns = duration_to_time_ns(dur);
        int128 target_instant_ns = start_ns + dur_time_ns;
        int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
        if (target_instant_ns > ns_limit || target_instant_ns < -ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
            return;
        }
        if (unit == TemporalUnit.DAY || unit == TemporalUnit.WEEK || unit == TemporalUnit.MONTH || unit == TemporalUnit.YEAR) {
            int128 one_day_ns = (int128)86400000000000L;
            bool is_neg = dur.years < 0 || dur.months < 0 || dur.weeks < 0 || dur.days < 0 ||
                          dur.hours < 0 || dur.minutes < 0 || dur.seconds < 0 || dur.ms < 0 || dur.us < 0 || dur.ns < 0;
            if (!is_neg && start_ns + one_day_ns > ns_limit) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
                return;
            }
            if (is_neg && start_ns - one_day_ns < -ns_limit) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
                return;
            }
        }
    } else {
        rel_date = { .y = relative_to.extra.temporal.long_a,
                     .m = relative_to.extra.temporal.long_b,
                     .d = relative_to.extra.temporal.long_c };
        if (relative_to.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            rel_time = plain_datetime_value(relative_to).time;
        }
    }

    if (!is_cal_unit(unit) && unit != TemporalUnit.DAY) {
        long rel_days = temporal::epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
        if (rel_days < -100000000L || rel_days > 100000000L) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo is outside representable range after conversion to DateTime");
            return;
        }
    }
    int128 time_only_ns = (int128)0;
    time_only_ns += (int128)dur.hours   * 3600000000000L;
    time_only_ns += (int128)dur.minutes *   60000000000L;
    time_only_ns += (int128)dur.seconds *    1000000000L;
    time_only_ns += (int128)dur.ms      *       1000000L;
    time_only_ns += (int128)dur.us      *          1000L;
    time_only_ns += (int128)dur.ns;
    time_only_ns += (int128)rel_time.h  * 3600000000000L +
                    (int128)rel_time.mi *   60000000000L +
                    (int128)rel_time.s  *    1000000000L +
                    (int128)rel_time.ms *       1000000L +
                    (int128)rel_time.us *          1000L +
                    (int128)rel_time.ns;
    long target_time_days = (long)(time_only_ns / 86400000000000L);
    int128 target_time_rem = time_only_ns % 86400000000000L;
    if (time_only_ns < 0 && target_time_rem != 0) {
        target_time_days -= 1;
        target_time_rem += 86400000000000L;
    }
    long adj_days = dur.days + target_time_days;
    CivilDate target_date = rel_date;
    if (dur.years != 0) target_date = temporal::add_months(target_date, dur.years * 12, temporal::OverflowKind.CONSTRAIN);
    if (dur.months != 0) target_date = temporal::add_months(target_date, dur.months, temporal::OverflowKind.CONSTRAIN);
    if (dur.weeks != 0) target_date = temporal::add_days(target_date, dur.weeks * 7);
    if (adj_days != 0) target_date = temporal::add_days(target_date, adj_days);

    if (!temporal::is_valid_iso_date(target_date.y, (int)target_date.m, (int)target_date.d) ||
        !temporal::is_valid_iso_date(rel_date.y, (int)rel_date.m, (int)rel_date.d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "ISO date outside representable range");
        return;
    }

    if (relative_to.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
        long rel_days = temporal::epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
        long tgt_days = temporal::epoch_days_from_civil(target_date.y, (int)target_date.m, (int)target_date.d);
        if (rel_days < -100000000L || rel_days > 100000000L || tgt_days < -100000000L || tgt_days > 100000000L) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "ISO date outside representable range");
            return;
        }
    }

    int128 rem_work = target_time_rem;
    long tgt_h = (long)(rem_work / 3600000000000L); rem_work %= 3600000000000L;
    long tgt_mi = (long)(rem_work / 60000000000L); rem_work %= 60000000000L;
    long tgt_s = (long)(rem_work / 1000000000L); rem_work %= 1000000000L;
    long tgt_ms = (long)(rem_work / 1000000L); rem_work %= 1000000L;
    long tgt_us = (long)(rem_work / 1000L); rem_work %= 1000L;
    long tgt_ns = (long)rem_work;

    if (!temporal::is_valid_iso_datetime(target_date.y, target_date.m, target_date.d, tgt_h, tgt_mi, tgt_s, tgt_ms, tgt_us, tgt_ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo + duration is out of range");
        return;
    }

    bool has_cal = dur.years != 0 || dur.months != 0 || dur.weeks != 0;
    if (!is_cal_unit(unit) && !has_cal) {
        int128 time_ns = duration_to_time_ns(dur);
        long div_ns = unit == TemporalUnit.DAY
            ? 86400000000000L
            : unit_ns_divisor(unit);
        // Integer quotient + float64 remainder, matching the no-relativeTo
        // path and exposing the FP-loss result for the precision tests.
        long whole = (long)(time_ns / (int128)div_ns);
        int128 rem_ns = time_ns - (int128)whole * (int128)div_ns;
        double rem_d = (double)rem_ns / (double)div_ns;
        ctx.result.set_number((double)whole + rem_d);
        return;
    }
    long rel_epoch = temporal::epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
    long tgt_epoch = temporal::epoch_days_from_civil(target_date.y, (int)target_date.m, (int)target_date.d);
    // Calculate relativeTo time in nanoseconds
    int128 relativeTo_time_ns = (int128)rel_time.h * 3600000000000L +
                                (int128)rel_time.mi * 60000000000L +
                                (int128)rel_time.s * 1000000000L +
                                (int128)rel_time.ms * 1000000L +
                                (int128)rel_time.us * 1000L +
                                (int128)rel_time.ns;
    // Calculate time difference: (relativeTo time + duration time) - relativeTo time
    int128 time_diff_ns = target_time_rem - relativeTo_time_ns;
    int128 days_diff_ns = (int128)(tgt_epoch - rel_epoch) * 86400000000000L;
    // Handle negative time difference by borrowing a day
    if (time_diff_ns < 0) {
        days_diff_ns -= 86400000000000L;
        time_diff_ns += 86400000000000L;
    }
    int128 diff_ns = days_diff_ns + time_diff_ns;
    long divisor = unit_ns_divisor(unit);
    if (divisor > 0) {
        // Integer quotient + float64 remainder preserves the sub-quantum ns.
        long whole = (long)(diff_ns / (int128)divisor);
        int128 rem_ns = diff_ns - (int128)whole * (int128)divisor;
        double rem_d = (double)rem_ns / (double)divisor;
        ctx.result.set_number((double)whole + rem_d);
        return;
    }
    if (unit == TemporalUnit.DAY) {
        long whole = (long)(diff_ns / (int128)86400000000000L);
        int128 rem_ns = diff_ns - (int128)whole * (int128)86400000000000L;
        double rem_d = (double)rem_ns / 86400000000000.0;
        ctx.result.set_number((double)whole + rem_d);
        return;
    }
    if (unit == TemporalUnit.WEEK) {
        // Include the time remainder (target_time_rem) so 10 days 12 hours
        // reports as 1.5 weeks, not 1.42857 (= 10/7). The plain day count
        // (tgt_epoch - rel_epoch) drops any sub-day remainder, which is
        // wrong for total().
        long div_ns = 7L * 86400000000000L;
        long whole = (long)(diff_ns / (int128)div_ns);
        int128 rem_ns = diff_ns - (int128)whole * (int128)div_ns;
        double rem_d = (double)rem_ns / (double)div_ns;
        ctx.result.set_number((double)whole + rem_d);
        return;
    }
    // Re-decompose (relTo + duration) into the calendar-aware {years,
    // months, weeks, days} that DifferenceISODateTime would produce, so r1
    // (the trunc'd unit count) reflects the actual calendar span rather
    // than only what's in the input duration's years/months fields. Without
    // this, an `until()` that defaulted to days gives r1 = 0 even for a
    // multi-year span and the formula collapses to diff_ns / unit_ns.
    if (unit != TemporalUnit.MONTH && unit != TemporalUnit.YEAR) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "unsupported unit for total");
        return;
    }
    temporal::DateDifference dd;
    if (unit == TemporalUnit.YEAR) {
        dd = temporal::difference_date(rel_date, target_date, temporal::DifferenceUnit.YEARS);
    } else {
        dd = temporal::difference_date(rel_date, target_date, temporal::DifferenceUnit.MONTHS);
    }
    long r1;
    long sign = dur.years >= 0 && dur.months >= 0 && dur.weeks >= 0 && dur.days >= 0
        && dur.hours >= 0 && dur.minutes >= 0 && dur.seconds >= 0
        && dur.ms >= 0 && dur.us >= 0 && dur.ns >= 0
        ? 1 : -1;
    CivilDate unit_start;
    CivilDate unit_end;
    if (unit == TemporalUnit.YEAR) {
        r1 = dd.years;
        unit_start = temporal::add_months(rel_date, r1 * 12, temporal::OverflowKind.CONSTRAIN);
        unit_end = temporal::add_months(rel_date, (r1 + sign) * 12, temporal::OverflowKind.CONSTRAIN);
    } else {
        r1 = dd.months;
        unit_start = temporal::add_months(rel_date, r1, temporal::OverflowKind.CONSTRAIN);
        unit_end = temporal::add_months(rel_date, r1 + sign, temporal::OverflowKind.CONSTRAIN);
    }
    long start_epoch = temporal::epoch_days_from_civil(unit_start.y, (int)unit_start.m, (int)unit_start.d);
    long end_epoch   = temporal::epoch_days_from_civil(unit_end.y, (int)unit_end.m, (int)unit_end.d);
    int128 unit_ns = (int128)(end_epoch - start_epoch) * 86400000000000L;
    if (unit_ns < 0) unit_ns = -unit_ns;
    if (unit_ns <= 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration out of range");
        return;
    }
    int128 dest_ns = (int128)(tgt_epoch - rel_epoch) * 86400000000000L + target_time_rem;
    int128 start_ns_offset = (int128)(start_epoch - rel_epoch) * 86400000000000L;
    int128 numerator = dest_ns - start_ns_offset;
    int128 total_num = unit_ns * (int128)r1 + numerator;
    long whole = (long)(total_num / unit_ns);
    int128 rem_ns = total_num - (int128)whole * unit_ns;
    double rem_d = (double)rem_ns / (double)unit_ns;
    ctx.result.set_number((double)whole + rem_d);
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
    if (ctx.argc >= 4 && !arg_at(ctx, 3).is_undefined()) {
        if (!to_temporal_calendar_identifier(ctx, arg_at(ctx, 3), &calendar)) return;
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
    Vm* v = (Vm*)ctx.vm;

    // Per spec, the property bag is read before the options bag (the bag
    // reads must observe `calendar` first, then day/month/monthCode/year in
    // alphabetical order). We defer overflow-option parsing until after
    // the field reads are done.
    temporal::CivilDate result;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return; }
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.from: symbol cannot be converted");
            return;
        }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate.from: invalid ISO date string");
            return;
        }
        // Per the Temporal grammar, `TemporalDateTimeString[~Zoned]` (the
        // only goal ToTemporalDate accepts) forbids a `Z` designator —
        // `DateTime[~Z]` excludes it. A bare numeric offset after a time
        // component is allowed and silently dropped along with the time.
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate.from: Z designator is not allowed");
            return;
        }
        temporal::CivilDate d = { .y = p.year, .m = p.month, .d = p.day };
        // For string inputs, overflow defaults to constrain; only parse
        // overflow when the caller passed an options object.
        if (ctx.argc >= 2 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
            temporal::OverflowKind overflow;
            if (!read_overflow_option(ctx, 1, &overflow)) return;
            int dim = temporal::days_in_month(d.y, (int)d.m);
            if (d.d > dim) {
                if (overflow == temporal::OverflowKind.REJECT) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows month");
                    return;
                }
                d.d = dim;
            }
        } else {
            int dim = temporal::days_in_month(d.y, (int)d.m);
            if (d.d > dim) d.d = dim;
        }
        if (!temporal::is_valid_iso_date(d.y, (int)d.m, (int)d.d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
            return;
        }
        result = d;
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
            // Spec returns a fresh copy (CreateTemporalDate from the
            // receiver's slots), never the receiver itself. The options bag
            // is still observed so Proxy-based order-of-operations tests see
            // the overflow read.
            temporal::OverflowKind clone_overflow;
            if (!read_overflow_option(ctx, 1, &clone_overflow)) return;
            (void)clone_overflow;
            temporal::CivilDate cd = plain_date_value(o);
            HObject*? copy_o = alloc_plain_date(ctx.heap, cd, o.extra.temporal.calendar);
            if (catch err = copy_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            HObject* copy = copy_o;
            copy.prototype = ctx.heap.temporal_plain_date_proto;
            ctx.result.set_object(copy);
            return;
        }
        // Slot-extraction fast path for PlainDateTime / ZonedDateTime
        // (ToTemporalDate steps 2.b / 2.c): no property-bag getters fire.
        // The options bag is still observed when present.
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME ||
            o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            temporal::OverflowKind fast_overflow;
            if (ctx.argc >= 2 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
                if (!read_overflow_option(ctx, 1, &fast_overflow)) return;
            }
            temporal::CivilDate cd;
            if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
                cd = plain_date_value(o);
            } else {
                long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
                zdt_wall_fields(o, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
                (void)wh; (void)wmi; (void)ws; (void)wms; (void)wus; (void)wns; (void)off;
                cd = { .y = wy, .m = (int)wm, .d = (int)wd };
            }
            HObject*? fast_o = alloc_plain_date(ctx.heap, cd, ctx.heap.temporal_iso_calendar);
            if (catch err = fast_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            HObject* fast = fast_o;
            fast.prototype = ctx.heap.temporal_plain_date_proto;
            ctx.result.set_object(fast);
            return;
        }
        // Property bag: read fields first, then the overflow option. The
        // monthCode suitability check runs AFTER the option bag so the
        // options bag is observed even when the field bag is unsuitable
        // (test262 options-read-before-algorithmic-validation).
        temporal::CivilDate fields;
        long _ep;
        bool have_mc;
        int mci;
        TVal mc_v;
        if (!bag_to_fields(ctx, o, false, false, { .y = 0, .m = 1, .d = 1 }, &fields, &_ep,
                           &have_mc, &mci, &mc_v)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        temporal::OverflowKind overflow;
        if (!read_overflow_option(ctx, 1, &overflow)) return;
        if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) {
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
    // is the default calendar; always/critical append it. Use the Proxy-
    // aware getter so a propertyBagObserver's `get` trap fires in the
    // spec's order.
    bool show_calendar = false;
    bool critical = false;
    if (ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal ov = ctx.regs[ctx.base_reg];
        if (!ov.is_object() || ov.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
            return;
        }
        HObject* opts = (HObject*)ov.get_heapptr();
        TVal cn = prop_or_undefined_pa(ctx, opts, "calendarName");
        if (ctx.should_throw) return;
        if (!cn.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &cn);
            if (ctx.should_throw) return;
            if (s == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "calendarName must be a string");
                return;
            }
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
    ctx.argc = 0;
    builtin_temporal_plain_date_proto_toString(ctx);
}

fn void builtin_temporal_plain_date_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    ctx.argc = 0;
    builtin_temporal_plain_date_proto_toString(ctx);
}

fn void builtin_temporal_plain_date_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    // equals runs ToTemporalDate on its argument, so a value that cannot be
    // converted throws instead of comparing unequal. That covers a missing
    // argument, a bare number and a Duration.
    TVal* arg = arg_at(ctx, 0);
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires a Temporal.PlainDate argument");
        return;
    }

    // plain_date_from_arg raises the TypeError or RangeError for what it
    // cannot convert.
    HObject* other_pd;
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
        other_pd = (HObject*)arg.get_heapptr();
    } else {
        HObject*? other_o = plain_date_from_arg(ctx, arg);
        if (ctx.should_throw) return;
        other_pd = other_o!!;
    }

    temporal::CivilDate a = plain_date_value(obj);
    temporal::CivilDate b = plain_date_value(other_pd);
    bool same_cal = obj.extra.temporal.calendar == other_pd.extra.temporal.calendar;
    ctx.result.set_boolean(same_cal && temporal::date_equals(a, b));
}

fn void builtin_temporal_plain_date_proto_toPlainDateTime(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();

    temporal::CivilTime t = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
    if (ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal* arg = arg_at(ctx, 0);
        HObject*? time_o = plain_time_from_arg(ctx, arg);
        if (ctx.should_throw) return;
        HObject* time_obj = time_o!!;
        t = plain_time_value(time_obj);
    }

    temporal::CivilDate d = plain_date_value(obj);
    temporal::CivilDateTime result = { .date = d, .time = t };
    // The combined date+time must be representable: the minimum date's
    // midnight (below the PlainDateTime lower edge) is invalid.
    if (!temporal::is_valid_iso_datetime(result.date.y, (int)result.date.m, (int)result.date.d,
                                         result.time.h, result.time.mi, result.time.s,
                                         result.time.ms, result.time.us, result.time.ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "datetime outside representable PlainDateTime range");
        return;
    }
    HObject*? obj_o = alloc_plain_datetime(ctx.heap, result, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(obj2);
}

// this.toZonedDateTime(item) — combine this date with midnight (or a given
// plainTime) and resolve the local date-time to an instant in the given
// time zone, using "compatible" disambiguation. `item` is either a
// time-zone-like value (string zone id or TimeZone/object) or an options bag
// { timeZone, plainTime }.
fn void builtin_temporal_plain_date_proto_toZonedDateTime(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();

    if (ctx.argc < 1 || ctx.regs[ctx.base_reg].is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "toZonedDateTime requires a time zone or options bag");
        return;
    }
    TVal* arg = arg_at(ctx, 0);

    HObject* tz = null;
    temporal::CivilTime t = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };

    // A string or a TimeZone-branded object is used directly as the time
    // zone; anything else is treated as an options bag with `timeZone` and
    // an optional `plainTime`.
    bool is_tz_like = arg.is_string()
        || (arg.is_object() && arg.get_heapptr() != null
            && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_TIMEZONE);
    if (is_tz_like) {
        if (try maybe_tz = to_temporal_tz(ctx, arg)) {
            if (ctx.should_throw) return;
            tz = maybe_tz;
        } else {
            return;
        }
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* bag = (HObject*)arg.get_heapptr();
        TVal tz_v = prop_or_undefined_pa(ctx, bag, "timeZone");
        if (ctx.should_throw) return;
        if (tz_v.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "toZonedDateTime requires a timeZone");
            return;
        }
        if (try maybe_tz = to_temporal_tz(ctx, &tz_v)) {
            if (ctx.should_throw) return;
            tz = maybe_tz;
        } else {
            return;
        }
        TVal pt_v = prop_or_undefined_pa(ctx, bag, "plainTime");
        if (ctx.should_throw) return;
        if (!pt_v.is_undefined()) {
            HObject*? time_o = plain_time_from_arg(ctx, &pt_v);
            if (ctx.should_throw) return;
            HObject* time_obj = time_o!!;
            t = plain_time_value(time_obj);
        }
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "toZonedDateTime requires a time zone or options bag");
        return;
    }

    temporal::CivilDate d = plain_date_value(obj);
    // ISODateTimeWithinLimits: the combined wall date+time must be a
    // representable PlainDateTime; the minimum date at midnight (below the
    // lower edge) throws.
    if (!temporal::is_valid_iso_datetime(d.y, (int)d.m, (int)d.d,
                                         t.h, t.mi, t.s, t.ms, t.us, t.ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "combined date-time outside representable PlainDateTime range");
        return;
    }
    long wall_secs = temporal::epoch_days_from_civil(d.y, (int)d.m, (int)d.d) * 86400
        + (long)t.h * 3600 + (long)t.mi * 60 + (long)t.s;
    long wall_frac = (long)t.ms * 1000000 + (long)t.us * 1000 + (long)t.ns;
    String zone = timezone_name(tz);
    int128 epoch_ns_128 = zdt_local_to_epoch_ns(zone, wall_secs, wall_frac);

    // GetStartOfDay resolves midnight; the resulting UTC instant must fall
    // within the representable epoch range (±8.64e21 ns). A wall date at the
    // ISO boundary with an offset can land past NS_MIN/NS_MAX.
    int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
    if (epoch_ns_128 > ns_limit || epoch_ns_128 < -ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
        return;
    }

    hbigint::HBigInt*? ns_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns_128);
    if (catch err = ns_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
    hbigint::HBigInt* ns = ns_o;
    zdt_from_parts(ctx, ns, tz, (HString*)obj.extra.temporal.calendar);
}

fn void builtin_temporal_plain_date_proto_toPlainYearMonth(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDate d = plain_date_value(obj);
    HObject*? ym_o = alloc_plain_yearmonth(ctx.heap, d.y, (int)d.m, 1, obj.extra.temporal.calendar);
    if (catch err = ym_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* ym = ym_o;
    ym.prototype = ctx.heap.temporal_plain_yearmonth_proto;
    ctx.result.set_object(ym);
}

fn void builtin_temporal_plain_date_proto_toPlainMonthDay(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDate d = plain_date_value(obj);
    HObject*? md_o = alloc_plain_monthday(ctx.heap, 1972, (int)d.m, (int)d.d, obj.extra.temporal.calendar);
    if (catch err = md_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* md = md_o;
    md.prototype = ctx.heap.temporal_plain_monthday_proto;
    ctx.result.set_object(md);
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
    if (!reject_temporal_object_bag(ctx, bag)) return;

    Vm* v = (Vm*)ctx.vm;
    temporal::CivilDate cur = plain_date_value(obj);
    temporal::CivilDate fields;
    long _ep;
    bool have_mc;
    int mci;
    TVal mc_v;
    bool found_any;
    if (!bag_to_fields(ctx, bag, true, true, cur, &fields, &_ep, &have_mc, &mci, &mc_v, &found_any)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    if (!found_any) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "at least one property must be provided");
        return;
    }
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) {
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
// carry fractions (folded into nanoseconds). Identical contract to
// duration_from_arg: alphabetical read order, prop_or_undefined_pa (so a
// Proxy's get trap fires and the order-of-operations test262 tests see the
// expected log), and a TypeError when none of the ten fields is present.
// One duration component: ToIntegerIfIntegralOrInfinity plus the component
// ceiling. Returns false after throwing.
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
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return false; }
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Duration: symbol cannot be converted");
            return false;
        }
        if (!temporal::parse_duration(s.get_cstr()[:s.blen], out)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid duration string");
            return false;
        }
        if (!is_valid_duration(out)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "duration is out of range");
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

    // Spec order: ToTemporalDuration reads the fields in alphabetical order
    // (CreateDurationRecord / the Duration field table). The slot[] array
    // maps a read position back to the field it fills.
    char[][] names = { "days", "hours", "microseconds", "milliseconds",
        "minutes", "months", "nanoseconds", "seconds", "weeks", "years" };
    int[] slot = { 3, 4, 8, 7, 5, 1, 9, 6, 2, 0 };
    bool any_field = false;
    // Per spec, mixed-sign duration properties raise RangeError; collect the
    // sign of the first non-zero field and reject anything that disagrees.
    int overall_sign = 0;
    for (int i = 0; i < 10; i++) {
        int k = slot[i];
        TVal pv = prop_or_undefined_pa(ctx, o, names[i]);
        if (ctx.should_throw) return false;
        if (pv.is_undefined()) continue;
        any_field = true;
        double val = vm::vm_to_number(v, &pv);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
        if (!duration_field_integral(ctx, val)) return false;
        // All ten fields must be integers — fractional time components are
        // only allowed via ISO strings (where the parser balances them into
        // smaller units), not in a plain property bag.
        if (val != 0) {
            int s = val < 0 ? -1 : 1;
            if (overall_sign == 0) {
                overall_sign = s;
            } else if (overall_sign != s) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "mixed-sign duration properties are not allowed");
                return false;
            }
        }
        long whole = (long)math::trunc(val);
        switch (k) {
            case 0: out.years = whole; break;
            case 1: out.months = whole; break;
            case 2: out.weeks = whole; break;
            case 3: out.days = whole; break;
            case 4: out.hours = whole; break;
            case 5: out.minutes = whole; break;
            case 6: out.seconds = whole; break;
            case 7: out.ms = whole; break;
            case 8: out.us = whole; break;
            default: out.ns = whole; break;
        }
    }
    if (!any_field) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "duration property bag has no recognized fields");
        return false;
    }
    if (!is_valid_duration(out)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration is out of range");
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
    // date arithmetic on largerUnit day). Use int128 to avoid overflow:
    // PT2400000023H... has dur.hours = 2.4e9, which times 3.6e12 overflows
    // long (max ~9.2e18). int128 holds the full ~8.64e21 ns comfortably.
    int128 extra_ns = (int128)dur.ns + ((int128)dur.us * 1000) + ((int128)dur.ms * 1_000_000) +
                    ((int128)dur.seconds * 1_000_000_000L) + ((int128)dur.minutes * 60_000_000_000L) +
                    ((int128)dur.hours * 3_600_000_000_000L);
    // For PlainDate, the time portion must convert to a whole-day
    // contribution via MathTrunc-style truncation toward zero, not floor. The
    // spec's ToDateDurationRecord keeps the time sub-day fields normalized
    // (so any non-zero sub-day here means the duration is invalid) and
    // adds MathTrunc(time / 86400) to the date's days column. -PT23H59M59.999...
    // truncates to 0 (not -1), which is why subtracting -P273790Y8M12DT23H59M59.999...
    // from 1970-01-01 lands on the valid min date -271821-04-19, not one day
    // earlier.
    long whole_days = (long)(extra_ns / 86_400_000_000_000L);
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
    // Time units balance into whole days (truncating, the spec's floor for
    // date arithmetic on largerUnit day). Use int128 to avoid overflow:
    // PT2400000047H... has dur.hours = 2.4e9, which times 3.6e12 overflows
    // long (max ~9.2e18). int128 holds the full ~8.64e21 ns comfortably.
    int128 extra_ns = (int128)dur.ns + ((int128)dur.us * 1000) + ((int128)dur.ms * 1_000_000) +
                    ((int128)dur.seconds * 1_000_000_000L) + ((int128)dur.minutes * 60_000_000_000L) +
                    ((int128)dur.hours * 3_600_000_000_000L);
    // C integer division truncates toward 0, matching the spec's MathTrunc
    // time-to-day conversion: subtracting -PT23H59M59.999... truncates to
    // adding 0 days, not 1.
    long whole_days = (long)(extra_ns / 86_400_000_000_000L);
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

    // A PlainDate has no time, so only day-and-coarser units are accepted.
    // `since` negates the rounding mode (ceil ↔ floor, halfCeil ↔ halfFloor)
    // because the internal computation runs in the positive direction
    // regardless of operation and the sign is flipped at the end.
    DiffSettings ds;
    if (!read_diff_settings(ctx, 1, TemporalUnit.YEAR, TemporalUnit.DAY,
                            TemporalUnit.DAY, TemporalUnit.DAY, flipped, &ds)) return;
    temporal::CivilDate a = plain_date_value(obj);
    temporal::CivilDate b = plain_date_value(other);
    temporal::CivilDateTime start = { .date = a };
    temporal::CivilDateTime end   = { .date = b };

    temporal::DurationParts dur;
    if (!datetime_difference(ctx, start, end, ds, &dur)) return;

    if (flipped) {
        dur.years = -dur.years;
        dur.months = -dur.months;
        dur.weeks = -dur.weeks;
        dur.days = -dur.days;
        dur.hours = -dur.hours;
        dur.minutes = -dur.minutes;
        dur.seconds = -dur.seconds;
        dur.ms = -dur.ms;
        dur.us = -dur.us;
        dur.ns = -dur.ns;
    }

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
    if (ctx.argc < 1 || ctx.regs[ctx.base_reg].is_undefined()) {
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
    if (ctx.argc >= 1 && !arg_at(ctx, 0).is_undefined()) {
        long h_lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 0), &h_lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "hour is not an integral number");
            return;
        }
        t.h = (int)h_lv;
    }
    if (ctx.argc >= 2 && !arg_at(ctx, 1).is_undefined()) {
        long mi;
        if (!to_integer_with_truncation(v, arg_at(ctx, 1), &mi)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "minute is not an integral number");
            return;
        }
        t.mi = (int)mi;
    }
    if (ctx.argc >= 3 && !arg_at(ctx, 2).is_undefined()) {
        long s;
        if (!to_integer_with_truncation(v, arg_at(ctx, 2), &s)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "second is not an integral number");
            return;
        }
        t.s = (int)s;
    }
    if (ctx.argc >= 4 && !arg_at(ctx, 3).is_undefined()) {
        long ms;
        if (!to_integer_with_truncation(v, arg_at(ctx, 3), &ms)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "millisecond is not an integral number");
            return;
        }
        t.ms = (int)ms;
    }
    if (ctx.argc >= 5 && !arg_at(ctx, 4).is_undefined()) {
        long us;
        if (!to_integer_with_truncation(v, arg_at(ctx, 4), &us)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "microsecond is not an integral number");
            return;
        }
        t.us = (int)us;
    }
    if (ctx.argc >= 6 && !arg_at(ctx, 5).is_undefined()) {
        long ns;
        if (!to_integer_with_truncation(v, arg_at(ctx, 5), &ns)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "nanosecond is not an integral number");
            return;
        }
        t.ns = (int)ns;
    }

    temporal::CivilTime valid;
    // A PlainTime holds no leap-second concept: second 60 is out of range
    // (IsValidTime). Only the ISO-string date-time parser folds a :60 to 59.
    if (!fields_to_valid_time(ctx, t, &valid, temporal::OverflowKind.REJECT, false)) return;

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
    Vm* v = (Vm*)ctx.vm;

    temporal::CivilTime result;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return; }
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainTime.from: symbol cannot be converted");
            return;
        }
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
        // Per the Temporal grammar (`AnnotatedTime` and
        // `AnnotatedDateTime[~Zoned, +TimeRequired]` both parameterise
        // `DateTimeUTCOffset` as `[~Z]`), the `Z` designator is forbidden
        // on a PlainTime string. A numeric UTC offset is silently
        // discarded.
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainTime.from: Z designator is not allowed");
            return;
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
        // Per spec ToTemporalTime always parses the overflow option even
        // when the input is a string (step 1 of ToTemporalTime runs
        // GetTemporalOverflowOption before the per-kind coercion). The
        // value is unused here, but the property reads must fire so the
        // order-of-operations test for `from(string, options)` records them.
        temporal::OverflowKind _str_overflow;
        if (!read_overflow_option(ctx, 1, &_str_overflow)) return;
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_TIME) {
            temporal::OverflowKind clone_overflow;
            if (!read_overflow_option(ctx, 1, &clone_overflow)) return;
            (void)clone_overflow;
            HObject*? copy_o = alloc_plain_time(ctx.heap, plain_time_value(o));
            if (catch err = copy_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            HObject* copy = copy_o;
            copy.prototype = ctx.heap.temporal_plain_time_proto;
            ctx.result.set_object(copy);
            return;
        }
        // PlainDateTime: read time fields directly from internal slots.
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            temporal::OverflowKind pdt_overflow;
            if (!read_overflow_option(ctx, 1, &pdt_overflow)) return;
            temporal::CivilDateTime dt = plain_datetime_value(o);
            temporal::CivilTime valid;
            if (!fields_to_valid_time(ctx, dt.time, &valid, pdt_overflow, false)) return;
            HObject*? obj_o = alloc_plain_time(ctx.heap, valid);
            if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            HObject* obj = obj_o;
            obj.prototype = ctx.heap.temporal_plain_time_proto;
            ctx.result.set_object(obj);
            return;
        }
        // Property bag: read fields first, then the overflow option.
        temporal::CivilTime fields;
        temporal::CivilTime cur = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
        if (!bag_to_time_fields(ctx, o, false, cur, &fields, true)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        temporal::OverflowKind overflow;
        if (!read_overflow_option(ctx, 1, &overflow)) return;
        if (!fields_to_valid_time(ctx, fields, &result, overflow, false)) {
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
    // Route through plain_time_from_arg: it accepts a PlainTime object, a
    // property bag, or an ISO string (RangeError if it does not parse), and
    // raises TypeError for everything else — matching the test262
    // argument-wrong-type matrix.
    HObject*? ao = plain_time_from_arg(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject*? bo = plain_time_from_arg(ctx, arg_at(ctx, 1));
    if (ctx.should_throw) return;
    ctx.result.set_fastint((long)temporal::time_compare(plain_time_value(ao!!), plain_time_value(bo!!)));
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

    // Reuse to_string_precision for the option reads: it goes through
    // prop_or_undefined_pa (so a Proxy's get trap fires) and uses
    // builtin_to_string_vm (so toString/valueOf pair is observed in the
    // order-of-operations log). The smallestUnit branch is encoded as
    // sentinel -10 (minute), 0 (second), 3/6/9 (sub-second).
    int digits = -1;
    TemporalRoundMode rm = TemporalRoundMode.TRUNC;
    if (!to_string_precision(ctx, 0, &digits, &rm, false, null)) return;

    int ns_digits;
    if (digits == -10) {
        ns_digits = -12;
    } else if (digits < 0) {
        ns_digits = -1;  // auto: smallest non-zero
    } else {
        ns_digits = digits;
    }

    // Round the time-of-day (RoundTime): the increment is the unit implied
    // by the precision, whole nanoseconds (no rounding) when "auto". A
    // PlainTime wraps at midnight, so a rounded-up 24:00 becomes 00:00.
    long unit_ns = 0;
    if (ns_digits == -12) {
        unit_ns = 60000000000L;
    } else if (ns_digits >= 0 && ns_digits < 9) {
        unit_ns = ns_pow10(9 - ns_digits);
    } else if (ns_digits == 9) {
        unit_ns = 1;
    }
    if (unit_ns > 1) {
        long total = round_long_ns(civil_time_to_ns(t), unit_ns, rm);
        if (total >= 86400000000000L) total -= 86400000000000L;
        t = civil_time_from_ns(total);
    }

    char[32] buf;
    usz len = temporal::format_civil_time(t, &buf, 32, ns_digits);
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_time_proto_toJSON(BuiltinContext* ctx) {
    ctx.argc = 0;
    builtin_temporal_plain_time_proto_toString(ctx);
}

fn void builtin_temporal_plain_time_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    ctx.argc = 0;
    builtin_temporal_plain_time_proto_toString(ctx);
}

fn void builtin_temporal_plain_time_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* other = (HObject*)arg.get_heapptr();
        if (other.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_TIME) {
            ctx.result.set_boolean(temporal::time_equals(plain_time_value(obj), plain_time_value(other)));
            return;
        }
    }
    // PlainTime can be derived from a string or property bag via ToTemporalTime.
    HObject*? other_o = plain_time_from_arg(ctx, arg);
    if (ctx.should_throw) return;
    HObject* other = other_o!!;
    ctx.result.set_boolean(temporal::time_equals(plain_time_value(obj), plain_time_value(other)));
}

// Convert an until/since argument into a PlainTime HObject.
fn HObject*? plain_time_from_arg(BuiltinContext* ctx, TVal* arg) {
    Vm* v = (Vm*)ctx.vm;
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_TIME) return o;
        // PlainDateTime: read time fields directly from internal slots.
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            temporal::CivilDateTime dt = plain_datetime_value(o);
            temporal::CivilTime valid;
            if (!fields_to_valid_time(ctx, dt.time, &valid, temporal::OverflowKind.CONSTRAIN, true)) return null;
            HObject*? res = alloc_plain_time(ctx.heap, valid);
            if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
            HObject* r = res;
            r.prototype = ctx.heap.temporal_plain_time_proto;
            return r;
        }
        // ZonedDateTime: ToTemporalTime spec uses the wall-clock time at
        // the ZDT's epoch (after applying the zone offset). Read it via
        // zdt_wall_fields so the sub-second precision (ns_rem = 1 for
        // negative-epoch ZDTs) survives.
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
            zdt_wall_fields(o, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
            (void)wy; (void)wm; (void)wd; (void)off;
            temporal::CivilTime valid;
            if (!fields_to_valid_time(ctx, {
                .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns,
            }, &valid, temporal::OverflowKind.CONSTRAIN, true)) return null;
            HObject*? res = alloc_plain_time(ctx.heap, valid);
            if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
            HObject* r = res;
            r.prototype = ctx.heap.temporal_plain_time_proto;
            return r;
        }
        temporal::CivilTime fields;
        temporal::CivilTime cur = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
        if (!bag_to_time_fields(ctx, o, false, cur, &fields, true)) return null;
        temporal::CivilTime valid;
        if (!fields_to_valid_time(ctx, fields, &valid, temporal::OverflowKind.CONSTRAIN, true)) return null;
        HObject*? res = alloc_plain_time(ctx.heap, valid);
        if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        HObject* r = res;
        r.prototype = ctx.heap.temporal_plain_time_proto;
        return r;
    }
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return null; }
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to a PlainTime");
            return null;
        }
        char[] text = s.get_cstr()[:s.blen];
        // PlainTime accepts both time-only strings (`12:34`, `T12:34:56`)
        // and date-time strings whose date portion is silently dropped.
        // Try the time-only parser first; fall back to the date-time parser.
        temporal::ParsedIsoDateTime p;
        bool ok = temporal::parse_iso_time_string(text, &p);
        if (!ok) {
            ok = temporal::parse_iso_date_string(text, &p);
            if (!ok || !p.has_time) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO time string");
                return null;
            }
        }
        // Per the Temporal grammar (`AnnotatedTime` and the
        // date-time production both use `DateTimeUTCOffset[~Z]`), the `Z`
        // designator is forbidden on a PlainTime string.
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Z designator not valid for PlainTime");
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
    if (!reject_temporal_object_bag(ctx, bag)) return;
    // RejectObjectWithCalendarOrTimeZone ([[Get]] probes, per test262
    // order-of-operations): a present calendar or timeZone is a TypeError.
    TVal cal_f = prop_or_undefined_pa(ctx, bag, "calendar");
    if (ctx.should_throw) return;
    if (!cal_f.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a calendar property");
        return;
    }
    TVal tz_f = prop_or_undefined_pa(ctx, bag, "timeZone");
    if (ctx.should_throw) return;
    if (!tz_f.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a timeZone property");
        return;
    }
    Vm* v = (Vm*)ctx.vm;
    temporal::CivilTime cur = plain_time_value(obj);
    temporal::CivilTime fields;
    if (!bag_to_time_fields(ctx, bag, true, cur, &fields, true)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    temporal::CivilTime valid;
    if (!fields_to_valid_time(ctx, fields, &valid, overflow, false)) return;
    HObject*? obj_o = alloc_plain_time(ctx.heap, valid);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(obj2);
}

fn void plain_time_add_sub(BuiltinContext* ctx, bool subtract) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, subtract ? "subtract requires a duration" : "add requires a duration");
        return;
    }
    temporal::DurationParts dur;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur)) return;
    // PlainTime.add/subtract take no options argument: the result wraps within
    // the day, so there is no overflow to choose. The engine must not read or
    // validate a second argument (test262 options-ignored).

    temporal::CivilTime cur = plain_time_value(obj);
    int128 cur_ns = (int128)cur.h * 3_600_000_000_000L + (int128)cur.mi * 60_000_000_000L +
                    (int128)cur.s * 1_000_000_000L + (int128)cur.ms * 1_000_000L +
                    (int128)cur.us * 1000L + (int128)cur.ns;
    int128 dur_ns = (int128)dur.hours * 3_600_000_000_000L + (int128)dur.minutes * 60_000_000_000L +
                    (int128)dur.seconds * 1_000_000_000L + (int128)dur.ms * 1_000_000L +
                    (int128)dur.us * 1000L + (int128)dur.ns;
    int128 sum_ns = subtract ? (cur_ns - dur_ns) : (cur_ns + dur_ns);
    int128 day_ns = (int128)86_400_000_000_000L;
    int128 rem_ns = sum_ns % day_ns;
    if (rem_ns < 0) rem_ns += day_ns;

    temporal::CivilTime result;
    result.h = (int)(rem_ns / 3_600_000_000_000L);
    rem_ns %= 3_600_000_000_000L;
    result.mi = (int)(rem_ns / 60_000_000_000L);
    rem_ns %= 60_000_000_000L;
    result.s = (int)(rem_ns / 1_000_000_000L);
    rem_ns %= 1_000_000_000L;
    result.ms = (int)(rem_ns / 1_000_000L);
    rem_ns %= 1_000_000L;
    result.us = (int)(rem_ns / 1000L);
    result.ns = (int)(rem_ns % 1000L);

    HObject*? obj_o = alloc_plain_time(ctx.heap, result);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_time_proto_add(BuiltinContext* ctx) {
    plain_time_add_sub(ctx, false);
}

fn void builtin_temporal_plain_time_proto_subtract(BuiltinContext* ctx) {
    plain_time_add_sub(ctx, true);
}

fn void plain_time_until_since(BuiltinContext* ctx, HObject* obj, bool flipped) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "until/since requires another time");
        return;
    }
    HObject*? other_o = plain_time_from_arg(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject* other = other_o!!;

    // PlainTime carries no date, so only hour-and-finer units are accepted.
    DiffSettings ds;
    if (!read_diff_settings(ctx, 1, TemporalUnit.HOUR, TemporalUnit.NANOSECOND,
                            TemporalUnit.HOUR, TemporalUnit.NANOSECOND, false, &ds)) return;

    temporal::CivilTime a = plain_time_value(obj);
    temporal::CivilTime b = plain_time_value(other);
    temporal::CivilTime start = flipped ? b : a;
    temporal::CivilTime end   = flipped ? a : b;

    // The delta is under 24 hours, so it fits a long and needs no BigInt.
    long start_ns = ((long)start.h * 3600 + (long)start.mi * 60 + (long)start.s) * 1_000_000_000L
                  + (long)start.ms * 1_000_000L + (long)start.us * 1000L + (long)start.ns;
    long end_ns   = ((long)end.h  * 3600 + (long)end.mi  * 60 + (long)end.s ) * 1_000_000_000L
                  + (long)end.ms  * 1_000_000L + (long)end.us  * 1000L + (long)end.ns;
    long delta = end_ns - start_ns;

    long incr_ns = unit_ns_divisor(ds.smallest) * (long)ds.increment;
    if (incr_ns > 1) delta = round_long_ns(delta, incr_ns, ds.mode);

    temporal::DurationParts dur = time_ns_split(delta, ds.largest);

    HObject*? dur_o = alloc_duration(ctx.heap, dur);
    if (catch err = dur_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* dur_obj = dur_o;
    dur_obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur_obj);
}

fn void builtin_temporal_plain_time_proto_round(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_TIME, "this is not a Temporal.PlainTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "PlainTime.prototype.round requires an argument");
        return;
    }
    HObject* self = (HObject*)this_val.get_heapptr();
    TVal* round_to = arg_at(ctx, 0);
    HObject* opts = null;
    TemporalUnit smallest_unit = TemporalUnit.NANOSECOND;
    bool smallest_given = false;
    double rounding_increment = 1;
    TemporalRoundMode rounding_mode = TemporalRoundMode.HALF_EXPAND;
    if (!round_to.is_object() || round_to.get_heapptr() == null) {
        // String shorthand: smallestUnit = the string.
        if (round_to.is_string() || (round_to.is_object() && round_to.get_heapptr() != null && !((HObject*)round_to.get_heapptr()).flags.callable)) {
            HString* s = builtin_to_string_vm(ctx, round_to);
            if (ctx.should_throw) return;
            char[] str = s.get_cstr()[:s.blen];
            if (!parse_unit_str(str, &smallest_unit) || smallest_unit < TemporalUnit.HOUR) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
                return;
            }
            smallest_given = true;
        } else {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object or string");
            return;
        }
    } else {
        opts = (HObject*)round_to.get_heapptr();
        TVal su_v = prop_or_undefined_pa(ctx, opts, "smallestUnit");
        if (ctx.should_throw) return;
        if (!su_v.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &su_v);
            if (ctx.should_throw) return;
            if (!parse_unit_str(s.get_cstr()[:s.blen], &smallest_unit) || smallest_unit < TemporalUnit.HOUR) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
                return;
            }
            smallest_given = true;
        }
        TVal ri_v = prop_or_undefined_pa(ctx, opts, "roundingIncrement");
        if (ctx.should_throw) return;
        if (!ri_v.is_undefined()) {
            Vm* v = (Vm*)ctx.vm;
            double ri_val = vm::vm_to_number(v, &ri_v);
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            if (math::is_nan(ri_val) || math::is_inf(ri_val)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a positive integer");
                return;
            }
            rounding_increment = math::floor(ri_val);
            if (rounding_increment < 1) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a positive integer");
                return;
            }
        }
        TVal rm_v = prop_or_undefined_pa(ctx, opts, "roundingMode");
        if (ctx.should_throw) return;
        if (!rm_v.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &rm_v);
            if (ctx.should_throw) return;
            if (!parse_rm_str(s.get_cstr()[:s.blen], &rounding_mode)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return;
            }
        }
    }
    if (!smallest_given) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "round requires a smallestUnit option");
        return;
    }
    long max_incr = max_round_incr(smallest_unit);
    if (max_incr > 0 && (rounding_increment > (double)max_incr
        || (double)max_incr / rounding_increment != math::floor((double)max_incr / rounding_increment)
        || rounding_increment == (double)max_incr)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
        return;
    }

    long divisor = unit_ns_divisor(smallest_unit);
    long incr_ns = divisor * (long)rounding_increment;
    // PlainTime stores its fields directly. Build the total ns value:
    long h = self.extra.temporal.long_a;
    long m = self.extra.temporal.long_b;
    long s = self.extra.temporal.long_c;
    long ms = self.extra.temporal.long_d;
    long us = self.extra.temporal.long_e;
    long ns = self.extra.temporal.long_f;
    long total_ns = h * 3600000000000L + m * 60000000000L + s * 1000000000L
                  + ms * 1000000L + us * 1000L + ns;
    long rounded = round_long_ns(total_ns, incr_ns, rounding_mode);
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(rounded / 1000000000L);
    int rh = bd.h;
    long rem = rounded - (rounded / 1000000000L) * 1000000000L;
    int rmin = bd.mi;
    int rs = bd.s;
    int rms = (int)(rem / 1000000L); rem %= 1000000L;
    int rus = (int)(rem / 1000L);
    int rns = (int)(rem % 1000L);
    // Normalize hours >= 24 (rolls over the day; PlainTime discards the day).
    rh = rh % 24;
    if (rh < 0) rh += 24;
    HObject*? obj_o = alloc_plain_time(ctx.heap, (temporal::CivilTime){
        .h = (int)rh, .mi = (int)rmin, .s = (int)rs,
        .ms = rms, .us = rus, .ns = rns
    });
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(obj);
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
    if (ctx.argc >= 4 && !arg_at(ctx, 3).is_undefined()) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 3), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "hour is not an integral number");
            return;
        }
        h = (int)lv;
    }
    if (ctx.argc >= 5 && !arg_at(ctx, 4).is_undefined()) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 4), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "minute is not an integral number");
            return;
        }
        mi = (int)lv;
    }
    if (ctx.argc >= 6 && !arg_at(ctx, 5).is_undefined()) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 5), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "second is not an integral number");
            return;
        }
        s = (int)lv;
    }
    if (ctx.argc >= 7 && !arg_at(ctx, 6).is_undefined()) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 6), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "millisecond is not an integral number");
            return;
        }
        ms = (int)lv;
    }
    if (ctx.argc >= 8 && !arg_at(ctx, 7).is_undefined()) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 7), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "microsecond is not an integral number");
            return;
        }
        us = (int)lv;
    }
    if (ctx.argc >= 9 && !arg_at(ctx, 8).is_undefined()) {
        long lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 8), &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "nanosecond is not an integral number");
            return;
        }
        ns = (int)lv;
    }

    HObject* calendar = ctx.heap.temporal_iso_calendar;
    if (ctx.argc >= 10 && !arg_at(ctx, 9).is_undefined()) {
        if (!to_temporal_calendar_identifier(ctx, arg_at(ctx, 9), &calendar)) return;
    }

    temporal::CivilTime t = { .h = h, .mi = mi, .s = s, .ms = ms, .us = us, .ns = ns };
    temporal::CivilTime valid_t;
    if (!fields_to_valid_time(ctx, t, &valid_t, temporal::OverflowKind.REJECT, false)) return;

    if (!temporal::is_valid_iso_datetime(y, (int)m, (int)d, valid_t.h, valid_t.mi, valid_t.s, valid_t.ms, valid_t.us, valid_t.ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDateTime: invalid ISO date-time");
        return;
    }

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
    Vm* v = (Vm*)ctx.vm;

    // Per spec, the property bag is read before the options bag. We defer
    // overflow-option parsing until after the field reads are done.
    temporal::CivilDateTime result;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return; }
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDateTime.from: symbol cannot be converted");
            return;
        }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDateTime.from: invalid ISO date-time string");
            return;
        }
        // Per the Temporal grammar (DateTime[~Z]), the `Z` designator is
        // forbidden on a PlainDateTime string. A numeric UTC offset is
        // parsed and silently discarded.
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDateTime.from: Z designator is not allowed");
            return;
        }
        if (!p.has_time) {
            // A date-only string is valid: the time portion defaults to
            // 00:00:00.000000000 (Temporal.PlainDateTime.from("2001-05-02")
            // is accepted by the DateTime grammar, which releases the
            // time-part requirement).
            p.hour = 0; p.minute = 0; p.second = 0; p.nanos = 0;
        }
        temporal::CivilDate d = { .y = p.year, .m = p.month, .d = p.day };
        // For string inputs, only parse overflow when the caller passed
        // an options object. The default is constrain, so the same clamp
        // runs unless the caller asked for reject.
        if (ctx.argc >= 2 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
            temporal::OverflowKind overflow;
            if (!read_overflow_option(ctx, 1, &overflow)) return;
            int dim = temporal::days_in_month(d.y, (int)d.m);
            if (d.d > dim) {
                if (overflow == temporal::OverflowKind.REJECT) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "day overflows month");
                    return;
                }
                d.d = dim;
            }
        } else {
            int dim = temporal::days_in_month(d.y, (int)d.m);
            if (d.d > dim) d.d = dim;
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
        if (!temporal::is_valid_plain_datetime(d.y, (int)d.m, (int)d.d, (int)t.h, (int)t.mi, (int)t.s, (int)t.ms, (int)t.us, (int)t.ns)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date-time is out of range");
            return;
        }
        result = { .date = d, .time = t };
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            temporal::OverflowKind clone_overflow;
            if (!read_overflow_option(ctx, 1, &clone_overflow)) return;
            (void)clone_overflow;
            temporal::CivilDateTime cdt = plain_datetime_value(o);
            HObject*? copy_o = alloc_plain_datetime(ctx.heap, cdt, o.extra.temporal.calendar);
            if (catch err = copy_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            HObject* copy = copy_o;
            copy.prototype = ctx.heap.temporal_plain_datetime_proto;
            ctx.result.set_object(copy);
            return;
        }
        // PlainDate → PlainDateTime: date slots plus midnight, no property-bag
        // getters (ToTemporalDateTime step 2.b).
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
            temporal::OverflowKind fast_overflow;
            if (ctx.argc >= 2 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
                if (!read_overflow_option(ctx, 1, &fast_overflow)) return;
            }
            temporal::CivilDate cd = plain_date_value(o);
            temporal::CivilDateTime dt = { .date = cd, .time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 } };
            if (!temporal::is_valid_iso_datetime(dt.date.y, (int)dt.date.m, (int)dt.date.d,
                                                 dt.time.h, dt.time.mi, dt.time.s,
                                                 dt.time.ms, dt.time.us, dt.time.ns)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "date-time is out of range");
                return;
            }
            HObject*? fast_o = alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
            if (catch err = fast_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            HObject* fast = fast_o;
            fast.prototype = ctx.heap.temporal_plain_datetime_proto;
            ctx.result.set_object(fast);
            return;
        }
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            // ZonedDateTime → PlainDateTime: read the wall-clock fields of
            // the ZDT directly via zdt_wall_fields and synthesize a PDT.
            // The ZDT body methods don't expose day/hour/... as normal
            // object properties, so the bag-reading path can't extract them.
            long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
            zdt_wall_fields(o, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
            (void)off;
            temporal::OverflowKind _clone_overflow;
            if (!read_overflow_option(ctx, 1, &_clone_overflow)) return;
            temporal::CivilDate valid_d;
            temporal::CivilTime valid_t = {
                .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns,
            };
            if (!fields_to_valid_date(ctx, { .y = wy, .m = (int)wm, .d = (int)wd }, temporal::OverflowKind.CONSTRAIN, &valid_d)) return;
            if (!fields_to_valid_time(ctx, valid_t, &valid_t, temporal::OverflowKind.REJECT, false)) return;
            temporal::CivilDateTime dt = { .date = valid_d, .time = valid_t };
            HObject*? res = alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
            if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            HObject* obj = res;
            obj.prototype = ctx.heap.temporal_plain_datetime_proto;
            ctx.result.set_object(obj);
            return;
        }
        // Property bag: read fields first, then overflow option. The
        // `calendar` field is read inside bag_to_datetime_fields (via
        // bag_to_fields), so we don't double-read it here. The monthCode
        // suitability check runs AFTER the option bag so the options bag
        // is observed even when the field bag is unsuitable (test262
        // options-read-before-algorithmic-validation).
        temporal::CivilDateTime fields;
        bool have_mc;
        int mci;
        TVal mc_v;
        if (!bag_to_datetime_fields_ex(ctx, o, TBM_PLAIN, false, false, { .y = 0, .m = 1, .d = 1 },
                                    { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 }, &fields,
                                    null, &have_mc, &mci, &mc_v, null, null, null, null)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        temporal::OverflowKind overflow;
        if (!read_overflow_option(ctx, 1, &overflow)) return;
        if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        temporal::CivilDate valid_d;
        if (!fields_to_valid_date(ctx, fields.date, overflow, &valid_d)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        temporal::CivilTime valid_t;
        if (!fields_to_valid_time(ctx, fields.time, &valid_t, overflow, false)) return;
        if (!temporal::is_valid_plain_datetime(valid_d.y, (int)valid_d.m, (int)valid_d.d,
                (int)valid_t.h, (int)valid_t.mi, (int)valid_t.s, (int)valid_t.ms, (int)valid_t.us, (int)valid_t.ns)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date-time is out of range");
            return;
        }
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

// PrepareCalendarFields, restricted to what ToTemporalDateTime's non-Temporal
// object path needs: the calendar date fields (day, month, monthCode, year)
// and time fields (hour, microsecond, millisecond, minute, nanosecond,
// second), all required-field-free (missing ones default: date fields
// default via CalendarResolveFields' year/day-required check below, time
// fields default to 0). Reads happen in the spec's lexicographic property
// order across the *combined* set, via the Proxy-aware getter.
fn bool compare_datetime_fields(BuiltinContext* ctx, HObject* bag, temporal::CivilDateTime* out) {
    Vm* v = (Vm*)ctx.vm;
    long lv;

    long day = 0; bool have_day = false;
    TVal day_v = prop_or_undefined_pa(ctx, bag, "day");
    if (ctx.should_throw) return false;
    if (!day_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &day_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
            return false;
        }
        day = lv; have_day = true;
    }

    long h = 0;
    TVal h_v = prop_or_undefined_pa(ctx, bag, "hour");
    if (ctx.should_throw) return false;
    if (!h_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &h_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "hour is not an integral number");
            return false;
        }
        h = lv;
    }

    long us = 0;
    TVal us_v = prop_or_undefined_pa(ctx, bag, "microsecond");
    if (ctx.should_throw) return false;
    if (!us_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &us_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "microsecond is not an integral number");
            return false;
        }
        us = lv;
    }

    long ms = 0;
    TVal ms_v = prop_or_undefined_pa(ctx, bag, "millisecond");
    if (ctx.should_throw) return false;
    if (!ms_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &ms_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "millisecond is not an integral number");
            return false;
        }
        ms = lv;
    }

    long mi = 0;
    TVal mi_v = prop_or_undefined_pa(ctx, bag, "minute");
    if (ctx.should_throw) return false;
    if (!mi_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &mi_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "minute is not an integral number");
            return false;
        }
        mi = lv;
    }

    long month = 0; bool have_month = false;
    TVal month_v = prop_or_undefined_pa(ctx, bag, "month");
    if (ctx.should_throw) return false;
    if (!month_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &month_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
            return false;
        }
        month = lv; have_month = true;
    }

    bool have_month_code = false;
    int mc = 0;
    TVal mc_v = prop_or_undefined_pa(ctx, bag, "monthCode");
    if (ctx.should_throw) return false;
    if (!mc_v.is_undefined()) {
        if (!parse_month_code(ctx, mc_v, &mc)) return false;
        have_month_code = true;
        if (have_month && month != mc) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "month and monthCode do not agree");
            return false;
        }
        month = mc;
        have_month = true;
    }

    long ns = 0;
    TVal ns_v = prop_or_undefined_pa(ctx, bag, "nanosecond");
    if (ctx.should_throw) return false;
    if (!ns_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &ns_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "nanosecond is not an integral number");
            return false;
        }
        ns = lv;
    }

    long s = 0;
    TVal s_v = prop_or_undefined_pa(ctx, bag, "second");
    if (ctx.should_throw) return false;
    if (!s_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &s_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "second is not an integral number");
            return false;
        }
        s = lv;
    }

    long year = 0;
    TVal year_v = prop_or_undefined_pa(ctx, bag, "year");
    if (ctx.should_throw) return false;
    bool have_year = !year_v.is_undefined();
    if (have_year) {
        if (!to_integer_with_truncation(v, &year_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "year is not an integral number");
            return false;
        }
        year = lv;
    }

    // CalendarResolveFields(iso8601, fields, date): year and day are always
    // required for a full date; month is required via month OR monthCode.
    if (!have_year) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing year property");
        return false;
    }
    if (!have_day) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing day property");
        return false;
    }
    if (!have_month) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing month or monthCode property");
        return false;
    }

    out.date = { .y = year, .m = (int)month, .d = (int)day };
    out.time = { .h = h, .mi = mi, .s = s, .ms = ms, .us = us, .ns = ns };
    return true;
}

// ToTemporalDateTime, restricted to Temporal.PlainDateTime.compare's needs:
// calendar identity doesn't matter (CompareISODateTime only looks at the ISO
// fields), so the calendar-carrying fast paths just extract [[ISODateTime]]
// / [[ISODate]]+midnight without allocating a fresh calendar. A plain object
// still has its `calendar` property probed (for TypeError/RangeError on an
// invalid identifier) even though the result is discarded, to match the
// spec's GetTemporalCalendarIdentifierWithISODefault side effect.
fn bool compare_to_temporal_datetime(BuiltinContext* ctx, TVal* arg, temporal::CivilDateTime* out) {
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        hobject::ObjClass cls = o.get_class();
        if (cls == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            *out = plain_datetime_value(o);
            return true;
        }
        if (cls == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
            zdt_wall_fields(o, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
            out.date = { .y = wy, .m = (int)wm, .d = (int)wd };
            out.time = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns };
            return true;
        }
        if (cls == hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
            out.date = plain_date_value(o);
            out.time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
            return true;
        }
        // Plain property bag: probe `calendar` first (order-of-operations),
        // then read the combined date+time fields in lexicographic order.
        TVal cal_v = prop_or_undefined_pa(ctx, o, "calendar");
        if (ctx.should_throw) return false;
        if (!cal_v.is_undefined()) {
            HObject* cal;
            if (!calendar_from_arg(ctx, &cal_v, &cal)) return false;
        }
        temporal::CivilDateTime fields;
        if (!compare_datetime_fields(ctx, o, &fields)) return false;
        temporal::CivilDate valid_d;
        if (!fields_to_valid_date(ctx, fields.date, temporal::OverflowKind.CONSTRAIN, &valid_d)) return false;
        // ToTemporalDateTime calls RegulateTime via InterpretTemporalDateTimeFields
        // with no options argument, so the overflow defaults to ~constrain~.
        out.date = valid_d;
        out.time = regulate_time_constrain(fields.time);
        if (!temporal::is_valid_iso_datetime(out.date.y, (int)out.date.m, (int)out.date.d,
                                             out.time.h, out.time.mi, out.time.s,
                                             out.time.ms, out.time.us, out.time.ns)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date-time is out of range");
            return false;
        }
        return true;
    }
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return false; }
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "argument is a symbol");
            return false;
        }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO date-time string");
            return false;
        }
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Z designator not valid for PlainDateTime");
            return false;
        }
        temporal::CivilDate d = { .y = p.year, .m = p.month, .d = p.day };
        if (!temporal::is_valid_iso_date(d.y, (int)d.m, (int)d.d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
            return false;
        }
        temporal::CivilTime t = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
        if (p.has_time) {
            t = {
                .h = p.hour, .mi = p.minute, .s = p.second,
                .ms = (int)(p.nanos / 1_000_000),
                .us = (int)((p.nanos / 1000) % 1000),
                .ns = (int)(p.nanos % 1000),
            };
        }
        out.date = d;
        out.time = t;
        // ISODateTimeWithinLimits: a date-time at the ISO edge (min date at
        // midnight, or a date past the max) is outside the PlainDateTime range.
        if (!temporal::is_valid_iso_datetime(out.date.y, (int)out.date.m, (int)out.date.d,
                                             out.time.h, out.time.mi, out.time.s,
                                             out.time.ms, out.time.us, out.time.ns)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date-time is out of range");
            return false;
        }
        return true;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "argument must be a Temporal.PlainDateTime, string, or object");
    return false;
}

fn void builtin_temporal_plain_datetime_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDateTime.compare requires two arguments");
        return;
    }
    temporal::CivilDateTime ad;
    if (!compare_to_temporal_datetime(ctx, arg_at(ctx, 0), &ad)) return;
    temporal::CivilDateTime bd;
    if (!compare_to_temporal_datetime(ctx, arg_at(ctx, 1), &bd)) return;
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
            ctx.result.set_boolean(temporal::is_leap_year(y));
            return;
        }
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_ERA:
        case Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_ERAYEAR:
            // The ISO calendar has no eras, so both getters return undefined.
            ctx.result.set_undefined();
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
    TemporalRoundMode rm = TemporalRoundMode.TRUNC;
    if (ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal ov = ctx.regs[ctx.base_reg];
        if (!ov.is_object() || ov.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
            return;
        }
        HObject* opts = (HObject*)ov.get_heapptr();
        // Spec reads options in alphabetical order, calling ToString on each
        // value right after its [[Get]] (GetOption-style conversion). For
        // each field the propertyBagObserver expects the
        // `get options.X` / `get options.X.toString` / `call options.X.toString`
        // triple before the next option's [[Get]] runs. Read-and-store,
        // then validate-and-coerce in alphabetical order so the
        // observable triple order matches the spec.
        HString* cn_s = null;
        HString* fd_s = null;
        HString* rm_s = null;
        HString* su_s = null;
        bool fd_is_number = false;
        double fd_num = 0;

        TVal cn = prop_or_undefined_pa(ctx, opts, "calendarName");
        if (ctx.should_throw) return;
        if (!cn.is_undefined()) {
            cn_s = builtin_to_string_vm(ctx, &cn);
            if (ctx.should_throw) return;
            if (cn_s == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "calendarName must be a string");
                return;
            }
        }

        TVal fd = prop_or_undefined_pa(ctx, opts, "fractionalSecondDigits");
        if (ctx.should_throw) return;
        if (!fd.is_undefined()) {
            // GetStringOrNumberOption uses a Number numerically and never
            // stringifies it; only non-Numbers take the string path, where
            // "auto" is the sole valid value. Reads still happen in spec
            // order because the property was already fetched above.
            if (fd.is_numeric()) {
                fd_is_number = true;
                fd_num = fd.get_number_or_fastint();
            } else {
                fd_s = builtin_to_string_vm(ctx, &fd);
                if (ctx.should_throw) return;
                if (fd_s == null) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "fractionalSecondDigits must be a string");
                    return;
                }
            }
        }

        TVal rm_tv = prop_or_undefined_pa(ctx, opts, "roundingMode");
        if (ctx.should_throw) return;
        if (!rm_tv.is_undefined()) {
            rm_s = builtin_to_string_vm(ctx, &rm_tv);
            if (ctx.should_throw) return;
            if (rm_s == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "roundingMode must be a string");
                return;
            }
        }

        TVal su = prop_or_undefined_pa(ctx, opts, "smallestUnit");
        if (ctx.should_throw) return;
        if (!su.is_undefined()) {
            su_s = builtin_to_string_vm(ctx, &su);
            if (ctx.should_throw) return;
            if (su_s == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "smallestUnit must be a string");
                return;
            }
        }

        // Validate in any order.
        if (cn_s != null) {
            char[] v = cn_s.get_cstr()[:cn_s.blen];
            if (v == "auto") { show_calendar = false; }
            else if (v == "always") { show_calendar = true; }
            else if (v == "critical") { show_calendar = true; critical = true; }
            else if (v == "never") { show_calendar = false; }
            else { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendarName"); return; }
        }
        if (fd_is_number) {
            // Per spec, GetStringOrNumberOption floors non-integer values.
            double dv = math::floor(fd_num);
            if (math::is_nan(fd_num) || dv < 0 || dv > 9) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0..9 or \"auto\"");
                return;
            }
            ns_digits = (int)dv;
        } else if (fd_s != null) {
            char[] v = fd_s.get_cstr()[:fd_s.blen];
            if (v == "auto") { ns_digits = -1; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0..9 or \"auto\"");
                return;
            }
        }
        if (rm_s != null) {
            char[] v = rm_s.get_cstr()[:rm_s.blen];
            if (!parse_rm_str(v, &rm)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return;
            }
        }
        if (su_s != null) {
            char[] v = su_s.get_cstr()[:su_s.blen];
            // smallestUnit wins over fractionalSecondDigits when both are
            // given (ToSecondsStringPrecisionRecord keeps the unit's own
            // precision).
            if (v == "minute" || v == "minutes") {
                ns_digits = -12;
            } else if (v == "second" || v == "seconds") {
                ns_digits = 0;
            } else if (v == "millisecond" || v == "milliseconds") {
                ns_digits = 3;
            } else if (v == "microsecond" || v == "microseconds") {
                ns_digits = 6;
            } else if (v == "nanosecond" || v == "nanoseconds") {
                ns_digits = 9;
            } else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
                return;
            }
        }
    }

    // Round the time-of-day (RoundTime): increment is the unit implied by
    // the precision; whole nanoseconds (no rounding) when "auto". Rounding
    // up past midnight folds into the date part for PlainDateTime.
    long unit_ns = 0;
    if (ns_digits == -12) {
        unit_ns = 60000000000L;
    } else if (ns_digits >= 0 && ns_digits < 9) {
        unit_ns = ns_pow10(9 - ns_digits);
    } else if (ns_digits == 9) {
        unit_ns = 1;
    }
    if (unit_ns > 1) {
        long total = round_long_ns(civil_time_to_ns(dt.time), unit_ns, rm);
        if (total >= 86400000000000L) {
            total -= 86400000000000L;
            dt.date = temporal::civil_date_from_epoch_days(
                temporal::epoch_days_from_civil(dt.date.y, (int)dt.date.m, (int)dt.date.d) + 1);
        }
        dt.time = civil_time_from_ns(total);
        // The balanced datetime must still lie in the representable instant
        // range, an open interval at ±8.64e21 ns (so -271821-04-19T00:00:00.000
        // and 275760-09-14T00:00:00.000 are both out of range).
        int128 epoch_ns = (int128)temporal::epoch_days_from_civil(dt.date.y, (int)dt.date.m, (int)dt.date.d)
            * (int128)86400000000000L + (int128)total;
        int128 ns_limit = (int128)86400000000000L * (int128)100000000L;
        if (epoch_ns <= -ns_limit || epoch_ns >= ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "rounding pushed the datetime out of range");
            return;
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
    ctx.argc = 0;
    builtin_temporal_plain_datetime_proto_toString(ctx);
}

fn void builtin_temporal_plain_datetime_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    ctx.argc = 0;
    builtin_temporal_plain_datetime_proto_toString(ctx);
}

fn void builtin_temporal_plain_datetime_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* other = (HObject*)arg.get_heapptr();
        if (other.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            bool same_cal = obj.extra.temporal.calendar == other.extra.temporal.calendar;
            temporal::CivilDateTime a = plain_datetime_value(obj);
            temporal::CivilDateTime b = plain_datetime_value(other);
            ctx.result.set_boolean(same_cal && temporal::date_equals(a.date, b.date) && temporal::time_equals(a.time, b.time));
            return;
        }
    }
    // PlainDateTime can be derived from a string or property bag.
    HObject*? other_o = plain_datetime_from_arg(ctx, arg);
    if (ctx.should_throw) return;
    HObject* other = other_o!!;
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
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
            temporal::CivilDate cd = plain_date_value(o);
            temporal::CivilDateTime dt = {
                .date = cd,
                .time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 },
            };
            HObject*? res = alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
            if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
            HObject* r = res;
            r.prototype = ctx.heap.temporal_plain_datetime_proto;
            return r;
        }
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
            zdt_wall_fields(o, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
            (void)off;
            temporal::CivilDateTime dt = {
                .date = { .y = wy, .m = (int)wm, .d = (int)wd },
                .time = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns },
            };
            HObject*? res = alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
            if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
            HObject* r = res;
            r.prototype = ctx.heap.temporal_plain_datetime_proto;
            return r;
        }
        HObject* calendar = ctx.heap.temporal_iso_calendar;
        TVal cal_v = prop_or_undefined(o, ctx.heap, "calendar");
        if (!cal_v.is_undefined()) {
            if (!calendar_from_arg(ctx, &cal_v, &calendar)) return null;
        }
        temporal::CivilDateTime fields;
        bool have_mc;
        int mci;
        TVal mc_v;
        if (!bag_to_datetime_fields_ex(ctx, o, TBM_PLAIN, false, false, { .y = 0, .m = 1, .d = 1 },
                                    { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 }, &fields,
                                    null, &have_mc, &mci, &mc_v, null, null, null, null)) return null;
        if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) return null;
        temporal::CivilDate valid_d;
        if (!fields_to_valid_date(ctx, fields.date, temporal::OverflowKind.CONSTRAIN, &valid_d)) return null;
        temporal::CivilTime valid_t;
        if (!fields_to_valid_time(ctx, fields.time, &valid_t, temporal::OverflowKind.CONSTRAIN, true)) return null;
        if (!temporal::is_valid_iso_datetime(valid_d.y, (int)valid_d.m, (int)valid_d.d,
                                             valid_t.h, valid_t.mi, valid_t.s, valid_t.ms, valid_t.us, valid_t.ns)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "datetime is out of range");
            return null;
        }
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
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to a PlainDateTime");
            return null;
        }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO date-time string");
            return null;
        }
        // Per the Temporal grammar (DateTime[~Z]), the `Z` designator is
        // forbidden on a PlainDateTime string.
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Z designator not valid for PlainDateTime");
            return null;
        }
        if (!p.has_time) {
            p.hour = 0; p.minute = 0; p.second = 0; p.nanos = 0;
        }
        temporal::CivilDate d = { .y = p.year, .m = p.month, .d = p.day };
        temporal::CivilTime t = {
            .h = p.hour, .mi = p.minute, .s = p.second,
            .ms = (int)(p.nanos / 1_000_000),
            .us = (int)((p.nanos / 1000) % 1000),
            .ns = (int)(p.nanos % 1000),
        };
        if (!temporal::is_valid_iso_datetime(d.y, (int)d.m, (int)d.d, t.h, t.mi, t.s, t.ms, t.us, t.ns)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date-time is out of range");
            return null;
        }
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

// RegulateTime(..., ~constrain~): clamps each field into its valid range
// instead of rejecting, which is the default overflow behaviour ToTemporalTime
// applies when called without an options argument (as withPlainTime does).
// A leap-second-shaped hour:mi:60 collapses to :59 like the reject-mode
// fields_to_valid_time does.
fn temporal::CivilTime regulate_time_constrain(temporal::CivilTime f) {
    temporal::CivilTime v = f;
    if (v.h < 0) { v.h = 0; } else if (v.h > 23) { v.h = 23; }
    if (v.mi < 0) { v.mi = 0; } else if (v.mi > 59) { v.mi = 59; }
    if (v.s < 0) { v.s = 0; } else if (v.s > 59) { v.s = 59; }
    if (v.ms < 0) { v.ms = 0; } else if (v.ms > 999) { v.ms = 999; }
    if (v.us < 0) { v.us = 0; } else if (v.us > 999) { v.us = 999; }
    if (v.ns < 0) { v.ns = 0; } else if (v.ns > 999) { v.ns = 999; }
    return v;
}

// ToTemporalTimeRecord: reads the six time properties in the spec's
// lexicographic order (hour, microsecond, millisecond, minute, nanosecond,
// second), each via the Proxy-aware getter so property-bag observers see
// the exact [[Get]] sequence. Throws TypeError if none of the six
// properties is present (the "any" check). `cur` seeds each field so the
// caller only needs to overwrite what's actually present; callers that want
// the ToTemporalTimeRecord "complete" semantics (missing -> 0) should pass
// an all-zero `cur`.
fn bool datetime_time_record(BuiltinContext* ctx, HObject* bag, temporal::CivilTime* out) {
    Vm* v = (Vm*)ctx.vm;
    long h = 0; long mi = 0; long s = 0; long ms = 0; long us = 0; long ns = 0;
    bool have_any = false;
    long lv;

    TVal h_v = prop_or_undefined_pa(ctx, bag, "hour");
    if (ctx.should_throw) return false;
    if (!h_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &h_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "hour is not an integral number");
            return false;
        }
        h = lv;
        have_any = true;
    }
    TVal us_v = prop_or_undefined_pa(ctx, bag, "microsecond");
    if (ctx.should_throw) return false;
    if (!us_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &us_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "microsecond is not an integral number");
            return false;
        }
        us = lv;
        have_any = true;
    }
    TVal ms_v = prop_or_undefined_pa(ctx, bag, "millisecond");
    if (ctx.should_throw) return false;
    if (!ms_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &ms_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "millisecond is not an integral number");
            return false;
        }
        ms = lv;
        have_any = true;
    }
    TVal mi_v = prop_or_undefined_pa(ctx, bag, "minute");
    if (ctx.should_throw) return false;
    if (!mi_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &mi_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "minute is not an integral number");
            return false;
        }
        mi = lv;
        have_any = true;
    }
    TVal ns_v = prop_or_undefined_pa(ctx, bag, "nanosecond");
    if (ctx.should_throw) return false;
    if (!ns_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &ns_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "nanosecond is not an integral number");
            return false;
        }
        ns = lv;
        have_any = true;
    }
    TVal s_v = prop_or_undefined_pa(ctx, bag, "second");
    if (ctx.should_throw) return false;
    if (!s_v.is_undefined()) {
        if (!to_integer_with_truncation(v, &s_v, &lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "second is not an integral number");
            return false;
        }
        s = lv;
        have_any = true;
    }

    if (!have_any) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument must have at least one time property");
        return false;
    }

    out.h = h; out.mi = mi; out.s = s; out.ms = ms; out.us = us; out.ns = ns;
    return true;
}

// ToTemporalTime(item), restricted to the argument shapes withPlainTime
// needs: a PlainTime/PlainDateTime/ZonedDateTime object (time extracted
// directly, no coercion), an ISO time string, or a plain property bag read
// via ToTemporalTimeRecord above. Any other Temporal-branded object (a
// PlainDate, PlainYearMonth, PlainMonthDay, or Duration/Instant/TimeZone)
// falls through to the bag path and is rejected there with a TypeError,
// since none of those expose hour/minute/second/etc. own properties.
fn HObject*? datetime_to_temporal_time(BuiltinContext* ctx, TVal* arg) {
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        hobject::ObjClass cls = o.get_class();
        if (cls == hobject::ObjClass.TEMPORAL_PLAIN_TIME) return o;
        if (cls == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            temporal::CivilTime t = plain_datetime_value(o).time;
            HObject*? res = alloc_plain_time(ctx.heap, t);
            if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
            HObject* r = res;
            r.prototype = ctx.heap.temporal_plain_time_proto;
            return r;
        }
        if (cls == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
            zdt_wall_fields(o, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
            temporal::CivilTime t = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns };
            HObject*? res = alloc_plain_time(ctx.heap, t);
            if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
            HObject* r = res;
            r.prototype = ctx.heap.temporal_plain_time_proto;
            return r;
        }
        temporal::CivilTime fields;
        if (!datetime_time_record(ctx, o, &fields)) return null;
        // withPlainTime calls ToTemporalTime with no options argument, so
        // GetTemporalOverflowOption defaults to ~constrain~: out-of-range
        // fields clamp rather than throw.
        temporal::CivilTime valid = regulate_time_constrain(fields);
        HObject*? res = alloc_plain_time(ctx.heap, valid);
        if (catch err = res) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        HObject* r = res;
        r.prototype = ctx.heap.temporal_plain_time_proto;
        return r;
    }
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return null; }
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to a PlainTime");
            return null;
        }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        bool ok = temporal::parse_iso_time_string(text, &p);
        if (!ok) {
            ok = temporal::parse_iso_date_string(text, &p);
            if (!ok || !p.has_time) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO time string");
                return null;
            }
        }
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Z designator not valid for PlainTime");
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

// ToTimeRecordOrMidnight: undefined (or a missing argument) means midnight;
// otherwise delegate to ToTemporalTime and take its [[Time]] fields.
fn bool datetime_time_record_or_midnight(BuiltinContext* ctx, TVal* arg, temporal::CivilTime* out) {
    if (arg == null || arg.is_undefined()) {
        *out = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
        return true;
    }
    HObject*? o = datetime_to_temporal_time(ctx, arg);
    if (ctx.should_throw) return false;
    *out = plain_time_value(o!!);
    return true;
}

fn void builtin_temporal_plain_datetime_proto_withPlainTime(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    TVal undef; undef.set_undefined();
    TVal* arg = ctx.argc >= 1 ? arg_at(ctx, 0) : &undef;
    temporal::CivilTime new_time;
    if (!datetime_time_record_or_midnight(ctx, arg, &new_time)) return;

    temporal::CivilDateTime cur = plain_datetime_value(obj);
    temporal::CivilDateTime result = { .date = cur.date, .time = new_time };
    // CreateTemporalDateTime validates the combined date+time; the minimum
    // date at midnight (below the PlainDateTime lower edge) throws.
    if (!temporal::is_valid_iso_datetime(result.date.y, (int)result.date.m, (int)result.date.d,
                                         result.time.h, result.time.mi, result.time.s,
                                         result.time.ms, result.time.us, result.time.ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "datetime outside representable PlainDateTime range");
        return;
    }
    HObject*? obj_o = alloc_plain_datetime(ctx.heap, result, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* r = obj_o;
    r.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(r);
}

fn void builtin_temporal_plain_datetime_proto_toPlainDate(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDate d = plain_date_value(obj);
    HObject*? date_o = alloc_plain_date(ctx.heap, d, obj.extra.temporal.calendar);
    if (catch err = date_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* date_obj = date_o;
    date_obj.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(date_obj);
}

fn void builtin_temporal_plain_datetime_proto_toPlainTime(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilTime t;
    t.h  = obj.extra.temporal.long_d;
    t.mi = obj.extra.temporal.long_e;
    t.s  = obj.extra.temporal.long_f;
    t.ms = obj.extra.temporal.long_g;
    t.us = obj.extra.temporal.long_h;
    t.ns = obj.extra.temporal.long_i;
    HObject*? time_o = alloc_plain_time(ctx.heap, t);
    if (catch err = time_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* time_obj = time_o;
    time_obj.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(time_obj);
}

fn void builtin_temporal_plain_datetime_proto_toZonedDateTime(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();

    if (ctx.argc < 1 || ctx.regs[ctx.base_reg].is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "toZonedDateTime requires a time zone");
        return;
    }
    TVal* tz_arg = arg_at(ctx, 0);

    // Read and validate options BEFORE resolving timezone (spec order of operations).
    if (ctx.argc >= 2 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
        TVal* opts_val = arg_at(ctx, 1);
        if (!opts_val.is_object() || opts_val.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
            return;
        }
        HObject* opts = (HObject*)opts_val.get_heapptr();
        TVal dis_v = prop_or_undefined_pa(ctx, opts, "disambiguation");
        if (ctx.should_throw) return;
        if (!dis_v.is_undefined()) {
            HString* ds = builtin_to_string_vm(ctx, &dis_v);
            if (ctx.should_throw) return;
            char[] dstr = ds.get_cstr()[:ds.blen];
            if (dstr != "compatible" && dstr != "earlier" && dstr != "later" && dstr != "reject") {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid disambiguation");
                return;
            }
        }
    }

    // Resolve timezone.
    HObject* tz = null;
    if (try maybe_tz = to_temporal_tz(ctx, tz_arg)) {
        if (ctx.should_throw) return;
        tz = maybe_tz;
    } else { return; }

    // Convert datetime to epoch nanoseconds.
    temporal::CivilDateTime cdt = plain_datetime_value(obj);
    long wall_secs = temporal::epoch_days_from_civil(cdt.date.y, (int)cdt.date.m, (int)cdt.date.d) * 86400
        + cdt.time.h * 3600 + cdt.time.mi * 60 + cdt.time.s;
    long wall_frac = cdt.time.ms * 1000000 + cdt.time.us * 1000 + cdt.time.ns;
    String zone = timezone_name(tz);
    int128 epoch_ns = zdt_local_to_epoch_ns(zone, wall_secs, wall_frac);

    // Instant range check: ±100,000,000 days × 86400 × 1e9 ns.
    {
        int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
        if (epoch_ns > ns_limit || epoch_ns < -ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside the representable range");
            return;
        }
    }

    hbigint::HBigInt*? ns_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns);
    if (catch err = ns_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
    hbigint::HBigInt* ns = ns_o;
    zdt_from_parts(ctx, ns, tz, (HString*)obj.extra.temporal.calendar);
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
    if (!reject_temporal_object_bag(ctx, bag)) return;

    Vm* v = (Vm*)ctx.vm;
    temporal::CivilDateTime cur = plain_datetime_value(obj);
    temporal::CivilDateTime fields;
    bool have_mc;
    int mci;
    TVal mc_v;
    bool found_any;
    if (!bag_to_datetime_fields_ex(ctx, bag, TBM_PLAIN_WITH, true, false, cur.date, cur.time, &fields,
                                &found_any, &have_mc, &mci, &mc_v, null, null, null, null)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    if (!found_any) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "at least one property must be provided");
        return;
    }
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    temporal::CivilDate valid_d;
    if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) return;
    if (!fields_to_valid_date(ctx, fields.date, overflow, &valid_d)) return;
    temporal::CivilTime valid_t;
    if (!fields_to_valid_time(ctx, fields.time, &valid_t, overflow, false)) return;
    if (!temporal::is_valid_iso_datetime(valid_d.y, (int)valid_d.m, (int)valid_d.d,
                                         valid_t.h, valid_t.mi, valid_t.s, valid_t.ms, valid_t.us, valid_t.ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "datetime is out of range");
        return;
    }
    temporal::CivilDateTime result = { .date = valid_d, .time = valid_t };
    HObject*? obj_o = alloc_plain_datetime(ctx.heap, result, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_datetime_proto_round(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "PlainDateTime.prototype.round requires an argument");
        return;
    }
    HObject* self = (HObject*)this_val.get_heapptr();
    TVal* round_to = arg_at(ctx, 0);
    HObject* opts = null;
    TemporalUnit smallest_unit = TemporalUnit.NANOSECOND;
    bool smallest_given = false;
    double rounding_increment = 1;
    TemporalRoundMode rounding_mode = TemporalRoundMode.HALF_EXPAND;
    if (!round_to.is_object() || round_to.get_heapptr() == null) {
        // String shorthand: smallestUnit = the string.
        if (round_to.is_string() || (round_to.is_object() && round_to.get_heapptr() != null && !((HObject*)round_to.get_heapptr()).flags.callable)) {
            HString* s = builtin_to_string_vm(ctx, round_to);
            if (ctx.should_throw) return;
            char[] str = s.get_cstr()[:s.blen];
            if (!parse_unit_str(str, &smallest_unit) || smallest_unit < TemporalUnit.DAY) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
                return;
            }
            smallest_given = true;
        } else {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object or string");
            return;
        }
    } else {
        opts = (HObject*)round_to.get_heapptr();
        // Spec reads options in alphabetical order: roundingIncrement,
        // roundingMode, smallestUnit. Property bag reads must fire in
        // that sequence for test262's order-of-operations and options-
        // read-before fixtures to see the full bag before any validation
        // throws. ToString/valueOf fires per-field so observers see
        // `get options.X` / `get options.X.toString` / `call options.X.toString`
        // (and the same triple on `X.valueOf` for numeric values), then
        // move to the next option.
        TVal ri_v = prop_or_undefined_pa(ctx, opts, "roundingIncrement");
        if (ctx.should_throw) return;
        if (!ri_v.is_undefined()) {
            Vm* v = (Vm*)ctx.vm;
            double ri_val = vm::vm_to_number(v, &ri_v);
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            if (math::is_nan(ri_val) || math::is_inf(ri_val)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a positive integer");
                return;
            }
            rounding_increment = math::floor(ri_val);
            if (rounding_increment < 1) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a positive integer");
                return;
            }
        }
        TVal rm_v = prop_or_undefined_pa(ctx, opts, "roundingMode");
        if (ctx.should_throw) return;
        if (!rm_v.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &rm_v);
            if (ctx.should_throw) return;
            if (!parse_rm_str(s.get_cstr()[:s.blen], &rounding_mode)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return;
            }
        }
        TVal su_v = prop_or_undefined_pa(ctx, opts, "smallestUnit");
        if (ctx.should_throw) return;
        if (!su_v.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &su_v);
            if (ctx.should_throw) return;
            if (!parse_unit_str(s.get_cstr()[:s.blen], &smallest_unit) || smallest_unit < TemporalUnit.DAY) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
                return;
            }
            smallest_given = true;
        }
    }
    if (!smallest_given) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "round requires a smallestUnit option");
        return;
    }
    if (smallest_unit == TemporalUnit.DAY) {
        // "day" allows only roundingIncrement 1: there is exactly one day
        // per rounding unit, so nothing larger can divide evenly.
        if (rounding_increment > 1) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
            return;
        }
    } else {
        long max_incr = max_round_incr(smallest_unit);
        if (max_incr > 0 && (rounding_increment > (double)max_incr
            || (double)max_incr / rounding_increment != math::floor((double)max_incr / rounding_increment)
            || rounding_increment == (double)max_incr)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
            return;
        }
    }

    temporal::CivilDateTime cur = plain_datetime_value(self);
    long total_ns = cur.time.h * 3600000000000L + cur.time.mi * 60000000000L + cur.time.s * 1000000000L
                  + cur.time.ms * 1000000L + cur.time.us * 1000L + cur.time.ns;

    long day_delta;
    long rounded_ns;
    if (smallest_unit == TemporalUnit.DAY) {
        // roundingIncrement is fixed at 1 for "day" (checked above), so this
        // rounds the whole time-of-day to the nearer midnight.
        double day_frac = (double)total_ns / 86400000000000.0;
        double rounded_days = round_num_to_incr(day_frac, 1, rounding_mode);
        day_delta = (long)rounded_days;
        rounded_ns = 0;
    } else {
        long divisor = unit_ns_divisor(smallest_unit);
        long incr_ns = divisor * (long)rounding_increment;
        long rounded = round_long_ns(total_ns, incr_ns, rounding_mode);
        // A whole day of nanoseconds (86400000000000) can only be reached by
        // rounding up past the last representable time-of-day value; carry
        // that into the date and keep the time-of-day in [0, 1 day).
        day_delta = rounded / 86400000000000L;
        rounded_ns = rounded - day_delta * 86400000000000L;
        if (rounded_ns < 0) { rounded_ns += 86400000000000L; day_delta -= 1; }
    }

    temporal::BrokenDownTime bd = temporal::civil_from_seconds(rounded_ns / 1000000000L);
    long rem = rounded_ns - (rounded_ns / 1000000000L) * 1000000000L;
    int rms = (int)(rem / 1000000L); rem %= 1000000L;
    int rus = (int)(rem / 1000L);
    int rns = (int)(rem % 1000L);

    temporal::CivilDate new_date = cur.date;
    if (day_delta != 0) {
        long epoch_day = temporal::epoch_days_from_civil(cur.date.y, (int)cur.date.m, (int)cur.date.d) + day_delta;
        new_date = temporal::civil_date_from_epoch_days(epoch_day);
    }

    temporal::CivilDateTime result = {
        .date = new_date,
        .time = {
            .h = bd.h, .mi = bd.mi, .s = bd.s,
            .ms = rms, .us = rus, .ns = rns,
        },
    };
    if (!temporal::is_valid_plain_datetime(result.date.y, (int)result.date.m, (int)result.date.d,
                                            (int)result.time.h, (int)result.time.mi, (int)result.time.s,
                                            (int)result.time.ms, (int)result.time.us, (int)result.time.ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "rounded datetime outside representable limits");
        return;
    }
    HObject*? obj_o = alloc_plain_datetime(ctx.heap, result, self.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(obj2);
}

fn void plain_datetime_add_sub(BuiltinContext* ctx, bool subtract) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, subtract ? "subtract requires a duration" : "add requires a duration");
        return;
    }
    temporal::DurationParts dur;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur)) return;
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;

    temporal::CivilDateTime cur = plain_datetime_value(obj);
    long sign = subtract ? -1 : 1;
    long total_months = sign * (dur.years * 12 + dur.months);

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

    int128 cur_time_ns = (int128)cur.time.h * 3_600_000_000_000L + (int128)cur.time.mi * 60_000_000_000L +
                         (int128)cur.time.s * 1_000_000_000L + (int128)cur.time.ms * 1_000_000L +
                         (int128)cur.time.us * 1000L + (int128)cur.time.ns;
    int128 dur_time_ns = (int128)dur.hours * 3_600_000_000_000L + (int128)dur.minutes * 60_000_000_000L +
                         (int128)dur.seconds * 1_000_000_000L + (int128)dur.ms * 1_000_000L +
                         (int128)dur.us * 1000L + (int128)dur.ns;
    int128 sum_time_ns = subtract ? (cur_time_ns - dur_time_ns) : (cur_time_ns + dur_time_ns);
    int128 day_ns = (int128)86_400_000_000_000L;
    int128 time_days = sum_time_ns / day_ns;
    int128 rem_time_ns = sum_time_ns % day_ns;
    if (rem_time_ns < 0) {
        rem_time_ns += day_ns;
        time_days -= 1;
    }

    temporal::CivilTime time_part;
    time_part.h = (int)(rem_time_ns / 3_600_000_000_000L);
    int128 rem_ns = rem_time_ns % 3_600_000_000_000L;
    time_part.mi = (int)(rem_ns / 60_000_000_000L);
    rem_ns %= 60_000_000_000L;
    time_part.s = (int)(rem_ns / 1_000_000_000L);
    rem_ns %= 1_000_000_000L;
    time_part.ms = (int)(rem_ns / 1_000_000L);
    rem_ns %= 1_000_000L;
    time_part.us = (int)(rem_ns / 1000L);
    time_part.ns = (int)(rem_ns % 1000L);

    long total_days = sign * (dur.weeks * 7 + dur.days) + (long)time_days;
    temporal::CivilDate date_part = temporal::add_days(after_months, total_days);

    if (!temporal::is_valid_iso_datetime(date_part.y, (int)date_part.m, (int)date_part.d,
                                         time_part.h, time_part.mi, time_part.s,
                                         time_part.ms, time_part.us, time_part.ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "result is out of range");
        return;
    }

    temporal::CivilDateTime result = { .date = date_part, .time = time_part };
    HObject*? obj_o = alloc_plain_datetime(ctx.heap, result, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_datetime_proto_add(BuiltinContext* ctx) {
    plain_datetime_add_sub(ctx, false);
}

fn void builtin_temporal_plain_datetime_proto_subtract(BuiltinContext* ctx) {
    plain_datetime_add_sub(ctx, true);
}

// Difference two wall-clock date-times into a Duration, honoring largestUnit
// and the rounding options.
//
// Dates are differenced first, then the leftover time of day. Rounding to a
// calendar unit is anchored to `start`, since months and years have no fixed
// length.
//
// Returns false after throwing.
fn bool datetime_difference(BuiltinContext* ctx, temporal::CivilDateTime start,
                            temporal::CivilDateTime end, DiffSettings ds,
                            temporal::DurationParts* out) {
    long start_tod = civil_time_to_ns(start.time);
    long end_tod = civil_time_to_ns(end.time);

    temporal::CivilDate sd = start.date;
    temporal::CivilDate ed = end.date;
    long tod_delta = end_tod - start_tod;

    int cmp = temporal::date_compare(sd, ed);
    long sign = 0;
    if (cmp < 0 || (cmp == 0 && tod_delta > 0)) {
        sign = 1;
    } else if (cmp > 0 || (cmp == 0 && tod_delta < 0)) {
        sign = -1;
    }
    // Borrowing a day keeps the date difference at whole days and gives the
    // time remainder the same sign as the difference.
    if (sign > 0 && tod_delta < 0) {
        tod_delta += 86_400_000_000_000L;
        ed = temporal::add_days(ed, -1);
    } else if (sign < 0 && tod_delta > 0) {
        tod_delta -= 86_400_000_000_000L;
        ed = temporal::add_days(ed, 1);
    }

    // A time-only largestUnit folds the date span into the time delta, leaving
    // a flat nanosecond count to round.
    if (ds.largest > TemporalUnit.DAY) {
        long days = temporal::epoch_days_from_civil(ed.y, (int)ed.m, (int)ed.d)
                  - temporal::epoch_days_from_civil(sd.y, (int)sd.m, (int)sd.d);
        int128 total = (int128)days * 86_400_000_000_000L + (int128)tod_delta;
        int128 incr_ns = (int128)(unit_ns_divisor(ds.smallest) * (long)ds.increment);
        if (incr_ns > 1) total = round_long_ns_128(total, incr_ns, ds.mode);
        decompose_ns_128(total, ds.largest, out);
        return true;
    }

    temporal::DifferenceUnit du;
    switch (ds.largest) {
        case TemporalUnit.YEAR:  du = temporal::DifferenceUnit.YEARS; break;
        case TemporalUnit.MONTH: du = temporal::DifferenceUnit.MONTHS; break;
        case TemporalUnit.WEEK:  du = temporal::DifferenceUnit.WEEKS; break;
        default:                 du = temporal::DifferenceUnit.DAYS; break;
    }
    temporal::DateDifference dd = temporal::difference_date(sd, ed, du);

    temporal::DurationParts dp = time_ns_split(tod_delta, TemporalUnit.HOUR);
    dp.years = dd.years;
    dp.months = dd.months;
    dp.days = dd.days;
    if (ds.largest == TemporalUnit.WEEK) {
        dp.weeks = dd.days / 7;
        dp.days = dd.days % 7;
    }

    if (ds.smallest > TemporalUnit.DAY) {
        // The date part is whole days, so rounding stays inside the time of
        // day and can carry at most one full day into it.
        long incr_ns = unit_ns_divisor(ds.smallest) * (long)ds.increment;
        if (incr_ns > 1) {
            long rounded = round_long_ns(tod_delta, incr_ns, ds.mode);
            if (rounded != tod_delta) {
                if (rounded == 86_400_000_000_000L || rounded == -86_400_000_000_000L) {
                    // A carry of a whole day empties the time of day and adds a
                    // day to the date part, which can cascade up through
                    // months and years.
                    dp.hours = 0; dp.minutes = 0; dp.seconds = 0;
                    dp.ms = 0; dp.us = 0; dp.ns = 0;
                    if (!bump_date_part(ctx, sd, ds, sign, &dp)) return false;
                } else {
                    temporal::DurationParts t = time_ns_split(rounded, TemporalUnit.HOUR);
                    dp.hours = t.hours; dp.minutes = t.minutes; dp.seconds = t.seconds;
                    dp.ms = t.ms; dp.us = t.us; dp.ns = t.ns;
                }
            }
        }
        *out = dp;
        return true;
    }

    // For a calendar smallestUnit (day or coarser), the leftover below that
    // unit determines whether the count steps to the next whole one.
    if (ds.smallest == TemporalUnit.WEEK && ds.largest != TemporalUnit.WEEK) {
        // round_date_part reads the smallestUnit count out of dp.weeks.
        // difference_date left the sub-month remainder in dp.days (the
        // coarser components keep the year/month structure of largestUnit),
        // so split just that remainder into weeks and days.
        dp.weeks = dp.days / 7;
        dp.days = dp.days % 7;
    }
    if (!round_date_part(ctx, sd, ed, tod_delta, ds, sign, &dp)) return false;
    *out = dp;
    return true;
}

// Add a day to the date part of `dp` in the direction of `sign`, then
// rebalance. Called when time-of-day rounding carries a full day.
fn bool bump_date_part(BuiltinContext* ctx, temporal::CivilDate start, DiffSettings ds,
                       long sign, temporal::DurationParts* dp) {
    dp.days += sign;
    return rebalance_date_part(ctx, start, ds, dp);
}

// Re-derive years/months/weeks/days at largestUnit by walking `start` forward
// by the current date part and differencing again. A carry that pushes months
// to 12 or days past a month length settles here.
fn bool rebalance_date_part(BuiltinContext* ctx, temporal::CivilDate start, DiffSettings ds,
                            temporal::DurationParts* dp) {
    temporal::CivilDate end = start;
    if (dp.years != 0 || dp.months != 0) {
        end = temporal::add_months(end, dp.years * 12 + dp.months, temporal::OverflowKind.CONSTRAIN);
    }
    end = temporal::add_days(end, dp.weeks * 7 + dp.days);

    temporal::DifferenceUnit du;
    switch (ds.largest) {
        case TemporalUnit.YEAR:  du = temporal::DifferenceUnit.YEARS; break;
        case TemporalUnit.MONTH: du = temporal::DifferenceUnit.MONTHS; break;
        case TemporalUnit.WEEK:  du = temporal::DifferenceUnit.WEEKS; break;
        default:                 du = temporal::DifferenceUnit.DAYS; break;
    }
    temporal::DateDifference dd = temporal::difference_date(start, end, du);
    dp.years = dd.years;
    dp.months = dd.months;
    dp.weeks = 0;
    dp.days = dd.days;
    if (ds.largest == TemporalUnit.WEEK) {
        dp.weeks = dd.days / 7;
        dp.days = dd.days % 7;
    } else if (ds.smallest == TemporalUnit.WEEK) {
        dp.weeks = dp.days / 7;
        dp.days = dp.days % 7;
    }
    return true;
}

// Round a date-level difference to `ds.smallest` (day, week, month or year).
//
// A calendar unit has no fixed length, so the fraction is measured against the
// distance between the unit boundaries on either side of the difference:
// advance the start date by the truncated count, then by one more unit, and
// locate the exact endpoint between them.
fn bool round_date_part(BuiltinContext* ctx, temporal::CivilDate start, temporal::CivilDate end,
                        long tod_delta, DiffSettings ds, long sign,
                        temporal::DurationParts* dp) {
    if (sign == 0) return true;

    // Only the smallestUnit count is rounded; the coarser components stand as
    // difference_date produced them at largestUnit. Folding the difference into
    // smallestUnit first loses that structure, since a month is 4 weeks and 3
    // days and no whole number of weeks recovers P1M.
    long incr = (long)ds.increment;
    long units = smallest_unit_count(*dp, ds.smallest);
    long kept = units - units % incr;

    // `lo` and `hi` are the boundaries at `kept` and one increment beyond it,
    // reached by walking the date part forward from `start` with the coarser
    // components held fixed. Both must land on whole multiples of smallestUnit,
    // so everything finer is cleared first: a leftover month would carry `lo`
    // past the year boundary it marks.
    temporal::DurationParts base = *dp;
    set_smallest_unit_count(&base, ds.smallest, kept);
    clear_below(&base, ds.smallest);
    temporal::CivilDate lo = apply_date_part(start, base);
    temporal::DurationParts next = base;
    set_smallest_unit_count(&next, ds.smallest, kept + sign * incr);
    temporal::CivilDate hi = apply_date_part(start, next);

    long to_end = total_days_between(lo, end) * 86_400_000_000_000L + tod_delta;
    long span = total_days_between(lo, hi) * 86_400_000_000_000L;
    if (span == 0) return true;

    // The nudged endpoint must be a representable ISO date when it is actually
    // materialized to make a rounding decision: a rounding increment that shoves
    // the boundary past the ±275760 range is a RangeError (NudgeToCalendarUnit
    // CalendarDateAdd). An exact multiple at increment 1 (to_end == 0) steps to
    // the natural next boundary and never needs the increment-beyond one, so it
    // need not be representable (test262 PlainYearMonth argument-string-limits).
    if (to_end != 0 || ds.increment > 1) {
        if (!temporal::is_valid_iso_date(lo.y, (int)lo.m, (int)lo.d) ||
            !temporal::is_valid_iso_date(hi.y, (int)hi.m, (int)hi.d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "rounded date outside valid ISO range");
            return false;
        }
    }

    // round_long_ns takes the offset past the boundary and reports whether it
    // reaches the next one.
    long mag_span = span < 0 ? -span : span;
    long mag_end = to_end < 0 ? -to_end : to_end;
    bool step_up;
    if (mag_end * 2 == mag_span && is_half_mode(ds.mode)) {
        // An exact halfway point is settled here rather than in round_long_ns,
        // which breaks ties on the quotient within a single span. That quotient
        // is always 0, and halfEven needs the parity of the unit count.
        // Stepping up means away from zero, so ceil and floor swap for a
        // negative difference.
        TemporalRoundMode tie = sign < 0 ? mode_for_negative_magnitude(ds.mode) : ds.mode;
        switch (tie) {
            case TemporalRoundMode.HALF_EVEN:
                step_up = (kept / incr) % 2 != 0;
            case TemporalRoundMode.HALF_EXPAND:
            case TemporalRoundMode.HALF_CEIL:
                step_up = true;
            default:
                step_up = false;
        }
    } else {
        step_up = round_long_ns(to_end, mag_span, ds.mode) != 0;
    }
    set_smallest_unit_count(dp, ds.smallest, step_up ? kept + sign * incr : kept);
    clear_below(dp, ds.smallest);
    // When smallestUnit == largestUnit the rounding has already decided the
    // final value and clear_below zeroed everything finer. Rebalancing would
    // re-derive the canonical difference through add_months + difference_date,
    // which loses month counts at end-of-month boundaries (e.g., rounding
    // 10m30d up to 11m then rebalancing May31+11m → Apr30 → 10m30d).
    if (ds.smallest != ds.largest) {
        if (!rebalance_date_part(ctx, start, ds, dp)) return false;
    }
    return true;
}

fn bool is_half_mode(TemporalRoundMode m) {
    return m >= TemporalRoundMode.HALF_CEIL;
}

// The count held in `dp`'s smallestUnit field, not the difference folded into
// that unit. A roundingIncrement of 5 months under largestUnit "years" snaps
// the months within the year (2y8m -> 2y5m); under largestUnit "months" the
// whole span sits in the months field and snaps there (32m -> 30m).
fn long smallest_unit_count(temporal::DurationParts dp, TemporalUnit unit) {
    switch (unit) {
        case TemporalUnit.YEAR:  return dp.years;
        case TemporalUnit.MONTH: return dp.months;
        case TemporalUnit.WEEK:  return dp.weeks;
        default:                 return dp.days;
    }
}

// Set the count of `unit`, leaving the coarser components alone.
fn void set_smallest_unit_count(temporal::DurationParts* dp, TemporalUnit unit, long n) {
    switch (unit) {
        case TemporalUnit.YEAR:  dp.years = n; break;
        case TemporalUnit.MONTH: dp.months = n; break;
        case TemporalUnit.WEEK:  dp.weeks = n; break;
        default:                 dp.days = n; break;
    }
}

// Zero every component finer than `unit`; rounding to it leaves no remainder.
fn void clear_below(temporal::DurationParts* dp, TemporalUnit unit) {
    if (unit <= TemporalUnit.YEAR)  dp.months = 0;
    if (unit <= TemporalUnit.MONTH) dp.weeks = 0;
    if (unit <= TemporalUnit.WEEK)  dp.days = 0;
    dp.hours = 0; dp.minutes = 0; dp.seconds = 0;
    dp.ms = 0; dp.us = 0; dp.ns = 0;
}

// Advance a date by the date-level components of a Duration.
fn temporal::CivilDate apply_date_part(temporal::CivilDate d, temporal::DurationParts dp) {
    temporal::CivilDate r = d;
    long months = dp.years * 12 + dp.months;
    if (months != 0) r = temporal::add_months(r, months, temporal::OverflowKind.CONSTRAIN);
    return temporal::add_days(r, dp.weeks * 7 + dp.days);
}

fn long total_days_between(temporal::CivilDate a, temporal::CivilDate b) {
    return temporal::epoch_days_from_civil(b.y, (int)b.m, (int)b.d)
         - temporal::epoch_days_from_civil(a.y, (int)a.m, (int)a.d);
}

fn long civil_time_to_ns(temporal::CivilTime t) {
    return ((long)t.h * 3600 + (long)t.mi * 60 + (long)t.s) * 1_000_000_000L
         + (long)t.ms * 1_000_000L + (long)t.us * 1000L + (long)t.ns;
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

    DiffSettings ds;
    if (!read_diff_settings(ctx, 1, TemporalUnit.YEAR, TemporalUnit.NANOSECOND,
                            TemporalUnit.DAY, TemporalUnit.NANOSECOND, flipped, &ds)) return;

    temporal::CivilDateTime a = plain_datetime_value(obj);
    temporal::CivilDateTime b = plain_datetime_value(other);
    // Always compute b - a (positive direction). The spec algorithm uses
    // `this` as the rounding origin (matching NudgeToCalendarUnit's
    // isoDateTime parameter), regardless of until/since, and flips the
    // sign at the end for `since`.
    temporal::CivilDateTime start = a;
    temporal::CivilDateTime end   = b;

    temporal::DurationParts dur;
    if (!datetime_difference(ctx, start, end, ds, &dur)) return;

    if (flipped) {
        dur.years = -dur.years;
        dur.months = -dur.months;
        dur.weeks = -dur.weeks;
        dur.days = -dur.days;
        dur.hours = -dur.hours;
        dur.minutes = -dur.minutes;
        dur.seconds = -dur.seconds;
        dur.ms = -dur.ms;
        dur.us = -dur.us;
        dur.ns = -dur.ns;
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
    if (ctx.argc < 1 || ctx.regs[ctx.base_reg].is_undefined()) {
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
// object and writes a CivilDate whose `d` slot is the reference day (always
// 1, per CalendarYearMonthFromFields forcing `fields.day = 1` before
// resolving — the reference day is never taken from a bag's `day`
// property, not even when the caller `with()`s a partial bag over an
// existing PlainYearMonth). `with()` passes the current reference day
// through `cur_day` untouched.
//
// Property reads follow PrepareCalendarFields's order: `calendar` is read
// first (GetTemporalCalendarIdentifierWithISODefault), then the ISO
// calendar's field set (`month`, `monthCode`, `year`) in alphabetical
// order, each Get followed by its conversion so observers see the
// valueOf/toString calls between the gets. The ISO calendar's
// `extraFields()` is empty, so `day`/`era`/`eraYear` are never read at
// all. With `with_mode` (PlainYearMonth.with), `calendar` and `timeZone`
// are Get-probed and rejected on presence (RejectObjectWithCalendarOrTimeZone,
// which is a [[Get]] per test262 order-of-operations), and the bag must
// carry at least one of month/monthCode/year.
fn bool bag_to_yearmonth_fields(BuiltinContext* ctx, HObject* bag, bool keep_missing, bool with_mode,
                                long cur_y, int cur_m, int cur_day,
                                long* out_y, int* out_m, int* out_day,
                                bool* out_have_mc, int* out_mci, TVal* out_mc_v) {
    Vm* v = (Vm*)ctx.vm;
    *out_have_mc = false;
    if (with_mode) {
        TVal cal_p = prop_or_undefined_pa(ctx, bag, "calendar");
        if (ctx.should_throw) return false;
        if (!cal_p.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a calendar property");
            return false;
        }
        TVal tz_p = prop_or_undefined_pa(ctx, bag, "timeZone");
        if (ctx.should_throw) return false;
        if (!tz_p.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a timeZone property");
            return false;
        }
    } else {
        TVal cal_v = prop_or_undefined_pa(ctx, bag, "calendar");
        if (ctx.should_throw) return false;
        if (!cal_v.is_undefined()) {
            HObject* cal;
            if (!calendar_from_arg(ctx, &cal_v, &cal)) return false;
        }
    }

    // month, then monthCode, then year, each converted immediately after
    // its Get (alphabetical PrepareCalendarFields order).
    int m = cur_m;
    bool have_month = false;
    bool have_mc = false;
    long mv = 0;
    TVal month_v = prop_or_undefined_pa(ctx, bag, "month");
    if (ctx.should_throw) return false;
    if (!month_v.is_undefined()) {
        have_month = true;
        if (!to_integer_with_truncation(v, &month_v, &mv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
            return false;
        }
        if (mv < 1) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is out of range");
            return false;
        }
    }
    TVal mc_v = prop_or_undefined_pa(ctx, bag, "monthCode");
    if (ctx.should_throw) return false;
    if (!mc_v.is_undefined()) {
        have_mc = true;
        int mci;
        if (!parse_month_code(ctx, mc_v, &mci)) return false;
        // Report the parsed monthCode so the caller can run the ISO
        // suitability check after read_overflow_option (options-read-
        // before-algorithmic-validation.js expects overflow read first
        // when monthCode is unsuitable).
        *out_have_mc = true;
        *out_mci = mci;
        *out_mc_v = mc_v;
        if (have_month && mv != mci) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "month and monthCode do not agree");
            return false;
        }
        m = mci;
    } else if (have_month) {
        m = (int)mv;
    } else if (!keep_missing && !with_mode) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing month property");
        return false;
    }

    long y = cur_y;
    TVal year_v = prop_or_undefined_pa(ctx, bag, "year");
    if (ctx.should_throw) return false;
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

    if (with_mode && !have_month && !have_mc && year_v.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "with() requires at least one recognised field");
        return false;
    }

    // `day` is never a calendar field for the year-month projection (the
    // ISO calendar's CalendarYearMonthFromFields always forces the
    // reference day to 1 before resolving); a bag's `day` property, if
    // any, is neither read nor applied. `from()` always passes cur_day==1;
    // `with()` passes the existing PlainYearMonth's reference day through
    // untouched.
    int d = cur_day;

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
    if (!temporal::is_valid_iso_yearmonth(y, (int)m)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
        return false;
    }
    *out_y = y;
    *out_m = m;
    *out_d = d;
    return true;
}

// Temporal.PlainYearMonth(year, month, calendar?, referenceDay?) — per spec,
// the 3rd argument is the calendar (string or Calendar object) and the 4th
// is the reference day (1..31, used only for date arithmetic). Older builds
// mistakenly treated the 3rd slot as `day`, which made `new PlainYearMonth(2000, 5, "iso8601")`
// throw "day is not an integral number" because the calendar string
// converted to NaN. Reorder: calendar first, then reference day.
fn void builtin_temporal_plain_yearmonth_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainYearMonth requires new");
        return;
    }
    Vm* v = (Vm*)ctx.vm;
    long y = 0;
    int m = 1;
    int reference_day = 1;

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

    HObject* calendar = ctx.heap.temporal_iso_calendar;
    if (ctx.argc >= 3 && !arg_at(ctx, 2).is_undefined()) {
        if (!to_temporal_calendar_identifier(ctx, arg_at(ctx, 2), &calendar)) return;
    }
    if (ctx.argc >= 4 && !arg_at(ctx, 3).is_undefined()) {
        long d_lv;
        if (!to_integer_with_truncation(v, arg_at(ctx, 3), &d_lv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "referenceDay is not an integral number");
            return;
        }
        reference_day = (int)d_lv;
    }

    long vy; int vm; int vd;
    if (!fields_to_valid_yearmonth(ctx, y, m, reference_day, temporal::OverflowKind.REJECT, &vy, &vm, &vd)) return;

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
    Vm* v = (Vm*)ctx.vm;

    long vy = 0; int vm = 1; int vd = 1;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return; }
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainYearMonth.from: symbol cannot be converted");
            return;
        }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_yearmonth_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainYearMonth.from: invalid ISO year-month string");
            return;
        }
        // Per the Temporal grammar (`AnnotatedDateTime[~Zoned, ~TimeRequired]`
        // for the year-month projection), the `Z` designator is not allowed.
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainYearMonth.from: Z designator is not allowed");
            return;
        }
        vy = p.year; vm = p.month; vd = p.day;
        // For string inputs, only parse overflow when the caller passed
        // an options object. The default is constrain.
        if (ctx.argc >= 2 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
            temporal::OverflowKind overflow;
            if (!read_overflow_option(ctx, 1, &overflow)) return;
            if (!fields_to_valid_yearmonth(ctx, vy, vm, vd, overflow, &vy, &vm, &vd)) return;
        } else {
            if (!fields_to_valid_yearmonth(ctx, vy, vm, vd, temporal::OverflowKind.CONSTRAIN, &vy, &vm, &vd)) return;
        }
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH) {
            // IsTemporalYearMonth fast path: still validates (and discards)
            // the options bag before copying, per ToTemporalYearMonth step
            // 1.a (`GetTemporalOverflowOption` runs even though its result
            // is unused for an identity copy).
            temporal::OverflowKind clone_overflow;
            if (!read_overflow_option(ctx, 1, &clone_overflow)) return;
            (void)clone_overflow;
            HObject*? copy_o = alloc_plain_yearmonth(
                ctx.heap, plain_yearmonth_y(o), plain_yearmonth_m(o), plain_yearmonth_day(o),
                ctx.heap.temporal_iso_calendar);
            if (catch err = copy_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            HObject* copy = copy_o;
            copy.prototype = ctx.heap.temporal_plain_yearmonth_proto;
            ctx.result.set_object(copy);
            return;
        }
        // `bag_to_yearmonth_fields` reads `calendar` itself (in spec
        // order, before month/monthCode/year); reading it again here would
        // double-fire a `calendar` getter (order-of-operations bug). Read
        // the property bag first, then parse the overflow option, so the
        // options log line follows the fields log line. The monthCode
        // suitability check runs AFTER the option bag so the options bag
        // is observed even when the field bag is unsuitable (test262
        // options-read-before-algorithmic-validation).
        long y; int m; int d;
        bool have_mc;
        int mci;
        TVal mc_v;
        if (!bag_to_yearmonth_fields(ctx, o, false, false, 0, 1, 1, &y, &m, &d,
                                     &have_mc, &mci, &mc_v)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        temporal::OverflowKind overflow;
        if (!read_overflow_option(ctx, 1, &overflow)) return;
        if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) {
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

// Temporal.PlainYearMonth.compare(one, two): both arguments go through
// ToTemporalYearMonth — the same string / property-bag / PlainYearMonth
// coercion `from()` uses (CompareTemporalYearMonth in the spec calls
// ToTemporalYearMonth on each, not a stricter brand check) — fully
// coercing `one` before touching `two`, per argument order. The ordering
// is CompareISODate: year, then month, then the reference ISO day (always
// 1 for any coerced value here, but included for structural parity with
// the spec's CompareISODate).
fn void builtin_temporal_plain_yearmonth_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainYearMonth.compare requires two arguments");
        return;
    }
    HObject*? a_o = plain_yearmonth_from_arg_full(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject*? b_o = plain_yearmonth_from_arg_full(ctx, arg_at(ctx, 1));
    if (ctx.should_throw) return;
    long ay = plain_yearmonth_y(a_o!!);
    long by = plain_yearmonth_y(b_o!!);
    int am = plain_yearmonth_m(a_o!!);
    int bm = plain_yearmonth_m(b_o!!);
    int ad = plain_yearmonth_day(a_o!!);
    int bd = plain_yearmonth_day(b_o!!);
    int cmp = 0;
    if (ay != by) { cmp = ay < by ? -1 : 1; }
    else if (am != bm) { cmp = am < bm ? -1 : 1; }
    else if (ad != bd) { cmp = ad < bd ? -1 : 1; }
    ctx.result.set_fastint((long)cmp);
}

fn void builtin_temporal_plain_yearmonth_proto_year(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    ctx.result.set_number((double)plain_yearmonth_y(obj));
}

fn void builtin_temporal_plain_yearmonth_proto_referenceISOYear(BuiltinContext* ctx) {
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
        TVal cn = prop_or_undefined_pa(ctx, opts, "calendarName");
        if (ctx.should_throw) return;
        if (!cn.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &cn);
            if (ctx.should_throw) return;
            if (s == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "calendarName must be a string");
                return;
            }
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
        // TemporalYearMonthToString: "always"/"critical" also emit the
        // reference day so the string round-trips through PlainDate.
        len += (usz)libc::snprintf(&buf[len], 48 - len, "-%02d", plain_yearmonth_day(obj));
        char[] ann = critical ? "[!u-ca=iso8601]" : "[u-ca=iso8601]";
        for (usz k = 0; k < ann.len; k++) buf[len++] = ann[k];
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_yearmonth_proto_toJSON(BuiltinContext* ctx) {
    ctx.argc = 0;
    builtin_temporal_plain_yearmonth_proto_toString(ctx);
}

fn void builtin_temporal_plain_yearmonth_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    ctx.argc = 0;
    builtin_temporal_plain_yearmonth_proto_toString(ctx);
}

// ToTemporalYearMonth coercion for equals(): unlike plain_yearmonth_from_arg
// (used by compare/until/since, which require an actual PlainYearMonth),
// equals must accept the full ISO string / property-bag forms that
// Temporal.PlainYearMonth.from accepts. This mirrors
// builtin_temporal_plain_yearmonth_from's coercion exactly (minus the
// options-bag overflow read, which equals does not take).
fn HObject*? plain_yearmonth_from_arg_full(BuiltinContext* ctx, TVal* arg) {
    Vm* v = (Vm*)ctx.vm;
    long vy = 0; int vm = 1; int vd = 1;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return null; }
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to a PlainYearMonth");
            return null;
        }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_yearmonth_string(text, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO year-month string");
            return null;
        }
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Z designator is not allowed");
            return null;
        }
        vy = p.year; vm = p.month; vd = p.day;
        if (!fields_to_valid_yearmonth(ctx, vy, vm, vd, temporal::OverflowKind.CONSTRAIN, &vy, &vm, &vd)) return null;
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH) return o;
        // `bag_to_yearmonth_fields` reads `calendar` itself; reading it
        // again here would double-fire a `calendar` getter.
        long y; int m; int d;
        bool have_mc;
        int mci;
        TVal mc_v;
        if (!bag_to_yearmonth_fields(ctx, o, false, false, 0, 1, 1, &y, &m, &d,
                                     &have_mc, &mci, &mc_v)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return null;
        }
        if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) return null;
        if (!fields_to_valid_yearmonth(ctx, y, m, d, temporal::OverflowKind.CONSTRAIN, &vy, &vm, &vd)) return null;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument must be a string or object");
        return null;
    }
    HObject*? obj_o = alloc_plain_yearmonth(ctx.heap, vy, vm, vd, ctx.heap.temporal_iso_calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
    return obj_o;
}

fn void builtin_temporal_plain_yearmonth_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    HObject*? other_o = plain_yearmonth_from_arg_full(ctx, arg);
    if (ctx.should_throw) return;
    HObject* other = other_o!!;
    long ay = plain_yearmonth_y(obj);
    long by = plain_yearmonth_y(other);
    int am = plain_yearmonth_m(obj);
    int bm = plain_yearmonth_m(other);
    int ad = plain_yearmonth_day(obj);
    int bd = plain_yearmonth_day(other);
    bool same_cal = obj.extra.temporal.calendar == other.extra.temporal.calendar;
    ctx.result.set_boolean(same_cal && ay == by && am == bm && ad == bd);
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
    if (!reject_temporal_object_bag(ctx, bag)) return;

    Vm* v = (Vm*)ctx.vm;

    long y; int m; int d;
    bool have_mc;
    int mci;
    TVal mc_v;
    if (!bag_to_yearmonth_fields(ctx, bag, true, true,
                                  plain_yearmonth_y(obj), plain_yearmonth_m(obj), plain_yearmonth_day(obj),
                                  &y, &m, &d,
                                  &have_mc, &mci, &mc_v)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) {
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

fn void builtin_temporal_plain_yearmonth_proto_toPlainDate(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_YEARMONTH, "this is not a Temporal.PlainYearMonth")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "toPlainDate requires an item bag");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "toPlainDate requires an object");
        return;
    }
    HObject* bag = (HObject*)arg.get_heapptr();
    Vm* v = (Vm*)ctx.vm;

    TVal day_v = prop_or_undefined_pa(ctx, bag, "day");
    if (ctx.should_throw) return;
    if (day_v.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing day property");
        return;
    }
    long d;
    if (!to_integer_with_truncation(v, &day_v, &d)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        else { builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number"); }
        return;
    }

    temporal::CivilDate fields;
    fields.y = plain_yearmonth_y(obj);
    fields.m = plain_yearmonth_m(obj);
    fields.d = (int)d;

    temporal::CivilDate valid;
    if (!fields_to_valid_date(ctx, fields, temporal::OverflowKind.CONSTRAIN, &valid)) return;

    HObject*? obj_o = alloc_plain_date(ctx.heap, valid, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_date_proto;
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
    // PlainYearMonth holds no day component: any non-zero unit below months
    // (days, hours, …) is a RangeError, regardless of overflow (test262
    // argument-lower-units, end-of-month-out-of-range).
    if (dur.weeks != 0 || dur.days != 0 || dur.hours != 0 || dur.minutes != 0 || dur.seconds != 0 ||
        dur.ms != 0 || dur.us != 0 || dur.ns != 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "cannot add a unit lower than months to a PlainYearMonth");
        return;
    }

    long cur_y = plain_yearmonth_y(obj);
    int cur_m = plain_yearmonth_m(obj);
    int cur_d = plain_yearmonth_day(obj);
    // The intermediate date (reference day in the receiver's month) must itself
    // be representable; a year-month at the ISO boundary (e.g. -271821-04 with
    // reference day 1, below the 04-19 minimum) cannot be added to at all.
    if (!temporal::is_valid_iso_date(cur_y, cur_m, cur_d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "year-month reference date is out of range");
        return;
    }
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
    if (dur.weeks != 0 || dur.days != 0 || dur.hours != 0 || dur.minutes != 0 || dur.seconds != 0 ||
        dur.ms != 0 || dur.us != 0 || dur.ns != 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "cannot subtract a unit lower than months from a PlainYearMonth");
        return;
    }

    long cur_y = plain_yearmonth_y(obj);
    int cur_m = plain_yearmonth_m(obj);
    int cur_d = plain_yearmonth_day(obj);
    if (!temporal::is_valid_iso_date(cur_y, cur_m, cur_d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "year-month reference date is out of range");
        return;
    }
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
    HObject*? other_o = plain_yearmonth_from_arg_full(ctx, arg_at(ctx, 0));
    if (ctx.should_throw) return;
    HObject* other = other_o!!;

    HObject* this_cal = obj.extra.temporal.calendar;
    HObject* other_cal = other.extra.temporal.calendar;
    if (this_cal != other_cal || this_cal == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "calendars do not match");
        return;
    }

    // A PlainYearMonth has no day, so only year and month units are accepted.
    // For `since` the rounding mode is negated (ceil ↔ floor, halfCeil ↔
    // halfFloor) and the result is negated at the end, matching
    // DifferenceTemporalPlainDate / DifferenceTemporalPlainDateTime.
    DiffSettings ds;
    if (!read_diff_settings(ctx, 1, TemporalUnit.YEAR, TemporalUnit.MONTH,
                            TemporalUnit.YEAR, TemporalUnit.MONTH, flipped, &ds)) return;

    long a_y = plain_yearmonth_y(obj);
    int  a_m = plain_yearmonth_m(obj);
    long b_y = plain_yearmonth_y(other);
    int  b_m = plain_yearmonth_m(other);
    // Always compute b - a (positive direction); round_date_part uses `a`
    // as the origin regardless of until/since, mirroring NudgeToCalendarUnit.
    long start_y = a_y;
    int  start_m = a_m;
    long end_y   = b_y;
    int  end_m   = b_m;

    // Use a synthetic date at day 1 so the shared date differencing handles the
    // year/month split identically to the PlainDate path.
    temporal::CivilDateTime start = { .date = { .y = start_y, .m = start_m, .d = 1 } };
    temporal::CivilDateTime end   = { .date = { .y = end_y,   .m = end_m,   .d = 1 } };

    // DifferenceTemporalPlainYearMonth forms each operand as a day-1 date and
    // throws when that date is outside the representable ISO range. Equal
    // operands short-circuit to a zero difference before that formation (so
    // the minimum year-month compared to itself yields PT0S).
    if (a_y != b_y || a_m != b_m) {
        if (!temporal::is_valid_iso_date(start_y, start_m, 1) ||
            !temporal::is_valid_iso_date(end_y, end_m, 1)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "year-month outside usable date range");
            return;
        }
    }

    temporal::DurationParts dur;
    if (!datetime_difference(ctx, start, end, ds, &dur)) return;

    if (flipped) {
        dur.years = -dur.years;
        dur.months = -dur.months;
        dur.weeks = -dur.weeks;
        dur.days = -dur.days;
        dur.hours = -dur.hours;
        dur.minutes = -dur.minutes;
        dur.seconds = -dur.seconds;
        dur.ms = -dur.ms;
        dur.us = -dur.us;
        dur.ns = -dur.ns;
    }

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
fn bool bag_to_monthday_fields(BuiltinContext* ctx, HObject* bag, bool keep_missing, bool with_mode,
                                int cur_y, int cur_m, int cur_d,
                                int* out_y, int* out_m, int* out_d,
                                bool* out_have_mc, int* out_mci, TVal* out_mc_v,
                                bool* out_found_any = null) {
    Vm* v = (Vm*)ctx.vm;
    *out_have_mc = false;
    bool found_any = false;
    // Spec reads the calendar fields alphabetically — calendar, day,
    // month, monthCode, year — for the ISO 8601 calendar. era / eraYear
    // are NOT in ISO PrepareTemporalFields and are intentionally not
    // probed here; propertyBagObserver expects the fire of these five
    // traps in lexicographic order, with each property's valueOf/toString
    // triple landing between the get and the next field's get. With
    // `with_mode`, `calendar` and `timeZone` are Get-probed and rejected
    // on presence (RejectObjectWithCalendarOrTimeZone, a [[Get]] per
    // test262 order-of-operations).
    if (with_mode) {
        TVal cal_p = prop_or_undefined_pa(ctx, bag, "calendar");
        if (ctx.should_throw) return false;
        if (!cal_p.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a calendar property");
            return false;
        }
        TVal tz_p = prop_or_undefined_pa(ctx, bag, "timeZone");
        if (ctx.should_throw) return false;
        if (!tz_p.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "with() does not accept a timeZone property");
            return false;
        }
    } else {
        TVal cal_v = prop_or_undefined_pa(ctx, bag, "calendar");
        if (ctx.should_throw) return false;
        if (!cal_v.is_undefined()) {
            HObject* cal;
            if (!calendar_from_arg(ctx, &cal_v, &cal)) return false;
        }
    }

    // day (alphabetical position 2): read, then coerce via
    // toIntegerWithTruncation which fires the primitive's valueOf.
    int d = cur_d;
    TVal day_v = prop_or_undefined_pa(ctx, bag, "day");
    if (!day_v.is_undefined()) {
        found_any = true;
        long dl;
        if (!to_integer_with_truncation(v, &day_v, &dl)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is not an integral number");
            return false;
        }
        if (dl < 1) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "day is out of range");
            return false;
        }
        d = (int)dl;
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing day property");
        return false;
    }

    // month
    int m = cur_m;
    TVal month_v = prop_or_undefined_pa(ctx, bag, "month");
    bool have_month = false;
    long mv = 0;
    if (!month_v.is_undefined()) {
        found_any = true;
        if (!to_integer_with_truncation(v, &month_v, &mv)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is not an integral number");
            return false;
        }
        if (mv < 1) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "month is out of range");
            return false;
        }
        have_month = true;
    }

    // monthCode: parse_month_code fires toString on the wrapped primitive
    TVal mc_v = prop_or_undefined_pa(ctx, bag, "monthCode");
    if (!mc_v.is_undefined()) {
        found_any = true;
        int mci;
        if (!parse_month_code(ctx, mc_v, &mci)) return false;
        *out_have_mc = true;
        *out_mci = mci;
        *out_mc_v = mc_v;
        if (have_month && mv != mci) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "month and monthCode do not agree");
            return false;
        }
        m = mci;
    } else if (have_month) {
        m = (int)mv;
    } else if (!keep_missing) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing month property");
        return false;
    }

    // year (last alphabetical position)
    int y = cur_y;
    TVal year_v = prop_or_undefined_pa(ctx, bag, "year");
    if (!year_v.is_undefined()) {
        found_any = true;
        long yl;
        if (!to_integer_with_truncation(v, &year_v, &yl)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return false; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "year is not an integral number");
            return false;
        }
        y = (int)yl;
    } else if (!keep_missing) {
        y = 1972;  // default reference year: leap year so Feb 29 is valid
    }

    *out_y = y;
    *out_m = m;
    *out_d = d;
    if (out_found_any != null) *out_found_any = found_any;
    return true;
}

// Constrain or reject (year, month, day) into a valid CivilDate. The year is
// only used for calendar checks (Feb 29 requires a leap year); outside that
// case the value is unchanged.
fn bool fields_to_valid_monthday(BuiltinContext* ctx, int y, int m, int d,
                                   temporal::OverflowKind overflow,
                                   int* out_y, int* out_m, int* out_d) {
    if (m < 1) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid month"); return false;
    }
    if (m > 12) {
        if (overflow == temporal::OverflowKind.REJECT) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid month"); return false; }
        m = 12;
    }
    if (d < 1) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid day"); return false;
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
    if (ctx.argc >= 3 && !arg_at(ctx, 2).is_undefined()) {
        if (!to_temporal_calendar_identifier(ctx, arg_at(ctx, 2), &calendar)) return;
    }

    int y = 1972;  // ISO ref year (leap so M02-29 is representable); spec passes through 4th arg
    if (ctx.argc >= 4 && !arg_at(ctx, 3).is_undefined()) {
        long yl;
        if (!to_integer_with_truncation(v, arg_at(ctx, 3), &yl)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            builtin_throw(ctx, ctx.heap.range_err_proto, "reference year is not an integral number");
            return;
        }
        y = (int)yl;
    }
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

    // PlainMonthDay fast path: read overflow first, then copy.
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY) {
            temporal::OverflowKind _ov;
            if (!read_overflow_option(ctx, 1, &_ov)) return;
            HObject*? copy_o = alloc_plain_monthday(ctx.heap,
                (int)o.extra.temporal.long_a, (int)o.extra.temporal.long_b,
                (int)o.extra.temporal.long_c, o.extra.temporal.calendar);
            if (catch err = copy_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            HObject* copy = copy_o;
            copy.prototype = ctx.heap.temporal_plain_monthday_proto;
            ctx.result.set_object(copy);
            return;
        }
    }

    // String path: parse first (may throw RangeError without reading overflow),
    // then validate strictly with REJECT (ISO strings ignore overflow).
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return; }
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainMonthDay: symbol cannot be converted");
            return;
        }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        bool ok = temporal::parse_iso_monthday_string(text, &p);
        if (!ok) {
            ok = temporal::parse_iso_date_string(text, &p);
            if (!ok) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainMonthDay: invalid ISO month-day string");
                return;
            }
        }
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainMonthDay: Z designator is not allowed");
            return;
        }
        int sy = 1972; int sm = p.month; int sd = p.day;
        if (!fields_to_valid_monthday(ctx, sy, sm, sd, temporal::OverflowKind.REJECT, &sy, &sm, &sd)) return;
        // Read overflow after successful parse (test262 observable ordering).
        temporal::OverflowKind _ov;
        if (!read_overflow_option(ctx, 1, &_ov)) return;
        HObject*? obj_o = alloc_plain_monthday(ctx.heap, sy, sm, sd, ctx.heap.temporal_iso_calendar);
        if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* obj = obj_o;
        obj.prototype = ctx.heap.temporal_plain_monthday_proto;
        ctx.result.set_object(obj);
        return;
    }

    // Bag path: read fields first, then read overflow, then validate.
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        HObject* calendar = ctx.heap.temporal_iso_calendar;
        TVal cal_v = prop_or_undefined(o, ctx.heap, "calendar");
        if (!cal_v.is_undefined()) {
            if (!calendar_from_arg(ctx, &cal_v, &calendar)) return;
        }
        int y; int m; int d;
        bool have_mc;
        int mci;
        TVal mc_v;
        Vm* v = (Vm*)ctx.vm;
        if (!bag_to_monthday_fields(ctx, o, false, false, 1972, 1, 1, &y, &m, &d,
                                    &have_mc, &mci, &mc_v)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        // Read overflow after bag fields (test262 observable ordering).
        temporal::OverflowKind overflow;
        if (!read_overflow_option(ctx, 1, &overflow)) return;
        // Validate monthCode suitability after overflow is read.
        if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) return;
        if (!fields_to_valid_monthday(ctx, y, m, d, overflow, &y, &m, &d)) return;
        HObject*? obj_o = alloc_plain_monthday(ctx.heap, 1972, m, d, ctx.heap.temporal_iso_calendar);
        if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* obj = obj_o;
        obj.prototype = ctx.heap.temporal_plain_monthday_proto;
        ctx.result.set_object(obj);
        return;
    }

    // Primitive path: throw TypeError without reading overflow.
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainMonthDay: argument must be a string or object");
}

// ToTemporalMonthDay shared path: takes a string, property bag, or another
// PlainMonthDay (handled by the caller) and produces vy/vm/vd. Symbol
// inputs throw TypeError; non-string non-object primitives throw TypeError;
// invalid strings throw RangeError. The caller adds the PlainMonthDay
// fast-path and the allocation.
fn bool plainmonthday_from_arg_full(BuiltinContext* ctx, TVal* arg, temporal::OverflowKind overflow, int* out_y, int* out_m, int* out_d) {
    Vm* v = (Vm*)ctx.vm;
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return false; }
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainMonthDay: symbol cannot be converted");
            return false;
        }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoDateTime p;
        bool ok = temporal::parse_iso_monthday_string(text, &p);
        if (!ok) {
            ok = temporal::parse_iso_date_string(text, &p);
            if (!ok || !p.has_time) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainMonthDay: invalid ISO month-day string");
                return false;
            }
        }
        if (p.offset_kind == temporal::OffsetKind.Z) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainMonthDay: Z designator is not allowed");
            return false;
        }
        *out_y = 1972; *out_m = p.month; *out_d = p.day;
        return fields_to_valid_monthday(ctx, *out_y, *out_m, *out_d, temporal::OverflowKind.REJECT, out_y, out_m, out_d);
    }
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        HObject* calendar = ctx.heap.temporal_iso_calendar;
        TVal cal_v = prop_or_undefined(o, ctx.heap, "calendar");
        if (!cal_v.is_undefined()) {
            if (!calendar_from_arg(ctx, &cal_v, &calendar)) return false;
        }
        int y; int m; int d;
        bool have_mc;
        int mci;
        TVal mc_v;
        if (!bag_to_monthday_fields(ctx, o, false, false, 1972, 1, 1, &y, &m, &d,
                                    &have_mc, &mci, &mc_v)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return false;
        }
        // monthCode suitability is checked AFTER read_overflow_option in the
        // caller (the option is read first at line 6948); running the check
        // here keeps PlainMonthDay.from's options-before-algorithmic-validation
        // invariant even when the input bag is otherwise valid.
        if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) return false;
        return fields_to_valid_monthday(ctx, y, m, d, overflow, out_y, out_m, out_d);
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainMonthDay: argument must be a string or object");
    return false;
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

fn void builtin_temporal_plain_monthday_proto_referenceISOYear(BuiltinContext* ctx) {
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
        TVal cn = prop_or_undefined_pa(ctx, opts, "calendarName");
        if (ctx.should_throw) return;
        if (!cn.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &cn);
            if (ctx.should_throw) return;
            if (s == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "calendarName must be a string");
                return;
            }
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
    if (show_calendar) {
        len = (usz)libc::snprintf(&buf, 48, "%04d-%02d-%02d", y, m, d);
        char[] ann = critical ? "[!u-ca=iso8601]" : "[u-ca=iso8601]";
        for (usz k = 0; k < ann.len; k++) buf[len++] = ann[k];
    } else {
        len = (usz)libc::snprintf(&buf, 48, "%02d-%02d", m, d);
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_monthday_proto_toJSON(BuiltinContext* ctx) {
    ctx.argc = 0;
    builtin_temporal_plain_monthday_proto_toString(ctx);
}

fn void builtin_temporal_plain_monthday_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    ctx.argc = 0;
    builtin_temporal_plain_monthday_proto_toString(ctx);
}

fn void builtin_temporal_plain_monthday_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* other = (HObject*)arg.get_heapptr();
        if (other.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY) {
            int ay = plain_monthday_year(obj);
            int by = plain_monthday_year(other);
            int am = plain_monthday_m(obj);
            int bm = plain_monthday_m(other);
            int ad = plain_monthday_d(obj);
            int bd = plain_monthday_d(other);
            bool same_cal = obj.extra.temporal.calendar == other.extra.temporal.calendar;
            ctx.result.set_boolean(same_cal && ay == by && am == bm && ad == bd);
            return;
        }
    }
    // Non-MonthDay inputs (strings, property bags, primitives) — defer to
    // builtin_temporal_plain_monthday_from for full ToTemporalMonthDay
    // semantics: strings parse (RangeError if invalid), plain objects need a
    // usable monthCode/month/day (TypeError otherwise), primitives throw.
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    int vy; int vm; int vd;
    if (!plainmonthday_from_arg_full(ctx, arg, overflow, &vy, &vm, &vd)) return;
    int am = plain_monthday_m(obj);
    int ad = plain_monthday_d(obj);
    bool same_cal = obj.extra.temporal.calendar == ctx.heap.temporal_iso_calendar;
    ctx.result.set_boolean(same_cal && am == vm && ad == vd);
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
    if (!reject_temporal_object_bag(ctx, bag)) return;
    Vm* v = (Vm*)ctx.vm;

    int y; int m; int d;
    bool have_mc;
    int mci;
    TVal mc_v;
    bool found_any;
    if (!bag_to_monthday_fields(ctx, bag, true, true,
                                plain_monthday_year(obj), plain_monthday_m(obj), plain_monthday_d(obj),
                                &y, &m, &d, &have_mc, &mci, &mc_v, &found_any)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    if (!found_any) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "at least one property must be provided");
        return;
    }
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    int vy; int vm; int vd;
    // The given year constrains/rejects the month/day per the overflow option;
    // the stored reference year stays the original (the ISO calendar uses the
    // year only for that leap-day overflow, not as a new reference).
    if (!fields_to_valid_monthday(ctx, y, m, d, overflow, &vy, &vm, &vd)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        return;
    }
    HObject*? obj_o = alloc_plain_monthday(ctx.heap, plain_monthday_year(obj), vm, vd, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_monthday_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_monthday_proto_toPlainDate(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_MONTHDAY, "this is not a Temporal.PlainMonthDay")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "toPlainDate requires an item bag");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "toPlainDate requires an object");
        return;
    }
    HObject* bag = (HObject*)arg.get_heapptr();
    Vm* v = (Vm*)ctx.vm;

    TVal year_v = prop_or_undefined_pa(ctx, bag, "year");
    if (ctx.should_throw) return;
    if (year_v.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "missing year property");
        return;
    }
    long y;
    if (!to_integer_with_truncation(v, &year_v, &y)) {
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
        else { builtin_throw(ctx, ctx.heap.range_err_proto, "year is not an integral number"); }
        return;
    }

    temporal::CivilDate fields;
    fields.y = y;
    fields.m = plain_monthday_m(obj);
    fields.d = plain_monthday_d(obj);

    temporal::CivilDate valid;
    if (!fields_to_valid_date(ctx, fields, temporal::OverflowKind.CONSTRAIN, &valid)) return;

    HObject*? obj_o = alloc_plain_date(ctx.heap, valid, obj.extra.temporal.calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_date_proto;
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
    if (!register_string_proto_method(proto, heap, "toLocaleString", Builtin.TEMPORAL_DURATION_PROTO_TOLOCALESTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_DURATION_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_DURATION_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_DURATION_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_DURATION_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "round", Builtin.TEMPORAL_DURATION_PROTO_ROUND.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "total", Builtin.TEMPORAL_DURATION_PROTO_TOTAL.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_DURATION_FROM.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "compare", Builtin.TEMPORAL_DURATION_COMPARE.ordinal)) return false;

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
    if (!register_string_proto_method(proto, heap, "toLocaleString", Builtin.TEMPORAL_PLAIN_DATE_PROTO_TOLOCALESTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_DATE_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_DATE_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_PLAIN_DATE_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_PLAIN_DATE_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_DATE_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_DATE_PROTO_SINCE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "withCalendar", Builtin.TEMPORAL_PLAIN_DATE_PROTO_WITHCALENDAR.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toPlainDateTime", Builtin.TEMPORAL_PLAIN_DATE_PROTO_TOPLAINDATETIME.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toZonedDateTime", Builtin.TEMPORAL_PLAIN_DATE_PROTO_TOZONEDDATETIME.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toPlainYearMonth", Builtin.TEMPORAL_PLAIN_DATE_PROTO_TOPLAINYEARMONTH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toPlainMonthDay", Builtin.TEMPORAL_PLAIN_DATE_PROTO_TOPLAINMONTHDAY.ordinal)) return false;

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
    if (!register_string_proto_method(proto, heap, "toLocaleString", Builtin.TEMPORAL_PLAIN_TIME_PROTO_TOLOCALESTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_TIME_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_TIME_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_PLAIN_TIME_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_PLAIN_TIME_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_TIME_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_TIME_PROTO_SINCE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "round", Builtin.TEMPORAL_PLAIN_TIME_PROTO_ROUND.ordinal)) return false;

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
    if (!register_proto_getter_accessor(proto, heap, "era", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_ERA.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "eraYear", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_ERAYEAR.ordinal)) return false;
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
    if (!register_string_proto_method(proto, heap, "toLocaleString", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_TOLOCALESTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_SINCE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "withCalendar", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_WITHCALENDAR.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "round", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_ROUND.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "withPlainTime", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_WITHPLAINTIME.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toZonedDateTime", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_TOZONEDDATETIME.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toPlainDate", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_TOPLAINDATE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toPlainTime", Builtin.TEMPORAL_PLAIN_DATETIME_PROTO_TOPLAINTIME.ordinal)) return false;

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
    if (!register_proto_getter_accessor(proto, heap, "daysInYear", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_DAYSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInMonth", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_DAYSINMONTH.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "monthsInYear", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_MONTHSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "inLeapYear", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_INLEAPYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "era", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_ERA.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "eraYear", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_ERAYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "calendar", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_CALENDAR.ordinal)) return false;
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
    if (!register_proto_getter_accessor(proto, heap, "referenceISOYear", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_REFERENCEISOYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInWeek", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_DAYSINWEEK.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toLocaleString", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_TOLOCALESTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_SINCE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toPlainDate", Builtin.TEMPORAL_PLAIN_YEARMONTH_PROTO_TOPLAINDATE.ordinal)) return false;

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
    if (!register_proto_getter_accessor(proto, heap, "referenceISOYear", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_REFERENCEISOYEAR.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toLocaleString", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_TOLOCALESTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_SINCE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toPlainDate", Builtin.TEMPORAL_PLAIN_MONTHDAY_PROTO_TOPLAINDATE.ordinal)) return false;

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

// Bridge between the JS-facing BigInt representation and the pure int128
// arithmetic in lib/temporal/instant.c3. Temporal exposes epoch nanoseconds as
// a BigInt, so the value arrives and leaves as an HBigInt; the calendrical
// arithmetic itself needs no heap and no engine, which is why it lives in the
// library rather than here.
//
// int128 covers the spec's +/-8.64e21 ns range with room to spare, so these
// cannot overflow for in-range inputs. Out-of-range results are a spec error
// and are rejected by the caller's range check, not here.
fn hbigint::HBigInt*? instant_add_big(hbigint::HBigInt* a, hbigint::HBigInt* delta, Heap* hp) {
    if (a == null || delta == null) return null;
    int128 res = temporal::instant_add(a.to_int128(), delta.to_int128());
    if (!temporal::instant_in_range(res)) return null;
    return hbigint::hbigint_alloc(hp, res);
}

fn hbigint::HBigInt*? instant_sub_big(hbigint::HBigInt* a, hbigint::HBigInt* delta, Heap* hp) {
    if (a == null || delta == null) return null;
    int128 res = temporal::instant_sub(a.to_int128(), delta.to_int128());
    if (!temporal::instant_in_range(res)) return null;
    return hbigint::hbigint_alloc(hp, res);
}

// Ordering on the BigInt representation. Null sorts before any value, matching
// the previous behaviour of the library function this replaced.
fn int instant_cmp_big(hbigint::HBigInt* a, hbigint::HBigInt* b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    return temporal::instant_cmp(a.to_int128(), b.to_int128());
}

fn HObject*? alloc_instant(Heap* hp, hbigint::HBigInt* ns) {
    if (ns == null) return null;
    if (!temporal::instant_in_range(ns.to_int128())) return null;
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_INSTANT);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    ((types::HeapHeader*)ns).incref();
    obj.extra.temporal.big_ns = ns;
    obj.extra.temporal.calendar = null;
    obj.extra.temporal.timezone = null;
    return obj;
}

// Date.prototype.toTemporalInstant() — the Temporal proposal's bridge from the
// legacy Date object. Lives here rather than in date.c3 because it needs the
// Instant allocator and the BigInt helpers.
//
// 1. Let dateObject be the this value.
// 2. Perform ? RequireInternalSlot(dateObject, [[DateValue]]).
// 3. Let t be dateObject.[[DateValue]]; if t is NaN, throw a RangeError.
// 4. Let ns be ℤ(ℝ(t) × 10^6).
// 5. Return ! CreateTemporalInstant(ns).
fn void builtin_date_proto_toTemporalInstant(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    // Handles the [[DateValue]] brand check, throwing TypeError for a
    // non-Date this value (including Date.prototype itself).
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid Date");
        return;
    }
    // A valid time value is an integral number of milliseconds within
    // ±8.64e15, so the nanosecond count fits int128 exactly. Scaling in
    // int128 rather than double keeps the full range representable —
    // ±8.64e21 ns is far beyond 2^53.
    int128 ns_128 = (int128)(long)tv * (int128)1000000L;
    hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, ns_128);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
    hbigint::HBigInt* ns = big_o;
    HObject*? obj_o = alloc_instant(ctx.heap, ns);
    ctx.heap.decref((types::HeapHeader*)ns);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
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

// Temporal.Instant.from(item) — accepts an ISO string or another Instant.
// Per the argument-wrong-type tests, BigInt and other primitives throw
// TypeError: only a String primitive (after ToPrimitive on an object
// argument, hint string) or a brand-checked Temporal.Instant object
// produce an Instant. Numbers, booleans, BigInts, null and undefined
// reject — they are not coerced to a numeric epoch.
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
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            // Fast path for ZonedDateTime → Instant: copy the [[Nanoseconds]]
            // directly. Avoids coercing via toString (which would defeat the
            // identity check in checkToTemporalInstantFastPath).
            hbigint::HBigInt* src = o.extra.temporal.big_ns;
            hbigint::HBigInt*? b_o = hbigint::hbigint_copy(ctx.heap, src);
            if (catch err = b_o) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Instant.from: ZDT copy failed");
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
        // Non-Instant object: ToPrimitive(string) — same shape as
        // ToTemporalInstant for the object branch. The primitive must
        // be a string for the parse path; everything else throws
        // TypeError (e.g. valueOf returning a number).
        Vm* v = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(v, arg, 1);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
        if (!prim.is_string() || prim.get_heapptr() == null
            || ((HString*)prim.get_heapptr()).is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant.from: argument must be a string or Temporal.Instant");
            return;
        }
        arg = &prim;
    } else if (!arg.is_string()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant.from: argument must be a string or Temporal.Instant");
        return;
    }
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
    // Per spec, ToTemporalInstant is applied to each arg: an object Instant
    // passes through; a non-Instant object ToPrimitive's to a string we
    // parse; a primitive that's not string-or-symbol throws TypeError.
    // to_temporal_instant raises the right error for every shape.
    hbigint::HBigInt* a;
    if (!to_temporal_instant(ctx, a_arg, &a)) return;
    defer ctx.heap.decref((types::HeapHeader*)a);
    hbigint::HBigInt* b;
    if (!to_temporal_instant(ctx, b_arg, &b)) return;
    defer ctx.heap.decref((types::HeapHeader*)b);
    ctx.result.set_fastint(instant_cmp_big(a, b));
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
// Render the fractional-seconds suffix (`.XYZ`) into `buf` and return the
// number of bytes written (0 when no fractional part should be printed).
// `digits` (-1 = auto, 0..9 = fixed) selects the precision; `mode` is the
// rounding rule (default trunc). `*ns_rem` is read AND may be updated: when
// rounding pushes ns_rem to 1_000_000_000 (a full second), the caller must
// increment whole_secs — see the wrapper in this file that handles the
// carry.
fn int format_fractional_seconds(char* buf, long ns_rem, int digits, TemporalRoundMode mode) {
    if (ns_rem < 0) ns_rem = -ns_rem;
    int d = digits;
    // Explicit fixed digits request (`fractionalSecondDigits` was given):
    // even when ns_rem is 0 the spec requires padding the requested number
    // of zeros, so a no-op short-circuit doesn't apply.
    if (d < 0) {
        // auto: write fraction only when non-zero; trailing zeros dropped.
        if (ns_rem == 0) return 0;
        d = 9;
        long x = ns_rem;
        while (x > 1 && x % 10 == 0) { x /= 10; d--; }
        if (d <= 0) return 0;
    } else {
        // Fixed digits: even when ns_rem == 0 we still write ".000…00" so
        // e.g. `toString({fractionalSecondDigits: 2})` on a whole-second
        // instant yields ".00".
        if (ns_rem == 0) {
            if (d == 0) return 0;
            buf[0] = '.';
            for (int i = 0; i < d; i++) buf[1 + i] = '0';
            return 1 + d;
        }
    }
    if (d > 9) d = 9;
    // Round to `d` digits using `mode`. Compute a divisor = 10^(9-d), then
    // round ns_rem/divisor to the nearest integer, then multiply back.
    long divisor = 1;
    for (int i = 0; i < 9 - d; i++) divisor *= 10;
    long v;
    {
        double x = (double)ns_rem / (double)divisor;
        v = (long)round_num_to_incr(x, 1.0, mode);
    }
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

// Resolve the fractional-second precision and rounding mode for a Temporal
// toString(options) bag. `digits` (-1 = auto, 0..9 = fixed) is set from
// `fractionalSecondDigits` or, if `smallestUnit` is given, its implied width
// (hour/minute/second -> 0, millisecond -> 3, microsecond -> 6, nanosecond ->
// 9). `rounding_mode` defaults to TRUNC; "ceil", "floor", "expand", "trunc",
// "halfCeil", "halfFloor", "halfExpand", "halfTrunc", "halfEven" are valid.
// Returns false on a malformed option (after throwing).
fn bool to_string_precision(BuiltinContext* ctx, int options_index, int* digits, TemporalRoundMode* rm, bool read_time_zone, TVal* out_time_zone) {
    *digits = -1;  // auto when no options
    *rm = TemporalRoundMode.TRUNC;
    if (ctx.argc <= options_index) return true;
    TVal ov = ctx.regs[ctx.base_reg + options_index];
    if (ov.is_undefined()) return true;
    if (!ov.is_object() || ov.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    HObject* opts = (HObject*)ov.get_heapptr();

    // Spec reads options in alphabetical order: fractionalSecondDigits,
    // roundingMode, smallestUnit (GetTemporalFractionalSecondDigitsOption,
    // GetRoundingModeOption, GetTemporalUnitValuedOption). Property bag reads
    // must go through the accessor/Proxy-aware path so getters/Proxy traps
    // observe the reads in this order (test262 propertyBagObserver).
    TVal f = prop_or_undefined_pa(ctx, opts, "fractionalSecondDigits");
    if (ctx.should_throw) return false;
    if (!f.is_undefined()) {
        // GetStringOrNumberOption branches on the ORIGINAL value's type: a
        // Number is used numerically (floored, then range-checked), while
        // anything else is stringified and must match a valid string option
        // — here only "auto". A non-Number is never numerically parsed, so
        // e.g. 2n and {} are RangeErrors even though they stringify to "2"
        // and "[object Object]". An object whose toString returns "auto" is
        // still accepted (test262's propertyBagObserver proxies the value
        // and expects toString, not valueOf, to be invoked).
        if (f.is_numeric()) {
            double dv = f.get_number_or_fastint();
            double dc = math::floor(dv);
            if (math::is_nan(dv) || dc < 0 || dc > 9) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0 to 9");
                return false;
            }
            *digits = (int)dc;
        } else {
            HString* f_s = builtin_to_string_vm(ctx, &f);
            if (ctx.should_throw) return false;
            if (f_s == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "fractionalSecondDigits must be a number or \"auto\"");
                return false;
            }
            char[] v = f_s.get_cstr()[:f_s.blen];
            if (v == "auto") { *digits = -1; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0 to 9");
                return false;
            }
        }
    }

    TVal rmv = prop_or_undefined_pa(ctx, opts, "roundingMode");
    if (ctx.should_throw) return false;
    if (!rmv.is_undefined()) {
        HString* rm_s = builtin_to_string_vm(ctx, &rmv);
        if (ctx.should_throw) return false;
        if (rm_s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "roundingMode must be a string"); return false; }
        char[] v = rm_s.get_cstr()[:rm_s.blen];
        if (v == "ceil") { *rm = TemporalRoundMode.CEIL; }
        else if (v == "floor") { *rm = TemporalRoundMode.FLOOR; }
        else if (v == "expand") { *rm = TemporalRoundMode.EXPAND; }
        else if (v == "trunc") { *rm = TemporalRoundMode.TRUNC; }
        else if (v == "halfCeil") { *rm = TemporalRoundMode.HALF_CEIL; }
        else if (v == "halfFloor") { *rm = TemporalRoundMode.HALF_FLOOR; }
        else if (v == "halfExpand") { *rm = TemporalRoundMode.HALF_EXPAND; }
        else if (v == "halfTrunc") { *rm = TemporalRoundMode.HALF_TRUNC; }
        else if (v == "halfEven") { *rm = TemporalRoundMode.HALF_EVEN; }
        else { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode"); return false; }
    }

    TVal su = prop_or_undefined_pa(ctx, opts, "smallestUnit");
    if (ctx.should_throw) return false;
    bool su_valid = true;
    if (!su.is_undefined()) {
        HString* su_s = builtin_to_string_vm(ctx, &su);
        if (ctx.should_throw) return false;
        if (su_s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "smallestUnit option must be a string"); return false; }
        char[] v = su_s.get_cstr()[:su_s.blen];
        // Sentinel -10: round to minute, no fractional part. Both singular
        // and plural spellings are accepted for every unit.
        if (v == "minute" || v == "minutes") { *digits = -10; }
        else if (v == "second" || v == "seconds") { *digits = 0; }
        else if (v == "millisecond" || v == "milliseconds") { *digits = 3; }
        else if (v == "microsecond" || v == "microseconds") { *digits = 6; }
        else if (v == "nanosecond" || v == "nanoseconds")  { *digits = 9; }
        else { su_valid = false; }
    }
    // Instant/ZDT observe `timeZone` in their toString tests; PlainTime does
    // not. Read it after the alphabetical option batch so the order-of-
    // operations expected record observes the `get options.timeZone` entry
    // even when smallestUnit later proves invalid (test262's
    // options-read-before-algorithmic-validation.js expects this sequence).
    if (read_time_zone) {
        TVal _tz = prop_or_undefined_pa(ctx, opts, "timeZone");
        if (ctx.should_throw) return false;
        if (out_time_zone != null) *out_time_zone = _tz;
    }
    if (!su_valid) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
        return false;
    }
    return true;
}

fn void builtin_temporal_instant_proto_toString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    int digits;
    TemporalRoundMode rm;
    TVal tzv;
    tzv.set_undefined();
    // to_string_precision probes timeZone last (after fractionalSecondDigits,
    // roundingMode, smallestUnit), matching the spec's alphabetical option
    // read order; undefined means UTC ("Z" suffix).
    if (!to_string_precision(ctx, 0, &digits, &rm, true, &tzv)) return;

    HObject* tz = null;
    if (!tzv.is_undefined()) {
        if (try maybe_tz = to_temporal_tz(ctx, &tzv)) {
            if (ctx.should_throw) return;
            tz = maybe_tz;
        } else {
            return;
        }
    }

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

    // Apply rounding (RoundTemporalInstant) to the full epoch-nanosecond
    // value before splitting into wall-clock fields, so the rounded value's
    // carries (into seconds/minutes/... and even the date) are correct —
    // matching the spec, which rounds epochNs first and only then computes
    // wall-clock fields from the rounded instant.
    if (digits == -10) {
        // smallestUnit: "minute" -> round to a whole minute boundary.
        long total_ns = whole_secs * 1000000000 + ns_rem;
        long rounded_total_ns = round_long_ns(total_ns, 60 * 1000000000L, rm);
        whole_secs = rounded_total_ns / 1000000000;
        ns_rem = 0;
    } else if (digits >= 0 && ns_rem != 0) {
        long divisor = 1;
        for (int i = 0; i < 9 - digits; i++) divisor *= 10;
        long v = (long)round_num_to_incr((double)ns_rem / (double)divisor, 1.0, rm);
        long new_ns_rem = v * divisor;
        if (new_ns_rem >= 1000000000) {
            whole_secs += 1;
            new_ns_rem -= 1000000000;
        }
        ns_rem = new_ns_rem;
    }

    // Shift wall-clock fields into the requested time zone (or UTC/"Z" if
    // none given).
    String zone = tz == null ? "" : timezone_name(tz);
    int off = 0;
    if (tz != null) off = temporal::tzdb_offset_for_zone_at(zone, whole_secs);
    long local_secs = whole_secs + off;

    temporal::BrokenDownTime bd = temporal::civil_from_seconds(local_secs);

    // Year formatting per spec §`GetISOPartsFromEpoch`: 0 ≤ year ≤ 9999 renders
    // as a 4-digit unsigned year; year < 0 or year > 9999 renders as a 6-digit
    // signed year with `-` or `+` prefix.
    char[64] buf;
    int n;
    long y = bd.y;
    if (digits == -10) {
        if (y >= 0 && y <= 9999) {
            n = libc::snprintf(&buf, 40, "%04ld-%02ld-%02ldT%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        } else if (y < 0) {
            n = libc::snprintf(&buf, 40, "-%06ld-%02ld-%02ldT%02ld:%02ld",
                -y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        } else {
            n = libc::snprintf(&buf, 40, "+%06ld-%02ld-%02ldT%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        }
    } else {
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
        n += format_fractional_seconds(&buf[n], ns_rem, digits, rm);
    }
    if (tz == null) {
        buf[n] = 'Z';
        n++;
    } else {
        format_offset_seconds(&buf[n], off);
        n += 6;
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:n]));
}

fn void builtin_temporal_instant_proto_toJSON(BuiltinContext* ctx) {
    // toJSON takes no options and always formats at "auto" precision, so the
    // caller's arguments must not reach the toString delegate.
    ctx.argc = 0;
    builtin_temporal_instant_proto_toString(ctx);
}

fn void builtin_temporal_instant_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    ctx.argc = 0;
    builtin_temporal_instant_proto_toString(ctx);
}

fn void builtin_temporal_instant_proto_toZonedDateTimeISO(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();

    // 1. Require timezone argument.
    if (ctx.argc < 1 || ctx.regs[ctx.base_reg].is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "toZonedDateTimeISO requires a time zone");
        return;
    }
    TVal* tz_arg = arg_at(ctx, 0);

    // 2. Resolve timezone.
    HObject* tz = null;
    if (try maybe_tz = to_temporal_tz(ctx, tz_arg)) {
        if (ctx.should_throw) return;
        tz = maybe_tz;
    } else { return; }

    // 3. Get the instant's epoch nanoseconds and create ZonedDateTime with ISO calendar.
    hbigint::HBigInt* ns;
    if (try ns_o = instant_value(obj)) {
        ns = ns_o;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "invalid Instant");
        return;
    }
    ((types::HeapHeader*)ns).incref();
    HString* cal = builtin_intern_string(ctx.heap, "iso8601");
    zdt_from_parts(ctx, ns, tz, cal);
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
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_INSTANT) {
        HObject* a = (HObject*)ctx.this_val.get_heapptr();
        HObject* b = (HObject*)arg.get_heapptr();
        ctx.result.set_boolean(hbigint::hbigint_cmp(a.extra.temporal.big_ns, b.extra.temporal.big_ns) == 0);
        return;
    }
    // Strings convert via ToTemporalInstant (rejects invalid strings).
    hbigint::HBigInt* other_ns;
    if (!to_temporal_instant(ctx, arg, &other_ns)) return;
    defer ctx.heap.decref((types::HeapHeader*)other_ns);
    HObject* a = (HObject*)ctx.this_val.get_heapptr();
    ctx.result.set_boolean(hbigint::hbigint_cmp(a.extra.temporal.big_ns, other_ns) == 0);
}

// add / subtract take a Temporal.Duration.
fn void builtin_temporal_instant_proto_add(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "add requires a Duration argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    // Per spec, AddDurationToOrSubtractDurationFromInstant's argument is a
    // Temporal.DurationLike: a Temporal.Duration instance, a duration
    // string, or a property bag with hour/minute/second/ms/us/ns fields
    // (no calendar units — Instant rejects years/months/weeks/days).
    temporal::DurationParts dp;
    if (!duration_record_from_arg(ctx, arg, &dp)) return;
    if (dp.years != 0 || dp.months != 0 || dp.weeks != 0 || dp.days != 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Instant does not accept calendar units");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
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
    hbigint::HBigInt*? result = instant_add_big(base, delta, ctx.heap);
    ctx.heap.decref((types::HeapHeader*)delta);
    if (catch err = result) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    if (result == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, result);
    if (catch err2 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    if (obj_o == null) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
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
    temporal::DurationParts dp;
    if (!duration_record_from_arg(ctx, arg, &dp)) return;
    if (dp.years != 0 || dp.months != 0 || dp.weeks != 0 || dp.days != 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Instant does not accept calendar units");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
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
    hbigint::HBigInt*? result = instant_sub_big(base, delta, ctx.heap);
    ctx.heap.decref((types::HeapHeader*)delta);
    if (catch err = result) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    if (result == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, result);
    if (catch err2 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    if (obj_o == null) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)result);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Settings shared by every until/since method, resolved from the options bag.
struct DiffSettings {
    TemporalUnit largest;
    TemporalUnit smallest;
    TemporalRoundMode mode;
    double increment;
    bool largest_provided;
}

// Read largestUnit / smallestUnit / roundingIncrement / roundingMode for an
// until/since call.
//
// Property reads happen in the spec's order (largestUnit, roundingIncrement,
// roundingMode, smallestUnit) because each one can run user code through a
// getter or valueOf, and test262 observes the sequence.
//
// `fallback_smallest` is the finest unit the receiver can express and
// `default_largest` the coarsest unit it reports by default; `min_unit` and
// `max_unit` bound what the receiver accepts at all, so a PlainTime rejects
// "day" and a PlainYearMonth rejects "hour". For `since` the caller negates
// the resulting Duration, but the rounding mode is negated here instead, since
// rounding must happen in the direction of the original difference.
//
// Returns false after throwing.
fn bool read_diff_settings(BuiltinContext* ctx, int options_index,
                           TemporalUnit min_unit, TemporalUnit max_unit,
                           TemporalUnit default_largest, TemporalUnit fallback_smallest,
                           bool negate_mode, DiffSettings* out) {
    out.largest = default_largest;
    out.smallest = fallback_smallest;
    out.mode = TemporalRoundMode.TRUNC;
    out.increment = 1;

    HObject* opts = null;
    if (ctx.argc > options_index) {
        TVal ov = ctx.regs[ctx.base_reg + options_index];
        if (!ov.is_undefined()) {
            if (!ov.is_object() || ov.get_heapptr() == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
                return false;
            }
            opts = (HObject*)ov.get_heapptr();
        }
    }

    bool largest_given = false;
    bool smallest_given = false;

    if (opts != null) {
        TVal lu_v = prop_or_undefined_pa(ctx, opts, "largestUnit");
        if (ctx.should_throw) return false;
        if (!lu_v.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &lu_v);
            if (ctx.should_throw) return false;
            char[] str = s.get_cstr()[:s.blen];
            if (str != "auto") {
                if (!parse_unit_str(str, &out.largest)) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "largestUnit is not a valid value");
                    return false;
                }
                largest_given = true;
                out.largest_provided = true;
            }
        }

        TVal ri_v = prop_or_undefined_pa(ctx, opts, "roundingIncrement");
        if (ctx.should_throw) return false;
        if (!ri_v.is_undefined()) {
            Vm* v = (Vm*)ctx.vm;
            long ri;
            if (!to_integer_with_truncation(v, &ri_v, &ri)) {
                if (v.throw_pending) {
                    ctx.should_throw = true;
                    ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                    v.throw_pending = false;
                    return false;
                }
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be finite");
                return false;
            }
            out.increment = (double)ri;
        }

        TVal rm_v = prop_or_undefined_pa(ctx, opts, "roundingMode");
        if (ctx.should_throw) return false;
        if (!rm_v.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &rm_v);
            if (ctx.should_throw) return false;
            if (!parse_rm_str(s.get_cstr()[:s.blen], &out.mode)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return false;
            }
        }

        TVal su_v = prop_or_undefined_pa(ctx, opts, "smallestUnit");
        if (ctx.should_throw) return false;
        if (!su_v.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &su_v);
            if (ctx.should_throw) return false;
            char[] str = s.get_cstr()[:s.blen];
            if (str != "auto") {
                if (!parse_unit_str(str, &out.smallest)) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "smallestUnit is not a valid value");
                    return false;
                }
                smallest_given = true;
            }
        }
    }

    // Validation runs only after all four options are read. Each read can
    // invoke user code through a getter or valueOf, and the spec observes every
    // one of them even when an earlier value is unusable.
    if (out.increment < 1 || out.increment > 1e9) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
        return false;
    }
    if (largest_given && (out.largest < min_unit || out.largest > max_unit)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "largestUnit is not supported by this type");
        return false;
    }
    if (smallest_given && (out.smallest < min_unit || out.smallest > max_unit)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "smallestUnit is not supported by this type");
        return false;
    }

    // Per the spec, defaultLargestUnit = LargerOfTwoTemporalUnits(defaultLargest, smallestUnit).
    // When the user did not explicitly set largestUnit, recompute it.
    if (!largest_given) {
        out.largest = larger_unit(default_largest, out.smallest);
    }
    if (out.largest > out.smallest) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "smallestUnit must be coarser than largestUnit");
        return false;
    }

    long max_incr = max_round_incr(out.smallest);
    if (max_incr > 0) {
        // The increment must divide the unit evenly, and cannot span a whole
        // unit — 60 minutes is not a legal minute increment.
        if (!validate_rounding_increment(ctx, out.smallest, out.increment)) return false;
    }
    // Calendar units and "day" have no fixed length for an increment to divide
    // into, so any positive integer is accepted there and the [1, 1e9] check
    // above is the only bound.

    if (negate_mode) out.mode = negate_round_mode(out.mode);
    return true;
}

// Mirror a rounding mode about zero, so rounding a negated difference lands on
// the same instant as rounding the difference itself.
fn TemporalRoundMode negate_round_mode(TemporalRoundMode m) {
    switch (m) {
        case TemporalRoundMode.CEIL:       return TemporalRoundMode.FLOOR;
        case TemporalRoundMode.FLOOR:      return TemporalRoundMode.CEIL;
        case TemporalRoundMode.HALF_CEIL:  return TemporalRoundMode.HALF_FLOOR;
        case TemporalRoundMode.HALF_FLOOR: return TemporalRoundMode.HALF_CEIL;
        default: return m;
    }
}

// Translate a sign-aware rounding mode into the as-if-positive mode that
// round_bigint_ns must use to produce the same result for a NEGATIVE value.
//
// round_bigint_ns works on the floor-normalized scale, where "down" is toward
// negative infinity. For a negative value, rounding toward zero is therefore
// "up" — so trunc behaves as ceil and expand as floor. The ceil/floor pair
// swaps for the same reason, and the half-* modes follow their tie direction.
fn TemporalRoundMode mode_for_negative(TemporalRoundMode m) {
    switch (m) {
        case TemporalRoundMode.TRUNC:       return TemporalRoundMode.CEIL;
        case TemporalRoundMode.EXPAND:      return TemporalRoundMode.FLOOR;
        case TemporalRoundMode.HALF_TRUNC:  return TemporalRoundMode.HALF_CEIL;
        case TemporalRoundMode.HALF_EXPAND: return TemporalRoundMode.HALF_FLOOR;
        default: return m;
    }
}

// Build a Duration whose time units are the difference between two Instants'
// epoch-ns BigInts. `largest_unit_ns` is the unit ns (3600*1e9 for hours,
// 60*1e9 for minutes, 1e9 for seconds, 1e6 for ms, etc.). The duration is
// balanced so the chosen unit holds the whole number and the sub-units carry
// the remainder. Negative differences produce all-negative components.
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

// Split a nanosecond count into a Duration, filling `largest` and every finer
// time unit. The value has already been rounded to smallestUnit by the caller,
// so the tail fields simply come out zero.
//
// The count is taken as int128 rather than long: an Instant pair can be up to
// ~2*8.64e21 ns apart, which overflows a 64-bit nanosecond field even though
// each individual unit field fits comfortably.
fn bool instant_ns_split_duration(BuiltinContext* ctx, hbigint::HBigInt* ns, TemporalUnit largest, HObject** out) {
    int128 v = ns.to_int128();
    temporal::DurationParts dp = {};

    // Walk the ladder from `largest` down; each unit takes the whole quotient
    // at its scale and hands the remainder to the next one.
    if (largest <= TemporalUnit.HOUR) {
        dp.hours = (long)(v / 3600000000000L);
        v %= 3600000000000L;
    }
    if (largest <= TemporalUnit.MINUTE) {
        dp.minutes = (long)(v / 60000000000L);
        v %= 60000000000L;
    }
    if (largest <= TemporalUnit.SECOND) {
        dp.seconds = (long)(v / 1000000000L);
        v %= 1000000000L;
    }
    if (largest <= TemporalUnit.MILLISECOND) {
        dp.ms = (long)(v / 1000000L);
        v %= 1000000L;
    }
    if (largest <= TemporalUnit.MICROSECOND) {
        dp.us = (long)(v / 1000L);
        v %= 1000L;
    }
    dp.ns = (long)v;

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

// Parse an ISO instant string into an HBigInt of epoch nanoseconds.
// Throws RangeError on parse failure / invalid components. On success the
// returned BigInt is incref'd; ownership passes to the caller.
fn bool instant_from_iso_string(BuiltinContext* ctx, String str, hbigint::HBigInt** out) {
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
    // The sub-minute offset component (e.g. `+00:00:00.5`) carries the
    // sign of `offset_seconds` — a positive seconds value means the
    // parsed time is east of UTC, so the offset also subtracts.
    long sign = p.offset_seconds < 0 ? -1L : 1L;
    ns128 -= (int128)(sign * p.offset_nanos);
    // ToTemporalInstant rejects an instant outside NS_MIN..NS_MAX
    // (±100,000,000 days * 86400e9), e.g. the maximum wall date with a
    // negative offset pushes the epoch over the top.
    int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
    if (ns128 > ns_limit || ns128 < -ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside the representable epoch-nanoseconds range");
        return false;
    }
    hbigint::HBigInt*? b_o = hbigint::hbigint_alloc(ctx.heap, ns128);
    if (catch err = b_o) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Instant alloc failed");
        return false;
    }
    *out = b_o;
    return true;
}

// ToTemporalInstant(arg): coerce arg to a Temporal.Instant epoch-ns BigInt.
// On success the returned BigInt is incref'd (refcount-1) and ownership passes
// to the caller. On failure the function returns false after throwing.
//   - Object with class TEMPORAL_INSTANT: copy its big_ns.
//   - Object (or function) without that class: ToPrimitive(arg, string).
//     If the primitive is a string, parse it (RangeError on failure).
//     ToPrimitive can itself throw (e.g. @@toPrimitive returning an
//     object, or a brand-check failure on Temporal.Instant.prototype);
//     those exceptions propagate.
//   - Symbol: throw TypeError (ToPrimitive on a Symbol throws TypeError).
//   - String: parse as ISO instant string. RangeError on invalid input.
//   - Other primitives (number, boolean, null, undefined, bigint):
//     throw TypeError — they have no string representation the parser
//     would accept.
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
        // ZonedDateTime: copy [[Nanoseconds]] directly so the fast-path
        // identity tests don't fire toString via ToPrimitive coercion.
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            hbigint::HBigInt*? b_o = hbigint::hbigint_copy(ctx.heap, o.extra.temporal.big_ns);
            if (catch err = b_o) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Instant.from ZDT copy failed");
                return false;
            }
            *out = b_o;
            return true;
        }
        // Non-Instant object (including functions and Temporal.Instant.prototype):
        // ToPrimitive(arg, string) — Object's toString() (or @@toPrimitive) yields a
        // string we parse, or the conversion throws. Symbols fall through to here
        // only when wrapped — bare Symbols are caught by the is_symbol path below.
        Vm* v = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(v, arg, 1);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return false;
        }
        if (prim.is_string() && prim.get_heapptr() != null) {
            HString* s = (HString*)prim.get_heapptr();
            String str = (String)s.get_cstr()[:s.blen];
            return instant_from_iso_string(ctx, str, out);
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
        // Symbols live as HString objects with is_symbol=true; the parser
        // would just RangeError on the embedded 0xFF prefix, but the spec
        // requires a TypeError before any string work happens.
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to an Instant");
            return false;
        }
        String str = (String)s.get_cstr()[:s.blen];
        return instant_from_iso_string(ctx, str, out);
    }
    // Symbol and other primitives (number, boolean, null, undefined, bigint):
    // ToTemporalInstant does not coerce these to strings, so a TypeError is
    // raised for things like `Instant.prototype.equals(1)` and
    // `.equals(Symbol())` — matching the test262 "argument-wrong-type" suites.
    builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to an Instant");
    return false;
}

// this.since(other[, options]) = this - other, as a Duration in seconds (or
// other time units when largestUnit is set).
fn void builtin_temporal_instant_proto_since(BuiltinContext* ctx) {
    instant_until_since(ctx, false);
}

// this.until(other[, options]) = other - this, as a Duration in seconds.
fn void builtin_temporal_instant_proto_until(BuiltinContext* ctx) {
    instant_until_since(ctx, true);
}

// Shared body for Instant.prototype.until/since.
//
// Instant has no date, so every unit is a fixed number of nanoseconds and the
// whole difference is one BigInt subtraction: round the elapsed nanoseconds to
// smallestUnit, then split the result across the ladder down from largestUnit.
fn void instant_until_since(BuiltinContext* ctx, bool until) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "until/since requires an Instant argument");
        return;
    }
    hbigint::HBigInt* other_ns;
    if (!to_temporal_instant(ctx, arg_at(ctx, 0), &other_ns)) return;
    defer ctx.heap.decref((types::HeapHeader*)other_ns);

    // Instant spans no calendar, so units coarser than "hour" are rejected.
    //
    // negate_mode is false even for `since`. The operands below are swapped, so
    // the difference already carries the final sign and the rounding mode is
    // adjusted against that sign directly.
    DiffSettings ds;
    if (!read_diff_settings(ctx, 1, TemporalUnit.HOUR, TemporalUnit.NANOSECOND,
                            TemporalUnit.SECOND, TemporalUnit.NANOSECOND, false, &ds)) return;

    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* a;
    hbigint::HBigInt* b;
    if (until) { a = other_ns; b = self.extra.temporal.big_ns; }
    else       { a = self.extra.temporal.big_ns; b = other_ns; }

    hbigint::HBigInt*? diff_o = hbigint::hbigint_addsub(ctx.heap, a, b, true);
    if (catch err = diff_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "difference overflow"); return; }
    hbigint::HBigInt* diff = diff_o;

    // Rounding to nanoseconds by 1 is the identity, so skip the BigInt work.
    long incr_ns = unit_ns_divisor(ds.smallest) * (long)ds.increment;
    if (incr_ns > 1) {
        // round_bigint_ns rounds as if the value were positive, while
        // until/since round by magnitude: on a negative difference "trunc"
        // moves toward zero, which is up, and "expand" away from it. Mapping
        // the mode to its as-if-positive form avoids negating the BigInt twice.
        TemporalRoundMode mode = ds.mode;
        if (diff.is_negative()) mode = mode_for_negative(mode);
        hbigint::HBigInt*? rounded_o = round_bigint_ns(ctx, diff, incr_ns, mode);
        ctx.heap.decref((types::HeapHeader*)diff);
        if (catch err = rounded_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "rounding failed"); return; }
        diff = rounded_o;
    }

    HObject* dur;
    bool ok = instant_ns_split_duration(ctx, diff, ds.largest, &dur);
    ctx.heap.decref((types::HeapHeader*)diff);
    if (!ok) return;
    dur.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur);
}

// Helper: round a BigInt nanosecond value to the nearest multiple of
// `incr_ns` using the spec's `RoundNumberToIncrementAsIfPositive`. Returns a
// newly-allocated BigInt on success; on failure the `catch` path yields
// BIGINT_DIV_ZERO or an allocation fault.
fn hbigint::HBigInt*? round_bigint_ns(BuiltinContext* ctx, hbigint::HBigInt* b, long incr_ns, TemporalRoundMode rounding_mode) {
    hbigint::HBigInt*? incr_o = hbigint::hbigint_alloc(ctx.heap, (int128)incr_ns);
    if (catch err = incr_o) return err~;
    hbigint::HBigInt* incr = incr_o;
    hbigint::HBigInt* q = null;
    hbigint::HBigInt* r = null;
    if (catch err = hbigint::hbigint_divrem(ctx.heap, b, incr, &q, &r)) {
        ctx.heap.decref((types::HeapHeader*)incr);
        return err~;
    }
    if (q == null || r == null) {
        ctx.heap.decref((types::HeapHeader*)incr);
        ctx.heap.decref((types::HeapHeader*)q);
        ctx.heap.decref((types::HeapHeader*)r);
        return hbigint::BIGINT_ALLOC~;
    }
    int128 qv = q.to_int128();
    int128 rv = r.to_int128();
    int128 incr_128 = (int128)incr_ns;
    // Normalize to floor-division (spec uses RoundNumberToIncrementAsIfPositive,
    // which expects r in [0, incr_ns) with q_f = floor(b/incr_ns)).
    int128 q_f;
    int128 r_f;
    if (rv >= 0) { q_f = qv; r_f = rv; }
    else         { q_f = qv - 1; r_f = rv + incr_128; }
    int128 chosen_q;
    if (r_f == 0) {
        chosen_q = q_f;
    } else {
        switch (rounding_mode) {
            // floor / trunc → unsigned "zero" → always r1.
            case TemporalRoundMode.FLOOR:
            case TemporalRoundMode.TRUNC: chosen_q = q_f; break;
            // ceil / expand → unsigned "infinity" → always r2.
            case TemporalRoundMode.CEIL:
            case TemporalRoundMode.EXPAND: chosen_q = q_f + 1; break;
            // half-* modes pick the closer candidate, breaking ties per unsigned mode.
            case TemporalRoundMode.HALF_FLOOR:
            case TemporalRoundMode.HALF_TRUNC:
            case TemporalRoundMode.HALF_CEIL:
            case TemporalRoundMode.HALF_EXPAND:
            case TemporalRoundMode.HALF_EVEN: {
                int128 two_r = r_f * 2;
                if (two_r < incr_128) {
                    chosen_q = q_f;
                } else if (two_r > incr_128) {
                    chosen_q = q_f + 1;
                } else {
                    switch (rounding_mode) {
                        case TemporalRoundMode.HALF_FLOOR:
                        case TemporalRoundMode.HALF_TRUNC: chosen_q = q_f; break;
                        case TemporalRoundMode.HALF_CEIL:
                        case TemporalRoundMode.HALF_EXPAND: chosen_q = q_f + 1; break;
                        case TemporalRoundMode.HALF_EVEN:
                            chosen_q = ((q_f & 1) == 0) ? q_f : q_f + 1; break;
                        default: chosen_q = q_f; break;  // unreachable
                    }
                }
                break;
            }
        }
    }
    ctx.heap.decref((types::HeapHeader*)q);
    ctx.heap.decref((types::HeapHeader*)r);
    hbigint::HBigInt*? chosen_o = hbigint::hbigint_alloc(ctx.heap, chosen_q);
    if (catch err = chosen_o) {
        ctx.heap.decref((types::HeapHeader*)incr);
        return err~;
    }
    hbigint::HBigInt* chosen = chosen_o;
    hbigint::HBigInt*? result = hbigint::hbigint_mul(ctx.heap, chosen, incr);
    ctx.heap.decref((types::HeapHeader*)chosen);
    ctx.heap.decref((types::HeapHeader*)incr);
    return result;
}

// Temporal.Instant.prototype.round([options]) — see spec
// §sec-temporal.instant.prototype.round. Rounds `this` to the chosen
// `smallestUnit` (hour, minute, second, millisecond, microsecond, or
// nanosecond). Accepts `roundingIncrement` and `roundingMode`; the IANA
// time-zone is irrelevant because Instants are point-in-time.
fn void builtin_temporal_instant_proto_round(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) { builtin_throw(ctx, ctx.heap.type_err_proto, "round requires an options argument"); return; }
    TVal* arg = arg_at(ctx, 0);
    HObject* opts;
    if (arg.is_string()) {
        // String shorthand: round(string) is equivalent to round({ smallestUnit: string }).
        HString* hstr = (HString*)arg.get_heapptr();
        if (hstr == null) { builtin_throw(ctx, ctx.heap.range_err_proto, "round string shorthand is invalid"); return; }
        HObject*? bag_o = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = bag_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* bag = bag_o;
        HString* su_key = builtin_intern_string(ctx.heap, "smallestUnit");
        HString* su_copy = builtin_intern_string(ctx.heap, (String)hstr.get_cstr()[:hstr.blen]);
        TVal su_tv;
        su_tv.set_string(su_copy);
        PropFlags pf;
        pf.writable = true;
        pf.enumerable = true;
        pf.configurable = true;
        pf.is_accessor = false;
        bag.put_prop(su_key, su_tv, pf, ctx.heap);
        opts = bag;
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        opts = (HObject*)arg.get_heapptr();
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "round options must be an object or a string");
        return;
    }
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();

    // Spec §3.1: read all options before any algorithmic validation so that
    // observable property access (Proxy handlers, TemporalHelpers probes)
    // occurs in a stable order independent of which validation trips first.
    // Per spec §Temporal.Instant.prototype.round steps 7-9: read and convert
    // each option in order — roundingIncrement first (with ToNumber → valueOf),
    // then roundingMode (with ToString → toString), then smallestUnit (with
    // ToString → toString). Validation runs after all three have been observed.
    TVal ri_v = prop_or_undefined_pa(ctx, opts, "roundingIncrement");
    double ri_val = 1;
    if (!ri_v.is_undefined()) {
        Vm* v = (Vm*)ctx.vm;
        ri_val = vm::vm_to_number(v, &ri_v);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    }
    TVal rm_v = prop_or_undefined_pa(ctx, opts, "roundingMode");
    HString* rm_str = null;
    if (!rm_v.is_undefined()) {
        rm_str = builtin_to_string_vm(ctx, &rm_v);
        if (ctx.should_throw) return;
    }
    TVal su_v = prop_or_undefined_pa(ctx, opts, "smallestUnit");
    if (su_v.is_undefined()) { builtin_throw(ctx, ctx.heap.range_err_proto, "round requires a smallestUnit option"); return; }
    HString* su_str = builtin_to_string_vm(ctx, &su_v);
    if (ctx.should_throw) return;

    // Algorithmic validation now that all props have been observed.
    TemporalUnit smallest_unit;
    if (!parse_unit_str(su_str.get_cstr()[:su_str.blen], &smallest_unit)
        || smallest_unit < TemporalUnit.HOUR) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit for Instant.round");
        return;
    }
    double rounding_increment = 1;
    if (!ri_v.is_undefined()) {
        if (math::is_nan(ri_val) || math::is_inf(ri_val) || ri_val < 1 || ri_val > 1e9) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a finite positive integer (≤ 1e9)");
            return;
        }
        // Per spec: non-integer increments are truncated, not rejected.
        rounding_increment = math::floor(ri_val);
        if (rounding_increment < 1) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be ≥ 1 after truncation");
            return;
        }
    }
    long divisor = unit_ns_divisor(smallest_unit);
    // Spec §ValidateTemporalRoundingIncrement: increment must satisfy
    //   (1) inc ≤ maximum (inclusive)
    //   (2) dividend mod inc == 0
    // where dividend is "number of this-unit-in-one-solar-day" for Instant.
    // That is dividend = 86400 seconds / (this unit in seconds). Computed as
    // nsPerDay / divisor = (86400 * 1e9) / divisor.
    long long_solar_ns = 86400L * 1000000000L;
    long dividend = divisor > 0 ? (long)(long_solar_ns / divisor) : 1;
    long long_incr = (long)rounding_increment;
    if (long_incr > dividend || dividend % long_incr != 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
        return;
    }

    TemporalRoundMode rounding_mode = TemporalRoundMode.HALF_EXPAND;
    if (rm_str != null) {
        if (!parse_rm_str(rm_str.get_cstr()[:rm_str.blen], &rounding_mode)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
            return;
        }
    }

    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    long incr_ns = divisor * (long)rounding_increment;
    hbigint::HBigInt*? result = round_bigint_ns(ctx, b, incr_ns, rounding_mode);
    if (catch err = result) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "round failed");
        return;
    }
    HObject*? inst_o = alloc_instant(ctx.heap, result);
    ctx.heap.decref((types::HeapHeader*)result);
    if (catch err2 = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* inst = inst_o;
    inst.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(inst);
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
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.TimeZone requires new");
        return;
    }
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
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_timezone_proto);
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
    // wall-clock mapping is stable). Collect unique matching instants.
    double[4] hits;
    int nh = 0;
    for (int k = 0; k < nc; k++) {
        double cand_ns = naive_ns - (double)cand[k] * 1e9;
        long cand_sec = (long)math::floor(cand_ns / 1e9);
        int real_off = temporal::tzdb_offset_for_zone_at(zone, cand_sec);
        if (real_off != cand[k]) continue;
        double e_ns = naive_ns - (double)real_off * 1e9;
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
// the UTC offset, or null if there is none.
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
    ctx.result.set_null();
}

// getPreviousTransition(startingInstant) — last earlier transition that
// changes the UTC offset, or null if there is none.
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
    if (last_epoch < 0) { ctx.result.set_null(); return; }
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
    if (!register_string_proto_method(proto, heap, "toLocaleString", Builtin.TEMPORAL_INSTANT_PROTO_TOLOCALESTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_INSTANT_PROTO_VALUEOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_INSTANT_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_INSTANT_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_INSTANT_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "round", Builtin.TEMPORAL_INSTANT_PROTO_ROUND.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_INSTANT_PROTO_SINCE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_INSTANT_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toZonedDateTimeISO", Builtin.TEMPORAL_INSTANT_PROTO_TOZONEDDATETIMEISO.ordinal)) return false;
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
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime requires new");
        return;
    }
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime requires epochNanoseconds and timeZone args");
        return;
    }
    TVal* narg = arg_at(ctx, 0);
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, narg, &ok);
    if (!ok) return;

    // timeZone may be a string or a Temporal.TimeZone object.
    TVal* tzarg = arg_at(ctx, 1);
    HObject* tz;
    if (tzarg.is_object() && tzarg.get_heapptr() != null
        && ((HObject*)tzarg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_TIMEZONE) {
        tz = (HObject*)tzarg.get_heapptr();
    } else if (tzarg.is_string()) {
        // Symbols are string-tagged but cannot be a timezone.
        HString* tzs_str = builtin_to_string_vm(ctx, tzarg);
        if (ctx.should_throw) return;
        String s = tzs_str != null ? (String)tzs_str.get_cstr()[:tzs_str.blen] : (String)"";
        HObject* tz_o = resolve_tz_from_string(ctx, s);
        if (tz_o == null) return;
        tz = tz_o;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime requires a string or TimeZone object");
        return;
    }

    // calendar: defaults to iso8601; a supplied calendar must be a string
    // matching "iso8601"/"gregory"/"gregorian" (case-insensitive) or a
    // Temporal.Calendar object. Anything else throws TypeError; unknown
    // identifiers throw RangeError.
    HObject* calendar_obj = ctx.heap.temporal_iso_calendar;
    if (ctx.argc >= 3) {
        TVal* cal_arg = arg_at(ctx, 2);
        if (!cal_arg.is_undefined()) {
            if (!to_temporal_calendar_identifier(ctx, cal_arg, &calendar_obj)) return;
        }
    }
    // The slot stores the calendar id string; use a small HString per call so
    // we don't share the "iso8601" literal across distinct calendar objects.
    String cal_id = "iso8601";
    if (calendar_obj != ctx.heap.temporal_iso_calendar) {
        // Only "iso8601" exists right now; reaching here means an unrecognized
        // Calendar object was passed and slipped past calendar_from_arg.
        builtin_throw(ctx, ctx.heap.range_err_proto, "unknown calendar");
        return;
    }
    HString* calendar = builtin_intern_string(ctx.heap, cal_id);
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

// Resolve a timezone string to a Temporal.TimeZone object. The string may be
// an IANA zone name, an offset like "+01:00", "Z", or a full ISO date-time
// with a bracketed zone annotation like "2021-08-19T17:30Z[UTC]" — in the
// last case, the bracketed annotation wins and any leading ISO prefix is
// validated and ignored. Empty strings, sub-minute offsets, bare date-times
// without a zone, unknown IANA names, and negative-zero years throw
// RangeError per spec.
fn HObject* resolve_tz_from_string(BuiltinContext* ctx, String s) {
    if (s.len == 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "empty time zone string");
        return null;
    }

    long off_sec = 0;
    bool off_known = false;
    String zone_name = (String)"";
    bool zone_known = false;
    bool is_z = false;
    // Reject bare sub-minute offsets like `+01:35:00.000000000` or
    // `-12:12:59.9`. The sub-minute `.` / `,` form is only valid inside
    // the date-time prefix of a ZonedDateTime ISO string (e.g. the
    // offset of `2021-08-19T17:30:45.123-12:12[+01:00]`), not as a
    // time-zone identifier on its own. The bracket path (e.g.
    // `2021-08-19T17:30-12:12[+01:46]`) is handled later.
    if (s.len > 0 && (s[0] == '+' || s[0] == '-')) {
        for (usz chk = 0; chk < s.len; chk++) {
            if (s[chk] == '.' || s[chk] == ',') {
                builtin_throw(ctx, ctx.heap.range_err_proto, "sub-minute time zone identifier is not allowed");
                return null;
            }
        }
        // Sub-minute `:SS` is also disallowed for bare-offset identifiers.
        int cs = 0;
        for (usz chk = 0; chk < s.len; chk++) {
            if (s[chk] == ':') cs++;
        }
        if (cs >= 2) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "sub-minute time zone identifier is not allowed");
            return null;
        }
    }
    if (!now_resolve_tz(ctx, s, &off_sec, &off_known, &zone_name, &zone_known, &is_z)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid time zone string");
        return null;
    }

    if (off_known) {
        if (is_z) {
            // Z designator (not +HH:MM) in a datetime string without bracket
            // annotation means the UTC time zone, not +00:00.
            HObject*? tz_o = alloc_timezone(ctx.heap, (String)"UTC");
            if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
            return tz_o;
        }
        // Canonicalize as a "+HH:MM" string for the TimeZone id.
        char[8] buf;
        long mag = off_sec < 0 ? -off_sec : off_sec;
        buf[0] = off_sec >= 0 ? '+' : '-';
        buf[1] = (char)('0' + (int)(mag / 3600 / 10));
        buf[2] = (char)('0' + (int)(mag / 3600 % 10));
        buf[3] = ':';
        buf[4] = (char)('0' + (int)((mag % 3600) / 60 / 10));
        buf[5] = (char)('0' + (int)((mag % 3600) / 60 % 10));
        buf[6] = 0;
        HObject*? tz_o = alloc_timezone(ctx.heap, (String)buf[:6]);
        if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        return tz_o;
    }
    // Zone name path: must be a known IANA name (case-insensitive). An
    // unknown identifier is a RangeError per spec.
    if (off_known) {
        // Canonicalize as a "+HH:MM" string for the TimeZone id.
        char[8] buf;
        long mag = off_sec < 0 ? -off_sec : off_sec;
        buf[0] = off_sec >= 0 ? '+' : '-';
        buf[1] = (char)('0' + (int)(mag / 3600 / 10));
        buf[2] = (char)('0' + (int)(mag / 3600 % 10));
        buf[3] = ':';
        buf[4] = (char)('0' + (int)((mag % 3600) / 60 / 10));
        buf[5] = (char)('0' + (int)((mag % 3600) / 60 % 10));
        buf[6] = 0;
        HObject*? tz_o = alloc_timezone(ctx.heap, (String)buf[:6]);
        if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
        return tz_o;
    }
    char[64] canon_buf;
    if (!temporal::tzdb_zone_exists_ci(zone_name, &canon_buf[0], 64)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Unknown time zone");
        return null;
    }
    // canon_buf is null-terminated. Convert to a C3 slice for alloc_timezone.
    usz n = 0;
    while (n < 64 && canon_buf[n] != 0) n += 1;
    char[] canon_slice = canon_buf[:n];
    HObject*? tz_o = alloc_timezone(ctx.heap, (String)canon_slice);
    if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return null; }
    return tz_o;
}

// Convert string or TimeZone to a TimeZone HObject. Per spec, anything that
// cannot be converted to a string (Symbols, plain objects without a useful
// toString) raises TypeError; unparseable offset strings raise RangeError.
fn HObject*? to_temporal_tz(BuiltinContext* ctx, TVal* arg) {
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_TIMEZONE) {
        return (HObject*)arg.get_heapptr();
    }
    if (arg.is_string()) {
        HString* hs = (HString*)arg.get_heapptr();
        // Symbols are string-tagged but cannot be converted via get_cstr().
        HString* s_str = builtin_to_string_vm(ctx, arg);
        if (ctx.should_throw) return null;
        String s = s_str != null ? (String)s_str.get_cstr()[:s_str.blen] : (String)"";
        HObject* tz = resolve_tz_from_string(ctx, s);
        if (tz == null) return null;
        return tz;
    }
    builtin_throw(ctx, ctx.heap.type_err_proto, "time zone must be a string or Temporal.TimeZone object");
    return null;
}

// Validate the options bag for `Temporal.ZonedDateTime.from`. Reads three
// options:
//   * `disambiguation`: "compatible" | "earlier" | "later" | "reject"
//   * `offset`: "prefer" | "use" | "ignore" | "reject"
//   * `overflow`: "constrain" | "reject"
// Anything else throws RangeError; non-object primitives (null/true/number/
// Symbol/string/BigInt) throw TypeError. The spec calls GetOption on each
// key, which only succeeds when the option is a string member of the
// allowed set; reading happens before any algorithmic validation.
// Validate the `offset`, `disambiguation` and `overflow` options accepted by
// ZonedDateTime.from/with. Returns the resolved offset mode (-1 on error):
// 0 = default (prefer), 1 = use, 2 = ignore, 3 = prefer, 4 = reject.
// Reads must go through the Proxy-aware path so observers see the option
// gets in alphabetical order (disambiguation, offset, overflow).
fn int validate_zdt_from_options(BuiltinContext* ctx, temporal::OverflowKind* out_overflow) {
    *out_overflow = temporal::OverflowKind.CONSTRAIN;
    if (ctx.argc < 2) return 0;
    TVal ov = ctx.regs[ctx.base_reg + 1];
    if (ov.is_undefined()) return 0;
    if (!ov.is_object() || ov.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return -1;
    }
    HObject* opts = (HObject*)ov.get_heapptr();
    TVal dv = prop_or_undefined_pa(ctx, opts, "disambiguation");
    if (ctx.should_throw) return -1;
    if (!dv.is_undefined()) {
        HString* ds = builtin_to_string_vm(ctx, &dv);
        if (ctx.should_throw) return -1;
        char[] dstr = ds.get_cstr()[:ds.blen];
        if (dstr != "compatible" && dstr != "earlier" && dstr != "later" && dstr != "reject") {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid disambiguation");
            return -1;
        }
    }
    TVal offv = prop_or_undefined_pa(ctx, opts, "offset");
    if (ctx.should_throw) return -1;
    int offset_mode = 0;
    if (!offv.is_undefined()) {
        HString* os = builtin_to_string_vm(ctx, &offv);
        if (ctx.should_throw) return -1;
        char[] ostr = os.get_cstr()[:os.blen];
        if (ostr == "use") { offset_mode = 1; }
        else if (ostr == "ignore") { offset_mode = 2; }
        else if (ostr == "prefer") { offset_mode = 3; }
        else if (ostr == "reject") { offset_mode = 4; }
        else {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset option");
            return -1;
        }
    }
    TVal ofv = prop_or_undefined_pa(ctx, opts, "overflow");
    if (ctx.should_throw) return -1;
    if (!ofv.is_undefined()) {
        HString* os2 = builtin_to_string_vm(ctx, &ofv);
        if (ctx.should_throw) return -1;
        char[] ostr2 = os2.get_cstr()[:os2.blen];
        if (ostr2 != "constrain" && ostr2 != "reject") {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid overflow option");
            return -1;
        }
        *out_overflow = ostr2 == "reject" ? temporal::OverflowKind.REJECT : temporal::OverflowKind.CONSTRAIN;
    }
    return offset_mode;
}

// Validate that an explicit UTC offset agrees with the time zone's actual
// offset at the instant it produces, per GetEpochNanosecondsFor. `mode` is
// the offset option (0=default,1=use,2=ignore,3=prefer,4=reject). On
// disagreement, reject/default throw RangeError, prefer falls back to the
// zone's own offset, and use/ignore never throw (ignore ignores the provided
// offset entirely). Writes the chosen epoch back through `epoch_ns_128`.
fn bool zdt_check_offset_agreement(BuiltinContext* ctx, String zone_name, int128 wall_ns_128,
                                   long off_sec, int mode, int128* epoch_ns_128) {
    if (mode == 1 /* use */) return true;
    if (mode == 2 /* ignore */) {
        // Ignore the supplied offset: resolve the wall time by the zone.
        long wall_secs = (long)(wall_ns_128 / 1000000000);
        long zone_off = (long)temporal::tzdb_offset_for_zone_at(zone_name, wall_secs);
        *epoch_ns_128 = wall_ns_128 - (int128)zone_off * (int128)1000000000L;
        return true;
    }
    long epoch_secs = (long)(*epoch_ns_128 / 1000000000);
    long zone_off = (long)temporal::tzdb_offset_for_zone_at(zone_name, epoch_secs);
    if (zone_off == off_sec) return true;
    if (mode == 3 /* prefer */) {
        *epoch_ns_128 = wall_ns_128 - (int128)zone_off * (int128)1000000000L;
        return true;
    }
    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset string");
    return false;
}

fn void builtin_temporal_zoneddatetime_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);

    // Per spec, a Symbol argument is a TypeError (not a RangeError from the
    // ISO parser). Other non-string non-object primitives also throw
    // TypeError. Empty string goes through the ISO parser as RangeError.
    if (arg.is_string()) {
        HString* argstr = (HString*)arg.get_heapptr();
        if (argstr != null && argstr.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from: Symbol argument is not a valid string or property bag");
            return;
        }
    } else if (!arg.is_object() || arg.get_heapptr() == null) {
        // null, true, numbers, BigInts land here. Each throws TypeError.
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from: argument must be a string or object");
        return;
    }

    // String input: parse ISO ZonedDateTime string. Per spec, options are
    // validated AFTER string parsing succeeds (so a syntactically bad string
    // raises RangeError before any TypeError from the options check).
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid string"); return; }
        char[] text = s.get_cstr()[:s.blen];
        temporal::ParsedIsoZonedDateTime p = { .year = 0, .month = 0, .day = 0, .hour = 0, .minute = 0, .second = 0, .nanos = 0, .offset_seconds = 0, .has_offset = false, .is_z = false };
        if (!temporal::parse_iso_zoneddatetime_string(text, &p)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.ZonedDateTime.from: invalid ISO string");
            return;
        }
        // Validate options for the string path. Returns the offset mode so
        // the wall-day range check can be skipped for `use`/`ignore`, where
        // the exact time is pinned and the wall instant need not be computed.
        temporal::OverflowKind _str_overflow;
        int offset_mode = validate_zdt_from_options(ctx, &_str_overflow);
        if (offset_mode < 0) return;
        // Resolve timezone from annotation or offset. If the bracket is an
        // offset like `+01:00` and there was NO explicit offset on the
        // date-time (i.e. the parser left offset_seconds at 0 without seeing
        // Z/±HH:MM), the bracket offset governs the wall-to-epoch arithmetic.
        // An explicit `Z`/`±HH:MM` between time and bracket wins per spec:
        // the bracket is only the zone identifier.
        HObject* tz;
        long bracket_off = 0;
        bool bracket_is_offset = false;
        String zname = "";
        if (p.timezone.len > 0) {
            char[] tz_id = p.timezone;
            String tzid_str = (String)tz_id;
            zname = tzid_str;
            usz j = 0;
            long off_check = 0;
            if (parse_offset_only(tzid_str, &j, &off_check) && j == tzid_str.len) {
                bracket_off = off_check;
                bracket_is_offset = true;
            }
            if (temporal::tzdb_zone_exists((String)tz_id)) {
                HObject*? tz_o = alloc_timezone(ctx.heap, (String)tz_id);
                if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
                tz = tz_o;
            } else {
                HObject* tz_o = resolve_tz_from_string(ctx, (String)tz_id);
                if (tz_o == null) return;
                tz = tz_o;
            }
        } else {
            char[8] off_buf;
            long mag = p.offset_seconds < 0 ? -p.offset_seconds : p.offset_seconds;
            off_buf[0] = p.offset_seconds >= 0 ? '+' : '-';
            off_buf[1] = (char)('0' + (int)(mag / 3600 / 10));
            off_buf[2] = (char)('0' + (int)(mag / 3600 % 10));
            off_buf[3] = ':';
            off_buf[4] = (char)('0' + (int)((mag % 3600) / 60 / 10));
            off_buf[5] = (char)('0' + (int)((mag % 3600) / 60 % 10));
            off_buf[6] = 0;
            zname = (String)off_buf[:6];
            HObject*? tz_o = alloc_timezone(ctx.heap, (String)off_buf[:6]);
            if (catch err = tz_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            tz = tz_o;
        }
        long wall_secs = temporal::epoch_days_from_civil(p.year, p.month, p.day) * 86400
            + (long)p.hour * 3600 + (long)p.minute * 60 + (long)p.second;
        // CheckISODaysRange: the wall date must be within ±10^8 days of the
        // epoch (per spec, to keep the intermediate arithmetic representable).
        // Without this, `-271821-04-19T23:00-01:00[-01:00]` is silently
        // accepted even though the wall date is one day below the limit.
        // However, when the offset option is `use` or `ignore` the exact
        // instant is pinned by the explicit offset and the wall instant need
        // not be computed, so a wall date outside the limit is allowed.
        if (offset_mode != 1 && offset_mode != 2) {
            long wall_day = temporal::epoch_days_from_civil(p.year, p.month, p.day);
            long day_limit = 100000000L;
            if (wall_day > day_limit || wall_day < -day_limit) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.ZonedDateTime.from: ISO date outside the representable range");
                return;
            }
        }
        // When the bracket is an offset zone (e.g. `+01:00`) and no explicit
        // offset was given on the date-time, the bracket offset governs.
        // For an IANA zone with no explicit offset, offset_seconds=0 and
        // disambiguation picks the right wall instant.
        long effective_off = (bracket_is_offset && !p.has_offset) ? bracket_off : p.offset_seconds;
        // Build the instant as a BigInt so the range check survives at
        // ±10^8 days, where double precision (2^53) can't represent every
        // integer. Wall and offset are converted via int128 then to BigInt
        // so values near NS_MAX/NS_MIN don't round.
        int128 wall_ns_128 = (int128)wall_secs * (int128)1000000000L + (int128)p.nanos;
        int128 eff_off_128 = (int128)effective_off;
        int128 epoch_ns_128 = wall_ns_128 - eff_off_128 * (int128)1000000000L;
        // Instant range check: NS_MIN..NS_MAX is ±100,000,000 days * 86400e9 ns.
        {
            int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
            if (epoch_ns_128 > ns_limit || epoch_ns_128 < -ns_limit) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.ZonedDateTime.from: instant outside the representable range");
                return;
            }
        }
        // An explicit numeric offset (a `Z`/`±HH:MM` between time and bracket)
        // must agree with the zone's actual offset at the instant it produces,
        // per the offset option semantics (reject/default throw, use/ignore
        // pass, prefer falls back to the zone offset). `Z` pins the instant;
        // it is the bracket that is merely the zone identifier, so it is
        // excluded from this agreement check.
        if (p.has_offset && !p.is_z) {
            int128 agree_epoch = epoch_ns_128;
            if (!zdt_check_offset_agreement(ctx, zname, wall_ns_128, p.offset_seconds, offset_mode, &agree_epoch)) return;
            epoch_ns_128 = agree_epoch;
        }
        // Build the BigInt straight from the int128. Going via a double here
        // would discard every bit below 2^53, so an epoch instant such as
        // 2000-01-01T12:34:56.98765Z (946730096987650000 ns) came back as
        // ...987650048 and its `nanosecond` field read 48 instead of 0.
        hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns_128);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
        hbigint::HBigInt* epoch_ns = big_o;
        HString* cal = builtin_intern_string(ctx.heap, "iso8601");
        HObject*? obj_o = alloc_zoneddatetime(ctx.heap, epoch_ns, tz, cal);
        ctx.heap.decref((types::HeapHeader*)epoch_ns);
        if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* obj = obj_o;
        obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
        ctx.result.set_object(obj);
        return;
    }

    // Object input. Options are read before the ZDT identity copy path; the
    // property-bag path reads them after the fields (order-of-operations).
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            temporal::OverflowKind om_overflow;
            int om = validate_zdt_from_options(ctx, &om_overflow);
            if (om < 0) return;
            // Per spec, a ZonedDateTime argument produces a copy rather
            // than the same instance. The shared sub-objects (time-zone,
            // calendar) are incref'd in `alloc_zoneddatetime` so this
            // copy keeps the original reachable through them.
            hbigint::HBigInt* src_ns = o.extra.temporal.big_ns;
            HObject* src_tz = o.extra.temporal.timezone;
            HString* src_cal = (HString*)o.extra.temporal.calendar;
            hbigint::HBigInt*? big_o = hbigint::hbigint_copy(ctx.heap, src_ns);
            if (catch err = big_o) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Instant copy failed");
                return;
            }
            HObject*? obj_o = alloc_zoneddatetime(ctx.heap, big_o, src_tz, src_cal);
            ctx.heap.decref((types::HeapHeader*)big_o);
            if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
            HObject* obj = obj_o;
            obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
            ctx.result.set_object(obj);
            return;
        }
        // Property bag. Read all fields in the spec's alphabetical order:
        // the unified reader resolves `timeZone` and validates `offset` at
        // their positions (offset between nanosecond and second, timeZone
        // between second and year) and requires the date fields. The
        // disambiguation/offset/overflow options are read AFTER the fields
        // per the order-of-operations fixture, before field validation so
        // `overflow: "reject"` is honored (test262 overflow-options.js,
        // calendarresolvefields-error-ordering.js).
        Vm* v = (Vm*)ctx.vm;
        temporal::CivilDateTime fields;
        temporal::CivilDateTime cur = { .date = { .y = 1970, .m = 1, .d = 1 }, .time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 } };
        bool _zdt_have_mc;
        int _zdt_mci;
        TVal _zdt_mc_v;
        bool has_tz = false;
        HObject* tz = null;
        bool has_offset_prop = false;
        long off_sec = 0;
        if (!bag_to_datetime_fields_ex(ctx, o, TBM_ZDT, true, true, cur.date, cur.time, &fields,
                                       null, &_zdt_have_mc, &_zdt_mci, &_zdt_mc_v,
                                       &has_tz, &tz, &has_offset_prop, &off_sec)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        if (!has_tz) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from: property bag requires a timeZone property");
            return;
        }
        // If no `offset` was supplied but the time zone is an offset zone
        // (e.g. "+01:46"), use that offset to convert the wall time to UTC.
        // The agreement check below applies only when both an offset and an
        // offset-zone name were supplied; here they would necessarily agree.
        if (!has_offset_prop) {
            String tzid_str = timezone_name(tz);
            usz k = 0;
            long tz_off = 0;
            if (parse_offset_only((char[])tzid_str, &k, &tz_off) && k == tzid_str.len) {
                off_sec = tz_off;
                has_offset_prop = true;
            }
        }
        temporal::OverflowKind zdt_overflow;
        int zdt_offset_mode = 0;
        {
            temporal::OverflowKind ov_kind;
            int om_b = validate_zdt_from_options(ctx, &ov_kind);
            if (om_b < 0) return;
            zdt_overflow = ov_kind;
            zdt_offset_mode = om_b;
        }
        if (!check_iso_monthcode_suitability(ctx, _zdt_have_mc, _zdt_mci, _zdt_mc_v)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return;
        }
        temporal::CivilDate valid_d;
        if (!fields_to_valid_date(ctx, fields.date, zdt_overflow, &valid_d)) return;
        temporal::CivilTime valid_t;
        if (!fields_to_valid_time(ctx, fields.time, &valid_t, temporal::OverflowKind.REJECT, false)) return;
        long wall_secs = temporal::epoch_days_from_civil(valid_d.y, (int)valid_d.m, (int)valid_d.d) * 86400
            + (long)valid_t.h * 3600 + (long)valid_t.mi * 60 + (long)valid_t.s;
        long frac_ns = (long)valid_t.ms * 1000000 + (long)valid_t.us * 1000 + (long)valid_t.ns;
        // Combine in int128: double arithmetic here would drop every bit
        // below 2^53 and corrupt the sub-microsecond digits.
        int128 epoch_ns_128 = (int128)wall_secs * (int128)1000000000L + (int128)frac_ns
            - (int128)off_sec * (int128)1000000000L;
        // The supplied offset must agree with the time zone's actual offset
        // at the instant it produces, per the offset option semantics. When
        // the offset was synthesized from an offset-form zone id it agrees
        // trivially; an explicit property offset on an IANA zone is the real
        // check that can throw (see `offset-does-not-match-iana-time-zone`).
        if (has_offset_prop) {
            int128 agree_epoch = epoch_ns_128;
            String zname = timezone_name(tz);
            if (!zdt_check_offset_agreement(ctx, zname, epoch_ns_128 + (int128)off_sec * (int128)1000000000L,
                                            off_sec, zdt_offset_mode, &agree_epoch)) return;
            epoch_ns_128 = agree_epoch;
        }
        hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns_128);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
        hbigint::HBigInt* epoch_ns = big_o;
        HString* cal_str = builtin_intern_string(ctx.heap, "iso8601");
        HObject*? obj_o = alloc_zoneddatetime(ctx.heap, epoch_ns, tz, cal_str);
        ctx.heap.decref((types::HeapHeader*)epoch_ns);
        if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* zdt_obj = obj_o;
        zdt_obj.prototype = ctx.heap.temporal_zoneddatetime_proto;
        ctx.result.set_object(zdt_obj);
        return;
    }

    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.from: argument must be a string or object");
}

// Temporal.ZonedDateTime.compare(a, b)
fn void builtin_temporal_zoneddatetime_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare requires two arguments");
        return;
    }
    TVal* a_arg = arg_at(ctx, 0);
    TVal* b_arg = arg_at(ctx, 1);

    // Resolve a.
    hbigint::HBigInt* a_ns = null;
    if (a_arg.is_object() && a_arg.get_heapptr() != null
        && ((HObject*)a_arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        a_ns = ((HObject*)a_arg.get_heapptr()).extra.temporal.big_ns;
    } else {
        // Reject non-string/non-object primitives (including Symbol) before
        // delegating to `from`, which would otherwise mishandle them.
        if (!a_arg.is_string() && !(a_arg.is_object() && a_arg.get_heapptr() != null)) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare: argument must be a ZonedDateTime, string, or property bag");
            return;
        }
        // String path: reject Symbols (they would otherwise coerce to a
        // RangeError via the ISO parser; the spec wants a TypeError here).
        if (a_arg.is_string()) {
            HString* as = (HString*)a_arg.get_heapptr();
            if (as != null && as.is_symbol()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare: Symbol argument is not a ZonedDateTime");
                return;
            }
        }
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *a_arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        ctx.argc = 2;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) { builtin_throw(ctx, ctx.heap.type_err_proto, "not a ZonedDateTime"); return; }
        a_ns = ((HObject*)ctx.result.get_heapptr()).extra.temporal.big_ns;
    }

    // Resolve b.
    hbigint::HBigInt* b_ns = null;
    if (b_arg.is_object() && b_arg.get_heapptr() != null
        && ((HObject*)b_arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        b_ns = ((HObject*)b_arg.get_heapptr()).extra.temporal.big_ns;
    } else {
        if (!b_arg.is_string() && !(b_arg.is_object() && b_arg.get_heapptr() != null)) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare: argument must be a ZonedDateTime, string, or property bag");
            return;
        }
        if (b_arg.is_string()) {
            HString* bs = (HString*)b_arg.get_heapptr();
            if (bs != null && bs.is_symbol()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.compare: Symbol argument is not a ZonedDateTime");
                return;
            }
        }
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *b_arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        ctx.argc = 2;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) { builtin_throw(ctx, ctx.heap.type_err_proto, "not a ZonedDateTime"); return; }
        b_ns = ((HObject*)ctx.result.get_heapptr()).extra.temporal.big_ns;
    }

    ctx.result.set_fastint(instant_cmp_big(a_ns, b_ns));
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
fn void zdt_iso_string(BuiltinContext* ctx, hbigint::HBigInt* b, HObject* tz, int digits, TemporalRoundMode rm, bool drop_zone,
                      int show_offset, int show_tz, int show_cal) {
    // show_offset: 1 = show, 0 = hide; show_tz: 1 = show, 0 = hide, 2 = the
    // `!` critical flag; show_cal: 0 = auto (omits ISO), 1 = always,
    // 2 = never, 3 = critical. The caller has already read and validated the
    // option strings; nothing is re-read here.
    long epoch_secs;
    long ns_rem;
    if (b.fits_int128()) {
        int128 total = b.to_int128();
        long sec_trunc = (long)(total / 1000000000);
        ns_rem = (long)(total - (int128)sec_trunc * 1000000000);
        if (ns_rem < 0) {
            sec_trunc -= 1;
            ns_rem += 1000000000;
        }
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

    // Round up to whole minute when smallestUnit == "minute" (digits == -10):
    // collapse seconds + ns to a multiple of 60s using `rm`. After rounding
    // the broken-down time's seconds/ms/us/ns are all zero.
    if (digits == -10) {
        long total_ns = local_secs * 1000000000 + ns_rem;
        long rounded_total_ns = round_long_ns(total_ns, 60 * 1000000000L, rm);
        local_secs = rounded_total_ns / 1000000000;
        ns_rem = 0;
    } else if (digits >= 0 && ns_rem != 0) {
        // Round ns_rem to `digits` precision. If rounding pushes ns_rem over
        // a whole second, carry the extra second into local_secs before
        // recomputing the broken-down time.
        long divisor = 1;
        for (int i = 0; i < 9 - digits; i++) divisor *= 10;
        long v = (long)round_num_to_incr((double)ns_rem / (double)divisor, 1.0, rm);
        long new_ns_rem = v * divisor;
        if (new_ns_rem >= 1000000000) {
            local_secs += 1;
            new_ns_rem -= 1000000000;
        }
        ns_rem = new_ns_rem;
    }

    temporal::BrokenDownTime bd = temporal::civil_from_seconds(local_secs);
    char[64] buf;
    int n;
    // Year formatting per GetISOPartsFromEpoch: 0..9999 renders as a 4-digit
    // unsigned year; negative or >9999 renders as a 6-digit signed year.
    long y = bd.y;
    if (digits == -10) {
        if (y < 0) {
            n = libc::snprintf(&buf, 64, "-%06ld-%02ld-%02ldT%02ld:%02ld",
                -y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        } else if (y > 9999) {
            n = libc::snprintf(&buf, 64, "+%06ld-%02ld-%02ldT%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        } else {
            n = libc::snprintf(&buf, 64, "%04ld-%02ld-%02ldT%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        }
    } else {
        if (y < 0) {
            n = libc::snprintf(&buf, 64, "-%06ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                -y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        } else if (y > 9999) {
            n = libc::snprintf(&buf, 64, "+%06ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        } else {
            n = libc::snprintf(&buf, 64, "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        }
        n += format_fractional_seconds(&buf[n], ns_rem, digits, rm);
    }
    format_offset_seconds(&buf[n], off);
    if (show_offset == 1) n += 6;
    if (!drop_zone && zone.len > 0 && zone.ptr != null && show_tz > 0) {
        int zn = libc::snprintf(&buf[n], 64 - (usz)n, (show_tz == 2) ? "[!%s]" : "[%s]", (char*)zone.ptr);
        n += zn;
    }
    // Calendar name suffix per spec: auto omits for ISO, always and critical
    // include it (`critical` with `!`), never never adds it.
    bool include_cal = false;
    bool cal_critical = false;
    if (show_cal == 1) { include_cal = true; }
    else if (show_cal == 3) { include_cal = true; cal_critical = true; }
    // show_cal == 0 (auto) and show_cal == 2 (never) both leave include_cal false.
    if (include_cal && 64 - (usz)n > 12) {
        int zn = libc::snprintf(&buf[n], 64 - (usz)n, cal_critical ? "[!u-ca=iso8601]" : "[u-ca=iso8601]");
        n += zn;
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:n]));
}

fn void builtin_temporal_zoneddatetime_proto_toString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    int digits;
    TemporalRoundMode rm;
    // Display flags for offset / timeZoneName / calendarName. Defaults match
    // the spec: offset and timeZoneName show, calendarName shows only when
    // non-ISO ("auto"). Set from the validated option strings below.
    int show_offset = 1; // 1 = show, 0 = hide
    int show_tz = 1;     // 1 = show, 0 = hide, 2 = critical flag
    int show_cal = 0;    // 0 = auto, 1 = always, 2 = never, 3 = critical
    // Probe all seven ZDT.toString options in alphabetical order:
    // calendarName, fractionalSecondDigits, offset, roundingMode,
    // smallestUnit, timeZoneName, timeZone. The order-of-operations
    // fixture asserts each `get options.X` / `get options.X.toString` /
    // `call options.X.toString` triple in that order, so ToString the
    // value right after the get. Validate only after all reads succeed —
    // matches the spec's `Read options / Validate` split.
    if (ctx.argc >= 1 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal ov = ctx.regs[ctx.base_reg];
        if (!ov.is_object() || ov.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
            return;
        }
        HObject* opts = (HObject*)ov.get_heapptr();
        HString* cal_s = null;
        HString* fd_s = null;
        HString* off_s = null;
        HString* rm_str = null;
        HString* su_s = null;
        HString* tzn_s = null;
        bool fd_is_number = false;
        double fd_num = 0;

        // calendarName
        TVal cn = prop_or_undefined_pa(ctx, opts, "calendarName");
        if (ctx.should_throw) return;
        if (!cn.is_undefined()) {
            cal_s = builtin_to_string_vm(ctx, &cn);
            if (ctx.should_throw) return;
        }

        // fractionalSecondDigits
        {
            TVal fd = prop_or_undefined_pa(ctx, opts, "fractionalSecondDigits");
            if (ctx.should_throw) return;
            if (!fd.is_undefined()) {
                // GetStringOrNumberOption uses a Number numerically and never
                // stringifies it; only non-Numbers take the string path,
                // where "auto" is the sole valid value.
                if (fd.is_numeric()) {
                    fd_is_number = true;
                    fd_num = fd.get_number_or_fastint();
                } else {
                    fd_s = builtin_to_string_vm(ctx, &fd);
                    if (ctx.should_throw) return;
                }
            }
        }

        // offset
        {
            TVal offv = prop_or_undefined_pa(ctx, opts, "offset");
            if (ctx.should_throw) return;
            if (!offv.is_undefined()) {
                off_s = builtin_to_string_vm(ctx, &offv);
                if (ctx.should_throw) return;
            }
        }

        // roundingMode
        {
            TVal rmod = prop_or_undefined_pa(ctx, opts, "roundingMode");
            if (ctx.should_throw) return;
            if (!rmod.is_undefined()) {
                rm_str = builtin_to_string_vm(ctx, &rmod);
                if (ctx.should_throw) return;
            }
        }

        // smallestUnit (default: no rounding; sentinel handled below).
        digits = -1;
        rm = TemporalRoundMode.TRUNC;
        {
            TVal su = prop_or_undefined_pa(ctx, opts, "smallestUnit");
            if (ctx.should_throw) return;
            if (!su.is_undefined()) {
                su_s = builtin_to_string_vm(ctx, &su);
                if (ctx.should_throw) return;
            }
        }

        // timeZoneName
        {
            TVal tzn = prop_or_undefined_pa(ctx, opts, "timeZoneName");
            if (ctx.should_throw) return;
            if (!tzn.is_undefined()) {
                tzn_s = builtin_to_string_vm(ctx, &tzn);
                if (ctx.should_throw) return;
            }
        }

        // Validate after all probes. Note: `timeZone` is intentionally
        // omitted from this list because the ZDT.toString spec doesn't
        // accept a `timeZone` option (the zone is the receiver's).
        if (cal_s != null) {
            char[] v = cal_s.get_cstr()[:cal_s.blen];
            if (v != "auto" && v != "always" && v != "never" && v != "critical") {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid calendarName");
                return;
            }
            if (v == "always") { show_cal = 1; }
            else if (v == "never") { show_cal = 2; }
            else if (v == "critical") { show_cal = 3; }
        }
        // fractionalSecondDigits: "auto" or a non-negative integer 0..9. When the
        // value was wrapped by the toPrimitiveObserver the coerced string is
        // already the digit text (e.g. "2" or "auto"); don't re-read the
        // bag to honour propertyBagObserver's "one get per option" rule.
        if (fd_is_number) {
            // Per spec, GetStringOrNumberOption floors non-integer values.
            double dv = math::floor(fd_num);
            if (math::is_nan(fd_num) || dv < 0 || dv > 9) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0..9 or \"auto\"");
                return;
            }
            digits = (int)dv;
        } else if (fd_s != null) {
            char[] v = fd_s.get_cstr()[:fd_s.blen];
            if (v == "auto") { digits = -1; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0..9 or \"auto\"");
                return;
            }
        }
        if (off_s != null) {
            char[] v = off_s.get_cstr()[:off_s.blen];
            if (v != "auto" && v != "never") {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset option");
                return;
            }
            show_offset = (v == "auto") ? 1 : 0;
        }
        if (rm_str != null) {
            char[] v = rm_str.get_cstr()[:rm_str.blen];
            if (v != "ceil" && v != "floor" && v != "expand" && v != "trunc"
                && v != "halfCeil" && v != "halfFloor" && v != "halfExpand"
                && v != "halfTrunc" && v != "halfEven") {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return;
            }
            // Map strings to TemporalRoundMode. The default before this
            // block was TRUNC; any explicit value overrides.
            if (v == "ceil") { rm = TemporalRoundMode.CEIL; }
            else if (v == "floor") { rm = TemporalRoundMode.FLOOR; }
            else if (v == "expand") { rm = TemporalRoundMode.EXPAND; }
            else if (v == "trunc") { rm = TemporalRoundMode.TRUNC; }
            else if (v == "halfCeil") { rm = TemporalRoundMode.HALF_CEIL; }
            else if (v == "halfFloor") { rm = TemporalRoundMode.HALF_FLOOR; }
            else if (v == "halfExpand") { rm = TemporalRoundMode.HALF_EXPAND; }
            else if (v == "halfTrunc") { rm = TemporalRoundMode.HALF_TRUNC; }
            else if (v == "halfEven") { rm = TemporalRoundMode.HALF_EVEN; }
        }
        if (su_s != null) {
            char[] v = su_s.get_cstr()[:su_s.blen];
            // Sentinel -10: round to minute, no fractional part.
            if (v == "minute" || v == "minutes") { digits = -10; }
            else if (v == "second" || v == "seconds") { digits = 0; }
            else if (v == "millisecond" || v == "milliseconds") { digits = 3; }
            else if (v == "microsecond" || v == "microseconds") { digits = 6; }
            else if (v == "nanosecond" || v == "nanoseconds") { digits = 9; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
                return;
            }
        }
        if (tzn_s != null) {
            char[] v = tzn_s.get_cstr()[:tzn_s.blen];
            if (v != "auto" && v != "never" && v != "critical") {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid timeZoneName option");
                return;
            }
            if (v == "never") { show_tz = 0; }
            else if (v == "critical") { show_tz = 2; }
        }
    } else {
        digits = -1;
        rm = TemporalRoundMode.TRUNC;
    }
    zdt_iso_string(ctx, obj.extra.temporal.big_ns, obj.extra.temporal.timezone, digits, rm, false, show_offset, show_tz, show_cal);
}

fn void builtin_temporal_zoneddatetime_proto_toJSON(BuiltinContext* ctx) {
    // toJSON delegates to toString: auto precision, full output including [Zone].
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    ctx.argc = 0;
    builtin_temporal_zoneddatetime_proto_toString(ctx);
}

fn void builtin_temporal_zoneddatetime_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    ctx.argc = 0;
    builtin_temporal_zoneddatetime_proto_toString(ctx);
}

fn void builtin_temporal_zoneddatetime_proto_equals(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    // equals runs ToTemporalZonedDateTime, so strings and property bags
    // (with year / month / day / timeZone) are accepted. Non-Temporal,
    // non-string, non-object primitives throw TypeError.
    hbigint::HBigInt* b_ns = null;
    HObject* b_tz = null;
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        HObject* b = (HObject*)arg.get_heapptr();
        b_ns = b.extra.temporal.big_ns;
        b_tz = b.extra.temporal.timezone;
    } else if (arg.is_string()) {
        HString* as = (HString*)arg.get_heapptr();
        if (as != null && as.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "argument is not a Temporal.ZonedDateTime");
            return;
        }
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        ctx.argc = 1;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) { builtin_throw(ctx, ctx.heap.type_err_proto, "not a ZonedDateTime"); return; }
        HObject* b = (HObject*)ctx.result.get_heapptr();
        b_ns = b.extra.temporal.big_ns;
        b_tz = b.extra.temporal.timezone;
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        // Property bag — delegate to from().
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        ctx.argc = 1;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) { builtin_throw(ctx, ctx.heap.type_err_proto, "not a ZonedDateTime"); return; }
        HObject* b = (HObject*)ctx.result.get_heapptr();
        b_ns = b.extra.temporal.big_ns;
        b_tz = b.extra.temporal.timezone;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument is not a Temporal.ZonedDateTime");
        return;
    }
    HObject* a = (HObject*)ctx.this_val.get_heapptr();
    // ZonedDateTime equality also requires the same time zone (calendar
    // is always iso8601, so it can be omitted from the check).
    String za = a.extra.temporal.timezone == null ? "" : timezone_name(a.extra.temporal.timezone);
    String zb = b_tz == null ? "" : timezone_name(b_tz);
    bool same_ns = b_ns != null && hbigint::hbigint_cmp(a.extra.temporal.big_ns, b_ns) == 0;
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

    // RejectObjectWithCalendarOrTimeZone (spec step 4-5): throw TypeError
    // if the bag is a Temporal object or has "calendar"/"timeZone" Get-
    // probed properties. The bag reader below probes both (calendar, then
    // timeZone) and rejects on presence.
    if (!reject_temporal_object_bag(ctx, bag)) return;

    // Current wall time: epoch -> local via the offset in effect at the epoch.
    // Go through zdt_wall_fields, which splits the epoch in int128; routing
    // this through a double instead rounded away everything below 2^53, so
    // the carried-over sub-microsecond digits were lost for any field the
    // bag did not overwrite.
    long cwy, cwm, cwd; int cwh, cwmi, cws, cwms, cwus, cwns, cwoff;
    zdt_wall_fields(self, &cwy, &cwm, &cwd, &cwh, &cwmi, &cws, &cwms, &cwus, &cwns, &cwoff);
    temporal::CivilDateTime cur = {
        .date = { .y = cwy, .m = cwm, .d = cwd },
        .time = { .h = cwh, .mi = cwmi, .s = cws,
                  .ms = cwms, .us = cwus, .ns = cwns },
    };

    temporal::CivilDateTime fields;
    bool have_mc;
    int mci;
    TVal mc_v;
    bool found_any;
    if (!bag_to_datetime_fields_ex(ctx, bag, TBM_ZDT_WITH, true, false, cur.date, cur.time, &fields,
                                &found_any, &have_mc, &mci, &mc_v, null, null, null, null)) {
        return;
    }
    if (!found_any) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "at least one property must be provided");
        return;
    }

    temporal::OverflowKind overflow = temporal::OverflowKind.CONSTRAIN;
    if (ctx.argc >= 2) {
        TVal* ov = arg_at(ctx, 1);
        if (ov != null && !ov.is_undefined()) {
            if (!ov.is_object() || ov.get_heapptr() == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "with options must be an object");
                return;
            }
            HObject* opts = (HObject*)ov.get_heapptr();
            // Spec order: disambiguation, offset, overflow.
            TVal disv = prop_or_undefined_pa(ctx, opts, "disambiguation");
            if (ctx.should_throw) return;
            if (!disv.is_undefined()) {
                HString* s = builtin_to_string_vm(ctx, &disv);
                if (ctx.should_throw) return;
                if (s == null) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "disambiguation option must be a string");
                    return;
                }
                char[] ostr = (String)s.get_cstr()[:s.blen];
                if (ostr != "compatible" && ostr != "earlier" && ostr != "later" && ostr != "reject") {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid disambiguation option");
                    return;
                }
            }
            TVal offv = prop_or_undefined_pa(ctx, opts, "offset");
            if (ctx.should_throw) return;
            if (!offv.is_undefined()) {
                HString* s = builtin_to_string_vm(ctx, &offv);
                if (ctx.should_throw) return;
                if (s == null) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "offset option must be a string");
                    return;
                }
                char[] ostr = (String)s.get_cstr()[:s.blen];
                if (ostr != "prefer" && ostr != "use" && ostr != "ignore" && ostr != "reject") {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid offset option");
                    return;
                }
            }
            TVal ovv = prop_or_undefined_pa(ctx, opts, "overflow");
            if (ctx.should_throw) return;
            if (!ovv.is_undefined()) {
                HString* s = builtin_to_string_vm(ctx, &ovv);
                if (ctx.should_throw) return;
                if (s == null) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "overflow option must be a string");
                    return;
                }
                char[] ostr = (String)s.get_cstr()[:s.blen];
                if (ostr == "reject") {
                    overflow = temporal::OverflowKind.REJECT;
                } else if (ostr != "constrain") {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid overflow option");
                    return;
                }
            }
        }
    }
    temporal::CivilDate valid_d;
    if (!check_iso_monthcode_suitability(ctx, have_mc, mci, mc_v)) return;
    if (!fields_to_valid_date(ctx, fields.date, overflow, &valid_d)) return;
    temporal::CivilTime valid_t;
    if (!fields_to_valid_time(ctx, fields.time, &valid_t, overflow, false)) return;

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

    // Candidate selection above only needs second-level accuracy, so it can
    // run in doubles; but the final instant must be exact. Recover the chosen
    // candidate's offset (a whole number of seconds) and rebuild the epoch
    // nanos in int128, or the sub-microsecond digits are rounded away.
    long chosen_off;
    if (nh == 1 || nh == 2) {
        // Overlap: "earlier" and "compatible" pick the earlier instant, "later"
        // the later. (compatible normally prefers the offset matching the
        // current instant; for the common single-offset-change case the earlier
        // instant carries that offset.)
        chosen_off = (long)math::round((naive_ns - hits[0]) / 1e9);
    } else {
        // Gap: "compatible" shifts the wall time across the skipped hour,
        // relocating it to the instant whose local time is the post-gap offset.
        chosen_off = (long)temporal::tzdb_offset_for_zone_at(zone, wall_secs + 4 * 3600);
    }
    int128 chosen_128 = (int128)wall_secs * (int128)1000000000L + (int128)wfrac
        - (int128)chosen_off * (int128)1000000000L;

    // The resolved instant must fall within the representable epoch range
    // (±8.64e21 ns). The wall date can be a lone valid ISO date while its
    // UTC instant lands just past −271821-04-19T00:00 (below NS_MIN), so this
    // is a genuine second check after date/time validation.
    int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
    if (chosen_128 > ns_limit || chosen_128 < -ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
        return;
    }

    hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, chosen_128);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
    ((types::HeapHeader*)self.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, self.extra.temporal.timezone, (HString*)self.extra.temporal.calendar);
}

// Resolve a wall-clock time in `zone` to an epoch-nanosecond instant, using
// the "compatible" disambiguation: an ambiguous time in a fall-back overlap
// takes the earlier instant, and a time skipped by a spring-forward gap moves
// to the post-gap offset.
// Offsets are whole seconds, so the result is computed as an int128 to keep
// nanosecond precision: epoch-ns of a modern date exceeds what a double can
// represent exactly.
fn int128 zdt_local_to_epoch_ns(String zone, long wall_secs, long wall_frac_ns) {
    if (zone.len == 0 || zone.ptr == null) {
        return (int128)wall_secs * 1000000000 + (int128)wall_frac_ns;
    }

    // Any offset in force near the wall time is a candidate; keep the ones
    // that map back to a matching offset, which drops the phantom readings a
    // transition creates.
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

    // An overlap yields several valid offsets; "compatible" wants the earliest
    // instant, which is the largest offset.
    int chosen_off = 0;
    bool found = false;
    for (int k = 0; k < nc; k++) {
        if (temporal::tzdb_offset_for_zone_at(zone, wall_secs - cand[k]) != cand[k]) continue;
        if (!found || cand[k] > chosen_off) { chosen_off = cand[k]; found = true; }
    }
    // A gap skips the wall time entirely; shift it past the transition.
    if (!found) chosen_off = temporal::tzdb_offset_for_zone_at(zone, wall_secs + 4 * 3600);

    return (int128)(wall_secs - chosen_off) * 1000000000 + (int128)wall_frac_ns;
}

// Convert a Duration's time components (hours..nanoseconds) to an
// epoch-nanosecond BigInt delta. Calendar units carry no fixed nanosecond
// length and are the caller's to resolve against a date.
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
    // Per spec, withTimeZone accepts either a TimeZone object or a string
    // / ISO-string time-zone identifier. Earlier builds rejected strings
    // outright, but test262 (e.g. `disregard-time-zone-ids-if-exact-
    // times-are-equal.js`) calls `zdt.withTimeZone("+05:30")`.
    HObject* new_tz_obj;
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_TIMEZONE) {
        new_tz_obj = (HObject*)arg.get_heapptr();
    } else if (try maybe_tz = to_temporal_tz(ctx, arg)) {
        if (ctx.should_throw) return;
        new_tz_obj = maybe_tz;
    } else {
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    ((types::HeapHeader*)self.extra.temporal.big_ns).incref();
    zdt_from_parts(ctx, self.extra.temporal.big_ns, new_tz_obj, (HString*)self.extra.temporal.calendar);
}

// this.withCalendar(calendar) — Phase 2 accepts only the iso8601 calendar;
// a non-iso8601 or non-Calendar argument throws.
fn void builtin_temporal_zoneddatetime_proto_withCalendar(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1 || ctx.regs[ctx.base_reg].is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "withCalendar requires a calendar");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    HObject* cal = null;
    if (!calendar_from_arg(ctx, arg, &cal)) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    ((types::HeapHeader*)self.extra.temporal.big_ns).incref();
    ((types::HeapHeader*)self.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, self.extra.temporal.big_ns, self.extra.temporal.timezone, (HString*)cal);
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
    // Per spec, the duration argument is coerced via `ToTemporalDuration`,
    // which accepts a Duration, a duration string, or a property bag.
    // Primitive non-string types (number, boolean, BigInt, null, Symbol)
    // throw TypeError.
    temporal::DurationParts d_in;
    if (!duration_from_arg(ctx, arg, &d_in)) return;
    // ZDT.add/subtract reads the overflow option (default `reject`) before
    // any calendar arithmetic — see GetTemporalOverflowOption in the spec.
    // The order-of-operations tests wrap `options` in a Proxy and expect to
    // see the `get options.overflow` log line after the duration fields.
    temporal::OverflowKind overflow;
    if (!read_overflow_option(ctx, 1, &overflow)) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    temporal::DurationParts dp = d_in;
    long sign = subtract ? -1 : 1;

    hbigint::HBigInt* base = self.extra.temporal.big_ns;
    ((types::HeapHeader*)base).incref();

    // Years, months, weeks and days move the wall-clock date, so they are
    // applied on the local axis and re-resolved against the zone; a day across
    // a DST boundary is then a calendar day rather than a fixed 24 hours.
    if (dp.years != 0 || dp.months != 0 || dp.weeks != 0 || dp.days != 0) {
        long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
        zdt_wall_fields(self, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);
        temporal::CivilDate d = { .y = wy, .m = wm, .d = wd };
        if (dp.years != 0)  d = temporal::add_months(d, sign * dp.years * 12, temporal::OverflowKind.CONSTRAIN);
        if (dp.months != 0) d = temporal::add_months(d, sign * dp.months, temporal::OverflowKind.CONSTRAIN);
        long day_shift = sign * (dp.weeks * 7 + dp.days);
        if (day_shift != 0) d = temporal::add_days(d, day_shift);

        long wall_secs = temporal::epoch_days_from_civil(d.y, (int)d.m, (int)d.d) * 86400
            + (long)wh * 3600 + (long)wmi * 60 + (long)ws;
        long wall_frac = (long)wms * 1000000 + (long)wus * 1000 + (long)wns;
        String zone = self.extra.temporal.timezone == null ? "" : timezone_name(self.extra.temporal.timezone);
        int128 moved = zdt_local_to_epoch_ns(zone, wall_secs, wall_frac);

        hbigint::HBigInt*? moved_o = hbigint::hbigint_alloc(ctx.heap, moved);
        ctx.heap.decref((types::HeapHeader*)base);
        if (catch err = moved_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
        base = moved_o;
    }

    // The time components are an exact elapsed-nanosecond shift on the instant.
    temporal::DurationParts time_only = {};
    time_only.hours = dp.hours;
    time_only.minutes = dp.minutes;
    time_only.seconds = dp.seconds;
    time_only.ms = dp.ms;
    time_only.us = dp.us;
    time_only.ns = dp.ns;
    hbigint::HBigInt* delta;
    if (!duration_to_ns_delta(ctx, time_only, &delta)) {
        ctx.heap.decref((types::HeapHeader*)base);
        return;
    }
    hbigint::HBigInt*? result;
    if (subtract) {
        result = instant_sub_big(base, delta, ctx.heap);
    } else {
        result = instant_add_big(base, delta, ctx.heap);
    }
    ctx.heap.decref((types::HeapHeader*)delta);
    ctx.heap.decref((types::HeapHeader*)base);
    if (catch err = result) { builtin_throw(ctx, ctx.heap.range_err_proto, "failed"); return; }
    ((types::HeapHeader*)self.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, result, self.extra.temporal.timezone, (HString*)self.extra.temporal.calendar);
}

// this.until(other) / this.since(other) — the difference as a Duration, in the
// units named by the options bag. Defaults to hours.
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
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    HObject* other;
    ushort original_argc = ctx.argc;

    // Convert argument to a ZonedDateTime via Temporal.ZonedDateTime.from.
    // Strings and property bags are accepted; primitives other than string
    // throw (Symbol → TypeError, others too).
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        other = (HObject*)arg.get_heapptr();
    } else {
        if (arg.is_string()) {
            HString* as = (HString*)arg.get_heapptr();
            if (as != null && as.is_symbol()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.until/since: Symbol argument is not a ZonedDateTime");
                return;
            }
        } else if (!arg.is_object() || arg.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.until/since: argument must be a ZonedDateTime, string, or property bag");
            return;
        }
        TVal saved_this = ctx.this_val;
        ctx.regs[ctx.base_reg + 0] = *arg;
        ctx.argc = 1;
        builtin_temporal_zoneddatetime_from(ctx);
        ctx.this_val = saved_this;
        // Restore argc so `read_diff_settings` sees the user's options arg at
        // index 1 (or no options if the caller passed only one arg).
        ctx.argc = original_argc;
        if (ctx.should_throw) return;
        if (!ctx.result.is_object()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime.until/since: argument is not a ZonedDateTime");
            return;
        }
        other = (HObject*)ctx.result.get_heapptr();
    }

    DiffSettings ds;
    if (!read_diff_settings(ctx, 1, TemporalUnit.YEAR, TemporalUnit.NANOSECOND,
                            TemporalUnit.HOUR, TemporalUnit.NANOSECOND, !until, &ds)) return;

    // Both zones must agree for a calendar-unit difference to mean anything:
    // the wall-clock breakdown below is only defined against a single zone.
    if (is_cal_unit(ds.largest) || ds.largest == TemporalUnit.DAY) {
        String za = self.extra.temporal.timezone == null ? "" : timezone_name(self.extra.temporal.timezone);
        String zb = other.extra.temporal.timezone == null ? "" : timezone_name(other.extra.temporal.timezone);
        if (za != zb) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "cannot compute calendar units across different time zones");
            return;
        }
    }

    hbigint::HBigInt* a;
    hbigint::HBigInt* b;
    if (until) { a = other.extra.temporal.big_ns; b = self.extra.temporal.big_ns; }
    else       { a = self.extra.temporal.big_ns;  b = other.extra.temporal.big_ns; }

    // Time-only largestUnit: difference on the exact epoch axis, round to the
    // smallest-unit increment, split by largestUnit. The difference is taken
    // in the other-minus-self direction (rounding origin = receiver) and
    // negated at the end for `since`, matching the calendar path below.
    if (!is_cal_unit(ds.largest) && ds.largest != TemporalUnit.DAY) {
        assert(self.extra.temporal.big_ns.fits_int128() && other.extra.temporal.big_ns.fits_int128(),
               "ZonedDateTime epochNanoseconds out of int128 range");
        int128 self_ns = self.extra.temporal.big_ns.to_int128();
        int128 other_ns = other.extra.temporal.big_ns.to_int128();
        int128 total = other_ns - self_ns;
        int128 incr_ns = (int128)(unit_ns_divisor(ds.smallest) * (long)ds.increment);
        if (incr_ns > 1) total = round_long_ns_128(total, incr_ns, ds.mode);
        temporal::DurationParts dp;
        decompose_ns_128(total, ds.largest, &dp);
        if (!until) {
            dp.hours = -dp.hours;
            dp.minutes = -dp.minutes;
            dp.seconds = -dp.seconds;
            dp.ms = -dp.ms;
            dp.us = -dp.us;
            dp.ns = -dp.ns;
        }
        HObject*? dur_o = alloc_duration(ctx.heap, dp);
        if (catch err = dur_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* dur = dur_o;
        dur.prototype = ctx.heap.temporal_duration_proto;
        ctx.result.set_object(dur);
        return;
    }

    // Calendar-unit path: difference the wall-clock dates, then carry whatever
    // time is left over. Working on the local axis keeps a DST day one calendar
    // day even though it is not 24 hours of elapsed time.
    //
    // The spec's NudgeToCalendarUnit uses the receiver as the rounding origin
    // regardless of until/since, and flips the sign at the end for `since`.
    // Mirror that here: `start = self` always (so the year/month lengths are
    // measured at `self`), `end = other` always, and negate the resulting
    // duration when this is a `since` call.
    HObject* from = self;
    HObject* to   = other;
    long fy, fm, fd; int fh, fmi, fs, fms, fus, fns, foff;
    long ty, tm, td; int th, tmi, ts, tms, tus, tns, toff;
    zdt_wall_fields(from, &fy, &fm, &fd, &fh, &fmi, &fs, &fms, &fus, &fns, &foff);
    zdt_wall_fields(to, &ty, &tm, &td, &th, &tmi, &ts, &tms, &tus, &tns, &toff);

    temporal::CivilDateTime start_dt = {
        .date = { .y = fy, .m = fm, .d = fd },
        .time = { .h = fh, .mi = fmi, .s = fs, .ms = fms, .us = fus, .ns = fns },
    };
    temporal::CivilDateTime end_dt = {
        .date = { .y = ty, .m = tm, .d = td },
        .time = { .h = th, .mi = tmi, .s = ts, .ms = tms, .us = tus, .ns = tns },
    };

    temporal::DurationParts dp;
    if (!datetime_difference(ctx, start_dt, end_dt, ds, &dp)) return;

    if (!until) {
        // `since` negates the result. read_diff_settings already negated
        // the rounding mode (ceil ↔ floor, halfCeil ↔ halfFloor), so the
        // sign of the integer fields flips here.
        dp.years = -dp.years;
        dp.months = -dp.months;
        dp.weeks = -dp.weeks;
        dp.days = -dp.days;
        dp.hours = -dp.hours;
        dp.minutes = -dp.minutes;
        dp.seconds = -dp.seconds;
        dp.ms = -dp.ms;
        dp.us = -dp.us;
        dp.ns = -dp.ns;
    }

    HObject*? dur_o = alloc_duration(ctx.heap, dp);
    if (catch err = dur_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* dur = dur_o;
    dur.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur);
}


// =====================================================================
// ZonedDateTime: missing getter and method implementations
// =====================================================================

// Helper: resolve wall-time fields from epoch-ns + timezone.
//
// ZonedDateTime construction rejects epochNanoseconds outside +-10^8 days
// (see builtin_temporal_instant_ctor), so big_ns always fits int128 here.
fn void zdt_wall_fields(HObject* zdt, long* wy, long* wm, long* wd,
                         int* wh, int* wmi, int* ws, int* wms, int* wus, int* wns, int* off_sec) {
    hbigint::HBigInt* b = zdt.extra.temporal.big_ns;
    HObject* tz = zdt.extra.temporal.timezone;
    assert(b.fits_int128(), "ZonedDateTime epochNanoseconds out of int128 range");
    int128 total = b.to_int128();
    long epoch_secs = (long)(total / 1000000000);
    long ns_rem = (long)(total - (int128)epoch_secs * 1000000000);
    // Floor toward -inf so a negative epoch carries its sub-second part as
    // a positive remainder on the previous civil second (per
    // GetISOPartsFromEpoch).
    if (ns_rem < 0) {
        epoch_secs -= 1;
        ns_rem += 1000000000;
    }
    String zone = (tz != null) ? timezone_name(tz) : (String)"";
    int off = 0;
    if (zone.len > 0 && zone.ptr != null) off = temporal::tzdb_offset_for_zone_at(zone, epoch_secs);
    long local_secs = epoch_secs + off;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(local_secs);
    *wy = bd.y;
    *wm = bd.m + 1;
    *wd = bd.d;
    *wh = bd.h;
    *wmi = bd.mi;
    *ws = bd.s;
    *wms = (int)(ns_rem / 1000000);
    *wus = (int)((ns_rem % 1000000) / 1000);
    *wns = (int)(ns_rem % 1000);
    *off_sec = off;
}

fn void builtin_temporal_zoneddatetime_proto_year(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wy);
}

fn void builtin_temporal_zoneddatetime_proto_month(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wm);
}

fn void builtin_temporal_zoneddatetime_proto_monthCode(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    char[4] buf;
    buf[0] = 'M';
    buf[1] = (char)('0' + (int)(wm / 10));
    buf[2] = (char)('0' + (int)(wm % 10));
    buf[3] = 0;
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:3]));
}

fn void builtin_temporal_zoneddatetime_proto_day(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wd);
}

fn void builtin_temporal_zoneddatetime_proto_hour(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wh);
}

fn void builtin_temporal_zoneddatetime_proto_minute(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wmi);
}

fn void builtin_temporal_zoneddatetime_proto_second(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(ws);
}

fn void builtin_temporal_zoneddatetime_proto_millisecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wms);
}

fn void builtin_temporal_zoneddatetime_proto_microsecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wus);
}

fn void builtin_temporal_zoneddatetime_proto_nanosecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wns);
}

fn void builtin_temporal_zoneddatetime_proto_offset(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    char[7] buf;
    format_offset_seconds(&buf[0], off);
    buf[6] = 0;
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:6]));
}

fn void builtin_temporal_zoneddatetime_proto_offsetNanoseconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_number((double)off * 1e9);
}

fn void builtin_temporal_zoneddatetime_proto_dayOfWeek(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long epoch_d = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd);
    long dow = ((epoch_d + 10) % 7) + 1;
    if (dow <= 0) dow += 7;
    ctx.result.set_fastint(dow);
}

fn void builtin_temporal_zoneddatetime_proto_dayOfYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long jan1 = temporal::epoch_days_from_civil(wy, 1, 1);
    long cur = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd);
    ctx.result.set_fastint(cur - jan1 + 1);
}

fn void builtin_temporal_zoneddatetime_proto_weekOfYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long doy = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) -
               temporal::epoch_days_from_civil(wy, 1, 1) + 1;
    long dow = ((temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    long week = (doy - dow + 10) / 7;
    if (week < 1) {
        week = iso_weeks_in_year(wy - 1);
    } else if (week > iso_weeks_in_year(wy)) {
        week = 1;
    }
    ctx.result.set_fastint(week);
}

fn void builtin_temporal_zoneddatetime_proto_yearOfWeek(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long doy = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) -
               temporal::epoch_days_from_civil(wy, 1, 1) + 1;
    long dow = ((temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) % 7) + 4) % 7;
    if (dow <= 0) dow += 7;
    long week = (doy - dow + 10) / 7;
    long week_year = wy;
    if (week < 1) { week_year = wy - 1; }
    else if (week > iso_weeks_in_year(wy)) { week_year = wy + 1; }
    ctx.result.set_fastint(week_year);
}

fn void builtin_temporal_zoneddatetime_proto_daysInWeek(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    ctx.result.set_fastint(7);
}

fn void builtin_temporal_zoneddatetime_proto_daysInMonth(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(temporal::days_in_month(wy, (int)wm));
}

fn void builtin_temporal_zoneddatetime_proto_daysInYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long jan1 = temporal::epoch_days_from_civil(wy, 1, 1);
    long dec31 = temporal::epoch_days_from_civil(wy, 12, 31);
    ctx.result.set_fastint(dec31 - jan1 + 1);
}

fn void builtin_temporal_zoneddatetime_proto_monthsInYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    ctx.result.set_fastint(12);
}

fn void builtin_temporal_zoneddatetime_proto_inLeapYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_boolean(temporal::is_leap_year(wy));
}

fn void builtin_temporal_zoneddatetime_proto_hoursInDay(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    String zone = obj.extra.temporal.timezone == null ? "" : timezone_name(obj.extra.temporal.timezone);
    long epoch_secs;
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    if (b.fits_int128()) { epoch_secs = (long)(b.to_int128() / 1000000000); }
    else { double s_d; if (!bigint_to_epoch_number(b, &s_d, ctx)) return; epoch_secs = (long)math::floor(s_d / 1e9); }
    int off_start = 0;
    int off_end = 0;
    if (zone.len > 0 && zone.ptr != null) {
        long day_start_local = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
        long day_start_epoch = day_start_local - off;
        off_start = temporal::tzdb_offset_for_zone_at(zone, day_start_epoch);
        long day_end_epoch = day_start_epoch + 86400;
        off_end = temporal::tzdb_offset_for_zone_at(zone, day_end_epoch);
    }
    double hours = (double)(86400 + off_end - off_start) / 3600.0;
    ctx.result.set_number(hours);
}

fn void builtin_temporal_zoneddatetime_proto_era(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    // The ISO calendar has no eras, so this returns undefined.
    ctx.result.set_undefined();
}

fn void builtin_temporal_zoneddatetime_proto_eraYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    // The ISO calendar has no eras, so this returns undefined.
    ctx.result.set_undefined();
}

fn void builtin_temporal_zoneddatetime_proto_toInstant(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    ((types::HeapHeader*)b).incref();
    HObject*? inst_o = alloc_instant(ctx.heap, b);
    ctx.heap.decref((types::HeapHeader*)b);
    if (catch err = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* inst = inst_o;
    inst.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(inst);
}

fn void builtin_temporal_zoneddatetime_proto_toPlainDateTime(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilDateTime wall_dt;
    wall_dt.date = { .y = wy, .m = wm, .d = wd };
    wall_dt.time = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns };
    HObject*? pdt_o = alloc_plain_datetime(ctx.heap, wall_dt, ctx.heap.temporal_iso_calendar);
    if (catch err = pdt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* pdt = pdt_o;
    pdt.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(pdt);
}

fn void builtin_temporal_zoneddatetime_proto_toPlainTime(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilTime t;
    t.h = wh; t.mi = wmi; t.s = ws; t.ms = wms; t.us = wus; t.ns = wns;
    HObject*? pt_o = alloc_plain_time(ctx.heap, t);
    if (catch err = pt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* pt = pt_o;
    pt.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(pt);
}

fn void builtin_temporal_zoneddatetime_proto_toPlainDate(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilDate d;
    d.y = wy; d.m = wm; d.d = wd;
    HObject*? pd_o = alloc_plain_date(ctx.heap, d, ctx.heap.temporal_iso_calendar);
    if (catch err = pd_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* pd = pd_o;
    pd.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(pd);
}

fn void builtin_temporal_zoneddatetime_proto_startOfDay(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long day_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
    int128 epoch_ns_128 = (int128)day_secs * (int128)1000000000L
        - (int128)off * (int128)1000000000L;
    hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns_128);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
    ((types::HeapHeader*)obj.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, (HString*)obj.extra.temporal.calendar);
}

fn void builtin_temporal_zoneddatetime_proto_getTimeZoneTransition(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) { builtin_throw(ctx, ctx.heap.type_err_proto, "getTimeZoneTransition requires a direction argument"); return; }
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    HObject* tz = obj.extra.temporal.timezone;
    if (tz == null) { ctx.result.set_undefined(); return; }
    // Create an Instant from this ZDT's epoch ns.
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    ((types::HeapHeader*)b).incref();
    HObject*? inst_o = alloc_instant(ctx.heap, b);
    ctx.heap.decref((types::HeapHeader*)b);
    if (catch err = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* inst = inst_o;
    inst.prototype = ctx.heap.temporal_instant_proto;
    // Read direction: a plain string, or a `direction` property on an
    // options bag (GetDirectionOption — Proxy-aware so observers see
    // `get ...direction` / toString). Only this property is read; the
    // other bag fields (year/month/day/...) are ignored per spec.
    TVal* dir_arg = arg_at(ctx, 0);
    String dir = "next";
    TVal dir_tv;
    dir_tv.set_undefined();
    if (dir_arg.is_string()) {
        HString* ds = (HString*)dir_arg.get_heapptr();
        // ToString(Symbol) throws TypeError; a Symbol-typed argument must not
        // be treated as a direction name.
        if (ds != null && ds.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert a Symbol value to a string");
            return;
        }
        if (ds != null) dir = (String)ds.get_cstr()[:ds.blen];
    } else if (dir_arg.is_object() && dir_arg.get_heapptr() != null) {
        HObject* dbag = (HObject*)dir_arg.get_heapptr();
        dir_tv = prop_or_undefined_pa(ctx, dbag, "direction");
        if (ctx.should_throw) return;
        if (dir_tv.is_undefined()) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "direction property is required");
            return;
        }
        HString* ds = builtin_to_string_vm(ctx, &dir_tv);
        if (ctx.should_throw) return;
        if (ds == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "direction must be a string");
            return;
        }
        dir = (String)ds.get_cstr()[:ds.blen];
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "direction must be a string or object");
        return;
    }
    if (dir != "next" && dir != "previous") {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid direction");
        return;
    }
    // Delegate to TimeZone method.
    TVal saved_this = ctx.this_val;
    TVal inst_tv;
    inst_tv.set_object(inst);
    ctx.this_val.set_object(tz);
    ctx.regs[ctx.base_reg + 0] = inst_tv;
    ctx.argc = 1;
    if (dir == "next") {
        builtin_temporal_timezone_proto_getNextTransition(ctx);
    } else {
        builtin_temporal_timezone_proto_getPreviousTransition(ctx);
    }
    ctx.this_val = saved_this;
    if (ctx.result.is_object() && ctx.result.get_heapptr() != null) {
        HObject* res_inst = (HObject*)ctx.result.get_heapptr();
        if (res_inst.get_class() == hobject::ObjClass.TEMPORAL_INSTANT) {
            hbigint::HBigInt* trans_ns = res_inst.extra.temporal.big_ns;
            ((types::HeapHeader*)trans_ns).incref();
            ((types::HeapHeader*)tz).incref();
            zdt_from_parts(ctx, trans_ns, tz, (HString*)obj.extra.temporal.calendar);
        }
    }
}

fn void builtin_temporal_zoneddatetime_proto_valueOf(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.ZonedDateTime cannot be converted to a primitive value");
}

fn void builtin_temporal_zoneddatetime_proto_withPlainTime(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilTime new_time;
    new_time.h = 0; new_time.mi = 0; new_time.s = 0;
    new_time.ms = 0; new_time.us = 0; new_time.ns = 0;
    if (ctx.argc >= 1) {
        TVal* arg = arg_at(ctx, 0);
        if (!arg.is_undefined()) {
            if (arg.is_object() && arg.get_heapptr() != null) {
                HObject* bag = (HObject*)arg.get_heapptr();
                if (!bag_to_time_fields(ctx, bag, false, new_time, &new_time, true)) {
                    Vm* v = (Vm*)ctx.vm;
                    if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
                    return;
                }
                // ToTemporalTime regulates the bag's fields with the default
                // constrain overflow, which clamps out-of-range values and
                // collapses a leap 60 to 59 (a bag cannot carry a leap second).
                temporal::CivilTime valid_t;
                if (!fields_to_valid_time(ctx, new_time, &valid_t, temporal::OverflowKind.CONSTRAIN, false)) return;
                new_time = valid_t;
            } else if (arg.is_string()) {
                HString* s = (HString*)arg.get_heapptr();
                if (s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "withPlainTime: invalid string"); return; }
                if (s.is_symbol()) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "withPlainTime: symbol cannot be converted");
                    return;
                }
                char[] text = s.get_cstr()[:s.blen];
                temporal::ParsedIsoDateTime p;
                bool ok = temporal::parse_iso_time_string(text, &p);
                if (!ok) {
                    ok = temporal::parse_iso_date_string(text, &p);
                    if (!ok || !p.has_time) {
                        builtin_throw(ctx, ctx.heap.range_err_proto, "withPlainTime: invalid ISO time string");
                        return;
                    }
                }
                if (p.offset_kind == temporal::OffsetKind.Z) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "withPlainTime: Z designator not valid");
                    return;
                }
                new_time.h = p.hour; new_time.mi = p.minute; new_time.s = p.second;
                new_time.ms = (int)(p.nanos / 1_000_000);
                new_time.us = (int)((p.nanos / 1000) % 1000);
                new_time.ns = (int)(p.nanos % 1000);
                if (!temporal::is_valid_time((int)new_time.h, (int)new_time.mi, (int)new_time.s, (int)new_time.ms, (int)new_time.us, (int)new_time.ns)) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "withPlainTime: time is out of range");
                    return;
                }
            } else {
                builtin_throw(ctx, ctx.heap.type_err_proto, "withPlainTime: argument must be undefined, string, or object");
                return;
            }
        }
    }
    long day_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400
        + (long)new_time.h * 3600 + (long)new_time.mi * 60 + (long)new_time.s;
    long frac_ns = (long)new_time.ms * 1000000 + (long)new_time.us * 1000 + (long)new_time.ns;
    int128 epoch_ns_128 = (int128)day_secs * (int128)1000000000L + (int128)frac_ns
        - (int128)off * (int128)1000000000L;
    // The combined date+time instant must sit within the representable epoch
    // range; a wall date at the upper edge combined with a later time-of-day,
    // or an early date with an offset, can push the instant past ±8.64e21.
    int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
    if (epoch_ns_128 > ns_limit || epoch_ns_128 < -ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
        return;
    }
    hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns_128);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
    ((types::HeapHeader*)obj.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, (HString*)obj.extra.temporal.calendar);
}

fn void builtin_temporal_zoneddatetime_proto_round(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) { builtin_throw(ctx, ctx.heap.type_err_proto, "round requires an options argument"); return; }
    TVal* arg = arg_at(ctx, 0);
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();

    TemporalUnit smallest_unit;
    double rounding_increment = 1;
    TemporalRoundMode rounding_mode = TemporalRoundMode.HALF_EXPAND;

    if (arg.is_string()) {
        HString* s = builtin_to_string_vm(ctx, arg);
        if (ctx.should_throw) return;
        if (!parse_unit_str(s.get_cstr()[:s.blen], &smallest_unit) || smallest_unit < TemporalUnit.DAY) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit for round");
            return;
        }
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* opts = (HObject*)arg.get_heapptr();
        TVal ri_v = prop_or_undefined_pa(ctx, opts, "roundingIncrement");
        if (ctx.should_throw) return;
        if (!ri_v.is_undefined()) {
            Vm* v = (Vm*)ctx.vm;
            double ri_val = vm::vm_to_number(v, &ri_v);
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            if (math::is_nan(ri_val) || math::is_inf(ri_val)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a positive integer");
                return;
            }
            rounding_increment = math::floor(ri_val);
            if (rounding_increment < 1) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a positive integer");
                return;
            }
        }

        TVal rm_v = prop_or_undefined_pa(ctx, opts, "roundingMode");
        if (ctx.should_throw) return;
        if (!rm_v.is_undefined()) {
            HString* rm_str = builtin_to_string_vm(ctx, &rm_v);
            if (ctx.should_throw) return;
            if (!parse_rm_str(rm_str.get_cstr()[:rm_str.blen], &rounding_mode)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return;
            }
        }

        TVal su_v = prop_or_undefined_pa(ctx, opts, "smallestUnit");
        if (ctx.should_throw) return;
        if (su_v.is_undefined()) { builtin_throw(ctx, ctx.heap.range_err_proto, "round requires a smallestUnit option"); return; }
        HString* su_str = builtin_to_string_vm(ctx, &su_v);
        if (ctx.should_throw) return;
        if (!parse_unit_str(su_str.get_cstr()[:su_str.blen], &smallest_unit) || smallest_unit < TemporalUnit.DAY) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit for round");
            return;
        }
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "round options must be an object");
        return;
    }

    if (smallest_unit == TemporalUnit.DAY && rounding_increment != 1) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
        return;
    }
    if (!validate_rounding_increment(ctx, smallest_unit, rounding_increment)) return;

    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);

    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    long epoch_secs;
    long ns_rem;
    if (b.fits_int128()) {
        int128 total = b.to_int128();
        epoch_secs = (long)(total / 1000000000);
        ns_rem = (long)(total - (int128)epoch_secs * 1000000000);
    } else {
        double s_d;
        if (!bigint_to_epoch_number(b, &s_d, ctx)) return;
        epoch_secs = (long)math::floor(s_d / 1e9);
        ns_rem = 0;
    }

    long result_secs;
    long result_ns;

    if (smallest_unit == TemporalUnit.DAY) {
        // roundingIncrement is fixed at 1 for "day" (checked above), so this
        // rounds to the nearer local calendar-day boundary.
        long local_secs = epoch_secs + woff;
        long day_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
        // Validate day boundaries: GetStartOfDay converts midnight local to
        // UTC via startNs = day_secs - woff.  Both the current day's start
        // and the next day's start must lie in the representable range.
        int128 start_ns = ((int128)day_secs - (int128)woff) * 1000000000;
        int128 end_ns = ((int128)day_secs + 86400 - (int128)woff) * 1000000000;
        int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
        if (start_ns <= -ns_limit || start_ns >= ns_limit || end_ns <= -ns_limit || end_ns >= ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "rounding pushed the datetime out of range");
            return;
        }
        double day_frac = (double)(local_secs - day_secs) + (double)ns_rem / 1e9;
        double rounded_days = round_num_to_incr(day_frac / 86400.0, 1, rounding_mode);
        result_secs = day_secs + (long)rounded_days * 86400 - woff;
        result_ns = 0;
    } else {
        long divisor = unit_ns_divisor(smallest_unit);
        long incr_ns = divisor * (long)rounding_increment;
        // The spec rounds the nanoseconds within the local calendar day
        // (always non-negative), not the epoch nanoseconds.  Compute the
        // day start in local-ns, then round the offset from it.
        long day_start_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
        int128 local_ns = (int128)(epoch_secs + woff) * 1000000000 + (int128)ns_rem;
        int128 day_start_ns = (int128)day_start_secs * 1000000000;
        int128 ns_in_day = local_ns - day_start_ns;
        int128 incr = (int128)incr_ns;
        int128 q = ns_in_day / incr;
        int128 r = ns_in_day - q * incr;
        if (r != 0) {
            switch (rounding_mode) {
                case TemporalRoundMode.TRUNC:
                case TemporalRoundMode.FLOOR: break;
                case TemporalRoundMode.EXPAND:
                case TemporalRoundMode.CEIL: q += 1; break;
                default: {
                    int128 twice = r * 2;
                    if (twice > incr) {
                        q += 1;
                    } else if (twice == incr) {
                        switch (rounding_mode) {
                            case TemporalRoundMode.HALF_TRUNC:
                            case TemporalRoundMode.HALF_FLOOR: break;
                            case TemporalRoundMode.HALF_EXPAND:
                            case TemporalRoundMode.HALF_CEIL: q += 1; break;
                            case TemporalRoundMode.HALF_EVEN: if ((q & 1) != 0) q += 1; break;
                            default: break;
                        }
                    }
                    break;
                }
            }
        }
        int128 rounded_ns_in_day = q * incr;
        int128 result_local_ns = day_start_ns + rounded_ns_in_day;
        int128 total_i128 = result_local_ns - (int128)woff * 1000000000;
        int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
        if (total_i128 >= ns_limit || total_i128 <= -ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "rounding pushed the datetime out of range");
            return;
        }
        hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, total_i128);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
        ((types::HeapHeader*)obj.extra.temporal.timezone).incref();
        zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, (HString*)obj.extra.temporal.calendar);
        return;
    }

    // Combine result_secs and result_ns as a BigInt to avoid the 2^53
    // ceiling on double precision. `(double)result_secs * 1e9` rounds
    // values past ~1973 by 1 ns or more.
    int128 total_i128 = (int128)result_secs * 1000000000 + (int128)result_ns;
    int128 ns_limit = (int128)86400L * (int128)100000000L * (int128)1000000000L;
    if (total_i128 >= ns_limit || total_i128 <= -ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "rounding pushed the datetime out of range");
        return;
    }
    hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, total_i128);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
    ((types::HeapHeader*)obj.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, (HString*)obj.extra.temporal.calendar);
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
    if (!register_string_proto_method(proto, heap, "toLocaleString", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_TOLOCALESTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "withTimeZone", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_WITHTIMEZONE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "withCalendar", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_WITHCALENDAR.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_SINCE.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_ZONEDDATETIME_FROM.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "compare", Builtin.TEMPORAL_ZONEDDATETIME_COMPARE.ordinal)) return false;
    // New getters.
    if (!register_proto_getter_accessor(proto, heap, "year", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_YEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "month", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_MONTH.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "monthCode", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_MONTHCODE.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "day", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_DAY.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "hour", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_HOUR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "minute", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_MINUTE.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "second", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_SECOND.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "millisecond", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_MILLISECOND.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "microsecond", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_MICROSECOND.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "nanosecond", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_NANOSECOND.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "offset", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_OFFSET.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "offsetNanoseconds", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_OFFSETNANOSECONDS.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "dayOfWeek", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_DAYOFWEEK.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "dayOfYear", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_DAYOFYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "weekOfYear", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_WEEKOFYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "yearOfWeek", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_YEAROFWEEK.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInWeek", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_DAYSINWEEK.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInMonth", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_DAYSINMONTH.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "daysInYear", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_DAYSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "monthsInYear", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_MONTHSINYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "inLeapYear", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_INLEAPYEAR.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "hoursInDay", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_HOURSINDAY.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "era", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_ERA.ordinal)) return false;
    if (!register_proto_getter_accessor(proto, heap, "eraYear", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_ERAYEAR.ordinal)) return false;
    // New methods.
    if (!register_string_proto_method(proto, heap, "round", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_ROUND.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "withPlainTime", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_WITHPLAIN_TIME.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toInstant", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_TOINSTANT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toPlainDateTime", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_TOPLAINDATETIME.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toPlainTime", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_TOPLAINTIME.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toPlainDate", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_TOPLAINDATE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "startOfDay", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_STARTOFDAY.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "getTimeZoneTransition", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_GETTIMEZONETRANSITION.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", Builtin.TEMPORAL_ZONEDDATETIME_PROTO_VALUEOF.ordinal)) return false;

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
    // Sub-minute precision: optional `:SS[.fffffffff]`. Trailing zeros in the
    // fraction are forbidden (per spec), enforced by the caller when this is a
    // time-zone identifier. Only round to whole seconds here.
    int sec = 0;
    if (*i < len && text[*i] == ':') {
        *i += 1;
        if (!temporal::parse_two_digits(text, i, &sec)) return false;
        if (sec > 59) return false;
        // Optional fraction (1-9 digits). The last digit must be non-zero
        // for time-zone identifiers; we just store it rounded to the nearest
        // second so the offset stays in whole seconds here.
        if (*i < len && text[*i] == '.') {
            *i += 1;
            usz fstart = *i;
            while (*i < len && temporal::digit_at(text, *i) >= 0 && *i - fstart < 9) *i += 1;
            if (*i == fstart) return false;
            // TimeZoneOffsetString allows at most 9 fraction digits.
            if (*i < len && temporal::digit_at(text, *i) >= 0) return false;
        }
    }
    long total = (long)h * 3600 + (long)mi * 60 + (long)sec;
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
                       bool* offset_known, String* out_zone_name, bool* out_zone_known,
                       bool* out_is_z) {
    *offset_known = false;
    *out_zone_known = false;
    *out_is_z = false;
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
        // Sub-minute forms (`:SS` or `.frac`) are not valid time-zone
        // identifiers per spec; reject them.
        for (usz chk = 0; chk < bracket.len; chk++) {
            if (bracket[chk] == '.' || bracket[chk] == ',') return false;
        }
        // If the bracket starts with `+`/`-` and contains more than one
        // `:`, it is a sub-minute form (e.g. `+01:30:45`); reject.
        if (bracket.len > 0 && (bracket[0] == '+' || bracket[0] == '-')) {
            int colons = 0;
            for (usz chk = 0; chk < bracket.len; chk++) {
                if (bracket[chk] == ':') colons++;
            }
            if (colons >= 2) return false;
        }
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
    // or a ±HH:MM offset. Anything else (e.g. bare date-time without zone,
    // or sub-minute offset like `2021-08-19T17:30-07:00:00.1`) is a
    // RangeError.
    if (has_iso_prefix) {
        long off = 0;
        if (prefix_end < text.len && parse_offset_only(text, &prefix_end, &off)) {
            if (prefix_end != text.len) return false;
            *out_is_z = (text[prefix_end - 1] == 'Z' || text[prefix_end - 1] == 'z');
            // Reject sub-minute offsets: scan the offset tail for `.` or `,`
            // (fractional separator) or for a third `:` (the seconds tier).
            // `prefix_end` is the position right after the offset, so the
            // offset itself lives in `text[time_end..prefix_end]`. We don't
            // have `time_end` tracked here, but the only thing after `time_end`
            // and before `prefix_end` is the offset (and possibly trailing
            // junk we already rejected with `prefix_end != text.len`).
            // Use the time zone name path's check: count colons in the
            // tail and reject when the offset has 2+.
            int tail_colons = 0;
            // Walk backwards from prefix_end to find the offset's start
            // (the first non-`±HH:MM:SS[.frac]` char).
            // Cheaper: re-walk from the end and detect a third `:` at the
            // offset tier. The date-time time portion has the form
            // `HH:MM:SS[.frac]`, so there are exactly 2 colons. Anything
            // beyond the time tier (after the time's `T`) is the offset
            // and adds 1 or 2 colons. Sub-minute offset = 2 colons
            // (`±HH:MM:SS`); reject when offset has 2 colons.
            // Walk from prefix_end backward to find `:T`-style boundary.
            // Simpler approximation: count colons in the entire `prefix_end..text.len`
            // tail; the time part is the only thing before the offset,
            // and our offset parser already knows the offset ends here.
            // For now, scan the entire tail starting at `prefix_end` minus
            // the offset's start.
            // Concrete approach: find the time separator (`T`/`t`/` `) in
            // the text, walk forward, count colons in the offset suffix
            // (the part from there to the end, up to but not including any
            // optional bracket).
            usz k = 0;
            while (k < text.len && text[k] != 'T' && text[k] != 't' && text[k] != ' ') k++;
            if (k < text.len) {
                // After the time separator, count colons in the time
                // portion (we expect exactly 2) and in the offset portion.
                // We approximate: any third `:` from there to the end is
                // the offset's `:SS` tier.
                int cs = 0;
                for (usz j = k + 1; j < text.len; j++) {
                    if (text[j] == ':') cs++;
                }
                // Subtract 2 for the time portion itself; if anything
                // remains, the offset has more than `±HH:MM`.
                if (cs > 2) return false;
            }
            *out_offset_sec = off;
            *offset_known = true;
            return true;
        }
        return false;
    }

    // Otherwise the input is a bare zone/offset token. A UTC-offset zone
    // identifier is minute precision only: `:SS` or a fractional part makes
    // it a sub-minute offset, which parse_offset_only accepts but which is
    // not a valid time-zone identifier.
    if (text.len > 0 && (text[0] == '+' || text[0] == '-')) {
        int colons = 0;
        for (usz chk = 0; chk < text.len; chk++) {
            if (text[chk] == '.' || text[chk] == ',') return false;
            if (text[chk] == ':') colons++;
        }
        if (colons > 1) return false;
    }
    usz saved = 0;
    long off2 = 0;
    if (parse_offset_only(text, &saved, &off2)) {
        if (saved != text.len) return false;
        *out_is_z = (text[0] == 'Z' || text[0] == 'z');
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
    bool unused_is_z = false;
    if (!now_resolve_tz(ctx, text, &off, &off_known, &zone, &zone_known, &unused_is_z)) {
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
    bool unused_is_z = false;
    if (!is_default) {
        if (!now_resolve_tz(ctx, text, &off2, &off_known, &zone, &zone_known, &unused_is_z)) {
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