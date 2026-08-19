/// structuredClone (HTML §2.7.10).
///
/// Single-pass deep clone for the engine's JS types. The destination is in
/// the same realm as the source, so the spec's two-pass Serialize/Deserialize
/// pair collapses into a recursive walk that allocates clones inline.
/// Cycles and shared references are preserved through a flat identity map
/// keyed by `HObject*`.
///
/// Throws `TypeError` with `.name = "DataCloneError"` (no DOM here, but the
/// spec error name is what test262 and user code check for).
module boomkat::builtins;
import boomkat::types;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;

// ============================================================================
// Identity map: HObject* -> in-progress clone TVal.
// ============================================================================
//
// Linear scan, grows on demand. The map is only walked per unique source
// object (cycles short-circuit; primitives never enter), so a flat array is
// fine for the sizes structuredClone encounters in practice.

struct CloneEntry {
    HObject* src;
    TVal     clone;
}

struct CloneMap {
    Heap*        heap;
    CloneEntry*  entries;
    uint         count;
    uint         cap;
}

fn void CloneMap.init(&self, Heap* heap) {
    self.heap = heap;
    self.entries = null;
    self.count = 0;
    self.cap = 0;
}

fn void CloneMap.free(&self) {
    if (self.entries != null) {
        // Drop refcount held on every clone while it was in the map.
        for (uint i = 0; i < self.count; i++) {
            self.heap.decref_tval(&self.entries[i].clone);
        }
        self.heap.free_func(self.heap.heap_udata, self.entries);
    }
    self.entries = null;
    self.count = 0;
    self.cap = 0;
}

fn bool CloneMap.put(&self, HObject* src, TVal clone) {
    if (self.count == self.cap) {
        uint new_cap = self.cap == 0 ? 16 : self.cap * 2;
        usz bytes = (usz)new_cap * CloneEntry::size;
        if (self.entries == null) {
            self.entries = (CloneEntry*)self.heap.alloc_func(self.heap.heap_udata, bytes);
        } else {
            self.entries = (CloneEntry*)self.heap.realloc_func(self.heap.heap_udata, self.entries, bytes);
        }
        if (self.entries == null) return false;
        self.cap = new_cap;
    }
    // Hold a refcount on the clone until the walk completes.
    TVal held = clone;
    self.heap.tval_copy_ref(&held, &clone);
    self.entries[self.count].src = src;
    self.entries[self.count].clone = held;
    self.count++;
    return true;
}

/// Returns the cached clone if `src` is already in the map. The returned
/// `TVal?` is a copy; the caller does not own a reference.
fn TVal? CloneMap.get(&self, HObject* src) {
    for (uint i = 0; i < self.count; i++) {
        if (self.entries[i].src == src) {
            TVal out = self.entries[i].clone;
            return out;
        }
    }
    return hobject::PROP_NOT_FOUND~;
}

// ============================================================================
// Helpers
// ============================================================================

