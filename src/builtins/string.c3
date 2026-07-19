/// String constructor and String.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::env;
import std::math;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::re_bindings;
import duktape::unicode_bindings;
import duktape::vm;

// ============================================================================
// String constructor builtins
// ============================================================================

/// Populate indexed character properties on a String wrapper object (ES5 §15.5.5.1).
/// Each character position becomes a non-writable, enumerable, non-configurable own property.
fn void populate_string_indexed_props(HObject* obj, HString* s, Heap* heap) {
    for (uint i = 0; i < s.char_length(); i++) {
        HString* key = heap.int_to_hstring((long)i);
        if (key == null) continue;
        uint cp = s.char_at(i);
        char[4] cbuf;
        uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
        HString* char_str = heap.str_intern(cbuf[:cblen]);
        if (char_str == null) continue;
        TVal char_tv;
        char_tv.set_string(char_str);
        obj.put_prop(key, char_tv, hobject::PROP_FLAGS_NEC);
    }
}

/// ToString then return string primitive (function call) or
/// a String wrapper object (constructor call).
fn void builtin_string(BuiltinContext* ctx) {
    HString* s;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        // Per ES2019+ §7.1.12, ToString(symbol) wraps as "Symbol(description)".
        // builtin_to_string_vm leaves symbol HString unchanged; wrap explicitly here.
        if (arg.is_string()) {
            HString* hs = (HString*)arg.get_heapptr();
            if (hs != null && hs.is_symbol()) {
                s = builtin_to_string(ctx.heap, arg);
                if (s == null) {
                    // Should never happen: builtin_to_string never fails for symbol storage
                    ctx.result.set_undefined();
                    return;
                }
            } else {
                s = hs;
            }
        } else {
            s = builtin_to_string_vm(ctx, arg);
            if (s == null) {
                // Caller already has ctx.should_throw set if applicable.
                ctx.result.set_undefined();
                return;
            }
        }
    } else {
        s = builtin_intern_string(ctx.heap, "");
    }

    if (ctx.is_constructor) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.flags.exotic_stringobj = true;
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.string_proto);
        (*obj.extra_ptr()).prim.primitive_value.set_string(s);
        // Set .length own property (ES5 §15.5.5.1) — non-writable, non-enumerable, non-configurable
        HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)s.char_length());
        obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
        // Indexed character properties are served lazily via the exotic_stringobj flag;
        // no per-character own properties are materialised at construction time.
        ctx.result.set_object(obj);
    } else {
        ctx.result.set_string(s);
    }
}

/// ToUint16 abstract operation (ES5 §9.7).
/// 1. Let number be ? ToNumber(argument).
/// 2. If number is NaN, +0, -0, +∞, or -∞, return +0.
/// 3. Let int = truncate(number).
/// 4. Let int16bit be int modulo 2^16 (always non-negative).
/// 5. Return int16bit.
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

/// String.fromCharCode (ES5 §15.5.3.2)
fn void builtin_string_fromcharcode(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        HString* empty = builtin_intern_string(ctx.heap, "");
        ctx.result.set_string(empty);
        return;
    }
    // Build string from code units. Worst case 3 bytes per unit, so size the
    // buffer off argc — apply() can pass thousands of arguments.
    usz cc_cap = (usz)ctx.argc * 3;
    char* buf = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, cc_cap);
    if (buf == null) { ctx.result.set_undefined(); return; }
    usz offset = 0;
    ushort max_args = ctx.argc;
    for (ushort i = 0; i < max_args; i++) {
        uint cu = to_uint16(ctx, &ctx.regs[ctx.base_reg + i]);
        if (cu < 128) {
            buf[offset++] = (char)cu;
        } else if (cu < 2048) {
            buf[offset++] = (char)(0xC0 | (cu >> 6));
            buf[offset++] = (char)(0x80 | (cu & 0x3F));
        } else {
            buf[offset++] = (char)(0xE0 | (cu >> 12));
            buf[offset++] = (char)(0x80 | ((cu >> 6) & 0x3F));
            buf[offset++] = (char)(0x80 | (cu & 0x3F));
        }
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    ctx.heap.free_func(ctx.heap.heap_udata, buf);
    ctx.result.set_string(result);
}

/// String.fromCodePoint(...codePoints) — ES6 §21.1.2.2
fn void builtin_string_fromcodepoint(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        HString* empty = builtin_intern_string(ctx.heap, "");
        ctx.result.set_string(empty);
        return;
    }
    // Build string from code points (supporting supplementary plane via UTF-8).
    // Worst case 6 bytes per argument (supplementary plane surrogate pair in
    // CESU-8), so size the buffer off argc — callers like
    // String.fromCodePoint.apply(null, hugeArray) pass thousands of args.
    usz buf_cap = (usz)ctx.argc * 6;
    char* buf = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, buf_cap);
    if (buf == null) { ctx.result.set_undefined(); return; }
    usz offset = 0;
    ushort max_args = ctx.argc;
    for (ushort i = 0; i < max_args; i++) {
        TVal* arg = &ctx.regs[ctx.base_reg + i];
        double d;
        if (arg.is_fastint()) {
            d = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            d = arg.get_number();
        } else if (arg.is_boolean()) {
            d = arg.get_boolean() ? 1.0 : 0.0;
        } else if (arg.is_undefined() || arg.is_null()) {
            d = 0.0;
        } else {
            d = builtin_to_number_vm(ctx, arg);
            if (ctx.should_throw) {
                ctx.heap.free_func(ctx.heap.heap_udata, buf);
                return;
            }
        }
        // Check: must be integral Number in [0, 0x10FFFF]
        if (math::is_nan(d) || math::is_inf(d) || d != math::trunc(d) || d < 0 || d > 0x10FFFF) {
            // Throw RangeError
            ctx.heap.free_func(ctx.heap.heap_udata, buf);
            builtin_throw_no_result_change(ctx, ctx.heap.range_err_proto, "Invalid code point value");
            return;
        }
        uint ucp = (uint)(long)d;
        if (ucp < 0x80) {
            buf[offset++] = (char)ucp;
        } else if (ucp < 0x800) {
            buf[offset++] = (char)(0xC0 | (ucp >> 6));
            buf[offset++] = (char)(0x80 | (ucp & 0x3F));
        } else if (ucp < 0x10000) {
            buf[offset++] = (char)(0xE0 | (ucp >> 12));
            buf[offset++] = (char)(0x80 | ((ucp >> 6) & 0x3F));
            buf[offset++] = (char)(0x80 | (ucp & 0x3F));
        } else {
            // Supplementary plane: ECMAScript strings are UTF-16 code unit
            // sequences, so encode as a surrogate pair (CESU-8 storage —
            // each half gets its own 3-byte UTF-8 sequence) rather than a
            // single 4-byte UTF-8 sequence, so `.length` reports 2.
            uint high; uint low;
            hstring::codepoint_to_surrogates(ucp, &high, &low);
            buf[offset++] = (char)(0xE0 | (high >> 12));
            buf[offset++] = (char)(0x80 | ((high >> 6) & 0x3F));
            buf[offset++] = (char)(0x80 | (high & 0x3F));
            buf[offset++] = (char)(0xE0 | (low >> 12));
            buf[offset++] = (char)(0x80 | ((low >> 6) & 0x3F));
            buf[offset++] = (char)(0x80 | (low & 0x3F));
        }
    }
    HString* result_str = builtin_intern_string(ctx.heap, buf[:offset]);
    ctx.heap.free_func(ctx.heap.heap_udata, buf);
    ctx.result.set_string(result_str);
}

/// String.raw(template, ...substitutions) — ES2015 §22.1.2.4
///
/// Reads template.raw as an array-like, interleaves its string-coerced
/// elements with the substitution arguments, and returns the concatenation.
/// ToObject/Get/LengthOfArrayLike follow the spec exactly so getter
/// side-effects and abrupt completions propagate correctly.
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
    if (raw_key == null) { ctx.result.set_undefined(); return; }
    TVal? raw_tv_opt = builtins_generic_get(cooked, raw_key, ctx);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
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
    if (len_key == null) { ctx.result.set_undefined(); return; }
    TVal? len_opt = builtins_generic_get(raw_obj, len_key, ctx);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
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
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        }
        if (math::is_nan(ld) || math::is_inf(ld) || ld < 0) {
            ld = 0.0;
        }
        if (ld > (double)0x7FFFFFFF) ld = (double)0x7FFFFFFF;
        literal_segments = (long)ld;
    }

    // Step 6: If literalSegments ≤ 0, return "".
    if (literal_segments <= 0) {
        HString* empty = builtin_intern_string(heap, "");
        ctx.result.set_string(empty);
        return;
    }

    // Step 12+: Accumulate in a heap-allocated growable buffer.
    usz buf_cap = 256;
    usz buf_len = 0;
    char* buf = (char*)heap.alloc_func(heap.heap_udata, buf_cap);
    if (buf == null) { ctx.result.set_undefined(); return; }

    // Helper macro-like inline: append bytes to buf, growing as needed.
    // Returns false and sets result to undefined on allocation failure.
    for (long next_index = 0; next_index < literal_segments; next_index++) {
        // Step 12.b: nextSeg = ToString(Get(raw, nextKey)).
        HString* idx_key = heap.int_to_hstring(next_index);
        if (idx_key == null) { heap.free_func(heap.heap_udata, buf); ctx.result.set_undefined(); return; }
        TVal? seg_opt = builtins_generic_get(raw_obj, idx_key, ctx);
        if (ctx.should_throw) { heap.free_func(heap.heap_udata, buf); ctx.result.set_undefined(); return; }
        TVal seg_tv;
        if (try sv = seg_opt) {
            seg_tv = sv;
        } else {
            seg_tv.set_undefined();
        }
        if (is_symbol_val(seg_tv)) {
            heap.free_func(heap.heap_udata, buf);
            builtin_throw(ctx, heap.type_err_proto, "Cannot convert a Symbol value to a string");
            return;
        }
        HString* seg_str = builtin_to_string_vm(ctx, &seg_tv);
        if (ctx.should_throw) { heap.free_func(heap.heap_udata, buf); ctx.result.set_undefined(); return; }
        if (seg_str != null && seg_str.blen > 0) {
            usz need = buf_len + (usz)seg_str.blen;
            if (need > buf_cap) {
                usz new_cap = buf_cap * 2;
                if (new_cap < need) new_cap = need + 64;
                char* new_buf = (char*)alloc::realloc_try(mem, buf, (sz)(new_cap)) ?? null;
                if (new_buf == null) { heap.free_func(heap.heap_udata, buf); ctx.result.set_undefined(); return; }
                buf = new_buf;
                buf_cap = new_cap;
            }
            mem::copy(&buf[buf_len], seg_str.get_cstr(), (sz)(seg_str.blen));
            buf_len += (usz)seg_str.blen;
        }

        // Step 12.e: If nextIndex + 1 = literalSegments, finished — exit loop.
        if (next_index + 1 == literal_segments) break;

        // Step 12.f: Append substitutions[nextIndex] (if present).
        // Substitution args start at base_reg + 1; ctx.argc includes the template arg.
        long sub_argc = (long)ctx.argc - 1;
        if (next_index < sub_argc) {
            TVal sub_tv = ctx.regs[ctx.base_reg + 1 + (uint)next_index];
            if (is_symbol_val(sub_tv)) {
                heap.free_func(heap.heap_udata, buf);
                builtin_throw(ctx, heap.type_err_proto, "Cannot convert a Symbol value to a string");
                return;
            }
            HString* sub_str = builtin_to_string_vm(ctx, &sub_tv);
            if (ctx.should_throw) { heap.free_func(heap.heap_udata, buf); ctx.result.set_undefined(); return; }
            if (sub_str != null && sub_str.blen > 0) {
                usz need = buf_len + (usz)sub_str.blen;
                if (need > buf_cap) {
                    usz new_cap = buf_cap * 2;
                    if (new_cap < need) new_cap = need + 64;
                    char* new_buf = (char*)alloc::realloc_try(mem, buf, (sz)(new_cap)) ?? null;
                    if (new_buf == null) { heap.free_func(heap.heap_udata, buf); ctx.result.set_undefined(); return; }
                    buf = new_buf;
                    buf_cap = new_cap;
                }
                mem::copy(&buf[buf_len], sub_str.get_cstr(), (sz)(sub_str.blen));
                buf_len += (usz)sub_str.blen;
            }
        }
    }

    HString* result = heap.str_intern(buf[:buf_len]);
    heap.free_func(heap.heap_udata, buf);
    if (result == null) { ctx.result.set_undefined(); return; }
    ctx.result.set_string(result);
}

/// String.prototype.toString — returns the wrapped string value
fn void builtin_string_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.STRING &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()) {
            ctx.result.set_string((*obj.extra_ptr()).prim.primitive_value.get_heapptr());
            return;
        }
    } else if (this_val.is_string()) {
        HString* hs = (HString*)this_val.get_heapptr();
        // Symbols stored as tagged strings — thisStringValue throws TypeError for Symbol.
        if (hs != null && hs.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "Cannot convert a Symbol value to a string");
            return;
        }
        ctx.result.set_string(this_val.get_heapptr());
        return;
    }
    // Per ES2015 §21.1.3.27 step 1-3: thisStringValue throws TypeError for non-String values
    builtin_throw(ctx, ctx.heap.type_err_proto,
        "String.prototype.toString requires that 'this' be a String");
}

/// String.prototype.data.valueOf — returns the wrapped string primitive
fn void builtin_string_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.STRING &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()) {
            ctx.result.set_string((*obj.extra_ptr()).prim.primitive_value.get_heapptr());
            return;
        }
    } else if (this_val.is_string()) {
        HString* hs = (HString*)this_val.get_heapptr();
        // Symbols stored as tagged strings — thisStringValue throws TypeError for Symbol.
        if (hs != null && hs.is_symbol()) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "Cannot convert a Symbol value to a string");
            return;
        }
        ctx.result.set_string(this_val.get_heapptr());
        return;
    }
    // Per ES2015 §21.1.3.28 step 1-3: thisStringValue throws TypeError for non-String values
    builtin_throw(ctx, ctx.heap.type_err_proto,
        "String.prototype.valueOf requires that 'this' be a String");
}

