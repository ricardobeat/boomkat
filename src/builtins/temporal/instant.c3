// Temporal.Instant bindings: constructor, the epoch-* statics, getters, and
// prototype methods. The epoch nanoseconds live in a JS BigInt, so this file
// owns the conversion to and from the library's int128 form.
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
// Phase 2 — Temporal.Instant
// ============================================================================

// Bridge between the JS-facing BigInt representation and the pure int128
// arithmetic in lib/temporal/instant.c3. Temporal exposes epoch nanoseconds as
// a BigInt, so the value arrives and leaves as an HBigInt; the calendrical
// arithmetic itself needs no heap and no engine, which is why it lives in the
// library rather than here.
//
// int128 covers the spec's +/-8.64e21 ns range with room to spare, so these
// cannot overflow for in-range inputs. Out-of-range results are a spec error
// and are rejected by the caller's range check, not here.
fn hbigint::HBigInt*? instant_add_big(hbigint::HBigInt* a, hbigint::HBigInt* delta, Heap* hp) {
    if (a == null || delta == null) return null;
    int128 res = temporal::instant_add(a.to_int128(), delta.to_int128());
    if (!temporal::instant_in_range(res)) return null;
    return hbigint::hbigint_alloc(hp, res);
}

fn hbigint::HBigInt*? instant_sub_big(hbigint::HBigInt* a, hbigint::HBigInt* delta, Heap* hp) {
    if (a == null || delta == null) return null;
    int128 res = temporal::instant_sub(a.to_int128(), delta.to_int128());
    if (!temporal::instant_in_range(res)) return null;
    return hbigint::hbigint_alloc(hp, res);
}

// Ordering on the BigInt representation. Null sorts before any value, matching
// the previous behaviour of the library function this replaced.
fn int instant_cmp_big(hbigint::HBigInt* a, hbigint::HBigInt* b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    return temporal::instant_cmp(a.to_int128(), b.to_int128());
}

fn HObject*? alloc_instant(Heap* hp, hbigint::HBigInt* ns) {
    if (ns == null) return null;
    if (!temporal::instant_in_range(ns.to_int128())) return null;
    HObject*? raw = hp.alloc_object(hobject::ObjClass.TEMPORAL_INSTANT);
    if (catch err = raw) return err~;
    HObject* obj = raw;
    ((types::HeapHeader*)ns).incref();
    obj.extra.temporal.big_ns = ns;
    obj.extra.temporal.calendar = null;
    obj.extra.temporal.timezone = null;
    return obj;
}

// Date.prototype.toTemporalInstant() — the Temporal proposal's bridge from the
// legacy Date object. Lives here rather than in date.c3 because it needs the
// Instant allocator and the BigInt helpers.
//
// 1. Let dateObject be the this value.
// 2. Perform ? RequireInternalSlot(dateObject, [[DateValue]]).
// 3. Let t be dateObject.[[DateValue]]; if t is NaN, throw a RangeError.
// 4. Let ns be ℤ(ℝ(t) × 10^6).
// 5. Return ! CreateTemporalInstant(ns).
fn void builtin_date_proto_toTemporalInstant(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    // Handles the [[DateValue]] brand check, throwing TypeError for a
    // non-Date this value (including Date.prototype itself).
    double tv = date_this_time_value(ctx, &this_val);
    if (ctx.should_throw) return;
    if (math::is_nan(tv)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid Date");
        return;
    }
    // A valid time value is an integral number of milliseconds within
    // ±8.64e15, so the nanosecond count fits int128 exactly. Scaling in
    // int128 rather than double keeps the full range representable —
    // ±8.64e21 ns is far beyond 2^53.
    int128 ns_128 = (int128)(long)tv * (int128)temporal::NS_PER_MS;
    hbigint::HBigInt*? big_o = hbigint::hbigint_alloc(ctx.heap, ns_128);
    if (catch err = big_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "out of range"); return; }
    hbigint::HBigInt* ns = big_o;
    HObject*? obj_o = alloc_instant(ctx.heap, ns);
    ctx.heap.decref((types::HeapHeader*)ns);
    if (catch err = obj_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Extract the BigInt from a Temporal.Instant heap object. Returns null if the
// object is missing the slot (defensive — should never happen for a valid
// TEMPORAL_INSTANT object).
fn hbigint::HBigInt*? instant_value(HObject* obj) {
    return obj.extra.temporal.big_ns;
}

// Temporal.Instant(epochNanoseconds) — accepts a BigInt, throws on anything else.
// The ns value is range-checked against ±86400 * 10^17 (the ISO 8601 range
// ±100_000_000 days from the epoch), and the call is rejected when it is not
// invoked with `new` (per spec §`TemporalInstant` step 1).
fn void builtin_temporal_instant_ctor(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant must be called with new");
        return;
    }
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant requires an epochNanoseconds argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, arg, &ok);
    if (!ok) return;
    // builtin_to_bigint returns a borrowed reference: for a BigInt argument the
    // caller's register (or constant pool) still owns it, so we do NOT release
    // it on any path. alloc_instant increfs the stored copy; on throw paths the
    // caller's register cleanup frees the original. Decref'ing here would
    // double-free a register BigInt whose VM cleanup runs after the throw
    // returns (caught the segfault via `try { new Instant(lim + 1n) }`).
    if (!b.fits_int128()) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.Instant: epochNanoseconds is out of range");
        return;
    }
    int128 v = b.to_int128();
    int128 ns_limit = temporal::INSTANT_MAX_NS;
    if (v < -ns_limit || v > ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Temporal.Instant: epochNanoseconds is outside the representable range");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, b);
    if (catch err = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.temporal_instant_proto);
    ctx.result.set_object(obj);
}

