// Temporal.PlainDateTime bindings: constructor, statics, getters, and
// prototype methods, including the shared date-time difference and rounding
// paths that PlainDate and ZonedDateTime delegate into.
module boomkat::builtins @feat(TEMPORAL);

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

    temporal::CalendarId calendar = temporal::CalendarId.ISO8601;
    if (ctx.argc >= 10 && !arg_at(ctx, 9).is_undefined()) {
        if (!calendar_ctor_arg(ctx, arg_at(ctx, 9), &calendar)) return;
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
    ctx.heap.set_prototype(obj, builtin_proto_from_new_target(ctx, ctx.heap.temporal_plain_datetime_proto));
    ctx.result_object(obj);
}

fn void builtin_temporal_plain_datetime_from(BuiltinContext* ctx) {
    temporal::CivilDateTime iso;
    temporal::CalendarId cal;
    if (to_temporal_datetime(ctx, arg_at(ctx, 0), &iso, &cal, arg_at(ctx, 1))) plain_datetime_result(ctx, iso, cal);
}

fn void plain_datetime_result(BuiltinContext* ctx, temporal::CivilDateTime iso, temporal::CalendarId cal) {
    @temporal_result(ctx, alloc_plain_datetime(ctx.heap, iso, cal), ctx.heap.temporal_plain_datetime_proto);
}

// ISODateTimeWithinLimits, throwing a RangeError for false.
fn bool datetime_within_limits(BuiltinContext* ctx, temporal::CivilDateTime dt) {
    if (temporal::is_valid_iso_datetime(dt.date.y, dt.date.m, dt.date.d, dt.time.h, dt.time.mi, dt.time.s,
                                        dt.time.ms, dt.time.us, dt.time.ns)) return true;
    builtin_throw(ctx, ctx.heap.range_err_proto, "date-time is out of range");
    return false;
}

// ToTemporalDateTime: the ISO date-time and calendar of `item`, reading the overflow of `options`.
fn bool to_temporal_datetime(BuiltinContext* ctx, TVal* item, temporal::CivilDateTime* iso, temporal::CalendarId* cal, TVal* options = null) {
    temporal::OverflowKind overflow;
    if (item.is_object()) {
        HObject* o = (HObject*)item.get_heapptr();
        switch (o.get_class()) {
            case TEMPORAL_PLAIN_DATETIME:
                *iso = plain_datetime_value(o);
            case TEMPORAL_PLAIN_DATE:
                *iso = { .date = plain_date_value(o) };
            case TEMPORAL_ZONEDDATETIME:
                *iso = zdt_wall_datetime(o);
            default:
                temporal::CalendarFields fields;
                return bag_calendar(ctx, o, cal)
                    && prepare_calendar_fields(ctx, *cal, o, DATE_FIELD_NAMES | TIME_FIELD_NAMES, 0, false, &fields)
                    && read_overflow(ctx, options, &overflow)
                    && interpret_datetime_fields(ctx, *cal, &fields, overflow, iso);
        }
        *cal = o.extra.temporal.calendar;
        return read_overflow(ctx, options, &overflow) && datetime_within_limits(ctx, *iso);
    }
    HString* s = item.is_string() ? (HString*)item.get_heapptr() : null;
    if (s == null || s.is_symbol()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "a PlainDateTime needs a string or an object");
        return false;
    }
    // TemporalDateTimeString[~Zoned] has no Z designator; a numeric offset is dropped.
    temporal::ParsedIsoDateTime p;
    if (!temporal::parse_iso_date_string(s.get_cstr()[:s.blen], &p) || p.offset_kind == temporal::OffsetKind.Z) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO date-time string");
        return false;
    }
    if (!read_overflow(ctx, options, &overflow)) return false;
    if (!temporal::is_valid_iso_date(p.year, p.month, p.day)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
        return false;
    }
    *iso = { .date = { p.year, p.month, p.day } };
    if (p.has_time) iso.time = { p.hour, p.minute, p.second, p.nanos / 1_000_000, p.nanos / 1000 % 1000, p.nanos % 1000 };
    *cal = p.calendar;
    return datetime_within_limits(ctx, *iso);
}