// ============================================================================
// String.prototype methods (Phase 6b)
// ============================================================================

/// Helper: extract the string data and length from `this`, handling both
/// primitive strings and String wrapper objects. Returns null on failure.
///
/// Implements RequireObjectCoercible + ToString(this) with full ToPrimitive
/// support (Symbol.toPrimitive, toString, valueOf) for object receivers.
/// Symbols as `this` throw TypeError per §7.1.17.
fn HString* string_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_string()) {
        HString* hs = (HString*)this_val.get_heapptr();
        // Symbols stored as tagged strings — ToString(Symbol) throws TypeError.
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
            // ToPrimitive returned an object — throw TypeError per §7.1.1.
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
                "Cannot convert object to primitive value");
            return null;
        }
        return builtin_to_string(ctx.heap, &prim);
    }
    return builtin_to_string(ctx.heap, &this_val);
}

/// String.prototype.charAt(pos) — ES5 §15.5.4.4
fn void builtin_string_proto_charAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    uint clen = s_hstr.char_length();
    double pos = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (pos < 0 || pos >= (double)clen) {
        // Return empty string
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    uint idx = (uint)(long)pos;
    uint cp = s_hstr.char_at(idx);
    char[4] buf;
    uint blen = hstring::encode_codepoint(cp, buf[:4]);
    HString* result = builtin_intern_string(ctx.heap, buf[:blen]);
    ctx.result.set_string(result);
}

/// String.prototype.charCodeAt(pos) — ES5 §15.5.4.5
///
/// Returns the UTF-16 code unit at `pos` (a surrogate half for astral
/// characters, never combined) — indexed by `char_length()`, not `blen`.
fn void builtin_string_proto_charCodeAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    uint clen = s_hstr.char_length();
    double pos = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (pos < 0 || pos >= (double)clen) {
        ctx.result.set_number(double::nan);
        return;
    }
    uint idx = (uint)(long)pos;
    ctx.result.set_fastint((long)s_hstr.char_at(idx));
}

/// String.prototype.indexOf(searchString, position) — ES5 §15.5.4.7
fn void builtin_string_proto_indexOf(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    // Indexed by UTF-16 code unit for the argument/result; byte search
    // itself is safe on CESU-8-canonical data (a byte match can't straddle
    // a code-unit boundary), so only pos/result need unit<->byte conversion.
    uint clen = s_hstr.char_length();

    // Get search string
    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) {
        ctx.result.set_fastint(-1);
        return;
    }

    // Get position
    double pos_d = (ctx.argc > 1) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    uint pos_units;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos_units = 0;
    } else if (pos_d >= (double)clen) {
        pos_units = clen;
    } else {
        pos_units = (uint)(long)pos_d;
    }
    uint pos = s_hstr.char_offset_to_byte_offset(pos_units);

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    // Search for occurrence
    if (search_len == 0) {
        ctx.result.set_fastint((long)pos_units);
        return;
    }

    int result = -1;
    for (uint i = pos; i + search_len <= len; i++) {
        bool found = true;
        for (uint j = 0; j < search_len; j++) {
            if (data[i + j] != search_data[j]) {
                found = false;
                break;
            }
        }
        if (found) {
            result = (int)i;
            break;
        }
    }
    if (result >= 0) {
        // Convert the matched byte offset back to a code-unit index by
        // counting units in the (already-scanned, CESU-8-canonical) prefix.
        uint unit_idx = 0;
        uint byte_off = 0;
        while (byte_off < (uint)result) {
            byte_off += hstring::utf16_unit_byte_len(s_hstr.get_data(), byte_off);
            unit_idx++;
        }
        ctx.result.set_fastint((long)unit_idx);
    } else {
        ctx.result.set_fastint(-1);
    }
}

/// String.prototype.slice(start, end) — ES5 §15.5.4.13
fn void builtin_string_proto_slice(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    // Indexed by UTF-16 code unit (char_length), not raw byte.
    uint len = s_hstr.char_length();

    double start_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    // Per ES5 §15.5.4.13 step 6: if end is undefined, let end be len.
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
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    // ES5 §15.5.4.13 steps 7-8: clamp to [0, len]. NaN→0; ±∞ resolve to the
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
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    uint byte_start = s_hstr.char_offset_to_byte_offset((uint)start_i);
    uint byte_end = s_hstr.char_offset_to_byte_offset((uint)end_i);
    char[] data = s_hstr.get_data();
    HString* result = builtin_intern_string(ctx.heap, data[byte_start..byte_end-1]);
    ctx.result.set_string(result);
}

/// String.prototype.substring(start, end) — ES5 §15.5.4.15
fn void builtin_string_proto_substring(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    // Indexed by UTF-16 code unit (char_length), not raw byte.
    uint len = s_hstr.char_length();

    double start_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    // Per ES5 §15.5.4.15 step 6: if end is undefined, let end be len.
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
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    uint start = clamp_index(start_d, len);
    uint end = clamp_index(end_d, len);

    uint from = start < end ? start : end;
    uint to = start < end ? end : start;

    if (from >= to) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    uint byte_from = s_hstr.char_offset_to_byte_offset(from);
    uint byte_to = s_hstr.char_offset_to_byte_offset(to);
    char[] data = s_hstr.get_data();
    HString* result = builtin_intern_string(ctx.heap, data[byte_from..byte_to-1]);
    ctx.result.set_string(result);
}

/// String.prototype.substr(start, length) — ES5 §B.2.3
fn void builtin_string_proto_substr(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    // Indexed by UTF-16 code unit (char_length), not raw byte.
    uint len = s_hstr.char_length();

    double start_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    int start_i;
    if (math::is_nan(start_d)) {
        start_i = 0;
    } else if (start_d < 0) {
        start_i = (int)(long)start_d + (int)len;
        if (start_i < 0) start_i = 0;
    } else {
        start_i = (int)(long)start_d;
        if (start_i > (int)len) start_i = (int)len;
    }

    double length_d;
    if (ctx.argc > 1) {
        length_d = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
    } else {
        length_d = (double)(len - (uint)start_i);
    }
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    int length_i;
    if (math::is_nan(length_d) || length_d <= 0) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    length_i = (int)(long)length_d;
    if (length_i > (int)len - start_i) {
        length_i = (int)len - start_i;
    }
    if (length_i <= 0) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    uint byte_start = s_hstr.char_offset_to_byte_offset((uint)start_i);
    uint byte_end = s_hstr.char_offset_to_byte_offset((uint)(start_i + length_i));
    char[] data = s_hstr.get_data();
    HString* result = builtin_intern_string(ctx.heap, data[byte_start..byte_end-1]);
    ctx.result.set_string(result);
}

// ============================================================================
// Unicode case conversion helpers
// ============================================================================

/// Decode a single Unicode codepoint from a CESU-8 string.
/// CESU-8 stores astral codepoints as surrogate pairs, each encoded as a
/// standalone 3-byte UTF-8 sequence.  When a high surrogate is immediately
/// followed by a low surrogate, they are combined into the astral codepoint.
/// Returns the codepoint and writes the byte sequence length to *seq_len.
fn uint cesu8_decode_codepoint(char* data, uint off, uint total_len, uint* seq_len) {
    if (off >= total_len) { *seq_len = 0; return 0; }
    uint b0 = (uint)data[off];

    // 1-byte ASCII fast path
    if (b0 < 0x80) { *seq_len = 1; return b0; }

    // 2-byte: 110xxxxx 10xxxxxx
    if ((b0 & 0xE0) == 0xC0) {
        if (off + 1 >= total_len) { *seq_len = 1; return b0 & 0x1F; }
        *seq_len = 2;
        return ((b0 & 0x1F) << 6) | ((uint)data[off + 1] & 0x3F);
    }

    // 3-byte: 1110xxxx 10xxxxxx 10xxxxxx
    if ((b0 & 0xF0) == 0xE0) {
        if (off + 2 >= total_len) { *seq_len = 1; return 0; }
        uint b1 = (uint)data[off + 1];
        uint b2 = (uint)data[off + 2];
        uint cp = ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);

        // Check for surrogate pair (CESU-8 astral encoding)
        if (cp >= 0xD800 && cp <= 0xDBFF) {
            // High surrogate — try to find a trailing low surrogate
            uint off2 = off + 3;
            if (off2 + 2 < total_len) {
                uint c0 = (uint)data[off2];
                if ((c0 & 0xF0) == 0xE0) {
                    uint c1 = (uint)data[off2 + 1];
                    uint c2 = (uint)data[off2 + 2];
                    uint cp2 = ((c0 & 0x0F) << 12) | ((c1 & 0x3F) << 6) | (c2 & 0x3F);
                    if (cp2 >= 0xDC00 && cp2 <= 0xDFFF) {
                        // Valid surrogate pair → astral codepoint
                        *seq_len = 6;
                        return 0x10000 + ((cp - 0xD800) << 10) + (cp2 - 0xDC00);
                    }
                }
            }
        }

        *seq_len = 3;
        return cp;
    }

    // 4-byte (standard UTF-8 — shouldn't normally appear in CESU-8 but handle defensively)
    if ((b0 & 0xF8) == 0xF0) {
        if (off + 3 >= total_len) { *seq_len = 1; return 0; }
        uint b1 = (uint)data[off + 1];
        uint b2 = (uint)data[off + 2];
        uint b3 = (uint)data[off + 3];
        *seq_len = 4;
        return ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
    }

    *seq_len = 1;
    return 0;
}

