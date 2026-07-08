/// Math built-in object methods.
module tinyduck::builtins;
import tinyduck::types;
import tinyduck::hstring;
import tinyduck::env;

import tinyduck::heap;
import tinyduck::hobject;
import std::io;
import std::math;

// ============================================================================
// Math method builtins
// ============================================================================

/// Helper: get numeric arg at index i, defaulting to NaN if absent.
fn double math_arg(BuiltinContext* ctx, ushort i) {
    if (i >= ctx.argc) return double::nan;
    TVal* arg = &ctx.regs[ctx.base_reg + i];
    if (arg.is_fastint()) return (double)arg.get_fastint();
    if (arg.is_number()) return arg.get_number();
    // Non-numeric — need ToNumber
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
    } else {
        // round half up (away from zero)
        double frac = x - math::floor(x);
        if (frac < 0.5) {
            ctx.result.set_number(math::floor(x));
        } else if (frac > 0.5) {
            ctx.result.set_number(math::ceil(x));
        } else {
            // exactly 0.5 — round away from zero
            ctx.result.set_number(math::floor(x) + 1.0);
        }
    }
}

fn void builtin_math_max(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        ctx.result.set_number(-double::inf);
        return;
    }
    double max = math_arg(ctx, 0);
    for (ushort i = 1; i < ctx.argc; i++) {
        double v = math_arg(ctx, i);
        if (math::is_nan(v)) {
            max = double::nan;
        } else if (v > max || math::is_nan(max)) {
            max = v;
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
    for (ushort i = 1; i < ctx.argc; i++) {
        double v = math_arg(ctx, i);
        if (math::is_nan(v)) {
            min = double::nan;
        } else if (v < min || math::is_nan(min)) {
            min = v;
        }
    }
    ctx.result.set_number(min);
}

fn void builtin_math_pow(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    double y = math_arg(ctx, 1);
    ctx.result.set_number(0.0);
    if (math::is_nan(y) && x != 1.0) {
        ctx.result.set_number(double::nan);
    } else {
        ctx.result.set_number(math_pow(x, y));
    }
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
    double result = 0.0;
    for (ushort i = 0; i < ctx.argc; i++) {
        double v = math_arg(ctx, i);
        if (math::is_nan(v)) { result = double::nan; break; }
        result = result + v * v;
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
    uint val = (uint)x;
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
    int a = (int)(uint)x;
    int b = (int)(uint)y;
    ctx.result.set_fastint((long)(a * b));
}

fn bool register_math_object(EnvRecord* global_env, Heap* heap) {
    HObject*? math_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = math_raw) return false;
    HObject* math = math_raw;
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
    math.put_prop(key, tv);
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
    obj.put_prop(key, tv);
    return true;
}
