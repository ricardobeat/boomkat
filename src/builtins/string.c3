// String constructor and String.prototype methods.
module boomkat::builtins;
import boomkat::features;
import boomkat::types;
import boomkat::env;
import std::math;

import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::re_bindings;
import boomkat::unicode_bindings;
import boomkat::vm;

// ============================================================================
// String constructor builtins
// ============================================================================

// ToString then return string primitive (function call) or
// a String wrapper object (constructor call).
fn void builtin_string(BuiltinContext* ctx) {
    HString* s;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        // ECMA-262 String(value):
        //   2a. If NewTarget is undefined and Type(value) is Symbol, return
        //       SymbolDescriptiveString(value).
        //   2b. Let s be ? ToString(value).
        // So `String(symbol)` (no `new`) returns "Symbol(description)", but
        // `new String(symbol)` must call ToString which throws TypeError.
        // builtin_to_string_vm implements the throwing path (it treats any
        // symbol HString as a TypeError); builtin_to_string wraps it. Only
        // take the wrapping path when NewTarget is undefined.
        bool arg_is_symbol = false;
        if (arg.is_string()) {
            HString* hs = (HString*)arg.get_heapptr();
            arg_is_symbol = (hs != null && hs.is_symbol());
        }
        if (arg_is_symbol && !ctx.is_constructor) {
            // String(symbol) → SymbolDescriptiveString, no throw.
            s = builtin_to_string(ctx.heap, arg);
            if (s == null) {
                // Should never happen: builtin_to_string never fails for symbol storage.
                ctx.result_undefined();
                return;
            }
        } else {
            // new String(symbol) → ToString throws TypeError.
            // All other primitives and objects go through ToPrimitive + ToString.
            s = builtin_to_string_vm(ctx, arg);
            if (s == null) {
                // Caller already has ctx.should_throw set if applicable.
                ctx.result_undefined();
                return;
            }
        }
    } else {
        s = ctx.heap.str(heap::BuiltinStr.EMPTY);
    }

    if (ctx.is_constructor) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
        if (catch err = obj_raw) {
            ctx.result_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.flags.exotic_stringobj = true;
        ctx.heap.set_prototype(obj, builtin_proto_from_new_target(ctx, ctx.heap.string_proto));
        (*obj.extra_ptr()).prim.primitive_value.set_string(s);
        // Set.length own property, non-writable, non-enumerable, non-configurable
        HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)s.unit_len());
        obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC, ctx.heap);
        // Indexed character properties are served lazily via the exotic_stringobj flag;
        // no per-character own properties are materialised at construction time.
        ctx.result_object(obj);
    } else {
        ctx.result_string(s);
    }
}

// ToUint16 abstract operation.
// 1. Let number be ? ToNumber(argument).
// 2. If number is NaN, +0, -0, +∞, or -∞, return +0.
// 3. Let int = truncate(number).
// 4. Let int16bit be int modulo 2^16 (always non-negative).
// 5. Return int16bit.
fn uint to_uint16(BuiltinContext* ctx, TVal* val) {
    double n = builtin_to_number_vm(ctx, val);
    if (ctx.should_throw) return 0;
    if (math::is_nan(n) || n == 0.0 || n == double::inf || n == -double::inf) return 0;
    // Step 3: truncate toward zero
    double truncated = n >= 0 ? math::floor(n) : -math::floor(-n);
    // Step 4: modulo 2^16 (always non-negative)
    // For values within safe integer range, use integer modulo (exact).
    if (truncated >= -9007199254740992.0 && truncated <= 9007199254740992.0) {
        long int_val = (long)truncated;
        return (uint)(int_val & 0xFFFF);
    }
    // For very large values, use floating-point approach.
    double mod = truncated - math::floor(truncated / 65536.0) * 65536.0;
    return (uint)(ushort)mod;
}

// String.fromCharCode
fn void builtin_string_fromcharcode(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        HString* empty = ctx.heap.str(heap::BuiltinStr.EMPTY);
        ctx.result_string(empty);
        return;
    }
    StrBuf out;
    out.init(ctx.heap);
    defer out.free();
    for (ushort i = 0; i < ctx.argc; i++) {
        uint cu = to_uint16(ctx, &ctx.regs[ctx.base_reg + i]);
        if (ctx.should_throw) return;
        out.append_unit(cu);
    }
    HString* result = builtin_intern_string(ctx.heap, out.bytes());
    if (result == null) { builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid string length"); return; }
    ctx.result_string(result);
}

// String.fromCodePoint(...codePoints)
fn void builtin_string_fromcodepoint(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        HString* empty = ctx.heap.str(heap::BuiltinStr.EMPTY);
        ctx.result_string(empty);
        return;
    }
    StrBuf out;
    out.init(ctx.heap);
    defer out.free();
    for (ushort i = 0; i < ctx.argc; i++) {
        TVal* arg = &ctx.regs[ctx.base_reg + i];
        double d;
        if (arg.is_fastint()) {
            d = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            d = arg.get_number();
        } else if (arg.is_boolean()) {
            d = arg.get_boolean() ? 1.0 : 0.0;
        } else if (arg.is_null()) {
            d = 0.0;
        } else {
            d = builtin_to_number_vm(ctx, arg);
            if (ctx.should_throw) return;
        }
        // Check: must be integral Number in [0, 0x10FFFF]
        if (math::is_nan(d) || math::is_inf(d) || d != math::trunc(d) || d < 0 || d > 0x10FFFF) {
            builtin_throw_no_result_change(ctx, ctx.heap.range_err_proto, "Invalid code point value");
            return;
        }
        uint ucp = (uint)(long)d;
        if (ucp < hstring::ASTRAL_START) {
            out.append_unit(ucp);
        } else {
            uint high; uint low;
            hstring::codepoint_to_surrogates(ucp, &high, &low);
            out.append_unit(high);
            out.append_unit(low);
        }
    }
    HString* result_str = builtin_intern_string(ctx.heap, out.bytes());
    if (result_str == null) { builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid string length"); return; }
    ctx.result_string(result_str);
}

// String.raw(template,...substitutions)
//
// Reads template.raw as an array-like, interleaves its string-coerced
// elements with the substitution arguments, and returns the concatenation.
// ToObject/Get/LengthOfArrayLike follow the spec exactly so getter
// side-effects and abrupt completions propagate correctly.
fn void builtin_string_raw(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    if (ctx.argc == 0) {
        builtin_throw(ctx, heap.type_err_proto, "String.raw requires a template argument");
        return;
    }

    // Step 1-3: Let cooked = ToObject(template).
    TVal template_val = ctx.regs[ctx.base_reg];
    HObject* cooked = arr_to_object(template_val, heap);
    if (cooked == null) {
        builtin_throw(ctx, heap.type_err_proto, "String.raw: template is not an object");
        return;
    }

    // Step 4: Let raw = ToObject(Get(cooked, "raw")).
    HString* raw_key = builtin_intern_string(heap, "raw");
    if (raw_key == null) { ctx.result_undefined(); return; }
    TVal? raw_tv_opt = builtins_generic_get(cooked, raw_key, ctx);
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    TVal raw_tv;
    if (try rv = raw_tv_opt) {
        raw_tv = rv;
    } else {
        raw_tv.set_undefined();
    }
    HObject* raw_obj = arr_to_object(raw_tv, heap);
    if (raw_obj == null) {
        builtin_throw(ctx, heap.type_err_proto, "String.raw: template.raw is not an object");
        return;
    }

    // Step 5: Let literalSegments = LengthOfArrayLike(raw).
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (len_key == null) { ctx.result_undefined(); return; }
    TVal? len_opt = builtins_generic_get(raw_obj, len_key, ctx);
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    long literal_segments = 0;
    if (try lv = len_opt) {
        double ld;
        if (lv.is_fastint()) {
            ld = (double)lv.get_fastint();
        } else if (lv.is_number()) {
            ld = lv.get_number();
        } else if (lv.is_undefined() || lv.is_null()) {
            ld = 0.0;
        } else if (is_symbol_val(lv)) {
            builtin_throw(ctx, heap.type_err_proto, "Cannot convert a Symbol value to a number");
            return;
        } else {
            ld = builtin_to_number_getdouble(ctx, &lv);
            if (ctx.should_throw) { ctx.result_undefined(); return; }
        }
        if (math::is_nan(ld) || math::is_inf(ld) || ld < 0) {
            ld = 0.0;
        }
        if (ld > (double)0x7FFFFFFF) ld = (double)0x7FFFFFFF;
        literal_segments = (long)ld;
    }

    // Step 6: If literalSegments ≤ 0, return "".
    if (literal_segments <= 0) {
        HString* empty = heap.str(heap::BuiltinStr.EMPTY);
        ctx.result_string(empty);
        return;
    }

    // Step 12+: Accumulate the interleaved segments.
    StrBuf out;
    out.init(heap);
    defer out.free();

    for (long next_index = 0; next_index < literal_segments; next_index++) {
        // Step 12.b: nextSeg = ToString(Get(raw, nextKey)).
        HString* idx_key = heap.int_to_hstring(next_index);
        if (idx_key == null) { ctx.result_undefined(); return; }
        TVal? seg_opt = builtins_generic_get(raw_obj, idx_key, ctx);
        if (ctx.should_throw) { ctx.result_undefined(); return; }
        TVal seg_tv;
        if (try sv = seg_opt) {
            seg_tv = sv;
        } else {
            seg_tv.set_undefined();
        }
        if (is_symbol_val(seg_tv)) {
            builtin_throw(ctx, heap.type_err_proto, "Cannot convert a Symbol value to a string");
            return;
        }
        HString* seg_str = builtin_to_string_vm(ctx, &seg_tv);
        if (ctx.should_throw) { ctx.result_undefined(); return; }
        if (seg_str != null) out.append_hstring(seg_str);

        // Step 12.e: If nextIndex + 1 = literalSegments, finished, exit loop.
        if (next_index + 1 == literal_segments) break;

        // Step 12.f: Append substitutions[nextIndex] (if present).
        // Substitution args start at base_reg + 1; ctx.argc includes the template arg.
        long sub_argc = (long)ctx.argc - 1;
        if (next_index < sub_argc) {
            TVal sub_tv = ctx.regs[ctx.base_reg + 1 + (uint)next_index];
            if (is_symbol_val(sub_tv)) {
                builtin_throw(ctx, heap.type_err_proto, "Cannot convert a Symbol value to a string");
                return;
            }
            HString* sub_str = builtin_to_string_vm(ctx, &sub_tv);
            if (ctx.should_throw) { ctx.result_undefined(); return; }
            if (sub_str != null) out.append_hstring(sub_str);
        }
    }
    out.finish(ctx);
}

// String.prototype.toString, returns the wrapped string value
fn void builtin_string_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.STRING &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()) {
            ctx.result_string((*obj.extra_ptr()).prim.primitive_value.get_heapptr());
            return;
        }
    } else if (this_val.is_string()) {
        HString* hs = (HString*)this_val.get_heapptr();
        // Symbols stored as tagged strings, thisStringValue throws TypeError for Symbol.
        if (hs != null && hs.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "Cannot convert a Symbol value to a string");
            return;
        }
        ctx.result_string(this_val.get_heapptr());
        return;
    }
    // Per ECMA-262 §21.1.3.27 step 1-3: thisStringValue throws TypeError for non-String values
    builtin_throw(ctx, ctx.heap.type_err_proto,
        "String.prototype.toString requires that 'this' be a String");
}

// String.prototype.data.valueOf, returns the wrapped string primitive
fn void builtin_string_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.STRING &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()) {
            ctx.result_string((*obj.extra_ptr()).prim.primitive_value.get_heapptr());
            return;
        }
    } else if (this_val.is_string()) {
        HString* hs = (HString*)this_val.get_heapptr();
        // Symbols stored as tagged strings, thisStringValue throws TypeError for Symbol.
        if (hs != null && hs.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "Cannot convert a Symbol value to a string");
            return;
        }
        ctx.result_string(this_val.get_heapptr());
        return;
    }
    // Per ECMA-262 §21.1.3.28 step 1-3: thisStringValue throws TypeError for non-String values
    builtin_throw(ctx, ctx.heap.type_err_proto,
        "String.prototype.valueOf requires that 'this' be a String");
}

