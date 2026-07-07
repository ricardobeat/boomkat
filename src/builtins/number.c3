/// Number constructor and Number.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::env;
import std::math;
import libc;
import duktape::hstring;

import duktape::heap;
import duktape::hobject;
import duktape::dtoa_bindings;
import std::io;

// ============================================================================
// Number constructor builtins
// ============================================================================

/// Helper: extract the double value from 'this' for Number.prototype methods.
/// Returns NaN on incompatible 'this' (caller checks via isnan).
fn double number_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.NUMBER &&
            ((*obj.extra_ptr()).prim.primitive_value.is_number() || (*obj.extra_ptr()).prim.primitive_value.is_fastint())) {
            return (*obj.extra_ptr()).prim.primitive_value.get_number_or_fastint();
        }
    } else if (this_val.is_number()) {
        return this_val.get_number();
    } else if (this_val.is_fastint()) {
        return (double)this_val.get_fastint();
    }
    return double::nan;
}

/// Helper: check if a double is -0.
fn bool is_neg_zero(double d) {
    return d == 0.0 && math::signbit(d);
}

/// Helper: convert a positive integer to a string in the given radix (2-36).
/// Writes at most 64 chars into buf. Returns the number of chars written.
fn int number_to_radix_str(ulong val, uint radix, char* buf, usz buf_size) {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    char[64] tmp;
    int pos = 0;
    while (val > 0 && pos < 64) {
        uint digit = (uint)(val % (ulong)radix);
        val /= (ulong)radix;
        if (digit < 10) {
            tmp[pos++] = (char)('0' + digit);
        } else {
            tmp[pos++] = (char)('a' + digit - 10);
        }
    }
    // Reverse into buf
    int write_pos = 0;
    while (pos > 0 && write_pos < (int)buf_size - 1) {
        pos--;
        buf[write_pos++] = tmp[pos];
    }
    buf[write_pos] = 0;
    return write_pos;
}

/// ToNumber then return number primitive (function call) or
/// a Number wrapper object (constructor call).
fn void builtin_number(BuiltinContext* ctx) {
    TVal num;
    if (ctx.argc > 0) {
        builtin_to_number(&ctx.regs[ctx.base_reg], &num);
    } else {
        num.set_fastint(0);
    }

    if (ctx.is_constructor) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.NUMBER);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.number_proto;
        (*obj.extra_ptr()).prim.primitive_value = num;
        ctx.result.set_object(obj);
    } else {
        if (num.is_fastint()) {
            ctx.result.set_fastint(num.get_fastint());
        } else {
            ctx.result.set_number(num.get_number());
        }
    }
}