fn void clone_throw(BuiltinContext* ctx, char[] msg) {
    // Build a plain Error with the spec-required `.name = "DataCloneError"`.
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.err_proto;
        HString* name_str = builtin_intern_string(ctx.heap, "DataCloneError");
        TVal name_tv; name_tv.set_string(name_str);
        err.put_prop(ctx.heap.str(heap::BuiltinStr.NAME), name_tv,
                     hobject::PROP_FLAGS_WC, ctx.heap);
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        if (msg_str != null) {
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(ctx.heap.str(heap::BuiltinStr.MESSAGE), msg_tv,
                         hobject::PROP_FLAGS_WC, ctx.heap);
        }
        // Capture the current JS stack so user-side error.stack is useful.
        if (ctx.heap.err_proto != null) {
            HString* stack_str = error_build_stack_string(ctx, name_str, msg_str);
            error_set_captured_stack(err, ctx.heap, stack_str);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
    ctx.result.set_undefined();
}

fn bool tval_is_primitive(TVal v) {
    switch (v.get_tag()) {
        case UNDEFINED: case NULL_VAL: case BOOLEAN:
        case NUMBER: case FASTINT: case BIGINT:
            return true;
        case STRING: return !is_symbol_val(v);
        default: return false;
    }
}

/// Read `key` on `obj` via the accessor-aware path (invokes getters, which
/// may throw). Returns the value or sets ctx.should_throw.
fn TVal? clone_get(HObject* obj, HString* key, BuiltinContext* ctx) {
    TVal out;
    if (key == null) {
        out.set_undefined();
        return out;
    }
    if (try v = builtins_generic_get(obj, key, ctx)) {
        out = v;
        return out;
    }
    return hobject::PROP_NOT_FOUND~;
}

/// Walk `obj`'s own enumerable string-keyed properties and write each
/// (cloned key, cloned value) into the clone via accessor-aware Get and
/// plain data-property Put (CreateDataProperty semantics: WEC).
fn bool clone_own_enumerable_props(BuiltinContext* ctx, HObject* src, HObject* dst, CloneMap* map) {
    uint cap = src.prop_count + src.array_size + 32;
    HString** keys = (HString**)ctx.heap.alloc_func(ctx.heap.heap_udata, HString*::size * cap);
    if (keys == null) return false;
    defer ctx.heap.free_func(ctx.heap.heap_udata, keys);

    uint n = collect_own_enum_string_keys(ctx.heap, src, keys, true);
    for (uint i = 0; i < n; i++) {
        HString* k = keys[i];
        TVal src_val;
        if (try got = clone_get(src, k, ctx)) {
            src_val = got;
        } else {
            return false;
        }

        TVal new_val;
        if (!clone_value(ctx, src_val, map, &new_val)) return false;

        // CreateDataProperty: WEC, no setter invocation.
        hobject::PropFlags flags;
        flags.writable = true;
        flags.enumerable = true;
        flags.configurable = true;
        flags.is_accessor = false;
        TVal new_key; new_key.set_string(k);
        dst.put_prop(k, new_val, flags, ctx.heap);
    }
    return true;
}

// ============================================================================
// Top-level dispatch
// ============================================================================

fn bool clone_value(BuiltinContext* ctx, TVal src, CloneMap* map, TVal* out) {
    if (tval_is_primitive(src)) {
        *out = src;
        return true;
    }
    if (!src.is_object() || src.get_heapptr() == null) {
        clone_throw(ctx, "value is not cloneable");
        return false;
    }
    HObject* src_obj = (HObject*)src.get_heapptr();

    if (try cached = map.get(src_obj)) {
        *out = cached;
        return true;
    }

    switch (src_obj.flags.obj_class) {
        case hobject::ObjClass.ARRAY:
            return clone_plain_or_array(ctx, src_obj, hobject::ObjClass.ARRAY, map, out);
        case hobject::ObjClass.OBJECT:
            return clone_plain_or_array(ctx, src_obj, hobject::ObjClass.OBJECT, map, out);
        case hobject::ObjClass.DATE:
            return clone_date(ctx, src_obj, out);
        case hobject::ObjClass.REGEXP:
            return clone_regexp(ctx, src_obj, out);
        case hobject::ObjClass.BOOLEAN:
        case hobject::ObjClass.NUMBER:
        case hobject::ObjClass.STRING:
            return clone_into_wrapper(ctx, src_obj, out);
        case hobject::ObjClass.ARRAYBUFFER:
            return clone_arraybuffer(ctx, src_obj, map, out);
        case hobject::ObjClass.DATAVIEW:
            return clone_data_view(ctx, src_obj, map, out);
        case hobject::ObjClass.INT8ARRAY:
        case hobject::ObjClass.UINT8ARRAY:
        case hobject::ObjClass.UINT8CLAMPEDARRAY:
        case hobject::ObjClass.INT16ARRAY:
        case hobject::ObjClass.UINT16ARRAY:
        case hobject::ObjClass.INT32ARRAY:
        case hobject::ObjClass.UINT32ARRAY:
        case hobject::ObjClass.FLOAT16ARRAY:
        case hobject::ObjClass.FLOAT32ARRAY:
        case hobject::ObjClass.FLOAT64ARRAY:
        case hobject::ObjClass.BIGINT64ARRAY:
        case hobject::ObjClass.BIGUINT64ARRAY:
            return clone_typed_array(ctx, src_obj, map, out);
        case hobject::ObjClass.MAP:
            return clone_map(ctx, src_obj, map, out);
        case hobject::ObjClass.SET:
            return clone_set(ctx, src_obj, map, out);
        case hobject::ObjClass.ERROR:
            return clone_error(ctx, src_obj, map, out);
        default:
            clone_throw(ctx, "value is not cloneable");
            return false;
    }
}

fn bool clone_into_wrapper(BuiltinContext* ctx, HObject* src, TVal* out) {
    TVal pv = (*src.extra_ptr()).prim.primitive_value;
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = raw) return false;
    HObject* obj = raw;
    // Preserve the wrapper's identity (the source's prototype is one of the
    // wrapper prototypes: Boolean/Number/String/BigInt).
    obj.prototype = src.prototype;
    (*obj.extra_ptr()).prim.primitive_value = pv;
    // alloc_object initialises the new object's refcount to 1; the primitive
    // value may carry its own references through the copy, so bump them.
    ctx.heap.tval_copy_ref(&(*obj.extra_ptr()).prim.primitive_value, &pv);
    out.set_object(obj);
    return true;
}

