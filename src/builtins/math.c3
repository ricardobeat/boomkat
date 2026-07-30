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
    // ES6 §20.2.2.26 Math.pow(x, y):
    // 1. If y is +0 or -0, the result is 1, even if x is NaN
    // 2. If y is NaN, the result is NaN
    // 3. If |x| is 1 and y is ±∞, the result is NaN
    // 4. If x is +1 and y is finite and non-zero, the result is 1
    if (y == 0.0) {
        ctx.result.set_number(1.0);
        return;
    }
    if (math::is_nan(y)) {
        ctx.result.set_number(double::nan);
        return;
    }
    if (math::abs(x) == 1.0 && math::is_inf(y)) {
        ctx.result.set_number(double::nan);
        return;
    }
    if (x == 1.0) {
        ctx.result.set_number(1.0);
        return;
    }
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

/// Math.random(), uses the heap's PRNG state (xorshift32).
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

fn void builtin_math_f16round(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    // fromfp16(tofp16(x)), preserves NaN/Inf/zero (and sign of zero) exactly.
    ctx.result.set_number(f16_to_double(double_to_f16(x)));
}

fn void builtin_math_clz32(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    // Per spec: ToUint32(x), NaN, +0, -0, +Infinity, -Infinity all return +0.
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

// ============================================================================
// Math.sumPrecise - compensated summation using Shewchuk algorithm
// ============================================================================

/// SumPrecise state for accumulating high-precision sums.
/// Uses limb-based representation for infinite precision intermediate result.
enum SumPreciseStateEnum : uint {
    FINITE,
    INFINITY,
    MINUS_INFINITY,
    NAN,
}

const uint SP_LIMB_BITS = 56;
const uint SP_RND_BITS = SP_LIMB_BITS - 53;
const uint SUM_PRECISE_ACC_LEN = 39;
const uint SUM_PRECISE_COUNTER_INIT = 250;

struct SumPreciseState {
    SumPreciseStateEnum state;
    uint counter;
    int n_limbs;
    long[SUM_PRECISE_ACC_LEN] acc;
}

fn void sum_precise_init(SumPreciseState* s) {
    for (uint i = 0; i < SUM_PRECISE_ACC_LEN; i++) {
        s.acc[i] = 0;
    }
    s.state = SumPreciseStateEnum.FINITE;
    s.counter = SUM_PRECISE_COUNTER_INIT;
    s.n_limbs = 0;
}

fn void sum_precise_renorm(SumPreciseState* s) {
    long v, carry;
    int i;

    carry = 0;
    for (i = 0; i < s.n_limbs; i++) {
        v = s.acc[i] + carry;
        s.acc[i] = v & (long)(((1uL << SP_LIMB_BITS) - 1));
        carry = v >> (int)SP_LIMB_BITS;
    }
    if (carry != 0 && s.n_limbs < (int)SUM_PRECISE_ACC_LEN) {
        s.acc[s.n_limbs++] = carry;
    }
}

fn void sum_precise_add(SumPreciseState* s, double d) {
    ulong a, m, a0, a1;
    int sgn, e, p;
    uint shift;

    a = *(ulong*)&d;
    sgn = (int)(a >> 63);
    e = (int)((a >> 52) & ((1uL << 11) - 1));
    m = a & (((1uL << 52) - 1));

    if (e == 2047) {
        if (m == 0) {
            if (s.state == SumPreciseStateEnum.NAN ||
                (s.state == SumPreciseStateEnum.MINUS_INFINITY && !sgn) ||
                (s.state == SumPreciseStateEnum.INFINITY && sgn)) {
                s.state = SumPreciseStateEnum.NAN;
            } else {
                s.state = sgn ? SumPreciseStateEnum.MINUS_INFINITY : SumPreciseStateEnum.INFINITY;
            }
        } else {
            s.state = SumPreciseStateEnum.NAN;
        }
        return;
    }

    if (e == 0) {
        if (m == 0) {
            if (s.n_limbs == 0 && !sgn) {
                s.n_limbs = 1;
            }
        } else {
            p = 0;
            shift = 0;
            a0 = (m << shift) & (((1uL << SP_LIMB_BITS) - 1));
            a1 = m >> (SP_LIMB_BITS - shift);
            if (!sgn) {
                s.acc[p] += (long)a0;
                s.acc[p + 1] += (long)a1;
            } else {
                s.acc[p] -= (long)a0;
                s.acc[p + 1] -= (long)a1;
            }
            if (p + 2 > s.n_limbs) {
                s.n_limbs = p + 2;
            }

            if (--s.counter == 0) {
                s.counter = SUM_PRECISE_COUNTER_INIT;
                sum_precise_renorm(s);
            }
        }
        return;
    }

    m |= (1uL << 52);
    shift = (uint)(e - 1);
    p = (int)(shift / SP_LIMB_BITS);
    shift %= SP_LIMB_BITS;

    a0 = (m << shift) & (((1uL << SP_LIMB_BITS) - 1));
    a1 = m >> ((int)SP_LIMB_BITS - (int)shift);
    if (!sgn) {
        s.acc[p] += (long)a0;
        s.acc[p + 1] += (long)a1;
    } else {
        s.acc[p] -= (long)a0;
        s.acc[p + 1] -= (long)a1;
    }
    if (p + 2 > s.n_limbs) {
        s.n_limbs = p + 2;
    }

    if (--s.counter == 0) {
        s.counter = SUM_PRECISE_COUNTER_INIT;
        sum_precise_renorm(s);
    }
}

fn uint clz64(ulong x) {
    if (x == 0) return 64;
    uint n = 0;
    if (x <= 0x00000000FFFFFFFFUL) { n += 32; x <<= 32; }
    if (x <= 0x0000FFFFFFFFFFFFUL) { n += 16; x <<= 16; }
    if (x <= 0x00FFFFFFFFFFFFFFUL) { n += 8; x <<= 8; }
    if (x <= 0x0FFFFFFFFFFFFFFFUL) { n += 4; x <<= 4; }
    if (x <= 0x3FFFFFFFFFFFFFFFUL) { n += 2; x <<= 2; }
    if (x <= 0x7FFFFFFFFFFFFFFFUL) { n += 1; }
    return n;
}

fn double sum_precise_get_result(SumPreciseState* s) {
    int n, shift, e, p, is_neg;
    ulong m, addend;

    if (s.state != SumPreciseStateEnum.FINITE) {
        switch (s.state) {
            case SumPreciseStateEnum.INFINITY:
                return double::inf;
            case SumPreciseStateEnum.MINUS_INFINITY:
                return -double::inf;
            case SumPreciseStateEnum.NAN:
                return double::nan;
            default:
                return double::inf;
        }
    }

    sum_precise_renorm(s);

    n = s.n_limbs;
    if (n == 0) {
        return -0.0;
    }

    while (n > 0 && s.acc[n - 1] == 0) {
        n--;
    }

    if (n == 0) {
        return 0.0;
    }

    is_neg = (s.acc[n - 1] < 0) ? 1 : 0;
    if (is_neg) {
        ulong v, carry;
        int i;
        carry = 1;
        for (i = 0; i < n - 1; i++) {
            v = (((1uL << SP_LIMB_BITS) - 1) - (ulong)s.acc[i] + carry);
            carry = v >> SP_LIMB_BITS;
            s.acc[i] = (long)(v & (((1uL << SP_LIMB_BITS) - 1)));
        }
        s.acc[n - 1] = (long)(-(ulong)s.acc[n - 1] + carry - 1);
        while (n > 1 && s.acc[n - 1] == 0) {
            n--;
        }
    }

    if (n == 1 && (ulong)s.acc[0] < (1uL << 52)) {
        ulong bits = (((ulong)is_neg << 63) | (ulong)s.acc[0]);
        return *(double*)&&bits;
    }

    e = n * (int)SP_LIMB_BITS;
    p = n - 1;
    m = (ulong)s.acc[p];
    shift = (uint)((int)clz64(m) - (64 - (int)SP_LIMB_BITS));
    e = e - (int)shift - 52;

    if (shift != 0) {
        m <<= shift;
        if (p > 0) {
            uint shift1;
            ulong nz;
            p--;
            shift1 = (uint)SP_LIMB_BITS - (uint)shift;
            nz = (ulong)s.acc[p] & (((1uL << (int)shift1) - 1));
            m = m | ((ulong)s.acc[p] >> (int)shift1) | (nz != 0 ? 1uL : 0);
        }
    }

    if ((m & ((1uL << SP_RND_BITS) - 1)) == (1uL << (SP_RND_BITS - 1))) {
        while (p > 0) {
            p--;
            if (s.acc[p] != 0) {
                m |= 1;
                break;
            }
        }
    }

    addend = (1uL << (SP_RND_BITS - 1)) - 1 + ((m >> SP_RND_BITS) & 1);
    m = (m + addend) >> SP_RND_BITS;

    if (m == (1uL << 53)) {
        e++;
    }

    if (e >= 2047) {
        ulong bits = (((ulong)is_neg << 63) | ((2047uL) << 52));
        return *(double*)&&bits;
    } else {
        m &= (((1uL << 52) - 1));
        ulong bits = (((ulong)is_neg << 63) | ((ulong)e << 52) | m);
        return *(double*)&&bits;
    }
}

fn void sp_throw_type_error(BuiltinContext* ctx, char[] msg) {
    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, msg);
}

