/// Atomics built-in object (ES2024 §25.4), single-agent variant.
///
/// This engine runs a single agent with no worker threads, so every atomic
/// read-modify-write is a plain (uncontended) memory operation. Atomics work on
/// both SharedArrayBuffer- and (per ES2024) ArrayBuffer-backed integer
/// TypedArrays. `wait`/`notify`/`waitAsync` degrade to their single-agent
/// no-waiter behaviour: `notify` always reports 0, `wait` returns "not-equal"
/// or "timed-out" without ever blocking, and `waitAsync` returns a synchronous
/// {async:false, value:...} result.
module duktape::builtins;

import duktape::types;
import duktape::hstring;
import duktape::heap;
import duktape::hobject;
import duktape::hbigint;
import duktape::env;
import std::io;
import std::math;

// ============================================================================
// Error helpers (reuse ArrayBuffer's, defined in arraybuffer.c3)
// ============================================================================

fn void atomics_throw_type_error(BuiltinContext* ctx, char[] msg) {
    arraybuffer_throw_type_error(ctx, msg);
}

fn void atomics_throw_range_error(BuiltinContext* ctx, char[] msg) {
    arraybuffer_throw_range_error(ctx, msg);
}

// ============================================================================
// ValidateIntegerTypedArray (§25.4.3.2) + ValidateAtomicAccess (§25.4.3.4)
// ============================================================================

/// True iff `cls` is an integer TypedArray kind valid for Atomics operations
/// (Int8/Uint8/Int16/Uint16/Int32/Uint32/BigInt64/BigUint64). Excludes
/// Uint8ClampedArray and the float kinds.
fn bool atomics_is_valid_int_class(hobject::ObjClass cls) {
    switch (cls) {
        case hobject::ObjClass.INT8ARRAY:
        case hobject::ObjClass.UINT8ARRAY:
        case hobject::ObjClass.INT16ARRAY:
        case hobject::ObjClass.UINT16ARRAY:
        case hobject::ObjClass.INT32ARRAY:
        case hobject::ObjClass.UINT32ARRAY:
        case hobject::ObjClass.BIGINT64ARRAY:
        case hobject::ObjClass.BIGUINT64ARRAY:
            return true;
        default:
            return false;
    }
}

