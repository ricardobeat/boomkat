/// Set constructor and Set.prototype methods.
module duktape::builtins;

import duktape::types;
import duktape::heap;
import duktape::hobject;
import duktape::hstring;
import duktape::env;

// ============================================================================
// Set helpers
// ============================================================================

fn HObject* check_set(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.SET) return obj;
    }
    // TypeError
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Set.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
    }
    return null;
}

/// Find the index in array_part where a value matches. Returns -1 if not found.
/// Set entries are stored as [v0, v1, ...] in array_part.
fn int set_find_value(HObject* set, TVal val) {
    uint count = set.array_used;
    for (uint i = 0; i < count; i++) {
        if (same_value_zero(set.array_part()[i], val)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// Set constructor (ES6 §23.2.1)
// ============================================================================
fn void builtin_set(BuiltinContext* ctx) {
    HObject*? set_raw = ctx.heap.alloc_object(hobject::ObjClass.SET);
    if (catch err = set_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* set = set_raw;

    // Set size property
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint(0);
    set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // If iterable argument, populate set
    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.is_object() && arg.get_heapptr() != null) {
            HObject* iterable = (HObject*)arg.get_heapptr();
            uint len = array_get_length(iterable, ctx.heap);
            for (uint i = 0; i < len; i++) {
                TVal v = array_get_elem(iterable, i, ctx.heap);
                if (!v.is_undefined()) {
                    int found = set_find_value(set, v);
                    if (found < 0) {
                        set.set_array_idx(set.array_used, v);
                    }
                }
            }
            size_val.set_fastint((long)set.array_used);
            set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);
        }
    }

    ctx.result.set_object(set);
}

// ============================================================================
// Set.prototype.add(value) — ES6 §23.2.3.1
// ============================================================================
fn void builtin_set_proto_add(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    if (found < 0) {
        set.set_array_idx(set.array_used, value);
    }

    // Update size
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint((long)set.array_used);
    set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // Return the set
    ctx.result.set_object(set);
}

// ============================================================================
// Set.prototype.has(value) — ES6 §23.2.3.7
// ============================================================================
fn void builtin_set_proto_has(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// Set.prototype.delete(value) — ES6 §23.2.3.4
// ============================================================================
fn void builtin_set_proto_delete(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    if (found >= 0) {
        uint cnt = set.array_used;
        // Shift elements down
        for (uint i = (uint)found; i + 1 < cnt; i++) {
            set.array_part()[i] = set.array_part()[i + 1];
        }
        set.array_part()[cnt - 1].set_undefined();
        set.array_used = (ushort)(cnt - 1);

        HString* size_key = builtin_intern_string(ctx.heap, "size");
        TVal size_val;
        size_val.set_fastint((long)set.array_used);
        set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// Set.prototype.clear() — ES6 §23.2.3.2
// ============================================================================
fn void builtin_set_proto_clear(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    uint cnt = set.array_used;
    for (uint i = 0; i < cnt; i++) {
        set.array_part()[i].set_undefined();
    }
    set.array_used = 0;

    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint(0);
    set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    ctx.result.set_undefined();
}

// ============================================================================
// Set.prototype.forEach(callbackfn[, thisArg]) — ES6 §23.2.3.6
// ============================================================================
fn void builtin_set_proto_forEach(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    if (ctx.argc < 1) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            HString* msg_str = builtin_intern_string(ctx.heap, "missing argument 0 when calling function forEach");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
        }
        ctx.result.set_undefined();
        return;
    }

    // Basic forEach without VM callback support — just returns undefined
    ctx.result.set_undefined();
}

// ============================================================================
// Set constructor registration
// ============================================================================

fn bool register_set_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Set prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.SET);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    heap.set_proto = proto;

    // Add .add(value) method
    if (!register_string_proto_method(proto, heap, "add", BUILTIN_SET_PROTO_ADD)) return false;
    // Add .has(value) method
    if (!register_string_proto_method(proto, heap, "has", BUILTIN_SET_PROTO_HAS)) return false;
    // Add .delete(value) method
    if (!register_string_proto_method(proto, heap, "delete", BUILTIN_SET_PROTO_DELETE)) return false;
    // Add .clear() method
    if (!register_string_proto_method(proto, heap, "clear", BUILTIN_SET_PROTO_CLEAR)) return false;
    // Add .keys() method
    if (!register_string_proto_method(proto, heap, "keys", BUILTIN_SET_PROTO_KEYS)) return false;
    // Add .values() method
    if (!register_string_proto_method(proto, heap, "values", BUILTIN_SET_PROTO_VALUES)) return false;
    // Add .entries() method
    if (!register_string_proto_method(proto, heap, "entries", BUILTIN_SET_PROTO_ENTRIES)) return false;
    // Add .forEach() method
    if (!register_string_proto_method(proto, heap, "forEach", BUILTIN_SET_PROTO_FOREACH)) return false;

    // Add .size property (will be updated on each mutation)
    HString* size_key = builtin_intern_string(heap, "size");
    TVal size_tv;
    size_tv.set_fastint(0);
    proto.put_prop(size_key, size_tv, hobject::PROP_FLAGS_NWC);

    // Create Set constructor as a proper function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_SET;

    // Set .constructor on Set.prototype
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Set.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Set.length
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    // Register Set constructor globally
    uint hash = heap.hash_string("Set");
    HString* existing = heap.str_table_lookup("Set", hash);
    HString* set_key;
    if (existing != null) {
        set_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Set", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        set_key = new_key;
    }
    TVal set_val;
    set_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, "Set");
    env::env_declare_nonenum(global_env, set_key, set_val);

    return true;
}
