/// Map constructor and Map.prototype methods.
module duktape::builtins;
import duktape::types;
import std::math;
import duktape::hstring;
import duktape::env;

import duktape::heap;
import duktape::hobject;

// Differs from === only in that NaN equals NaN.
// ============================================================================
fn bool same_value_zero(TVal a, TVal b) {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) && math::is_nan(b.get_number())) return true;
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING:    return a.get_heapptr() == b.get_heapptr();
            case OBJECT:    return a.get_heapptr() == b.get_heapptr();
            default: return false;
        }
    }
    if ((a.is_number() && b.is_fastint()) || (a.is_fastint() && b.is_number())) {
        double av = a.is_fastint() ? (double)a.get_fastint() : a.get_number();
        double bv = b.is_fastint() ? (double)b.get_fastint() : b.get_number();
        return av == bv;
    }
    return false;
}

// ============================================================================
// SameValue comparison (ES6 §7.2.9)
// Used by Object.is.
// Differs from SameValueZero in that +0 !== -0.
// ============================================================================
fn bool same_value(TVal a, TVal b) {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) && math::is_nan(b.get_number())) return true;
                // +0 !== -0: check if both are zero with different signs
                if (a.get_number() == 0.0 && b.get_number() == 0.0) {
                    return 1.0 / a.get_number() == 1.0 / b.get_number();
                }
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING:    return a.get_heapptr() == b.get_heapptr();
            case OBJECT:    return a.get_heapptr() == b.get_heapptr();
            default: return false;
        }
    }
    if ((a.is_number() && b.is_fastint()) || (a.is_fastint() && b.is_number())) {
        double av = a.is_fastint() ? (double)a.get_fastint() : a.get_number();
        double bv = b.is_fastint() ? (double)b.get_fastint() : b.get_number();
        return av == bv;
    }
    return false;
}

// ============================================================================
// Map helpers
// ============================================================================

fn HObject* check_map(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.MAP) return obj;
    }
    // TypeError
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Map.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
    }
    return null;
}