/// ValidateIntegerTypedArray(typedArray, waitable): returns the view HObject
/// (validated as an integer TypedArray) or null (with a thrown TypeError).
/// When `waitable` is true, only Int32Array / BigInt64Array are accepted.
fn HObject* atomics_validate_int_ta(BuiltinContext* ctx, TVal arg, bool waitable) {
    if (!arg.is_object() || arg.get_heapptr() == null) {
        atomics_throw_type_error(ctx, "Atomics operation requires a TypedArray");
        return null;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    hobject::ObjClass cls = obj.flags.obj_class;
    if (!is_typed_array_class(cls)) {
        atomics_throw_type_error(ctx, "Atomics operation requires a TypedArray");
        return null;
    }
    if (waitable) {
        if (cls != hobject::ObjClass.INT32ARRAY && cls != hobject::ObjClass.BIGINT64ARRAY) {
            atomics_throw_type_error(ctx, "Atomics.wait requires an Int32Array or BigInt64Array");
            return null;
        }
    } else {
        if (!atomics_is_valid_int_class(cls)) {
            atomics_throw_type_error(ctx, "Atomics operation requires an integer TypedArray");
            return null;
        }
    }
    // ValidateIntegerTypedArray → the buffer must not be detached / the view
    // out of bounds (§25.4.3.2 via MakeTypedArrayWithBufferWitnessRecord). This
    // runs before any index/value coercion.
    if (ta_is_detached(obj)) {
        atomics_throw_type_error(ctx, "Atomics: TypedArray backing buffer is detached or out of bounds");
        return null;
    }
    return obj;
}

/// ValidateAtomicAccess(taRecord, requestIndex): ToIndex(requestIndex) then
/// bounds-check against the CURRENT element count. Returns false (with a thrown
/// RangeError or a propagated ToIndex throw) on failure; otherwise writes the
/// validated element index to *out_idx.
fn bool atomics_validate_access(BuiltinContext* ctx, HObject* ta, TVal idx_arg, uint* out_idx) {
    *out_idx = 0;
    // §25.4.3.4 ValidateAtomicAccess: capture length (step 1) BEFORE ToIndex
    // (step 2), a resize triggered by index coercion must not affect the bound.
    uint len = ta_element_count(ta);
    // ToIndex (§7.1.22), may run user code.
    double d = 0.0;
    if (idx_arg.is_fastint()) {
        long v = idx_arg.get_fastint();
        if (v < 0) { atomics_throw_range_error(ctx, "Atomics access index out of range"); return false; }
        d = (double)v;
    } else {
        d = builtin_to_integer_vm(ctx, &idx_arg);
        if (ctx.should_throw) return false;
        if (d != d) d = 0.0; // NaN -> 0
        if (d < 0.0) { atomics_throw_range_error(ctx, "Atomics access index out of range"); return false; }
        if (d > 9007199254740991.0) { atomics_throw_range_error(ctx, "Atomics access index out of range"); return false; }
    }
    if (d >= (double)len) {
        atomics_throw_range_error(ctx, "Atomics access index out of range");
        return false;
    }
    *out_idx = (uint)(long)d;
    return true;
}

/// True when the view's backing buffer is detached or the view is out of bounds.
fn bool atomics_revalidate(HObject* ta) {
    return ta_is_detached(ta);
}

// ============================================================================
// Element read/write at a raw byte pointer for a validated integer class.
// Returns the previous value as a TVal (fastint / number / bigint).
// ============================================================================

fn char* atomics_elem_ptr(HObject* ta, uint idx) {
    HObject* buf = (*ta.extra_ptr()).view.buffer;
    char* base = (*buf.extra_ptr()).ab.data + (*ta.extra_ptr()).view.byte_offset;
    uint shift = ta_elem_shift(ta.flags.obj_class);
    return base + (idx << shift);
}

/// Read the current element as a TVal (used by load/exchange/etc. to return the
/// "previous" value).
fn TVal atomics_read(Heap* heap, HObject* ta, uint idx) {
    HObject* buf = (*ta.extra_ptr()).view.buffer;
    char* base = (*buf.extra_ptr()).ab.data + (*ta.extra_ptr()).view.byte_offset;
    return ta_load_element(heap, base, ta.flags.obj_class, idx);
}

// ============================================================================
// Value coercion, §25.4.1.1 ToIntegerOrInfinity / ToBigInt depending on class.
// Returns the low 64 bits as a `long` (for integer kinds, the coerced int32/
// uint32/… truncated to the element width at store time). BigInt kinds go
// through ToBigInt.
// ============================================================================

/// Coerce a value argument for a non-BigInt integer TypedArray. Produces the
/// ToIntegerOrInfinity result as a double (store truncates to width). Returns
/// false on a propagated throw.
fn bool atomics_coerce_number(BuiltinContext* ctx, TVal* val, double* out) {
    *out = 0.0;
    if (val.is_fastint()) { *out = (double)val.get_fastint(); return true; }
    double d = builtin_to_integer_vm(ctx, val);
    if (ctx.should_throw) return false;
    *out = d;
    return true;
}

/// Coerce a value argument for a BigInt TypedArray (ToBigInt). Returns false on
/// a propagated throw.
fn bool atomics_coerce_bigint(BuiltinContext* ctx, TVal* val, int128* out) {
    *out = 0;
    bool ok;
    int128 bv = builtin_to_bigint(ctx, val, &ok);
    if (!ok || ctx.should_throw) return false;
    *out = bv;
    return true;
}

// Integer op kinds for the read-modify-write dispatcher.
enum AtomicOp : char {
    ADD, AND, OR, SUB, XOR, EXCHANGE, COMPARE_EXCHANGE, STORE,
}

/// Perform the read-modify-write for a non-BigInt integer element. `p` points
/// at the element; `width` is the byte width; `signed_kind` selects sign
/// extension for the returned old value. `operand` is the ToInteger'd argument,
/// `expected` is only used for COMPARE_EXCHANGE. Writes the returned "old value"
/// into *old_out (as a double so both int32 and uint32 fit).
fn void atomics_rmw_int(char* p, hobject::ObjClass cls, AtomicOp op, double operand, double expected, double* old_out) {
    uint width = ta_elem_size(cls);
    bool is_signed = (cls == hobject::ObjClass.INT8ARRAY
        || cls == hobject::ObjClass.INT16ARRAY
        || cls == hobject::ObjClass.INT32ARRAY);

    // Read current raw value (zero-extended into u64).
    ulong cur = 0;
    switch (width) {
        case 1: cur = (ulong)*(char*)p; break;
        case 2: { ushort v; mem::copy(&v, p, (sz)(2)); cur = (ulong)v; break; }
        case 4: { uint v; mem::copy(&v, p, (sz)(4)); cur = (ulong)v; break; }
        default: break;
    }

    // Old value as a properly-signed double for the return.
    *old_out = atomics_raw_to_double(cur, width, is_signed);

    // Compute operand as an integer in u64 (mod 2^width via masking at store).
    long opnd = double_to_int_wrap(operand);
    long exp = double_to_int_wrap(expected);

    ulong result = cur;
    switch (op) {
        case ADD:      result = cur + (ulong)opnd; break;
        case AND:      result = cur & (ulong)opnd; break;
        case OR:       result = cur | (ulong)opnd; break;
        case SUB:      result = cur - (ulong)opnd; break;
        case XOR:      result = cur ^ (ulong)opnd; break;
        case EXCHANGE: result = (ulong)opnd; break;
        case STORE:    result = (ulong)opnd; break;
        case COMPARE_EXCHANGE: {
            // Compare current (masked to width) against expected (masked).
            ulong mask = atomics_width_mask(width);
            if ((cur & mask) == ((ulong)exp & mask)) {
                result = (ulong)opnd;
            } else {
                result = cur;
            }
            break;
        }
    }

    // Store back, truncated to width.
    switch (width) {
        case 1: *(char*)p = (char)(result & 0xFF); break;
        case 2: { ushort v = (ushort)(result & 0xFFFF); mem::copy(p, &v, (sz)(2)); break; }
        case 4: { uint v = (uint)(result & 0xFFFFFFFF); mem::copy(p, &v, (sz)(4)); break; }
        default: break;
    }
}

fn ulong atomics_width_mask(uint width) {
    switch (width) {
        case 1: return 0xFFuL;
        case 2: return 0xFFFFuL;
        case 4: return 0xFFFFFFFFuL;
        default: return 0xFFFFFFFFFFFFFFFFuL;
    }
}

/// Convert a raw zero-extended value of `width` bytes to a double, applying sign
/// extension when `is_signed`.
fn double atomics_raw_to_double(ulong raw, uint width, bool is_signed) {
    switch (width) {
        case 1:
            if (is_signed) return (double)(long)(ichar)(char)raw;
            return (double)(char)raw;
        case 2:
            if (is_signed) return (double)(long)(short)(ushort)raw;
            return (double)(ushort)raw;
        case 4:
            if (is_signed) return (double)(long)(int)(uint)raw;
            return (double)(uint)raw;
        default:
            return (double)raw;
    }
}

/// ToInteger'd double -> a long, truncating toward zero and wrapping mod 2^64.
fn long double_to_int_wrap(double d) {
    if (d != d) return 0;
    // Reduce mod 2^64 in a way that matches two's-complement store truncation.
    // For the ranges Atomics operands appear in (already ToInteger'd), a direct
    // cast through int128 keeps the low 64 bits correct.
    if (d >= 9223372036854775808.0 || d <= -9223372036854775808.0) {
        // Out of long range: reduce via fmod over 2^64.
        double m = math::floor(d);
        double twop64 = 18446744073709551616.0;
        double r = m - math::floor(m / twop64) * twop64; // in [0, 2^64)
        if (r >= 9223372036854775808.0) r -= twop64;
        return (long)r;
    }
    return (long)d;
}

// ============================================================================
// BigInt read-modify-write.
// ============================================================================

fn void atomics_rmw_bigint(char* p, hobject::ObjClass cls, AtomicOp op, int128 operand, int128 expected, int128* old_out) {
    long raw;
    mem::copy(&raw, p, (sz)(8));
    int128 cur;
    if (cls == hobject::ObjClass.BIGINT64ARRAY) {
        cur = (int128)raw;
    } else {
        cur = (int128)(uint128)(ulong)raw;
    }
    *old_out = cur;

    int128 result = cur;
    switch (op) {
        case ADD:      result = cur + operand; break;
        case AND:      result = cur & operand; break;
        case OR:       result = cur | operand; break;
        case SUB:      result = cur - operand; break;
        case XOR:      result = cur ^ operand; break;
        case EXCHANGE: result = operand; break;
        case STORE:    result = operand; break;
        case COMPARE_EXCHANGE: {
            // Compare low 64 bits.
            if ((long)cur == (long)expected) { result = operand; } else { result = cur; }
            break;
        }
    }
    long lo = (long)result; // low 64 bits
    mem::copy(p, &lo, (sz)(8));
}

// ============================================================================
// Generic AtomicReadModifyWrite (§25.4.3.11) driver for the 8 RMW builtins.
// ============================================================================

fn void atomics_rmw_op(BuiltinContext* ctx, AtomicOp op) {
    TVal ta_arg;   ta_arg.set_undefined();
    TVal idx_arg;  idx_arg.set_undefined();
    TVal val_arg;  val_arg.set_undefined();
    if (ctx.argc >= 1) ta_arg  = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) idx_arg = ctx.regs[ctx.base_reg + 1];
    if (ctx.argc >= 3) val_arg = ctx.regs[ctx.base_reg + 2];

    HObject* ta = atomics_validate_int_ta(ctx, ta_arg, false);
    if (ta == null) return;

    uint idx = 0;
    if (!atomics_validate_access(ctx, ta, idx_arg, &idx)) return;

    hobject::ObjClass cls = ta.flags.obj_class;
    bool is_big = is_bigint_typed_array_class(cls);

    // Coerce the value operand (may run user code / throw).
    double num_operand = 0.0;
    int128 big_operand = 0;
    if (is_big) {
        if (!atomics_coerce_bigint(ctx, &val_arg, &big_operand)) return;
    } else {
        if (!atomics_coerce_number(ctx, &val_arg, &num_operand)) return;
    }

    // Revalidate after coercion (detach / OOB).
    if (atomics_revalidate(ta)) {
        // Per §25.4.3.11: if IsIntegerIndexedObjectOutOfBounds, throw TypeError.
        atomics_throw_type_error(ctx, "Atomics: TypedArray backing buffer became detached or out of bounds");
        return;
    }
    if (idx >= ta_element_count(ta)) {
        atomics_throw_range_error(ctx, "Atomics access index out of range");
        return;
    }

    char* p = atomics_elem_ptr(ta, idx);
    if (is_big) {
        int128 old;
        atomics_rmw_bigint(p, cls, op, big_operand, 0, &old);
        atomics_set_bigint_result(ctx, cls, old);
    } else {
        double old = 0.0;
        atomics_rmw_int(p, cls, op, num_operand, 0.0, &old);
        atomics_set_num_result(ctx, cls, old);
    }
}

