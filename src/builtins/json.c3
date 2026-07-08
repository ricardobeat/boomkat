/// JSON.parse and JSON.stringify.
module tinyduck::builtins;
import tinyduck::types;
import std::math;
import libc;

import tinyduck::heap;
import tinyduck::hstring;
import tinyduck::hobject;
import tinyduck::env;
import std::io;

// ============================================================================
// JSON.parse (ES5 §15.12.2)
// ============================================================================

struct JsonParseCtx {
    char* src;
    uint pos;
    uint len;
    Heap* heap;
}

fn void json_skip_ws(JsonParseCtx* jctx) {
    while (jctx.pos < jctx.len) {
        char c = jctx.src[jctx.pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            jctx.pos++;
        } else {
            break;
        }
    }
}

/// Parse a 4-digit hex escape (\uXXXX).
fn uint json_parse_hex4(JsonParseCtx* jctx) {
    uint val = 0;
    for (int i = 0; i < 4; i++) {
        if (jctx.pos >= jctx.len) return 0xFFFFFFFF;
        char c = jctx.src[jctx.pos];
        uint d;
        if (c >= '0' && c <= '9') {
            d = (uint)(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            d = (uint)(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            d = (uint)(c - 'A' + 10);
        } else {
            return 0xFFFFFFFF;
        }
        val = (val << 4) | d;
        jctx.pos++;
    }
    return val;
}

/// Parse a JSON string (between quotes).
fn HString*? json_parse_string(JsonParseCtx* jctx) {
    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '\"') {
        return null;
    }
    jctx.pos++; // skip opening quote

    char[1024] buf;
    usz out_len = 0;

    while (jctx.pos < jctx.len) {
        char c = jctx.src[jctx.pos];
        if (c == '\"') {
            jctx.pos++; // skip closing quote
            return builtin_intern_string(jctx.heap, buf[:out_len]);
        }
        if (c == '\\') {
            jctx.pos++;
            if (jctx.pos >= jctx.len) return null;
            char esc = jctx.src[jctx.pos];
            jctx.pos++;
            char ch;
            switch (esc) {
                case '\"': ch = '\"'; break;
                case '\\': ch = '\\'; break;
                case '/':  ch = '/';  break;
                case 'b':  ch = '\b'; break;
                case 'f':  ch = '\f'; break;
                case 'n':  ch = '\n'; break;
                case 'r':  ch = '\r'; break;
                case 't':  ch = '\t'; break;
                case 'u': {
                    uint cp = json_parse_hex4(jctx);
                    if (cp == 0xFFFFFFFF) return null;
                    // Simple ASCII-range unicode (for now, just low bytes)
                    if (cp <= 0x7F) {
                        ch = (char)cp;
                    } else if (cp <= 0x7FF) {
                        // UTF-8 2-byte sequence
                        if (out_len + 2 > 1024) return null;
                        buf[out_len++] = (char)(0xC0 | (cp >> 6));
                        ch = (char)(0x80 | (cp & 0x3F));
                    } else {
                        // UTF-8 3-byte sequence
                        if (out_len + 3 > 1024) return null;
                        buf[out_len++] = (char)(0xE0 | (cp >> 12));
                        buf[out_len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                        ch = (char)(0x80 | (cp & 0x3F));
                    }
                    break;
                }
                default:
                    return null;
            }
            if (out_len >= 1024) return null;
            buf[out_len++] = ch;
        } else if (c < 0x20) {
            // Control characters not allowed
            return null;
        } else {
            if (out_len >= 1024) return null;
            buf[out_len++] = c;
            jctx.pos++;
        }
    }
    return null; // unterminated string
}

/// Parse a JSON number.
fn TVal json_parse_number(JsonParseCtx* jctx) {
    uint start = jctx.pos;

    // Optional minus
    if (jctx.pos < jctx.len && jctx.src[jctx.pos] == '-') {
        jctx.pos++;
    }

    // Integer part
    if (jctx.pos >= jctx.len) {
        TVal r; r.set_undefined(); return r;
    }
    if (jctx.src[jctx.pos] == '0') {
        jctx.pos++;
    } else if (jctx.src[jctx.pos] >= '1' && jctx.src[jctx.pos] <= '9') {
        jctx.pos++;
        while (jctx.pos < jctx.len && jctx.src[jctx.pos] >= '0' && jctx.src[jctx.pos] <= '9') {
            jctx.pos++;
        }
    } else {
        TVal r; r.set_undefined(); return r;
    }

    // Fractional part
    if (jctx.pos < jctx.len && jctx.src[jctx.pos] == '.') {
        jctx.pos++;
        if (jctx.pos >= jctx.len || jctx.src[jctx.pos] < '0' || jctx.src[jctx.pos] > '9') {
            TVal r; r.set_undefined(); return r;
        }
        while (jctx.pos < jctx.len && jctx.src[jctx.pos] >= '0' && jctx.src[jctx.pos] <= '9') {
            jctx.pos++;
        }
    }

    // Exponent part
    if (jctx.pos < jctx.len && (jctx.src[jctx.pos] == 'e' || jctx.src[jctx.pos] == 'E')) {
        jctx.pos++;
        if (jctx.pos < jctx.len && (jctx.src[jctx.pos] == '+' || jctx.src[jctx.pos] == '-')) {
            jctx.pos++;
        }
        if (jctx.pos >= jctx.len || jctx.src[jctx.pos] < '0' || jctx.src[jctx.pos] > '9') {
            TVal r; r.set_undefined(); return r;
        }
        while (jctx.pos < jctx.len && jctx.src[jctx.pos] >= '0' && jctx.src[jctx.pos] <= '9') {
            jctx.pos++;
        }
    }

    // Convert to double
    uint end = jctx.pos;
    char saved = jctx.src[end];
    jctx.src[end] = 0;
    char* endptr;
    double d = libc::strtod(jctx.src + start, &endptr);
    jctx.src[end] = saved;

    // Try fastint preservation
    long fi = (long)d;
    if ((double)fi == d && fi >= -9007199254740991 && fi <= 9007199254740991) {
        TVal r; r.set_fastint(fi); return r;
    }
    TVal r; r.set_number(d); return r;
}

/// Parse a JSON array: [value, ...]
fn TVal json_parse_array(JsonParseCtx* jctx) {
    jctx.pos++; // skip '['
    json_skip_ws(jctx);

    HObject*? arr_raw = jctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* arr;
    if (try a = arr_raw) {
        arr = a;
    } else {
        TVal r; r.set_undefined(); return r;
    }

    HString* len_key = builtin_intern_string(jctx.heap, "length");
    uint idx = 0;

    if (jctx.pos < jctx.len && jctx.src[jctx.pos] != ']') {
        while (true) {
            json_skip_ws(jctx);
            TVal elem = json_parse_value(jctx);
            if (elem.is_undefined() && elem.get_heapptr() == null && jctx.pos < jctx.len) {
                TVal r; r.set_undefined(); return r; // parse error
            }
            json_skip_ws(jctx);

            HString* idx_key = jctx.heap.int_to_hstring((long)idx);
            if (idx_key != null) {
                arr.put_prop(idx_key, elem);
            }
            idx++;

            if (jctx.pos >= jctx.len) {
                TVal r; r.set_undefined(); return r;
            }
            if (jctx.src[jctx.pos] == ',') {
                jctx.pos++;
            } else {
                break;
            }
        }
    }

    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != ']') {
        TVal r; r.set_undefined(); return r;
    }
    jctx.pos++; // skip ']'

    TVal len_val;
    len_val.set_fastint((long)idx);
    arr.put_prop(len_key, len_val);

    TVal result;
    result.set_object(arr);
    return result;
}

/// Parse a JSON object: {key: value, ...}
fn TVal json_parse_object(JsonParseCtx* jctx) {
    jctx.pos++; // skip '{'
    json_skip_ws(jctx);

    HObject*? obj_raw = jctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    HObject* obj;
    if (try o = obj_raw) {
        obj = o;
    } else {
        TVal r; r.set_undefined(); return r;
    }

    if (jctx.pos < jctx.len && jctx.src[jctx.pos] != '}') {
        while (true) {
            json_skip_ws(jctx);
            if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '\"') {
                TVal r; r.set_undefined(); return r;
            }
            HString*? key_str = json_parse_string(jctx);
            if (try k = key_str) {
                json_skip_ws(jctx);
                if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != ':') {
                    TVal r; r.set_undefined(); return r;
                }
                jctx.pos++; // skip ':'
                json_skip_ws(jctx);
                TVal val = json_parse_value(jctx);
                if (val.is_undefined() && val.get_heapptr() == null && jctx.pos < jctx.len) {
                    TVal r; r.set_undefined(); return r;
                }
                obj.put_prop(k, val);
                json_skip_ws(jctx);
                if (jctx.pos >= jctx.len) {
                    TVal r; r.set_undefined(); return r;
                }
                if (jctx.src[jctx.pos] == ',') {
                    jctx.pos++;
                } else {
                    break;
                }
            } else {
                TVal r; r.set_undefined(); return r;
            }
        }
    }

    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '}') {
        TVal r; r.set_undefined(); return r;
    }
    jctx.pos++; // skip '}'

    TVal result;
    result.set_object(obj);
    return result;
}

