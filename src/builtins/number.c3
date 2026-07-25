/// Number constructor and Number.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::env;
import std::math;
import duktape::hstring;

import duktape::heap;
import duktape::hobject;
import duktape::dtoa_bindings;
import std::io;

// ============================================================================
// Number constructor builtins
// ============================================================================

/// thisNumberValue(this value) per ES2022 §21.1.3: returns the Number value
/// if `this` is a number primitive or a Number-wrapper object, else false.
/// Callers must check the returned bool before using `out` — a false return
/// means the caller must throw a TypeError (this value is not a number).
fn bool this_number_value(BuiltinContext* ctx, double* out) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_number()) {
        *out = this_val.get_number();
        return true;
    }
    if (this_val.is_fastint()) {
        *out = (double)this_val.get_fastint();
        return true;
    }
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.NUMBER &&
            ((*obj.extra_ptr()).prim.primitive_value.is_number() || (*obj.extra_ptr()).prim.primitive_value.is_fastint())) {
            *out = (*obj.extra_ptr()).prim.primitive_value.get_number_or_fastint();
            return true;
        }
    }
    return false;
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
        // ES2020 §21.1.1.1 step 2: Number(BigInt) → 𝔽(ℝ(value)); the Number
        // constructor converts a BigInt to the closest double (it does NOT go
        // through ToNumber, which would throw for a BigInt).
        TVal* n_arg = &ctx.regs[ctx.base_reg];
        if (n_arg.is_bigint()) {
            num.set_number((double)n_arg.get_bigint());
        } else if (ctx.vm != null) {
            double d = builtin_to_number_vm(ctx, &ctx.regs[ctx.base_reg]);
            if (ctx.should_throw) return;
            num.set_number(d);
        } else {
            builtin_to_number(&ctx.regs[ctx.base_reg], &num);
        }
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
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.number_proto);
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

    // Determine radix — ToIntegerOrInfinity(radix) via the VM so that a
    // radix object's valueOf/toString is invoked and abrupt completions
    // (thrown errors) propagate before the range check.
    int radix = 10;
    bool radix_undefined = ctx.argc == 0 ||
        ctx.regs[ctx.base_reg].get_tag() == types::TValTag.UNDEFINED;
    if (!radix_undefined) {
        double radix_d = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (radix_d < 2 || radix_d > 36) {
            // RangeError per ES5 §15.7.4.2
            builtin_throw(ctx, ctx.heap.range_err_proto, "radix must be an integer between 2 and 36");
            return;
        }
        radix = (int)(long)radix_d;
    }

    // Handle special values
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
    if (d == 0.0) {
        HString* s = builtin_intern_string(ctx.heap, "0");
        ctx.result.set_string(s);
        return;
    }

    // Radix 10: use existing ToString formatting
    if (radix == 10) {
        HString* s10 = builtin_number_to_hstring(ctx.heap, d);
        if (s10 == null) { ctx.result.set_undefined(); return; }
        ctx.result.set_string(s10);
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

/// Number.prototype.toFixed(fractionDigits) — ES2022 §21.1.3.3
/// Step order: ToIntegerOrInfinity(fractionDigits) and its range check happen
/// before thisNumberValue is checked, but thisNumberValue itself must throw
/// TypeError first if `this` is not a number (implementations commonly check
/// fractionDigits first since it can throw independently of `this`).
fn void builtin_number_proto_toFixed(BuiltinContext* ctx) {
    // 1. Let f be ? ToIntegerOrInfinity(fractionDigits).
    int f = 0;
    if (ctx.argc > 0) {
        double f_d = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        // 2. If f is not finite, throw a RangeError exception.
        // 3. If f < 0 or f > 100, throw a RangeError exception.
        if (math::is_inf(f_d) || f_d < 0 || f_d > 100) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "fractionDigits out of range");
            return;
        }
        f = (int)(long)f_d;
    }

    // 4. Let x be ? thisNumberValue(this value).
    double d;
    if (!this_number_value(ctx, &d)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Number.prototype.toFixed called on incompatible value");
        ctx.result.set_undefined();
        return;
    }

    // Normalize -0 to +0
    if (d == 0.0) d = 0.0;

    // 5. If x is NaN, return the String "NaN".
    if (math::is_nan(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.set_string(s);
        return;
    }
    // 6. If x < 0, ... 7. If x >= 10^21 ...  (both handled below via Infinity check + flag)
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.set_string(s);
        return;
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

/// Number.prototype.toExponential(fractionDigits) — ES2022 §21.1.3.2
/// Step order: 1. Let x be ? thisNumberValue(this value). 2. Let f be
/// ? ToIntegerOrInfinity(fractionDigits) — this may call user code (valueOf/
/// toString) so it must run even when fractionDigits is undefined behaves
/// as a no-op (ToIntegerOrInfinity(undefined) = 0, but the "undefined" case
/// is distinguished later to select free-format output).
fn void builtin_number_proto_toExponential(BuiltinContext* ctx) {
    // 1. Let x be ? thisNumberValue(this value).
    double d;
    if (!this_number_value(ctx, &d)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Number.prototype.toExponential called on incompatible value");
        ctx.result.set_undefined();
        return;
    }

    // Normalize -0 to +0
    if (d == 0.0) d = 0.0;

    bool fraction_digits_undefined = ctx.argc == 0 ||
        ctx.regs[ctx.base_reg].get_tag() == types::TValTag.UNDEFINED;

    // 2. Let f be ? ToIntegerOrInfinity(fractionDigits).
    double f_d = 0.0;
    if (!fraction_digits_undefined) {
        f_d = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }

    // 4. If x is NaN, return the String "NaN".
    if (math::is_nan(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.set_string(s);
        return;
    }
    // 7. If x = +/-Infinity, return the signed "Infinity" string.
    // (the fractionDigits range check does not apply to Infinity `this`)
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.set_string(s);
        return;
    }

    // 8. If f < 0 or f > 100, throw a RangeError exception.
    if (!fraction_digits_undefined && (f_d < 0 || f_d > 100)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "fractionDigits out of range");
        return;
    }
    int f = (int)(long)f_d;

    int flags = dtoa_bindings::JS_DTOA_FORMAT_FIXED | dtoa_bindings::JS_DTOA_EXP_ENABLED;
    int n_digits = f + 1;
    if (fraction_digits_undefined) {
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

/// Number.prototype.toPrecision(precision) — ES2022 §21.1.3.5
/// Step order: 1. Let x be ? thisNumberValue(this value). 2. If precision is
/// undefined, return ! ToString(x). 3. Let p be ? ToInteger(precision).
/// 4. If x is NaN, return "NaN" (checked AFTER ToInteger(precision), so a
/// poisoned precision object still has its valueOf/toString invoked).
fn void builtin_number_proto_toPrecision(BuiltinContext* ctx) {
    // 1. Let x be ? thisNumberValue(this value).
    double d;
    if (!this_number_value(ctx, &d)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Number.prototype.toPrecision called on incompatible value");
        ctx.result.set_undefined();
        return;
    }

    // Normalize -0 to +0
    if (d == 0.0) d = 0.0;

    bool precision_undefined = ctx.argc == 0 ||
        ctx.regs[ctx.base_reg].get_tag() == types::TValTag.UNDEFINED;

    // 2. If precision is undefined, return ! ToString(x).
    if (precision_undefined) {
        HString* s = builtin_number_to_hstring(ctx.heap, d);
        if (s == null) { ctx.result.set_undefined(); return; }
        ctx.result.set_string(s);
        return;
    }

    // 3. Let p be ? ToInteger(precision).
    double p_d = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    // 4. If x is NaN, return the String "NaN".
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

    // 8. If p < 1 or p > 100, throw a RangeError exception.
    if (p_d < 1 || p_d > 100) {
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

/// Number.prototype.valueOf() — ES2022 §21.1.3.7
/// 1. Return ? thisNumberValue(this value). Throws TypeError if `this` is
/// not a number primitive or Number-wrapper object.
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
    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Number.prototype.valueOf called on incompatible value");
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

    // Add .toString() method — registered as a proper function object (not
    // LIGHTFUNC) so its .length (1, per ES2022 §21.1.3.6) can differ from
    // Number.prototype.toLocaleString's .length (0), even though both share
    // the same builtin_fn_index and would otherwise read identical metadata.
    HObject*? tostring_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = tostring_raw) return false;
    HObject* tostring_obj = tostring_raw;
    (*tostring_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.NUMBER_PROTO_TOSTRING.ordinal;
    tostring_obj.flags.callable = true;
    tostring_obj.flags.constructable = false;
    tostring_obj.prototype = heap.function_proto;
    HString* tostring_name_key = builtin_intern_string(heap, "name");
    HString* tostring_name_val = builtin_intern_string(heap, "toString");
    if (tostring_name_key != null && tostring_name_val != null) {
        TVal name_tv; name_tv.set_string(tostring_name_val);
        tostring_obj.put_prop(tostring_name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* tostring_length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (tostring_length_key != null) {
        TVal len_tv; len_tv.set_fastint(1);
        tostring_obj.put_prop(tostring_length_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* tostring_key = (HString*)heap.strs[heap::BuiltinStr.TO_STRING];
    TVal tostring_tv;
    tostring_tv.set_object(tostring_obj);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .valueOf() method
    HString* valueof_key = (HString*)heap.strs[heap::BuiltinStr.VALUE_OF];
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)Builtin.NUMBER_PROTO_VALUEOF.ordinal);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC);

    // Add .toFixed() method (Phase 6d)
    if (!register_string_proto_method(proto, heap, "toFixed", Builtin.NUMBER_PROTO_TOFIXED.ordinal)) return false;
    // Add .toExponential() method
    if (!register_string_proto_method(proto, heap, "toExponential", Builtin.NUMBER_PROTO_TOEXPONENTIAL.ordinal)) return false;
    // Add .toPrecision() method
    if (!register_string_proto_method(proto, heap, "toPrecision", Builtin.NUMBER_PROTO_TOPRECISION.ordinal)) return false;

    // Number.prototype.toLocaleString — ES5 §15.7.4.5
    // Delegates to Number.prototype.toString (handles number primitives correctly).
    if (!register_string_proto_method(proto, heap, "toLocaleString", Builtin.NUMBER_PROTO_TOSTRING.ordinal)) return false;

    // Create Number constructor as a proper function object (not LIGHTFUNC)
    // so it can carry static properties like Number.MAX_VALUE, Number.NaN, etc.
    HObject*? num_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = num_raw) return false;
    HObject* num = num_raw;
    (*num.extra_ptr()).func.builtin_fn_index = (int)Builtin.NUMBER.ordinal;

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
    if (!register_string_proto_method(num, heap, "isNaN", Builtin.NUMBER_ISNAN.ordinal)) return false;
    // Add Number.isFinite (ES6 §20.1.2.2)
    if (!register_string_proto_method(num, heap, "isFinite", Builtin.NUMBER_ISFINITE.ordinal)) return false;
    // Add Number.isInteger (ES6 §20.1.2.3)
    if (!register_string_proto_method(num, heap, "isInteger", Builtin.NUMBER_ISINTEGER.ordinal)) return false;
    // Add Number.isSafeInteger (ES6 §20.1.2.5)
    if (!register_string_proto_method(num, heap, "isSafeInteger", Builtin.NUMBER_ISSAFEINTEGER.ordinal)) return false;

    // Add Number.EPSILON (ES6 §20.1.2.1) — 2^-52
    if (!set_num_static_prop(num, heap, "EPSILON", 2.220446049250313e-16)) return false;
    // Add Number.MAX_SAFE_INTEGER (ES6 §20.1.2.6) — 2^53 - 1
    if (!set_num_static_prop(num, heap, "MAX_SAFE_INTEGER", (double)types::DUK_MAX_SAFE_INT)) return false;
    // Add Number.MIN_SAFE_INTEGER (ES6 §20.1.2.8) — -(2^53 - 1)
    if (!set_num_static_prop(num, heap, "MIN_SAFE_INTEGER", (double)types::DUK_MIN_SAFE_INT)) return false;
    // Add Number.parseInt (ES6 §20.1.2.12) — MUST be the same function object as global parseInt.
    // Look up the global parseInt (already registered) and put it directly on Number.
    {
        HString* parse_int_key = builtin_intern_string(heap, "parseInt");
        if (parse_int_key == null) return false;
        TVal? global_pi_opt = env::env_get(global_env, parse_int_key);
        TVal global_pi;
        if (try pi = global_pi_opt) {
            global_pi = pi;
        } else {
            // Fallback: create a new lightfunc if global lookup fails
            global_pi.set_lightfunc((void*)(usz)Builtin.PARSE_INT.ordinal);
        }
        num.put_prop(parse_int_key, global_pi, hobject::PROP_FLAGS_WC);
    }
    // Add Number.parseFloat (ES6 §20.1.2.13) — MUST be the same function object as global parseFloat.
    {
        HString* parse_float_key = builtin_intern_string(heap, "parseFloat");
        if (parse_float_key == null) return false;
        TVal? global_pf_opt = env::env_get(global_env, parse_float_key);
        TVal global_pf;
        if (try pf = global_pf_opt) {
            global_pf = pf;
        } else {
            global_pf.set_lightfunc((void*)(usz)Builtin.PARSE_FLOAT.ordinal);
        }
        num.put_prop(parse_float_key, global_pf, hobject::PROP_FLAGS_WC);
    }

    // Register Number constructor globally as an OBJECT (not LIGHTFUNC)
    HString* num_key = heap.str_intern("Number");
    if (num_key == null) return false;
    TVal num_val;
    num_val.set_object(num);
    set_func_ctor_name_length(num, heap, "Number", 1);
    env::env_declare_nonenum(global_env, num_key, num_val);

    return true;
}
