// Temporal.TimeZone bindings: constructor, from(), id, and
// getOffsetNanosecondsFor. The tz database lookup itself is in
// lib/temporal/tzdb.c3.
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
// Phase 2 — Temporal.TimeZone (minimal: ctor, from, id, getOffsetNanosecondsFor)
// ============================================================================

// A TimeZone heap object holds just the IANA zone name as a string. The
// offset lookups are pure calls into the tzdb module.
fn HObject*? alloc_timezone(Heap* hp, String zone_name) {
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_TIMEZONE);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    HString* str = builtin_intern_string(hp, zone_name);
    // Store the zone name in the calendar slot (we have no other string slot
    // in HObjectTemporal for the TZ). Calendar and TimeZone never coexist
    // on the same instance, so reusing the slot is safe and saves memory.
    obj.extra.temporal.calendar = (HObject*)str;
    obj.extra.temporal.timezone = null;
    return obj;
}

// Extract the IANA zone name string from a TimeZone heap object.
fn String timezone_name(HObject* obj) {
    HString* str = (HString*)obj.extra.temporal.calendar;
    if (str == null) return "";
    return (String)str.get_cstr()[:str.blen];
}

fn void builtin_temporal_timezone_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.TimeZone requires new");
        return;
    }
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.TimeZone requires an identifier argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    String s;
    if (arg.is_string()) {
        HString* hs = (HString*)arg.get_heapptr();
        s = (String)hs.get_cstr()[:hs.blen];
    } else {
        Vm* v = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(v, arg, 0);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        if (!prim.is_string()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.TimeZone identifier must be a string");
            return;
        }
        HString* hs = (HString*)prim.get_heapptr();
        s = (String)hs.get_cstr()[:hs.blen];
    }
    if (!temporal::tzdb_zone_exists(s)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Unknown time zone");
        return;
    }
    HObject*? obj_o = alloc_timezone(ctx.heap, s);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_timezone_proto);
    ctx.result.set_object(obj);
}

fn void builtin_temporal_timezone_from(BuiltinContext* ctx) {
    // For Phase 2, from() === ctor().
    builtin_temporal_timezone_ctor(ctx);
}

fn void builtin_temporal_timezone_proto_id(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_TIMEZONE, "this is not a Temporal.TimeZone")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    HString* str = (HString*)obj.extra.temporal.calendar;
    if (str == null) { ctx.result.set_string(builtin_intern_string(ctx.heap, "")); return; }
    ctx.result.set_string(str);
}

// getOffsetNanosecondsFor(instant) returns the zone's offset at the given
// Instant's epoch_ns as a Number.
fn void builtin_temporal_timezone_proto_getOffsetNanosecondsFor(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_TIMEZONE, "this is not a Temporal.TimeZone")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getOffsetNanosecondsFor requires an Instant argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_INSTANT) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getOffsetNanosecondsFor requires a Temporal.Instant");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    String zone = timezone_name(self);
    hbigint::HBigInt* ns = ((HObject*)arg.get_heapptr()).extra.temporal.big_ns;
    double secs_d;
    if (!bigint_to_epoch_number(ns, &secs_d, ctx)) return;
    long secs = (long)math::floor(secs_d / 1e9);
    int offset_sec = temporal::tzdb_offset_for_zone_at(zone, secs);
    ctx.result.set_number((double)offset_sec * 1e9);
}


// getPossibleInstantsFor(plainDateTime) resolves a wall-clock PlainDateTime in
// this zone to the concrete UTC instants it can denote. The wall time in a
// DST overlap maps to two instants; a gap (a wall time that does not exist,
// e.g. the hour skipped at spring-forward) maps to none. Unique wall times
// map to one. Naive resolution: treat the wall clock as UTC, compare the
// offset iteratively, and disambiguate by determinism (offsetBefore vs the
// offsets at the candidate instants).
fn void builtin_temporal_timezone_proto_getPossibleInstantsFor(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_TIMEZONE, "this is not a Temporal.TimeZone")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getPossibleInstantsFor requires a PlainDateTime argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_PLAIN_DATETIME) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getPossibleInstantsFor requires a Temporal.PlainDateTime");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    String zone = timezone_name(self);
    HObject* pdt = (HObject*)arg.get_heapptr();
    temporal::CivilDateTime c = plain_datetime_value(pdt);
    long wall_secs = temporal::epoch_days_from_civil(c.date.y, (int)c.date.m, (int)c.date.d) * 86400
        + (long)c.time.h * 3600 + (long)c.time.mi * 60 + (long)c.time.s;
    long frac_ns = (long)c.time.ms * 1000000 + (long)c.time.us * 1000 + (long)c.time.ns;
    double naive_ns = (double)wall_secs * 1e9 + (double)frac_ns;

    // Candidate UTC offsets: the offset in effect at the naive wall time, plus
    // the offsets of every transition within a 2-day window. In an overlap or a
    // gap the DST flip bracketing the wall time contributes its pre/post
    // offsets here; each candidate is then tested for self-consistency below.
    int[8] cand;
    int nc = 0;
    temporal::tz_cand_add(cand[..], &nc, temporal::tzdb_offset_for_zone_at(zone, wall_secs));
    temporal::TzdbTransition[] trans = temporal::tzdb_zone_transitions(zone);
    long window = 2 * 86400;
    for (usz i = 0; i < trans.len; i++) {
        if (trans[i].epoch_sec >= wall_secs - window && trans[i].epoch_sec <= wall_secs + window) {
            temporal::tz_cand_add(cand[..], &nc, trans[i].offset_sec);
        }
    }
    if (nc == 0) temporal::tz_cand_add(cand[..], &nc, 0);

    // For each candidate offset, the hypothetical instant is naive - offset;
    // keep it only if the zone's offset there really is that offset (i.e. the
    // wall-clock mapping is stable). Collect unique matching instants.
    double[4] hits;
    int nh = 0;
    for (int k = 0; k < nc; k++) {
        double cand_ns = naive_ns - (double)cand[k] * 1e9;
        long cand_sec = (long)math::floor(cand_ns / 1e9);
        int real_off = temporal::tzdb_offset_for_zone_at(zone, cand_sec);
        if (real_off != cand[k]) continue;
        double e_ns = naive_ns - (double)real_off * 1e9;
        bool dup = false;
        for (int j = 0; j < nh; j++) {
            if (hits[j] == e_ns) { dup = true; break; }
        }
        if (!dup && nh < 4) { hits[nh] = e_ns; nh++; }
    }

    // Sort ascending by epoch (an overlap yields the two instants in order).
    for (int i = 0; i < nh; i++) {
        for (int j = i + 1; j < nh; j++) {
            if (hits[j] < hits[i]) { double t = hits[i]; hits[i] = hits[j]; hits[j] = t; }
        }
    }

    HObject*? arr_o = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* arr = arr_o;
    arr.prototype = ctx.heap.array_proto;
    for (int i = 0; i < nh; i++) {
        hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, hits[i]);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
        HObject*? inst_o = alloc_instant(ctx.heap, big_o);
        ctx.heap.decref((types::HeapHeader*)big_o);
        if (catch err2 = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* inst = inst_o;
        inst.prototype = ctx.heap.temporal_instant_proto;
        TVal tv;
        tv.set_object(inst);
        if (!arr.set_array_idx((uint)i, tv, ctx.heap)) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    }
    *arr.array_len_ptr() = (uint)nh;
    ctx.result.set_object(arr);
}

