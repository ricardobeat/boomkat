/// Object constructor and Object.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::bytecode;
import duktape::env;
import std::math;
import std::io;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::vm;

// ============================================================================
// Object constructor builtins
// ============================================================================

/// ToObject, ES5 §9.9
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
    // BigInt → BigInt wrapper object (ES2020 §7.1.18)
    if (val.is_bigint()) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = obj_raw) return false;
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.bigint_proto;
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
        // Set .length own property (ES5 §15.5.5.1), non-writable, non-enumerable, non-configurable
        HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        TVal len_tv;
        len_tv.set_fastint((long)prim_str.char_length());
        obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC, ctx.heap);
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
    desc.put_prop(heap.str(heap::BuiltinStr.VALUE), value, hobject::PROP_FLAGS_WEC, heap);
    TVal w_tv; w_tv.set_boolean(writable);
    desc.put_prop(builtin_intern_string(heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC, heap);
    TVal e_tv; e_tv.set_boolean(enumerable);
    desc.put_prop(builtin_intern_string(heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC, heap);
    TVal c_tv; c_tv.set_boolean(configurable);
    desc.put_prop(builtin_intern_string(heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC, heap);
    *out = desc;
}

/// Object() as function (ES5 §15.2.1.1) or new Object() as constructor (§15.2.2.1).
/// If value is null/undefined/absent, returns a new empty Object.
/// If value is already an Object, returns it.
/// Otherwise, wraps the primitive (boolean/number/string) in a wrapper object.
fn void builtin_object(BuiltinContext* ctx) {
    // ES2015 §19.1.1.1 Object([value]) step 1: when NewTarget is neither
    // undefined nor the active function object (i.e. Object was invoked via
    // super() from a subclass like `class O extends Object {}`, or
    // `Reflect.construct(Object, args, O)`), the value argument is completely
    // ignored, return an ordinary object whose [[Prototype]] is
    // NewTarget.prototype.
    if (ctx.is_constructor && ctx.new_target != null && ctx.new_target != ctx.callee_obj) {
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.object_proto);
        ctx.result.set_object(obj);
        return;
    }

    // Object() with no args, create and return new empty object
    // Both Object() function call and new Object() with no args.
    if (ctx.argc == 0) {
        // Object() with no args, create and return new empty object
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        // ES2015 §9.2.2 [[Construct]] step 5/2.a: base constructor must use
        // OrdinaryCreateFromConstructor(newTarget, "%Object.prototype%"), so
        // a `class Sub extends Object {}` constructor returns an object whose
        // [[Prototype]] is Sub.prototype, not Object.prototype.
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.object_proto);
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
        obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.object_proto);
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

    if (arg.is_bigint()) {
        // ToObject(BigInt) → a BigInt wrapper object (ES2020 §7.1.18).
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = obj_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.bigint_proto;
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
        obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC, ctx.heap);
        // Indexed character properties are served lazily via the exotic_stringobj flag;
        // no per-character own properties are materialised at construction time.
        ctx.result.set_object(obj);
        return;
    }

    // Fallback, new empty object
    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = obj_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* obj = obj_raw;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.object_proto);
    ctx.result.set_object(obj);
}

/// Collects an object's own String-keyed property names into `key_buf` in
/// spec order (OrdinaryOwnPropertyKeys): integer indices ascending, then
/// String keys in insertion order.  Symbol keys are excluded.  Returns the
/// number of keys written.  `key_buf` must have room for at least
/// `obj.prop_count + obj.array_size + string_char_length` entries.
///
/// When `require_enumerable` is true, only currently-enumerable keys are
/// collected (used by Object.keys, where EnumerableOwnPropertyNames' kind
/// is "key" and no [[Get]] is ever performed, so a single filtered pass is
/// spec-equivalent to the interleaved algorithm).  When false, ALL own
/// string keys are returned regardless of enumerability, Object.entries/
/// values must call this with `require_enumerable = false` and then, for
/// each key, re-check `[[GetOwnProperty]]`'s enumerable attribute
/// immediately before performing `[[Get]]` on that key, since a getter
/// invoked earlier in the walk may have changed a later key's
/// enumerability (EnumerableOwnPropertyNames interleaves the descriptor
/// check and the value fetch per key, it does not snapshot enumerability
/// for the whole list up front).
/// Upper bound on the number of own string keys collect_own_enum_string_keys
/// (and the equivalent inline getOwnPropertyNames/Reflect.ownKeys walks) can
/// write into key_buf. Named props + dense array slots are NOT enough: exotic
/// objects synthesize virtual integer-index keys outside the property table,
/// string-wrapper char indices [0, char_length) and TypedArray element
/// indices [0, [[ArrayLength]]), which must be budgeted for separately or
/// the collector overflows key_buf (heap corruption).
fn uint own_key_buf_capacity(HObject* obj) {
    uint max_keys = obj.prop_count + obj.array_size + 32;
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) max_keys += prim.char_length();
    }
    if (is_typed_array_class(obj.get_class())) {
        max_keys += ta_element_count(obj);
    }
    return max_keys;
}

/// True iff `obj` has at least one own enumerable String key, i.e. iff
/// collect_own_enum_string_keys would write at least one entry.  Callers that
/// only need "is it empty?" use this instead of scanning `prop_count`
/// themselves: the named property table is not the only key source, and a
/// bare prop_count test reports an integer-indexed exotic (TypedArray
/// elements, String-wrapper char indices) as having no keys at all.
fn bool own_has_enum_string_key(Heap* heap, HObject* obj) {
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null && prim.char_length() > 0) return true;
    }
    if (is_typed_array_class(obj.get_class()) && ta_element_count(obj) > 0) return true;
    if (obj.flags.exotic_array || obj.flags.exotic_arguments) {
        for (uint i = 0; i < obj.array_size; i++) {
            if (!obj.array_part()[i].is_undefined()) return true;
        }
    }
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i, heap) != null) return true;
    }
    return false;
}

fn uint collect_own_enum_string_keys(Heap* heap, HObject* obj, HString** key_buf, bool require_enumerable = true) {
    uint key_count = 0;

    // STRING exotic: integer indices [0, clen) are enumerable own properties
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) {
            for (uint i = 0; i < prim.char_length(); i++) {
                HString* k = heap.int_to_hstring((long)i);
                if (k == null) return key_count;
                key_buf[key_count++] = k;
            }
        }
    }

    // TypedArray (Integer-Indexed exotic): [0, [[ArrayLength]]) are
    // enumerable own properties, ascending.
    if (is_typed_array_class(obj.get_class())) {
        uint ta_len = ta_element_count(obj);
        for (uint i = 0; i < ta_len; i++) {
            HString* k = heap.int_to_hstring((long)i);
            if (k == null) return key_count;
            key_buf[key_count++] = k;
        }
    }

    // Phase 1: ALL integer-indexed properties merged from named props + dense
    // array, sorted by numeric index (ES2015 §9.1.11.1 OrdinaryOwnPropertyKeys).
    {
        // Count integer-indexed named properties
        uint named_int_count = 0;
        for (uint i = 0; i < obj.prop_count; i++) {
            if (obj.prop_key_at(i, heap) != null && ((HString*)obj.prop_key_at(i, heap)).is_arridx()) {
                named_int_count++;
            }
        }
        // Count dense array indices that are not also in the named property table
        uint dense_int_count = 0;
        // ARRAY and ARGUMENTS exotics surface array_part as indexed own
        // properties (mirroring get_prop, which consults array_part for both
        // classes). Map/Set/WeakMap/WeakSet/WeakRef/FinalizationRegistry keep
        // their entries in array_part as internal storage, not own properties.
        bool array_part_is_indexed = obj.flags.exotic_array || obj.flags.exotic_arguments;
        if (obj.array_size > 0 && array_part_is_indexed) {
            for (uint i = 0; i < obj.array_size; i++) {
                if (!obj.array_part()[i].is_undefined()) {
                    HString* ki = heap.int_to_hstring((long)i);
                    if (ki != null && ki.is_arridx() && obj.find_prop_idx(ki, heap) >= 0) continue;
                    dense_int_count++;
                }
            }
        }
        uint total_int = named_int_count + dense_int_count;
        if (total_int > 0) {
            // Sort buffer: [index, source_index, source_type] triples
            // source_type: 0 = named prop (index into prop table), 1 = dense array index
            usz sort_size = (usz)(total_int * 3 * 4);
            uint* sort_buf = (uint*)heap.alloc_func(heap.heap_udata, sort_size);
            if (sort_buf != null) {
                uint p = 0;
                // Add integer-indexed named properties
                for (uint i = 0; i < obj.prop_count; i++) {
                    if (obj.prop_key_at(i, heap) != null) {
                        HString* key = (HString*)obj.prop_key_at(i, heap);
                        if (key.is_arridx()) {
                            sort_buf[p * 3] = key.array_index();
                            sort_buf[p * 3 + 1] = i;     // prop table index
                            sort_buf[p * 3 + 2] = 0;     // source: named prop
                            p++;
                        }
                    }
                }
                // Add dense array indices (not already in named props)
                for (uint i = 0; array_part_is_indexed && i < obj.array_size; i++) {
                    if (!obj.array_part()[i].is_undefined()) {
                        HString* ki = heap.int_to_hstring((long)i);
                        if (ki != null && ki.is_arridx() && obj.find_prop_idx(ki, heap) >= 0) continue;
                        sort_buf[p * 3] = (uint)i;
                        sort_buf[p * 3 + 1] = i;         // dense array index
                        sort_buf[p * 3 + 2] = 1;         // source: dense array
                        p++;
                    }
                }
                total_int = p;
                // Insertion sort by numeric index
                for (uint i = 1; i < total_int; i++) {
                    uint t0 = sort_buf[i * 3];
                    uint t1 = sort_buf[i * 3 + 1];
                    uint t2 = sort_buf[i * 3 + 2];
                    uint j = i;
                    while (j > 0 && sort_buf[(j - 1) * 3] > t0) {
                        sort_buf[j * 3] = sort_buf[(j - 1) * 3];
                        sort_buf[j * 3 + 1] = sort_buf[(j - 1) * 3 + 1];
                        sort_buf[j * 3 + 2] = sort_buf[(j - 1) * 3 + 2];
                        j--;
                    }
                    sort_buf[j * 3] = t0;
                    sort_buf[j * 3 + 1] = t1;
                    sort_buf[j * 3 + 2] = t2;
                }
                // Emit sorted integer-indexed keys
                for (uint i = 0; i < total_int; i++) {
                    uint src_type = sort_buf[i * 3 + 2];
                    if (src_type == 0) {
                        // Named property, check enumerable
                        uint prop_idx = sort_buf[i * 3 + 1];
                        if (!require_enumerable || obj.get_prop_flags(prop_idx, heap).enumerable) {
                            HString* key = (HString*)obj.prop_key_at(prop_idx, heap);
                            key_buf[key_count++] = key;
                        }
                    } else {
                        // Dense array index, always enumerable
                        HString* key = heap.int_to_hstring((long)sort_buf[i * 3]);
                        if (key == null) { heap.free_func(heap.heap_udata, sort_buf); return key_count; }
                        key_buf[key_count++] = key;
                    }
                }
                heap.free_func(heap.heap_udata, sort_buf);
            }
        }
    }
    // Phase 2: non-index named properties (insertion order)
    for (uint i = 0; i < obj.prop_count; i++) {
        if ((!require_enumerable || obj.get_prop_flags(i, heap).enumerable) && obj.prop_key_at(i, heap) != null) {
            HString* key = (HString*)obj.prop_key_at(i, heap);
            if (key.is_symbol()) continue;  // only String keys
            if (key.is_arridx()) continue;
            if (obj.flags.exotic_stringobj && (void*)key == (void*)heap.strs[heap::BuiltinStr.LENGTH]) continue;
            if (obj.flags.exotic_array && (void*)key == (void*)heap.strs[heap::BuiltinStr.LENGTH]) continue;
            key_buf[key_count++] = key;
        }
    }
    return key_count;
}

/// Object.keys(obj), ES5 §15.2.3.14
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
    HString** key_buf;
    uint key_count;
    if (obj.flags.exotic_proxyobj) {
        if (!proxy_filtered_own_keys(ctx.vm, ctx.heap, obj, 0, &key_buf, &key_count)) { proxy_ctx_ok(ctx); return; }
    } else {
        uint max_keys = own_key_buf_capacity(obj);
        key_buf = (HString**)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(max_keys * HString*::size));
        if (key_buf == null) { ctx.result.set_undefined(); return; }
        key_count = collect_own_enum_string_keys(ctx.heap, obj, key_buf);
        // Module Namespace Exotic: EnumerableOwnProperties (§7.3.23) calls
        // [[GetOwnProperty]] for each string key, which reads the live binding
        // and throws ReferenceError for a TDZ export (§10.4.6.5 step 4).
        if (obj.flags.exotic_module_ns) {
            for (uint ki = 0; ki < key_count; ki++) {
                ProxyDesc nd;
                if (!module_ns_own_desc(ctx.vm, ctx.heap, obj, key_buf[ki], &nd)) {
                    ctx.heap.free_func(ctx.heap.heap_udata, key_buf);
                    proxy_ctx_ok(ctx);
                    return;
                }
            }
        }
    }
    defer ctx.heap.free_func(ctx.heap.heap_udata, key_buf);

    // Write collected keys into the result array as named properties.
    // Using put_prop with string index keys ensures hasOwnProperty("0"),
    // getOwnPropertyDescriptor("0"), and for-in + result[stringKey] all work.
    for (uint i = 0; i < key_count; i++) {
        HString* idx_key = ctx.heap.int_to_hstring((long)i);
        if (idx_key == null) { ctx.result.set_undefined(); return; }
        TVal val_tv;
        val_tv.set_string(key_buf[i]);
        arr.put_prop(idx_key, val_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    }

    // Set .length, Array.length is writable, non-enumerable, configurable (ES5 §15.4.5.1)
    TVal len_tv;
    len_tv.set_fastint((long)key_count);
    HString* length_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WC, ctx.heap);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.getOwnPropertyNames, ES5 §15.2.3.4
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
            HString* name_str = ctx.heap.str(heap::BuiltinStr.NAME);
            TVal name_tv; name_tv.set_string(name_str);
            array_set_elem(arr, idx, name_tv, ctx.heap);
            idx++;
        }
        if (!length_deleted) {
            HString* length_str = ctx.heap.str(heap::BuiltinStr.LENGTH);
            TVal length_tv; length_tv.set_string(length_str);
            array_set_elem(arr, idx, length_tv, ctx.heap);
            idx++;
        }

        TVal len_tv; len_tv.set_fastint((long)count);
        arr.put_prop(ctx.heap.str(heap::BuiltinStr.LENGTH), len_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
        ctx.result.set_object(arr);
        return;
    }

    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        // ToObject wrapper for primitives, use proper exotic class
        if (!builtin_to_object(ctx, arg)) {
            ctx.result.set_undefined();
            return;
        }
        obj = (HObject*)ctx.result.get_heapptr();
    }
    // Proxy exotic: [[OwnPropertyKeys]] filtered to string keys.
    if (obj.flags.exotic_proxyobj) {
        HString** pkeys;
        uint pn;
        if (!proxy_filtered_own_keys(ctx.vm, ctx.heap, obj, 1, &pkeys, &pn)) { proxy_ctx_ok(ctx); return; }
        defer ctx.heap.free_func(ctx.heap.heap_udata, pkeys);
        HObject*? parr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch perr = parr_raw) { ctx.result.set_undefined(); return; }
        HObject* parr = parr_raw;
        parr.prototype = ctx.heap.array_proto;
        for (uint i = 0; i < pn; i++) {
            HString* idx_key = ctx.heap.int_to_hstring((long)i);
            if (idx_key == null) { ctx.result.set_undefined(); return; }
            TVal kv; kv.set_string(pkeys[i]);
            parr.put_prop(idx_key, kv, hobject::PROP_FLAGS_WEC, ctx.heap);
        }
        TVal plen; plen.set_fastint((long)pn);
        parr.put_prop(ctx.heap.str(heap::BuiltinStr.LENGTH), plen, hobject::PROP_FLAGS_WC, ctx.heap);
        ctx.result.set_object(parr);
        return;
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

    uint max_keys = own_key_buf_capacity(obj);
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

    // TypedArray (Integer-Indexed exotic): [0, [[ArrayLength]]) are own
    // properties, ascending.
    if (is_typed_array_class(obj.get_class())) {
        uint ta_len = ta_element_count(obj);
        for (uint i = 0; i < ta_len; i++) {
            HString* k = ctx.heap.int_to_hstring((long)i);
            if (k == null) { ctx.result.set_undefined(); return; }
            key_buf[key_count++] = k;
        }
    }

    // Phase 1: ALL integer-indexed properties merged from named props + dense
    // array, sorted by numeric index (ES2015 §9.1.11.1 OrdinaryOwnPropertyKeys).
    {
        // Count integer-indexed named properties
        uint named_int_count = 0;
        for (uint i = 0; i < obj.prop_count; i++) {
            if (obj.prop_key_at(i, ctx.heap) != null && ((HString*)obj.prop_key_at(i, ctx.heap)).is_arridx()) {
                named_int_count++;
            }
        }
        // Count dense array indices not in named property table
        uint dense_int_count = 0;
        // ARRAY and ARGUMENTS exotics surface array_part as indexed own
        // properties (mirroring get_prop, which consults array_part for both
        // classes). Map/Set/WeakMap/WeakSet/WeakRef/FinalizationRegistry keep
        // their entries in array_part as internal storage, not own properties.
        bool array_part_is_indexed = obj.flags.exotic_array || obj.flags.exotic_arguments;
        if (obj.array_size > 0 && array_part_is_indexed) {
            for (uint i = 0; i < obj.array_size; i++) {
                if (!obj.array_part()[i].is_undefined()) {
                    HString* ki = ctx.heap.int_to_hstring((long)i);
                    if (ki != null && ki.is_arridx() && obj.find_prop_idx(ki, ctx.heap) >= 0) continue;
                    dense_int_count++;
                }
            }
        }
        uint total_int = named_int_count + dense_int_count;
        if (total_int > 0) {
            usz sort_size = (usz)(total_int * 3 * 4);
            uint* sort_buf = (uint*)ctx.heap.alloc_func(ctx.heap.heap_udata, sort_size);
            if (sort_buf != null) {
                uint p = 0;
                // Add integer-indexed named properties (all, not just enumerable, this is getOwnPropertyNames)
                for (uint i = 0; i < obj.prop_count; i++) {
                    if (obj.prop_key_at(i, ctx.heap) != null) {
                        HString* key = (HString*)obj.prop_key_at(i, ctx.heap);
                        if (key.is_arridx()) {
                            sort_buf[p * 3] = key.array_index();
                            sort_buf[p * 3 + 1] = i;
                            sort_buf[p * 3 + 2] = 0;  // source: named prop
                            p++;
                        }
                    }
                }
                // Add dense array indices
                for (uint i = 0; array_part_is_indexed && i < obj.array_size; i++) {
                    if (!obj.array_part()[i].is_undefined()) {
                        HString* ki = ctx.heap.int_to_hstring((long)i);
                        if (ki != null && ki.is_arridx() && obj.find_prop_idx(ki, ctx.heap) >= 0) continue;
                        sort_buf[p * 3] = (uint)i;
                        sort_buf[p * 3 + 1] = i;
                        sort_buf[p * 3 + 2] = 1;  // source: dense array
                        p++;
                    }
                }
                total_int = p;
                // Insertion sort by numeric index
                for (uint i = 1; i < total_int; i++) {
                    uint t0 = sort_buf[i * 3];
                    uint t1 = sort_buf[i * 3 + 1];
                    uint t2 = sort_buf[i * 3 + 2];
                    uint j = i;
                    while (j > 0 && sort_buf[(j - 1) * 3] > t0) {
                        sort_buf[j * 3] = sort_buf[(j - 1) * 3];
                        sort_buf[j * 3 + 1] = sort_buf[(j - 1) * 3 + 1];
                        sort_buf[j * 3 + 2] = sort_buf[(j - 1) * 3 + 2];
                        j--;
                    }
                    sort_buf[j * 3] = t0;
                    sort_buf[j * 3 + 1] = t1;
                    sort_buf[j * 3 + 2] = t2;
                }
                for (uint i = 0; i < total_int; i++) {
                    uint src_type = sort_buf[i * 3 + 2];
                    if (src_type == 0) {
                        uint prop_idx = sort_buf[i * 3 + 1];
                        HString* key = (HString*)obj.prop_key_at(prop_idx, ctx.heap);
                        if (key.is_symbol()) continue;
                        key_buf[key_count++] = key;
                    } else {
                        HString* key = ctx.heap.int_to_hstring((long)sort_buf[i * 3]);
                        if (key == null) { ctx.heap.free_func(ctx.heap.heap_udata, sort_buf); ctx.result.set_undefined(); return; }
                        key_buf[key_count++] = key;
                    }
                }
                ctx.heap.free_func(ctx.heap.heap_udata, sort_buf);
            }
        }
    }
    // Phase 2: non-index named properties (insertion order)
    // ES5 §15.2.3.4: getOwnPropertyNames returns ONLY string keys (no symbols)
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i, ctx.heap) != null) {
            HString* key = (HString*)obj.prop_key_at(i, ctx.heap);
            if (key.is_arridx()) continue;
            if (key.is_symbol()) continue;  // Skip symbol keys
            key_buf[key_count++] = key;
        }
    }

    // Write collected keys into the result array as named properties.
    for (uint i = 0; i < key_count; i++) {
        HString* idx_key = ctx.heap.int_to_hstring((long)i);
        if (idx_key == null) { ctx.result.set_undefined(); return; }
        TVal val_tv;
        val_tv.set_string(key_buf[i]);
        arr.put_prop(idx_key, val_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    }

    // Set .length, Array.length is writable, non-enumerable, configurable (ES5 §15.4.5.1)
    TVal len_tv;
    len_tv.set_fastint((long)key_count);
    HString* length_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WC, ctx.heap);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.getOwnPropertySymbols, ES6 §19.1.2.7
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
    // Proxy exotic: [[OwnPropertyKeys]] filtered to symbol keys.
    if (obj.flags.exotic_proxyobj) {
        HString** pkeys;
        uint pn;
        if (!proxy_filtered_own_keys(ctx.vm, ctx.heap, obj, 2, &pkeys, &pn)) { proxy_ctx_ok(ctx); return; }
        defer ctx.heap.free_func(ctx.heap.heap_udata, pkeys);
        HObject*? parr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch perr = parr_raw) { ctx.result.set_undefined(); return; }
        HObject* parr = parr_raw;
        parr.prototype = ctx.heap.array_proto;
        for (uint i = 0; i < pn; i++) {
            TVal kv; kv.set_string(pkeys[i]);
            array_set_elem(parr, i, kv, ctx.heap);
        }
        TVal plen; plen.set_fastint((long)pn);
        parr.put_prop(ctx.heap.str(heap::BuiltinStr.LENGTH), plen, hobject::PROP_FLAGS_WC, ctx.heap);
        ctx.result.set_object(parr);
        return;
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
        if (obj.prop_key_at(i, ctx.heap) != null) {
            HString* key = (HString*)obj.prop_key_at(i, ctx.heap);
            if (key.is_symbol()) {
                if (key.is_hidden()) continue;
                TVal key_tv;
                key_tv.set_string(key);
                array_set_elem(arr, idx, key_tv, ctx.heap);
                idx++;
            }
        }
    }

    // Set .length, Array.length is writable, non-enumerable, configurable (ES5 §15.4.5.1)
    TVal len_tv;
    len_tv.set_fastint((long)idx);
    HString* length_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WC, ctx.heap);
    ctx.result.set_object(arr);
}

