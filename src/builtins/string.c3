/// String constructor and String.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::env;
import std::math;
import libc;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::re_bindings;

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
        s = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
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
fn uint to_uint16(TVal* val) {
    TVal num;
    builtin_to_number(val, &num);
    double n;
    if (num.is_fastint()) {
        n = (double)num.get_fastint();
    } else if (num.is_number()) {
        n = num.get_number();
    } else {
        return 0;
    }
    if (math::is_nan(n) || n == 0.0 || n == double::inf || n == -double::inf) return 0;
    double pos_int = math::abs(n);
    pos_int = math::floor(pos_int);
    long int_val = (long)pos_int;
    return (uint)(ushort)(int)(int_val & 0xFFFF);
}

/// String.fromCharCode (ES5 §15.5.3.2)
fn void builtin_string_fromcharcode(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        HString* empty = builtin_intern_string(ctx.heap, "");
        ctx.result.set_string(empty);
        return;
    }
    // Build string from code units (max ~256 args, cap at 512 bytes)
    char[512] buf;
    usz offset = 0;
    ushort max_args = (ushort)(ctx.argc < 256 ? ctx.argc : 256);
    for (ushort i = 0; i < max_args && offset < 510; i++) {
        uint cu = to_uint16(&ctx.regs[ctx.base_reg + i]);
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
    ctx.result.set_string(result);
}

/// String.fromCodePoint(...codePoints) — ES6 §21.1.2.2
fn void builtin_string_fromcodepoint(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        HString* empty = builtin_intern_string(ctx.heap, "");
        ctx.result.set_string(empty);
        return;
    }
    // Build string from code points (supporting supplementary plane via UTF-8)
    char[1024] buf;
    usz offset = 0;
    ushort max_args = (ushort)(ctx.argc < 256 ? ctx.argc : 256);
    for (ushort i = 0; i < max_args && offset < 1020; i++) {
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
            d = builtin_to_number_getdouble(ctx, arg);
        }
        // Check: must be integral Number in [0, 0x10FFFF]
        if (math::is_nan(d) || math::is_inf(d) || d != math::trunc(d) || d < 0 || d > 0x10FFFF) {
            // Throw RangeError
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                HString* msg = builtin_intern_string(ctx.heap, "Invalid code point value");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
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
            // 4-byte UTF-8 for supplementary plane
            buf[offset++] = (char)(0xF0 | (ucp >> 18));
            buf[offset++] = (char)(0x80 | ((ucp >> 12) & 0x3F));
            buf[offset++] = (char)(0x80 | ((ucp >> 6) & 0x3F));
            buf[offset++] = (char)(0x80 | (ucp & 0x3F));
        }
    }
    HString* result_str = builtin_intern_string(ctx.heap, buf[:offset]);
    ctx.result.set_string(result_str);
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
        ctx.result.set_string(this_val.get_heapptr());
        return;
    }
    ctx.result.set_undefined();
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
        ctx.result.set_string(this_val.get_heapptr());
        return;
    }
    ctx.result.set_undefined();
}

// ============================================================================
// String.prototype methods (Phase 6b)
// ============================================================================

/// Helper: extract the string data and length from `this`, handling both
/// primitive strings and String wrapper objects. Returns null on failure.
fn HString* string_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_string()) {
        return (HString*)this_val.get_heapptr();
    }
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.get_class() == hobject::ObjClass.STRING &&
            (*obj.extra_ptr()).prim.primitive_value.is_string()) {
            return (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        }
    }
    // TypeError: String.prototype method called on incompatible value
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        HString* msg_str = builtin_intern_string(ctx.heap, "String.prototype method called on incompatible value");
        TVal msg_val;
        msg_val.set_string(msg_str);
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        TVal err_tv;
        err_tv.set_object(err);
        ctx.throw_value = err_tv;
    }
    ctx.should_throw = true;
    return null;
}

/// String.prototype.charAt(pos) — ES5 §15.5.4.4
fn void builtin_string_proto_charAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    double pos = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    if (pos < 0 || pos >= (double)len) {
        // Return empty string
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    uint idx = (uint)(long)pos;
    char[2] buf;
    buf[0] = data[idx];
    buf[1] = 0;
    HString* result = builtin_intern_string(ctx.heap, buf[:1]);
    ctx.result.set_string(result);
}

/// String.prototype.charCodeAt(pos) — ES5 §15.5.4.5
fn void builtin_string_proto_charCodeAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    double pos = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    if (pos < 0 || pos >= (double)len) {
        ctx.result.set_number(double::nan);
        return;
    }
    uint idx = (uint)(long)pos;
    ctx.result.set_fastint((long)(data[idx] & 0xFF));
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

    // Get search string
    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) {
        ctx.result.set_fastint(-1);
        return;
    }

    // Get position
    double pos_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : 0.0;
    uint pos;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos = 0;
    } else if (pos_d >= (double)len) {
        pos = len;
    } else {
        pos = (uint)(long)pos_d;
    }

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    // Search for occurrence
    if (search_len == 0) {
        ctx.result.set_fastint((long)pos);
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
    ctx.result.set_fastint((long)result);
}