/// Store the "old value" of a non-BigInt RMW as the builtin result (fastint or
/// number, matching the element kind's read semantics).
fn void atomics_set_num_result(BuiltinContext* ctx, hobject::ObjClass cls, double old) {
    if (cls == hobject::ObjClass.UINT32ARRAY) {
        if (old >= 2147483648.0) { ctx.result.set_number(old); return; }
    }
    // Integer-valued; fits in fastint for all 8/16/signed-32 kinds and small u32.
    ctx.result.set_fastint((long)old);
}

/// Store the "old value" of a BigInt RMW as a BigInt result.
fn void atomics_set_bigint_result(BuiltinContext* ctx, hobject::ObjClass cls, int128 old) {
    int128 v = old;
    if (cls == hobject::ObjClass.BIGUINT64ARRAY) {
        v = (int128)(uint128)(ulong)(long)old;
    }
    builtin_set_bigint_result(ctx, v);
}

// ============================================================================
// Public builtins
// ============================================================================

fn void builtin_atomics_add(BuiltinContext* ctx)  { atomics_rmw_op(ctx, AtomicOp.ADD); }
fn void builtin_atomics_and(BuiltinContext* ctx)  { atomics_rmw_op(ctx, AtomicOp.AND); }
fn void builtin_atomics_or(BuiltinContext* ctx)   { atomics_rmw_op(ctx, AtomicOp.OR); }
fn void builtin_atomics_sub(BuiltinContext* ctx)  { atomics_rmw_op(ctx, AtomicOp.SUB); }
fn void builtin_atomics_xor(BuiltinContext* ctx)  { atomics_rmw_op(ctx, AtomicOp.XOR); }
fn void builtin_atomics_exchange(BuiltinContext* ctx) { atomics_rmw_op(ctx, AtomicOp.EXCHANGE); }