/// Encode a codepoint to CESU-8 into buf, returning bytes written.
/// Astral codepoints (>= U+10000) are encoded as surrogate pairs,
/// each as an independent 3-byte UTF-8 sequence.
fn uint cesu8_encode_codepoint(uint cp, char* buf, uint buf_remaining) {
    if (cp < 0x80) {
        if (buf_remaining < 1) return 0;
        buf[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        if (buf_remaining < 2) return 0;
        buf[0] = (char)(0xC0 | (cp >> 6));
        buf[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        if (buf_remaining < 3) return 0;
        buf[0] = (char)(0xE0 | (cp >> 12));
        buf[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        buf[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    // Astral: encode as surrogate pair in CESU-8
    if (buf_remaining < 6) return 0;
    uint high = 0xD800 + ((cp - 0x10000) >> 10);
    uint low  = 0xDC00 + ((cp - 0x10000) & 0x3FF);
    buf[0] = (char)(0xE0 | (high >> 12));
    buf[1] = (char)(0x80 | ((high >> 6) & 0x3F));
    buf[2] = (char)(0x80 | (high & 0x3F));
    buf[3] = (char)(0xE0 | (low >> 12));
    buf[4] = (char)(0x80 | ((low >> 6) & 0x3F));
    buf[5] = (char)(0x80 | (low & 0x3F));
    return 6;
}

/// Decode the entire CESU-8 string into a heap-allocated uint[] of codepoints.
/// Returns pointer to allocated array (caller must mem::free) and sets *out_n.
fn uint* cesu8_to_codepoints(char* data, uint blen, uint* out_n) {
    if (blen == 0) { *out_n = 0; return (uint*)alloc::malloc_try(mem, (sz)(4)) ?? null; }
    // Upper bound: each codepoint is at least 1 byte
    uint* cps = (uint*)alloc::malloc_try(mem, (sz)((usz)blen * 4)) ?? null;
    if (cps == null) { *out_n = 0; return null; }
    uint n = 0;
    uint i = 0;
    while (i < blen) {
        uint seq_len;
        uint cp = cesu8_decode_codepoint(data, i, blen, &seq_len);
        if (seq_len == 0) break;
        cps[n] = cp;
        n++;
        i += seq_len;
    }
    *out_n = n;
    return cps;
}

// GREEK CAPITAL LETTER SIGMA codepoint — has Final_Sigma conditional mapping.
const uint CP_SIGMA = 0x03A3;
const uint CP_SIGMA_FINAL = 0x03C2;   // ς — final form
const uint CP_SIGMA_LOWER = 0x03C3;   // σ — non-final form

/// Determine which lowercase form of Greek Sigma to use.
/// Per Unicode Default Case Algorithms §3.13:
///   Final_Sigma: Σ is lowercase to ς (U+03C2) when it is directly after
///   a Cased character (possibly surrounded by Case_Ignorable) and is NOT
///   directly before a Cased character (possibly surrounded by Case_Ignorable).
fn uint sigma_lower_form(uint* cps, uint n, uint idx) {
    // Look backward for a Cased character (skip Case_Ignorable).
    // Per Unicode §3.13 Final_Sigma: the "anchor" cased character must be
    // Cased AND *not* Case_Ignorable (characters that are both Cased and
    // Case_Ignorable — like U+0345 — count only as Case_Ignorable, not as
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

/// Full Unicode case conversion (toLowerCase or toUpperCase).
/// conv_type: 1 = lowercase, 0 = uppercase.
/// Returns a newly interned HString*, or null on OOM.
fn HString* unicode_case_convert_str(Heap* heap, char* data, uint blen, int conv_type) {
    if (blen == 0) {
        return builtin_intern_string(heap, "");
    }

    // Fast path: ASCII-only string
    if (true) {
        bool all_ascii = true;
        for (uint ai = 0; ai < blen; ai++) {
            if ((uint)data[ai] >= 0x80) { all_ascii = false; break; }
        }
        if (all_ascii) {
            char* out_buf = (char*)alloc::malloc_try(mem, (sz)((usz)blen + 1)) ?? null;
            if (out_buf == null) return null;
            for (uint ai = 0; ai < blen; ai++) {
                char c = data[ai];
                if (conv_type == 1) { // lowercase
                    if (c >= 'A' && c <= 'Z') c = (char)((uint)c + 32);
                } else { // uppercase
                    if (c >= 'a' && c <= 'z') c = (char)((uint)c - 32);
                }
                out_buf[ai] = c;
            }
            HString* result = builtin_intern_string(heap, out_buf[:blen]);
            mem::free(out_buf);
            return result;
        }
    }

    // Decode CESU-8 to codepoint array
    uint num_cps;
    uint* cps = cesu8_to_codepoints(data, blen, &num_cps);
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
        int n_mapped;
        if (conv_type == 1 && cp == CP_SIGMA) {
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

    // Encode output codepoints back to CESU-8
    // Worst case: 6 bytes per codepoint
    usz out_bytes_max = (usz)out_n * 6 + 1;
    char* out_bytes = (char*)alloc::malloc_try(mem, (sz)(out_bytes_max)) ?? null;
    if (out_bytes == null) {
        mem::free(out_cps);
        return null;
    }

    uint byte_off = 0;
    for (uint i = 0; i < out_n; i++) {
        uint written = cesu8_encode_codepoint(out_cps[i], out_bytes + byte_off,
                                              (uint)(out_bytes_max - byte_off));
        byte_off += written;
    }
    mem::free(out_cps);

    HString* result = builtin_intern_string(heap, out_bytes[:byte_off]);
    mem::free(out_bytes);
    return result;
}

/// String.prototype.toLowerCase() — full Unicode case mapping (ES2024 §22.1.3.26)
fn void builtin_string_proto_toLowerCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    HString* result = unicode_case_convert_str(ctx.heap, data, len, 1);
    if (result == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(result);
}

/// String.prototype.toUpperCase() — full Unicode case mapping (ES2024 §22.1.3.28)
fn void builtin_string_proto_toUpperCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    HString* result = unicode_case_convert_str(ctx.heap, data, len, 0);
    if (result == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(result);
}

/// String.prototype.toLocaleLowerCase() — locale-insensitive (uses Unicode default).
fn void builtin_string_proto_toLocaleLowerCase(BuiltinContext* ctx) {
    builtin_string_proto_toLowerCase(ctx);
}

/// String.prototype.toLocaleUpperCase() — locale-insensitive (uses Unicode default).
fn void builtin_string_proto_toLocaleUpperCase(BuiltinContext* ctx) {
    builtin_string_proto_toUpperCase(ctx);
}

/// String.prototype.localeCompare(that) — ES5 §15.5.4.12
/// Returns <0, 0, or >0 based on lexicographic comparison.
fn void builtin_string_proto_localeCompare(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    HString* that_hstr;
    if (ctx.argc > 0) {
        that_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    } else {
        that_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (that_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* a = s_hstr.get_cstr();
    uint a_len = s_hstr.blen;
    char* b = that_hstr.get_cstr();
    uint b_len = that_hstr.blen;
    usz min_len = a_len < b_len ? (usz)a_len : (usz)b_len;
    for (usz i = 0; i < min_len; i++) {
        int diff = (int)a[i] - (int)b[i];
        if (diff != 0) {
            ctx.result.set_number((double)diff);
            return;
        }
    }
    ctx.result.set_number((double)((int)a_len - (int)b_len));
}

/// String.prototype.trim() — ES5 §15.5.4.20
///
/// Removes leading and trailing WhiteSpace and LineTerminator characters.
/// Must handle the full Unicode range (not just ASCII bytes) including
/// multi-byte UTF-8 characters like U+FEFF, U+2028, U+2029, and all
/// Unicode Zs (Space_Separator) characters.
fn void builtin_string_proto_trim(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // ── Trim leading whitespace (by codepoint) ──
    uint start = 0;
    while (start < len) {
        uint seq_len;
        uint cp = decode_codepoint_at(data, start, len, &seq_len);
        if (!is_ecma_ws_codepoint(cp)) break;
        start += seq_len;
    }

    // All whitespace
    if (start >= len) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    // ── Trim trailing whitespace (by codepoint) ──
    uint end = len;
    while (end > start) {
        // Walk backward to find the lead byte of the last codepoint
        uint lead = end - 1;
        while (lead > start && ((uint)data[lead] & 0xC0) == 0x80) {
            lead--;
        }
        uint seq_len;
        uint cp = decode_codepoint_at(data, lead, end, &seq_len);
        if (!is_ecma_ws_codepoint(cp)) break;
        end = lead;
    }

    uint substr_len = end - start;
    char[256] buf;
    usz copy_len = substr_len < 256 ? (usz)substr_len : 256;
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = data[start + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.split(separator, limit) — ES5 §15.5.4.14
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
                            // Call splitter(O, limit) — O is the raw this value (not ToString'd),
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
                            *ctx.result = res;
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
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // Create result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    // If separator is undefined, return [string] — but the limit=0 case
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
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        if (undef_limit_zero) {
            TVal len_val0; len_val0.set_fastint(0);
            arr.put_prop(len_key, len_val0, hobject::PROP_FLAGS_WEC);
            ctx.result.set_object(arr);
            return;
        }
        TVal elem;
        elem.set_string(s_hstr);
        HString* zero_key = builtin_intern_string(ctx.heap, "0");
        arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);
        TVal len_val;
        len_val.set_fastint(1);
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(arr);
        return;
    }

    // For RegExp separator, delegate to @@split on the regexp (which will call
    // RegExp.prototype[@@split]), or fall through to the built-in regexp path.
    // For other separators: step 4 = ToString(separator) — must happen before limit=0 check.
    TVal* sep_val = &sep_tv;

    // Compute limit via ToUint32 — done here, after the @@split check.
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

    // ── RegExp separator ─────────────────────────────────────────────────
    if (is_regexp_object(sep_val)) {
        if (limit == 0) {
            TVal lv0; lv0.set_fastint(0);
            HString* lk0 = builtin_intern_string(ctx.heap, "length");
            arr.put_prop(lk0, lv0, hobject::PROP_FLAGS_WEC);
            ctx.result.set_object(arr);
            return;
        }
        HObject* rx = (HObject*)sep_val.get_heapptr();
        char* input = data;
        int input_len = (int)len;

        HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
        TVal zero_tv; zero_tv.set_fastint(0);
        rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);

        uint arr_idx = 0;
        int search_pos = 0;
        HString* len_key = builtin_intern_string(ctx.heap, "length");

        while (search_pos <= input_len && arr_idx < limit) {
            int out_start = 0;
            int out_end = 0;
            int out_num_captures = 0;
            int[re_bindings::RE_MAX_CAPTURES] caps_start;
            int[re_bindings::RE_MAX_CAPTURES] caps_end;
            mem::clear(&caps_start, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));
            mem::clear(&caps_end, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));

            int result = re_bindings::re_exec(
                (*rx.extra_ptr()).regexp.regexp_data, input, input_len, search_pos,
                &out_start, &out_end, &out_num_captures,
                &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
            );
            if (result != re_bindings::RE_MATCH) break;

            // Substring before match
            uint substr_len = (uint)out_start - (uint)search_pos;
            HString* substr;
            if (substr_len == 0) {
                substr = builtin_intern_string(ctx.heap, "");
            } else if (substr_len < 256) {
                char[256] buf;
                for (usz i = 0; i < (usz)substr_len; i++) buf[i] = input[(usz)search_pos + i];
                substr = builtin_intern_string(ctx.heap, buf[:substr_len]);
            } else {
                substr = builtin_intern_string(ctx.heap, input[search_pos : substr_len]);
            }
            TVal elem;
            elem.set_string(substr);
            arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC);
            arr_idx++;

            // Capture groups
            int num_caps = out_num_captures;
            if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
            for (int i = 0; i < num_caps && arr_idx < limit; i++) {
                TVal cap_elem;
                if (caps_start[i] >= 0 && caps_end[i] >= 0) {
                    usz cap_len = (usz)(caps_end[i] - caps_start[i]);
                    if (cap_len == 0) {
                        cap_elem.set_string(builtin_intern_string(ctx.heap, ""));
                    } else if (cap_len < 256) {
                        char[256] cap_buf;
                        for (usz j = 0; j < cap_len; j++) cap_buf[j] = input[(usz)caps_start[i] + j];
                        cap_elem.set_string(builtin_intern_string(ctx.heap, cap_buf[:cap_len]));
                    } else {
                        cap_elem.set_string(builtin_intern_string(ctx.heap, input[caps_start[i] : cap_len]));
                    }
                } else {
                    cap_elem.set_undefined();
                }
                arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), cap_elem, hobject::PROP_FLAGS_WEC);
                arr_idx++;
            }

            if (out_end == search_pos) {
                bool unicode_flag = ((*rx.extra_ptr()).regexp.flags & (16 | 128)) != 0;
                search_pos = out_end + (int)hstring::advance_string_index_byte_len(
                    input[:input_len], (uint)out_end, unicode_flag);
                if (search_pos > input_len) break;
            } else {
                search_pos = out_end;
            }
        }

        // Remaining part
        if (arr_idx < limit && search_pos <= input_len) {
            uint substr_len = len - (uint)search_pos;
            HString* substr;
            if (substr_len == 0) {
                substr = builtin_intern_string(ctx.heap, "");
            } else if (substr_len < 256) {
                char[256] buf;
                for (usz i = 0; i < (usz)substr_len; i++) buf[i] = input[(usz)search_pos + i];
                substr = builtin_intern_string(ctx.heap, buf[:substr_len]);
            } else {
                substr = builtin_intern_string(ctx.heap, input[search_pos : substr_len]);
            }
            TVal elem;
            elem.set_string(substr);
            arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC);
            arr_idx++;
        }

        TVal len_val; len_val.set_fastint((long)arr_idx);
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(arr);
        return;
    }

    // ── String separator: ToString(separator) — must happen before limit=0 check ──
    HString* sep_hstr = builtin_to_string_vm(ctx, sep_val);
    if (ctx.should_throw) return;
    if (sep_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    // limit=0 check after separator is stringified
    if (limit == 0) {
        TVal len_val; len_val.set_fastint(0);
        HString* len_key0 = builtin_intern_string(ctx.heap, "length");
        arr.put_prop(len_key0, len_val, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(arr);
        return;
    }

    char* sep_data = sep_hstr.get_cstr();
    uint sep_len = sep_hstr.blen;

    // Empty separator: split by UTF-16 code unit (ES5 §15.5.4.14 step 11 —
    // T is a String of length 1 containing element q of S, where S is
    // indexed by UTF-16 code unit, not Unicode codepoint or byte).
    if (sep_len == 0) {
        uint clen = s_hstr.char_length();
        uint count = clen < limit ? clen : limit;
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        TVal len_val;
        len_val.set_fastint((long)count);
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        char[] cdata = s_hstr.get_data();
        uint byte_off = 0;
        for (uint i = 0; i < count; i++) {
            uint unit_len = hstring::utf16_unit_byte_len(cdata, byte_off);
            HString* ch_str = builtin_intern_string(ctx.heap, cdata[byte_off : unit_len]);
            TVal elem;
            elem.set_string(ch_str);
            arr.put_prop(ctx.heap.int_to_hstring((long)i), elem, hobject::PROP_FLAGS_WEC);
            byte_off += unit_len;
        }
        ctx.result.set_object(arr);
        return;
    }

    // Non-empty separator: split by separator
    uint arr_idx = 0;
    uint search_pos = 0;
    HString* len_key = builtin_intern_string(ctx.heap, "length");

    while (search_pos + sep_len <= len && arr_idx < limit) {
        int found_pos = -1;
        for (uint i = search_pos; i + sep_len <= len; i++) {
            bool match = true;
            for (uint j = 0; j < sep_len; j++) {
                if (data[i + j] != sep_data[j]) {
                    match = false;
                    break;
                }
            }
            if (match) { found_pos = (int)i; break; }
        }

        if (found_pos < 0) break;

        uint substr_len = (uint)found_pos - search_pos;
        HString* substr;
        if (substr_len == 0) {
            substr = builtin_intern_string(ctx.heap, "");
        } else {
            char[256] buf;
            usz copy_len = substr_len < 256 ? (usz)substr_len : 256;
            for (usz i = 0; i < copy_len; i++) buf[i] = data[search_pos + i];
            substr = builtin_intern_string(ctx.heap, buf[:copy_len]);
        }

        TVal elem;
        elem.set_string(substr);
        arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC);
        arr_idx++;

        search_pos = (uint)(found_pos + (int)sep_len);
    }

    // Add remaining part if not at limit
    if (arr_idx < limit) {
        uint substr_len = len - search_pos;
        HString* substr;
        if (substr_len == 0) {
            substr = builtin_intern_string(ctx.heap, "");
        } else {
            char[256] buf;
            usz copy_len = substr_len < 256 ? (usz)substr_len : 256;
            for (usz i = 0; i < copy_len; i++) buf[i] = data[search_pos + i];
            substr = builtin_intern_string(ctx.heap, buf[:copy_len]);
        }
        TVal elem;
        elem.set_string(substr);
        arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC);
        arr_idx++;
    }

    TVal len_val;
    len_val.set_fastint((long)arr_idx);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(arr);
}

/// String.prototype.concat(...args) — ES5 §15.5.4.6
fn void builtin_string_proto_concat(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // Concatenate all into a buffer. First, coerce and collect all argument strings.
    usz max_args = ctx.argc < 256 ? (usz)ctx.argc : 256;
    HString*[256] arg_strs;
    uint total_len = len;
    for (usz i = 0; i < max_args; i++) {
        HString* arg_str = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg + i]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        arg_strs[i] = arg_str;
        if (arg_str != null) total_len += arg_str.blen;
    }

    // Allocate output buffer and copy.
    char* out_buf = (char*)alloc::malloc_try(mem, (sz)((usz)total_len + 1)) ?? null;
    if (out_buf == null) { ctx.result.set_string(s_hstr); return; }
    defer mem::free(out_buf);

    usz offset = 0;
    for (usz i = 0; i < (usz)len; i++) out_buf[offset++] = data[i];
    for (usz i = 0; i < max_args; i++) {
        HString* arg_str = arg_strs[i];
        if (arg_str == null) continue;
        char* arg_data = arg_str.get_cstr();
        uint arg_len = arg_str.blen;
        for (usz j = 0; j < (usz)arg_len; j++) out_buf[offset++] = arg_data[j];
    }
    out_buf[offset] = 0;

    HString* result = builtin_intern_string(ctx.heap, out_buf[:offset]);
    ctx.result.set_string(result);
}

