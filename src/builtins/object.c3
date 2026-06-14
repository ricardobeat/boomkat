/// Object constructor and Object.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::env;
import libc;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;

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
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
        if (catch err = obj_raw) return false;
        HObject* obj = obj_raw;
        obj.flags.exotic_stringobj = true;
        obj.prototype = ctx.heap.string_proto;
        HString* prim_str = (HString*)val.get_heapptr();
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
    // Handle object prototype method calls (this-value dispatch)
    if (!ctx.is_constructor && ctx.argc == 0) {
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
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.flags.exotic_stringobj = true;
        obj.prototype = ctx.heap.string_proto;
        HString* prim_str = (HString*)arg.get_heapptr();
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_k = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.keys called on non-object");
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
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

    // STRING exotic: integer indices [0, clen) are enumerable own properties
    // synthesised lazily from the primitive value — no materialised slots needed.
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

    // Own named properties — ES2020 §10.1.12 [[OwnPropertyKeys]]:
    // integer indices ascending first, then string keys in insertion order.
    // Phase 1: integer-indexed named properties (sorted by numeric index)
    {
        uint int_count = 0;
        for (uint i = 0; i < obj.prop_count; i++) {
            if (obj.prop_key_at(i) != null && ((HString*)obj.prop_key_at(i)).is_arridx()) {
                int_count++;
            }
        }
        if (int_count > 0) {
            uint* sort_buf = (uint*)libc::malloc((usz)(int_count * 2 * 4));
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
                        TVal key_tv;
                        key_tv.set_string(key);
                        array_set_elem(arr, idx, key_tv, ctx.heap);
                        idx++;
                    }
                }
                libc::free(sort_buf);
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
            TVal key_tv;
            key_tv.set_string(key);
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Dense array indices (as strings)
    // put_prop syncs arridx keys into both named properties and array_part,
    // so Phase 1 already emitted those.  Skip array_part entries whose index
    // also exists as a named arridx property to avoid duplicates.
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            if (obj.flags.exotic_array) {
                HString* ki = ctx.heap.int_to_hstring((long)i);
                if (ki != null && ki.is_arridx() && obj.find_prop_idx(ki) >= 0) continue;
            }
            HString* key = ctx.heap.int_to_hstring((long)i);
            if (key == null) {
                ctx.result.set_undefined();
                return;
            }
            TVal key_tv;
            key_tv.set_string(key);
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Set .length
    TVal len_tv;
    len_tv.set_fastint((long)idx);
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WEC);
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_gpn = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.getOwnPropertyNames called on non-object");
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
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

    // STRING exotic: integer indices [0, clen) are own properties (enumerable by spec).
    // Synthesise them before the named property list so they precede "length".
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

    // Named own property names — integer indices ascending, then strings in insertion order.
    // Phase 1: integer-indexed named properties (sorted by numeric index)
    {
        uint int_count = 0;
        for (uint i = 0; i < obj.prop_count; i++) {
            if (obj.prop_key_at(i) != null && ((HString*)obj.prop_key_at(i)).is_arridx()) {
                int_count++;
            }
        }
        if (int_count > 0) {
            uint* sort_buf = (uint*)libc::malloc((usz)(int_count * 2 * 4));
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
                    TVal key_tv;
                    key_tv.set_string(key);
                    array_set_elem(arr, idx, key_tv, ctx.heap);
                    idx++;
                }
                libc::free(sort_buf);
            }
        }
    }
    // Phase 2: non-index named properties (insertion order)
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i) != null) {
            HString* key = (HString*)obj.prop_key_at(i);
            if (key.is_arridx()) continue;
            TVal key_tv;
            key_tv.set_string(key);
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Dense array indices (as strings)
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) {
            HString* key = ctx.heap.int_to_hstring((long)i);
            if (key == null) {
                ctx.result.set_undefined();
                return;
            }
            TVal key_tv;
            key_tv.set_string(key);
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Set .length
    TVal len_tv;
    len_tv.set_fastint((long)idx);
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WEC);
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.getPrototypeOf requires a value");
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object()) {
        // Throw TypeError for null/undefined/primitives
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.getPrototypeOf called on non-object");
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
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
        } else {
            ctx.result.set_undefined();
            return;
        }
    }

    if (!arg0.is_object()) {
        // ES5 §15.2.3.3: throw TypeError for null/undefined,
        // use ToObject wrapper for primitives (ES2015+)
        if (arg0.is_null() || arg0.is_undefined()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Object.getOwnPropertyDescriptor called on non-object");
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
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
    HString* key_hstr = builtin_to_string(ctx.heap, &key_val);
    if (key_hstr == null) { ctx.result.set_undefined(); return; }
    void* key = key_hstr;

    // String exotic [[GetOwnProperty]] — ES5 §15.5.5.1
    // Numeric indices on String exotic objects return character descriptors.
    // This runs AFTER the default lookup as a fallback (step 1 of spec: try
    // default first, then synthesize if not found).

    // Look up own property (not prototype chain - don't fall through to array_part
    // unless the key matches a numeric index and this is an Array)
    int idx = obj.find_prop_idx(key);
    if (idx < 0) {
        // Check dense array part if key is a string representing a valid index
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
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err1 = err_raw) { return false; }
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            HString* msg_str = builtin_intern_string(ctx.heap, "Cannot assign to read only property");
            if (msg_key == null || msg_str == null) { return false; }
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { return false; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot add property to non-extensible object");
        if (msg_key == null || msg_str == null) { return false; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) return false;
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Invalid property descriptor — cannot have both data and accessor fields");
        if (msg_key == null || msg_str == null) return false;
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return false;
    }

    // Validate getter/setter are callable or undefined
    if (has_get && !get_val.is_undefined()) {
        if (!get_val.is_object() && !get_val.is_lightfunc()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err2 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key2 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str2 = builtin_intern_string(ctx.heap, "Getter must be callable or undefined");
            if (msg_key2 == null || msg_str2 == null) return false;
            TVal msg_tv;
            msg_tv.set_string(msg_str2);
            err.put_prop(msg_key2, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
            return false;
        }
        HObject* fn_obj = (HObject*)get_val.get_heapptr();
        if (!fn_obj.is_callable()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err3 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key3 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str3 = builtin_intern_string(ctx.heap, "Getter must be callable");
            if (msg_key3 == null || msg_str3 == null) return false;
            TVal msg_tv;
            msg_tv.set_string(msg_str3);
            err.put_prop(msg_key3, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
            return false;
        }
    }
    if (has_set && !set_val.is_undefined()) {
        if (!set_val.is_object() && !set_val.is_lightfunc()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err4 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key4 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str4 = builtin_intern_string(ctx.heap, "Setter must be callable or undefined");
            if (msg_key4 == null || msg_str4 == null) return false;
            TVal msg_tv;
            msg_tv.set_string(msg_str4);
            err.put_prop(msg_key4, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
            return false;
        }
        HObject* fn_obj = (HObject*)set_val.get_heapptr();
        if (!fn_obj.is_callable()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err5 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key5 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str5 = builtin_intern_string(ctx.heap, "Setter must be callable");
            if (msg_key5 == null || msg_str5 == null) return false;
            TVal msg_tv;
            msg_tv.set_string(msg_str5);
            err.put_prop(msg_key5, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.defineProperty called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj = (HObject*)arg0.get_heapptr();

    // Step 2: Convert property key to string
    if (ctx.argc < 2) {
        ctx.result.set_undefined();
        return;
    }
    TVal key_val = ctx.regs[ctx.base_reg + 1];
    HString* key_hstr = builtin_to_string(ctx.heap, &key_val);
    if (key_hstr == null) { ctx.result.set_undefined(); return; }
    void* key = key_hstr;

    // Step 3: Check Attributes is Object
    if (ctx.argc < 3) {
        ctx.result.set_undefined();
        return;
    }
    TVal attr_val = ctx.regs[ctx.base_reg + 2];
    if (!attr_val.is_object()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err5 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key3 = builtin_intern_string(ctx.heap, "message");
        HString* msg_str3 = builtin_intern_string(ctx.heap, "Object.defineProperty called with non-object descriptor");
        if (msg_key3 == null || msg_str3 == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str3);
        err.put_prop(msg_key3, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
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
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err6 = err_raw) {
                ctx.result.set_undefined();
                return;
            }
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key4 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str4 = builtin_intern_string(ctx.heap, "Cannot define property on a non-extensible object");
            if (msg_key4 == null || msg_str4 == null) { ctx.result.set_undefined(); return; }
            TVal msg_tv;
            msg_tv.set_string(msg_str4);
            err.put_prop(msg_key4, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
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
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err7 = err_raw) {
                    ctx.result.set_undefined();
                    return;
                }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key5 = builtin_intern_string(ctx.heap, "message");
                HString* msg_str5 = builtin_intern_string(ctx.heap, "Cannot redefine non-configurable property");
                if (msg_key5 == null || msg_str5 == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.set_string(msg_str5);
                err.put_prop(msg_key5, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
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
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err8 = err_raw) {
                    ctx.result.set_undefined();
                    return;
                }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key6 = builtin_intern_string(ctx.heap, "message");
                HString* msg_str6 = builtin_intern_string(ctx.heap, "Cannot change property type from data to accessor or vice versa on non-configurable property");
                if (msg_key6 == null || msg_str6 == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.set_string(msg_str6);
                err.put_prop(msg_key6, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
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
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (catch err_gc = err_raw) {
                        ctx.result.set_undefined();
                        return;
                    }
                    HObject* err = err_raw;
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_key_gc = builtin_intern_string(ctx.heap, "message");
                    HString* msg_str_gc = builtin_intern_string(ctx.heap, "Cannot redefine property: configurable");
                    if (msg_key_gc == null || msg_str_gc == null) { ctx.result.set_undefined(); return; }
                    TVal msg_tv_gc;
                    msg_tv_gc.set_string(msg_str_gc);
                    err.put_prop(msg_key_gc, msg_tv_gc, hobject::PROP_FLAGS_WEC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                    return;
                }
                if (has_enum_in_desc && desc_flags.enumerable != cur_flags.enumerable) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (catch err_ge = err_raw) {
                        ctx.result.set_undefined();
                        return;
                    }
                    HObject* err = err_raw;
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_key_ge = builtin_intern_string(ctx.heap, "message");
                    HString* msg_str_ge = builtin_intern_string(ctx.heap, "Cannot redefine property: enumerable");
                    if (msg_key_ge == null || msg_str_ge == null) { ctx.result.set_undefined(); return; }
                    TVal msg_tv_ge;
                    msg_tv_ge.set_string(msg_str_ge);
                    err.put_prop(msg_key_ge, msg_tv_ge, hobject::PROP_FLAGS_WEC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
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
            if (!cur_flags.configurable) {
                if (has_get_in_desc && !same_value(hobject::hobject_access_getter(*current), desc_vals[0])) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (catch err8a = err_raw) {
                        ctx.result.set_undefined();
                        return;
                    }
                    HObject* err = err_raw;
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_key6a = builtin_intern_string(ctx.heap, "message");
                    HString* msg_str6a = builtin_intern_string(ctx.heap, "Cannot change getter of non-configurable accessor property");
                    if (msg_key6a == null || msg_str6a == null) { ctx.result.set_undefined(); return; }
                    TVal msg_tv;
                    msg_tv.set_string(msg_str6a);
                    err.put_prop(msg_key6a, msg_tv, hobject::PROP_FLAGS_WEC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                    return;
                }
                if (has_set_in_desc && !same_value(hobject::hobject_access_setter(*current), desc_vals[1])) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (catch err8b = err_raw) {
                        ctx.result.set_undefined();
                        return;
                    }
                    HObject* err = err_raw;
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_key6b = builtin_intern_string(ctx.heap, "message");
                    HString* msg_str6b = builtin_intern_string(ctx.heap, "Cannot change setter of non-configurable accessor property");
                    if (msg_key6b == null || msg_str6b == null) { ctx.result.set_undefined(); return; }
                    TVal msg_tv;
                    msg_tv.set_string(msg_str6b);
                    err.put_prop(msg_key6b, msg_tv, hobject::PROP_FLAGS_WEC);
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                    return;
                }
            }

            if (has_get_in_desc) hobject::hobject_set_access_getter(*current, desc_vals[0], ctx.heap);
            if (has_set_in_desc) hobject::hobject_set_access_setter(*current, desc_vals[1], ctx.heap);

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
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err9 = err_raw) {
                    ctx.result.set_undefined();
                    return;
                }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key7 = builtin_intern_string(ctx.heap, "message");
                HString* msg_str7 = builtin_intern_string(ctx.heap, "Cannot change writable attribute of non-configurable property from false to true");
                if (msg_key7 == null || msg_str7 == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.set_string(msg_str7);
                err.put_prop(msg_key7, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
                return;
            }

            if (has_val_in_desc) {
                // ES5 §8.12.9 step 9: If non-configurable and non-writable, reject only if
                // the new value differs from the current value (SameValue check).
                if (!cur_flags.configurable && !cur_flags.writable) {
                    if (!same_value(cur_value, desc_vals[0])) {
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (catch err10 = err_raw) {
                            ctx.result.set_undefined();
                            return;
                        }
                        HObject* err = err_raw;
                        err.prototype = ctx.heap.type_err_proto;
                        HString* msg_key8 = builtin_intern_string(ctx.heap, "message");
                        HString* msg_str8 = builtin_intern_string(ctx.heap, "Cannot change value of non-writable non-configurable property");
                        if (msg_key8 == null || msg_str8 == null) { ctx.result.set_undefined(); return; }
                        TVal msg_tv;
                        msg_tv.set_string(msg_str8);
                        err.put_prop(msg_key8, msg_tv, hobject::PROP_FLAGS_WEC);
                        ctx.should_throw = true;
                        ctx.throw_value.set_object(err);
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.defineProperties called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject* obj = (HObject*)arg0.get_heapptr();

    // Step 2: Check Properties argument is present and is an object
    if (ctx.argc < 2) {
        ctx.result.set_object(obj);
        return;
    }
    TVal props_val = ctx.regs[ctx.base_reg + 1];
    if (!props_val.is_object()) {
        ctx.result.set_object(obj);
        return;
    }
    HObject* props = (HObject*)props_val.get_heapptr();

    // Step 4: For each key, get descriptor and call DefinePropertyOrThrow
    // Collect keys first in case properties are modified during iteration
    HString*[256] keys_arr;
    uint keys_count = 0;
    for (uint i = 0; i < props.prop_count && keys_count < 256; i++) {
        if (props.prop_key_at(i) != null) {
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
                    if (has_get_in_desc_helper(ctx.heap, desc_obj)) hobject::hobject_set_access_getter(*current, desc_vals[0], ctx.heap);
                    if (has_set_in_desc_helper(ctx.heap, desc_obj)) hobject::hobject_set_access_setter(*current, desc_vals[1], ctx.heap);
                    cur_flags.is_accessor = true;
                    if (has_enumerable_in_desc_helper(ctx.heap, desc_obj)) cur_flags.enumerable = desc_flags.enumerable;
                    if (has_configurable_in_desc_helper(ctx.heap, desc_obj)) cur_flags.configurable = desc_flags.configurable;
                    obj.set_prop_flags((uint)existing_idx, cur_flags);
                } else {
                    // Basic data property update
                    if (has_value_in_desc_helper(ctx.heap, desc_obj)) {
                        if (!cur_flags.configurable && !cur_flags.writable) {
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
// Object.create — ES5 §15.2.3.5
// ============================================================================
/// Create a new object with the specified prototype and optional properties.
fn void builtin_object_create(BuiltinContext* ctx) {
    // Step 1-2: Check prototype argument
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

    // If O is not Object or Null, throw TypeError
    if (proto_val.is_null()) {
        // null prototype is valid
    } else if (proto_val.is_object()) {
        // valid
    } else {
        // Throw TypeError
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

    // Step 4: If Properties is not undefined, call defineProperties
    if (ctx.argc >= 2) {
        TVal props_val = ctx.regs[ctx.base_reg + 1];
        if (!props_val.is_undefined() && !props_val.is_null()) {
            // Create a mini-BuiltinContext for the defineProperties call
            // We reuse the same approach: inline defineProperties logic
            if (props_val.is_object()) {
                HObject* props = (HObject*)props_val.get_heapptr();

                // Collect own property keys
                HString*[256] keys_arr;
                uint keys_count = 0;
                for (uint i = 0; i < props.prop_count && keys_count < 256; i++) {
                    if (props.prop_key_at(i) != null) {
                        keys_arr[keys_count] = (HString*)props.prop_key_at(i);
                        keys_count++;
                    }
                }

                for (uint k = 0; k < keys_count; k++) {
                    HString* pk_key = keys_arr[k];
                    PropValue*? prop_entry = props.find_prop(pk_key);
                    if (try pe = prop_entry) {
                        TVal desc_obj_val = *pe;
                        if (!desc_obj_val.is_object()) {
                            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (catch err4 = err_raw) { ctx.result.set_undefined(); return; }
                            HObject* err = err_raw;
                            err.prototype = ctx.heap.type_err_proto;
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            char[128] msg_buf;
                            int msg_len = libc::snprintf(&msg_buf, 128, "Property descriptor for '%s' must be an object", pk_key.get_data());
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
                        bool is_accessor;
                        if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_accessor, null, null)) {
                            if (ctx.should_throw) return;
                            ctx.result.set_undefined();
                            return;
                        }

                        if (is_accessor) {
                            obj.put_prop(pk_key, desc_vals[0], desc_flags);
                            int idx = obj.find_prop_idx(pk_key);
                            if (idx >= 0) {
                                obj.prop_values()[idx] = hobject::hobject_create_accessors(ctx.heap, desc_vals[0], desc_vals[1]);
                            }
                        } else {
                            obj.put_prop(pk_key, desc_vals[0], desc_flags);
                        }
                    }
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
    // ES5 §15.2.3.11: non-object arguments return false
    if (!arg.is_object()) {
        ctx.result.set_boolean(false);
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
    // ES5 §15.2.3.12: non-object arguments return false
    if (!arg.is_object()) {
        ctx.result.set_boolean(false);
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
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err3 = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;
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
    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        HObject*? wrapped = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err2 = wrapped) { ctx.result.set_undefined(); return; }
        obj = wrapped;
        obj.prototype = ctx.heap.object_proto;
    }
    // Count enumerable own properties
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.get_prop_flags(i).enumerable && obj.prop_key_at(i) != null) count++;
    }
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) count++;
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.hasOwn requires 2 arguments");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    TVal obj_val = ctx.regs[ctx.base_reg];
    TVal prop_val = ctx.regs[ctx.base_reg + 1];
    // ToObject on first argument — throw TypeError for null/undefined
    if (obj_val.is_null() || obj_val.is_undefined()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
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
    HObject* obj;
    if (obj_val.is_object()) {
        obj = (HObject*)obj_val.get_heapptr();
    } else {
        // Primitive — wrap via ToObject (for now, return false)
        ctx.result.set_boolean(false);
        return;
    }
    HString* key = builtin_to_string(ctx.heap, &prop_val);
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.setPrototypeOf requires an object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    // TypeError if proto is not an object or null
    if (!proto_val.is_null() && !proto_val.is_object()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.setPrototypeOf requires an object or null");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.fromEntries requires an iterable");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
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
    // Get length
    usz len = 0;
    bool has_len = false;
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
    if (!has_len || len == 0) {
        ctx.result.set_object(obj);
        return;
    }
    // Iterate entries
    for (usz i = 0; i < len; i++) {
        TVal idx_tv;
        idx_tv.set_fastint((long)i);
        TVal entry;
        if (try e = iterable.get_prop(&idx_tv)) {
            entry = e;
        } else {
            continue;
        }
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
        // Convert key to string
        HString* key_str = null;
        if (key_val.is_string()) {
            key_str = (HString*)key_val.get_heapptr();
        } else if (key_val.is_number()) {
            char[32] buf;
            int slen = libc::snprintf(&buf[0], 32, "%g", key_val.get_number());
            if (slen > 0) {
                key_str = ctx.heap.str_intern(buf[..slen]);
            }
        } else if (key_val.is_object()) {
            // Symbol objects: skip per spec (Symbol keys are not string-coerced)
            HObject* key_obj = (HObject*)key_val.get_heapptr();
            if (key_obj.get_class() == hobject::ObjClass.SYMBOL) continue;
            // For other objects, use toString via .name or [object Object]
            char[64] buf;
            char* repr = "[object Object]";
            int slen = 15;
            libc::memcpy(&buf, repr, (usz)slen);
            key_str = ctx.heap.str_intern(buf[..slen]);
        } else {
            // ToPropertyKey: toString for null/undefined/boolean
            char[64] buf;
            char* repr = "undefined";
            int slen = 9;
            if (key_val.is_null()) {
                repr = "null";
                slen = 4;
            } else if (key_val.is_boolean()) {
                if (key_val.get_boolean()) { repr = "true"; slen = 4; }
                else { repr = "false"; slen = 5; }
            }
            uint hash = ctx.heap.hash_string(buf[..slen]);
            libc::memcpy(&buf, repr, (usz)slen);
            key_str = ctx.heap.str_intern(buf[..slen]);
        }
        if (key_str != null) {
            obj.put_prop(key_str, val_val, hobject::PROP_FLAGS_WEC);
        }
    }
    ctx.result.set_object(obj);
}

fn void builtin_object_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        char[64] buf;
        char* class_name = "Object";
        switch (obj.get_class()) {
            case hobject::ObjClass.ARRAY:     class_name = "Array"; break;
            case hobject::ObjClass.FUNCTION:  class_name = "Function"; break;
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
    } else if (this_val.is_undefined()) {
        HString* s = builtin_intern_string(ctx.heap, "[object Undefined]");
        ctx.result.set_string(s);
        return;
    } else if (this_val.is_null()) {
        HString* s = builtin_intern_string(ctx.heap, "[object Null]");
        ctx.result.set_string(s);
        return;
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
    HString* key = builtin_to_string(ctx.heap, &arg);
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
    HString* key = builtin_to_string(ctx.heap, &arg);
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