/// Atomics.store(ta, index, value), §25.4.3.13. Unlike the RMW ops, store
/// returns the *stored* value (after coercion), not the old value.
fn void builtin_atomics_store(BuiltinContext* ctx) {
    TVal ta_arg;   ta_arg.set_undefined();
    TVal idx_arg;  idx_arg.set_undefined();
    TVal val_arg;  val_arg.set_undefined();
    if (ctx.argc >= 1) ta_arg  = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) idx_arg = ctx.regs[ctx.base_reg + 1];
    if (ctx.argc >= 3) val_arg = ctx.regs[ctx.base_reg + 2];

    HObject* ta = atomics_validate_int_ta(ctx, ta_arg, false);
    if (ta == null) return;

    uint idx = 0;
    if (!atomics_validate_access(ctx, ta, idx_arg, &idx)) return;

    hobject::ObjClass cls = ta.flags.obj_class;
    bool is_big = is_bigint_typed_array_class(cls);

    double num_operand = 0.0;
    int128 big_operand = 0;
    if (is_big) {
        if (!atomics_coerce_bigint(ctx, &val_arg, &big_operand)) return;
    } else {
        if (!atomics_coerce_number(ctx, &val_arg, &num_operand)) return;
    }

    if (atomics_revalidate(ta)) {
        atomics_throw_type_error(ctx, "Atomics.store: TypedArray backing buffer became detached or out of bounds");
        return;
    }
    if (idx >= ta_element_count(ta)) {
        atomics_throw_range_error(ctx, "Atomics access index out of range");
        return;
    }

    char* p = atomics_elem_ptr(ta, idx);
    if (is_big) {
        int128 old;
        atomics_rmw_bigint(p, cls, AtomicOp.STORE, big_operand, 0, &old);
        // store returns the ToBigInt'd value itself (§25.4.3.13 step 3 returns
        // `v`), NOT the width-reinterpreted stored bits.
        builtin_set_bigint_result(ctx, big_operand);
    } else {
        double old = 0.0;
        atomics_rmw_int(p, cls, AtomicOp.STORE, num_operand, 0.0, &old);
        // store returns the (integer) value that was passed, as a Number.
        atomics_store_num_result(ctx, num_operand);
    }
}

/// Atomics.store returns the ToInteger'd value as a Number (not truncated to
/// the element width) per §25.4.3.13 step 8 (returns `v`, the ToInteger result).
fn void atomics_store_num_result(BuiltinContext* ctx, double v) {
    // The returned value is the ToIntegerOrInfinity result. For finite integers
    // that fit in a fastint use it, else use a number.
    if (v == math::floor(v) && v >= -9007199254740992.0 && v <= 9007199254740992.0
        && v >= -9223372036854775808.0 && v < 9223372036854775807.0) {
        ctx.result.set_fastint((long)v);
    } else {
        ctx.result.set_number(v);
    }
}

