// Temporal.Duration bindings: constructor, statics, getters, and the
// prototype methods, including round() and total() with their relativeTo
// handling.
//
// The arithmetic itself is in lib/temporal/duration.c3; what remains here is
// argument coercion, options reading, and translating a library `false`
// return into the RangeError the spec asks for.
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
// Temporal.Duration
// ============================================================================

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

fn bool duration_field_integral_long(BuiltinContext* ctx, double val) {
    if (!duration_field_integral(ctx, val)) return false;
    if (math::abs(val) > 9223372036854775807.0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration field magnitude exceeds long range");
        return false;
    }
    return true;
}


// Read a Temporal.DurationLike argument and return its total nanoseconds as a
// freshly allocated BigInt. Used by AddDurationToOrSubtractDurationFromInstant
// so that sub-second fields larger than int64 (`{nanoseconds: 2e22}`) survive
// the conversion. The duration must be a Duration instance, a string, or a
// property bag with hour/minute/second/ms/us/ns; calendar units (years/months/
// weeks/days) are rejected with RangeError, matching the spec for Instant.
//
// On success, the returned BigInt's refcount is 1 and ownership passes to the
// caller. On failure the function has already thrown and returned false; the
// caller must not touch `*out_ns`.
fn bool duration_arg_to_ns_bigint(BuiltinContext* ctx, TVal* arg, hbigint::HBigInt** out_ns) {
    Vm* v = (Vm*)ctx.vm;
    // Start at zero.
    hbigint::HBigInt*? total_o = hbigint::hbigint_from_slimb(ctx.heap, 0);
    if (catch err = total_o) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration: alloc failed");
        return false;
    }
    hbigint::HBigInt* total = total_o;

    // Strings: parse to DurationParts, then convert.
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) { ctx.heap.decref((types::HeapHeader*)total); builtin_throw(ctx, ctx.heap.type_err_proto, "invalid string"); return false; }
        if (s.is_symbol()) { ctx.heap.decref((types::HeapHeader*)total); builtin_throw(ctx, ctx.heap.type_err_proto, "Duration: symbol cannot be converted"); return false; }
        temporal::DurationParts parts;
        if (!temporal::parse_duration(s.get_cstr()[:s.blen], &parts)) {
            ctx.heap.decref((types::HeapHeader*)total);
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid duration string");
            return false;
        }
        if (!temporal::is_valid_duration(&parts)) {
            ctx.heap.decref((types::HeapHeader*)total);
            builtin_throw(ctx, ctx.heap.range_err_proto, "duration is out of range");
            return false;
        }
        if (parts.years != 0 || parts.months != 0 || parts.weeks != 0 || parts.days != 0) {
            ctx.heap.decref((types::HeapHeader*)total);
            builtin_throw(ctx, ctx.heap.range_err_proto, "Instant does not accept calendar units");
            return false;
        }
        long[6] part_vals;
        long[6] part_scales;
        part_vals[0] = parts.hours;   part_scales[0] = temporal::NS_PER_HOUR;
        part_vals[1] = parts.minutes; part_scales[1] = temporal::NS_PER_MIN;
        part_vals[2] = parts.seconds; part_scales[2] = temporal::NS_PER_SEC;
        part_vals[3] = (long)parts.ms;      part_scales[3] = temporal::NS_PER_MS;
        part_vals[4] = (long)parts.us;      part_scales[4] = 1000L;
        part_vals[5] = (long)parts.ns;      part_scales[5] = 1L;
        for (int k = 0; k < 6; k++) {
            if (part_vals[k] == 0) continue;
            hbigint::HBigInt*? part_o = hbigint::hbigint_alloc(ctx.heap, (int128)part_vals[k]);
            if (catch err = part_o) { ctx.heap.decref((types::HeapHeader*)total); builtin_throw(ctx, ctx.heap.range_err_proto, "duration: alloc failed"); return false; }
            hbigint::HBigInt* part = part_o;
            hbigint::HBigInt*? scale_o = hbigint::hbigint_alloc(ctx.heap, (int128)part_scales[k]);
            if (catch err = scale_o) { ctx.heap.decref((types::HeapHeader*)part); ctx.heap.decref((types::HeapHeader*)total); builtin_throw(ctx, ctx.heap.range_err_proto, "duration: alloc failed"); return false; }
            hbigint::HBigInt* scale = scale_o;
            hbigint::HBigInt*? scaled = hbigint::hbigint_mul(ctx.heap, part, scale);
            ctx.heap.decref((types::HeapHeader*)part);
            ctx.heap.decref((types::HeapHeader*)scale);
            if (catch err = scaled) { ctx.heap.decref((types::HeapHeader*)total); builtin_throw(ctx, ctx.heap.range_err_proto, "duration: multiply failed"); return false; }
            hbigint::HBigInt*? new_total = hbigint::hbigint_addsub(ctx.heap, total, scaled, false);
            ctx.heap.decref((types::HeapHeader*)scaled);
            ctx.heap.decref((types::HeapHeader*)total);
            if (catch err = new_total) { builtin_throw(ctx, ctx.heap.range_err_proto, "duration: addsub failed"); return false; }
            total = new_total;
        }
        *out_ns = total;
        return true;
    }

    if (!arg.is_object() || arg.get_heapptr() == null) {
        ctx.heap.decref((types::HeapHeader*)total);
        builtin_throw(ctx, ctx.heap.type_err_proto, "argument must be a Temporal.Duration, duration string, or object");
        return false;
    }
    HObject* o = (HObject*)arg.get_heapptr();

    // Duration instance: copy the parts (calendar-unit check below).
    if (o.get_class() == hobject::ObjClass.TEMPORAL_DURATION) {
        temporal::DurationParts parts = duration_value(o);
        if (parts.years != 0 || parts.months != 0 || parts.weeks != 0 || parts.days != 0) {
            ctx.heap.decref((types::HeapHeader*)total);
            builtin_throw(ctx, ctx.heap.range_err_proto, "Instant does not accept calendar units");
            return false;
        }
        long[6] part_vals;
        long[6] part_scales;
        part_vals[0] = parts.hours;   part_scales[0] = temporal::NS_PER_HOUR;
        part_vals[1] = parts.minutes; part_scales[1] = temporal::NS_PER_MIN;
        part_vals[2] = parts.seconds; part_scales[2] = temporal::NS_PER_SEC;
        part_vals[3] = (long)parts.ms;      part_scales[3] = temporal::NS_PER_MS;
        part_vals[4] = (long)parts.us;      part_scales[4] = 1000L;
        part_vals[5] = (long)parts.ns;      part_scales[5] = 1L;
        for (int k = 0; k < 6; k++) {
            if (part_vals[k] == 0) continue;
            hbigint::HBigInt*? part_o = hbigint::hbigint_alloc(ctx.heap, (int128)part_vals[k]);
            if (catch err = part_o) { ctx.heap.decref((types::HeapHeader*)total); builtin_throw(ctx, ctx.heap.range_err_proto, "duration: alloc failed"); return false; }
            hbigint::HBigInt* part = part_o;
            hbigint::HBigInt*? scale_o = hbigint::hbigint_alloc(ctx.heap, (int128)part_scales[k]);
            if (catch err = scale_o) { ctx.heap.decref((types::HeapHeader*)part); ctx.heap.decref((types::HeapHeader*)total); builtin_throw(ctx, ctx.heap.range_err_proto, "duration: alloc failed"); return false; }
            hbigint::HBigInt* scale = scale_o;
            hbigint::HBigInt*? scaled = hbigint::hbigint_mul(ctx.heap, part, scale);
            ctx.heap.decref((types::HeapHeader*)part);
            ctx.heap.decref((types::HeapHeader*)scale);
            if (catch err = scaled) { ctx.heap.decref((types::HeapHeader*)total); builtin_throw(ctx, ctx.heap.range_err_proto, "duration: multiply failed"); return false; }
            hbigint::HBigInt*? new_total = hbigint::hbigint_addsub(ctx.heap, total, scaled, false);
            ctx.heap.decref((types::HeapHeader*)scaled);
            ctx.heap.decref((types::HeapHeader*)total);
            if (catch err = new_total) { builtin_throw(ctx, ctx.heap.range_err_proto, "duration: addsub failed"); return false; }
            total = new_total;
        }
        *out_ns = total;
        return true;
    }

    // Property bag. Reject calendar units; read hour/minute/second/ms/us/ns
    // as doubles, convert each to BigInt via hbigint_from_doubleint (exact
    // for finite integer doubles), then scale and add. The key trick: we
    // never go through `long`, so values like 2e22 ns survive.
    char[][] names = { "days", "hours", "microseconds", "milliseconds",
        "minutes", "months", "nanoseconds", "seconds", "weeks", "years" };
    int[] slot = { 3, 4, 8, 7, 5, 1, 9, 6, 2, 0 };
    bool any_field = false;
    int overall_sign = 0;
    // hours(4) minutes(5) seconds(6) ms(7) us(8) ns(9) contribute; years/months/weeks/days
    // are calendar units (rejected below).
    int[6] part_slot = { 4, 5, 6, 7, 8, 9 };
    long[6] part_scales = { temporal::NS_PER_HOUR, temporal::NS_PER_MIN, temporal::NS_PER_SEC, temporal::NS_PER_MS, 1000L, 1L };
    for (int i = 0; i < 10; i++) {
        int k = slot[i];
        TVal pv = prop_or_undefined_pa(ctx, o, names[i]);
        if (ctx.should_throw) { ctx.heap.decref((types::HeapHeader*)total); return false; }
        if (pv.is_undefined()) continue;
        any_field = true;
        double val = vm::vm_to_number(v, &pv);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; ctx.heap.decref((types::HeapHeader*)total); return false; }
        if (!duration_field_integral(ctx, val)) { ctx.heap.decref((types::HeapHeader*)total); return false; }
        // Only reject non-zero calendar units.
        if ((k == 0 || k == 1 || k == 2 || k == 3) && val != 0) {
            ctx.heap.decref((types::HeapHeader*)total);
            builtin_throw(ctx, ctx.heap.range_err_proto, "Instant does not accept calendar units");
            return false;
        }
        if (k == 0 || k == 1 || k == 2 || k == 3) continue;
        if (val != 0) {
            int s = val < 0 ? -1 : 1;
            if (overall_sign == 0) {
                overall_sign = s;
            } else if (overall_sign != s) {
                ctx.heap.decref((types::HeapHeader*)total);
                builtin_throw(ctx, ctx.heap.range_err_proto, "mixed-sign duration properties are not allowed");
                return false;
            }
        }
        // Find the scale for this slot.
        int scale_idx = -1;
        for (int s_i = 0; s_i < 6; s_i++) {
            if (part_slot[s_i] == k) { scale_idx = s_i; break; }
        }
        if (scale_idx < 0) continue;  // already rejected calendar units above
        if (val == 0) continue;
        hbigint::HBigInt*? part_o = hbigint::hbigint_from_double(ctx.heap, val);
        if (catch err = part_o) { ctx.heap.decref((types::HeapHeader*)total); builtin_throw(ctx, ctx.heap.range_err_proto, "duration: alloc failed"); return false; }
        hbigint::HBigInt* part = part_o;
        hbigint::HBigInt*? scale_o = hbigint::hbigint_alloc(ctx.heap, (int128)part_scales[scale_idx]);
        if (catch err = scale_o) { ctx.heap.decref((types::HeapHeader*)part); ctx.heap.decref((types::HeapHeader*)total); builtin_throw(ctx, ctx.heap.range_err_proto, "duration: alloc failed"); return false; }
        hbigint::HBigInt* scale = scale_o;
        hbigint::HBigInt*? scaled = hbigint::hbigint_mul(ctx.heap, part, scale);
        ctx.heap.decref((types::HeapHeader*)part);
        ctx.heap.decref((types::HeapHeader*)scale);
        if (catch err = scaled) { ctx.heap.decref((types::HeapHeader*)total); builtin_throw(ctx, ctx.heap.range_err_proto, "duration: multiply failed"); return false; }
        hbigint::HBigInt*? new_total = hbigint::hbigint_addsub(ctx.heap, total, scaled, false);
        ctx.heap.decref((types::HeapHeader*)scaled);
        ctx.heap.decref((types::HeapHeader*)total);
        if (catch err = new_total) { builtin_throw(ctx, ctx.heap.range_err_proto, "duration: addsub failed"); return false; }
        total = new_total;
    }
    if (!any_field) {
        ctx.heap.decref((types::HeapHeader*)total);
        builtin_throw(ctx, ctx.heap.type_err_proto, "duration property bag has no recognized fields");
        return false;
    }
    *out_ns = total;
    return true;
}