// Both transition methods collapse consecutive transitions whose UTC offset
// does not actually change (abbreviation-only edits in the IANA source), and
// treat the zone's pre-history initial offset as the offset before the first
// recorded transition.

// getNextTransition(startingInstant) — first later transition that changes
// the UTC offset, or null if there is none.
fn void builtin_temporal_timezone_proto_getNextTransition(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_TIMEZONE, "this is not a Temporal.TimeZone")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getNextTransition requires an Instant argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_INSTANT) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getNextTransition requires a Temporal.Instant");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    String zone = timezone_name(self);
    hbigint::HBigInt* start = ((HObject*)arg.get_heapptr()).extra.temporal.big_ns;
    double s_d;
    if (!bigint_to_epoch_number(start, &s_d, ctx)) return;
    long start_sec = (long)math::floor(s_d / 1e9);
    bool start_has_sub = s_d - (double)start_sec * 1e9 != 0.0;

    temporal::TzdbTransition[] trans = temporal::tzdb_zone_transitions(zone);
    int prev_off = temporal::tzdb_zone_initial_offset(zone);
    for (usz i = 0; i < trans.len; i++) {
        if (trans[i].offset_sec == prev_off) continue;   // no real offset change
        prev_off = trans[i].offset_sec;
        bool after = trans[i].epoch_sec > start_sec
            || (trans[i].epoch_sec == start_sec && start_has_sub);
        if (!after) continue;
        double ns = (double)trans[i].epoch_sec * 1e9;
        hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, ns);
        if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
        HObject*? inst_o = alloc_instant(ctx.heap, big_o);
        ctx.heap.decref((types::HeapHeader*)big_o);
        if (catch err2 = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* inst = inst_o;
        inst.prototype = ctx.heap.temporal_instant_proto;
        ctx.result.set_object(inst);
        return;
    }
    // No transition after the start instant.
    ctx.result.set_null();
}

// getPreviousTransition(startingInstant) — last earlier transition that
// changes the UTC offset, or null if there is none.
fn void builtin_temporal_timezone_proto_getPreviousTransition(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_TIMEZONE, "this is not a Temporal.TimeZone")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getPreviousTransition requires an Instant argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (!arg.is_object() || arg.get_heapptr() == null
        || ((HObject*)arg.get_heapptr()).get_class() != hobject::ObjClass.TEMPORAL_INSTANT) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "getPreviousTransition requires a Temporal.Instant");
        return;
    }
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    String zone = timezone_name(self);
    hbigint::HBigInt* start = ((HObject*)arg.get_heapptr()).extra.temporal.big_ns;
    double s_d;
    if (!bigint_to_epoch_number(start, &s_d, ctx)) return;
    long start_sec = (long)math::floor(s_d / 1e9);
    bool start_has_sub = s_d - (double)start_sec * 1e9 != 0.0;

    temporal::TzdbTransition[] trans = temporal::tzdb_zone_transitions(zone);
    int prev_off = temporal::tzdb_zone_initial_offset(zone);
    long last_epoch = -1;
    for (usz i = 0; i < trans.len; i++) {
        if (trans[i].offset_sec == prev_off) continue;   // no real offset change
        prev_off = trans[i].offset_sec;
        bool before = trans[i].epoch_sec < start_sec
            || (trans[i].epoch_sec == start_sec && start_has_sub);
        if (before) last_epoch = trans[i].epoch_sec;
    }
    if (last_epoch < 0) { ctx.result.set_null(); return; }
    double ns = (double)last_epoch * 1e9;
    hbigint::HBigInt*? big_o = hbigint::hbigint_from_double(ctx.heap, ns);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return; }
    HObject*? inst_o = alloc_instant(ctx.heap, big_o);
    ctx.heap.decref((types::HeapHeader*)big_o);
    if (catch err2 = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* inst = inst_o;
    inst.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(inst);
}

