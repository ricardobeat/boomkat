// Minimal value rendering for console output, for builds that cannot afford
// the full formatter in inspect.c3.
//
// The full version is ~30 KB of __text, most of it layout: column grouping for
// long arrays, one-line/multi-line fitting against a width budget, indentation,
// quote-style selection, and a case for every value shape. This file keeps the
// part that makes console.log readable and drops the part that makes it pretty:
//
//   - one level of structure, then `[Object]` / `[Array]`
//   - always one line, no width budget, no column alignment
//   - no cycle tracking; the depth limit is what bounds recursion
//   - single-quoted strings, escaping only what would corrupt the line
//
// So `{ a: 1, b: 'x' }` and `[ 1, 2, 3 ]` still render, while
// `{ a: { b: { c: 1 } } }` renders `{ a: [Object] }` where the full formatter
// would expand two levels.
//
// Two rules are NOT relaxed, because breaking either changes program behaviour
// rather than output quality:
//
//   1. Rendering never invokes a getter. An accessor prints `[Getter]`.
//      Logging a value must not run user code.
//   2. Rendering never throws and never allocates an HString. Output is raw
//      CESU-8 appended to a StrBuf, as in the full version.
//
// Selected by the SLIM feature; inspect_entry.c3 owns that choice. This file
// carries no feature flags, and neither does inspect.c3.
module boomkat::builtins;
import boomkat::types;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::math;

// Structures nested deeper than this render as a placeholder. Matches the full
// formatter's INSPECT_MAX_DEPTH so the %s specifier, which starts two levels in
// and relies on one level of budget remaining, renders the same shape here.
const int TINY_MAX_DEPTH = 2;

// Ceiling on entries rendered per structure, so a large array cannot produce an
// unbounded line. The remainder collapses into `... N more items`.
const usz TINY_MAX_ENTRIES = 32;

// ============================================================================
// Entry points, mirroring inspect.c3's contract
// ============================================================================

// Render `val` as console.log renders a top-level argument: a string is bare,
// everything else takes its structured form.
fn bool tiny_root(Heap* heap, void* vm, TVal* val, StrBuf* out) {
    if (val.is_string()) {
        HString* s = (HString*)val.get_heapptr();
        if (s != null && !s.is_symbol()) return out.append_bytes(s.get_data());
    }
    return tiny_value(heap, val, 0, out);
}

// Render `val` as it appears nested, where a string is quoted.
fn bool tiny_nested(Heap* heap, void* vm, TVal* val, StrBuf* out) {
    return tiny_value(heap, val, 0, out);
}

// As tiny_nested, but starting at `start_depth`, shortening the depth budget.
fn bool tiny_at_depth(Heap* heap, void* vm, TVal* val, StrBuf* out, int start_depth) {
    return tiny_value(heap, val, start_depth, out);
}

// ============================================================================
// Value dispatch
// ============================================================================

fn bool tiny_value(Heap* heap, TVal* val, int depth, StrBuf* out) {
    switch (val.get_tag()) {
        case UNDEFINED: return out.append_bytes("undefined");
        case NULL_VAL:  return out.append_bytes("null");
        case BOOLEAN:   return out.append_bytes(val.get_boolean() ? "true" : "false");
        case FASTINT:   return tiny_int(out, val.get_fastint());
        case NUMBER:    return tiny_number(out, val.get_number());
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            if (s == null) return out.append_bytes("''");
            // A Symbol is tagged STRING but renders as Symbol(desc).
            if (s.is_symbol()) {
                if (!out.append_bytes("Symbol(")) return false;
                if (symbol_has_description(s) && !out.append_bytes(symbol_description(s))) {
                    return false;
                }
                return out.append_char(')');
            }
            return tiny_quoted(out, s.get_data());
        }
        default:
            break;
    }
    if (!val.is_object()) return out.append_bytes("[value]");
    HObject* obj = (HObject*)val.get_heapptr();
    if (obj == null) return out.append_bytes("null");
    return tiny_object(heap, obj, depth, out);
}

// ============================================================================
// Objects
// ============================================================================