fn void builtin_temporal_duration_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Duration requires new");
        return;
    }
    Vm* v = (Vm*)ctx.vm;
    temporal::DurationParts d;
    d.years = 0; d.months = 0; d.weeks = 0; d.days = 0;
    d.hours = 0; d.minutes = 0; d.seconds = 0;
    d.ms = 0; d.us = 0; d.ns = 0;

    int arg_count = ctx.argc < 10 ? ctx.argc : 10;
    for (int k = 0; k < arg_count; k++) {
        TVal* arg = arg_at(ctx, k);
        if (arg.is_undefined()) continue; // spec: undefined args treated as zero
        double val = vm::vm_to_number(v, arg);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        if (!duration_field_integral_long(ctx, val)) return;
        long whole = (long)math::trunc(val);
        switch (k) {
            case 0: d.years = whole; break;
            case 1: d.months = whole; break;
            case 2: d.weeks = whole; break;
            case 3: d.days = whole; break;
            case 4: d.hours = whole; break;
            case 5: d.minutes = whole; break;
            case 6: d.seconds = whole; break;
            case 7: d.ms = whole; break;
            case 8: d.us = whole; break;
            default: d.ns = whole; break;
        }
    }
    if (!temporal::is_valid_duration(&d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid duration: components out of range or mixed signs");
        return;
    }
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_duration_proto);
    ctx.result.set_object(obj);
}

fn void builtin_temporal_duration_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Duration.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    temporal::DurationParts d;
    if (!duration_from_arg(ctx, arg, &d)) return;
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

// ToRelativeTemporalObject: read the `relativeTo` option out of `opts` (which
// may be null, meaning no options bag was supplied) and resolve it into a
// PlainDate or PlainDateTime object, writing null when the property is
// absent. Shared by Duration.compare / .round / .total, which all interpret
// relativeTo identically.
//
// Accepts:
//   * an existing PlainDate / PlainDateTime object (identity kept);
//   * a ZonedDateTime object (converted to its local wall-clock PlainDateTime,
//     since none of the three callers need the time zone itself -- they only
//     read the date fields off `long_a/long_b/long_c`);
//   * a property bag with year/month/day (+ optional time fields), which may
//     additionally carry `timeZone` (and `offset`), making it ZonedDateTime-
//     relative; the resolved local wall-clock is likewise converted to a
//     PlainDateTime;
//   * an ISO date or date-time string.
//
// Returns false with `ctx.should_throw` set on failure.
// Reads the `relativeTo` option. `out_is_zoned` reports whether the
// argument was zoned, which the caller CANNOT recover from the returned
// object: a `Temporal.ZonedDateTime` argument is converted to a
// `PlainDateTime` below (the ISO-calendar difference math wants
// wall-clock fields), so a `get_class()` check on the result would always
// say "not zoned". The spec needs the distinction — a plain relativeTo
// folds days as uniform 24-hour days (Add24HourDaysToTimeDuration), a
// zoned one defers to the tz rules (NudgeToZonedTime) — and the two agree
// only in zones without offset transitions, which is why dropping the flag
// stayed invisible under UTC.
fn bool read_relative_to_option(BuiltinContext* ctx, HObject* opts, HObject** out_relative_to, bool* out_is_zoned) {
    *out_relative_to = null;
    *out_is_zoned = false;
    if (opts == null) return true;
    TVal rv = prop_or_undefined_pa(ctx, opts, "relativeTo");
    if (ctx.should_throw) return false;
    if (rv.is_undefined()) return true;

    if (rv.is_object() && rv.get_heapptr() != null) {
        HObject* ro = (HObject*)rv.get_heapptr();
        if (ro.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATE ||
            ro.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            *out_relative_to = ro;
            return true;
        }
        if (ro.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            // Hand back the ZonedDateTime itself, not a PlainDateTime copy of
            // its wall fields. The zoned callers need the instant
            // (`extra.temporal.big_ns`) and the zone, which a PlainDateTime
            // does not carry; the two other zoned paths below (property bag,
            // bracketed string) already return a real ZonedDateTime, so this
            // makes `is_zoned == true` mean the same thing everywhere.
            *out_relative_to = ro;
            *out_is_zoned = true;
            return true;
        }

        // Property bag. ToRelativeTemporalObject reads every field via
        // PrepareTemporalFields in alphabetical order (calendar, day, hour,
        // ..., offset, second, timeZone, year); the unified reader resolves
        // `timeZone` and validates `offset` at their positions and reports
        // whether the bag is zoned. Missing date fields are a TypeError
        // (require_date); missing time fields default to 0.
        Vm* v = (Vm*)ctx.vm;
        temporal::CivilDateTime cur = { .date = { .y = 1970, .m = 1, .d = 1 }, .time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 } };
        temporal::CivilDateTime fields;
        bool _have_mc;
        int _mci;
        TVal _mc_v;
        bool has_tz = false;
        HObject* tz = null;
        bool has_offset_prop = false;
        long off_sec = 0;
        if (!bag_to_datetime_fields_ex(ctx, ro, TBM_ZDT, true, true, cur.date, cur.time, &fields,
                                       null, &_have_mc, &_mci, &_mc_v,
                                       &has_tz, &tz, &has_offset_prop, &off_sec)) {
            if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; }
            return false;
        }
        temporal::CivilDate valid_d;
        if (!fields_to_valid_date(ctx, fields.date, temporal::OverflowKind.CONSTRAIN, &valid_d)) return false;
        temporal::CivilTime valid_t;
        if (!fields_to_valid_time(ctx, fields.time, &valid_t, temporal::OverflowKind.CONSTRAIN, true)) return false;

        if (tz == null) {
            // If no time fields were supplied on the property bag, build a PlainDate;
            // otherwise build a PlainDateTime.
            bool has_time_props = !prop_or_undefined(ro, ctx.heap, "hour").is_undefined() ||
                                  !prop_or_undefined(ro, ctx.heap, "minute").is_undefined() ||
                                  !prop_or_undefined(ro, ctx.heap, "second").is_undefined() ||
                                  !prop_or_undefined(ro, ctx.heap, "millisecond").is_undefined() ||
                                  !prop_or_undefined(ro, ctx.heap, "microsecond").is_undefined() ||
                                  !prop_or_undefined(ro, ctx.heap, "nanosecond").is_undefined();
            if (ctx.should_throw) return false;
            if (!has_time_props) {
                HObject*? d_o = alloc_plain_date(ctx.heap, valid_d, ctx.heap.temporal_iso_calendar);
                if (catch err = d_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return false; }
                *out_relative_to = d_o;
                return true;
            }
            temporal::CivilDateTime dt = { .date = valid_d, .time = valid_t };
            HObject*? dt_o = alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
            if (catch err = dt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return false; }
            *out_relative_to = dt_o;
            return true;
        }

        // ZonedDateTime-relative bag: resolve the wall time to an instant
        // using the offset (explicit `offset` property, or the offset
        // implied by an offset-form time zone identifier), then convert
        // back to the zone's local wall-clock PlainDateTime -- callers only
        // read the date fields.
        if (!has_offset_prop) {
            String tzid_str = timezone_name(tz);
            usz k = 0;
            long tz_off = 0;
            if (temporal::parse_offset_only((char[])tzid_str, &k, &tz_off) && k == tzid_str.len) {
                off_sec = tz_off;
                has_offset_prop = true;
            }
        } else {
            String tzid_str = timezone_name(tz);
            usz k = 0;
            long tz_off = 0;
            if (temporal::parse_offset_only((char[])tzid_str, &k, &tz_off) && k == tzid_str.len) {
                if (tz_off != off_sec) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo: offset property does not agree with time zone");
                    return false;
                }
            }
        }
        long wall_secs = temporal::epoch_days_from_civil(valid_d.y, (int)valid_d.m, (int)valid_d.d) * 86400
            + (long)valid_t.h * 3600 + (long)valid_t.mi * 60 + (long)valid_t.s;
        long frac_ns = (long)valid_t.ms * 1000000 + (long)valid_t.us * 1000 + (long)valid_t.ns;
        // Combine in int128: double arithmetic here would drop every bit
        // below 2^53 and corrupt the sub-microsecond digits.
        int128 epoch_ns_128 = (int128)wall_secs * (int128)temporal::NS_PER_SEC + (int128)frac_ns
            - (int128)off_sec * (int128)temporal::NS_PER_SEC;
        hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, epoch_ns_128);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return false; }
        hbigint::HBigInt* epoch_ns = big_o;
        HString* cal_str = builtin_intern_string(ctx.heap, "iso8601");
        HObject*? zdt_o = alloc_zoneddatetime(ctx.heap, epoch_ns, tz, cal_str);
        ctx.heap.decref((types::HeapHeader*)epoch_ns);
        if (catch err = zdt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return false; }
        HObject* zdt = zdt_o;
        *out_relative_to = zdt;
        *out_is_zoned = true;
        return true;
    }

    if (rv.is_string()) {
        HString* rs = builtin_to_string_vm(ctx, &rv);
        if (ctx.should_throw) return false;
        char[] rtxt = rs.get_cstr()[:rs.blen];
        bool has_bracket = false;
        for (usz ci = 0; ci < rtxt.len; ci++) {
            if (rtxt[ci] == '[') { has_bracket = true; break; }
        }
        if (has_bracket) {
            TVal saved_res = *ctx.result;
            ctx.regs[ctx.base_reg + 0] = rv;
            ctx.argc = 1;
            builtin_temporal_zoneddatetime_from(ctx);
            if (ctx.should_throw) return false;
            if (ctx.result.is_object() && ctx.result.get_heapptr() != null) {
                HObject* zdt = (HObject*)ctx.result.get_heapptr();
                *ctx.result = saved_res;
                *out_relative_to = zdt;
                *out_is_zoned = true;
                return true;
            }
            *ctx.result = saved_res;
        }
        temporal::ParsedIsoDateTime p;
        if (!temporal::parse_iso_date_string(rtxt, &p)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid relativeTo string");
            return false;
        }
        // A date-time + Z (UTC designator) without an IANA bracket
        // annotation is ambiguous — reject it.
        if (p.offset_kind == temporal::OffsetKind.Z && !has_bracket) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "date-time + Z without an IANA annotation");
            return false;
        }
        if (p.has_time) {
            if (!temporal::is_valid_iso_datetime(p.year, p.month, p.day, p.hour, p.minute, p.second,
                                                 p.nanos / 1000000, (p.nanos / 1000) % 1000, p.nanos % 1000)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo datetime outside valid ISO range");
                return false;
            }
            temporal::CivilDateTime dt = {
                .date = { .y = p.year, .m = p.month, .d = p.day },
                .time = { .h = p.hour, .mi = p.minute, .s = p.second,
                          .ms = p.nanos / 1000000, .us = (p.nanos / 1000) % 1000,
                          .ns = p.nanos % 1000 },
            };
            HObject*? dt_o = alloc_plain_datetime(ctx.heap, dt, ctx.heap.temporal_iso_calendar);
            if (catch err = dt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return false; }
            *out_relative_to = dt_o;
        } else {
            if (!temporal::is_valid_iso_date(p.year, p.month, p.day)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo date outside valid ISO range");
                return false;
            }
            temporal::CivilDate dd = { .y = p.year, .m = p.month, .d = p.day };
            HObject*? dt_o = alloc_plain_date(ctx.heap, dd, ctx.heap.temporal_iso_calendar);
            if (catch err = dt_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return false; }
            *out_relative_to = dt_o;
        }
        return true;
    }

    builtin_throw(ctx, ctx.heap.type_err_proto, "relativeTo must be a string or object");
    return false;
}

