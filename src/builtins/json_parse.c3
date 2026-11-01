// JSON.parse over the code units of the source string, in place.
//
// `Unit` is `char` for a narrow (Latin-1) source and `ushort` for a wide
// (UTF-16) one, so one parser serves both without transcoding the text. The
// code points JSON cares about are all ASCII, which both widths store as the
// same values. Offsets are unit offsets into the source string.
module boomkat::builtins::jsonparse <Unit>;
import boomkat::builtins;
import boomkat::dtoa_bindings;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;

struct JsonParseCtx {
    Unit* src;
    uint pos;
    uint len;
    Heap* heap;
    bool error;  // set on parse error to distinguish from valid undefined
    bool record; // when true, parse functions build a JsonParseRecord tree
}

fn bool json_is_space(uint c) @inline {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

fn void json_skip_ws(JsonParseCtx* jctx) @inline {
    uint pos = jctx.pos;
    while (pos < jctx.len && json_is_space((uint)jctx.src[pos])) pos++;
    jctx.pos = pos;
}

// Parse a 4-digit hex escape (\uXXXX).
fn uint json_parse_hex4(JsonParseCtx* jctx) {
    uint val = 0;
    for (int i = 0; i < 4; i++) {
        if (jctx.pos >= jctx.len) return 0xFFFFFFFF;
        uint c = (uint)jctx.src[jctx.pos];
        uint d;
        if (c >= '0' && c <= '9') {
            d = c - '0';
        } else if (c >= 'a' && c <= 'f') {
            d = c - 'a' + 10;
        } else if (c >= 'A' && c <= 'F') {
            d = c - 'A' + 10;
        } else {
            return 0xFFFFFFFF;
        }
        val = (val << 4) | d;
        jctx.pos++;
    }
    return val;
}

// The string with the units `[from, to)` of the source, which hold no escape.
fn HString* json_source_slice(JsonParseCtx* jctx, uint from, uint to) @inline {
    $if Unit::size == 1:
        return jctx.heap.str_intern_units({ .ptr = (char*)jctx.src + from, .len = to - from, .wide = false });
    $else
        return jctx.heap.str_intern_span({ .ptr = (char*)(jctx.src + from), .len = to - from, .wide = true });
    $endif
}

// Parse a JSON string (between quotes) to an interned string.
// Returns null on parse error (unterminated string, invalid escape, etc.).
fn HString*? json_parse_string(JsonParseCtx* jctx) {
    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '\"') {
        return null;
    }
    jctx.pos++; // skip opening quote
    uint start = jctx.pos;
    uint pos = start;
    uint len = jctx.len;
    Unit* src = jctx.src;

    // Most strings hold no escape and are a slice of the source.
    while (pos < len) {
        uint c = (uint)src[pos];
        if (c == '\"') {
            jctx.pos = pos + 1;
            return json_source_slice(jctx, start, pos);
        }
        if (c == '\\' || c < 0x20) break;
        pos++;
    }
    if (pos >= len) return null; // unterminated string

    // An escape: build the string in a unit buffer. Grows to fit: valid JSON
    // produced by this engine must parse back. Bounded only by memory.
    UnitBuf buf;
    buf.init(jctx.heap);
    defer buf.free();
    if (!json_append_run(&buf, src, start, pos)) return null;

    while (pos < len) {
        uint c = (uint)src[pos];
        if (c == '\"') {
            jctx.pos = pos + 1;
            return buf.intern(jctx.heap);
        }
        if (c == '\\') {
            pos++;
            if (pos >= len) return null;
            uint esc = (uint)src[pos];
            pos++;
            uint unit;
            switch (esc) {
                case '\"': unit = '\"';
                case '\\': unit = '\\';
                case '/':  unit = '/';
                case 'b':  unit = '\b';
                case 'f':  unit = '\f';
                case 'n':  unit = '\n';
                case 'r':  unit = '\r';
                case 't':  unit = '\t';
                case 'u':
                    jctx.pos = pos;
                    unit = json_parse_hex4(jctx);
                    pos = jctx.pos;
                    if (unit == 0xFFFFFFFF) return null;
                default:
                    return null;
            }
            if (!buf.append_unit(unit)) return null;
        } else if (c < 0x20) {
            return null; // control characters are not allowed
        } else {
            // A run up to the next quote, backslash or control character.
            uint run = pos;
            while (run < len) {
                uint r = (uint)src[run];
                if (r == '\"' || r == '\\' || r < 0x20) break;
                run++;
            }
            if (!json_append_run(&buf, src, pos, run)) return null;
            pos = run;
        }
    }
    return null; // unterminated string
}