/// Atomics.compareExchange(ta, index, expected, replacement), §25.4.3.9.
fn void builtin_atomics_compareexchange(BuiltinContext* ctx) {
    TVal ta_arg;   ta_arg.set_undefined();
    TVal idx_arg;  idx_arg.set_undefined();
    TVal exp_arg;  exp_arg.set_undefined();
    TVal rep_arg;  rep_arg.set_undefined();
    if (ctx.argc >= 1) ta_arg  = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) idx_arg = ctx.regs[ctx.base_reg + 1];
    if (ctx.argc >= 3) exp_arg = ctx.regs[ctx.base_reg + 2];
    if (ctx.argc >= 4) rep_arg = ctx.regs[ctx.base_reg + 3];

    HObject* ta = atomics_validate_int_ta(ctx, ta_arg, false);
    if (ta == null) return;

    uint idx = 0;
    if (!atomics_validate_access(ctx, ta, idx_arg, &idx)) return;

    hobject::ObjClass cls = ta.flags.obj_class;
    bool is_big = is_bigint_typed_array_class(cls);

    double num_exp = 0.0; double num_rep = 0.0;
    int128 big_exp = 0; int128 big_rep = 0;
    if (is_big) {
        if (!atomics_coerce_bigint(ctx, &exp_arg, &big_exp)) return;
        if (!atomics_coerce_bigint(ctx, &rep_arg, &big_rep)) return;
    } else {
        if (!atomics_coerce_number(ctx, &exp_arg, &num_exp)) return;
        if (!atomics_coerce_number(ctx, &rep_arg, &num_rep)) return;
    }

    if (atomics_revalidate(ta)) {
        atomics_throw_type_error(ctx, "Atomics.compareExchange: buffer became detached or out of bounds");
        return;
    }
    if (idx >= ta_element_count(ta)) {
        atomics_throw_range_error(ctx, "Atomics access index out of range");
        return;
    }

    char* p = atomics_elem_ptr(ta, idx);
    if (is_big) {
        int128 old;
        atomics_rmw_bigint(p, cls, AtomicOp.COMPARE_EXCHANGE, big_rep, big_exp, &old);
        atomics_set_bigint_result(ctx, cls, old);
    } else {
        double old = 0.0;
        atomics_rmw_int(p, cls, AtomicOp.COMPARE_EXCHANGE, num_rep, num_exp, &old);
        atomics_set_num_result(ctx, cls, old);
    }
}

/// Atomics.load(ta, index), §25.4.3.12.
fn void builtin_atomics_load(BuiltinContext* ctx) {
    TVal ta_arg;   ta_arg.set_undefined();
    TVal idx_arg;  idx_arg.set_undefined();
    if (ctx.argc >= 1) ta_arg  = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) idx_arg = ctx.regs[ctx.base_reg + 1];

    HObject* ta = atomics_validate_int_ta(ctx, ta_arg, false);
    if (ta == null) return;

    uint idx = 0;
    if (!atomics_validate_access(ctx, ta, idx_arg, &idx)) return;

    if (atomics_revalidate(ta)) {
        atomics_throw_type_error(ctx, "Atomics.load: buffer became detached or out of bounds");
        return;
    }
    if (idx >= ta_element_count(ta)) {
        atomics_throw_range_error(ctx, "Atomics access index out of range");
        return;
    }

    *ctx.result = atomics_read(ctx.heap, ta, idx);
}

/// Atomics.isLockFree(size), §25.4.3.15. Returns whether an atomic op on a
/// value of the given byte size is lock-free. Per QuickJS: 1,2,4,8 are lock-free.
fn void builtin_atomics_islockfree(BuiltinContext* ctx) {
    TVal size_arg; size_arg.set_undefined();
    if (ctx.argc >= 1) size_arg = ctx.regs[ctx.base_reg];
    double n = builtin_to_integer_vm(ctx, &size_arg);
    if (ctx.should_throw) return;
    bool lock_free = (n == 1.0 || n == 2.0 || n == 4.0 || n == 8.0);
    ctx.result.set_boolean(lock_free);
}

// ============================================================================
// wait / notify / waitAsync, single-agent degenerate behaviour.
// ============================================================================