// ============================================================================
// Reflect.ownKeys, ES6 §26.1.11
// ============================================================================
/// Returns an array of the target object's own property keys (strings and symbols).
/// Unlike Object.keys, does NOT filter by enumerable, returns ALL own keys.
/// Order: integer indices ascending, then string keys in insertion order, then symbol keys.
fn void builtin_reflect_ownKeys(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    if (ctx.argc > 0) target_tv = ctx.regs[ctx.base_reg];
    HObject* obj = reflect_require_object(ctx, target_tv, "Reflect.ownKeys called on non-object");
    if (obj == null) return;

    // Proxy exotic: [[OwnPropertyKeys]] verbatim.
    if (obj.flags.exotic_proxyobj) {
        HObject* parr;
        if (!proxy_mop_own_keys(ctx.vm, ctx.heap, obj, &parr)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_object(parr);
        return;
    }

    // Allocate result array.
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    // Collect keys into a temporary buffer, then write them into the result array.
    uint max_keys = own_key_buf_capacity(obj);
    HString** key_buf = (HString**)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(max_keys * HString*::size));
    if (key_buf == null) { ctx.result.set_undefined(); return; }
    uint key_count = 0;
    defer ctx.heap.free_func(ctx.heap.heap_udata, key_buf);

    // STRING exotic: integer indices [0, clen) are own properties.
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

    // TypedArray (Integer-Indexed exotic): [0, [[ArrayLength]]) are own
    // properties, ascending, before any named/symbol keys (ES2022 §10.4.5.12).
    if (is_typed_array_class(obj.get_class())) {
        uint ta_len = ta_element_count(obj);
        for (uint i = 0; i < ta_len; i++) {
            HString* k = ctx.heap.int_to_hstring((long)i);
            if (k == null) { ctx.result.set_undefined(); return; }
            key_buf[key_count++] = k;
        }
    }

    // Phase 1: integer-indexed properties merged from named props + dense array, sorted.
    {
        uint named_int_count = 0;
        for (uint i = 0; i < obj.prop_count; i++) {
            if (obj.prop_key_at(i, ctx.heap) != null && ((HString*)obj.prop_key_at(i, ctx.heap)).is_arridx()) {
                named_int_count++;
            }
        }
        uint dense_int_count = 0;
        // ARRAY and ARGUMENTS exotics surface array_part as indexed own
        // properties (mirroring get_prop, which consults array_part for both
        // classes). Map/Set/WeakMap/WeakSet/WeakRef/FinalizationRegistry keep
        // their entries in array_part as internal storage, not own properties.
        bool array_part_is_indexed = obj.flags.exotic_array || obj.flags.exotic_arguments;
        if (obj.array_size > 0 && array_part_is_indexed) {
            for (uint i = 0; i < obj.array_size; i++) {
                if (!obj.array_part()[i].is_undefined()) {
                    HString* ki = ctx.heap.int_to_hstring((long)i);
                    if (ki != null && ki.is_arridx() && obj.find_prop_idx(ki, ctx.heap) >= 0) continue;
                    dense_int_count++;
                }
            }
        }
        uint total_int = named_int_count + dense_int_count;
        if (total_int > 0) {
            usz sort_size = (usz)(total_int * 3 * 4);
            uint* sort_buf = (uint*)ctx.heap.alloc_func(ctx.heap.heap_udata, sort_size);
            if (sort_buf != null) {
                uint p = 0;
                for (uint i = 0; i < obj.prop_count; i++) {
                    if (obj.prop_key_at(i, ctx.heap) != null) {
                        HString* key = (HString*)obj.prop_key_at(i, ctx.heap);
                        if (key.is_arridx()) {
                            sort_buf[p * 3] = key.array_index();
                            sort_buf[p * 3 + 1] = i;
                            sort_buf[p * 3 + 2] = 0;  // named prop
                            p++;
                        }
                    }
                }
                for (uint i = 0; array_part_is_indexed && i < obj.array_size; i++) {
                    if (!obj.array_part()[i].is_undefined()) {
                        HString* ki = ctx.heap.int_to_hstring((long)i);
                        if (ki != null && ki.is_arridx() && obj.find_prop_idx(ki, ctx.heap) >= 0) continue;
                        sort_buf[p * 3] = i;
                        sort_buf[p * 3 + 1] = i;
                        sort_buf[p * 3 + 2] = 1;  // dense array
                        p++;
                    }
                }
                total_int = p;
                for (uint i = 1; i < total_int; i++) {
                    uint t0 = sort_buf[i * 3];
                    uint t1 = sort_buf[i * 3 + 1];
                    uint t2 = sort_buf[i * 3 + 2];
                    uint j = i;
                    while (j > 0 && sort_buf[(j - 1) * 3] > t0) {
                        sort_buf[j * 3] = sort_buf[(j - 1) * 3];
                        sort_buf[j * 3 + 1] = sort_buf[(j - 1) * 3 + 1];
                        sort_buf[j * 3 + 2] = sort_buf[(j - 1) * 3 + 2];
                        j--;
                    }
                    sort_buf[j * 3] = t0;
                    sort_buf[j * 3 + 1] = t1;
                    sort_buf[j * 3 + 2] = t2;
                }
                for (uint i = 0; i < total_int; i++) {
                    uint src_type = sort_buf[i * 3 + 2];
                    HString* key;
                    if (src_type == 0) {
                        key = (HString*)obj.prop_key_at(sort_buf[i * 3 + 1], ctx.heap);
                        if (key.is_symbol()) continue;
                    } else {
                        key = ctx.heap.int_to_hstring((long)sort_buf[i * 3]);
                        if (key == null) { ctx.result.set_undefined(); return; }
                    }
                    key_buf[key_count++] = key;
                }
                ctx.heap.free_func(ctx.heap.heap_udata, sort_buf);
            }
        }
    }

    // Phase 2: non-index string properties (insertion order).
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i, ctx.heap) != null) {
            HString* key = (HString*)obj.prop_key_at(i, ctx.heap);
            if (key.is_arridx() || key.is_symbol()) continue;
            key_buf[key_count++] = key;
        }
    }

    // Phase 3: symbol properties (insertion order).
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i, ctx.heap) != null) {
            HString* key = (HString*)obj.prop_key_at(i, ctx.heap);
            if (key.is_symbol()) {
                if (key.is_hidden()) continue;
                key_buf[key_count++] = key;
            }
        }
    }

    // Write collected keys into the result array.
    for (uint i = 0; i < key_count; i++) {
        HString* idx_key = ctx.heap.int_to_hstring((long)i);
        if (idx_key == null) { ctx.result.set_undefined(); return; }
        TVal val_tv;
        val_tv.set_string(key_buf[i]);
        arr.put_prop(idx_key, val_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    }

    TVal len_tv;
    len_tv.set_fastint((long)key_count);
    HString* length_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WC, ctx.heap);
    ctx.result.set_object(arr);
}

// ============================================================================
// Shared Reflect helpers
// ============================================================================

/// Validate that `arg` is an object. For Reflect methods the target must be an
/// Object (no ToObject coercion for primitives). Throws TypeError and returns
/// null if the argument is null, undefined, or any primitive.
fn HObject* reflect_require_object(BuiltinContext* ctx, TVal arg, char[] msg) {
    if (arg.is_null() || arg.is_undefined() || !arg.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, msg);
        return null;
    }
    return (HObject*)arg.get_heapptr();
}

// ============================================================================
// Reflect.get, ES6 §26.1.5
// ============================================================================
/// Returns the value of the property, or undefined if the property is absent.
fn void builtin_reflect_get(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    if (ctx.argc > 0) target_tv = ctx.regs[ctx.base_reg];
    HObject* obj = reflect_require_object(ctx, target_tv, "Reflect.get called on non-object");
    if (obj == null) return;

    TVal key_tv; key_tv.set_undefined();
    if (ctx.argc > 1) key_tv = ctx.regs[ctx.base_reg + 1];
    HString* key = builtin_to_property_key_vm(ctx, &key_tv);
    if (ctx.should_throw) return;
    if (key == null) { ctx.result.set_undefined(); return; }

    TVal receiver = target_tv;
    if (ctx.argc > 2) receiver = ctx.regs[ctx.base_reg + 2];

    TVal out;
    if (!js_get_with_receiver(ctx.vm, ctx.heap, obj, key, receiver, &out)) {
        proxy_ctx_ok(ctx);
        return;
    }
    *ctx.result = out;
}

// ============================================================================
// Reflect.set, ES6 §26.1.13
// ============================================================================
/// Sets the property and returns a boolean indicating success.
fn void builtin_reflect_set(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    if (ctx.argc > 0) target_tv = ctx.regs[ctx.base_reg];
    HObject* obj = reflect_require_object(ctx, target_tv, "Reflect.set called on non-object");
    if (obj == null) return;

    TVal key_tv; key_tv.set_undefined();
    if (ctx.argc > 1) key_tv = ctx.regs[ctx.base_reg + 1];
    HString* key = builtin_to_property_key_vm(ctx, &key_tv);
    if (ctx.should_throw) return;
    if (key == null) { ctx.result.set_boolean(false); return; }

    TVal value; value.set_undefined();
    if (ctx.argc > 2) value = ctx.regs[ctx.base_reg + 2];

    TVal receiver = target_tv;
    if (ctx.argc > 3) receiver = ctx.regs[ctx.base_reg + 3];

    bool res;
    if (!js_set_with_receiver(ctx.vm, ctx.heap, obj, key, value, receiver, &res)) {
        proxy_ctx_ok(ctx);
        return;
    }
    ctx.result.set_boolean(res);
}

// ============================================================================
// Reflect.has, ES6 §26.1.8
// ============================================================================
/// Returns true if the target has the property (own or inherited).
fn void builtin_reflect_has(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    if (ctx.argc > 0) target_tv = ctx.regs[ctx.base_reg];
    HObject* obj = reflect_require_object(ctx, target_tv, "Reflect.has called on non-object");
    if (obj == null) return;

    TVal key_tv; key_tv.set_undefined();
    if (ctx.argc > 1) key_tv = ctx.regs[ctx.base_reg + 1];
    HString* key = builtin_to_property_key_vm(ctx, &key_tv);
    if (ctx.should_throw) return;
    if (key == null) { ctx.result.set_boolean(false); return; }

    bool out;
    if (!js_has_property(ctx.vm, ctx.heap, obj, key, &out)) {
        proxy_ctx_ok(ctx);
        return;
    }
    ctx.result.set_boolean(out);
}

// ============================================================================
// Reflect.deleteProperty, ES6 §26.1.4
// ============================================================================
/// Deletes the property and returns a boolean indicating success.
fn void builtin_reflect_deleteProperty(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    if (ctx.argc > 0) target_tv = ctx.regs[ctx.base_reg];
    HObject* obj = reflect_require_object(ctx, target_tv, "Reflect.deleteProperty called on non-object");
    if (obj == null) return;

    TVal key_tv; key_tv.set_undefined();
    if (ctx.argc > 1) key_tv = ctx.regs[ctx.base_reg + 1];
    HString* key = builtin_to_property_key_vm(ctx, &key_tv);
    if (ctx.should_throw) return;
    if (key == null) { ctx.result.set_boolean(true); return; }

    if (obj.flags.exotic_proxyobj) {
        bool res;
        if (!proxy_mop_delete(ctx.vm, ctx.heap, obj, key, &res)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_boolean(res);
        return;
    }
    // Module Namespace Exotic [[Delete]] (§10.4.6.10): a symbol key that is not
    // an own property (or an absent string key) succeeds; an existing own key
    // (any export or Symbol.toStringTag) is non-configurable and cannot be
    // deleted (false).
    if (obj.flags.exotic_module_ns) {
        ctx.result.set_boolean(obj.find_prop_idx((void*)key, ctx.heap) < 0);
        return;
    }
    ctx.result.set_boolean(obj.es_delete_prop((void*)key, ctx.heap));
}

// ============================================================================
// Reflect.getOwnPropertyDescriptor, ES6 §26.1.6
// ============================================================================
/// Returns a property descriptor for the own property, or undefined.
fn void builtin_reflect_getOwnPropertyDescriptor(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    if (ctx.argc > 0) target_tv = ctx.regs[ctx.base_reg];
    HObject* obj = reflect_require_object(ctx, target_tv, "Reflect.getOwnPropertyDescriptor called on non-object");
    if (obj == null) return;

    TVal key_tv; key_tv.set_undefined();
    if (ctx.argc > 1) key_tv = ctx.regs[ctx.base_reg + 1];
    HString* key = builtin_to_property_key_vm(ctx, &key_tv);
    if (ctx.should_throw) return;
    if (key == null) { ctx.result.set_undefined(); return; }

    ProxyDesc pd;
    if (!own_property_desc(ctx.vm, ctx.heap, obj, key, &pd)) { proxy_ctx_ok(ctx); return; }
    if (!pd.found) { ctx.result.set_undefined(); return; }
    pd.complete();
    HObject* desc = proxy_desc_to_object(ctx.heap, &pd);
    if (desc == null) { ctx.result.set_undefined(); return; }
    ctx.result.set_object(desc);
}

// ============================================================================
// Reflect.defineProperty, ES6 §26.1.3
// ============================================================================
/// Defines a property and returns a boolean indicating success.
fn void builtin_reflect_defineProperty(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    if (ctx.argc > 0) target_tv = ctx.regs[ctx.base_reg];
    HObject* obj = reflect_require_object(ctx, target_tv, "Reflect.defineProperty called on non-object");
    if (obj == null) return;

    TVal key_tv; key_tv.set_undefined();
    if (ctx.argc > 1) key_tv = ctx.regs[ctx.base_reg + 1];
    HString* key = builtin_to_property_key_vm(ctx, &key_tv);
    if (ctx.should_throw) return;
    if (key == null) { ctx.result.set_boolean(false); return; }

    TVal desc_tv; desc_tv.set_undefined();
    if (ctx.argc > 2) desc_tv = ctx.regs[ctx.base_reg + 2];
    if (desc_tv.is_null() || desc_tv.is_undefined() || !desc_tv.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Reflect.defineProperty called with non-object descriptor");
        return;
    }
    HObject* desc_obj = (HObject*)desc_tv.get_heapptr();

    ProxyDesc pd;
    if (!proxy_object_to_desc(ctx.vm, ctx.heap, desc_obj, &pd)) { proxy_ctx_ok(ctx); return; }

    bool res;
    if (!object_define_own(ctx.vm, ctx.heap, obj, key, &pd, &res)) { proxy_ctx_ok(ctx); return; }
    ctx.result.set_boolean(res);
}

// ============================================================================
// Reflect.getPrototypeOf, ES6 §26.1.7
// ============================================================================
/// Returns the [[Prototype]] of the target object.
fn void builtin_reflect_getPrototypeOf(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    if (ctx.argc > 0) target_tv = ctx.regs[ctx.base_reg];
    HObject* obj = reflect_require_object(ctx, target_tv, "Reflect.getPrototypeOf called on non-object");
    if (obj == null) return;

    TVal proto;
    if (!object_get_proto(ctx.vm, ctx.heap, obj, &proto)) { proxy_ctx_ok(ctx); return; }
    *ctx.result = proto;
}

// ============================================================================
// Reflect.setPrototypeOf, ES6 §26.1.14
// ============================================================================
/// Sets the [[Prototype]] and returns a boolean indicating success.
fn void builtin_reflect_setPrototypeOf(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    if (ctx.argc > 0) target_tv = ctx.regs[ctx.base_reg];
    HObject* obj = reflect_require_object(ctx, target_tv, "Reflect.setPrototypeOf called on non-object");
    if (obj == null) return;

    TVal proto_tv; proto_tv.set_undefined();
    if (ctx.argc > 1) proto_tv = ctx.regs[ctx.base_reg + 1];
    if (!proto_tv.is_null() && !proto_tv.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Reflect.setPrototypeOf called with invalid prototype");
        return;
    }

    if (obj.flags.exotic_proxyobj) {
        bool res;
        if (!proxy_mop_set_proto(ctx.vm, ctx.heap, obj, proto_tv, &res)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_boolean(res);
        return;
    }
    HObject* proto_obj = proto_tv.is_null() ? null : (HObject*)proto_tv.get_heapptr();
    bool ok = ordinary_set_proto(ctx, obj, proto_obj);
    if (ctx.should_throw) return;
    ctx.result.set_boolean(ok);
}

// ============================================================================
// Reflect.isExtensible, ES6 §26.1.9
// ============================================================================
/// Returns true if the target object is extensible.
fn void builtin_reflect_isExtensible(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    if (ctx.argc > 0) target_tv = ctx.regs[ctx.base_reg];
    HObject* obj = reflect_require_object(ctx, target_tv, "Reflect.isExtensible called on non-object");
    if (obj == null) return;

    bool ext;
    if (!object_is_extensible(ctx.vm, ctx.heap, obj, &ext)) { proxy_ctx_ok(ctx); return; }
    ctx.result.set_boolean(ext);
}

// ============================================================================
// Reflect.preventExtensions, ES6 §26.1.12
// ============================================================================
/// Makes the target object non-extensible and returns a boolean.
fn void builtin_reflect_preventExtensions(BuiltinContext* ctx) {
    TVal target_tv; target_tv.set_undefined();
    if (ctx.argc > 0) target_tv = ctx.regs[ctx.base_reg];
    HObject* obj = reflect_require_object(ctx, target_tv, "Reflect.preventExtensions called on non-object");
    if (obj == null) return;

    if (obj.flags.exotic_proxyobj) {
        bool res;
        if (!proxy_mop_prevent_extensions(ctx.vm, ctx.heap, obj, &res)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_boolean(res);
        return;
    }
    obj.flags.extensible = false;
    ctx.result.set_boolean(true);
}

// ============================================================================
// Reflect.apply, ES6 §26.1.1
// ============================================================================
/// Calls `target` with `thisArgument` and the elements of `argumentsList`.
fn void builtin_reflect_apply(BuiltinContext* ctx) {
    TVal target; target.set_undefined();
    if (ctx.argc > 0) target = ctx.regs[ctx.base_reg];

    bool callable = false;
    if (target.is_lightfunc()) {
        callable = true;
    } else if (target.is_object()) {
        HObject* hobj = (HObject*)target.get_heapptr();
        if (hobj != null) callable = hobj.is_callable();
    }
    if (!callable) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Reflect.apply called on non-callable");
        return;
    }

    TVal this_arg; this_arg.set_undefined();
    if (ctx.argc > 1) this_arg = ctx.regs[ctx.base_reg + 1];

    TVal args_list; args_list.set_undefined();
    if (ctx.argc > 2) args_list = ctx.regs[ctx.base_reg + 2];
    if (!args_list.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Reflect.apply called with non-object arguments list");
        return;
    }

    apply_call(ctx, target, this_arg, args_list);
}

// ============================================================================
// Reflect.construct, ES6 §26.1.2
// ============================================================================
/// Constructs an instance of `target` using `argumentsList` and optional
/// `newTarget` as the value of new.target.
fn void builtin_reflect_construct(BuiltinContext* ctx) {
    TVal target; target.set_undefined();
    if (ctx.argc > 0) target = ctx.regs[ctx.base_reg];

    if (!target.is_object() || target.get_heapptr() == null ||
        !((HObject*)target.get_heapptr()).is_constructable()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Reflect.construct called on non-constructor");
        return;
    }

    TVal args_list; args_list.set_undefined();
    if (ctx.argc > 1) args_list = ctx.regs[ctx.base_reg + 1];
    if (!args_list.is_object()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Reflect.construct called with non-object arguments list");
        return;
    }

    TVal new_target = target;
    if (ctx.argc > 2) {
        new_target = ctx.regs[ctx.base_reg + 2];
        if (!new_target.is_object() || new_target.get_heapptr() == null ||
            !((HObject*)new_target.get_heapptr()).is_constructable()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Reflect.construct called with non-constructor newTarget");
            return;
        }
    }

    // Extract arguments from the array-like.
    HObject* arr_obj = (HObject*)args_list.get_heapptr();
    double raw_len = array_get_length_raw(arr_obj, ctx.heap, ctx);
    if (ctx.should_throw) return;
    if (math::is_nan(raw_len) || raw_len < 0) raw_len = 0;
    if (raw_len > 4294967295.0) raw_len = 4294967295.0;
    uint len = (uint)raw_len;
    if (len > 65535) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Reflect.construct: too many arguments");
        return;
    }

    TVal* args = null;
    if (len > 0) {
        args = (TVal*)ctx.heap.alloc_func(ctx.heap.heap_udata, TVal::size * len);
        if (args == null) { ctx.result.set_undefined(); return; }
    }

    bool is_plain_array = arr_obj.get_class() == hobject::ObjClass.ARRAY
                          && arr_obj.array_part() != null
                          && arr_obj.prop_count <= 1;
    uint actual = 0;
    for (uint i = 0; i < len; i++) {
        TVal elem;
        if (is_plain_array && i < arr_obj.array_size) {
            TVal dv = arr_obj.array_part()[i];
            if (!dv.is_undefined()) {
                if (actual < len) args[actual++] = dv;
                continue;
            }
        }
        char[20] buf;
        int n = (int)(io::bprintf(&buf, "%d", i) ?? buf[:0]).len;
        if (n <= 0 || n >= 20) break;
        HString* key = builtin_intern_string(ctx.heap, buf[:n]);
        if (key == null) break;
        int own_idx = arr_obj.find_prop_idx(key, ctx.heap);
        if (own_idx >= 0 && arr_obj.get_prop_flags((uint)own_idx, ctx.heap).is_accessor) {
            TVal getter = hobject::hobject_access_getter(arr_obj.prop_values()[own_idx]);
            elem = arr_invoke_getter_ctx(arr_obj, getter, ctx.heap, ctx);
            if (ctx.should_throw) {
                if (args != null) ctx.heap.free_func(ctx.heap.heap_udata, args);
                return;
            }
        } else if (own_idx >= 0) {
            elem = arr_obj.prop_values()[own_idx];
        } else if (!is_plain_array && arr_obj.get_class() == hobject::ObjClass.ARRAY && arr_obj.array_part() != null
                   && i < arr_obj.array_size && !arr_obj.array_part()[i].is_undefined()) {
            elem = arr_obj.array_part()[i];
        } else {
            hobject::PropLookupResult res = arr_obj.get_prop_or_accessor_proto(key, true, ctx.heap);
            if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                elem = arr_invoke_getter_ctx(arr_obj, res.acc.accessor_fn, ctx.heap, ctx);
                if (ctx.should_throw) {
                    if (args != null) ctx.heap.free_func(ctx.heap.heap_udata, args);
                    return;
                }
            } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                elem = res.data_val;
            } else {
                elem.set_undefined();
            }
        }
        if (actual < len) args[actual++] = elem;
    }

    TVal result = ctx.heap.construct_fn(ctx.vm, target, args, actual, new_target);
    if (ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        if (args != null) ctx.heap.free_func(ctx.heap.heap_udata, args);
        return;
    }
    if (args != null) ctx.heap.free_func(ctx.heap.heap_udata, args);
    *ctx.result = result;
}

