/// Object constructor and Object.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::env;
import std::math;
import libc;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::vm;

// ============================================================================
// Object constructor builtins
// ============================================================================

/// ToObject — ES5 §9.9
/// Wraps primitives into proper exotic wrapper objects.
/// Returns the object directly for OBJECT type. Returns false for null/undefined.
/// Sets ctx.result and returns true on success. Returns false on allocation failure.
fn bool builtin_to_object(BuiltinContext* ctx, TVal val) {
    // Already an object
    if (val.is_object()) {
        *ctx.result = val;
        return true;
    }
    // null/undefined → caller should throw TypeError
    if (val.is_null() || val.is_undefined()) {
        return false;
    }
    // Boolean → Boolean exotic object
    if (val.is_boolean()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.BOOLEAN);
        if (catch err = obj_raw) return false;
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.bool_proto;
        (*obj.extra_ptr()).prim.primitive_value.set_boolean(val.get_boolean());
        ctx.result.set_object(obj);
        return true;
    }
    // Number/fastint → Number exotic object
    if (val.is_number() || val.is_fastint()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.NUMBER);
        if (catch err = obj_raw) return false;
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.number_proto;
        (*obj.extra_ptr()).prim.primitive_value = val;
        ctx.result.set_object(obj);
        return true;
    }
    // String → String exotic object with .length own property
    if (val.is_string()) {
        HString* prim_str = (HString*)val.get_heapptr();
        // Symbol → Symbol exotic object (must check before general string path)
        if (prim_str != null && prim_str.is_symbol()) {
            HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.SYMBOL);
            if (catch err = obj_raw) return false;
            HObject* obj = obj_raw;
            obj.prototype = ctx.heap.symbol_proto;
            (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
            ctx.result.set_object(obj);
            return true;
        }
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
        if (catch err = obj_raw) return false;
        HObject* obj = obj_raw;
        obj.flags.exotic_stringobj = true;
        obj.prototype = ctx.heap.string_proto;
        (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
        // Set .length own property (ES5 §15.5.5.1) — non-writable, non-enumerable, non-configurable
        HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)prim_str.char_length());
        obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
        // Indexed character properties are served lazily via the exotic_stringobj flag;
        // no per-character own properties are materialised at construction time.
        ctx.result.set_object(obj);
        return true;
    }
    return false;
}

/// Helper: build a property descriptor object for a data property
fn void builtin_build_data_descriptor(Heap* heap, HObject** out, TVal value, bool writable, bool enumerable, bool configurable) {
    HObject*? desc_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = desc_raw) { *out = null; return; }
    HObject* desc = desc_raw;
    desc.prototype = heap.object_proto;
    desc.put_prop(builtin_intern_string(heap, "value"), value, hobject::PROP_FLAGS_WEC);
    TVal w_tv; w_tv.set_boolean(writable);
    desc.put_prop(builtin_intern_string(heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC);
    TVal e_tv; e_tv.set_boolean(enumerable);
    desc.put_prop(builtin_intern_string(heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC);
    TVal c_tv; c_tv.set_boolean(configurable);
    desc.put_prop(builtin_intern_string(heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC);
    *out = desc;
}

/// Object() as function (ES5 §15.2.1.1) or new Object() as constructor (§15.2.2.1).
/// If value is null/undefined/absent, returns a new empty Object.
/// If value is already an Object, returns it.
/// Otherwise, wraps the primitive (boolean/number/string) in a wrapper object.
fn void builtin_object(BuiltinContext* ctx) {
    // Object() with no args — create and return new empty object
    // Both Object() function call and new Object() with no args.
    if (ctx.argc == 0) {
        // Object() with no args — create and return new empty object
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.object_proto;
        ctx.result.set_object(obj);
        return;
    }

    // Get the first argument
    TVal arg = ctx.regs[ctx.base_reg];

    // null/undefined/not supplied → new empty object
    if (arg.is_null() || arg.is_undefined()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.object_proto;
        ctx.result.set_object(obj);
        return;
    }

    // Already an object → return as-is
    if (arg.is_object()) {
        ctx.result.set_object(arg.get_heapptr());
        return;
    }

    // Primitive → create wrapper object (ToObject per ES5 §9.9)
    if (arg.is_boolean()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.BOOLEAN);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.bool_proto;
        (*obj.extra_ptr()).prim.primitive_value.set_boolean(arg.get_boolean());
        ctx.result.set_object(obj);
        return;
    }

    if (arg.is_number() || arg.is_fastint()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.NUMBER);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.number_proto;
        (*obj.extra_ptr()).prim.primitive_value = arg;
        ctx.result.set_object(obj);
        return;
    }

    if (arg.is_string()) {
        HString* prim_str = (HString*)arg.get_heapptr();
        // Symbol → Symbol exotic object (must check before general string path)
        if (prim_str != null && prim_str.is_symbol()) {
            HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.SYMBOL);
            if (catch err = obj_raw) {
                ctx.result.set_undefined();
                return;
            }
            HObject* obj = obj_raw;
            obj.prototype = ctx.heap.symbol_proto;
            (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
            ctx.result.set_object(obj);
            return;
        }
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.flags.exotic_stringobj = true;
        obj.prototype = ctx.heap.string_proto;
        (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
        // Set .length own property (ES5 §15.5.5.1)
        HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)prim_str.char_length());
        obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
        // Indexed character properties are served lazily via the exotic_stringobj flag;
        // no per-character own properties are materialised at construction time.
        ctx.result.set_object(obj);
        return;
    }

    // Fallback — new empty object
    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = obj_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* obj = obj_raw;
    obj.prototype = ctx.heap.object_proto;
    ctx.result.set_object(obj);
}

/// Object.keys(obj) — ES5 §15.2.3.14
/// Returns an array of an object's own enumerable property names.
fn void builtin_object_keys(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // ES5 §15.2.3.14 / ES2015 §19.1.2.16: throw TypeError for null/undefined,
    // use ToObject wrapper for primitives
    if (arg.is_null() || arg.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.keys called on non-object");
        return;
    }
    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        // ToObject wrapper for primitives
        if (!builtin_to_object(ctx, arg)) {
            ctx.result.set_undefined();
            return;
        }
        obj = (HObject*)ctx.result.get_heapptr();
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;

    // Collect keys into a temporary buffer, then write them into the result
    // array as named properties (using put_prop with string index keys) so
    // that hasOwnProperty("0"), getOwnPropertyDescriptor("0"), and
    // for-in + result[stringKey] all work correctly on the result array.

    // Maximum number of keys we'll collect
    uint max_keys = obj.prop_count + obj.array_size + 32;
    HString** key_buf = (HString**)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(max_keys * HString*::size));
    if (key_buf == null) { ctx.result.set_undefined(); return; }
    uint key_count = 0;
    defer ctx.heap.free_func(ctx.heap.heap_udata, key_buf);

    // STRING exotic: integer indices [0, clen) are enumerable own properties
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) {
            for (uint i = 0; i < prim.char_length(); i++) {
                HString* k = ctx.heap.int_to_hstring((long)i);
                if (k == null) { ctx.result.set_undefined(); return; }
                key_buf[key_count++] = k;
            }
        }
    }

    // Phase 1: integer-indexed named properties (sorted by numeric index)
    {
        uint int_count = 0;
        for (uint i = 0; i < obj.prop_count; i++) {
            if (obj.prop_key_at(i) != null && ((HString*)obj.prop_key_at(i)).is_arridx()) {
                int_count++;
            }
        }
        if (int_count > 0) {
            uint* sort_buf = (uint*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(int_count * 2 * 4));
            if (sort_buf != null) {
                uint p = 0;
                for (uint i = 0; i < obj.prop_count; i++) {
                    if (obj.prop_key_at(i) != null) {
                        HString* key = (HString*)obj.prop_key_at(i);
                        if (key.is_arridx()) {
                            sort_buf[p * 2] = key.array_index();
                            sort_buf[p * 2 + 1] = i;
                            p++;
                        }
                    }
                }
                // Insertion sort by arridx
                for (uint i = 1; i < int_count; i++) {
                    uint t0 = sort_buf[i * 2];
                    uint t1 = sort_buf[i * 2 + 1];
                    uint j = i;
                    while (j > 0 && sort_buf[(j - 1) * 2] > t0) {
                        sort_buf[j * 2] = sort_buf[(j - 1) * 2];
                        sort_buf[j * 2 + 1] = sort_buf[(j - 1) * 2 + 1];
                        j--;
                    }
                    sort_buf[j * 2] = t0;
                    sort_buf[j * 2 + 1] = t1;
                }
                for (uint i = 0; i < int_count; i++) {
                    uint si = sort_buf[i * 2 + 1];
                    if (obj.get_prop_flags(si).enumerable) {
                        HString* key = (HString*)obj.prop_key_at(si);
                        key_buf[key_count++] = key;
                    }
                }
                ctx.heap.free_func(ctx.heap.heap_udata, sort_buf);
            }
        }
    }
    // Phase 2: non-index named properties (insertion order)
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.get_prop_flags(i).enumerable && obj.prop_key_at(i) != null) {
            HString* key = (HString*)obj.prop_key_at(i);
            if (key.is_arridx()) continue;
            if (obj.flags.exotic_stringobj && (void*)key == (void*)ctx.heap.strs[heap::BuiltinStr.LENGTH]) continue;
            if (obj.flags.exotic_array && (void*)key == (void*)ctx.heap.strs[heap::BuiltinStr.LENGTH]) continue;
            key_buf[key_count++] = key;
        }
    }
    // Dense array indices (as strings)
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            if (obj.flags.exotic_array) {
                HString* ki = ctx.heap.int_to_hstring((long)i);
                if (ki != null && ki.is_arridx() && obj.find_prop_idx(ki) >= 0) continue;
            }
            HString* key = ctx.heap.int_to_hstring((long)i);
            if (key == null) { ctx.result.set_undefined(); return; }
            key_buf[key_count++] = key;
        }
    }

    // Write collected keys into the result array as named properties.
    // Using put_prop with string index keys ensures hasOwnProperty("0"),
    // getOwnPropertyDescriptor("0"), and for-in + result[stringKey] all work.
    for (uint i = 0; i < key_count; i++) {
        HString* idx_key = ctx.heap.int_to_hstring((long)i);
        if (idx_key == null) { ctx.result.set_undefined(); return; }
        TVal val_tv;
        val_tv.set_string(key_buf[i]);
        arr.put_prop(idx_key, val_tv, hobject::PROP_FLAGS_WEC);
    }

    // Set .length — Array.length is writable, non-enumerable, configurable (ES5 §15.4.5.1)
    TVal len_tv;
    len_tv.set_fastint((long)key_count);
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WC);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.getOwnPropertyNames — ES5 §15.2.3.4
// ============================================================================
/// Returns an array of all own property names (both enumerable and non-enumerable)
/// of the given object. Equivalent to Object.keys but without the enumerable filter.
fn void builtin_object_getOwnPropertyNames(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // ES5 §15.2.3.2 / ES2015: throw TypeError for null/undefined,
    // use ToObject wrapper for primitives
    if (arg.is_null() || arg.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.getOwnPropertyNames called on non-object");
        return;
    }

    // Handle lightfuncs: return ["name", "length"] as own property names
    if (arg.is_lightfunc()) {
        uint fn_idx = (uint)(usz)arg.get_heapptr();
        bool name_deleted = heap::lf_is_deleted(&ctx.heap.lf_deleted_props[0], fn_idx, 0);
        bool length_deleted = heap::lf_is_deleted(&ctx.heap.lf_deleted_props[0], fn_idx, 1);
        uint count = 0;
        if (!name_deleted) count++;
        if (!length_deleted) count++;

        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = arr_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* arr = arr_raw;
        arr.prototype = ctx.heap.array_proto;

        uint idx = 0;
        if (!name_deleted) {
            HString* name_str = builtin_intern_string(ctx.heap, "name");
            TVal name_tv; name_tv.set_string(name_str);
            array_set_elem(arr, idx, name_tv, ctx.heap);
            idx++;
        }
        if (!length_deleted) {
            HString* length_str = builtin_intern_string(ctx.heap, "length");
            TVal length_tv; length_tv.set_string(length_str);
            array_set_elem(arr, idx, length_tv, ctx.heap);
            idx++;
        }

        TVal len_tv; len_tv.set_fastint((long)count);
        arr.put_prop(builtin_intern_string(ctx.heap, "length"), len_tv, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(arr);
        return;
    }

    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        // ToObject wrapper for primitives — use proper exotic class
        if (!builtin_to_object(ctx, arg)) {
            ctx.result.set_undefined();
            return;
        }
        obj = (HObject*)ctx.result.get_heapptr();
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;

    // Collect keys into a temporary buffer, then write them into the result
    // array as named properties (using put_prop with string index keys) so
    // that hasOwnProperty("0"), getOwnPropertyDescriptor("0"), and
    // for-in + result[stringKey] all work correctly on the result array.

    uint max_keys = obj.prop_count + obj.array_size + 32;
    HString** key_buf = (HString**)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(max_keys * HString*::size));
    if (key_buf == null) { ctx.result.set_undefined(); return; }
    uint key_count = 0;
    defer ctx.heap.free_func(ctx.heap.heap_udata, key_buf);

    // STRING exotic: integer indices [0, clen) are own properties (enumerable by spec).
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) {
            for (uint i = 0; i < prim.char_length(); i++) {
                HString* k = ctx.heap.int_to_hstring((long)i);
                if (k == null) { ctx.result.set_undefined(); return; }
                key_buf[key_count++] = k;
            }
        }
    }

    // Phase 1: integer-indexed named properties (sorted by numeric index)
    {
        uint int_count = 0;
        for (uint i = 0; i < obj.prop_count; i++) {
            if (obj.prop_key_at(i) != null && ((HString*)obj.prop_key_at(i)).is_arridx()) {
                int_count++;
            }
        }
        if (int_count > 0) {
            uint* sort_buf = (uint*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(int_count * 2 * 4));
            if (sort_buf != null) {
                uint p = 0;
                for (uint i = 0; i < obj.prop_count; i++) {
                    if (obj.prop_key_at(i) != null) {
                        HString* key = (HString*)obj.prop_key_at(i);
                        if (key.is_arridx()) {
                            sort_buf[p * 2] = key.array_index();
                            sort_buf[p * 2 + 1] = i;
                            p++;
                        }
                    }
                }
                // Insertion sort by arridx
                for (uint i = 1; i < int_count; i++) {
                    uint t0 = sort_buf[i * 2];
                    uint t1 = sort_buf[i * 2 + 1];
                    uint j = i;
                    while (j > 0 && sort_buf[(j - 1) * 2] > t0) {
                        sort_buf[j * 2] = sort_buf[(j - 1) * 2];
                        sort_buf[j * 2 + 1] = sort_buf[(j - 1) * 2 + 1];
                        j--;
                    }
                    sort_buf[j * 2] = t0;
                    sort_buf[j * 2 + 1] = t1;
                }
                for (uint i = 0; i < int_count; i++) {
                    uint si = sort_buf[i * 2 + 1];
                    HString* key = (HString*)obj.prop_key_at(si);
                    if (key.is_symbol()) continue;  // Skip symbol keys
                    key_buf[key_count++] = key;
                }
                ctx.heap.free_func(ctx.heap.heap_udata, sort_buf);
            }
        }
    }
    // Phase 2: non-index named properties (insertion order)
    // ES5 §15.2.3.4: getOwnPropertyNames returns ONLY string keys (no symbols)
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i) != null) {
            HString* key = (HString*)obj.prop_key_at(i);
            if (key.is_arridx()) continue;
            if (key.is_symbol()) continue;  // Skip symbol keys
            key_buf[key_count++] = key;
        }
    }
    // Dense array indices (as strings)
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            HString* key = ctx.heap.int_to_hstring((long)i);
            if (key == null) { ctx.result.set_undefined(); return; }
            key_buf[key_count++] = key;
        }
    }

    // Write collected keys into the result array as named properties.
    for (uint i = 0; i < key_count; i++) {
        HString* idx_key = ctx.heap.int_to_hstring((long)i);
        if (idx_key == null) { ctx.result.set_undefined(); return; }
        TVal val_tv;
        val_tv.set_string(key_buf[i]);
        arr.put_prop(idx_key, val_tv, hobject::PROP_FLAGS_WEC);
    }

    // Set .length — Array.length is writable, non-enumerable, configurable (ES5 §15.4.5.1)
    TVal len_tv;
    len_tv.set_fastint((long)key_count);
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WC);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.getOwnPropertySymbols — ES6 §19.1.2.7
// ============================================================================
/// Returns an array of all symbol-keyed own properties of the given object.
fn void builtin_object_getOwnPropertySymbols(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // ES6 §19.1.2.7: throw TypeError for null/undefined,
    // use ToObject wrapper for primitives
    if (arg.is_null() || arg.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.getOwnPropertySymbols called on non-object");
        return;
    }

    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        // ToObject wrapper for primitives
        if (!builtin_to_object(ctx, arg)) {
            ctx.result.set_undefined();
            return;
        }
        obj = (HObject*)ctx.result.get_heapptr();
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;

    // Collect only symbol-keyed own properties
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i) != null) {
            HString* key = (HString*)obj.prop_key_at(i);
            if (key.is_symbol()) {
                TVal key_tv;
                key_tv.set_string(key);
                array_set_elem(arr, idx, key_tv, ctx.heap);
                idx++;
            }
        }
    }

    // Set .length — Array.length is writable, non-enumerable, configurable (ES5 §15.4.5.1)
    TVal len_tv;
    len_tv.set_fastint((long)idx);
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WC);
    ctx.result.set_object(arr);
}

