// Structured value rendering for console output: the form that prints
// `{ a: 1 }` and `[ 1, 2, 3 ]` where plain ToString would give
// `[object Object]` and `1,2,3`.
//
// console.log, console.dir and the %o/%O specifiers all route here; the
// surrounding format-specifier machinery in global.c3 owns everything else.
// The exact output form is the de-facto one shared across JS runtimes, and
// test/console_format/ pins every rule below to captured reference output.
//
// Two rules that are easy to get backwards:
//
//   1. A TOP-LEVEL string renders bare (`console.log("x")` prints `x`), but a
//      string nested inside a structure is QUOTED (`{ a: 'x' }`). Only the
//      root call is unquoted, so `inspect_root` and the recursive
//      `inspect_value` differ precisely there.
//   2. Rendering must never invoke a getter. A getter shows as `[Getter]`,
//      because logging a value is not supposed to run user code with side
//      effects.
//
// Output is assembled into a StrBuf as raw CESU-8 and written straight to the
// sink. No HString is allocated along the way, so this file cannot leak an
// un-interned string into the engine (string equality is pointer identity
// engine-wide, so an escaping un-interned HString would silently break
// indexOf/SEQ/keys).
module boomkat::builtins;
import boomkat::types;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import boomkat::hbigint;
import std::math;

// The default depth limit. A structure nested deeper renders as the
// placeholder `[Object]` / `[Array]` rather than being expanded.
const int INSPECT_MAX_DEPTH = 2;

// The line-width budget. Entries are joined on one line only while they fit
// inside it; see inspect_fits_one_line for the exact arithmetic.
const usz INSPECT_BREAK_LENGTH = 80;

// Column grouping kicks in for an array with MORE than this many entries.
// Shorter arrays are laid out by the plain one-line/one-per-line rule.
const usz INSPECT_GROUP_MIN_ENTRIES = 6;

// Ceiling on the circular-reference stack. A structure nested deeper than this
// renders the placeholder instead of recursing, so a pathological input cannot
// run the C stack out.
const usz INSPECT_MAX_STACK = 256;

// Traversal state for one top-level inspect call.
struct InspectCtx {
    Heap*  heap;
    void*  vm;
    // Objects on the path from the root to the value being rendered, used both
    // for cycle detection and to assign the `<ref *1>` marker.
    HObject*[INSPECT_MAX_STACK] stack;
    usz    stack_count;
    // Set when a cycle was actually hit, which is what makes the root print
    // its `<ref *1>` prefix. The marker appears only when a back-reference
    // exists, so `{ a: 1 }` must not gain one.
    bool   saw_circular;
    // Current indentation in spaces.
    usz    indent;
}

// ============================================================================
// Entry points
// ============================================================================

// Render `val` the way console.log renders a top-level argument, appending to
// `out`. A top-level string is emitted bare; everything else takes its
// structured form.
fn bool inspect_root(Heap* heap, void* vm, TVal* val, StrBuf* out) @feat(!SLIM) {
    if (val.is_string()) {
        HString* s = (HString*)val.get_heapptr();
        // A Symbol is tagged STRING but is not a string: it renders as
        // Symbol(desc) at the root just as it does when nested.
        if (s != null && !s.is_symbol()) {
            return out.append_bytes(s.get_data());
        }
    }
    return inspect_nested(heap, vm, val, out);
}

// Render `val` as it appears in a NON-root position, where a string is quoted.
// This is what %o, %O and console.dir want, since none of them is the
// bare-string case.
fn bool inspect_nested(Heap* heap, void* vm, TVal* val, StrBuf* out) @feat(!SLIM) {
    return inspect_at_depth(heap, vm, val, out, 0);
}

// As inspect_nested, but starting at `start_depth`, which shortens the
// effective depth budget by that many levels. %s passes 2, leaving one level,
// since %s renders one level shallower than a plain argument
// and so prints `{ a: [Object] }` where a plain argument expands the `b`.
fn bool inspect_at_depth(Heap* heap, void* vm, TVal* val, StrBuf* out, int start_depth) @feat(!SLIM) {
    InspectCtx ctx;
    ctx.heap = heap;
    ctx.vm = vm;
    ctx.stack_count = 0;
    ctx.saw_circular = false;
    ctx.indent = 0;

    // The `<ref *1>` prefix depends on whether a cycle was found, which is only
    // known after the walk. Render into a scratch buffer first, then prefix.
    StrBuf body;
    body.init(heap);
    defer body.free();
    if (!inspect_value(&ctx, val, start_depth, &body)) return false;
    if (ctx.saw_circular && !out.append_bytes("<ref *1> ")) return false;
    return out.append_bytes(body.data[:body.len]);
}

// ============================================================================
// Value dispatch
// ============================================================================

// Render one value at `depth`, as it appears NESTED inside a structure: a
// string here is quoted. The root's bare-string case is handled by
// inspect_root before this is ever reached.
fn bool inspect_value(InspectCtx* ctx, TVal* val, int depth, StrBuf* out) {
    switch (val.get_tag()) {
        case UNDEFINED:
            return out.append_bytes("undefined");
        case NULL_VAL:
            return out.append_bytes("null");
        case BOOLEAN:
            return out.append_bytes(val.get_boolean() ? "true" : "false");
        case FASTINT:
            return inspect_append_int(out, val.get_fastint());
        case NUMBER:
            return inspect_append_number(out, val.get_number());
        case BIGINT: {
            char[48] buf;
            char* heap_buf;
            char[] bs = hbigint::hbigint_to_decimal(ctx.heap, val.get_bigint(), buf[..], &heap_buf);
            defer if (heap_buf != null) ctx.heap.free((void*)heap_buf);
            if (!out.append_bytes(bs)) return false;
            return out.append_char('n');
        }
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            if (s == null) return out.append_bytes("''");
            if (s.is_symbol()) return inspect_append_symbol(out, s);
            return inspect_append_quoted(out, s.get_data());
        }
        case LIGHTFUNC:
            return out.append_bytes("[Function (anonymous)]");
        case OBJECT: {
            if (val.get_heapptr() == null) return out.append_bytes("null");
            return inspect_object(ctx, (HObject*)val.get_heapptr(), depth, out);
        }
        default:
            return out.append_bytes("undefined");
    }
}