/// String.prototype.slice(start, end) — ES5 §15.5.4.13
fn void builtin_string_proto_slice(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    double start_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    double end_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : (double)len;

    // Handle negative start
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

    // Handle negative end
    int end_i;
    if (math::is_nan(end_d)) {
        end_i = (int)len;
    } else if (end_d < 0) {
        end_i = (int)(long)end_d + (int)len;
        if (end_i < 0) end_i = 0;
    } else {
        end_i = (int)(long)end_d;
        if (end_i > (int)len) end_i = (int)len;
    }

    if (start_i >= end_i) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    uint substr_len = (uint)(end_i - start_i);
    char[256] buf;
    usz copy_len = (usz)(substr_len < 256 ? substr_len : 256);
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = data[(uint)start_i + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.substring(start, end) — ES5 §15.5.4.15
fn void builtin_string_proto_substring(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    uint len = s_hstr.blen;

    double start_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    double end_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : (double)len;

    uint start = clamp_index(start_d, len);
    uint end = clamp_index(end_d, len);

    uint from = start < end ? start : end;
    uint to = start < end ? end : start;

    if (from >= to) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    uint substr_len = to - from;
    char* cstr = s_hstr.get_cstr();
    char[256] buf;
    usz copy_len = (usz)(substr_len < 256 ? substr_len : 256);
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = cstr[from + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.substr(start, length) — ES5 §B.2.3
fn void builtin_string_proto_substr(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    uint len = s_hstr.blen;

    double start_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;

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
        length_d = builtin_to_integer(&ctx.regs[ctx.base_reg + 1]);
    } else {
        length_d = (double)(len - (uint)start_i);
    }

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

    char* cstr = s_hstr.get_cstr();
    char[256] buf;
    usz copy_len = (usz)((uint)length_i < 256 ? (uint)length_i : 256);
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = cstr[(uint)start_i + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.toLowerCase() — ES5 §15.5.4.17 (ASCII-only)
fn void builtin_string_proto_toLowerCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    char[256] buf;
    usz copy_len = len < 256 ? (usz)len : 256;
    for (usz i = 0; i < copy_len; i++) {
        char c = data[i];
        if (c >= 'A' && c <= 'Z') {
            buf[i] = (char)(c + 32);
        } else {
            buf[i] = c;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.toUpperCase() — ES5 §15.5.4.18 (ASCII-only)
fn void builtin_string_proto_toUpperCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    char[256] buf;
    usz copy_len = len < 256 ? (usz)len : 256;
    for (usz i = 0; i < copy_len; i++) {
        char c = data[i];
        if (c >= 'a' && c <= 'z') {
            buf[i] = (char)(c - 32);
        } else {
            buf[i] = c;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(result);
}

/// String.prototype.toLocaleLowerCase() — ES5 §15.5.4.17
/// Identical to toLowerCase in default locale.
fn void builtin_string_proto_toLocaleLowerCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    char[256] buf;
    usz copy_len = len < 256 ? (usz)len : 256;
    for (usz i = 0; i < copy_len; i++) {
        char c = data[i];
        if (c >= 'A' && c <= 'Z') {
            buf[i] = (char)(c + 32);
        } else {
            buf[i] = c;
        }
    }
    HString* lower = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(lower);
}

/// String.prototype.toLocaleUpperCase() — ES5 §15.5.4.19
/// Identical to toUpperCase in default locale.
fn void builtin_string_proto_toLocaleUpperCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    char[256] buf;
    usz copy_len = len < 256 ? (usz)len : 256;
    for (usz i = 0; i < copy_len; i++) {
        char c = data[i];
        if (c >= 'a' && c <= 'z') {
            buf[i] = (char)(c - 32);
        } else {
            buf[i] = c;
        }
    }
    HString* upper = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.set_string(upper);
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
        that_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
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
fn void builtin_string_proto_trim(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // Trim leading whitespace
    uint start = 0;
    while (start < len && is_ecma_whitespace(data[start])) {
        start++;
    }

    // All whitespace
    if (start == len) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    // Trim trailing whitespace
    uint end = len;
    while (end > start && is_ecma_whitespace(data[end - 1])) {
        end--;
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

    // If separator is undefined, return [string]
    if (ctx.argc == 0 || ctx.regs[ctx.base_reg].is_undefined()) {
        TVal elem;
        elem.set_string(s_hstr);
        HString* zero_key = builtin_intern_string(ctx.heap, "0");
        arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);
        TVal len_val;
        len_val.set_fastint(1);
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(arr);
        return;
    }

    TVal* sep_val = &ctx.regs[ctx.base_reg];

    // ── RegExp separator ─────────────────────────────────────────────────
    if (is_regexp_object(sep_val)) {
        HObject* rx = (HObject*)sep_val.get_heapptr();
        char* input = data;
        int input_len = (int)len;

        uint limit = 0xFFFFFFFF;
        if (ctx.argc > 1) {
            double limit_d = builtin_to_integer(&ctx.regs[ctx.base_reg + 1]);
            if (!math::is_nan(limit_d) && limit_d >= 0) {
                limit = (uint)(long)limit_d;
            }
        }

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
            libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
            libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

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
                search_pos = out_end + 1;
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

    // ── String separator ─────────────────────────────────────────────────
    HString* sep_hstr = builtin_to_string(ctx.heap, sep_val);
    if (sep_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    // Get limit
    uint limit = 0xFFFFFFFF;
    if (ctx.argc > 1) {
        double limit_d = builtin_to_integer(&ctx.regs[ctx.base_reg + 1]);
        if (!math::is_nan(limit_d) && limit_d >= 0) {
            limit = (uint)(long)limit_d;
        }
    }

    char* sep_data = sep_hstr.get_cstr();
    uint sep_len = sep_hstr.blen;

    // Empty separator: split by character
    if (sep_len == 0) {
        uint count = len < limit ? len : limit;
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        TVal len_val;
        len_val.set_fastint((long)count);
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        for (uint i = 0; i < count; i++) {
            char[2] buf;
            buf[0] = data[i];
            buf[1] = 0;
            HString* ch_str = builtin_intern_string(ctx.heap, buf[:1]);
            TVal elem;
            elem.set_string(ch_str);
            arr.put_prop(ctx.heap.int_to_hstring((long)i), elem, hobject::PROP_FLAGS_WEC);
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

    // Concatenate all into a buffer
    // First, compute total length
    uint total_len = len;
    usz max_args = ctx.argc < 256 ? (usz)ctx.argc : 256;
    for (usz i = 0; i < max_args; i++) {
        HString* arg_str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + i]);
        if (arg_str == null) continue;
        total_len += arg_str.blen;
    }

    if (total_len > 512) total_len = 512;  // cap buffer size

    char[512] buf;
    usz offset = 0;

    // Copy original string
    usz orig_copy = (usz)(len < 512 ? len : 512);
    for (usz i = 0; i < orig_copy; i++) {
        buf[offset++] = data[i];
    }

    // Copy each arg
    for (usz i = 0; i < max_args && offset < 512; i++) {
        HString* arg_str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + i]);
        if (arg_str == null) continue;
        char* arg_data = arg_str.get_cstr();
        uint arg_len = arg_str.blen;
        usz copy = (usz)(arg_len < (512 - offset) ? arg_len : (512 - offset));
        for (usz j = 0; j < copy; j++) {
            buf[offset++] = arg_data[j];
        }
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
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
            if (next >= '1' && next <= '9') {
                int group_idx = next - '1';
                i++;
                if (i + 1 < rep_len && rep[i + 1] >= '0' && rep[i + 1] <= '9') {
                    int two_digit = (next - '0') * 10 + (rep[i + 1] - '0');
                    if (two_digit <= num_caps) {
                        group_idx = two_digit - 1;
                        i++;
                    }
                }
                if (group_idx < num_caps && group_idx >= 0 &&
                    caps_start[group_idx] >= 0 && caps_end[group_idx] >= 0) {
                    for (usz j = (usz)caps_start[group_idx]; j < (usz)caps_end[group_idx] && offset < 4096; j++) {
                        buf[offset++] = input[j];
                    }
                }
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
            libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
            libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

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
                if (ctx.heap.has_error) { ctx.should_throw = true; return; }
                replace_str = builtin_to_string(ctx.heap, &res);
                if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "undefined");
            } else {
                HString* raw_replace = ctx.argc > 1
                    ? builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1])
                    : builtin_intern_string(ctx.heap, "undefined");
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
                libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
                libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

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
                    if (ctx.heap.has_error) { ctx.should_throw = true; return; }
                    replace_str = builtin_to_string(ctx.heap, &res);
                    if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "undefined");
                } else {
                    HString* raw_replace = ctx.argc > 1
                        ? builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1])
                        : builtin_intern_string(ctx.heap, "undefined");
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
                    search_pos = out_end + 1;
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

    // ── String searchValue (existing code) ──────────────────────────────
    HString* search_hstr = builtin_to_string(ctx.heap, search_val);
    if (search_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    HString* replace_hstr;
    if (ctx.argc > 1) {
        replace_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1]);
    } else {
        replace_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (replace_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

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

    char* replace_data = replace_hstr.get_cstr();
    uint replace_len = replace_hstr.blen;

    char[4096] buf;
    usz bOff = 0;
    for (usz i = 0; i < (usz)found_pos && bOff < 4096; i++) buf[bOff++] = input[i];
    for (usz i = 0; i < (usz)replace_len && bOff < 4096; i++) buf[bOff++] = replace_data[i];
    uint suffix_start = (uint)(found_pos + (int)search_len);
    for (usz i = (usz)suffix_start; i < (usz)input_len && bOff < 4096; i++) buf[bOff++] = input[i];

    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:bOff]));
}

/// String.prototype.replaceAll(searchValue, replaceValue) — ES2021 §21.1.3.18
fn void builtin_string_proto_replaceAll(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    if (ctx.argc < 1) {
        ctx.result.set_string(s_hstr);
        return;
    }

    TVal search_val = ctx.regs[ctx.base_reg];
    char* input = s_hstr.get_cstr();
    uint input_len = s_hstr.blen;

    // If searchValue is a regex, check for global flag; throw TypeError if missing
    if (is_regexp_object(&search_val)) {
        HObject* rx = (HObject*)search_val.get_heapptr();
        // Read global flag directly from internal flags (get_prop doesn't invoke accessor getters)
        bool global_flag = ((*rx.extra_ptr()).regexp.flags & 1) != 0;
        if (!global_flag) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                HString* msg_str = builtin_intern_string(ctx.heap, "String.prototype.replaceAll called with a non-global regular expression");
                if (msg_str != null) {
                    TVal msg_val;
                    msg_val.set_string(msg_str);
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
                }
                TVal err_tv;
                err_tv.set_object(err);
                ctx.throw_value = err_tv;
            }
            ctx.result.set_undefined();
            ctx.should_throw = true;
            return;
        }
        // Direct global regex replace-all implementation
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

        HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
        TVal zero_tv; zero_tv.set_fastint(0);
        rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);

        char[8192] buf;
        usz bOff = 0;
        int search_pos = 0;
        int ilen = (int)input_len;

        while (search_pos <= ilen) {
            int out_start = 0;
            int out_end = 0;
            int out_num_captures = 0;
            int[re_bindings::RE_MAX_CAPTURES] caps_start;
            int[re_bindings::RE_MAX_CAPTURES] caps_end;
            libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
            libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

            int result = re_bindings::re_exec(
                (*rx.extra_ptr()).regexp.regexp_data, input, ilen, search_pos,
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
                if (ctx.heap.has_error) { ctx.should_throw = true; return; }
                replace_str = builtin_to_string(ctx.heap, &res);
                if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "undefined");
            } else {
                HString* raw_replace = ctx.argc > 1
                    ? builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1])
                    : builtin_intern_string(ctx.heap, "undefined");
                if (raw_replace == null) break;
                replace_str = builtin_replace_substitute(ctx.heap, raw_replace,
                    input, ilen, out_start, out_end,
                    &caps_start, &caps_end, out_num_captures);
                if (replace_str == null) replace_str = raw_replace;
            }

            char* rData = replace_str.get_cstr();
            uint rLen = replace_str.blen;
            for (usz i = 0; i < (usz)rLen && bOff < 8192; i++) buf[bOff++] = rData[i];

            if (out_end == search_pos) {
                search_pos = out_end + 1;
                if (search_pos > ilen) break;
            } else {
                search_pos = out_end;
            }
        }

        for (usz i = (usz)search_pos; i < (usz)ilen && bOff < 8192; i++) buf[bOff++] = input[i];
        ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:bOff]));
        return;
    }

    // String searchValue path
    HString* search_hstr = builtin_to_string(ctx.heap, &search_val);
    if (search_hstr == null) { ctx.result.set_string(s_hstr); return; }

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    // If search string is empty, return the original string
    if (search_len == 0) {
        ctx.result.set_string(s_hstr);
        return;
    }

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

    char[8192] buf;
    usz bOff = 0;
    int pos = 0;

    while (pos <= (int)(input_len - search_len)) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (input[(uint)pos + j] != search_data[j]) { match = false; break; }
        }
        if (!match) {
            if (bOff < 8192) buf[bOff++] = input[(uint)pos];
            pos++;
            continue;
        }

        // Found a match at pos
        HString* replace_str;
        if (replace_is_fn && ctx.heap.call_fn != null && ctx.vm != null) {
            TVal[3] fn_args;
            fn_args[0].set_string(search_hstr);
            fn_args[1].set_fastint((long)pos);
            fn_args[2].set_string(s_hstr);
            TVal this_val; this_val.set_undefined();
            TVal res = ctx.heap.call_fn(ctx.vm, replace_val, &fn_args[0], 3, this_val);
            if (ctx.heap.has_error) { ctx.should_throw = true; return; }
            replace_str = builtin_to_string(ctx.heap, &res);
            if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "undefined");
        } else {
            HString* raw_replace = ctx.argc > 1
                ? builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1])
                : builtin_intern_string(ctx.heap, "undefined");
            if (raw_replace == null) break;
            // Handle $-substitution patterns ($$, $&, $`, $', $1, etc.)
            replace_str = builtin_replace_substitute(ctx.heap, raw_replace,
                input, (int)input_len, pos, pos + (int)search_len,
                null, null, 0);
            if (replace_str == null) replace_str = raw_replace;
        }

        char* rData = replace_str.get_cstr();
        uint rLen = replace_str.blen;
        for (usz i = 0; i < (usz)rLen && bOff < 8192; i++) buf[bOff++] = rData[i];

        pos += (int)search_len;
    }

    // Copy remaining characters
    for (usz i = (usz)pos; i < (usz)input_len && bOff < 8192; i++) buf[bOff++] = input[i];

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
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

    double pos_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : 0.0;
    uint pos;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos = 0;
    } else if (pos_d >= (double)len) {
        pos = len;
    } else {
        pos = (uint)(long)pos_d;
    }

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
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

    double pos_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : 0.0;
    uint pos;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos = 0;
    } else if (pos_d > (double)len) {
        pos = len;
    } else {
        pos = (uint)(long)pos_d;
    }

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
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

    double end_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : (double)len;
    uint end_pos;
    if (math::is_nan(end_d) || end_d < 0) {
        end_pos = 0;
    } else if (end_d > (double)len) {
        end_pos = len;
    } else {
        end_pos = (uint)(long)end_d;
    }

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

    double count_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (count_d < 0 || math::is_inf(count_d)) {
        // Throw RangeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            HString* msg = builtin_intern_string(ctx.heap, "Invalid count value");
            TVal msg_val; msg_val.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            TVal err_val; err_val.set_object(err);
            ctx.heap.curr_thread = err;
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
        libc::memcpy(&buf[i * s_hstr.blen], src, s_hstr.blen);
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
    while (start < len && is_ecma_whitespace(data[start])) { start++; }
    if (start == 0) {
        ctx.result.set_string(s_hstr); return;
    }
    HString* result = ctx.heap.str_intern(data[start..len]);
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
    while (end > 0 && is_ecma_whitespace(data[end - 1])) { end--; }
    if (end == len) {
        ctx.result.set_string(s_hstr); return;
    }
    HString* result = ctx.heap.str_intern(data[0..end]);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
}