/// Parse a JSON value.
fn TVal json_parse_value(JsonParseCtx* jctx) {
    json_skip_ws(jctx);
    if (jctx.pos >= jctx.len) {
        TVal r; r.set_undefined(); return r;
    }

    char c = jctx.src[jctx.pos];
    switch (c) {
        case '\"':
            // String
            {
                HString*? s = json_parse_string(jctx);
                if (try str = s) {
                    TVal r; r.set_string(str); return r;
                }
                TVal r; r.set_undefined(); return r;
            }
        case '{':
            return json_parse_object(jctx);
        case '[':
            return json_parse_array(jctx);
        case 't':
            // true
            if (jctx.pos + 4 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'r' &&
                jctx.src[jctx.pos + 2] == 'u' &&
                jctx.src[jctx.pos + 3] == 'e') {
                jctx.pos += 4;
                TVal r; r.set_boolean(true); return r;
            }
            { TVal r; r.set_undefined(); return r; }
        case 'f':
            // false
            if (jctx.pos + 5 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'a' &&
                jctx.src[jctx.pos + 2] == 'l' &&
                jctx.src[jctx.pos + 3] == 's' &&
                jctx.src[jctx.pos + 4] == 'e') {
                jctx.pos += 5;
                TVal r; r.set_boolean(false); return r;
            }
            { TVal r; r.set_undefined(); return r; }
        case 'n':
            // null
            if (jctx.pos + 4 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'u' &&
                jctx.src[jctx.pos + 2] == 'l' &&
                jctx.src[jctx.pos + 3] == 'l') {
                jctx.pos += 4;
                TVal r; r.set_null(); return r;
            }
            { TVal r; r.set_undefined(); return r; }
        case '-':
        case '0'..'9':
            return json_parse_number(jctx);
        default:
            { TVal r; r.set_undefined(); return r; }
    }
}

/// Walk helper for reviver (ES5 §15.12.2, step 4 — internalize properties).
fn TVal json_walk(Heap* heap, TVal reviver, TVal holder, HString* name) {
    TVal val;
    if (holder.is_object() && holder.get_heapptr() != null) {
        HObject* obj = (HObject*)holder.get_heapptr();
        TVal? prop = obj.get_prop(name);
        if (try p = prop) {
            val = p;
        } else {
            val.set_undefined();
        }
    } else {
        val.set_undefined();
    }

    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.get_class() == ObjClass.ARRAY) {
            HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            TVal? len_prop = obj.get_prop(len_key);
            uint len = 0;
            if (try l = len_prop) {
                if (l.is_fastint()) len = (uint)l.get_fastint();
            }
            for (uint i = 0; i < len; i++) {
                HString* idx_key = heap.int_to_hstring((long)i);
                if (idx_key == null) continue;
                TVal new_elem = json_walk(heap, reviver, val, idx_key);
                if (new_elem.is_undefined()) {
                    obj.delete_prop(idx_key);
                } else {
                    obj.put_prop(idx_key, new_elem);
                }
            }
        } else if (obj.get_class() == ObjClass.OBJECT) {
            // Walk own properties
            for (uint i = 0; i < obj.prop_count; i++) {
                HString* key_str = obj.prop_key_at(i);
                if (key_str != null) {
                    TVal new_val = json_walk(heap, reviver, val, key_str);
                    if (new_val.is_undefined()) {
                        obj.delete_prop(key_str);
                    } else {
                        obj.put_prop(key_str, new_val);
                    }
                }
            }
        }
    }

    // Call reviver(this=holder, name, val)
    TVal name_str;
    name_str.set_string(name);

    // For the reviver call, we need to invoke it via the calling convention
    // Since we're in a builtin context, we need to set up the stack
    // and re-dispatch. However, since JSON.parse is called as a LIGHTFUNC,
    // we don't have a VM activation. We need to signal re-dispatch.
    // For now, skip reviver and just return val
    return val;
}