// ============================================================================
// String.prototype methods (Phase 6b)
// ============================================================================

// Helper: extract the string data and length from `this`, handling both
// primitive strings and String wrapper objects. Returns null on failure.
//
// Implements RequireObjectCoercible + ToString(this) with full ToPrimitive
// support (Symbol.toPrimitive, toString, valueOf) for object receivers.
// Symbols as `this` throw TypeError per §7.1.17.
fn HString* string_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_string()) {
        HString* hs = (HString*)this_val.get_heapptr();
        // Symbols stored as tagged strings, ToString(Symbol) throws TypeError.
        if (hs != null && hs.is_symbol()) {
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
                "Cannot convert a Symbol value to a string");
            return null;
        }
        return hs;
    }
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.STRING &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()) {
            return (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        }
    }
    // RequireObjectCoercible: throw for undefined/null.
    if (this_val.is_undefined() || this_val.is_null()) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "String.prototype method called on incompatible value");
        return null;
    }
    // ToString for objects: ToPrimitive(hint "string") then ToString.
    // The VM-aware path runs user-defined Symbol.toPrimitive/toString/valueOf
    // and propagates abrupt completions (including accessor get errors).
    if (this_val.is_object() && ctx.vm != null) {
        Vm* vm_ptr = (Vm*)ctx.vm;
        TVal prim = vm::to_primitive_value(vm_ptr, &this_val, 1);  // hint "string"
        if (vm_ptr.throw_pending) {
            // Propagate the pending throw value so the caller's
            // `ctx.should_throw` path surfaces the original exception.
            // Clear throw_pending so stale state does not re-fire after the
            // dispatcher re-throws via vm_throw_value.
            ctx.should_throw = true;
            ctx.throw_value = vm_ptr.throw_value;
            vm_ptr.throw_pending = false;
            return null;
        }
        // ToString the resulting primitive.
        if (prim.is_string()) {
            HString* ps = (HString*)prim.get_heapptr();
            if (ps != null && ps.is_symbol()) {
                builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
                    "Cannot convert a Symbol value to a string");
                return null;
            }
            return ps;
        }
        if (prim.is_object()) {
            // ToPrimitive returned an object, throw TypeError per §7.1.1.
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
                "Cannot convert object to primitive value");
            return null;
        }
        return builtin_to_string(ctx.heap, &prim);
    }
    return builtin_to_string(ctx.heap, &this_val);
}

// String.prototype.charAt(pos)
fn void builtin_string_proto_charAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    uint clen = s_hstr.unit_len();
    double pos = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    if (pos < 0 || pos >= (double)clen) {
        // Return empty string
        ctx.result_string(ctx.heap.str(heap::BuiltinStr.EMPTY));
        return;
    }
    uint idx = (uint)(long)pos;
    ctx.result_string(ctx.heap.str_from_unit(s_hstr.unit_at(idx)));
}

// String.prototype.charCodeAt(pos)
//
// Returns the UTF-16 code unit at `pos` (a surrogate half for astral
// characters, never combined).
fn void builtin_string_proto_charCodeAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    uint clen = s_hstr.unit_len();
    double pos = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    if (pos < 0 || pos >= (double)clen) {
        ctx.result_number(double::nan);
        return;
    }
    uint idx = (uint)(long)pos;
    ctx.result_fastint((long)s_hstr.unit_at(idx));
}

// String.prototype.indexOf(searchString, position)
fn void builtin_string_proto_indexOf(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    uint clen = s_hstr.unit_len();

    // Get search string
    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result_undefined(); return; }
    } else {
        search_hstr = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }
    if (search_hstr == null) {
        ctx.result_fastint(-1);
        return;
    }

    // Get position
    double pos_d = (ctx.argc > 1) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]) : 0.0;
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    uint pos_units;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos_units = 0;
    } else if (pos_d >= (double)clen) {
        pos_units = clen;
    } else {
        pos_units = (uint)(long)pos_d;
    }
    ctx.result_fastint((long)hstring::find_units(s_hstr, search_hstr, pos_units));
}

// String.prototype.slice(start, end)
fn void builtin_string_proto_slice(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    uint len = s_hstr.unit_len();

    double start_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    // Per ECMA-262 §15.5.4.13 step 6: if end is undefined, let end be len.
    double end_d;
    if (ctx.argc > 1) {
        TVal* end_arg = &ctx.regs[ctx.base_reg + 1];
        if (end_arg.is_undefined()) {
            end_d = (double)len;
        } else {
            end_d = builtin_to_integer_vm(ctx, end_arg);
        }
    } else {
        end_d = (double)len;
    }
    if (ctx.should_throw) { ctx.result_undefined(); return; }

    // ECMA-262 §15.5.4.13 steps 7-8: clamp to [0, len]. NaN→0; ±∞ resolve to the
    // clamped extreme (cast to int after clamping so Infinity doesn't wrap).
    int start_i;
    if (math::is_nan(start_d) || start_d == 0.0) {
        start_i = 0;
    } else if (start_d < 0) {
        start_i = (start_d + (double)len < 0) ? 0 : (int)(long)(start_d + (double)len);
    } else {
        start_i = (start_d > (double)len) ? (int)len : (int)(long)start_d;
    }

    int end_i;
    if (math::is_nan(end_d)) {
        end_i = 0;
    } else if (end_d < 0) {
        end_i = (end_d + (double)len < 0) ? 0 : (int)(long)(end_d + (double)len);
    } else {
        end_i = (end_d > (double)len) ? (int)len : (int)(long)end_d;
    }

    if (start_i >= end_i) {
        ctx.result_string(ctx.heap.str(heap::BuiltinStr.EMPTY));
        return;
    }

    ctx.result_string(ctx.heap.str_slice(s_hstr, (uint)start_i, (uint)end_i));
}

// String.prototype.substring(start, end)
fn void builtin_string_proto_substring(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    uint len = s_hstr.unit_len();

    double start_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    // Per ECMA-262 §15.5.4.15 step 6: if end is undefined, let end be len.
    double end_d;
    if (ctx.argc > 1) {
        TVal* end_arg = &ctx.regs[ctx.base_reg + 1];
        if (end_arg.is_undefined()) {
            end_d = (double)len;
        } else {
            end_d = builtin_to_integer_vm(ctx, end_arg);
        }
    } else {
        end_d = (double)len;
    }
    if (ctx.should_throw) { ctx.result_undefined(); return; }

    uint start = clamp_index(start_d, len);
    uint end = clamp_index(end_d, len);

    uint from = start < end ? start : end;
    uint to = start < end ? end : start;

    if (from >= to) {
        ctx.result_string(ctx.heap.str(heap::BuiltinStr.EMPTY));
        return;
    }

    ctx.result_string(ctx.heap.str_slice(s_hstr, from, to));
}

// String.prototype.substr(start, length)
//
// Per §B.2.3 step 4, an explicit `undefined` length means "+∞" — not the
// 0 that ToInteger(NaN) produces from a missing arg. Otherwise ToInteger
// applies and any negative result clamps to 0 via `resultLength ≤ 0`.
fn void builtin_string_proto_substr(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    uint len = s_hstr.unit_len();

    double start_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result_undefined(); return; }

    int start_i;
    if (math::is_nan(start_d)) {
        start_i = 0;
    } else if (start_d == double::inf) {
        start_i = (int)len;
    } else if (start_d == -double::inf) {
        start_i = 0;
    } else if (start_d < 0) {
        start_i = (int)(long)start_d + (int)len;
        if (start_i < 0) start_i = 0;
    } else {
        start_i = (int)(long)start_d;
        if (start_i > (int)len) start_i = (int)len;
    }

    // length_d = +∞ when no arg was passed or the arg was explicitly undefined.
    // A `null` arg goes through ToInteger → 0 → empty string (matches qjs).
    double length_d;
    if (ctx.argc < 2 || ctx.regs[ctx.base_reg + 1].is_undefined()) {
        length_d = double::inf;
    } else {
        length_d = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
    }
    if (ctx.should_throw) { ctx.result_undefined(); return; }

    if (length_d <= 0 || (length_d != length_d)) {
        ctx.result_string(ctx.heap.str(heap::BuiltinStr.EMPTY));
        return;
    }
    int length_i;
    if (length_d == double::inf) {
        length_i = (int)len - start_i;
    } else {
        length_i = (int)(long)length_d;
        if (length_i > (int)len - start_i) {
            length_i = (int)len - start_i;
        }
    }
    if (length_i <= 0) {
        ctx.result_string(ctx.heap.str(heap::BuiltinStr.EMPTY));
        return;
    }

    ctx.result_string(ctx.heap.str_slice(s_hstr, (uint)start_i, (uint)(start_i + length_i)));
}

// ============================================================================
// Unicode case conversion helpers
// ============================================================================

// The code points of `s` in a malloc'd array the caller frees; a surrogate pair
// becomes one code point and a lone surrogate stays itself. Null on OOM.
fn uint* string_codepoints(HString* s, uint* out_n) {
    uint len = s.unit_len();
    uint* cps = (uint*)alloc::malloc_try(mem, (sz)(((usz)len + 1) * 4)) ?? null;
    if (cps == null) { *out_n = 0; return null; }
    uint n = 0;
    for (uint i = 0; i < len; i++) {
        uint cp = s.unit_at(i);
        if (hstring::is_high_surrogate(cp) && i + 1 < len) {
            uint low = s.unit_at(i + 1);
            if (hstring::is_low_surrogate(low)) {
                cp = hstring::surrogates_to_codepoint(cp, low);
                i++;
            }
        }
        cps[n++] = cp;
    }
    *out_n = n;
    return cps;
}

// The string of the code points `cps[0:n]`, interned when short. Null on OOM or
// when the result would be too long.
fn HString* codepoints_to_hstring(Heap* heap, uint* cps, uint n) {
    StrBuf out;
    out.init(heap);
    defer out.free();
    for (uint i = 0; i < n; i++) out.append_codepoint(cps[i]);
    if (out.failed) return null;
    return builtin_intern_string(heap, out.bytes());
}

// GREEK CAPITAL LETTER SIGMA codepoint, has Final_Sigma conditional mapping.
const uint CP_SIGMA = 0x03A3;
const uint CP_SIGMA_FINAL = 0x03C2;   // ς, final form
const uint CP_SIGMA_LOWER = 0x03C3;   // σ, non-final form

// Determine which lowercase form of Greek Sigma to use.
// Per Unicode Default Case Algorithms §3.13:
//   Final_Sigma: Σ is lowercase to ς (U+03C2) when it is directly after
//   a Cased character (possibly surrounded by Case_Ignorable) and is NOT
//   directly before a Cased character (possibly surrounded by Case_Ignorable).
fn uint sigma_lower_form(uint* cps, uint n, uint idx) {
    // Look backward for a Cased character (skip Case_Ignorable).
    // Per Unicode Final_Sigma: the "anchor" cased character must be
    // Cased AND *not* Case_Ignorable (characters that are both Cased and
    // Case_Ignorable, like U+0345, count only as Case_Ignorable, not as
    // the cased anchor).
    bool preceded_by_cased = false;
    uint j = idx;
    while (j > 0) {
        j--;
        uint prev = cps[j];
        bool prev_cased    = (unicode_bindings::unicode_is_cased(prev) != 0);
        bool prev_ignorable = (unicode_bindings::unicode_is_case_ignorable(prev) != 0);
        if (prev_cased && !prev_ignorable) {
            preceded_by_cased = true;
            break;
        }
        if (!prev_ignorable) {
            break; // non-ignorable, non-cased: stops the backward scan
        }
        // prev is Case_Ignorable (whether cased or not): keep scanning
    }
    if (!preceded_by_cased) return CP_SIGMA_LOWER;

    // Look forward for a Cased character (skip Case_Ignorable).
    // Same convention as the backward scan: the "following cased" anchor must
    // be Cased AND not Case_Ignorable.
    bool followed_by_cased = false;
    uint k = idx + 1;
    while (k < n) {
        uint next = cps[k];
        bool next_cased     = (unicode_bindings::unicode_is_cased(next) != 0);
        bool next_ignorable  = (unicode_bindings::unicode_is_case_ignorable(next) != 0);
        if (next_cased && !next_ignorable) {
            followed_by_cased = true;
            break;
        }
        if (!next_ignorable) {
            break; // non-ignorable, non-cased: stops the forward scan
        }
        k++;
    }

    return followed_by_cased ? CP_SIGMA_LOWER : CP_SIGMA_FINAL;
}