// ============================================================================
// Object.getPrototypeOf, ES5 §15.2.3.2
// ============================================================================
/// Returns the [[Prototype]] of an object. Throws TypeError if argument is
/// not an object (null or undefined).
fn void builtin_object_getPrototypeOf(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.getPrototypeOf requires a value");
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // Lightfuncs have Function.prototype as their [[Prototype]]
    if (arg.is_lightfunc()) {
        if (ctx.heap.function_proto != null) {
            ctx.result.set_object(ctx.heap.function_proto);
        } else {
            ctx.result.set_null();
        }
        return;
    }
    if (!arg.is_object()) {
        if (arg.is_null() || arg.is_undefined()) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Object.getPrototypeOf called on null or undefined");
            return;
        }
        // ES2015+: ToObject for primitives
        if (!builtin_to_object(ctx, arg)) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Object.getPrototypeOf: ToObject failed");
            return;
        }
        arg = *ctx.result;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    if (obj.flags.exotic_proxyobj) {
        TVal pproto;
        if (!proxy_mop_get_proto(ctx.vm, ctx.heap, obj, &pproto)) { proxy_ctx_ok(ctx); return; }
        *ctx.result = pproto;
        return;
    }
    HObject* proto = obj.prototype;
    if (proto == null) {
        ctx.result.set_null();
        return;
    }
    ctx.result.set_object(proto);
}

// ============================================================================
// Object.isExtensible, ES5 §15.2.3.13
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
    if (obj.flags.exotic_proxyobj) {
        bool ext;
        if (!proxy_mop_is_extensible(ctx.vm, ctx.heap, obj, &ext)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_boolean(ext);
        return;
    }
    ctx.result.set_boolean(obj.is_extensible());
}

