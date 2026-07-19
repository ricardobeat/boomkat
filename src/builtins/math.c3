/// Math built-in object methods.
module duktape::builtins;
import duktape::types;
import duktape::hstring;
import duktape::env;

import duktape::heap;
import duktape::hobject;
import duktape::vm;
import std::io;
import std::math;

// ============================================================================
// Math method builtins
// ============================================================================

/// Helper: get numeric arg at index i, defaulting to NaN if absent.
/// Uses vm_to_number for objects so that valueOf / toString are called
/// per the spec (and any exception they throw propagates through the VM).
/// Returns NaN and sets ctx.should_throw / throw_value on ToNumber failure.
fn double math_arg(BuiltinContext* ctx, ushort i) {
    if (i >= ctx.argc) return double::nan;
    TVal* arg = &ctx.regs[ctx.base_reg + i];
    if (arg.is_fastint()) return (double)arg.get_fastint();
    if (arg.is_number()) return arg.get_number();
    if (arg.is_object() && ctx.vm != null) {
        Vm* v = (Vm*)ctx.vm;
        double d = vm::vm_to_number(v, arg);
        if (v.throw_pending) {
            ctx.should_throw = true;
            ctx.throw_value = v.throw_value;
            v.throw_pending = false;
            return double::nan;
        }
        return d;
    }
    // Non-object non-number: undefined / null / boolean / string / symbol.
    TVal num;
    builtin_to_number(arg, &num);
    return num.is_fastint() ? (double)num.get_fastint() : num.get_number();
}

fn void builtin_math_abs(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math::abs(x));
}

fn void builtin_math_floor(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math::floor(x));
}

fn void builtin_math_ceil(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math::ceil(x));
}

fn void builtin_math_round(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(0.0);
    // ES5 §15.8.2.15: round half away from zero
    if (math::is_nan(x)) {
        ctx.result.set_number(double::nan);
    } else if (math::is_inf(x) || x == 0.0) {
        ctx.result.set_number(x);
    } else if (x > 0.0 && x < 0.5) {
        // Per ES2018+ §20.2.2.34: Math.round(x) for 0 < x < 0.5 returns +0
        ctx.result.set_number(0.0);
    } else if (x < 0.0 && x >= -0.5) {
        // Per ES2018+ §20.2.2.34: Math.round(x) for -0.5 ≤ x ≤ -0 returns -0
        ctx.result.set_number(-0.0);
    } else {
        // Round half away from zero
        double frac = x - math::floor(x);
        if (frac < 0.5) {
            ctx.result.set_number(math::floor(x));
        } else {
            ctx.result.set_number(math::ceil(x));
        }
    }
}

fn void builtin_math_max(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        ctx.result.set_number(-double::inf);
        return;
    }
    double max = math_arg(ctx, 0);
    // ES6 §20.2.2.24: if any argument is NaN, the result is NaN
    for (ushort i = 1; i < ctx.argc; i++) {
        double v = math_arg(ctx, i);
        if (math::is_nan(v)) {
            max = double::nan;
            continue;
        }
        // Abstract Relational Comparison: +0 > -0, NaN treated as missing
        if (max != v) {
            if (v > max) {
                max = v;
            }
        } else {
            // max == v. Handle +0 vs -0: -0 < +0 per spec.
            // If v is +0 and max is -0, v wins.
            if (v == 0.0 && max == 0.0 && !math::signbit(v) && math::signbit(max)) {
                max = v;
            }
        }
    }
    ctx.result.set_number(max);
}

fn void builtin_math_min(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        ctx.result.set_number(double::inf);
        return;
    }
    double min = math_arg(ctx, 0);
    // ES6 §20.2.2.25: if any argument is NaN, the result is NaN
    for (ushort i = 1; i < ctx.argc; i++) {
        double v = math_arg(ctx, i);
        if (math::is_nan(v)) {
            min = double::nan;
            continue;
        }
        // Abstract Relational Comparison: +0 > -0, NaN treated as missing
        if (min != v) {
            if (v < min) {
                min = v;
            }
        } else {
            // min == v. Handle +0 vs -0: -0 < +0 per spec.
            // If v is -0 and min is +0, v wins.
            if (v == 0.0 && min == 0.0 && math::signbit(v) && !math::signbit(min)) {
                min = v;
            }
        }
    }
    ctx.result.set_number(min);
}

