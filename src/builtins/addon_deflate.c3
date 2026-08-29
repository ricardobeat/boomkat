// Deflate add-on — the reference consumer of the host-class mechanism.
//
// This is deliberately a *placeholder* API: it exists to exercise every part of
// the ObjClass.HOST contract that a real add-on (Temporal, Intl, a crypto
// module) will need, on a feature small enough to read in one sitting.
//
// What it proves:
//   - a class registered at runtime, with its id allocated by the Heap
//     rather than baked into the ObjClass enum
//   - a payload the engine never interprets, allocated and freed by the module
//   - a finalizer that runs on collection, so the payload does not leak
//   - a gc_mark callback that keeps a JS value held inside the payload alive
//     across a collection (the load-bearing part; see mark_deflater)
//
// JS surface:
//   const d = new Deflater(tag?)   // tag: any JS value, retained and GC-marked
//   d.push(str)                    // accumulate input, returns total bytes in
//   d.bytesIn                      // accessor over payload state
//   d.tag                          // the retained value, proving gc_mark works
//   Deflate.compress(str)          // one-shot, returns compressed byte length
//   Deflate.roundtrip(str)         // compress + decompress, returns the string
//
// The compression itself is std::compression::deflate; nothing here is novel.
// The point is the plumbing around it.
module boomkat::builtins;

import boomkat::heap;
import boomkat::types;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::env;
import std::compression::deflate;
import std::io;

// The class id handed back by Heap.register_host_class, cached so instance
// methods can check that `this` is really one of ours before touching the
// payload. -1 until registration runs.
long g_deflater_class_id @private = -1;

// Module-owned payload. The engine treats this as an opaque void*; only this
// file knows the layout.
struct DeflaterState @private {
    heap::Heap* heap;  // the allocator that owns buf; engine code avoids raw libc
    char*  buf;        // accumulated input, module-owned
    usz    len;
    usz    cap;
    TVal   tag;        // a JS value the payload holds -- must be GC-marked
    bool   has_tag;
}

// ============================================================================
// Host-class callbacks
// ============================================================================

// Free everything the payload owns. Runs during sweep, and also during heap
// teardown, since this memory is the module's rather than the JS heap's.
fn void finalize_deflater(void* payload, void* udata) @private {
    if (payload == null) return;
    heap::Heap* h = (heap::Heap*)udata;
    if (h == null) return;
    DeflaterState* st = (DeflaterState*)payload;
    if (st.buf != null) {
        h.free_func(h.heap_udata, (void*)st.buf);
        st.buf = null;
    }
    h.free_func(h.heap_udata, payload);
}

// Keep the retained tag reachable. This is the callback that makes host classes
// safe: without it, `d.tag` would be freed by any collection that runs while
// the Deflater is alive but the tag is referenced nowhere else.
fn void mark_deflater(void* payload, heap::Heap* h, void* udata) @private {
    if (payload == null) return;
    DeflaterState* st = (DeflaterState*)payload;
    if (st.has_tag) {
        h.mark_tval(&st.tag);
    }
}

// ============================================================================
// Helpers
// ============================================================================

// The payload of `v`, or null when `v` is not a Deflater. Every instance method
// goes through this, so a method stolen and applied to a foreign object gets a
// TypeError rather than reinterpreting someone else's extra union.
fn DeflaterState* deflater_payload(TVal v) @private {
    if (!v.is_object()) return null;
    HObject* o = (HObject*)v.get_heapptr();
    if (o == null) return null;
    if (o.flags.obj_class != hobject::ObjClass.HOST) return null;
    if (g_deflater_class_id < 0) return null;
    if ((*o.extra_ptr()).host.class_id != (uint)g_deflater_class_id) return null;
    return (DeflaterState*)(*o.extra_ptr()).host.payload;
}

// Append `data`, growing geometrically. Returns false on allocation failure.
fn bool deflater_append(DeflaterState* st, char[] data) @private {
    if (data.len == 0) return true;
    usz need = st.len + data.len;
    if (need > st.cap) {
        usz new_cap = st.cap == 0 ? 64 : st.cap;
        while (new_cap < need) new_cap *= 2;
        char* grown = (char*)st.heap.realloc_func(st.heap.heap_udata, (void*)st.buf, new_cap);
        if (grown == null) return false;
        st.buf = grown;
        st.cap = new_cap;
    }
    for (usz i = 0; i < data.len; i++) st.buf[st.len + i] = data[i];
    st.len = need;
    return true;
}

// The bytes of a string argument, or an empty slice for anything else. Kept
// deliberately narrow: this is a placeholder API, not a coercion showcase.
fn char[] arg_bytes(BuiltinContext* ctx, ushort idx) @private {
    if (ctx.argc <= idx) return {};
    TVal v = ctx.regs[ctx.base_reg + idx];
    if (!v.is_string()) return {};
    HString* hs = (HString*)v.get_heapptr();
    if (hs == null) return {};
    return hs.get_cstr()[:hs.blen];
}

// ============================================================================
// Builtins
// ============================================================================