/// Substitute $-patterns in a replace string (ES5 §15.5.4.11 step 10)
fn HString* builtin_replace_substitute(Heap* heap, HString* replace_str,
    char* input, int input_len,
    int match_start, int match_end,
    int* caps_start, int* caps_end, int num_caps) {

    char* rep = replace_str.get_cstr();
    uint rep_len = replace_str.blen;
    char[4096] buf;
    usz offset = 0;

    for (usz i = 0; i < rep_len && offset < 4096; i++) {
        if (rep[i] == '$' && i + 1 < rep_len) {
            char next = rep[i + 1];
            if (next == '$') {
                buf[offset++] = '$';
                i++;
                continue;
            }
            if (next == '&') {
                for (usz j = (usz)match_start; j < (usz)match_end && offset < 4096; j++) {
                    buf[offset++] = input[j];
                }
                i++;
                continue;
            }
            if (next == '`') {
                for (usz j = 0; j < (usz)match_start && offset < 4096; j++) {
                    buf[offset++] = input[j];
                }
                i++;
                continue;
            }
            if (next == '\'') {
                for (usz j = (usz)match_end; j < (usz)input_len && offset < 4096; j++) {
                    buf[offset++] = input[j];
                }
                i++;
                continue;
            }
            // ES6 §21.1.3.14 step 14.f: "$" followed by 1 or more decimal
            // digits refers to a capture group. We try 2 digits first; if
            // the resulting index > num_caps, fall back to 1 digit.
            if (next >= '0' && next <= '9') {
                int digit_count = 1;
                int index = next - '0';
                if (i + 2 < rep_len && rep[i + 2] >= '0' && rep[i + 2] <= '9') {
                    int two_digit = index * 10 + (rep[i + 2] - '0');
                    if (two_digit > 0 && two_digit <= num_caps) {
                        index = two_digit;
                        digit_count = 2;
                    }
                }
                if (index >= 1 && index <= num_caps) {
                    if (caps_start[index - 1] >= 0 && caps_end[index - 1] >= 0) {
                        for (usz j = (usz)caps_start[index - 1]; j < (usz)caps_end[index - 1] && offset < 4096; j++) {
                            buf[offset++] = input[j];
                        }
                    }
                    // Otherwise capture is undefined → empty substitution.
                    i += (usz)digit_count;
                    continue;
                }
                // Index out of range (0 or > num_caps): emit the entire
                // "$<digits>" sequence literally per spec.
                buf[offset++] = '$';
                buf[offset++] = (char)next;
                if (digit_count == 2) {
                    buf[offset++] = rep[i + 2];
                }
                i += (usz)digit_count;
                continue;
            }
        }
        buf[offset++] = rep[i];
    }
    return builtin_intern_string(heap, buf[:offset]);
}

/// String.prototype.replace(searchValue, replaceValue) — ES5 §15.5.4.11
fn void builtin_string_proto_replace(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    if (ctx.argc < 1) {
        ctx.result.set_string(s_hstr);
        return;
    }

    TVal* search_val = &ctx.regs[ctx.base_reg];
    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    // ── Check for @@replace protocol (ES6 §21.1.3.14 step 2) ─────────────
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
                            fn_args[0].set_string(s_hstr);  // O
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
                            *ctx.result = res;
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

    // ── RegExp searchValue ────────────────────────────────────────────────
    if (is_regexp_object(search_val)) {
        HObject* rx = (HObject*)search_val.get_heapptr();

        bool global_flag = ((*rx.extra_ptr()).regexp.flags & 1) != 0;

        bool replace_is_fn = false;
        TVal replace_val;
        replace_val.set_undefined();
        if (ctx.argc > 1) {
            replace_val = ctx.regs[ctx.base_reg + 1];
            if (replace_val.is_object() && replace_val.get_heapptr() != null &&
                ((HObject*)replace_val.get_heapptr()).is_callable()) {
                replace_is_fn = true;
            }
        }

        if (!global_flag) {
            // ── Non-global: single match ──────────────────────────────────
            int out_start = 0;
            int out_end = 0;
            int out_num_captures = 0;
            int[re_bindings::RE_MAX_CAPTURES] caps_start;
            int[re_bindings::RE_MAX_CAPTURES] caps_end;
            mem::clear(&caps_start, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));
            mem::clear(&caps_end, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));

            int result = re_bindings::re_exec(
                (*rx.extra_ptr()).regexp.regexp_data, input, input_len, 0,
                &out_start, &out_end, &out_num_captures,
                &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
            );

            if (result != re_bindings::RE_MATCH) {
                ctx.result.set_string(s_hstr);
                return;
            }

            HString* replace_str;
            if (replace_is_fn && ctx.heap.call_fn != null && ctx.vm != null) {
                int num_caps = out_num_captures;
                if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
                TVal[36] fn_args;
                int arg_count = 0;
                usz m_len = (usz)(out_end - out_start);
                fn_args[arg_count].set_string(
                    m_len == 0 ? builtin_intern_string(ctx.heap, "")
                               : builtin_intern_string(ctx.heap, input[out_start : m_len]));
                arg_count++;
                for (int i = 0; i < num_caps; i++) {
                    if (caps_start[i] >= 0 && caps_end[i] >= 0) {
                        usz cap_len = (usz)(caps_end[i] - caps_start[i]);
                        fn_args[arg_count].set_string(
                            cap_len == 0 ? builtin_intern_string(ctx.heap, "")
                                         : builtin_intern_string(ctx.heap, input[caps_start[i] : cap_len]));
                    } else {
                        fn_args[arg_count].set_undefined();
                    }
                    arg_count++;
                }
                TVal offset_tv; offset_tv.set_fastint((long)out_start);
                fn_args[arg_count++] = offset_tv;
                fn_args[arg_count++].set_string(s_hstr);
                TVal this_val; this_val.set_undefined();
                TVal res = ctx.heap.call_fn(ctx.vm, replace_val, &fn_args[0], (uint)arg_count, this_val);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    return;
                }
                replace_str = builtin_to_string_vm(ctx, &res);
                if (ctx.should_throw) return;
                if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "undefined");
            } else {
                HString* raw_replace = ctx.argc > 1
                    ? builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg + 1])
                    : builtin_intern_string(ctx.heap, "undefined");
                if (ctx.should_throw) return;
                if (raw_replace == null) { ctx.result.set_string(s_hstr); return; }
                replace_str = builtin_replace_substitute(ctx.heap, raw_replace,
                    input, input_len, out_start, out_end,
                    &caps_start, &caps_end, out_num_captures);
                if (replace_str == null) replace_str = raw_replace;
            }

            char[4096] buf;
            usz bOff = 0;
            char* rData = replace_str.get_cstr();
            uint rLen = replace_str.blen;
            for (usz i = 0; i < (usz)out_start && bOff < 4096; i++) buf[bOff++] = input[i];
            for (usz i = 0; i < (usz)rLen && bOff < 4096; i++) buf[bOff++] = rData[i];
            for (usz i = (usz)out_end; i < (usz)input_len && bOff < 4096; i++) buf[bOff++] = input[i];
            ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:bOff]));
            return;
        } else {
            // ── Global: replace all matches ───────────────────────────────
            HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
            TVal zero_tv; zero_tv.set_fastint(0);
            rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);

            char[8192] buf;
            usz bOff = 0;
            int search_pos = 0;

            while (search_pos <= input_len) {
                int out_start = 0;
                int out_end = 0;
                int out_num_captures = 0;
                int[re_bindings::RE_MAX_CAPTURES] caps_start;
                int[re_bindings::RE_MAX_CAPTURES] caps_end;
                mem::clear(&caps_start, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));
                mem::clear(&caps_end, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));

                int result = re_bindings::re_exec(
                    (*rx.extra_ptr()).regexp.regexp_data, input, input_len, search_pos,
                    &out_start, &out_end, &out_num_captures,
                    &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
                );
                if (result != re_bindings::RE_MATCH) break;

                for (usz i = (usz)search_pos; i < (usz)out_start && bOff < 8192; i++) buf[bOff++] = input[i];

                HString* replace_str;
                if (replace_is_fn && ctx.heap.call_fn != null && ctx.vm != null) {
                    int num_caps = out_num_captures;
                    if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
                    TVal[36] fn_args;
                    int arg_count = 0;
                    usz m_len = (usz)(out_end - out_start);
                    fn_args[arg_count].set_string(
                        m_len == 0 ? builtin_intern_string(ctx.heap, "")
                                   : builtin_intern_string(ctx.heap, input[out_start : m_len]));
                    arg_count++;
                    for (int i = 0; i < num_caps; i++) {
                        if (caps_start[i] >= 0 && caps_end[i] >= 0) {
                            usz cap_len = (usz)(caps_end[i] - caps_start[i]);
                            fn_args[arg_count].set_string(
                                cap_len == 0 ? builtin_intern_string(ctx.heap, "")
                                             : builtin_intern_string(ctx.heap, input[caps_start[i] : cap_len]));
                        } else {
                            fn_args[arg_count].set_undefined();
                        }
                        arg_count++;
                    }
                    TVal offset_tv; offset_tv.set_fastint((long)out_start);
                    fn_args[arg_count++] = offset_tv;
                    fn_args[arg_count++].set_string(s_hstr);
                    TVal this_val; this_val.set_undefined();
                    TVal res = ctx.heap.call_fn(ctx.vm, replace_val, &fn_args[0], (uint)arg_count, this_val);
                    if (ctx.heap.has_error) {
                        ctx.should_throw = true;
                        ctx.throw_value = ctx.heap.error_value;
                        ctx.heap.has_error = false;
                        return;
                    }
                    replace_str = builtin_to_string_vm(ctx, &res);
                    if (ctx.should_throw) return;
                    if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "undefined");
                } else {
                    HString* raw_replace = ctx.argc > 1
                        ? builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg + 1])
                        : builtin_intern_string(ctx.heap, "undefined");
                    if (ctx.should_throw) return;
                    if (raw_replace == null) break;
                    replace_str = builtin_replace_substitute(ctx.heap, raw_replace,
                        input, input_len, out_start, out_end,
                        &caps_start, &caps_end, out_num_captures);
                    if (replace_str == null) replace_str = raw_replace;
                }

                char* rData = replace_str.get_cstr();
                uint rLen = replace_str.blen;
                for (usz i = 0; i < (usz)rLen && bOff < 8192; i++) buf[bOff++] = rData[i];

                if (out_end == search_pos) {
                    bool unicode_flag = ((*rx.extra_ptr()).regexp.flags & (16 | 128)) != 0;
                    int next_pos = out_end + (int)hstring::advance_string_index_byte_len(
                        input[:input_len], (uint)out_end, unicode_flag);
                    for (usz i = (usz)out_end; i < (usz)next_pos && bOff < 8192; i++) buf[bOff++] = input[i];
                    search_pos = next_pos;
                    if (search_pos > input_len) break;
                } else {
                    search_pos = out_end;
                }
            }

            for (usz i = (usz)search_pos; i < (usz)input_len && bOff < 8192; i++) buf[bOff++] = input[i];
            ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:bOff]));
            return;
        }
    }

    // ── String searchValue ──────────────────────────────────────────────
    // Step 5: Let searchString be ? ToString(searchValue).
    HString* search_hstr = builtin_to_string_vm(ctx, search_val);
    if (ctx.should_throw) return;
    if (search_hstr == null) {
        ctx.result.set_undefined();
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
        if (replace_str_precomp == null) replace_str_precomp = builtin_intern_string(ctx.heap, "undefined");
    }

    // Step 8: Search for first occurrence of searchString.
    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    int found_pos = -1;
    for (uint i = 0; i + search_len <= (uint)input_len; i++) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (input[i + j] != search_data[j]) { match = false; break; }
        }
        if (match) { found_pos = (int)i; break; }
    }

    if (found_pos < 0) {
        ctx.result.set_string(s_hstr);
        return;
    }

    HString* replace_str;
    if (str_replace_is_fn && ctx.heap.call_fn != null && ctx.vm != null) {
        TVal[3] fn_args;
        HString* match_str = builtin_intern_string(ctx.heap, input[found_pos : (usz)search_len]);
        if (match_str == null) match_str = builtin_intern_string(ctx.heap, "");
        fn_args[0].set_string(match_str);
        fn_args[1].set_fastint((long)found_pos);
        fn_args[2].set_string(s_hstr);
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
        if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "undefined");
        replace_str = builtin_replace_substitute(ctx.heap, replace_str,
            input, input_len, found_pos, found_pos + (int)search_len,
            null, null, 0);
        if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "");
    } else {
        replace_str = builtin_replace_substitute(ctx.heap, replace_str_precomp,
            input, input_len, found_pos, found_pos + (int)search_len,
            null, null, 0);
        if (replace_str == null) replace_str = replace_str_precomp;
    }

    char* replace_data = replace_str.get_cstr();
    uint replace_len = replace_str.blen;

    char[4096] buf;
    usz bOff = 0;
    for (usz i = 0; i < (usz)found_pos && bOff < 4096; i++) buf[bOff++] = input[i];
    for (usz i = 0; i < (usz)replace_len && bOff < 4096; i++) buf[bOff++] = replace_data[i];
    uint suffix_start = (uint)(found_pos + (int)search_len);
    for (usz i = (usz)suffix_start; i < (usz)input_len && bOff < 4096; i++) buf[bOff++] = input[i];

    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:bOff]));
}