// The languages with conditional mappings in SpecialCasing.txt.
enum CaseLanguage {
    ROOT,
    TURKIC,       // tr, az
    LITHUANIAN,   // lt
}

const uint CP_COMBINING_DOT_ABOVE = 0x0307;

// Unicode Table 3-17 casing contexts. A mark of class 0 or 230 (Above) ends each scan.
fn bool case_ends_scan(uint cp) {
    int cc = unicode_bindings::unicode_combining_class(cp);
    return cc == 0 || cc == 230;
}

// More_Above: a class-230 mark follows before any other class-0 or class-230 character.
fn bool case_more_above(uint* cps, uint n, uint idx) {
    for (uint k = idx + 1; k < n; k++) {
        int cc = unicode_bindings::unicode_combining_class(cps[k]);
        if (cc == 230) return true;
        if (cc == 0) return false;
    }
    return false;
}

// Before_Dot: U+0307 follows, with only marks of other classes than 0 and 230 between.
fn bool case_before_dot(uint* cps, uint n, uint idx) {
    for (uint k = idx + 1; k < n; k++) {
        if (cps[k] == CP_COMBINING_DOT_ABOVE) return true;
        if (case_ends_scan(cps[k])) return false;
    }
    return false;
}

// After_I (want_soft_dotted false) and After_Soft_Dotted: an I, or a Soft_Dotted character,
// precedes with no class-0 or class-230 character between.
fn bool case_after(uint* cps, uint idx, bool want_soft_dotted) {
    uint j = idx;
    while (j > 0) {
        j--;
        uint cp = cps[j];
        if (want_soft_dotted ? unicode_bindings::unicode_is_soft_dotted(cp) != 0 : cp == 'I') return true;
        if (case_ends_scan(cp)) return false;
    }
    return false;
}

// The SpecialCasing language-conditional mapping of cps[idx], written to out. Returns how many
// code points it wrote, 0 to drop the code point, or -1 when no conditional mapping applies.
fn int case_language_map(CaseLanguage lang, int conv_type, uint* cps, uint n, uint idx, uint* out) {
    uint cp = cps[idx];
    if (lang == TURKIC) {
        if (conv_type == 0) {
            if (cp != 'i') return -1;
            out[0] = 0x0130;
            return 1;
        }
        switch (cp) {
            case 0x0130:
                out[0] = 'i';
                return 1;
            case CP_COMBINING_DOT_ABOVE:
                return case_after(cps, idx, false) ? 0 : -1;
            case 'I':
                out[0] = case_before_dot(cps, n, idx) ? 'i' : 0x0131;
                return 1;
            default:
                return -1;
        }
    }
    if (lang == LITHUANIAN) {
        if (conv_type == 0) {
            return cp == CP_COMBINING_DOT_ABOVE && case_after(cps, idx, true) ? 0 : -1;
        }
        uint accent;
        switch (cp) {
            case 'I':
            case 'J':
            case 0x012E:
                if (!case_more_above(cps, n, idx)) return -1;
                out[0] = cp == 0x012E ? 0x012F : cp + 0x20;
                out[1] = CP_COMBINING_DOT_ABOVE;
                return 2;
            case 0x00CC: accent = 0x0300;
            case 0x00CD: accent = 0x0301;
            case 0x0128: accent = 0x0303;
            default: return -1;
        }
        out[0] = 'i';
        out[1] = CP_COMBINING_DOT_ABOVE;
        out[2] = accent;
        return 3;
    }
    return -1;
}

// Full Unicode case conversion (toLowerCase or toUpperCase), with the language-conditional
// mappings of `lang` (toLocaleLowerCase / toLocaleUpperCase).
// conv_type: 1 = lowercase, 0 = uppercase.
// Returns a newly interned HString*, or null on OOM.
fn HString* unicode_case_convert_str(Heap* heap, HString* s, int conv_type, CaseLanguage lang = ROOT) {
    if (s.unit_len() == 0) {
        return heap.str(heap::BuiltinStr.EMPTY);
    }

    // Fast path: ASCII-only string. Turkic maps the ASCII i and I differently.
    if (lang != TURKIC && s.is_ascii()) {
        char[] data = s.ascii_bytes();
        char* out_buf = (char*)alloc::malloc_try(mem, (sz)data.len) ?? null;
        if (out_buf == null) return null;
        for (usz ai = 0; ai < data.len; ai++) {
            char c = data[ai];
            if (conv_type == 1) { // lowercase
                if (c >= 'A' && c <= 'Z') c = (char)((uint)c + 32);
            } else { // uppercase
                if (c >= 'a' && c <= 'z') c = (char)((uint)c - 32);
            }
            out_buf[ai] = c;
        }
        HString* result = builtin_intern_string(heap, out_buf[:data.len]);
        mem::free(out_buf);
        return result;
    }

    uint num_cps;
    uint* cps = string_codepoints(s, &num_cps);
    if (cps == null) return null;

    // Apply case mapping: each input codepoint can expand to up to 3 output codepoints
    uint out_max = num_cps * 3 + 1;
    uint* out_cps = (uint*)alloc::malloc_try(mem, (sz)((usz)out_max * 4)) ?? null;
    if (out_cps == null) {
        mem::free(cps);
        return null;
    }

    uint out_n = 0;
    uint[3] mapped;
    for (uint i = 0; i < num_cps; i++) {
        uint cp = cps[i];
        int n_mapped = lang == ROOT ? -1 : case_language_map(lang, conv_type, cps, num_cps, i, &mapped[0]);
        if (n_mapped >= 0) {
            for (int m = 0; m < n_mapped; m++) {
                out_cps[out_n] = mapped[m];
                out_n++;
            }
        } else if (conv_type == 1 && cp == CP_SIGMA) {
            // Greek capital sigma: context-sensitive lowercase
            out_cps[out_n] = sigma_lower_form(cps, num_cps, i);
            out_n++;
        } else {
            n_mapped = unicode_bindings::unicode_case_conv(cp, conv_type, &mapped[0]);
            for (int m = 0; m < n_mapped; m++) {
                out_cps[out_n] = mapped[m];
                out_n++;
            }
        }
    }
    mem::free(cps);

    HString* result = codepoints_to_hstring(heap, out_cps, out_n);
    mem::free(out_cps);
    return result;
}

// String.prototype.toLowerCase(), full Unicode case mapping
fn void builtin_string_proto_toLowerCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    HString* result = unicode_case_convert_str(ctx.heap, s_hstr, 1);
    if (result == null) {
        ctx.result_undefined();
        return;
    }
    ctx.result_string(result);
}

// String.prototype.toUpperCase(), full Unicode case mapping
fn void builtin_string_proto_toUpperCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    HString* result = unicode_case_convert_str(ctx.heap, s_hstr, 0);
    if (result == null) {
        ctx.result_undefined();
        return;
    }
    ctx.result_string(result);
}

// ECMA-402 TransformCase: the first requested locale picks the language whose
// conditional mappings apply; an invalid tag throws a RangeError. Without Intl the default
// mappings apply.
fn void string_locale_case(BuiltinContext* ctx, int conv_type) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    CaseLanguage lang = ROOT;
$if $feat(INTL):
    HObject* requested = intl_locales(ctx, builtin_arg(ctx, 0), IntlLocaleFilter.ALL);
    if (ctx.should_throw) return;
    TVal? first = requested.get_prop(ctx.heap.int_to_hstring(0), ctx.heap);
    if (try tag = first) {
        HString* t = (HString*)tag.get_heapptr();
        if (t.is_ascii()) {
            char[] text = t.ascii_bytes();
            usz end = 0;
            while (end < text.len && text[end] != '-') end++;
            char[] language = text[:end];
            if (mem_eq_bytes(language, "tr") || mem_eq_bytes(language, "az")) {
                lang = TURKIC;
            } else if (mem_eq_bytes(language, "lt")) {
                lang = LITHUANIAN;
            }
        }
    }
$endif
    HString* result = unicode_case_convert_str(ctx.heap, s_hstr, conv_type, lang);
    if (result == null) {
        ctx.result_undefined();
        return;
    }
    ctx.result_string(result);
}

// String.prototype.toLocaleLowerCase([locales]), ECMA-402 §19.1.2
fn void builtin_string_proto_toLocaleLowerCase(BuiltinContext* ctx) {
    string_locale_case(ctx, 1);
}

// String.prototype.toLocaleUpperCase([locales]), ECMA-402 §19.1.3
fn void builtin_string_proto_toLocaleUpperCase(BuiltinContext* ctx) {
    string_locale_case(ctx, 0);
}

// String.prototype.localeCompare(that)
//
// A build with Intl.Collator compares through it (ECMA-402 §19.1.1). Otherwise
// this returns <0, 0, or >0 based on lexicographic comparison.
//, must treat Strings that are canonically
// equivalent under Unicode NFC as identical (return 0). For example,
// "o\u0308" (o + combining diaeresis) and "ö" (precomposed ö) must
// compare equal even though their UTF-8 byte sequences differ. We
// NFC-normalize both operands via libunicode before the byte-level compare.
fn void builtin_string_proto_localeCompare(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    HString* that_hstr;
    if (ctx.argc > 0) {
        that_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result_undefined(); return; }
    } else {
        that_hstr = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }
    if (that_hstr == null) {
        ctx.result_undefined();
        return;
    }
$if $feat(INTL_COLLATOR):
    coll_locale_compare(ctx, s_hstr, that_hstr);
$else
    // NFC normalize both operands (canonical equivalence), bytes differ
    // but codepoints are equivalent after normalization. Short-circuit
    // byte-equal strings: most compare() calls (localeSort, Intl.Collator
    // fast path, etc.) are on pre-normalized ASCII.
    if (hstring::units_equal(s_hstr, that_hstr)) {
        ctx.result_number(0.0);
        return;
    }

    uint a_n; uint b_n;
    uint* a_src = string_codepoints(s_hstr, &a_n);
    uint* b_src = string_codepoints(that_hstr, &b_n);
    int a_norm_len = 0;
    int b_norm_len = 0;
    uint* a_norm = a_src == null ? null
        : unicode_bindings::unicode_normalize_simple(a_src, (int)a_n, unicode_bindings::UNICODE_NFC, &a_norm_len);
    uint* b_norm = b_src == null ? null
        : unicode_bindings::unicode_normalize_simple(b_src, (int)b_n, unicode_bindings::UNICODE_NFC, &b_norm_len);
    defer {
        if (a_src != null) mem::free(a_src);
        if (b_src != null) mem::free(b_src);
        if (a_norm != null) mem::free(a_norm);
        if (b_norm != null) mem::free(b_norm);
    }

    // If normalization failed, fall back to comparing the code units.
    if (a_norm == null || b_norm == null) {
        ctx.result_number((double)hstring::units_compare(s_hstr, that_hstr));
        return;
    }

    // Compare normalized codepoint arrays
    int min_n = a_norm_len < b_norm_len ? a_norm_len : b_norm_len;
    for (int i = 0; i < min_n; i++) {
        if (a_norm[i] != b_norm[i]) {
            ctx.result_number((double)((int)a_norm[i] - (int)b_norm[i]));
            return;
        }
    }
    ctx.result_number((double)(a_norm_len - b_norm_len));
$endif
}

// String.prototype.trim()
//
// Removes leading and trailing WhiteSpace and LineTerminator characters.
// Must handle the full Unicode range (not just ASCII bytes) including
// multi-byte UTF-8 characters like U+FEFF, U+2028, U+2029, and all
// Unicode Zs (Space_Separator) characters.
fn void builtin_string_proto_trim(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    uint start; uint end;
    ws_trim_bounds(s_hstr, &start, &end);
    ctx.result_string(ctx.heap.str_slice(s_hstr, start, end));
}

