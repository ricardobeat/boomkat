// Temporal built-ins layer. Adapts boomkat::lib::temporal value types to
// HObject, TVal, and BuiltinContext.
module boomkat::builtins;

import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::env;
import boomkat::vm;
import boomkat::lib::temporal;
import libc;

// ============================================================================
// Shared helpers
// ============================================================================

// Validate that `this_val` carries a TEMPORAL_PLAIN_DATE object and return
// the underlying HObject. Throws TypeError on mismatch.
fn HObject* plain_date_this(BuiltinContext* ctx, TVal* this_val, char[] why) {
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, why);
        return null;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
        builtin_throw(ctx, ctx.heap.type_err_proto, why);
        return null;
    }
    return obj;
}

fn HObject* calendar_this(BuiltinContext* ctx, TVal* this_val, char[] why) {
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, why);
        return null;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.TEMPORAL_CALENDAR) {
        builtin_throw(ctx, ctx.heap.type_err_proto, why);
        return null;
    }
    return obj;
}

// Read a CivilDate from a PlainDate HObject's internal slots. Caller has
// already validated obj_class.
fn temporal::CivilDate plain_date_value(HObject* obj) {
    return {
        .y = (long)obj.extra.temporal.int_a,
        .m = obj.extra.temporal.int_b,
        .d = obj.extra.temporal.int_c,
    };
}

fn HObject*? alloc_plain_date(Heap* hp, temporal::CivilDate d, HObject* calendar) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_PLAIN_DATE);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    obj.extra.temporal.int_a = (int)d.y;
    obj.extra.temporal.int_b = d.m;
    obj.extra.temporal.int_c = d.d;
    obj.extra.temporal.calendar = calendar;
    return obj;
}

// Parse `YYYY-MM-DD`, `+YYYYYY-MM-DD`, or `-YYYYYY-MM-DD`. Extended-year sign
// is required when |year| >= 10000 or year <= 0. Callers re-validate via
// is_valid_iso_date on success.
fn bool parse_iso_date_string(char[] text, long* out_y, int* out_m, int* out_d) {
    usz len = text.len;
    usz i = 0;
    int sign = 1;
    if (i < len && (text[i] == '+' || text[i] == '-')) {
        if (text[i] == '-') sign = -1;
        i += 1;
    }
    usz year_start = i;
    while (i < len && text[i] >= '0' && text[i] <= '9') i += 1;
    if (i == year_start) return false;
    if (i - year_start > 6) return false;
    if (i >= len || text[i] != '-') return false;
    long y = 0;
    for (usz k = year_start; k < i; k++) y = y * 10 + (long)(text[k] - '0');
    y *= sign;
    i += 1;
    if (i + 2 > len) return false;
    if (text[i] < '0' || text[i] > '9') return false;
    if (text[i+1] < '0' || text[i+1] > '9') return false;
    int m = (text[i] - '0') * 10 + (text[i+1] - '0');
    i += 2;
    if (i >= len || text[i] != '-') return false;
    i += 1;
    if (i + 2 > len) return false;
    if (text[i] < '0' || text[i] > '9') return false;
    if (text[i+1] < '0' || text[i+1] > '9') return false;
    int d = (text[i] - '0') * 10 + (text[i+1] - '0');
    i += 2;
    if (i != len) return false;
    *out_y = y;
    *out_m = m;
    *out_d = d;
    return true;
}

// ============================================================================
// Temporal.Calendar
// ============================================================================

fn void builtin_temporal_calendar_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Calendar.from requires a string argument");
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    if (!arg.is_string() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Calendar.from requires a string");
        return;
    }
    HString* s = (HString*)arg.get_heapptr();
    char[] text = s.get_cstr()[:s.blen];
    bool ok = text == "iso8601" || text == "gregory" || text == "gregorian";
    if (!ok) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "unknown calendar identifier");
        return;
    }
    ctx.result.set_object(ctx.heap.temporal_iso_calendar);
}

fn void builtin_temporal_calendar_proto_id(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = calendar_this(ctx, this_val, "this is not a Temporal.Calendar");
    if (ctx.should_throw) return;
    HString* id = builtin_intern_string(ctx.heap, "iso8601");
    ctx.result.set_string(id);
}

// ============================================================================
// Temporal.PlainDate constructor + methods
// ============================================================================