// new Deflater(tag?)
fn void builtin_deflater_ctor(BuiltinContext* ctx) {
    if (g_deflater_class_id < 0) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Deflater is not available");
        return;
    }

    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.HOST);
    if (catch err = obj_raw) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "out of memory");
        return;
    }
    HObject* obj = obj_raw;

    DeflaterState* st = (DeflaterState*)ctx.heap.alloc_func(ctx.heap.heap_udata, DeflaterState::size);
    if (st == null) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "out of memory");
        return;
    }
    *st = (DeflaterState){ .heap = ctx.heap };

    // Retain the tag argument. From here the payload holds a JS value, which is
    // exactly what mark_deflater has to report to the collector.
    if (ctx.argc >= 1) {
        st.tag = ctx.regs[ctx.base_reg];
        st.has_tag = true;
    }

    (*obj.extra_ptr()).host.payload  = (void*)st;
    (*obj.extra_ptr()).host.class_id = (uint)g_deflater_class_id;
    obj.prototype = ctx.heap.deflater_proto;

    ctx.result.set_object(obj);
}

// Deflater.prototype.push(str) -> total bytes accumulated
fn void builtin_deflater_push(BuiltinContext* ctx) {
    DeflaterState* st = deflater_payload(ctx.this_val);
    if (st == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "not a Deflater");
        return;
    }
    if (!deflater_append(st, arg_bytes(ctx, 0))) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "out of memory");
        return;
    }
    ctx.result.set_number((double)st.len);
}

// get Deflater.prototype.bytesIn
fn void builtin_deflater_bytes_in(BuiltinContext* ctx) {
    DeflaterState* st = deflater_payload(ctx.this_val);
    if (st == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "not a Deflater");
        return;
    }
    ctx.result.set_number((double)st.len);
}

// get Deflater.prototype.tag -- reads the value the payload retained, which is
// only sound because mark_deflater kept it alive.
fn void builtin_deflater_tag(BuiltinContext* ctx) {
    DeflaterState* st = deflater_payload(ctx.this_val);
    if (st == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "not a Deflater");
        return;
    }
    if (st.has_tag) {
        *ctx.result = st.tag;
    } else {
        ctx.result.set_undefined();
    }
}

// Deflate.compress(str) -> compressed byte length
fn void builtin_deflate_compress(BuiltinContext* ctx) {
    char[] src = arg_bytes(ctx, 0);
    char[] packed = deflate::compress(mem, src) ?? {};
    ctx.result.set_number((double)packed.len);
}

// Deflate.roundtrip(str) -> str, proving the data survives the round trip.
fn void builtin_deflate_roundtrip(BuiltinContext* ctx) {
    char[] src = arg_bytes(ctx, 0);
    char[] packed = deflate::compress(mem, src) ?? {};
    char[] back = deflate::decompress(mem, packed) ?? {};
    HString* out = builtin_intern_string(ctx.heap, back);
    if (out == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(out);
}

// ============================================================================
// Registration
// ============================================================================

fn bool register_deflate_addon(EnvRecord* global_env, Heap* heap) {
    // Allocate the class id up front: the constructor needs it, and it is
    // stable for the life of the heap.
    HString* cls_name = heap.str_intern("Deflater");
    long id = heap.register_host_class(
        (void*)&finalize_deflater,
        (void*)&mark_deflater,
        (void*)heap,
        (void*)cls_name);
    if (id < 0) return false;
    g_deflater_class_id = id;

    // --- Deflater.prototype ---
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.deflater_proto = proto;

    if (!register_string_proto_method(proto, heap, "push", Builtin.DEFLATER_PROTO_PUSH.ordinal)) return false;
    if (!register_dataview_accessor(proto, heap, "bytesIn", Builtin.DEFLATER_PROTO_BYTES_IN.ordinal)) return false;
    if (!register_dataview_accessor(proto, heap, "tag", Builtin.DEFLATER_PROTO_TAG.ordinal)) return false;

    // --- Deflater constructor ---
    // Built directly rather than via alloc_builtin_fn, which forces
    // constructable = false; a host class needs `new`.
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.DEFLATER_CTOR.ordinal;
    ctor.flags.callable = true;
    ctor.flags.constructable = true;
    ctor.prototype = heap.function_proto;
    set_func_ctor_name_length(ctor, heap, "Deflater", 1);

    HString* proto_key = heap.str(heap::BuiltinStr.PROTOTYPE);
    TVal proto_tv;
    proto_tv.set_object(proto);
    ctor.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_NNC, heap);

    HString* ctor_key = heap.str(heap::BuiltinStr.CONSTRUCTOR);
    TVal ctor_tv;
    ctor_tv.set_object(ctor);
    proto.put_prop(ctor_key, ctor_tv, hobject::PROP_FLAGS_WC, heap);

    HString* d_key = heap.str_intern("Deflater");
    if (d_key == null) return false;
    env::env_declare_nonenum(global_env, d_key, ctor_tv);

    // --- Deflate namespace ---
    HObject*? ns_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = ns_raw) return false;
    HObject* ns = ns_raw;
    ns.prototype = heap.object_proto;

    if (!register_string_proto_method(ns, heap, "compress", Builtin.DEFLATE_COMPRESS.ordinal)) return false;
    if (!register_string_proto_method(ns, heap, "roundtrip", Builtin.DEFLATE_ROUNDTRIP.ordinal)) return false;

    TVal ns_tv;
    ns_tv.set_object(ns);
    HString* ns_key = heap.str_intern("Deflate");
    if (ns_key == null) return false;
    env::env_declare_nonenum(global_env, ns_key, ns_tv);

    return true;
}