// String.prototype.split(separator, limit)
fn void builtin_string_proto_split(BuiltinContext* ctx) {
    // Step 1: Let O be ? RequireObjectCoercible(this value).
    TVal this_tv = ctx.regs[ctx.base_reg - 1];
    if (this_tv.is_undefined() || this_tv.is_null()) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "String.prototype method called on incompatible value");
        return;
    }

    TVal sep_tv; sep_tv.set_undefined();
    if (ctx.argc > 0) sep_tv = ctx.regs[ctx.base_reg];

    // Step 2: If separator is neither undefined nor null, check @@split.
    // Use builtins_generic_get to invoke accessor getters (propagating throws).
    if (!sep_tv.is_null() && !sep_tv.is_undefined()) {
        if (sep_tv.is_object() && sep_tv.get_heapptr() != null) {
            HObject* sep_obj = (HObject*)sep_tv.get_heapptr();
            HString* split_sym = ensure_split_symbol(ctx.heap);
            if (split_sym != null) {
                TVal? splitter_opt = builtins_generic_get(sep_obj, split_sym, ctx);
                if (ctx.should_throw) return;
                if (try splitter = splitter_opt) {
                    if (!splitter.is_undefined() && !splitter.is_null()) {
                        if (splitter.is_lightfunc() ||
                            (splitter.is_object() && splitter.get_heapptr() != null &&
                             ((HObject*)splitter.get_heapptr()).is_callable())) {
                            // Call splitter(O, limit), O is the raw this value (not ToString'd),
                            // limit is the original argument (not coerced).
                            TVal[2] fn_args;
                            fn_args[0] = this_tv;
                            fn_args[1] = (ctx.argc > 1) ? ctx.regs[ctx.base_reg + 1] : (TVal){ };
                            if (ctx.argc <= 1) fn_args[1].set_undefined();
                            TVal splitter_this = sep_tv;
                            TVal res = ctx.heap.call_fn(ctx.vm, splitter, &fn_args[0], 2, splitter_this);
                            if (ctx.heap.has_error) {
                                ctx.should_throw = true;
                                ctx.throw_value = ctx.heap.error_value;
                                ctx.heap.has_error = false;
                                return;
                            }
                            ctx.copy_result(res);
                            return;
                        } else {
                            // GetMethod: non-callable @@split throws TypeError.
                            arr_throw_type_error(ctx, "Symbol.split is not callable");
                            return;
                        }
                    }
                }
            }
        }
    }

    // Step 3: Let S be ? ToString(O).
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }
    uint len = s_hstr.unit_len();

    // Create result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result_undefined();
        return;
    }
    HObject* arr = arr_raw;
    ctx.heap.set_prototype(arr, ctx.heap.array_proto);

    // If separator is undefined, return [string], but the limit=0 case
    // (§22.1.3.21 step 10: if lim = 0, return an empty array) takes precedence.
    if (sep_tv.is_undefined()) {
        bool undef_limit_zero = false;
        if (ctx.argc > 1) {
            TVal lim_arg0 = ctx.regs[ctx.base_reg + 1];
            if (!lim_arg0.is_undefined()) {
                double lim0 = builtin_to_number_vm(ctx, &lim_arg0);
                if (ctx.should_throw) return;
                // ToUint32: NaN/±0/±Inf → 0.
                if (lim0 != lim0 || lim0 == 0.0 || lim0 == double::inf || lim0 == -double::inf) {
                    undef_limit_zero = true;
                } else {
                    double two32u = 4294967296.0;
                    double nu = lim0 - math::floor(lim0 / two32u) * two32u;
                    if (nu < 0.0) nu += two32u;
                    undef_limit_zero = ((uint)nu == 0);
                }
            }
        }
        HString* len_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
        if (undef_limit_zero) {
            TVal len_val0; len_val0.set_fastint(0);
            arr.put_prop(len_key, len_val0, hobject::PROP_FLAGS_WEC, ctx.heap);
            ctx.result_object(arr);
            return;
        }
        TVal elem;
        elem.set_string_borrowed(s_hstr);
        HString* zero_key = ctx.heap.int_to_hstring(0);
        arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC, ctx.heap);
        TVal len_val;
        len_val.set_fastint(1);
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC, ctx.heap);
        ctx.result_object(arr);
        return;
    }

    // For RegExp separator, delegate to @@split on the regexp (which will call
    // RegExp.prototype[@@split]), or fall through to the built-in regexp path.
    // For other separators: step 4 = ToString(separator), must happen before limit=0 check.
    TVal* sep_val = &sep_tv;

    // Compute limit via ToUint32, done here, after the @@split check.
    // spec step 17: If limit is undefined, let lim = 2^32-1; else let lim = ? ToUint32(limit).
    uint limit = 0xFFFFFFFF;  // 2^32 - 1
    {
        TVal limit_arg; limit_arg.set_undefined();
        if (ctx.argc > 1) limit_arg = ctx.regs[ctx.base_reg + 1];
        if (!limit_arg.is_undefined()) {
            double limit_num = builtin_to_number_vm(ctx, &limit_arg);
            if (ctx.should_throw) return;
            if (limit_num != limit_num || limit_num == 0.0 ||
                limit_num == double::inf || limit_num == -double::inf) {
                limit = 0;
            } else {
                double two32 = 4294967296.0;
                double n = limit_num - math::floor(limit_num / two32) * two32;
                if (n < 0.0) n += two32;
                limit = (uint)n;
            }
        }
    }

    // String separator: ToString(separator), must happen before limit=0 check.
    HString* sep_hstr = builtin_to_string_vm(ctx, sep_val);
    if (ctx.should_throw) return;
    if (sep_hstr == null) {
        ctx.result_undefined();
        return;
    }

    // limit=0 check after separator is stringified
    if (limit == 0) {
        TVal len_val; len_val.set_fastint(0);
        HString* len_key0 = ctx.heap.str(heap::BuiltinStr.LENGTH);
        arr.put_prop(len_key0, len_val, hobject::PROP_FLAGS_WEC, ctx.heap);
        ctx.result_object(arr);
        return;
    }

    uint sep_len = sep_hstr.unit_len();

    // Empty separator: split by UTF-16 code unit (ECMA-262 §15.5.4.14 step 11,
    // T is a String of length 1 containing element q of S, where S is
    // indexed by UTF-16 code unit, not Unicode codepoint or byte).
    if (sep_len == 0) {
        uint count = len < limit ? len : limit;
        HString* len_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
        TVal len_val;
        len_val.set_fastint((long)count);
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC, ctx.heap);
        for (uint i = 0; i < count; i++) {
            TVal elem;
            elem.set_string_borrowed(ctx.heap.str_from_unit(s_hstr.unit_at(i)));
            arr.put_prop(ctx.heap.int_to_hstring((long)i), elem, hobject::PROP_FLAGS_WEC, ctx.heap);
        }
        ctx.result_object(arr);
        return;
    }

    // Non-empty separator: split by separator
    uint arr_idx = 0;
    uint search_pos = 0;
    HString* len_key = ctx.heap.str(heap::BuiltinStr.LENGTH);

    while (search_pos + sep_len <= len && arr_idx < limit) {
        int found_pos = hstring::find_units(s_hstr, sep_hstr, search_pos);
        if (found_pos < 0) break;

        HString* substr = ctx.heap.str_slice(s_hstr, search_pos, (uint)found_pos);

        TVal elem;
        elem.set_string_borrowed(substr);
        arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC, ctx.heap);
        arr_idx++;

        search_pos = (uint)(found_pos + (int)sep_len);
    }

    // Add remaining part if not at limit
    if (arr_idx < limit) {
        HString* substr = ctx.heap.str_slice(s_hstr, search_pos, len);
        TVal elem;
        elem.set_string_borrowed(substr);
        arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC, ctx.heap);
        arr_idx++;
    }

    TVal len_val;
    len_val.set_fastint((long)arr_idx);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC, ctx.heap);

    ctx.result_object(arr);
}

// String.prototype.concat(...args)
fn void builtin_string_proto_concat(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }

    StrBuf out;
    out.init(ctx.heap);
    defer out.free();
    out.append_hstring(s_hstr);
    // Coerce each argument in order, as a later argument's conversion may have
    // side effects.
    for (usz i = 0; i < ctx.argc; i++) {
        HString* arg_str = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg + i]);
        if (ctx.should_throw) { ctx.result_undefined(); return; }
        if (arg_str != null) out.append_hstring(arg_str);
    }
    out.finish(ctx);
}

// Append GetSubstitution(`rep`) to `out` for the match
// input[match_start..match_end) of a string search value. That match has no
// captures, so only `$$`, `$&`, `` $` `` and `$'` are special.
fn void string_get_substitution(StrBuf* out, HString* rep, HString* input,
                                uint match_start, uint match_end) {
    uint n = rep.unit_len();
    uint i = 0;
    while (i < n && !out.failed) {
        uint lit = i;
        while (lit < n && rep.unit_at(lit) != '$') lit++;
        if (lit > i) {
            out.append_hstring_range(rep, i, lit);
            i = lit;
            continue;
        }
        switch (i + 1 < n ? rep.unit_at(i + 1) : 0) {
            case '$': out.append_char('$');
            case '&': out.append_hstring_range(input, match_start, match_end);
            case '`': out.append_hstring_range(input, 0, match_start);
            case '\'': out.append_hstring_range(input, match_end, input.unit_len());
            default:
                out.append_char('$');
                i++;
                continue;
        }
        i += 2;
    }
}

fn void builtin_string_proto_replace(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) {
        ctx.result_undefined();
        return;
    }

    if (ctx.argc < 1) {
        ctx.result_string(s_hstr);
        return;
    }

    TVal* search_val = &ctx.regs[ctx.base_reg];

    // Check for @@replace protocol (ECMA-262 §21.1.3.14 step 2).
    // Step 2: If searchValue is neither undefined nor null, GetMethod(searchValue, @@replace).
    // Use builtins_generic_get so accessor/getter properties are invoked (propagating throws).
    if (ctx.argc >= 1 && !search_val.is_null() && !search_val.is_undefined()) {
        if (search_val.is_object() && search_val.get_heapptr() != null) {
            HObject* search_obj = (HObject*)search_val.get_heapptr();
            HString* replace_sym = ensure_replace_symbol(ctx.heap);
            if (replace_sym != null) {
                TVal? replacer_opt = builtins_generic_get(search_obj, replace_sym, ctx);
                if (ctx.should_throw) return;
                if (try replacer = replacer_opt) {
                    if (!replacer.is_undefined() && !replacer.is_null()) {
                        if (replacer.is_lightfunc() ||
                            (replacer.is_object() && replacer.get_heapptr() != null &&
                             ((HObject*)replacer.get_heapptr()).is_callable())) {
                            TVal[2] fn_args;
                            fn_args[0].set_string_borrowed(s_hstr);  // O
                            if (ctx.argc > 1) {
                                fn_args[1] = ctx.regs[ctx.base_reg + 1];  // replaceValue
                            } else {
                                fn_args[1].set_undefined();
                            }
                            TVal this_val = ctx.regs[ctx.base_reg];
                            TVal res = ctx.heap.call_fn(ctx.vm, replacer, &fn_args[0], 2, this_val);
                            if (ctx.heap.has_error) {
                                ctx.should_throw = true;
                                ctx.throw_value = ctx.heap.error_value;
                                ctx.heap.has_error = false;
                                return;
                            }
                            ctx.copy_result(res);
                            return;
                        } else {
                            // GetMethod: if not callable, throw TypeError.
                            arr_throw_type_error(ctx, "Symbol.replace is not callable");
                            return;
                        }
                    }
                }
            }
        }
    }

    // String searchValue.
    // Step 5: Let searchString be ? ToString(searchValue).
    HString* search_hstr = builtin_to_string_vm(ctx, search_val);
    if (ctx.should_throw) return;
    if (search_hstr == null) {
        ctx.result_undefined();
        return;
    }

    // Step 6: Let functionalReplace = IsCallable(replaceValue).
    bool str_replace_is_fn = false;
    TVal replace_val_str; replace_val_str.set_undefined();
    if (ctx.argc > 1) {
        replace_val_str = ctx.regs[ctx.base_reg + 1];
        if (replace_val_str.is_lightfunc()) {
            str_replace_is_fn = true;
        } else if (replace_val_str.is_object() && replace_val_str.get_heapptr() != null &&
                   ((HObject*)replace_val_str.get_heapptr()).is_callable()) {
            str_replace_is_fn = true;
        }
    }

    // Step 7: If !functionalReplace, let replaceValue = ? ToString(replaceValue).
    // This must happen BEFORE searching (spec step 7 precedes step 8).
    HString* replace_str_precomp = null;
    if (!str_replace_is_fn) {
        replace_str_precomp = builtin_to_string_vm(ctx, &replace_val_str);
        if (ctx.should_throw) return;
        if (replace_str_precomp == null) replace_str_precomp = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }

    // Step 8: Search for first occurrence of searchString.
    int found_pos = hstring::find_units(s_hstr, search_hstr, 0);

    if (found_pos < 0) {
        ctx.result_string(s_hstr);
        return;
    }

    StrBuf out;
    out.init(ctx.heap);
    defer out.free();
    uint match_end = (uint)found_pos + search_hstr.unit_len();
    out.append_hstring_range(s_hstr, 0, (uint)found_pos);
    HString* replace_str = replace_str_precomp;
    if (str_replace_is_fn && ctx.heap.call_fn != null && ctx.vm != null) {
        TVal[3] fn_args;
        fn_args[0].set_string_borrowed(ctx.heap.str_slice(s_hstr, (uint)found_pos, match_end));
        fn_args[1].set_fastint((long)found_pos);
        fn_args[2].set_string_borrowed(s_hstr);
        TVal this_val; this_val.set_undefined();
        TVal res = ctx.heap.call_fn(ctx.vm, replace_val_str, &fn_args[0], 3, this_val);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return;
        }
        replace_str = builtin_to_string_vm(ctx, &res);
        if (ctx.should_throw) return;
        if (replace_str == null) replace_str = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }
    string_get_substitution(&out, replace_str, s_hstr, (uint)found_pos, match_end);
    out.append_hstring_range(s_hstr, match_end, s_hstr.unit_len());
    out.finish(ctx);
}