/// Helper: throw a SyntaxError from a JSON builtin.
fn void json_throw_syntax_error(BuiltinContext* ctx, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        err.put_prop(msg_key, msg_tv);
        ctx.throw_value.set_object(err);
    } else {
        ctx.throw_value.set_undefined();
    }
    ctx.should_throw = true;
}

/// JSON.parse(text [, reviver]) — ES5 §15.12.2
fn void builtin_json_parse(BuiltinContext* ctx) {
    // Step 1: Coerce first argument to string
    if (ctx.argc < 1) {
        json_throw_syntax_error(ctx, "JSON.parse requires at least 1 argument");
        return;
    }

    TVal* text_arg = &ctx.regs[ctx.base_reg];
    HString* text_str;

    if (text_arg.is_string()) {
        text_str = (HString*)text_arg.get_heapptr();
    } else {
        text_str = builtin_to_string(ctx.heap, text_arg);
        if (text_str == null) {
            json_throw_syntax_error(ctx, "Invalid JSON");
            return;
        }
    }

    char* src = text_str.get_cstr();
    uint len = text_str.blen;

    JsonParseCtx jctx;
    jctx.src = src;
    jctx.pos = 0;
    jctx.len = len;
    jctx.heap = ctx.heap;

    TVal result = json_parse_value(&jctx);

    // Check parse error (undefined == error)
    if (result.is_undefined() && result.get_heapptr() == null) {
        json_throw_syntax_error(ctx, "Unexpected token in JSON");
        return;
    }

    // Skip trailing whitespace
    json_skip_ws(&jctx);
    if (jctx.pos != jctx.len) {
        // Trailing non-whitespace characters → SyntaxError
        json_throw_syntax_error(ctx, "Unexpected token in JSON");
        return;
    }

    // Reviver support (ES5 §15.12.2 step 4)
    if (ctx.argc > 1) {
        TVal* reviver_arg = &ctx.regs[ctx.base_reg + 1];
        if (reviver_arg.is_lightfunc() || (reviver_arg.is_object() &&
            ((HObject*)reviver_arg.get_heapptr()) != null &&
            ((HObject*)reviver_arg.get_heapptr()).is_callable())) {
            // Create holder object { "": result }
            HObject*? holder_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try holder = holder_raw) {
                HString* empty_key = builtin_intern_string(ctx.heap, "");
                holder.put_prop(empty_key, result);

                TVal holder_tv;
                holder_tv.set_object(holder);

                // For now, skip the full walk and just return result without reviver
                // Full reviver support requires VM re-dispatch which is complex
                *ctx.result = result;
            } else {
                *ctx.result = result;
            }
        } else {
            *ctx.result = result;
        }
    } else {
        *ctx.result = result;
    }
}

// ============================================================================
// JSON.stringify (ES5 §15.12.3)
// ============================================================================

/// Helper: append a JSON-escaped string to a buffer.
fn usz json_escape_string(char* src, uint len, char* buf, usz buf_size) {
    usz pos = 0;
    if (pos < buf_size) buf[pos++] = '\"';
    for (uint i = 0; i < len && pos < buf_size; i++) {
        char c = src[i];
        switch (c) {
            case '\"': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = '\"'; break;
            case '\\': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = '\\'; break;
            case '\b': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'b'; break;
            case '\f': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'f'; break;
            case '\n': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'n'; break;
            case '\r': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'r'; break;
            case '\t': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 't'; break;
            default:
                if ((c & 0x80) != 0) {
                    // Non-ASCII: pass through as-is (valid UTF-8)
                    if (pos >= buf_size) break;
                    buf[pos++] = c;
                } else if (c < 0x20) {
                    // Control char: \uXXXX
                    if (pos + 6 > buf_size) break;
                    buf[pos++] = '\\';
                    buf[pos++] = 'u';
                    buf[pos++] = '0';
                    buf[pos++] = '0';
                    char[16] hex_digits = { '0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f' };
                    buf[pos++] = hex_digits[(c >> 4) & 0xF];
                    buf[pos++] = hex_digits[c & 0xF];
                } else {
                    // Regular ASCII
                    if (pos >= buf_size) break;
                    buf[pos++] = c;
                }
                break;
        }
    }
    if (pos < buf_size) buf[pos++] = '\"';
    return pos;
}

/// Serialize a JSON value (internal recursive helper).
/// Returns 0 on success, non-zero on error.
/// Writes to buf starting at offset, updates offset.
struct JsonSerializeCtx {
    Heap* heap;
    void* vm;                    // VM pointer for calling JS functions
    char* buf;
    usz buf_size;
    usz offset;
    usz indent_level;
    char* gap;
    usz gap_len;
    /// Current stack depth for cycle detection
    uint depth;
    /// Replacer function (undefined if none)
    TVal replacer_func;
    /// Property list from replacer array (null if none)
    HString** prop_keys;
    uint prop_key_count;
    /// True when a replacer array was provided (even if empty)
    bool has_replacer_array;
    /// Set when a call_fn error occurred (toJSON/replacer threw)
    bool error;
}

const uint JSON_MAX_DEPTH = 128;