// ============================================================================
// Object.preventExtensions, ES5 §15.2.3.10
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
    if (obj.flags.exotic_proxyobj) {
        bool pok;
        if (!proxy_mop_prevent_extensions(ctx.vm, ctx.heap, obj, &pok)) { proxy_ctx_ok(ctx); return; }
        if (!pok) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "'preventExtensions' on proxy: trap returned falsish");
            return;
        }
        ctx.result.set_object(obj);
        return;
    }
    obj.flags.extensible = false;
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.getOwnPropertyDescriptor, ES5 §15.2.3.3
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
        if (key_val.is_string()) {
            key = key_val.get_heapptr();
        } else if (key_val.is_fastint()) {
            key = ctx.heap.int_to_hstring(key_val.get_fastint());
            if (key == null) { ctx.result.set_undefined(); return; }
        } else if (key_val.is_number()) {
            key = builtin_number_to_hstring(ctx.heap, key_val.get_number());
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
                desc.put_prop(ctx.heap.str(heap::BuiltinStr.VALUE), name_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal w_tv; w_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal e_tv; e_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal c_tv; c_tv.set_boolean(true);
                desc.put_prop(builtin_intern_string(ctx.heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

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
            {
                HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch err5 = desc_raw) { ctx.result.set_undefined(); return; }
                HObject* desc = desc_raw;
                desc.prototype = ctx.heap.object_proto;

                TVal len_tv; len_tv.set_fastint((long)(meta.arity >= 0 ? meta.arity : 0));
                desc.put_prop(ctx.heap.str(heap::BuiltinStr.VALUE), len_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal w_tv; w_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal e_tv; e_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal c_tv; c_tv.set_boolean(true);
                desc.put_prop(builtin_intern_string(ctx.heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

                ctx.result.set_object(desc);
            }
            return;
        } else if (key_hstr.equals("prototype")) {
            // ES5 §15.3.5: Function.prototype property of constructors
            // {writable: false, enumerable: false, configurable: false}
            // Map lightfunc indices to their prototype objects from the heap.
            HObject* proto = null;
            switch (fn_idx) {
                case builtins::Builtin.TYPE_ERROR.ordinal:      proto = ctx.heap.type_err_proto; break;
                case builtins::Builtin.RANGE_ERROR.ordinal:     proto = ctx.heap.range_err_proto; break;
                case builtins::Builtin.REFERENCE_ERROR.ordinal:  proto = ctx.heap.ref_err_proto; break;
                case builtins::Builtin.SYNTAX_ERROR.ordinal:    proto = ctx.heap.syntax_err_proto; break;
                case builtins::Builtin.EVAL_ERROR.ordinal:      proto = ctx.heap.eval_err_proto; break;
                case builtins::Builtin.URI_ERROR.ordinal:       proto = ctx.heap.uri_err_proto; break;
                case builtins::Builtin.AGGREGATE_ERROR.ordinal:  proto = ctx.heap.aggregate_err_proto; break;
                case builtins::Builtin.BOOLEAN.ordinal:         proto = ctx.heap.bool_proto; break;
                default: break;
            }
            if (proto != null) {
                HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch err6 = desc_raw) { ctx.result.set_undefined(); return; }
                HObject* desc = desc_raw;
                desc.prototype = ctx.heap.object_proto;

                TVal proto_tv; proto_tv.set_object(proto);
                desc.put_prop(ctx.heap.str(heap::BuiltinStr.VALUE), proto_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal w_tv; w_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal e_tv; e_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal c_tv; c_tv.set_boolean(false);
                desc.put_prop(builtin_intern_string(ctx.heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

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
        // ToPropertyKey(undefined) = "undefined", still runs the proxy trap
        // (and the revoked-proxy TypeError).
        if (obj != null && obj.flags.exotic_proxyobj) {
            HString* ukey = ctx.heap.str(heap::BuiltinStr.UNDEFINED);
            ProxyDesc upd;
            if (!proxy_mop_get_own(ctx.vm, ctx.heap, obj, ukey, &upd)) { proxy_ctx_ok(ctx); return; }
            if (!upd.found) { ctx.result.set_undefined(); return; }
            upd.complete();
            HObject* udesc = proxy_desc_to_object(ctx.heap, &upd);
            if (udesc == null) { ctx.result.set_undefined(); return; }
            ctx.result.set_object(udesc);
            return;
        }
        ctx.result.set_undefined();
        return;
    }
    TVal key_val = ctx.regs[ctx.base_reg + 1];
    // ES2015+ ToPropertyKey. The shared helper passes symbols through, coerces
    // objects via ToPrimitive, and interns the key: property lookup compares by
    // pointer identity, so an un-interned concatenation result would miss.
    HString* key_hstr = builtin_to_property_key_vm(ctx, &key_val);
    if (key_hstr == null) {
        if (ctx.should_throw) return;
        ctx.result.set_undefined();
        return;
    }
    void* key = key_hstr;

    // Proxy exotic: route through [[GetOwnProperty]].
    if (obj.flags.exotic_proxyobj) {
        ProxyDesc pd;
        if (!proxy_mop_get_own(ctx.vm, ctx.heap, obj, key_hstr, &pd)) { proxy_ctx_ok(ctx); return; }
        if (!pd.found) { ctx.result.set_undefined(); return; }
        pd.complete();
        HObject* desc_out = proxy_desc_to_object(ctx.heap, &pd);
        if (desc_out == null) { ctx.result.set_undefined(); return; }
        ctx.result.set_object(desc_out);
        return;
    }

    // Module Namespace Exotic [[GetOwnProperty]], §10.4.6.5. Exports are
    // presented as DATA descriptors {value, writable:true, enumerable:true,
    // configurable:false}; symbols (Symbol.toStringTag) keep their stored flags.
    // Reading a TDZ export throws ReferenceError (propagated via proxy_ctx_ok).
    if (obj.flags.exotic_module_ns) {
        ProxyDesc nd;
        if (!module_ns_own_desc(ctx.vm, ctx.heap, obj, key_hstr, &nd)) { proxy_ctx_ok(ctx); return; }
        if (!nd.found) { ctx.result.set_undefined(); return; }
        nd.complete();
        HObject* nd_out = proxy_desc_to_object(ctx.heap, &nd);
        if (nd_out == null) { ctx.result.set_undefined(); return; }
        ctx.result.set_object(nd_out);
        return;
    }

    // String exotic [[GetOwnProperty]], ES5 §15.5.5.1
    // Numeric indices on String exotic objects return character descriptors.
    // This runs AFTER the default lookup as a fallback (step 1 of spec: try
    // default first, then synthesize if not found).

    // Look up own property (not prototype chain - don't fall through to array_part
    // unless the key matches a numeric index and this is an Array)
    int idx = obj.find_prop_idx(key, ctx.heap);
    if (idx < 0) {
        // TypedArray exotic [[GetOwnProperty]], ES2015 §9.4.5.3: integer
        // indices in range are own data properties {value, writable:true,
        // enumerable:true, configurable:true}; out of range/detached -> undefined.
        if (is_typed_array_class(obj.get_class())) {
            HString* key_str = (HString*)key;
            if (key_str.is_arridx()) {
                uint ta_idx = key_str.array_index();
                HObject* ta_buf = (*obj.extra_ptr()).view.buffer;
                uint ta_shift = builtins::ta_elem_shift(obj.get_class());
                uint ta_count = ta_buf != null && (*ta_buf.extra_ptr()).ab.data != null
                    ? (*obj.extra_ptr()).view.byte_length >> ta_shift : 0;
                if (ta_idx < ta_count) {
                    char* ta_base = (*ta_buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset;
                    TVal ta_val = builtins::ta_load_element(ctx.heap, ta_base, obj.get_class(), ta_idx);

                    HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                    if (catch err = desc_raw) { ctx.result.set_undefined(); return; }
                    HObject* desc = desc_raw;
                    desc.prototype = ctx.heap.object_proto;
                    desc.put_prop(ctx.heap.str(heap::BuiltinStr.VALUE), ta_val, hobject::PROP_FLAGS_WEC, ctx.heap);
                    TVal w_tv; w_tv.set_boolean(true);
                    desc.put_prop(builtin_intern_string(ctx.heap, "writable"), w_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                    TVal e_tv; e_tv.set_boolean(true);
                    desc.put_prop(builtin_intern_string(ctx.heap, "enumerable"), e_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                    TVal c_tv; c_tv.set_boolean(true);
                    desc.put_prop(builtin_intern_string(ctx.heap, "configurable"), c_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                    ctx.result.set_object(desc);
                    return;
                }
                ctx.result.set_undefined();
                return;
            }
        }
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

                HString* value_key = ctx.heap.str(heap::BuiltinStr.VALUE);
                TVal len_tv;
                len_tv.set_fastint((long)obj.array_size);
                desc.put_prop(value_key, len_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

                HString* writable_key = builtin_intern_string(ctx.heap, "writable");
                TVal w_tv;
                w_tv.set_boolean(true);
                desc.put_prop(writable_key, w_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

                HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
                TVal e_tv;
                e_tv.set_boolean(false);
                desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

                HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
                TVal c_tv;
                c_tv.set_boolean(false);
                desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

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

            HString* value_key = ctx.heap.str(heap::BuiltinStr.VALUE);
            TVal vt;
            vt.set_string(key_str);
            // Actually set the array element value as the descriptor value
            TVal array_val = obj.array_part()[arr_idx];
            desc.put_prop(value_key, array_val, hobject::PROP_FLAGS_WEC, ctx.heap);

            HString* writable_key = builtin_intern_string(ctx.heap, "writable");
            TVal w_tv;
            w_tv.set_boolean(true);
            desc.put_prop(writable_key, w_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

            HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
            TVal e_tv;
            e_tv.set_boolean(true);
            desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

            HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
            TVal c_tv;
            c_tv.set_boolean(true);
            desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

            ctx.result.set_object(desc);
            return;
        }

        // String exotic fallback, ES5 §15.5.5.1 step 3-4:
        // String indexed properties are non-writable, enumerable, non-configurable.
        if (obj.get_class() == hobject::ObjClass.STRING &&
            (*obj.extra_ptr()).prim.primitive_value.is_string() &&
            is_numeric && kd.len > 0 && kd.len <= 10) {
            HString* prim_str = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
            if (arr_idx < (ulong)prim_str.char_length()) {
                uint cp = prim_str.char_at_unchecked((uint)arr_idx);
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
    hobject::PropFlags entry_flags = obj.get_prop_flags((uint)idx, ctx.heap);

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
        desc.put_prop(get_key, hobject::hobject_access_getter(*entry), hobject::PROP_FLAGS_WEC, ctx.heap);

        HString* set_key = builtin_intern_string(ctx.heap, "set");
        desc.put_prop(set_key, hobject::hobject_access_setter(*entry), hobject::PROP_FLAGS_WEC, ctx.heap);

        HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
        TVal e_tv;
        e_tv.set_boolean(entry_flags.enumerable);
        desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

        HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
        TVal c_tv;
        c_tv.set_boolean(entry_flags.configurable);
        desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    } else {
        // Data descriptor: { value, writable, enumerable, configurable }
        HString* value_key = ctx.heap.str(heap::BuiltinStr.VALUE);
        desc.put_prop(value_key, *entry, hobject::PROP_FLAGS_WEC, ctx.heap);

        HString* writable_key = builtin_intern_string(ctx.heap, "writable");
        TVal w_tv;
        w_tv.set_boolean(entry_flags.writable);
        desc.put_prop(writable_key, w_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

        HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
        TVal e_tv;
        e_tv.set_boolean(entry_flags.enumerable);
        desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

        HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
        TVal c_tv;
        c_tv.set_boolean(entry_flags.configurable);
        desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    }

    ctx.result.set_object(desc);
}

// ============================================================================
// Object.getOwnPropertyDescriptors, ES2017 §19.1.2.9
// ============================================================================
/// Returns an object whose own keys are the own property keys of ToObject(arg),
/// each mapped to that property's descriptor object.
fn void builtin_object_getOwnPropertyDescriptors(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.getOwnPropertyDescriptors called on non-object");
        return;
    }
    TVal arg0 = ctx.regs[ctx.base_reg];
    if (arg0.is_null() || arg0.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.getOwnPropertyDescriptors called on non-object");
        return;
    }

    HObject*? res_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch e = res_raw) { ctx.result.set_undefined(); return; }
    HObject* res = res_raw;
    res.prototype = ctx.heap.object_proto;

    // Lightfunc: synthesize .name and .length descriptors from metadata. The
    // generic HObject path (below) would crash because lightfuncs aren't
    // HObject-backed.
    if (arg0.is_lightfunc()) {
        uint lf_idx = (uint)(usz)arg0.get_heapptr();
        builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_idx);
        HString* name_key = (HString*)ctx.heap.strs[heap::BuiltinStr.NAME];
        HString* length_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        if (lf_meta.name.len > 0 && name_key != null) {
            HObject*? ndesc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try ndesc = ndesc_raw) {
                ndesc.prototype = ctx.heap.object_proto;
                HString* nstr = builtin_intern_string(ctx.heap, lf_meta.name);
                TVal ntv; ntv.set_string(nstr);
                ndesc.put_prop(ctx.heap.str(heap::BuiltinStr.VALUE), ntv, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal w; w.set_boolean(false);
                ndesc.put_prop(builtin_intern_string(ctx.heap, "writable"), w, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal e; e.set_boolean(false);
                ndesc.put_prop(builtin_intern_string(ctx.heap, "enumerable"), e, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal c; c.set_boolean(true);
                ndesc.put_prop(builtin_intern_string(ctx.heap, "configurable"), c, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal ndtv; ndtv.set_object(ndesc);
                res.put_prop(name_key, ndtv, hobject::PROP_FLAGS_WEC, ctx.heap);
            }
        }
        if (length_key != null) {
            HObject*? ldesc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try ldesc = ldesc_raw) {
                ldesc.prototype = ctx.heap.object_proto;
                TVal ltv; ltv.set_fastint((long)(lf_meta.arity >= 0 ? lf_meta.arity : 0));
                ldesc.put_prop(ctx.heap.str(heap::BuiltinStr.VALUE), ltv, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal w; w.set_boolean(false);
                ldesc.put_prop(builtin_intern_string(ctx.heap, "writable"), w, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal e; e.set_boolean(false);
                ldesc.put_prop(builtin_intern_string(ctx.heap, "enumerable"), e, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal c; c.set_boolean(true);
                ldesc.put_prop(builtin_intern_string(ctx.heap, "configurable"), c, hobject::PROP_FLAGS_WEC, ctx.heap);
                TVal ldtv; ldtv.set_object(ldesc);
                res.put_prop(length_key, ldtv, hobject::PROP_FLAGS_WEC, ctx.heap);
            }
        }
        ctx.result.set_object(res);
        return;
    }
    if (!arg0.is_object()) {
        if (!builtin_to_object(ctx, arg0)) { ctx.result.set_undefined(); return; }
        arg0 = *ctx.result;
    }
    HObject* obj = (HObject*)arg0.get_heapptr();
    if (obj == null) { ctx.result.set_undefined(); return; }

    // Proxy exotic: [[OwnPropertyKeys]] + [[GetOwnProperty]] per key.
    if (obj.flags.exotic_proxyobj) {
        HObject* karr;
        if (!proxy_mop_own_keys(ctx.vm, ctx.heap, obj, &karr)) { proxy_ctx_ok(ctx); return; }
        for (uint i = 0; i < karr.array_used; i++) {
            TVal el = karr.array_part()[i];
            if (!el.is_string()) continue;
            HString* k = (HString*)el.get_heapptr();
            ProxyDesc pd;
            if (!proxy_mop_get_own(ctx.vm, ctx.heap, obj, k, &pd)) { proxy_ctx_ok(ctx); return; }
            if (!pd.found) continue;
            pd.complete();
            HObject* dobj = proxy_desc_to_object(ctx.heap, &pd);
            if (dobj == null) continue;
            TVal dtv; dtv.set_object(dobj);
            res.put_prop((void*)k, dtv, hobject::PROP_FLAGS_WEC, ctx.heap);
        }
        ctx.result.set_object(res);
        return;
    }

    // Collect own keys from every source so enumeration matches
    // [[OwnPropertyKeys]]: String-exotic char indices, the dense array part,
    // and named/symbol entries in the property table.
    uint cap = obj.prop_count + obj.array_size + 64;
    HString** keys = (HString**)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(cap * HString*::size));
    if (keys == null) { ctx.result.set_undefined(); return; }
    defer ctx.heap.free_func(ctx.heap.heap_udata, keys);
    uint kn = 0;

    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) {
            for (uint i = 0; i < prim.char_length() && kn < cap; i++) {
                HString* k = ctx.heap.int_to_hstring((long)i);
                if (k != null) keys[kn++] = k;
            }
        }
    }
    if (obj.flags.exotic_array || obj.flags.exotic_arguments) {
        for (uint i = 0; i < obj.array_size && kn < cap; i++) {
            if (!obj.array_part()[i].is_undefined()) {
                HString* k = ctx.heap.int_to_hstring((long)i);
                if (k != null) keys[kn++] = k;
            }
        }
    }
    for (uint i = 0; i < obj.prop_count && kn < cap; i++) {
        void* kptr = obj.prop_key_at(i, ctx.heap);
        if (kptr == null) continue;
        keys[kn++] = (HString*)kptr;
    }

    for (uint ki = 0; ki < kn; ki++) {
        HString* key = keys[ki];
        // Reuse the singular builtin's descriptor logic via a scratch window.
        TVal[2] sub_regs;
        sub_regs[0] = arg0;
        sub_regs[1].set_string(key);
        BuiltinContext sub;
        sub = *ctx;
        sub.regs = &sub_regs;
        sub.base_reg = 0;
        sub.argc = 2;
        TVal desc_result;
        desc_result.set_undefined();
        sub.result = &desc_result;
        sub.is_constructor = false;
        sub.should_throw = false;
        builtin_object_getOwnPropertyDescriptor(&sub);
        if (sub.should_throw) {
            ctx.should_throw = true;
            ctx.throw_value = sub.throw_value;
            return;
        }
        if (desc_result.is_undefined()) continue;
        res.put_prop(key, desc_result, hobject::PROP_FLAGS_WEC, ctx.heap);
    }

    ctx.result.set_object(res);
}

/// ES5 [[Get]] for descriptor field extraction, invokes getters per §8.10.5.
/// Returns true if the property exists, setting `out` to the result value.
fn bool desc_get(BuiltinContext* ctx, HObject* obj, hstring::HString* key, TVal* out) {
    if (obj.flags.exotic_proxyobj) {
        TVal recv; recv.set_object(obj);
        if (!proxy_mop_get(ctx.vm, ctx.heap, obj, key, recv, out)) {
            proxy_ctx_ok(ctx);
            return false;
        }
        return true;
    }
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto(key, true, ctx.heap);
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

/// Re-checks whether `key`, already known to be an own String-keyed
/// property of `obj` (as produced by collect_own_enum_string_keys with
/// require_enumerable = false), is *currently* enumerable.  Object.entries/
/// values must call this immediately before [[Get]]ing each key, since an
/// earlier key's getter may have changed a later key's enumerability
/// in-between the snapshot and the fetch (EnumerableOwnPropertyNames
/// interleaves [[GetOwnProperty]] and [[Get]] per key, not once up front).
/// Dense array indices, String-exotic character indices, and TypedArray
/// indices are always enumerable by spec and can't be redefined non-
/// enumerable without leaving the property table, so only named
/// properties need a fresh flags lookup.
fn bool key_is_currently_enumerable(HObject* obj, hstring::HString* key, Heap* h) {
    int idx = obj.find_prop_idx(key, h);
    if (idx < 0) return true;
    return obj.get_prop_flags((uint)idx, h).enumerable;
}

/// [[Get]] for Object.values/entries enumeration: like desc_get, but also serves
/// the lazily-materialised indexed character properties of a String exotic object
/// (which don't live in the property table and so aren't found by desc_get).
fn bool desc_get_enum(BuiltinContext* ctx, HObject* obj, hstring::HString* key, TVal* out) {
    if (obj.flags.exotic_stringobj && key.is_arridx()
        && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        uint ci = key.array_index();
        if (prim != null && ci < prim.char_length()) {
            uint bstart = prim.char_offset_to_byte_offset(ci);
            uint bend = prim.char_offset_to_byte_offset(ci + 1);
            char[] data = prim.get_data();
            HString*? ch = builtin_intern_string(ctx.heap, data[bstart:bend - bstart]);
            if (try c = ch) { out.set_string(c); return true; }
            out.set_undefined();
            return true;
        }
    }
    return desc_get(ctx, obj, key, out);
}

/// Perform `[[Set]]` of `key` = `val` on `obj` with Throw=true (Object.assign
/// semantics, ES2015 §19.1.2.2).  Invokes setters when an accessor exists
/// (own or on prototype chain).  Throws TypeError when the target is
/// non-writable for a new/existing data property or non-extensible for a
/// new property.  Returns true on success, false on error (ctx->should_throw
/// is set in the latter case).
fn bool obj_assign_set(BuiltinContext* ctx, HObject* obj, hstring::HString* key, TVal* val) {
    if (obj.flags.exotic_proxyobj) {
        TVal recv; recv.set_object(obj);
        bool sres;
        if (!proxy_mop_set(ctx.vm, ctx.heap, obj, key, *val, recv, &sres)) {
            proxy_ctx_ok(ctx);
            return false;
        }
        if (!sres) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "'set' on proxy: trap returned falsish");
            return false;
        }
        return true;
    }
    // Array exotic "length" (ES2015 §9.4.2.1 ArraySetLength via OrdinarySet):
    // a Set on "length" must go through ArraySetLength, not a plain data-
    // property write, so growing/shrinking the array and dropping
    // out-of-range elements happens as it would for a direct assignment.
    if (obj.get_class() == hobject::ObjClass.ARRAY && key.equals("length")) {
        bool len_writable = true;
        if (obj.flags.exotic_array) len_writable = obj.flags.array_len_writable;
        int len_idx = obj.find_prop_idx(key, ctx.heap);
        if (len_idx >= 0) len_writable = obj.get_prop_flags((uint)len_idx, ctx.heap).writable;
        double num = builtin_to_number_vm(ctx, val);
        if (ctx.should_throw) return false;
        if (num != num || num < 0.0 || num > 4294967295.0 || num != math::floor(num)) {
            builtin_throw(ctx, ctx.heap.range_err_proto, "Invalid array length");
            return false;
        }
        if (!len_writable) {
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot assign to read only property 'length'");
            return false;
        }
        array_set_length(obj, (uint)num, ctx.heap);
        return true;
    }

    // String exotic own character index (ES2015 §9.4.3.1): a non-configurable,
    // non-writable, enumerable data property for every index < the string's
    // length. Not materialized as a real own property, so it must be checked
    // before the general own-property lookup below.
    if (obj.flags.exotic_stringobj && key.is_arridx()
        && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null && (ulong)key.array_index() < (ulong)prim.char_length()) {
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot assign to read only property");
            return false;
        }
    }

    // Step 1: own property
    int idx = obj.find_prop_idx((void*)key, ctx.heap);
    if (idx >= 0) {
        hobject::PropFlags f = obj.get_prop_flags((uint)idx, ctx.heap);
        if (f.is_accessor) {
            // Accessor, invoke the setter
            TVal setter = hobject::hobject_access_setter(obj.prop_values()[(uint)idx]);
            if (setter.is_undefined() || setter.is_null()) {
                // No setter, Set returns true (no-op, per spec).
                return true;
            }
            if (ctx.heap.call_fn == null || ctx.vm == null) {
                // VM call_fn unavailable, degrade silently (matches legacy behavior)
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
        // Writable data property, write value (preserve existing flags)
        TVal* entry = &obj.prop_values()[(uint)idx];
        ctx.heap.tval_copy_ref(entry, val);
        return true;
    }

    // Step 2: not an own property, check prototype chain for accessor
    hobject::AccessorResult acc = obj.find_accessor_proto((void*)key, false, ctx.heap);
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

    // Step 3: not on prototype chain, create new data property if extensible
    if (!obj.flags.extensible) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot add property to non-extensible object");
        return false;
    }
    obj.put_prop((void*)key, *val, hobject::PROP_FLAGS_WEC, ctx.heap);
    return true;
}

/// Field-presence flags returned by `to_property_descriptor` so callers can
/// distinguish a descriptor that omits a field from one that sets it to undefined
/// (e.g. when the value is inherited via an accessor with no getter). Per ES5
/// §8.10.5, even an `undefined` field is "present" in the descriptor.
struct DescFields {
    bool has_enumerable;
    bool has_configurable;
    bool has_value;
    bool has_writable;
    bool has_get;
    bool has_set;
}

/// ToPropertyDescriptor, ES5 §8.10.5
///
/// Parses a descriptor object into PropFlags + value (or getter/setter).
/// `out_flags` receives the flags to use for a newly created property.
/// `out_value` receives the data value (or getter/setter).
/// `is_accessor_out` is set true when the descriptor is an accessor descriptor.
/// `out_fields` (optional) receives which fields were present on the descriptor
/// (counts inherited accessor results that returned undefined as present).
fn bool to_property_descriptor(BuiltinContext* ctx, HObject* desc_obj,
                               hobject::PropFlags* out_flags,
                               TVal* out_value, bool* is_accessor_out,
                               DescFields* out_fields) {
    // Check the five possible descriptor fields.
    HString* enum_key   = builtin_intern_string(ctx.heap, "enumerable");
    HString* conf_key   = builtin_intern_string(ctx.heap, "configurable");
    HString* value_key  = ctx.heap.str(heap::BuiltinStr.VALUE);
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
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Invalid property descriptor, cannot have both data and accessor fields");
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
    if (out_fields != null) {
        out_fields.has_enumerable   = has_enumerable;
        out_fields.has_configurable = has_configurable;
        out_fields.has_value        = has_value;
        out_fields.has_writable     = has_writable;
        out_fields.has_get          = has_get;
        out_fields.has_set          = has_set;
    }
    return true;
}

/// Object.defineProperty, ES5 §15.2.3.6
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

    // Step 2: Convert property key to string or resolve Symbol key.
    // Symbol keys are valid property keys and must pass through without
    // ToString coercion, ToString(Symbol) would throw TypeError.
    if (ctx.argc < 2) {
        ctx.result.set_undefined();
        return;
    }
    TVal key_val = ctx.regs[ctx.base_reg + 1];
    HString* key_hstr = builtin_to_property_key_vm(ctx, &key_val);
    if (ctx.should_throw) return;
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

    // Proxy exotic: route through [[DefineOwnProperty]].
    if (obj.flags.exotic_proxyobj) {
        ProxyDesc pd;
        if (!proxy_object_to_desc(ctx.vm, ctx.heap, desc_obj, &pd)) { proxy_ctx_ok(ctx); return; }
        bool dok;
        if (!proxy_mop_define(ctx.vm, ctx.heap, obj, key_hstr, &pd, &dok)) { proxy_ctx_ok(ctx); return; }
        if (!dok) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "'defineProperty' on proxy: trap returned falsish");
            return;
        }
        *ctx.result = arg0;
        return;
    }

    // Step 4: ToPropertyDescriptor
    hobject::PropFlags desc_flags;
    TVal[2] desc_vals;  // [0]=value/getter, [1]=setter (unused for data)
    bool is_accessor;
    DescFields desc_fields;
    if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_accessor, &desc_fields)) {
        if (ctx.should_throw) return;
        ctx.result.set_undefined();
        return;
    }
    bool is_generic = !is_accessor && !desc_fields.has_value && !desc_fields.has_writable;
    bool has_any_field = desc_fields.has_enumerable || desc_fields.has_configurable
                      || desc_fields.has_value || desc_fields.has_writable
                      || desc_fields.has_get || desc_fields.has_set;

    // Module Namespace Exotic [[DefineOwnProperty]] (§10.4.6.4): only a no-op
    // redefinition (every present field already matches the current descriptor)
    // succeeds; any other define throws TypeError. A TDZ export read throws
    // ReferenceError (propagated via proxy_ctx_ok).
    if (obj.flags.exotic_module_ns) {
        ProxyDesc md = module_ns_desc_from_fields(is_accessor, &desc_flags, &desc_vals, &desc_fields);
        bool err;
        bool ok = module_ns_define_own(ctx.vm, ctx.heap, obj, key_hstr, &md, &err);
        if (err) { proxy_ctx_ok(ctx); return; }
        if (!ok) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine property on module namespace");
            return;
        }
        *ctx.result = arg0;
        return;
    }

    // Integer-Indexed exotic [[DefineOwnProperty]] (ES2022 §10.4.5.3): routes
    // through the shared ordinary_define_own, which special-cases canonical
    // numeric index keys on TypedArrays. Non-numeric-index keys on a
    // TypedArray fall through to the general (ordinary object) path below.
    if (is_typed_array_class(obj.get_class())) {
        ProxyDesc pd;
        pd.found = true;
        if (is_accessor) {
            pd.has_get = desc_fields.has_get; pd.getter = desc_vals[0];
            pd.has_set = desc_fields.has_set; pd.setter = desc_vals[1];
        } else {
            pd.has_value = desc_fields.has_value; pd.value = desc_vals[0];
            pd.has_writable = desc_fields.has_writable; pd.writable = desc_flags.writable;
        }
        pd.has_enumerable = desc_fields.has_enumerable; pd.enumerable = desc_flags.enumerable;
        pd.has_configurable = desc_fields.has_configurable; pd.configurable = desc_flags.configurable;
        bool dok;
        if (!ordinary_define_own(ctx.vm, ctx.heap, obj, key_hstr, &pd, &dok)) { proxy_ctx_ok(ctx); return; }
        if (!dok) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine property");
            return;
        }
        *ctx.result = arg0;
        return;
    }

    // ES2024 §10.4.2.4 ArraySetLength: special handling when defining 'length'
    // on an Array. Shared with Reflect.defineProperty and defineProperties via
    // ordinary_define_own / array_set_length_desc, see proxy.c3.
    bool is_array_length = obj.get_class() == hobject::ObjClass.ARRAY
        && key_hstr.equals("length");
    if (is_array_length) {
        ProxyDesc pd;
        pd.has_value = desc_fields.has_value; pd.value = desc_vals[0];
        pd.has_writable = desc_fields.has_writable; pd.writable = desc_flags.writable;
        // ArraySetLength only inspects the accessor PRESENCE flags (an
        // accessor desc on "length" is rejected outright), so getter/setter
        // stay zeroed.
        pd.has_get = desc_fields.has_get;
        pd.has_set = desc_fields.has_set;
        pd.has_enumerable = desc_fields.has_enumerable; pd.enumerable = desc_flags.enumerable;
        pd.has_configurable = desc_fields.has_configurable; pd.configurable = desc_flags.configurable;
        bool dok;
        if (!array_set_length_desc(ctx.vm, ctx.heap, obj, &pd, &dok)) { proxy_ctx_ok(ctx); return; }
        if (!dok) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine property: length");
            return;
        }
        ctx.result.set_object(obj);
        return;
    }

    // Step 5: [[DefineOwnProperty]]
    // Check if property already exists
    int existing_idx = obj.find_prop_idx(key, ctx.heap);

    // Dense array promotion: if the key is a valid array index and the element
    // exists in the dense array part but not in named props, promote it with
    // WEC flags so the normal [[DefineOwnProperty]] update path handles it.
    // We use a non-WEC flag (WC: enumerable=false) to force put_prop into the
    // named property table; otherwise put_prop re-routes back to dense storage
    // (leaving find_prop_idx returning -1) and the update creates a new property
    // with all-false default flags instead of preserving the WEC defaults.
    // After creating the named entry we fix its flags to WEC and clear the dense
    // slot to prevent the VM GETPROP fast path from returning the stale dense value.
    if (existing_idx < 0 && ((HString*)key).is_arridx()) {
        uint arr_idx = ((HString*)key).array_index();
        TVal* ap = obj.array_part();
        if (ap != null && arr_idx < obj.array_size) {
            TVal arr_val = ap[arr_idx];
            if (!arr_val.is_undefined()) {
                // PROP_FLAGS_WC has enumerable=false, put_prop routes to named table.
                obj.put_prop((void*)key, arr_val, hobject::PROP_FLAGS_WC, ctx.heap);
                existing_idx = obj.find_prop_idx(key, ctx.heap);
                if (existing_idx >= 0) {
                    // Fix flags to WEC: dense elements are WEC data properties.
                    obj.set_prop_flags((uint)existing_idx, hobject::PROP_FLAGS_WEC, ctx.heap);
                    // Clear the dense slot: the named-prop table is now authoritative.
                    // This prevents the VM GETPROP fast path from returning the stale
                    // dense value instead of the (soon-to-be-updated) named value.
                    // set_array_idx decrefs the dense slot's own reference to arr_val
                    // (a separate owning copy from the one put_prop just anchored above)
                    // and already decrements array_used on the non-undefined→undefined
                    // transition, so no separate decrement is needed here.
                    TVal hole; hole.set_undefined();
                    obj.set_array_idx(arr_idx, hole, ctx.heap);
                }
            }
        }
    }

    // ES5 §15.4.5.1 step 4: For Arrays, if 'name' is a valid array index >= length
    // and length is non-writable, throw TypeError.
    if (obj.get_class() == hobject::ObjClass.ARRAY && key_hstr.is_arridx()) {
        uint arr_idx2 = key_hstr.array_index();
        uint cur_arr_len = array_get_length(obj, ctx.heap);
        if (arr_idx2 >= cur_arr_len) {
            bool arr_len_writable = true;
            HString* len_key_i2 = ctx.heap.str(heap::BuiltinStr.LENGTH);
            if (len_key_i2 != null) {
                int li2 = obj.find_prop_idx(len_key_i2, ctx.heap);
                if (li2 >= 0) arr_len_writable = obj.get_prop_flags((uint)li2, ctx.heap).writable;
            }
            if (!arr_len_writable) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot define array element: length is non-writable");
                return;
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
        // Property doesn't exist, check extensibility
        if (!obj.flags.extensible) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot define property on a non-extensible object");
            return;
        }
        // Create new property
        if (is_accessor) {
            // Accessor property, set value as getter placeholder
            obj.put_prop(key, desc_vals[0], desc_flags, ctx.heap);
            int idx = obj.find_prop_idx(key, ctx.heap);
            if (idx >= 0) {
                // put_prop above anchored desc_vals[0] as the (placeholder) slot value;
                // the GS cell holds its own incref'd copy, so release the placeholder's
                // reference before replacing the slot.
                ctx.heap.decref_tval(&obj.prop_values()[idx]);
                obj.prop_values()[idx] = hobject::hobject_create_accessors(ctx.heap, desc_vals[0], desc_vals[1]);
            }
            // Clear the dense array slot so arr_get_elem_vm falls through to the
            // named-property accessor rather than returning the getter function object.
            if (key_hstr.is_arridx()) {
                uint ai = key_hstr.array_index();
                TVal* ap = obj.array_part();
                if (ap != null && ai < obj.array_size) {
                    TVal undef; undef.set_undefined();
                    ap[ai] = undef;
                }
            }
        } else {
            obj.put_prop(key, desc_vals[0], desc_flags, ctx.heap);
        }
    } else {
        // Property exists, validate changes per ES5 §8.12.9
        hobject::PropValue* current = &obj.prop_values()[existing_idx];
        hobject::PropFlags cur_flags = obj.get_prop_flags((uint)existing_idx, ctx.heap);
        TVal cur_value = *current;

        // Check if descriptor is empty (generic, no fields)
        bool has_value_field   = (ctx.regs[ctx.base_reg + 2].is_object()); // already validated
        // We've already extracted descriptor fields above, so check what was present

        // Check configurable constraint, ES5 §8.12.9 step 8
        if (!cur_flags.configurable) {
            bool reject = false;
            // Only reject if the field is actually present in the descriptor AND differs
            bool desc_has_conf = false;
            bool desc_has_enum = false;
            HString* tmp_conf_k = builtin_intern_string(ctx.heap, "configurable");
            HString* tmp_enum_k = builtin_intern_string(ctx.heap, "enumerable");
            if (tmp_conf_k != null) desc_has_conf = desc_obj.find_prop_idx(tmp_conf_k, ctx.heap) >= 0;
            if (tmp_enum_k != null) desc_has_enum = desc_obj.find_prop_idx(tmp_enum_k, ctx.heap) >= 0;
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
        // should NOT trigger a type change, they only update enumerable/configurable.
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
            // ES5 §8.12.9: Generic descriptor, only update enumerable/configurable.
            // Do NOT change value, writable, is_accessor, getter, or setter.
            bool has_enum_in_desc = desc_fields.has_enumerable;
            bool has_conf_in_desc = desc_fields.has_configurable;
            // ES5 §8.12.9 step 7: non-configurable property, reject if descriptor
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
            obj.set_prop_flags((uint)existing_idx, cur_flags, ctx.heap);
        } else if (is_accessor) {
            // Update accessor fields. Use to_property_descriptor's has_* flags
            // (which include inherited accessor lookups that returned undefined).
            bool has_get_in_desc = desc_fields.has_get;
            bool has_set_in_desc = desc_fields.has_set;
            bool has_enum_in_desc = desc_fields.has_enumerable;
            bool has_conf_in_desc = desc_fields.has_configurable;

            // ES5 §8.12.9 step 11: non-configurable accessor, reject if get/set changes
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
                // *current holds a data value (number, string, etc.), calling
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

            // Update flags, only overwrite fields present in descriptor
            cur_flags.is_accessor = true;
            if (has_enum_in_desc) cur_flags.enumerable   = desc_flags.enumerable;
            if (has_conf_in_desc) cur_flags.configurable = desc_flags.configurable;
            obj.set_prop_flags((uint)existing_idx, cur_flags, ctx.heap);
            // Clear the dense array slot so arr_get_elem_vm falls through to the
            // named-property accessor rather than returning a stale data value.
            if (key_hstr.is_arridx()) {
                uint ai = key_hstr.array_index();
                TVal* ap = obj.array_part();
                if (ap != null && ai < obj.array_size) {
                    TVal undef; undef.set_undefined();
                    ap[ai] = undef;
                }
            }
        } else {
            // Update data property.
            // Use the has_* flags from to_property_descriptor (which include
            // inherited accessor lookups that returned undefined) instead of
            // own-prop checks on desc_obj, which would miss inherited fields.
            bool has_val_in_desc = desc_fields.has_value;
            bool has_wrt_in_desc = desc_fields.has_writable;
            bool has_enum_in_desc = desc_fields.has_enumerable;
            bool has_conf_in_desc = desc_fields.has_configurable;

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
            obj.set_prop_flags((uint)existing_idx, cur_flags, ctx.heap);
        }
    }

    // Step 6: Return O
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.defineProperties, ES5 §15.2.3.7
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

    // Step 2: ToObject(Properties), ES5 §15.2.3.7 step 2.
    // null and undefined throw TypeError; primitives are coerced to wrapper objects.
    if (ctx.argc < 2) {
        ctx.result.set_object(obj);
        return;
    }
    TVal props_val = ctx.regs[ctx.base_reg + 1];
    if (props_val.is_null() || props_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.defineProperties called with null or undefined Properties");
        return;
    }
    if (!props_val.is_object()) {
        // Primitive, coerce to wrapper object (Boolean, Number, or String exotic).
        if (!builtin_to_object(ctx, props_val)) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Object.defineProperties: cannot convert Properties to object");
            return;
        }
        props_val = *ctx.result;
    }
    HObject* props = (HObject*)props_val.get_heapptr();

    // Proxy exotic target: parse each descriptor and route through
    // [[DefineOwnProperty]].
    if (obj.flags.exotic_proxyobj) {
        for (uint i = 0; i < props.prop_count; i++) {
            if (props.prop_key_at(i, ctx.heap) == null || !props.get_prop_flags(i, ctx.heap).enumerable) continue;
            HString* k = (HString*)props.prop_key_at(i, ctx.heap);
            TVal desc_val;
            if (!desc_get(ctx, props, k, &desc_val)) {
                if (ctx.should_throw) return;
                continue;
            }
            if (!desc_val.is_object()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Property description must be an object");
                return;
            }
            ProxyDesc pd;
            if (!proxy_object_to_desc(ctx.vm, ctx.heap, (HObject*)desc_val.get_heapptr(), &pd)) { proxy_ctx_ok(ctx); return; }
            bool dok;
            if (!proxy_mop_define(ctx.vm, ctx.heap, obj, k, &pd, &dok)) { proxy_ctx_ok(ctx); return; }
            if (!dok) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "'defineProperty' on proxy: trap returned falsish");
                return;
            }
        }
        ctx.result.set_object(obj);
        return;
    }

    // Proxy props: [[OwnPropertyKeys]] + [[GetOwnProperty]] per key (in trap order).
    if (props.flags.exotic_proxyobj) {
        HObject* karr;
        if (!proxy_mop_own_keys(ctx.vm, ctx.heap, props, &karr)) { proxy_ctx_ok(ctx); return; }
        for (uint i = 0; i < karr.array_used; i++) {
            TVal el = karr.array_part()[i];
            if (!el.is_string()) continue;
            HString* k = (HString*)el.get_heapptr();
            ProxyDesc pd;
            if (!proxy_mop_get_own(ctx.vm, ctx.heap, props, k, &pd)) { proxy_ctx_ok(ctx); return; }
            if (!pd.found || !pd.enumerable) continue;
            // Get the descriptor value via [[Get]] on props.
            TVal recv; recv.set_object(props);
            TVal desc_val;
            if (!proxy_mop_get(ctx.vm, ctx.heap, props, k, recv, &desc_val)) { proxy_ctx_ok(ctx); return; }
            if (desc_val.is_undefined()) continue;
            if (!desc_val.is_object()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Property description must be an object");
                return;
            }
            // Define on obj (ordinary or proxy).
            if (obj.flags.exotic_proxyobj) {
                ProxyDesc ipd;
                if (!proxy_object_to_desc(ctx.vm, ctx.heap, (HObject*)desc_val.get_heapptr(), &ipd)) { proxy_ctx_ok(ctx); return; }
                bool dok;
                if (!proxy_mop_define(ctx.vm, ctx.heap, obj, k, &ipd, &dok)) { proxy_ctx_ok(ctx); return; }
                if (!dok) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "'defineProperty' on proxy: trap returned falsish");
                    return;
                }
            } else {
                HObject* desc_obj = (HObject*)desc_val.get_heapptr();
                hobject::PropFlags desc_flags;
                TVal[2] desc_vals;
                bool is_acc;
                if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_acc, null)) {
                    if (ctx.should_throw) return;
                    continue;
                }
                if (is_acc) {
                    obj.put_prop((void*)k, desc_vals[0], desc_flags, ctx.heap);
                    int pidx = obj.find_prop_idx(k, ctx.heap);
                    if (pidx >= 0) {
                        // put_prop above anchored desc_vals[0] as the (placeholder) slot
                        // value; the GS cell holds its own incref'd copy, so release the
                        // placeholder's reference before replacing the slot.
                        ctx.heap.decref_tval(&obj.prop_values()[pidx]);
                        obj.prop_values()[pidx] = hobject::hobject_create_accessors(ctx.heap, desc_vals[0], desc_vals[1]);
                    }
                } else {
                    obj.put_prop((void*)k, desc_vals[0], desc_flags, ctx.heap);
                }
            }
        }
        ctx.result.set_object(obj);
        return;
    }

    // Step 4: For each key, get descriptor and call DefinePropertyOrThrow
    // Collect keys first in case properties are modified during iteration
    HString*[256] keys_arr;
    uint keys_count = 0;
    for (uint i = 0; i < props.prop_count && keys_count < 256; i++) {
        if (props.prop_key_at(i, ctx.heap) != null && props.get_prop_flags(i, ctx.heap).enumerable) {
            keys_arr[keys_count] = (HString*)props.prop_key_at(i, ctx.heap);
            keys_count++;
        }
    }
    // String exotic char indices: lazy enumerable own properties on a wrapped
    // string primitive. The named-prop table is empty for these, so enumerate
    // 0..char_length-1 explicitly per ES5 §15.5.5.1.
    if (props.flags.exotic_stringobj && (*props.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*props.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null) {
            for (uint i = 0; i < prim.char_length() && keys_count < 256; i++) {
                HString* pk = ctx.heap.int_to_hstring((long)i);
                if (pk != null) keys_arr[keys_count++] = pk;
            }
        }
    }

    for (uint k = 0; k < keys_count; k++) {
        HString* p_key = keys_arr[k];
        // Get descObj = props.[[Get]](p_key), invokes getters with props as receiver.
        // Per ES5 §15.2.3.7 step 5, we must call [[Get]], not [[GetOwnProperty]].
        TVal desc_obj_val;
        if (!desc_get(ctx, props, p_key, &desc_obj_val)) {
            if (ctx.should_throw) return;
            continue;
        }
        {
            // ToPropertyDescriptor(desc_obj)
            if (!desc_obj_val.is_object()) {
                // TypeError, property descriptor must be an object
                char[128] msg_buf;
                int msg_len = (int)(io::bprintf(&msg_buf, "Property descriptor for '%s' must be an object", (String)p_key.get_data()) ?? msg_buf[:0]).len;
                builtin_throw(ctx, ctx.heap.type_err_proto, msg_buf[:msg_len]);
                return;
            }
            HObject* desc_obj = (HObject*)desc_obj_val.get_heapptr();

            // Convert to property descriptor
            hobject::PropFlags desc_flags;
            TVal[2] desc_vals;
            bool is_accessor;
            if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_accessor, null)) {
                if (ctx.should_throw) return;
                ctx.result.set_undefined();
                return;
            }

            // Array-length special path: delegate to ArraySetLength logic
            // (ES2024 §10.4.2.4), shared with Object.defineProperty and
            // Reflect.defineProperty via array_set_length_desc (proxy.c3).
            if (obj.get_class() == hobject::ObjClass.ARRAY && p_key.equals("length")) {
                ProxyDesc pd;
                pd.has_value = has_value_in_desc_helper(ctx.heap, desc_obj); pd.value = desc_vals[0];
                pd.has_writable = has_writable_in_desc_helper(ctx.heap, desc_obj); pd.writable = desc_flags.writable;
                // Accessor PRESENCE flags only, see the defineProperty site.
                pd.has_get = has_get_in_desc_helper(ctx.heap, desc_obj);
                pd.has_set = has_set_in_desc_helper(ctx.heap, desc_obj);
                pd.has_enumerable = has_enumerable_in_desc_helper(ctx.heap, desc_obj); pd.enumerable = desc_flags.enumerable;
                pd.has_configurable = has_configurable_in_desc_helper(ctx.heap, desc_obj); pd.configurable = desc_flags.configurable;
                bool dok;
                if (!array_set_length_desc(ctx.vm, ctx.heap, obj, &pd, &dok)) { proxy_ctx_ok(ctx); return; }
                if (!dok) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine property: length");
                    return;
                }
                continue;
            }

            // Integer-Indexed exotic [[DefineOwnProperty]] (ES2022 §10.4.5.3):
            // route through ordinary_define_own (which special-cases canonical
            // numeric index keys on TypedArrays, out-of-bounds indices and any
            // non-writable/non-configurable/enumerable=false or accessor
            // descriptor make it return false → DefinePropertyOrThrow throws).
            // Shared with Object.defineProperty and Reflect.defineProperty.
            if (is_typed_array_class(obj.get_class())) {
                ProxyDesc pd;
                pd.found = true;
                if (is_accessor) {
                    pd.has_get = has_get_in_desc_helper(ctx.heap, desc_obj); pd.getter = desc_vals[0];
                    pd.has_set = has_set_in_desc_helper(ctx.heap, desc_obj); pd.setter = desc_vals[1];
                } else {
                    pd.has_value = has_value_in_desc_helper(ctx.heap, desc_obj); pd.value = desc_vals[0];
                    pd.has_writable = has_writable_in_desc_helper(ctx.heap, desc_obj); pd.writable = desc_flags.writable;
                }
                pd.has_enumerable = has_enumerable_in_desc_helper(ctx.heap, desc_obj); pd.enumerable = desc_flags.enumerable;
                pd.has_configurable = has_configurable_in_desc_helper(ctx.heap, desc_obj); pd.configurable = desc_flags.configurable;
                bool dok;
                if (!ordinary_define_own(ctx.vm, ctx.heap, obj, p_key, &pd, &dok)) { proxy_ctx_ok(ctx); return; }
                if (!dok) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine property");
                    return;
                }
                continue;
            }

            // [[DefineOwnProperty]]
            // ES5 §15.4.5.1: ARRAY exotic, dense elements are own data properties
            // with {writable:true, enumerable:true, configurable:true}. Promote a
            // dense element to a named property before the descriptor-validation so
            // the existing-property path applies with the correct implicit flags.
            // Dense-to-named promotion: when a dense array slot exists but has no named
            // property entry, we must create one so the existing-property update path
            // (which reads/updates named-prop flags) can operate correctly.
            // Use PROP_FLAGS_WC (enumerable=false) to force put_prop into the named
            // property table, WEC would route back to dense and leave find_prop_idx at -1.
            // After creating the named entry we fix flags to WEC and clear the dense slot
            // so the VM GETPROP fast path does not return the stale dense value.
            if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS)
                && obj.find_prop_idx(p_key, ctx.heap) < 0 && p_key.is_arridx()) {
                uint p_ai = (uint)((HString*)p_key).array_index();
                if (p_ai < obj.array_size) {
                    TVal dense_elem = obj.array_part()[p_ai];
                    if (!dense_elem.is_undefined()) {
                        obj.put_prop(p_key, dense_elem, hobject::PROP_FLAGS_WC, ctx.heap);
                        int promo_idx = obj.find_prop_idx(p_key, ctx.heap);
                        if (promo_idx >= 0) {
                            obj.set_prop_flags((uint)promo_idx, hobject::PROP_FLAGS_WEC, ctx.heap);
                            // set_array_idx decrefs the dense slot's own reference to
                            // dense_elem (a separate owning copy from the one put_prop
                            // just anchored above) and already decrements array_used on
                            // the non-undefined→undefined transition.
                            TVal hole; hole.set_undefined();
                            obj.set_array_idx(p_ai, hole, ctx.heap);
                        }
                    }
                }
            }
            int existing_idx = obj.find_prop_idx(p_key, ctx.heap);
            // ES5 §15.4.5.1 step 4: defining a valid array index >= length on an
            // Array whose length is non-writable throws TypeError (mirrors the
            // single-property defineProperty path).
            if (existing_idx < 0 && obj.get_class() == hobject::ObjClass.ARRAY
                && p_key.is_arridx()) {
                uint dp_idx = p_key.array_index();
                if (dp_idx >= array_get_length(obj, ctx.heap)) {
                    HString* len_key_dp = ctx.heap.str(heap::BuiltinStr.LENGTH);
                    bool dp_len_wr = true;
                    if (len_key_dp != null) {
                        int li_dp = obj.find_prop_idx(len_key_dp, ctx.heap);
                        if (li_dp >= 0) dp_len_wr = obj.get_prop_flags((uint)li_dp, ctx.heap).writable;
                    }
                    if (!dp_len_wr) {
                        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot add property past a non-writable array length");
                        return;
                    }
                }
            }
            if (existing_idx < 0) {
                if (!obj.flags.extensible) {
                    builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot define property on a non-extensible object");
                    return;
                }
                if (is_accessor) {
                    obj.put_prop(p_key, desc_vals[0], desc_flags, ctx.heap);
                    int idx = obj.find_prop_idx(p_key, ctx.heap);
                    if (idx >= 0) {
                        // put_prop above anchored desc_vals[0] as the (placeholder) slot
                        // value; the GS cell holds its own incref'd copy, so release the
                        // placeholder's reference before replacing the slot.
                        ctx.heap.decref_tval(&obj.prop_values()[idx]);
                        obj.prop_values()[idx] = hobject::hobject_create_accessors(ctx.heap, desc_vals[0], desc_vals[1]);
                    }
                } else {
                    obj.put_prop(p_key, desc_vals[0], desc_flags, ctx.heap);
                }
            } else {
                // Property exists, validate changes
                hobject::PropValue* current = &obj.prop_values()[existing_idx];
                hobject::PropFlags cur_flags = obj.get_prop_flags((uint)existing_idx, ctx.heap);
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
                        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot redefine non-configurable property");
                        return;
                    }
                }

                if (is_accessor) {
                    if (!cur_flags.is_accessor) {
                        // Data → accessor conversion: create a new GetterSetter cell.
                        // *current holds a data value (number, string, etc.), calling
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
                    obj.set_prop_flags((uint)existing_idx, cur_flags, ctx.heap);
                } else {
                    // Data descriptor update (or accessor→data conversion).
                    // A generic descriptor (only enumerable/configurable, no value/writable/get/set)
                    // must NOT change the property type, only update the generic fields.
                    bool desc_has_data_fields = has_value_in_desc_helper(ctx.heap, desc_obj) || has_writable_in_desc_helper(ctx.heap, desc_obj);
                    if (cur_flags.is_accessor && desc_has_data_fields) {
                        // Accessor → data conversion (ES5 §8.12.9 step 9.a/b): release the
                        // GetterSetter cell and reset flags so the slot becomes a data slot.
                        ctx.heap.decref_tval(current);
                        TVal undef_tv; undef_tv.set_undefined();
                        *current = undef_tv;
                        cur_flags.is_accessor = false;
                        cur_flags.writable     = false;
                        cur_flags.enumerable   = cur_flags.enumerable;
                        cur_flags.configurable = cur_flags.configurable;
                    }
                    if (has_value_in_desc_helper(ctx.heap, desc_obj)) {
                        // ES5 §8.12.9 step 10.a.ii: reject value change on non-configurable,
                        // non-writable property (SameValue check).
                        if (!cur_flags.configurable && !cur_flags.writable) {
                            if (!same_value(*current, desc_vals[0])) {
                                builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot change value of non-writable non-configurable property");
                                return;
                            }
                        }
                        // The prop-table slot and (if synced) the dense array slot are two
                        // independent owning references to the same value, incref once per
                        // slot, in each case before decref'ing the slot's previous occupant.
                        if (desc_vals[0].is_heap_allocated() && desc_vals[0].get_heapptr() != null) {
                            ((types::HeapHeader*)desc_vals[0].get_heapptr()).incref();
                        }
                        ctx.heap.decref_tval(current);
                        *current = desc_vals[0];
                        // Sync value change back to dense array slot for ARRAY exotic.
                        if (obj.get_class() == hobject::ObjClass.ARRAY && p_key.is_arridx()) {
                            uint sync_ai = ((HString*)p_key).array_index();
                            if (sync_ai < obj.array_size) {
                                obj.set_array_idx(sync_ai, desc_vals[0], ctx.heap);
                            }
                        }
                    }
                    if (has_writable_in_desc_helper(ctx.heap, desc_obj)) cur_flags.writable = desc_flags.writable;
                    if (has_enumerable_in_desc_helper(ctx.heap, desc_obj)) cur_flags.enumerable = desc_flags.enumerable;
                    if (has_configurable_in_desc_helper(ctx.heap, desc_obj)) cur_flags.configurable = desc_flags.configurable;
                    obj.set_prop_flags((uint)existing_idx, cur_flags, ctx.heap);
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
    return key != null && desc_obj.find_prop_idx(key, heap) >= 0;
}
/// Helper: check if descriptor object has "set" property
fn bool has_set_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "set");
    return key != null && desc_obj.find_prop_idx(key, heap) >= 0;
}
/// Helper: check if descriptor object has "value" property
fn bool has_value_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    return key != null && desc_obj.find_prop_idx(key, heap) >= 0;
}
/// Helper: check if descriptor object has "writable" property
fn bool has_writable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "writable");
    return key != null && desc_obj.find_prop_idx(key, heap) >= 0;
}
/// Helper: check if descriptor object has "enumerable" property
fn bool has_enumerable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "enumerable");
    return key != null && desc_obj.find_prop_idx(key, heap) >= 0;
}
/// Helper: check if descriptor object has "configurable" property
fn bool has_configurable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "configurable");
    return key != null && desc_obj.find_prop_idx(key, heap) >= 0;
}