// Append the units `[from, to)` of the source.
fn bool json_append_run(UnitBuf* buf, Unit* src, uint from, uint to) @inline {
    $if Unit::size == 1:
        return buf.append_latin1(((char*)src)[from:to - from]);
    $else
        return buf.append_units({ .ptr = (char*)(src + from), .len = to - from, .wide = true });
    $endif
}

// The number token of `[start, jctx.pos)` as a double, by way of strtod. Fails
// only when the NUL-terminated copy strtod needs cannot be allocated.
fn bool json_token_to_double(JsonParseCtx* jctx, uint start, double* result) {
    uint count = jctx.pos - start;
    char[64] stack;
    char* text = &stack;
    if (count >= stack.len) {
        text = (char*)jctx.heap.alloc_func(jctx.heap.heap_udata, (usz)count + 1);
        if (text == null) return false;
    }
    for (uint i = 0; i < count; i++) text[i] = (char)jctx.src[start + i];
    text[count] = 0;
    char* endptr;
    double d = dtoa_bindings::atod_strtod_compat(text, &endptr);
    if (text != &stack) jctx.heap.free_func(jctx.heap.heap_udata, text);
    *result = d;
    return true;
}

// Parse a JSON number.
fn TVal json_parse_number(JsonParseCtx* jctx) {
    uint start = jctx.pos;
    uint pos = start;
    uint len = jctx.len;
    Unit* src = jctx.src;
    bool negative = false;
    TVal fail;
    fail.set_undefined();

    if (pos < len && src[pos] == '-') {
        negative = true;
        pos++;
    }

    // Integer part
    if (pos >= len) { jctx.error = true; return fail; }
    uint digits_start = pos;
    if (src[pos] == '0') {
        pos++;
    } else if (src[pos] >= '1' && src[pos] <= '9') {
        pos++;
        while (pos < len && src[pos] >= '0' && src[pos] <= '9') pos++;
    } else {
        jctx.error = true;
        return fail;
    }
    uint int_digits = pos - digits_start;
    bool integer = true;

    // Fractional part
    if (pos < len && src[pos] == '.') {
        integer = false;
        pos++;
        if (pos >= len || src[pos] < '0' || src[pos] > '9') { jctx.error = true; return fail; }
        while (pos < len && src[pos] >= '0' && src[pos] <= '9') pos++;
    }

    // Exponent part
    if (pos < len && (src[pos] == 'e' || src[pos] == 'E')) {
        integer = false;
        pos++;
        if (pos < len && (src[pos] == '+' || src[pos] == '-')) pos++;
        if (pos >= len || src[pos] < '0' || src[pos] > '9') { jctx.error = true; return fail; }
        while (pos < len && src[pos] >= '0' && src[pos] <= '9') pos++;
    }
    jctx.pos = pos;

    // Up to fifteen digits are exact in a double and well inside a long, so a
    // plain integer needs no strtod.
    if (integer && int_digits <= 15) {
        long value = 0;
        for (uint i = digits_start; i < pos; i++) value = value * 10 + (long)((uint)src[i] - '0');
        // A negative zero must stay one: JSON.parse("-0") is -0.
        if (negative && value == 0) { TVal r; r.set_number(-0.0); return r; }
        if (negative) value = -value;
        if (value >= types::FASTINT_MIN && value <= types::FASTINT_MAX) {
            TVal r; r.set_fastint(value); return r;
        }
        TVal r; r.set_number((double)value); return r;
    }

    double d;
    if (!json_token_to_double(jctx, start, &d)) {
        jctx.error = true;
        return fail;
    }
    // Try fastint preservation. Guard against negative zero: (long)(-0.0)==0
    // and (double)0==-0.0, so the fastint path would silently drop the sign.
    // The bound is the fastint payload range (±2^47), not the safe-integer
    // range (±(2^53-1)): a JSON number like 2251799813685248 (2^51) is a safe
    // integer but overflows set_fastint's 48-bit nanbox encoding and would be
    // silently truncated.
    long fi = (long)d;
    bool is_neg_zero = d == 0.0 && (1.0 / d) < 0.0;
    if (!is_neg_zero && (double)fi == d && fi >= types::FASTINT_MIN && fi <= types::FASTINT_MAX) {
        TVal r; r.set_fastint(fi); return r;
    }
    TVal r; r.set_number(d); return r;
}