// ============================================================================
// Reflect.ownKeys — ES6 §26.1.11
// ============================================================================
/// Returns an array of the target object's own property keys (strings and symbols).
/// Unlike Object.keys, does NOT filter by enumerable — returns ALL own keys.
/// Order: integer indices ascending, then string keys in insertion order, then symbol keys.
fn void builtin_reflect_ownKeys(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // ES6 §26.1.11: throw TypeError for null/undefined,
    // use ToObject wrapper for primitives
    if (arg.is_null() || arg.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Reflect.ownKeys called on non-object");
        return;
    }

    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        // ToObject wrapper for primitives
        if (!builtin_to_object(ctx, arg)) {
            ctx.result.set_undefined();
            return;
        }
        obj = (HObject*)ctx.result.get_heapptr();
    }

    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;

    // STRING exotic: integer indices [0, clen) are own properties
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) {
            for (uint i = 0; i < prim.char_length(); i++) {
                HString* k = ctx.heap.int_to_hstring((long)i);
                if (k == null) { ctx.result.set_undefined(); return; }
                TVal key_tv;
                key_tv.set_string(k);
                array_set_elem(arr, idx, key_tv, ctx.heap);
                idx++;
            }
        }
    }

    // Phase 1: integer-indexed named properties (sorted by numeric index)
    {
        uint int_count = 0;
        for (uint i = 0; i < obj.prop_count; i++) {
            if (obj.prop_key_at(i) != null) {
                HString* key = (HString*)obj.prop_key_at(i);
                if (key.is_arridx() && !key.is_symbol()) {
                    int_count++;
                }
            }
        }
        if (int_count > 0) {
            uint* sort_buf = (uint*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(int_count * 2 * 4));
            if (sort_buf != null) {
                uint p = 0;
                for (uint i = 0; i < obj.prop_count; i++) {
                    if (obj.prop_key_at(i) != null) {
                        HString* key = (HString*)obj.prop_key_at(i);
                        if (key.is_arridx() && !key.is_symbol()) {
                            sort_buf[p * 2] = key.array_index();
                            sort_buf[p * 2 + 1] = i;
                            p++;
                        }
                    }
                }
                // Insertion sort by arridx
                for (uint i = 1; i < int_count; i++) {
                    uint t0 = sort_buf[i * 2];
                    uint t1 = sort_buf[i * 2 + 1];
                    uint j = i;
                    while (j > 0 && sort_buf[(j - 1) * 2] > t0) {
                        sort_buf[j * 2] = sort_buf[(j - 1) * 2];
                        sort_buf[j * 2 + 1] = sort_buf[(j - 1) * 2 + 1];
                        j--;
                    }
                    sort_buf[j * 2] = t0;
                    sort_buf[j * 2 + 1] = t1;
                }
                for (uint i = 0; i < int_count; i++) {
                    uint si = sort_buf[i * 2 + 1];
                    HString* key = (HString*)obj.prop_key_at(si);
                    TVal key_tv;
                    key_tv.set_string(key);
                    array_set_elem(arr, idx, key_tv, ctx.heap);
                    idx++;
                }
                ctx.heap.free_func(ctx.heap.heap_udata, sort_buf);
            }
        }
    }
    // Phase 2: non-index string properties (insertion order)
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i) != null) {
            HString* key = (HString*)obj.prop_key_at(i);
            if (key.is_arridx() || key.is_symbol()) continue;
            TVal key_tv;
            key_tv.set_string(key);
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Phase 3: symbol properties (insertion order)
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i) != null) {
            HString* key = (HString*)obj.prop_key_at(i);
            if (key.is_symbol()) {
                TVal key_tv;
                key_tv.set_string(key);
                array_set_elem(arr, idx, key_tv, ctx.heap);
                idx++;
            }
        }
    }

    // Set .length — Array.length is writable, non-enumerable, configurable (ES5 §15.4.5.1)
    TVal len_tv;
    len_tv.set_fastint((long)idx);
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WC);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.getPrototypeOf — ES5 §15.2.3.2
// ============================================================================
/// Returns the [[Prototype]] of an object. Throws TypeError if argument is
/// not an object (null or undefined).
fn void builtin_object_getPrototypeOf(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        // Throw TypeError: Object.getPrototypeOf requires an argument
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.getPrototypeOf requires a value");
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object()) {
        // Throw TypeError for null/undefined/primitives
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.getPrototypeOf called on non-object");
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    HObject* proto = obj.prototype;
    if (proto == null) {
        ctx.result.set_null();
        return;
    }
    ctx.result.set_object(proto);
}

// ============================================================================
// Object.isExtensible — ES5 §15.2.3.13
// ============================================================================
/// Returns true if the object is extensible (can have new properties added).
/// Non-object arguments return true per ES5 §15.2.3.13.
fn void builtin_object_isExtensible(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // ES5 §15.2.3.13: non-object arguments return true (always extensible)
    if (!arg.is_object()) {
        ctx.result.set_boolean(true);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    ctx.result.set_boolean(obj.is_extensible());
}

// ============================================================================
// Object.preventExtensions — ES5 §15.2.3.10
// ============================================================================
/// Makes an object non-extensible (prevents adding new properties).
/// Returns the object itself. Throws TypeError if argument is not an object.
fn void builtin_object_preventExtensions(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // ES2015 §19.1.2.13: if Type(O) is not Object, return O.
    if (!arg.is_object()) {
        ctx.result[0] = arg;
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    obj.flags.extensible = false;
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.getOwnPropertyDescriptor — ES5 §15.2.3.3
// ============================================================================
/// Returns a property descriptor for an own property of the given object.
/// Throws TypeError if first argument is not an object.
fn void builtin_object_getOwnPropertyDescriptor(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg0 = ctx.regs[ctx.base_reg];

    // Handle lightfuncs: synthesize .name and .length property descriptors
    if (arg0.is_lightfunc()) {
        if (ctx.argc < 2) {
            ctx.result.set_undefined();
            return;
        }
        TVal key_val = ctx.regs[ctx.base_reg + 1];
        void* key = null;
        char[64] key_buf;
        if (key_val.is_string()) {
            key = key_val.get_heapptr();
        } else if (key_val.is_fastint()) {
            key = ctx.heap.int_to_hstring(key_val.get_fastint());
            if (key == null) { ctx.result.set_undefined(); return; }
        } else if (key_val.is_number()) {
            int len = libc::snprintf(&key_buf, 64, "%.17g", key_val.get_number());
            if (len < 0 || len >= 64) { ctx.result.set_undefined(); return; }
            key = ctx.heap.str_intern(key_buf[:len]);
            if (key == null) { ctx.result.set_undefined(); return; }
        } else {
            ctx.result.set_undefined();
            return;
        }

        uint fn_idx = (uint)(usz)arg0.get_heapptr();
        HString* key_hstr = (HString*)key;

        if (key_hstr.equals("name")) {
            if (heap::lf_is_deleted(&ctx.heap.lf_deleted_props[0], fn_idx, 0)) {
                ctx.result.set_undefined();
                return;
            }
            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
            if (meta.name.len > 0) {
                HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch err4 = desc_raw) { ctx.result.set_undefined(); return; }
                HObject* desc = desc_raw;
                desc.prototype = ctx.heap.object_proto;

                HString* name_val = builtin_intern_string(ctx.heap, meta.name);
                TVal name_tv; name_tv.set_string(name_val);
                desc.put_prop(builtin_intern_string(ctx.heap, "value"), name_tv, hobject::PROP_FLAGS_WEC);
                TVal w_tv; w_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC);
                TVal e_tv; e_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC);
                TVal c_tv; c_tv.set_boolean(true);
                desc.put_prop(builtin_intern_string(ctx.heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC);

                ctx.result.set_object(desc);
            } else {
                ctx.result.set_undefined();
            }
            return;
        } else if (key_hstr.equals("length")) {
            if (heap::lf_is_deleted(&ctx.heap.lf_deleted_props[0], fn_idx, 1)) {
                ctx.result.set_undefined();
                return;
            }
            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
            if (meta.arity >= 0) {
                HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch err5 = desc_raw) { ctx.result.set_undefined(); return; }
                HObject* desc = desc_raw;
                desc.prototype = ctx.heap.object_proto;

                TVal len_tv; len_tv.set_fastint((long)meta.arity);
                desc.put_prop(builtin_intern_string(ctx.heap, "value"), len_tv, hobject::PROP_FLAGS_WEC);
                TVal w_tv; w_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC);
                TVal e_tv; e_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC);
                TVal c_tv; c_tv.set_boolean(true);
                desc.put_prop(builtin_intern_string(ctx.heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC);

                ctx.result.set_object(desc);
            } else {
                ctx.result.set_undefined();
            }
            return;
        } else if (key_hstr.equals("prototype")) {
            // ES5 §15.3.5: Function.prototype property of constructors
            // {writable: false, enumerable: false, configurable: false}
            // Map lightfunc indices to their prototype objects from the heap.
            HObject* proto = null;
            switch (fn_idx) {
                case builtins::BUILTIN_TYPE_ERROR:      proto = ctx.heap.type_err_proto; break;
                case builtins::BUILTIN_RANGE_ERROR:     proto = ctx.heap.range_err_proto; break;
                case builtins::BUILTIN_REFERENCE_ERROR:  proto = ctx.heap.ref_err_proto; break;
                case builtins::BUILTIN_SYNTAX_ERROR:    proto = ctx.heap.syntax_err_proto; break;
                case builtins::BUILTIN_EVAL_ERROR:      proto = ctx.heap.eval_err_proto; break;
                case builtins::BUILTIN_URI_ERROR:       proto = ctx.heap.uri_err_proto; break;
                case builtins::BUILTIN_AGGREGATE_ERROR:  proto = ctx.heap.aggregate_err_proto; break;
                case builtins::BUILTIN_BOOLEAN:         proto = ctx.heap.bool_proto; break;
                default: break;
            }
            if (proto != null) {
                HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch err6 = desc_raw) { ctx.result.set_undefined(); return; }
                HObject* desc = desc_raw;
                desc.prototype = ctx.heap.object_proto;

                TVal proto_tv; proto_tv.set_object(proto);
                desc.put_prop(builtin_intern_string(ctx.heap, "value"), proto_tv, hobject::PROP_FLAGS_WEC);
                TVal w_tv; w_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC);
                TVal e_tv; e_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC);
                TVal c_tv; c_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC);

                ctx.result.set_object(desc);
            } else {
                ctx.result.set_undefined();
            }
            return;
        } else {
            ctx.result.set_undefined();
            return;
        }
    }

    if (!arg0.is_object()) {
        // ES5 §15.2.3.3: throw TypeError for null/undefined,
        // use ToObject wrapper for primitives (ES2015+)
        if (arg0.is_null() || arg0.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Object.getOwnPropertyDescriptor called on non-object");
            return;
        }
        if (!builtin_to_object(ctx, arg0)) {
            ctx.result.set_undefined();
            return;
        }
        arg0 = *ctx.result;
    }
    HObject* obj = (HObject*)arg0.get_heapptr();

    // Resolve the property key (second argument)
    if (ctx.argc < 2) {
        ctx.result.set_undefined();
        return;
    }
    TVal key_val = ctx.regs[ctx.base_reg + 1];
    // ES2015+ ToPropertyKey: if key is already a string (including symbols,
    // which we represent as STRING tag with is_symbol flag), use it directly.
    // Only convert objects (ToPrimitive) and primitives (ToString) otherwise.
    HString* key_hstr;
    if (key_val.is_string()) {
        // Includes both regular strings and symbols (STRING tag + is_symbol flag)
        key_hstr = (HString*)key_val.get_heapptr();
        if (key_hstr == null) {
            ctx.result.set_undefined();
            return;
        }
    } else if (key_val.is_object()) {
        key_hstr = builtin_to_string_vm(ctx, &key_val);
        if (key_hstr == null) {
            if (ctx.vm != null) {
                Vm* vm_ptr = (Vm*)ctx.vm;
                if (vm_ptr.throw_pending) {
                    ctx.should_throw = true;
                    ctx.throw_value = vm_ptr.throw_value;
                    return;
                }
            }
            ctx.result.set_undefined();
            return;
        }
    } else {
        // ToString for primitives (excluding symbols which were handled above)
        key_hstr = builtin_to_string(ctx.heap, &key_val);
        if (key_hstr == null) {
            ctx.result.set_undefined();
            return;
        }
    }
    void* key = key_hstr;

    // String exotic [[GetOwnProperty]] — ES5 §15.5.5.1
    // Numeric indices on String exotic objects return character descriptors.
    // This runs AFTER the default lookup as a fallback (step 1 of spec: try
    // default first, then synthesize if not found).

    // Look up own property (not prototype chain - don't fall through to array_part
    // unless the key matches a numeric index and this is an Array)
    int idx = obj.find_prop_idx(key);
    if (idx < 0) {
        // Special case: ARRAY exotic "length" property (spec §22.1.3 / §10.4.2).
        // The "length" property of an Array exotic is its `array_size` even when
        // array_size > array_part capacity (e.g. Array.prototype.length === 0).
        if (obj.get_class() == hobject::ObjClass.ARRAY) {
            HString* key_str = (HString*)key;
            if (key_str.equals("length")) {
                HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch err = desc_raw) {
                    ctx.result.set_undefined();
                    return;
                }
                HObject* desc = desc_raw;
                desc.prototype = ctx.heap.object_proto;

                HString* value_key = builtin_intern_string(ctx.heap, "value");
                TVal len_tv;
                len_tv.set_fastint((long)obj.array_size);
                desc.put_prop(value_key, len_tv, hobject::PROP_FLAGS_WEC);

                HString* writable_key = builtin_intern_string(ctx.heap, "writable");
                TVal w_tv;
                w_tv.set_boolean(true);
                desc.put_prop(writable_key, w_tv, hobject::PROP_FLAGS_WEC);

                HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
                TVal e_tv;
                e_tv.set_boolean(false);
                desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC);

                HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
                TVal c_tv;
                c_tv.set_boolean(false);
                desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC);

                ctx.result.set_object(desc);
                return;
            }
        }
        HString* key_str = (HString*)key;
        char[] kd = key_str.get_data();
        bool is_numeric = true;
        uint arr_idx = 0;
        for (usz i = 0; i < kd.len; i++) {
            if (kd[i] < '0' || kd[i] > '9') {
                is_numeric = false;
                break;
            }
            arr_idx = arr_idx * 10 + (uint)(kd[i] - '0');
        }
        if (is_numeric && kd.len > 0 && kd.len <= 10 && arr_idx < obj.array_size) {
            TVal av = obj.array_part()[arr_idx];
            if (av.is_undefined()) {
                ctx.result.set_undefined();
                return;
            }
            // Build a data descriptor
            HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (catch err5 = desc_raw) {
                ctx.result.set_undefined();
                return;
            }
            HObject* desc = desc_raw;
            desc.prototype = ctx.heap.object_proto;

            HString* value_key = builtin_intern_string(ctx.heap, "value");
            TVal vt;
            vt.set_string(key_str);
            // Actually set the array element value as the descriptor value
            TVal array_val = obj.array_part()[arr_idx];
            desc.put_prop(value_key, array_val, hobject::PROP_FLAGS_WEC);

            HString* writable_key = builtin_intern_string(ctx.heap, "writable");
            TVal w_tv;
            w_tv.set_boolean(true);
            desc.put_prop(writable_key, w_tv, hobject::PROP_FLAGS_WEC);

            HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
            TVal e_tv;
            e_tv.set_boolean(true);
            desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC);

            HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
            TVal c_tv;
            c_tv.set_boolean(true);
            desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC);

            ctx.result.set_object(desc);
            return;
        }

        // String exotic fallback — ES5 §15.5.5.1 step 3-4:
        // String indexed properties are non-writable, enumerable, non-configurable.
        if (obj.get_class() == hobject::ObjClass.STRING &&
            (*obj.extra_ptr()).prim.primitive_value.is_string() &&
            is_numeric && kd.len > 0 && kd.len <= 10) {
            HString* prim_str = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
            if (arr_idx < (ulong)prim_str.char_length()) {
                uint cp = prim_str.char_at((uint)arr_idx);
                char[4] cbuf;
                uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
                HString* char_str = ctx.heap.str_intern(cbuf[:cblen]);
                if (char_str != null) {
                    TVal char_tv; char_tv.set_string(char_str);
                    HObject* desc;
                    builtin_build_data_descriptor(ctx.heap, &desc, char_tv, false, true, false);
                    if (desc != null) {
                        ctx.result.set_object(desc);
                        return;
                    }
                }
            }
        }

        ctx.result.set_undefined();
        return;
    }

    hobject::PropValue* entry = &obj.prop_values()[idx];
    hobject::PropFlags entry_flags = obj.get_prop_flags((uint)idx);

    // Build the descriptor object
    HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err6 = desc_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* desc = desc_raw;
    desc.prototype = ctx.heap.object_proto;

    if (entry_flags.is_accessor) {
        // Accessor descriptor: { get, set, enumerable, configurable }
        HString* get_key = builtin_intern_string(ctx.heap, "get");
        desc.put_prop(get_key, hobject::hobject_access_getter(*entry), hobject::PROP_FLAGS_WEC);

        HString* set_key = builtin_intern_string(ctx.heap, "set");
        desc.put_prop(set_key, hobject::hobject_access_setter(*entry), hobject::PROP_FLAGS_WEC);

        HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
        TVal e_tv;
        e_tv.set_boolean(entry_flags.enumerable);
        desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC);

        HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
        TVal c_tv;
        c_tv.set_boolean(entry_flags.configurable);
        desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC);
    } else {
        // Data descriptor: { value, writable, enumerable, configurable }
        HString* value_key = builtin_intern_string(ctx.heap, "value");
        desc.put_prop(value_key, *entry, hobject::PROP_FLAGS_WEC);

        HString* writable_key = builtin_intern_string(ctx.heap, "writable");
        TVal w_tv;
        w_tv.set_boolean(entry_flags.writable);
        desc.put_prop(writable_key, w_tv, hobject::PROP_FLAGS_WEC);

        HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
        TVal e_tv;
        e_tv.set_boolean(entry_flags.enumerable);
        desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC);

        HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
        TVal c_tv;
        c_tv.set_boolean(entry_flags.configurable);
        desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC);
    }

    ctx.result.set_object(desc);
}