/// Number.prototype.toString(radix) — ES5 §15.7.4.2
/// Returns string representation in the given radix (2-36), default 10.
fn void builtin_number_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double d;

    // ES5 §15.7.4.2: throw TypeError if this is not a Number or Number object
    if (this_val.is_number()) {
        d = this_val.get_number();
    } else if (this_val.is_fastint()) {
        d = (double)this_val.get_fastint();
    } else if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.NUMBER &&
            ((*obj.extra_ptr()).prim.primitive_value.is_number() || (*obj.extra_ptr()).prim.primitive_value.is_fastint())) {
            d = (*obj.extra_ptr()).prim.primitive_value.get_number_or_fastint();
        } else {
            // Not a Number wrapper — throw TypeError
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Number.prototype.toString called on incompatible value");
            return;
        }
    } else {
        // Not a number or Number wrapper — throw TypeError
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Number.prototype.toString called on incompatible value");
        return;
    }

    // Determine radix
    int radix = 10;
    if (ctx.argc > 0) {
        TVal* rad_arg = &ctx.regs[ctx.base_reg];
        if (rad_arg.is_fastint()) {
            radix = (int)rad_arg.get_fastint();
        } else if (rad_arg.is_number()) {
            radix = (int)(long)rad_arg.get_number();
        } else {
            radix = 10;
        }
        if (radix < 2 || radix > 36) {
            // RangeError per ES5 §15.7.4.2
            builtin_throw(ctx, ctx.heap.range_err_proto, "radix must be an integer between 2 and 36");
            return;
        }
    }

    // Handle special values
    if (math::is_nan(d) && !is_neg_zero(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.set_string(s);
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.set_string(s);
        return;
    }
    if (d == 0.0) {
        HString* s = builtin_intern_string(ctx.heap, "0");
        ctx.result.set_string(s);
        return;
    }

    // Radix 10: use existing ToString formatting
    if (radix == 10) {
        char[64] buf;
        int len = libc::snprintf(&buf, 64, "%.17g", d);
        if (len < 0 || len >= 64) {
            ctx.result.set_undefined();
            return;
        }
        // Trim trailing zeros in decimal notation (before any 'e')
        ulong val_bits = bitcast(d, ulong);
        bool has_exp = false;
        for (int i = 0; i < len; i++) {
            if (buf[i] == 'e' || buf[i] == 'E') { has_exp = true; break; }
        }
        if (!has_exp) {
            while (len > 1 && buf[len - 1] == '0' && buf[len - 2] != '.') len--;
            if (len > 1 && buf[len - 1] == '.') len--;
            // Progressively trim trailing digits while round-trip holds
            buf[len] = 0;
            while (len > 0) {
                char last = buf[len - 1];
                if (last == '.' || last == '-') break;
                buf[len - 1] = 0;
                double parsed = libc::strtod(&buf, null);
                if (bitcast(parsed, ulong) == val_bits) {
                    len--;
                } else {
                    buf[len - 1] = last;
                    break;
                }
            }
        }
        HString* s = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.set_string(s);
        return;
    }

    // Radix 2-36: manual conversion
    bool negative = d < 0;
    if (negative) d = -d;

    // Split into integer and fractional parts
    double int_part = math::trunc(d);
    double frac_part = d - int_part;

    char[128] buf;
    usz offset = 0;

    if (negative) {
        buf[offset++] = '-';
    }

    // Convert integer part
    ulong int_val = (ulong)(long)int_part;
    char[64] int_digits;
    int int_len = number_to_radix_str(int_val, (uint)radix, &int_digits, 64);
    for (int i = 0; i < int_len; i++) {
        buf[offset++] = int_digits[i];
    }

    // Convert fractional part (up to 20 digits)
    if (frac_part > 0.0 && offset < 120) {
        buf[offset++] = '.';
        int max_frac_digits = 20;
        if ((int)offset + max_frac_digits > 127) max_frac_digits = 127 - (int)offset;
        for (int i = 0; i < max_frac_digits; i++) {
            frac_part *= (double)radix;
            uint digit = (uint)(long)frac_part;
            if (digit >= (uint)radix) digit = (uint)radix - 1;
            frac_part -= (double)digit;
            if (digit < 10) {
                buf[offset++] = (char)('0' + digit);
            } else {
                buf[offset++] = (char)('a' + digit - 10);
            }
            if (frac_part <= 0.0) break;
        }
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    if (result == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(result);
}

/// Number.prototype.toFixed(fractionDigits) — ES5 §15.7.4.5
fn void builtin_number_proto_toFixed(BuiltinContext* ctx) {
    double d = number_proto_get_this(ctx);

    // Normalize -0 to +0
    if (d == 0.0) d = 0.0;

    if (math::is_nan(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.set_string(s);
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.set_string(s);
        return;
    }

    int f = 0;
    if (ctx.argc > 0) {
        double f_d = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (f_d < 0 || f_d > 20) {
            // ES5 §15.7.4.5: throw RangeError
            builtin_throw(ctx, ctx.heap.range_err_proto, "fractionDigits out of range");
            return;
        }
        f = (int)(long)f_d;
    }

    int flags = dtoa_bindings::JS_DTOA_FORMAT_FRAC;
    if (math::abs(d) >= 1e21) flags = dtoa_bindings::JS_DTOA_FORMAT_FREE;
    char[256] buf;
    char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] tmp;
    int len = dtoa_bindings::duktape_js_dtoa(&buf, d, 10, f, flags, &tmp);
    if (len < 0 || len >= 256) {
        ctx.result.set_undefined();
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(s);
}

/// Number.prototype.toExponential(fractionDigits) — ES5 §15.7.4.6
fn void builtin_number_proto_toExponential(BuiltinContext* ctx) {
    double d = number_proto_get_this(ctx);

    // Normalize -0 to +0
    if (d == 0.0) d = 0.0;

    if (math::is_nan(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.set_string(s);
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.set_string(s);
        return;
    }

    int f = 0;
    if (ctx.argc > 0) {
        double f_d = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (f_d < 0 || f_d > 20) {
            // ES5 §15.7.4.6: throw RangeError
            builtin_throw(ctx, ctx.heap.range_err_proto, "fractionDigits out of range");
            return;
        }
        f = (int)(long)f_d;
    }

    int flags = dtoa_bindings::JS_DTOA_FORMAT_FIXED | dtoa_bindings::JS_DTOA_EXP_ENABLED;
    int n_digits = f + 1;
    if (ctx.argc == 0) {
        flags = dtoa_bindings::JS_DTOA_FORMAT_FREE | dtoa_bindings::JS_DTOA_EXP_ENABLED;
        n_digits = 0;
    }
    char[256] buf;
    char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] tmp;
    int len = dtoa_bindings::duktape_js_dtoa(&buf, d, 10, n_digits, flags, &tmp);
    if (len < 0 || len >= 256) {
        ctx.result.set_undefined();
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(s);
}

/// Number.prototype.toPrecision(precision) — ES5 §15.7.4.7
fn void builtin_number_proto_toPrecision(BuiltinContext* ctx) {
    double d = number_proto_get_this(ctx);

    // Normalize -0 to +0
    if (d == 0.0) d = 0.0;

    if (math::is_nan(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.set_string(s);
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.set_string(s);
        return;
    }

    if (ctx.argc == 0) {
        // No arg: return ToString(x)
        char[64] buf;
        int len = libc::snprintf(&buf, 64, "%.17g", d);
        if (len < 0 || len >= 64) {
            ctx.result.set_undefined();
            return;
        }
        HString* s = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.set_string(s);
        return;
    }

    double p_d = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (p_d < 1 || p_d > 21) {
        // ES5 §15.7.4.7: throw RangeError
        builtin_throw(ctx, ctx.heap.range_err_proto, "precision out of range");
        return;
    }
    int p = (int)(long)p_d;

    char[256] buf;
    char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] tmp;
    int flags = dtoa_bindings::JS_DTOA_FORMAT_FIXED;
    int len = dtoa_bindings::duktape_js_dtoa(&buf, d, 10, p, flags, &tmp);
    if (len < 0 || len >= 256) {
        ctx.result.set_undefined();
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.set_string(s);
}

/// Number.prototype.data.valueOf — returns the wrapped number primitive
fn void builtin_number_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.NUMBER &&
            ((*obj.extra_ptr()).prim.primitive_value.is_number() || (*obj.extra_ptr()).prim.primitive_value.is_fastint())) {
            if ((*obj.extra_ptr()).prim.primitive_value.is_fastint()) {
                ctx.result.set_fastint((*obj.extra_ptr()).prim.primitive_value.get_fastint());
            } else {
                ctx.result.set_number((*obj.extra_ptr()).prim.primitive_value.get_number());
            }
            return;
        }
    } else if (this_val.is_number()) {
        ctx.result.set_number(this_val.get_number());
        return;
    } else if (this_val.is_fastint()) {
        ctx.result.set_fastint(this_val.get_fastint());
        return;
    }
    ctx.result.set_undefined();
}

// ============================================================================
// Number static methods (ES6 §20.1.2)
// ============================================================================

/// Number.isNaN(number) — ES6 §20.1.2.4
/// Returns true only if the argument is the NaN number value (no coercion).
fn void builtin_number_isNaN(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (!ctx.regs[ctx.base_reg].is_number() && !ctx.regs[ctx.base_reg].is_fastint())) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    ctx.result.set_boolean(false);
    if (arg.is_number()) {
        ctx.result.set_boolean(math::is_nan(arg.get_number()));
    } else {
        // FASTINT is never NaN
        ctx.result.set_boolean(false);
    }
}

/// Number.isFinite(number) — ES6 §20.1.2.2
/// Returns true only if the argument is a finite number value (no coercion).
fn void builtin_number_isFinite(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (!ctx.regs[ctx.base_reg].is_number() && !ctx.regs[ctx.base_reg].is_fastint())) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    ctx.result.set_boolean(false);
    if (arg.is_number()) {
        ctx.result.set_boolean(!math::is_nan(arg.get_number()) && !math::is_inf(arg.get_number()));
    } else {
        // FASTINT is always finite
        ctx.result.set_boolean(true);
    }
}