/// String.prototype.replaceAll(searchValue, replaceValue) — ES2021 §22.1.3.18
fn void builtin_string_proto_replaceAll(BuiltinContext* ctx) {
    // Step 1: RequireObjectCoercible(this). We don't ToString the receiver
    // yet — step 2's searchValue checks (IsRegExp, flags, @@replace) must
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
                        is_regexp_like = builtin_to_boolean(&mtv);
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
            TVal? flags_tv_opt = builtins_generic_get(rx, builtin_intern_string(ctx.heap, "flags"), ctx);
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
            char* flags_cstr = flags_hstr.get_cstr();
            usz flags_len = flags_hstr.blen;
            for (usz i = 0; i < flags_len; i++) {
                if (flags_cstr[i] == 'g') { has_g = true; break; }
            }
            if (!has_g) {
                arr_throw_type_error(ctx, "String.prototype.replaceAll called with a non-global regular expression");
                return;
            }
        }

        // Step 2.c: replacer = GetMethod(searchValue, @@replace).
        // Step 2.d: if replacer is not undefined, delegate to it entirely —
        // this happens BEFORE ToString(this) / ToString(searchValue), so a
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
                        fn_args[0] = this_tv;         // O — NOT yet ToString'd
                        fn_args[1] = replace_val;     // replaceValue as-is
                        TVal res = ctx.heap.call_fn(ctx.vm, replacer, &fn_args[0], 2, search_val);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                            return;
                        }
                        *ctx.result = res;
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
    char* input = s_hstr.get_cstr();
    uint input_len = s_hstr.blen;

    // Step 4: searchString = ToString(searchValue).
    if (is_symbol_val(search_val)) {
        arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
        return;
    }
    HString* search_hstr = builtin_to_string_vm(ctx, &search_val);
    if (ctx.should_throw) return;
    if (search_hstr == null) return;
    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

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

    // Step 7: advanceBy = max(1, searchString length) — code-unit length,
    // but since matches can't straddle CESU-8 byte boundaries, byte length
    // is equivalent here.
    uint advance_by = search_len == 0 ? 1 : search_len;

    // Steps 8-11: find all match positions via a (byte-based) StringIndexOf
    // loop, matching left-to-right, non-overlapping, advancing by
    // advanceBy on every step (including empty-string matches).
    char[8192] buf;
    usz bOff = 0;
    int pos = 0;
    int last_end = 0;
    int ilen = (int)input_len;

    while (pos <= ilen - (int)search_len) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (input[(uint)pos + j] != search_data[j]) { match = false; break; }
        }
        if (!match) { pos++; continue; }

        // Copy the unmatched prefix since the previous match.
        for (usz i = (usz)last_end; i < (usz)pos && bOff < 8192; i++) buf[bOff++] = input[i];

        // Step 14: compute replacement for this match position.
        HString* replacement_str;
        if (functional_replace) {
            TVal[3] fn_args;
            fn_args[0].set_string(search_hstr);
            fn_args[1].set_fastint((long)pos);
            fn_args[2].set_string(s_hstr);
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
            replacement_str = builtin_to_string_vm(ctx, &res);
            if (ctx.should_throw) return;
            if (replacement_str == null) return;
        } else {
            // GetSubstitution with an always-empty captures list: only
            // $$, $&, $`, and $' are recognized; $N/$NN/$<...> stay literal
            // since there are no captures (num_caps == 0).
            replacement_str = builtin_replace_substitute(ctx.heap, replace_hstr,
                input, ilen, pos, pos + (int)search_len,
                null, null, 0);
            if (replacement_str == null) replacement_str = replace_hstr;
        }

        char* rData = replacement_str.get_cstr();
        uint rLen = replacement_str.blen;
        for (usz i = 0; i < (usz)rLen && bOff < 8192; i++) buf[bOff++] = rData[i];

        last_end = pos + (int)search_len;
        pos += (int)advance_by;
    }

    // Copy remaining characters after the last match.
    for (usz i = (usz)last_end; i < (usz)ilen && bOff < 8192; i++) buf[bOff++] = input[i];

    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:bOff]));
}

// ============================================================================
// Additional String.prototype methods
// ============================================================================

/// String.prototype.includes(searchString, position) — ES6 §21.1.3.7
fn void builtin_string_proto_includes(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        // ES6 §21.1.3.7 step 3-6: IsRegExp(searchString) → throw TypeError
        int regexp_check = is_regexp_check_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (regexp_check < 0) { ctx.result.set_undefined(); return; }
        if (regexp_check == 1) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "First argument to String.prototype.includes must not be a RegExp");
            return;
        }
        search_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

    // position argument is in code units; convert to byte offset before
    // searching. Byte-level substring matching itself stays correct on
    // CESU-8-canonical data (a match can't straddle a code-unit boundary).
    uint clen = s_hstr.char_length();
    double pos_d = (ctx.argc > 1) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    uint pos_units;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos_units = 0;
    } else if (pos_d >= (double)clen) {
        pos_units = clen;
    } else {
        pos_units = (uint)(long)pos_d;
    }
    uint pos = s_hstr.char_offset_to_byte_offset(pos_units);

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (search_len == 0) { ctx.result.set_boolean(true); return; }

    bool found = false;
    for (uint i = pos; i + search_len <= len; i++) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (data[i + j] != search_data[j]) { match = false; break; }
        }
        if (match) { found = true; break; }
    }
    ctx.result.set_boolean(found);
}

/// String.prototype.startsWith(searchString, position) — ES6 §21.1.3.18
fn void builtin_string_proto_startsWith(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        // ES6 §21.1.3.18 step 3-6: IsRegExp(searchString) → throw TypeError
        int regexp_check = is_regexp_check_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (regexp_check < 0) { ctx.result.set_undefined(); return; }
        if (regexp_check == 1) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "First argument to String.prototype.startsWith must not be a RegExp");
            return;
        }
        search_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

    // position argument is in code units; convert to byte offset.
    uint clen = s_hstr.char_length();
    double pos_d = (ctx.argc > 1) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    uint pos_units;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos_units = 0;
    } else if (pos_d > (double)clen) {
        pos_units = clen;
    } else {
        pos_units = (uint)(long)pos_d;
    }
    uint pos = s_hstr.char_offset_to_byte_offset(pos_units);

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (pos + search_len > len) { ctx.result.set_boolean(false); return; }

    bool found = true;
    for (uint j = 0; j < search_len; j++) {
        if (data[pos + j] != search_data[j]) { found = false; break; }
    }
    ctx.result.set_boolean(found);
}

/// String.prototype.endsWith(searchString, endPosition) — ES6 §21.1.3.6
fn void builtin_string_proto_endsWith(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        // ES6 §21.1.3.6 step 3-6: IsRegExp(searchString) → throw TypeError
        int regexp_check = is_regexp_check_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (regexp_check < 0) { ctx.result.set_undefined(); return; }
        if (regexp_check == 1) {
            builtin_throw(ctx, ctx.heap.type_err_proto,
                "First argument to String.prototype.endsWith must not be a RegExp");
            return;
        }
        search_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

    // endPosition argument is in code units; convert to byte offset.
    uint clen = s_hstr.char_length();
    double end_d = (ctx.argc > 1) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]) : (double)clen;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    uint end_units;
    if (math::is_nan(end_d) || end_d < 0) {
        end_units = 0;
    } else if (end_d > (double)clen) {
        end_units = clen;
    } else {
        end_units = (uint)(long)end_d;
    }
    uint end_pos = s_hstr.char_offset_to_byte_offset(end_units);

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (search_len > end_pos) { ctx.result.set_boolean(false); return; }

    uint start = end_pos - search_len;
    bool found = true;
    for (uint j = 0; j < search_len; j++) {
        if (data[start + j] != search_data[j]) { found = false; break; }
    }
    ctx.result.set_boolean(found);
}

/// String.prototype.repeat(count) — ES6 §21.1.3.14
fn void builtin_string_proto_repeat(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    // Step 3: ToIntegerOrInfinity(count) — runs valueOf/toString and throws for
    // Symbol/BigInt *before* the RangeError range check (ES2022 §22.1.3.16).
    double count_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    // Step 4: RangeError if count < 0 or count is +∞ (NaN already clamped to 0).
    if (count_d < 0 || math::is_inf(count_d)) {
        // Throw RangeError per ES6 §21.1.3.14 step 4.
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.range_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Invalid count value");
            TVal msg_val; msg_val.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        ctx.result.set_undefined();
        return;
    }
    uint count = (uint)(long)count_d;

    if (count == 0 || s_hstr.blen == 0) {
        HString* empty = builtin_intern_string(ctx.heap, "");
        ctx.result.set_string(empty);
        return;
    }

    // Build repeated string
    usz total = (usz)s_hstr.blen * (usz)count;
    char* buf = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, total + 1);
    if (buf == null) { ctx.result.set_undefined(); return; }
    char* src = s_hstr.get_cstr();
    for (uint i = 0; i < count; i++) {
        mem::copy(&buf[i * s_hstr.blen], src, (sz)(s_hstr.blen));
    }
    buf[total] = 0;

    HString* result = ctx.heap.str_intern(buf[:total]);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
    ctx.heap.free_func(ctx.heap.heap_udata, buf);
}

/// String.prototype.trimStart() — ES2019 §21.1.3.26
fn void builtin_string_proto_trimStart(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    uint start = 0;
    while (start < len) {
        uint seq_len;
        uint cp = decode_codepoint_at(data, start, len, &seq_len);
        if (!is_ecma_ws_codepoint(cp)) break;
        start += seq_len;
    }
    if (start == 0) {
        ctx.result.set_string(s_hstr); return;
    }
    HString* result = ctx.heap.str_intern(data[start:len - start]);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
}

/// String.prototype.trimEnd() — ES2019 §21.1.3.27
fn void builtin_string_proto_trimEnd(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    uint end = len;
    while (end > 0) {
        // Walk backward to find the lead byte of the last codepoint
        uint lead = end - 1;
        while (lead > 0 && ((uint)data[lead] & 0xC0) == 0x80) {
            lead--;
        }
        uint seq_len;
        uint cp = decode_codepoint_at(data, lead, end, &seq_len);
        if (!is_ecma_ws_codepoint(cp)) break;
        end = lead;
    }
    if (end == len) {
        ctx.result.set_string(s_hstr); return;
    }
    HString* result = ctx.heap.str_intern(data[0:end]);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
}

/// String.prototype.codePointAt(pos) — ES6 §21.1.3.3
///
/// Indexed by UTF-16 code unit (`char_length()`). If the unit at `pos` is a
/// high surrogate and `pos+1` is a low surrogate, combine them into the
/// astral codepoint; otherwise return the code unit as-is (matches
/// CharCodeAt semantics for non-surrogate / lone-surrogate positions).
fn void builtin_string_proto_codePointAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    uint clen = s_hstr.char_length();

    double pos_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (math::is_nan(pos_d) || pos_d < 0) {
        ctx.result.set_undefined(); return;
    }
    uint pos = (uint)(long)pos_d;
    if (pos >= clen) { ctx.result.set_undefined(); return; }

    uint first = s_hstr.char_at(pos);
    if (hstring::is_high_surrogate(first) && pos + 1 < clen) {
        uint second = s_hstr.char_at(pos + 1);
        if (hstring::is_low_surrogate(second)) {
            ctx.result.set_fastint((long)hstring::surrogates_to_codepoint(first, second));
            return;
        }
    }
    ctx.result.set_fastint((long)first);
}

/// String.prototype.at(index) — ES2022 §21.1.3.1
///
/// Indexed by UTF-16 code unit; returns a one-code-unit String (a lone
/// surrogate half for astral characters), matching `charAt`.
fn void builtin_string_proto_at(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    uint clen = s_hstr.char_length();

    // Step 4: ToIntegerOrInfinity(index) — coerces via valueOf/toString, NaN→0.
    double idx_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    long idx = (long)idx_d;
    if (idx < 0) { idx = (long)clen + idx; }
    if (idx < 0 || idx >= (long)clen) { ctx.result.set_undefined(); return; }

    uint cp = s_hstr.char_at((uint)idx);
    char[4] cbuf;
    uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
    HString* result = builtin_intern_string(ctx.heap, cbuf[:cblen]);
    ctx.result.set_string(result);
}

/// String.prototype.padStart(maxLength, fillString) — ES2017 §21.1.3.13
///
/// StringPad operates on code-unit length throughout: maxLength is a code
/// unit count, and the fill string is truncated to land on exactly the
/// needed number of code units (never split mid-surrogate-pair, since we
/// truncate at unit boundaries, not byte boundaries).
fn void builtin_string_proto_padStart(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    double max_len_d = (ctx.argc > 0) ? builtin_to_number_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(max_len_d) || max_len_d < 0) { max_len_d = 0; }
    uint max_len = (uint)(long)max_len_d;

    uint str_units = s_hstr.char_length();
    if (str_units >= max_len) {
        ctx.result.set_string(s_hstr); return;
    }

    HString* fill_hstr;
    if (ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
        fill_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
    } else {
        fill_hstr = builtin_intern_string(ctx.heap, " ");
    }
    if (fill_hstr == null || fill_hstr.blen == 0) {
        ctx.result.set_string(s_hstr); return;
    }

    uint pad_units = max_len - str_units;
    uint fill_units = fill_hstr.char_length();
    char[] fill_data = fill_hstr.get_data();
    char[] src = s_hstr.get_data();

    // Worst case every pad unit is a 4-byte codepoint.
    usz cap = (usz)pad_units * 4 + (usz)src.len + 1;
    char* buf_ptr = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, cap);
    if (buf_ptr == null) { ctx.result.set_undefined(); return; }

    usz off = 0;
    uint fill_byte_off = 0;
    for (uint i = 0; i < pad_units; i++) {
        if (fill_byte_off >= fill_hstr.blen) { fill_byte_off = 0; }
        uint ulen = hstring::utf16_unit_byte_len(fill_data, fill_byte_off);
        for (uint k = 0; k < ulen; k++) { buf_ptr[off + k] = fill_data[fill_byte_off + k]; }
        off += ulen;
        fill_byte_off += ulen;
    }
    if (src.len > 0) { mem::copy(&buf_ptr[off], src.ptr, (sz)(src.len)); }
    off += (usz)src.len;

    HString* result = ctx.heap.str_intern(buf_ptr[:off]);
    ctx.heap.free_func(ctx.heap.heap_udata, buf_ptr);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
}