/// ES5 [[Get]] for descriptor field extraction — invokes getters per §8.10.5.
/// Returns true if the property exists, setting `out` to the result value.
fn bool desc_get(BuiltinContext* ctx, HObject* obj, hstring::HString* key, TVal* out) {
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto(key, true);
    if (res.kind == hobject::PropLookupKind.PROP_NOT_FOUND) {
        return false;
    }
    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        TVal getter = res.acc.accessor_fn;
        if (getter.is_undefined() || getter.is_null()) {
            out.set_undefined();
            return true;
        }
        if (ctx.heap.call_fn == null) {
            out.set_undefined();
            return true;
        }
        TVal this_tv;
        this_tv.set_object(obj);
        *out = ctx.heap.call_fn(ctx.vm, getter, null, 0, this_tv);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return false;
        }
        return true;
    }
    // PROP_DATA
    *out = res.data_val;
    return true;
}

/// Perform `[[Set]]` of `key` = `val` on `obj` with Throw=true (Object.assign
/// semantics, ES2015 §19.1.2.2).  Invokes setters when an accessor exists
/// (own or on prototype chain).  Throws TypeError when the target is
/// non-writable for a new/existing data property or non-extensible for a
/// new property.  Returns true on success, false on error (ctx->should_throw
/// is set in the latter case).
fn bool obj_assign_set(BuiltinContext* ctx, HObject* obj, hstring::HString* key, TVal* val) {
    // Step 1: own property
    int idx = obj.find_prop_idx((void*)key);
    if (idx >= 0) {
        hobject::PropFlags f = obj.get_prop_flags((uint)idx);
        if (f.is_accessor) {
            // Accessor — invoke the setter
            TVal setter = hobject::hobject_access_setter(obj.prop_values()[(uint)idx]);
            if (setter.is_undefined() || setter.is_null()) {
                // No setter — Set returns true (no-op, per spec).
                return true;
            }
            if (ctx.heap.call_fn == null || ctx.vm == null) {
                // VM call_fn unavailable — degrade silently (matches legacy behavior)
                return true;
            }
            TVal this_tv;
            this_tv.set_object(obj);
            TVal[1] args = { *val };
            ctx.heap.call_fn(ctx.vm, setter, &args[0], 1, this_tv);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return false;
            }
            return true;
        }
        if (!f.writable) {
            // Non-writable data property → throw TypeError
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot assign to read only property");
            return false;
        }
        // Writable data property — write value (preserve existing flags)
        TVal* entry = &obj.prop_values()[(uint)idx];
        ctx.heap.tval_copy_ref(entry, val);
        return true;
    }

    // Step 2: not an own property — check prototype chain for accessor
    hobject::AccessorResult acc = obj.find_accessor_proto((void*)key, false);
    if (acc.found) {
        TVal setter = acc.accessor_fn;
        if (setter.is_undefined() || setter.is_null()) {
            return true;
        }
        if (ctx.heap.call_fn == null || ctx.vm == null) { return true; }
        TVal this_tv;
        this_tv.set_object(obj);
        TVal[1] args = { *val };
        ctx.heap.call_fn(ctx.vm, setter, &args[0], 1, this_tv);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return false;
        }
        return true;
    }

    // Step 3: not on prototype chain — create new data property if extensible
    if (!obj.flags.extensible) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot add property to non-extensible object");
        return false;
    }
    obj.put_prop((void*)key, *val, hobject::PROP_FLAGS_WEC);
    return true;
}

/// ToPropertyDescriptor — ES5 §8.10.5
///
/// Parses a descriptor object into PropFlags + value (or getter/setter).
/// `out_flags` receives the flags to use for a newly created property.
/// `out_value` receives the data value (or getter/setter).
/// `is_accessor_out` is set true when the descriptor is an accessor descriptor.
/// Returns true on success, sets ctx.should_throw on error.
fn bool to_property_descriptor(BuiltinContext* ctx, HObject* desc_obj,
                               hobject::PropFlags* out_flags,
                               TVal* out_value, bool* is_accessor_out,
                               bool* is_generic_out, bool* has_any_out) {
    // Check the five possible descriptor fields.
    HString* enum_key   = builtin_intern_string(ctx.heap, "enumerable");
    HString* conf_key   = builtin_intern_string(ctx.heap, "configurable");
    HString* value_key  = builtin_intern_string(ctx.heap, "value");
    HString* writ_key   = builtin_intern_string(ctx.heap, "writable");
    HString* get_key    = builtin_intern_string(ctx.heap, "get");
    HString* set_key    = builtin_intern_string(ctx.heap, "set");

    if (enum_key   == null) return false;
    if (conf_key   == null) return false;
    if (value_key  == null) return false;
    if (writ_key   == null) return false;
    if (get_key    == null) return false;
    if (set_key    == null) return false;

    TVal enum_val;   bool has_enumerable   = false;
    if (desc_get(ctx, desc_obj, enum_key, &enum_val)) {
        has_enumerable = true; }
    TVal conf_val;   bool has_configurable = false;
    if (desc_get(ctx, desc_obj, conf_key, &conf_val)) {
        has_configurable = true; }
    TVal value_val;  bool has_value        = false;
    if (desc_get(ctx, desc_obj, value_key, &value_val)) {
        has_value = true; }
    TVal writ_val;   bool has_writable     = false;
    if (desc_get(ctx, desc_obj, writ_key, &writ_val)) {
        has_writable = true; }
    TVal get_val;    bool has_get          = false;
    if (desc_get(ctx, desc_obj, get_key, &get_val)) {
        has_get = true; }
    TVal set_val;    bool has_set          = false;
    if (desc_get(ctx, desc_obj, set_key, &set_val)) {
        has_set = true; }

    // Step 16: If both data and accessor fields present, throw TypeError
    if ((has_value || has_writable) && (has_get || has_set)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Invalid property descriptor — cannot have both data and accessor fields");
        return false;
    }

    // Validate getter/setter are callable or undefined
    if (has_get && !get_val.is_undefined()) {
        if (!get_val.is_object() && !get_val.is_lightfunc()) {
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Getter must be callable or undefined");
            return false;
        }
        HObject* fn_obj = (HObject*)get_val.get_heapptr();
        if (!fn_obj.is_callable()) {
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Getter must be callable");
            return false;
        }
    }
    if (has_set && !set_val.is_undefined()) {
        if (!set_val.is_object() && !set_val.is_lightfunc()) {
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Setter must be callable or undefined");
            return false;
        }
        HObject* fn_obj = (HObject*)set_val.get_heapptr();
        if (!fn_obj.is_callable()) {
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Setter must be callable");
            return false;
        }
    }

    bool is_accessor = has_get || has_set;

    // Build output flags
    hobject::PropFlags flags;
    flags.is_accessor = is_accessor;

    // Set defaults: if descriptor doesn't mention a field, preserve existing
    // (will be handled by caller). Here we set sentinel values:
    // For a new property, absent fields default to false.
    if (has_enumerable) {
        flags.enumerable = builtin_to_boolean(&enum_val);
    } else {
        flags.enumerable = false;
    }

    if (has_configurable) {
        flags.configurable = builtin_to_boolean(&conf_val);
    } else {
        flags.configurable = false;
    }

    if (has_writable && !is_accessor) {
        flags.writable = builtin_to_boolean(&writ_val);
    } else if (!is_accessor) {
        flags.writable = false;
    }

    if (is_accessor) {
        flags.writable = false;
        if (has_get) {
            out_value[0] = get_val;
        } else {
            out_value[0] = types::make_undefined();
        }
        if (has_set) {
            out_value[1] = set_val;
        } else {
            out_value[1] = types::make_undefined();
        }
    } else {
        if (has_value) {
            out_value[0] = value_val;
        } else {
            out_value[0] = types::make_undefined();
        }
        out_value[1] = types::make_undefined(); // not used for data
    }

    out_flags[0] = flags;
    is_accessor_out[0] = is_accessor;
    if (is_generic_out != null) {
        is_generic_out[0] = !is_accessor && !has_value && !has_writable;
    }
    if (has_any_out != null) {
        has_any_out[0] = has_enumerable || has_configurable || has_value || has_writable || has_get || has_set;
    }
    return true;
}