fn void builtin_temporal_duration_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Duration.compare requires two arguments");
        return;
    }
    temporal::DurationParts da;
    if (!duration_from_arg(ctx, arg_at(ctx, 0), &da)) return;
    temporal::DurationParts db;
    if (!duration_from_arg(ctx, arg_at(ctx, 1), &db)) return;

    // Options bag: must be an object or undefined.
    HObject* opts = null;
    if (ctx.argc >= 3 && !arg_at(ctx, 2).is_undefined()) {
        TVal* ov = arg_at(ctx, 2);
        if (!ov.is_object() || ov.get_heapptr() == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object or undefined");
            return;
        }
        opts = (HObject*)ov.get_heapptr();
    }

    // relativeTo
    HObject* relative_to = null;
    bool rel_is_zoned = false;
    if (!read_relative_to_option(ctx, opts, &relative_to, &rel_is_zoned)) return;

    if (da.years == db.years && da.months == db.months && da.weeks == db.weeks && da.days == db.days &&
        da.hours == db.hours && da.minutes == db.minutes && da.seconds == db.seconds &&
        da.ms == db.ms && da.us == db.us && da.ns == db.ns) {
        ctx.result.set_number(0);
        return;
    }

    if (relative_to == null) {
        if (temporal::is_cal_unit(temporal::default_largest_unit(da)) || temporal::is_cal_unit(temporal::default_largest_unit(db))) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo is required to compare durations with calendar units");
            return;
        }
        int128 na = temporal::duration_to_time_ns(da);
        int128 nb = temporal::duration_to_time_ns(db);
        long cmp = na < nb ? -1 : (na > nb ? 1 : 0);
        ctx.result.set_number((double)cmp);
        return;
    }

    // Spec step 12: with a zoned relativeTo and a date-category largestUnit,
    // each duration is added via AddZonedDateTime and the resulting instants
    // are compared. That add is also the range check -- a duration that pushes
    // the target past the representable instant range throws rather than
    // comparing (test262 compare/throws-when-target-zoned-date-time-outside-
    // valid-limits), and it gets the day lengths right in a zone with offset
    // transitions.
    // Step 12 is gated on TemporalUnitCategory(largestUnit) being "date" for
    // at least one operand. A time-only pair (largestUnit hour or smaller)
    // skips AddZonedDateTime entirely and compares elapsed nanoseconds, so a
    // 5-minute duration relative to the maximum instant compares fine rather
    // than throwing (test262 compare/relativeto-string-limits).
    bool date_cat = temporal::is_date_unit(temporal::default_largest_unit(da)) || temporal::is_date_unit(temporal::default_largest_unit(db));
    if (rel_is_zoned && date_cat) {
        int128 after_a;
        int128 after_b;
        if (!add_zoned_datetime(relative_to, da, 1, temporal::OverflowKind.CONSTRAIN, &after_a) ||
            !add_zoned_datetime(relative_to, db, 1, temporal::OverflowKind.CONSTRAIN, &after_b)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
            return;
        }
        long zcmp = after_a < after_b ? -1 : (after_a > after_b ? 1 : 0);
        ctx.result.set_number((double)zcmp);
        return;
    }

    // With relativeTo: add each duration's date part to relativeTo's date and
    // compute total nanoseconds relative to that same origin, then compare.
    CivilDate rel_date;
    if (relative_to.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
        long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
        zdt_wall_fields(relative_to, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);
        rel_date = { .y = wy, .m = wm, .d = wd };
    } else {
        rel_date = { .y = relative_to.extra.temporal.long_a,
                     .m = relative_to.extra.temporal.long_b,
                     .d = relative_to.extra.temporal.long_c };
    }

    if (!temporal::is_cal_unit(temporal::default_largest_unit(da)) && !temporal::is_cal_unit(temporal::default_largest_unit(db))) {
        int128 na = temporal::duration_to_time_ns(da);
        int128 nb = temporal::duration_to_time_ns(db);
        long cmp = na < nb ? -1 : (na > nb ? 1 : 0);
        ctx.result.set_number((double)cmp);
        return;
    }

    int128 total_a = 0;
    int128 total_b = 0;
    if (!temporal::duration_total_ns_from(rel_date, da, &total_a) ||
        !temporal::duration_total_ns_from(rel_date, db, &total_b)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "date outside valid ISO range");
        return;
    }
    long cmp = total_a < total_b ? -1 : (total_a > total_b ? 1 : 0);
    ctx.result.set_number((double)cmp);
}


// Shared coercion from a string, Duration, or property bag into a Duration.
// Returns true on success; on failure throws and writes `ctx.should_throw`.
// Reused by the + / - / until / since / round operations on every Temporal
// type that takes a Duration argument.
fn bool duration_from_arg(BuiltinContext* ctx, TVal* arg, temporal::DurationParts* out) {
    // Duration.from and Duration.compare need the full ToTemporalDuration
    // validation: integral fields, sign consistency, and a recognized field.
    return duration_record_from_arg(ctx, arg, out);
}

// One getter for all ten duration fields, dispatched on the builtin index.
fn void builtin_temporal_duration_getter(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    HObject* obj = (HObject*)this_val.get_heapptr();
    double val = 0.0;
    switch ((TemporalBuiltin)((uint)(*(ctx.callee_obj.extra_ptr())).func.builtin_fn_index - TEMPORAL_BASE)) {
        case TemporalBuiltin.DURATION_PROTO_YEARS:        val = (double)obj.extra.temporal.long_a; break;
        case TemporalBuiltin.DURATION_PROTO_MONTHS:       val = (double)obj.extra.temporal.long_b; break;
        case TemporalBuiltin.DURATION_PROTO_WEEKS:        val = (double)obj.extra.temporal.long_c; break;
        case TemporalBuiltin.DURATION_PROTO_DAYS:         val = (double)obj.extra.temporal.long_d; break;
        case TemporalBuiltin.DURATION_PROTO_HOURS:        val = (double)obj.extra.temporal.long_e; break;
        case TemporalBuiltin.DURATION_PROTO_MINUTES:      val = (double)obj.extra.temporal.long_f; break;
        case TemporalBuiltin.DURATION_PROTO_SECONDS:      val = (double)obj.extra.temporal.long_g; break;
        case TemporalBuiltin.DURATION_PROTO_MILLISECONDS: val = bitcast((ulong)obj.extra.temporal.long_h, double); break;
        case TemporalBuiltin.DURATION_PROTO_MICROSECONDS: val = bitcast((ulong)obj.extra.temporal.long_i, double); break;
        case TemporalBuiltin.DURATION_PROTO_NANOSECONDS:  val = bitcast((ulong)obj.extra.temporal.long_j, double); break;
        default: break;
    }
    ctx.result.set_number(val);
}