// Temporal.Instant.from(item) — accepts an ISO string or another Instant.
// Per the argument-wrong-type tests, BigInt and other primitives throw
// TypeError: only a String primitive (after ToPrimitive on an object
// argument, hint string) or a brand-checked Temporal.Instant object
// produce an Instant. Numbers, booleans, BigInts, null and undefined
// reject — they are not coerced to a numeric epoch.
fn void builtin_temporal_instant_from(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant.from requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_INSTANT) {
            // Copy the underlying BigInt.
            hbigint::HBigInt* src = o.extra.temporal.big_ns;
            hbigint::HBigInt*? b_o = hbigint::hbigint_copy(ctx.heap, src);
            if (catch err = b_o) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Instant.from: copy failed");
                return;
            }
            HObject*? obj_o = alloc_instant(ctx.heap, b_o);
            if (catch err2 = obj_o) {
                ctx.heap.decref((types::HeapHeader*)b_o);
                builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
                return;
            }
            HObject* obj = obj_o;
            ctx.heap.decref((types::HeapHeader*)b_o);
            obj.prototype = ctx.heap.temporal_instant_proto;
            ctx.result.set_object(obj);
            return;
        }
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            // Fast path for ZonedDateTime → Instant: copy the [[Nanoseconds]]
            // directly. Avoids coercing via toString (which would defeat the
            // identity check in checkToTemporalInstantFastPath).
            hbigint::HBigInt* src = o.extra.temporal.big_ns;
            hbigint::HBigInt*? b_o = hbigint::hbigint_copy(ctx.heap, src);
            if (catch err = b_o) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Instant.from: ZDT copy failed");
                return;
            }
            HObject*? obj_o = alloc_instant(ctx.heap, b_o);
            if (catch err2 = obj_o) {
                ctx.heap.decref((types::HeapHeader*)b_o);
                builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
                return;
            }
            HObject* obj = obj_o;
            ctx.heap.decref((types::HeapHeader*)b_o);
            obj.prototype = ctx.heap.temporal_instant_proto;
            ctx.result.set_object(obj);
            return;
        }
        // Non-Instant object: ToPrimitive(string) — same shape as
        // ToTemporalInstant for the object branch. The primitive must
        // be a string for the parse path; everything else throws
        // TypeError (e.g. valueOf returning a number).
        Vm* v = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(v, arg, 1);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return;
        }
        if (!prim.is_string() || prim.get_heapptr() == null
            || ((HString*)prim.get_heapptr()).is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant.from: argument must be a string or Temporal.Instant");
            return;
        }
        arg = &prim;
    } else if (!arg.is_string()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant.from: argument must be a string or Temporal.Instant");
        return;
    }
    hbigint::HBigInt* b;
    if (!to_temporal_instant(ctx, arg, &b)) return;
    defer ctx.heap.decref((types::HeapHeader*)b);
    HObject*? obj_o = alloc_instant(ctx.heap, b);
    if (catch err = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Temporal.Instant.fromEpochSeconds(n) — converts a Number (or BigInt) of
// seconds to an Instant via seconds * 10^9 nanoseconds.
fn void builtin_temporal_instant_fromEpochSeconds(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "fromEpochSeconds requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    // Allow BigInt or Number. Number must be an integer (no fractional seconds).
    hbigint::HBigInt* b;
    if (arg.is_bigint()) {
        b = arg.get_bigint();
    } else if (arg.is_number() || arg.is_fastint()) {
        Vm* v = (Vm*)ctx.vm;
        double d = vm::vm_to_number(v, arg);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
        if (math::is_nan(d) || math::is_inf(d)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochSeconds: non-finite value");
            return;
        }
        if (math::floor(d) != d) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochSeconds: non-integer value");
            return;
        }
        // d is now an integer in [-2^53, 2^53]; convert via int64.
        int128 i128 = (int128)d;
        hbigint::HBigInt*? b_o = hbigint::hbigint_alloc(ctx.heap, i128);
        if (catch err = b_o) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochSeconds: allocation failed");
            return;
        }
        b = b_o;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "fromEpochSeconds requires a number or BigInt");
        return;
    }
    // Multiply by 10^9 nanoseconds.
    hbigint::HBigInt*? ns_o = hbigint::hbigint_from_slimb(ctx.heap, 1000000000);
    if (catch err = ns_o) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochSeconds: 10^9 alloc failed");
        return;
    }
    hbigint::HBigInt* nine = ns_o;
    hbigint::HBigInt*? result = hbigint::hbigint_mul(ctx.heap, b, nine);
    ctx.heap.decref((types::HeapHeader*)nine);
    if (catch err = result) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochSeconds: multiply failed");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, result);
    if (catch err2 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)result);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Same shape for ms, us, ns — delegate via simple scaling.
fn void builtin_temporal_instant_fromEpochMilliseconds(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: missing argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    Vm* v = (Vm*)ctx.vm;
    double d = vm::vm_to_number(v, arg);
    if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    if (math::is_nan(d) || math::is_inf(d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: non-finite");
        return;
    }
    if (math::floor(d) != d) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: non-integer");
        return;
    }
    int128 i128 = (int128)d;
    // ES262 §TemporalInstant: ms must stay within the range that fits in ns
    // after multiplication. Limit is the same ±86400 * 1e9 ns / 1e3 ms =
    // ±8.64e15 ms.
    int128 ms_limit = temporal::INSTANT_MAX_NS / (int128)temporal::NS_PER_MS;
    if (i128 < -ms_limit || i128 > ms_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: out of representable range");
        return;
    }
    hbigint::HBigInt*? ms_o = hbigint::hbigint_alloc(ctx.heap, i128);
    if (catch err = ms_o) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: alloc failed");
        return;
    }
    hbigint::HBigInt* ms = ms_o;
    hbigint::HBigInt*? million_o = hbigint::hbigint_from_slimb(ctx.heap, 1000000);
    if (catch err2 = million_o) {
        ctx.heap.decref((types::HeapHeader*)ms);
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: 10^6 alloc failed");
        return;
    }
    hbigint::HBigInt* million = million_o;
    hbigint::HBigInt*? ns = hbigint::hbigint_mul(ctx.heap, ms, million);
    ctx.heap.decref((types::HeapHeader*)million);
    ctx.heap.decref((types::HeapHeader*)ms);
    if (catch err3 = ns) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMilliseconds: multiply failed");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, ns);
    if (catch err4 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)ns);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)ns);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_instant_fromEpochMicroseconds(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "fromEpochMicroseconds requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    Vm* v = (Vm*)ctx.vm;
    double d = vm::vm_to_number(v, arg);
    if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    if (math::is_nan(d) || math::is_inf(d)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMicroseconds: non-finite");
        return;
    }
    if (math::floor(d) != d) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMicroseconds: non-integer");
        return;
    }
    int128 i128 = (int128)d;
    hbigint::HBigInt*? us_o = hbigint::hbigint_alloc(ctx.heap, i128);
    if (catch err = us_o) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMicroseconds: alloc failed");
        return;
    }
    hbigint::HBigInt* us = us_o;
    hbigint::HBigInt*? thousand_o = hbigint::hbigint_from_slimb(ctx.heap, 1000);
    if (catch err2 = thousand_o) {
        ctx.heap.decref((types::HeapHeader*)us);
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMicroseconds: 10^3 alloc failed");
        return;
    }
    hbigint::HBigInt* thousand = thousand_o;
    hbigint::HBigInt*? ns = hbigint::hbigint_mul(ctx.heap, us, thousand);
    ctx.heap.decref((types::HeapHeader*)thousand);
    ctx.heap.decref((types::HeapHeader*)us);
    if (catch err3 = ns) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochMicroseconds: multiply failed");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, ns);
    if (catch err4 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)ns);
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)ns);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_instant_fromEpochNanoseconds(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "fromEpochNanoseconds requires an argument");
        return;
    }
    bool ok;
    hbigint::HBigInt* b = builtin_to_bigint(ctx, arg_at(ctx, 0), &ok);
    if (!ok) return;
    if (!b.fits_int128()) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochNanoseconds: out of range");
        return;
    }
    int128 v = b.to_int128();
    int128 ns_limit = temporal::INSTANT_MAX_NS;
    if (v < -ns_limit || v > ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fromEpochNanoseconds: outside the representable range");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, b);
    if (catch err = obj_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return;
    }
    HObject* obj = obj_o;
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Temporal.Instant.compare(a, b) → -1 / 0 / 1.
fn void builtin_temporal_instant_compare(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "compare requires two arguments");
        return;
    }
    TVal* a_arg = arg_at(ctx, 0);
    TVal* b_arg = arg_at(ctx, 1);
    // Per spec, ToTemporalInstant is applied to each arg: an object Instant
    // passes through; a non-Instant object ToPrimitive's to a string we
    // parse; a primitive that's not string-or-symbol throws TypeError.
    // to_temporal_instant raises the right error for every shape.
    hbigint::HBigInt* a;
    if (!to_temporal_instant(ctx, a_arg, &a)) return;
    defer ctx.heap.decref((types::HeapHeader*)a);
    hbigint::HBigInt* b;
    if (!to_temporal_instant(ctx, b_arg, &b)) return;
    defer ctx.heap.decref((types::HeapHeader*)b);
    ctx.result.set_fastint(instant_cmp_big(a, b));
}

// All four getters: epochSeconds, epochMilliseconds, epochMicroseconds,
// epochNanoseconds. The seconds/ms/us getters must return a Number; the ns
// getter returns a BigInt. We divide via / 10^9 (or 10^6 / 10^3).
fn void builtin_temporal_instant_proto_epochSeconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result.set_number(math::floor(d / 1e9));
}

fn void builtin_temporal_instant_proto_epochMilliseconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    // Convert ms (Number) to integer. floor() then cast.
    ctx.result.set_number(math::floor(d / 1e6));
}

fn void builtin_temporal_instant_proto_epochMicroseconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    double d;
    if (!bigint_to_epoch_number(b, &d, ctx)) return;
    ctx.result.set_number(math::floor(d / 1e3));
}

fn void builtin_temporal_instant_proto_epochNanoseconds(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    ctx.result.set_bigint(b);
}


