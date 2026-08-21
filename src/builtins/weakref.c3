// WeakRef and FinalizationRegistry constructors and prototype methods
// (ES2021 §26.1 / §26.2).
//
// This engine's weak collections are not truly weak: nothing is ever
// collected, so a WeakRef target and every FinalizationRegistry entry are
// held strongly (in the object's array_part) and never cleared. deref()
// therefore always returns the target, and cleanup callbacks never fire,
// both are spec-legal, since collection is entirely at the implementation's
// discretion. This mirrors the accepted non-weak WeakMap/WeakSet behaviour.
module boomkat::builtins;
import boomkat::types;
import boomkat::hstring;
import boomkat::env;
import boomkat::heap;
import boomkat::hobject;

// ============================================================================
// Callable predicate
// ============================================================================

fn bool is_callable_val(TVal v) {
    if (v.is_lightfunc()) return true;
    return v.is_object() && v.get_heapptr() != null &&
        ((HObject*)v.get_heapptr()).is_callable();
}

// ============================================================================
// WeakRef constructor (ES2021 §26.1.1)
// ============================================================================
//
// The target is stored at array_part()[0]. array_used == 1.
fn void builtin_weakref(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        coll_throw(ctx, "Constructor WeakRef requires 'new'");
        return;
    }
    if (ctx.argc < 1 || !can_be_held_weakly(ctx.heap, ctx.regs[ctx.base_reg])) {
        builtin_throw(ctx, ctx.heap.type_err_proto,
            "WeakRef: target must be an object or an unregistered symbol");
        return;
    }
    TVal target = ctx.regs[ctx.base_reg];

    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.WEAKREF);
    if (catch err = obj_raw) { ctx.result.set_undefined(); return; }
    HObject* wr = obj_raw;
    wr.prototype = builtin_proto_from_new_target(ctx, ctx.heap.weakref_proto);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    wr.set_array_idx(0, target, ctx.heap);
    if (wr.array_used < 1) wr.array_used = 1;

    ctx.result.set_object(wr);
}