fn void builtin_temporal_plain_date_ctor(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate requires at least a year");
        return;
    }
    Vm* v = (Vm*)ctx.vm;
    TVal* yr_arg = &ctx.regs[ctx.base_reg];
    double yr_d = vm::vm_to_number(v, yr_arg);
    if (v.throw_pending) {
        ctx.should_throw = true;
        ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
        v.throw_pending = false;
        return;
    }
    double mo_d = ctx.argc >= 2 ? vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 1]) : 1.0;
    if (v.throw_pending) {
        ctx.should_throw = true;
        ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
        v.throw_pending = false;
        return;
    }
    double dy_d = ctx.argc >= 3 ? vm::vm_to_number(v, &ctx.regs[ctx.base_reg + 2]) : 1.0;
    if (v.throw_pending) {
        ctx.should_throw = true;
        ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
        v.throw_pending = false;
        return;
    }

    long y = (long)yr_d;
    int m = (int)mo_d;
    int d = (int)dy_d;

    if (!temporal::is_valid_iso_date(y, m, d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate: invalid ISO date");
        return;
    }

    temporal::CivilDate cd = { .y = y, .m = m, .d = d };

    HObject*? obj_o = alloc_plain_date(ctx.heap, cd, ctx.heap.temporal_iso_calendar);
    if (catch err = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "Temporal.PlainDate: alloc failed");
        return;
    }
    HObject* obj = obj_o;
    if (ctx.is_constructor) {
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_plain_date_proto);
    } else {
        obj.prototype = ctx.heap.temporal_plain_date_proto;
    }
    ctx.result.set_object(obj);
}

fn void builtin_temporal_plain_date_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.from requires an argument");
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];

    if (arg.is_string() && arg.get_heapptr() != null) {
        HString* s = (HString*)arg.get_heapptr();
        char[] text = s.get_cstr()[:s.blen];
        long y;
        int m, d;
        if (!parse_iso_date_string(text, &y, &m, &d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate.from: invalid ISO date string");
            return;
        }
        if (!temporal::is_valid_iso_date(y, m, d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate.from: invalid ISO date");
            return;
        }
        temporal::CivilDate cd = { .y = y, .m = m, .d = d };
        HObject*? obj_o = alloc_plain_date(ctx.heap, cd, ctx.heap.temporal_iso_calendar);
        if (catch err = obj_o) {
            builtin_throw(ctx, ctx.heap.err_proto, "Temporal.PlainDate.from: alloc failed");
            return;
        }
        HObject* obj2 = obj_o;
        obj2.prototype = ctx.heap.temporal_plain_date_proto;
        ctx.result.set_object(obj2);
        return;
    }

    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* obj = (HObject*)arg.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
            ctx.result.set_object(obj);
            return;
        }
        HString* year_key = builtin_intern_string(ctx.heap, "year");
        HString* month_key = builtin_intern_string(ctx.heap, "month");
        HString* day_key = builtin_intern_string(ctx.heap, "day");
        TVal undef; undef.set_undefined();
        TVal yt = obj.get_prop(year_key, ctx.heap) ?? undef;
        TVal mt = obj.get_prop(month_key, ctx.heap) ?? undef;
        TVal dtv = obj.get_prop(day_key, ctx.heap) ?? undef;
        if (!yt.is_undefined() && !mt.is_undefined()) {
            Vm* v = (Vm*)ctx.vm;
            double yd = vm::vm_to_number(v, &yt);
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            double mod = vm::vm_to_number(v, &mt);
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            double ddv = dtv.is_undefined() ? 1.0 : vm::vm_to_number(v, &dtv);
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
            long y = (long)yd;
            int m = (int)mod;
            int d = (int)ddv;
            if (!temporal::is_valid_iso_date(y, m, d)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate.from: invalid ISO date");
                return;
            }
            temporal::CivilDate cd = { .y = y, .m = m, .d = d };
            HObject*? obj_o = alloc_plain_date(ctx.heap, cd, ctx.heap.temporal_iso_calendar);
            if (catch err = obj_o) {
                builtin_throw(ctx, ctx.heap.err_proto, "Temporal.PlainDate.from: alloc failed");
                return;
            }
            HObject* obj2 = obj_o;
            obj2.prototype = ctx.heap.temporal_plain_date_proto;
            ctx.result.set_object(obj2);
            return;
        }
    }

    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.from: argument must be a PlainDate or an object with year/month/day");
}