/// Object.defineProperty — ES5 §15.2.3.6
fn void builtin_object_defineProperty(BuiltinContext* ctx) {
    // Step 1: Check first arg is Object
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg0 = ctx.regs[ctx.base_reg];
    if (!arg0.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.defineProperty called on non-object");
        return;
    }
    HObject* obj = (HObject*)arg0.get_heapptr();

    // Step 2: Convert property key to string
    if (ctx.argc < 2) {
        ctx.result.set_undefined();
        return;
    }
    TVal key_val = ctx.regs[ctx.base_reg + 1];
    HString* key_hstr = builtin_to_string_vm(ctx, &key_val);
    if (key_hstr == null) { ctx.result.set_undefined(); return; }
    void* key = key_hstr;

    // Step 3: Check Attributes is Object
    if (ctx.argc < 3) {
        ctx.result.set_undefined();
        return;
    }
    TVal attr_val = ctx.regs[ctx.base_reg + 2];
    if (!attr_val.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.defineProperty called with non-object descriptor");
        return;
    }
    HObject* desc_obj = (HObject*)attr_val.get_heapptr();

    // Step 4: ToPropertyDescriptor
    hobject::PropFlags desc_flags;
    TVal[2] desc_vals;  // [0]=value/getter, [1]=setter (unused for data)
    bool is_accessor;
    bool is_generic = false;
    bool has_any_field = false;
    if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_accessor, &is_generic, &has_any_field)) {
        if (ctx.should_throw) return;
        ctx.result.set_undefined();
        return;
    }

    // ES5 §15.4.5.1 ArraySetLength: full validation when defining 'length' on an Array.
    // Per the spec, this must happen BEFORE the general [[DefineOwnProperty]] path.
    // Array length is always non-configurable and non-writable.
    bool is_array_length = obj.get_class() == hobject::ObjClass.ARRAY
        && key_hstr.equals("length");
    uint arr_new_len = 0;
    bool arr_has_new_len = false;
    if (is_array_length) {
        // Check for accessor descriptor on length — reject (length is always data)
        HString* get_k = builtin_intern_string(ctx.heap, "get");
        HString* set_k = builtin_intern_string(ctx.heap, "set");
        bool has_get = (get_k != null) && desc_obj.find_prop_idx(get_k) >= 0;
        bool has_set = (set_k != null) && desc_obj.find_prop_idx(set_k) >= 0;
        if (has_get || has_set) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine property: length");
            return;
        }

        // ES5 §15.4.5.1 step 3.a: Reject if configurable is explicitly set to true
        HString* conf_k = builtin_intern_string(ctx.heap, "configurable");
        bool has_conf = (conf_k != null) && desc_obj.find_prop_idx(conf_k) >= 0;
        if (has_conf && desc_flags.configurable) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine property: length");
            return;
        }

        // ES5 §15.4.5.1 step 3.b: Reject if writable is explicitly set to false
        HString* writ_k = builtin_intern_string(ctx.heap, "writable");
        bool has_wrt = (writ_k != null) && desc_obj.find_prop_idx(writ_k) >= 0;
        if (has_wrt && !desc_flags.writable) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine property: length");
            return;
        }

        // Array length is non-configurable and non-enumerable; reject attempts
        // to change its enumerability (e.g. { enumerable: true }).
        HString* enum_k = builtin_intern_string(ctx.heap, "enumerable");
        bool has_enum = (enum_k != null) && desc_obj.find_prop_idx(enum_k) >= 0;
        if (has_enum && desc_flags.enumerable) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine property: length");
            return;
        }

        // ES5 §15.4.5.1 step 2: If 'value' is present, validate it.
        HString* val_k = builtin_intern_string(ctx.heap, "value");
        bool has_value_in_desc = (val_k != null) && desc_obj.find_prop_idx(val_k) >= 0;
        if (has_value_in_desc) {
            TVal new_len_val = desc_vals[0];

            // ES5 §15.4.5.1 step 3.c: ToNumber then ToUint32. Use the VM-aware
            // helper so object values are converted via ToPrimitive (valueOf/toString).
            double num = builtin_to_number_vm(ctx, &new_len_val);
            if (ctx.should_throw) {
                return;
            }

            // ToUint32: reject NaN, ±∞, negative, non-integer, > 2^32-1
            if (num != num || num < 0.0 || num > 4294967295.0 || num != math::floor(num)) {
                builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid array length");
                return;
            }

            uint new_len = (uint)num;
            arr_new_len = new_len;
            arr_has_new_len = true;

            // ES5 §15.4.5.1 step 3.l: truncate elements when new < old
            uint old_len = array_get_length(obj, ctx.heap);
            if (new_len < old_len) {
                for (uint di = old_len; di > new_len; di--) {
                    array_delete_elem(obj, di - 1, ctx.heap);
                }
            }
        }
    }
    // Array length: return early. The only valid operation is changing the value.
    // configurable/writable are rejected above, and enumerable cannot be changed.
    if (is_array_length) {
        if (arr_has_new_len) {
            array_set_length(obj, arr_new_len, ctx.heap);
        }
        ctx.result.set_object(obj);
        return;
    }

    // Step 5: [[DefineOwnProperty]]
    // Check if property already exists
    int existing_idx = obj.find_prop_idx(key);

    // Dense array promotion: if the key is a valid array index and the element
    // exists in the dense array part but not in named props, promote it with
    // WEC flags so the normal [[DefineOwnProperty]] update path handles it.
    if (existing_idx < 0 && ((HString*)key).is_arridx()) {
        uint arr_idx = ((HString*)key).array_index();
        TVal* ap = obj.array_part();
        if (ap != null && arr_idx < obj.array_size) {
            TVal arr_val = ap[arr_idx];
            if (!arr_val.is_undefined()) {
                obj.put_prop((void*)key, arr_val, hobject::PROP_FLAGS_WEC);
                existing_idx = obj.find_prop_idx(key);
            }
        }
    }

    // ES5 §8.12.9 step 1: If every field in Desc is absent, return true.
    // This short-circuit only applies when the property already exists;
    // for a new property we must still create it (with all-false defaults).
    if (!has_any_field && existing_idx >= 0) {
        ctx.result.set_object(obj);
        return;
    }
    if (existing_idx < 0) {
        // Property doesn't exist — check extensibility
        if (!obj.flags.extensible) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot define property on a non-extensible object");
            return;
        }
        // Create new property
        if (is_accessor) {
            // Accessor property — set value as getter placeholder
            obj.put_prop(key, desc_vals[0], desc_flags);
            int idx = obj.find_prop_idx(key);
            if (idx >= 0) {
                obj.prop_values()[idx] = hobject::hobject_create_accessors(ctx.heap, desc_vals[0], desc_vals[1]);
            }
        } else {
            obj.put_prop(key, desc_vals[0], desc_flags);
        }
    } else {
        // Property exists — validate changes per ES5 §8.12.9
        hobject::PropValue* current = &obj.prop_values()[existing_idx];
        hobject::PropFlags cur_flags = obj.get_prop_flags((uint)existing_idx);
        TVal cur_value = *current;

        // Check if descriptor is empty (generic, no fields)
        bool has_value_field   = (ctx.regs[ctx.base_reg + 2].is_object()); // already validated
        // We've already extracted descriptor fields above, so check what was present

        // Check configurable constraint — ES5 §8.12.9 step 8
        if (!cur_flags.configurable) {
            bool reject = false;
            // Only reject if the field is actually present in the descriptor AND differs
            bool desc_has_conf = false;
            bool desc_has_enum = false;
            HString* tmp_conf_k = builtin_intern_string(ctx.heap, "configurable");
            HString* tmp_enum_k = builtin_intern_string(ctx.heap, "enumerable");
            if (tmp_conf_k != null) desc_has_conf = desc_obj.find_prop_idx(tmp_conf_k) >= 0;
            if (tmp_enum_k != null) desc_has_enum = desc_obj.find_prop_idx(tmp_enum_k) >= 0;
            if (desc_has_conf && desc_flags.configurable != cur_flags.configurable) reject = true;
            if (desc_has_enum && desc_flags.enumerable != cur_flags.enumerable) reject = true;
            if (reject) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine non-configurable property");
                return;
            }
        }

        // Update the property
        // ES5 §8.12.9: Only reject type changes when the descriptor explicitly
        // declares a different type. Generic descriptors (no value/writable/get/set)
        // should NOT trigger a type change — they only update enumerable/configurable.
        bool explicit_type_change = is_accessor != cur_flags.is_accessor && !is_generic;
        if (explicit_type_change) {
            // Changing from data to accessor or vice versa on non-configurable
            if (!cur_flags.configurable) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot change property type from data to accessor or vice versa on non-configurable property");
                return;
            }
            // Type change allowed only if configurable
        }

        if (is_generic) {
            // ES5 §8.12.9: Generic descriptor — only update enumerable/configurable.
            // Do NOT change value, writable, is_accessor, getter, or setter.
            HString* enum_k = builtin_intern_string(ctx.heap, "enumerable");
            HString* conf_k = builtin_intern_string(ctx.heap, "configurable");
            bool has_enum_in_desc = (enum_k != null) && desc_obj.find_prop_idx(enum_k) >= 0;
            bool has_conf_in_desc = (conf_k != null) && desc_obj.find_prop_idx(conf_k) >= 0;
            // ES5 §8.12.9 step 7: non-configurable property — reject if descriptor
            // tries to set configurable:true, or changes enumerable.
            if (!cur_flags.configurable) {
                if (has_conf_in_desc && desc_flags.configurable) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine property: configurable");
                    return;
                }
                if (has_enum_in_desc && desc_flags.enumerable != cur_flags.enumerable) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine property: enumerable");
                    return;
                }
            }
            if (has_enum_in_desc) cur_flags.enumerable   = desc_flags.enumerable;
            if (has_conf_in_desc) cur_flags.configurable = desc_flags.configurable;
            obj.set_prop_flags((uint)existing_idx, cur_flags);
        } else if (is_accessor) {
            // Update accessor fields
            bool has_get_in_desc = false;
            bool has_set_in_desc = false;
            bool has_enum_in_desc = false;
            bool has_conf_in_desc = false;
            // Re-check which fields were in the descriptor
            HString* get_k = builtin_intern_string(ctx.heap, "get");
            HString* set_k = builtin_intern_string(ctx.heap, "set");
            HString* enum_k = builtin_intern_string(ctx.heap, "enumerable");
            HString* conf_k = builtin_intern_string(ctx.heap, "configurable");
            if (get_k != null) has_get_in_desc = desc_obj.find_prop_idx(get_k) >= 0;
            if (set_k != null) has_set_in_desc = desc_obj.find_prop_idx(set_k) >= 0;
            if (enum_k != null) has_enum_in_desc = desc_obj.find_prop_idx(enum_k) >= 0;
            if (conf_k != null) has_conf_in_desc = desc_obj.find_prop_idx(conf_k) >= 0;

            // ES5 §8.12.9 step 11: non-configurable accessor — reject if get/set changes
            // Only valid when the existing property is already an accessor.
            if (!cur_flags.configurable && cur_flags.is_accessor) {
                if (has_get_in_desc && !same_value(hobject::hobject_access_getter(*current), desc_vals[0])) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot change getter of non-configurable accessor property");
                    return;
                }
                if (has_set_in_desc && !same_value(hobject::hobject_access_setter(*current), desc_vals[1])) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot change setter of non-configurable accessor property");
                    return;
                }
            }

            if (!cur_flags.is_accessor) {
                // Data → accessor conversion: create a new GetterSetter cell.
                // *current holds a data value (number, string, etc.) — calling
                // hobject_set_access_getter on it would crash on slot.get_heapptr().
                // Decref the old data value (may be a heap pointer like a string)
                // and replace with a fresh GS cell.
                ctx.heap.decref_tval(current);
                *current = hobject::hobject_create_accessors(ctx.heap, desc_vals[0], desc_vals[1]);
            } else {
                // Update existing accessor: modify the GS cell in-place.
                if (has_get_in_desc) hobject::hobject_set_access_getter(*current, desc_vals[0], ctx.heap);
                if (has_set_in_desc) hobject::hobject_set_access_setter(*current, desc_vals[1], ctx.heap);
            }

            // Update flags — only overwrite fields present in descriptor
            cur_flags.is_accessor = true;
            if (has_enum_in_desc) cur_flags.enumerable   = desc_flags.enumerable;
            if (has_conf_in_desc) cur_flags.configurable = desc_flags.configurable;
            obj.set_prop_flags((uint)existing_idx, cur_flags);
        } else {
            // Update data property
            bool has_val_in_desc = false;
            bool has_wrt_in_desc = false;
            bool has_enum_in_desc = false;
            bool has_conf_in_desc = false;
            HString* val_k  = builtin_intern_string(ctx.heap, "value");
            HString* writ_k = builtin_intern_string(ctx.heap, "writable");
            HString* enum_k = builtin_intern_string(ctx.heap, "enumerable");
            HString* conf_k = builtin_intern_string(ctx.heap, "configurable");
            if (val_k  != null) has_val_in_desc  = desc_obj.find_prop_idx(val_k)  >= 0;
            if (writ_k != null) has_wrt_in_desc  = desc_obj.find_prop_idx(writ_k) >= 0;
            if (enum_k != null) has_enum_in_desc = desc_obj.find_prop_idx(enum_k) >= 0;
            if (conf_k != null) has_conf_in_desc = desc_obj.find_prop_idx(conf_k) >= 0;

            // Check writable → non-writable transition when non-configurable
            if (!cur_flags.configurable && !cur_flags.writable && has_wrt_in_desc && desc_flags.writable) {
                // Cannot change non-writable to writable on non-configurable
                builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot change writable attribute of non-configurable property from false to true");
                return;
            }

            if (has_val_in_desc) {
                // ES5 §8.12.9 step 9: If non-configurable and non-writable, reject only if
                // the new value differs from the current value (SameValue check).
                if (!cur_flags.configurable && !cur_flags.writable) {
                    if (!same_value(cur_value, desc_vals[0])) {
                        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot change value of non-writable non-configurable property");
                        return;
                    }
                }
                *current = desc_vals[0];
            }

            if (has_wrt_in_desc)  cur_flags.writable     = desc_flags.writable;
            if (has_enum_in_desc) cur_flags.enumerable   = desc_flags.enumerable;
            if (has_conf_in_desc) cur_flags.configurable = desc_flags.configurable;
            // Clear is_accessor when converting accessor→data (ES5 §8.12.9 step 9)
            cur_flags.is_accessor = false;
            obj.set_prop_flags((uint)existing_idx, cur_flags);
        }
    }

    // Step 6: Return O
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.defineProperties — ES5 §15.2.3.7
// ============================================================================
/// Define multiple properties on an object from a properties object.
fn void builtin_object_defineProperties(BuiltinContext* ctx) {
    // Step 1: Check first arg is Object
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg0 = ctx.regs[ctx.base_reg];
    if (!arg0.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.defineProperties called on non-object");
        return;
    }
    HObject* obj = (HObject*)arg0.get_heapptr();

    // Step 2: If Properties is undefined, return O; if not Object, throw TypeError.
    if (ctx.argc < 2) {
        ctx.result.set_object(obj);
        return;
    }
    TVal props_val = ctx.regs[ctx.base_reg + 1];
    if (props_val.is_undefined()) {
        // ES5 §15.2.3.7 step 1: undefined Properties is a no-op
        ctx.result.set_object(obj);
        return;
    }
    if (!props_val.is_object()) {
        // ES5 §15.2.3.7 step 2: Type(Properties) is not Object → TypeError
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.defineProperties called on non-object Properties");
        return;
    }
    HObject* props = (HObject*)props_val.get_heapptr();

    // Step 4: For each key, get descriptor and call DefinePropertyOrThrow
    // Collect keys first in case properties are modified during iteration
    HString*[256] keys_arr;
    uint keys_count = 0;
    for (uint i = 0; i < props.prop_count && keys_count < 256; i++) {
        if (props.prop_key_at(i) != null && props.get_prop_flags(i).enumerable) {
            keys_arr[keys_count] = (HString*)props.prop_key_at(i);
            keys_count++;
        }
    }

    for (uint k = 0; k < keys_count; k++) {
        HString* p_key = keys_arr[k];
        // Get descObj = props.[[GetOwnProperty]](p_key).value
        PropValue*? prop_entry = props.find_prop(p_key);
        if (try pe = prop_entry) {
            TVal desc_obj_val = *pe;

            // ToPropertyDescriptor(desc_obj)
            if (!desc_obj_val.is_object()) {
                // TypeError — property descriptor must be an object
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                char[128] msg_buf;
                int msg_len = libc::snprintf(&msg_buf, 128, "Property descriptor for '%s' must be an object", p_key.get_data());
                HString* msg_str = builtin_intern_string(ctx.heap, msg_buf[:msg_len]);
                if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.set_string(msg_str);
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
                return;
            }
            HObject* desc_obj = (HObject*)desc_obj_val.get_heapptr();

            // Convert to property descriptor
            hobject::PropFlags desc_flags;
            TVal[2] desc_vals;
            bool is_accessor;
            if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_accessor, null, null)) {
                if (ctx.should_throw) return;
                ctx.result.set_undefined();
                return;
            }

            // [[DefineOwnProperty]]
            int existing_idx = obj.find_prop_idx(p_key);
            if (existing_idx < 0) {
                if (!obj.flags.extensible) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (catch err3 = err_raw) { ctx.result.set_undefined(); return; }
                    HObject* err = err_raw;
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    HString* msg_str = builtin_intern_string(ctx.heap, "Cannot define property on a non-extensible object");
                    if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                    TVal msg_tv;
                    msg_tv.set_string(msg_str);
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                    return;
                }
                if (is_accessor) {
                    obj.put_prop(p_key, desc_vals[0], desc_flags);
                    int idx = obj.find_prop_idx(p_key);
                    if (idx >= 0) {
                        obj.prop_values()[idx] = hobject::hobject_create_accessors(ctx.heap, desc_vals[0], desc_vals[1]);
                    }
                } else {
                    obj.put_prop(p_key, desc_vals[0], desc_flags);
                }
            } else {
                // Property exists — validate changes
                hobject::PropValue* current = &obj.prop_values()[existing_idx];
                hobject::PropFlags cur_flags = obj.get_prop_flags((uint)existing_idx);
                // ES5 §8.12.9 step 8: Reject changes to non-configurable property
                if (!cur_flags.configurable) {
                    bool reject = false;
                    bool desc_has_conf = has_configurable_in_desc_helper(ctx.heap, desc_obj);
                    bool desc_has_enum = has_enumerable_in_desc_helper(ctx.heap, desc_obj);
                    if (desc_has_conf && desc_flags.configurable != cur_flags.configurable) reject = true;
                    if (desc_has_enum && desc_flags.enumerable != cur_flags.enumerable) reject = true;

                    // ES5 §8.12.9 step 12: Reject type changes on non-configurable
                    bool has_any_data = has_value_in_desc_helper(ctx.heap, desc_obj) || has_writable_in_desc_helper(ctx.heap, desc_obj);
                    bool has_any_access = has_get_in_desc_helper(ctx.heap, desc_obj) || has_set_in_desc_helper(ctx.heap, desc_obj);
                    bool is_generic_desc = !has_any_data && !has_any_access;
                    if (!is_generic_desc) {
                        bool new_is_accessor = has_any_access;
                        if (new_is_accessor != cur_flags.is_accessor) reject = true;
                    }

                    // ES5 §8.12.9 step 13.a: Reject writable false→true on non-configurable
                    if (!has_any_access && !cur_flags.writable) {
                        if (has_writable_in_desc_helper(ctx.heap, desc_obj) && desc_flags.writable) reject = true;
                    }

                    // ES5 §8.12.9 step 13.a.ii: Reject value change on non-configurable+non-writable
                    if (!has_any_access && !cur_flags.configurable && !cur_flags.writable) {
                        if (has_value_in_desc_helper(ctx.heap, desc_obj) && !same_value(*current, desc_vals[0])) reject = true;
                    }

                    // ES5 §8.12.9 step 13.b: Reject accessor get/set change on non-configurable
                    if (has_any_access && cur_flags.is_accessor) {
                        if (has_get_in_desc_helper(ctx.heap, desc_obj)) {
                            TVal cur_get = hobject::hobject_access_getter(*current);
                            if (!same_value(cur_get, desc_vals[0])) reject = true;
                        }
                        if (has_set_in_desc_helper(ctx.heap, desc_obj)) {
                            TVal cur_set = hobject::hobject_access_setter(*current);
                            if (!same_value(cur_set, desc_vals[1])) reject = true;
                        }
                    }

                    if (reject) {
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (catch err4 = err_raw) { ctx.result.set_undefined(); return; }
                        HObject* err = err_raw;
                        err.prototype = ctx.heap.type_err_proto;
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot redefine non-configurable property");
                        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                        TVal msg_tv;
                        msg_tv.set_string(msg_str);
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                        ctx.should_throw = true;
                        ctx.throw_value.set_object(err);
                        return;
                    }
                }

                if (is_accessor) {
                    if (!cur_flags.is_accessor) {
                        // Data → accessor conversion: create a new GetterSetter cell.
                        // *current holds a data value (number, string, etc.) — calling
                        // hobject_set_access_getter on it would crash on slot.get_heapptr().
                        // Decref the old data value and replace with a fresh GS cell.
                        ctx.heap.decref_tval(current);
                        *current = hobject::hobject_create_accessors(ctx.heap, desc_vals[0], desc_vals[1]);
                    } else {
                        // Update existing accessor: modify the GS cell in-place.
                        if (has_get_in_desc_helper(ctx.heap, desc_obj)) hobject::hobject_set_access_getter(*current, desc_vals[0], ctx.heap);
                        if (has_set_in_desc_helper(ctx.heap, desc_obj)) hobject::hobject_set_access_setter(*current, desc_vals[1], ctx.heap);
                    }
                    cur_flags.is_accessor = true;
                    if (has_enumerable_in_desc_helper(ctx.heap, desc_obj)) cur_flags.enumerable = desc_flags.enumerable;
                    if (has_configurable_in_desc_helper(ctx.heap, desc_obj)) cur_flags.configurable = desc_flags.configurable;
                    obj.set_prop_flags((uint)existing_idx, cur_flags);
                } else {
                    // Basic data property update
                    if (has_value_in_desc_helper(ctx.heap, desc_obj)) {
                        // ES5 §8.12.9 step 9: If non-configurable and non-writable, reject only if
                        // the new value differs from the current value (SameValue check).
                        if (!cur_flags.configurable && !cur_flags.writable) {
                            if (!same_value(*current, desc_vals[0])) {
                                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                                if (catch err5 = err_raw) { ctx.result.set_undefined(); return; }
                                HObject* err = err_raw;
                                err.prototype = ctx.heap.type_err_proto;
                                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                                HString* msg_str = builtin_intern_string(ctx.heap, "Cannot change value of non-writable non-configurable property");
                                if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                                TVal msg_tv;
                                msg_tv.set_string(msg_str);
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                                ctx.should_throw = true;
                                ctx.throw_value.set_object(err);
                                return;
                            }
                        }
                        *current = desc_vals[0];
                    }
                    if (has_writable_in_desc_helper(ctx.heap, desc_obj)) cur_flags.writable = desc_flags.writable;
                    if (has_enumerable_in_desc_helper(ctx.heap, desc_obj)) cur_flags.enumerable = desc_flags.enumerable;
                    if (has_configurable_in_desc_helper(ctx.heap, desc_obj)) cur_flags.configurable = desc_flags.configurable;
                    obj.set_prop_flags((uint)existing_idx, cur_flags);
                }
            }
        }
    }

    // Step 5: Return obj
    ctx.result.set_object(obj);
}