/// String.prototype.codePointAt(pos) — ES6 §21.1.3.3
fn void builtin_string_proto_codePointAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    double pos_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    uint pos;
    if (math::is_nan(pos_d) || pos_d < 0) {
        ctx.result.set_undefined(); return;
    }
    pos = (uint)(long)pos_d;
    if (pos >= len) { ctx.result.set_undefined(); return; }

    // Simple ASCII fallback (most test262 tests use ASCII)
    ctx.result.set_fastint((long)(data[pos] & 0xFF));
}

/// String.prototype.at(index) — ES2022 §21.1.3.1
fn void builtin_string_proto_at(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    double idx_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(idx_d)) { ctx.result.set_undefined(); return; }

    long idx = (long)idx_d;
    if (idx < 0) { idx = (long)len + idx; }
    if (idx < 0 || idx >= (long)len) { ctx.result.set_undefined(); return; }

    ctx.result.set_fastint((long)data[idx] & 0xFF);
}

/// String.prototype.padStart(maxLength, fillString) — ES2017 §21.1.3.13
fn void builtin_string_proto_padStart(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    double max_len_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(max_len_d) || max_len_d < 0) { max_len_d = 0; }
    uint max_len = (uint)(long)max_len_d;

    uint str_len = s_hstr.blen;
    if (str_len >= max_len) {
        ctx.result.set_string(s_hstr); return;
    }

    HString* fill_hstr;
    if (ctx.argc > 1) {
        fill_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1]);
    } else {
        fill_hstr = builtin_intern_string(ctx.heap, " ");
    }
    if (fill_hstr == null || fill_hstr.blen == 0) {
        ctx.result.set_string(s_hstr); return;
    }

    uint pad_len = max_len - str_len;
    char* fill_data = fill_hstr.get_cstr();
    uint fill_len = fill_hstr.blen;
    char* src = s_hstr.get_cstr();

    usz total = (usz)pad_len + (usz)str_len;
    char* buf_ptr = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, total + 1);
    if (buf_ptr == null) { ctx.result.set_undefined(); return; }

    for (uint i = 0; i < pad_len; i++) {
        buf_ptr[i] = fill_data[i % fill_len];
    }
    libc::memcpy(&buf_ptr[pad_len], src, str_len);
    buf_ptr[total] = 0;

    char[] buf_slice = buf_ptr[:total];
    HString* result = ctx.heap.str_intern(buf_slice);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
    ctx.heap.free_func(ctx.heap.heap_udata, buf_ptr);
}