// ============================================================================
// Object.create, ES5 §15.2.3.5 / ES2020 §19.1.2.2
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
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.create requires at least 1 argument");
        return;
    }
    TVal proto_val = ctx.regs[ctx.base_reg];

    // Step 2: If O is not Object or Null, throw TypeError
    if (proto_val.is_null()) {
        // null prototype is valid
    } else if (proto_val.is_object()) {
        // valid
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object prototype may only be an Object or null");
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
            // ToObject(Properties), wrap primitives, throw TypeError for null
            HObject* props;
            if (props_val.is_object()) {
                props = (HObject*)props_val.get_heapptr();
            } else if (props_val.is_null()) {
                // ToObject(null) → TypeError
                builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert undefined or null to object");
                return;
            } else {
                // ToObject(primitive) → wrap via builtin_to_object
                if (!builtin_to_object(ctx, props_val)) {
                    // Should not happen for non-null/non-undefined
                    builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert undefined or null to object");
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

            // Helper: collect keys, named properties first, then array-part, then symbols
            // Named properties
            for (uint i = 0; i < props.prop_count && desc_count < 256; i++) {
                void* raw_key = props.prop_key_at(i, ctx.heap);
                if (raw_key == null) continue;
                HString* pk_key = (HString*)raw_key;

                // [[GetOwnProperty]](pk_key), check if own and enumerable
                int pidx = props.find_prop_idx(pk_key, ctx.heap);
                if (pidx < 0) continue;
                hobject::PropFlags pflags = props.get_prop_flags((uint)pidx, ctx.heap);
                if (!pflags.enumerable) continue;

                // [[Get]](props, pk_key), invoke getter if accessor
                TVal desc_obj_val;
                if (pflags.is_accessor) {
                    TVal gs_slot = props.prop_values()[(uint)pidx];
                    TVal getter_fn = hobject::hobject_access_getter(gs_slot);
                    if (getter_fn.is_undefined() || getter_fn.is_null()) {
                        // No getter, Get returns undefined
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
                    // Data property, value is directly in PropValue
                    desc_obj_val = props.prop_values()[(uint)pidx];
                }

                // ToPropertyDescriptor(desc_obj_val)
                if (!desc_obj_val.is_object()) {
                    // ToPropertyDescriptor requires an object, throw TypeError
                    char[128] msg_buf;
                    int msg_len = (int)(io::bprintf(&msg_buf, "Property descriptor for '%s' must be an object",
                                                 (String)pk_key.get_data()) ?? msg_buf[:0]).len;
                    builtin_throw(ctx, ctx.heap.type_err_proto, msg_buf[:msg_len]);
                    return;
                }
                HObject* desc_obj = (HObject*)desc_obj_val.get_heapptr();

                hobject::PropFlags desc_flags;
                TVal[2] desc_vals;
                bool is_acc;
                if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_acc, null)) {
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
                    char[128] msg_buf;
                    int msg_len = (int)(io::bprintf(&msg_buf, "Property descriptor for '%s' must be an object",
                                                 (String)pk_key.get_data()) ?? msg_buf[:0]).len;
                    builtin_throw(ctx, ctx.heap.type_err_proto, msg_buf[:msg_len]);
                    return;
                }
                HObject* desc_obj = (HObject*)desc_obj_val.get_heapptr();

                hobject::PropFlags desc_flags;
                TVal[2] desc_vals;
                bool is_acc;
                if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_acc, null)) {
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

            // Phase 1.5: String exotic character indices (e.g. new String("hi")
            // or Object.create({}, "hi")). Per ES5 §15.5.5.1 the integer
            // indices 0..char_length-1 are own enumerable properties served
            // lazily from the wrapped primitive. The named-prop table and
            // array part are both empty for these, so they must be enumerated
            // explicitly here. ObjectDefineProperties calls [[GetOwnProperty]]
            // on each, which yields a String-exotic char as the descriptor
            // value, and ToPropertyDescriptor on a non-object throws.
            if (props.flags.exotic_stringobj && (*props.extra_ptr()).prim.primitive_value.is_string()) {
                HString* prim = (HString*)(*props.extra_ptr()).prim.primitive_value.get_heapptr();
                if (prim != null) {
                    uint clen = prim.char_length();
                    char[] pdata = prim.get_data();
                    for (uint i = 0; i < clen && desc_count < 256; i++) {
                        HString* pk_key = ctx.heap.int_to_hstring((long)i);
                        if (pk_key == null) continue;
                        char[2] ch_buf;
                        ch_buf[0] = pdata[i];
                        ch_buf[1] = 0;
                        HString* ch_hstr = builtin_intern_string(ctx.heap, ch_buf[:1]);
                        if (ch_hstr == null) continue;
                        TVal ch_val;
                        ch_val.set_string(ch_hstr);
                        if (!ch_val.is_object()) {
                            char[128] msg_buf;
                            int msg_len = (int)(io::bprintf(&msg_buf, "Property descriptor for '%s' must be an object",
                                                         (String)pk_key.get_data()) ?? msg_buf[:0]).len;
                            builtin_throw(ctx, ctx.heap.type_err_proto, msg_buf[:msg_len]);
                            return;
                        }
                    }
                }
            }

            // Phase 2: Apply all collected descriptors atomically
            for (uint k = 0; k < desc_count; k++) {
                HString* pk_key = desc_keys[k];
                hobject::PropFlags df = desc_flags_arr[k];
                if (desc_is_acc[k]) {
                    obj.put_prop(pk_key, desc_acc_get[k], df, ctx.heap);
                    int eidx = obj.find_prop_idx(pk_key, ctx.heap);
                    if (eidx >= 0) {
                        // put_prop above anchored desc_acc_get[k] as the (placeholder) slot
                        // value; the GS cell holds its own incref'd copy, so release the
                        // placeholder's reference before replacing the slot.
                        ctx.heap.decref_tval(&obj.prop_values()[eidx]);
                        obj.prop_values()[eidx] = hobject::hobject_create_accessors(
                            ctx.heap, desc_acc_get[k], desc_acc_set[k]);
                    }
                } else {
                    obj.put_prop(pk_key, desc_values[k], df, ctx.heap);
                }
            }
        }
    }

    // Step 5: Return obj
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.seal, ES5 §15.2.3.8
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
    // Proxy: SetIntegrityLevel(O, sealed), ES2015 §7.3.13, routes
    // [[PreventExtensions]] then [[DefineOwnProperty]]({configurable:false})
    // for every own key through the MOP so both traps fire.
    if (obj.flags.exotic_proxyobj) {
        if (!proxy_set_integrity_level(ctx.vm, ctx.heap, obj, false)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_object(obj);
        return;
    }
    // Integer-Indexed exotic SetIntegrityLevel(O, sealed), same gap as
    // freeze: [[PreventExtensions]] returns false for a non-fixed-length
    // view (§10.4.5.1), and [[DefineOwnProperty]] with {configurable:false}
    // on an in-bounds element returns false (§10.4.5.3), so seal throws for
    // exactly the same condition; only a fixed-length zero-length view seals.
    if (is_typed_array_class(obj.get_class())
        && (!ta_is_fixed_length(obj) || ta_element_count(obj) > 0)) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot seal this TypedArray");
        return;
    }
    obj.seal(ctx.heap);
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.freeze, ES5 §15.2.3.9
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
    // Proxy: SetIntegrityLevel(O, frozen), ES2015 §7.3.13, routes
    // [[PreventExtensions]] then [[DefineOwnProperty]] for every own key
    // through the MOP so both traps fire (non-writable for data properties,
    // non-configurable for all).
    if (obj.flags.exotic_proxyobj) {
        if (!proxy_set_integrity_level(ctx.vm, ctx.heap, obj, true)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_object(obj);
        return;
    }
    // Integer-Indexed exotic SetIntegrityLevel(O, frozen), §7.3.15 step 3.a
    // calls O.[[PreventExtensions]](), which for a non-fixed-length TypedArray
    // (length-tracking, or any view over a resizable non-shared buffer) returns
    // false (§10.4.5.1). SetIntegrityLevel then returns false and Object.freeze
    // throws TypeError, even when the view is currently zero-length. A
    // fixed-length TypedArray with in-bounds elements still throws because
    // DefineOwnProperty with {[[Writable]]: false} on an element returns false
    // (§10.4.5.3); a fixed-length zero-length view has no keys and freezes.
    if (is_typed_array_class(obj.get_class())
        && (!ta_is_fixed_length(obj) || ta_element_count(obj) > 0)) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot freeze this TypedArray");
        return;
    }
    // Module Namespace Exotic SetIntegrityLevel(O, frozen), §7.3.15:
    // [[DefineOwnProperty]] with {[[Writable]]: false} on any export returns
    // false (exports are permanently writable per §10.4.6.4), so freeze throws.
    // An empty namespace (only Symbol.toStringTag, already non-writable) freezes.
    if (obj.flags.exotic_module_ns) {
        for (uint i = 0; i < obj.prop_count; i++) {
            void* pk = obj.prop_key_at(i, ctx.heap);
            if (pk != null && !((HString*)pk).is_symbol()) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot freeze module namespace object");
                return;
            }
        }
        ctx.result.set_object(obj);
        return;
    }
    obj.freeze(ctx.heap);
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.isSealed, ES5 §15.2.3.11
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

    if (obj.flags.exotic_proxyobj) {
        bool sealed;
        if (!proxy_test_integrity_level(ctx.vm, ctx.heap, obj, false, &sealed)) {
            proxy_ctx_ok(ctx);
            return;
        }
        ctx.result.set_boolean(sealed);
        return;
    }

    // Dense array elements are always writable and configurable (no per-element
    // flags in the flat array part).  If any exist, the object can't be sealed.
    if (obj.array_used > 0) {
        ctx.result.set_boolean(false);
        return;
    }

    // Check if any own property is configurable
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i, ctx.heap) != null && obj.get_prop_flags(i, ctx.heap).configurable) {
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
// Object.isFrozen, ES5 §15.2.3.12
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

    if (obj.flags.exotic_proxyobj) {
        bool frozen;
        if (!proxy_test_integrity_level(ctx.vm, ctx.heap, obj, true, &frozen)) {
            proxy_ctx_ok(ctx);
            return;
        }
        ctx.result.set_boolean(frozen);
        return;
    }

    // Module Namespace Exotic TestIntegrityLevel(O, frozen), §7.3.16: each
    // export's [[GetOwnProperty]] is a data descriptor with [[Writable]]: true,
    // so any string export means the namespace is not frozen. An empty namespace
    // (only the non-writable Symbol.toStringTag) is frozen.
    if (obj.flags.exotic_module_ns) {
        for (uint i = 0; i < obj.prop_count; i++) {
            void* pk = obj.prop_key_at(i, ctx.heap);
            if (pk != null && !((HString*)pk).is_symbol()) {
                ctx.result.set_boolean(false);
                return;
            }
        }
        ctx.result.set_boolean(true);
        return;
    }

    // Dense array elements are always writable and configurable (no per-element
    // flags in the flat array part).  If any exist, the object can't be frozen.
    if (obj.array_used > 0) {
        ctx.result.set_boolean(false);
        return;
    }

    // Check if any own property is configurable or data property writable
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.prop_key_at(i, ctx.heap) != null) {
            hobject::PropFlags f = obj.get_prop_flags(i, ctx.heap);
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
// Object.entries, ES2017 §19.1.2.21
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
        if (!builtin_to_object(ctx, arg)) { ctx.result.set_undefined(); return; }
        obj = (HObject*)ctx.result.get_heapptr();
    }

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err3 = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;

    if (obj.flags.exotic_proxyobj) {
        // EnumerableOwnProperties §7.3.21: for each key interleave
        // [[GetOwnProperty]] (descriptor) then [[Get]] (value) before next key.
        HObject* keys_arr;
        if (!proxy_mop_own_keys(ctx.vm, ctx.heap, obj, &keys_arr)) { proxy_ctx_ok(ctx); return; }
        uint n = keys_arr.array_used;
        for (uint i = 0; i < n; i++) {
            TVal el = keys_arr.array_part()[i];
            if (!el.is_string()) continue;
            HString* k = (HString*)el.get_heapptr();
            if (k.is_symbol()) continue;
            ProxyDesc d;
            if (!proxy_mop_get_own(ctx.vm, ctx.heap, obj, k, &d)) { proxy_ctx_ok(ctx); return; }
            if (!d.found || !d.enumerable) continue;
            TVal val;
            TVal recv; recv.set_object(obj);
            if (!proxy_mop_get(ctx.vm, ctx.heap, obj, k, recv, &val)) { proxy_ctx_ok(ctx); return; }
            HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch e4 = pair_raw) { ctx.result.set_undefined(); return; }
            HObject* pair = pair_raw;
            pair.prototype = ctx.heap.array_proto;
            TVal key_tv; key_tv.set_string(k);
            array_set_elem(pair, 0, key_tv, ctx.heap);
            array_set_elem(pair, 1, val, ctx.heap);
            TVal len_tv; len_tv.set_fastint(2);
            HString* len_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
            pair.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
            TVal pair_tv; pair_tv.set_object(pair);
            array_set_elem(arr, idx, pair_tv, ctx.heap);
            idx++;
        }
    } else {
        // Non-proxy: snapshot ALL own string keys first (regardless of
        // enumerability), then re-check each key's enumerable attribute
        // immediately before its [[Get]] (EnumerableOwnPropertyNames
        // interleaves the two per key, so a getter earlier in the walk can
        // make a later key non-enumerable before that key is reached).
        uint max_keys = own_key_buf_capacity(obj);
        HString** key_buf = (HString**)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(max_keys * HString*::size));
        if (key_buf == null) { ctx.result.set_undefined(); return; }
        defer ctx.heap.free_func(ctx.heap.heap_udata, key_buf);
        uint key_count = collect_own_enum_string_keys(ctx.heap, obj, key_buf, false);
        for (uint i = 0; i < key_count; i++) {
            HString* key = key_buf[i];
            if (!key_is_currently_enumerable(obj, key, ctx.heap)) continue;
            TVal val;
            if (!desc_get_enum(ctx, obj, key, &val)) {
                if (ctx.should_throw) { return; }
                continue;
            }
            HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err4 = pair_raw) { ctx.result.set_undefined(); return; }
            HObject* pair = pair_raw;
            pair.prototype = ctx.heap.array_proto;
            TVal key_tv; key_tv.set_string(key);
            array_set_elem(pair, 0, key_tv, ctx.heap);
            array_set_elem(pair, 1, val, ctx.heap);
            TVal len_tv; len_tv.set_fastint(2);
            HString* len_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
            pair.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
            TVal pair_tv; pair_tv.set_object(pair);
            array_set_elem(arr, idx, pair_tv, ctx.heap);
            idx++;
        }
    }

    TVal rlen_tv; rlen_tv.set_fastint((long)idx);
    HString* rlen_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
    arr.put_prop(rlen_key, rlen_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.values, ES2017 §19.1.2.22
// ============================================================================
/// Returns an array of the given object's own enumerable string-keyed property values.
fn void builtin_object_values(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (arg.is_null() || arg.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert undefined or null to object");
        return;
    }
    HObject* obj;
    if (arg.is_object()) {
        obj = (HObject*)arg.get_heapptr();
    } else {
        if (!builtin_to_object(ctx, arg)) { ctx.result.set_undefined(); return; }
        obj = (HObject*)ctx.result.get_heapptr();
    }

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err3 = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;

    if (obj.flags.exotic_proxyobj) {
        // EnumerableOwnProperties §7.3.21: interleave [[GetOwnProperty]] then
        // [[Get]] per key so that observable trap order matches the spec.
        HObject* keys_arr;
        if (!proxy_mop_own_keys(ctx.vm, ctx.heap, obj, &keys_arr)) { proxy_ctx_ok(ctx); return; }
        uint n = keys_arr.array_used;
        for (uint i = 0; i < n; i++) {
            TVal el = keys_arr.array_part()[i];
            if (!el.is_string()) continue;
            HString* k = (HString*)el.get_heapptr();
            if (k.is_symbol()) continue;
            ProxyDesc d;
            if (!proxy_mop_get_own(ctx.vm, ctx.heap, obj, k, &d)) { proxy_ctx_ok(ctx); return; }
            if (!d.found || !d.enumerable) continue;
            TVal val;
            TVal recv; recv.set_object(obj);
            if (!proxy_mop_get(ctx.vm, ctx.heap, obj, k, recv, &val)) { proxy_ctx_ok(ctx); return; }
            array_set_elem(arr, idx, val, ctx.heap);
            idx++;
        }
    } else {
        // Snapshot ALL own string keys, then re-check enumerability per key
        // right before its [[Get]], see the comment in builtin_object_entries.
        uint max_keys = own_key_buf_capacity(obj);
        HString** key_buf = (HString**)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)(max_keys * HString*::size));
        if (key_buf == null) { ctx.result.set_undefined(); return; }
        defer ctx.heap.free_func(ctx.heap.heap_udata, key_buf);
        uint key_count = collect_own_enum_string_keys(ctx.heap, obj, key_buf, false);
        for (uint i = 0; i < key_count; i++) {
            HString* key = key_buf[i];
            if (!key_is_currently_enumerable(obj, key, ctx.heap)) continue;
            TVal val;
            if (!desc_get_enum(ctx, obj, key, &val)) {
                if (ctx.should_throw) { return; }
                continue;
            }
            array_set_elem(arr, idx, val, ctx.heap);
            idx++;
        }
    }

    TVal rlen_tv; rlen_tv.set_fastint((long)idx);
    HString* rlen_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
    arr.put_prop(rlen_key, rlen_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
    ctx.result.set_object(arr);
}

