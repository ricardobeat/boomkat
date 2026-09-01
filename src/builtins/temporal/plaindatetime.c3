// Temporal.PlainDateTime bindings: constructor, statics, getters, and
// prototype methods, including the shared date-time difference and rounding
// paths that PlainDate and ZonedDateTime delegate into.
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
        out.time = temporal::regulate_time_constrain(fields.time);
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
    switch ((TemporalBuiltin)((uint)(*(ctx.callee_obj.extra_ptr())).func.builtin_fn_index - TEMPORAL_BASE)) {
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_YEAR:        val = (double)(long)obj.extra.temporal.long_a; break;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_MONTH:       val = (double)obj.extra.temporal.long_b; break;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_DAY:         val = (double)obj.extra.temporal.long_c; break;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_HOUR:        val = (double)obj.extra.temporal.long_d; break;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_MINUTE:      val = (double)obj.extra.temporal.long_e; break;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_SECOND:      val = (double)obj.extra.temporal.long_f; break;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_MILLISECOND: val = (double)obj.extra.temporal.long_g; break;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_MICROSECOND: val = (double)obj.extra.temporal.long_h; break;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_NANOSECOND:  val = (double)obj.extra.temporal.long_i; break;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_CALENDAR:
            ctx.result.set_object(obj.extra.temporal.calendar);
            return;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_CALENDARID:
            ctx.result.set_string(builtin_intern_string(ctx.heap, "iso8601"));
            return;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_MONTHCODE: {
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
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYOFWEEK: {
            long y = (long)obj.extra.temporal.long_a;
            int m = (int)obj.extra.temporal.long_b;
            int d = (int)obj.extra.temporal.long_c;
            long days = temporal::epoch_days_from_civil(y, m, d);
            long dow = ((days % 7) + 4) % 7;
            if (dow <= 0) dow += 7;
            ctx.result.set_number((double)dow);
            return;
        }
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYOFYEAR: {
            long y = (long)obj.extra.temporal.long_a;
            long jan1 = temporal::epoch_days_from_civil(y, (int)1, (int)1);
            long doy = temporal::epoch_days_from_civil(y, (int)obj.extra.temporal.long_b, (int)obj.extra.temporal.long_c) - jan1 + 1;
            ctx.result.set_number((double)doy);
            return;
        }
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_WEEKOFYEAR: {
            long y = (long)obj.extra.temporal.long_a;
            int m = (int)obj.extra.temporal.long_b;
            int d = (int)obj.extra.temporal.long_c;
            long doy = temporal::epoch_days_from_civil(y, m, d) - temporal::epoch_days_from_civil(y, 1, 1) + 1;
            long dow = ((temporal::epoch_days_from_civil(y, m, d) % 7) + 4) % 7;
            if (dow <= 0) dow += 7;
            long week = (doy - dow + 10) / 7;
            if (week < 1) {
                week = temporal::iso_weeks_in_year(y - 1);
            } else if (week > temporal::iso_weeks_in_year(y)) {
                week = 1;
            }
            ctx.result.set_number((double)week);
            return;
        }
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_YEAROFWEEK: {
            long y = (long)obj.extra.temporal.long_a;
            int m = (int)obj.extra.temporal.long_b;
            int d = (int)obj.extra.temporal.long_c;
            long doy = temporal::epoch_days_from_civil(y, m, d) - temporal::epoch_days_from_civil(y, 1, 1) + 1;
            long dow = ((temporal::epoch_days_from_civil(y, m, d) % 7) + 4) % 7;
            if (dow <= 0) dow += 7;
            long week = (doy - dow + 10) / 7;
            long week_year = y;
            if (week < 1) { week_year = y - 1; }
            else if (week > temporal::iso_weeks_in_year(y)) { week_year = y + 1; }
            ctx.result.set_number((double)week_year);
            return;
        }
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYSINWEEK:
            ctx.result.set_number(7.0);
            return;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYSINMONTH: {
            int m = (int)obj.extra.temporal.long_b;
            long y = (long)obj.extra.temporal.long_a;
            ctx.result.set_number((double)temporal::days_in_month((int)y, m));
            return;
        }
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_DAYSINYEAR: {
            long y = (long)obj.extra.temporal.long_a;
            ctx.result.set_number(temporal::is_leap_year(y) ? 366.0 : 365.0);
            return;
        }
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_MONTHSINYEAR:
            ctx.result.set_number(12.0);
            return;
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_INLEAPYEAR: {
            long y = (long)obj.extra.temporal.long_a;
            ctx.result.set_boolean(temporal::is_leap_year(y));
            return;
        }
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_ERA:
        case TemporalBuiltin.PLAIN_DATETIME_PROTO_ERAYEAR:
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
        temporal::CivilTime valid = temporal::regulate_time_constrain(fields);
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
    int128 epoch_ns = temporal::zdt_local_to_epoch_ns(zone, wall_secs, wall_frac);

    // Instant range check: ±100,000,000 days × 86400 × 1e9 ns.
    {
        int128 ns_limit = temporal::INSTANT_MAX_NS;
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

    int128 cur_time_ns = (int128)cur.time.h * temporal::NS_PER_HOUR + (int128)cur.time.mi * temporal::NS_PER_MIN +
                         (int128)cur.time.s * temporal::NS_PER_SEC + (int128)cur.time.ms * temporal::NS_PER_MS +
                         (int128)cur.time.us * 1000L + (int128)cur.time.ns;
    int128 dur_time_ns = (int128)dur.hours * temporal::NS_PER_HOUR + (int128)dur.minutes * temporal::NS_PER_MIN +
                         (int128)dur.seconds * temporal::NS_PER_SEC + (int128)dur.ms * temporal::NS_PER_MS +
                         (int128)dur.us * 1000L + (int128)dur.ns;
    int128 sum_time_ns = subtract ? (cur_time_ns - dur_time_ns) : (cur_time_ns + dur_time_ns);
    int128 day_ns = (int128)temporal::NS_PER_DAY;
    int128 time_days = sum_time_ns / day_ns;
    int128 rem_time_ns = sum_time_ns % day_ns;
    if (rem_time_ns < 0) {
        rem_time_ns += day_ns;
        time_days -= 1;
    }

    temporal::CivilTime time_part;
    time_part.h = (int)(rem_time_ns / temporal::NS_PER_HOUR);
    int128 rem_ns = rem_time_ns % temporal::NS_PER_HOUR;
    time_part.mi = (int)(rem_ns / temporal::NS_PER_MIN);
    rem_ns %= temporal::NS_PER_MIN;
    time_part.s = (int)(rem_ns / temporal::NS_PER_SEC);
    rem_ns %= temporal::NS_PER_SEC;
    time_part.ms = (int)(rem_ns / temporal::NS_PER_MS);
    rem_ns %= temporal::NS_PER_MS;
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
    temporal::DateDifference dd = temporal::difference_date(sd, ed, du);

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
    temporal::CivilDate end = start;
    if (dp.years != 0 || dp.months != 0) {
        end = temporal::add_months(end, dp.years * 12 + dp.months, temporal::OverflowKind.CONSTRAIN);
    }
    end = temporal::add_days(end, dp.weeks * 7 + dp.days);

    temporal::DifferenceUnit du;
    switch (ds.largest) {
        case temporal::TemporalUnit.YEAR:  du = temporal::DifferenceUnit.YEARS; break;
        case temporal::TemporalUnit.MONTH: du = temporal::DifferenceUnit.MONTHS; break;
        case temporal::TemporalUnit.WEEK:  du = temporal::DifferenceUnit.WEEKS; break;
        default:                 du = temporal::DifferenceUnit.DAYS; break;
    }
    temporal::DateDifference dd = temporal::difference_date(start, end, du);
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
    temporal::CivilDate lo = temporal::apply_date_part(start, base);
    temporal::DurationParts next = base;
    temporal::set_smallest_unit_count(&next, ds.smallest, kept + sign * incr);
    temporal::CivilDate hi = temporal::apply_date_part(start, next);

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
    if (!read_diff_settings(ctx, 1, temporal::TemporalUnit.YEAR, temporal::TemporalUnit.NANOSECOND,
                            temporal::TemporalUnit.DAY, temporal::TemporalUnit.NANOSECOND, flipped, &ds)) return;

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