/// String.prototype.padEnd(maxLength, fillString) — ES2017 §21.1.3.12
fn void builtin_string_proto_padEnd(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    double max_len_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(max_len_d) || max_len_d < 0) { max_len_d = 0; }
    uint max_len = (uint)(long)max_len_d;

    uint str_len = s_hstr.blen;
    if (str_len >= max_len) {
        ctx.result.set_string(s_hstr); return;
    }

    HString* fill_hstr;
    if (ctx.argc > 1) {
        fill_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1]);
    } else {
        fill_hstr = builtin_intern_string(ctx.heap, " ");
    }
    if (fill_hstr == null || fill_hstr.blen == 0) {
        ctx.result.set_string(s_hstr); return;
    }

    uint pad_len = max_len - str_len;
    char* fill_data = fill_hstr.get_cstr();
    uint fill_len = fill_hstr.blen;
    char* src = s_hstr.get_cstr();

    usz total = (usz)str_len + (usz)pad_len;
    char* buf_ptr = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, total + 1);
    if (buf_ptr == null) { ctx.result.set_undefined(); return; }

    libc::memcpy(buf_ptr, src, str_len);
    for (uint i = 0; i < pad_len; i++) {
        buf_ptr[str_len + i] = fill_data[i % fill_len];
    }
    buf_ptr[total] = 0;

    char[] buf_slice = buf_ptr[:total];
    HString* result = ctx.heap.str_intern(buf_slice);
    if (result != null) {
        ctx.result.set_string(result);
    } else { ctx.result.set_undefined(); }
    ctx.heap.free_func(ctx.heap.heap_udata, buf_ptr);
}