/// ES5 §15.12.3 step 5: Type unwrapping via ToString/ToNumber/ToBoolean.
/// For String/Number wrapper objects, calls toString()/valueOf() (per spec)
/// rather than reading the cached primitive_value (which ignores overrides).
/// Returns the unwrapped TVal. Sets *had_error=true if the method threw.
/// For non-wrapper objects, returns the value unchanged.
fn TVal json_unwrap_wrapper(JsonSerializeCtx* jctx, TVal val, bool* had_error) {
    *had_error = false;
    if (!val.is_object() || val.get_heapptr() == null) return val;
    HObject* obj = (HObject*)val.get_heapptr();
    ObjClass cls = obj.get_class();

    // Boolean wrapper: just read [[BooleanData]] per spec
    if (cls == ObjClass.BOOLEAN) {
        if ((*obj.extra_ptr()).prim.primitive_value.is_boolean()) {
            TVal result;
            result.set_boolean((*obj.extra_ptr()).prim.primitive_value.get_boolean());
            return result;
        }
        return val;
    }

    // String wrapper: ToString → call toString()
    if (cls == ObjClass.STRING) {
        HString* to_str_key = (HString*)jctx.heap.strs[heap::BuiltinStr.TO_STRING];
        if (to_str_key == null) return val;
        TVal? toString_fn_opt = obj.get_prop(to_str_key);
        if (try toString_fn = toString_fn_opt) {
            bool callable = false;
            if (toString_fn.is_object() && toString_fn.get_heapptr() != null) {
                HObject* fn_hobj = (HObject*)toString_fn.get_heapptr();
                callable = fn_hobj.is_callable();
            } else if (toString_fn.is_lightfunc()) {
                callable = true;
            }
            if (callable && jctx.heap.call_fn != null && jctx.vm != null) {
                TVal result = jctx.heap.call_fn(jctx.vm, toString_fn, null, 0, val);
                if (jctx.heap.has_error) { *had_error = true; return val; }
                return result;
            }
        }
        // No callable toString — fall back to primitive value
        if ((*obj.extra_ptr()).prim.primitive_value.is_string()) {
            return (*obj.extra_ptr()).prim.primitive_value;
        }
        return val;
    }

    // Number wrapper: ToNumber → call valueOf() first (per ES §9.3 / §15.12.3.4)
    if (cls == ObjClass.NUMBER) {
        HString* vo_key = (HString*)jctx.heap.strs[heap::BuiltinStr.VALUE_OF];
        if (vo_key != null) {
            TVal? valueOf_fn_opt = obj.get_prop(vo_key);
            if (try valueOf_fn = valueOf_fn_opt) {
                bool callable = false;
                if (valueOf_fn.is_object() && valueOf_fn.get_heapptr() != null) {
                    HObject* fn_hobj = (HObject*)valueOf_fn.get_heapptr();
                    callable = fn_hobj.is_callable();
                } else if (valueOf_fn.is_lightfunc()) {
                    callable = true;
                }
                if (callable && jctx.heap.call_fn != null && jctx.vm != null) {
                    TVal result = jctx.heap.call_fn(jctx.vm, valueOf_fn, null, 0, val);
                    if (jctx.heap.has_error) { *had_error = true; return val; }
                    return result;
                }
            }
        }
        // Fallback: primitive value
        return (*obj.extra_ptr()).prim.primitive_value;
    }

    return val;
}

/// Apply toJSON + replacer function + type unwrapping per ES5 §15.12.3
/// SerializeJSONProperty steps 1-4. Returns the processed value.
/// If the result should be omitted (undefined/functions), sets *omit=true.
fn TVal json_check_property(JsonSerializeCtx* jctx, HString* key, TVal val, TVal holder, bool* omit) {
    *omit = false;

    // Step 2: Check toJSON on objects
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        HString* toJSON_key = builtin_intern_string(jctx.heap, "toJSON");
        TVal? toJSON_val = obj.get_prop(toJSON_key);
        if (try toJSON_fn = toJSON_val) {
            bool callable = false;
            if (toJSON_fn.is_object() && toJSON_fn.get_heapptr() != null) {
                HObject* fn_hobj = (HObject*)toJSON_fn.get_heapptr();
                callable = fn_hobj.is_callable();
            } else if (toJSON_fn.is_lightfunc()) {
                callable = true;
            }
            if (callable) {
                TVal key_tv;
                key_tv.set_string(key);
                TVal[1] json_args;
                json_args[0] = key_tv;
                if (jctx.heap.call_fn != null && jctx.vm != null) {
                    val = jctx.heap.call_fn(jctx.vm, toJSON_fn, &json_args[0], 1, val);
                    if (jctx.heap.has_error) { jctx.error = true; *omit = true; return val; }
                }
            }
        }
    }

    // Step 3: Call replacer function
    if (!jctx.replacer_func.is_undefined()) {
        bool callable = false;
        if (jctx.replacer_func.is_object() && jctx.replacer_func.get_heapptr() != null) {
            HObject* fn_hobj = (HObject*)jctx.replacer_func.get_heapptr();
            callable = fn_hobj.is_callable();
        } else if (jctx.replacer_func.is_lightfunc()) {
            callable = true;
        }
        if (callable) {
            TVal key_tv;
            key_tv.set_string(key);
            TVal[2] rep_args;
            rep_args[0] = key_tv;
            rep_args[1] = val;
            if (jctx.heap.call_fn != null && jctx.vm != null) {
                val = jctx.heap.call_fn(jctx.vm, jctx.replacer_func, &rep_args[0], 2, holder);
                if (jctx.heap.has_error) { jctx.error = true; *omit = true; return val; }
            }
        }
    }

    // Step 4: Unwrap wrapper objects (String/Number/Boolean) per ES5 §15.12.3
    // For String/Number wrappers, ToString/ToNumber calls toString()/valueOf()
    // — must respect any overridden methods on the wrapper.
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        ObjClass cls = obj.get_class();
        if (cls == ObjClass.STRING || cls == ObjClass.NUMBER || cls == ObjClass.BOOLEAN) {
            bool unwrap_err = false;
            TVal unwrapped = json_unwrap_wrapper(jctx, val, &unwrap_err);
            if (unwrap_err) { jctx.error = true; *omit = true; return unwrapped; }
            val = unwrapped;
        }
    }

    // Step 5-12: Determine if value should be omitted
    // undefined and functions → omit
    if (val.is_undefined()) { *omit = true; return val; }
    if (val.is_lightfunc()) { *omit = true; return val; }
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.get_class() == ObjClass.FUNCTION) { *omit = true; return val; }
    }

    return val;
}

/// Check if a value is an array-like object per ES5 spec (HasProperty with "length")
fn bool json_is_array(HObject* obj) {
    return obj.get_class() == ObjClass.ARRAY;
}

