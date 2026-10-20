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

    temporal::CalendarId calendar = temporal::CalendarId.ISO8601;
    if (ctx.argc >= 4 && !arg_at(ctx, 3).is_undefined()) {
        if (!calendar_ctor_arg(ctx, arg_at(ctx, 3), &calendar)) return;
    }

    if (!temporal::is_valid_iso_date(y, (int)m, (int)d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate: invalid ISO date");
        return;
    }
    temporal::CivilDate cd = { .y = y, .m = (int)m, .d = (int)d };
    HObject*? obj_o = alloc_plain_date(ctx.heap, cd, calendar);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    ctx.heap.set_prototype(obj, builtin_proto_from_new_target(ctx, ctx.heap.temporal_plain_date_proto));
    ctx.result_object(obj);
}

fn void builtin_temporal_plain_date_from(BuiltinContext* ctx) {
    temporal::CivilDate iso;
    temporal::CalendarId cal;
    if (to_temporal_date(ctx, arg_at(ctx, 0), &iso, &cal, arg_at(ctx, 1))) plain_date_result(ctx, iso, cal);
}

// ToTemporalDate: the ISO date and calendar of `item`, reading the overflow of `options`.
fn bool to_temporal_date(BuiltinContext* ctx, TVal* item, temporal::CivilDate* iso, temporal::CalendarId* cal, TVal* options = null) {
    temporal::OverflowKind overflow;
    if (item.is_object()) {
        HObject* o = (HObject*)item.get_heapptr();
        switch (o.get_class()) {
            case TEMPORAL_PLAIN_DATE:
            case TEMPORAL_PLAIN_DATETIME:
                *iso = temporal_object_date(o);
            case TEMPORAL_ZONEDDATETIME:
                *iso = zdt_wall_date(o);
            default:
                temporal::CalendarFields fields;
                if (!bag_calendar(ctx, o, cal) || !prepare_calendar_fields(ctx, *cal, o, DATE_FIELD_NAMES, 0, false, &fields)
                    || !read_overflow(ctx, options, &overflow)) return false;
                return @iso_date(ctx, temporal::calendar_date_from_fields(*cal, &fields, overflow), iso);
        }
        *cal = o.extra.temporal.calendar;
        return read_overflow(ctx, options, &overflow);
    }
    HString* s = item.is_string() ? (HString*)item.get_heapptr() : null;
    if (s == null || s.is_symbol()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "a PlainDate needs a string or an object");
        return false;
    }
    // TemporalDateTimeString[~Zoned] has no Z designator; a numeric offset is dropped with the time.
    temporal::ParsedIsoDateTime p;
    if (!temporal::parse_iso_date_string(s.get_cstr()[:s.blen], &p) || p.offset_kind == temporal::OffsetKind.Z) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO date string");
        return false;
    }
    if (!read_overflow(ctx, options, &overflow)) return false;
    if (!temporal::is_valid_iso_date(p.year, p.month, p.day)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "date is out of range");
        return false;
    }
    *iso = { p.year, p.month, p.day };
    *cal = p.calendar;
    return true;
}

fn void builtin_temporal_plain_date_compare(BuiltinContext* ctx) {
    temporal::CivilDate one, two;
    temporal::CalendarId cal;
    if (!to_temporal_date(ctx, arg_at(ctx, 0), &one, &cal) || !to_temporal_date(ctx, arg_at(ctx, 1), &two, &cal)) return;
    ctx.result_fastint(temporal::date_compare(one, two));
}

// ============================================================================
// Temporal.PlainDate getters
// ============================================================================


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

    ShowCalendar show;
    if (!read_show_calendar_option(ctx, arg_at(ctx, 0), &show)) return;
    char[64] buf;
    usz len = temporal::format_civil_date(d, &buf, 64);
    append_calendar_annotation(&buf, &len, obj.extra.temporal.calendar, show);
    ctx.result_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_date_proto_toJSON(BuiltinContext* ctx) {
    ctx.argc = 0;
    builtin_temporal_plain_date_proto_toString(ctx);
}

fn void builtin_temporal_plain_date_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    if (temporal_locale_string(ctx, DTF_REQ_DATE)) return;
    ctx.argc = 0;
    builtin_temporal_plain_date_proto_toString(ctx);
}

fn void builtin_temporal_plain_date_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDate other;
    temporal::CalendarId cal;
    if (!to_temporal_date(ctx, arg_at(ctx, 0), &other, &cal)) return;
    ctx.result_boolean(obj.extra.temporal.calendar == cal && temporal::date_equals(plain_date_value(obj), other));
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
    ctx.heap.set_prototype(obj2, ctx.heap.temporal_plain_datetime_proto);
    ctx.result_object(obj2);
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
    bool has_time = false;

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
            has_time = true;
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
    int128 epoch_ns_128 = has_time ? temporal::zdt_local_to_epoch_ns(zone, wall_secs, wall_frac) : temporal::zdt_start_of_day_ns(zone, wall_secs);

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
    zdt_from_parts(ctx, ns, tz, obj.extra.temporal.calendar);
}