// ============================================================================
// Clone the bytes of `src_ab` into a fresh ArrayBuffer (non-shared, fixed).
// Used for cloning ArrayBuffer and as the backing store for TypedArray /
// DataView clones.
// ============================================================================
fn bool clone_arraybuffer_bytes(BuiltinContext* ctx, HObject* src_ab, HObject** out) {
    if ((*src_ab.extra_ptr()).ab.is_shared) {
        clone_throw(ctx, "SharedArrayBuffer is not cloneable");
        return false;
    }
    if ((*src_ab.extra_ptr()).ab.byte_length == 0xFFFFFFFFu) {
        clone_throw(ctx, "ArrayBuffer is detached");
        return false;
    }
    uint len = (*src_ab.extra_ptr()).ab.byte_length;
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAYBUFFER);
    if (catch err = raw) {
        clone_throw(ctx, "out of memory cloning ArrayBuffer");
        return false;
    }
    HObject* dst = raw;
    dst.prototype = ctx.heap.arraybuffer_proto;
    (*dst.extra_ptr()).ab.data = null;
    (*dst.extra_ptr()).ab.byte_length = 0;
    (*dst.extra_ptr()).ab.views_head = null;
    (*dst.extra_ptr()).ab.resizable = (*src_ab.extra_ptr()).ab.resizable;
    (*dst.extra_ptr()).ab.max_byte_length = (*src_ab.extra_ptr()).ab.max_byte_length;
    (*dst.extra_ptr()).ab.is_shared = false;
    if (len > 0) {
        char* data = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)len);
        if (data == null) {
            clone_throw(ctx, "out of memory cloning ArrayBuffer");
            return false;
        }
        char* src_data = (*src_ab.extra_ptr()).ab.data;
        mem::copy(data, src_data, (sz)((usz)len));
        (*dst.extra_ptr()).ab.data = data;
        (*dst.extra_ptr()).ab.byte_length = len;
    }
    *out = dst;
    return true;
}

// ============================================================================
// Per-class clone bodies
// ============================================================================