fn void builtin_temporal_duration_proto_sign(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    long sign = 0;
    if (d.years < 0 || d.months < 0 || d.weeks < 0 || d.days < 0 ||
        d.hours < 0 || d.minutes < 0 || d.seconds < 0 || d.ms < 0 || d.us < 0 || d.ns < 0) { sign = -1; }
    else if (d.years > 0 || d.months > 0 || d.weeks > 0 || d.days > 0 ||
             d.hours > 0 || d.minutes > 0 || d.seconds > 0 || d.ms > 0 || d.us > 0 || d.ns > 0) { sign = 1; }
    ctx.result.set_fastint(sign);
}

fn void builtin_temporal_duration_proto_blank(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    bool blank = d.years == 0 && d.months == 0 && d.weeks == 0 && d.days == 0 &&
                 d.hours == 0 && d.minutes == 0 && d.seconds == 0 &&
                 d.ms == 0 && d.us == 0 && d.ns == 0;
    ctx.result.set_boolean(blank);
}

fn void builtin_temporal_duration_proto_negated(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    d.years = -d.years; d.months = -d.months; d.weeks = -d.weeks; d.days = -d.days;
    d.hours = -d.hours; d.minutes = -d.minutes; d.seconds = -d.seconds;
    d.ms = -d.ms; d.us = -d.us; d.ns = -d.ns;
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_duration_proto_abs(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    if (d.years < 0) d.years = -d.years;
    if (d.months < 0) d.months = -d.months;
    if (d.weeks < 0) d.weeks = -d.weeks;
    if (d.days < 0) d.days = -d.days;
    if (d.hours < 0) d.hours = -d.hours;
    if (d.minutes < 0) d.minutes = -d.minutes;
    if (d.seconds < 0) d.seconds = -d.seconds;
    if (d.ms < 0) d.ms = -d.ms;
    if (d.us < 0) d.us = -d.us;
    if (d.ns < 0) d.ns = -d.ns;
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

// Resolve the fractional-second precision, rounding mode, and rounding
// increment (in nanoseconds) for Duration.prototype.toString(options).
// Unlike to_string_precision (shared by Instant/ZonedDateTime, which also
// accept smallestUnit "minute" and larger units are always a RangeError for
// them too), Duration.toString restricts smallestUnit to the time units at
// or below "second" — "minute", "hour", and any calendar unit are a
// RangeError here. Options are read in the spec's alphabetical order:
// fractionalSecondDigits, roundingMode, smallestUnit.
fn bool duration_to_string_precision(BuiltinContext* ctx, int* digits, temporal::TemporalRoundMode* rm, long* incr_ns) {
    *digits = -1;   // auto
    *rm = temporal::TemporalRoundMode.TRUNC;
    *incr_ns = 1;
    if (ctx.argc < 1) return true;
    TVal ov = ctx.regs[ctx.base_reg + 0];
    if (ov.is_undefined()) return true;
    if (!ov.is_object() || ov.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    HObject* opts = (HObject*)ov.get_heapptr();

    TVal f = prop_or_undefined_pa(ctx, opts, "fractionalSecondDigits");
    if (ctx.should_throw) return false;
    if (!f.is_undefined()) {
        // GetStringOrNumberOption branches on the ORIGINAL value's type: a
        // Number is used numerically (floored, then range-checked), while
        // anything else is stringified and must match a valid string option
        // — here only "auto". A non-Number is never numerically parsed, so
        // e.g. 2n and {} are RangeErrors even though they stringify to "2"
        // and "[object Object]".
        if (f.is_numeric()) {
            double dv = f.get_number_or_fastint();
            double n = math::floor(dv);
            if (math::is_nan(dv) || n < 0 || n > 9) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be \"auto\" or 0-9");
                return false;
            }
            *digits = (int)n;
            // A numeric digit count also fixes the rounding increment, not
            // just the rendered precision: {fractionalSecondDigits: 6,
            // roundingMode: "ceil"} must round to 1us even without
            // smallestUnit.
            *incr_ns = (*digits == 9) ? 1 : temporal::ns_pow10(9 - *digits);
        } else {
            HString* s = builtin_to_string_vm(ctx, &f);
            if (ctx.should_throw) return false;
            if (s == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "fractionalSecondDigits must be a number or \"auto\"");
                return false;
            }
            char[] v = s.get_cstr()[:s.blen];
            if (v == "auto") { *digits = -1; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be \"auto\" or 0-9");
                return false;
            }
        }
    }

    TVal rmv = prop_or_undefined_pa(ctx, opts, "roundingMode");
    if (ctx.should_throw) return false;
    if (!rmv.is_undefined()) {
        HString* rm_s = builtin_to_string_vm(ctx, &rmv);
        if (ctx.should_throw) return false;
        if (rm_s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "roundingMode must be a string"); return false; }
        char[] v = rm_s.get_cstr()[:rm_s.blen];
        if (v == "ceil") { *rm = temporal::TemporalRoundMode.CEIL; }
        else if (v == "floor") { *rm = temporal::TemporalRoundMode.FLOOR; }
        else if (v == "expand") { *rm = temporal::TemporalRoundMode.EXPAND; }
        else if (v == "trunc") { *rm = temporal::TemporalRoundMode.TRUNC; }
        else if (v == "halfCeil") { *rm = temporal::TemporalRoundMode.HALF_CEIL; }
        else if (v == "halfFloor") { *rm = temporal::TemporalRoundMode.HALF_FLOOR; }
        else if (v == "halfExpand") { *rm = temporal::TemporalRoundMode.HALF_EXPAND; }
        else if (v == "halfTrunc") { *rm = temporal::TemporalRoundMode.HALF_TRUNC; }
        else if (v == "halfEven") { *rm = temporal::TemporalRoundMode.HALF_EVEN; }
        else { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode"); return false; }
    }

    TVal su = prop_or_undefined_pa(ctx, opts, "smallestUnit");
    if (ctx.should_throw) return false;
    if (!su.is_undefined()) {
        HString* su_s = builtin_to_string_vm(ctx, &su);
        if (ctx.should_throw) return false;
        if (su_s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "smallestUnit option must be a string"); return false; }
        char[] v = su_s.get_cstr()[:su_s.blen];
        // ToSecondsStringPrecisionRecord's [[Increment]]/[[Unit]] mapping,
        // restricted to units <= second (minute/hour and any calendar unit
        // are a RangeError for Duration.toString per spec step "If
        // smallestUnit is either hour or minute, throw a RangeError").
        if (v == "second" || v == "seconds")           { *digits = 0; *incr_ns = temporal::NS_PER_SEC; }
        else if (v == "millisecond" || v == "milliseconds") { *digits = 3; *incr_ns = temporal::NS_PER_MS; }
        else if (v == "microsecond" || v == "microseconds") { *digits = 6; *incr_ns = 1000L; }
        else if (v == "nanosecond" || v == "nanoseconds")   { *digits = 9; *incr_ns = 1L; }
        else { builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit"); return false; }
    }
    return true;
}

fn void builtin_temporal_duration_proto_toString(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    int digits;
    temporal::TemporalRoundMode rm;
    long incr_ns;
    if (!duration_to_string_precision(ctx, &digits, &rm, &incr_ns)) return;

    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());

    // No rounding requested (fractionalSecondDigits: "auto" and no
    // smallestUnit, i.e. RoundTimeDuration's increment is 1ns) -> format
    // with the requested (possibly still fixed, e.g. "auto") precision
    // without touching the stored value.
    if (incr_ns == 1) {
        char[160] buf;
        usz len = temporal::format_duration_precision(d, digits, &buf, 160);
        ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
        return;
    }

    // Round the time portion (RoundTimeDuration): combine hours..ns into a
    // single nanosecond count (using int128 so large values don't lose
    // precision through double math), round to a multiple of incr_ns, then
    // rebalance back into hours/minutes/seconds/ms/us/ns. Unlike duration
    // arithmetic, this never folds overflow into days — CombineDateAndTime
    // Duration leaves the date part untouched, and toString's smallestUnit
    // can only be second/millisecond/microsecond/nanosecond (never hour or
    // minute), so the largest unit stays within the time portion here.
    int128 total_ns = (int128)0;
    total_ns += (int128)d.hours   * temporal::NS_PER_HOUR;
    total_ns += (int128)d.minutes *   temporal::NS_PER_MIN;
    total_ns += (int128)d.seconds *    temporal::NS_PER_SEC;
    total_ns += (int128)d.ms      *       temporal::NS_PER_MS;
    total_ns += (int128)d.us      *          1000L;
    total_ns += (int128)d.ns;

    int128 sign_i = total_ns < 0 ? (int128)(-1) : (int128)1;
    int128 mag = total_ns < 0 ? -total_ns : total_ns;
    int128 incr = (int128)incr_ns;
    int128 q = mag / incr;
    int128 remv = mag % incr;
    if (remv != 0) {
        bool round_up;
        switch (rm) {
            case temporal::TemporalRoundMode.TRUNC:
            case temporal::TemporalRoundMode.FLOOR: round_up = false; break;
            case temporal::TemporalRoundMode.EXPAND:
            case temporal::TemporalRoundMode.CEIL: round_up = true; break;
            default: {
                // Half-* modes: compare remainder against half the
                // increment. mode_for_negative_magnitude flips ceil/floor
                // bias for a negative-signed duration so half-ceil/half-floor
                // remain magnitude-symmetric around zero (mirrors
                // round_long_ns's handling elsewhere in this file).
                temporal::TemporalRoundMode eff = sign_i < 0 ? temporal::mode_for_negative_magnitude(rm) : rm;
                int128 twice = remv * 2;
                if (twice < incr) { round_up = false; }
                else if (twice > incr) { round_up = true; }
                else {
                    switch (eff) {
                        case temporal::TemporalRoundMode.HALF_TRUNC:
                        case temporal::TemporalRoundMode.HALF_FLOOR: round_up = false; break;
                        case temporal::TemporalRoundMode.HALF_EXPAND:
                        case temporal::TemporalRoundMode.HALF_CEIL: round_up = true; break;
                        case temporal::TemporalRoundMode.HALF_EVEN: round_up = (q & 1) != 0; break;
                        default: round_up = false; break;
                    }
                }
                break;
            }
        }
        if (round_up) q += 1;
    }
    int128 rounded_ns = q * incr * sign_i;

    // Rebalance rounded_ns back into days/hours/minutes/seconds/ms/us/ns
    // per TemporalDurationFromInternal(internalDuration, roundedLargestUnit)
    // where roundedLargestUnit = LargerOfTwoTemporalUnits(
    // DefaultTemporalLargestUnit(<pre-rounding duration>), second):
    //   - date category (years/months/weeks/days present, i.e. any of
    //     those is non-zero): time balances all the way to hours, AND
    //     hour-overflow folds into the date part's days (verified against
    //     the reference polyfill: {days:5, seconds:90000, ms:900} with
    //     smallestUnit "second"/halfExpand -> "P6DT1H1S", i.e. 25.9h
    //     contributes +1 day).
    //   - hour category (no date fields, but hours present): time balances
    //     to hours only (no day fold).
    //   - minute category (no date/hour fields, but minutes present): time
    //     balances to minutes only (no hour fold — {minutes:1,
    //     seconds:90000} stays "PT1501M0S", not "PT25H1M0S").
    //   - otherwise (only seconds/ms/us/ns present, or an all-zero
    //     duration): time collapses fully into seconds (no minute fold —
    //     {seconds:59,ms:900} rounding past 60s stays "PT60S", not
    //     "PT1M0S").
    bool has_date_unit = d.years != 0 || d.months != 0 || d.weeks != 0 || d.days != 0;
    bool has_hour = d.hours != 0;
    bool has_minute = d.minutes != 0;

    temporal::DurationParts rd = d;
    int128 rmag = rounded_ns < 0 ? -rounded_ns : rounded_ns;
    long rsign = rounded_ns < 0 ? -1 : 1;
    if (has_date_unit) {
        long extra_days = rsign * (long)(rmag / temporal::NS_PER_DAY); rmag %= temporal::NS_PER_DAY;
        rd.days   += extra_days;
        rd.hours   = rsign * (long)(rmag / temporal::NS_PER_HOUR); rmag %= temporal::NS_PER_HOUR;
        rd.minutes = rsign * (long)(rmag /   temporal::NS_PER_MIN); rmag %=   temporal::NS_PER_MIN;
    } else if (has_hour) {
        rd.hours   = rsign * (long)(rmag / temporal::NS_PER_HOUR); rmag %= temporal::NS_PER_HOUR;
        rd.minutes = rsign * (long)(rmag /   temporal::NS_PER_MIN); rmag %=   temporal::NS_PER_MIN;
    } else if (has_minute) {
        rd.hours   = 0;
        rd.minutes = rsign * (long)(rmag /   temporal::NS_PER_MIN); rmag %=   temporal::NS_PER_MIN;
    } else {
        rd.hours   = 0;
        rd.minutes = 0;
    }
    rd.seconds = rsign * (long)(rmag /    temporal::NS_PER_SEC); rmag %=    temporal::NS_PER_SEC;
    rd.ms      = (double)(rsign * (long)(rmag /       temporal::NS_PER_MS)); rmag %=       temporal::NS_PER_MS;
    rd.us      = (double)(rsign * (long)(rmag /          1000L)); rmag %=          1000L;
    rd.ns      = (double)(rsign * (long)(rmag));

    // Per spec, after rounding the time portion must remain within ±2^53
    // seconds (RegulateTimeDuration / IsValidDuration). Calendar-unit
    // overflows (year/month/week) are unbounded, but seconds here is a
    // value derived solely from the time portion. Fold any pre-existing
    // date-unit days into the bound check too, so {days: N, seconds: x}
    // with x + N*86400 ≥ 2^53 also throws.
    int128 sec_total = (int128)rd.seconds + (int128)rd.days * 86400L
                     + (int128)rd.hours * 3600L + (int128)rd.minutes * 60L;
    int128 max_secs = (int128)9007199254740992L;  // 2^53
    if (sec_total >= max_secs || sec_total <= -max_secs) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration out of range");
        return;
    }

    char[160] buf;
    usz len = temporal::format_duration_precision(rd, digits, &buf, 160);
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
}