// ============================================================================
// Primitive rendering
// ============================================================================

fn bool inspect_append_int(StrBuf* out, long v) {
    char[24] buf;
    int len = hstring::int_to_buf(v, &buf, 24);
    if (len <= 0) return false;
    return out.append_bytes(buf[:(usz)len]);
}

// ToString(Number), except that negative zero prints as "-0" where
// ToString collapses it to "0". The sign bit is the only way to tell the two
// apart, since -0.0 == 0.0.
fn bool inspect_append_number(StrBuf* out, double d) {
    if (d == 0.0 && math::signbit(d)) return out.append_bytes("-0");
    char[64] buf;
    usz len = json_number_to_string(d, &buf, 64);
    return out.append_bytes(buf[:len]);
}

// "Symbol(desc)". The raw HString bytes carry the 0xFF prefix and description
// marker, so they cannot be emitted directly.
fn bool inspect_append_symbol(StrBuf* out, HString* sym) {
    if (!out.append_bytes("Symbol(")) return false;
    if (symbol_has_description(sym) && !out.append_bytes(symbol_description(sym))) return false;
    return out.append_char(')');
}

// Quote a string: single quotes normally, double quotes when
// the content contains a single quote, backticks when it contains both. The
// chosen quote is then the only one that needs escaping.
fn bool inspect_append_quoted(StrBuf* out, char[] data) {
    bool has_single = false;
    bool has_double = false;
    for (usz i = 0; i < data.len; i++) {
        if (data[i] == '\'') has_single = true;
        if (data[i] == '"') has_double = true;
    }
    char quote = '\'';
    if (has_single) quote = has_double ? '`' : '"';

    if (!out.append_char(quote)) return false;
    for (usz i = 0; i < data.len; i++) {
        char c = data[i];
        if (c == quote || c == '\\') {
            if (!out.append_char('\\')) return false;
            if (!out.append_char(c)) return false;
            continue;
        }
        if (!inspect_append_escaped_char(out, c)) return false;
    }
    return out.append_char(quote);
}

// Control characters inside a quoted string take their JS escape form, so a
// logged newline stays on one line as "\n" rather than breaking the output.
fn bool inspect_append_escaped_char(StrBuf* out, char c) {
    switch (c) {
        case '\n': return out.append_bytes("\\n");
        case '\t': return out.append_bytes("\\t");
        case '\r': return out.append_bytes("\\r");
        case '\b': return out.append_bytes("\\b");
        case '\f': return out.append_bytes("\\f");
        default:
            if (c < 0x20 || c == 0x7F) {
                if (!out.append_bytes("\\x")) return false;
                if (!out.append_char(inspect_hex_digit((char)(c >> 4)))) return false;
                return out.append_char(inspect_hex_digit((char)(c & 0x0F)));
            }
            return out.append_char(c);
    }
}

fn char inspect_hex_digit(char nibble) @inline {
    return nibble < 10 ? (char)('0' + nibble) : (char)('a' + nibble - 10);
}

// ============================================================================
// Cycle detection
// ============================================================================

// Index of `obj` on the current path, or -1. A hit is a back-reference, which
// renders as [Circular *1].
fn int inspect_stack_find(InspectCtx* ctx, HObject* obj) {
    for (usz i = 0; i < ctx.stack_count; i++) {
        if (ctx.stack[i] == obj) return (int)i;
    }
    return -1;
}

// ============================================================================
// Object rendering
// ============================================================================

// Render an object: dispatches on the shapes that get their own syntax
// (function, error, regexp, date, boxed primitive, Map, Set, TypedArray,
// array) and otherwise falls through to the plain `{ ... }` form.
fn bool inspect_object(InspectCtx* ctx, HObject* obj, int depth, StrBuf* out) {
    // A back-reference terminates the walk; without this a cyclic structure
    // recurses until the C stack goes.
    if (inspect_stack_find(ctx, obj) >= 0) {
        ctx.saw_circular = true;
        return out.append_bytes("[Circular *1]");
    }

    // Shapes that render as a leaf, with no property walk and no depth limit.
    if (obj.is_callable()) return inspect_function(ctx, obj, depth, out);
    if (obj.flags.obj_class == hobject::ObjClass.ERROR) return inspect_error(ctx, obj, out);
    if (obj.flags.obj_class == hobject::ObjClass.REGEXP || obj.flags.obj_class == hobject::ObjClass.DATE
        || obj.flags.obj_class == hobject::ObjClass.SYMBOL) {
        return inspect_via_tostring(ctx, obj, out);
    }
    if (inspect_is_boxed_primitive(obj)) return inspect_boxed_primitive(ctx, obj, out);

    InspectShape shape = inspect_shape_of(ctx, obj);

    // Past the depth limit a structure collapses to a placeholder naming its
    // kind rather than being expanded.
    if (depth > INSPECT_MAX_DEPTH) {
        return out.append_bytes(shape.is_array_like() ? "[Array]" : "[Object]");
    }
    if (ctx.stack_count >= INSPECT_MAX_STACK) {
        return out.append_bytes(shape.is_array_like() ? "[Array]" : "[Object]");
    }

    ctx.stack[ctx.stack_count++] = obj;
    defer ctx.stack_count--;

    return inspect_entries(ctx, obj, shape, depth, out);
}

// What kind of backing store an entry walk should read.
enum InspectKind : char {
    // Named properties only: a plain object.
    PLAIN,
    // Dense/indexed elements, then any extra named properties.
    ARRAY,
    // Map's [k0, v0, k1, v1, ...] backing store, rendered as `k => v`.
    MAP,
    // Set's [v0, v1, ...] backing store.
    SET,
    // An integer-indexed exotic, read through its element accessor.
    TYPEDARRAY,
}