/// Atomics.wait(ta, index, value, timeout), §25.4.13.
/// This engine's single main agent has AgentCanSuspend = true, but with no
/// other agents there is never a notifier, so wait never actually blocks: it
/// returns "not-equal" when the cell differs from `value`, and "timed-out"
/// otherwise (any finite/zero/negative timeout elapses instantly; an infinite
/// timeout with no possible notifier likewise cannot make progress and would
/// deadlock, so we conservatively return "timed-out" too). Argument validation
/// (ValidateIntegerTypedArray waitable, ValidateAtomicAccess, ToInteger of
/// value, ToNumber of timeout) runs first and may throw.
fn void builtin_atomics_wait(BuiltinContext* ctx) {
    TVal ta_arg;   ta_arg.set_undefined();
    TVal idx_arg;  idx_arg.set_undefined();
    TVal val_arg;  val_arg.set_undefined();
    TVal to_arg;   to_arg.set_undefined();
    if (ctx.argc >= 1) ta_arg  = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) idx_arg = ctx.regs[ctx.base_reg + 1];
    if (ctx.argc >= 3) val_arg = ctx.regs[ctx.base_reg + 2];
    if (ctx.argc >= 4) to_arg  = ctx.regs[ctx.base_reg + 3];

    HObject* ta = atomics_validate_int_ta(ctx, ta_arg, true);
    if (ta == null) return;

    // The buffer must be shared for wait (§25.4.13 step 3: RevalidateAtomicAccess
    // requires a SharedArrayBuffer).
    HObject* buf = (*ta.extra_ptr()).view.buffer;
    if (buf == null || !(*buf.extra_ptr()).ab.is_shared) {
        atomics_throw_type_error(ctx, "Atomics.wait requires a SharedArrayBuffer-backed TypedArray");
        return;
    }

    uint idx = 0;
    if (!atomics_validate_access(ctx, ta, idx_arg, &idx)) return;

    // Coerce value (BigInt for BigInt64Array, else ToInteger).
    hobject::ObjClass cls = ta.flags.obj_class;
    bool matches;
    if (cls == hobject::ObjClass.BIGINT64ARRAY) {
        int128 b;
        if (!atomics_coerce_bigint(ctx, &val_arg, &b)) return;
        char* p = atomics_elem_ptr(ta, idx);
        long raw; mem::copy(&raw, p, (sz)(8));
        matches = ((long)b == raw);
    } else {
        double d = builtin_to_integer_vm(ctx, &val_arg);
        if (ctx.should_throw) return;
        char* p = atomics_elem_ptr(ta, idx);
        int raw; mem::copy(&raw, p, (sz)(4));
        matches = ((int)double_to_int_wrap(d) == raw);
    }

    // ToNumber(timeout), may run user code / throw.
    double timeout = builtin_to_number_vm(ctx, &to_arg);
    if (ctx.should_throw) return;

    char[] verdict = matches ? "timed-out" : "not-equal";
    ctx.result.set_string(builtin_intern_string(ctx.heap, verdict));
}

/// Atomics.notify(ta, index, count), §25.4.14.
/// With no other agents ever waiting, always returns 0.
/// Atomics.pause([iterationNumber]), ES2025 §25.4.6 (microwait). A spin-wait
/// hint to the CPU; observably a no-op. iterationNumber, when present and not
/// undefined, must already BE an integral Number (no coercion), else
/// TypeError. Negative integers are allowed. Length is 0.
fn void builtin_atomics_pause(BuiltinContext* ctx) {
    if (ctx.argc >= 1) {
        TVal n = ctx.regs[ctx.base_reg];
        if (!n.is_undefined()) {
            bool ok = n.is_fastint();
            if (!ok && n.get_tag() == types::TValTag.NUMBER) {
                double d = n.get_number();
                ok = !math::is_nan(d) && !math::is_inf(d) && math::floor(d) == d;
            }
            if (!ok) {
                atomics_throw_type_error(ctx, "Atomics.pause: iterationNumber must be an integral number");
                return;
            }
        }
    }
    ctx.result.set_undefined();
}

fn void builtin_atomics_notify(BuiltinContext* ctx) {
    TVal ta_arg;   ta_arg.set_undefined();
    TVal idx_arg;  idx_arg.set_undefined();
    TVal count_arg; count_arg.set_undefined();
    if (ctx.argc >= 1) ta_arg   = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) idx_arg  = ctx.regs[ctx.base_reg + 1];
    if (ctx.argc >= 3) count_arg = ctx.regs[ctx.base_reg + 2];

    HObject* ta = atomics_validate_int_ta(ctx, ta_arg, true);
    if (ta == null) return;

    uint idx = 0;
    if (!atomics_validate_access(ctx, ta, idx_arg, &idx)) return;

    // ToIntegerOrInfinity(count) with default +Infinity when undefined.
    double count = 1.0e308; // sentinel for +Infinity (all waiters)
    if (!count_arg.is_undefined()) {
        double c = builtin_to_integer_vm(ctx, &count_arg);
        if (ctx.should_throw) return;
        count = c < 0.0 ? 0.0 : c;
    }

    // Only shared buffers can have parked async waiters; non-shared: 0.
    HObject* buf = (*ta.extra_ptr()).view.buffer;
    if (buf == null || !(*buf.extra_ptr()).ab.is_shared) {
        ctx.result.set_fastint(0);
        return;
    }

    uint shift = ta_elem_shift(ta.flags.obj_class);
    uint byte_index = (*ta.extra_ptr()).view.byte_offset + (idx << shift);
    long notified = atomics_notify_waiters(ctx, buf, byte_index, count);
    ctx.result.set_fastint(notified);
}