fn void builtin_math_pow(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    double y = math_arg(ctx, 1);
    ctx.result.set_number(0.0);
    // Number::exponentiate(base, exponent) — ES2024 §13.6.4
    // 1. If exponent is NaN, return NaN.
    // 2. If exponent is +0𝔽 or -0𝔽, return 1𝔽.
    // 3. If base is NaN, return NaN.
    // 4. If base is +∞𝔽, then [sign of ∞ determines result]
    // 5. If base is -∞𝔽, then [...]
    // 6. If base is +0𝔽 or -0𝔽, then [...]
    // 7. If base is 1𝔽, return 1𝔽.
    // 8. If exponent is +∞𝔽, return NaN.
    // 9. If exponent is -∞𝔽, return NaN.
    if (math::is_nan(y)) { return ctx.result.set_number(double::nan); }
    if (y == 0.0) { return ctx.result.set_number(1.0); }
    if (math::is_nan(x)) { return ctx.result.set_number(double::nan); }
    if (math::abs(x) == 1.0 && math::is_inf(y)) { return ctx.result.set_number(double::nan); }
    if (x == 1.0) { return ctx.result.set_number(1.0); }
    if (x == -1.0 && math::is_inf(y)) { return ctx.result.set_number(double::nan); }
    ctx.result.set_number(math_pow(x, y));
}

fn void builtin_math_sqrt(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_sqrt(x));
}

fn void builtin_math_exp(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_exp(x));
}

fn void builtin_math_log(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_log(x));
}

fn void builtin_math_sin(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_sin(x));
}

fn void builtin_math_cos(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_cos(x));
}

fn void builtin_math_tan(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_tan(x));
}

/// Math.random() — uses the heap's PRNG state (xorshift32).
fn void builtin_math_random(BuiltinContext* ctx) {
    uint state = ctx.heap.rnd_state;
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    ctx.heap.rnd_state = state;
    ctx.result.set_number((double)state / 4294967296.0);
}

fn void builtin_math_acos(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_acos(x));
}

fn void builtin_math_asin(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_asin(x));
}

fn void builtin_math_atan(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_atan(x));
}

fn void builtin_math_atan2(BuiltinContext* ctx) {
    double y = math_arg(ctx, 0);
    double x = math_arg(ctx, 1);
    ctx.result.set_number(math_atan2(y, x));
}

fn void builtin_math_cosh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_cosh(x));
}

fn void builtin_math_sinh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_sinh(x));
}

fn void builtin_math_tanh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_tanh(x));
}

fn void builtin_math_acosh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_acosh(x));
}

fn void builtin_math_asinh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_asinh(x));
}

fn void builtin_math_atanh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_atanh(x));
}

fn void builtin_math_log2(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_log2(x));
}

fn void builtin_math_log10(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_log10(x));
}

fn void builtin_math_log1p(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_log1p(x));
}

fn void builtin_math_expm1(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_expm1(x));
}

fn void builtin_math_cbrt(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(math_cbrt(x));
}

fn void builtin_math_hypot(BuiltinContext* ctx) {
    // ES6 §20.2.2.18 Math.hypot(...):
    // - Coerce all args to Number FIRST (in argument order)
    // - If any coercion throws, propagate the throw immediately
    // - After successful coercion: if any arg was +∞ or -∞, return +∞
    // - If any arg was NaN (and no arg was ±∞), return NaN
    // - Otherwise return sqrt(sum of squares)
    if (ctx.argc == 0) {
        ctx.result.set_number(0.0);
        return;
    }
    bool saw_infinity = false;
    bool saw_nan = false;
    double result = 0.0;
    for (ushort i = 0; i < ctx.argc; i++) {
        // Coerce first; if it throws, bail out (do not process later args).
        double v;
        if (ctx.vm != null) {
            Vm* v_ptr = (Vm*)ctx.vm;
            v = vm::vm_to_number(v_ptr, &ctx.regs[ctx.base_reg + i]);
            if (v_ptr.throw_pending) {
                ctx.should_throw = true;
                ctx.throw_value = v_ptr.throw_value;
                v_ptr.throw_pending = false;
                ctx.result.set_number(double::nan);
                return;
            }
        } else {
            v = math_arg(ctx, i);
        }
        if (math::is_inf(v)) { saw_infinity = true; continue; }
        if (math::is_nan(v)) { saw_nan = true; continue; }
        result = result + v * v;
    }
    if (saw_infinity) {
        ctx.result.set_number(double::inf);
        return;
    }
    if (saw_nan) {
        ctx.result.set_number(double::nan);
        return;
    }
    ctx.result.set_number(math_sqrt(result));
}

