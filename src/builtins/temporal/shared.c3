// Temporal built-ins: helpers shared across every Temporal type.
//
// Coercion from JS values and property bags into the library's value types,
// object allocation, brand checks, and the options-bag readers (overflow,
// rounding mode, relativeTo, difference settings). Everything here touches
// BuiltinContext, HObject or TVal -- the pure arithmetic lives in
// boomkat::lib::temporal.
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
    // Sub-second fields stored as float64 bit patterns so values exceeding
    // int64 range survive round-tripping through the HObject long slots.
    // Normalize -0.0 to 0.0: IEEE 754 arithmetic (negation, subtraction)
    // can produce -0.0 for zero sub-second fields, but the spec treats
    // Duration fields as mathematical values where 0 has no sign.
    ulong ms_bits = bitcast(d.ms, ulong);
    ulong us_bits = bitcast(d.us, ulong);
    ulong ns_bits = bitcast(d.ns, ulong);
    if ((ms_bits & 0x7FFFFFFFFFFFFFFF) == 0) ms_bits = 0;
    if ((us_bits & 0x7FFFFFFFFFFFFFFF) == 0) us_bits = 0;
    if ((ns_bits & 0x7FFFFFFFFFFFFFFF) == 0) ns_bits = 0;
    obj.extra.temporal.long_h = (long)ms_bits;
    obj.extra.temporal.long_i = (long)us_bits;
    obj.extra.temporal.long_j = (long)ns_bits;
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
    // Sub-second fields stored as float64 bit patterns; bitcast back.
    d.ms      = bitcast((ulong)obj.extra.temporal.long_h, double);
    d.us      = bitcast((ulong)obj.extra.temporal.long_i, double);
    d.ns      = bitcast((ulong)obj.extra.temporal.long_j, double);
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
    if (!temporal::parse_offset_only(otxt, &pi, &off_sec) || pi != otxt.len) {
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
        d = math::trunc(d);
        if (d < 1) {
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

