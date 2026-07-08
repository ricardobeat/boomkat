/// Object constructor and Object.prototype methods.
module tinyduck::builtins;
import tinyduck::types;
import tinyduck::env;
import libc;

import tinyduck::heap;
import tinyduck::hstring;
import tinyduck::hobject;

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
        (*obj.extra_ptr()).prim.primitive_value.set_boolean(val.get_boolean());
        ctx.result.set_object(obj);
        return true;
    }
    // Number/fastint → Number exotic object
    if (val.is_number() || val.is_fastint()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.NUMBER);
        if (catch err = obj_raw) return false;
        HObject* obj = obj_raw;
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
        HString* prim_str = (HString*)val.get_heapptr();
        (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
        // Set .length own property (ES5 §15.5.5.1) — non-writable, non-enumerable, non-configurable
        HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)prim_str.char_length());
        obj.put_prop(len_key, len_tv);
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
    desc.put_prop(builtin_intern_string(heap, "value"), value);
    TVal w_tv; w_tv.set_boolean(writable);
    desc.put_prop(builtin_intern_string(heap, "writable"), w_tv);
    TVal e_tv; e_tv.set_boolean(enumerable);
    desc.put_prop(builtin_intern_string(heap, "enumerable"), e_tv);
    TVal c_tv; c_tv.set_boolean(configurable);
    desc.put_prop(builtin_intern_string(heap, "configurable"), c_tv);
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
        HString* prim_str = (HString*)arg.get_heapptr();
        (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
        // Set .length own property (ES5 §15.5.5.1)
        HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)prim_str.char_length());
        obj.put_prop(len_key, len_tv);
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
    // TypeError if argument is null or undefined
    if (arg.is_null() || arg.is_undefined()) {
        ctx.result.set_undefined();
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
                    if (true) {
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
        if (obj.prop_key_at(i) != null) {
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
    arr.put_prop(length_key, len_tv);
    ctx.result.set_object(arr);
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
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv);
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
        if (obj.prop_key_at(i) != null) count++;
    }
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) count++;
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err3 = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    uint idx = 0;
    // Named properties → [key, value] pairs
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i) != null) {
            HString* key = (HString*)obj.prop_key_at(i);
            // Create pair array [key, value]
            HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err4 = pair_raw) { ctx.result.set_undefined(); return; }
            HObject* pair = pair_raw;
            TVal key_tv; key_tv.set_string(key);
            array_set_elem(pair, 0, key_tv, ctx.heap);
            array_set_elem(pair, 1, obj.prop_values()[i].data.value, ctx.heap);
            TVal len_tv; len_tv.set_fastint(2);
            HString* len_key = builtin_intern_string(ctx.heap, "length");
            pair.put_prop(len_key, len_tv);
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
            TVal key_tv2; key_tv2.set_string(key_s);
            array_set_elem(pair2, 0, key_tv2, ctx.heap);
            array_set_elem(pair2, 1, obj.array_part()[i], ctx.heap);
            TVal len_tv2; len_tv2.set_fastint(2);
            HString* len_key2 = builtin_intern_string(ctx.heap, "length");
            pair2.put_prop(len_key2, len_tv2);
            TVal pair_tv2; pair_tv2.set_object(pair2);
            array_set_elem(arr, idx, pair_tv2, ctx.heap);
            idx++;
        }
    }
    // Set .length on result array
    TVal rlen_tv; rlen_tv.set_fastint((long)idx);
    HString* rlen_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(rlen_key, rlen_tv);
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
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv);
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
    }
    // Count enumerable own properties
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i) != null) count++;
    }
    for (uint i = 0; i < obj.array_size; i++) {
        if (!obj.array_part()[i].is_undefined()) count++;
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err3 = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    uint idx = 0;
    // Named properties
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i) != null) {
            array_set_elem(arr, idx, obj.prop_values()[i].data.value, ctx.heap);
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
    arr.put_prop(rlen_key, rlen_tv);
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
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    // ToObject on downstream
    HObject* downstream;
    if (downstream_val.is_object()) {
        downstream = (HObject*)downstream_val.get_heapptr();
    } else {
        HObject*? wrapped = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err2 = wrapped) { ctx.result.set_undefined(); return; }
        downstream = wrapped;
    }
    // Copy properties from each source (args 1..N)
    for (uint s = 1; s < ctx.argc; s++) {
        TVal source = ctx.regs[ctx.base_reg + s];
        // Skip null, undefined, and non-objects
        if (source.is_null() || source.is_undefined()) continue;
        if (!source.is_object()) continue;
        HObject* src_obj = (HObject*)source.get_heapptr();
        // Copy enumerable own named properties via [[Set]] per ES2015 §19.1.2.2
        for (uint i = 0; i < src_obj.prop_count; i++) {
            if (src_obj.prop_key_at(i) != null) {
                void* key = src_obj.prop_key_at(i);
                TVal val = src_obj.prop_values()[i].data.value;
                // [[Set]]: check own property first
                int down_idx = downstream.find_prop_idx(key);
                if (down_idx >= 0) {
                    hobject::PropFlags f = downstream.get_prop_flags((uint)down_idx);
                    if (!f.is_accessor && f.writable) {
                        downstream.put_prop(key, val);
                    }
                    // Accessor or non-writable: silently skip (non-strict [[Set]] behavior)
                } else {
                    // Not own property — check prototype chain for accessor
                    hobject::AccessorResult acc = downstream.find_accessor(key, false);
                    if (!acc.found && downstream.flags.extensible) {
                        downstream.put_prop(key, val);
                    }
                    // Accessor on prototype or non-extensible: silently skip
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
                            int down_idx = downstream.find_prop_idx((void*)key);
                            if (down_idx >= 0) {
                                hobject::PropFlags f = downstream.get_prop_flags((uint)down_idx);
                                if (!f.is_accessor && f.writable) {
                                    downstream.put_prop((void*)key, val);
                                }
                            } else {
                                hobject::AccessorResult acc = downstream.find_accessor((void*)key, false);
                                if (!acc.found && downstream.flags.extensible) {
                                    downstream.put_prop((void*)key, val);
                                }
                            }
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
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.hasOwn requires 2 arguments");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv);
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
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv);
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
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.fromEntries requires an iterable");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv);
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
            obj.put_prop(key_str, val_val);
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
            // WEAKMAP / WEAKSET removed in TinyDuck.
            case hobject::ObjClass.PROMISE:   class_name = "Promise"; break;
            default:                          class_name = "Object"; break;
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

/// Object.prototype.data.valueOf — returns 'this'
fn void builtin_object_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    ctx.result.set_fastint(this_val.get_fastint());
    ctx.result.set_number(this_val.get_number());
    ctx.result.set_object(this_val.get_heapptr());
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
        TVal fn_val = e.data.value;
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
    heap.object_proto = proto;

    // Add .toString() method to Object.prototype
    HString* tostring_key = (HString*)heap.strs[heap::BuiltinStr.TO_STRING];
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_TOSTRING);
    proto.put_prop(tostring_key, tostring_tv);

    // Add .hasOwnProperty() method to Object.prototype
    HString* hasown_key = builtin_intern_string(heap, "hasOwnProperty");
    TVal hasown_tv;
    hasown_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_HASOWNPROPERTY);
    proto.put_prop(hasown_key, hasown_tv);

    // Add .valueOf() method to Object.prototype (returns 'this')
    HString* valueof_key = (HString*)heap.strs[heap::BuiltinStr.VALUE_OF];
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_VALUEOF);
    proto.put_prop(valueof_key, valueof_tv);

    // Add .toLocaleString() method to Object.prototype (ES5 §15.2.4.3)
    HString* tolocalestring_key = builtin_intern_string(heap, "toLocaleString");
    TVal tolocalestring_tv;
    tolocalestring_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_PROTO_TOLOCALESTRING);
    proto.put_prop(tolocalestring_key, tolocalestring_tv);

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
    proto.put_prop(constructor_key, constructor_tv);

    // Set Object.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    obj.put_prop(prototype_key, proto_tv);

    // Set Object.length (ES5 §15.2.1)
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(1);
    obj.put_prop(length_key, length_tv);

    // Add static methods to Object constructor
    HString* keys_key = builtin_intern_string(heap, "keys");
    if (keys_key == null) return false;
    TVal keys_tv;
    keys_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_KEYS);
    obj.put_prop(keys_key, keys_tv);

    // Object.entries — ES2017 §19.1.2.21
    HString* entries_key = builtin_intern_string(heap, "entries");
    if (entries_key == null) return false;
    TVal entries_tv;
    entries_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ENTRIES);
    obj.put_prop(entries_key, entries_tv);

    // Object.values — ES2017 §19.1.2.22
    HString* values_key = builtin_intern_string(heap, "values");
    if (values_key == null) return false;
    TVal values_tv;
    values_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_VALUES);
    obj.put_prop(values_key, values_tv);

    // Object.assign — ES2015 §19.1.2.2
    HString* assign_key = builtin_intern_string(heap, "assign");
    if (assign_key == null) return false;
    TVal assign_tv;
    assign_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_ASSIGN);
    obj.put_prop(assign_key, assign_tv);

    // Object.is — ES6 §19.1.2.10
    HString* is_key = builtin_intern_string(heap, "is");
    if (is_key == null) return false;
    TVal is_tv;
    is_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_IS);
    obj.put_prop(is_key, is_tv);

    // Object.hasOwn — ES2022 §19.1.2.10
    HString* hasown_static_key = builtin_intern_string(heap, "hasOwn");
    if (hasown_static_key == null) return false;
    TVal hasown_static_tv;
    hasown_static_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_HASOWN);
    obj.put_prop(hasown_static_key, hasown_static_tv);

    // Object.fromEntries — ES2019 §19.1.2.5
    HString* fromentries_key = builtin_intern_string(heap, "fromEntries");
    if (fromentries_key == null) return false;
    TVal fromentries_tv;
    fromentries_tv.set_lightfunc((void*)(usz)BUILTIN_OBJECT_FROMENTRIES);
    obj.put_prop(fromentries_key, fromentries_tv);

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