// How a structure presents: its brace pair, its `Map(1) `-style prefix, and
// which backing store holds its entries. The prefix is stored inline rather
// than as a slice, so it stays valid after this value is returned by copy.
struct InspectShape {
    char[40]    prefix_buf;
    usz         prefix_len;
    char        open;
    char        close;
    InspectKind kind;
}

fn char[] InspectShape.prefix(&self) @inline {
    return self.prefix_buf[:self.prefix_len];
}

// Whether the depth-limit placeholder should read [Array] rather than [Object].
fn bool InspectShape.is_array_like(&self) @inline {
    return self.kind == InspectKind.ARRAY || self.kind == InspectKind.TYPEDARRAY;
}

// Append to the shape's inline prefix, silently truncating rather than
// overflowing: the prefix is a display detail and a constructor name long
// enough to fill the buffer is already pathological.
fn void InspectShape.add_prefix(&self, char[] bytes) {
    for (usz i = 0; i < bytes.len && self.prefix_len < 40; i++) {
        self.prefix_buf[self.prefix_len++] = bytes[i];
    }
}

fn void InspectShape.add_prefix_count(&self, uint n) {
    char[24] buf;
    int len = hstring::int_to_buf((long)n, &buf, 24);
    if (len > 0) self.add_prefix(buf[:(usz)len]);
}

// Classify `obj`: its braces, its prefix, and where its entries live.
fn InspectShape inspect_shape_of(InspectCtx* ctx, HObject* obj) {
    InspectShape shape;
    shape.prefix_len = 0;
    shape.open = '{';
    shape.close = '}';
    shape.kind = InspectKind.PLAIN;

    if (obj.flags.exotic_array) {
        shape.open = '[';
        shape.close = ']';
        shape.kind = InspectKind.ARRAY;
        return shape;
    }
    if (obj.flags.obj_class == hobject::ObjClass.MAP || obj.flags.obj_class == hobject::ObjClass.SET) {
        bool is_map = obj.flags.obj_class == hobject::ObjClass.MAP;
        shape.kind = is_map ? InspectKind.MAP : InspectKind.SET;
        shape.add_prefix(is_map ? "Map(" : "Set(");
        shape.add_prefix_count(inspect_collection_size(obj, is_map ? 2 : 1));
        shape.add_prefix(") ");
        return shape;
    }
    char[] ta_name = inspect_typedarray_name(obj.flags.obj_class);
    if (ta_name.len > 0) {
        shape.open = '[';
        shape.close = ']';
        shape.kind = InspectKind.TYPEDARRAY;
        shape.add_prefix(ta_name);
        shape.add_prefix("(");
        shape.add_prefix_count(inspect_typedarray_length(ctx, obj));
        shape.add_prefix(") ");
        return shape;
    }
    // A null-prototype object is called out, because it behaves unlike an
    // ordinary object (no toString, no hasOwnProperty) and that is worth seeing
    // in a log.
    if (obj.prototype == null) {
        shape.add_prefix("[Object: null prototype] ");
    }
    return shape;
}

// Non-deleted entry count of a Map or Set. `stride` is 2 for a Map (whose
// backing store interleaves keys and values) and 1 for a Set.
fn uint inspect_collection_size(HObject* obj, uint stride) {
    uint count = 0;
    TVal* arr = obj.array_part();
    if (arr == null) return 0;
    for (uint i = 0; i + stride - 1 < obj.array_used; i += stride) {
        if (!arr[i].is_deleted()) count++;
    }
    return count;
}

// The constructor name a TypedArray class prints, or "" if not a TypedArray.
fn char[] inspect_typedarray_name(hobject::ObjClass cls) {
    switch (cls) {
        case hobject::ObjClass.INT8ARRAY:         return "Int8Array";
        case hobject::ObjClass.UINT8ARRAY:        return "Uint8Array";
        case hobject::ObjClass.UINT8CLAMPEDARRAY: return "Uint8ClampedArray";
        case hobject::ObjClass.INT16ARRAY:        return "Int16Array";
        case hobject::ObjClass.UINT16ARRAY:       return "Uint16Array";
        case hobject::ObjClass.INT32ARRAY:        return "Int32Array";
        case hobject::ObjClass.UINT32ARRAY:       return "Uint32Array";
        case hobject::ObjClass.FLOAT16ARRAY:      return "Float16Array";
        case hobject::ObjClass.FLOAT32ARRAY:      return "Float32Array";
        case hobject::ObjClass.FLOAT64ARRAY:      return "Float64Array";
        case hobject::ObjClass.BIGINT64ARRAY:     return "BigInt64Array";
        case hobject::ObjClass.BIGUINT64ARRAY:    return "BigUint64Array";
        default:                                  return "";
    }
}

// True for a boxed String/Number/Boolean, which renders as
// [String: 'x'] rather than expanding its properties.
fn bool inspect_is_boxed_primitive(HObject* obj) {
    return obj.flags.obj_class == hobject::ObjClass.STRING
        || obj.flags.obj_class == hobject::ObjClass.NUMBER
        || obj.flags.obj_class == hobject::ObjClass.BOOLEAN;
}

// ============================================================================
// Entry collection and layout
// ============================================================================

// One rendered entry ("a: 1", "1 => 2", "'x'"), held as an owned buffer so the
// layout pass can measure every entry before deciding one line or many.
struct InspectEntry {
    StrBuf buf;
}

// The accumulated entries of one structure. Fixed capacity: rendering stops
// at 100 entries and prints "... N more items", and that same cap keeps this
// walk from allocating without bound.
const usz INSPECT_MAX_ENTRIES = 100;