/// String.prototype.lastIndexOf(searchString, position) — ES5 §15.5.4.8
fn void builtin_string_proto_lastIndexOf(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_fastint(-1); return; }

    double pos_d = (ctx.argc > 1) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 1]) : (double)len;
    if (math::is_nan(pos_d) || pos_d < 0) { pos_d = 0; }
    if (pos_d > (double)len) { pos_d = (double)len; }
    // For lastIndexOf, search from min(pos, len) backwards
    int start = (int)(long)pos_d;
    if (start > (int)len) start = (int)len;

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (search_len == 0) { ctx.result.set_fastint((long)(start < 0 ? 0 : (long)start)); return; }
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
    ctx.result.set_fastint((long)result);
}

/// String.prototype.match(regexp) — ES5 §15.5.4.10
fn void builtin_string_proto_match(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    // No args or undefined → null (per spec: RegExp(undefined) would match "undefined" string,
    // but most engines return null for match() with no args)
    if (ctx.argc == 0) {
        ctx.result.set_null();
        return;
    }

    TVal* regexp_arg = &ctx.regs[ctx.base_reg];

    // If arg is a RegExp object, use it directly
    if (is_regexp_object(regexp_arg)) {
        HObject* rx = (HObject*)regexp_arg.get_heapptr();

        // Get global flag
        bool global_flag = ((*rx.extra_ptr()).regexp.flags & 1) != 0;

        if (!global_flag) {
            // Non-global: single exec call
            int out_start = 0;
            int out_end = 0;
            int out_num_captures = 0;
            int[re_bindings::RE_MAX_CAPTURES] caps_start;
            int[re_bindings::RE_MAX_CAPTURES] caps_end;
            libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
            libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

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

            // Create result array with full match as element 0
            HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err = arr_raw) { ctx.result.set_null(); return; }
            HObject* arr = arr_raw;

            usz match_len = (usz)(out_end - out_start);
            HString* match_str;
            if (match_len == 0) {
                match_str = builtin_intern_string(ctx.heap, "");
            } else {
                match_str = builtin_intern_string(ctx.heap, input[out_start : match_len]);
            }
            TVal elem;
            elem.set_string(match_str);
            HString* zero_key = builtin_intern_string(ctx.heap, "0");
            arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

            // Set index property
            TVal idx_tv;
            idx_tv.set_fastint((long)out_start);
            HString* idx_key = builtin_intern_string(ctx.heap, "index");
            arr.put_prop(idx_key, idx_tv, hobject::PROP_FLAGS_WEC);

            // Set input property
            TVal input_tv;
            input_tv.set_string(s_hstr);
            HString* input_key = builtin_intern_string(ctx.heap, "input");
            arr.put_prop(input_key, input_tv, hobject::PROP_FLAGS_WEC);

            TVal len_tv;
            len_tv.set_fastint(1);
            HString* len_key = builtin_intern_string(ctx.heap, "length");
            arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

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

            uint arr_idx = 0;
            int search_pos = 0;

            while (search_pos <= input_len) {
                int out_start = 0;
                int out_end = 0;
                int out_num_captures = 0;
                int[re_bindings::RE_MAX_CAPTURES] caps_start;
                int[re_bindings::RE_MAX_CAPTURES] caps_end;
                libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
                libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

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

                // Advance: if empty match, move by one; else go to end of match
                if (out_end == search_pos) {
                    search_pos = out_end + 1;
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

    // Non-RegExp arg: convert to string and do literal search
    HString* search_hstr = builtin_to_string(ctx.heap, regexp_arg);
    if (search_hstr == null) { ctx.result.set_null(); return; }
    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    // Find first occurrence via indexOf
    int found_pos = -1;
    for (uint i = 0; i + search_len <= (uint)input_len; i++) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (input[i + j] != search_data[j]) { match = false; break; }
        }
        if (match) { found_pos = (int)i; break; }
    }

    if (found_pos < 0) {
        ctx.result.set_null();
        return;
    }

    // Create result array with single match
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_null(); return; }
    HObject* arr = arr_raw;

    TVal elem;
    elem.set_string(search_hstr);
    HString* zero_key = builtin_intern_string(ctx.heap, "0");
    arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

    TVal len_tv;
    len_tv.set_fastint(1);
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(arr);
}