// InterpretTemporalDateTimeFields: the date from the calendar fields, then the regulated time.
fn bool interpret_datetime_fields(BuiltinContext* ctx, temporal::CalendarId cal, temporal::CalendarFields* fields,
                                  temporal::OverflowKind overflow, temporal::CivilDateTime* iso) {
    temporal::CivilTime time = { fields.get(HOUR), fields.get(MINUTE), fields.get(SECOND),
                                 fields.get(MILLISECOND), fields.get(MICROSECOND), fields.get(NANOSECOND) };
    return @iso_date(ctx, temporal::calendar_date_from_fields(cal, fields, overflow), &iso.date)
        && fields_to_valid_time(ctx, time, &iso.time, overflow, false)
        && datetime_within_limits(ctx, *iso);
}

fn void builtin_temporal_plain_datetime_compare(BuiltinContext* ctx) {
    temporal::CivilDateTime one, two;
    temporal::CalendarId cal;
    if (!to_temporal_datetime(ctx, arg_at(ctx, 0), &one, &cal) || !to_temporal_datetime(ctx, arg_at(ctx, 1), &two, &cal)) return;
    int cmp = temporal::date_compare(one.date, two.date);
    ctx.result_fastint(cmp != 0 ? cmp : temporal::time_compare(one.time, two.time));
}

// One getter per PlainDateTime field, dispatched on the builtin fn index.
// The time-of-day getters; the calendar ones are builtin_temporal_calendar_getter.
fn void builtin_temporal_plain_datetime_getter(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    switch ((TemporalBuiltin)((uint)(*(ctx.callee_obj.extra_ptr())).func.builtin_fn_index - TEMPORAL_BASE)) {
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_HOUR:        ctx.result_fastint(obj.extra.temporal.long_d);
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_MINUTE:      ctx.result_fastint(obj.extra.temporal.long_e);
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_SECOND:      ctx.result_fastint(obj.extra.temporal.long_f);
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_MILLISECOND: ctx.result_fastint(obj.extra.temporal.long_g);
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_MICROSECOND: ctx.result_fastint(obj.extra.temporal.long_h);
        default:                                               ctx.result_fastint(obj.extra.temporal.long_i);
    }
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
    ShowCalendar show = AUTO;
    temporal::TemporalRoundMode rm = temporal::TemporalRoundMode.TRUNC;
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
            if (v == "auto") { show = AUTO; }
            else if (v == "always") { show = ALWAYS; }
            else if (v == "critical") { show = CRITICAL; }
            else if (v == "never") { show = NEVER; }
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
            if (!temporal::parse_rm_str(v, &rm)) {
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
        unit_ns = temporal::NS_PER_MIN;
    } else if (ns_digits >= 0 && ns_digits < 9) {
        unit_ns = temporal::ns_pow10(9 - ns_digits);
    } else if (ns_digits == 9) {
        unit_ns = 1;
    }
    if (unit_ns > 1) {
        long total = temporal::round_long_ns(temporal::civil_time_to_ns(dt.time), unit_ns, rm);
        if (total >= temporal::NS_PER_DAY) {
            total -= temporal::NS_PER_DAY;
            dt.date = temporal::civil_date_from_epoch_days(
                temporal::epoch_days_from_civil(dt.date.y, (int)dt.date.m, (int)dt.date.d) + 1);
        }
        dt.time = temporal::civil_time_from_ns(total);
        // The balanced datetime must still lie in the representable instant
        // range, an open interval at ±8.64e21 ns (so -271821-04-19T00:00:00.000
        // and 275760-09-14T00:00:00.000 are both out of range).
        int128 epoch_ns = (int128)temporal::epoch_days_from_civil(dt.date.y, (int)dt.date.m, (int)dt.date.d)
            * (int128)temporal::NS_PER_DAY + (int128)total;
        int128 ns_limit = temporal::INSTANT_MAX_NS;
        if (epoch_ns <= -ns_limit || epoch_ns >= ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "rounding pushed the datetime out of range");
            return;
        }
    }

    char[64] buf;
    usz len = temporal::format_civil_datetime(dt, &buf, 64, ns_digits);
    append_calendar_annotation(&buf, &len, obj.extra.temporal.calendar, show);
    ctx.result_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_datetime_proto_toJSON(BuiltinContext* ctx) {
    ctx.argc = 0;
    builtin_temporal_plain_datetime_proto_toString(ctx);
}