// String.prototype.replaceAll(searchValue, replaceValue)
fn void builtin_string_proto_replaceAll(BuiltinContext* ctx) {
    // Step 1: RequireObjectCoercible(this). We don't ToString the receiver
    // yet, step 2's searchValue checks (IsRegExp, flags, @@replace) must
    // run and can throw or delegate *before* `this` is ever stringified.
    TVal this_tv = ctx.regs[ctx.base_reg - 1];
    if (this_tv.is_undefined() || this_tv.is_null()) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "String.prototype method called on incompatible value");
        return;
    }

    TVal search_val;
    if (ctx.argc >= 1) {
        search_val = ctx.regs[ctx.base_reg];
    } else {
        search_val.set_undefined();
    }

    TVal replace_val;
    if (ctx.argc > 1) {
        replace_val = ctx.regs[ctx.base_reg + 1];
    } else {
        replace_val.set_undefined();
    }

    // Step 2: if searchValue is neither undefined nor null, run the
    // IsRegExp / flags / @@replace-delegation checks before anything else.
    if (!search_val.is_undefined() && !search_val.is_null()) {
        // Step 2.a IsRegExp(searchValue): true iff searchValue is an Object
        // and either has a truthy @@match property, or (when @@match is
        // undefined) has a [[RegExpMatcher]] internal slot.
        bool is_regexp_like = false;
        if (search_val.is_object() && search_val.get_heapptr() != null) {
            HObject* sv_obj = (HObject*)search_val.get_heapptr();
            HString* match_sym = ensure_match_symbol(ctx.heap);
            bool match_seen = false;
            if (match_sym != null) {
                TVal? match_tv_opt = builtins_generic_get(sv_obj, match_sym, ctx);
                if (ctx.should_throw) return;
                if (try mtv = match_tv_opt) {
                    if (!mtv.is_undefined()) {
                        match_seen = true;
                        is_regexp_like = builtin_to_boolean(&mtv, ctx.heap);
                    }
                }
            }
            if (!match_seen) {
                is_regexp_like = is_regexp_object(&search_val);
            }
        }

        if (is_regexp_like) {
            HObject* rx = (HObject*)search_val.get_heapptr();
            // Step 2.b.i: Get(searchValue, "flags").
            TVal? flags_tv_opt = builtins_generic_get(rx, ctx.heap.str(heap::BuiltinStr.FLAGS), ctx);
            if (ctx.should_throw) return;
            HString* flags_hstr = null;
            if (try fv = flags_tv_opt) {
                // Step 2.b.ii: RequireObjectCoercible(flags).
                if (fv.is_undefined() || fv.is_null()) {
                    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
                        "String.prototype.replaceAll: flags is null/undefined");
                    return;
                }
                if (is_symbol_val(fv)) {
                    arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
                    return;
                }
                TVal* fv_ptr = &fv;
                HString* tostr_hstr = builtin_to_string_vm(ctx, fv_ptr);
                if (ctx.should_throw) return;
                if (tostr_hstr == null) {
                    arr_throw_type_error(ctx, "Cannot convert flags to string");
                    return;
                }
                flags_hstr = tostr_hstr;
            } else {
                builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
                    "String.prototype.replaceAll: missing flags");
                return;
            }
            // Step 2.b.iii: flags must contain "g".
            bool has_g = false;
            uint flags_len = flags_hstr.unit_len();
            for (uint i = 0; i < flags_len; i++) {
                if (flags_hstr.unit_at(i) == 'g') { has_g = true; break; }
            }
            if (!has_g) {
                arr_throw_type_error(ctx, "String.prototype.replaceAll called with a non-global regular expression");
                return;
            }
        }

        // Step 2.c: replacer = GetMethod(searchValue, @@replace).
        // Step 2.d: if replacer is not undefined, delegate to it entirely. This
        // happens before ToString(this) and ToString(searchValue), so a
        // poisoned `this` or searchValue whose toString throws never fires.
        if (search_val.is_object() && search_val.get_heapptr() != null) {
            HObject* sv_obj = (HObject*)search_val.get_heapptr();
            HString* replace_sym = ensure_replace_symbol(ctx.heap);
            if (replace_sym != null) {
                TVal? replacer_opt = builtins_generic_get(sv_obj, replace_sym, ctx);
                if (ctx.should_throw) return;
                if (try replacer = replacer_opt) {
                    if (!replacer.is_undefined() && !replacer.is_null()) {
                        bool replacer_callable = replacer.is_lightfunc() ||
                            (replacer.is_object() && replacer.get_heapptr() != null &&
                             ((HObject*)replacer.get_heapptr()).is_callable());
                        if (!replacer_callable) {
                            arr_throw_type_error(ctx, "Symbol.replace method is not callable");
                            return;
                        }
                        TVal[2] fn_args;
                        fn_args[0] = this_tv;         // O, NOT yet ToString'd
                        fn_args[1] = replace_val;     // replaceValue as-is
                        TVal res = ctx.heap.call_fn(ctx.vm, replacer, &fn_args[0], 2, search_val);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                            return;
                        }
                        ctx.copy_result(res);
                        return;
                    }
                }
            }
        }
    }

    // Step 3: string = ToString(O).
    HString* s_hstr = builtin_to_string_vm(ctx, &this_tv);
    if (ctx.should_throw) return;
    if (s_hstr == null) return;
    uint input_len = s_hstr.unit_len();

    // Step 4: searchString = ToString(searchValue).
    if (is_symbol_val(search_val)) {
        arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
        return;
    }
    HString* search_hstr = builtin_to_string_vm(ctx, &search_val);
    if (ctx.should_throw) return;
    if (search_hstr == null) return;
    uint search_len = search_hstr.unit_len();

    // Step 5/6: functionalReplace = IsCallable(replaceValue); otherwise
    // ToString(replaceValue).
    bool functional_replace = replace_val.is_lightfunc() ||
        (replace_val.is_object() && replace_val.get_heapptr() != null &&
         ((HObject*)replace_val.get_heapptr()).is_callable());
    HString* replace_hstr = null;
    if (!functional_replace) {
        if (is_symbol_val(replace_val)) {
            arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
            return;
        }
        replace_hstr = builtin_to_string_vm(ctx, &replace_val);
        if (ctx.should_throw) return;
        if (replace_hstr == null) return;
    }

    // Nonempty searches advance by their length; empty matches advance one code unit.
    uint advance_by = search_len == 0 ? 1 : search_len;

    // Steps 8-11: find all match positions via a StringIndexOf loop, matching
    // left-to-right, non-overlapping, advancing by advanceBy on every step
    // (including empty-string matches).
    StrBuf out;
    out.init(ctx.heap);
    defer out.free();
    uint pos = 0;
    uint last_end = 0;

    while (!out.failed && pos <= input_len) {
        int found = hstring::find_units(s_hstr, search_hstr, pos);
        if (found < 0) break;
        pos = (uint)found;

        // Copy the unmatched prefix since the previous match.
        out.append_hstring_range(s_hstr, last_end, pos);

        // Step 14: compute replacement for this match position.
        if (functional_replace) {
            TVal[3] fn_args;
            fn_args[0].set_string_borrowed(search_hstr);
            fn_args[1].set_fastint((long)pos);
            fn_args[2].set_string_borrowed(s_hstr);
            TVal this_val; this_val.set_undefined();
            TVal res = ctx.heap.call_fn(ctx.vm, replace_val, &fn_args[0], 3, this_val);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return;
            }
            if (is_symbol_val(res)) {
                arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
                return;
            }
            HString* replacement_str = builtin_to_string_vm(ctx, &res);
            if (ctx.should_throw) return;
            if (replacement_str == null) return;
            out.append_hstring(replacement_str);
        } else {
            // GetSubstitution with an always-empty captures list: only
            // $$, $&, $`, and $' are recognized; $N/$NN/$<...> stay literal
            // since there are no captures (num_caps == 0).
            string_get_substitution(&out, replace_hstr, s_hstr, pos, pos + search_len);
        }

        last_end = pos + search_len;
        pos += advance_by;
    }

    // Copy remaining characters after the last match.
    out.append_hstring_range(s_hstr, last_end, input_len);
    out.finish(ctx);
}

// ============================================================================
// Additional String.prototype methods
// ============================================================================

// String.prototype.includes(searchString, position)
fn void builtin_string_proto_includes(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }

    HString* search_hstr;
    if (ctx.argc > 0) {
        // ECMA-262 §21.1.3.7 step 3-6: IsRegExp(searchString) → throw TypeError
        int regexp_check = is_regexp_check_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (regexp_check < 0) { ctx.result_undefined(); return; }
        if (regexp_check == 1) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "First argument to String.prototype.includes must not be a RegExp");
            return;
        }
        search_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result_undefined(); return; }
    } else {
        search_hstr = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }
    if (search_hstr == null) { ctx.result_boolean(false); return; }

    uint clen = s_hstr.unit_len();
    double pos_d = (ctx.argc > 1) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]) : 0.0;
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    uint pos_units;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos_units = 0;
    } else if (pos_d >= (double)clen) {
        pos_units = clen;
    } else {
        pos_units = (uint)(long)pos_d;
    }
    ctx.result_boolean(hstring::find_units(s_hstr, search_hstr, pos_units) >= 0);
}

// String.prototype.startsWith(searchString, position)
fn void builtin_string_proto_startsWith(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }

    HString* search_hstr;
    if (ctx.argc > 0) {
        // ECMA-262 §21.1.3.18 step 3-6: IsRegExp(searchString) → throw TypeError
        int regexp_check = is_regexp_check_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (regexp_check < 0) { ctx.result_undefined(); return; }
        if (regexp_check == 1) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "First argument to String.prototype.startsWith must not be a RegExp");
            return;
        }
        search_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result_undefined(); return; }
    } else {
        search_hstr = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }
    if (search_hstr == null) { ctx.result_boolean(false); return; }

    uint clen = s_hstr.unit_len();
    double pos_d = (ctx.argc > 1) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]) : 0.0;
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    uint pos_units;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos_units = 0;
    } else if (pos_d > (double)clen) {
        pos_units = clen;
    } else {
        pos_units = (uint)(long)pos_d;
    }
    ctx.result_boolean(s_hstr.matches_at(pos_units, search_hstr));
}