// Resolve the fractional-second precision and rounding mode for a Temporal
// toString(options) bag. `digits` (-1 = auto, 0..9 = fixed) is set from
// `fractionalSecondDigits` or, if `smallestUnit` is given, its implied width
// (hour/minute/second -> 0, millisecond -> 3, microsecond -> 6, nanosecond ->
// 9). `rounding_mode` defaults to TRUNC; "ceil", "floor", "expand", "trunc",
// "halfCeil", "halfFloor", "halfExpand", "halfTrunc", "halfEven" are valid.
// Returns false on a malformed option (after throwing).
fn bool to_string_precision(BuiltinContext* ctx, int options_index, int* digits, temporal::TemporalRoundMode* rm, bool read_time_zone, TVal* out_time_zone) {
    *digits = -1;  // auto when no options
    *rm = temporal::TemporalRoundMode.TRUNC;
    if (ctx.argc <= options_index) return true;
    TVal ov = ctx.regs[ctx.base_reg + options_index];
    if (ov.is_undefined()) return true;
    if (!ov.is_object() || ov.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    HObject* opts = (HObject*)ov.get_heapptr();

    // Spec reads options in alphabetical order: fractionalSecondDigits,
    // roundingMode, smallestUnit (GetTemporalFractionalSecondDigitsOption,
    // GetRoundingModeOption, GetTemporalUnitValuedOption). Property bag reads
    // must go through the accessor/Proxy-aware path so getters/Proxy traps
    // observe the reads in this order (test262 propertyBagObserver).
    TVal f = prop_or_undefined_pa(ctx, opts, "fractionalSecondDigits");
    if (ctx.should_throw) return false;
    if (!f.is_undefined()) {
        // GetStringOrNumberOption branches on the ORIGINAL value's type: a
        // Number is used numerically (floored, then range-checked), while
        // anything else is stringified and must match a valid string option
        // — here only "auto". A non-Number is never numerically parsed, so
        // e.g. 2n and {} are RangeErrors even though they stringify to "2"
        // and "[object Object]". An object whose toString returns "auto" is
        // still accepted (test262's propertyBagObserver proxies the value
        // and expects toString, not valueOf, to be invoked).
        if (f.is_numeric()) {
            double dv = f.get_number_or_fastint();
            double dc = math::floor(dv);
            if (math::is_nan(dv) || dc < 0 || dc > 9) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0 to 9");
                return false;
            }
            *digits = (int)dc;
        } else {
            HString* f_s = builtin_to_string_vm(ctx, &f);
            if (ctx.should_throw) return false;
            if (f_s == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "fractionalSecondDigits must be a number or \"auto\"");
                return false;
            }
            char[] v = f_s.get_cstr()[:f_s.blen];
            if (v == "auto") { *digits = -1; }
            else {
                builtin_throw(ctx, ctx.heap.range_err_proto, "fractionalSecondDigits must be an integer 0 to 9");
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
    bool su_valid = true;
    if (!su.is_undefined()) {
        HString* su_s = builtin_to_string_vm(ctx, &su);
        if (ctx.should_throw) return false;
        if (su_s == null) { builtin_throw(ctx, ctx.heap.type_err_proto, "smallestUnit option must be a string"); return false; }
        char[] v = su_s.get_cstr()[:su_s.blen];
        // Sentinel -10: round to minute, no fractional part. Both singular
        // and plural spellings are accepted for every unit.
        if (v == "minute" || v == "minutes") { *digits = -10; }
        else if (v == "second" || v == "seconds") { *digits = 0; }
        else if (v == "millisecond" || v == "milliseconds") { *digits = 3; }
        else if (v == "microsecond" || v == "microseconds") { *digits = 6; }
        else if (v == "nanosecond" || v == "nanoseconds")  { *digits = 9; }
        else { su_valid = false; }
    }
    // Instant/ZDT observe `timeZone` in their toString tests; PlainTime does
    // not. Read it after the alphabetical option batch so the order-of-
    // operations expected record observes the `get options.timeZone` entry
    // even when smallestUnit later proves invalid (test262's
    // options-read-before-algorithmic-validation.js expects this sequence).
    if (read_time_zone) {
        TVal _tz = prop_or_undefined_pa(ctx, opts, "timeZone");
        if (ctx.should_throw) return false;
        if (out_time_zone != null) *out_time_zone = _tz;
    }
    if (!su_valid) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit");
        return false;
    }
    return true;
}

fn void builtin_temporal_instant_proto_toString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    int digits;
    temporal::TemporalRoundMode rm;
    TVal tzv;
    tzv.set_undefined();
    // to_string_precision probes timeZone last (after fractionalSecondDigits,
    // roundingMode, smallestUnit), matching the spec's alphabetical option
    // read order; undefined means UTC ("Z" suffix).
    if (!to_string_precision(ctx, 0, &digits, &rm, true, &tzv)) return;

    HObject* tz = null;
    if (!tzv.is_undefined()) {
        if (try maybe_tz = to_temporal_tz(ctx, &tzv)) {
            if (ctx.should_throw) return;
            tz = maybe_tz;
        } else {
            return;
        }
    }

    // Whole seconds and sub-second remainder, split toward zero. Read the
    // epoch-nanosecond value directly via to_int128 (no allocation), so no GC
    // can sweep a temporary BigInt between the read and the format.
    long whole_secs;
    long ns_rem;
    if (b.fits_int128()) {
        int128 total = b.to_int128();
        // Truncate toward zero: sign of remainder follows dividend's sign.
        // For a negative total, floor the second so ns_rem is non-negative
        // (e.g. -1500000001 ns = -2 sec + 999999999 ns, not -1 sec + -500000001 ns).
        long sec_trunc = (long)(total / 1000000000);
        long rem_trunc = (long)(total - (int128)sec_trunc * 1000000000);
        if (rem_trunc < 0) {
            sec_trunc -= 1;
            rem_trunc += 1000000000;
        }
        whole_secs = sec_trunc;
        ns_rem = rem_trunc;
    } else {
        // Out of int128 range: fall back to the double approximation (the
        // output is only ever whole seconds at this magnitude anyway).
        double secs;
        if (!bigint_to_epoch_number(b, &secs, ctx)) return;
        whole_secs = (long)math::floor(secs / 1e9);
        ns_rem = 0;
    }

    // Apply rounding (RoundTemporalInstant) to the full epoch-nanosecond
    // value before splitting into wall-clock fields, so the rounded value's
    // carries (into seconds/minutes/... and even the date) are correct —
    // matching the spec, which rounds epochNs first and only then computes
    // wall-clock fields from the rounded instant.
    if (digits == -10) {
        // smallestUnit: "minute" -> round to a whole minute boundary.
        long total_ns = whole_secs * 1000000000 + ns_rem;
        long rounded_total_ns = temporal::round_long_ns(total_ns, 60 * temporal::NS_PER_SEC, rm);
        whole_secs = rounded_total_ns / 1000000000;
        ns_rem = 0;
    } else if (digits >= 0 && ns_rem != 0) {
        long divisor = 1;
        for (int i = 0; i < 9 - digits; i++) divisor *= 10;
        long v = (long)temporal::round_num_to_incr((double)ns_rem / (double)divisor, 1.0, rm);
        long new_ns_rem = v * divisor;
        if (new_ns_rem >= 1000000000) {
            whole_secs += 1;
            new_ns_rem -= 1000000000;
        }
        ns_rem = new_ns_rem;
    }

    // Shift wall-clock fields into the requested time zone (or UTC/"Z" if
    // none given).
    String zone = tz == null ? "" : timezone_name(tz);
    int off = 0;
    if (tz != null) off = temporal::tzdb_offset_for_zone_at(zone, whole_secs);
    long local_secs = whole_secs + off;

    temporal::BrokenDownTime bd = temporal::civil_from_seconds(local_secs);

    // Year formatting per spec §`GetISOPartsFromEpoch`: 0 ≤ year ≤ 9999 renders
    // as a 4-digit unsigned year; year < 0 or year > 9999 renders as a 6-digit
    // signed year with `-` or `+` prefix.
    char[64] buf;
    int n;
    long y = bd.y;
    if (digits == -10) {
        if (y >= 0 && y <= 9999) {
            n = libc::snprintf(&buf, 40, "%04ld-%02ld-%02ldT%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        } else if (y < 0) {
            n = libc::snprintf(&buf, 40, "-%06ld-%02ld-%02ldT%02ld:%02ld",
                -y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        } else {
            n = libc::snprintf(&buf, 40, "+%06ld-%02ld-%02ldT%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi);
        }
    } else {
        if (y >= 0 && y <= 9999) {
            n = libc::snprintf(&buf, 40, "%04ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        } else if (y < 0) {
            n = libc::snprintf(&buf, 40, "-%06ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                -y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        } else {
            n = libc::snprintf(&buf, 40, "+%06ld-%02ld-%02ldT%02ld:%02ld:%02ld",
                y, (long)bd.m + 1, (long)bd.d, (long)bd.h, (long)bd.mi, (long)bd.s);
        }
        n += temporal::format_fractional_seconds(&buf[n], ns_rem, digits, rm);
    }
    if (tz == null) {
        buf[n] = 'Z';
        n++;
    } else {
        temporal::format_offset_seconds(&buf[n], off);
        n += 6;
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:n]));
}

fn void builtin_temporal_instant_proto_toJSON(BuiltinContext* ctx) {
    // toJSON takes no options and always formats at "auto" precision, so the
    // caller's arguments must not reach the toString delegate.
    ctx.argc = 0;
    builtin_temporal_instant_proto_toString(ctx);
}

fn void builtin_temporal_instant_proto_toLocaleString(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    ctx.argc = 0;
    builtin_temporal_instant_proto_toString(ctx);
}

fn void builtin_temporal_instant_proto_toZonedDateTimeISO(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();

    // 1. Require timezone argument.
    if (ctx.argc < 1 || ctx.regs[ctx.base_reg].is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "toZonedDateTimeISO requires a time zone");
        return;
    }
    TVal* tz_arg = arg_at(ctx, 0);

    // 2. Resolve timezone.
    HObject* tz = null;
    if (try maybe_tz = to_temporal_tz(ctx, tz_arg)) {
        if (ctx.should_throw) return;
        tz = maybe_tz;
    } else { return; }

    // 3. Get the instant's epoch nanoseconds and create ZonedDateTime with ISO calendar.
    hbigint::HBigInt* ns;
    if (try ns_o = instant_value(obj)) {
        ns = ns_o;
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "invalid Instant");
        return;
    }
    ((types::HeapHeader*)ns).incref();
    HString* cal = builtin_intern_string(ctx.heap, "iso8601");
    zdt_from_parts(ctx, ns, tz, cal);
}

fn void builtin_temporal_instant_proto_valueOf(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    builtin_throw(ctx, ctx.heap.type_err_proto, "Temporal.Instant cannot be converted to a primitive value");
}

fn void builtin_temporal_instant_proto_equals(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "equals requires an argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    if (arg.is_object() && arg.get_heapptr() != null
        && ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.TEMPORAL_INSTANT) {
        HObject* a = (HObject*)ctx.this_val.get_heapptr();
        HObject* b = (HObject*)arg.get_heapptr();
        ctx.result.set_boolean(hbigint::hbigint_cmp(a.extra.temporal.big_ns, b.extra.temporal.big_ns) == 0);
        return;
    }
    // Strings convert via ToTemporalInstant (rejects invalid strings).
    hbigint::HBigInt* other_ns;
    if (!to_temporal_instant(ctx, arg, &other_ns)) return;
    defer ctx.heap.decref((types::HeapHeader*)other_ns);
    HObject* a = (HObject*)ctx.this_val.get_heapptr();
    ctx.result.set_boolean(hbigint::hbigint_cmp(a.extra.temporal.big_ns, other_ns) == 0);
}