// Parse a JSON array: [value, ...]
fn TVal json_parse_array(JsonParseCtx* jctx, JsonParseRecord** out_rec = null) {
    uint span_start = jctx.pos;
    jctx.pos++; // skip '['
    json_skip_ws(jctx);

    HObject*? arr_raw = jctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* arr;
    if (try a = arr_raw) {
        arr = a;
        jctx.heap.set_prototype(arr, jctx.heap.array_proto);
    } else {
        TVal r; r.set_undefined(); return r;
    }

    bool recording = out_rec != null && jctx.record;
    JsonParseRecord** elems = null;
    uint elem_cap = 0;

    HString* len_key = jctx.heap.str(heap::BuiltinStr.LENGTH);
    uint idx = 0;

    if (jctx.pos < jctx.len && jctx.src[jctx.pos] != ']') {
        while (true) {
            json_skip_ws(jctx);
            JsonParseRecord* child = null;
            TVal elem = json_parse_value(jctx, recording ? &child : null);
            defer jctx.heap.decref_tval(&elem);
            if (jctx.error || (elem.is_undefined() && elem.get_heapptr() == null && jctx.pos < jctx.len)) {
                jctx.error = true;
                if (elems != null) {
                    for (uint i = 0; i < idx; i++) builtins::json_record_free(jctx.heap, elems[i]);
                    jctx.heap.free_func(jctx.heap.heap_udata, elems);
                }
                builtins::json_record_free(jctx.heap, child);
                TVal r; r.set_undefined(); return r; // parse error
            }
            json_skip_ws(jctx);

            // Elements arrive in index order and are never undefined, so they
            // go straight into the dense part without minting a key per index.
            if (!arr.set_array_idx(idx, elem, jctx.heap)) {
                HString* idx_key = jctx.heap.int_to_hstring((long)idx);
                if (idx_key != null) {
                    arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC, jctx.heap);
                }
            }

            if (recording) {
                if (idx >= elem_cap) {
                    uint new_cap = elem_cap == 0 ? 8 : elem_cap * 2;
                    JsonParseRecord** ne = (JsonParseRecord**)jctx.heap.realloc_func(
                        jctx.heap.heap_udata, elems, (usz)new_cap * JsonParseRecord*::size);
                    if (ne != null) { elems = ne; elem_cap = new_cap; }
                    else { recording = false; }
                }
                if (recording) { elems[idx] = child; }
                else { builtins::json_record_free(jctx.heap, child); }
            }
            idx++;

            if (jctx.pos >= jctx.len) {
                jctx.error = true;
                if (elems != null) {
                    for (uint i = 0; i < idx; i++) builtins::json_record_free(jctx.heap, elems[i]);
                    jctx.heap.free_func(jctx.heap.heap_udata, elems);
                }
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
        jctx.error = true;
        if (elems != null) {
            for (uint i = 0; i < idx; i++) builtins::json_record_free(jctx.heap, elems[i]);
            jctx.heap.free_func(jctx.heap.heap_udata, elems);
        }
        TVal r; r.set_undefined(); return r;
    }
    jctx.pos++; // skip ']'

    TVal len_val;
    len_val.set_fastint((long)idx);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC, jctx.heap);

    TVal result;
    result.set_object(arr);

    if (out_rec != null && jctx.record) {
        JsonParseRecord* rec = builtins::json_record_alloc(jctx.heap);
        if (rec != null) {
            rec.kind = 1;
            rec.span_start = span_start;
            rec.span_end = jctx.pos;
            rec.value = result;
            rec.elements = elems;
            rec.elem_count = idx;
            *out_rec = rec;
        } else if (elems != null) {
            for (uint i = 0; i < idx; i++) builtins::json_record_free(jctx.heap, elems[i]);
            jctx.heap.free_func(jctx.heap.heap_udata, elems);
        }
    } else if (elems != null) {
        for (uint i = 0; i < idx; i++) builtins::json_record_free(jctx.heap, elems[i]);
        jctx.heap.free_func(jctx.heap.heap_udata, elems);
    }

    return result;
}