fn void builtin_temporal_plain_date_proto_toPlainYearMonth(BuiltinContext* ctx) {
    plain_date_convert(ctx, YEAR_MONTH);
}

fn void builtin_temporal_plain_date_proto_toPlainMonthDay(BuiltinContext* ctx) {
    plain_date_convert(ctx, MONTH_DAY);
}

// toPlainYearMonth and toPlainMonthDay: the date's fields of `type`, resolved as that type.
fn void plain_date_convert(BuiltinContext* ctx, temporal::FieldsType type) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CalendarId cal = obj.extra.temporal.calendar;
    temporal::CalendarFields fields = temporal::iso_date_to_fields(cal, plain_date_value(obj), DATE);
    temporal::CivilDate iso;
    if (@iso_date(ctx, temporal::calendar_from_fields(cal, &fields, type, CONSTRAIN), &iso)) partial_date_result(ctx, type, iso, cal);
}

fn void builtin_temporal_plain_date_proto_with(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    HObject* bag = partial_temporal_object(ctx, arg_at(ctx, 0));
    if (bag == null) return;
    temporal::CalendarId cal = obj.extra.temporal.calendar;
    temporal::CalendarFields partial;
    temporal::OverflowKind overflow;
    if (!prepare_calendar_fields(ctx, cal, bag, DATE_FIELD_NAMES, 0, true, &partial) || !read_overflow_option(ctx, 1, &overflow)) return;
    temporal::CalendarFields fields = temporal::calendar_merge_fields(cal, temporal::iso_date_to_fields(cal, plain_date_value(obj), DATE), partial);
    temporal::CivilDate iso;
    if (@iso_date(ctx, temporal::calendar_date_from_fields(cal, &fields, overflow), &iso)) plain_date_result(ctx, iso, cal);
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
    plain_date_add(ctx, 1);
}

fn void builtin_temporal_plain_date_proto_subtract(BuiltinContext* ctx) {
    plain_date_add(ctx, -1);
}

// AddDurationToDate. The time of the duration counts as its whole days, truncated
// (ToDateDurationRecordWithoutTime).
fn void plain_date_add(BuiltinContext* ctx, long sign) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::DurationParts dur;
    temporal::OverflowKind overflow;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &dur) || !read_overflow_option(ctx, 1, &overflow)) return;
    int128 time_ns = (int128)dur.ns + (int128)dur.us * 1000 + (int128)dur.ms * 1_000_000
        + (int128)dur.seconds * temporal::NS_PER_SEC + (int128)dur.minutes * temporal::NS_PER_MIN
        + (int128)dur.hours * temporal::NS_PER_HOUR;
    long days = dur.days + (long)(time_ns / temporal::NS_PER_DAY);
    temporal::CalendarId cal = obj.extra.temporal.calendar;
    temporal::CivilDate iso;
    if (!@iso_date(ctx, temporal::calendar_add(cal, plain_date_value(obj), sign * dur.years, sign * dur.months,
                                               sign * dur.weeks, sign * days, overflow), &iso)) return;
    if (!temporal::is_valid_iso_date(iso.y, (int)iso.m, (int)iso.d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "result is out of range");
        return;
    }
    plain_date_result(ctx, iso, cal);
}

// DifferenceTemporalPlainDate; `flipped` is since, which differences this - other.
fn void plain_date_until_since(BuiltinContext* ctx, bool flipped) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_PLAIN_DATE, "this is not a Temporal.PlainDate")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDate other;
    DiffSettings ds;
    if (!to_temporal_date(ctx, arg_at(ctx, 0), &other, &ds.calendar)) return;
    if (ds.calendar != obj.extra.temporal.calendar) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "calendars do not match");
        return;
    }
    // A PlainDate has no time, so only day-and-coarser units are accepted. The difference is
    // computed in the positive direction, so since negates the rounding mode.
    if (!read_diff_settings(ctx, 1, temporal::TemporalUnit.YEAR, temporal::TemporalUnit.DAY,
                            temporal::TemporalUnit.DAY, temporal::TemporalUnit.DAY, flipped, &ds)) return;
    temporal::DurationParts dur;
    if (!datetime_difference(ctx, { .date = plain_date_value(obj) }, { .date = other }, ds, &dur)) return;
    if (flipped) dur = dur.negate();
    @temporal_result(ctx, alloc_duration(ctx.heap, dur), ctx.heap.temporal_duration_proto);
}

fn void builtin_temporal_plain_date_proto_until(BuiltinContext* ctx) {
    plain_date_until_since(ctx, false);
}

fn void builtin_temporal_plain_date_proto_since(BuiltinContext* ctx) {
    plain_date_until_since(ctx, true);
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
    temporal::CalendarId cal;
    if (!calendar_from_arg(ctx, arg_at(ctx, 0), &cal)) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    temporal::CivilDate cur = plain_date_value(obj);
    HObject*? obj_o = alloc_plain_date(ctx.heap, cur, cal);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj2 = obj_o;
    ctx.heap.set_prototype(obj2, ctx.heap.temporal_plain_date_proto);
    ctx.result_object(obj2);
}