/// String.prototype.padEnd(maxLength, fillString) — ES2017 §21.1.3.12
///
/// See padStart: fill is applied by whole code unit, not raw byte.
fn void builtin_string_proto_padEnd(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    double max_len_d = (ctx.argc > 0) ? builtin_to_number_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(max_len_d) || max_len_d < 0) { max_len_d = 0; }
    uint max_len = (uint)(long)max_len_d;

    uint str_units = s_hstr.char_length();
    if (str_units >= max_len) {
        ctx.result.set_string(s_hstr); return;
    }

    HString* fill_hstr;
    if (ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
        fill_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
    } else {
        fill_hstr = builtin_intern_string(ctx.heap, " ");
    }
    if (fill_hstr == null || fill_hstr.blen == 0) {
        ctx.result.set_string(s_hstr); return;
    }

    uint pad_units = max_len - str_units;
    char[] fill_data = fill_hstr.get_data();
    char[] src = s_hstr.get_data();

    usz cap = (usz)src.len + (usz)pad_units * 4 + 1;
    char* buf_ptr = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, cap);
    if (buf_ptr == null) { ctx.result.set_undefined(); return; }

    usz off = 0;
    if (src.len > 0) { mem::copy(buf_ptr, src.ptr, (sz)(src.len)); }
    off += (usz)src.len;

    uint fill_byte_off = 0;
    for (uint i = 0; i < pad_units; i++) {
        if (fill_byte_off >= fill_hstr.blen) { fill_byte_off = 0; }
        uint ulen = hstring::utf16_unit_byte_len(fill_data, fill_byte_off);
        for (uint k = 0; k < ulen; k++) { buf_ptr[off + k] = fill_data[fill_byte_off + k]; }
        off += ulen;
        fill_byte_off += ulen;
    }

    HString* result = ctx.heap.str_intern(buf_ptr[:off]);
    ctx.heap.free_func(ctx.heap.heap_udata, buf_ptr);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
}

/// String.prototype.lastIndexOf(searchString, position) — ES5 §15.5.4.8
fn void builtin_string_proto_lastIndexOf(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    // Indexed by UTF-16 code unit for the argument/result.
    uint clen = s_hstr.char_length();

    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_fastint(-1); return; }

    // Step 4-6: numPos = ToNumber(position); NaN → +∞ (i.e. search from the very
    // end), otherwise ToIntegerOrInfinity. ToNumber runs valueOf and may throw
    // (ES2022 §22.1.3.9).
    double pos_d;
    if (ctx.argc > 1) {
        double num_pos = builtin_to_number_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        pos_d = math::is_nan(num_pos) ? (double)clen : num_pos;
    } else {
        pos_d = (double)clen;
    }
    if (pos_d < 0) { pos_d = 0; }
    if (pos_d > (double)clen) { pos_d = (double)clen; }
    // For lastIndexOf, search from min(pos, clen) backwards, in code units.
    int start_units = (int)(long)pos_d;
    if (start_units > (int)clen) start_units = (int)clen;
    int start = (int)s_hstr.char_offset_to_byte_offset((uint)start_units);

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (search_len == 0) { ctx.result.set_fastint((long)(start_units < 0 ? 0 : (long)start_units)); return; }
    if (search_len > len) { ctx.result.set_fastint(-1); return; }
    if (start > (int)(len - search_len)) start = (int)(len - search_len);

    int result = -1;
    for (int i = start; i >= 0 && i + (int)search_len <= (int)len; i--) {
        bool found = true;
        for (uint j = 0; j < search_len; j++) {
            if (data[(uint)i + j] != search_data[j]) { found = false; break; }
        }
        if (found) { result = i; break; }
    }
    if (result >= 0) {
        uint unit_idx = 0;
        uint byte_off = 0;
        while (byte_off < (uint)result) {
            byte_off += hstring::utf16_unit_byte_len(s_hstr.get_data(), byte_off);
            unit_idx++;
        }
        ctx.result.set_fastint((long)unit_idx);
    } else {
        ctx.result.set_fastint(-1);
    }
}

/// Helper: invoke @@match on an HObject `rx` with string argument `s_hstr`.
/// Looks up the @@match method on rx's prototype chain and calls it.
/// Returns false if no callable @@match was found (caller should handle fallback).
fn bool invoke_regexp_match(BuiltinContext* ctx, HObject* rx, HString* s_hstr) {
    HString* match_sym = ensure_match_symbol(ctx.heap);
    if (match_sym == null) return false;
    TVal? matcher_opt = rx.get_prop_proto(match_sym);
    if (try matcher = matcher_opt) {
        if (matcher.is_lightfunc() ||
            (matcher.is_object() && matcher.get_heapptr() != null &&
             ((HObject*)matcher.get_heapptr()).is_callable())) {
            TVal[1] args;
            args[0].set_string(s_hstr);
            TVal this_val; this_val.set_object(rx);
            TVal res = ctx.heap.call_fn(ctx.vm, matcher, &args[0], 1, this_val);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return true;
            }
            *ctx.result = res;
            return true;
        }
    }
    return false;
}

/// String.prototype.match(regexp) — ES2019 §21.1.3.11
///
/// Step 2: If regexp is an object, GetMethod(regexp, @@match); if callable,
/// invoke and return. (GetMethod returns undefined for null/undefined @@match.)
/// Steps 3-4: Create RegExpCreate(regexp, undefined) and Invoke(rx, @@match, [S]).
fn void builtin_string_proto_match(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    TVal* regexp_arg = (ctx.argc > 0) ? &ctx.regs[ctx.base_reg] : null;
    bool arg_nullish = (regexp_arg == null)
        || regexp_arg.is_null() || regexp_arg.is_undefined();

    // Step 2: If regexp is neither undefined nor null, check @@match.
    if (!arg_nullish && regexp_arg.is_object() && regexp_arg.get_heapptr() != null) {
        HObject* arg_obj = (HObject*)regexp_arg.get_heapptr();
        HString* match_sym = ensure_match_symbol(ctx.heap);
        if (match_sym != null) {
            TVal? matcher_opt = builtins_generic_get(arg_obj, match_sym, ctx);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (try matcher = matcher_opt) {
                // GetMethod: if null or undefined, treat as not found and fall through.
                if (!matcher.is_undefined() && !matcher.is_null()) {
                    if (matcher.is_lightfunc() ||
                        (matcher.is_object() && matcher.get_heapptr() != null &&
                         ((HObject*)matcher.get_heapptr()).is_callable())) {
                        TVal[1] args;
                        args[0].set_string(s_hstr);
                        TVal this_val = *regexp_arg;
                        TVal res = ctx.heap.call_fn(ctx.vm, matcher, &args[0], 1, this_val);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                        }
                        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                        *ctx.result = res;
                        return;
                    }
                }
            }
        }
    }

    // Steps 3-4: Let rx = RegExpCreate(regexp, undefined); return Invoke(rx, @@match, [S]).
    // ToString the pattern: null → "null", undefined/missing → "", anything else → ToString.
    char[16] pat_buf;
    int pat_len = 0;
    if (!arg_nullish) {
        if (regexp_arg.is_string()) {
            HString* ps = (HString*)regexp_arg.get_heapptr();
            if (ps != null && !ps.is_symbol()) {
                // Use the string directly as the pattern.
                HObject* rx = create_regexp_from_string(ctx.heap, ps.get_data(), 0);
                if (rx == null) { ctx.result.set_null(); return; }
                if (!invoke_regexp_match(ctx, rx, s_hstr)) { ctx.result.set_null(); }
                return;
            }
        }
        // For objects whose @@match is null/undefined, convert to string (via toString)
        // then create a RegExp from that string.
        HString* pat_str;
        if (regexp_arg.is_object()) {
            pat_str = builtin_to_string_vm(ctx, regexp_arg);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        } else {
            pat_str = builtin_to_string(ctx.heap, regexp_arg);
        }
        if (pat_str == null) { ctx.result.set_null(); return; }
        HObject* rx = create_regexp_from_string(ctx.heap, pat_str.get_data(), 0);
        if (rx == null) { ctx.result.set_null(); return; }
        if (!invoke_regexp_match(ctx, rx, s_hstr)) { ctx.result.set_null(); }
        return;
    } else {
        // arg is missing/null/undefined → RegExpCreate("" or "null") then @@match.
        if (regexp_arg != null && regexp_arg.is_null()) {
            char[] s = "null";
            pat_len = s.len;
            mem::copy(&pat_buf[0], s.ptr, (sz)(s.len));
        }
        HObject* rx = create_regexp_from_string(ctx.heap, pat_buf[:pat_len], 0);
        if (rx == null) { ctx.result.set_null(); return; }
        if (!invoke_regexp_match(ctx, rx, s_hstr)) { ctx.result.set_null(); }
        return;
    }
}

/// (Unused internal helper — RegExp@@match dispatch now handles direct exec.)
fn void builtin_string_proto_match_regexp(BuiltinContext* ctx, HString* s_hstr, HObject* rx) {
    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    // Get global flag
    bool global_flag = ((*rx.extra_ptr()).regexp.flags & 1) != 0;

    if (!global_flag) {
            // Non-global: single exec call
            int out_start = 0;
            int out_end = 0;
            int out_num_captures = 0;
            int[re_bindings::RE_MAX_CAPTURES] caps_start;
            int[re_bindings::RE_MAX_CAPTURES] caps_end;
            mem::clear(&caps_start, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));
            mem::clear(&caps_end, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));

            // Get lastIndex
            HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
            int start_pos = 0;
            if (try liv = rx.get_prop(li_key)) {
                if (liv.is_fastint()) { start_pos = (int)liv.get_fastint(); }
                else if (liv.is_number()) { start_pos = (int)liv.get_number(); }
            }

            int result = re_bindings::re_exec(
                (*rx.extra_ptr()).regexp.regexp_data, input, input_len, start_pos,
                &out_start, &out_end, &out_num_captures,
                &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
            );

            if (result != re_bindings::RE_MATCH) {
                ctx.result.set_null();
                return;
            }

            // Build result array with .groups and .indices (when d flag is set)
            int num_caps = out_num_captures;
            if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
            void* re_data = (*rx.extra_ptr()).regexp.regexp_data;
            bool has_indices = ((*rx.extra_ptr()).regexp.flags & 64) != 0;
            HObject* arr = regexp_build_match_result(ctx, re_data, s_hstr, input, input_len,
                                                     out_start, out_end,
                                                     &caps_start, &caps_end, num_caps, has_indices);
            if (arr == null) { ctx.result.set_null(); return; }
            ctx.result.set_object(arr);
            return;
        } else {
            // Global: collect all matches
            HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");

            // Reset lastIndex to 0
            TVal zero_tv;
            zero_tv.set_fastint(0);
            rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);

            HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err = arr_raw) { ctx.result.set_null(); return; }
            HObject* arr = arr_raw;
            arr.prototype = ctx.heap.array_proto;

            uint arr_idx = 0;
            int search_pos = 0;

            while (search_pos <= input_len) {
                int out_start = 0;
                int out_end = 0;
                int out_num_captures = 0;
                int[re_bindings::RE_MAX_CAPTURES] caps_start;
                int[re_bindings::RE_MAX_CAPTURES] caps_end;
                mem::clear(&caps_start, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));
                mem::clear(&caps_end, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));

                int result = re_bindings::re_exec(
                    (*rx.extra_ptr()).regexp.regexp_data, input, input_len, search_pos,
                    &out_start, &out_end, &out_num_captures,
                    &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
                );

                if (result != re_bindings::RE_MATCH) break;

                // Add match string to array
                usz match_len = (usz)(out_end - out_start);
                HString* match_str;
                if (match_len == 0) {
                    match_str = builtin_intern_string(ctx.heap, "");
                } else {
                    match_str = builtin_intern_string(ctx.heap, input[out_start : match_len]);
                }
                TVal elem;
                elem.set_string(match_str);
                arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC);
                arr_idx++;

                // Advance: if empty match, move by one code unit (or surrogate
                // pair under the u/v flag); else go to end of match
                if (out_end == search_pos) {
                    bool unicode_flag = ((*rx.extra_ptr()).regexp.flags & (16 | 128)) != 0;
                    search_pos = out_end + (int)hstring::advance_string_index_byte_len(
                        input[:input_len], (uint)out_end, unicode_flag);
                    if (search_pos > input_len) break;
                } else {
                    search_pos = out_end;
                }
            }

            if (arr_idx == 0) {
                // Reset lastIndex
                rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
                ctx.result.set_null();
                return;
            }

            // Update lastIndex on the regexp
            TVal li_tv;
            li_tv.set_fastint(0);
            rx.put_prop(li_key, li_tv, hobject::PROP_FLAGS_WEC);

            TVal len_tv;
            len_tv.set_fastint((long)arr_idx);
            HString* len_key = builtin_intern_string(ctx.heap, "length");
            arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

            ctx.result.set_object(arr);
            return;
        }
}

/// Helper: create a RegExp HObject from a pattern string with JS flags.
/// Used by matchAll for the non-RegExp arg path.
/// Returns null on failure (allocation or compile error).
fn HObject* create_regexp_from_string(Heap* heap, char[] pattern, int js_flags) {
    // Compute engine flags from js_flags (only i, m, s, u, y, d, v affect compilation)
    int engine_flags = 0;
    if (js_flags & 2)   engine_flags |= re_bindings::RE_FLAG_IGNORECASE;
    if (js_flags & 4)   engine_flags |= re_bindings::RE_FLAG_MULTILINE;
    if (js_flags & 8)   engine_flags |= re_bindings::RE_FLAG_DOTALL;
    if (js_flags & 16)  engine_flags |= re_bindings::RE_FLAG_UNICODE;
    if (js_flags & 32)  engine_flags |= re_bindings::RE_FLAG_STICKY;
    if (js_flags & 64)  engine_flags |= re_bindings::RE_FLAG_INDICES;
    if (js_flags & 128) engine_flags |= re_bindings::RE_FLAG_UNICODE_SETS;

    // Compile the regexp
    char[128] error_buf;
    void* compiled = re_bindings::re_compile(
        (char*)pattern.ptr, pattern.len,
        engine_flags, &error_buf, 128
    );
    if (compiled == null) return null;

    HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.REGEXP);
    if (catch err = obj_raw) {
        re_bindings::re_free(compiled);
        return null;
    }
    HObject* obj = obj_raw;
    obj.prototype = heap.regexp_proto;
    (*obj.extra_ptr()).regexp.regexp_data = compiled;
    (*obj.extra_ptr()).regexp.flags = js_flags;

    // Store pattern string as primitive_value
    HString* pattern_hs = builtin_intern_string(heap, pattern);
    if (pattern_hs != null) {
        (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);
    }

    // Set lastIndex to 0
    HString* li_key = builtin_intern_string(heap, "lastIndex");
    TVal zero_tv; zero_tv.set_fastint(0);
    obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);

    return obj;
}