// Parse a JSON object: {key: value, ...}
fn TVal json_parse_object(JsonParseCtx* jctx, JsonParseRecord** out_rec = null) {
    uint span_start = jctx.pos;
    jctx.pos++; // skip '{'
    json_skip_ws(jctx);

    HObject*? obj_raw = jctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    HObject* obj;
    if (try o = obj_raw) {
        obj = o;
        jctx.heap.set_prototype(obj, jctx.heap.object_proto);
    } else {
        TVal r; r.set_undefined(); return r;
    }

    bool recording = out_rec != null && jctx.record;
    JsonEntry* entries = null;
    uint entry_count = 0;
    uint entry_cap = 0;

    if (jctx.pos < jctx.len && jctx.src[jctx.pos] != '}') {
        while (true) {
            json_skip_ws(jctx);
            if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '\"') {
                jctx.error = true;
                builtins::json_entries_free(jctx.heap, entries, entry_count);
                TVal r; r.set_undefined(); return r;
            }
            HString*? key_str = json_parse_string(jctx);
            if (try k = key_str) {
                if (k == null) {
                    jctx.error = true;
                    builtins::json_entries_free(jctx.heap, entries, entry_count);
                    TVal r; r.set_undefined(); return r;
                }
                json_skip_ws(jctx);
                if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != ':') {
                    jctx.error = true;
                    builtins::json_entries_free(jctx.heap, entries, entry_count);
                    TVal r; r.set_undefined(); return r;
                }
                jctx.pos++; // skip ':'
                json_skip_ws(jctx);
                JsonParseRecord* child = null;
                TVal val = json_parse_value(jctx, recording ? &child : null);
                defer jctx.heap.decref_tval(&val);
                if (jctx.error || (val.is_undefined() && val.get_heapptr() == null && jctx.pos < jctx.len)) {
                    jctx.error = true;
                    builtins::json_entries_free(jctx.heap, entries, entry_count);
                    builtins::json_record_free(jctx.heap, child);
                    TVal r; r.set_undefined(); return r;
                }
                // A key over MAX_INTERN_BYTES comes back un-interned, but
                // put_prop stores keys canonically and the duplicate-key
                // recording below compares by pointer, so canonicalize once.
                k = jctx.heap.ensure_interned(k);
                obj.put_prop(k, val, hobject::PROP_FLAGS_WEC, jctx.heap);

                if (recording) {
                    // Duplicate keys: last value wins (matches put_prop), so
                    // replace any existing entry's record for this key.
                    bool replaced = false;
                    for (uint i = 0; i < entry_count; i++) {
                        if (entries[i].key.borrow() == k) {
                            builtins::json_record_free(jctx.heap, entries[i].record);
                            entries[i].record = child;
                            replaced = true;
                            break;
                        }
                    }
                    if (!replaced) {
                        if (entry_count >= entry_cap) {
                            uint new_cap = entry_cap == 0 ? 8 : entry_cap * 2;
                            JsonEntry* ne = (JsonEntry*)jctx.heap.realloc_func(
                                jctx.heap.heap_udata, entries, (usz)new_cap * JsonEntry::size);
                            if (ne != null) { entries = ne; entry_cap = new_cap; }
                            else { recording = false; }
                        }
                        if (recording) {
                            entries[entry_count].key = hstring::string_ref(k);
                            entries[entry_count].record = child;
                            entry_count++;
                        } else {
                            builtins::json_record_free(jctx.heap, child);
                        }
                    }
                }

                json_skip_ws(jctx);
                if (jctx.pos >= jctx.len) {
                    jctx.error = true;
                    builtins::json_entries_free(jctx.heap, entries, entry_count);
                    TVal r; r.set_undefined(); return r;
                }
                if (jctx.src[jctx.pos] == ',') {
                    jctx.pos++;
                } else {
                    break;
                }
            } else {
                jctx.error = true;
                builtins::json_entries_free(jctx.heap, entries, entry_count);
                TVal r; r.set_undefined(); return r;
            }
        }
    }

    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '}') {
        jctx.error = true;
        builtins::json_entries_free(jctx.heap, entries, entry_count);
        TVal r; r.set_undefined(); return r;
    }
    jctx.pos++; // skip '}'

    TVal result;
    result.set_object(obj);

    if (out_rec != null && jctx.record) {
        JsonParseRecord* rec = builtins::json_record_alloc(jctx.heap);
        if (rec != null) {
            rec.kind = 2;
            rec.span_start = span_start;
            rec.span_end = jctx.pos;
            rec.value = result;
            rec.entries = entries;
            rec.entry_count = entry_count;
            *out_rec = rec;
        } else {
            builtins::json_entries_free(jctx.heap, entries, entry_count);
        }
    } else {
        builtins::json_entries_free(jctx.heap, entries, entry_count);
    }

    return result;
}