// add / subtract take a Temporal.Duration.
fn void builtin_temporal_instant_proto_add(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "add requires a Duration argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    // Per spec, AddDurationToOrSubtractDurationFromInstant's argument is a
    // Temporal.DurationLike: a Temporal.Duration instance, a duration
    // string, or a property bag with hour/minute/second/ms/us/ns fields
    // (no calendar units; Instant rejects years/months/weeks/days).
    // We compute the total-nanoseconds delta via BigInt arithmetic so values
    // larger than int64 range (e.g. `{nanoseconds: 2e22}`) survive the
    // conversion; truncating each field to `long` first would wrap to a
    // garbage value around 2e18 ns.
    hbigint::HBigInt* delta;
    if (!duration_arg_to_ns_bigint(ctx, arg, &delta)) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* base = self.extra.temporal.big_ns;
    hbigint::HBigInt*? result = instant_add_big(base, delta, ctx.heap);
    ctx.heap.decref((types::HeapHeader*)delta);
    if (catch err = result) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    if (result == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, result);
    if (catch err2 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    if (obj_o == null) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)result);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

fn void builtin_temporal_instant_proto_subtract(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "subtract requires a Duration argument");
        return;
    }
    TVal* arg = arg_at(ctx, 0);
    hbigint::HBigInt* delta;
    if (!duration_arg_to_ns_bigint(ctx, arg, &delta)) return;
    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* base = self.extra.temporal.big_ns;
    hbigint::HBigInt*? result = instant_sub_big(base, delta, ctx.heap);
    ctx.heap.decref((types::HeapHeader*)delta);
    if (catch err = result) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    if (result == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    HObject*? obj_o = alloc_instant(ctx.heap, result);
    if (catch err2 = obj_o) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    if (obj_o == null) {
        ctx.heap.decref((types::HeapHeader*)result);
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant is out of range");
        return;
    }
    HObject* obj = obj_o;
    ctx.heap.decref((types::HeapHeader*)result);
    obj.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(obj);
}

// Settings shared by every until/since method, resolved from the options bag.
struct DiffSettings {
    temporal::TemporalUnit largest;
    temporal::TemporalUnit smallest;
    temporal::TemporalRoundMode mode;
    double increment;
    bool largest_provided;
    // True when the receiver is a ZonedDateTime. The spec's
    // NudgeToCalendarUnit treats days as a calendar unit for a zoned
    // receiver, so a far-out `hi` boundary throws even though PlainDate
    // (which routes through NudgeToDayOrTime) does not.
    bool is_zoned;
}