struct InspectEntries {
    InspectEntry[INSPECT_MAX_ENTRIES] items;
    usz count;
    // Entries the cap elided, reported as "... N more items".
    usz elided;
    // Cleared as soon as a non-numeric element is collected. Column grouping
    // right-aligns a purely numeric array and left-aligns everything else.
    bool all_numeric;
}

fn void InspectEntries.free(&self) {
    for (usz i = 0; i < self.count; i++) self.items[i].buf.free();
}

// Reserve the next entry buffer, or null when the cap is reached (in which
// case the elision counter advances instead).
fn StrBuf* InspectEntries.next(&self, Heap* heap) {
    if (self.count >= INSPECT_MAX_ENTRIES) { self.elided++; return null; }
    StrBuf* b = &self.items[self.count].buf;
    b.init(heap);
    self.count++;
    return b;
}

// Walk `obj`'s entries and lay them out between its braces.
fn bool inspect_entries(InspectCtx* ctx, HObject* obj, InspectShape shape, int depth, StrBuf* out) {
    InspectEntries entries;
    entries.count = 0;
    entries.elided = 0;
    entries.all_numeric = true;
    defer entries.free();

    // Entries are rendered one indent level deeper, matching the
    // ctx.indentationLvl bump around the recursive call.
    ctx.indent += 2;
    bool ok = inspect_collect(ctx, obj, shape, depth, &entries);
    ctx.indent -= 2;
    if (!ok) return false;

    return inspect_layout(ctx, shape, &entries, out);
}

// Fill `entries` from whichever backing store this shape names.
fn bool inspect_collect(InspectCtx* ctx, HObject* obj, InspectShape shape, int depth,
                        InspectEntries* entries) {
    switch (shape.kind) {
        case InspectKind.MAP:
            return inspect_collect_map(ctx, obj, depth, entries);
        case InspectKind.SET:
            return inspect_collect_set(ctx, obj, depth, entries);
        case InspectKind.TYPEDARRAY:
            return inspect_collect_typedarray(ctx, obj, depth, entries);
        case InspectKind.ARRAY:
            if (!inspect_collect_indexed(ctx, obj, depth, entries)) return false;
            // An array's non-index properties print after its elements, as
            // `extra: 'p'`, so `[1, 2, 3, extra: 'p']` keeps both visible.
            return inspect_collect_named(ctx, obj, depth, entries, true);
        default:
            return inspect_collect_named(ctx, obj, depth, entries, false);
    }
}

// Map: `key => value` per non-deleted entry of the [k0, v0, k1, v1, ...] store.
fn bool inspect_collect_map(InspectCtx* ctx, HObject* obj, int depth, InspectEntries* entries) {
    TVal* arr = obj.array_part();
    if (arr == null) return true;
    for (uint i = 0; i + 1 < obj.array_used; i += 2) {
        if (arr[i].is_deleted()) continue;
        StrBuf* b = entries.next(ctx.heap);
        if (b == null) return true;
        TVal k = arr[i];
        TVal v = arr[i + 1];
        if (!inspect_value(ctx, &k, depth + 1, b)) return false;
        if (!b.append_bytes(" => ")) return false;
        if (!inspect_value(ctx, &v, depth + 1, b)) return false;
    }
    return true;
}

// Set: one entry per non-deleted slot of the [v0, v1, ...] store.
fn bool inspect_collect_set(InspectCtx* ctx, HObject* obj, int depth, InspectEntries* entries) {
    TVal* arr = obj.array_part();
    if (arr == null) return true;
    for (uint i = 0; i < obj.array_used; i++) {
        if (arr[i].is_deleted()) continue;
        StrBuf* b = entries.next(ctx.heap);
        if (b == null) return true;
        TVal v = arr[i];
        if (!inspect_value(ctx, &v, depth + 1, b)) return false;
    }
    return true;
}

fn bool inspect_collect_typedarray(InspectCtx* ctx, HObject* obj, int depth, InspectEntries* entries) {
    uint n = inspect_typedarray_length(ctx, obj);
    for (uint i = 0; i < n; i++) {
        StrBuf* b = entries.next(ctx.heap);
        if (b == null) return true;
        TVal v = ta_read_element_checked(ctx.heap, obj, i);
        if (!inspect_value(ctx, &v, depth + 1, b)) return false;
    }
    return true;
}

fn uint inspect_typedarray_length(InspectCtx* ctx, HObject* obj) {
    if (ta_is_detached(obj)) return 0;
    return ta_element_count(obj);
}

// Array elements, with runs of holes collapsed into the
// `<N empty items>` marker rather than printed as undefined.
fn bool inspect_collect_indexed(InspectCtx* ctx, HObject* obj, int depth, InspectEntries* entries) {
    uint len = *obj.array_len_ptr();
    uint i = 0;
    while (i < len) {
        TVal elem;
        bool present = inspect_array_element(ctx, obj, i, &elem);
        if (!present) {
            uint run_start = i;
            while (i < len && !inspect_array_element(ctx, obj, i, &elem)) i++;
            StrBuf* b = entries.next(ctx.heap);
            if (b == null) return true;
            // A hole reads as undefined, so it is not a numeric element and
            // switches column alignment to left-aligned.
            entries.all_numeric = false;
            if (!b.append_char('<')) return false;
            if (!inspect_append_int(b, (long)(i - run_start))) return false;
            if (!b.append_bytes(i - run_start == 1 ? " empty item>" : " empty items>")) return false;
            continue;
        }
        StrBuf* b = entries.next(ctx.heap);
        if (b == null) return true;
        if (!elem.is_fastint() && !elem.is_number() && !elem.is_bigint()) {
            entries.all_numeric = false;
        }
        if (!inspect_value(ctx, &elem, depth + 1, b)) return false;
        i++;
    }
    return true;
}