/// Resolve up to `count` parked waitAsync promises on (buffer, byte_index) with
/// "ok" (FIFO). Returns the number resolved.
fn long atomics_notify_waiters(BuiltinContext* ctx, HObject* buffer, uint byte_index, double count) {
    Heap* heap = ctx.heap;
    long resolved = 0;
    for (uint i = 0; i < heap.async_waiter_count; i++) {
        if ((double)resolved >= count) break;
        heap::AtomicsWaiter* w = &heap.async_waiters[i];
        if (!w.active) continue;
        if (w.buffer != buffer || w.byte_index != byte_index) continue;
        w.active = false;
        HObject* promise = w.promise;
        w.promise = null;
        w.buffer = null;
        TVal ok; ok.set_string(builtin_intern_string(heap, "ok"));
        promise_resolve_with_value(promise, ok, heap, ctx.vm);
        resolved++;
    }
    atomics_compact_waiters(heap);
    return resolved;
}

/// Drop trailing inactive waiter slots so the count stays small.
fn void atomics_compact_waiters(Heap* heap) {
    while (heap.async_waiter_count > 0 && !heap.async_waiters[heap.async_waiter_count - 1].active) {
        heap.async_waiter_count--;
    }
}

/// Park a pending Promise on (buffer, byte_index). Returns the promise HObject,
/// or null if no slot is free.
fn HObject* atomics_park_waiter(BuiltinContext* ctx, HObject* buffer, uint byte_index) {
    Heap* heap = ctx.heap;
    // Reuse an inactive slot if one exists.
    uint slot = heap.async_waiter_count;
    for (uint i = 0; i < heap.async_waiter_count; i++) {
        if (!heap.async_waiters[i].active) { slot = i; break; }
    }
    if (slot == heap.async_waiter_count) {
        if (heap.async_waiter_count >= 64) return null; // list full
        heap.async_waiter_count++;
    }
    HObject*? prom_raw = promise_create(heap);
    if (catch e = prom_raw) { return null; }
    HObject* promise = prom_raw;
    heap.async_waiters[slot].buffer = buffer;
    heap.async_waiters[slot].promise = promise;
    heap.async_waiters[slot].byte_index = byte_index;
    heap.async_waiters[slot].active = true;
    return promise;
}

/// Atomics.waitAsync(ta, index, value, timeout), ES2024 §25.4.15.
/// Single-agent: no other agent can ever notify, so this resolves synchronously
/// to {async:false, value:"not-equal"} (when the cell differs) or
/// {async:false, value:"timed-out"} (when it matches; there is no way to block).
fn void builtin_atomics_waitasync(BuiltinContext* ctx) {
    TVal ta_arg;   ta_arg.set_undefined();
    TVal idx_arg;  idx_arg.set_undefined();
    TVal val_arg;  val_arg.set_undefined();
    TVal to_arg;   to_arg.set_undefined();
    if (ctx.argc >= 1) ta_arg  = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) idx_arg = ctx.regs[ctx.base_reg + 1];
    if (ctx.argc >= 3) val_arg = ctx.regs[ctx.base_reg + 2];
    if (ctx.argc >= 4) to_arg  = ctx.regs[ctx.base_reg + 3];

    HObject* ta = atomics_validate_int_ta(ctx, ta_arg, true);
    if (ta == null) return;

    HObject* buf = (*ta.extra_ptr()).view.buffer;
    if (buf == null || !(*buf.extra_ptr()).ab.is_shared) {
        atomics_throw_type_error(ctx, "Atomics.waitAsync requires a SharedArrayBuffer-backed TypedArray");
        return;
    }

    uint idx = 0;
    if (!atomics_validate_access(ctx, ta, idx_arg, &idx)) return;

    hobject::ObjClass cls = ta.flags.obj_class;
    bool matches;
    if (cls == hobject::ObjClass.BIGINT64ARRAY) {
        int128 b;
        if (!atomics_coerce_bigint(ctx, &val_arg, &b)) return;
        char* p = atomics_elem_ptr(ta, idx);
        long raw; mem::copy(&raw, p, (sz)(8));
        matches = ((long)b == raw);
    } else {
        double d = builtin_to_integer_vm(ctx, &val_arg);
        if (ctx.should_throw) return;
        char* p = atomics_elem_ptr(ta, idx);
        int raw; mem::copy(&raw, p, (sz)(4));
        matches = ((int)double_to_int_wrap(d) == raw);
    }

    // ToNumber(timeout), may run user code / throw. NaN/undefined -> +Infinity.
    double timeout = builtin_to_number_vm(ctx, &to_arg);
    if (ctx.should_throw) return;
    bool zero_timeout = (timeout == timeout) && (timeout <= 0.0);

    if (!matches) {
        // Cell differs: no waiting needed. {async:false, value:"not-equal"}.
        atomics_make_wait_result_str(ctx, false, "not-equal");
        return;
    }
    if (zero_timeout) {
        // Value matches but the timeout has already elapsed: {async:false,
        // value:"timed-out"} (no async waiter is parked).
        atomics_make_wait_result_str(ctx, false, "timed-out");
        return;
    }

    // Value matches with a non-zero timeout: park an async waiter and return a
    // pending promise. In this single-agent engine the promise is only ever
    // resolved by a later Atomics.notify on the same location (with "ok"); the
    // timeout is not otherwise driven, matching the tests that notify before
    // draining microtasks.
    uint shift = ta_elem_shift(ta.flags.obj_class);
    uint byte_index = (*ta.extra_ptr()).view.byte_offset + (idx << shift);
    HObject* promise = atomics_park_waiter(ctx, buf, byte_index);
    if (promise == null) {
        // Fallback: no slot, behave as an immediate timeout.
        atomics_make_wait_result_str(ctx, false, "timed-out");
        return;
    }
    TVal prom_tv; prom_tv.set_object(promise);
    atomics_make_wait_result_val(ctx, true, prom_tv);
}