// Read largestUnit / smallestUnit / roundingIncrement / roundingMode for an
// until/since call.
//
// Property reads happen in the spec's order (largestUnit, roundingIncrement,
// roundingMode, smallestUnit) because each one can run user code through a
// getter or valueOf, and test262 observes the sequence.
//
// `fallback_smallest` is the finest unit the receiver can express and
// `default_largest` the coarsest unit it reports by default; `min_unit` and
// `max_unit` bound what the receiver accepts at all, so a PlainTime rejects
// "day" and a PlainYearMonth rejects "hour". For `since` the caller negates
// the resulting Duration, but the rounding mode is negated here instead, since
// rounding must happen in the direction of the original difference.
//
// Returns false after throwing.
fn bool read_diff_settings(BuiltinContext* ctx, int options_index,
                           temporal::TemporalUnit min_unit, temporal::TemporalUnit max_unit,
                           temporal::TemporalUnit default_largest, temporal::TemporalUnit fallback_smallest,
                           bool negate_mode, DiffSettings* out) {
    out.largest = default_largest;
    out.smallest = fallback_smallest;
    out.mode = temporal::TemporalRoundMode.TRUNC;
    out.increment = 1;
    out.is_zoned = false;

    HObject* opts = null;
    if (ctx.argc > options_index) {
        TVal ov = ctx.regs[ctx.base_reg + options_index];
        if (!ov.is_undefined()) {
            if (!ov.is_object() || ov.get_heapptr() == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
                return false;
            }
            opts = (HObject*)ov.get_heapptr();
        }
    }

    bool largest_given = false;
    bool smallest_given = false;

    if (opts != null) {
        TVal lu_v = prop_or_undefined_pa(ctx, opts, "largestUnit");
        if (ctx.should_throw) return false;
        if (!lu_v.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &lu_v);
            if (ctx.should_throw) return false;
            char[] str = s.get_cstr()[:s.blen];
            if (str != "auto") {
                if (!temporal::parse_unit_str(str, &out.largest)) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "largestUnit is not a valid value");
                    return false;
                }
                largest_given = true;
                out.largest_provided = true;
            }
        }

        TVal ri_v = prop_or_undefined_pa(ctx, opts, "roundingIncrement");
        if (ctx.should_throw) return false;
        if (!ri_v.is_undefined()) {
            Vm* v = (Vm*)ctx.vm;
            long ri;
            if (!to_integer_with_truncation(v, &ri_v, &ri)) {
                if (v.throw_pending) {
                    ctx.should_throw = true;
                    ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
                    v.throw_pending = false;
                    return false;
                }
                builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be finite");
                return false;
            }
            out.increment = (double)ri;
        }

        TVal rm_v = prop_or_undefined_pa(ctx, opts, "roundingMode");
        if (ctx.should_throw) return false;
        if (!rm_v.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &rm_v);
            if (ctx.should_throw) return false;
            if (!temporal::parse_rm_str(s.get_cstr()[:s.blen], &out.mode)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
                return false;
            }
        }

        TVal su_v = prop_or_undefined_pa(ctx, opts, "smallestUnit");
        if (ctx.should_throw) return false;
        if (!su_v.is_undefined()) {
            HString* s = builtin_to_string_vm(ctx, &su_v);
            if (ctx.should_throw) return false;
            char[] str = s.get_cstr()[:s.blen];
            if (str != "auto") {
                if (!temporal::parse_unit_str(str, &out.smallest)) {
                    builtin_throw(ctx, ctx.heap.range_err_proto, "smallestUnit is not a valid value");
                    return false;
                }
                smallest_given = true;
            }
        }
    }

    // Validation runs only after all four options are read. Each read can
    // invoke user code through a getter or valueOf, and the spec observes every
    // one of them even when an earlier value is unusable.
    if (out.increment < 1 || out.increment > 1e9) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
        return false;
    }
    if (largest_given && (out.largest < min_unit || out.largest > max_unit)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "largestUnit is not supported by this type");
        return false;
    }
    if (smallest_given && (out.smallest < min_unit || out.smallest > max_unit)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "smallestUnit is not supported by this type");
        return false;
    }

    // Per the spec, defaultLargestUnit = LargerOfTwoTemporalUnits(defaultLargest, smallestUnit).
    // When the user did not explicitly set largestUnit, recompute it.
    if (!largest_given) {
        out.largest = temporal::larger_unit(default_largest, out.smallest);
    }
    if (out.largest > out.smallest) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "smallestUnit must be coarser than largestUnit");
        return false;
    }

    long max_incr = temporal::max_round_incr(out.smallest);
    if (max_incr > 0) {
        // The increment must divide the unit evenly, and cannot span a whole
        // unit — 60 minutes is not a legal minute increment.
        if (!validate_rounding_increment(ctx, out.smallest, out.increment)) return false;
    }
    // Calendar units and "day" have no fixed length for an increment to divide
    // into, so any positive integer is accepted there and the [1, 1e9] check
    // above is the only bound.

    if (negate_mode) out.mode = temporal::negate_round_mode(out.mode);
    return true;
}



// Build a Duration whose time units are the difference between two Instants'
// epoch-ns BigInts. `largest_unit_ns` is the unit ns (3600*1e9 for hours,
// 60*1e9 for minutes, 1e9 for seconds, 1e6 for ms, etc.). The duration is
// balanced so the chosen unit holds the whole number and the sub-units carry
// the remainder. Negative differences produce all-negative components.
// `out` receives a refcount-1 Duration object or null on failure.
fn bool instant_ns_diff_duration(BuiltinContext* ctx, hbigint::HBigInt* a, hbigint::HBigInt* b, long largest_unit_ns, HObject** out) {
    if (largest_unit_ns <= 0) largest_unit_ns = 1000000000;
    hbigint::HBigInt*? diff_o = hbigint::hbigint_addsub(ctx.heap, a, b, true);
    if (catch err = diff_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "difference overflow"); return false; }
    hbigint::HBigInt* diff = diff_o;
    hbigint::HBigInt*? one_o = hbigint::hbigint_alloc(ctx.heap, (int128)largest_unit_ns);
    if (catch err = one_o) { ctx.heap.decref((types::HeapHeader*)diff); builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return false; }
    hbigint::HBigInt* one = one_o;
    hbigint::HBigInt* q = null;
    hbigint::HBigInt* r = null;
    if (catch err = hbigint::hbigint_divrem(ctx.heap, diff, one, &q, &r)) {
        ctx.heap.decref((types::HeapHeader*)one);
        ctx.heap.decref((types::HeapHeader*)diff);
        builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed");
        return false;
    }
    ctx.heap.decref((types::HeapHeader*)one);
    ctx.heap.decref((types::HeapHeader*)diff);
    if (q == null || r == null) { builtin_throw(ctx, ctx.heap.range_err_proto, "alloc failed"); return false; }
    temporal::DurationParts dp = {};
    long subsec_per_unit = temporal::NS_PER_SEC / largest_unit_ns;
    int128 qv = q.to_int128();
    int128 rv = r.to_int128();
    // The quotient is in `largest_unit_ns` units, the remainder in ns. Convert
    // the quotient to the smallest sensible field. For seconds (default),
    // dp.seconds = q; for ms, dp.milliseconds = q; etc.
    switch (largest_unit_ns) {
        case temporal::NS_PER_HOUR: dp.hours = (long)qv; break;
        case temporal::NS_PER_MIN:   dp.minutes = (long)qv; break;
        case temporal::NS_PER_SEC:    dp.seconds = (long)qv; break;
        case temporal::NS_PER_MS:       dp.ms = (long)qv; break;
        case 1000L:          dp.us = (long)qv; break;
        case 1L:             dp.ns = (long)qv; rv = 0; break;
        default:
            // Shouldn't happen — fallback to seconds.
            dp.seconds = (long)qv;
            subsec_per_unit = 1;
            largest_unit_ns = 1000000000;
            break;
    }
    if (largest_unit_ns != 1L) {
        // Re-distribute remainder (in ns) across the sub-units of the chosen
        // largestUnit. rv is in ns (always < `largest_unit_ns`); the values
        // fit in long so we work in long for the redistribution arithmetic.
        long rv_ns = (long)rv;
        long ms = rv_ns / 1000000;
        long rem_us = rv_ns - ms * 1000000;
        long us = rem_us / 1000;
        long ns = rem_us - us * 1000;
        if (largest_unit_ns == temporal::NS_PER_SEC) {
            dp.ms = ms; dp.us = us; dp.ns = ns;
        } else if (largest_unit_ns == temporal::NS_PER_MIN) {
            dp.seconds = (long)(ms / 1000); dp.ms = ms % 1000; dp.us = us; dp.ns = ns;
        } else if (largest_unit_ns == temporal::NS_PER_HOUR) {
            long min_total = ms / (60 * 1000);
            long ms_in_h = ms - min_total * 60 * 1000;
            long sec_total = ms_in_h / 1000;
            long ms_rem = ms_in_h - sec_total * 1000;
            dp.minutes = min_total;
            dp.seconds = sec_total;
            dp.ms = ms_rem; dp.us = us; dp.ns = ns;
        } else if (largest_unit_ns == temporal::NS_PER_MS) {
            dp.us = us; dp.ns = ns;
        } else if (largest_unit_ns == 1000L) {
            dp.ns = ns;
        }
    }
    ctx.heap.decref((types::HeapHeader*)q);
    ctx.heap.decref((types::HeapHeader*)r);
    HObject*? dur_o = alloc_duration(ctx.heap, dp);
    if (catch err = dur_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return false;
    }
    *out = dur_o;
    return true;
}