// Read array index `i` as an OWN property, without consulting the prototype
// chain: a hole must stay a hole even when Array.prototype has that index.
fn bool inspect_array_element(InspectCtx* ctx, HObject* obj, uint i, TVal* out) {
    // array_used counts non-hole elements; array_size is the addressable bound.
    TVal* arr = obj.array_part();
    if (arr != null && i < obj.array_size) {
        // An undefined slot in the dense part IS the hole representation.
        if (arr[i].is_undefined()) return false;
        *out = arr[i];
        return true;
    }
    HString* key = ctx.heap.int_to_hstring((long)i);
    if (key == null) return false;
    int idx = obj.find_prop_idx(key, ctx.heap);
    if (idx < 0) return false;
    if (obj.get_prop_flags((uint)idx, ctx.heap).is_accessor) { out.set_undefined(); return true; }
    *out = obj.prop_values()[idx];
    return true;
}

// Named own properties, skipping non-enumerables the way the default
// (showHidden: false) does. `skip_indices` is set for arrays, whose index
// properties were already emitted by the element walk.
//
// Keys come out in [[OwnPropertyKeys]] order — integer indices ascending, then
// strings in insertion order, then symbols — which is why `{ 'a-b': 1, 2: 3 }`
// prints its "2" first. The property table is in insertion order, so the
// integer keys need their own ascending pass over it.
fn bool inspect_collect_named(InspectCtx* ctx, HObject* obj, int depth,
                              InspectEntries* entries, bool skip_indices) {
    if (!skip_indices) {
        // Integer-index keys, ascending. Selection over the table rather than a
        // sort, since an object with many index keys keeps them in the dense
        // array part and never reaches this path.
        bool more = true;
        bool have_prev = false;
        uint prev = 0;
        while (more) {
            more = false;
            uint best = 0;
            uint best_idx = 0;
            for (uint i = 0; i < obj.prop_count; i++) {
                HString* key = (HString*)obj.prop_key_at(i, ctx.heap);
                if (key == null || key.is_symbol() || !key.is_arridx() || key.is_hidden()) continue;
                uint n = key.array_index();
                if (have_prev && n <= prev) continue;
                if (!more || n < best) { more = true; best = n; best_idx = i; }
            }
            if (!more) break;
            have_prev = true;
            prev = best;
            if (!inspect_emit_named(ctx, obj, best_idx, depth, entries)) return false;
        }
    }
    // Non-index string keys, then symbol keys, both in insertion order.
    for (uint pass = 0; pass < 2; pass++) {
        for (uint i = 0; i < obj.prop_count; i++) {
            HString* key = (HString*)obj.prop_key_at(i, ctx.heap);
            if (key == null || key.is_hidden()) continue;
            bool is_sym = key.is_symbol();
            if ((pass == 0) == is_sym) continue;
            if (!is_sym && key.is_arridx()) continue;
            if (!inspect_emit_named(ctx, obj, i, depth, entries)) return false;
        }
    }
    return true;
}

// Emit property slot `i` as a `key: value` entry, if it is enumerable.
fn bool inspect_emit_named(InspectCtx* ctx, HObject* obj, uint i, int depth,
                           InspectEntries* entries) {
    hobject::PropFlags flags = obj.get_prop_flags(i, ctx.heap);
    if (!flags.enumerable) return true;
    HString* key = (HString*)obj.prop_key_at(i, ctx.heap);
    if (key == null) return true;

    StrBuf* b = entries.next(ctx.heap);
    if (b == null) return true;
    // A `key: value` entry is never a bare number, so an array carrying extra
    // named properties left-aligns its columns.
    entries.all_numeric = false;
    if (!inspect_append_key(b, key)) return false;
    if (!b.append_bytes(": ")) return false;
    TVal slot = obj.prop_values()[i];
    return inspect_append_prop_value(ctx, flags, &slot, depth, b);
}

// Render a property's value. An accessor renders as [Getter] / [Setter] /
// [Getter/Setter] and is NEVER invoked: logging a value must not run user code
// with side effects.
fn bool inspect_append_prop_value(InspectCtx* ctx, hobject::PropFlags flags, TVal* slot,
                                  int depth, StrBuf* b) {
    if (flags.is_accessor) {
        HObject* gs = (HObject*)slot.get_heapptr();
        if (gs == null) return b.append_bytes("[Getter/Setter]");
        HObjectGetterSetter* pair = (HObjectGetterSetter*)gs.extra_ptr();
        bool has_get = !pair.getter.is_undefined();
        bool has_set = !pair.setter.is_undefined();
        if (has_get && has_set) return b.append_bytes("[Getter/Setter]");
        if (has_set) return b.append_bytes("[Setter]");
        return b.append_bytes("[Getter]");
    }
    return inspect_value(ctx, slot, depth + 1, b);
}

// A key prints bare when it is a valid identifier, and quoted otherwise, so
// `{ 'a-b': 1 }` stays unambiguous. The test is /^[a-zA-Z_][a-zA-Z_0-9]*$/,
// which notably rejects `$` and so quotes `valid_$`.
fn bool inspect_append_key(StrBuf* b, HString* key) {
    if (key.is_symbol()) {
        // A symbol key prints as its bare Symbol(desc) form, unquoted.
        return inspect_append_symbol(b, key);
    }
    char[] data = key.get_data();
    if (inspect_is_identifier(data)) return b.append_bytes(data);
    return inspect_append_quoted(b, data);
}