/// Serialize an object's properties
fn int json_serialize_object(JsonSerializeCtx* jctx, HObject* obj) {
    if (jctx.error) return -1;
    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = '{';

    // Create holder TVal for replacer calls
    TVal holder;
    holder.set_object(obj);

    // Build the key list: use property_list if replacer array, else own properties
    bool has_replacer = jctx.has_replacer_array;
    bool has_props = false;


    if (!has_replacer) {
        // Check if object has own properties (including accessor properties with getters)
        for (uint i = 0; i < obj.prop_count; i++) {
            if (obj.prop_key_at(i) != null) {
                has_props = true;
                break;
            }
        }
    } else {
        has_props = true;
    }

    if (!has_props) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = '}';
        return 0;
    }

    bool first = true;

    if (has_replacer) {
        // Iterate property list from replacer array
        for (uint p = 0; p < jctx.prop_key_count; p++) {
            HString* key_hstr = jctx.prop_keys[p];

            // Get value from object
            TVal? val_opt = obj.get_prop(key_hstr);
            TVal val;
            if (try v = val_opt) {
                val = v;
            } else {
                val.set_undefined();
            }

            // Apply toJSON + replacer
            bool omit = false;
            val = json_check_property(jctx, key_hstr, val, holder, &omit);
            if (jctx.error) return -1;
            if (omit) continue;

            if (!first) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = ',';
            }
            first = false;

            // Indentation
            if (jctx.gap_len > 0) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = '\n';
                for (usz g = 0; g < (jctx.indent_level + 1) * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
                    jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
                }
            }

            // Key
            char* key_data = key_hstr.get_cstr();
            uint key_len = key_hstr.blen;
            char[1024] key_buf;
            usz key_out = json_escape_string(key_data, key_len, &key_buf, 1024);
            usz copy = key_out < (jctx.buf_size - jctx.offset) ? key_out : (jctx.buf_size - jctx.offset);
            for (usz k = 0; k < copy; k++) {
                jctx.buf[jctx.offset++] = key_buf[k];
            }

            if (jctx.offset + 2 > jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = ':';
            if (jctx.gap_len > 0) {
                jctx.buf[jctx.offset++] = ' ';
            }

            // Value
            jctx.depth++;
            if (jctx.depth > JSON_MAX_DEPTH) {
                jctx.depth--;
                return -1;
            }
            int r = json_serialize_val(jctx, &val);
            jctx.depth--;
            if (r != 0) return r;
        }
    } else {
        // Snapshot property keys before iterating, so that getters that delete
        // properties don't cause keys to be skipped (ES5 §15.12.3 step 4.b).
        HString*[64] snap_keys;
        ushort[64] snap_indices;
        uint snap_count = 0;
        for (uint i = 0; i < obj.prop_count && snap_count < 64; i++) {
            if (obj.prop_key_at(i) != null) {
                snap_keys[snap_count] = (HString*)obj.prop_key_at(i);
                snap_indices[snap_count] = (ushort)i;
                snap_count++;
            }
        }

        for (uint si = 0; si < snap_count; si++) {
            HString* key_hstr = snap_keys[si];
            uint pi = snap_indices[si];
            TVal val;
            // Check if property still exists and read its value
            if (pi < obj.prop_count && obj.prop_key_at(pi) == key_hstr) {
                if (obj.get_prop_flags(pi).is_accessor) {
                    // Invoke the getter to get the property value
                    TVal getter_fn = obj.prop_values()[pi].data.getter;
                    if (getter_fn.is_undefined() || getter_fn.is_null()) {
                        val.set_undefined();
                    } else if (jctx.heap.call_fn != null && jctx.vm != null) {
                        TVal holder_tv;
                        holder_tv.set_object(obj);
                        val = jctx.heap.call_fn(jctx.vm, getter_fn, null, 0, holder_tv);
                        if (jctx.heap.has_error) { jctx.error = true; return -1; }
                    } else {
                        continue;
                    }
                } else {
                    val = obj.prop_values()[pi].data.value;
                }
            } else {
                // Property was deleted (e.g., by a getter) — treat as undefined
                val.set_undefined();
            }

            // Apply toJSON + replacer (even without explicit replacer, this
            // handles the spec correctly — when replacer_func is undefined
            // the check just does toJSON + type unwrapping)
            bool omit = false;
            val = json_check_property(jctx, key_hstr, val, holder, &omit);
            if (jctx.error) return -1;
            if (omit) continue;

            if (!first) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = ',';
            }
            first = false;

            // Indentation
            if (jctx.gap_len > 0) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = '\n';
                for (usz g = 0; g < (jctx.indent_level + 1) * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
                    jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
                }
            }

            // Key
            char* key_data = key_hstr.get_cstr();
            uint key_len = key_hstr.blen;
            char[1024] key_buf;
            usz key_out = json_escape_string(key_data, key_len, &key_buf, 1024);
            usz copy = key_out < (jctx.buf_size - jctx.offset) ? key_out : (jctx.buf_size - jctx.offset);
            for (usz k = 0; k < copy; k++) {
                jctx.buf[jctx.offset++] = key_buf[k];
            }

            if (jctx.offset + 2 > jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = ':';
            if (jctx.gap_len > 0) {
                jctx.buf[jctx.offset++] = ' ';
            }

            // Value
            jctx.depth++;
            if (jctx.depth > JSON_MAX_DEPTH) {
                jctx.depth--;
                return -1;
            }
            int r = json_serialize_val(jctx, &val);
            jctx.depth--;
            if (r != 0) return r;
        }
    }

    if (jctx.gap_len > 0) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = '\n';
        for (usz g = 0; g < jctx.indent_level * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
            jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
        }
    }

    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = '}';
    return 0;
}