fn bool clone_date(BuiltinContext* ctx, HObject* src, TVal* out) {
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.DATE);
    if (catch err = raw) return false;
    HObject* obj = raw;
    obj.prototype = ctx.heap.date_proto;
    TVal pv = (*src.extra_ptr()).prim.primitive_value;
    (*obj.extra_ptr()).prim.primitive_value = pv;
    ctx.heap.tval_copy_ref(&(*obj.extra_ptr()).prim.primitive_value, &pv);
    out.set_object(obj);
    return true;
}

fn bool clone_regexp(BuiltinContext* ctx, HObject* src, TVal* out) {
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.REGEXP);
    if (catch err = raw) return false;
    HObject* obj = raw;
    obj.prototype = ctx.heap.regexp_proto;
    (*obj.extra_ptr()).regexp.regexp_data = null;
    (*obj.extra_ptr()).regexp.flags = 0;
    (*obj.extra_ptr()).prim.primitive_value.set_undefined();

    TVal pv = (*src.extra_ptr()).prim.primitive_value;
    char* pat = "";
    usz pat_len = 0;
    HString* pat_str = null;
    if (pv.is_string() && pv.get_heapptr() != null) {
        pat_str = (HString*)pv.get_heapptr();
        pat = (char*)pat_str.get_cstr();
        pat_len = (usz)pat_str.blen;
    }
    if (!regexp_initialize(ctx, obj, pat, pat_len, "", 0,
                           (*src.extra_ptr()).regexp.flags)) {
        clone_throw(ctx, "could not clone RegExp");
        return false;
    }
    // Mirror the source's `lastIndex` (spec preserves it indirectly via the
    // original matcher; we re-compiled, so copy the value over).
    HString* lastindex_key = ctx.heap.str(heap::BuiltinStr.LAST_INDEX);
    TVal src_lastindex;
    src_lastindex.set_fastint(0);
    if (try v = clone_get(src, lastindex_key, ctx)) { src_lastindex = v; }
    if (ctx.should_throw) return false;
    obj.put_prop(lastindex_key, src_lastindex, hobject::PROP_FLAGS_WENC, ctx.heap);
    out.set_object(obj);
    return true;
}

fn bool clone_arraybuffer(BuiltinContext* ctx, HObject* src, CloneMap* map, TVal* out) {
    if ((*src.extra_ptr()).ab.is_shared) {
        clone_throw(ctx, "SharedArrayBuffer is not cloneable");
        return false;
    }
    if ((*src.extra_ptr()).ab.byte_length == 0xFFFFFFFFu) {
        clone_throw(ctx, "ArrayBuffer is detached");
        return false;
    }
    // Identity-map the clone before allocating its bytes (no cycle possible,
    // but keeps the protocol uniform and lets the bytes' TVal stay valid).
    HObject* dst;
    if (!clone_arraybuffer_bytes(ctx, src, &dst)) return false;
    TVal dst_tv; dst_tv.set_object(dst);
    map.put(src, dst_tv);
    out.set_object(dst);
    return true;
}