fn bool inspect_is_identifier(char[] data) {
    if (data.len == 0) return false;
    char c0 = data[0];
    bool head = (c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z') || c0 == '_';
    if (!head) return false;
    for (usz i = 1; i < data.len; i++) {
        char c = data[i];
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
               || (c >= '0' && c <= '9') || c == '_';
        if (!ok) return false;
    }
    return true;
}

// ============================================================================
// Layout
// ============================================================================

// Join the collected entries between the shape's braces, on one line when they
// fit and one-per-line otherwise.
fn bool inspect_layout(InspectCtx* ctx, InspectShape shape, InspectEntries* entries, StrBuf* out) {
    if (!out.append_bytes(shape.prefix())) return false;

    // An empty structure has no inner padding: "{}" and "[]", not
    // "{ }". Its prefix still shows, as in "Map(0) {}".
    if (entries.count == 0 && entries.elided == 0) {
        if (!out.append_char(shape.open)) return false;
        return out.append_char(shape.close);
    }

    // An array of more than six short entries is packed into aligned columns
    // BEFORE the fits-on-one-line test, since grouping is what decides how many
    // lines there are. Grouping may also collapse the whole thing back to one
    // line, which the test below then picks up.
    bool grouped = false;
    if (shape.is_array_like() && entries.count > INSPECT_GROUP_MIN_ENTRIES) {
        usz before = entries.count;
        if (!inspect_group_array(ctx, entries)) return false;
        grouped = entries.count != before;
    }
    // Grouped rows already carry their own ", " separators, so rejoining them
    // on one line would double them up. The join is likewise only reached in
    // single-line join when grouping left the entry list alone.
    if (grouped) return inspect_layout_multiline(ctx, shape, entries, out);

    if (inspect_fits_one_line(ctx, shape, entries)) {
        if (!out.append_char(shape.open)) return false;
        if (!out.append_char(' ')) return false;
        for (usz i = 0; i < entries.count; i++) {
            if (i > 0 && !out.append_bytes(", ")) return false;
            if (!out.append_bytes(entries.items[i].buf.data[:entries.items[i].buf.len])) return false;
        }
        if (!inspect_append_elision(entries, out, entries.count > 0)) return false;
        if (!out.append_char(' ')) return false;
        return out.append_char(shape.close);
    }

    return inspect_layout_multiline(ctx, shape, entries, out);
}

// One entry per line, indented one level past the braces, with the closing
// brace back at the opening brace's indent. Grouped rows arrive here already
// carrying their own internal separators, so they take no trailing comma.
fn bool inspect_layout_multiline(InspectCtx* ctx, InspectShape shape,
                                 InspectEntries* entries, StrBuf* out) {
    if (!out.append_char(shape.open)) return false;
    for (usz i = 0; i < entries.count; i++) {
        if (i > 0 && !out.append_char(',')) return false;
        if (!out.append_char('\n')) return false;
        if (!inspect_append_indent(out, ctx.indent + 2)) return false;
        if (!out.append_bytes(entries.items[i].buf.data[:entries.items[i].buf.len])) return false;
    }
    if (entries.elided > 0) {
        if (entries.count > 0 && !out.append_char(',')) return false;
        if (!out.append_char('\n')) return false;
        if (!inspect_append_indent(out, ctx.indent + 2)) return false;
        if (!inspect_append_elision(entries, out, false)) return false;
    }
    if (!out.append_char('\n')) return false;
    if (!inspect_append_indent(out, ctx.indent)) return false;
    return out.append_char(shape.close);
}

// Pack a long array of short entries into aligned
// columns, so `[1..10]` prints as two rows of five rather than ten lines.
// Rewrites `entries` in place, each remaining entry being one composed row.
//
// The arithmetic includes the "expect a character to be about
// 2.5 times as high as wide" square-area heuristic that picks the column count.
// Numeric arrays right-align their columns; anything else left-aligns.
fn bool inspect_group_array(InspectCtx* ctx, InspectEntries* entries) {
    const usz SEPARATOR_SPACE = 2;   // ", " between two entries
    usz n = entries.count;

    usz total_length = 0;
    usz max_length = 0;
    for (usz i = 0; i < n; i++) {
        usz len = inspect_display_width(&entries.items[i].buf);
        total_length += len + SEPARATOR_SPACE;
        if (len > max_length) max_length = len;
    }
    usz actual_max = max_length + SEPARATOR_SPACE;

    // Group only when at least three entries fit side by side, and skip arrays
    // whose entries differ wildly in length (one long entry would otherwise
    // stretch every column).
    if (actual_max * 3 + ctx.indent >= INSPECT_BREAK_LENGTH) return true;
    if (!((double)total_length / (double)actual_max > 5.0 || max_length <= 6)) return true;

    double approx_char_heights = 2.5;
    double average_bias = math::sqrt((double)actual_max - (double)total_length / (double)n);
    double biased_max = (double)actual_max - 3.0 - average_bias;
    if (biased_max < 1.0) biased_max = 1.0;

    long columns = (long)math::round(math::sqrt(approx_char_heights * biased_max * (double)n) / biased_max);
    long fit_limit = (long)((INSPECT_BREAK_LENGTH - ctx.indent) / actual_max);
    if (fit_limit < columns) columns = fit_limit;
    // The compact setting defaults to 3, so the `compact * 4` cap is 12.
    if (columns > 12) columns = 12;
    if (columns > 15) columns = 15;
    if (columns <= 1) return true;

    // Per-column width: the widest entry in that column, plus the separator.
    usz[16] col_width;
    for (long c = 0; c < columns; c++) {
        usz w = 0;
        for (usz j = (usz)c; j < n; j += (usz)columns) {
            usz len = inspect_display_width(&entries.items[j].buf);
            if (len > w) w = len;
        }
        col_width[c] = w + SEPARATOR_SPACE;
    }

    InspectEntries rows;
    rows.count = 0;
    rows.elided = entries.elided;
    rows.all_numeric = entries.all_numeric;
    bool ok = true;

    for (usz i = 0; i < n && ok; i += (usz)columns) {
        usz max = i + (usz)columns;
        if (max > n) max = n;
        StrBuf* row = rows.next(ctx.heap);
        if (row == null) break;
        for (usz j = i; j < max && ok; j++) {
            StrBuf* cell = &entries.items[j].buf;
            usz width = inspect_display_width(cell);
            bool last_in_row = j == max - 1;
            // The final cell of a row carries no ", ", and only right-aligned
            // (numeric) output pads it at all.
            usz field = col_width[j - i];
            if (last_in_row && entries.all_numeric) field -= SEPARATOR_SPACE;

            usz pad = field > width + (last_in_row ? 0 : SEPARATOR_SPACE)
                    ? field - width - (last_in_row ? 0 : SEPARATOR_SPACE) : 0;
            if (entries.all_numeric && !inspect_append_indent(row, pad)) { ok = false; break; }
            if (!row.append_bytes(cell.data[:cell.len])) { ok = false; break; }
            if (!last_in_row && !row.append_bytes(", ")) { ok = false; break; }
            if (!entries.all_numeric && !last_in_row && !inspect_append_indent(row, pad)) { ok = false; break; }
        }
    }

    if (!ok) { rows.free(); return false; }
    // Hand the composed rows back to the caller, releasing the per-entry buffers.
    entries.free();
    *entries = rows;
    // A StrBuf that never outgrew its inline storage points `data` at its own
    // inline_buf, so the struct copy above left every such pointer aimed at the
    // OLD stack address. Rebind them to the copies that now own the bytes.
    for (usz i = 0; i < entries.count; i++) {
        if (rows.items[i].buf.data == &rows.items[i].buf.inline_buf[0]) {
            entries.items[i].buf.data = &entries.items[i].buf.inline_buf[0];
        }
    }
    return true;
}

// Display width of a rendered entry in characters. The buffer holds CESU-8, so
// continuation bytes must not each count as a column.
fn usz inspect_display_width(StrBuf* b) {
    usz w = 0;
    for (usz i = 0; i < b.len; i++) {
        if ((b.data[i] & 0xC0) != 0x80) w++;
    }
    return w;
}

// The "... N more items" tail for a structure past the entry cap.
fn bool inspect_append_elision(InspectEntries* entries, StrBuf* out, bool need_separator) {
    if (entries.elided == 0) return true;
    if (need_separator && !out.append_bytes(", ")) return false;
    if (!out.append_bytes("... ")) return false;
    if (!inspect_append_int(out, (long)entries.elided)) return false;
    return out.append_bytes(entries.elided == 1 ? " more item" : " more items");
}

fn bool inspect_append_indent(StrBuf* out, usz spaces) {
    for (usz i = 0; i < spaces; i++) {
        if (!out.append_char(' ')) return false;
    }
    return true;
}

// A structure stays on one line while it fits the 80-column break length.
// The arithmetic was verified against captured reference output across a sweep
// of entry counts, entry widths and nesting depths:
//
//     start = count + indentationLvl + len(open brace) + len(prefix) + 10
//     total = count + start + sum(len(entry))
//     one line iff total <= 80
//
// There is deliberately no entry-count cap here. The reference rule gates this
// join on the HEIGHT of the value's own subtree rather than on how many entries
// it has, and the depth limit already caps that height below the threshold. So
// a wide-but-shallow object stays on one line however many entries it has,
// which is why `{ k0: 0, ..., k8: 8 }` does not break. An entry-count cap looks
// right on hand-picked shapes and is wrong; test/console_format/matrix.js is
// what catches that.
//
// An entry that itself broke onto multiple lines forces the parent to break
// too, since a newline inside an entry cannot appear on a single-line join.
fn bool inspect_fits_one_line(InspectCtx* ctx, InspectShape shape, InspectEntries* entries) {
    if (entries.elided > 0) return false;

    usz total = 2 * entries.count + ctx.indent + 1 + shape.prefix_len + 10;
    for (usz i = 0; i < entries.count; i++) {
        StrBuf* b = &entries.items[i].buf;
        for (usz j = 0; j < b.len; j++) {
            if (b.data[j] == '\n') return false;
        }
        total += b.len;
    }
    return total <= INSPECT_BREAK_LENGTH;
}

// ============================================================================
// Leaf shapes
// ============================================================================

// [Function: name], [Function (anonymous)], [class C], [class (anonymous)].
// A function with extra own properties additionally shows them, as in
// with `[Function: f] { a: 1 }`.
fn bool inspect_function(InspectCtx* ctx, HObject* obj, int depth, StrBuf* out) {
    bool is_class = inspect_is_class_ctor(obj);
    if (!out.append_bytes(is_class ? "[class " : "[Function")) return false;

    char[] name = inspect_function_name(ctx, obj);
    if (name.len > 0) {
        if (!is_class && !out.append_bytes(": ")) return false;
        if (!out.append_bytes(name)) return false;
    } else {
        if (!out.append_bytes(is_class ? "(anonymous)" : " (anonymous)")) return false;
    }
    if (!out.append_char(']')) return false;

    // Own enumerable properties hang off the tag. A function's own "name",
    // "length" and "prototype" are non-enumerable, so they stay out of this.
    InspectEntries entries;
    entries.count = 0;
    entries.elided = 0;
    entries.all_numeric = true;
    defer entries.free();
    if (ctx.stack_count >= INSPECT_MAX_STACK) return true;
    ctx.stack[ctx.stack_count++] = obj;
    ctx.indent += 2;
    bool ok = inspect_collect_named(ctx, obj, depth, &entries, false);
    ctx.indent -= 2;
    ctx.stack_count--;
    if (!ok) return false;
    if (entries.count == 0 && entries.elided == 0) return true;

    if (!out.append_char(' ')) return false;
    InspectShape shape;
    shape.prefix_len = 0;
    shape.open = '{';
    shape.close = '}';
    shape.kind = InspectKind.PLAIN;
    return inspect_layout(ctx, shape, &entries, out);
}

// A class constructor is distinguished by its compiled template's
// is_class_ctor flag; a builtin or bound function has no template and is never
// a class.
fn bool inspect_is_class_ctor(HObject* obj) {
    if (obj.flags.obj_class != hobject::ObjClass.FUNCTION) return false;
    HObjectFunction* fn_extra = (HObjectFunction*)obj.extra_ptr();
    if (fn_extra.comp_func == null) return false;
    return fn_extra.comp_func.is_class_ctor();
}

// The function's own "name" property, or "" when absent or empty. Read as a
// plain own data property so an exotic "name" accessor is not invoked.
fn char[] inspect_function_name(InspectCtx* ctx, HObject* obj) {
    HString* name_key = ctx.heap.str(heap::BuiltinStr.NAME);
    if (name_key == null) return "";
    int idx = obj.find_prop_idx(name_key, ctx.heap);
    if (idx < 0) return "";
    if (obj.get_prop_flags((uint)idx, ctx.heap).is_accessor) return "";
    TVal v = obj.prop_values()[idx];
    if (!v.is_string()) return "";
    HString* s = (HString*)v.get_heapptr();
    if (s == null || s.is_symbol()) return "";
    return s.get_data();
}

// An Error prints its stack, which already carries the "Type: message" header.
// With no stack it falls back to that header alone.
fn bool inspect_error(InspectCtx* ctx, HObject* obj, StrBuf* out) {
    HString* stack_key = ctx.heap.str(heap::BuiltinStr.STACK);
    if (stack_key != null) {
        int idx = obj.find_prop_idx(stack_key, ctx.heap);
        if (idx >= 0 && !obj.get_prop_flags((uint)idx, ctx.heap).is_accessor) {
            TVal v = obj.prop_values()[idx];
            if (v.is_string()) {
                HString* s = (HString*)v.get_heapptr();
                if (s != null && !s.is_symbol() && s.blen > 0) {
                    return inspect_append_indented_block(out, s.get_data(), ctx.indent);
                }
            }
        }
    }
    return inspect_via_tostring(ctx, obj, out);
}

// Emit a multi-line block, re-indenting continuation lines to sit under the
// current structure. An error nested in an object keeps its stack lined up
// with the property rather than running back to column zero.
fn bool inspect_append_indented_block(StrBuf* out, char[] data, usz indent) {
    for (usz i = 0; i < data.len; i++) {
        if (!out.append_char(data[i])) return false;
        if (data[i] == '\n' && !inspect_append_indent(out, indent)) return false;
    }
    return true;
}

// Shapes whose own string form is their rendering: RegExp (/re/g) and Symbol
// objects via toString, Date via toISOString — a Date prints in ISO form,
// not the locale-dependent toString form.
fn bool inspect_via_tostring(InspectCtx* ctx, HObject* obj, StrBuf* out) {
    char[] method = obj.flags.obj_class == hobject::ObjClass.DATE
        ? "toISOString" : "toString";
    HString* s = inspect_call_method(ctx, obj, method);
    // An invalid Date has no ISO form (toISOString throws), so it falls back
    // to the toString form, which reads "Invalid Date".
    if (s == null && obj.flags.obj_class == hobject::ObjClass.DATE) {
        s = inspect_call_method(ctx, obj, "toString");
    }
    if (s == null) return out.append_bytes("[Object]");
    return out.append_bytes(s.get_data());
}

// Call `obj[method]()` and return the resulting HString, or null if there is
// no callable method or it did not return a string. A thrown error is
// swallowed: rendering a value for a log must not turn into a thrown
// exception at the console.log call site.
fn HString* inspect_call_method(InspectCtx* ctx, HObject* obj, char[] name) {
    if (ctx.vm == null || ctx.heap.call_fn == null) return null;
    HString* key = builtin_intern_string(ctx.heap, name);
    if (key == null) return null;
    TVal? found = obj.get_prop_proto(key, ctx.heap);
    if (catch found) return null;
    if (!found.is_object() && !found.is_lightfunc()) return null;

    TVal recv;
    recv.set_object(obj);
    TVal result = ctx.heap.call_fn(ctx.vm, found, null, 0, recv);
    if (ctx.heap.has_error) { ctx.heap.has_error = false; return null; }
    if (!result.is_string()) return null;
    HString* s = (HString*)result.get_heapptr();
    if (s == null || s.is_symbol()) return null;
    return s;
}

// True when `obj` reaches a "toString" that is not the one on
// Object.prototype. %s renders such an object through it, on the
// grounds that an author who wrote a toString meant it to be the string form,
// while the inherited default would only ever yield "[object Object]".
//
// The prototype chain is walked rather than the own properties alone, since a
// class puts its toString on the prototype, not on the instance.
//
// A builtin's own toString does not count: an Array, a Map
// and an Error rather than printing "1,2" or "[object Map]", so only a
// toString reached before any builtin prototype qualifies.
fn bool inspect_has_custom_tostring(Heap* heap, HObject* obj) @feat(!SLIM) {
    HString* key = heap.str(heap::BuiltinStr.TO_STRING);
    if (key == null) return false;
    HObject* cur = obj;
    while (cur != null) {
        if (cur == heap.object_proto || inspect_is_builtin_proto(heap, cur)) return false;
        if (cur.find_prop_idx(key, heap) >= 0) return true;
        cur = cur.prototype;
    }
    return false;
}

// True for a built-in prototype whose toString is the engine's own, not a
// user-authored string form.
fn bool inspect_is_builtin_proto(Heap* heap, HObject* obj) {
    return obj == heap.array_proto || obj == heap.map_proto || obj == heap.set_proto
        || obj == heap.date_proto || obj == heap.regexp_proto;
}

// [String: 'x'], [Number: 1], [Boolean: true] for a boxed primitive, whose
// wrapped value is the interesting part.
fn bool inspect_boxed_primitive(InspectCtx* ctx, HObject* obj, StrBuf* out) {
    TVal prim = (*obj.extra_ptr()).prim.primitive_value;
    switch (obj.flags.obj_class) {
        case hobject::ObjClass.STRING:  if (!out.append_bytes("[String: ")) return false;
        case hobject::ObjClass.NUMBER:  if (!out.append_bytes("[Number: ")) return false;
        default:                        if (!out.append_bytes("[Boolean: ")) return false;
    }
    if (!inspect_value(ctx, &prim, INSPECT_MAX_DEPTH, out)) return false;
    return out.append_char(']');
}