// ============================================================================
// Object.assign, ES2015 §19.1.2.2
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
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert undefined or null to object");
        return;
    }
    // ES2015 §19.1.2.1 step 1: ToObject(target). Symbol values are tagged
    // as strings internally (TAG_STRING with the HString's is_symbol flag),
    // so is_string() returns true for them, dispatch on the symbol flag
    // before falling into the string-wrapper path.
    HObject* downstream;
    if (downstream_val.is_object()) {
        downstream = (HObject*)downstream_val.get_heapptr();
    } else if (downstream_val.is_string() && downstream_val.get_heapptr() != null
               && ((HString*)downstream_val.get_heapptr()).is_symbol()) {
        // Symbol wrapper: ObjClass.SYMBOL with [[SymbolData]] = the primitive.
        HString* sym_hs = (HString*)downstream_val.get_heapptr();
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.SYMBOL);
        if (catch err2 = obj_raw) { ctx.result.set_undefined(); return; }
        downstream = obj_raw;
        downstream.prototype = ctx.heap.symbol_proto;
        (*downstream.extra_ptr()).prim.primitive_value.set_string(sym_hs);
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
        downstream.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC, ctx.heap);
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
        // BigInt or other, no enumerable own properties, wrap as plain.
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
            src_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC, ctx.heap);
        } else {
            // Number, Boolean, Symbol, BigInt, no enumerable own properties
            continue;
        }
        // Proxy source: [[OwnPropertyKeys]] + enumerable filter + [[Get]].
        if (src_obj.flags.exotic_proxyobj) {
            HObject* karr;
            if (!proxy_mop_own_keys(ctx.vm, ctx.heap, src_obj, &karr)) { proxy_ctx_ok(ctx); return; }
            for (uint i = 0; i < karr.array_used; i++) {
                TVal el = karr.array_part()[i];
                if (!el.is_string()) continue;
                HString* k = (HString*)el.get_heapptr();
                ProxyDesc pd;
                if (!proxy_mop_get_own(ctx.vm, ctx.heap, src_obj, k, &pd)) { proxy_ctx_ok(ctx); return; }
                if (!pd.found || !pd.enumerable) continue;
                TVal recv; recv.set_object(src_obj);
                TVal v;
                if (!proxy_mop_get(ctx.vm, ctx.heap, src_obj, k, recv, &v)) { proxy_ctx_ok(ctx); return; }
                if (!obj_assign_set(ctx, downstream, k, &v)) { return; }
            }
            continue;
        }

        // Copy enumerable own named properties via [[Set]] per ES2015 §19.1.2.2.
        // Per OrdinaryOwnPropertyKeys, string keys precede symbol keys, so we
        // iterate twice: first strings, then symbols, to match spec order
        // (test262/built-ins/Object/assign/strings-and-symbol-order.js).
        for (uint pass = 0; pass < 2; pass++) {
            for (uint i = 0; i < src_obj.prop_count; i++) {
                if (!src_obj.get_prop_flags(i, ctx.heap).enumerable || src_obj.prop_key_at(i, ctx.heap) == null) continue;
                HString* key = (HString*)src_obj.prop_key_at(i, ctx.heap);
                bool is_sym = key.flags.is_symbol;
                if ((pass == 0 && is_sym) || (pass == 1 && !is_sym)) continue;
                if (is_sym && key.is_hidden()) continue;
                // ES2015 §19.1.2.2 step 5.c: propValue = ? Get(from, nextKey).
                // Use [[Get]] so source getters are invoked (the raw prop slot
                // holds the GetterSetter object, not the getter's return value).
                TVal val;
                if (!desc_get(ctx, src_obj, key, &val)) {
                    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                    continue;
                }
                if (!obj_assign_set(ctx, downstream, key, &val)) {
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
                    int dlen = (int)(io::bprintf(&digit_buf, "%d", i) ?? digit_buf[:0]).len;
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
                    uint cp = prim.char_at_unchecked(ci);
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
// Object.is, ES6 §19.1.2.10
// ============================================================================
/// Object.is(value1, value2), SameValue comparison.
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
// Object.hasOwn, ES2022 §19.1.2.10
// ============================================================================
/// Object.hasOwn(obj, prop), returns true if obj has own property prop.
/// Equivalent to Object.prototype.hasOwnProperty.call(obj, prop).
fn void builtin_object_hasOwn(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.hasOwn requires 2 arguments");
        return;
    }
    TVal obj_val = ctx.regs[ctx.base_reg];
    TVal prop_val = ctx.regs[ctx.base_reg + 1];
    // ToObject on first argument, throw TypeError for null/undefined
    if (obj_val.is_null() || obj_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot convert undefined or null to object");
        return;
    }
    HObject* obj;
    if (obj_val.is_object()) {
        obj = (HObject*)obj_val.get_heapptr();
    } else {
        // Primitive, wrap via ToObject (for now, return false)
        ctx.result.set_boolean(false);
        return;
    }
    HString* key = builtin_to_property_key_vm(ctx, &prop_val);
    if (key == null) {
        ctx.result.set_boolean(false);
        return;
    }
    if (obj.flags.exotic_proxyobj) {
        ProxyDesc pd;
        if (!proxy_mop_get_own(ctx.vm, ctx.heap, obj, key, &pd)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_boolean(pd.found);
        return;
    }
    PropValue*? entry = obj.find_prop(key, ctx.heap);
    if (try e = entry) {
        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// Object.setPrototypeOf, ES2015 §19.1.2.19
// ============================================================================
/// Shared ordinary-object prototype-set logic with extensible and cycle checks.
/// Returns true if the prototype was set (or no change was needed), false if
/// the operation was rejected, non-extensible object with different proto,
/// proto cycle, or an immutable-prototype exotic object given a different
/// value. Never throws itself (ES2022 §10.4.7.1 [[SetPrototypeOf]] just
/// returns false); callers that need Set-with-Throw semantics (e.g.
/// Object.setPrototypeOf, unlike Reflect.setPrototypeOf) throw on a false
/// result themselves.
fn bool ordinary_set_proto(BuiltinContext* ctx, HObject* obj, HObject* new_proto) {
    // Immutable-prototype exotic object check (ES2022 §10.4.7.1):
    // Object.prototype is an immutable-prototype exotic object, its [[Prototype]]
    // can only be set to the SAME value (null); any other value is rejected.
    if (obj == ctx.heap.object_proto) {
        return new_proto == obj.prototype;
    }

    // Same value, no change needed.
    if (new_proto == obj.prototype) return true;

    // Non-extensible object: cannot change prototype (ES2022 §10.1.2.1 step 3).
    if (!obj.is_extensible()) return false;

    // Prototype cycle check (ES2022 §9.1.2.1 step 8).
    HObject* p = new_proto;
    while (p != null) {
        if (p == obj) return false;
        // Non-ordinary objects stop the walk; their [[SetPrototypeOf]] must
        // prevent cycles internally.
        if (p.flags.exotic_proxyobj) break;
        p = p.prototype;
    }

    obj.prototype = new_proto;

    // Class constructors currently resolve super() through the captured
    // __super__ binding. Keep that binding synchronized with the constructor's
    // mutable [[Prototype]], which is what GetSuperConstructor reads.
    if (obj.get_class() == hobject::ObjClass.FUNCTION) {
        CompiledFunction* func = (*obj.extra_ptr()).func.comp_func;
        EnvRecord* lex_env = (*obj.extra_ptr()).func.lex_env;
        if (func != null && func.is_class_ctor() && lex_env != null) {
            HString* super_key = builtin_intern_string(ctx.heap, "__super__");
            if (super_key != null) {
                TVal super_val;
                if (new_proto == null) {
                    super_val.set_null();
                } else {
                    super_val.set_object(new_proto);
                }
                env::env_put(lex_env, super_key, super_val);
            }
        }
    }
    return true;
}

/// Object.setPrototypeOf(obj, proto), sets the prototype of obj to proto.
fn void builtin_object_setPrototypeOf(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.setPrototypeOf requires an object");
        return;
    }
    TVal obj_val = ctx.regs[ctx.base_reg];
    // ES2015 §19.1.2.19 step 1: RequireObjectCoercible(O), throw TypeError for null/undefined
    if (obj_val.is_null() || obj_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.setPrototypeOf requires an object");
        return;
    }
    // ES2015 §19.1.2.19 step 2: If Type(proto) is neither Object nor Null, throw TypeError
    TVal proto_val;
    if (ctx.argc >= 2) {
        proto_val = ctx.regs[ctx.base_reg + 1];
    } else {
        // Missing proto arg → undefined, which is neither Object nor Null
        proto_val.set_undefined();
    }
    if (!proto_val.is_null() && !proto_val.is_object() && !proto_val.is_lightfunc()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.setPrototypeOf requires an object or null");
        return;
    }
    // LIGHTFUNC is an internal compact representation for built-in function
    // objects. Materialize it before storing the [[Prototype]] so functions
    // have the same object semantics as ordinary callable HObjects.
    if (proto_val.is_lightfunc()) {
        uint fn_idx = (uint)(usz)proto_val.get_heapptr();
        BuiltinMeta meta = builtin_get_metadata(fn_idx);
        HObject* proto_func = alloc_builtin_fn(ctx.heap, fn_idx, meta.name, meta.arity);
        if (proto_func == null) {
            ctx.result.set_undefined();
            return;
        }
        if (ctx.vm != null) {
            proto_func.flags.constructable = vm::builtin_fn_is_constructor((Vm*)ctx.vm, fn_idx);
        }
        proto_val.set_object(proto_func);
    }
    // ES2015 §19.1.2.19 step 3: If Type(O) is not Object, return O
    if (!obj_val.is_object()) {
        *ctx.result = obj_val;
        return;
    }
    HObject* obj = (HObject*)obj_val.get_heapptr();

    if (obj.flags.exotic_proxyobj) {
        bool sok;
        if (!proxy_mop_set_proto(ctx.vm, ctx.heap, obj, proto_val, &sok)) { proxy_ctx_ok(ctx); return; }
        if (!sok) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "'setPrototypeOf' on proxy: trap returned falsish");
            return;
        }
        ctx.result.set_object(obj);
        return;
    }

    HObject* new_proto = proto_val.is_null() ? null : (HObject*)proto_val.get_heapptr();
    if (!ordinary_set_proto(ctx, obj, new_proto)) {
        if (ctx.should_throw) return;
        builtin_throw(ctx, ctx.heap.type_err_proto, "Cannot set prototype: object is not extensible or would create a prototype cycle");
        return;
    }
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.fromEntries, ES2019 §19.1.2.5
// ============================================================================
/// Creates a new object from an iterable of [key, value] pairs.
/// Get(entry, ToString(idx)) for an entry pair: dense array slot, then
/// String-exotic character access, then accessor-aware named lookup through
/// the prototype chain. Getter throws land in ctx.should_throw.
fn TVal from_entries_get_index(BuiltinContext* ctx, HObject* pair, uint idx) {
    TVal out;
    out.set_undefined();
    if (pair.array_part() != null && idx < pair.array_size) {
        if (try v = pair.get_array_idx(idx)) {
            if (!v.is_undefined()) return v;
        }
    }
    // String wrapper object: indexed access reads characters from the
    // primitive value (they are not materialised as own properties).
    if (pair.flags.exotic_stringobj && (*pair.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*pair.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null && idx < prim.char_length()) {
            uint cp = prim.char_at_unchecked(idx);
            char[4] cbuf;
            uint clen = hstring::encode_codepoint(cp, cbuf[:4]);
            HString* ch = builtin_intern_string(ctx.heap, cbuf[:clen]);
            if (ch != null) { out.set_string(ch); }
            return out;
        }
    }
    HString* key = ctx.heap.int_to_hstring((long)idx);
    if (key == null) return out;
    if (try v2 = builtins_generic_get(pair, key, ctx)) {
        return v2;
    }
    return out;
}

fn void builtin_object_fromEntries(BuiltinContext* ctx) {
    // RequireObjectCoercible(iterable), §20.1.2.7 step 1.
    if (ctx.argc < 1) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.fromEntries requires an iterable");
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

    if (iter_sym != null) {
        TVal? iter_method_opt = iterable.get_prop_proto(iter_sym, ctx.heap);
        if (try iter_method = iter_method_opt) {
            bool callable = false;
            if (iter_method.is_lightfunc()) {
                callable = true;
            } else if (iter_method.is_object() && iter_method.get_heapptr() != null) {
                callable = ((HObject*)iter_method.get_heapptr()).is_callable();
            }
            if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                iterator = ctx.heap.call_fn(ctx.vm, iter_method, null, 0, arg);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    return;
                }
                use_iter = true;
            }
        }
    }

    if (use_iter) {
        // === Iterator path ===
        HString* next_key = builtin_intern_string(ctx.heap, "next");
        HString* done_key = ctx.heap.str(heap::BuiltinStr.DONE);
        HString* value_key = ctx.heap.str(heap::BuiltinStr.VALUE);

        while (ctx.heap.call_fn != null && ctx.vm != null) {
            if (!iterator.is_object() || iterator.get_heapptr() == null) break;
            HObject* iter_obj = (HObject*)iterator.get_heapptr();

            TVal? next_method_opt = iter_obj.get_prop_proto(next_key, ctx.heap);
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
            // Uncallable next: TypeError, no IteratorClose (§7.4.3 GetIterator).
            if (!callable) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Object.fromEntries: iterator next is not callable");
                return;
            }

            TVal result = ctx.heap.call_fn(ctx.vm, next_method, null, 0, iterator);
            // Abrupt completion from next() propagates WITHOUT IteratorClose
            // (§7.4.11 IteratorStep passes the throw through directly).
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return;
            }
            // next() must return an object: TypeError, no IteratorClose (§7.4.5).
            if (!result.is_object() || result.get_heapptr() == null) {
                builtin_throw(ctx, ctx.heap.type_err_proto, "Object.fromEntries: iterator result is not an object");
                return;
            }

            HObject* result_obj = (HObject*)result.get_heapptr();
            // Get(result, "done") through accessors; abrupt completions
            // propagate without IteratorClose (§7.4.5 IteratorComplete).
            bool done = false;
            if (try dv = builtins_generic_get(result_obj, done_key, ctx)) {
                done = builtin_to_boolean(&dv);
            } else if (ctx.should_throw) {
                return;
            }
            if (done) break;

            TVal entry;
            if (try vv = builtins_generic_get(result_obj, value_key, ctx)) {
                entry = vv;
            } else if (ctx.should_throw) {
                return;
            } else {
                entry.set_undefined();
            }

            // §19.1.2.5 CreateDataPropertyOnObject: a non-object entry is a
            // TypeError, and the iterator must be closed before throwing.
            if (!entry.is_object() || entry.get_heapptr() == null) {
                arr_iterator_close_after_throw(ctx, iterator);
                builtin_throw(ctx, ctx.heap.type_err_proto, "Object.fromEntries: iterator entry is not an object");
                return;
            }
            HObject* pair = (HObject*)entry.get_heapptr();

            // k = Get(entry, "0"), v = Get(entry, "1"); getter throws close
            // the iterator, then propagate (§20.1.2.7 step 9 + IfAbruptCloseIterator).
            TVal key_val = from_entries_get_index(ctx, pair, 0);
            if (ctx.should_throw) {
                arr_iterator_close_after_throw(ctx, iterator);
                return;
            }
            // Pin key_val: a call_fn-routed getter/toString result's only
            // owning reference is the shared vm.return_val slot, which the
            // NEXT call_fn invocation below (Get('1'), then ToPropertyKey)
            // overwrites, decref'ing key_val's object out from under us
            // without this pin (test262 fromEntries/evaluation-order.js UAF).
            bool key_val_pinned = false;
            if (key_val.is_heap_allocated() && key_val.get_heapptr() != null) {
                ((types::HeapHeader*)key_val.get_heapptr()).incref();
                key_val_pinned = true;
            }
            TVal val_val = from_entries_get_index(ctx, pair, 1);
            if (ctx.should_throw) {
                if (key_val_pinned) ctx.heap.decref_tval(&key_val);
                arr_iterator_close_after_throw(ctx, iterator);
                return;
            }
            // Pin val_val too: ToPropertyKey below may invoke a user toString
            // (another call_fn), which would clobber val_val the same way.
            bool val_val_pinned = false;
            if (val_val.is_heap_allocated() && val_val.get_heapptr() != null) {
                ((types::HeapHeader*)val_val.get_heapptr()).incref();
                val_val_pinned = true;
            }

            // ToPropertyKey(k), a throwing toString also closes the iterator.
            HString* key_str = builtin_to_property_key(ctx, key_val);
            if (key_val_pinned) ctx.heap.decref_tval(&key_val);
            if (ctx.should_throw) {
                if (val_val_pinned) ctx.heap.decref_tval(&val_val);
                arr_iterator_close_after_throw(ctx, iterator);
                return;
            }
            if (key_str != null) {
                obj.put_prop(key_str, val_val, hobject::PROP_FLAGS_WEC, ctx.heap);
            }
            if (val_val_pinned) ctx.heap.decref_tval(&val_val);
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
        HString* length_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
        if (try len_tv = iterable.get_prop(length_key, ctx.heap)) {
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
            if (try e2 = iterable.get_prop_proto(idx_str, ctx.heap)) {
                entry = e2;
                got_entry = true;
            }
        }
        if (!got_entry) continue;
        if (!entry.is_object()) continue;
        HObject* pair = (HObject*)entry.get_heapptr();
        // Get key from pair[0] and value from pair[1], same dual-path logic
        TVal key_val;
        TVal val_val;
        bool got_key = false;
        if (pair.array_size > 0) {
            if (try kv = pair.get_array_idx(0)) { key_val = kv; got_key = true; }
        }
        if (!got_key) {
            HString* zero_str = ctx.heap.int_to_hstring(0);
            if (zero_str == null) continue;
            if (try kv2 = pair.get_prop_proto(zero_str, ctx.heap)) { key_val = kv2; got_key = true; }
        }
        if (!got_key) continue;
        TVal val_tmp; val_tmp.set_undefined();
        if (pair.array_size > 1) {
            if (try vv = pair.get_array_idx(1)) { val_tmp = vv; }
        } else {
            HString* one_str = ctx.heap.int_to_hstring(1);
            if (one_str != null) {
                if (try vv2 = pair.get_prop_proto(one_str, ctx.heap)) { val_tmp = vv2; }
            }
        }
        val_val = val_tmp;
        HString* key_str = builtin_to_property_key(ctx, key_val);
        if (key_str != null) {
            obj.put_prop(key_str, val_val, hobject::PROP_FLAGS_WEC, ctx.heap);
        }
    }
    ctx.result.set_object(obj);
}