fn void builtin_temporal_duration_proto_add(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.add requires an argument");
        return;
    }
    temporal::DurationParts other;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &other)) return;
    temporal::DurationParts a = duration_value((HObject*)this_val.get_heapptr());
    temporal::DurationParts result;
    if (!temporal::add_durations_no_relative(a, other, &result)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Duration arithmetic produced an out-of-range result");
        return;
    }
    if (!temporal::is_valid_duration(&result)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration is out of range");
        return;
    }
    HObject*? obj_o = alloc_duration(ctx.heap, result);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_duration_proto_subtract(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.subtract requires an argument");
        return;
    }
    temporal::DurationParts other;
    if (!duration_record_from_arg(ctx, arg_at(ctx, 0), &other)) return;
    // Negate and add.
    other.years = -other.years;
    other.months = -other.months;
    other.weeks = -other.weeks;
    other.days = -other.days;
    other.hours = -other.hours;
    other.minutes = -other.minutes;
    other.seconds = -other.seconds;
    other.ms = -other.ms;
    other.us = -other.us;
    other.ns = -other.ns;
    temporal::DurationParts a = duration_value((HObject*)this_val.get_heapptr());
    temporal::DurationParts result;
    if (!temporal::add_durations_no_relative(a, other, &result)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Duration arithmetic produced an out-of-range result");
        return;
    }
    if (!temporal::is_valid_duration(&result)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration is out of range");
        return;
    }
    HObject*? obj_o = alloc_duration(ctx.heap, result);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

// Duration.prototype.with: copy `this` and overwrite the named fields. Unknown
// properties are ignored, mirroring the basic test's
// "incorrectly-spelled properties are ignored" case.
fn void builtin_temporal_duration_proto_with(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    if (ctx.argc < 1 || !arg_at(ctx, 0).is_object() || arg_at(ctx, 0).get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.with requires a property bag");
        return;
    }
    HObject* bag = (HObject*)arg_at(ctx, 0).get_heapptr();
    if (!reject_temporal_object_bag(ctx, bag)) return;
    temporal::DurationParts d = duration_value((HObject*)this_val.get_heapptr());
    // Spec reads fields in alphabetical order: days, hours, microseconds,
    // milliseconds, minutes, months, nanoseconds, seconds, weeks, years.
    // All 10 must be probed even when absent so a Proxy observer sees every
    // get call (order-of-operations test fixture depends on this).
    char[][] names = { "days", "hours", "microseconds", "milliseconds",
        "minutes", "months", "nanoseconds", "seconds", "weeks", "years" };
    // Slot index maps alphabetical read order back to field position:
    // 0=years 1=months 2=weeks 3=days 4=hours 5=minutes 6=seconds 7=ms 8=us 9=ns
    int[10] slot = { 3, 4, 8, 7, 5, 1, 9, 6, 2, 0 };
    Vm* v = (Vm*)ctx.vm;
    bool found_any = false;
    for (int k = 0; k < 10; k++) {
        TVal pv = prop_or_undefined_pa(ctx, bag, names[k]);
        if (ctx.should_throw) return;
        if (pv.is_undefined()) continue;
        found_any = true;
        double val = vm::vm_to_number(v, &pv);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        if (!duration_field_integral_long(ctx, val)) return;
        long whole = (long)math::trunc(val);
        switch (slot[k]) {
            case 0: d.years = whole; break;
            case 1: d.months = whole; break;
            case 2: d.weeks = whole; break;
            case 3: d.days = whole; break;
            case 4: d.hours = whole; break;
            case 5: d.minutes = whole; break;
            case 6: d.seconds = whole; break;
            case 7: d.ms = (double)whole; break;
            case 8: d.us = (double)whole; break;
            case 9: d.ns = (double)whole; break;
        }
    }
    if (!found_any) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.with requires at least one recognized property");
        return;
    }
    if (!temporal::is_valid_duration(&d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid duration result");
        return;
    }
    HObject*? obj_o = alloc_duration(ctx.heap, d);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_duration_proto_toJSON(BuiltinContext* ctx) {
    // toJSON takes no options and always formats at "auto" precision, so the
    // caller's arguments must not reach the toString delegate.
    ctx.argc = 0;
    builtin_temporal_duration_proto_toString(ctx);
}

fn void builtin_temporal_duration_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    ctx.argc = 0;
    builtin_temporal_duration_proto_toString(ctx);
}

fn void builtin_temporal_duration_proto_valueOf(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Duration cannot be converted to a primitive number");
}

// ============================================================================
// Duration.prototype.round / .total — unit, rounding, helpers
// ============================================================================








// Throws unless the increment is a legal divisor of the next-higher unit
// (divides it evenly, and is not the full unit). Calendar units have no fixed
// length, so any positive integer is accepted there. Returns false after
// throwing.
fn bool validate_rounding_increment(BuiltinContext* ctx, temporal::TemporalUnit unit, double increment) {
    if (increment < 1.0 || increment > 1e9) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
        return false;
    }
    long max_incr = temporal::max_round_incr(unit);
    if (max_incr > 0) {
        if ((double)max_incr / increment != math::floor((double)max_incr / increment)
            || increment == (double)max_incr) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
            return false;
        }
    }
    return true;
}


















// ============================================================================
// Temporal.Duration.prototype.round
// ============================================================================