/// Helper: check if descriptor object has "get" property
fn bool has_get_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "get");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "set" property
fn bool has_set_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "set");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "value" property
fn bool has_value_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "writable" property
fn bool has_writable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "writable");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "enumerable" property
fn bool has_enumerable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "enumerable");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "configurable" property
fn bool has_configurable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "configurable");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}

// ============================================================================
// Object.create — ES5 §15.2.3.5 / ES2020 §19.1.2.2
// ============================================================================
/// Create a new object with the specified prototype and optional properties.
///
/// ES2020 spec:
/// 1. Let obj be ? OrdinaryCreateFromConstructor(O, "%Object.prototype%").
/// 2. If Properties is not undefined, then
///    a. Return ? ObjectDefineProperties(obj, Properties).
/// 3. Return obj.
///
/// ObjectDefineProperties (§19.1.2.4):
/// 1. Let props be ? ToObject(Properties).
/// 2. Let keys be ? props.[[OwnPropertyKeys]]().
/// 3. Let descriptors be a new empty List.
/// 4. For each element nextKey of keys, do
///    a. Let propDesc be ? props.[[GetOwnProperty]](nextKey).
///    b. If propDesc is not undefined and propDesc.[[Enumerable]] is true, then
///       i. Let descObj be ? Get(props, nextKey).
///       ii. Let desc be ? ToPropertyDescriptor(descObj).
///       iii. Append { nextKey, desc } to descriptors.
/// 5. For each element { propKey, desc } in descriptors, do
///    a. ? DefinePropertyOrThrow(O, propKey, desc).
/// 6. Return O.
fn void builtin_object_create(BuiltinContext* ctx) {
    // Step 1: Check prototype argument
    if (ctx.argc < 1) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.create requires at least 1 argument");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    TVal proto_val = ctx.regs[ctx.base_reg];

    // Step 2: If O is not Object or Null, throw TypeError
    if (proto_val.is_null()) {
        // null prototype is valid
    } else if (proto_val.is_object()) {
        // valid
    } else {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object prototype may only be an Object or null");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject*? proto_obj_raw = null;
    if (proto_val.is_object()) {
        proto_obj_raw = (HObject*)proto_val.get_heapptr();
    }

    // Step 3: Create a new object with [[Prototype]] = O
    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err3 = obj_raw) { ctx.result.set_undefined(); return; }
    HObject* obj = obj_raw;
    if (try proto_obj = proto_obj_raw) {
        obj.prototype = proto_obj;
    } else {
        obj.prototype = null;
    }
    obj.flags.extensible = true;

    // Step 4: If Properties is not undefined, call ObjectDefineProperties semantics.
    // ES2020: ToObject(Properties) wraps primitives; only null throws (via ToObject(null)).
    if (ctx.argc >= 2) {
        TVal props_val = ctx.regs[ctx.base_reg + 1];
        if (!props_val.is_undefined()) {
            // ToObject(Properties) — wrap primitives, throw TypeError for null
            HObject* props;
            if (props_val.is_object()) {
                props = (HObject*)props_val.get_heapptr();
            } else if (props_val.is_null()) {
                // ToObject(null) → TypeError
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err4 = err_raw) { ctx.result.set_undefined(); return; }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
                if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.set_string(msg_str);
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
                return;
            } else {
                // ToObject(primitive) → wrap via builtin_to_object
                if (!builtin_to_object(ctx, props_val)) {
                    // Should not happen for non-null/non-undefined
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (catch err5 = err_raw) { ctx.result.set_undefined(); return; }
                    HObject* err = err_raw;
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
                    if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                    TVal msg_tv;
                    msg_tv.set_string(msg_str);
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                    return;
                }
                props = (HObject*)ctx.result.get_heapptr();
            }

            // ---- ObjectDefineProperties(obj, Properties) ----
            // Phase 1: Collect all property descriptors (calling getters, checking enumerable).
            // We collect into parallel arrays to apply atomically after all getters are invoked.

            HString*[256] desc_keys;
            hobject::PropFlags[256] desc_flags_arr;
            TVal[256] desc_values;
            TVal[256] desc_acc_get;
            TVal[256] desc_acc_set;
            bool[256] desc_is_acc;
            uint desc_count = 0;

            // Helper: collect keys — named properties first, then array-part, then symbols
            // Named properties
            for (uint i = 0; i < props.prop_count && desc_count < 256; i++) {
                void* raw_key = props.prop_key_at(i);
                if (raw_key == null) continue;
                HString* pk_key = (HString*)raw_key;

                // [[GetOwnProperty]](pk_key) — check if own and enumerable
                int pidx = props.find_prop_idx(pk_key);
                if (pidx < 0) continue;
                hobject::PropFlags pflags = props.get_prop_flags((uint)pidx);
                if (!pflags.enumerable) continue;

                // [[Get]](props, pk_key) — invoke getter if accessor
                TVal desc_obj_val;
                if (pflags.is_accessor) {
                    TVal gs_slot = props.prop_values()[(uint)pidx];
                    TVal getter_fn = hobject::hobject_access_getter(gs_slot);
                    if (getter_fn.is_undefined() || getter_fn.is_null()) {
                        // No getter — Get returns undefined
                        TVal undef;
                        undef.set_undefined();
                        desc_obj_val = undef;
                    } else if (ctx.heap.call_fn != null && ctx.vm != null) {
                        TVal this_tv;
                        this_tv.set_object(props);
                        desc_obj_val = ctx.heap.call_fn(ctx.vm, getter_fn, null, 0, this_tv);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                            return;
                        }
                    } else {
                        TVal undef;
                        undef.set_undefined();
                        desc_obj_val = undef;
                    }
                } else {
                    // Data property — value is directly in PropValue
                    desc_obj_val = props.prop_values()[(uint)pidx];
                }

                // ToPropertyDescriptor(desc_obj_val)
                if (!desc_obj_val.is_object()) {
                    // ToPropertyDescriptor requires an object — throw TypeError
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (catch err6 = err_raw) { ctx.result.set_undefined(); return; }
                    HObject* err = err_raw;
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    char[128] msg_buf;
                    int msg_len = libc::snprintf(&msg_buf, 128, "Property descriptor for '%s' must be an object",
                                                 pk_key.get_data());
                    HString* msg_str = builtin_intern_string(ctx.heap, msg_buf[:msg_len]);
                    if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                    TVal msg_tv;
                    msg_tv.set_string(msg_str);
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                    return;
                }
                HObject* desc_obj = (HObject*)desc_obj_val.get_heapptr();

                hobject::PropFlags desc_flags;
                TVal[2] desc_vals;
                bool is_acc;
                if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_acc, null, null)) {
                    if (ctx.should_throw) return;
                    ctx.result.set_undefined();
                    return;
                }

                // Store collected descriptor
                desc_keys[desc_count] = pk_key;
                desc_flags_arr[desc_count] = desc_flags;
                desc_values[desc_count] = desc_vals[0];
                desc_acc_get[desc_count] = desc_vals[0];
                desc_acc_set[desc_count] = desc_vals[1];
                desc_is_acc[desc_count] = is_acc;
                desc_count++;
            }

            // Array-part properties (numeric indices)
            for (uint i = 0; i < props.array_size && desc_count < 256; i++) {
                if (props.array_part()[i].is_undefined()) continue;

                HString* pk_key = ctx.heap.int_to_hstring((long)i);
                if (pk_key == null) continue;

                // Array-part entries are always writable/enumerable/configurable
                // (no per-element flags in the flat array part)
                // So always enumerable.

                TVal desc_obj_val = props.array_part()[i];

                if (!desc_obj_val.is_object()) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (catch err7 = err_raw) { ctx.result.set_undefined(); return; }
                    HObject* err = err_raw;
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    char[128] msg_buf;
                    int msg_len = libc::snprintf(&msg_buf, 128, "Property descriptor for '%s' must be an object",
                                                 pk_key.get_data());
                    HString* msg_str = builtin_intern_string(ctx.heap, msg_buf[:msg_len]);
                    if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                    TVal msg_tv;
                    msg_tv.set_string(msg_str);
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                    return;
                }
                HObject* desc_obj = (HObject*)desc_obj_val.get_heapptr();

                hobject::PropFlags desc_flags;
                TVal[2] desc_vals;
                bool is_acc;
                if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_acc, null, null)) {
                    if (ctx.should_throw) return;
                    ctx.result.set_undefined();
                    return;
                }

                desc_keys[desc_count] = pk_key;
                desc_flags_arr[desc_count] = desc_flags;
                desc_values[desc_count] = desc_vals[0];
                desc_acc_get[desc_count] = desc_vals[0];
                desc_acc_set[desc_count] = desc_vals[1];
                desc_is_acc[desc_count] = is_acc;
                desc_count++;
            }

            // Phase 2: Apply all collected descriptors atomically
            for (uint k = 0; k < desc_count; k++) {
                HString* pk_key = desc_keys[k];
                hobject::PropFlags df = desc_flags_arr[k];
                if (desc_is_acc[k]) {
                    obj.put_prop(pk_key, desc_acc_get[k], df);
                    int eidx = obj.find_prop_idx(pk_key);
                    if (eidx >= 0) {
                        obj.prop_values()[eidx] = hobject::hobject_create_accessors(
                            ctx.heap, desc_acc_get[k], desc_acc_set[k]);
                    }
                } else {
                    obj.put_prop(pk_key, desc_values[k], df);
                }
            }
        }
    }

    // Step 5: Return obj
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.seal — ES5 §15.2.3.8
// ============================================================================
/// Seal an object: prevent extensions and make all properties non-configurable.
fn void builtin_object_seal(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // ES2015 §19.1.2.18: if Type(O) is not Object, return O.
    if (!arg.is_object()) {
        ctx.result[0] = arg;
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    obj.seal();
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.freeze — ES5 §15.2.3.9
// ============================================================================
/// Freeze an object: seal and make all data properties non-writable.
fn void builtin_object_freeze(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // ES2015 §19.1.2.7: if Type(O) is not Object, return O.
    if (!arg.is_object()) {
        ctx.result[0] = arg;
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    obj.freeze();
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.isSealed — ES5 §15.2.3.11
// ============================================================================
/// Check if an object is sealed.
fn void builtin_object_isSealed(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // ES5 §15.2.3.11: non-object arguments return true
    if (!arg.is_object()) {
        ctx.result.set_boolean(true);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();

    // Dense array elements are always writable and configurable (no per-element
    // flags in the flat array part).  If any exist, the object can't be sealed.
    if (obj.array_used > 0) {
        ctx.result.set_boolean(false);
        return;
    }

    // Check if any own property is configurable
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i) != null && obj.get_prop_flags(i).configurable) {
            ctx.result.set_boolean(false);
            return;
        }
    }

    // Check if extensible
    if (obj.flags.extensible) {
        ctx.result.set_boolean(false);
        return;
    }

    ctx.result.set_boolean(true);
}

// ============================================================================
// Object.isFrozen — ES5 §15.2.3.12
// ============================================================================
/// Check if an object is frozen.
fn void builtin_object_isFrozen(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // ES5 §15.2.3.12: non-object arguments return true
    if (!arg.is_object()) {
        ctx.result.set_boolean(true);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();

    // Dense array elements are always writable and configurable (no per-element
    // flags in the flat array part).  If any exist, the object can't be frozen.
    if (obj.array_used > 0) {
        ctx.result.set_boolean(false);
        return;
    }

    // Check if any own property is configurable or data property writable
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i) != null) {
            hobject::PropFlags f = obj.get_prop_flags(i);
            if (f.configurable) {
                ctx.result.set_boolean(false);
                return;
            }
            if (!f.is_accessor && f.writable) {
                ctx.result.set_boolean(false);
                return;
            }
        }
    }

    // Check if extensible
    if (obj.flags.extensible) {
        ctx.result.set_boolean(false);
        return;
    }

    ctx.result.set_boolean(true);
}