/// Helper: create a RegExpStringIterator object with .next() method.
fn HObject* create_regexp_string_iterator(Heap* heap, HObject* rx, HString* s_hstr, bool global_flag) {
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.REGEXP_STRING_ITERATOR);
    if (catch err = iter_raw) return null;
    HObject* iter = iter_raw;

    // Store string (for GC tracing) and regexp
    TVal str_tv;
    str_tv.set_string(s_hstr);
    (*iter.extra_ptr()).regexp_iter.string_val = str_tv;
    (*iter.extra_ptr()).regexp_iter.regexp = rx;
    (*iter.extra_ptr()).regexp_iter.flags = global_flag ? 1u : 0u; // bit 0 = global

    iter.prototype = heap.iterator_proto;

    // Add .next method as an own property
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.REGEXP_STRING_ITERATOR_NEXT.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    return iter;
}

/// Helper: invoke @@matchAll on `rx` with string `s_hstr` as argument.
/// Throws TypeError if @@matchAll is not callable (per spec Invoke semantics).
/// Returns true if the call was attempted (result set); false on TypeError thrown.
fn bool invoke_regexp_matchall(BuiltinContext* ctx, HObject* rx, HString* s_hstr) {
    HString* matchall_sym = ensure_matchall_symbol(ctx.heap);
    if (matchall_sym == null) return false;
    // Use get_prop_proto so accessor getters on the prototype chain are NOT invoked
    // (we need the raw property lookup first; actual invoke via call_fn handles the call).
    // For @@matchAll on created rx (steps 4-5), use proto-chain lookup.
    TVal? matcher_opt = rx.get_prop_proto(matchall_sym);
    if (try matcher = matcher_opt) {
        if (matcher.is_lightfunc() ||
            (matcher.is_object() && matcher.get_heapptr() != null &&
             ((HObject*)matcher.get_heapptr()).is_callable())) {
            TVal[1] args;
            args[0].set_string(s_hstr);
            TVal this_val; this_val.set_object(rx);
            TVal res = ctx.heap.call_fn(ctx.vm, matcher, &args[0], 1, this_val);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
            }
            if (ctx.should_throw) { ctx.result.set_undefined(); return true; }
            *ctx.result = res;
            return true;
        }
    }
    // @@matchAll not found or not callable → TypeError (Invoke requires callable).
    builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
        "RegExp[Symbol.matchAll] is not a function");
    return false;
}

/// String.prototype.matchAll(regexp) — ES2021 §22.1.3.14
///
/// Step 2: IsRegExp check + Get("flags") + "g" check; then GetMethod(@@matchAll)
/// delegation for any non-null/undefined argument. Steps 3-5: RegExpCreate with "g"
/// flag + Invoke(@@matchAll) on the result.
fn void builtin_string_proto_matchAll(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

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
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (try mtv = match_tv_opt) {
                if (!mtv.is_undefined()) {
                    match_sym_seen = true;
                    is_regexp_like = builtin_to_boolean(&mtv);
                }
            }
        }
        if (!match_sym_seen) {
            is_regexp_like = is_regexp_object(regexp_arg);
        }

        // Step 2b: If isRegExp, Get("flags") and verify it contains "g".
        if (is_regexp_like) {
            HString* flags_key = builtin_intern_string(heap, "flags");
            TVal? flags_tv_opt = builtins_generic_get(arg_obj, flags_key, ctx);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            HString* flags_hstr = null;
            if (try fv = flags_tv_opt) {
                // RequireObjectCoercible(flags): undefined → TypeError.
                if (fv.is_undefined() || fv.is_null()) {
                    builtin_throw_no_result_change(ctx, heap.type_err_proto,
                        "String.prototype.matchAll: flags is null/undefined");
                    ctx.result.set_undefined();
                    return;
                }
                if (is_symbol_val(fv)) {
                    arr_throw_type_error(ctx, "Cannot convert a Symbol value to a string");
                    ctx.result.set_undefined();
                    return;
                }
                TVal* fv_ptr = &fv;
                flags_hstr = builtin_to_string_vm(ctx, fv_ptr);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            } else {
                builtin_throw_no_result_change(ctx, heap.type_err_proto,
                    "String.prototype.matchAll: missing flags property");
                ctx.result.set_undefined();
                return;
            }
            // Check that flags string contains "g".
            bool has_g = false;
            if (flags_hstr != null) {
                char* fc = flags_hstr.get_cstr();
                usz flen = flags_hstr.blen;
                for (usz i = 0; i < flen; i++) {
                    if (fc[i] == 'g') { has_g = true; break; }
                }
            }
            if (!has_g) {
                arr_throw_type_error(ctx,
                    "String.prototype.matchAll called with a non-global regular expression");
                ctx.result.set_undefined();
                return;
            }
        }

        // Step 2c: matcher = GetMethod(regexp, @@matchAll).
        HString* matchall_sym = ensure_matchall_symbol(heap);
        if (matchall_sym != null) {
            TVal? matcher_opt = builtins_generic_get(arg_obj, matchall_sym, ctx);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (try matcher = matcher_opt) {
                // GetMethod: null or undefined → treat as not found, fall through.
                if (!matcher.is_undefined() && !matcher.is_null()) {
                    if (matcher.is_lightfunc() ||
                        (matcher.is_object() && matcher.get_heapptr() != null &&
                         ((HObject*)matcher.get_heapptr()).is_callable())) {
                        TVal[1] args;
                        args[0].set_string(s_hstr);
                        TVal this_val = *regexp_arg;
                        TVal res = ctx.heap.call_fn(ctx.vm, matcher, &args[0], 1, this_val);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                        }
                        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                        *ctx.result = res;
                        return;
                    }
                    // matcher found but not callable → TypeError.
                    arr_throw_type_error(ctx, "regexp[Symbol.matchAll] is not a function");
                    ctx.result.set_undefined();
                    return;
                }
            }
        }
    }

    // Steps 3-5: S = ToString(O) [done], rx = RegExpCreate(regexp, "g"),
    //            Return Invoke(rx, @@matchAll, [S]).
    // Pattern: null → "null", missing/undefined → "" (empty), string → use directly,
    //          non-string non-null non-undefined → ToString.
    char[16] pat_buf;
    int pat_len = 0;
    if (!arg_nullish) {
        if (regexp_arg.is_string()) {
            HString* ps = (HString*)regexp_arg.get_heapptr();
            if (ps != null && !ps.is_symbol()) {
                HObject* rx = create_regexp_from_string(heap, ps.get_data(), 1);
                if (rx == null) { ctx.result.set_undefined(); return; }
                invoke_regexp_matchall(ctx, rx, s_hstr);
                return;
            }
        }
        // Objects whose @@matchAll is null/undefined: stringify the object then RegExpCreate.
        HString* pat_str;
        if (regexp_arg.is_object()) {
            pat_str = builtin_to_string_vm(ctx, regexp_arg);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        } else {
            pat_str = builtin_to_string(heap, regexp_arg);
        }
        if (pat_str == null) { ctx.result.set_undefined(); return; }
        HObject* rx = create_regexp_from_string(heap, pat_str.get_data(), 1);
        if (rx == null) { ctx.result.set_undefined(); return; }
        invoke_regexp_matchall(ctx, rx, s_hstr);
        return;
    } else {
        // arg is null → pattern "null"; arg is missing/undefined → pattern "".
        if (regexp_arg != null && regexp_arg.is_null()) {
            char[] s = "null";
            pat_len = (int)s.len;
            mem::copy(&pat_buf[0], s.ptr, (sz)(s.len));
        }
        HObject* rx = create_regexp_from_string(heap, pat_buf[:pat_len], 1);
        if (rx == null) { ctx.result.set_undefined(); return; }
        invoke_regexp_matchall(ctx, rx, s_hstr);
        return;
    }
}

/// String.prototype.normalize([form]) — ES6 §21.1.3.12
///
/// Supports NFC, NFD, NFKC, NFKD via QuickJS's libunicode.
fn void builtin_string_proto_normalize(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    // Default form: NFC
    int n_type = unicode_bindings::UNICODE_NFC;

    // Process form argument (ES6 §21.1.3.12 steps 3-5)
    // If form is not provided or is undefined, default to NFC.
    if (ctx.argc > 0 && !ctx.regs[ctx.base_reg].is_undefined()) {
        HString* form = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (form != null) {
            char* f = form.get_cstr();
            uint flen = form.blen;

            // Map form string to enum value (case-insensitive)
            bool valid = false;
            if (flen == 3) {
                char c0 = f[0] | 0x20;
                char c1 = f[1] | 0x20;
                char c2 = f[2] | 0x20;
                if (c0 == 'n' && c1 == 'f') {
                    if (c2 == 'c') { n_type = unicode_bindings::UNICODE_NFC; valid = true; }
                    else if (c2 == 'd') { n_type = unicode_bindings::UNICODE_NFD; valid = true; }
                }
            } else if (flen == 4) {
                char c0 = f[0] | 0x20;
                char c1 = f[1] | 0x20;
                char c2 = f[2] | 0x20;
                char c3 = f[3] | 0x20;
                if (c0 == 'n' && c1 == 'f' && c2 == 'k') {
                    if (c3 == 'c') { n_type = unicode_bindings::UNICODE_NFKC; valid = true; }
                    else if (c3 == 'd') { n_type = unicode_bindings::UNICODE_NFKD; valid = true; }
                }
            }
            if (!valid) {
                // Throw RangeError for invalid form
                builtin_throw(ctx, ctx.heap.range_err_proto, "The normalization form should be one of NFC, NFD, NFKC, NFKD.");
                return;
            }
        }
    }

    // Empty string fast path
    if (s_hstr.blen == 0) {
        ctx.result.set_string(s_hstr);
        return;
    }

    // ── Step 1: Decode CESU-8 → Unicode codepoints (reassembling surrogate pairs) ──
    char* raw_data = s_hstr.get_cstr();
    uint blen = s_hstr.blen;

    uint num_cps;
    uint* src_cps = cesu8_to_codepoints(raw_data, blen, &num_cps);
    if (src_cps == null) {
        ctx.result.set_string(s_hstr);
        return;
    }

    // ── Step 2: Run Unicode normalization via libunicode ────────────────────
    int out_len = 0;
    uint* result_cps = unicode_bindings::unicode_normalize_simple(src_cps,
                        (int)num_cps, n_type, &out_len);
    mem::free(src_cps);

    if (result_cps == null || out_len < 0) {
        if (result_cps != null) mem::free(result_cps);
        ctx.result.set_string(s_hstr);
        return;
    }

    // Handle empty result
    if (out_len == 0) {
        mem::free(result_cps);
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    // ── Step 3: Encode normalized codepoints back to CESU-8 ─────────────────
    // Worst case: 6 bytes per codepoint (astral in CESU-8)
    usz out_bytes_max = (usz)out_len * 6 + 1;
    char* out_buf = (char*)alloc::malloc_try(mem, (sz)(out_bytes_max)) ?? null;
    if (out_buf == null) {
        mem::free(result_cps);
        ctx.result.set_string(s_hstr);
        return;
    }

    uint out_off = 0;
    for (int i = 0; i < out_len; i++) {
        uint written = cesu8_encode_codepoint(result_cps[i], out_buf + out_off,
                                              (uint)(out_bytes_max - out_off));
        out_off += written;
    }
    mem::free(result_cps);

    // ── Step 4: Create HString from CESU-8 bytes ────────────────────────────
    HString* result_hstr = ctx.heap.str_intern(out_buf[:out_off]);
    mem::free(out_buf);

    if (result_hstr != null) {
        ctx.result.set_string(result_hstr);
    } else {
        ctx.result.set_string(s_hstr);
    }
}

// ============================================================================
// String.prototype.isWellFormed / toWellFormed  (ES2024 §21.1.3.7 / §21.1.3.27)
// ============================================================================
//
// Both methods operate on the UTF-16 code-unit view of the string.  Because
// internal storage is CESU-8, every code unit (including surrogate halves) is
// represented as an independent 1-3 byte UTF-8-shaped sequence.  We scan by
// decoding each sequence; a lone surrogate is:
//   - a high surrogate (0xD800-0xDBFF) NOT immediately followed by a low
//     surrogate (0xDC00-0xDFFF), OR
//   - a low surrogate that is not the second unit of such a pair.
//
// isWellFormed: O(n) scan, returns boolean, no allocation.
// toWellFormed: O(n) scan + allocation of worst-case same byte length (every
// non-surrogate code unit is already well-formed; lone surrogates are replaced
// by U+FFFD which encodes to exactly 3 bytes — same as the surrogate itself).

/// String.prototype.isWellFormed() — ES2024 §21.1.3.7
/// Returns true iff the string's UTF-16 code-unit sequence contains no lone
/// (unpaired) surrogate code units.
fn void builtin_string_proto_isWellFormed(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    char[] data = s_hstr.get_data();
    uint len = (uint)data.len;
    uint i = 0;
    while (i < len) {
        uint seq_len = hstring::utf8_seq_len(data[i]);
        uint cp = hstring::decode_codepoint(data, i);
        if (hstring::is_high_surrogate(cp)) {
            // Must be paired with an immediately following low surrogate.
            uint next_off = i + seq_len;
            if (next_off >= len) {
                // High surrogate at end-of-string — lone.
                ctx.result.set_boolean(false);
                return;
            }
            uint next_cp = hstring::decode_codepoint(data, next_off);
            if (!hstring::is_low_surrogate(next_cp)) {
                // High surrogate followed by something that is not a low
                // surrogate — lone.
                ctx.result.set_boolean(false);
                return;
            }
            // Valid surrogate pair: skip both code units.
            uint low_len = hstring::utf8_seq_len(data[next_off]);
            i = next_off + low_len;
        } else if (hstring::is_low_surrogate(cp)) {
            // Low surrogate without a preceding high surrogate — lone.
            ctx.result.set_boolean(false);
            return;
        } else {
            i += seq_len;
        }
    }
    ctx.result.set_boolean(true);
}

/// String.prototype.toWellFormed() — ES2024 §21.1.3.27
/// Returns a copy of the string with every lone surrogate code unit replaced
/// by U+FFFD (REPLACEMENT CHARACTER, UTF-8: 0xEF 0xBF 0xBD).
fn void builtin_string_proto_toWellFormed(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    char[] data = s_hstr.get_data();
    uint len = (uint)data.len;

    // Fast path: empty string.
    if (len == 0) {
        ctx.result.set_string(s_hstr);
        return;
    }

    // Allocate output buffer.  Lone surrogates encode as 3 bytes in CESU-8
    // and U+FFFD also encodes as 3 bytes, so the output length is at most
    // the input length.  We use the same heap allocator as other methods.
    char* buf = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)len);
    if (buf == null) { ctx.result.set_string(s_hstr); return; }

    uint i = 0;
    uint o = 0;
    while (i < len) {
        uint seq_len = hstring::utf8_seq_len(data[i]);
        uint cp = hstring::decode_codepoint(data, i);

        if (hstring::is_high_surrogate(cp)) {
            uint next_off = i + seq_len;
            if (next_off < len) {
                uint next_cp = hstring::decode_codepoint(data, next_off);
                if (hstring::is_low_surrogate(next_cp)) {
                    // Valid surrogate pair: copy both code units verbatim.
                    uint low_len = hstring::utf8_seq_len(data[next_off]);
                    for (uint k = 0; k < seq_len; k++) buf[o++] = data[i + k];
                    for (uint k = 0; k < low_len; k++) buf[o++] = data[next_off + k];
                    i = next_off + low_len;
                    continue;
                }
            }
            // Lone high surrogate — emit U+FFFD (3 bytes: EF BF BD).
            buf[o++] = (char)0xEF;
            buf[o++] = (char)0xBF;
            buf[o++] = (char)0xBD;
            i += seq_len;
        } else if (hstring::is_low_surrogate(cp)) {
            // Lone low surrogate — emit U+FFFD.
            buf[o++] = (char)0xEF;
            buf[o++] = (char)0xBF;
            buf[o++] = (char)0xBD;
            i += seq_len;
        } else {
            // Non-surrogate code unit: copy bytes verbatim.
            for (uint k = 0; k < seq_len; k++) buf[o++] = data[i + k];
            i += seq_len;
        }
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:o]);
    ctx.heap.free_func(ctx.heap.heap_udata, buf);
    if (result != null) {
        ctx.result.set_string(result);
    } else {
        ctx.result.set_string(s_hstr);
    }
}