fn void builtin_temporal_plain_date_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.compare requires two arguments");
        return;
    }
    TVal* a_arg = &ctx.regs[ctx.base_reg];
    TVal* b_arg = &ctx.regs[ctx.base_reg + 1];
    if (!a_arg.is_object() || a_arg.get_heapptr() == null
        || ((HObject*)a_arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATE
        || !b_arg.is_object() || b_arg.get_heapptr() == null
        || ((HObject*)b_arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.compare arguments must both be Temporal.PlainDate");
        return;
    }
    temporal::CivilDate a = plain_date_value((HObject*)a_arg.get_heapptr());
    temporal::CivilDate b = plain_date_value((HObject*)b_arg.get_heapptr());
    ctx.result.set_fastint((long)temporal::date_compare(a, b));
}

fn void builtin_temporal_plain_date_proto_year(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    ctx.result.set_number((double)(long)obj.extra.temporal.int_a);
}

fn void builtin_temporal_plain_date_proto_month(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    ctx.result.set_number((double)obj.extra.temporal.int_b);
}

fn void builtin_temporal_plain_date_proto_day(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    ctx.result.set_number((double)obj.extra.temporal.int_c);
}

fn void builtin_temporal_plain_date_proto_dayOfWeek(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    long days = temporal::epoch_days_from_civil(
        (long)obj.extra.temporal.int_a,
        obj.extra.temporal.int_b,
        obj.extra.temporal.int_c);
    // 1970-01-01 = Thursday = ISO 4; ((d % 7) + 4) % 7 maps [0..6] -> [4,5,6,7,1,2,3].
    long w = ((days % 7) + 4) % 7;
    if (w == 0) w = 7;
    ctx.result.set_number((double)w);
}

fn void builtin_temporal_plain_date_proto_dayOfYear(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    long y = (long)obj.extra.temporal.int_a;
    long jan1 = temporal::epoch_days_from_civil(y, 1, 1);
    long doy = temporal::epoch_days_from_civil(y, obj.extra.temporal.int_b, obj.extra.temporal.int_c) - jan1 + 1;
    ctx.result.set_number((double)doy);
}

fn void builtin_temporal_plain_date_proto_monthCode(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    int m = obj.extra.temporal.int_b;
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
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    ctx.result.set_boolean(temporal::is_leap_year((long)obj.extra.temporal.int_a));
}

fn void builtin_temporal_plain_date_proto_calendar(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    ctx.result.set_object(obj.extra.temporal.calendar);
}

fn void builtin_temporal_plain_date_proto_toString(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    temporal::CivilDate d = plain_date_value(obj);
    char[32] buf;
    usz len = temporal::format_civil_date(d, &buf, 32);
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}

fn void builtin_temporal_plain_date_proto_toJSON(BuiltinContext* ctx) {
    builtin_temporal_plain_date_proto_toString(ctx);
}

fn void builtin_temporal_plain_date_proto_equals(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
        ctx.result.set_boolean(false);
        return;
    }
    temporal::CivilDate a = plain_date_value(obj);
    temporal::CivilDate b = plain_date_value((HObject*)arg.get_heapptr());
    ctx.result.set_boolean(temporal::date_equals(a, b));
}

fn void builtin_temporal_plain_date_proto_with(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.prototype.with requires a fields bag");
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.prototype.with requires an object");
        return;
    }
    HObject* bag = (HObject*)arg.get_heapptr();
    temporal::CivilDate cur = plain_date_value(obj);
    HString* year_key = builtin_intern_string(ctx.heap, "year");
    HString* month_key = builtin_intern_string(ctx.heap, "month");
    HString* day_key = builtin_intern_string(ctx.heap, "day");
    TVal undef; undef.set_undefined();
    TVal yt = bag.get_prop(year_key, ctx.heap) ?? undef;
    TVal mt = bag.get_prop(month_key, ctx.heap) ?? undef;
    TVal dtv = bag.get_prop(day_key, ctx.heap) ?? undef;
    Vm* v = (Vm*)ctx.vm;
    long y = yt.is_undefined() ? cur.y : (long)vm::vm_to_number(v, &yt);
    if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    int m = mt.is_undefined() ? cur.m : (int)vm::vm_to_number(v, &mt);
    if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    int d = dtv.is_undefined() ? cur.d : (int)vm::vm_to_number(v, &dtv);
    if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    if (!temporal::is_valid_iso_date(y, m, d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate.prototype.with: invalid ISO date");
        return;
    }
    temporal::CivilDate cd = { .y = y, .m = m, .d = d };
    HObject*? obj_o = alloc_plain_date(ctx.heap, cd, ctx.heap.temporal_iso_calendar);
    if (catch err = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "Temporal.PlainDate.prototype.with: alloc failed");
        return;
    }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_date_proto_add(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    builtin_temporal_plain_date_addsub(ctx, obj, false);
}