// ============================================================================
// Object.entries — ES2017 §19.1.2.21
// ============================================================================
/// Returns an array of the given object's own enumerable string-keyed property
/// [key, value] pairs.
fn void builtin_object_entries(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.is_null() || arg.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert undefined or null to object");
        return;
    }
    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        // ToObject wrapper for primitives — use proper exotic class
        if (!builtin_to_object(ctx, arg)) { ctx.result.set_undefined(); return; }
        obj = (HObject*)ctx.result.get_heapptr();
    }
    // Count enumerable own properties
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.get_prop_flags(i).enumerable && obj.prop_key_at(i) != null) count++;
    }
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) count++;
    }
    // STRING exotic: integer indices [0, char_length) are enumerable own
    // properties served lazily via the exotic_stringobj flag.
    uint stringobj_len = 0;
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) stringobj_len = prim.char_length();
        count += stringobj_len;
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err3 = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;
    // STRING exotic indices first (matches Object.keys ordering and matches
    // the spec enumeration of indexed character properties).
    if (stringobj_len > 0) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        char* data = prim.get_cstr();
        for (uint i = 0; i < stringobj_len; i++) {
            HString* key_s = ctx.heap.int_to_hstring((long)i);
            if (key_s == null) continue;
            // Build single-character string value.
            char[2] ch_buf;
            ch_buf[0] = data[i];
            ch_buf[1] = 0;
            HString* ch_hstr = builtin_intern_string(ctx.heap, ch_buf[:1]);
            TVal ch_val; ch_val.set_string(ch_hstr);
            // Append [key, value] pair
            HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err_ex = pair_raw) continue;
            HObject* pair = pair_raw;
            pair.prototype = ctx.heap.array_proto;
            TVal key_tv; key_tv.set_string(key_s);
            array_set_elem(pair, 0, key_tv, ctx.heap);
            array_set_elem(pair, 1, ch_val, ctx.heap);
            TVal len_tv; len_tv.set_fastint(2);
            HString* len_key = builtin_intern_string(ctx.heap, "length");
            pair.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
            TVal pair_tv; pair_tv.set_object(pair);
            array_set_elem(arr, idx, pair_tv, ctx.heap);
            idx++;
        }
    }
    // Named properties → [key, value] pairs
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.get_prop_flags(i).enumerable && obj.prop_key_at(i) != null) {
            HString* key = (HString*)obj.prop_key_at(i);
            // Create pair array [key, value]
            HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err4 = pair_raw) { ctx.result.set_undefined(); return; }
            HObject* pair = pair_raw;
            pair.prototype = ctx.heap.array_proto;
            TVal key_tv; key_tv.set_string(key);
            array_set_elem(pair, 0, key_tv, ctx.heap);
            array_set_elem(pair, 1, obj.prop_values()[i], ctx.heap);
            TVal len_tv; len_tv.set_fastint(2);
            HString* len_key = builtin_intern_string(ctx.heap, "length");
            pair.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
            TVal pair_tv; pair_tv.set_object(pair);
            array_set_elem(arr, idx, pair_tv, ctx.heap);
            idx++;
        }
    }
    // Dense array indices → [key, value] pairs
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            HString* key_s = ctx.heap.int_to_hstring((long)i);
            if (key_s == null) continue;
            HObject*? pair_raw2 = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err6 = pair_raw2) continue;
            HObject* pair2 = pair_raw2;
            pair2.prototype = ctx.heap.array_proto;
            TVal key_tv2; key_tv2.set_string(key_s);
            array_set_elem(pair2, 0, key_tv2, ctx.heap);
            array_set_elem(pair2, 1, obj.array_part()[i], ctx.heap);
            TVal len_tv2; len_tv2.set_fastint(2);
            HString* len_key2 = builtin_intern_string(ctx.heap, "length");
            pair2.put_prop(len_key2, len_tv2, hobject::PROP_FLAGS_WEC);
            TVal pair_tv2; pair_tv2.set_object(pair2);
            array_set_elem(arr, idx, pair_tv2, ctx.heap);
            idx++;
        }
    }
    // Set .length on result array
    TVal rlen_tv; rlen_tv.set_fastint((long)idx);
    HString* rlen_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(rlen_key, rlen_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.values — ES2017 §19.1.2.22
// ============================================================================
/// Returns an array of the given object's own enumerable string-keyed property values.
fn void builtin_object_values(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.is_null() || arg.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert undefined or null to object");
        return;
    }
    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        // ToObject wrapper for primitives — use proper exotic class
        if (!builtin_to_object(ctx, arg)) { ctx.result.set_undefined(); return; }
        obj = (HObject*)ctx.result.get_heapptr();
    }
    // Count enumerable own properties
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.get_prop_flags(i).enumerable && obj.prop_key_at(i) != null) count++;
    }
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) count++;
    }
    // String exotic: integer indices [0, char_length) are own enumerable
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) count += prim.char_length();
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err3 = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;
    // Named properties
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.get_prop_flags(i).enumerable && obj.prop_key_at(i) != null) {
            array_set_elem(arr, idx, obj.prop_values()[i], ctx.heap);
            idx++;
        }
    }
    // Dense array indices
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            array_set_elem(arr, idx, obj.array_part()[i], ctx.heap);
            idx++;
        }
    }
    // String exotic: serve indexed character properties lazily
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) {
            usz blen = prim.blen;
            char[] data = prim.get_data();
            usz byte_pos = 0;
            uint ch_idx = 0;
            while (byte_pos < blen && ch_idx < prim.char_length()) {
                usz char_start = byte_pos;
                // Single-byte ASCII fast path: top 2 bits are 00, not 10.
                if (byte_pos < blen && (data[byte_pos] & 0x80) == 0) {
                    byte_pos++;
                } else {
                    // Multi-byte UTF-8: count continuation bytes (top 2 bits == 10).
                    byte_pos++;  // skip the leading byte
                    while (byte_pos < blen && (data[byte_pos] & 0xC0) == 0x80) { byte_pos++; }
                }
                char[8] one;
                usz copy_len = byte_pos - char_start;
                if (copy_len >= one.len) copy_len = one.len - 1;
                for (usz j = 0; j < copy_len; j++) { one[j] = data[char_start + j]; }
                one[copy_len] = 0;
                HString*? ch_raw = builtin_intern_string(ctx.heap, one[:copy_len]);
                if (try ch = ch_raw) {
                    TVal ch_tv; ch_tv.set_string(ch);
                    array_set_elem(arr, idx, ch_tv, ctx.heap);
                    idx++;
                }
                ch_idx++;
            }
        }
    }
    // Set .length
    TVal rlen_tv; rlen_tv.set_fastint((long)idx);
    HString* rlen_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(rlen_key, rlen_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.assign — ES2015 §19.1.2.2
// ============================================================================
/// Copies enumerable own properties from source objects to a downstream object.
fn void builtin_object_assign(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal downstream_val = ctx.regs[ctx.base_reg];
    // TypeError if downstream is null or undefined
    if (downstream_val.is_null() || downstream_val.is_undefined()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    // ES2015 §19.1.2.1 step 1: ToObject(target)
    HObject* downstream;
    if (downstream_val.is_object()) {
        downstream = (HObject*)downstream_val.get_heapptr();
    } else if (downstream_val.is_string()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
        if (catch err2 = obj_raw) { ctx.result.set_undefined(); return; }
        downstream = obj_raw;
        downstream.flags.exotic_stringobj = true;
        downstream.prototype = ctx.heap.string_proto;
        HString* prim_str = (HString*)downstream_val.get_heapptr();
        (*downstream.extra_ptr()).prim.primitive_value.set_string(prim_str);
        HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)prim_str.char_length());
        downstream.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
    } else if (downstream_val.is_number() || downstream_val.is_fastint()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.NUMBER);
        if (catch err2 = obj_raw) { ctx.result.set_undefined(); return; }
        downstream = obj_raw;
        downstream.prototype = ctx.heap.number_proto;
        (*downstream.extra_ptr()).prim.primitive_value = downstream_val;
    } else if (downstream_val.is_boolean()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.BOOLEAN);
        if (catch err2 = obj_raw) { ctx.result.set_undefined(); return; }
        downstream = obj_raw;
        downstream.prototype = ctx.heap.bool_proto;
        (*downstream.extra_ptr()).prim.primitive_value.set_boolean(downstream_val.get_boolean());
    } else {
        // Symbol, BigInt, etc.
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err2 = obj_raw) { ctx.result.set_undefined(); return; }
        downstream = obj_raw;
        downstream.prototype = ctx.heap.object_proto;
    }
    // Copy properties from each source (args 1..N)
    for (uint s = 1; s < ctx.argc; s++) {
        TVal source = ctx.regs[ctx.base_reg + s];
        // ES2015 §19.1.2.2 step 2: skip undefined/null, ToObject everything else
        if (source.is_null() || source.is_undefined()) continue;
        // ES2015 §19.1.2.2 step 2: Let from be ToObject(source)
        HObject* src_obj;
        if (source.is_object()) {
            src_obj = (HObject*)source.get_heapptr();
        } else if (source.is_string()) {
            // Create String exotic object for string sources
            HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
            if (catch err3 = obj_raw) continue;
            src_obj = obj_raw;
            src_obj.flags.exotic_stringobj = true;
            src_obj.prototype = ctx.heap.string_proto;
            HString* prim_str = (HString*)source.get_heapptr();
            (*src_obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
            HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
            TVal len_tv;
            len_tv.set_fastint((long)prim_str.char_length());
            src_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
        } else {
            // Number, Boolean, Symbol, BigInt — no enumerable own properties
            continue;
        }
        // Copy enumerable own named properties via [[Set]] per ES2015 §19.1.2.2
        for (uint i = 0; i < src_obj.prop_count; i++) {
            if (src_obj.get_prop_flags(i).enumerable && src_obj.prop_key_at(i) != null) {
                void* key = src_obj.prop_key_at(i);
                // ES2015 §19.1.2.2 step 5.c: propValue = ? Get(from, nextKey).
                // Use [[Get]] so source getters are invoked (the raw prop slot
                // holds the GetterSetter object, not the getter's return value).
                TVal val;
                if (!desc_get(ctx, src_obj, (hstring::HString*)key, &val)) {
                    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                    continue;
                }
                if (!obj_assign_set(ctx, downstream, (hstring::HString*)key, &val)) {
                    ctx.result.set_undefined();
                    return;
                }
            }
        }
        // Copy enumerable own dense array indices via [[Set]]
        if (src_obj.array_part() != null) {
            char[12] digit_buf;
            for (uint i = 0; i < src_obj.array_size; i++) {
                if (!src_obj.array_part()[i].is_undefined()) {
                    int dlen = libc::snprintf(&digit_buf[0], 12, "%u", i);
                    if (dlen > 0) {
                        HString* key = builtin_intern_string(ctx.heap, digit_buf[:(uint)dlen]);
                        if (key != null) {
                            TVal val = src_obj.array_part()[i];
                            if (!obj_assign_set(ctx, downstream, key, &val)) {
                                ctx.result.set_undefined();
                                return;
                            }
                        }
                    }
                }
            }
        }
        // STRING exotic: copy lazy character indices [[Set]] per ES5 §15.5.5.1
        if (src_obj.flags.exotic_stringobj && (*src_obj.extra_ptr()).prim.primitive_value.is_string()) {
            HString* prim = (HString*)(*src_obj.extra_ptr()).prim.primitive_value.get_heapptr();
            if (prim != null) {
                for (uint ci = 0; ci < prim.char_length(); ci++) {
                    HString* ik = ctx.heap.int_to_hstring((long)ci);
                    if (ik == null) continue;
                    // Character properties are always writable, enumerable, configurable
                    uint cp = prim.char_at(ci);
                    char[4] cbuf;
                    uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
                    HString* ch_str = ctx.heap.str_intern(cbuf[:cblen]);
                    if (ch_str != null) {
                        TVal ch_tv; ch_tv.set_string(ch_str);
                        if (!obj_assign_set(ctx, downstream, ik, &ch_tv)) {
                            ctx.result.set_undefined();
                            return;
                        }
                    }
                }
            }
        }
    }
    ctx.result.set_object(downstream);
}

// ============================================================================
// Object.is — ES6 §19.1.2.10
// ============================================================================
/// Object.is(value1, value2) — SameValue comparison.
/// Differs from === in two ways: NaN === NaN, and +0 !== -0.
fn void builtin_object_is(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        // Missing args → undefined (per ES6 spec, both args required)
        TVal undef; undef.set_undefined();
        TVal undef2; undef2.set_undefined();
        // With < 2 args, default is undefined === undefined → true
        ctx.result.set_boolean((ctx.argc == 0) ? true : same_value(ctx.regs[ctx.base_reg], undef2));
        return;
    }
    TVal x = ctx.regs[ctx.base_reg];
    TVal y = ctx.regs[ctx.base_reg + 1];
    ctx.result.set_boolean(same_value(x, y));
}