// Split a nanosecond count into a Duration, filling `largest` and every finer
// time unit. The value has already been rounded to smallestUnit by the caller,
// so the tail fields simply come out zero.
//
// The count is taken as int128 rather than long: an Instant pair can be up to
// ~2*8.64e21 ns apart, which overflows a 64-bit nanosecond field even though
// each individual unit field fits comfortably.
fn bool instant_ns_split_duration(BuiltinContext* ctx, hbigint::HBigInt* ns, temporal::TemporalUnit largest, HObject** out) {
    int128 v = ns.to_int128();
    temporal::DurationParts dp = {};

    // Walk the ladder from `largest` down; each unit takes the whole quotient
    // at its scale and hands the remainder to the next one.
    if (largest <= temporal::TemporalUnit.HOUR) {
        dp.hours = (long)(v / temporal::NS_PER_HOUR);
        v %= temporal::NS_PER_HOUR;
    }
    if (largest <= temporal::TemporalUnit.MINUTE) {
        dp.minutes = (long)(v / temporal::NS_PER_MIN);
        v %= temporal::NS_PER_MIN;
    }
    if (largest <= temporal::TemporalUnit.SECOND) {
        dp.seconds = (long)(v / temporal::NS_PER_SEC);
        v %= temporal::NS_PER_SEC;
    }
    if (largest <= temporal::TemporalUnit.MILLISECOND) {
        dp.ms = (long)(v / temporal::NS_PER_MS);
        v %= temporal::NS_PER_MS;
    }
    if (largest <= temporal::TemporalUnit.MICROSECOND) {
        dp.us = (long)(v / 1000L);
        v %= 1000L;
    }
    dp.ns = (long)v;

    HObject*? dur_o = alloc_duration(ctx.heap, dp);
    if (catch err = dur_o) {
        builtin_throw(ctx, ctx.heap.err_proto, "alloc failed");
        return false;
    }
    *out = dur_o;
    return true;
}

// Resolve `largestUnit` from an options bag at `ctx.regs[ctx.base_reg +
// options_index]` to a number of nanoseconds. Returns 0 and emits the
// appropriate error (TypeError / RangeError) on bad input. The default for
// Instant is 1e9 (seconds); for PlainDate/Time/DateTime/ZDT, defaults vary
// per type. The Instant case accepts only the six time units; calendar units
// are rejected because Instants are point-in-time.
fn bool read_instant_largest_unit_ns(BuiltinContext* ctx, int options_index, long* out) {
    *out = temporal::NS_PER_SEC;
    if (ctx.argc <= options_index) return true;
    TVal ov = ctx.regs[ctx.base_reg + options_index];
    if (ov.is_undefined()) return true;
    if (!ov.is_object() || ov.get_heapptr() == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "options must be an object");
        return false;
    }
    HObject* opts = (HObject*)ov.get_heapptr();
    TVal val = prop_or_undefined(opts, ctx.heap, "largestUnit");
    if (val.is_undefined()) return true;
    if (!val.is_string()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "largestUnit must be a string");
        return false;
    }
    HString* s = (HString*)val.get_heapptr();
    String str = s ? (String)s.get_cstr()[:s.blen] : "";
    if (temporal::ci_eq(str, "hour") || temporal::ci_eq(str, "hours"))         { *out = temporal::NS_PER_HOUR; return true; }
    if (temporal::ci_eq(str, "minute") || temporal::ci_eq(str, "minutes"))     { *out = temporal::NS_PER_MIN; return true; }
    if (temporal::ci_eq(str, "second") || temporal::ci_eq(str, "seconds"))     { *out = temporal::NS_PER_SEC; return true; }
    if (temporal::ci_eq(str, "millisecond") || temporal::ci_eq(str, "milliseconds")) { *out = temporal::NS_PER_MS; return true; }
    if (temporal::ci_eq(str, "microsecond") || temporal::ci_eq(str, "microseconds")) { *out = 1000L; return true; }
    if (temporal::ci_eq(str, "nanosecond") || temporal::ci_eq(str, "nanoseconds"))   { *out = 1L; return true; }
    builtin_throw(ctx, ctx.heap.range_err_proto, "largestUnit is not a valid value");
    return false;
}


// Parse an ISO instant string into an HBigInt of epoch nanoseconds.
// Throws RangeError on parse failure / invalid components. On success the
// returned BigInt is incref'd; ownership passes to the caller.
fn bool instant_from_iso_string(BuiltinContext* ctx, String str, hbigint::HBigInt** out) {
    temporal::ParsedIsoInstant p;
    if (!temporal::parse_iso_instant_string(str, &p)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO string");
        return false;
    }
    // Reject only the obvious garbage (month/day out of their natural
    // ranges). The year bound, leap-year check, and ±100,000,000-day epoch
    // window are enforced below by computing the epoch nanoseconds and
    // comparing against ns_limit — a date like `+275760-09-14` paired with a
    // sub-minute offset lands *inside* the representable epoch range, so
    // strict `is_valid_iso_date` would over-reject.
    if (p.m < 1 || p.m > 12 || p.d < 1 || p.d > 31) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO date");
        return false;
    }
    long ed = temporal::epoch_days_from_civil(p.y, (int)p.m, (int)p.d);
    long sec_of_day = (long)p.hour * 3600 + (long)p.minute * 60 + (long)p.second;
    int128 ns128 = (int128)ed * 86400L * temporal::NS_PER_SEC;
    ns128 += (int128)sec_of_day * temporal::NS_PER_SEC;
    ns128 += (int128)p.nanos;
    ns128 -= (int128)p.offset_seconds * temporal::NS_PER_SEC;
    // The offset's sub-minute fraction already carries the offset's sign
    // (parsed with `negative ? -off_nanos : off_nanos`), so it subtracts
    // directly. A positive seconds value means the parsed time is east of
    // UTC, so the offset subtracts; the signed fraction behaves the same
    // way.
    ns128 -= (int128)p.offset_nanos;
    // ToTemporalInstant rejects an instant outside NS_MIN..NS_MAX
    // (±100,000,000 days * 86400e9), e.g. the maximum wall date with a
    // negative offset pushes the epoch over the top.
    int128 ns_limit = temporal::INSTANT_MAX_NS;
    if (ns128 > ns_limit || ns128 < -ns_limit) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "instant outside the representable epoch-nanoseconds range");
        return false;
    }
    hbigint::HBigInt*? b_o = hbigint::hbigint_alloc(ctx.heap, ns128);
    if (catch err = b_o) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Instant alloc failed");
        return false;
    }
    *out = b_o;
    return true;
}