// ============================================================================
// Object.groupBy, ES2024 §23.1.2.1
// ============================================================================
fn void builtin_object_groupBy(BuiltinContext* ctx) {
    HObject* groups = group_by_shared(ctx, false);
    if (groups == null) { ctx.result.set_undefined(); return; }
    ctx.result.set_object(groups);
}

/// Convert a TVal to a property key (HString*) for use in Object.fromEntries.
/// Per ES2019 §19.1.2.5, this performs ToPropertyKey on the entry's "0" element.
/// Uses builtin_to_string_vm for object values (calls toString/valueOf via ToPrimitive),
/// and builtin_to_string for primitives.
fn HString* builtin_to_property_key(BuiltinContext* ctx, TVal key_val) {
    if (key_val.is_string()) {
        HString* s = (HString*)key_val.get_heapptr();
        // Symbols are always canonical (never re-interned as strings); plain
        // strings must be. A string produced by e.g. a concat opcode's
        // accumulator fast path is heap-allocated but NOT in the intern
        // table, so put_prop's pointer-identity property lookup would never
        // match it again from a literal (test262 fromEntries/evaluation-order.js).
        if (s != null && !s.is_symbol() && !s.is_interned()) {
            return builtin_intern_string(ctx.heap, s.get_data());
        }
        return s;
    }
    if (key_val.is_number()) {
        return builtin_to_string(ctx.heap, &key_val);
    }
    if (key_val.is_object()) {
        HObject* key_obj = (HObject*)key_val.get_heapptr();
        // Symbol wrapper objects: ToPrimitive unwraps to the Symbol itself,
        // and Symbols pass through ToPropertyKey unchanged (never stringified).
        if (key_obj.get_class() == hobject::ObjClass.SYMBOL) {
            TVal prim = (*key_obj.extra_ptr()).prim.primitive_value;
            if (prim.is_string()) {
                HString* s = (HString*)prim.get_heapptr();
                if (s != null && s.is_symbol()) return s;
            }
            return builtin_to_string(ctx.heap, &key_val);
        }
        // For other objects, call ToString (invokes toString/valueOf via ToPrimitive).
        // builtin_to_string_vm does not guarantee an interned result (a
        // toString() returning a fresh concat-accumulator string), so intern
        // it here, same rationale as the is_string() branch above.
        HString* ts = builtin_to_string_vm(ctx, &key_val);
        if (ts != null && !ts.is_symbol() && !ts.is_interned()) {
            return builtin_intern_string(ctx.heap, ts.get_data());
        }
        return ts;
    }
    // null, undefined, boolean, call ToString
    return builtin_to_string(ctx.heap, &key_val);
}

fn void builtin_object_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    // ES2022 §20.1.3.6 step 1-2: undefined and null shortcut
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

    // ES2022 §20.1.3.6 step 3: Let O = ToObject(this value)
    // For object/lightfunc this values, use them directly.
    // For primitives, wrap them so we can search @@toStringTag via prototype chain.

    char[64] buf;
    HString* tag_sym = ensure_tostringtag_symbol(ctx.heap);

    // Helper inline: build and return "[object <tag>]" string
    // (used at end for builtinTag fallback)

    // Handle lightfunc this, [[Call]] → builtinTag = "Function"
    if (this_val.is_lightfunc()) {
        char* builtin_tag = "Function";
        if (tag_sym != null) {
            // Lightfuncs have Function.prototype as prototype; search it for @@toStringTag
            HObject* fn_proto = ctx.heap.function_proto;
            if (fn_proto != null) {
                TVal? tag_val = builtins_generic_get(fn_proto, tag_sym, ctx);
                if (ctx.should_throw) return;
                if (try tv = tag_val) {
                    if (tv.is_string()) {
                        HString* tag_str = (HString*)tv.get_heapptr();
                        if (tag_str != null && !tag_str.is_symbol()) {
                            char[] tag_bytes = tag_str.get_data();
                            int tag_len = (int)tag_bytes.len;
                            if (tag_len > 0 && tag_len < 62) {
                                buf[0] = '['; buf[1] = 'o'; buf[2] = 'b'; buf[3] = 'j';
                                buf[4] = 'e'; buf[5] = 'c'; buf[6] = 't'; buf[7] = ' ';
                                int pos = 8;
                                for (int i = 0; i < tag_len && pos < 62; i++) { buf[pos++] = tag_bytes[i]; }
                                buf[pos++] = ']';
                                ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:pos]));
                                return;
                            }
                        }
                    }
                }
            }
        }
        int len = (int)(io::bprintf(&buf, "[object %s]", (ZString)builtin_tag) ?? buf[:0]).len;
        if (len > 0 && len < 64) {
            ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
        } else {
            ctx.result.set_string(builtin_intern_string(ctx.heap, "[object Function]"));
        }
        return;
    }

    // For primitive this values (boolean/number/string/symbol), find their wrapper prototype
    // so we can check @@toStringTag via the prototype chain (ES2022 §20.1.3.6 steps 3+15).
    if (this_val.is_boolean() || this_val.is_number() || this_val.is_fastint() ||
        this_val.is_bigint() || this_val.is_string() /* includes symbols */) {
        // Determine builtinTag and which prototype to search for @@toStringTag
        char* builtin_tag;
        HObject* prim_proto;
        if (this_val.is_boolean()) {
            builtin_tag = "Boolean";
            prim_proto = ctx.heap.bool_proto;
        } else if (this_val.is_number() || this_val.is_fastint()) {
            builtin_tag = "Number";
            prim_proto = ctx.heap.number_proto;
        } else if (this_val.is_bigint()) {
            // BigInt has no special builtinTag (ES2020 §20.1.3.6); its tag comes
            // from BigInt.prototype[@@toStringTag] = "BigInt".
            builtin_tag = "Object";
            prim_proto = ctx.heap.bigint_proto;
        } else if (is_symbol_val(this_val)) {
            // Symbol wrappers have no special builtinTag in the spec (ES2022 §20.1.3.6);
            // they get their tag from Symbol.prototype[@@toStringTag] = "Symbol".
            builtin_tag = "Object";
            prim_proto = ctx.heap.symbol_proto;
        } else {
            // Regular string
            builtin_tag = "String";
            prim_proto = ctx.heap.string_proto;
        }
        // Check @@toStringTag via the wrapper's prototype chain
        if (tag_sym != null && prim_proto != null) {
            // Create a temporary wrapper object to search the prototype chain.
            // Use get_prop_or_accessor_proto starting from prim_proto directly.
            hobject::PropLookupResult res = prim_proto.get_prop_or_accessor_proto((void*)tag_sym, true, ctx.heap);
            if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                TVal tv = res.data_val;
                if (tv.is_string()) {
                    HString* tag_str = (HString*)tv.get_heapptr();
                    if (tag_str != null && !tag_str.is_symbol()) {
                        char[] tag_bytes = tag_str.get_data();
                        int tag_len = (int)tag_bytes.len;
                        if (tag_len > 0 && tag_len < 62) {
                            buf[0] = '['; buf[1] = 'o'; buf[2] = 'b'; buf[3] = 'j';
                            buf[4] = 'e'; buf[5] = 'c'; buf[6] = 't'; buf[7] = ' ';
                            int pos = 8;
                            for (int i = 0; i < tag_len && pos < 62; i++) { buf[pos++] = tag_bytes[i]; }
                            buf[pos++] = ']';
                            ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:pos]));
                            return;
                        }
                    }
                }
            } else if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                // Accessor getter for @@toStringTag on prototype, invoke it with this = primitive wrapper
                if (ctx.vm != null && ctx.heap.call_fn != null) {
                    // Build a temp TVal wrapping the primitive as the receiver
                    TVal prim_wrapper;
                    prim_wrapper.set_object(prim_proto);
                    TVal tag_result = ctx.heap.call_fn(ctx.vm, res.acc.accessor_fn, null, 0, prim_wrapper);
                    if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }
                    if (tag_result.is_string()) {
                        HString* tag_str = (HString*)tag_result.get_heapptr();
                        if (tag_str != null && !tag_str.is_symbol()) {
                            char[] tag_bytes = tag_str.get_data();
                            int tag_len = (int)tag_bytes.len;
                            if (tag_len > 0 && tag_len < 62) {
                                buf[0] = '['; buf[1] = 'o'; buf[2] = 'b'; buf[3] = 'j';
                                buf[4] = 'e'; buf[5] = 'c'; buf[6] = 't'; buf[7] = ' ';
                                int pos = 8;
                                for (int i = 0; i < tag_len && pos < 62; i++) { buf[pos++] = tag_bytes[i]; }
                                buf[pos++] = ']';
                                ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:pos]));
                                return;
                            }
                        }
                    }
                }
            }
        }
        // Fall back to builtinTag
        int len = (int)(io::bprintf(&buf, "[object %s]", (ZString)builtin_tag) ?? buf[:0]).len;
        if (len > 0 && len < 64) {
            ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
        } else {
            ctx.result.set_string(builtin_intern_string(ctx.heap, "[object Object]"));
        }
        return;
    }

    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();

        // ES2022 §20.1.3.6: builtinTag determined by internal slot checks only.
        // Objects whose class is MAP, SET, WEAKMAP, WEAKSET, SYMBOL, PROMISE,
        // GENERATOR, JSON, MATH do not appear in the spec's internal-slot list;
        // they rely on @@toStringTag set on their prototypes.
        char* class_name = "Object";

        // Proxy: IsArray may throw for a revoked proxy (§7.2.2 step 3.a).
        if (obj.flags.exotic_proxyobj) {
            bool is_arr = false;
            if (!proxy_is_array(ctx.heap, obj, &is_arr)) {
                // Revoked proxy or other error, propagate TypeError.
                if (!proxy_ctx_ok(ctx)) return;
                return;
            }
            if (is_arr) {
                class_name = "Array";
            } else if (obj.is_callable()) {
                // §20.1.3.6 step 6: callable → builtinTag "Function".
                class_name = "Function";
            }
            // Fall through to @@toStringTag lookup below.
        } else {
        switch (obj.get_class()) {
            case hobject::ObjClass.ARRAY:     class_name = "Array"; break;
            case hobject::ObjClass.FUNCTION:  class_name = "Function"; break;
            case hobject::ObjClass.ARGUMENTS: class_name = "Arguments"; break;
            case hobject::ObjClass.BOOLEAN:   class_name = "Boolean"; break;
            case hobject::ObjClass.NUMBER:    class_name = "Number"; break;
            case hobject::ObjClass.STRING:    class_name = "String"; break;
            case hobject::ObjClass.ERROR:     class_name = "Error"; break;
            case hobject::ObjClass.DATE:      class_name = "Date"; break;
            case hobject::ObjClass.REGEXP:    class_name = "RegExp"; break;
            default:                          class_name = "Object"; break;
        }
        // Check callable (IsCallable) for non-FUNCTION objects that have [[Call]]
        if (!obj.flags.exotic_proxyobj &&
            obj.is_callable() && obj.get_class() != hobject::ObjClass.FUNCTION) {
            class_name = "Function";
        }
        } // end else (non-proxy class_name determination)

        // ES2022 §20.1.3.6 step 15: Get(O, @@toStringTag)
        if (tag_sym != null) {
            TVal? tag_val = builtins_generic_get(obj, tag_sym, ctx);
            if (ctx.should_throw) return;
            if (try tv = tag_val) {
                if (tv.is_string()) {
                    HString* tag_str = (HString*)tv.get_heapptr();
                    if (tag_str != null && !tag_str.is_symbol()) {
                        char[] tag_bytes = tag_str.get_data();
                        int tag_len = (int)tag_bytes.len;
                        if (tag_len > 0 && tag_len < 62) {
                            buf[0] = '['; buf[1] = 'o'; buf[2] = 'b'; buf[3] = 'j';
                            buf[4] = 'e'; buf[5] = 'c'; buf[6] = 't'; buf[7] = ' ';
                            int pos = 8;
                            for (int i = 0; i < tag_len && pos < 62; i++) { buf[pos++] = tag_bytes[i]; }
                            buf[pos++] = ']';
                            ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:pos]));
                            return;
                        }
                    }
                }
            }
        }

        int len = (int)(io::bprintf(&buf, "[object %s]", (ZString)class_name) ?? buf[:0]).len;
        if (len > 0 && len < 64) {
            ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
            return;
        }
    }
    ctx.result.set_string(builtin_intern_string(ctx.heap, "[object Object]"));
}