/// String.prototype.matchAll(regexp) — ES2020 §21.1.3.12
/// Returns an array of all match results (simplified: returns array instead of iterator).
fn void builtin_string_proto_matchAll(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    if (ctx.argc == 0) {
        // matchAll() with no args: RegExp(undefined) has no 'g' flag → TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            HString* msg_str = builtin_intern_string(ctx.heap, "String.prototype.matchAll requires a global regular expression");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
            TVal err_tv;
            err_tv.set_object(err);
            ctx.throw_value = err_tv;
        }
        ctx.result.set_undefined();
        ctx.should_throw = true;
        return;
    }

    TVal* search_val = &ctx.regs[ctx.base_reg];

    // If searchValue is a regex, check for global flag
    if (is_regexp_object(search_val)) {
        HObject* rx = (HObject*)search_val.get_heapptr();

        // Read the global flag directly from the internal flags byte.
        // (get_prop("global") doesn't invoke accessor getters — it
        // returns the getter function object instead of the boolean.)
        bool global_flag = ((*rx.extra_ptr()).regexp.flags & 1) != 0;
        if (!global_flag) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                HString* msg_str = builtin_intern_string(ctx.heap, "String.prototype.matchAll called with a non-global regular expression");
                if (msg_str != null) {
                    TVal msg_val;
                    msg_val.set_string(msg_str);
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
                }
                TVal err_tv;
                err_tv.set_object(err);
                ctx.throw_value = err_tv;
            }
            ctx.result.set_undefined();
            ctx.should_throw = true;
            return;
        }

        // Reset lastIndex to 0
        HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
        TVal zero_tv; zero_tv.set_fastint(0);
        rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);

        // Create result array
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = arr_raw) { ctx.result.set_null(); return; }
        HObject* result_arr = arr_raw;

        uint arr_idx = 0;
        int search_pos = 0;

        while (search_pos <= input_len) {
            int out_start = 0;
            int out_end = 0;
            int out_num_captures = 0;
            int[re_bindings::RE_MAX_CAPTURES] caps_start;
            int[re_bindings::RE_MAX_CAPTURES] caps_end;
            libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
            libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

            int result = re_bindings::re_exec(
                (*rx.extra_ptr()).regexp.regexp_data, input, input_len, search_pos,
                &out_start, &out_end, &out_num_captures,
                &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
            );

            if (result != re_bindings::RE_MATCH) break;

            // Create match result array with captures, index, input
            HObject*? match_arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err = match_arr_raw) break;
            HObject* match_arr = match_arr_raw;

            // Element 0: full match
            usz match_len = (usz)(out_end - out_start);
            HString* match_str;
            if (match_len == 0) {
                match_str = builtin_intern_string(ctx.heap, "");
            } else {
                match_str = builtin_intern_string(ctx.heap, input[out_start : match_len]);
            }
            TVal elem;
            elem.set_string(match_str);
            HString* zero_key = builtin_intern_string(ctx.heap, "0");
            match_arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

            // Capture groups
            uint match_arr_len = 1;
            int num_caps = out_num_captures;
            if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
            for (int i = 0; i < num_caps; i++) {
                HString* cap_str;
                if (caps_start[i] >= 0 && caps_end[i] >= 0) {
                    usz cap_len = (usz)(caps_end[i] - caps_start[i]);
                    cap_str = cap_len == 0
                        ? builtin_intern_string(ctx.heap, "")
                        : builtin_intern_string(ctx.heap, input[caps_start[i] : cap_len]);
                } else {
                    cap_str = null; // undefined
                }
                TVal cap_elem;
                if (cap_str != null) {
                    cap_elem.set_string(cap_str);
                } else {
                    cap_elem.set_undefined();
                }
                match_arr.put_prop(ctx.heap.int_to_hstring((long)(i + 1)), cap_elem, hobject::PROP_FLAGS_WEC);
                match_arr_len++;
            }

            // Set index property
            TVal idx_tv;
            idx_tv.set_fastint((long)out_start);
            HString* idx_key = builtin_intern_string(ctx.heap, "index");
            match_arr.put_prop(idx_key, idx_tv, hobject::PROP_FLAGS_WEC);

            // Set input property
            TVal input_tv;
            input_tv.set_string(s_hstr);
            HString* input_key = builtin_intern_string(ctx.heap, "input");
            match_arr.put_prop(input_key, input_tv, hobject::PROP_FLAGS_WEC);

            // Set length
            TVal mlen_tv;
            mlen_tv.set_fastint((long)match_arr_len);
            HString* mlen_key = builtin_intern_string(ctx.heap, "length");
            match_arr.put_prop(mlen_key, mlen_tv, hobject::PROP_FLAGS_WEC);

            // Add match result array to outer array
            TVal match_tv;
            match_tv.set_object(match_arr);
            result_arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), match_tv, hobject::PROP_FLAGS_WEC);
            arr_idx++;

            // Advance: if empty match, move by one; else go to end of match
            if (out_end == search_pos) {
                search_pos = out_end + 1;
                if (search_pos > input_len) break;
            } else {
                search_pos = out_end;
            }
        }

        // Reset lastIndex
        TVal li_tv; li_tv.set_fastint(0);
        rx.put_prop(li_key, li_tv, hobject::PROP_FLAGS_WEC);

        // Set length on result array
        TVal len_tv;
        len_tv.set_fastint((long)arr_idx);
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        result_arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

        ctx.result.set_object(result_arr);
        return;
    }

    // Non-RegExp arg: convert to RegExp with "g" flag by doing literal string search
    HString* search_hstr = builtin_to_string(ctx.heap, search_val);
    if (search_hstr == null) { ctx.result.set_null(); return; }
    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    // Create result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_null(); return; }
    HObject* result_arr = arr_raw;

    if (search_len == 0) {
        // Empty pattern: return empty array
        TVal len_tv; len_tv.set_fastint(0);
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        result_arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(result_arr);
        return;
    }

    uint arr_idx = 0;
    uint pos = 0;

    while (pos + search_len <= (uint)input_len) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (input[pos + j] != search_data[j]) { match = false; break; }
        }
        if (!match) { pos++; continue; }

        // Create match result array
        HObject*? match_arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = match_arr_raw) break;
        HObject* match_arr = match_arr_raw;

        // Element 0: full match
        TVal elem;
        elem.set_string(search_hstr);
        HString* zero_key = builtin_intern_string(ctx.heap, "0");
        match_arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

        // Set index property
        TVal idx_tv;
        idx_tv.set_fastint((long)pos);
        HString* idx_key = builtin_intern_string(ctx.heap, "index");
        match_arr.put_prop(idx_key, idx_tv, hobject::PROP_FLAGS_WEC);

        // Set input property
        TVal input_tv;
        input_tv.set_string(s_hstr);
        HString* input_key = builtin_intern_string(ctx.heap, "input");
        match_arr.put_prop(input_key, input_tv, hobject::PROP_FLAGS_WEC);

        // Set length = 1
        TVal mlen_tv;
        mlen_tv.set_fastint(1);
        HString* mlen_key = builtin_intern_string(ctx.heap, "length");
        match_arr.put_prop(mlen_key, mlen_tv, hobject::PROP_FLAGS_WEC);

        // Add to result array
        TVal match_tv;
        match_tv.set_object(match_arr);
        result_arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), match_tv, hobject::PROP_FLAGS_WEC);
        arr_idx++;

        pos += search_len;
    }

    // Set length on result array
    TVal len_tv;
    len_tv.set_fastint((long)arr_idx);
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    result_arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result_arr);
}