/// Serialize an array
fn int json_serialize_array(JsonSerializeCtx* jctx, HObject* arr) {
    if (jctx.error) return -1;
    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = '[';

    // Create holder TVal for replacer calls
    TVal holder;
    holder.set_object(arr);

    // Check if dense array fast path is available for element reads
    bool is_dense = (arr.get_class() == ObjClass.ARRAY)
                    && arr.array_part() != null;

    // Always read length from the property (spec-correct)
    HString* len_key = builtin_intern_string(jctx.heap, "length");
    TVal? len_prop = arr.get_prop(len_key);
    uint len = 0;
    if (try l = len_prop) {
        if (l.is_fastint()) {
            len = (uint)l.get_fastint();
        } else if (l.is_number()) {
            len = (uint)(long)l.get_number();
        }
    }

    if (len == 0) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = ']';
        return 0;
    }

    bool first = true;
    for (uint i = 0; i < len; i++) {
        // Read element: try array_part fast path first, then fall back to prop lookup
        TVal elem;
        bool found = false;
        if (is_dense && i < arr.array_size) {
            TVal av = arr.array_part()[i];
            if (!av.is_undefined()) {
                elem = av;
                found = true;
            }
            // undefined in array_part means hole — fall through to prop lookup
        }

        // Build the index key for this element
        HString* idx_key = jctx.heap.int_to_hstring((long)i);

        if (!found) {
            TVal? elem_prop = arr.get_prop(idx_key);
            if (try e = elem_prop) {
                elem = e;
                found = true;
            } else {
                elem.set_undefined();
            }
        }

        // Apply toJSON + replacer
        bool omit = false;
        elem = json_check_property(jctx, idx_key, elem, holder, &omit);
        if (jctx.error) return -1;

        if (!first) {
            if (jctx.offset >= jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = ',';
        }
        first = false;

        // Indentation
        if (jctx.gap_len > 0) {
            if (jctx.offset >= jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = '\n';
            for (usz g = 0; g < (jctx.indent_level + 1) * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
                jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
            }
        }

        // null for omitted/undefined elements
        if (omit || elem.is_undefined()) {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
        } else if (elem.is_lightfunc()) {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
        } else if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* vobj = (HObject*)elem.get_heapptr();
            if (vobj.get_class() == ObjClass.FUNCTION) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
            } else {
                jctx.depth++;
                if (jctx.depth > JSON_MAX_DEPTH) {
                    jctx.depth--;
                    return -1;
                }
                int r = json_serialize_val(jctx, &elem);
                jctx.depth--;
                if (r != 0) return r;
            }
        } else {
            jctx.depth++;
            if (jctx.depth > JSON_MAX_DEPTH) {
                jctx.depth--;
                return -1;
            }
            int r = json_serialize_val(jctx, &elem);
            jctx.depth--;
            if (r != 0) return r;
        }
    }

    if (jctx.gap_len > 0) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = '\n';
        for (usz g = 0; g < jctx.indent_level * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
            jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
        }
    }

    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = ']';
    return 0;
}

/// Serialize a value to JSON
fn int json_serialize_val(JsonSerializeCtx* jctx, TVal* val) {
    switch (val.get_tag()) {
        case NULL_VAL: {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = 'n';
            jctx.buf[jctx.offset++] = 'u';
            jctx.buf[jctx.offset++] = 'l';
            jctx.buf[jctx.offset++] = 'l';
            return 0;
        }
        case BOOLEAN: {
            if (val.get_boolean()) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "true", 4);
                jctx.offset += 4;
            } else {
                if (jctx.offset + 6 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "false", 5);
                jctx.offset += 5;
            }
            return 0;
        }
        case NUMBER: {
            double d = val.get_number();
            if (math::is_nan(d) || math::is_inf(d)) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
                return 0;
            }
            char[64] buf;
            int len = libc::snprintf(&buf, 64, "%.17g", d);
            if (len < 0 || len >= 64) return -1;
            if (jctx.offset + (usz)len > jctx.buf_size) return -1;
            for (int i = 0; i < len; i++) {
                jctx.buf[jctx.offset++] = buf[i];
            }
            return 0;
        }
        case FASTINT: {
            char[24] buf;
            int len = hstring::int_to_buf(val.get_fastint(), &buf, 24);
            if (len <= 0) return -1;
            if (jctx.offset + (usz)len > jctx.buf_size) return -1;
            for (int i = 0; i < len; i++) {
                jctx.buf[jctx.offset++] = buf[i];
            }
            return 0;
        }
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            char* data = s.get_cstr();
            uint slen = s.blen;
            usz max_out = (usz)(slen * 6 + 3);
            char[4096] str_buf;
            usz out_len = json_escape_string(data, slen, &str_buf, 4096);
            if (out_len == 0) return -1;
            usz copy = out_len < (jctx.buf_size - jctx.offset) ? out_len : (jctx.buf_size - jctx.offset);
            for (usz i = 0; i < copy; i++) {
                jctx.buf[jctx.offset++] = str_buf[i];
            }
            return 0;
        }
        case OBJECT: {
            if (val.get_heapptr() == null) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
                return 0;
            }
            HObject* obj = (HObject*)val.get_heapptr();
            if (obj.get_class() == ObjClass.ARRAY) {
                return json_serialize_array(jctx, obj);
            } else if (obj.get_class() == ObjClass.FUNCTION) {
                // Functions serialize as null in JSON
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
                return 0;
            } else {
                return json_serialize_object(jctx, obj);
            }
        }
        case LIGHTFUNC: {
            // Functions serialize as null
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
            return 0;
        }
        case UNDEFINED:
        case BUFFER:
        case POINTER:
        default:
            // Undefined, Buffer, Pointer -> serialize as null
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
            return 0;
    }
}