// String.prototype.endsWith(searchString, endPosition)
fn void builtin_string_proto_endsWith(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }

    HString* search_hstr;
    if (ctx.argc > 0) {
        // ECMA-262 §21.1.3.6 step 3-6: IsRegExp(searchString) → throw TypeError
        int regexp_check = is_regexp_check_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (regexp_check < 0) { ctx.result_undefined(); return; }
        if (regexp_check == 1) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "First argument to String.prototype.endsWith must not be a RegExp");
            return;
        }
        search_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result_undefined(); return; }
    } else {
        search_hstr = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }
    if (search_hstr == null) { ctx.result_boolean(false); return; }

    uint clen = s_hstr.unit_len();
    double end_d = (ctx.argc > 1) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]) : (double)clen;
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    uint end_units;
    if (math::is_nan(end_d) || end_d < 0) {
        end_units = 0;
    } else if (end_d > (double)clen) {
        end_units = clen;
    } else {
        end_units = (uint)(long)end_d;
    }
    uint search_len = search_hstr.unit_len();
    if (search_len > end_units) { ctx.result_boolean(false); return; }
    ctx.result_boolean(s_hstr.matches_at(end_units - search_len, search_hstr));
}

// String.prototype.repeat(count)
fn void builtin_string_proto_repeat(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }

    // Step 3: ToIntegerOrInfinity(count), runs valueOf/toString and throws for
    // Symbol/BigInt *before* the RangeError range check.
    double count_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    // Step 4: RangeError if count < 0 or count is +∞ (NaN already clamped to 0).
    if (count_d < 0 || math::is_inf(count_d)) {
        // Throw RangeError per ECMA-262 §21.1.3.14 step 4.
        builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid count value");
        return;
    }
    // A zero count, or a receiver with nothing to repeat, yields "" whatever
    // the count is. This has to precede the length check: an empty receiver has
    // a representable result for every finite count, so `"".repeat(2**32)` is
    // "" and not a RangeError. The count stays a double until here, since
    // narrowing it first is what let 2**32 wrap to 0 and 1e10 to 1410065408.
    if (count_d == 0 || s_hstr.unit_len() == 0) {
        HString* empty = ctx.heap.str(heap::BuiltinStr.EMPTY);
        ctx.result_string(empty);
        return;
    }

    // The product is formed in double, which represents every finite count
    // exactly up to 2^53 and saturates rather than wrapping above that, so a
    // count of 2^32 or 1e10 is compared at its true magnitude.
    double total_d = (double)s_hstr.unit_len() * count_d;
    if (total_d > (double)hstring::MAX_STRING_LENGTH) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid string length");
        return;
    }
    ulong count64 = (ulong)count_d;

    StrBuf out;
    out.init(ctx.heap);
    defer out.free();
    for (ulong i = 0; i < count64 && !out.failed; i++) out.append_hstring(s_hstr);
    out.finish(ctx);
}

// String.prototype.trimStart()
fn void builtin_string_proto_trimStart(BuiltinContext* ctx) {
    string_trim_side(ctx, true);
}

// String.prototype.trimEnd()
fn void builtin_string_proto_trimEnd(BuiltinContext* ctx) {
    string_trim_side(ctx, false);
}

// trimStart (`lead`) or trimEnd: the string itself when nothing is removed.
fn void string_trim_side(BuiltinContext* ctx, bool lead) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }
    uint start; uint end;
    ws_trim_bounds(s_hstr, &start, &end, lead, !lead);
    if (start == 0 && end == s_hstr.unit_len()) {
        ctx.result_string(s_hstr);
        return;
    }
    ctx.result_string(ctx.heap.str_slice(s_hstr, start, end));
}

// String.prototype.codePointAt(pos)
//
// Indexed by UTF-16 code unit. If the unit at `pos` is a
// high surrogate and `pos+1` is a low surrogate, combine them into the
// astral codepoint; otherwise return the code unit as-is (matches
// CharCodeAt semantics for non-surrogate / lone-surrogate positions).
fn void builtin_string_proto_codePointAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }
    uint clen = s_hstr.unit_len();

    double pos_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result_undefined(); return; }
    // Reject out-of-range (including +Infinity) before casting: (uint)(long)d
    // is UB for a d past int64/uint range and x86 miscompiles it at -O2.
    // pos >= clen returns undefined anyway, so fold the bound check in here.
    if (math::is_nan(pos_d) || pos_d < 0 || pos_d >= (double)clen) {
        ctx.result_undefined(); return;
    }
    uint pos = (uint)(long)pos_d;

    uint first = s_hstr.unit_at(pos);
    if (hstring::is_high_surrogate(first) && pos + 1 < clen) {
        uint second = s_hstr.unit_at(pos + 1);
        if (hstring::is_low_surrogate(second)) {
            ctx.result_fastint((long)hstring::surrogates_to_codepoint(first, second));
            return;
        }
    }
    ctx.result_fastint((long)first);
}

// String.prototype.at(index)
//
// Indexed by UTF-16 code unit; returns a one-code-unit String (a lone
// surrogate half for astral characters), matching `charAt`.
fn void builtin_string_proto_at(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }
    uint clen = s_hstr.unit_len();

    // Step 4: ToIntegerOrInfinity(index), coerces via valueOf/toString, NaN→0.
    double idx_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result_undefined(); return; }

    long idx = (long)idx_d;
    if (idx < 0) { idx = (long)clen + idx; }
    if (idx < 0 || idx >= (long)clen) { ctx.result_undefined(); return; }

    ctx.result_string(ctx.heap.str_from_unit(s_hstr.unit_at((uint)idx)));
}

// Truncate fills at UTF-16 code-unit boundaries, preserving lone surrogates.
macro void @string_pad(BuiltinContext* ctx, $at_start) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }

    double max_len_d = (ctx.argc > 0) ? builtin_to_number_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(max_len_d) || max_len_d < 0) { max_len_d = 0; }
    if (max_len_d > 4294967295.0) max_len_d = 4294967295.0;
    uint max_len = (uint)(long)max_len_d;

    uint str_units = s_hstr.unit_len();
    if (str_units >= max_len) {
        ctx.result_string(s_hstr); return;
    }

    HString* fill_hstr;
    if (ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
        fill_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
    } else {
        fill_hstr = builtin_intern_string(ctx.heap, " ");
    }
    if (fill_hstr == null || fill_hstr.unit_len() == 0) {
        ctx.result_string(s_hstr); return;
    }

    // maxLength is caller-controlled up to 2^32, so check it against the cap
    // before building anything.
    if (hstring::length_exceeds_max((ulong)max_len)) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid string length");
        return;
    }
    StrBuf out;
    out.init(ctx.heap);
    defer out.free();
    if (!$at_start) out.append_hstring(s_hstr);
    uint fill_len = fill_hstr.unit_len();
    uint remaining = max_len - str_units;
    while (remaining >= fill_len && !out.failed) {
        out.append_hstring(fill_hstr);
        remaining -= fill_len;
    }
    out.append_hstring_range(fill_hstr, 0, remaining);
    if ($at_start) out.append_hstring(s_hstr);
    out.finish(ctx);
}

fn void builtin_string_proto_padStart(BuiltinContext* ctx) => @string_pad(ctx, true);
fn void builtin_string_proto_padEnd(BuiltinContext* ctx) => @string_pad(ctx, false);

// String.prototype.lastIndexOf(searchString, position)
fn void builtin_string_proto_lastIndexOf(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }
    uint clen = s_hstr.unit_len();

    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result_undefined(); return; }
    } else {
        search_hstr = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
    }
    if (search_hstr == null) { ctx.result_fastint(-1); return; }

    // Step 4-6: numPos = ToNumber(position); NaN → +∞ (i.e. search from the very
    // end), otherwise ToIntegerOrInfinity. ToNumber runs valueOf and may throw
    //.
    double pos_d;
    if (ctx.argc > 1) {
        double num_pos = builtin_to_number_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
        if (ctx.should_throw) { ctx.result_undefined(); return; }
        pos_d = math::is_nan(num_pos) ? (double)clen : num_pos;
    } else {
        pos_d = (double)clen;
    }
    if (pos_d < 0) { pos_d = 0; }
    if (pos_d > (double)clen) { pos_d = (double)clen; }
    // For lastIndexOf, search from min(pos, clen) backwards, in code units.
    int start_units = (int)(long)pos_d;
    if (start_units > (int)clen) start_units = (int)clen;
    ctx.result_fastint((long)hstring::rfind_units(s_hstr, search_hstr, (uint)start_units));
}

// Helper: invoke @@match on an HObject `rx` with string argument `s_hstr`.
// Looks up the @@match method on rx's prototype chain and calls it.
// Returns false if no callable @@match was found (caller should handle fallback).
fn bool invoke_regexp_match(BuiltinContext* ctx, HObject* rx, HString* s_hstr) {
    HString* match_sym = ensure_match_symbol(ctx.heap);
    if (match_sym == null) return false;
    TVal? matcher_opt = rx.get_prop_proto(match_sym, ctx.heap);
    if (try matcher = matcher_opt) {
        if (matcher.is_lightfunc() ||
            (matcher.is_object() && matcher.get_heapptr() != null &&
             ((HObject*)matcher.get_heapptr()).is_callable())) {
            TVal[1] args;
            args[0].set_string_borrowed(s_hstr);
            TVal this_val; this_val.set_object(rx);
            TVal res = ctx.heap.call_fn(ctx.vm, matcher, &args[0], 1, this_val);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return true;
            }
            ctx.copy_result(res);
            return true;
        }
    }
    return false;
}

// String.prototype.match(regexp)
//
// Step 2: If regexp is an object, GetMethod(regexp, @@match); if callable,
// invoke and return. (GetMethod returns undefined for null/undefined @@match.)
// Steps 3-4: Create RegExpCreate(regexp, undefined) and Invoke(rx, @@match, [S]).
fn void builtin_string_proto_match(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }

    TVal* regexp_arg = (ctx.argc > 0) ? &ctx.regs[ctx.base_reg] : null;
    bool arg_nullish = (regexp_arg == null)
        || regexp_arg.is_null() || regexp_arg.is_undefined();

    // Step 2: If regexp is neither undefined nor null, check @@match.
    if (!arg_nullish && regexp_arg.is_object() && regexp_arg.get_heapptr() != null) {
        HObject* arg_obj = (HObject*)regexp_arg.get_heapptr();
        HString* match_sym = ensure_match_symbol(ctx.heap);
        if (match_sym != null) {
            TVal? matcher_opt = builtins_generic_get(arg_obj, match_sym, ctx);
            if (ctx.should_throw) { ctx.result_undefined(); return; }
            if (try matcher = matcher_opt) {
                // GetMethod: if null or undefined, treat as not found and fall through.
                if (!matcher.is_undefined() && !matcher.is_null()) {
                    if (matcher.is_lightfunc() ||
                        (matcher.is_object() && matcher.get_heapptr() != null &&
                         ((HObject*)matcher.get_heapptr()).is_callable())) {
                        TVal[1] args;
                        args[0].set_string_borrowed(s_hstr);
                        TVal this_val = *regexp_arg;
                        TVal res = ctx.heap.call_fn(ctx.vm, matcher, &args[0], 1, this_val);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                        }
                        if (ctx.should_throw) { ctx.result_undefined(); return; }
                        ctx.copy_result(res);
                        return;
                    } else {
                        // GetMethod: if not callable, throw TypeError.
                        arr_throw_type_error(ctx, "Symbol.match is not callable");
                        ctx.result_undefined();
                        return;
                    }
                }
            }
        }
    }

    // Steps 3-4: Let rx = RegExpCreate(regexp, undefined); return Invoke(rx, @@match, [S]).
    // ToString the pattern: null → "null", undefined/missing → "", anything else → ToString.
    if (!arg_nullish) {
        if (regexp_arg.is_string()) {
            HString* ps = (HString*)regexp_arg.get_heapptr();
            if (ps != null && !ps.is_symbol()) {
                // Use the string directly as the pattern.
                HObject* rx = create_regexp_from_string(ctx.heap, ps, 0);
                if (rx == null) { ctx.result_null(); return; }
                if (!invoke_regexp_match(ctx, rx, s_hstr)) { ctx.result_null(); }
                return;
            }
        }
        // For objects whose @@match is null/undefined, convert to string (via toString)
        // then create a RegExp from that string.
        HString* pat_str;
        if (regexp_arg.is_object()) {
            pat_str = builtin_to_string_vm(ctx, regexp_arg);
            if (ctx.should_throw) { ctx.result_undefined(); return; }
        } else {
            pat_str = builtin_to_string(ctx.heap, regexp_arg);
        }
        if (pat_str == null) { ctx.result_null(); return; }
        HObject* rx = create_regexp_from_string(ctx.heap, pat_str, 0);
        if (rx == null) { ctx.result_null(); return; }
        if (!invoke_regexp_match(ctx, rx, s_hstr)) { ctx.result_null(); }
        return;
    } else {
        // arg is missing/null/undefined → RegExpCreate("" or "null") then @@match.
        bool is_null_arg = regexp_arg != null && regexp_arg.is_null();
        HString* empty_pat = is_null_arg ? ctx.heap.str_intern("null") : ctx.heap.str(heap::BuiltinStr.EMPTY);
        HObject* rx = create_regexp_from_string(ctx.heap, empty_pat, 0);
        if (rx == null) { ctx.result_null(); return; }
        if (!invoke_regexp_match(ctx, rx, s_hstr)) { ctx.result_null(); }
        return;
    }
}