fn void builtin_temporal_plain_datetime_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    if (temporal_locale_string(ctx, DTF_REQ_ANY)) return;
    ctx.argc = 0;
    builtin_temporal_plain_datetime_proto_toString(ctx);
}

fn void builtin_temporal_plain_datetime_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDateTime other;
    temporal::CalendarId cal;
    if (!to_temporal_datetime(ctx, arg_at(ctx, 0), &other, &cal)) return;
    temporal::CivilDateTime self = plain_datetime_value(obj);
    ctx.result_boolean(obj.extra.temporal.calendar == cal && temporal::date_equals(self.date, other.date)
                       && temporal::time_equals(self.time, other.time));
}


// withPlainTime(plainTime): the date with the time ToTemporalTime reads from the argument, midnight
// when it is undefined.
fn void builtin_temporal_plain_datetime_proto_withPlainTime(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDateTime result = { .date = plain_date_value(obj) };
    if (!arg_at(ctx, 0).is_undefined()) {
        HObject*? time_o = plain_time_from_arg(ctx, arg_at(ctx, 0));
        if (ctx.should_throw) return;
        result.time = plain_time_value(time_o!!);
    }
    if (datetime_within_limits(ctx, result)) plain_datetime_result(ctx, result, obj.extra.temporal.calendar);
}

fn void builtin_temporal_plain_datetime_proto_toPlainDate(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDate d = plain_date_value(obj);
    HObject*? date_o = alloc_plain_date(ctx.heap, d, obj.extra.temporal.calendar);
    if (catch err = date_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* date_obj = date_o;
    ctx.heap.set_prototype(date_obj, ctx.heap.temporal_plain_date_proto);
    ctx.result_object(date_obj);
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
    ctx.heap.set_prototype(time_obj, ctx.heap.temporal_plain_time_proto);
    ctx.result_object(time_obj);
}

fn void builtin_temporal_plain_datetime_proto_toZonedDateTime(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (arg_at(ctx, 0).is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "toZonedDateTime requires a time zone");
        return;
    }
    HObject*? tz_o = to_temporal_tz(ctx, arg_at(ctx, 0));
    if (catch tz_o) return;
    if (ctx.should_throw) return;
    HObject* tz = tz_o;
    int disambiguation;
    if (!read_disambiguation(ctx, arg_at(ctx, 1), &disambiguation)) return;

    temporal::CivilDateTime cdt = plain_datetime_value(obj);
    long wall_secs = temporal::epoch_days_from_civil(cdt.date.y, (int)cdt.date.m, (int)cdt.date.d) * 86400
        + cdt.time.h * 3600 + cdt.time.mi * 60 + cdt.time.s;
    long wall_frac = cdt.time.ms * 1000000 + cdt.time.us * 1000 + cdt.time.ns;
    bool rejected;
    int128 epoch_ns = temporal::zdt_local_to_epoch_ns(timezone_name(tz), wall_secs, wall_frac, disambiguation, &rejected);
    if (rejected) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "the wall-clock time is skipped or repeated in the time zone");
        return;
    }
    if (!temporal::instant_in_range(epoch_ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside the representable range");
        return;
    }
    hbigint::HBigInt*? ns_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns);
    if (catch err = ns_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
    zdt_from_parts(ctx, ns_o, tz, obj.extra.temporal.calendar);
}