// ToTemporalInstant(arg): coerce arg to a Temporal.Instant epoch-ns BigInt.
// On success the returned BigInt is incref'd (refcount-1) and ownership passes
// to the caller. On failure the function returns false after throwing.
//   - Object with class TEMPORAL_INSTANT: copy its big_ns.
//   - Object (or function) without that class: ToPrimitive(arg, string).
//     If the primitive is a string, parse it (RangeError on failure).
//     ToPrimitive can itself throw (e.g. @@toPrimitive returning an
//     object, or a brand-check failure on Temporal.Instant.prototype);
//     those exceptions propagate.
//   - Symbol: throw TypeError (ToPrimitive on a Symbol throws TypeError).
//   - String: parse as ISO instant string. RangeError on invalid input.
//   - Other primitives (number, boolean, null, undefined, bigint):
//     throw TypeError — they have no string representation the parser
//     would accept.
fn bool to_temporal_instant(BuiltinContext* ctx, TVal* arg, hbigint::HBigInt** out) {
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.get_class() == hobject::ObjClass.TEMPORAL_INSTANT) {
            hbigint::HBigInt*? b_o = hbigint::hbigint_copy(ctx.heap, o.extra.temporal.big_ns);
            if (catch err = b_o) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Instant copy failed");
                return false;
            }
            *out = b_o;
            return true;
        }
        // ZonedDateTime: copy [[Nanoseconds]] directly so the fast-path
        // identity tests don't fire toString via ToPrimitive coercion.
        if (o.get_class() == hobject::ObjClass.TEMPORAL_ZONEDDATETIME) {
            hbigint::HBigInt*? b_o = hbigint::hbigint_copy(ctx.heap, o.extra.temporal.big_ns);
            if (catch err = b_o) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Instant.from ZDT copy failed");
                return false;
            }
            *out = b_o;
            return true;
        }
        // Non-Instant object (including functions and Temporal.Instant.prototype):
        // ToPrimitive(arg, string) — Object's toString() (or @@toPrimitive) yields a
        // string we parse, or the conversion throws. Symbols fall through to here
        // only when wrapped — bare Symbols are caught by the is_symbol path below.
        Vm* v = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(v, arg, 1);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value);
            v.throw_pending = false;
            return false;
        }
        if (prim.is_string() && prim.get_heapptr() != null) {
            HString* s = (HString*)prim.get_heapptr();
            String str = (String)s.get_cstr()[:s.blen];
            return instant_from_iso_string(ctx, str, out);
        }
        builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to an Instant");
        return false;
    }
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid ISO string");
            return false;
        }
        // Symbols live as HString objects with is_symbol=true; the parser
        // would just RangeError on the embedded 0xFF prefix, but the spec
        // requires a TypeError before any string work happens.
        if (s.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to an Instant");
            return false;
        }
        String str = (String)s.get_cstr()[:s.blen];
        return instant_from_iso_string(ctx, str, out);
    }
    // Symbol and other primitives (number, boolean, null, undefined, bigint):
    // ToTemporalInstant does not coerce these to strings, so a TypeError is
    // raised for things like `Instant.prototype.equals(1)` and
    // `.equals(Symbol())` — matching the test262 "argument-wrong-type" suites.
    builtin_throw(ctx, ctx.heap.type_err_proto, "value cannot be converted to an Instant");
    return false;
}

// this.since(other[, options]) = this - other, as a Duration in seconds (or
// other time units when largestUnit is set).
fn void builtin_temporal_instant_proto_since(BuiltinContext* ctx) {
    instant_until_since(ctx, false);
}

// this.until(other[, options]) = other - this, as a Duration in seconds.
fn void builtin_temporal_instant_proto_until(BuiltinContext* ctx) {
    instant_until_since(ctx, true);
}

// Shared body for Instant.prototype.until/since.
//
// Instant has no date, so every unit is a fixed number of nanoseconds and the
// whole difference is one BigInt subtraction: round the elapsed nanoseconds to
// smallestUnit, then split the result across the ladder down from largestUnit.
fn void instant_until_since(BuiltinContext* ctx, bool until) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "until/since requires an Instant argument");
        return;
    }
    hbigint::HBigInt* other_ns;
    if (!to_temporal_instant(ctx, arg_at(ctx, 0), &other_ns)) return;
    defer ctx.heap.decref((types::HeapHeader*)other_ns);

    // Instant spans no calendar, so units coarser than "hour" are rejected.
    //
    // negate_mode is false even for `since`. The operands below are swapped, so
    // the difference already carries the final sign and the rounding mode is
    // adjusted against that sign directly.
    DiffSettings ds;
    if (!read_diff_settings(ctx, 1, temporal::TemporalUnit.HOUR, temporal::TemporalUnit.NANOSECOND,
                            temporal::TemporalUnit.SECOND, temporal::TemporalUnit.NANOSECOND, false, &ds)) return;

    HObject* self = (HObject*)ctx.this_val.get_heapptr();
    hbigint::HBigInt* a;
    hbigint::HBigInt* b;
    if (until) { a = other_ns; b = self.extra.temporal.big_ns; }
    else       { a = self.extra.temporal.big_ns; b = other_ns; }

    hbigint::HBigInt*? diff_o = hbigint::hbigint_addsub(ctx.heap, a, b, true);
    if (catch err = diff_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "difference overflow"); return; }
    hbigint::HBigInt* diff = diff_o;

    // Rounding to nanoseconds by 1 is the identity, so skip the BigInt work.
    long incr_ns = temporal::unit_ns_divisor(ds.smallest) * (long)ds.increment;
    if (incr_ns > 1) {
        // round_bigint_ns rounds as if the value were positive, while
        // until/since round by magnitude: on a negative difference "trunc"
        // moves toward zero, which is up, and "expand" away from it. Mapping
        // the mode to its as-if-positive form avoids negating the BigInt twice.
        temporal::TemporalRoundMode mode = ds.mode;
        if (diff.is_negative()) mode = temporal::mode_for_negative(mode);
        hbigint::HBigInt*? rounded_o = round_bigint_ns(ctx, diff, incr_ns, mode);
        ctx.heap.decref((types::HeapHeader*)diff);
        if (catch err = rounded_o) { builtin_throw(ctx, ctx.heap.range_err_proto, "rounding failed"); return; }
        diff = rounded_o;
    }

    HObject* dur;
    bool ok = instant_ns_split_duration(ctx, diff, ds.largest, &dur);
    ctx.heap.decref((types::HeapHeader*)diff);
    if (!ok) return;
    dur.prototype = ctx.heap.temporal_duration_proto;
    ctx.result.set_object(dur);
}

// Helper: round a BigInt nanosecond value to the nearest multiple of
// `incr_ns` using the spec's `RoundNumberToIncrementAsIfPositive`. Returns a
// newly-allocated BigInt on success; on failure the `catch` path yields
// BIGINT_DIV_ZERO or an allocation fault.
fn hbigint::HBigInt*? round_bigint_ns(BuiltinContext* ctx, hbigint::HBigInt* b, long incr_ns, temporal::TemporalRoundMode rounding_mode) {
    hbigint::HBigInt*? incr_o = hbigint::hbigint_alloc(ctx.heap, (int128)incr_ns);
    if (catch err = incr_o) return err~;
    hbigint::HBigInt* incr = incr_o;
    hbigint::HBigInt* q = null;
    hbigint::HBigInt* r = null;
    if (catch err = hbigint::hbigint_divrem(ctx.heap, b, incr, &q, &r)) {
        ctx.heap.decref((types::HeapHeader*)incr);
        return err~;
    }
    if (q == null || r == null) {
        ctx.heap.decref((types::HeapHeader*)incr);
        ctx.heap.decref((types::HeapHeader*)q);
        ctx.heap.decref((types::HeapHeader*)r);
        return hbigint::BIGINT_ALLOC~;
    }
    int128 qv = q.to_int128();
    int128 rv = r.to_int128();
    int128 incr_128 = (int128)incr_ns;
    // Normalize to floor-division (spec uses RoundNumberToIncrementAsIfPositive,
    // which expects r in [0, incr_ns) with q_f = floor(b/incr_ns)).
    int128 q_f;
    int128 r_f;
    if (rv >= 0) { q_f = qv; r_f = rv; }
    else         { q_f = qv - 1; r_f = rv + incr_128; }
    int128 chosen_q;
    if (r_f == 0) {
        chosen_q = q_f;
    } else {
        switch (rounding_mode) {
            // floor / trunc → unsigned "zero" → always r1.
            case temporal::TemporalRoundMode.FLOOR:
            case temporal::TemporalRoundMode.TRUNC: chosen_q = q_f; break;
            // ceil / expand → unsigned "infinity" → always r2.
            case temporal::TemporalRoundMode.CEIL:
            case temporal::TemporalRoundMode.EXPAND: chosen_q = q_f + 1; break;
            // half-* modes pick the closer candidate, breaking ties per unsigned mode.
            case temporal::TemporalRoundMode.HALF_FLOOR:
            case temporal::TemporalRoundMode.HALF_TRUNC:
            case temporal::TemporalRoundMode.HALF_CEIL:
            case temporal::TemporalRoundMode.HALF_EXPAND:
            case temporal::TemporalRoundMode.HALF_EVEN: {
                int128 two_r = r_f * 2;
                if (two_r < incr_128) {
                    chosen_q = q_f;
                } else if (two_r > incr_128) {
                    chosen_q = q_f + 1;
                } else {
                    switch (rounding_mode) {
                        case temporal::TemporalRoundMode.HALF_FLOOR:
                        case temporal::TemporalRoundMode.HALF_TRUNC: chosen_q = q_f; break;
                        case temporal::TemporalRoundMode.HALF_CEIL:
                        case temporal::TemporalRoundMode.HALF_EXPAND: chosen_q = q_f + 1; break;
                        case temporal::TemporalRoundMode.HALF_EVEN:
                            chosen_q = ((q_f & 1) == 0) ? q_f : q_f + 1; break;
                        default: chosen_q = q_f; break;  // unreachable
                    }
                }
                break;
            }
        }
    }
    ctx.heap.decref((types::HeapHeader*)q);
    ctx.heap.decref((types::HeapHeader*)r);
    hbigint::HBigInt*? chosen_o = hbigint::hbigint_alloc(ctx.heap, chosen_q);
    if (catch err = chosen_o) {
        ctx.heap.decref((types::HeapHeader*)incr);
        return err~;
    }
    hbigint::HBigInt* chosen = chosen_o;
    hbigint::HBigInt*? result = hbigint::hbigint_mul(ctx.heap, chosen, incr);
    ctx.heap.decref((types::HeapHeader*)chosen);
    ctx.heap.decref((types::HeapHeader*)incr);
    return result;
}