/// Find the index in array_part where a key matches. Returns -1 if not found.
/// Map entries are stored as [k0, v0, k1, v1, ...] in array_part.
fn int map_find_key(HObject* map, TVal key) {
    uint count = map.array_used;
    for (uint i = 0; i < count; i += 2) {
        if (same_value_zero(map.array_part()[i], key)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// Map constructor (ES6 §23.1.1)
// ============================================================================
fn void builtin_map(BuiltinContext* ctx) {
    HObject*? map_raw = ctx.heap.alloc_object(hobject::ObjClass.MAP);
    if (catch err = map_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* map = map_raw;

    // Set size property
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint(0);
    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // If iterable argument, populate map
    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.is_object() && arg.get_heapptr() != null) {
            HObject* iterable = (HObject*)arg.get_heapptr();
            // Simple case: array-like iterable with forEach/pairs
            // We handle the common case of array of [key, value] pairs
            uint len = array_get_length(iterable, ctx.heap);
            for (uint i = 0; i < len; i++) {
                TVal pair = array_get_elem(iterable, i, ctx.heap);
                if (pair.is_object() && pair.get_heapptr() != null) {
                    HObject* pair_obj = (HObject*)pair.get_heapptr();
                    TVal k = array_get_elem(pair_obj, 0, ctx.heap);
                    TVal v = array_get_elem(pair_obj, 1, ctx.heap);
                    // Call builtin_map_proto_set-style logic inline
                    int found = map_find_key(map, k);
                    if (found >= 0) {
                        map.array_part()[(uint)found + 1] = v;
                    } else {
                        uint cnt = map.array_used;
                        map.set_array_idx(cnt, k);
                        map.set_array_idx(cnt + 1, v);
                    }
                    // Update size
                    uint entry_count = map.array_used / 2;
                    size_val.set_fastint((long)entry_count);
                    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);
                }
            }
        }
    }

    ctx.result.set_object(map);
}

// ============================================================================
// Map.prototype.set(key, value) — ES6 §23.1.3.9
// ============================================================================
fn void builtin_map_proto_set(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    TVal value = ctx.regs[ctx.base_reg + 1];  // undefined if not provided

    int found = map_find_key(map, key);
    if (found >= 0) {
        map.array_part()[(uint)found + 1] = value;
    } else {
        uint cnt = map.array_used;
        map.set_array_idx(cnt, key);
        map.set_array_idx(cnt + 1, value);
    }

    // Update size property
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint((long)(map.array_used / 2));
    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // Return the map itself
    ctx.result.set_object(map);
}

// ============================================================================
// Map.prototype.get(key) — ES6 §23.1.3.6
// ============================================================================
fn void builtin_map_proto_get(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    if (found >= 0) {
        *ctx.result = map.array_part()[(uint)found + 1];
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// Map.prototype.has(key) — ES6 §23.1.3.7
// ============================================================================
fn void builtin_map_proto_has(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// Map.prototype.delete(key) — ES6 §23.1.3.3
// ============================================================================
fn void builtin_map_proto_delete(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    if (found >= 0) {
        uint cnt = map.array_used;
        // Shift elements down to fill the gap
        for (uint i = (uint)found; i + 2 < cnt; i++) {
            map.array_part()[i] = map.array_part()[i + 2];
        }
        // Clear the last two slots
        map.array_part()[cnt - 2].set_undefined();
        map.array_part()[cnt - 1].set_undefined();
        map.array_used = (ushort)(cnt - 2);

        HString* size_key = builtin_intern_string(ctx.heap, "size");
        TVal size_val;
        size_val.set_fastint((long)(map.array_used / 2));
        map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// Map.prototype.clear() — ES6 §23.1.3.1
// ============================================================================
fn void builtin_map_proto_clear(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }

    // Reset array_part
    uint cnt = map.array_used;
    for (uint i = 0; i < cnt; i++) {
        map.array_part()[i].set_undefined();
    }
    map.array_used = 0;

    // Update size
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.set_fastint(0);
    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    ctx.result.set_undefined();
}

// ============================================================================
// Map.prototype.forEach(callbackfn[, thisArg]) — ES6 §23.1.3.5
// ============================================================================
fn void builtin_map_proto_forEach(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }

    if (ctx.argc < 1) {
        // Missing callback throws TypeError
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

    // forEach with callback requires VM call mechanism (callback invocation).
    // For now, we validate the callback exists but don't invoke it.
    TVal callback = ctx.regs[ctx.base_reg];
    if (!(callback.is_object() && callback.get_heapptr() != null && ((HObject*)callback.get_heapptr()).flags.callable)) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            HString* msg_str = builtin_intern_string(ctx.heap, "object is not a function");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
        }
    }

    ctx.result.set_undefined();
}

// ============================================================================
// Map constructor registration
// ============================================================================

fn bool register_map_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Map prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.MAP);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    heap.map_proto = proto;

    // Add .set(key, value) method
    if (!register_string_proto_method(proto, heap, "set", BUILTIN_MAP_PROTO_SET)) return false;
    // Add .get(key) method
    if (!register_string_proto_method(proto, heap, "get", BUILTIN_MAP_PROTO_GET)) return false;
    // Add .has(key) method
    if (!register_string_proto_method(proto, heap, "has", BUILTIN_MAP_PROTO_HAS)) return false;
    // Add .delete(key) method
    if (!register_string_proto_method(proto, heap, "delete", BUILTIN_MAP_PROTO_DELETE)) return false;
    // Add .clear() method
    if (!register_string_proto_method(proto, heap, "clear", BUILTIN_MAP_PROTO_CLEAR)) return false;
    // Add .keys() method
    if (!register_string_proto_method(proto, heap, "keys", BUILTIN_MAP_PROTO_KEYS)) return false;
    // Add .values() method
    if (!register_string_proto_method(proto, heap, "values", BUILTIN_MAP_PROTO_VALUES)) return false;
    // Add .entries() method
    if (!register_string_proto_method(proto, heap, "entries", BUILTIN_MAP_PROTO_ENTRIES)) return false;
    // Add .forEach() method
    if (!register_string_proto_method(proto, heap, "forEach", BUILTIN_MAP_PROTO_FOREACH)) return false;

    // Add .size property (will be updated on each mutation)
    HString* size_key = builtin_intern_string(heap, "size");
    TVal size_tv;
    size_tv.set_fastint(0);
    proto.put_prop(size_key, size_tv, hobject::PROP_FLAGS_NWC);

    // Create Map constructor as a proper function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_MAP;

    // Set .constructor on Map.prototype
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Map.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Map.length
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    // Map.prototype's [[Prototype]] is set later (to Object.prototype)

    // Register Map constructor globally
    uint hash = heap.hash_string("Map");
    HString* existing = heap.str_table_lookup("Map", hash);
    HString* map_key;
    if (existing != null) {
        map_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Map", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        map_key = new_key;
    }
    TVal map_val;
    map_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, "Map");
    env::env_declare_nonenum(global_env, map_key, map_val);

    return true;
}