fn void builtin_temporal_plain_datetime_proto_with(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    HObject* bag = partial_temporal_object(ctx, arg_at(ctx, 0));
    if (bag == null) return;
    temporal::CalendarId cal = obj.extra.temporal.calendar;
    temporal::CalendarFields partial;
    temporal::OverflowKind overflow;
    if (!prepare_calendar_fields(ctx, cal, bag, DATE_FIELD_NAMES | TIME_FIELD_NAMES, 0, true, &partial)
        || !read_overflow(ctx, arg_at(ctx, 1), &overflow)) return;
    temporal::CivilDateTime cur = plain_datetime_value(obj);
    temporal::CalendarFields current = temporal::iso_date_to_fields(cal, cur.date, DATE);
    current.put(HOUR, cur.time.h);
    current.put(MINUTE, cur.time.mi);
    current.put(SECOND, cur.time.s);
    current.put(MILLISECOND, cur.time.ms);
    current.put(MICROSECOND, cur.time.us);
    current.put(NANOSECOND, cur.time.ns);
    temporal::CalendarFields fields = temporal::calendar_merge_fields(cal, current, partial);
    temporal::CivilDateTime iso;
    if (interpret_datetime_fields(ctx, cal, &fields, overflow, &iso)) plain_datetime_result(ctx, iso, cal);
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
            if (!temporal::parse_unit_str(str, &smallest_unit) || smallest_unit < temporal::TemporalUnit.DAY) {
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
            if (!temporal::parse_unit_str(s.get_cstr()[:s.blen], &smallest_unit) || smallest_unit < temporal::TemporalUnit.DAY) {
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
    if (smallest_unit == temporal::TemporalUnit.DAY) {
        // "day" allows only roundingIncrement 1: there is exactly one day
        // per rounding unit, so nothing larger can divide evenly.
        if (rounding_increment > 1) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
            return;
        }
    } else {
        long max_incr = temporal::max_round_incr(smallest_unit);
        if (max_incr > 0 && (rounding_increment > (double)max_incr
            || (double)max_incr / rounding_increment != math::floor((double)max_incr / rounding_increment)
            || rounding_increment == (double)max_incr)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
            return;
        }
    }

    temporal::CivilDateTime cur = plain_datetime_value(self);
    long total_ns = cur.time.h * temporal::NS_PER_HOUR + cur.time.mi * temporal::NS_PER_MIN + cur.time.s * temporal::NS_PER_SEC
                  + cur.time.ms * temporal::NS_PER_MS + cur.time.us * 1000L + cur.time.ns;

    long day_delta;
    long rounded_ns;
    if (smallest_unit == temporal::TemporalUnit.DAY) {
        // roundingIncrement is fixed at 1 for "day" (checked above), so this
        // rounds the whole time-of-day to the nearer midnight.
        double day_frac = (double)total_ns / 86400000000000.0;
        double rounded_days = temporal::round_num_to_incr(day_frac, 1, rounding_mode);
        day_delta = (long)rounded_days;
        rounded_ns = 0;
    } else {
        long divisor = temporal::unit_ns_divisor(smallest_unit);
        long incr_ns = divisor * (long)rounding_increment;
        long rounded = temporal::round_long_ns(total_ns, incr_ns, rounding_mode);
        // A whole day of nanoseconds (86400000000000) can only be reached by
        // rounding up past the last representable time-of-day value; carry
        // that into the date and keep the time-of-day in [0, 1 day).
        day_delta = rounded / temporal::NS_PER_DAY;
        rounded_ns = rounded - day_delta * temporal::NS_PER_DAY;
        if (rounded_ns < 0) { rounded_ns += temporal::NS_PER_DAY; day_delta -= 1; }
    }

    temporal::BrokenDownTime bd = temporal::civil_from_seconds(rounded_ns / temporal::NS_PER_SEC);
    long rem = rounded_ns - (rounded_ns / temporal::NS_PER_SEC) * temporal::NS_PER_SEC;
    int rms = (int)(rem / temporal::NS_PER_MS); rem %= temporal::NS_PER_MS;
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
    ctx.heap.set_prototype(obj2, ctx.heap.temporal_plain_datetime_proto);
    ctx.result_object(obj2);
}

// AddDurationToDateTime.
fn void plain_datetime_add_sub(BuiltinContext* ctx, bool subtract) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATETIME, "this is not a Temporal.PlainDateTime")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::DurationParts dur;
    temporal::OverflowKind overflow;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur) || !read_overflow(ctx, arg_at(ctx, 1), &overflow)) return;

    temporal::CivilDateTime cur = plain_datetime_value(obj);
    long sign = subtract ? -1 : 1;
    int128 cur_time_ns = (int128)temporal::civil_time_to_ns(cur.time);
    int128 dur_time_ns = (int128)dur.hours * temporal::NS_PER_HOUR + (int128)dur.minutes * temporal::NS_PER_MIN +
                         (int128)dur.seconds * temporal::NS_PER_SEC + (int128)dur.ms * temporal::NS_PER_MS +
                         (int128)dur.us * 1000L + (int128)dur.ns;
    int128 sum_time_ns = cur_time_ns + sign * dur_time_ns;
    int128 day_ns = (int128)temporal::NS_PER_DAY;
    int128 time_days = sum_time_ns / day_ns;
    int128 rem_time_ns = sum_time_ns % day_ns;
    if (rem_time_ns < 0) {
        rem_time_ns += day_ns;
        time_days -= 1;
    }
    temporal::CalendarId cal = obj.extra.temporal.calendar;
    temporal::CivilDateTime result = { .time = temporal::civil_time_from_ns((long)rem_time_ns) };
    if (!@iso_date(ctx, temporal::calendar_add(cal, cur.date, sign * dur.years, sign * dur.months, sign * dur.weeks,
                                               sign * dur.days + (long)time_days, overflow), &result.date)) return;
    if (datetime_within_limits(ctx, result)) plain_datetime_result(ctx, result, cal);
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
    long start_tod = temporal::civil_time_to_ns(start.time);
    long end_tod = temporal::civil_time_to_ns(end.time);

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
        tod_delta += temporal::NS_PER_DAY;
        ed = temporal::add_days(ed, -1);
    } else if (sign < 0 && tod_delta > 0) {
        tod_delta -= temporal::NS_PER_DAY;
        ed = temporal::add_days(ed, 1);
    }

    // A time-only largestUnit folds the date span into the time delta, leaving
    // a flat nanosecond count to round.
    if (ds.largest > temporal::TemporalUnit.DAY) {
        long days = temporal::epoch_days_from_civil(ed.y, (int)ed.m, (int)ed.d)
                  - temporal::epoch_days_from_civil(sd.y, (int)sd.m, (int)sd.d);
        int128 total = (int128)days * temporal::NS_PER_DAY + (int128)tod_delta;
        int128 incr_ns = (int128)(temporal::unit_ns_divisor(ds.smallest) * (long)ds.increment);
        if (incr_ns > 1) total = temporal::round_long_ns_128(total, incr_ns, ds.mode);
        temporal::decompose_ns_128(total, ds.largest, out);
        return true;
    }

    temporal::DifferenceUnit du;
    switch (ds.largest) {
        case temporal::TemporalUnit.YEAR:  du = temporal::DifferenceUnit.YEARS; break;
        case temporal::TemporalUnit.MONTH: du = temporal::DifferenceUnit.MONTHS; break;
        case temporal::TemporalUnit.WEEK:  du = temporal::DifferenceUnit.WEEKS; break;
        default:                 du = temporal::DifferenceUnit.DAYS; break;
    }
    temporal::DateDifference dd = temporal::calendar_until(ds.calendar, sd, ed, du);

    temporal::DurationParts dp = temporal::time_ns_split(tod_delta, temporal::TemporalUnit.HOUR);
    dp.years = dd.years;
    dp.months = dd.months;
    dp.days = dd.days;
    if (ds.largest == temporal::TemporalUnit.WEEK) {
        dp.weeks = dd.days / 7;
        dp.days = dd.days % 7;
    }

    if (ds.smallest > temporal::TemporalUnit.DAY) {
        long incr_ns = temporal::unit_ns_divisor(ds.smallest) * (long)ds.increment;
        if (ds.is_zoned) {
            // NudgeToZonedTime: a day is a real, possibly non-24-hour calendar
            // day resolved against the zone, so it cannot be folded into the
            // time column. Rounding stays inside the time of day and can carry
            // at most one full day into the date part.
            if (incr_ns > 1) {
                long rounded = temporal::round_long_ns(tod_delta, incr_ns, ds.mode);
                if (rounded != tod_delta) {
                    if (rounded == temporal::NS_PER_DAY || rounded == -temporal::NS_PER_DAY) {
                        // A carry of a whole day empties the time of day and adds a
                        // day to the date part, which can cascade up through
                        // months and years.
                        dp.hours = 0; dp.minutes = 0; dp.seconds = 0;
                        dp.ms = 0; dp.us = 0; dp.ns = 0;
                        if (!bump_date_part(ctx, sd, ds, sign, &dp)) return false;
                    } else {
                        temporal::DurationParts t = temporal::time_ns_split(rounded, temporal::TemporalUnit.HOUR);
                        dp.hours = t.hours; dp.minutes = t.minutes; dp.seconds = t.seconds;
                        dp.ms = t.ms; dp.us = t.us; dp.ns = t.ns;
                    }
                }
            }
        } else {
            // NudgeToDayOrTime (unzoned): Add24HourDaysToTimeDuration folds the
            // whole-day count into the time duration as uniform 24-hour days
            // before rounding, so days participate in the increment alongside
            // hours/minutes/etc rather than being held fixed. This is what
            // makes a halfEven tie resolve differently from the zoned case.
            int128 total = (int128)dp.days * temporal::NS_PER_DAY + (int128)tod_delta;
            if (incr_ns > 1) total = temporal::round_long_ns_128(total, (int128)incr_ns, ds.mode);
            long whole_days = (long)(total / temporal::NS_PER_DAY);
            long rem = (long)(total % temporal::NS_PER_DAY);
            if (rem != 0 && ((rem < 0) != (whole_days < 0)) && whole_days != 0) {
                // C3's truncating int128 division can leave a remainder whose
                // sign disagrees with the quotient; align it so time_ns_split
                // (which expects a same-sign remainder) doesn't misdecompose.
                whole_days += (total < 0) ? 1 : -1;
                rem = (long)(total - (int128)whole_days * temporal::NS_PER_DAY);
            }
            dp.days = whole_days;
            temporal::DurationParts t = temporal::time_ns_split(rem, temporal::TemporalUnit.HOUR);
            dp.hours = t.hours; dp.minutes = t.minutes; dp.seconds = t.seconds;
            dp.ms = t.ms; dp.us = t.us; dp.ns = t.ns;
            if (whole_days != 0) {
                if (!rebalance_date_part(ctx, sd, ds, &dp)) return false;
            }
        }
        *out = dp;
        return true;
    }

    // For a calendar smallestUnit (day or coarser), the leftover below that
    // unit determines whether the count steps to the next whole one.
    if (ds.smallest == temporal::TemporalUnit.WEEK && ds.largest != temporal::TemporalUnit.WEEK) {
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
    temporal::CivilDate end = temporal::apply_date_part(ds.calendar, start, *dp);

    temporal::DifferenceUnit du;
    switch (ds.largest) {
        case temporal::TemporalUnit.YEAR:  du = temporal::DifferenceUnit.YEARS; break;
        case temporal::TemporalUnit.MONTH: du = temporal::DifferenceUnit.MONTHS; break;
        case temporal::TemporalUnit.WEEK:  du = temporal::DifferenceUnit.WEEKS; break;
        default:                 du = temporal::DifferenceUnit.DAYS; break;
    }
    temporal::DateDifference dd = temporal::calendar_until(ds.calendar, start, end, du);
    dp.years = dd.years;
    dp.months = dd.months;
    dp.weeks = 0;
    dp.days = dd.days;
    if (ds.largest == temporal::TemporalUnit.WEEK) {
        dp.weeks = dd.days / 7;
        dp.days = dd.days % 7;
    } else if (ds.smallest == temporal::TemporalUnit.WEEK) {
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
    long units = temporal::smallest_unit_count(*dp, ds.smallest);
    long kept = units - units % incr;

    // `lo` and `hi` are the boundaries at `kept` and one increment beyond it,
    // reached by walking the date part forward from `start` with the coarser
    // components held fixed. Both must land on whole multiples of smallestUnit,
    // so everything finer is cleared first: a leftover month would carry `lo`
    // past the year boundary it marks.
    temporal::DurationParts base = *dp;
    temporal::set_smallest_unit_count(&base, ds.smallest, kept);
    temporal::clear_below(&base, ds.smallest);
    temporal::CivilDate lo = temporal::apply_date_part(ds.calendar, start, base);
    temporal::DurationParts next = base;
    temporal::set_smallest_unit_count(&next, ds.smallest, kept + sign * incr);
    temporal::CivilDate hi = temporal::apply_date_part(ds.calendar, start, next);

    long to_end = temporal::total_days_between(lo, end) * temporal::NS_PER_DAY + tod_delta;
    // Compute the span in int128: (kept+incr) - kept in days at smallestUnit
    // granularity, lifted to nanoseconds. For calendar units like months and
    // years the actual `hi` date is variable, but we only need the ratio
    // between `to_end` and one full increment to decide whether to step up.
    // For uniform units (day and smaller) one increment is exactly
    // `incr * temporal::unit_ns_divisor(smallestUnit)` ns; for non-uniform units (week,
    // month, year) `incr` weeks/days differ by sign and so `apply_date_part`
    // gives the right span for the kept-boundary, which is what we compare.
    int128 span;
    if (ds.smallest >= temporal::TemporalUnit.DAY) {
        long unit_ns = (ds.smallest == temporal::TemporalUnit.DAY) ? temporal::NS_PER_DAY : temporal::unit_ns_divisor(ds.smallest);
        span = (int128)incr * (int128)unit_ns;
    } else {
        span = (int128)temporal::total_days_between(lo, hi) * temporal::NS_PER_DAY;
    }
    if (span == 0) return true;

    // The nudged endpoint must be representable as an Instant at midnight:
    // the spec's NudgeToCalendarUnit uses CalendarDateAdd to compute the
    // bound and ConvertToEpochNanoseconds to lift it, and that lifts throws
    // for any date whose epoch ns fall outside [-1e8, +1e8] days. The ISO
    // date range is asymmetric (-271821-04-19 .. +275760-09-13), so check
    // the Instant range, not just IsValidISODate. An exact multiple at
    // increment 1 (to_end == 0) steps to the natural next boundary and
    // never needs the increment-beyond one, so it need not be
    // representable (test262 PlainYearMonth argument-string-limits). When
    // the increment-beyond boundary (`hi`) would land outside the ISO range
    // but the actual endpoint `end` is representable, the rounding result
    // is determined by `to_end` alone: any unit larger than `to_end` is a
    // valid step-up, and `incr * unit_ns` already exceeds the representable
    // nanosecond range. Skip the `hi` check in that case; test262
    // roundingincrement-{non-integer,days-large} exercises this.
    bool lo_ok = temporal::is_instant_representable_date(lo);
    bool hi_ok = temporal::is_instant_representable_date(hi);
    // The spec's NudgeToCalendarUnit throws when CalendarDateAdd produces a
    // date outside the representable ISO range. Two test262 cases pin down
    // when this validation runs:
    //   - PlainYearMonth/until-argument-string-limits, PlainDate
    //     until-argument-string-limits: when `incr == 1` and the difference
    //     lands exactly on `lo` (`to_end == 0`), the algorithm does not
    //     advance past `lo` and the validation is skipped, even if `lo`
    //     sits at the ISO lower edge -271821-04-19 and `hi` would be
    //     unreachable.
    //   - PlainYearMonth/throws-if-rounded-date-outside-valid-iso-range:
    //     when `incr > 1`, CalendarDateAdd is called unconditionally on
    //     `start + (kept+incr)` and a throw propagates even if the nudge
    //     ultimately does not move.
    // For uniform smallestUnit (day and smaller), the nudge operates on a
    // day-scale window and never asks for the increment-beyond date, so a
    // far-out `hi` does not throw (PlainDate
    // roundingincrement-{non-integer,days-large}). A zoned receiver is the
    // exception: the spec treats days as a calendar unit when the time
    // zone must disambiguate the day boundary, so CalendarDateAdd runs and
    // an out-of-range `hi` throws (ZonedDateTime
    // roundingincrement-addition-out-of-range).
    bool calendar_unit = temporal::is_cal_unit(ds.smallest) || (ds.is_zoned && ds.smallest == temporal::TemporalUnit.DAY);
    bool incr_gt_one = ds.increment > 1;
    bool lo_at_edge_safe = (to_end == 0) && !incr_gt_one;
    if (!lo_ok && !lo_at_edge_safe) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "rounded date outside valid ISO range");
        return false;
    }
    if (calendar_unit && incr_gt_one && !hi_ok) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "rounded date outside valid ISO range");
        return false;
    }

    // round_long_ns takes the offset past the boundary and reports whether it
    // reaches the next one.
    int128 mag_span = span < 0 ? -span : span;
    long mag_end = to_end < 0 ? -to_end : to_end;
    bool step_up;
    if ((int128)mag_end * 2 == mag_span && temporal::is_half_mode(ds.mode)) {
        // An exact halfway point is settled here rather than in round_long_ns,
        // which breaks ties on the quotient within a single span. That quotient
        // is always 0, and halfEven needs the parity of the unit count.
        // Stepping up means away from zero, so ceil and floor swap for a
        // negative difference.
        temporal::TemporalRoundMode tie = sign < 0 ? temporal::mode_for_negative_magnitude(ds.mode) : ds.mode;
        switch (tie) {
            case temporal::TemporalRoundMode.HALF_EVEN:
                step_up = (kept / incr) % 2 != 0;
            case temporal::TemporalRoundMode.HALF_EXPAND:
            case temporal::TemporalRoundMode.HALF_CEIL:
                step_up = true;
            default:
                step_up = false;
        }
    } else {
        step_up = temporal::round_long_ns_128((int128)to_end, mag_span, ds.mode) != 0;
    }
    temporal::set_smallest_unit_count(dp, ds.smallest, step_up ? kept + sign * incr : kept);
    temporal::clear_below(dp, ds.smallest);
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