/// Number.isInteger(number) — ES6 §20.1.2.3
/// Returns true only if the argument is an integer number value (no coercion).
fn void builtin_number_isInteger(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (!ctx.regs[ctx.base_reg].is_number() && !ctx.regs[ctx.base_reg].is_fastint())) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    double d;
    if (arg.is_fastint()) {
        // FASTINT is always an integer
        ctx.result.set_boolean(true);
        return;
    }
    d = arg.get_number();
    // NaN, Infinity, -Infinity are not integers
    if (math::is_nan(d) || math::is_inf(d)) {
        ctx.result.set_boolean(false);
        return;
    }
    // Check: floor(abs(d)) == abs(d) — i.e. no fractional part
    double abs_d = d < 0 ? -d : d;
    double fl = math::floor(abs_d);
    ctx.result.set_boolean((fl == abs_d));
}

/// Number.isSafeInteger(number) — ES6 §20.1.2.5
/// Returns true only if the argument is a safe integer (±(2^53 - 1)).
fn void builtin_number_isSafeInteger(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (!ctx.regs[ctx.base_reg].is_number() && !ctx.regs[ctx.base_reg].is_fastint())) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    if (arg.is_fastint()) {
        // FASTINT values are always safe integers
        ctx.result.set_boolean(true);
        return;
    }
    double d = arg.get_number();
    if (math::is_nan(d) || math::is_inf(d)) {
        ctx.result.set_boolean(false);
        return;
    }
    double abs_d = d < 0 ? -d : d;
    double fl = math::floor(abs_d);
    // Must be integer AND within safe range (2^53 - 1 = 9007199254740991)
    ctx.result.set_boolean((fl == abs_d) && (abs_d <= (double)types::DUK_MAX_SAFE_INT));
}
fn bool register_number_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Number prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.NUMBER);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.number_proto = proto;

    // Add .toString() method
    HString* tostring_key = (HString*)heap.strs[heap::BuiltinStr.TO_STRING];
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_NUMBER_PROTO_TOSTRING);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .valueOf() method
    HString* valueof_key = (HString*)heap.strs[heap::BuiltinStr.VALUE_OF];
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)BUILTIN_NUMBER_PROTO_VALUEOF);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC);

    // Add .toFixed() method (Phase 6d)
    if (!register_string_proto_method(proto, heap, "toFixed", BUILTIN_NUMBER_PROTO_TOFIXED)) return false;
    // Add .toExponential() method
    if (!register_string_proto_method(proto, heap, "toExponential", BUILTIN_NUMBER_PROTO_TOEXPONENTIAL)) return false;
    // Add .toPrecision() method
    if (!register_string_proto_method(proto, heap, "toPrecision", BUILTIN_NUMBER_PROTO_TOPRECISION)) return false;

    // Number.prototype.toLocaleString — ES5 §15.7.4.5
    // Delegates to Number.prototype.toString (handles number primitives correctly).
    if (!register_string_proto_method(proto, heap, "toLocaleString", BUILTIN_NUMBER_PROTO_TOSTRING)) return false;

    // Create Number constructor as a proper function object (not LIGHTFUNC)
    // so it can carry static properties like Number.MAX_VALUE, Number.NaN, etc.
    HObject*? num_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = num_raw) return false;
    HObject* num = num_raw;
    (*num.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_NUMBER;

    // Set .constructor on Number.prototype to point to the actual Number object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(num);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Number.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    num.put_prop(prototype_key, proto_tv, proto_pflags);

    // Add Number.MAX_VALUE (ES5 §15.7.3.2) — non-writable, non-enumerable, non-configurable
    if (!set_num_static_prop(num, heap, "MAX_VALUE", 1.7976931348623157e+308)) return false;
    // Add Number.MIN_VALUE (ES5 §15.7.3.3)
    if (!set_num_static_prop(num, heap, "MIN_VALUE", 5e-324)) return false;
    // Add Number.NaN (ES5 §15.7.3.4)
    if (!set_num_static_prop(num, heap, "NaN", double::nan)) return false;
    // Add Number.NEGATIVE_INFINITY (ES5 §15.7.3.5)
    if (!set_num_static_prop(num, heap, "NEGATIVE_INFINITY", -double::inf)) return false;
    // Add Number.POSITIVE_INFINITY (ES5 §15.7.3.6)
    if (!set_num_static_prop(num, heap, "POSITIVE_INFINITY", double::inf)) return false;

    // Add Number.isNaN (ES6 §20.1.2.4)
    if (!register_string_proto_method(num, heap, "isNaN", BUILTIN_NUMBER_ISNAN)) return false;
    // Add Number.isFinite (ES6 §20.1.2.2)
    if (!register_string_proto_method(num, heap, "isFinite", BUILTIN_NUMBER_ISFINITE)) return false;
    // Add Number.isInteger (ES6 §20.1.2.3)
    if (!register_string_proto_method(num, heap, "isInteger", BUILTIN_NUMBER_ISINTEGER)) return false;
    // Add Number.isSafeInteger (ES6 §20.1.2.5)
    if (!register_string_proto_method(num, heap, "isSafeInteger", BUILTIN_NUMBER_ISSAFEINTEGER)) return false;

    // Add Number.EPSILON (ES6 §20.1.2.1) — 2^-52
    if (!set_num_static_prop(num, heap, "EPSILON", 2.220446049250313e-16)) return false;
    // Add Number.MAX_SAFE_INTEGER (ES6 §20.1.2.6) — 2^53 - 1
    if (!set_num_static_prop(num, heap, "MAX_SAFE_INTEGER", (double)types::DUK_MAX_SAFE_INT)) return false;
    // Add Number.MIN_SAFE_INTEGER (ES6 §20.1.2.8) — -(2^53 - 1)
    if (!set_num_static_prop(num, heap, "MIN_SAFE_INTEGER", (double)types::DUK_MIN_SAFE_INT)) return false;
    // Add Number.parseInt (ES6 §20.1.2.12) — same as global parseInt
    if (!register_string_proto_method(num, heap, "parseInt", BUILTIN_PARSE_INT)) return false;
    // Add Number.parseFloat (ES6 §20.1.2.13) — same as global parseFloat
    if (!register_string_proto_method(num, heap, "parseFloat", BUILTIN_PARSE_FLOAT)) return false;

    // Register Number constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("Number");
    HString* existing = heap.str_table_lookup("Number", hash);
    HString* num_key;
    if (existing != null) {
        num_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Number", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        num_key = new_key;
    }
    TVal num_val;
    num_val.set_object(num);
    set_func_ctor_name_length(num, heap, "Number", 1);
    env::env_declare_nonenum(global_env, num_key, num_val);

    return true;
}