fn void builtin_temporal_plain_date_proto_subtract(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    builtin_temporal_plain_date_addsub(ctx, obj, true);
}

fn void builtin_temporal_plain_date_addsub(BuiltinContext* ctx, HObject* obj, bool negate) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.add/subtract requires a duration");
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    if (!arg.is_object() || arg.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.add/subtract requires an object");
        return;
    }
    HObject* bag = (HObject*)arg.get_heapptr();
    Vm* v = (Vm*)ctx.vm;
    HString* years_key = builtin_intern_string(ctx.heap, "years");
    HString* months_key = builtin_intern_string(ctx.heap, "months");
    HString* weeks_key = builtin_intern_string(ctx.heap, "weeks");
    HString* days_key = builtin_intern_string(ctx.heap, "days");
    TVal undef; undef.set_undefined();
    long yrs;
    long mons;
    long dys;
    yrs = 0;
    mons = 0;
    dys = 0;
    TVal yv = bag.get_prop(years_key, ctx.heap) ?? undef;
    if (!yv.is_undefined()) {
        yrs = (long)vm::vm_to_number(v, &yv);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    }
    TVal mv = bag.get_prop(months_key, ctx.heap) ?? undef;
    if (!mv.is_undefined()) {
        mons = (long)vm::vm_to_number(v, &mv);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    }
    TVal wv = bag.get_prop(weeks_key, ctx.heap) ?? undef;
    if (!wv.is_undefined()) {
        long w = (long)vm::vm_to_number(v, &wv);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        dys += w * 7;
    }
    TVal dv = bag.get_prop(days_key, ctx.heap) ?? undef;
    if (!dv.is_undefined()) {
        dys += (long)vm::vm_to_number(v, &dv);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    }
    if (negate) { yrs = -yrs; mons = -mons; dys = -dys; }
    temporal::CivilDate cur = plain_date_value(obj);
    long total_months = yrs * 12 + mons;
    // Compute the year/month the result lands in so REJECT overflow can throw
    // before allocation. add_months would clamp silently otherwise.
    long total = (long)cur.m - 1 + total_months;
    long new_year = cur.y + total / 12;
    long new_month0 = total % 12;
    if (new_month0 < 0) { new_month0 += 12; new_year -= 1; }
    int new_month = (int)new_month0 + 1;
    int dim = temporal::days_in_month(new_year, new_month);
    if (cur.d > dim) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.PlainDate.add/subtract: day overflows resulting month");
        return;
    }
    temporal::CivilDate result = temporal::add_days({ .y = new_year, .m = new_month, .d = cur.d }, dys);
    HObject*? obj_o = alloc_plain_date(ctx.heap, result, ctx.heap.temporal_iso_calendar);
    if (catch err = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "Temporal.PlainDate.add/subtract: alloc failed");
        return;
    }
    HObject* obj2 = obj_o;
    obj2.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(obj2);
}

fn void builtin_temporal_plain_date_proto_until(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    builtin_temporal_plain_date_until_since(ctx, obj, false);
}

fn void builtin_temporal_plain_date_proto_since(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    HObject* obj = plain_date_this(ctx, this_val, "this is not a Temporal.PlainDate");
    if (ctx.should_throw) return;
    builtin_temporal_plain_date_until_since(ctx, obj, true);
}