fn bool tiny_object(Heap* heap, HObject* obj, int depth, StrBuf* out) {
    bool is_array = obj.flags.obj_class == hobject::ObjClass.ARRAY;

    if (obj.is_callable()) return tiny_function(heap, obj, out);

    // Past the budget, a structure collapses to its kind.
    if (depth > TINY_MAX_DEPTH) {
        return out.append_bytes(is_array ? "[Array]" : "[Object]");
    }

    // Anything that is neither a plain object nor an array renders as its class
    // tag. The full formatter gives Map/Set/Date/RegExp/Error each a real form;
    // that breadth is most of what this file trades away.
    if (!is_array && obj.flags.obj_class != hobject::ObjClass.OBJECT
                  && obj.flags.obj_class != hobject::ObjClass.ARGUMENTS) {
        return tiny_class_tag(heap, obj, out);
    }

    return is_array ? tiny_array(heap, obj, depth, out)
                    : tiny_plain(heap, obj, depth, out);
}

fn bool tiny_array(Heap* heap, HObject* obj, int depth, StrBuf* out) {
    uint len = *obj.array_len_ptr();
    if (len == 0) return out.append_bytes("[]");
    if (!out.append_bytes("[ ")) return false;

    usz shown = 0;
    for (uint i = 0; i < len; i++) {
        if (shown == TINY_MAX_ENTRIES) {
            if (!out.append_bytes(", ... ")) return false;
            if (!tiny_int(out, (long)(len - i))) return false;
            if (!out.append_bytes(" more items")) return false;
            break;
        }
        if (shown != 0 && !out.append_bytes(", ")) return false;
        TVal elem;
        if (!tiny_array_element(heap, obj, i, &elem)) {
            if (!out.append_bytes("<empty>")) return false;
        } else if (!tiny_value(heap, &elem, depth + 1, out)) {
            return false;
        }
        shown++;
    }
    return out.append_bytes(" ]");
}

// A dense-part read that never invokes an accessor: an accessor slot yields
// undefined rather than being called.
fn bool tiny_array_element(Heap* heap, HObject* obj, uint i, TVal* out) {
    TVal* arr = obj.array_part();
    if (arr != null && i < obj.array_size) {
        if (arr[i].is_undefined()) return false;
        *out = arr[i];
        return true;
    }
    HString* key = heap.int_to_hstring((long)i);
    if (key == null) return false;
    int idx = obj.find_prop_idx(key, heap);
    if (idx < 0) return false;
    if (obj.get_prop_flags((uint)idx, heap).is_accessor) { out.set_undefined(); return true; }
    *out = obj.prop_values()[idx];
    return true;
}

fn bool tiny_plain(Heap* heap, HObject* obj, int depth, StrBuf* out) {
    usz shown = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        hobject::PropFlags flags = obj.get_prop_flags(i, heap);
        if (!flags.enumerable) continue;
        HString* key = (HString*)obj.prop_key_at(i, heap);
        if (key == null || key.is_hidden()) continue;

        if (shown == TINY_MAX_ENTRIES) {
            if (!out.append_bytes(", ... more")) return false;
            shown++;
            break;
        }
        if (!out.append_bytes(shown == 0 ? "{ " : ", ")) return false;
        if (!tiny_key(out, key)) return false;
        if (!out.append_bytes(": ")) return false;

        // An accessor is reported, never called.
        if (flags.is_accessor) {
            if (!out.append_bytes("[Getter]")) return false;
        } else {
            TVal slot = obj.prop_values()[i];
            if (!tiny_value(heap, &slot, depth + 1, out)) return false;
        }
        shown++;
    }
    if (shown == 0) return out.append_bytes("{}");
    return out.append_bytes(" }");
}

// `[Function: name]`, or `[Function (anonymous)]`.
fn bool tiny_function(Heap* heap, HObject* obj, StrBuf* out) {
    HString* key = heap.str(heap::BuiltinStr.NAME);
    if (key != null) {
        int idx = obj.find_prop_idx(key, heap);
        if (idx >= 0 && !obj.get_prop_flags((uint)idx, heap).is_accessor) {
            TVal nv = obj.prop_values()[idx];
            if (nv.is_string()) {
                HString* n = (HString*)nv.get_heapptr();
                if (n != null && !n.is_symbol() && n.get_data().len > 0) {
                    if (!out.append_bytes("[Function: ")) return false;
                    if (!out.append_bytes(n.get_data())) return false;
                    return out.append_char(']');
                }
            }
        }
    }
    return out.append_bytes("[Function (anonymous)]");
}

