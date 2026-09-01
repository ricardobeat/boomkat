// Temporal.PlainTime bindings: constructor, statics, getters, and prototype
// methods.
module boomkat::builtins @feat(!NO_TEMPORAL);

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
    switch ((TemporalBuiltin)((uint)(*(ctx.callee_obj.extra_ptr())).func.builtin_fn_index - TEMPORAL_BASE)) {
        case TemporalBuiltin.PLAIN_TIME_PROTO_HOUR:       val = (double)obj.extra.temporal.long_a; break;
        case TemporalBuiltin.PLAIN_TIME_PROTO_MINUTE:     val = (double)obj.extra.temporal.long_b; break;
        case TemporalBuiltin.PLAIN_TIME_PROTO_SECOND:     val = (double)obj.extra.temporal.long_c; break;
        case TemporalBuiltin.PLAIN_TIME_PROTO_MILLISECOND: val = (double)obj.extra.temporal.long_d; break;
        case TemporalBuiltin.PLAIN_TIME_PROTO_MICROSECOND: val = (double)obj.extra.temporal.long_e; break;
        case TemporalBuiltin.PLAIN_TIME_PROTO_NANOSECOND:  val = (double)obj.extra.temporal.long_f; break;
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
    temporal::TemporalRoundMode rm = temporal::TemporalRoundMode.TRUNC;
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
        unit_ns = temporal::NS_PER_MIN;
    } else if (ns_digits >= 0 && ns_digits < 9) {
        unit_ns = temporal::ns_pow10(9 - ns_digits);
    } else if (ns_digits == 9) {
        unit_ns = 1;
    }
    if (unit_ns > 1) {
        long total = temporal::round_long_ns(temporal::civil_time_to_ns(t), unit_ns, rm);
        if (total >= temporal::NS_PER_DAY) total -= temporal::NS_PER_DAY;
        t = temporal::civil_time_from_ns(total);
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
    int128 cur_ns = (int128)cur.h * temporal::NS_PER_HOUR + (int128)cur.mi * temporal::NS_PER_MIN +
                    (int128)cur.s * temporal::NS_PER_SEC + (int128)cur.ms * temporal::NS_PER_MS +
                    (int128)cur.us * 1000L + (int128)cur.ns;
    int128 dur_ns = (int128)dur.hours * temporal::NS_PER_HOUR + (int128)dur.minutes * temporal::NS_PER_MIN +
                    (int128)dur.seconds * temporal::NS_PER_SEC + (int128)dur.ms * temporal::NS_PER_MS +
                    (int128)dur.us * 1000L + (int128)dur.ns;
    int128 sum_ns = subtract ? (cur_ns - dur_ns) : (cur_ns + dur_ns);
    int128 day_ns = (int128)temporal::NS_PER_DAY;
    int128 rem_ns = sum_ns % day_ns;
    if (rem_ns < 0) rem_ns += day_ns;

    temporal::CivilTime result;
    result.h = (int)(rem_ns / temporal::NS_PER_HOUR);
    rem_ns %= temporal::NS_PER_HOUR;
    result.mi = (int)(rem_ns / temporal::NS_PER_MIN);
    rem_ns %= temporal::NS_PER_MIN;
    result.s = (int)(rem_ns / temporal::NS_PER_SEC);
    rem_ns %= temporal::NS_PER_SEC;
    result.ms = (int)(rem_ns / temporal::NS_PER_MS);
    rem_ns %= temporal::NS_PER_MS;
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
    if (!read_diff_settings(ctx, 1, temporal::TemporalUnit.HOUR, temporal::TemporalUnit.NANOSECOND,
                            temporal::TemporalUnit.HOUR, temporal::TemporalUnit.NANOSECOND, false, &ds)) return;

    temporal::CivilTime a = plain_time_value(obj);
    temporal::CivilTime b = plain_time_value(other);
    temporal::CivilTime start = flipped ? b : a;
    temporal::CivilTime end   = flipped ? a : b;

    // The delta is under 24 hours, so it fits a long and needs no BigInt.
    long start_ns = ((long)start.h * 3600 + (long)start.mi * 60 + (long)start.s) * temporal::NS_PER_SEC
                  + (long)start.ms * temporal::NS_PER_MS + (long)start.us * 1000L + (long)start.ns;
    long end_ns   = ((long)end.h  * 3600 + (long)end.mi  * 60 + (long)end.s ) * temporal::NS_PER_SEC
                  + (long)end.ms  * temporal::NS_PER_MS + (long)end.us  * 1000L + (long)end.ns;
    long delta = end_ns - start_ns;

    long incr_ns = temporal::unit_ns_divisor(ds.smallest) * (long)ds.increment;
    if (incr_ns > 1) delta = temporal::round_long_ns(delta, incr_ns, ds.mode);

    temporal::DurationParts dur = temporal::time_ns_split(delta, ds.largest);

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
    temporal::TemporalUnit smallest_unit = temporal::TemporalUnit.NANOSECOND;
    bool smallest_given = false;
    double rounding_increment = 1;
    temporal::TemporalRoundMode rounding_mode = temporal::TemporalRoundMode.HALF_EXPAND;
    if (!round_to.is_object() || round_to.get_heapptr() == null) {
        // String shorthand: smallestUnit = the string.
        if (round_to.is_string() || (round_to.is_object() && round_to.get_heapptr() != null && !((HObject*)round_to.get_heapptr()).flags.callable)) {
            HString* s = builtin_to_string_vm(ctx, round_to);
            if (ctx.should_throw) return;
            char[] str = s.get_cstr()[:s.blen];
            if (!temporal::parse_unit_str(str, &smallest_unit) || smallest_unit < temporal::TemporalUnit.HOUR) {
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
            rounding_increment = math::trunc(ri_val);
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
            if (!temporal::parse_rm_str(s.get_cstr()[:s.blen], &rounding_mode)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return;
            }
        }
        TVal su_v = prop_or_undefined_pa(ctx, opts, "smallestUnit");
        if (ctx.should_throw) return;
        if (!su_v.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &su_v);
            if (ctx.should_throw) return;
            if (!temporal::parse_unit_str(s.get_cstr()[:s.blen], &smallest_unit) || smallest_unit < temporal::TemporalUnit.HOUR) {
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
    long max_incr = temporal::max_round_incr(smallest_unit);
    if (max_incr > 0 && (rounding_increment > (double)max_incr
        || (double)max_incr / rounding_increment != math::floor((double)max_incr / rounding_increment)
        || rounding_increment == (double)max_incr)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
        return;
    }

    long divisor = temporal::unit_ns_divisor(smallest_unit);
    long incr_ns = divisor * (long)rounding_increment;
    // PlainTime stores its fields directly. Build the total ns value:
    long h = self.extra.temporal.long_a;
    long m = self.extra.temporal.long_b;
    long s = self.extra.temporal.long_c;
    long ms = self.extra.temporal.long_d;
    long us = self.extra.temporal.long_e;
    long ns = self.extra.temporal.long_f;
    long total_ns = h * temporal::NS_PER_HOUR + m * temporal::NS_PER_MIN + s * temporal::NS_PER_SEC
                  + ms * temporal::NS_PER_MS + us * 1000L + ns;
    long rounded = temporal::round_long_ns(total_ns, incr_ns, rounding_mode);
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(rounded / temporal::NS_PER_SEC);
    int rh = bd.h;
    long rem = rounded - (rounded / temporal::NS_PER_SEC) * temporal::NS_PER_SEC;
    int rmin = bd.mi;
    int rs = bd.s;
    int rms = (int)(rem / temporal::NS_PER_MS); rem %= temporal::NS_PER_MS;
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

