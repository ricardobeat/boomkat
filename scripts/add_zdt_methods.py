#!/usr/bin/env python3
"""Add all missing ZonedDateTime method implementations to temporal.c3."""

with open('src/builtins/temporal.c3', 'r') as f:
    c = f.read()

# Find the last ZonedDateTime method and add our new implementations after it.
# We'll add them right after the equals function (which was already updated).
# Look for the compare function we just added.

new_impls = """
// =====================================================================
// ZonedDateTime: missing getter and method implementations
// =====================================================================

// Helper: resolve wall-time fields from epoch-ns + timezone.
fn void zdt_wall_fields(HObject* zdt, long* wy, long* wm, long* wd,
                         int* wh, int* wmi, int* ws, int* wms, int* wus, int* wns, int* off_sec) {
    hbigint::HBigInt* b = zdt.extra.temporal.big_ns;
    HObject* tz = zdt.extra.temporal.timezone;
    long epoch_secs;
    long ns_rem;
    if (b.fits_int128()) {
        int128 total = b.to_int128();
        long sec_trunc = (long)(total / 1000000000);
        ns_rem = (long)(total - (int128)sec_trunc * 1000000000);
        epoch_secs = sec_trunc;
    } else {
        double s_d;
        if (tz != null && b != null) {
            String zone = timezone_name(tz);
            // Approximate from double
            double secs_d = 0;
            // fallback: use 0
            epoch_secs = 0; ns_rem = 0;
        } else {
            epoch_secs = 0; ns_rem = 0;
        }
    }
    String zone = (tz != null) ? timezone_name(tz) : (String)"";
    int off = 0;
    if (zone.len > 0 && zone.ptr != null) off = temporal::tzdb_offset_for_zone_at(zone, epoch_secs);
    long local_secs = epoch_secs + off;
    temporal::BrokenDownTime bd = temporal::civil_from_seconds(local_secs);
    *wy = bd.y;
    *wm = bd.m + 1;
    *wd = bd.d;
    *wh = bd.h;
    *wmi = bd.mi;
    *ws = bd.s;
    *wms = (int)(ns_rem / 1000000);
    *wus = (int)((ns_rem % 1000000) / 1000);
    *wns = (int)(ns_rem % 1000);
    *off_sec = off;
}

fn void builtin_temporal_zoneddatetime_proto_year(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wy);
}

fn void builtin_temporal_zoneddatetime_proto_month(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wm);
}

fn void builtin_temporal_zoneddatetime_proto_monthCode(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    char[4] buf;
    buf[0] = 'M';
    buf[1] = (char)('0' + (int)(wm / 10));
    buf[2] = (char)('0' + (int)(wm % 10));
    buf[3] = 0;
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:3]));
}

fn void builtin_temporal_zoneddatetime_proto_day(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wd);
}

fn void builtin_temporal_zoneddatetime_proto_hour(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wh);
}

fn void builtin_temporal_zoneddatetime_proto_minute(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wmi);
}

fn void builtin_temporal_zoneddatetime_proto_second(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(ws);
}

fn void builtin_temporal_zoneddatetime_proto_millisecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wms);
}

fn void builtin_temporal_zoneddatetime_proto_microsecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wus);
}

fn void builtin_temporal_zoneddatetime_proto_nanosecond(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(wns);
}

fn void builtin_temporal_zoneddatetime_proto_offset(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    char[7] buf;
    format_offset_seconds(&buf[0], off);
    buf[6] = 0;
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:6]));
}

fn void builtin_temporal_zoneddatetime_proto_offsetNanoseconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_number((double)off * 1e9);
}

fn void builtin_temporal_zoneddatetime_proto_dayOfWeek(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long epoch_d = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd);
    long dow = ((epoch_d + 10) % 7) + 1;
    if (dow <= 0) dow += 7;
    ctx.result.set_fastint(dow);
}

fn void builtin_temporal_zoneddatetime_proto_dayOfYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long jan1 = temporal::epoch_days_from_civil(wy, 1, 1);
    long cur = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd);
    ctx.result.set_fastint(cur - jan1 + 1);
}

fn void builtin_temporal_zoneddatetime_proto_weekOfYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long jan4 = temporal::epoch_days_from_civil(wy, 1, 4);
    long dow_jan4 = ((jan4 + 10) % 7);
    long week1_monday = jan4 - dow_jan4;
    long cur = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd);
    long week = (cur - week1_monday) / 7 + 1;
    if (week < 1 || week > 53) {
        long prev_jan4 = temporal::epoch_days_from_civil(wy - 1, 1, 4);
        long dow_prev = ((prev_jan4 + 10) % 7);
        long prev_w1 = prev_jan4 - dow_prev;
        week = (cur - prev_w1) / 7 + 1;
    }
    if (week < 1) week = 1;
    if (week > 53) week = 53;
    ctx.result.set_fastint(week);
}

fn void builtin_temporal_zoneddatetime_proto_yearOfWeek(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long jan4 = temporal::epoch_days_from_civil(wy, 1, 4);
    long dow_jan4 = ((jan4 + 10) % 7);
    long week1_monday = jan4 - dow_jan4;
    long cur = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd);
    long year = wy;
    if (cur < week1_monday) { year -= 1; }
    else {
        long dec29 = temporal::epoch_days_from_civil(wy, 12, 29);
        long dow_dec29 = ((dec29 + 10) % 7);
        long last_week_monday = dec29 - dow_dec29;
        if (cur >= last_week_monday + 7) { year += 1; }
    }
    ctx.result.set_fastint(year);
}

fn void builtin_temporal_zoneddatetime_proto_daysInWeek(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    ctx.result.set_fastint(7);
}

fn void builtin_temporal_zoneddatetime_proto_daysInMonth(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_fastint(temporal::days_in_month(wy, (int)wm));
}

fn void builtin_temporal_zoneddatetime_proto_daysInYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long jan1 = temporal::epoch_days_from_civil(wy, 1, 1);
    long dec31 = temporal::epoch_days_from_civil(wy, 12, 31);
    ctx.result.set_fastint(dec31 - jan1 + 1);
}

fn void builtin_temporal_zoneddatetime_proto_monthsInYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    ctx.result.set_fastint(12);
}

fn void builtin_temporal_zoneddatetime_proto_inLeapYear(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    ctx.result.set_boolean(temporal::is_leap_year(wy));
}

fn void builtin_temporal_zoneddatetime_proto_hoursInDay(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    String zone = obj.extra.temporal.timezone == null ? "" : timezone_name(obj.extra.temporal.timezone);
    long epoch_secs;
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    if (b.fits_int128()) { epoch_secs = (long)(b.to_int128() / 1000000000); }
    else { double s_d; if (!bigint_to_epoch_number(b, &s_d, ctx)) return; epoch_secs = (long)math::floor(s_d / 1e9); }
    int off_start = 0;
    int off_end = 0;
    if (zone.len > 0 && zone.ptr != null) {
        long day_start_local = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
        long day_start_epoch = day_start_local - off;
        off_start = temporal::tzdb_offset_for_zone_at(zone, day_start_epoch);
        long day_end_epoch = day_start_epoch + 86400;
        off_end = temporal::tzdb_offset_for_zone_at(zone, day_end_epoch);
    }
    double hours = (double)(86400 + off_end - off_start) / 3600.0;
    ctx.result.set_number(hours);
}

fn void builtin_temporal_zoneddatetime_proto_era(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    ctx.result.set_string(builtin_intern_string(ctx.heap, "CE"));
}

fn void builtin_temporal_zoneddatetime_proto_eraYear(BuiltinContext* ctx) {
    builtin_temporal_zoneddatetime_proto_year(ctx);
}

fn void builtin_temporal_zoneddatetime_proto_toInstant(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    ((types::HeapHeader*)b).incref();
    HObject*? inst_o = alloc_instant(ctx.heap, b);
    ctx.heap.decref((types::HeapHeader*)b);
    if (catch err = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* inst = inst_o;
    inst.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(inst);
}

fn void builtin_temporal_zoneddatetime_proto_toPlainDateTime(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilDateTime wall_dt;
    wall_dt.date = { .y = wy, .m = wm, .d = wd };
    wall_dt.time = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns };
    HObject*? pdt_o = alloc_plain_datetime(ctx.heap, wall_dt, ctx.heap.temporal_iso_calendar);
    if (catch err = pdt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* pdt = pdt_o;
    pdt.prototype = ctx.heap.temporal_plain_datetime_proto;
    ctx.result.set_object(pdt);
}

fn void builtin_temporal_zoneddatetime_proto_toPlainTime(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilTime t;
    t.h = wh; t.mi = wmi; t.s = ws; t.ms = wms; t.us = wus; t.ns = wns;
    HObject*? pt_o = alloc_plain_time(ctx.heap, t);
    if (catch err = pt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* pt = pt_o;
    pt.prototype = ctx.heap.temporal_plain_time_proto;
    ctx.result.set_object(pt);
}

fn void builtin_temporal_zoneddatetime_proto_toPlainDate(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilDate d;
    d.y = wy; d.m = wm; d.d = wd;
    HObject*? pd_o = alloc_plain_date(ctx.heap, d, ctx.heap.temporal_iso_calendar);
    if (catch err = pd_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* pd = pd_o;
    pd.prototype = ctx.heap.temporal_plain_date_proto;
    ctx.result.set_object(pd);
}

fn void builtin_temporal_zoneddatetime_proto_startOfDay(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    long day_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
    double epoch_ns_d = (double)day_secs * 1e9 - (double)off * 1e9;
    hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, epoch_ns_d);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
    ((types::HeapHeader*)obj.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, (HString*)obj.extra.temporal.calendar);
}

fn void builtin_temporal_zoneddatetime_proto_getTimeZoneTransition(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) { builtin_throw(ctx, ctx.heap.type_err_proto, "getTimeZoneTransition requires a direction argument"); return; }
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    HObject* tz = obj.extra.temporal.timezone;
    if (tz == null) { ctx.result.set_undefined(); return; }
    // Create an Instant from this ZDT's epoch ns.
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    ((types::HeapHeader*)b).incref();
    HObject*? inst_o = alloc_instant(ctx.heap, b);
    ctx.heap.decref((types::HeapHeader*)b);
    if (catch err = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* inst = inst_o;
    inst.prototype = ctx.heap.temporal_instant_proto;
    // Read direction.
    TVal* dir_arg = arg_at(ctx, 0);
    String dir = "next";
    if (dir_arg.is_string()) {
        HString* ds = (HString*)dir_arg.get_heapptr();
        if (ds != null) dir = (String)ds.get_cstr()[:ds.blen];
    }
    // Delegate to TimeZone method.
    TVal saved_this = ctx.this_val;
    TVal inst_tv;
    inst_tv.set_object(inst);
    ctx.this_val.set_object(tz);
    ctx.regs[ctx.base_reg + 0] = inst_tv;
    ctx.argc = 1;
    if (dir == "next") {
        builtin_temporal_timezone_proto_getNextTransition(ctx);
    } else {
        builtin_temporal_timezone_proto_getPreviousTransition(ctx);
    }
    ctx.this_val = saved_this;
}

fn void builtin_temporal_zoneddatetime_proto_withPlainTime(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, off;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &off);
    temporal::CivilTime new_time;
    new_time.h = 0; new_time.mi = 0; new_time.s = 0;
    new_time.ms = 0; new_time.us = 0; new_time.ns = 0;
    if (ctx.argc >= 1) {
        TVal* arg = arg_at(ctx, 0);
        if (!arg.is_undefined()) {
            if (!arg.is_object() || arg.get_heapptr() == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "withPlainTime: argument must be an object, undefined, or null");
                return;
            }
            HObject* bag = (HObject*)arg.get_heapptr();
            if (!bag_to_time_fields(ctx, bag, false, new_time, &new_time)) {
                Vm* v = (Vm*)ctx.vm;
                if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
                return;
            }
        }
    }
    long day_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400
        + (long)new_time.h * 3600 + (long)new_time.mi * 60 + (long)new_time.s;
    long frac_ns = (long)new_time.ms * 1000000 + (long)new_time.us * 1000 + (long)new_time.ns;
    double epoch_ns_d = (double)day_secs * 1e9 + (double)frac_ns - (double)off * 1e9;
    hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, epoch_ns_d);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
    ((types::HeapHeader*)obj.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, (HString*)obj.extra.temporal.calendar);
}

fn void builtin_temporal_zoneddatetime_proto_round(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_ZONEDDATETIME, "this is not a Temporal.ZonedDateTime")) return;
    if (ctx.argc < 1) { builtin_throw(ctx, ctx.heap.type_err_proto, "round requires an options argument"); return; }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "round options must be an object"); return; }
    HObject* opts = (HObject*)arg.get_heapptr();
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();

    TVal su_v = prop_or_undefined_pa(ctx, opts, "smallestUnit");
    if (su_v.is_undefined()) { builtin_throw(ctx, ctx.heap.range_err_proto, "round requires a smallestUnit option"); return; }
    HString* su_str = builtin_to_string_vm(ctx, &su_v);
    if (ctx.should_throw) return;
    char[] unit = su_str.get_cstr()[:su_str.blen];

    long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
    zdt_wall_fields(obj, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);

    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    long epoch_secs;
    long ns_rem;
    if (b.fits_int128()) {
        int128 total = b.to_int128();
        epoch_secs = (long)(total / 1000000000);
        ns_rem = (long)(total - (int128)epoch_secs * 1000000000);
    } else {
        double s_d;
        if (!bigint_to_epoch_number(b, &s_d, ctx)) return;
        epoch_secs = (long)math::floor(s_d / 1e9);
        ns_rem = 0;
    }

    long result_secs = epoch_secs;
    long result_ns = ns_rem;

    if (unit == "day" || unit == "days") {
        long local_secs = epoch_secs + woff;
        long day_secs = temporal::epoch_days_from_civil(wy, (int)wm, (int)wd) * 86400;
        long diff = local_secs - day_secs;
        if (diff >= 43200) { day_secs += 86400; }
        result_secs = day_secs - woff;
        result_ns = 0;
    } else if (unit == "hour" || unit == "hours") {
        long local_secs = epoch_secs + woff;
        long hour_start = local_secs - (local_secs % 3600);
        long diff = local_secs - hour_start;
        if (diff > 1800 || diff == 1800) { hour_start += 3600; }
        result_secs = hour_start - woff;
        result_ns = 0;
    } else if (unit == "minute" || unit == "minutes") {
        long local_secs = epoch_secs + woff;
        long min_start = local_secs - (local_secs % 60);
        long diff = local_secs - min_start;
        if (diff >= 30) { min_start += 60; }
        result_secs = min_start - woff;
        result_ns = 0;
    } else if (unit == "second" || unit == "seconds") {
        long half = 500000000;
        if (result_ns >= half) { result_secs += 1; }
        result_ns = 0;
    } else if (unit == "millisecond" || unit == "milliseconds") {
        long ms_ns = (result_ns / 1000000) * 1000000;
        long diff = result_ns - ms_ns;
        if (diff >= 500000) { ms_ns += 1000000; }
        result_ns = ms_ns;
    } else if (unit == "microsecond" || unit == "microseconds") {
        long us_ns = (result_ns / 1000) * 1000;
        long diff = result_ns - us_ns;
        if (diff >= 500) { us_ns += 1000; }
        result_ns = us_ns;
    } else {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit for round");
        return;
    }

    double total_ns = (double)result_secs * 1e9 + (double)result_ns;
    hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, total_ns);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
    ((types::HeapHeader*)obj.extra.temporal.timezone).incref();
    zdt_from_parts(ctx, big_o, obj.extra.temporal.timezone, (HString*)obj.extra.temporal.calendar);
}
"""

# Insert before the setUpTemporalZonedDateTime function
idx = c.find('fn bool setUpTemporalZonedDateTime')
if idx > 0:
    c = c[:idx] + new_impls + "\n" + c[idx:]
else:
    print("ERROR: Could not find setUpTemporalZonedDateTime")
    exit(1)

with open('src/builtins/temporal.c3', 'w') as f:
    f.write(c)

print(f"Added implementations ({len(c)} bytes)")