fn void builtin_temporal_duration_proto_round(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    if (ctx.argc < 1 || arg_at(ctx, 0).is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.round requires an argument");
        return;
    }
    temporal::DurationParts dur = duration_value((HObject*)this_val.get_heapptr());

    TVal* round_to = arg_at(ctx, 0);
    bool string_shorthand = round_to.is_string();
    if (!string_shorthand && !round_to.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.round requires an object or string argument");
        return;
    }
    HObject* opts = null;
    temporal::TemporalUnit smallest_unit = temporal::TemporalUnit.NANOSECOND;
    bool smallest_was_set = false;
    temporal::TemporalUnit largest_unit = temporal::TemporalUnit.NANOSECOND;
    bool largest_was_set = false;
    double rounding_increment = 1;
    temporal::TemporalRoundMode rounding_mode = temporal::TemporalRoundMode.HALF_EXPAND;
    HObject* relative_to = null;
    bool rel_is_zoned = false;
    bool largest_provided = false;

    if (string_shorthand) {
        HString* ss = builtin_to_string_vm(ctx, round_to);
        if (ctx.should_throw) return;
        if (!temporal::parse_unit_str(ss.get_cstr()[:ss.blen], &smallest_unit)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
            return;
        }
        smallest_was_set = true;
    } else {
        opts = (HObject*)round_to.get_heapptr();
        if (opts == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object or string");
            return;
        }
        // largestUnit
        TVal lu_tv = prop_or_undefined_pa(ctx, opts, "largestUnit");
        if (!lu_tv.is_undefined()) {
            largest_provided = true;
            HString* lu_s = builtin_to_string_vm(ctx, &lu_tv);
            if (ctx.should_throw) return;
            char[] lu_str = lu_s.get_cstr()[:lu_s.blen];
            if (lu_str != "auto") {
                largest_was_set = true;
                if (!temporal::parse_unit_str(lu_str, &largest_unit)) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "invalid largestUnit");
                    return;
                }
            }
        }
        // relativeTo
        if (!read_relative_to_option(ctx, opts, &relative_to, &rel_is_zoned)) return;
        // roundingIncrement
        TVal ri_tv = prop_or_undefined_pa(ctx, opts, "roundingIncrement");
        if (!ri_tv.is_undefined()) {
            Vm* v = (Vm*)ctx.vm;
            double ri_val = vm::vm_to_number(v, &ri_tv);
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
        // roundingMode
        TVal rm_tv = prop_or_undefined_pa(ctx, opts, "roundingMode");
        if (!rm_tv.is_undefined()) {
            HString* rm_s = builtin_to_string_vm(ctx, &rm_tv);
            if (ctx.should_throw) return;
            if (!temporal::parse_rm_str(rm_s.get_cstr()[:rm_s.blen], &rounding_mode)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return;
            }
        }
        // smallestUnit
        TVal su_tv = prop_or_undefined_pa(ctx, opts, "smallestUnit");
        if (!su_tv.is_undefined()) {
            smallest_was_set = true;
            HString* su_s = builtin_to_string_vm(ctx, &su_tv);
            if (ctx.should_throw) return;
            if (!temporal::parse_unit_str(su_s.get_cstr()[:su_s.blen], &smallest_unit)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
                return;
            }
        }
    }

    temporal::TemporalUnit existing = temporal::default_largest_unit(dur);
    temporal::TemporalUnit default_lu = temporal::larger_unit(existing, smallest_unit);
    if (!largest_was_set) largest_unit = default_lu;

    if (!smallest_was_set && !largest_provided) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "at least one of smallestUnit or largestUnit must be provided");
        return;
    }
    if (temporal::larger_unit(largest_unit, smallest_unit) != largest_unit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "largestUnit must not be smaller than smallestUnit");
        return;
    }
    if (!validate_rounding_increment(ctx, smallest_unit, rounding_increment)) return;
    if (rounding_increment > 1 && largest_unit != smallest_unit && temporal::is_date_unit(smallest_unit)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement > 1 is not allowed with calendar smallestUnit unless largestUnit equals smallestUnit");
        return;
    }

    bool is_blank = dur.years == 0 && dur.months == 0 && dur.weeks == 0 && dur.days == 0 &&
                    dur.hours == 0 && dur.minutes == 0 && dur.seconds == 0 &&
                    dur.ms == 0 && dur.us == 0 && dur.ns == 0;
    if (is_blank && !temporal::is_cal_unit(smallest_unit) && smallest_unit != temporal::TemporalUnit.DAY &&
                    !temporal::is_cal_unit(largest_unit) && largest_unit != temporal::TemporalUnit.DAY) {
        temporal::DurationParts zero_dur = {};
        HObject*? obj_o = alloc_duration(ctx.heap, zero_dur);
        if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* obj = obj_o;
        obj.prototype = ctx.heap.temporal_duration_proto;
        ctx.result.set_object(obj);
        return;
    }

    // No-relativeTo: time-only path.
    if (relative_to == null) {
        if (temporal::is_cal_unit(existing) || temporal::is_cal_unit(largest_unit)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo is required for calendar units");
            return;
        }
        int128 time_ns = temporal::duration_to_time_ns(dur);
        // Spec's RoundTimeDuration is an integer operation on the time
        // duration (RoundNumberToIncrement on nanoseconds); rounding stays in
        // int128 so a duration longer than ~292 years does not overflow a
        // 64-bit count, and the ℝ(𝔽()) precision loss lands at decomposition.
        long divisor = (smallest_unit == temporal::TemporalUnit.DAY) ? temporal::NS_PER_DAY : temporal::unit_ns_divisor(smallest_unit);
        int128 incr_ns = (int128)rounding_increment * (int128)divisor;
        if (incr_ns <= 0) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement too large");
            return;
        }
        int128 rounded_ns;
        if (incr_ns == 1) {
            rounded_ns = time_ns;
        } else {
            rounded_ns = temporal::round_long_ns_128(time_ns, incr_ns, rounding_mode);
        }
        temporal::DurationParts result;
        temporal::decompose_ns_128(rounded_ns, largest_unit, &result);
        if (!temporal::is_valid_duration(&result)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "duration is out of range");
            return;
        }
        HObject*? obj_o = alloc_duration(ctx.heap, result);
        if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* obj = obj_o;
        obj.prototype = ctx.heap.temporal_duration_proto;
        ctx.result.set_object(obj);
        return;
    }

    // With relativeTo: calendar-aware rounding path.
    // Spec algorithm for plainRelativeTo:
    // 1. ToInternalDurationRecordWith24HourDays(duration) → {date, time}
    // 2. AddTime(MidnightTimeRecord(), time) → targetTime
    // 3. AdjustDateDurationRecord(date, targetTime.days)
    // 4. CalendarDateAdd(calendar, relativeTo, dateDuration) → targetDate
    // 5. isoDateTime = (relativeTo, MidnightTimeRecord)
    // 6. targetDateTime = (targetDate, targetTime.time)
    // 7. DifferencePlainDateTimeWithRounding(isoDateTime, targetDateTime, ...)
    //
    // For ISO calendar this simplifies to: compute total ns between the two
    // date-times, round, decompose.

    // Extract relativeTo date fields.
    CivilDate rel_date;
    temporal::CivilTime rel_time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
    bool is_zdt = rel_is_zoned;
    if (is_zdt) {
        long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
        zdt_wall_fields(relative_to, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);
        rel_date = { .y = wy, .m = wm, .d = wd };
        rel_time = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns };
        hbigint::HBigInt* start_big = (hbigint::HBigInt*)relative_to.extra.temporal.big_ns;
        int128 start_ns = start_big.to_int128();
        int128 dur_time_ns = temporal::duration_to_time_ns(dur);
        int128 target_instant_ns = start_ns + dur_time_ns;
        int128 ns_limit = temporal::INSTANT_MAX_NS;

        if (target_instant_ns > ns_limit || target_instant_ns < -ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
            return;
        }

        // NudgeToZonedTime needs the length of the day the result lands in,
        // which means resolving the next day's boundary. At the top of the
        // representable range that boundary does not exist, and the spec
        // throws rather than rounding -- even for a blank duration, since the
        // boundary is computed before the nudge decides nothing moves. Only
        // a day-or-larger largestUnit reaches that step (test262
        // round/next-day-out-of-range).
        // NudgeToZonedTime is reached when largestUnit is exactly "day" and
        // smallestUnit is a time unit: that combination has to know the length
        // of the day the result falls in, so it resolves the next day's
        // boundary. A calendar largestUnit routes to NudgeToCalendarUnit
        // instead, which derives its own boundary and must not be pre-empted
        // here -- doing so throws for the blank-duration cases in
        // round/relativeto-date-limits.
        if (largest_unit == temporal::TemporalUnit.DAY &&
            !temporal::is_cal_unit(smallest_unit) && smallest_unit != temporal::TemporalUnit.DAY) {
            bool neg = dur.years < 0 || dur.months < 0 || dur.weeks < 0 || dur.days < 0 ||
                       dur.hours < 0 || dur.minutes < 0 || dur.seconds < 0 ||
                       dur.ms < 0 || dur.us < 0 || dur.ns < 0;
            long dir = neg ? -1 : 1;
            temporal::DurationParts one_day = {};
            one_day.days = 1;
            int128 boundary;
            if (!add_zoned_datetime(relative_to, one_day, dir, temporal::OverflowKind.CONSTRAIN, &boundary)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "next day boundary is outside the valid time range");
                return;
            }
        }
    } else {
        rel_date = { .y = relative_to.extra.temporal.long_a,
                     .m = relative_to.extra.temporal.long_b,
                     .d = relative_to.extra.temporal.long_c };
        if (relative_to.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            rel_time = plain_datetime_value(relative_to).time;
        }
    }

    // RoundRelativeDuration returns before any range validation when the
    // duration is blank, so a relativeTo one step outside the representable
    // range (the minimum date -271821-04-19) rounds a blank duration to zero
    // but still throws for a non-blank one. test262 round/relativeto-date-
    // limits covers the first, round/relativeto-string-limits the second.
    if (!is_blank && !temporal::is_cal_unit(smallest_unit) && smallest_unit != temporal::TemporalUnit.DAY) {
        long rel_days = temporal::epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
        if (!temporal::epoch_days_in_range(rel_days)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo is outside representable range after conversion to DateTime");
            return;
        }
    }

    // Step 1: Compute time-only (no days) for AddTime.
    int128 time_only_ns = temporal::duration_time_part_ns(dur);

    // Step 2: AddTime(Midnight, time_only) → targetTime
    long target_time_days = (long)(time_only_ns / temporal::NS_PER_DAY);
    int128 target_time_rem = time_only_ns % temporal::NS_PER_DAY;
    if (time_only_ns < 0 && target_time_rem != 0) {
        target_time_days -= 1;
        target_time_rem += temporal::NS_PER_DAY;
    }

    // Step 3: AdjustDateDurationRecord(date, date.days + targetTime.days)
    // dateDuration = {years, months, weeks, dur.days + target_time_days}
    long adj_days = dur.days + target_time_days;

    // Step 4: Add dateDuration to rel_date → targetDate
    CivilDate target_date = rel_date;
    if (dur.years != 0) target_date = temporal::add_months(target_date, dur.years * 12, temporal::OverflowKind.CONSTRAIN);
    if (dur.months != 0) target_date = temporal::add_months(target_date, dur.months, temporal::OverflowKind.CONSTRAIN);
    if (dur.weeks != 0) target_date = temporal::add_days(target_date, dur.weeks * 7);
    if (adj_days != 0) target_date = temporal::add_days(target_date, adj_days);
    // As above: skipped entirely for a blank duration.
    if (!is_blank) {
        long rel_days = temporal::epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
        long tgt_days = temporal::epoch_days_from_civil(target_date.y, (int)target_date.m, (int)target_date.d);
        if (!temporal::epoch_days_in_range(rel_days) || !temporal::epoch_days_in_range(tgt_days)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "ISO date outside representable range");
            return;
        }
    }

    long rem = (long)target_time_rem;
    long h  = rem / temporal::NS_PER_HOUR; rem = (long)(rem % temporal::NS_PER_HOUR);
    long mi = rem / temporal::NS_PER_MIN;   rem = (long)(rem % temporal::NS_PER_MIN);
    long s  = rem / temporal::NS_PER_SEC;    rem = (long)(rem % temporal::NS_PER_SEC);
    long ms = rem / temporal::NS_PER_MS;       rem = (long)(rem % temporal::NS_PER_MS);
    long us = rem / 1000L;
    long ns = rem % 1000L;
    // is_valid_iso_datetime excludes the minimum date at exactly midnight,
    // because that instant falls below the PlainDateTime range. That rule is
    // right for a PlainDateTime but not for a PlainDate relativeTo, which the
    // spec keeps on the date axis: rounding a blank duration relative to
    // -271821-04-19 yields zero (test262 round/relativeto-date-limits).
    if (!is_blank &&
        !temporal::is_valid_iso_datetime(target_date.y, target_date.m, target_date.d, h, mi, s, ms, us, ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "date out of range");
        return;
    }

    // Steps 5-6: isoDateTime = (rel_date, midnight), targetDateTime = (target_date, target_time_rem)

    // Step 7: Round the difference. Delegate to the PlainDateTime path: the
    // same algorithm that backs PlainDateTime.prototype.round and until/since,
    // which already balances calendar units at largestUnit and handles the
    // day-borrow for a negative time-of-day remainder.
    temporal::CivilDateTime iso_dt = { .date = rel_date, .time = {} };
    temporal::CivilDateTime target_dt = { .date = target_date,
        .time = { .h = h, .mi = mi, .s = s, .ms = ms, .us = us, .ns = ns } };
    DiffSettings rds = { .largest = largest_unit, .smallest = smallest_unit,
                         .mode = rounding_mode, .increment = rounding_increment,
                         .is_zoned = is_zdt };
    temporal::DurationParts result;
    if (!datetime_difference(ctx, iso_dt, target_dt, rds, &result)) return;

    if (!temporal::is_valid_duration(&result)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration is out of range");
        return;
    }
    HObject*? obj_o = alloc_duration(ctx.heap, result);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(obj);
}