// Helper: invoke @@matchAll on `rx` with string `s_hstr` as argument.
// Throws TypeError if @@matchAll is not callable (per spec Invoke semantics).
// Returns true if the call was attempted (result set); false on TypeError thrown.
fn bool invoke_regexp_matchall(BuiltinContext* ctx, HObject* rx, HString* s_hstr) {
    HString* matchall_sym = ensure_matchall_symbol(ctx.heap);
    if (matchall_sym == null) return false;
    // Use get_prop_proto so accessor getters on the prototype chain are NOT invoked
    // (we need the raw property lookup first; actual invoke via call_fn handles the call).
    // For @@matchAll on created rx (steps 4-5), use proto-chain lookup.
    TVal? matcher_opt = rx.get_prop_proto(matchall_sym, ctx.heap);
    if (try matcher = matcher_opt) {
        if (matcher.is_lightfunc() ||
            (matcher.is_object() && matcher.get_heapptr() != null &&
             ((HObject*)matcher.get_heapptr()).is_callable())) {
            TVal[1] args;
            args[0].set_string_borrowed(s_hstr);
            TVal this_val; this_val.set_object(rx);
            TVal res = ctx.heap.call_fn(ctx.vm, matcher, &args[0], 1, this_val);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
            }
            if (ctx.should_throw) { ctx.result_undefined(); return true; }
            ctx.copy_result(res);
            return true;
        }
    }
    // @@matchAll not found or not callable → TypeError (Invoke requires callable).
    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
        "RegExp[Symbol.matchAll] is not a function");
    return false;
}

// String.prototype.matchAll(regexp)
//
// Step 2: IsRegExp check + Get("flags") + "g" check; then GetMethod(@@matchAll)
// delegation for any non-null/undefined argument. Steps 3-5: RegExpCreate with "g"
// flag + Invoke(@@matchAll) on the result.
fn void builtin_string_proto_matchAll(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }

    TVal* regexp_arg = (ctx.argc > 0) ? &ctx.regs[ctx.base_reg] : null;
    bool arg_nullish = (regexp_arg == null)
        || regexp_arg.is_null() || regexp_arg.is_undefined();

    // Step 2: If regexp is neither undefined nor null …
    if (!arg_nullish && regexp_arg.is_object() && regexp_arg.get_heapptr() != null) {
        HObject* arg_obj = (HObject*)regexp_arg.get_heapptr();

        // Step 2a: isRegExp = IsRegExp(regexp).
        // IsRegExp: @@match property is truthy, or object has [[RegExpMatcher]].
        bool is_regexp_like = false;
        HString* match_sym = ensure_match_symbol(heap);
        bool match_sym_seen = false;
        if (match_sym != null) {
            TVal? match_tv_opt = builtins_generic_get(arg_obj, match_sym, ctx);
            if (ctx.should_throw) { ctx.result_undefined(); return; }
            if (try mtv = match_tv_opt) {
                if (!mtv.is_undefined()) {
                    match_sym_seen = true;
                    is_regexp_like = builtin_to_boolean(&mtv, ctx.heap);
                }
            }
        }
        if (!match_sym_seen) {
            is_regexp_like = is_regexp_object(regexp_arg);
        }

        // Step 2b: If isRegExp, Get("flags") and verify it contains "g".
        if (is_regexp_like) {
            HString* flags_key = heap.str(heap::BuiltinStr.FLAGS);
            TVal? flags_tv_opt = builtins_generic_get(arg_obj, flags_key, ctx);
            if (ctx.should_throw) { ctx.result_undefined(); return; }
            HString* flags_hstr = null;
            if (try fv = flags_tv_opt) {
                // RequireObjectCoercible(flags): undefined → TypeError.
                if (fv.is_undefined() || fv.is_null()) {
                    builtin_throw_no_result_change(ctx, heap.type_err_proto,
                        "String.prototype.matchAll: flags is null/undefined");
                    ctx.result_undefined();
                    return;
                }
                if (is_symbol_val(fv)) {
                    arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
                    ctx.result_undefined();
                    return;
                }
                TVal* fv_ptr = &fv;
                flags_hstr = builtin_to_string_vm(ctx, fv_ptr);
                if (ctx.should_throw) { ctx.result_undefined(); return; }
            } else {
                builtin_throw_no_result_change(ctx, heap.type_err_proto,
                    "String.prototype.matchAll: missing flags property");
                ctx.result_undefined();
                return;
            }
            // Check that flags string contains "g".
            bool has_g = false;
            if (flags_hstr != null) {
                uint flen = flags_hstr.unit_len();
                for (uint i = 0; i < flen; i++) {
                    if (flags_hstr.unit_at(i) == 'g') { has_g = true; break; }
                }
            }
            if (!has_g) {
                arr_throw_type_error(ctx,
                    "String.prototype.matchAll called with a non-global regular expression");
                ctx.result_undefined();
                return;
            }
        }

        // Step 2c: matcher = GetMethod(regexp, @@matchAll).
        HString* matchall_sym = ensure_matchall_symbol(heap);
        if (matchall_sym != null) {
            TVal? matcher_opt = builtins_generic_get(arg_obj, matchall_sym, ctx);
            if (ctx.should_throw) { ctx.result_undefined(); return; }
            if (try matcher = matcher_opt) {
                // GetMethod: null or undefined → treat as not found, fall through.
                if (!matcher.is_undefined() && !matcher.is_null()) {
                    if (matcher.is_lightfunc() ||
                        (matcher.is_object() && matcher.get_heapptr() != null &&
                         ((HObject*)matcher.get_heapptr()).is_callable())) {
                        TVal[1] args;
                        args[0].set_string_borrowed(s_hstr);
                        TVal this_val = *regexp_arg;
                        TVal res = ctx.heap.call_fn(ctx.vm, matcher, &args[0], 1, this_val);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                        }
                        if (ctx.should_throw) { ctx.result_undefined(); return; }
                        ctx.copy_result(res);
                        return;
                    }
                    // matcher found but not callable → TypeError.
                    arr_throw_type_error(ctx, "regexp[Symbol.matchAll] is not a function");
                    ctx.result_undefined();
                    return;
                }
            }
        }
    }

    // Steps 3-5: S = ToString(O) [done], rx = RegExpCreate(regexp, "g"),
    //            Return Invoke(rx, @@matchAll, [S]).
    // Pattern: null → "null", missing/undefined → "" (empty), string → use directly,
    //          non-string non-null non-undefined → ToString.
    if (!arg_nullish) {
        if (regexp_arg.is_string()) {
            HString* ps = (HString*)regexp_arg.get_heapptr();
            if (ps != null && !ps.is_symbol()) {
                HObject* rx = create_regexp_from_string(heap, ps, 1);
                if (rx == null) { ctx.result_undefined(); return; }
                invoke_regexp_matchall(ctx, rx, s_hstr);
                return;
            }
        }
        // Objects whose @@matchAll is null/undefined: stringify the object then RegExpCreate.
        HString* pat_str;
        if (regexp_arg.is_object()) {
            pat_str = builtin_to_string_vm(ctx, regexp_arg);
            if (ctx.should_throw) { ctx.result_undefined(); return; }
        } else {
            pat_str = builtin_to_string(heap, regexp_arg);
        }
        if (pat_str == null) { ctx.result_undefined(); return; }
        HObject* rx = create_regexp_from_string(heap, pat_str, 1);
        if (rx == null) { ctx.result_undefined(); return; }
        invoke_regexp_matchall(ctx, rx, s_hstr);
        return;
    } else {
        // arg is null → pattern "null"; arg is missing/undefined → pattern "".
        bool is_null_arg = regexp_arg != null && regexp_arg.is_null();
        HString* empty_pat = is_null_arg ? heap.str_intern("null") : heap.str(heap::BuiltinStr.EMPTY);
        HObject* rx = create_regexp_from_string(heap, empty_pat, 1);
        if (rx == null) { ctx.result_undefined(); return; }
        invoke_regexp_matchall(ctx, rx, s_hstr);
        return;
    }
}

// String.prototype.normalize([form])
//
// Supports NFC, NFD, NFKC and NFKD via libunicode.
fn void builtin_string_proto_normalize(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }

    // Default form: NFC
    int n_type = unicode_bindings::UNICODE_NFC;

    // Process form argument (ECMA-262 §21.1.3.12 steps 3-5)
    // If form is not provided or is undefined, default to NFC.
    if (ctx.argc > 0 && !ctx.regs[ctx.base_reg].is_undefined()) {
        HString* form = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result_undefined(); return; }
        if (form != null) {
            bool valid = form.is_ascii();
            char[] f = valid ? form.ascii_bytes() : (char[])"";
            if (f == "NFC") {
                n_type = unicode_bindings::UNICODE_NFC;
            } else if (f == "NFD") {
                n_type = unicode_bindings::UNICODE_NFD;
            } else if (f == "NFKC") {
                n_type = unicode_bindings::UNICODE_NFKC;
            } else if (f == "NFKD") {
                n_type = unicode_bindings::UNICODE_NFKD;
            } else {
                valid = false;
            }
            if (!valid) {
                // Throw RangeError for invalid form
                builtin_throw(ctx, ctx.heap.range_err_proto, "The normalization form should be one of NFC, NFD, NFKC, NFKD.");
                return;
            }
        }
    }

    // Empty string fast path
    if (s_hstr.unit_len() == 0) {
        ctx.result_string(s_hstr);
        return;
    }

    uint num_cps;
    uint* src_cps = string_codepoints(s_hstr, &num_cps);
    if (src_cps == null) {
        ctx.result_string(s_hstr);
        return;
    }

    int out_len = 0;
    uint* result_cps = unicode_bindings::unicode_normalize_simple(src_cps,
                        (int)num_cps, n_type, &out_len);
    mem::free(src_cps);

    if (result_cps == null || out_len < 0) {
        if (result_cps != null) mem::free(result_cps);
        ctx.result_string(s_hstr);
        return;
    }

    HString* result_hstr = codepoints_to_hstring(ctx.heap, result_cps, (uint)out_len);
    mem::free(result_cps);
    ctx.result_string(result_hstr != null ? result_hstr : s_hstr);
}

// ============================================================================
// String.prototype.isWellFormed / toWellFormed
// ============================================================================
//
// Both methods operate on the UTF-16 code-unit view of the string. A lone
// surrogate is:
//   - a high surrogate (0xD800-0xDBFF) NOT immediately followed by a low
//     surrogate (0xDC00-0xDFFF), OR
//   - a low surrogate that is not the second unit of such a pair.

// String.prototype.isWellFormed()
// Returns true iff the string's UTF-16 code-unit sequence contains no lone
// (unpaired) surrogate code units.
fn void builtin_string_proto_isWellFormed(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }

    ctx.result_boolean(s_hstr.is_well_formed());
}