fn void builtin_math_trunc(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(0.0);
    if (x >= 0) {
        ctx.result.set_number(math::floor(x));
    } else {
        ctx.result.set_number(math::ceil(x));
    }
}

fn void builtin_math_sign(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(0.0);
    if (math::is_nan(x) || x == 0.0) {
        ctx.result.set_number(x);
    } else if (x > 0.0) {
        ctx.result.set_number(1.0);
    } else {
        ctx.result.set_number(-1.0);
    }
}

fn void builtin_math_fround(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.set_number(0.0);
    if (math::is_nan(x) || math::is_inf(x) || x == 0.0) {
        ctx.result.set_number(x);
    } else {
        // Round to nearest float32
        float f = (float)x;
        ctx.result.set_number((double)f);
    }
}

fn void builtin_math_clz32(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    // Per spec: ToUint32(x) — NaN, +0, -0, +Infinity, -Infinity all return +0.
    uint val;
    if (math::is_nan(x) || math::is_inf(x) || x == 0.0) {
        val = 0;
    } else {
        // Truncate toward zero, then interpret as uint32.
        val = (uint)(long)x;
    }
    if (val == 0) {
        ctx.result.set_fastint(32);
    } else {
        uint count = 0;
        while ((val & 0x80000000) == 0) {
            count++;
            val <<= 1;
        }
        ctx.result.set_fastint((long)count);
    }
}

fn void builtin_math_imul(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    double y = math_arg(ctx, 1);
    // Math.imul: ToUint32(x) * ToUint32(y) mod 2^32, then sign-fix to int32.
    // Truncate toward zero (C3 `(long)` cast) so fractional inputs become 0.
    long a_long = (long)x;
    long b_long = (long)y;
    uint a = (uint)a_long;
    uint b = (uint)b_long;
    // Use 64-bit multiply to avoid signed-overflow UB; then take low 32 bits.
    ulong product = (ulong)a * (ulong)b;
    uint low = (uint)(product & 0xFFFFFFFFul);
    // Reinterpret as signed int32.
    int result = (int)low;
    ctx.result.set_fastint((long)result);
}