fn void sp_iterator_close_after_throw(BuiltinContext* ctx, TVal iterator) {
    if (ctx.heap.call_fn == null || ctx.vm == null) return;
    if (!iterator.is_object() || iterator.get_heapptr() == null) return;
    HObject* iter_obj = (HObject*)iterator.get_heapptr();
    HString* return_key = builtin_intern_string(ctx.heap, "return");
    if (return_key == null) return;
    TVal? return_method_opt = iter_obj.get_prop_proto(return_key);
    if (try return_method = return_method_opt) {
        if (return_method.is_undefined() || return_method.is_null()) return;
        if (!return_method.is_object() || return_method.get_heapptr() == null) return;
        HObject* return_obj = (HObject*)return_method.get_heapptr();
        if (!return_obj.is_callable()) return;
        ctx.heap.call_fn(ctx.vm, return_method, null, 0, iterator);
        ctx.heap.has_error = false;
    }
}

fn void builtin_math_sumPrecise(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        sp_throw_type_error(ctx, "Math.sumPrecise requires an iterable argument");
        ctx.result.set_undefined();
        return;
    }

    if (ctx.vm == null) {
        sp_throw_type_error(ctx, "Math.sumPrecise requires a VM context");
        ctx.result.set_undefined();
        return;
    }

    Vm* vm = (Vm*)ctx.vm;
    Heap* heap = ctx.heap;
    TVal* iterable_val = &ctx.regs[ctx.base_reg];

    SumPreciseState sp_state;
    sum_precise_init(&sp_state);

    // Get Symbol.iterator
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym == null) {
        sp_throw_type_error(ctx, "Symbol.iterator not available");
        ctx.result.set_undefined();
        return;
    }

    // Wrap non-objects for property access (ES2015 ToObject semantics)
    HObject* items_obj = null;
    if (iterable_val.is_object() && iterable_val.get_heapptr() != null) {
        items_obj = (HObject*)iterable_val.get_heapptr();
    }

    if (items_obj == null) {
        sp_throw_type_error(ctx, "Math.sumPrecise argument is not iterable");
        ctx.result.set_undefined();
        return;
    }

    // GetMethod(items, @@iterator)
    TVal? iter_method_opt = builtins_generic_get(items_obj, iter_sym, ctx);
    if (ctx.should_throw) {
        ctx.result.set_undefined();
        return;
    }

    TVal iter_method;
    if (try im = iter_method_opt) {
        if (im.is_undefined() || im.is_null()) {
            sp_throw_type_error(ctx, "Math.sumPrecise argument is not iterable");
            ctx.result.set_undefined();
            return;
        }
        iter_method = im;
    } else {
        sp_throw_type_error(ctx, "Math.sumPrecise argument is not iterable");
        ctx.result.set_undefined();
        return;
    }

    // Call the iterator method to get the iterator object
    TVal iter_obj_val = heap.call_fn(vm, iter_method, null, 0, *iterable_val);
    if (heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = heap.error_value;
        heap.has_error = false;
        ctx.result.set_undefined();
        return;
    }

    if (!iter_obj_val.is_object() || iter_obj_val.get_heapptr() == null) {
        sp_throw_type_error(ctx, "Iterator is not an object");
        ctx.result.set_undefined();
        return;
    }

    HObject* iter_obj = (HObject*)iter_obj_val.get_heapptr();

    // Get the next method
    HString* next_key = builtin_intern_string(heap, "next");
    TVal? next_opt = iter_obj.get_prop_proto(next_key);
    TVal next_fn_val;
    if (try nv = next_opt) {
        if (nv.is_undefined() || nv.is_null()) {
            sp_throw_type_error(ctx, "Iterator next is not a method");
            sp_iterator_close_after_throw(ctx, iter_obj_val);
            ctx.result.set_undefined();
            return;
        }
        next_fn_val = nv;
    } else {
        sp_throw_type_error(ctx, "Iterator next is not a method");
        sp_iterator_close_after_throw(ctx, iter_obj_val);
        ctx.result.set_undefined();
        return;
    }

    // Iterate
    while (true) {
        TVal iter_result = heap.call_fn(vm, next_fn_val, null, 0, iter_obj_val);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            sp_iterator_close_after_throw(ctx, iter_obj_val);
            ctx.result.set_undefined();
            return;
        }

        if (!iter_result.is_object() || iter_result.get_heapptr() == null) {
            sp_throw_type_error(ctx, "Iterator result is not an object");
            sp_iterator_close_after_throw(ctx, iter_obj_val);
            ctx.result.set_undefined();
            return;
        }

        HObject* result_obj = (HObject*)iter_result.get_heapptr();

        // Check done property
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal? done_opt = result_obj.get_prop_proto(done_key);
        bool done = false;
        if (try dv = done_opt) {
            done = builtin_to_boolean(&dv);
        }

        if (done) break;

        // Get value property
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        TVal? value_opt = result_obj.get_prop_proto(value_key);

        double d;
        if (try val = value_opt) {
            if (val.is_fastint()) {
                d = (double)val.get_fastint();
            } else if (val.is_number()) {
                d = val.get_number();
            } else {
                sp_throw_type_error(ctx, "Sum element is not a number");
                sp_iterator_close_after_throw(ctx, iter_obj_val);
                ctx.result.set_undefined();
                return;
            }
        } else {
            sp_throw_type_error(ctx, "Cannot get value from iterator result");
            sp_iterator_close_after_throw(ctx, iter_obj_val);
            ctx.result.set_undefined();
            return;
        }

        sum_precise_add(&sp_state, d);
    }

    double result = sum_precise_get_result(&sp_state);
    ctx.result.set_number(result);
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
    if (!register_math_method(math, heap, "abs",    Builtin.MATH_ABS.ordinal))    return false;
    if (!register_math_method(math, heap, "floor",  Builtin.MATH_FLOOR.ordinal))  return false;
    if (!register_math_method(math, heap, "ceil",   Builtin.MATH_CEIL.ordinal))   return false;
    if (!register_math_method(math, heap, "round",  Builtin.MATH_ROUND.ordinal))  return false;
    if (!register_math_method(math, heap, "max",    Builtin.MATH_MAX.ordinal))    return false;
    if (!register_math_method(math, heap, "min",    Builtin.MATH_MIN.ordinal))    return false;
    if (!register_math_method(math, heap, "pow",    Builtin.MATH_POW.ordinal))    return false;
    if (!register_math_method(math, heap, "sqrt",   Builtin.MATH_SQRT.ordinal))   return false;
    if (!register_math_method(math, heap, "exp",    Builtin.MATH_EXP.ordinal))    return false;
    if (!register_math_method(math, heap, "log",    Builtin.MATH_LOG.ordinal))    return false;
    if (!register_math_method(math, heap, "sin",    Builtin.MATH_SIN.ordinal))    return false;
    if (!register_math_method(math, heap, "cos",    Builtin.MATH_COS.ordinal))    return false;
    if (!register_math_method(math, heap, "tan",    Builtin.MATH_TAN.ordinal))    return false;
    if (!register_math_method(math, heap, "random", Builtin.MATH_RANDOM.ordinal)) return false;
    if (!register_math_method(math, heap, "acos",   Builtin.MATH_ACOS.ordinal))   return false;
    if (!register_math_method(math, heap, "asin",   Builtin.MATH_ASIN.ordinal))   return false;
    if (!register_math_method(math, heap, "atan",   Builtin.MATH_ATAN.ordinal))   return false;
    if (!register_math_method(math, heap, "atan2",  Builtin.MATH_ATAN2.ordinal))  return false;
    if (!register_math_method(math, heap, "cosh",   Builtin.MATH_COSH.ordinal))   return false;
    if (!register_math_method(math, heap, "sinh",   Builtin.MATH_SINH.ordinal))   return false;
    if (!register_math_method(math, heap, "tanh",   Builtin.MATH_TANH.ordinal))   return false;
    if (!register_math_method(math, heap, "acosh",  Builtin.MATH_ACOSH.ordinal))  return false;
    if (!register_math_method(math, heap, "asinh",  Builtin.MATH_ASINH.ordinal))  return false;
    if (!register_math_method(math, heap, "atanh",  Builtin.MATH_ATANH.ordinal))  return false;
    if (!register_math_method(math, heap, "log2",   Builtin.MATH_LOG2.ordinal))   return false;
    if (!register_math_method(math, heap, "log10",  Builtin.MATH_LOG10.ordinal))  return false;
    if (!register_math_method(math, heap, "log1p",  Builtin.MATH_LOG1P.ordinal))  return false;
    if (!register_math_method(math, heap, "expm1",  Builtin.MATH_EXPM1.ordinal))  return false;
    if (!register_math_method(math, heap, "cbrt",   Builtin.MATH_CBRT.ordinal))   return false;
    if (!register_math_method(math, heap, "hypot",  Builtin.MATH_HYPOT.ordinal))  return false;
    if (!register_math_method(math, heap, "trunc",  Builtin.MATH_TRUNC.ordinal))  return false;
    if (!register_math_method(math, heap, "sign",   Builtin.MATH_SIGN.ordinal))   return false;
    if (!register_math_method(math, heap, "fround", Builtin.MATH_FROUND.ordinal)) return false;
    if (!register_math_method(math, heap, "f16round", Builtin.MATH_F16ROUND.ordinal)) return false;
    if (!register_math_method(math, heap, "clz32",  Builtin.MATH_CLZ32.ordinal))  return false;
    if (!register_math_method(math, heap, "imul",   Builtin.MATH_IMUL.ordinal))   return false;
    if (!register_math_method(math, heap, "sumPrecise", Builtin.MATH_SUMPRECISE.ordinal)) return false;

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
    HString* key = heap.str_intern(name);
    if (key == null) return false;
    TVal tv;
    tv.set_lightfunc((void*)(usz)fn_index);
    math.put_prop(key, tv, hobject::PROP_FLAGS_WC);
    return true;
}

fn bool set_num_prop_lookup(HObject* obj, Heap* heap, char[] name, double val) {
    HString* key = heap.str_intern(name);
    if (key == null) return false;
    TVal tv;
    tv.set_number(val);
    obj.put_prop(key, tv, hobject::PROP_FLAGS_NNC);
    return true;
}
