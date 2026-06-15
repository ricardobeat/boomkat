/// Global built-in functions: print, parseInt, parseFloat, isNaN, isFinite, eval, URI encoding/decoding.
module tinyduck::builtins;
import tinyduck::types;
import tinyduck::bytecode;
import std::io;
import std::math;
import libc;
import tinyduck::lexer;
import tinyduck::compiler;
import tinyduck::hstring;
import tinyduck::hobject;

import tinyduck::heap;
import tinyduck::env;

/// Print a single TVal using proper JS ToString coercion.
/// For objects, looks up and calls the object's toString() method via call_fn
/// so that Array.prototype.toString (join with commas), Date.prototype.toString,
/// and user-defined toString() all work correctly.
fn void print_tval_ctx(BuiltinContext* ctx, TVal* val) {
    if (val.is_object() && val.get_heapptr() != null && ctx.vm != null && ctx.heap.call_fn != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        // Look up toString on the object (searches prototype chain)
        HString* tostr_key = builtin_intern_string(ctx.heap, "toString");
        if (tostr_key != null) {
            if (try method_val = obj.get_prop(tostr_key)) {
                if (method_val.is_object() || method_val.is_lightfunc()) {
                    TVal str_result = ctx.heap.call_fn(ctx.vm, method_val, null, 0, *val);
                    if (str_result.is_string()) {
                        HString* s = (HString*)str_result.get_heapptr();
                        if (s != null) {
                            char[] d = s.get_data();
                            for (usz j = 0; j < d.len; j++) io::putchar(d[j]);
                            return;
                        }
                    }
                    // toString returned a non-string primitive — fall through to print_tval
                    if (!str_result.is_object()) {
                        print_tval(&str_result);
                        return;
                    }
                }
            }
        }
        // No callable toString found — fall back to generic "[object Object]"
        io::printf("[object Object]");
        return;
    }
    print_tval(val);
}

fn void builtin_print(BuiltinContext* ctx) {
    for (ushort i = 0; i < ctx.argc; i++) {
        if (i > 0) {
            io::putchar(' ');
        }
        print_tval_ctx(ctx, &ctx.regs[ctx.base_reg + i]);
    }
    io::putchar('\n');
    ctx.result.set_undefined();
}

fn void builtin_console_log(BuiltinContext* ctx) {
    for (ushort i = 0; i < ctx.argc; i++) {
        if (i > 0) {
            io::putchar(' ');
        }
        print_tval_ctx(ctx, &ctx.regs[ctx.base_reg + i]);
    }
    io::putchar('\n');
    ctx.result.set_undefined();
}

fn void builtin_parse_int(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_number(double::nan);
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    if (arg.is_fastint()) {
        ctx.result.set_fastint(arg.get_fastint());
        return;
    }
    if (!arg.is_string()) {
        ctx.result.set_number(double::nan);
        return;
    }
    HString* h = (HString*)arg.get_heapptr();
    if (h == null || h.blen == 0) {
        ctx.result.set_number(double::nan);
        return;
    }
    char* cstr = h.get_cstr();
    // Skip leading whitespace
    char* p = cstr;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;

    int radix;
    if (ctx.argc > 1) {
        TVal* rad_arg = &ctx.regs[ctx.base_reg + 1];
        radix = (int)(rad_arg.is_fastint() ? rad_arg.get_fastint() : rad_arg.get_number());
    } else {
        radix = 0;  // auto-detect (0x = hex, 0 = octal legacy, else decimal)
    }

    char* end;
    long result = libc::strtol(p, &end, radix);
    if (end == cstr) {
        ctx.result.set_number(double::nan);
        return;
    }
    ctx.result.set_fastint(result);
}

fn void builtin_parse_float(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_number(double::nan);
        return;
    }
    double d = string_to_double(&ctx.regs[ctx.base_reg]);
    ctx.result.set_number(d);
}

fn void builtin_is_nan(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal num;
    builtin_to_number(&ctx.regs[ctx.base_reg], &num);
    ctx.result.set_boolean((num.is_number()) ? math::is_nan(num.get_number()) : false);
}

fn void builtin_is_finite(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    double d = string_to_double(&ctx.regs[ctx.base_reg]);
    ctx.result.set_boolean(!math::is_nan(d) && !math::is_inf(d));
}


fn void uri_encode_byte(char* out, usz* offset, char b) {
    out[*offset] = '%';
    out[*offset + 1] = "0123456789ABCDEF"[b >> 4];
    out[*offset + 2] = "0123456789ABCDEF"[b & 0x0F];
    *offset += 3;
}