// ============================================================================
// WeakRef.prototype.deref() (ES2021 §26.1.3.2)
// ============================================================================
fn void builtin_weakref_proto_deref(BuiltinContext* ctx) {
    HObject* wr = check_collection_class(ctx, hobject::ObjClass.WEAKREF,
        "WeakRef.prototype.deref called on incompatible value");
    if (wr == null) { ctx.result.set_undefined(); return; }
    // Target is never collected, so it is always present.
    if (wr.array_used >= 1) {
        *ctx.result = wr.array_part()[0];
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// FinalizationRegistry constructor (ES2021 §26.2.1)
// ============================================================================
//
// Storage layout in array_part:
//   [0]              = cleanup callback
//   [1 + 3*i + 0]    = target       (entry i)
//   [1 + 3*i + 1]    = held value    (entry i)
//   [1 + 3*i + 2]    = unregister token (undefined if none)
fn void builtin_finalization_registry(BuiltinContext* ctx) {
    if (!ctx.is_constructor) {
        coll_throw(ctx, "Constructor FinalizationRegistry requires 'new'");
        return;
    }
    if (ctx.argc < 1 || !is_callable_val(ctx.regs[ctx.base_reg])) {
        builtin_throw(ctx, ctx.heap.type_err_proto,
            "FinalizationRegistry: cleanup callback is not callable");
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];

    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FINALIZATION_REGISTRY);
    if (catch err = obj_raw) { ctx.result.set_undefined(); return; }
    HObject* fr = obj_raw;
    fr.prototype = builtin_proto_from_new_target(ctx, ctx.heap.finalization_registry_proto);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    fr.set_array_idx(0, callback, ctx.heap);
    if (fr.array_used < 1) fr.array_used = 1;

    ctx.result.set_object(fr);
}

fn HObject* check_finalization_registry(BuiltinContext* ctx) {
    return check_collection_class(ctx, hobject::ObjClass.FINALIZATION_REGISTRY,
        "FinalizationRegistry.prototype method called on incompatible value");
}

// ============================================================================
// FinalizationRegistry.prototype.register(target, heldValue[, unregisterToken])
// (ES2021 §26.2.3.2)
// ============================================================================
fn void builtin_finalization_registry_proto_register(BuiltinContext* ctx) {
    HObject* fr = check_finalization_registry(ctx);
    if (fr == null) { ctx.result.set_undefined(); return; }

    TVal target = ctx.argc >= 1 ? ctx.regs[ctx.base_reg] : (TVal){};
    if (ctx.argc < 1) target.set_undefined();
    if (!can_be_held_weakly(ctx.heap, target)) {
        builtin_throw(ctx, ctx.heap.type_err_proto,
            "FinalizationRegistry.register: target must be an object or an unregistered symbol");
        return;
    }

    TVal held;
    held.set_undefined();
    if (ctx.argc >= 2) held = ctx.regs[ctx.base_reg + 1];

    // SameValue(target, heldValue) is disallowed (ES2021 §26.2.3.2 step 4).
    if (same_value(target, held)) {
        builtin_throw(ctx, ctx.heap.type_err_proto,
            "FinalizationRegistry.register: target and held value must not be the same");
        return;
    }

    TVal token;
    token.set_undefined();
    if (ctx.argc >= 3) token = ctx.regs[ctx.base_reg + 2];
    // If a token is present it must satisfy CanBeHeldWeakly (step 5).
    if (!token.is_undefined() && !can_be_held_weakly(ctx.heap, token)) {
        builtin_throw(ctx, ctx.heap.type_err_proto,
            "FinalizationRegistry.register: unregister token must be an object or an unregistered symbol");
        return;
    }

    uint cnt = fr.array_used;
    fr.set_array_idx(cnt, target, ctx.heap);
    fr.set_array_idx(cnt + 1, held, ctx.heap);
    fr.set_array_idx(cnt + 2, token, ctx.heap);
    if (fr.array_used < cnt + 3) fr.array_used = cnt + 3;

    ctx.result.set_undefined();
}

// ============================================================================
// FinalizationRegistry.prototype.unregister(unregisterToken) (ES2021 §26.2.3.3)
// ============================================================================
fn void builtin_finalization_registry_proto_unregister(BuiltinContext* ctx) {
    HObject* fr = check_finalization_registry(ctx);
    if (fr == null) { ctx.result.set_undefined(); return; }

    TVal token;
    token.set_undefined();
    if (ctx.argc >= 1) token = ctx.regs[ctx.base_reg];
    if (!can_be_held_weakly(ctx.heap, token)) {
        builtin_throw(ctx, ctx.heap.type_err_proto,
            "FinalizationRegistry.unregister: unregister token must be an object or an unregistered symbol");
        return;
    }

    bool removed = false;
    // Entries occupy [1 + 3*i .. +3). Compact out every entry whose token
    // matches (SameValue). Slot 0 (the callback) is preserved.
    uint used = fr.array_used;
    uint write = 1;
    for (uint read = 1; read + 3 <= used; read += 3) {
        TVal entry_token = fr.array_part()[read + 2];
        if (same_value(entry_token, token)) {
            // Drop this entry: release its refs.
            ctx.heap.decref_tval(&fr.array_part()[read]);
            ctx.heap.decref_tval(&fr.array_part()[read + 1]);
            ctx.heap.decref_tval(&fr.array_part()[read + 2]);
            removed = true;
        } else {
            if (write != read) {
                fr.array_part()[write] = fr.array_part()[read];
                fr.array_part()[write + 1] = fr.array_part()[read + 1];
                fr.array_part()[write + 2] = fr.array_part()[read + 2];
            }
            write += 3;
        }
    }
    // Clear any trailing slots left after compaction so GC marking / later
    // inserts do not observe stale (already-decref'd) TVals.
    for (uint i = write; i < used; i++) {
        fr.array_part()[i].set_undefined();
    }
    fr.array_used = write;

    ctx.result.set_boolean(removed);
}

// ============================================================================
// Shared registration helper for the WeakRef / FinalizationRegistry pattern.
// ============================================================================
//
// Builds the prototype (ordinary object, @@toStringTag = tag) and the
// constructor function (with prototype/length/name descriptors) and binds the
// constructor as a non-enumerable global. Returns the prototype so the caller
// can install prototype methods, or null on allocation failure.
fn HObject* register_weak_wrapper(EnvRecord* global_env, Heap* heap,
        char[] name, int length, Builtin ctor_builtin) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return null;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, name));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return null;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)ctor_builtin.ordinal;

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
    length_tv.set_fastint(length);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    HString* name_key = heap.str_intern(name);
    if (name_key == null) return null;
    TVal ctor_val;
    ctor_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, name);
    env::env_declare_nonenum(global_env, name_key, ctor_val);

    return proto;
}

// ============================================================================
// WeakRef registration (ES2021 §26.1)
// ============================================================================
fn bool register_weakref_constructor(EnvRecord* global_env, Heap* heap) {
    HObject* proto = register_weak_wrapper(global_env, heap, "WeakRef", 1, Builtin.WEAKREF);
    if (proto == null) return false;
    heap.weakref_proto = proto;
    if (!register_string_proto_method(proto, heap, "deref", Builtin.WEAKREF_PROTO_DEREF.ordinal)) return false;
    return true;
}

// ============================================================================
// FinalizationRegistry registration (ES2021 §26.2)
// ============================================================================
fn bool register_finalization_registry_constructor(EnvRecord* global_env, Heap* heap) {
    HObject* proto = register_weak_wrapper(global_env, heap, "FinalizationRegistry", 1, Builtin.FINALIZATION_REGISTRY);
    if (proto == null) return false;
    heap.finalization_registry_proto = proto;
    if (!register_string_proto_method(proto, heap, "register", Builtin.FINALIZATION_REGISTRY_PROTO_REGISTER.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "unregister", Builtin.FINALIZATION_REGISTRY_PROTO_UNREGISTER.ordinal)) return false;
    return true;
}