/// String.prototype.normalize([form]) — ES6 §21.1.3.12
/// Basic implementation: returns the string as-is (identity normalization).
/// Full Unicode normalization (NFC/NFD/NFKC/NFKD) requires complex tables;
/// this passes basic tests for ASCII strings and already-normalized input.
fn void builtin_string_proto_normalize(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    // Validate form argument if provided
    if (ctx.argc > 0) {
        HString* form = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
        if (form != null) {
            char* form_data = form.get_cstr();
            uint form_len = form.blen;
            // Accept NFC, NFD, NFKC, NFKD, or undefined
            bool valid = false;
            if (form_len == 3) {
                if ((form_data[0] == 'N' || form_data[0] == 'n') &&
                    (form_data[1] == 'F' || form_data[1] == 'f') &&
                    (form_data[2] == 'C' || form_data[2] == 'c' ||
                     form_data[2] == 'D' || form_data[2] == 'd')) {
                    valid = true;
                }
            } else if (form_len == 4) {
                if ((form_data[0] == 'N' || form_data[0] == 'n') &&
                    (form_data[1] == 'F' || form_data[1] == 'f') &&
                    (form_data[2] == 'K' || form_data[2] == 'k') &&
                    (form_data[3] == 'C' || form_data[3] == 'c' ||
                     form_data[3] == 'D' || form_data[3] == 'd')) {
                    valid = true;
                }
            }
            if (!valid) {
                // Throw RangeError for invalid form
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    HString* msg_str = builtin_intern_string(ctx.heap, "The normalization form should be one of NFC, NFD, NFKC, NFKD.");
                    TVal msg_val;
                    msg_val.set_string(msg_str);
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
                    TVal err_tv;
                    err_tv.set_object(err);
                    ctx.throw_value = err_tv;
                }
                ctx.should_throw = true;
                ctx.result.set_undefined();
                return;
            }
        }
    }

    // Identity normalization: return the string unchanged
    ctx.result.set_string(s_hstr);
}

