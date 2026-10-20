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


// ============================================================================
// Shared helpers
// ============================================================================

// Temporal toLocaleString (ECMA-402): format `this` through a DateTimeFormat
// built from (locales, options). Returns false when the build has no Intl
// date formatting, and the caller falls back to toString.
fn bool temporal_locale_string(BuiltinContext* ctx, int required) {
    $if $feat(INTL) && !$feat(NO_INTL_DATE):
        IntlDateState state;
        if (!intl_date_options(ctx, &state, builtin_arg(ctx, 0), builtin_arg(ctx, 1), required, required)) return true;
        intl_date_result(ctx, &state, ctx.regs[ctx.base_reg - 1], false);
        return true;
    $else
        return false;
    $endif
}

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

// Returns a new Temporal object, or throws for a failed allocation.
macro void @temporal_result(BuiltinContext* ctx, #alloc, HObject* proto) {
    HObject*? obj = #alloc;
    if (catch obj) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    ctx.heap.set_prototype(obj, proto);
    ctx.result_object(obj);
}

fn void plain_date_result(BuiltinContext* ctx, temporal::CivilDate iso, temporal::CalendarId cal) {
    partial_date_result(ctx, DATE, iso, cal);
}

// The class of a PlainDate, PlainYearMonth or PlainMonthDay, which all store an ISO date.
fn ObjClass fields_type_class(temporal::FieldsType type) {
    switch (type) {
        case DATE: return TEMPORAL_PLAIN_DATE;
        case YEAR_MONTH: return TEMPORAL_PLAIN_YEARMONTH;
        case MONTH_DAY: return TEMPORAL_PLAIN_MONTHDAY;
    }
}

fn HObject* fields_type_proto(Heap* hp, temporal::FieldsType type) {
    switch (type) {
        case DATE: return hp.temporal_plain_date_proto;
        case YEAR_MONTH: return hp.temporal_plain_yearmonth_proto;
        case MONTH_DAY: return hp.temporal_plain_monthday_proto;
    }
}

// The result of an operation on a PlainDate, PlainYearMonth or PlainMonthDay.
fn void partial_date_result(BuiltinContext* ctx, temporal::FieldsType type, temporal::CivilDate iso, temporal::CalendarId cal) {
    @temporal_result(ctx, alloc_plain_date(ctx.heap, iso, cal, fields_type_class(type)), fields_type_proto(ctx.heap, type));
}

// A PlainYearMonth keeps the reference day in the day slot and a PlainMonthDay the reference year in the
// year slot; neither is a separate field.
fn HObject*? alloc_plain_date(Heap* hp, temporal::CivilDate d, temporal::CalendarId calendar, ObjClass klass = TEMPORAL_PLAIN_DATE) {
    HObject*? raw = hp.alloc_object(klass);
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
fn HObject*? alloc_plain_datetime(Heap* hp, temporal::CivilDateTime dt, temporal::CalendarId calendar) {
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

tlocal TVal missing_arg @local;

// The argument at `idx`, undefined past the arguments passed.
fn TVal* arg_at(BuiltinContext* ctx, int idx) {
    if (idx < ctx.argc) return &ctx.regs[ctx.base_reg + idx];
    missing_arg.set_undefined();
    return &missing_arg;
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
fn bool read_overflow(BuiltinContext* ctx, TVal* options, temporal::OverflowKind* out) {
    *out = temporal::OverflowKind.CONSTRAIN;
    if (options == null || options.is_undefined()) return true;
    if (!options.is_object() || options.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    HObject* opts = (HObject*)options.get_heapptr();
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


// GetTemporalDisambiguationOption as the mode tzdb_resolve_local takes: 0 compatible, 1 earlier,
// 2 later, 3 reject.
fn bool read_disambiguation(BuiltinContext* ctx, TVal* options, int* out) {
    *out = 0;
    if (options.is_undefined()) return true;
    if (!options.is_object() || options.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    TVal val = prop_or_undefined_pa(ctx, (HObject*)options.get_heapptr(), "disambiguation");
    if (ctx.should_throw) return false;
    if (val.is_undefined()) return true;
    HString* str = builtin_to_string_vm(ctx, &val);
    if (ctx.should_throw) return false;
    switch (str.get_cstr()[:str.blen]) {
        case "compatible": return true;
        case "earlier": *out = 1;
        case "later": *out = 2;
        case "reject": *out = 3;
        default:
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid disambiguation");
            return false;
    }
    return true;
}


// Missing fields retain the receiver's time for with(); from() requires at least one field.
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
        if (!temporal::is_valid_duration(out)) {
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
        // Sub-second fields are stored as double so values exceeding int64
        // range (e.g. microseconds: 4.5e21) survive round-tripping.
        if (k >= 7) {
            switch (k) {
                case 7: out.ms = val; break;
                case 8: out.us = val; break;
                default: out.ns = val; break;
            }
        } else {
            long whole = (long)math::trunc(val);
            switch (k) {
                case 0: out.years = whole; break;
                case 1: out.months = whole; break;
                case 2: out.weeks = whole; break;
                case 3: out.days = whole; break;
                case 4: out.hours = whole; break;
                case 5: out.minutes = whole; break;
                default: out.seconds = whole; break;
            }
        }
    }
    if (!any_field) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "duration property bag has no recognized fields");
        return false;
    }
    if (!temporal::is_valid_duration(out)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration is out of range");
        return false;
    }
    return true;
}
