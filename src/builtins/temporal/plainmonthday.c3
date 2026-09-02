// Temporal.PlainMonthDay bindings: constructor, statics, getters, and
// prototype methods.
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
    if (!temporal::is_valid_iso_date((long)vy, vm, vd)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "PlainMonthDay: reference year is out of range");
        return;
    }

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
        week = temporal::iso_weeks_in_year(y - 1);
    } else if (week > temporal::iso_weeks_in_year(y)) {
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
    else if (week > temporal::iso_weeks_in_year(y)) { week_year = y + 1; }
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

