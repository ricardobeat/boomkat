// Temporal.Calendar (the ISO-8601 singleton) and Temporal.PlainDate:
// constructor, statics, getters and prototype methods.
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
        week = temporal::iso_weeks_in_year(y - 1);
    } else if (week > temporal::iso_weeks_in_year(y)) {
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
    else if (week > temporal::iso_weeks_in_year(y)) { week_year = y + 1; }
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
    int128 epoch_ns_128 = temporal::zdt_local_to_epoch_ns(zone, wall_secs, wall_frac);

    // GetStartOfDay resolves midnight; the resulting UTC instant must fall
    // within the representable epoch range (±8.64e21 ns). A wall date at the
    // ISO boundary with an offset can land past NS_MIN/NS_MAX.
    int128 ns_limit = temporal::INSTANT_MAX_NS;
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
                    ((int128)dur.seconds * temporal::NS_PER_SEC) + ((int128)dur.minutes * temporal::NS_PER_MIN) +
                    ((int128)dur.hours * temporal::NS_PER_HOUR);
    // For PlainDate, the time portion must convert to a whole-day
    // contribution via MathTrunc-style truncation toward zero, not floor. The
    // spec's ToDateDurationRecord keeps the time sub-day fields normalized
    // (so any non-zero sub-day here means the duration is invalid) and
    // adds MathTrunc(time / 86400) to the date's days column. -PT23H59M59.999...
    // truncates to 0 (not -1), which is why subtracting -P273790Y8M12DT23H59M59.999...
    // from 1970-01-01 lands on the valid min date -271821-04-19, not one day
    // earlier.
    long whole_days = (long)(extra_ns / temporal::NS_PER_DAY);
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
                    ((int128)dur.seconds * temporal::NS_PER_SEC) + ((int128)dur.minutes * temporal::NS_PER_MIN) +
                    ((int128)dur.hours * temporal::NS_PER_HOUR);
    // C integer division truncates toward 0, matching the spec's MathTrunc
    // time-to-day conversion: subtracting -PT23H59M59.999... truncates to
    // adding 0 days, not 1.
    long whole_days = (long)(extra_ns / temporal::NS_PER_DAY);
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
    if (!read_diff_settings(ctx, 1, temporal::TemporalUnit.YEAR, temporal::TemporalUnit.DAY,
                            temporal::TemporalUnit.DAY, temporal::TemporalUnit.DAY, flipped, &ds)) return;
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