// Temporal.Instant.prototype.round([options]) — see spec
// §sec-temporal.instant.prototype.round. Rounds `this` to the chosen
// `smallestUnit` (hour, minute, second, millisecond, microsecond, or
// nanosecond). Accepts `roundingIncrement` and `roundingMode`; the IANA
// time-zone is irrelevant because Instants are point-in-time.
fn void builtin_temporal_instant_proto_round(BuiltinContext* ctx) {
    if (!brand_check(ctx, &ctx.this_val, hobject::ObjClass.TEMPORAL_INSTANT, "this is not a Temporal.Instant")) return;
    if (ctx.argc < 1) { builtin_throw(ctx, ctx.heap.type_err_proto, "round requires an options argument"); return; }
    TVal* arg = arg_at(ctx, 0);
    HObject* opts;
    if (arg.is_string()) {
        // String shorthand: round(string) is equivalent to round({ smallestUnit: string }).
        HString* hstr = (HString*)arg.get_heapptr();
        if (hstr == null) { builtin_throw(ctx, ctx.heap.range_err_proto, "round string shorthand is invalid"); return; }
        HObject*? bag_o = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = bag_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
        HObject* bag = bag_o;
        HString* su_key = builtin_intern_string(ctx.heap, "smallestUnit");
        HString* su_copy = builtin_intern_string(ctx.heap, (String)hstr.get_cstr()[:hstr.blen]);
        TVal su_tv;
        su_tv.set_string(su_copy);
        PropFlags pf;
        pf.writable = true;
        pf.enumerable = true;
        pf.configurable = true;
        pf.is_accessor = false;
        bag.put_prop(su_key, su_tv, pf, ctx.heap);
        opts = bag;
    } else if (arg.is_object() && arg.get_heapptr() != null) {
        opts = (HObject*)arg.get_heapptr();
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "round options must be an object or a string");
        return;
    }
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();

    // Spec §3.1: read all options before any algorithmic validation so that
    // observable property access (Proxy handlers, TemporalHelpers probes)
    // occurs in a stable order independent of which validation trips first.
    // Per spec §Temporal.Instant.prototype.round steps 7-9: read and convert
    // each option in order — roundingIncrement first (with ToNumber → valueOf),
    // then roundingMode (with ToString → toString), then smallestUnit (with
    // ToString → toString). Validation runs after all three have been observed.
    TVal ri_v = prop_or_undefined_pa(ctx, opts, "roundingIncrement");
    double ri_val = 1;
    if (!ri_v.is_undefined()) {
        Vm* v = (Vm*)ctx.vm;
        ri_val = vm::vm_to_number(v, &ri_v);
        if (v.throw_pending) { ctx.should_throw = true; ctx.heap.tval_copy_ref(&ctx.throw_value, &v.throw_value); v.throw_pending = false; return; }
    }
    TVal rm_v = prop_or_undefined_pa(ctx, opts, "roundingMode");
    HString* rm_str = null;
    if (!rm_v.is_undefined()) {
        rm_str = builtin_to_string_vm(ctx, &rm_v);
        if (ctx.should_throw) return;
    }
    TVal su_v = prop_or_undefined_pa(ctx, opts, "smallestUnit");
    if (su_v.is_undefined()) { builtin_throw(ctx, ctx.heap.range_err_proto, "round requires a smallestUnit option"); return; }
    HString* su_str = builtin_to_string_vm(ctx, &su_v);
    if (ctx.should_throw) return;

    // Algorithmic validation now that all props have been observed.
    temporal::TemporalUnit smallest_unit;
    if (!temporal::parse_unit_str(su_str.get_cstr()[:su_str.blen], &smallest_unit)
        || smallest_unit < temporal::TemporalUnit.HOUR) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "invalid smallestUnit for Instant.round");
        return;
    }
    double rounding_increment = 1;
    if (!ri_v.is_undefined()) {
        if (math::is_nan(ri_val) || math::is_inf(ri_val) || ri_val < 1 || ri_val > 1e9) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be a finite positive integer (≤ 1e9)");
            return;
        }
        // Per spec: non-integer increments are truncated, not rejected.
        rounding_increment = math::floor(ri_val);
        if (rounding_increment < 1) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement must be ≥ 1 after truncation");
            return;
        }
    }
    long divisor = temporal::unit_ns_divisor(smallest_unit);
    // Spec §ValidateTemporalRoundingIncrement: increment must satisfy
    //   (1) inc ≤ maximum (inclusive)
    //   (2) dividend mod inc == 0
    // where dividend is "number of this-unit-in-one-solar-day" for Instant.
    // That is dividend = 86400 seconds / (this unit in seconds). Computed as
    // nsPerDay / divisor = (86400 * 1e9) / divisor.
    long long_solar_ns = 86400L * temporal::NS_PER_SEC;
    long dividend = divisor > 0 ? (long)(long_solar_ns / divisor) : 1;
    long long_incr = (long)rounding_increment;
    if (long_incr > dividend || dividend % long_incr != 0) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "roundingIncrement is out of range");
        return;
    }

    temporal::TemporalRoundMode rounding_mode = temporal::TemporalRoundMode.HALF_EXPAND;
    if (rm_str != null) {
        if (!temporal::parse_rm_str(rm_str.get_cstr()[:rm_str.blen], &rounding_mode)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "invalid roundingMode");
            return;
        }
    }

    hbigint::HBigInt* b = obj.extra.temporal.big_ns;
    long incr_ns = divisor * (long)rounding_increment;
    hbigint::HBigInt*? result = round_bigint_ns(ctx, b, incr_ns, rounding_mode);
    if (catch err = result) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "round failed");
        return;
    }
    HObject*? inst_o = alloc_instant(ctx.heap, result);
    ctx.heap.decref((types::HeapHeader*)result);
    if (catch err2 = inst_o) { builtin_throw(ctx, ctx.heap.err_proto, "alloc failed"); return; }
    HObject* inst = inst_o;
    inst.prototype = ctx.heap.temporal_instant_proto;
    ctx.result.set_object(inst);
}

// Helper: convert a BigInt to a double representing nanoseconds. The result
// is precise for any BigInt whose absolute value fits in 2^53 (~285 years
// of nanoseconds). Throws RangeError if the magnitude is too large.
fn bool bigint_to_epoch_number(hbigint::HBigInt* b, double* out, BuiltinContext* ctx) {
    if (b == null) { *out = 0.0; return true; }
    if (!b.fits_int128()) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Instant too large for Number conversion");
        return false;
    }
    int128 v = b.to_int128();
    *out = (double)v;
    return true;
}