/// Object.prototype.hasOwnProperty, ES2022 §20.1.3.2
/// Step 1: Let P = ? ToPropertyKey(V)  (before ToObject)
/// Step 2: Let O = ? ToObject(this value)
fn void builtin_object_proto_hasOwnProperty(BuiltinContext* ctx) {
    // Step 1: ToPropertyKey(V), must run BEFORE ToObject(this)
    TVal arg;
    if (ctx.argc > 0) {
        arg = ctx.regs[ctx.base_reg];
    } else {
        arg.set_undefined();
    }
    HString* key = builtin_to_property_key_vm(ctx, &arg);
    if (key == null) {
        // Propagate exception if ToPropertyKey threw
        if (ctx.should_throw) return;
        ctx.result.set_boolean(false);
        return;
    }
    // Step 2: ToObject(this), throws TypeError for null/undefined
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_null() || this_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.hasOwnProperty called on null or undefined");
        return;
    }
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
        // Primitive this value, return false (no own properties)
        ctx.result.set_boolean(false);
        return;
    }
    if (obj.flags.exotic_proxyobj) {
        ProxyDesc pd;
        if (!proxy_mop_get_own(ctx.vm, ctx.heap, obj, key, &pd)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_boolean(pd.found);
        return;
    }
    // Module Namespace Exotic: HasOwnProperty calls [[GetOwnProperty]], which
    // materialises the export's value via [[Get]] and throws ReferenceError for
    // a TDZ binding (§10.4.6.5 step 4).
    if (obj.flags.exotic_module_ns) {
        ProxyDesc nd;
        if (!module_ns_own_desc(ctx.vm, ctx.heap, obj, key, &nd)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_boolean(nd.found);
        return;
    }
    // Check own property
    PropValue*? entry = obj.find_prop(key, ctx.heap);
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

/// Object.prototype.propertyIsEnumerable, ES5 §15.2.4.7
fn void builtin_object_proto_propertyIsEnumerable(BuiltinContext* ctx) {
    // V = first argument, converted to string key
    TVal arg;
    if (ctx.argc > 0) {
        arg = ctx.regs[ctx.base_reg];
    } else {
        arg.set_undefined();
    }
    HString* key = builtin_to_property_key_vm(ctx, &arg);
    if (key == null) {
        if (ctx.should_throw) return;
        ctx.result.set_boolean(false);
        return;
    }
    // O = ToObject(this value), throws TypeError for null/undefined
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_null() || this_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.propertyIsEnumerable called on null or undefined");
        return;
    }
    HObject* obj;
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        obj = (HObject*)this_val.get_heapptr();
    } else {
        ctx.result.set_boolean(false);
        return;
    }
    if (obj.flags.exotic_proxyobj) {
        ProxyDesc pd;
        if (!proxy_mop_get_own(ctx.vm, ctx.heap, obj, key, &pd)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_boolean(pd.found && pd.enumerable);
        return;
    }
    // Module Namespace Exotic: propertyIsEnumerable calls [[GetOwnProperty]],
    // which reads the live binding and throws ReferenceError for a TDZ export.
    if (obj.flags.exotic_module_ns) {
        ProxyDesc nd;
        if (!module_ns_own_desc(ctx.vm, ctx.heap, obj, key, &nd)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_boolean(nd.found && nd.enumerable);
        return;
    }
    // Find own property descriptor
    PropValue*? entry = obj.find_prop(key, ctx.heap);
    if (try e = entry) {
        uint prop_idx = (uint)((char*)e - (char*)obj.prop_values()) / hobject::PropValue::size;
        ctx.result.set_boolean(obj.get_prop_flags(prop_idx, ctx.heap).enumerable);
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

/// Object.prototype.valueOf, ES5 §15.2.4.4
/// Performs ToObject(this) and returns the resulting object.
/// Throws TypeError if this is undefined or null (RequireObjectCoercible).
fn void builtin_object_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    // RequireObjectCoercible: null and undefined throw TypeError
    if (this_val.is_null() || this_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.valueOf called on null or undefined");
        return;
    }
    // ToObject: primitives are wrapped in their exotic wrapper objects
    if (!builtin_to_object(ctx, this_val)) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.valueOf: ToObject failed");
        return;
    }
    // ctx.result was set by builtin_to_object
}

/// Object.prototype.__proto__ getter, ES2015 Annex B §B.2.2.1.
/// Wraps Object.getPrototypeOf: ToObject(this) and return its [[Prototype]].
fn void builtin_object_proto___proto___getter(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    // §B.2.2.1 step 1: ToObject(this), throws TypeError for null/undefined.
    if (this_val.is_null() || this_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.__proto__ called on null or undefined");
        return;
    }
    // Primitive this: wrap in a temporary exotic object so we can read [[Prototype]].
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        if (!builtin_to_object(ctx, this_val)) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.__proto__: ToObject failed");
            return;
        }
        this_val = *ctx.result;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    // Proxy exotic: route through [[GetPrototypeOf]] so traps fire.
    if (obj.flags.exotic_proxyobj) {
        TVal proto_val;
        if (!proxy_mop_get_proto(ctx.vm, ctx.heap, obj, &proto_val)) { proxy_ctx_ok(ctx); return; }
        *ctx.result = proto_val;
        return;
    }
    HObject* proto = obj.prototype;
    if (proto == null) {
        ctx.result.set_null();
    } else {
        ctx.result.set_object(proto);
    }
}

/// Object.prototype.__proto__ setter, ES2015 Annex B §B.2.2.2.
/// Argument must be Object or null; this must be object-coercible.
/// Calls the equivalent of Object.setPrototypeOf(this, value) on success.
fn void builtin_object_proto___proto___setter(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    // §B.2.2.2 step 1: RequireObjectCoercible(this).
    if (this_val.is_null() || this_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.__proto__ setter called on null or undefined");
        return;
    }
    // The setter is a no-op when invoked with no argument (undefined → TypeError by spec).
    TVal proto_val;
    if (ctx.argc >= 1) {
        proto_val = ctx.regs[ctx.base_reg];
    } else {
        proto_val.set_undefined();
    }
    // §B.2.2.2 step 2: If proto is neither Object nor null, throw TypeError.
    if (!proto_val.is_null() && !proto_val.is_object() && !proto_val.is_lightfunc()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.__proto__: prototype must be an object or null");
        return;
    }
    // LIGHTFUNC proto: not allowed by Annex B §B.2.2.2, throw TypeError.
    if (proto_val.is_lightfunc()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.__proto__: prototype must be an object or null");
        return;
    }
    // §B.2.2.2 step 3: ToObject(this); primitives return the primitive unchanged.
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        // Primitive this, per §B.2.2.2 step 3, return `this` unchanged.
        *ctx.result = this_val;
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    // Proxy exotic: route through [[SetPrototypeOf]] so traps fire.
    if (obj.flags.exotic_proxyobj) {
        bool ok;
        if (!proxy_mop_set_proto(ctx.vm, ctx.heap, obj, proto_val, &ok)) { proxy_ctx_ok(ctx); return; }
        if (!ok) {
            builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.__proto__: 'setPrototypeOf' trap returned falsish");
            return;
        }
        ctx.result.set_undefined();
        return;
    }
    HObject* new_proto = proto_val.is_null() ? null : (HObject*)proto_val.get_heapptr();
    if (!ordinary_set_proto(ctx, obj, new_proto)) {
        if (ctx.should_throw) return;
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.__proto__: cannot set prototype (object is not extensible or would create a cycle)");
        return;
    }
    ctx.result.set_undefined();
}

/// Object.prototype.isPrototypeOf(V), ES2022 §20.1.3.3
/// Step 1: If V is not Object, return false.
/// Step 2: Let O = ? ToObject(this value), throws TypeError for null/undefined.
/// Walks the prototype chain of V looking for O.
fn void builtin_object_proto_isPrototypeOf(BuiltinContext* ctx) {
    ctx.result.set_boolean(false);

    // Step 1: If V is not an Object, return false (no TypeError for null/undefined this)
    if (ctx.argc == 0) {
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object() || arg.get_heapptr() == null) {
        return;
    }

    // Step 2: ToObject(this), throws TypeError for null/undefined
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_null() || this_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.isPrototypeOf called on null or undefined");
        return;
    }
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        // Primitive this (not null/undefined), ToObject would wrap it; it can't be in any chain
        return;
    }
    HObject* proto = (HObject*)this_val.get_heapptr();
    HObject* cur = (HObject*)arg.get_heapptr();

    // ES2022 §20.1.3.3 step 3: walk [[GetPrototypeOf]] on V (respects proxy traps).
    uint depth = 0;
    while (depth < 1024) {
        TVal proto_tv;
        if (!object_get_proto(ctx.vm, ctx.heap, cur, &proto_tv)) {
            if (!proxy_ctx_ok(ctx)) return;
            return;
        }
        if (proto_tv.is_null()) break;
        if (!proto_tv.is_object() || proto_tv.get_heapptr() == null) break;
        cur = (HObject*)proto_tv.get_heapptr();
        if (cur == proto) {
            ctx.result.set_boolean(true);
            return;
        }
        depth++;
    }
}

/// Object.prototype.toLocaleString(), ES2022 §20.1.3.5
/// Invoke(this, "toString"), gets toString via prototype chain and calls it with this as receiver.
/// Throws TypeError if this is null or undefined.
fn void builtin_object_proto_toLocaleString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    // RequireObjectCoercible: null and undefined throw TypeError
    if (this_val.is_null() || this_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.toLocaleString called on null or undefined");
        return;
    }

    HString* ts_key = (HString*)ctx.heap.strs[heap::BuiltinStr.TO_STRING];

    // Resolve the starting object for the [[Get]] prototype walk.
    // For object this, start from the object itself.
    // For primitives, start from their prototype (so they inherit toString).
    HObject* search_start = null;
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        search_start = (HObject*)this_val.get_heapptr();
    } else if (this_val.is_boolean()) {
        search_start = ctx.heap.bool_proto;
    } else if (this_val.is_number() || this_val.is_fastint()) {
        search_start = ctx.heap.number_proto;
    } else if (is_symbol_val(this_val)) {
        search_start = ctx.heap.symbol_proto;
    } else if (this_val.is_string()) {
        search_start = ctx.heap.string_proto;
    }

    if (search_start == null) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.toLocaleString: cannot resolve this");
        return;
    }

    // Get toString via prototype chain using get_prop_or_accessor_proto, which
    // properly handles both data properties and accessor (getter) properties.
    TVal fn_val;
    bool found = false;
    hobject::PropLookupResult res = search_start.get_prop_or_accessor_proto((void*)ts_key, true, ctx.heap);
    if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        fn_val = res.data_val;
        found = true;
    } else if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        // Accessor getter for toString, invoke it with this_val as receiver
        if (ctx.vm != null && ctx.heap.call_fn != null) {
            TVal getter_result = ctx.heap.call_fn(ctx.vm, res.acc.accessor_fn, null, 0, this_val);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return;
            }
            fn_val = getter_result;
            found = true;
        }
    }

    if (!found) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.toLocaleString: toString is not a function");
        return;
    }

    bool callable = fn_val.is_lightfunc() ||
        (fn_val.is_object() && fn_val.get_heapptr() != null &&
         ((HObject*)fn_val.get_heapptr()).is_callable());
    if (!callable) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Object.prototype.toLocaleString: toString is not a function");
        return;
    }

    // Invoke toString with this_val as receiver.
    // Use call_fn when a VM context is available (handles both lightfunc and object callees).
    if (ctx.vm != null && ctx.heap.call_fn != null) {
        TVal result = ctx.heap.call_fn(ctx.vm, fn_val, null, 0, this_val);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return;
        }
        *ctx.result = result;
        return;
    }
    // Fallback: re-dispatch (only works for HObject callees in vm_calls context)
    ctx.regs[ctx.base_reg - 2] = fn_val;
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}
fn bool register_object_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Object.prototype, the root of all prototype chains
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Object.prototype is the root, its [[Prototype]] is null
    heap.object_proto = proto;

    // Add .toString() method to Object.prototype
    HString* tostring_key = (HString*)heap.strs[heap::BuiltinStr.TO_STRING];
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_PROTO_TOSTRING.ordinal);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC, heap);

    // Add .hasOwnProperty() method to Object.prototype
    HString* hasown_key = builtin_intern_string(heap, "hasOwnProperty");
    TVal hasown_tv;
    hasown_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_PROTO_HASOWNPROPERTY.ordinal);
    proto.put_prop(hasown_key, hasown_tv, hobject::PROP_FLAGS_WC, heap);

    // Add .propertyIsEnumerable() method to Object.prototype (non-enumerable per ES5 §15.2.4.7)
    HString* propisenum_key = builtin_intern_string(heap, "propertyIsEnumerable");
    TVal propisenum_tv;
    propisenum_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_PROTO_PROPERTYISENUMERABLE.ordinal);
    proto.put_prop(propisenum_key, propisenum_tv, hobject::PROP_FLAGS_WC, heap);

    // Add .valueOf() method to Object.prototype (returns 'this')
    HString* valueof_key = (HString*)heap.strs[heap::BuiltinStr.VALUE_OF];
    TVal valueof_tv;
    valueof_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_PROTO_VALUEOF.ordinal);
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WC, heap);

    // Add .isPrototypeOf() method to Object.prototype
    HString* isproto_key = builtin_intern_string(heap, "isPrototypeOf");
    TVal isproto_tv;
    isproto_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_PROTO_ISPROTOTYPEOF.ordinal);
    proto.put_prop(isproto_key, isproto_tv, hobject::PROP_FLAGS_WC, heap);

    // Add .toLocaleString() method to Object.prototype (ES5 §15.2.4.3)
    HString* tolocalestring_key = builtin_intern_string(heap, "toLocaleString");
    TVal tolocalestring_tv;
    tolocalestring_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_PROTO_TOLOCALESTRING.ordinal);
    proto.put_prop(tolocalestring_key, tolocalestring_tv, hobject::PROP_FLAGS_WC, heap);

    // Add .__proto__ accessor (ES2015 Annex B §B.2.2.1 / §B.2.2.2), getter
    // returns Object.getPrototypeOf(this); setter is Object.setPrototypeOf(this, value).
    // Needed because test262 tests use `obj.__proto__` directly as a synonym for
    // Object.getPrototypeOf(obj); without this accessor the property is undefined.
    //
    // IMPORTANT: `heap.function_proto` is NOT set yet at this point,
    // register_object_constructor is called BEFORE register_function_constructor
    // (see core.c3). Setting the accessor's [[Prototype]] to the still-null
    // heap.function_proto would leave Function.prototype.{apply,call,bind,toString}
    // invisible, breaking test262's
    // built-in-function-object test (Object.getOwnPropertyDescriptors walks
    // every reachable function via Reflect.ownKeys and calls
    // Function.prototype.toString on each). The fix: build the accessor first,
    // then back-patch `getter.prototype` / `setter.prototype` to
    // heap.function_proto AFTER register_function_constructor has run,
    // see end of register_object_constructor (deferred_proto_accessor_fixup).
    HObject*? __proto___getter_opt = null;
    HObject*? __proto___setter_opt = null;
    {
        HString* proto_accessor_key = builtin_intern_string(heap, "__proto__");
        if (proto_accessor_key != null) {
            HObject*? getter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            HObject*? setter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = getter_raw) return false;
            if (catch err = setter_raw) return false;
            __proto___getter_opt = getter_raw;
            __proto___setter_opt = setter_raw;
            HObject* __proto___getter = __proto___getter_opt!!;
            HObject* __proto___setter = __proto___setter_opt!!;
            __proto___getter.flags.callable = true;
            __proto___getter.flags.constructable = false;
            (*__proto___getter.extra_ptr()).func.builtin_fn_index = (int)Builtin.OBJECT_PROTO___PROTO___GETTER.ordinal;
            __proto___setter.flags.callable = true;
            __proto___setter.flags.constructable = false;
            (*__proto___setter.extra_ptr()).func.builtin_fn_index = (int)Builtin.OBJECT_PROTO___PROTO___SETTER.ordinal;
            // Set .name = "get __proto__" / "set __proto__" per Annex B.
            HString* name_key = heap.str(heap::BuiltinStr.NAME);
            if (name_key != null) {
                HString* gname_str = builtin_intern_string(heap, "get __proto__");
                if (gname_str != null) {
                    TVal gname_tv; gname_tv.set_string(gname_str);
                    __proto___getter.put_prop(name_key, gname_tv, hobject::PROP_FLAGS_NWC, heap);
                }
                HString* sname_str = builtin_intern_string(heap, "set __proto__");
                if (sname_str != null) {
                    TVal sname_tv; sname_tv.set_string(sname_str);
                    __proto___setter.put_prop(name_key, sname_tv, hobject::PROP_FLAGS_NWC, heap);
                }
            }
            HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            if (length_key != null) {
                TVal glen_tv; glen_tv.set_fastint(0);
                __proto___getter.put_prop(length_key, glen_tv, hobject::PROP_FLAGS_NWC, heap);
                TVal slen_tv; slen_tv.set_fastint(1);
                __proto___setter.put_prop(length_key, slen_tv, hobject::PROP_FLAGS_NWC, heap);
            }
            TVal getter_tv; getter_tv.set_object(__proto___getter);
            TVal setter_tv; setter_tv.set_object(__proto___setter);
            hobject::PropFlags acc_flags;
            acc_flags.writable = false;
            acc_flags.enumerable = false;
            acc_flags.configurable = true;
            acc_flags.is_accessor = true;
            proto.put_prop(proto_accessor_key, hobject::hobject_create_accessors(heap, getter_tv, setter_tv), acc_flags, heap);
            // Stash on the heap so register_function_constructor can back-patch
            // the [[Prototype]] once Function.prototype exists.
            heap.object_proto___proto___getter = __proto___getter;
            heap.object_proto___proto___setter = __proto___setter;
        }
    }

    // Create Object constructor as a proper HObject (not LIGHTFUNC)
    // so it can carry .prototype, .length, etc.
    HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = obj_raw) return false;
    HObject* obj = obj_raw;
    (*obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.OBJECT.ordinal;

    // Set .constructor on Object.prototype to point to the actual Object constructor object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    // Set Object.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    obj.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    // Set Object.length (ES5 §15.2.1)
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(1);
    obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    // Set Object.name (ES2015 §19: "length" before "name")
    HString* name_key_obj = heap.str(heap::BuiltinStr.NAME);
    if (name_key_obj != null) {
        HString* name_val_obj = builtin_intern_string(heap, "Object");
        if (name_val_obj != null) {
            TVal name_tv_obj;
            name_tv_obj.set_string(name_val_obj);
            obj.put_prop(name_key_obj, name_tv_obj, hobject::PROP_FLAGS_NWC, heap);
        }
    }

    // Add static methods to Object constructor
    // ES5 §15.2.3.x: builtin methods have [[Writable]]:true, [[Enumerable]]:false, [[Configurable]]:true
    HString* keys_key = builtin_intern_string(heap, "keys");
    if (keys_key == null) return false;
    TVal keys_tv;
    keys_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_KEYS.ordinal);
    obj.put_prop(keys_key, keys_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.getPrototypeOf, ES5 §15.2.3.2
    HString* getproto_key = builtin_intern_string(heap, "getPrototypeOf");
    if (getproto_key == null) return false;
    TVal getproto_tv;
    getproto_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_GETPROTOTYPEOF.ordinal);
    obj.put_prop(getproto_key, getproto_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.isExtensible, ES5 §15.2.3.13
    HString* isext_key = builtin_intern_string(heap, "isExtensible");
    if (isext_key == null) return false;
    TVal isext_tv;
    isext_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_ISEXTENSIBLE.ordinal);
    obj.put_prop(isext_key, isext_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.preventExtensions, ES5 §15.2.3.10
    HString* prevext_key = builtin_intern_string(heap, "preventExtensions");
    if (prevext_key == null) return false;
    TVal prevext_tv;
    prevext_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_PREVENTEXTENSIONS.ordinal);
    obj.put_prop(prevext_key, prevext_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.getOwnPropertyDescriptor, ES5 §15.2.3.3
    HString* getownpropdesc_key = builtin_intern_string(heap, "getOwnPropertyDescriptor");
    if (getownpropdesc_key == null) return false;
    TVal getownpropdesc_tv;
    getownpropdesc_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_GETOWNPROPERTYDESCRIPTOR.ordinal);
    obj.put_prop(getownpropdesc_key, getownpropdesc_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.getOwnPropertyDescriptors, ES2017 §19.1.2.9
    HString* getownpropdescs_key = builtin_intern_string(heap, "getOwnPropertyDescriptors");
    if (getownpropdescs_key == null) return false;
    TVal getownpropdescs_tv;
    getownpropdescs_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_GETOWNPROPERTYDESCRIPTORS.ordinal);
    obj.put_prop(getownpropdescs_key, getownpropdescs_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.defineProperty, ES5 §15.2.3.6
    HString* defineprop_key = builtin_intern_string(heap, "defineProperty");
    if (defineprop_key == null) return false;
    TVal defineprop_tv;
    defineprop_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_DEFINEPROPERTY.ordinal);
    obj.put_prop(defineprop_key, defineprop_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.getOwnPropertyNames, ES5 §15.2.3.4
    HString* getownpropnames_key = builtin_intern_string(heap, "getOwnPropertyNames");
    if (getownpropnames_key == null) return false;
    TVal getownpropnames_tv;
    getownpropnames_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_GETOWNPROPERTYNAMES.ordinal);
    obj.put_prop(getownpropnames_key, getownpropnames_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.getOwnPropertySymbols, ES6 §19.1.2.7
    HString* getownpropsymbols_key = builtin_intern_string(heap, "getOwnPropertySymbols");
    if (getownpropsymbols_key == null) return false;
    TVal getownpropsymbols_tv;
    getownpropsymbols_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_GETOWNPROPERTYSYMBOLS.ordinal);
    obj.put_prop(getownpropsymbols_key, getownpropsymbols_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.defineProperties, ES5 §15.2.3.7
    HString* defineprops_key = builtin_intern_string(heap, "defineProperties");
    if (defineprops_key == null) return false;
    TVal defineprops_tv;
    defineprops_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_DEFINEPROPERTIES.ordinal);
    obj.put_prop(defineprops_key, defineprops_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.create, ES5 §15.2.3.5
    HString* create_key = builtin_intern_string(heap, "create");
    if (create_key == null) return false;
    TVal create_tv;
    create_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_CREATE.ordinal);
    obj.put_prop(create_key, create_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.seal, ES5 §15.2.3.8
    HString* seal_key = builtin_intern_string(heap, "seal");
    if (seal_key == null) return false;
    TVal seal_tv;
    seal_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_SEAL.ordinal);
    obj.put_prop(seal_key, seal_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.freeze, ES5 §15.2.3.9
    HString* freeze_key = builtin_intern_string(heap, "freeze");
    if (freeze_key == null) return false;
    TVal freeze_tv;
    freeze_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_FREEZE.ordinal);
    obj.put_prop(freeze_key, freeze_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.isSealed, ES5 §15.2.3.11
    HString* issealed_key = builtin_intern_string(heap, "isSealed");
    if (issealed_key == null) return false;
    TVal issealed_tv;
    issealed_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_ISSEALED.ordinal);
    obj.put_prop(issealed_key, issealed_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.isFrozen, ES5 §15.2.3.12
    HString* isfrozen_key = builtin_intern_string(heap, "isFrozen");
    if (isfrozen_key == null) return false;
    TVal isfrozen_tv;
    isfrozen_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_ISFROZEN.ordinal);
    obj.put_prop(isfrozen_key, isfrozen_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.entries, ES2017 §19.1.2.21
    HString* entries_key = builtin_intern_string(heap, "entries");
    if (entries_key == null) return false;
    TVal entries_tv;
    entries_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_ENTRIES.ordinal);
    obj.put_prop(entries_key, entries_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.values, ES2017 §19.1.2.22
    HString* values_key = builtin_intern_string(heap, "values");
    if (values_key == null) return false;
    TVal values_tv;
    values_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_VALUES.ordinal);
    obj.put_prop(values_key, values_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.assign, ES2015 §19.1.2.2
    HString* assign_key = builtin_intern_string(heap, "assign");
    if (assign_key == null) return false;
    TVal assign_tv;
    assign_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_ASSIGN.ordinal);
    obj.put_prop(assign_key, assign_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.is, ES6 §19.1.2.10
    HString* is_key = builtin_intern_string(heap, "is");
    if (is_key == null) return false;
    TVal is_tv;
    is_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_IS.ordinal);
    obj.put_prop(is_key, is_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.hasOwn, ES2022 §19.1.2.10
    HString* hasown_static_key = builtin_intern_string(heap, "hasOwn");
    if (hasown_static_key == null) return false;
    TVal hasown_static_tv;
    hasown_static_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_HASOWN.ordinal);
    obj.put_prop(hasown_static_key, hasown_static_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.setPrototypeOf, ES2015 §19.1.2.19
    HString* setproto_key = builtin_intern_string(heap, "setPrototypeOf");
    if (setproto_key == null) return false;
    TVal setproto_tv;
    setproto_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_SETPROTOTYPEOF.ordinal);
    obj.put_prop(setproto_key, setproto_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.fromEntries, ES2019 §19.1.2.5
    HString* fromentries_key = builtin_intern_string(heap, "fromEntries");
    if (fromentries_key == null) return false;
    TVal fromentries_tv;
    fromentries_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_FROMENTRIES.ordinal);
    obj.put_prop(fromentries_key, fromentries_tv, hobject::PROP_FLAGS_WC, heap);

    // Object.groupBy, ES2024 §23.1.2.1
    HString* groupby_key = builtin_intern_string(heap, "groupBy");
    if (groupby_key == null) return false;
    TVal groupby_tv;
    groupby_tv.set_lightfunc((void*)(usz)Builtin.OBJECT_GROUPBY.ordinal);
    obj.put_prop(groupby_key, groupby_tv, hobject::PROP_FLAGS_WC, heap);

    // Register Object constructor globally as an OBJECT (not LIGHTFUNC)
    HString* obj_key = heap.str_intern("Object");
    if (obj_key == null) return false;
    TVal obj_val;
    obj_val.set_object(obj);
    env::env_declare_nonenum(global_env, obj_key, obj_val);

    return true;
}