fn void builtin_temporal_plain_date_until_since(BuiltinContext* ctx, HObject* obj, bool flipped) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.until/since requires another date");
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATE) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.PlainDate.until/since argument must be a Temporal.PlainDate");
        return;
    }
    temporal::CivilDate a = plain_date_value(obj);
    temporal::CivilDate b = plain_date_value((HObject*)arg.get_heapptr());
    long days = temporal::epoch_days_from_civil(b.y, b.m, b.d)
              - temporal::epoch_days_from_civil(a.y, a.m, a.d);
    if (flipped) days = -days;
    HObject*? dur_o = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = dur_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* dur = dur_o;
    dur.prototype = ctx.heap.object_proto;
    HString* days_key = builtin_intern_string(ctx.heap, "days");
    TVal days_tv; days_tv.set_number((double)days);
    dur.put_prop(days_key, days_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    HString* weeks_key = builtin_intern_string(ctx.heap, "weeks");
    TVal weeks_tv; weeks_tv.set_number(0);
    dur.put_prop(weeks_key, weeks_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    HString* months_key = builtin_intern_string(ctx.heap, "months");
    TVal months_tv; months_tv.set_number(0);
    dur.put_prop(months_key, months_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    HString* years_key = builtin_intern_string(ctx.heap, "years");
    TVal years_tv; years_tv.set_number(0);
    dur.put_prop(years_key, years_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    ctx.result.set_object(dur);
}

// ============================================================================
// Registration
// ============================================================================

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

    HObject*? cal_raw = heap.alloc_object(hobject::ObjClass.TEMPORAL_CALENDAR);
    if (catch err = cal_raw) return false;
    HObject* cal_obj = cal_raw;
    cal_obj.prototype = proto;

    HString* id_key = builtin_intern_string(heap, "id");
    TVal id_tv;
    id_tv.set_string(builtin_intern_string(heap, "iso8601"));
    cal_obj.put_prop(id_key, id_tv, hobject::PROP_FLAGS_NWC, heap);

    if (!register_string_proto_method(proto, heap, "id", Builtin.TEMPORAL_CALENDAR_PROTO_ID.ordinal)) return false;
    if (!register_string_proto_method(cal_obj, heap, "from", Builtin.TEMPORAL_CALENDAR_FROM.ordinal)) return false;

    heap.temporal_iso_calendar = cal_obj;
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
    if (!register_proto_getter_accessor(proto, heap, "calendar", Builtin.TEMPORAL_PLAIN_DATE_PROTO_CALENDAR.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toString", Builtin.TEMPORAL_PLAIN_DATE_PROTO_TOSTRING.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toJSON", Builtin.TEMPORAL_PLAIN_DATE_PROTO_TOJSON.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "equals", Builtin.TEMPORAL_PLAIN_DATE_PROTO_EQUALS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "with", Builtin.TEMPORAL_PLAIN_DATE_PROTO_WITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "add", Builtin.TEMPORAL_PLAIN_DATE_PROTO_ADD.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "subtract", Builtin.TEMPORAL_PLAIN_DATE_PROTO_SUBTRACT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "until", Builtin.TEMPORAL_PLAIN_DATE_PROTO_UNTIL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "since", Builtin.TEMPORAL_PLAIN_DATE_PROTO_SINCE.ordinal)) return false;

    if (!register_string_proto_method(ctor, heap, "from", Builtin.TEMPORAL_PLAIN_DATE_FROM.ordinal)) return false;
    if (!register_string_proto_method(ctor, heap, "compare", Builtin.TEMPORAL_PLAIN_DATE_COMPARE.ordinal)) return false;

    heap.temporal_plain_date_proto = proto;
    return true;
}

fn bool setUpTemporalNamespace(EnvRecord* global_env, Heap* heap) {
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

    // Surface the PlainDate constructor on the namespace by walking back
    // through the prototype's .constructor property (set in setUpTemporalPlainDate).
    HString* pd_prop_key = builtin_intern_string(heap, "PlainDate");
    TVal undef; undef.set_undefined();
    HString* ctor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal ctor_tv = heap.temporal_plain_date_proto.get_prop((void*)ctor_key, heap) ?? undef;
    if (ctor_tv.is_object() && ctor_tv.get_heapptr() != null) {
        ns.put_prop(pd_prop_key, ctor_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HString* cal_key = builtin_intern_string(heap, "Calendar");
    TVal cal_tv;
    cal_tv.set_object(heap.temporal_iso_calendar);
    ns.put_prop(cal_key, cal_tv, hobject::PROP_FLAGS_NWC, heap);

    TVal ns_tv;
    ns_tv.set_object(ns);
    HString* t_key = heap.str_intern("Temporal");
    if (t_key == null) return false;
    env::env_declare_nonenum(global_env, t_key, ns_tv);

    return true;
}