/// Build {async, value:<string>} for waitAsync's synchronous outcomes.
fn void atomics_make_wait_result_str(BuiltinContext* ctx, bool is_async, char[] value_str) {
    TVal v; v.set_string(builtin_intern_string(ctx.heap, value_str));
    atomics_make_wait_result_val(ctx, is_async, v);
}

/// Build the {async, value} object returned by waitAsync.
fn void atomics_make_wait_result_val(BuiltinContext* ctx, bool is_async, TVal value_tv) {
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = raw) { ctx.result.set_undefined(); return; }
    HObject* obj = raw;
    obj.prototype = ctx.heap.object_proto;

    HString* async_key = builtin_intern_string(ctx.heap, "async");
    TVal async_tv; async_tv.set_boolean(is_async);
    obj.put_prop(async_key, async_tv, hobject::PROP_FLAGS_WEC);

    HString* value_key = (HString*)ctx.heap.strs[heap::BuiltinStr.VALUE];
    obj.put_prop(value_key, value_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(obj);
}

// ============================================================================
// Registration
// ============================================================================

/// Register an Atomics method as a lightfunc property with .name/.length set on
/// a proper HObject function (Atomics methods have observable name/length).
fn bool register_atomics_method(HObject* atomics, Heap* heap, char[] name, uint fn_index, int length) {
    HString* key = heap.str_intern(name);
    if (key == null) return false;

    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)fn_index;
    func_obj.flags.callable = true;
    func_obj.flags.constructable = false;
    func_obj.prototype = heap.function_proto;

    HString* fn_name = builtin_intern_string(heap, name);
    if (fn_name != null) {
        TVal name_tv; name_tv.set_string(fn_name);
        func_obj.put_prop((void*)heap.str(heap::BuiltinStr.NAME), name_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (length_key != null) {
        TVal len_tv; len_tv.set_fastint((long)length);
        func_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC);
    }

    TVal fn_tv; fn_tv.set_object(func_obj);
    atomics.put_prop(key, fn_tv, hobject::PROP_FLAGS_WC);
    return true;
}

fn bool register_atomics_object(EnvRecord* global_env, Heap* heap) {
    HObject*? atomics_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = atomics_raw) return false;
    HObject* atomics = atomics_raw;
    atomics.prototype = heap.object_proto;

    if (!register_atomics_method(atomics, heap, "add",             Builtin.ATOMICS_ADD.ordinal, 3)) return false;
    if (!register_atomics_method(atomics, heap, "and",             Builtin.ATOMICS_AND.ordinal, 3)) return false;
    if (!register_atomics_method(atomics, heap, "compareExchange", Builtin.ATOMICS_COMPAREEXCHANGE.ordinal, 4)) return false;
    if (!register_atomics_method(atomics, heap, "exchange",        Builtin.ATOMICS_EXCHANGE.ordinal, 3)) return false;
    if (!register_atomics_method(atomics, heap, "isLockFree",      Builtin.ATOMICS_ISLOCKFREE.ordinal, 1)) return false;
    if (!register_atomics_method(atomics, heap, "load",            Builtin.ATOMICS_LOAD.ordinal, 2)) return false;
    if (!register_atomics_method(atomics, heap, "or",              Builtin.ATOMICS_OR.ordinal, 3)) return false;
    if (!register_atomics_method(atomics, heap, "store",           Builtin.ATOMICS_STORE.ordinal, 3)) return false;
    if (!register_atomics_method(atomics, heap, "sub",             Builtin.ATOMICS_SUB.ordinal, 3)) return false;
    if (!register_atomics_method(atomics, heap, "xor",             Builtin.ATOMICS_XOR.ordinal, 3)) return false;
    if (!register_atomics_method(atomics, heap, "wait",            Builtin.ATOMICS_WAIT.ordinal, 4)) return false;
    if (!register_atomics_method(atomics, heap, "notify",          Builtin.ATOMICS_NOTIFY.ordinal, 3)) return false;
    if (!register_atomics_method(atomics, heap, "waitAsync",       Builtin.ATOMICS_WAITASYNC.ordinal, 4)) return false;
    if (!register_atomics_method(atomics, heap, "pause",           Builtin.ATOMICS_PAUSE.ordinal, 0)) return false;

    // @@toStringTag
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Atomics"));
        atomics.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    TVal atomics_tv;
    atomics_tv.set_object(atomics);
    return register_named_value(global_env, heap, "Atomics", atomics_tv);
}