// String.prototype.toWellFormed()
// Returns a copy of the string with every lone surrogate code unit replaced
// by U+FFFD (REPLACEMENT CHARACTER, UTF-8: 0xEF 0xBF 0xBD).
fn void builtin_string_proto_toWellFormed(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }

    if (s_hstr.is_well_formed()) {
        ctx.result_string(s_hstr);
        return;
    }
    StrBuf out;
    out.init(ctx.heap);
    defer out.free();
    uint len = s_hstr.unit_len();
    for (uint i = 0; i < len; i++) {
        uint u = s_hstr.unit_at(i);
        if (hstring::is_high_surrogate(u) && i + 1 < len && hstring::is_low_surrogate(s_hstr.unit_at(i + 1))) {
            out.append_unit(u);
            u = s_hstr.unit_at(++i);
        } else if (hstring::is_surrogate(u)) {
            u = hstring::UNICODE_REPLACEMENT;
        }
        out.append_unit(u);
    }
    out.finish(ctx);
}

// Helper: invoke @@search on `rx` with string `s_hstr` as argument.
// Returns false if no callable @@search found on the prototype chain.
fn bool invoke_regexp_search(BuiltinContext* ctx, HObject* rx, HString* s_hstr) {
    HString* search_sym = ensure_search_symbol(ctx.heap);
    if (search_sym == null) return false;
    TVal? searcher_opt = rx.get_prop_proto(search_sym, ctx.heap);
    if (try searcher = searcher_opt) {
        if (searcher.is_lightfunc() ||
            (searcher.is_object() && searcher.get_heapptr() != null &&
             ((HObject*)searcher.get_heapptr()).is_callable())) {
            TVal[1] args;
            args[0].set_string_borrowed(s_hstr);
            TVal this_val; this_val.set_object(rx);
            TVal res = ctx.heap.call_fn(ctx.vm, searcher, &args[0], 1, this_val);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
            }
            if (ctx.should_throw) { ctx.result_undefined(); return true; }
            ctx.copy_result(res);
            return true;
        }
    }
    return false;
}

// String.prototype.search(regexp)
//
// Step 2: If regexp is an object, GetMethod(regexp, @@search); if callable,
// invoke and return. (null/undefined @@search treated as "not found" per GetMethod.)
// Steps 3-4: Create RegExpCreate(regexp, undefined) and Invoke(rx, @@search, [S]).
fn void builtin_string_proto_search(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    StringRef receiver = hstring::string_ref(s_hstr);
    defer receiver.release(ctx.heap);
    if (s_hstr == null) { ctx.result_undefined(); return; }

    TVal* regexp_arg = (ctx.argc > 0) ? &ctx.regs[ctx.base_reg] : null;
    bool arg_nullish = (regexp_arg == null)
        || regexp_arg.is_null() || regexp_arg.is_undefined();

    // Step 2: If regexp is neither undefined nor null, check @@search.
    if (!arg_nullish && regexp_arg.is_object() && regexp_arg.get_heapptr() != null) {
        HObject* arg_obj = (HObject*)regexp_arg.get_heapptr();
        HString* search_sym = ensure_search_symbol(ctx.heap);
        if (search_sym != null) {
            TVal? searcher_opt = builtins_generic_get(arg_obj, search_sym, ctx);
            if (ctx.should_throw) { ctx.result_undefined(); return; }
            if (try searcher = searcher_opt) {
                // GetMethod: null or undefined → treat as not found, fall through.
                if (!searcher.is_undefined() && !searcher.is_null()) {
                    if (searcher.is_lightfunc() ||
                        (searcher.is_object() && searcher.get_heapptr() != null &&
                         ((HObject*)searcher.get_heapptr()).is_callable())) {
                        TVal[1] args;
                        args[0].set_string_borrowed(s_hstr);
                        TVal this_val = *regexp_arg;
                        TVal res = ctx.heap.call_fn(ctx.vm, searcher, &args[0], 1, this_val);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                        }
                        if (ctx.should_throw) { ctx.result_undefined(); return; }
                        ctx.copy_result(res);
                        return;
                    } else {
                        // GetMethod: if not callable, throw TypeError.
                        arr_throw_type_error(ctx, "Symbol.search is not callable");
                        ctx.result_undefined();
                        return;
                    }
                }
            }
        }
    }

    // Steps 3-4: RegExpCreate(regexp, undefined) then Invoke(rx, @@search, [S]).
    // For missing/null/undefined arg use empty pattern string (undefined) or "null".
    if (!arg_nullish) {
        if (regexp_arg.is_string()) {
            HString* ps = (HString*)regexp_arg.get_heapptr();
            if (ps != null && !ps.is_symbol()) {
                HObject* rx = create_regexp_from_string(ctx.heap, ps, 0);
                if (rx == null) { ctx.result_fastint(-1); return; }
                if (!invoke_regexp_search(ctx, rx, s_hstr)) { ctx.result_fastint(-1); }
                return;
            }
        }
        // For objects whose @@search is null/undefined, stringify and create RegExp.
        HString* pat_str;
        if (regexp_arg.is_object()) {
            pat_str = builtin_to_string_vm(ctx, regexp_arg);
            if (ctx.should_throw) { ctx.result_undefined(); return; }
        } else {
            pat_str = builtin_to_string(ctx.heap, regexp_arg);
        }
        if (pat_str == null) { ctx.result_fastint(-1); return; }
        HObject* rx = create_regexp_from_string(ctx.heap, pat_str, 0);
        if (rx == null) { ctx.result_fastint(-1); return; }
        if (!invoke_regexp_search(ctx, rx, s_hstr)) { ctx.result_fastint(-1); }
        return;
    } else {
        // arg is missing/null/undefined → pattern "" or "null"
        bool is_null_arg = regexp_arg != null && regexp_arg.is_null();
        HString* empty_pat = is_null_arg ? ctx.heap.str_intern("null") : ctx.heap.str(heap::BuiltinStr.EMPTY);
        HObject* rx = create_regexp_from_string(ctx.heap, empty_pat, 0);
        if (rx == null) { ctx.result_fastint(-1); return; }
        if (!invoke_regexp_search(ctx, rx, s_hstr)) { ctx.result_fastint(-1); }
        return;
    }
}
fn bool register_string_constructor(EnvRecord* global_env, Heap* heap) {
    // Create String.prototype, an exotic String object with [[StringData]] = ""
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.STRING);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    // Set [[StringData]] to "" so valueOf/toString work on String.prototype itself.
    HString* empty_str = heap.str(heap::BuiltinStr.EMPTY);
    if (empty_str != null) {
        (*proto.extra_ptr()).prim.primitive_value.set_string(empty_str);
    }
    // String.prototype is a String exotic object, so it carries its own
    // `length` data property (= 0 for the empty [[StringData]]), non-writable,
    // non-enumerable, non-configurable (ECMA-262).
    HString* proto_len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal proto_len_tv;
    proto_len_tv.set_fastint(0);
    proto.put_prop(proto_len_key, proto_len_tv, hobject::PROP_FLAGS_NNC, heap);
    heap.set_prototype(proto, heap.object_proto);
    heap.string_proto = proto;

    // Add.toString() method
    HString* tostring_key = (HString*)heap.strs[heap::BuiltinStr.TO_STRING];
    TVal tostring_tv;
    tostring_tv.set_builtin(heap, Builtin.STRING_PROTO_TOSTRING.ordinal);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC, heap);

    // Add.valueOf() method
    HString* valueof_key = (HString*)heap.strs[heap::BuiltinStr.VALUE_OF];
    TVal valueof_tv;
    valueof_tv.set_builtin(heap, Builtin.STRING_PROTO_VALUEOF.ordinal);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC, heap);

    {
        const uint[*] METHODS = {
            Builtin.STRING_PROTO_CHARAT.ordinal,
            Builtin.STRING_PROTO_CHARCODEAT.ordinal,
            Builtin.STRING_PROTO_INDEXOF.ordinal,
            Builtin.STRING_PROTO_SLICE.ordinal,
            Builtin.STRING_PROTO_SUBSTRING.ordinal,
            Builtin.STRING_PROTO_SUBSTR.ordinal,
            Builtin.STRING_PROTO_TOLOWERCASE.ordinal,
            Builtin.STRING_PROTO_TOUPPERCASE.ordinal,
            Builtin.STRING_PROTO_TRIM.ordinal,
            Builtin.STRING_PROTO_SPLIT.ordinal,
            Builtin.STRING_PROTO_CONCAT.ordinal,
            Builtin.STRING_PROTO_REPLACE.ordinal,
            Builtin.STRING_PROTO_REPLACEALL.ordinal,
            Builtin.STRING_PROTO_INCLUDES.ordinal,
            Builtin.STRING_PROTO_STARTSWITH.ordinal,
            Builtin.STRING_PROTO_ENDSWITH.ordinal,
            Builtin.STRING_PROTO_REPEAT.ordinal,
            Builtin.STRING_PROTO_TRIMSTART.ordinal,
            Builtin.STRING_PROTO_TRIMEND.ordinal,
        };
        if (!register_builtin_members(proto, heap, METHODS[..])) return false;
    }
    $if features::EXTENDED_BUILTINS:
        // Annex B-15: trimLeft/trimRight are the *same function objects*
        // as trimStart/trimEnd, so they keep those names.
        if (!alias_proto_method(proto, heap, "trimStart", "trimLeft"))  return false;
        if (!alias_proto_method(proto, heap, "trimEnd",   "trimRight")) return false;
    $endif
    {
        const uint[*] METHODS = {
            Builtin.STRING_PROTO_CODEPOINTAT.ordinal,
            Builtin.STRING_PROTO_AT.ordinal,
            Builtin.STRING_PROTO_PADSTART.ordinal,
            Builtin.STRING_PROTO_PADEND.ordinal,
            Builtin.STRING_PROTO_LASTINDEXOF.ordinal,
            Builtin.STRING_PROTO_MATCH.ordinal,
            Builtin.STRING_PROTO_MATCHALL.ordinal,
            Builtin.STRING_PROTO_SEARCH.ordinal,
            Builtin.STRING_PROTO_TOLOCALELOWERCASE.ordinal,
            Builtin.STRING_PROTO_TOLOCALEUPPERCASE.ordinal,
            Builtin.STRING_PROTO_LOCALECOMPARE.ordinal,
            Builtin.STRING_PROTO_NORMALIZE.ordinal,
            Builtin.STRING_PROTO_ISWELLFORMED.ordinal,
            Builtin.STRING_PROTO_TOWELLFORMED.ordinal,
        };
        if (!register_builtin_members(proto, heap, METHODS[..])) return false;
    }

    // Register String.prototype[@@iterator]
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        if (iter_sym != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.STRING_PROTO_SYMBOL_ITER.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.flags.constructable = false;
            heap.set_prototype(fn_obj, heap.function_proto);
            HString* name_key = heap.str(heap::BuiltinStr.NAME);
            HString* name_val = builtin_intern_string(heap, "[Symbol.iterator]");
            if (name_key != null && name_val != null) {
                TVal name_tv;
                name_tv.set_string_borrowed(name_val);
                fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC, heap);
            }
            HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            if (len_key != null) {
                TVal len_tv;
                len_tv.set_fastint(0);
                fn_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC, heap);
            }
            TVal iter_tv;
            iter_tv.set_object(fn_obj);
            proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_WC, heap);
        }
    }

    // Create String constructor as a proper function object (not LIGHTFUNC)
    // so it can carry static methods like String.fromCharCode.
    HObject*? str_obj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = str_obj_raw) return false;
    HObject* str_obj = str_obj_raw;
    (*str_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.STRING.ordinal;

    // Set.constructor on String.prototype to point to the actual String object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(str_obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    // Set String.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    str_obj.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    {
        const uint[*] METHODS = {
            Builtin.STRING_FROMCHARCODE.ordinal,
            Builtin.STRING_FROMCODEPOINT.ordinal,
            Builtin.STRING_RAW.ordinal,
        };
        if (!register_builtin_members(str_obj, heap, METHODS[..])) return false;
    }

    // Register String constructor globally as an OBJECT (not LIGHTFUNC)
    HString* str_key = heap.str_intern("String");
    if (str_key == null) return false;
    TVal str_val;
    str_val.set_object(str_obj);
    set_func_ctor_name_length(str_obj, heap, "String", 1);
    env::env_declare_nonenum(global_env, str_key, str_val);

    return true;
}

// Helper: register a method on a prototype as a proper HObject function.
