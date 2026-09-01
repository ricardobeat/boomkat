// Temporal.PlainYearMonth bindings: constructor, statics, getters, and
// prototype methods.
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
        week = temporal::iso_weeks_in_year(y - 1);
    } else if (week > temporal::iso_weeks_in_year(y)) {
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
    else if (week > temporal::iso_weeks_in_year(y)) { week_year = y + 1; }
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
    if (!read_diff_settings(ctx, 1, temporal::TemporalUnit.YEAR, temporal::TemporalUnit.MONTH,
                            temporal::TemporalUnit.YEAR, temporal::TemporalUnit.MONTH, flipped, &ds)) return;

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