fn bool clone_typed_array(BuiltinContext* ctx, HObject* src, CloneMap* map, TVal* out) {
    if (view_is_out_of_bounds(src)) {
        clone_throw(ctx, "TypedArray is out of bounds");
        return false;
    }
    HObject* src_buf = (*src.extra_ptr()).view.buffer;
    if (src_buf == null) {
        clone_throw(ctx, "TypedArray has no backing buffer");
        return false;
    }
    if ((*src_buf.extra_ptr()).ab.byte_length == 0xFFFFFFFFu) {
        clone_throw(ctx, "TypedArray buffer is detached");
        return false;
    }
    TVal src_buf_tv; src_buf_tv.set_object(src_buf);
    TVal buf_clone;
    if (!clone_value(ctx, src_buf_tv, map, &buf_clone)) {
        return false;
    }
    // clone_value returns null for transferred buffers; the spec says a TA
    // whose buffer is transferred is itself transferred, which we model by
    // rejecting it (this engine has no postMessage, so transfer is unused).
    if (!buf_clone.is_object() || buf_clone.get_heapptr() == null) {
        clone_throw(ctx, "TypedArray backing buffer is not cloneable");
        return false;
    }
    HObject* dst_buf = (HObject*)buf_clone.get_heapptr();
    uint byte_offset = (*src.extra_ptr()).view.byte_offset;
    uint byte_length = (*src.extra_ptr()).view.byte_length;
    uint shift = ta_elem_shift(src.flags.obj_class);
    uint array_length = byte_length >> shift;

    HObject*? raw = ctx.heap.alloc_object(src.flags.obj_class);
    if (catch err = raw) {
        clone_throw(ctx, "out of memory cloning TypedArray");
        return false;
    }
    HObject* dst = raw;
    // Preserve the source's specific typed-array subclass prototype
    // (Float32Array.prototype, BigInt64Array.prototype, …) so `instanceof`
    // and `Object.getPrototypeOf` return the right object. The boomkat keeps
    // one generic typedarray_proto on the heap, not per-subclass ones.
    dst.prototype = src.prototype;
    (*dst.extra_ptr()).view.buffer = dst_buf;
    (*dst.extra_ptr()).view.next_view = null;
    (*dst.extra_ptr()).view.byte_offset = byte_offset;
    (*dst.extra_ptr()).view.byte_length = byte_length;
    (*dst.extra_ptr()).view.length_tracking = (*src.extra_ptr()).view.length_tracking;
    ((types::HeapHeader*)dst_buf).incref();

    // Identity-map the view before populating (no cycle here, but uniform).
    TVal dst_tv; dst_tv.set_object(dst);
    map.put(src, dst_tv);

    // Link into dst_buf's view chain.
    (*dst.extra_ptr()).view.next_view = (*dst_buf.extra_ptr()).ab.views_head;
    (*dst_buf.extra_ptr()).ab.views_head = dst;

    out.set_object(dst);
    return true;
}

fn bool clone_data_view(BuiltinContext* ctx, HObject* src, CloneMap* map, TVal* out) {
    HObject* src_buf = (*src.extra_ptr()).view.buffer;
    if (src_buf == null) {
        clone_throw(ctx, "DataView has no backing buffer");
        return false;
    }
    if ((*src_buf.extra_ptr()).ab.byte_length == 0xFFFFFFFFu) {
        clone_throw(ctx, "DataView buffer is detached");
        return false;
    }
    TVal src_buf_tv2; src_buf_tv2.set_object(src_buf);
    TVal buf_clone;
    if (!clone_value(ctx, src_buf_tv2, map, &buf_clone)) {
        return false;
    }
    if (!buf_clone.is_object() || buf_clone.get_heapptr() == null) {
        clone_throw(ctx, "DataView backing buffer is not cloneable");
        return false;
    }
    HObject* dst_buf = (HObject*)buf_clone.get_heapptr();
    uint byte_offset = (*src.extra_ptr()).view.byte_offset;
    uint byte_length = (*src.extra_ptr()).view.byte_length;

    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.DATAVIEW);
    if (catch err = raw) {
        clone_throw(ctx, "out of memory cloning DataView");
        return false;
    }
    HObject* dst = raw;
    dst.prototype = ctx.heap.dataview_proto;
    (*dst.extra_ptr()).view.buffer = dst_buf;
    (*dst.extra_ptr()).view.next_view = null;
    (*dst.extra_ptr()).view.byte_offset = byte_offset;
    (*dst.extra_ptr()).view.byte_length = byte_length;
    (*dst.extra_ptr()).view.length_tracking = false;
    ((types::HeapHeader*)dst_buf).incref();
    (*dst.extra_ptr()).view.next_view = (*dst_buf.extra_ptr()).ab.views_head;
    (*dst_buf.extra_ptr()).ab.views_head = dst;

    out.set_object(dst);
    return true;
}