// ============================================================================
// Object.hasOwn — ES2022 §19.1.2.10
// ============================================================================
/// Object.hasOwn(obj, prop) — returns true if obj has own property prop.
/// Equivalent to Object.prototype.hasOwnProperty.call(obj, prop).
fn void builtin_object_hasOwn(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.hasOwn requires 2 arguments");
        return;
    }
    TVal obj_val = ctx.regs[ctx.base_reg];
    TVal prop_val = ctx.regs[ctx.base_reg + 1];
    // ToObject on first argument — throw TypeError for null/undefined
    if (obj_val.is_null() || obj_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert undefined or null to object");
        return;
    }
    HObject* obj;
    if (obj_val.is_object()) {
        obj = (HObject*)obj_val.get_heapptr();
    } else {
        // Primitive — wrap via ToObject (for now, return false)
        ctx.result.set_boolean(false);
        return;
    }
    HString* key = builtin_to_string_vm(ctx, &prop_val);
    if (key == null) {
        ctx.result.set_boolean(false);
        return;
    }
    PropValue*? entry = obj.find_prop(key);
    if (try e = entry) {
        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// Object.setPrototypeOf — ES2015 §19.1.2.19
// ============================================================================
/// Object.setPrototypeOf(obj, proto) — sets the prototype of obj to proto.
fn void builtin_object_setPrototypeOf(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        ctx.result.set_undefined();
        return;
    }
    TVal obj_val = ctx.regs[ctx.base_reg];
    TVal proto_val = ctx.regs[ctx.base_reg + 1];
    // TypeError if obj is not an object (null/undefined/primitive)
    if (obj_val.is_null() || obj_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.setPrototypeOf requires an object");
        return;
    }
    // TypeError if proto is not an object or null
    if (!proto_val.is_null() && !proto_val.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.setPrototypeOf requires an object or null");
        return;
    }
    // Only set prototype on objects (not primitives)
    if (!obj_val.is_object()) {
        ctx.result.set_fastint(obj_val.get_fastint());
        return;
    }
    HObject* obj = (HObject*)obj_val.get_heapptr();
    if (proto_val.is_null()) {
        obj.prototype = null;
    } else {
        obj.prototype = (HObject*)proto_val.get_heapptr();
    }
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.fromEntries — ES2019 §19.1.2.5
// ============================================================================
/// Creates a new object from an iterable of [key, value] pairs.
fn void builtin_object_fromEntries(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.is_null() || arg.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.fromEntries requires an iterable");
        return;
    }
    if (!arg.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* iterable = (HObject*)arg.get_heapptr();
    // Create result object
    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err2 = obj_raw) { ctx.result.set_undefined(); return; }
    HObject* obj = obj_raw;
    obj.prototype = ctx.heap.object_proto;

    // --- Iterator Protocol (ES2019 §19.1.2.5 step 4) ---
    // Try @@iterator first (spec-compliant path for arrays, Maps, Sets, generators, etc.)
    HString* iter_sym = ensure_iterator_symbol(ctx.heap);
    bool use_iter = false;
    TVal iterator;

    if (false && iter_sym != null) {
        TVal? iter_method_opt = iterable.get_prop_proto(iter_sym);
        if (try iter_method = iter_method_opt) {
            bool callable = false;
            if (iter_method.is_lightfunc()) {
                callable = true;
            } else if (iter_method.is_object() && iter_method.get_heapptr() != null) {
                callable = ((HObject*)iter_method.get_heapptr()).is_callable();
            }
            if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                iterator = ctx.heap.call_fn(ctx.vm, iter_method, null, 0, arg);
                if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }
                use_iter = true;
            }
        }
    }

    if (use_iter) {
        // === Iterator path ===
        HString* next_key = builtin_intern_string(ctx.heap, "next");
        HString* done_key = builtin_intern_string(ctx.heap, "done");
        HString* value_key = builtin_intern_string(ctx.heap, "value");

        while (ctx.heap.call_fn != null && ctx.vm != null) {
            if (!iterator.is_object() || iterator.get_heapptr() == null) break;
            HObject* iter_obj = (HObject*)iterator.get_heapptr();

            TVal? next_method_opt = iter_obj.get_prop_proto(next_key);
            TVal next_method;
            if (try nm = next_method_opt) {
                next_method = nm;
            } else { break; }

            bool callable = false;
            if (next_method.is_lightfunc()) {
                callable = true;
            } else if (next_method.is_object() && next_method.get_heapptr() != null) {
                callable = ((HObject*)next_method.get_heapptr()).is_callable();
            }
            if (!callable) break;

            TVal result = ctx.heap.call_fn(ctx.vm, next_method, null, 0, iterator);
            if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }
            if (!result.is_object() || result.get_heapptr() == null) break;

            HObject* result_obj = (HObject*)result.get_heapptr();
            TVal? done_opt = result_obj.get_prop_proto(done_key);
            bool done = false;
            if (try dv = done_opt) {
                done = builtin_to_boolean(&dv);
            }
            if (done) break;

            TVal? value_opt = result_obj.get_prop_proto(value_key);
            TVal entry;
            if (try vv = value_opt) {
                entry = vv;
            } else { break; }

            // Extract [key, value] from the entry pair
            if (!entry.is_object()) continue;
            HObject* pair = (HObject*)entry.get_heapptr();

            // Get key from pair[0]
            TVal key_idx;
            key_idx.set_fastint(0);
            TVal key_val;
            if (try kv = pair.get_prop(&key_idx)) {
                key_val = kv;
            } else {
                continue;
            }
            // Get value from pair[1]
            TVal val_idx;
            val_idx.set_fastint(1);
            TVal val_val;
            if (try vv = pair.get_prop(&val_idx)) {
                val_val = vv;
            } else {
                val_val.set_undefined();
            }
            // Convert key to property key (ToPropertyKey)
            HString* key_str = builtin_to_property_key(ctx, key_val);
            if (key_str != null) {
                obj.put_prop(key_str, val_val, hobject::PROP_FLAGS_WEC);
            }
        }
        ctx.result.set_object(obj);
        return;
    }

    // === Fallback: length-based iteration for array-like objects without @@iterator ===
    usz len = 0;
    bool has_len = false;
    // ARRAY exotics store length in array_len_ptr(), not the property table,
    // so get_prop("length") would return PROP_NOT_FOUND. Handle them directly.
    if (iterable.flags.exotic_array) {
        len = (usz)*iterable.array_len_ptr();
        has_len = true;
    } else {
        HString* length_key = builtin_intern_string(ctx.heap, "length");
        if (try len_tv = iterable.get_prop(length_key)) {
            if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
                len = (usz)len_tv.get_fastint();
                has_len = true;
            } else if (len_tv.is_number()) {
                len = (usz)len_tv.get_number();
                has_len = true;
            }
        }
    }
    if (!has_len || len == 0) {
        ctx.result.set_object(obj);
        return;
    }
    // Iterate entries by numeric index.
    // Arrays created by array literals with no prior elements have array_size=0
    // (PUTPROP skips set_array_idx when array_part is null), so elements may live
    // in the property table under string keys "0", "1", ... rather than the dense
    // array part.  We must fall back to get_prop_proto with a string key in that case.
    for (usz i = 0; i < len; i++) {
        TVal entry;
        bool got_entry = false;
        if (iterable.array_size > 0 && i < (usz)iterable.array_size) {
            if (try e = iterable.get_array_idx((uint)i)) {
                entry = e;
                got_entry = true;
            }
        }
        if (!got_entry) {
            // Fall back: element stored as named property (e.g. "0", "1")
            HString* idx_str = ctx.heap.int_to_hstring((long)i);
            if (idx_str == null) continue;
            if (try e2 = iterable.get_prop_proto(idx_str)) {
                entry = e2;
                got_entry = true;
            }
        }
        if (!got_entry) continue;
        if (!entry.is_object()) continue;
        HObject* pair = (HObject*)entry.get_heapptr();
        // Get key from pair[0] and value from pair[1] — same dual-path logic
        TVal key_val;
        TVal val_val;
        bool got_key = false;
        if (pair.array_size > 0) {
            if (try kv = pair.get_array_idx(0)) { key_val = kv; got_key = true; }
        }
        if (!got_key) {
            HString* zero_str = ctx.heap.int_to_hstring(0);
            if (zero_str == null) continue;
            if (try kv2 = pair.get_prop_proto(zero_str)) { key_val = kv2; got_key = true; }
        }
        if (!got_key) continue;
        TVal val_tmp; val_tmp.set_undefined();
        if (pair.array_size > 1) {
            if (try vv = pair.get_array_idx(1)) { val_tmp = vv; }
        } else {
            HString* one_str = ctx.heap.int_to_hstring(1);
            if (one_str != null) {
                if (try vv2 = pair.get_prop_proto(one_str)) { val_tmp = vv2; }
            }
        }
        val_val = val_tmp;
        HString* key_str = builtin_to_property_key(ctx, key_val);
        if (key_str != null) {
            obj.put_prop(key_str, val_val, hobject::PROP_FLAGS_WEC);
        }
    }
    ctx.result.set_object(obj);
}

/// Convert a TVal to a property key (HString*) for use in Object.fromEntries.
/// Per ES2019 §19.1.2.5, this performs ToPropertyKey on the entry's "0" element.
/// Uses builtin_to_string_vm for object values (calls toString/valueOf via ToPrimitive),
/// and builtin_to_string for primitives.
fn HString* builtin_to_property_key(BuiltinContext* ctx, TVal key_val) {
    if (key_val.is_string()) {
        return (HString*)key_val.get_heapptr();
    }
    if (key_val.is_number()) {
        return builtin_to_string(ctx.heap, &key_val);
    }
    if (key_val.is_object()) {
        HObject* key_obj = (HObject*)key_val.get_heapptr();
        // Symbol objects: ToString produces "Symbol(description)"
        if (key_obj.get_class() == hobject::ObjClass.SYMBOL) {
            return builtin_to_string(ctx.heap, &key_val);
        }
        // For other objects, call ToString (invokes toString/valueOf via ToPrimitive)
        return builtin_to_string_vm(ctx, &key_val);
    }
    // null, undefined, boolean — call ToString
    return builtin_to_string(ctx.heap, &key_val);
}

fn void builtin_object_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    // ES6 §19.1.3.6 step 2: If Type(O) is not Object, the class name is derived
    // from the value's type: Undefined → "Undefined", Null → "Null", Boolean → "Boolean",
    // Number → "Number", String → "String", Symbol → "Symbol", BigInt → "BigInt".
    if (this_val.is_undefined()) {
        HString* s = builtin_intern_string(ctx.heap, "[object Undefined]");
        ctx.result.set_string(s);
        return;
    }
    if (this_val.is_null()) {
        HString* s = builtin_intern_string(ctx.heap, "[object Null]");
        ctx.result.set_string(s);
        return;
    }
    if (this_val.is_boolean()) {
        HString* s = builtin_intern_string(ctx.heap, "[object Boolean]");
        ctx.result.set_string(s);
        return;
    }
    if (this_val.is_number() || this_val.is_fastint()) {
        HString* s = builtin_intern_string(ctx.heap, "[object Number]");
        ctx.result.set_string(s);
        return;
    }
    if (is_symbol_val(this_val)) {
        HString* s = builtin_intern_string(ctx.heap, "[object Symbol]");
        ctx.result.set_string(s);
        return;
    }
    if (this_val.is_string()) {
        HString* s = builtin_intern_string(ctx.heap, "[object String]");
        ctx.result.set_string(s);
        return;
    }
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        char[64] buf;
        char* class_name = "Object";
        switch (obj.get_class()) {
            case hobject::ObjClass.ARRAY:     class_name = "Array"; break;
            case hobject::ObjClass.FUNCTION:  class_name = "Function"; break;
            case hobject::ObjClass.ARGUMENTS: class_name = "Arguments"; break;
            case hobject::ObjClass.BOOLEAN:   class_name = "Boolean"; break;
            case hobject::ObjClass.NUMBER:    class_name = "Number"; break;
            case hobject::ObjClass.STRING:    class_name = "String"; break;
            case hobject::ObjClass.ERROR:     class_name = "Error"; break;
            case hobject::ObjClass.JSON:      class_name = "JSON"; break;
            case hobject::ObjClass.MATH:      class_name = "Math"; break;
            case hobject::ObjClass.DATE:      class_name = "Date"; break;
            case hobject::ObjClass.REGEXP:    class_name = "RegExp"; break;
            case hobject::ObjClass.MAP:       class_name = "Map"; break;
            case hobject::ObjClass.SET:       class_name = "Set"; break;
            case hobject::ObjClass.WEAKMAP:   class_name = "WeakMap"; break;
            case hobject::ObjClass.WEAKSET:   class_name = "WeakSet"; break;
            case hobject::ObjClass.SYMBOL:    class_name = "Symbol"; break;
            case hobject::ObjClass.PROMISE:   class_name = "Promise"; break;
            case hobject::ObjClass.GENERATOR: class_name = "Generator"; break;
            default:                          class_name = "Object"; break;
        }

        // ES6 §19.1.3.6: check @@toStringTag on the object
        HString* tag_sym = ensure_tostringtag_symbol(ctx.heap);
        if (tag_sym != null) {
            TVal? tag_val = obj.get_prop_proto(tag_sym);
            if (try tv = tag_val) {
                if (tv.is_string()) {
                    HString* tag_str = (HString*)tv.get_heapptr();
                    if (tag_str != null && !tag_str.is_symbol()) {
                        char[] tag_bytes = tag_str.get_data();
                        int tag_len = (int)tag_bytes.len;
                        if (tag_len > 0 && tag_len < 64) {
                            // Build "[object <tag>]"
                            buf[0] = '[';
                            buf[1] = 'o';
                            buf[2] = 'b';
                            buf[3] = 'j';
                            buf[4] = 'e';
                            buf[5] = 'c';
                            buf[6] = 't';
                            buf[7] = ' ';
                            int pos = 8;
                            for (int i = 0; i < tag_len && pos < 62; i++) {
                                buf[pos] = tag_bytes[i];
                                pos++;
                            }
                            buf[pos] = ']';
                            pos++;
                            HString* s = builtin_intern_string(ctx.heap, buf[:pos]);
                            ctx.result.set_string(s);
                            return;
                        }
                    }
                }
            }
        }

        int len = libc::snprintf(&buf, 64, "[object %s]", class_name);
        if (len > 0 && len < 64) {
            HString* s = builtin_intern_string(ctx.heap, buf[:len]);
            ctx.result.set_string(s);
            return;
        }
    }
    HString* s = builtin_intern_string(ctx.heap, "[object Object]");
    ctx.result.set_string(s);
}