// Parse a JSON value. Returns undefined on error; callers must also check
// jctx.error to distinguish "valid undefined" from parse failure.
// When out_rec is non-null and jctx.record is set, *out_rec receives a
// JsonParseRecord capturing this value's source span (json-parse-with-source).
fn TVal json_parse_value(JsonParseCtx* jctx, JsonParseRecord** out_rec = null) {
    json_skip_ws(jctx);
    if (jctx.pos >= jctx.len) {
        jctx.error = true;
        TVal r; r.set_undefined(); return r;
    }

    uint start = jctx.pos;
    uint c = (uint)jctx.src[jctx.pos];
    switch (c) {
        case '\"':
            // String
            {
                HString*? s = json_parse_string(jctx);
                if (try str = s) {
                    if (str != null) {
                        TVal r; r.set_string(str);
                        json_record_primitive(jctx, out_rec, r, start);
                        return r;
                    }
                }
                jctx.error = true;
                TVal r; r.set_undefined(); return r;
            }
        case '{':
            return json_parse_object(jctx, out_rec);
        case '[':
            return json_parse_array(jctx, out_rec);
        case 't':
            // true
            if (jctx.pos + 4 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'r' &&
                jctx.src[jctx.pos + 2] == 'u' &&
                jctx.src[jctx.pos + 3] == 'e') {
                jctx.pos += 4;
                TVal r; r.set_boolean(true);
                json_record_primitive(jctx, out_rec, r, start);
                return r;
            }
            { jctx.error = true; TVal r; r.set_undefined(); return r; }
        case 'f':
            // false
            if (jctx.pos + 5 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'a' &&
                jctx.src[jctx.pos + 2] == 'l' &&
                jctx.src[jctx.pos + 3] == 's' &&
                jctx.src[jctx.pos + 4] == 'e') {
                jctx.pos += 5;
                TVal r; r.set_boolean(false);
                json_record_primitive(jctx, out_rec, r, start);
                return r;
            }
            { jctx.error = true; TVal r; r.set_undefined(); return r; }
        case 'n':
            // null
            if (jctx.pos + 4 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'u' &&
                jctx.src[jctx.pos + 2] == 'l' &&
                jctx.src[jctx.pos + 3] == 'l') {
                jctx.pos += 4;
                TVal r; r.set_null();
                json_record_primitive(jctx, out_rec, r, start);
                return r;
            }
            { jctx.error = true; TVal r; r.set_undefined(); return r; }
        case '-':
        case '0'..'9':
            {
                TVal r = json_parse_number(jctx);
                if (!jctx.error) json_record_primitive(jctx, out_rec, r, start);
                return r;
            }
        default:
            { jctx.error = true; TVal r; r.set_undefined(); return r; }
    }
}

// Record a primitive value's source span [start, jctx.pos) into *out_rec.
fn void json_record_primitive(JsonParseCtx* jctx, JsonParseRecord** out_rec, TVal val, uint start) {
    if (out_rec == null || !jctx.record) return;
    JsonParseRecord* rec = builtins::json_record_alloc(jctx.heap);
    if (rec == null) return;
    rec.kind = 0;
    rec.span_start = start;
    rec.span_end = jctx.pos;
    jctx.heap.tval_copy_ref(&rec.value, &val);
    *out_rec = rec;
}


// Parse the whole of `src[0:len]` as one JSON text. On success `*result` holds the
// value, owning one reference, and `*root` its record when `record` is set. On
// failure `*result` is undefined and the caller still frees `*root`.
fn JsonParseStatus json_parse_document(Heap* heap, Unit* src, uint len, bool record,
                                       TVal* result, JsonParseRecord** root) {
    JsonParseCtx jctx = { .src = src, .pos = 0, .len = len, .heap = heap, .error = false, .record = record };
    *result = json_parse_value(&jctx, record ? root : null);
    if (jctx.error || (result.is_undefined() && result.get_heapptr() == null)) {
        heap.decref_tval(result);
        return JsonParseStatus.SYNTAX;
    }
    json_skip_ws(&jctx);
    if (jctx.pos != jctx.len) {
        heap.decref_tval(result);
        result.set_undefined();
        return JsonParseStatus.TRAILING;
    }
    return JsonParseStatus.OK;
}