fn bool clone_map(BuiltinContext* ctx, HObject* src, CloneMap* map, TVal* out) {
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.MAP);
    if (catch err = raw) return false;
    HObject* dst = raw;
    dst.prototype = ctx.heap.map_proto;
    // Identity-map immediately: a Map with cyclic values must not recurse
    // back into itself, and the map entry loop recurses through clone_value.
    TVal dst_tv; dst_tv.set_object(dst);
    map.put(src, dst_tv);

    // Map entries live in array_part as [k0, v0, k1, v1, ...]. Skip the
    // _empty_ (deleted) sentinel entries; surviving entries are cloned.
    TVal* src_arr = src.array_part();
    if (src_arr != null) {
        for (uint i = 0; i + 1 < src.array_used; i += 2) {
            TVal sk = src_arr[i];
            TVal sv = src_arr[i + 1];
            if (sk.is_deleted()) continue;

            TVal nk; if (!clone_value(ctx, sk, map, &nk)) return false;
            TVal nv; if (!clone_value(ctx, sv, map, &nv)) return false;

            // Append [nk, nv] into dst.array_part. set_array_idx grows the
            // array, tracks array_used, and increfs heap-allocated values.
            uint cnt = dst.array_used;
            if (!dst.set_array_idx(cnt, nk, ctx.heap)) {
                clone_throw(ctx, "out of memory cloning Map");
                return false;
            }
            if (!dst.set_array_idx(cnt + 1, nv, ctx.heap)) {
                clone_throw(ctx, "out of memory cloning Map");
                return false;
            }
            if (dst.array_used <= cnt + 1) dst.array_used = cnt + 2;
        }
    }
    out.set_object(dst);
    return true;
}

fn bool clone_set(BuiltinContext* ctx, HObject* src, CloneMap* map, TVal* out) {
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.SET);
    if (catch err = raw) return false;
    HObject* dst = raw;
    dst.prototype = ctx.heap.set_proto;
    TVal dst_tv; dst_tv.set_object(dst);
    map.put(src, dst_tv);

    TVal* src_arr = src.array_part();
    if (src_arr != null) {
        for (uint i = 0; i < src.array_used; i++) {
            TVal sv = src_arr[i];
            if (sv.is_deleted()) continue;
            TVal nv;
            if (!clone_value(ctx, sv, map, &nv)) return false;
            uint cnt = dst.array_used;
            if (!dst.set_array_idx(cnt, nv, ctx.heap)) {
                clone_throw(ctx, "out of memory cloning Set");
                return false;
            }
            if (dst.array_used <= cnt) dst.array_used = cnt + 1;
        }
    }
    out.set_object(dst);
    return true;
}