fn bool register_math_object(EnvRecord* global_env, Heap* heap) {
    HObject*? math_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = math_raw) return false;
    HObject* math = math_raw;
    math.prototype = heap.object_proto;
    if (!set_num_prop_lookup(math, heap, "E", 2.718281828459045)) return false;
    if (!set_num_prop_lookup(math, heap, "PI", 3.141592653589793)) return false;
    if (!set_num_prop_lookup(math, heap, "LN2", 0.6931471805599453)) return false;
    if (!set_num_prop_lookup(math, heap, "LN10", 2.302585092994046)) return false;
    if (!set_num_prop_lookup(math, heap, "LOG2E", 1.4426950408889634)) return false;
    if (!set_num_prop_lookup(math, heap, "LOG10E", 0.4342944819032518)) return false;
    if (!set_num_prop_lookup(math, heap, "SQRT1_2", 0.7071067811865476)) return false;
    if (!set_num_prop_lookup(math, heap, "SQRT2", 1.4142135623730951)) return false;

    // Math methods (registered as lightfuncs on the Math object)
    if (!register_math_method(math, heap, "abs",    BUILTIN_MATH_ABS))    return false;
    if (!register_math_method(math, heap, "floor",  BUILTIN_MATH_FLOOR))  return false;
    if (!register_math_method(math, heap, "ceil",   BUILTIN_MATH_CEIL))   return false;
    if (!register_math_method(math, heap, "round",  BUILTIN_MATH_ROUND))  return false;
    if (!register_math_method(math, heap, "max",    BUILTIN_MATH_MAX))    return false;
    if (!register_math_method(math, heap, "min",    BUILTIN_MATH_MIN))    return false;
    if (!register_math_method(math, heap, "pow",    BUILTIN_MATH_POW))    return false;
    if (!register_math_method(math, heap, "sqrt",   BUILTIN_MATH_SQRT))   return false;
    if (!register_math_method(math, heap, "exp",    BUILTIN_MATH_EXP))    return false;
    if (!register_math_method(math, heap, "log",    BUILTIN_MATH_LOG))    return false;
    if (!register_math_method(math, heap, "sin",    BUILTIN_MATH_SIN))    return false;
    if (!register_math_method(math, heap, "cos",    BUILTIN_MATH_COS))    return false;
    if (!register_math_method(math, heap, "tan",    BUILTIN_MATH_TAN))    return false;
    if (!register_math_method(math, heap, "random", BUILTIN_MATH_RANDOM)) return false;
    if (!register_math_method(math, heap, "acos",   BUILTIN_MATH_ACOS))   return false;
    if (!register_math_method(math, heap, "asin",   BUILTIN_MATH_ASIN))   return false;
    if (!register_math_method(math, heap, "atan",   BUILTIN_MATH_ATAN))   return false;
    if (!register_math_method(math, heap, "atan2",  BUILTIN_MATH_ATAN2))  return false;
    if (!register_math_method(math, heap, "cosh",   BUILTIN_MATH_COSH))   return false;
    if (!register_math_method(math, heap, "sinh",   BUILTIN_MATH_SINH))   return false;
    if (!register_math_method(math, heap, "tanh",   BUILTIN_MATH_TANH))   return false;
    if (!register_math_method(math, heap, "acosh",  BUILTIN_MATH_ACOSH))  return false;
    if (!register_math_method(math, heap, "asinh",  BUILTIN_MATH_ASINH))  return false;
    if (!register_math_method(math, heap, "atanh",  BUILTIN_MATH_ATANH))  return false;
    if (!register_math_method(math, heap, "log2",   BUILTIN_MATH_LOG2))   return false;
    if (!register_math_method(math, heap, "log10",  BUILTIN_MATH_LOG10))  return false;
    if (!register_math_method(math, heap, "log1p",  BUILTIN_MATH_LOG1P))  return false;
    if (!register_math_method(math, heap, "expm1",  BUILTIN_MATH_EXPM1))  return false;
    if (!register_math_method(math, heap, "cbrt",   BUILTIN_MATH_CBRT))   return false;
    if (!register_math_method(math, heap, "hypot",  BUILTIN_MATH_HYPOT))  return false;
    if (!register_math_method(math, heap, "trunc",  BUILTIN_MATH_TRUNC))  return false;
    if (!register_math_method(math, heap, "sign",   BUILTIN_MATH_SIGN))   return false;
    if (!register_math_method(math, heap, "fround", BUILTIN_MATH_FROUND)) return false;
    if (!register_math_method(math, heap, "clz32",  BUILTIN_MATH_CLZ32))  return false;
    if (!register_math_method(math, heap, "imul",   BUILTIN_MATH_IMUL))   return false;

    // Set @@toStringTag on Math
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Math"));
        math.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    TVal math_tv;
    math_tv.set_object(null);
    math_tv.set_fastint(0);
    math_tv.set_object(math);
    return register_named_value(global_env, heap, "Math", math_tv);
}

/// Helper: register a Math method as a lightfunc property on the Math object.
fn bool register_math_method(HObject* math, Heap* heap, char[] name, uint fn_index) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    void* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal tv;
    tv.set_lightfunc((void*)(usz)fn_index);
    math.put_prop(key, tv, hobject::PROP_FLAGS_WC);
    return true;
}

fn bool set_num_prop_lookup(HObject* obj, Heap* heap, char[] name, double val) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    void* key = existing;
    if (key == null) {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal tv;
    tv.set_number(val);
    obj.put_prop(key, tv, hobject::PROP_FLAGS_NNC);
    return true;
}