/// Helper: invoke @@search on `rx` with string `s_hstr` as argument.
/// Returns false if no callable @@search found on the prototype chain.
fn bool invoke_regexp_search(BuiltinContext* ctx, HObject* rx, HString* s_hstr) {
    HString* search_sym = ensure_search_symbol(ctx.heap);
    if (search_sym == null) return false;
    TVal? searcher_opt = rx.get_prop_proto(search_sym);
    if (try searcher = searcher_opt) {
        if (searcher.is_lightfunc() ||
            (searcher.is_object() && searcher.get_heapptr() != null &&
             ((HObject*)searcher.get_heapptr()).is_callable())) {
            TVal[1] args;
            args[0].set_string(s_hstr);
            TVal this_val; this_val.set_object(rx);
            TVal res = ctx.heap.call_fn(ctx.vm, searcher, &args[0], 1, this_val);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
            }
            if (ctx.should_throw) { ctx.result.set_undefined(); return true; }
            *ctx.result = res;
            return true;
        }
    }
    return false;
}

/// String.prototype.search(regexp) — ES2019 §21.1.3.15
///
/// Step 2: If regexp is an object, GetMethod(regexp, @@search); if callable,
/// invoke and return. (null/undefined @@search treated as "not found" per GetMethod.)
/// Steps 3-4: Create RegExpCreate(regexp, undefined) and Invoke(rx, @@search, [S]).
fn void builtin_string_proto_search(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    TVal* regexp_arg = (ctx.argc > 0) ? &ctx.regs[ctx.base_reg] : null;
    bool arg_nullish = (regexp_arg == null)
        || regexp_arg.is_null() || regexp_arg.is_undefined();

    // Step 2: If regexp is neither undefined nor null, check @@search.
    if (!arg_nullish && regexp_arg.is_object() && regexp_arg.get_heapptr() != null) {
        HObject* arg_obj = (HObject*)regexp_arg.get_heapptr();
        HString* search_sym = ensure_search_symbol(ctx.heap);
        if (search_sym != null) {
            TVal? searcher_opt = builtins_generic_get(arg_obj, search_sym, ctx);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (try searcher = searcher_opt) {
                // GetMethod: null or undefined → treat as not found, fall through.
                if (!searcher.is_undefined() && !searcher.is_null()) {
                    if (searcher.is_lightfunc() ||
                        (searcher.is_object() && searcher.get_heapptr() != null &&
                         ((HObject*)searcher.get_heapptr()).is_callable())) {
                        TVal[1] args;
                        args[0].set_string(s_hstr);
                        TVal this_val = *regexp_arg;
                        TVal res = ctx.heap.call_fn(ctx.vm, searcher, &args[0], 1, this_val);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                        }
                        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                        *ctx.result = res;
                        return;
                    }
                }
            }
        }
    }

    // Steps 3-4: RegExpCreate(regexp, undefined) then Invoke(rx, @@search, [S]).
    // For missing/null/undefined arg use empty pattern string (undefined) or "null".
    char[16] pat_buf;
    int pat_len = 0;
    if (!arg_nullish) {
        if (regexp_arg.is_string()) {
            HString* ps = (HString*)regexp_arg.get_heapptr();
            if (ps != null && !ps.is_symbol()) {
                HObject* rx = create_regexp_from_string(ctx.heap, ps.get_data(), 0);
                if (rx == null) { ctx.result.set_fastint(-1); return; }
                if (!invoke_regexp_search(ctx, rx, s_hstr)) { ctx.result.set_fastint(-1); }
                return;
            }
        }
        // For objects whose @@search is null/undefined, stringify and create RegExp.
        HString* pat_str;
        if (regexp_arg.is_object()) {
            pat_str = builtin_to_string_vm(ctx, regexp_arg);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        } else {
            pat_str = builtin_to_string(ctx.heap, regexp_arg);
        }
        if (pat_str == null) { ctx.result.set_fastint(-1); return; }
        HObject* rx = create_regexp_from_string(ctx.heap, pat_str.get_data(), 0);
        if (rx == null) { ctx.result.set_fastint(-1); return; }
        if (!invoke_regexp_search(ctx, rx, s_hstr)) { ctx.result.set_fastint(-1); }
        return;
    } else {
        // arg is missing/null/undefined → pattern "" or "null"
        if (regexp_arg != null && regexp_arg.is_null()) {
            char[] s = "null";
            pat_len = s.len;
            mem::copy(&pat_buf[0], s.ptr, (sz)(s.len));
        }
        HObject* rx = create_regexp_from_string(ctx.heap, pat_buf[:pat_len], 0);
        if (rx == null) { ctx.result.set_fastint(-1); return; }
        if (!invoke_regexp_search(ctx, rx, s_hstr)) { ctx.result.set_fastint(-1); }
        return;
    }
}
fn bool register_string_constructor(EnvRecord* global_env, Heap* heap) {
    // Create String.prototype — an exotic String object with [[StringData]] = ""
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.STRING);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    // Set [[StringData]] to "" so valueOf/toString work on String.prototype itself.
    HString* empty_str = builtin_intern_string(heap, "");
    if (empty_str != null) {
        (*proto.extra_ptr()).prim.primitive_value.set_string(empty_str);
    }
    // String.prototype is a String exotic object, so it carries its own
    // `length` data property (= 0 for the empty [[StringData]]), non-writable,
    // non-enumerable, non-configurable (ES §22.1.3).
    HString* proto_len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal proto_len_tv;
    proto_len_tv.set_fastint(0);
    proto.put_prop(proto_len_key, proto_len_tv, hobject::PROP_FLAGS_NNC);
    heap.string_proto = proto;

    // Add .toString() method
    HString* tostring_key = (HString*)heap.strs[heap::BuiltinStr.TO_STRING];
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)Builtin.STRING_PROTO_TOSTRING.ordinal);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .valueOf() method
    HString* valueof_key = (HString*)heap.strs[heap::BuiltinStr.VALUE_OF];
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)Builtin.STRING_PROTO_VALUEOF.ordinal);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC);

    // Add String.prototype methods (Phase 6b)
    if (!register_string_proto_method(proto, heap, "charAt",     Builtin.STRING_PROTO_CHARAT.ordinal))     return false;
    if (!register_string_proto_method(proto, heap, "charCodeAt", Builtin.STRING_PROTO_CHARCODEAT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "indexOf",    Builtin.STRING_PROTO_INDEXOF.ordinal))    return false;
    if (!register_string_proto_method(proto, heap, "slice",      Builtin.STRING_PROTO_SLICE.ordinal))      return false;
    if (!register_string_proto_method(proto, heap, "substring",  Builtin.STRING_PROTO_SUBSTRING.ordinal))  return false;
    if (!register_string_proto_method(proto, heap, "substr",     Builtin.STRING_PROTO_SUBSTR.ordinal))     return false;
    if (!register_string_proto_method(proto, heap, "toLowerCase",Builtin.STRING_PROTO_TOLOWERCASE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toUpperCase",Builtin.STRING_PROTO_TOUPPERCASE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "trim",       Builtin.STRING_PROTO_TRIM.ordinal))       return false;
    if (!register_string_proto_method(proto, heap, "split",      Builtin.STRING_PROTO_SPLIT.ordinal))      return false;
    if (!register_string_proto_method(proto, heap, "concat",     Builtin.STRING_PROTO_CONCAT.ordinal))     return false;
    if (!register_string_proto_method(proto, heap, "replace",    Builtin.STRING_PROTO_REPLACE.ordinal))    return false;
    if (!register_string_proto_method(proto, heap, "replaceAll", Builtin.STRING_PROTO_REPLACEALL.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "includes",   Builtin.STRING_PROTO_INCLUDES.ordinal))   return false;
    if (!register_string_proto_method(proto, heap, "startsWith", Builtin.STRING_PROTO_STARTSWITH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "endsWith",   Builtin.STRING_PROTO_ENDSWITH.ordinal))   return false;
    if (!register_string_proto_method(proto, heap, "repeat",     Builtin.STRING_PROTO_REPEAT.ordinal))     return false;
    if (!register_string_proto_method(proto, heap, "trimStart",  Builtin.STRING_PROTO_TRIMSTART.ordinal))  return false;
    if (!register_string_proto_method(proto, heap, "trimEnd",    Builtin.STRING_PROTO_TRIMEND.ordinal))    return false;
    if (!register_string_proto_method(proto, heap, "codePointAt", Builtin.STRING_PROTO_CODEPOINTAT.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "at",         Builtin.STRING_PROTO_AT.ordinal))         return false;
    if (!register_string_proto_method(proto, heap, "padStart",   Builtin.STRING_PROTO_PADSTART.ordinal))   return false;
    if (!register_string_proto_method(proto, heap, "padEnd",     Builtin.STRING_PROTO_PADEND.ordinal))     return false;
    if (!register_string_proto_method(proto, heap, "lastIndexOf", Builtin.STRING_PROTO_LASTINDEXOF.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "match",      Builtin.STRING_PROTO_MATCH.ordinal))      return false;
    if (!register_string_proto_method(proto, heap, "matchAll",   Builtin.STRING_PROTO_MATCHALL.ordinal))   return false;
    if (!register_string_proto_method(proto, heap, "search",     Builtin.STRING_PROTO_SEARCH.ordinal))     return false;
    if (!register_string_proto_method(proto, heap, "toLocaleLowerCase", Builtin.STRING_PROTO_TOLOCALELOWERCASE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toLocaleUpperCase", Builtin.STRING_PROTO_TOLOCALEUPPERCASE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "localeCompare", Builtin.STRING_PROTO_LOCALECOMPARE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "normalize",      Builtin.STRING_PROTO_NORMALIZE.ordinal))      return false;
    if (!register_string_proto_method(proto, heap, "isWellFormed",   Builtin.STRING_PROTO_ISWELLFORMED.ordinal))   return false;
    if (!register_string_proto_method(proto, heap, "toWellFormed",   Builtin.STRING_PROTO_TOWELLFORMED.ordinal))   return false;

    // Register String.prototype[@@iterator] (ES6 §21.1.3.30)
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        if (iter_sym != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.STRING_PROTO_SYMBOL_ITER.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.flags.constructable = false;
            fn_obj.prototype = heap.function_proto;
            HString* name_key = builtin_intern_string(heap, "name");
            HString* name_val = builtin_intern_string(heap, "[Symbol.iterator]");
            if (name_key != null && name_val != null) {
                TVal name_tv;
                name_tv.set_string(name_val);
                fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
            }
            HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            if (len_key != null) {
                TVal len_tv;
                len_tv.set_fastint(0);
                fn_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
            }
            TVal iter_tv;
            iter_tv.set_object(fn_obj);
            proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_WC);
        }
    }

    // Create String constructor as a proper function object (not LIGHTFUNC)
    // so it can carry static methods like String.fromCharCode.
    HObject*? str_obj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = str_obj_raw) return false;
    HObject* str_obj = str_obj_raw;
    (*str_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.STRING.ordinal;

    // Set .constructor on String.prototype to point to the actual String object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(str_obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set String.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    str_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Add String.fromCharCode (ES5 §15.5.3.2)
    if (!register_string_proto_method(str_obj, heap, "fromCharCode", Builtin.STRING_FROMCHARCODE.ordinal)) return false;
    if (!register_string_proto_method(str_obj, heap, "fromCodePoint", Builtin.STRING_FROMCODEPOINT.ordinal)) return false;
    if (!register_string_proto_method(str_obj, heap, "raw", Builtin.STRING_RAW.ordinal)) return false;

    // Register String constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("String");
    HString* existing = heap.str_table_lookup("String", hash);
    HString* str_key;
    if (existing != null) {
        str_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "String", hash);
        if (catch err2 = new_key) return false;
        heap.str_table_insert(new_key);
        str_key = new_key;
    }
    TVal str_val;
    str_val.set_object(str_obj);
    set_func_ctor_name_length(str_obj, heap, "String", 1);
    env::env_declare_nonenum(global_env, str_key, str_val);

    return true;
}

/// Helper: register a method on a prototype as a proper HObject function.