fn bool clone_error(BuiltinContext* ctx, HObject* src, CloneMap* map, TVal* out) {
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err = raw) {
        clone_throw(ctx, "out of memory cloning Error");
        return false;
    }
    HObject* dst = raw;

    // Resolve the prototype by the source's `name`. Unknown names map to
    // Error.prototype per HTML §2.7.6 step 21.2.
    HString* name_key = ctx.heap.str(heap::BuiltinStr.NAME);
    TVal name_tv;
    name_tv.set_string(builtin_intern_string(ctx.heap, "Error"));
    if (try n = clone_get(src, name_key, ctx)) { name_tv = n; }
    if (ctx.should_throw) return false;
    HString* name_hs = null;
    if (name_tv.is_string() && name_tv.get_heapptr() != null) {
        name_hs = (HString*)name_tv.get_heapptr();
    }
    HObject* proto = ctx.heap.err_proto;
    if (name_hs != null) {
        char[] n = name_hs.get_cstr()[:name_hs.blen];
        if (n == "EvalError")      { proto = ctx.heap.eval_err_proto; }
        else if (n == "RangeError")     { proto = ctx.heap.range_err_proto; }
        else if (n == "ReferenceError") { proto = ctx.heap.ref_err_proto; }
        else if (n == "SyntaxError")    { proto = ctx.heap.syntax_err_proto; }
        else if (n == "TypeError")      { proto = ctx.heap.type_err_proto; }
        else if (n == "URIError")       { proto = ctx.heap.uri_err_proto; }
        else if (n == "AggregateError") { proto = ctx.heap.aggregate_err_proto; }
    }
    dst.prototype = proto;

    // Copy .name and .message (writable, non-enumerable, configurable).
    if (name_hs != null) {
        TVal nt; nt.set_string(name_hs);
        dst.put_prop(name_key, nt, hobject::PROP_FLAGS_WC, ctx.heap);
    } else {
        TVal nt; nt.set_string(builtin_intern_string(ctx.heap, "Error"));
        dst.put_prop(name_key, nt, hobject::PROP_FLAGS_WC, ctx.heap);
    }

    HString* msg_key = ctx.heap.str(heap::BuiltinStr.MESSAGE);
    TVal msg_tv; msg_tv.set_undefined();
    if (try m = clone_get(src, msg_key, ctx)) { msg_tv = m; }
    if (ctx.should_throw) return false;
    if (!msg_tv.is_undefined()) {
        dst.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC, ctx.heap);
    }

    // Copy the captured stack so error.stack accessor returns the original.
    TVal stack = (*src.extra_ptr()).err.captured_stack;
    ctx.heap.tval_copy_ref(&(*dst.extra_ptr()).err.captured_stack, &stack);

    // Carry across other own enumerable string props (extensions add here).
    if (!clone_own_enumerable_props(ctx, src, dst, map)) return false;

    out.set_object(dst);
    return true;
}

fn bool clone_plain_or_array(BuiltinContext* ctx, HObject* src, hobject::ObjClass cls,
                             CloneMap* map, TVal* out) {
    HObject*? raw = ctx.heap.alloc_object(cls);
    if (catch err = raw) return false;
    HObject* dst = raw;
    dst.prototype = src.prototype;
    TVal dst_tv; dst_tv.set_object(dst);
    map.put(src, dst_tv);

    if (cls == hobject::ObjClass.ARRAY) {
        // Carry over the dense length so the new array reads as the right
        // size before properties are written into the named table.
        (*dst.extra_ptr()).array_length = (*src.extra_ptr()).array_length;
        dst.flags.exotic_array = true;
    }

    if (!clone_own_enumerable_props(ctx, src, dst, map)) return false;
    out.set_object(dst);
    return true;
}

// ============================================================================
// Builtin handler + registration
// ============================================================================

fn void builtin_structured_clone(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto,
            "structuredClone requires at least 1 argument");
        return;
    }

    // The `options` argument (transfer list) is accepted but not honored.
    // The engine has no transferable platform objects, so any non-empty
    // `transfer` is rejected as the spec's DataCloneError ("ArrayBuffer is
    // not in the transfer list" / "could not transfer" all surface here).
    if (ctx.argc >= 2) {
        TVal opt = ctx.regs[ctx.base_reg + 1];
        if (opt.is_object() && opt.get_heapptr() != null) {
            HString* transfer_key = builtin_intern_string(ctx.heap, "transfer");
            if (transfer_key != null) {
                TVal transfer;
                transfer.set_undefined();
                if (try t = clone_get((HObject*)opt.get_heapptr(), transfer_key, ctx)) {
                    transfer = t;
                }
                if (ctx.should_throw) return;
                if (!transfer.is_undefined() && !transfer.is_null()) {
                    clone_throw(ctx, "transfer option is not supported");
                    return;
                }
            }
        }
    }

    CloneMap map;
    map.init(ctx.heap);
    defer map.free();

    TVal src = ctx.regs[ctx.base_reg];
    TVal out;
    if (!clone_value(ctx, src, &map, &out)) return;
    *ctx.result = out;
}
