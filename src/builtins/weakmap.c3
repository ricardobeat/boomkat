// WeakMap constructor and WeakMap.prototype methods.
module boomkat::builtins;
import boomkat::types;
import boomkat::hstring;
import boomkat::env;

import boomkat::heap;
import boomkat::hobject;

// ============================================================================
// WeakMap helpers
// ============================================================================

fn HObject* check_weakmap(BuiltinContext* ctx) {
    return check_collection_class(ctx, hobject::ObjClass.WEAKMAP, "WeakMap.prototype method called on incompatible value");
}

// Find the index in array_part where a key matches. Returns -1 if not found.
// WeakMap entries are stored as [k0, v0, k1, v1, ...] in array_part.
fn int weakmap_find_key(HObject* wm, TVal key, heap::Heap* h) {
    return coll_find(wm, key, 2, h);
}

// ============================================================================
// WeakMap constructor (ES6 §23.3.1)
// ============================================================================
fn void builtin_weakmap(BuiltinContext* ctx) {
    coll_construct(ctx, hobject::ObjClass.WEAKMAP, ctx.heap.weakmap_proto,
        "Constructor WeakMap requires 'new'",
        "WeakMap constructor argument is not an object",
        "set", "WeakMap.prototype.set is not callable",
        "WeakMap: iterable argument is not iterable", true);
}

// ============================================================================
// WeakMap.prototype.set(key, value), ES6 §23.3.3.5
// ============================================================================
fn void builtin_weakmap_proto_set(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    coll_set_entry(ctx, wm, 2, true, "Invalid value used as weak map key", false);
}

// ============================================================================
// WeakMap.prototype.getOrInsert(key, value), ES2025 §24.3.3.6
// ============================================================================
fn void builtin_weakmap_proto_getOrInsert(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    coll_get_or_insert(ctx, wm, true, "Invalid value used as weak map key", false);
}

// ============================================================================
// WeakMap.prototype.getOrInsertComputed(key, callbackfn), ES2025 §24.3.3.7
// ============================================================================
fn void builtin_weakmap_proto_getOrInsertComputed(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    coll_get_or_insert_computed(ctx, wm, true, "Invalid value used as weak map key", "callback function is not callable", false);
}

// ============================================================================
// WeakMap.prototype.get(key), ES6 §23.3.3.3
// ============================================================================
fn void builtin_weakmap_proto_get(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = weakmap_find_key(wm, key, ctx.heap);
    if (found >= 0) {
        *ctx.result = wm.array_part()[(uint)found + 1];
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// WeakMap.prototype.has(key), ES6 §23.3.3.4
// ============================================================================
fn void builtin_weakmap_proto_has(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = weakmap_find_key(wm, key, ctx.heap);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// WeakMap.prototype.delete(key), ES6 §23.3.3.2
// ============================================================================
fn void builtin_weakmap_proto_delete(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }
    coll_delete(ctx, wm, ctx.regs[ctx.base_reg], 2, false);
}

// ============================================================================
// WeakMap constructor registration
// ============================================================================

fn bool register_weakmap_constructor(EnvRecord* global_env, Heap* heap) {
    // ES6 §23.3.3: WeakMap.prototype is an ordinary object, must NOT carry
    // the WEAKMAP ObjClass flag, otherwise check_weakmap() would accept it
    // as a valid WeakMap and prototype methods would skip the TypeError guard.
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.weakmap_proto = proto;

    if (!register_string_proto_method(proto, heap, "set", Builtin.WEAKMAP_PROTO_SET.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "get", Builtin.WEAKMAP_PROTO_GET.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "has", Builtin.WEAKMAP_PROTO_HAS.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "delete", Builtin.WEAKMAP_PROTO_DELETE.ordinal)) return false;
    // Add .getOrInsert(key, value) method, ES2025 §24.3.3.6
    if (!register_string_proto_method(proto, heap, "getOrInsert", Builtin.WEAKMAP_PROTO_GETORINSERT.ordinal)) return false;
    // Add .getOrInsertComputed(key, callbackfn) method, ES2025 §24.3.3.7
    if (!register_string_proto_method(proto, heap, "getOrInsertComputed", Builtin.WEAKMAP_PROTO_GETORINSERTCOMPUTED.ordinal)) return false;

    // Set @@toStringTag
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "WeakMap"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.WEAKMAP.ordinal;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    HString* wm_key = heap.str_intern("WeakMap");
    if (wm_key == null) return false;
    TVal wm_val;
    wm_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, "WeakMap");
    env::env_declare_nonenum(global_env, wm_key, wm_val);

    return true;
}