// DifferenceTemporalPlainDateTime; `flipped` is since, which differences this - other.
fn void plain_datetime_until_since(BuiltinContext* ctx, HObject* obj, bool flipped) {
    temporal::CivilDateTime other;
    DiffSettings ds;
    if (!to_temporal_datetime(ctx, arg_at(ctx, 0), &other, &ds.calendar)) return;
    if (ds.calendar != obj.extra.temporal.calendar) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "calendars do not match");
        return;
    }
    if (!read_diff_settings(ctx, 1, temporal::TemporalUnit.YEAR, temporal::TemporalUnit.NANOSECOND,
                            temporal::TemporalUnit.DAY, temporal::TemporalUnit.NANOSECOND, flipped, &ds)) return;
    // The difference is computed from this to other; since negates it.
    temporal::DurationParts dur;
    if (!datetime_difference(ctx, plain_datetime_value(obj), other, ds, &dur)) return;
    if (flipped) dur = dur.negate();
    @temporal_result(ctx, alloc_duration(ctx.heap, dur), ctx.heap.temporal_duration_proto);
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
    temporal::CalendarId cal;
    if (!calendar_from_arg(ctx, arg_at(ctx, 0), &cal)) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDateTime cur = plain_datetime_value(obj);
    HObject*? obj_o = alloc_plain_datetime(ctx.heap, cur, cal);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    ctx.heap.set_prototype(obj2, ctx.heap.temporal_plain_datetime_proto);
    ctx.result_object(obj2);
}