/// Object.prototype.hasOwnProperty — ES5 §15.2.4.5
fn void builtin_object_proto_hasOwnProperty(BuiltinContext* ctx) {
    // V = first argument, converted to string key
    TVal arg;
    if (ctx.argc > 0) {
        arg = ctx.regs[ctx.base_reg];
    } else {
        arg.set_undefined();
    }
    HString* key = builtin_to_string_vm(ctx, &arg);
    if (key == null) {
        ctx.result.set_boolean(false);
        return;
    }
    // O = ToObject(this value)
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* obj;
    if (this_val.is_lightfunc()) {
        // Lightfuncs have .name and .length as own properties per ES6 spec.
        // Check deletion bitset: deleted virtual properties are no longer own properties.
        uint fn_idx = (uint)(usz)this_val.get_heapptr();
        if (key.equals("name")) {
            ctx.result.set_boolean(!heap::lf_is_deleted(&ctx.heap.lf_deleted_props[0], fn_idx, 0));
        } else if (key.equals("length")) {
            ctx.result.set_boolean(!heap::lf_is_deleted(&ctx.heap.lf_deleted_props[0], fn_idx, 1));
        } else {
            ctx.result.set_boolean(false);
        }
        return;
    } else if (this_val.is_object() && this_val.get_heapptr() != null) {
        obj = (HObject*)this_val.get_heapptr();
    } else {
        // Primitive this value — return false (no own properties)
        ctx.result.set_boolean(false);
        return;
    }
    // Check own property
    PropValue*? entry = obj.find_prop(key);
    if (try e = entry) {
        ctx.result.set_boolean(true);
        return;
    }
    // ARRAY / ARGUMENTS exotic: numeric indices < array_size and stored in
    // the dense part are own properties (spec §10.4.2 [[GetOwnProperty]]).
    // Without this, hasOwnProperty returns false for dense-only arrays
    // produced by concat/slice/etc.
    if (obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) {
        if (key.is_arridx()) {
            uint ai = (uint)key.array_index();
            if (ai < obj.array_size && !obj.array_part()[ai].is_undefined()) {
                ctx.result.set_boolean(true);
                return;
            }
        }
        // ARRAY "length" is an own property of every Array exotic (§22.1.3).
        if (obj.get_class() == hobject::ObjClass.ARRAY && key.equals("length")) {
            ctx.result.set_boolean(true);
            return;
        }
    }
    // STRING exotic: integer indices [0, clen) are own properties served lazily.
    if (obj.flags.exotic_stringobj && key.is_arridx() && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        ctx.result.set_boolean(prim != null && key.array_index() < prim.char_length());
        return;
    }
    ctx.result.set_boolean(false);
}

/// Object.prototype.propertyIsEnumerable — ES5 §15.2.4.7
fn void builtin_object_proto_propertyIsEnumerable(BuiltinContext* ctx) {
    // V = first argument, converted to string key
    TVal arg;
    if (ctx.argc > 0) {
        arg = ctx.regs[ctx.base_reg];
    } else {
        arg.set_undefined();
    }
    HString* key = builtin_to_string_vm(ctx, &arg);
    if (key == null) {
        ctx.result.set_boolean(false);
        return;
    }
    // O = ToObject(this value)
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* obj;
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        obj = (HObject*)this_val.get_heapptr();
    } else {
        ctx.result.set_boolean(false);
        return;
    }
    // Find own property descriptor
    PropValue*? entry = obj.find_prop(key);
    if (try e = entry) {
        uint prop_idx = (uint)((char*)e - (char*)obj.prop_values()) / hobject::PropValue::size;
        ctx.result.set_boolean(obj.get_prop_flags(prop_idx).enumerable);
        return;
    }
    // ARRAY / ARGUMENTS exotic: numeric indices in the dense part are own
    // enumerable data properties (spec §10.4.2 [[GetOwnProperty]]).
    if (obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) {
        if (key.is_arridx()) {
            uint ai = (uint)key.array_index();
            if (ai < obj.array_size && !obj.array_part()[ai].is_undefined()) {
                ctx.result.set_boolean(true);
                return;
            }
        }
        // ARRAY "length" is non-enumerable per §22.1.3.
        if (obj.get_class() == hobject::ObjClass.ARRAY && key.equals("length")) {
            ctx.result.set_boolean(false);
            return;
        }
    }
    // STRING exotic: integer indices [0, clen) are enumerable own properties served lazily.
    if (obj.flags.exotic_stringobj && key.is_arridx() && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        // Indices in [0, clen) are enumerable per ES5 §15.5.5.1
        ctx.result.set_boolean(prim != null && key.array_index() < prim.char_length());
        return;
    }
    ctx.result.set_boolean(false);
}

/// Object.prototy*peOf — returns 'this'
fn void builtin_object_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    ctx.result.set_fastint(this_val.get_fastint());
    ctx.result.set_number(this_val.get_number());
    ctx.result.set_object(this_val.get_heapptr());
}

/// Object.prototype.isPrototypeOf(V) — ES5 §15.2.4.6
/// Returns true if the object is in the prototype chain of V.
fn void builtin_object_proto_isPrototypeOf(BuiltinContext* ctx) {
    ctx.result.set_boolean(false);

    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        return;
    }
    HObject* proto = (HObject*)this_val.get_heapptr();

    // Get argument V — must be an object
    if (ctx.argc == 0) {
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object() || arg.get_heapptr() == null) {
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();

    // Walk the prototype chain of obj looking for proto
    HObject* cur = obj.prototype;
    while (cur != null) {
        if (cur == proto) {
            ctx.result.set_boolean(true);
            return;
        }
        cur = cur.prototype;
    }
}

/// Object.prototype.toLocaleString() — ES5 §15.2.4.3
/// Calls the toString method and returns the result.
fn void builtin_object_proto_toLocaleString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        ctx.result.set_undefined();
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();

    // Call toString() on the object
    HString* ts_key = (HString*)ctx.heap.strs[heap::BuiltinStr.TO_STRING];
    PropValue*? entry = obj.find_prop(ts_key);
    if (try e = entry) {
        TVal fn_val = *e;
        if (fn_val.is_lightfunc()) {
            // Re-dispatch to toString
            ctx.needs_re_dispatch = true;
            ctx.regs[ctx.base_reg - 1] = fn_val;  // replace callee with toString
            ctx.re_nargs = 0;
            return;
        }
        if (fn_val.is_object() && fn_val.get_heapptr() != null) {
            HObject* fn_obj = (HObject*)fn_val.get_heapptr();
            if (fn_obj.is_callable()) {
                ctx.needs_re_dispatch = true;
                ctx.regs[ctx.base_reg - 1] = fn_val;
                ctx.re_nargs = 0;
                return;
            }
        }
    }

    ctx.result.set_undefined();
}
fn bool register_object_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Object.prototype — the root of all prototype chains
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Object.prototype is the root — its [[Prototype]] is null
    heap.object_proto = proto;

    // Add .toString() method to Object.prototype
    HString* tostring_key = (HString*)heap.strs[heap::BuiltinStr.TO_STRING];
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_TOSTRING);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .hasOwnProperty() method to Object.prototype
    HString* hasown_key = builtin_intern_string(heap, "hasOwnProperty");
    TVal hasown_tv;
    hasown_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_HASOWNPROPERTY);
    proto.put_prop(hasown_key, hasown_tv, hobject::PROP_FLAGS_WC);

    // Add .propertyIsEnumerable() method to Object.prototype (non-enumerable per ES5 §15.2.4.7)
    HString* propisenum_key = builtin_intern_string(heap, "propertyIsEnumerable");
    TVal propisenum_tv;
    propisenum_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_PROPERTYISENUMERABLE);
    proto.put_prop(propisenum_key, propisenum_tv, hobject::PROP_FLAGS_WC);

    // Add .valueOf() method to Object.prototype (returns 'this')
    HString* valueof_key = (HString*)heap.strs[heap::BuiltinStr.VALUE_OF];
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_VALUEOF);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC);

    // Add .isPrototypeOf() method to Object.prototype
    HString* isproto_key = builtin_intern_string(heap, "isPrototypeOf");
    TVal isproto_tv;
    isproto_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_ISPROTOTYPEOF);
    proto.put_prop(isproto_key, isproto_tv, hobject::PROP_FLAGS_WC);

    // Add .toLocaleString() method to Object.prototype (ES5 §15.2.4.3)
    HString* tolocalestring_key = builtin_intern_string(heap, "toLocaleString");
    TVal tolocalestring_tv;
    tolocalestring_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_TOLOCALESTRING);
    proto.put_prop(tolocalestring_key, tolocalestring_tv, hobject::PROP_FLAGS_WC);

    // Create Object constructor as a proper HObject (not LIGHTFUNC)
    // so it can carry .prototype, .length, etc.
    HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = obj_raw) return false;
    HObject* obj = obj_raw;
    (*obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_OBJECT;

    // Set .constructor on Object.prototype to point to the actual Object constructor object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Object.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Object.length (ES5 §15.2.1)
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(1);
    obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    // Add static methods to Object constructor
    // ES5 §15.2.3.x: builtin methods have [[Writable]]:true, [[Enumerable]]:false, [[Configurable]]:true
    HString* keys_key = builtin_intern_string(heap, "keys");
    if (keys_key == null) return false;
    TVal keys_tv;
    keys_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_KEYS);
    obj.put_prop(keys_key, keys_tv, hobject::PROP_FLAGS_WC);

    // Object.getPrototypeOf — ES5 §15.2.3.2
    HString* getproto_key = builtin_intern_string(heap, "getPrototypeOf");
    if (getproto_key == null) return false;
    TVal getproto_tv;
    getproto_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_GETPROTOTYPEOF);
    obj.put_prop(getproto_key, getproto_tv, hobject::PROP_FLAGS_WC);

    // Object.isExtensible — ES5 §15.2.3.13
    HString* isext_key = builtin_intern_string(heap, "isExtensible");
    if (isext_key == null) return false;
    TVal isext_tv;
    isext_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ISEXTENSIBLE);
    obj.put_prop(isext_key, isext_tv, hobject::PROP_FLAGS_WC);

    // Object.preventExtensions — ES5 §15.2.3.10
    HString* prevext_key = builtin_intern_string(heap, "preventExtensions");
    if (prevext_key == null) return false;
    TVal prevext_tv;
    prevext_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PREVENTEXTENSIONS);
    obj.put_prop(prevext_key, prevext_tv, hobject::PROP_FLAGS_WC);

    // Object.getOwnPropertyDescriptor — ES5 §15.2.3.3
    HString* getownpropdesc_key = builtin_intern_string(heap, "getOwnPropertyDescriptor");
    if (getownpropdesc_key == null) return false;
    TVal getownpropdesc_tv;
    getownpropdesc_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_GETOWNPROPERTYDESCRIPTOR);
    obj.put_prop(getownpropdesc_key, getownpropdesc_tv, hobject::PROP_FLAGS_WC);

    // Object.defineProperty — ES5 §15.2.3.6
    HString* defineprop_key = builtin_intern_string(heap, "defineProperty");
    if (defineprop_key == null) return false;
    TVal defineprop_tv;
    defineprop_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_DEFINEPROPERTY);
    obj.put_prop(defineprop_key, defineprop_tv, hobject::PROP_FLAGS_WC);

    // Object.getOwnPropertyNames — ES5 §15.2.3.4
    HString* getownpropnames_key = builtin_intern_string(heap, "getOwnPropertyNames");
    if (getownpropnames_key == null) return false;
    TVal getownpropnames_tv;
    getownpropnames_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_GETOWNPROPERTYNAMES);
    obj.put_prop(getownpropnames_key, getownpropnames_tv, hobject::PROP_FLAGS_WC);

    // Object.getOwnPropertySymbols — ES6 §19.1.2.7
    HString* getownpropsymbols_key = builtin_intern_string(heap, "getOwnPropertySymbols");
    if (getownpropsymbols_key == null) return false;
    TVal getownpropsymbols_tv;
    getownpropsymbols_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_GETOWNPROPERTYSYMBOLS);
    obj.put_prop(getownpropsymbols_key, getownpropsymbols_tv, hobject::PROP_FLAGS_WC);

    // Object.defineProperties — ES5 §15.2.3.7
    HString* defineprops_key = builtin_intern_string(heap, "defineProperties");
    if (defineprops_key == null) return false;
    TVal defineprops_tv;
    defineprops_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_DEFINEPROPERTIES);
    obj.put_prop(defineprops_key, defineprops_tv, hobject::PROP_FLAGS_WC);

    // Object.create — ES5 §15.2.3.5
    HString* create_key = builtin_intern_string(heap, "create");
    if (create_key == null) return false;
    TVal create_tv;
    create_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_CREATE);
    obj.put_prop(create_key, create_tv, hobject::PROP_FLAGS_WC);

    // Object.seal — ES5 §15.2.3.8
    HString* seal_key = builtin_intern_string(heap, "seal");
    if (seal_key == null) return false;
    TVal seal_tv;
    seal_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_SEAL);
    obj.put_prop(seal_key, seal_tv, hobject::PROP_FLAGS_WC);

    // Object.freeze — ES5 §15.2.3.9
    HString* freeze_key = builtin_intern_string(heap, "freeze");
    if (freeze_key == null) return false;
    TVal freeze_tv;
    freeze_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_FREEZE);
    obj.put_prop(freeze_key, freeze_tv, hobject::PROP_FLAGS_WC);

    // Object.isSealed — ES5 §15.2.3.11
    HString* issealed_key = builtin_intern_string(heap, "isSealed");
    if (issealed_key == null) return false;
    TVal issealed_tv;
    issealed_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ISSEALED);
    obj.put_prop(issealed_key, issealed_tv, hobject::PROP_FLAGS_WC);

    // Object.isFrozen — ES5 §15.2.3.12
    HString* isfrozen_key = builtin_intern_string(heap, "isFrozen");
    if (isfrozen_key == null) return false;
    TVal isfrozen_tv;
    isfrozen_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ISFROZEN);
    obj.put_prop(isfrozen_key, isfrozen_tv, hobject::PROP_FLAGS_WC);

    // Object.entries — ES2017 §19.1.2.21
    HString* entries_key = builtin_intern_string(heap, "entries");
    if (entries_key == null) return false;
    TVal entries_tv;
    entries_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ENTRIES);
    obj.put_prop(entries_key, entries_tv, hobject::PROP_FLAGS_WC);

    // Object.values — ES2017 §19.1.2.22
    HString* values_key = builtin_intern_string(heap, "values");
    if (values_key == null) return false;
    TVal values_tv;
    values_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_VALUES);
    obj.put_prop(values_key, values_tv, hobject::PROP_FLAGS_WC);

    // Object.assign — ES2015 §19.1.2.2
    HString* assign_key = builtin_intern_string(heap, "assign");
    if (assign_key == null) return false;
    TVal assign_tv;
    assign_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ASSIGN);
    obj.put_prop(assign_key, assign_tv, hobject::PROP_FLAGS_WC);

    // Object.is — ES6 §19.1.2.10
    HString* is_key = builtin_intern_string(heap, "is");
    if (is_key == null) return false;
    TVal is_tv;
    is_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_IS);
    obj.put_prop(is_key, is_tv, hobject::PROP_FLAGS_WC);

    // Object.hasOwn — ES2022 §19.1.2.10
    HString* hasown_static_key = builtin_intern_string(heap, "hasOwn");
    if (hasown_static_key == null) return false;
    TVal hasown_static_tv;
    hasown_static_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_HASOWN);
    obj.put_prop(hasown_static_key, hasown_static_tv, hobject::PROP_FLAGS_WC);

    // Object.setPrototypeOf — ES2015 §19.1.2.19
    HString* setproto_key = builtin_intern_string(heap, "setPrototypeOf");
    if (setproto_key == null) return false;
    TVal setproto_tv;
    setproto_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_SETPROTOTYPEOF);
    obj.put_prop(setproto_key, setproto_tv, hobject::PROP_FLAGS_WC);

    // Object.fromEntries — ES2019 §19.1.2.5
    HString* fromentries_key = builtin_intern_string(heap, "fromEntries");
    if (fromentries_key == null) return false;
    TVal fromentries_tv;
    fromentries_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_FROMENTRIES);
    obj.put_prop(fromentries_key, fromentries_tv, hobject::PROP_FLAGS_WC);

    // Register Object constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("Object");
    HString* existing = heap.str_table_lookup("Object", hash);
    HString* obj_key;
    if (existing != null) {
        obj_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Object", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        obj_key = new_key;
    }
    TVal obj_val;
    obj_val.set_object(obj);
    set_func_ctor_name_length(obj, heap, "Object", 1);
    env::env_declare_nonenum(global_env, obj_key, obj_val);

    return true;
}