// The constructor name in brackets, e.g. `[Map]`, so a value at least reports
// what it is. Falls back to `[Object]` when the class has no name.
fn bool tiny_class_tag(Heap* heap, HObject* obj, StrBuf* out) {
    if (!out.append_char('[')) return false;
    char[] name = tiny_class_name(obj.flags.obj_class);
    if (!out.append_bytes(name)) return false;
    return out.append_char(']');
}

fn char[] tiny_class_name(hobject::ObjClass c) {
    switch (c) {
        case MAP:         return "Map";
        case SET:         return "Set";
        case WEAKMAP:     return "WeakMap";
        case WEAKSET:     return "WeakSet";
        case DATE:        return "Date";
        case REGEXP:      return "RegExp";
        case ERROR:       return "Error";
        case PROXY:       return "Proxy";
        case ARRAYBUFFER: return "ArrayBuffer";
        case DATAVIEW:    return "DataView";
        case SYMBOL:      return "Symbol";
        case STRING:      return "String";
        case NUMBER:      return "Number";
        case BOOLEAN:     return "Boolean";
        default:          return "Object";
    }
}

// ============================================================================
// Scalars
// ============================================================================

fn bool tiny_int(StrBuf* out, long v) {
    char[24] buf;
    int len = hstring::int_to_buf(v, &buf, 24);
    if (len <= 0) return false;
    return out.append_bytes(buf[:(usz)len]);
}

// ToString(Number), except that -0 keeps its sign, which is the only way to
// tell it from 0 in output.
fn bool tiny_number(StrBuf* out, double d) {
    if (d == 0.0 && math::signbit(d)) return out.append_bytes("-0");
    char[64] buf;
    usz len = json_number_to_string(d, &buf, 64);
    return out.append_bytes(buf[:len]);
}

// A key prints bare when it is a plain identifier, quoted otherwise, so
// `{ a: 1 }` does not become `{ 'a': 1 }`.
fn bool tiny_key(StrBuf* out, HString* key) {
    if (key.is_symbol()) {
        if (!out.append_bytes("[Symbol(")) return false;
        if (symbol_has_description(key) && !out.append_bytes(symbol_description(key))) return false;
        return out.append_bytes(")]");
    }
    char[] d = key.get_data();
    bool bare = d.len > 0;
    for (usz i = 0; i < d.len; i++) {
        char c = d[i];
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '$'
               || (i > 0 && c >= '0' && c <= '9');
        if (!ok) { bare = false; break; }
    }
    if (bare) return out.append_bytes(d);
    return tiny_quoted(out, d);
}

// Single quotes always. Only the quote, the backslash, and the control
// characters that would break the line are escaped; everything else passes
// through, since output is raw CESU-8.
fn bool tiny_quoted(StrBuf* out, char[] data) {
    if (!out.append_char('\'')) return false;
    for (usz i = 0; i < data.len; i++) {
        char c = data[i];
        switch (c) {
            case '\'':
            case '\\':
                if (!out.append_char('\\')) return false;
                if (!out.append_char(c)) return false;
            case '\n':
                if (!out.append_bytes("\\n")) return false;
            case '\r':
                if (!out.append_bytes("\\r")) return false;
            case '\t':
                if (!out.append_bytes("\\t")) return false;
            default:
                if (!out.append_char(c)) return false;
        }
    }
    return out.append_char('\'');
}

// True when `obj` reaches a toString of its own before any builtin prototype.
// %s renders such an object by its toString rather than inspecting it, since
// that is what the author wrote it for. Duplicated from the full formatter
// rather than shared, because inspect.c3 is not compiled into this build.
fn bool tiny_has_custom_tostring(Heap* heap, HObject* obj) {
    HString* key = heap.str(heap::BuiltinStr.TO_STRING);
    if (key == null) return false;
    HObject* cur = obj;
    while (cur != null) {
        if (cur == heap.object_proto) return false;
        if (cur == heap.array_proto || cur == heap.map_proto || cur == heap.set_proto
         || cur == heap.date_proto || cur == heap.regexp_proto) return false;
        if (cur.find_prop_idx(key, heap) >= 0) return true;
        cur = cur.prototype;
    }
    return false;
}