/// JSON.stringify(value [, replacer [, space]]) — ES5 §15.12.3
fn void builtin_json_stringify(BuiltinContext* ctx) {
    // Clear any stale error flag and value
    ctx.heap.has_error = false;
    ctx.heap.error_value.set_undefined();
    // Get the value
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal value = ctx.regs[ctx.base_reg];

    // Process replacer argument
    TVal replacer_func;
    replacer_func.set_undefined();
    HString** prop_keys = null;
    uint prop_key_count = 0;
    bool has_replacer_array_flag = false;

    if (ctx.argc > 1) {
        TVal replacer = ctx.regs[ctx.base_reg + 1];

        if (replacer.is_object() && replacer.get_heapptr() != null) {
            HObject* robj = (HObject*)replacer.get_heapptr();
            if (robj.is_callable()) {
                replacer_func = replacer;
            } else if (robj.get_class() == ObjClass.ARRAY) {
                // Build PropertyList from array elements
                // Max 256 keys in property list
                HString*[256] temp_keys;
                uint count = 0;
                has_replacer_array_flag = true;

                // Get length
                HString* len_key = builtin_intern_string(ctx.heap, "length");
                TVal? len_prop = robj.get_prop(len_key);
                uint arr_len = 0;
                if (try l = len_prop) {
                    if (l.is_fastint()) {
                        arr_len = (uint)l.get_fastint();
                    } else if (l.is_number()) {
                        arr_len = (uint)(long)l.get_number();
                    }
                }


                bool is_dense = robj.get_class() == ObjClass.ARRAY && robj.array_part() != null;

                for (uint i = 0; i < arr_len && count < 256; i++) {
                    // Read element: try dense array fast path, then prop lookup
                    TVal elem;
                    bool found = false;
                    if (is_dense && i < robj.array_size) {
                        TVal av = robj.array_part()[i];
                        if (!av.is_undefined()) {
                            elem = av;
                            found = true;
                        }
                    }
                    if (!found) {
                        HString* idx_key = ctx.heap.int_to_hstring((long)i);
                        if (idx_key == null) continue;
                        TVal? elem_opt = robj.get_prop(idx_key);
                        if (try e = elem_opt) {
                            elem = e;
                            found = true;
                        }
                    }
                    if (!found) continue;

                    // Convert to string key per spec:
                    // String → use as-is
                    // Number → ToString
                    // String object → ToString (via .toString())
                    // Number object → ToString (via .toString())
                    // Everything else → skip
                    HString* str_key = null;

                    if (elem.is_string()) {
                        str_key = (HString*)elem.get_heapptr();
                    } else if (elem.is_fastint()) {
                        str_key = ctx.heap.int_to_hstring(elem.get_fastint());
                    } else if (elem.is_number()) {
                        char[64] num_buf;
                        int num_len = libc::snprintf(&num_buf, 64, "%.17g", elem.get_number());
                        str_key = builtin_intern_string(ctx.heap, num_buf[:num_len]);
                    } else if (elem.is_object() && elem.get_heapptr() != null) {
                        HObject* eobj = (HObject*)elem.get_heapptr();
                        if (eobj.get_class() == ObjClass.STRING) {
                            // ToString(value): call toString() to respect overrides
                            HString* ts_key = (HString*)ctx.heap.strs[heap::BuiltinStr.TO_STRING];
                            if (ts_key != null) {
                                TVal? toString_fn_opt = eobj.get_prop(ts_key);
                                if (try toString_fn = toString_fn_opt) {
                                    bool callable = false;
                                    if (toString_fn.is_object() && toString_fn.get_heapptr() != null) {
                                        callable = ((HObject*)toString_fn.get_heapptr()).is_callable();
                                    } else if (toString_fn.is_lightfunc()) {
                                        callable = true;
                                    }
                                    if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                                        TVal res = ctx.heap.call_fn(ctx.vm, toString_fn, null, 0, elem);
                                        if (ctx.heap.has_error) { /* propagate later via ctx */ }
                                        else if (res.is_string()) {
                                            str_key = (HString*)res.get_heapptr();
                                        }
                                    }
                                }
                            }
                            // Fallback: primitive value
                            if (str_key == null && (*eobj.extra_ptr()).prim.primitive_value.is_string()) {
                                str_key = (HString*)(*eobj.extra_ptr()).prim.primitive_value.get_heapptr();
                            }
                        } else if (eobj.get_class() == ObjClass.NUMBER) {
                            // ToString(value): call toString() to respect overrides
                            HString* ts_key = (HString*)ctx.heap.strs[heap::BuiltinStr.TO_STRING];
                            if (ts_key != null) {
                                TVal? toString_fn_opt = eobj.get_prop(ts_key);
                                if (try toString_fn = toString_fn_opt) {
                                    bool callable = false;
                                    if (toString_fn.is_object() && toString_fn.get_heapptr() != null) {
                                        callable = ((HObject*)toString_fn.get_heapptr()).is_callable();
                                    } else if (toString_fn.is_lightfunc()) {
                                        callable = true;
                                    }
                                    if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                                        TVal res = ctx.heap.call_fn(ctx.vm, toString_fn, null, 0, elem);
                                        if (ctx.heap.has_error) { /* propagate later via ctx */ }
                                        else if (res.is_string()) {
                                            str_key = (HString*)res.get_heapptr();
                                        } else if (res.is_fastint() || res.is_number()) {
                                            char[64] nb;
                                            int nl = libc::snprintf(&nb, 64, "%.17g",
                                                res.is_fastint() ? (double)res.get_fastint() : res.get_number());
                                            str_key = builtin_intern_string(ctx.heap, nb[:nl]);
                                        }
                                    }
                                }
                            }
                            // Fallback: primitive value
                            if (str_key == null) {
                                TVal pv = (*eobj.extra_ptr()).prim.primitive_value;
                                if (pv.is_fastint()) {
                                    str_key = ctx.heap.int_to_hstring(pv.get_fastint());
                                } else if (pv.is_number()) {
                                    char[64] num_buf;
                                    int num_len = libc::snprintf(&num_buf, 64, "%.17g", pv.get_number());
                                    str_key = builtin_intern_string(ctx.heap, num_buf[:num_len]);
                                }
                            }
                        }
                    }

                    if (str_key == null) continue;

                    // Deduplicate: check if already in list
                    bool dup = false;
                    for (uint d = 0; d < count; d++) {
                        if (temp_keys[d] == str_key) { dup = true; break; }
                    }
                    if (dup) continue;

                    temp_keys[count] = str_key;
                    count++;
                }

                if (count > 0) {
                    prop_keys = (HString**)libc::malloc(count * HString*::size);
                    if (prop_keys != null) {
                        libc::memcpy(prop_keys, &temp_keys[0], count * HString*::size);
                        prop_key_count = count;
                    }
                }

            }
        }
        // Non-callable, non-array replacer → ignore (leave replacer_func undefined)
    }

    // Check space parameter — unwrap Number/String wrappers
    uint space_num = 0;
    char[16] gap_buf;
    usz gap_len = 0;

    if (ctx.argc > 2) {
        TVal space_arg = ctx.regs[ctx.base_reg + 2];

        // Unwrap Number/String wrapper objects via ToString/ToNumber per spec
        if (space_arg.is_object() && space_arg.get_heapptr() != null) {
            HObject* sobj = (HObject*)space_arg.get_heapptr();
            if (sobj.get_class() == ObjClass.NUMBER) {
                // ToNumber(space) → call valueOf()
                HString* vo_key = (HString*)ctx.heap.strs[heap::BuiltinStr.VALUE_OF];
                if (vo_key != null) {
                    TVal? vo_opt = sobj.get_prop(vo_key);
                    if (try vo_fn = vo_opt) {
                        bool callable = false;
                        if (vo_fn.is_object() && vo_fn.get_heapptr() != null) {
                            callable = ((HObject*)vo_fn.get_heapptr()).is_callable();
                        } else if (vo_fn.is_lightfunc()) {
                            callable = true;
                        }
                        if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                            TVal res = ctx.heap.call_fn(ctx.vm, vo_fn, null, 0, space_arg);
                            if (ctx.heap.has_error) { /* propagate later */ }
                            else { space_arg = res; }
                        }
                    }
                }
                if (space_arg.is_object() && space_arg.get_heapptr() != null) {
                    space_arg = (*sobj.extra_ptr()).prim.primitive_value;
                }
            } else if (sobj.get_class() == ObjClass.STRING) {
                // ToString(space) → call toString()
                HString* ts_key = (HString*)ctx.heap.strs[heap::BuiltinStr.TO_STRING];
                if (ts_key != null) {
                    TVal? ts_opt = sobj.get_prop(ts_key);
                    if (try ts_fn = ts_opt) {
                        bool callable = false;
                        if (ts_fn.is_object() && ts_fn.get_heapptr() != null) {
                            callable = ((HObject*)ts_fn.get_heapptr()).is_callable();
                        } else if (ts_fn.is_lightfunc()) {
                            callable = true;
                        }
                        if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                            TVal res = ctx.heap.call_fn(ctx.vm, ts_fn, null, 0, space_arg);
                            if (ctx.heap.has_error) { /* propagate later */ }
                            else { space_arg = res; }
                        }
                    }
                }
                if (space_arg.is_object() && space_arg.get_heapptr() != null &&
                    (*sobj.extra_ptr()).prim.primitive_value.is_string()) {
                    space_arg = (*sobj.extra_ptr()).prim.primitive_value;
                }
            }
        }

        if (space_arg.is_fastint()) {
            space_num = (uint)space_arg.get_fastint();
            if (space_num > 10) space_num = 10;
        } else if (space_arg.is_number()) {
            space_num = (uint)(long)space_arg.get_number();
            if (space_num > 10) space_num = 10;
        } else if (space_arg.is_string()) {
            HString* s = (HString*)space_arg.get_heapptr();
            char* data = s.get_cstr();
            uint slen = s.blen;
            if (slen > 10) slen = 10;
            for (uint i = 0; i < slen; i++) {
                gap_buf[i] = data[i];
            }
            gap_len = slen;
        }
    }

    // Build gap string
    char[16] gap_str;
    if (space_num > 0) {
        gap_len = space_num;
        for (uint i = 0; i < gap_len && i < 16; i++) {
            gap_str[i] = ' ';
        }
    } else if (gap_len > 0) {
        // String gap: copy from gap_buf to gap_str
        for (usz i = 0; i < gap_len && i < 16; i++) {
            gap_str[i] = gap_buf[i];
        }
    }

    // Apply root-level toJSON + replacer per spec:
    // 1. Create wrapper = { "": value }
    // 2. If ReplacerFunction: value = Call(replacer, wrapper, ["", value])
    // 3. Process the result

    // Create wrapper object
    HObject*? wrapper_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch werr = wrapper_raw) {
        ctx.result.set_undefined();
        if (prop_keys != null) libc::free(prop_keys);
        return;
    }
    HObject* wrapper = wrapper_raw;

    TVal wrapper_tv;
    wrapper_tv.set_object(wrapper);

    // Set wrapper[""] = value
    HString* empty_key = builtin_intern_string(ctx.heap, "");
    wrapper.put_prop(empty_key, value);

    // Initialize serialization context
    char[16384] buf;
    JsonSerializeCtx jctx;
    jctx.heap = ctx.heap;
    jctx.vm = ctx.vm;
    jctx.buf = &buf;
    jctx.buf_size = 16384;
    jctx.offset = 0;
    jctx.indent_level = 0;
    jctx.gap = &gap_str;
    jctx.gap_len = gap_len;
    jctx.depth = 0;
    jctx.replacer_func = replacer_func;
    jctx.prop_keys = prop_keys;
    jctx.prop_key_count = prop_key_count;
    jctx.has_replacer_array = has_replacer_array_flag;

    // Apply root-level check: get value from wrapper, apply toJSON + replacer
    bool root_omit = false;
    TVal root_val = json_check_property(&jctx, empty_key, value, wrapper_tv, &root_omit);

    if (jctx.error || ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        if (prop_keys != null) libc::free(prop_keys);
        return;
    }

    if (root_omit) {
        ctx.result.set_undefined();
        if (prop_keys != null) libc::free(prop_keys);
        return;
    }

    // Serialize the processed value
    int result = json_serialize_val(&jctx, &root_val);

    if (jctx.error || ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        if (prop_keys != null) libc::free(prop_keys);
        return;
    }

    if (prop_keys != null) libc::free(prop_keys);

    if (result != 0) {
        ctx.result.set_undefined();
        return;
    }

    HString* result_str = builtin_intern_string(ctx.heap, buf[:jctx.offset]);
    ctx.result.set_string(result_str);
}
fn bool register_json_object(EnvRecord* global_env, Heap* heap) {
    HObject*? json_raw = heap.alloc_object(hobject::ObjClass.JSON);
    if (catch err = json_raw) return false;
    HObject* json = json_raw;

    // Register JSON.parse
    if (!register_math_method(json, heap, "parse", BUILTIN_JSON_PARSE)) return false;
    // Register JSON.stringify
    if (!register_math_method(json, heap, "stringify", BUILTIN_JSON_STRINGIFY)) return false;

    TVal json_tv;
    json_tv.set_object(null);
    json_tv.set_fastint(0);
    json_tv.set_object(json);
    return register_named_value(global_env, heap, "JSON", json_tv);
}