fn bool uri_is_unreserved(char c) {
    if (c >= 'A' && c <= 'Z') return true;
    if (c >= 'a' && c <= 'z') return true;
    if (c >= '0' && c <= '9') return true;
    if (c == '-' || c == '_' || c == '.' || c == '!') return true;
    if (c == '~' || c == '*' || c == '\'' || c == '(') return true;
    if (c == ')') return true;
    return false;
}

fn int hex_digit_val(char c) {
    if (c >= '0' && c <= '9') return (int)c - '0';
    if (c >= 'A' && c <= 'F') return (int)c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return (int)c - 'a' + 10;
    return -1;
}

/// encodeURI (ES5 §15.1.3.1)
fn void builtin_encode_uri(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        char c = data[i];
        // URI unreserved + reserved + '#' characters (not encoded)
        if (uri_is_unreserved(c)) {
            out[offset++] = c;
            i++;
        } else if (c == ';' || c == ',' || c == '/' || c == '?' || c == ':' ||
                   c == '@' || c == '&' || c == '=' || c == '+' || c == '$' ||
                   c == '-' || c == '_' || c == '.' || c == '!' || c == '~' ||
                   c == '*' || c == '\'' || c == '(' || c == ')' || c == '#') {
            out[offset++] = c;
            i++;
        } else {
            uint b = (uint)c;
            if (b < 0x80) {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            } else if (b >= 0xC2 && b <= 0xF4) {
                uint seq_len;
                if (b < 0xE0) { seq_len = 2; }
                else if (b < 0xF0) { seq_len = 3; }
                else { seq_len = 4; }
                if (i + seq_len > len) {
                    // Incomplete sequence - encode byte
                    uri_encode_byte(&out, &offset, (char)b);
                    i++;
                } else {
                    // Validate continuation bytes
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        uint cb = (uint)data[i + j];
                        if (cb < 0x80 || cb > 0xBF) { valid = false; break; }
                    }
                    if (!valid) {
                        uri_encode_byte(&out, &offset, (char)b);
                        i++;
                    } else {
                        for (uint j = 0; j < seq_len; j++) {
                            uri_encode_byte(&out, &offset, (char)data[i + j]);
                        }
                        i += seq_len;
                    }
                }
            } else {
                // Invalid leading byte (0x80-0xBF, 0xC0-0xC1, 0xF5-0xFF)
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            }
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

/// encodeURIComponent (ES5 §15.1.3.2)
fn void builtin_encode_uri_component(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        char c = data[i];
        if (uri_is_unreserved(c)) {
            out[offset++] = c;
            i++;
        } else {
            uint b = (uint)c;
            if (b < 0x80) {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            } else if (b >= 0xC2 && b <= 0xF4) {
                uint seq_len;
                if (b < 0xE0) { seq_len = 2; }
                else if (b < 0xF0) { seq_len = 3; }
                else { seq_len = 4; }
                if (i + seq_len > len) {
                    uri_encode_byte(&out, &offset, (char)b);
                    i++;
                } else {
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        uint cb = (uint)data[i + j];
                        if (cb < 0x80 || cb > 0xBF) { valid = false; break; }
                    }
                    if (!valid) {
                        uri_encode_byte(&out, &offset, (char)b);
                        i++;
                    } else {
                        for (uint j = 0; j < seq_len; j++) {
                            uri_encode_byte(&out, &offset, (char)data[i + j]);
                        }
                        i += seq_len;
                    }
                }
            } else {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            }
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

/// decodeURI (ES5 §15.1.3.3)
fn void builtin_decode_uri(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        if (data[i] == '%') {
            // Check if this is a reserved character that should NOT be decoded
            if (i + 2 < len) {
                int d1 = hex_digit_val(data[i + 1]);
                int d2 = hex_digit_val(data[i + 2]);
                if (d1 >= 0 && d2 >= 0) {
                    uint cp = (uint)((d1 << 4) | d2);
                    // decodeURI does NOT decode reserved URI characters
                    if (cp == 0x23 || cp == 0x24 || cp == 0x26 || cp == 0x2B ||
                        cp == 0x2C || cp == 0x2F || cp == 0x3A || cp == 0x3B ||
                        cp == 0x3D || cp == 0x3F || cp == 0x40) {
                        out[offset++] = '%';
                        out[offset++] = data[i + 1];
                        out[offset++] = data[i + 2];
                        i += 3;
                        continue;
                    }
                    // Decode the byte
                    char first = (char)cp;
                    if (first < 0x80) {
                        out[offset++] = (char)first;
                        i += 3;
                    } else if (first >= 0xC0 && first <= 0xF4) {
                        // Multi-byte UTF-8 sequence
                        uint seq_len;
                        if (first < 0xE0) { seq_len = 2; }
                        else if (first < 0xF0) { seq_len = 3; }
                        else { seq_len = 4; }
                        if (i + 3 * seq_len > len) {
                            // Incomplete - throw URIError
                            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                                TVal msg_tv; msg_tv.set_string(msg);
                                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                                ctx.should_throw = true;
                                ctx.throw_value.set_object(err);
                            }
                            return;
                        }
                        char[4] bytes;
                        bytes[0] = (char)first;
                        bool valid = true;
                        for (uint j = 1; j < seq_len; j++) {
                            if (data[i + 3 * j] != '%') { valid = false; break; }
                            int h1 = hex_digit_val(data[i + 3 * j + 1]);
                            int h2 = hex_digit_val(data[i + 3 * j + 2]);
                            if (h1 < 0 || h2 < 0) { valid = false; break; }
                            char b = (char)((h1 << 4) | h2);
                            if (b < 0x80 || b > 0xBF) { valid = false; break; }
                            bytes[j] = (char)b;
                        }
                        if (!valid) {
                            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                                TVal msg_tv; msg_tv.set_string(msg);
                                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                                ctx.should_throw = true;
                                ctx.throw_value.set_object(err);
                            }
                            return;
                        }
                        for (uint j = 0; j < seq_len; j++) {
                            out[offset++] = bytes[j];
                        }
                        i += 3 * seq_len;
                    } else {
                        // Invalid leading byte for multi-byte sequence
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                            TVal msg_tv; msg_tv.set_string(msg);
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                            ctx.should_throw = true;
                            ctx.throw_value.set_object(err);
                        }
                        return;
                    }
                } else {
                    // Invalid hex digits
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                        TVal msg_tv; msg_tv.set_string(msg);
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                        ctx.should_throw = true;
                        ctx.throw_value.set_object(err);
                    }
                    return;
                }
            } else {
                // '%' not followed by two hex digits
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                    TVal msg_tv; msg_tv.set_string(msg);
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                }
                return;
            }
        } else {
            out[offset++] = data[i];
            i++;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

/// decodeURIComponent (ES5 §15.1.3.4)
fn void builtin_decode_uri_component(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        if (data[i] == '%') {
            if (i + 2 < len) {
                int d1 = hex_digit_val(data[i + 1]);
                int d2 = hex_digit_val(data[i + 2]);
                if (d1 < 0 || d2 < 0) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                        TVal msg_tv; msg_tv.set_string(msg);
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                        ctx.should_throw = true;
                        ctx.throw_value.set_object(err);
                    }
                    return;
                }
                char first = (char)((d1 << 4) | d2);
                if (first < 0x80) {
                    out[offset++] = (char)first;
                    i += 3;
                } else if (first >= 0xC0 && first <= 0xF4) {
                    uint seq_len;
                    if (first < 0xE0) { seq_len = 2; }
                    else if (first < 0xF0) { seq_len = 3; }
                    else { seq_len = 4; }
                    if (i + 3 * seq_len > len) {
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                            TVal msg_tv; msg_tv.set_string(msg);
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                            ctx.should_throw = true;
                            ctx.throw_value.set_object(err);
                        }
                        return;
                    }
                    char[4] bytes;
                    bytes[0] = (char)first;
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        if (data[i + 3 * j] != '%') { valid = false; break; }
                        int h1 = hex_digit_val(data[i + 3 * j + 1]);
                        int h2 = hex_digit_val(data[i + 3 * j + 2]);
                        if (h1 < 0 || h2 < 0) { valid = false; break; }
                        char b = (char)((h1 << 4) | h2);
                        if (b < 0x80 || b > 0xBF) { valid = false; break; }
                        bytes[j] = (char)b;
                    }
                    if (!valid) {
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                            TVal msg_tv; msg_tv.set_string(msg);
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                            ctx.should_throw = true;
                            ctx.throw_value.set_object(err);
                        }
                        return;
                    }
                    for (uint j = 0; j < seq_len; j++) {
                        out[offset++] = bytes[j];
                    }
                    i += 3 * seq_len;
                } else {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                        TVal msg_tv; msg_tv.set_string(msg);
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                        ctx.should_throw = true;
                        ctx.throw_value.set_object(err);
                    }
                    return;
                }
            } else {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                    TVal msg_tv; msg_tv.set_string(msg);
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                }
                return;
            }
        } else {
            out[offset++] = data[i];
            i++;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}