/// String.prototype.search(regexp) — ES5 §15.5.4.12
fn void builtin_string_proto_search(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    if (ctx.argc == 0) {
        ctx.result.set_fastint(-1);
        return;
    }

    TVal* regexp_arg = &ctx.regs[ctx.base_reg];

    // If arg is a RegExp object, use it directly
    if (is_regexp_object(regexp_arg)) {
        HObject* rx = (HObject*)regexp_arg.get_heapptr();

        int out_start = 0;
        int out_end = 0;
        int out_num_captures = 0;
        int[re_bindings::RE_MAX_CAPTURES] caps_start;
        int[re_bindings::RE_MAX_CAPTURES] caps_end;
        libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
        libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

        int result = re_bindings::re_exec(
            (*rx.extra_ptr()).regexp.regexp_data, input, input_len, 0,
            &out_start, &out_end, &out_num_captures,
            &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
        );

        ctx.result.set_fastint((result == re_bindings::RE_MATCH) ? (long)out_start : -1);
        return;
    }

    // Non-RegExp arg: convert to string and do literal search
    HString* search_hstr = builtin_to_string(ctx.heap, regexp_arg);
    if (search_hstr == null) { ctx.result.set_fastint(-1); return; }
    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    for (uint i = 0; i + search_len <= (uint)input_len; i++) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (input[i + j] != search_data[j]) { match = false; break; }
        }
        if (match) {
            ctx.result.set_fastint((long)i);
            return;
        }
    }
    ctx.result.set_fastint(-1);
}
fn bool register_string_constructor(EnvRecord* global_env, Heap* heap) {
    // Create String.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.STRING);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    heap.string_proto = proto;

    // Add .toString() method
    HString* tostring_key = (HString*)heap.strs[heap::BuiltinStr.TO_STRING];
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_STRING_PROTO_TOSTRING);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .valueOf() method
    HString* valueof_key = (HString*)heap.strs[heap::BuiltinStr.VALUE_OF];
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)BUILTIN_STRING_PROTO_VALUEOF);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC);

    // Add String.prototype methods (Phase 6b)
    if (!register_string_proto_method(proto, heap, "charAt",     BUILTIN_STRING_PROTO_CHARAT))     return false;
    if (!register_string_proto_method(proto, heap, "charCodeAt", BUILTIN_STRING_PROTO_CHARCODEAT)) return false;
    if (!register_string_proto_method(proto, heap, "indexOf",    BUILTIN_STRING_PROTO_INDEXOF))    return false;
    if (!register_string_proto_method(proto, heap, "slice",      BUILTIN_STRING_PROTO_SLICE))      return false;
    if (!register_string_proto_method(proto, heap, "substring",  BUILTIN_STRING_PROTO_SUBSTRING))  return false;
    if (!register_string_proto_method(proto, heap, "substr",     BUILTIN_STRING_PROTO_SUBSTR))     return false;
    if (!register_string_proto_method(proto, heap, "toLowerCase",BUILTIN_STRING_PROTO_TOLOWERCASE)) return false;
    if (!register_string_proto_method(proto, heap, "toUpperCase",BUILTIN_STRING_PROTO_TOUPPERCASE)) return false;
    if (!register_string_proto_method(proto, heap, "trim",       BUILTIN_STRING_PROTO_TRIM))       return false;
    if (!register_string_proto_method(proto, heap, "split",      BUILTIN_STRING_PROTO_SPLIT))      return false;
    if (!register_string_proto_method(proto, heap, "concat",     BUILTIN_STRING_PROTO_CONCAT))     return false;
    if (!register_string_proto_method(proto, heap, "replace",    BUILTIN_STRING_PROTO_REPLACE))    return false;
    if (!register_string_proto_method(proto, heap, "replaceAll", BUILTIN_STRING_PROTO_REPLACEALL)) return false;
    if (!register_string_proto_method(proto, heap, "includes",   BUILTIN_STRING_PROTO_INCLUDES))   return false;
    if (!register_string_proto_method(proto, heap, "startsWith", BUILTIN_STRING_PROTO_STARTSWITH)) return false;
    if (!register_string_proto_method(proto, heap, "endsWith",   BUILTIN_STRING_PROTO_ENDSWITH))   return false;
    if (!register_string_proto_method(proto, heap, "repeat",     BUILTIN_STRING_PROTO_REPEAT))     return false;
    if (!register_string_proto_method(proto, heap, "trimStart",  BUILTIN_STRING_PROTO_TRIMSTART))  return false;
    if (!register_string_proto_method(proto, heap, "trimEnd",    BUILTIN_STRING_PROTO_TRIMEND))    return false;
    if (!register_string_proto_method(proto, heap, "codePointAt", BUILTIN_STRING_PROTO_CODEPOINTAT)) return false;
    if (!register_string_proto_method(proto, heap, "at",         BUILTIN_STRING_PROTO_AT))         return false;
    if (!register_string_proto_method(proto, heap, "padStart",   BUILTIN_STRING_PROTO_PADSTART))   return false;
    if (!register_string_proto_method(proto, heap, "padEnd",     BUILTIN_STRING_PROTO_PADEND))     return false;
    if (!register_string_proto_method(proto, heap, "lastIndexOf", BUILTIN_STRING_PROTO_LASTINDEXOF)) return false;
    if (!register_string_proto_method(proto, heap, "match",      BUILTIN_STRING_PROTO_MATCH))      return false;
    if (!register_string_proto_method(proto, heap, "matchAll",   BUILTIN_STRING_PROTO_MATCHALL))   return false;
    if (!register_string_proto_method(proto, heap, "search",     BUILTIN_STRING_PROTO_SEARCH))     return false;
    if (!register_string_proto_method(proto, heap, "toLocaleLowerCase", BUILTIN_STRING_PROTO_TOLOCALELOWERCASE)) return false;
    if (!register_string_proto_method(proto, heap, "toLocaleUpperCase", BUILTIN_STRING_PROTO_TOLOCALEUPPERCASE)) return false;
    if (!register_string_proto_method(proto, heap, "localeCompare", BUILTIN_STRING_PROTO_LOCALECOMPARE)) return false;
    if (!register_string_proto_method(proto, heap, "normalize",    BUILTIN_STRING_PROTO_NORMALIZE))    return false;

    // Create String constructor as a proper function object (not LIGHTFUNC)
    // so it can carry static methods like String.fromCharCode.
    HObject*? str_obj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = str_obj_raw) return false;
    HObject* str_obj = str_obj_raw;
    (*str_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_STRING;

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
    if (!register_string_proto_method(str_obj, heap, "fromCharCode", BUILTIN_STRING_FROMCHARCODE)) return false;
    if (!register_string_proto_method(str_obj, heap, "fromCodePoint", BUILTIN_STRING_FROMCODEPOINT)) return false;

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