// ============================================================================
// Temporal.Duration.prototype.total
// ============================================================================

fn void builtin_temporal_duration_proto_total(BuiltinContext* ctx) {
    TVal* this_val = &ctx.regs[ctx.base_reg - 1];
    if (!brand_check(ctx, this_val, hobject::ObjClass.TEMPORAL_DURATION, "this is not a Temporal.Duration")) return;
    if (ctx.argc < 1 || arg_at(ctx, 0).is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.total requires an argument");
        return;
    }
    temporal::DurationParts dur = duration_value((HObject*)this_val.get_heapptr());

    TVal* total_of = arg_at(ctx, 0);
    bool string_shorthand = total_of.is_string();
    if (!string_shorthand && !total_of.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Duration.prototype.total requires an object or string argument");
        return;
    }
    HObject* opts = null;
    temporal::TemporalUnit unit = temporal::TemporalUnit.NANOSECOND;
    HObject* relative_to = null;
    bool rel_is_zoned = false;

    if (string_shorthand) {
        HString* ss = builtin_to_string_vm(ctx, total_of);
        if (ctx.should_throw) return;
        if (!temporal::parse_unit_str(ss.get_cstr()[:ss.blen], &unit)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid unit");
            return;
        }
    } else {
        opts = (HObject*)total_of.get_heapptr();
        if (opts == null) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object or string");
            return;
        }
        // Per spec, options are read in alphabetical order before any
        // algorithmic validation: relativeTo first, then unit. Reading them
        // in any other order surfaces unit-validation errors before the
        // caller has observed relativeTo, breaking options-read-before-
        // algorithmic-validation tests.
        if (!read_relative_to_option(ctx, opts, &relative_to, &rel_is_zoned)) return;
        TVal unit_tv = prop_or_undefined_pa(ctx, opts, "unit");
        if (ctx.should_throw) return;
        if (unit_tv.is_undefined()) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "unit is required");
            return;
        }
        HString* unit_s = builtin_to_string_vm(ctx, &unit_tv);
        if (ctx.should_throw) return;
        if (!temporal::parse_unit_str(unit_s.get_cstr()[:unit_s.blen], &unit)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid unit");
            return;
        }
    }

    bool is_blank = dur.years == 0 && dur.months == 0 && dur.weeks == 0 && dur.days == 0 &&
                    dur.hours == 0 && dur.minutes == 0 && dur.seconds == 0 &&
                    dur.ms == 0 && dur.us == 0 && dur.ns == 0;
    // A blank duration adds nothing, but AddZonedDateTime/CalendarDateAdd
    // still run against relativeTo per spec, so a relativeTo outside the
    // representable range must still throw. Only skip straight to 0 when
    // there is no relativeTo to validate.
    if (is_blank && relative_to == null) {
        ctx.result.set_number(0.0);
        return;
    }

    temporal::TemporalUnit existing = temporal::default_largest_unit(dur);
    if (relative_to == null) {
        if (temporal::is_cal_unit(existing) || temporal::is_cal_unit(unit)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo is required for calendar units");
            return;
        }
        int128 time_ns = temporal::duration_to_time_ns(dur);
        long div_ns = unit == temporal::TemporalUnit.DAY
            ? temporal::NS_PER_DAY
            : temporal::unit_ns_divisor(unit);
        // DivideNormalizedTimeDuration divides the exact mathematical total
        // by the divisor once, rounding straight to the nearest double; see
        // divide_time_duration for why neither a plain int128→double cast-
        // then-divide nor a `whole + rem/div` split reproduces that single
        // rounding step (test262 precision-exact-mathematical-values-6/7).
        ctx.result.set_number(temporal::divide_time_duration(time_ns, div_ns));
        return;
    }
    // Always compute and validate target datetime with relative_to:
    CivilDate rel_date;
    temporal::CivilTime rel_time = { .h = 0, .mi = 0, .s = 0, .ms = 0, .us = 0, .ns = 0 };
    bool is_zdt = rel_is_zoned;
    if (is_zdt) {
        long wy, wm, wd; int wh, wmi, ws, wms, wus, wns, woff;
        zdt_wall_fields(relative_to, &wy, &wm, &wd, &wh, &wmi, &ws, &wms, &wus, &wns, &woff);
        rel_date = { .y = wy, .m = wm, .d = wd };
        rel_time = { .h = wh, .mi = wmi, .s = ws, .ms = wms, .us = wus, .ns = wns };
        hbigint::HBigInt* start_big = (hbigint::HBigInt*)relative_to.extra.temporal.big_ns;
        int128 start_ns = start_big.to_int128();
        int128 dur_time_ns = temporal::duration_to_time_ns(dur);
        int128 target_instant_ns = start_ns + dur_time_ns;
        int128 ns_limit = temporal::INSTANT_MAX_NS;

        if (target_instant_ns > ns_limit || target_instant_ns < -ns_limit) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
            return;
        }
        if (unit == temporal::TemporalUnit.DAY || unit == temporal::TemporalUnit.WEEK || unit == temporal::TemporalUnit.MONTH || unit == temporal::TemporalUnit.YEAR) {
            int128 one_day_ns = (int128)temporal::NS_PER_DAY;
            bool is_neg = dur.years < 0 || dur.months < 0 || dur.weeks < 0 || dur.days < 0 ||
                          dur.hours < 0 || dur.minutes < 0 || dur.seconds < 0 || dur.ms < 0 || dur.us < 0 || dur.ns < 0;
            if (!is_neg && start_ns + one_day_ns > ns_limit) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
                return;
            }
            if (is_neg && start_ns - one_day_ns < -ns_limit) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
                return;
            }
        }

        // Spec TotalRelativeDuration for a zoned relativeTo. Days here are
        // calendar days resolved against the zone, not a flat 24 hours, so
        // the total has to be measured on the instant axis via
        // AddZonedDateTime rather than by the shared uniform-day path below.
        if (!temporal::is_cal_unit(unit)) {
            int128 target_ns;
            if (!add_zoned_datetime(relative_to, dur, 1, temporal::OverflowKind.CONSTRAIN, &target_ns)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
                return;
            }
            int128 elapsed = target_ns - start_ns;

            if (unit != temporal::TemporalUnit.DAY) {
                // Hours and below are uniform on the instant axis.
                long div_ns = temporal::unit_ns_divisor(unit);
                int128 whole = elapsed / (int128)div_ns;
                int128 rem = elapsed - whole * (int128)div_ns;
                ctx.result.set_number((double)whole + (double)rem / (double)div_ns);
                return;
            }

            // Days are not uniform in a zone with offset transitions: the
            // spec's NudgeToCalendarUnit walks whole calendar days from the
            // start, then expresses the leftover as a fraction of the *next*
            // day's own length. Across a US spring-forward, 1d12h is 24h then
            // 12h into a 23h day, i.e. 1 + 12/23 -- not 36/24.
            long step = elapsed < 0 ? -1 : 1;
            long days = 0;
            int128 prev = (int128)0;
            temporal::DurationParts probe = {};
            while (true) {
                probe.days = days + step;
                int128 next_ns;
                if (!add_zoned_datetime(relative_to, probe, 1, temporal::OverflowKind.CONSTRAIN, &next_ns)) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside representable range");
                    return;
                }
                int128 next = next_ns - start_ns;
                // Stop once one more whole day would overshoot the target.
                if (step > 0 ? next > elapsed : next < elapsed) {
                    // `day_len` and `rem` share the direction's sign, so their
                    // quotient is a positive fraction of one day; `days`
                    // already carries the sign.
                    int128 day_len = next - prev;
                    if (day_len == 0) { ctx.result.set_number((double)days); return; }
                    int128 rem = elapsed - prev;
                    double frac = (double)rem / (double)day_len;
                    ctx.result.set_number((double)days + (double)step * frac);
                    return;
                }
                prev = next;
                days += step;
            }
        }
    } else {
        rel_date = { .y = relative_to.extra.temporal.long_a,
                     .m = relative_to.extra.temporal.long_b,
                     .d = relative_to.extra.temporal.long_c };
        if (relative_to.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
            rel_time = plain_datetime_value(relative_to).time;
        }
    }

    int128 time_only_ns = temporal::duration_time_part_ns(dur);
    time_only_ns += (int128)rel_time.h  * temporal::NS_PER_HOUR +
                    (int128)rel_time.mi *   temporal::NS_PER_MIN +
                    (int128)rel_time.s  *    temporal::NS_PER_SEC +
                    (int128)rel_time.ms *       temporal::NS_PER_MS +
                    (int128)rel_time.us *          1000L +
                    (int128)rel_time.ns;
    long target_time_days = (long)(time_only_ns / temporal::NS_PER_DAY);
    int128 target_time_rem = time_only_ns % temporal::NS_PER_DAY;
    if (time_only_ns < 0 && target_time_rem != 0) {
        target_time_days -= 1;
        target_time_rem += temporal::NS_PER_DAY;
    }
    long adj_days = dur.days + target_time_days;
    CivilDate target_date = rel_date;
    if (dur.years != 0) target_date = temporal::add_months(target_date, dur.years * 12, temporal::OverflowKind.CONSTRAIN);
    if (dur.months != 0) target_date = temporal::add_months(target_date, dur.months, temporal::OverflowKind.CONSTRAIN);
    if (dur.weeks != 0) target_date = temporal::add_days(target_date, dur.weeks * 7);
    if (adj_days != 0) target_date = temporal::add_days(target_date, adj_days);

    int128 rem_work = target_time_rem;
    long tgt_h = (long)(rem_work / temporal::NS_PER_HOUR); rem_work %= temporal::NS_PER_HOUR;
    long tgt_mi = (long)(rem_work / temporal::NS_PER_MIN); rem_work %= temporal::NS_PER_MIN;
    long tgt_s = (long)(rem_work / temporal::NS_PER_SEC); rem_work %= temporal::NS_PER_SEC;
    long tgt_ms = (long)(rem_work / temporal::NS_PER_MS); rem_work %= temporal::NS_PER_MS;
    long tgt_us = (long)(rem_work / 1000L); rem_work %= 1000L;
    long tgt_ns = (long)rem_work;

    // DifferencePlainDateTimeWithTotal: if the two ISO date-times are equal
    // (e.g. a blank duration), it returns 0 immediately -- before any range
    // validation of either date-time runs. That short-circuit is why a
    // relativeTo sitting exactly on an excluded boundary (a valid ISODate,
    // but not a valid ISODateTime) still totals to 0 rather than throwing,
    // and why the fraction-of-a-unit math below never runs (and can't leave
    // a floating-point residual) when nothing changed.
    bool datetimes_equal = target_date.y == rel_date.y && target_date.m == rel_date.m &&
                           target_date.d == rel_date.d && tgt_h == rel_time.h && tgt_mi == rel_time.mi &&
                           tgt_s == rel_time.s && tgt_ms == rel_time.ms && tgt_us == rel_time.us &&
                           tgt_ns == rel_time.ns;
    if (datetimes_equal) {
        ctx.result.set_number(0.0);
        return;
    }

    if (!temporal::is_valid_iso_date(target_date.y, (int)target_date.m, (int)target_date.d) ||
        !temporal::is_valid_iso_date(rel_date.y, (int)rel_date.m, (int)rel_date.d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "ISO date outside representable range");
        return;
    }

    if (relative_to.get_class() == hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
        long rel_days = temporal::epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
        long tgt_days = temporal::epoch_days_from_civil(target_date.y, (int)target_date.m, (int)target_date.d);
        if (!temporal::epoch_days_in_range(rel_days) || !temporal::epoch_days_in_range(tgt_days)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "ISO date outside representable range");
            return;
        }
    }

    if (!temporal::is_cal_unit(unit) && unit != temporal::TemporalUnit.DAY) {
        long rel_days = temporal::epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
        if (!temporal::epoch_days_in_range(rel_days)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo is outside representable range after conversion to DateTime");
            return;
        }
    }

    if (!temporal::is_valid_iso_datetime(target_date.y, target_date.m, target_date.d, tgt_h, tgt_mi, tgt_s, tgt_ms, tgt_us, tgt_ns)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "relativeTo + duration is out of range");
        return;
    }

    bool has_cal = dur.years != 0 || dur.months != 0 || dur.weeks != 0;
    if (!temporal::is_cal_unit(unit) && !has_cal) {
        int128 time_ns = temporal::duration_to_time_ns(dur);
        long div_ns = unit == temporal::TemporalUnit.DAY
            ? temporal::NS_PER_DAY
            : temporal::unit_ns_divisor(unit);
        ctx.result.set_number(temporal::divide_time_duration(time_ns, div_ns));
        return;
    }
    long rel_epoch = temporal::epoch_days_from_civil(rel_date.y, (int)rel_date.m, (int)rel_date.d);
    long tgt_epoch = temporal::epoch_days_from_civil(target_date.y, (int)target_date.m, (int)target_date.d);
    // Calculate relativeTo time in nanoseconds
    int128 relativeTo_time_ns = (int128)rel_time.h * temporal::NS_PER_HOUR +
                                (int128)rel_time.mi * temporal::NS_PER_MIN +
                                (int128)rel_time.s * temporal::NS_PER_SEC +
                                (int128)rel_time.ms * temporal::NS_PER_MS +
                                (int128)rel_time.us * 1000L +
                                (int128)rel_time.ns;
    // Calculate time difference: (relativeTo time + duration time) - relativeTo time
    int128 time_diff_ns = target_time_rem - relativeTo_time_ns;
    int128 days_diff_ns = (int128)(tgt_epoch - rel_epoch) * temporal::NS_PER_DAY;
    // Handle negative time difference by borrowing a day
    if (time_diff_ns < 0) {
        days_diff_ns -= temporal::NS_PER_DAY;
        time_diff_ns += temporal::NS_PER_DAY;
    }
    int128 diff_ns = days_diff_ns + time_diff_ns;
    long divisor = temporal::unit_ns_divisor(unit);
    if (divisor > 0) {
        ctx.result.set_number(temporal::divide_time_duration(diff_ns, divisor));
        return;
    }
    if (unit == temporal::TemporalUnit.DAY) {
        ctx.result.set_number(temporal::divide_time_duration(diff_ns, temporal::NS_PER_DAY));
        return;
    }
    if (unit == temporal::TemporalUnit.WEEK) {
        // Include the time remainder (target_time_rem) so 10 days 12 hours
        // reports as 1.5 weeks, not 1.42857 (= 10/7). The plain day count
        // (tgt_epoch - rel_epoch) drops any sub-day remainder, which is
        // wrong for total().
        long div_ns = 7L * temporal::NS_PER_DAY;
        ctx.result.set_number(temporal::divide_time_duration(diff_ns, div_ns));
        return;
    }
    // Re-decompose (relTo + duration) into the calendar-aware {years,
    // months, weeks, days} that DifferenceISODateTime would produce, so r1
    // (the trunc'd unit count) reflects the actual calendar span rather
    // than only what's in the input duration's years/months fields. Without
    // this, an `until()` that defaulted to days gives r1 = 0 even for a
    // multi-year span and the formula collapses to diff_ns / unit_ns.
    if (unit != temporal::TemporalUnit.MONTH && unit != temporal::TemporalUnit.YEAR) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "unsupported unit for total");
        return;
    }
    temporal::DateDifference dd;
    if (unit == temporal::TemporalUnit.YEAR) {
        dd = temporal::difference_date(rel_date, target_date, temporal::DifferenceUnit.YEARS);
    } else {
        dd = temporal::difference_date(rel_date, target_date, temporal::DifferenceUnit.MONTHS);
    }
    long r1;
    long sign = dur.years >= 0 && dur.months >= 0 && dur.weeks >= 0 && dur.days >= 0
        && dur.hours >= 0 && dur.minutes >= 0 && dur.seconds >= 0
        && dur.ms >= 0 && dur.us >= 0 && dur.ns >= 0
        ? 1 : -1;
    CivilDate unit_start;
    CivilDate unit_end;
    if (unit == temporal::TemporalUnit.YEAR) {
        r1 = dd.years;
        unit_start = temporal::add_months(rel_date, r1 * 12, temporal::OverflowKind.CONSTRAIN);
        unit_end = temporal::add_months(rel_date, (r1 + sign) * 12, temporal::OverflowKind.CONSTRAIN);
    } else {
        r1 = dd.months;
        unit_start = temporal::add_months(rel_date, r1, temporal::OverflowKind.CONSTRAIN);
        unit_end = temporal::add_months(rel_date, r1 + sign, temporal::OverflowKind.CONSTRAIN);
    }
    // NudgeToCalendarUnit step 8 computes the increment-beyond boundary with
    // CalendarDateAdd, which rejects a result outside the representable ISO
    // range. add_months constrains silently instead, so check both boundaries
    // explicitly: at the maximum date (+275760-09-13) one more year or month
    // is not representable and total() must throw (test262 total/
    // throws-if-date-time-invalid-with-plaindate-relative).
    if (!temporal::is_valid_iso_date(unit_start.y, (int)unit_start.m, (int)unit_start.d) ||
        !temporal::is_valid_iso_date(unit_end.y, (int)unit_end.m, (int)unit_end.d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "rounded date outside valid ISO range");
        return;
    }
    long start_epoch = temporal::epoch_days_from_civil(unit_start.y, (int)unit_start.m, (int)unit_start.d);
    long end_epoch   = temporal::epoch_days_from_civil(unit_end.y, (int)unit_end.m, (int)unit_end.d);
    int128 unit_ns = (int128)(end_epoch - start_epoch) * temporal::NS_PER_DAY;
    if (unit_ns < 0) unit_ns = -unit_ns;
    if (unit_ns <= 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "duration out of range");
        return;
    }
    int128 dest_ns = (int128)(tgt_epoch - rel_epoch) * temporal::NS_PER_DAY + target_time_rem;
    int128 start_ns_offset = (int128)(start_epoch - rel_epoch) * temporal::NS_PER_DAY;
    int128 numerator = dest_ns - start_ns_offset;
    int128 total_num = unit_ns * (int128)r1 + numerator;
    // Convert the full `r1 + numerator/unit_ns` to a Number with the one
    // rounding step TotalRelativeDuration's exact division requires — see
    // divide_time_duration for why a plain int128→double cast-then-divide
    // (or a `whole + rem/div` split) double-rounds and can land on the
    // wrong adjacent double (test262 precision-exact-mathematical-values-5..7,
    // relativeto-total-of-each-unit).
    ctx.result.set_number(temporal::divide_time_duration(total_num, unit_ns));
}

