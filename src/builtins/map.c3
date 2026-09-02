// Map constructor and Map.prototype methods.
module boomkat::builtins;
import boomkat::types;
import boomkat::hbigint;
import std::math;
import boomkat::hstring;
import boomkat::env;

import boomkat::heap;
import boomkat::hobject;

// Differs from === only in that NaN equals NaN.
// ============================================================================
// SameValueZero (ES6 §7.2.10) and SameValue (§7.2.9) differ only in ±0:
// SameValue treats +0 and -0 as distinct, SameValueZero treats them equal.
// `zero_signs_distinct` selects between them.
fn bool same_value_impl(TVal a, TVal b, bool zero_signs_distinct) {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) && math::is_nan(b.get_number())) return true;
                if (zero_signs_distinct && a.get_number() == 0.0 && b.get_number() == 0.0) {
                    return 1.0 / a.get_number() == 1.0 / b.get_number();
                }
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            // Strings over MAX_INTERN_BYTES are left un-interned, so two equal
            // strings can be distinct pointers. equals_hstring keeps the
            // interned-vs-interned case a single pointer compare and only falls
            // back to bytes when one side is un-interned.
            case STRING:    return ((hstring::HString*)a.get_heapptr()).equals_hstring(
                                       (hstring::HString*)b.get_heapptr());
            case OBJECT:    return a.get_heapptr() == b.get_heapptr();
            // A LIGHTFUNC builtin is an Object whose identity is its builtin
            // index rather than a pointer, so it compares the same way OBJECT
            // does. Without this it falls to `default: false`, and a builtin
            // used as a Map or Set key never matches itself on lookup.
            case LIGHTFUNC: return a.get_heapptr() == b.get_heapptr();
            case BIGINT:    return hbigint::hbigint_eq(a.get_bigint(), b.get_bigint());
            default: return false;
        }
    }
    if ((a.is_number() && b.is_fastint()) || (a.is_fastint() && b.is_number())) {
        double av = a.is_fastint() ? (double)a.get_fastint() : a.get_number();
        double bv = b.is_fastint() ? (double)b.get_fastint() : b.get_number();
        if (math::is_nan(av) && math::is_nan(bv)) return true;
        if (zero_signs_distinct && av == 0.0 && bv == 0.0) return 1.0 / av == 1.0 / bv;
        return av == bv;
    }
    return false;
}

fn bool same_value_zero(TVal a, TVal b) => same_value_impl(a, b, false);

// SameValue comparison (ES6 §7.2.9), used by Object.is; +0 !== -0.
fn bool same_value(TVal a, TVal b) => same_value_impl(a, b, true);

// ============================================================================
// Map helpers
// ============================================================================

fn HObject* check_map(BuiltinContext* ctx) {
    return check_collection_class(ctx, hobject::ObjClass.MAP, "Map.prototype method called on incompatible value");
}

// Find the index in array_part where a key matches. Returns -1 if not found.
// Map entries are stored as [k0, v0, k1, v1, ...] in array_part.
fn int map_find_key(HObject* map, TVal key, heap::Heap* h) {
    return coll_find(map, key, 2, h);
}

// ============================================================================
// Map constructor (ES6 §23.1.1)
// ============================================================================
fn void builtin_map(BuiltinContext* ctx) {
    coll_construct(ctx, hobject::ObjClass.MAP, ctx.heap.map_proto,
        "Constructor Map requires 'new'",
        "Map constructor argument is not an object",
        "set", "Map.prototype.set is not callable",
        "Map: iterable argument is not iterable",
        true, false);
}

// ============================================================================
// Map.prototype.set(key, value), ES6 §23.1.3.9
// ============================================================================
fn void builtin_map_proto_set(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    coll_set_entry(ctx, map, 2, false, "", true);
}

// ============================================================================
// Map.prototype.getOrInsert(key, value), ES2025 §24.1.3.9
// ============================================================================
fn void builtin_map_proto_getOrInsert(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    coll_get_or_insert(ctx, map, false, "", true);
}

// ============================================================================
// Map.prototype.getOrInsertComputed(key, callbackfn), ES2025 §24.1.3.10
// ============================================================================
fn void builtin_map_proto_getOrInsertComputed(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    coll_get_or_insert_computed(ctx, map, false, "", "callback function is not callable", true);
}

// ============================================================================
// Map.prototype.size getter, ES6 §23.1.3.10
// Counts non-deleted entries (deleted slots use TAG_DELETED sentinel).
// ============================================================================
fn void builtin_map_proto_size_get(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) return;
    uint count = 0;
    TVal* arr = map.array_part();
    if (arr != null) {
        for (uint i = 0; i + 1 < map.array_used; i += 2) {
            if (!arr[i].is_deleted()) count++;
        }
    }
    ctx.result.set_fastint((long)count);
}

// ============================================================================
// Map.prototype.get(key), ES6 §23.1.3.6
// ============================================================================
fn void builtin_map_proto_get(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key, ctx.heap);
    if (found >= 0) {
        *ctx.result = map.array_part()[(uint)found + 1];
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// Map.prototype.has(key), ES6 §23.1.3.7
// ============================================================================
fn void builtin_map_proto_has(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key, ctx.heap);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// Map.prototype.delete(key), ES6 §23.1.3.3
// Per ES6 spec, deletion marks the entry as "empty" (does not remove the slot)
// so concurrent iteration sees the deletion but new entries appear at the end.
// ============================================================================
fn void builtin_map_proto_delete(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }
    coll_delete(ctx, map, ctx.regs[ctx.base_reg], 2, true);
}

// ============================================================================
// Map.prototype.clear(), ES6 §23.1.3.1
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

    ctx.result.set_undefined();
}

// ============================================================================
// Map.prototype.keys(), ES6 §23.1.3.8
// Returns a MapIterator with kind=1 (keys).
// ============================================================================
fn void builtin_map_proto_keys(BuiltinContext* ctx) {
    create_map_iterator(ctx, 1);
}

// ============================================================================
// Map.prototype.data.values(), ES6 §23.1.3.11
// Returns a MapIterator with kind=0 (values).
// ============================================================================
fn void builtin_map_proto_values(BuiltinContext* ctx) {
    create_map_iterator(ctx, 0);
}

// ============================================================================
// Map.prototype.entries(), ES6 §23.1.3.4
// Returns a MapIterator with kind=2 (entries).
// ============================================================================
fn void builtin_map_proto_entries(BuiltinContext* ctx) {
    create_map_iterator(ctx, 2);
}

// ============================================================================
// MapIterator.prototype.next(), ES6 §23.1.5.2.1
// ============================================================================
fn void builtin_map_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        builtin_throw(ctx, heap.type_err_proto, "this is not an object");
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.MAP_ITERATOR) {
        builtin_throw(ctx, heap.type_err_proto, "this is not a Map Iterator");
        return;
    }

    HObject* target = (*iter.extra_ptr()).iter.target;
    if (target == null) {
        // Already exhausted, return {value: undefined, done: true}
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        TVal undef; undef.set_undefined();
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC, ctx.heap);
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv; done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
        ctx.result.set_object(result);
        return;
    }

    uint slot_idx = (*iter.extra_ptr()).iter.index * 2;  // Map entries are [k0,v0,k1,v1,...]
    uint kind = (*iter.extra_ptr()).iter.kind;

    bool done = false;
    TVal value;
    value.set_undefined();

    // Skip over deleted slots, array_used is high water mark,
    // and array_part() may contain TAG_DELETED slots from deletes.
    while (slot_idx < target.array_used && target.array_part() != null &&
           target.array_part()[slot_idx].is_deleted()) {
        slot_idx += 2;
    }

    if (slot_idx < target.array_used) {
        TVal* entries = target.array_part();
        if (entries != null) {
            if (kind == 1) {
                // keys: return key at slot_idx
                value = entries[slot_idx];
            } else if (kind == 0) {
                // values: return value at slot_idx+1
                value = entries[slot_idx + 1];
            } else {
                // entries: return [key, value]
                HObject*? pair_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try pair = pair_raw) {
                    pair.prototype = heap.array_proto;
                    pair.set_array_idx(0, entries[slot_idx], ctx.heap);
                    pair.set_array_idx(1, entries[slot_idx + 1], ctx.heap);
                    pair.array_used = 2;
                    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                    if (len_key != null) {
                        TVal len_tv;
                        len_tv.set_fastint(2);
                        pair.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
                    }
                    value.set_object(pair);
                }
            }
            (*iter.extra_ptr()).iter.index = (slot_idx / 2) + 1;
        } else {
            done = true;
        }
    } else {
        done = true;
    }

    if (done) {
        value.set_undefined();
        (*iter.extra_ptr()).iter.target = null;  // mark exhausted
    }

    // Create result object: {value, done}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC, ctx.heap);

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(done);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC, ctx.heap);

    ctx.result.set_object(result);
}

// ============================================================================
// Map.prototype.forEach(callbackfn[, thisArg]), ES6 §23.1.3.5
// ============================================================================
fn void builtin_map_proto_forEach(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }

    if (ctx.argc < 1) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "missing argument 0 when calling function forEach");
        ctx.result.set_undefined();
        return;
    }

    TVal callback = ctx.regs[ctx.base_reg];
    // ES6 §23.1.3.5 step 4: IsCallable(callbackfn). A lightfunc is callable, so
    // `map.forEach(console.log)` and any other native builtin passed as the
    // callback must be accepted; testing is_object() alone rejected them all.
    if (!tval_is_callable(callback)) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_k = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "object is not a function");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = ctx.heap.str(heap::BuiltinStr.MESSAGE);
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC, ctx.heap);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        ctx.result.set_undefined();
        return;
    }

    // ES6 §23.1.3.5, forEach iterates all non-empty entries and calls
    // callbackfn(value, key, map). Entries deleted before being visited are
    // skipped; entries added during forEach (appended) are visited.
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }

    TVal* entries = map.array_part();
    uint used = map.array_used;
    for (uint i = 0; i + 1 < used; i += 2) {
        TVal key = entries[i];
        if (key.is_deleted()) continue;  // skip deleted slot
        TVal value = entries[i + 1];

        TVal[3] args;
        args[0] = value;
        args[1] = key;
        args[2].set_object((void*)map);
        ctx.heap.call_fn(ctx.vm, callback, &args[0], 3, thisArg);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            ctx.result.set_undefined();
            return;
        }
        // After callback, refresh used (entries may have been added).
        used = map.array_used;
        entries = map.array_part();
    }

    ctx.result.set_undefined();
}

// ============================================================================
// Map[Symbol.species] getter, ES6 §23.1.2.2. Returns the this value (the
// constructor itself), so a subclass like `class MyMap extends Map {}` gets
// MyMap back from SpeciesConstructor calls that inherit this accessor.
// ============================================================================
fn void builtin_map_species_getter(BuiltinContext* ctx) {
    *ctx.result = ctx.this_val;
}

// ============================================================================
// Map.groupBy, ES2024 §24.1.2.1
// ============================================================================
fn void builtin_map_groupBy(BuiltinContext* ctx) {
    HObject* groups = group_by_shared(ctx, true);
    if (groups == null) { ctx.result.set_undefined(); return; }
    ctx.result.set_object(groups);
}

// ============================================================================
// Map constructor registration
// ============================================================================

fn bool register_map_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Map prototype (an ordinary object per ES6 §23.1.3, must NOT
    // carry the MAP ObjClass flag, otherwise check_map() would accept it as
    // a valid Map and methods like .set() would skip the TypeError guard).
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.map_proto = proto;

    // Add .set(key, value) method
    if (!register_string_proto_method(proto, heap, "set", Builtin.MAP_PROTO_SET.ordinal)) return false;
    // Add .get(key) method
    if (!register_string_proto_method(proto, heap, "get", Builtin.MAP_PROTO_GET.ordinal)) return false;
    // Add .has(key) method
    if (!register_string_proto_method(proto, heap, "has", Builtin.MAP_PROTO_HAS.ordinal)) return false;
    // Add .delete(key) method
    if (!register_string_proto_method(proto, heap, "delete", Builtin.MAP_PROTO_DELETE.ordinal)) return false;
    // Add .clear() method
    if (!register_string_proto_method(proto, heap, "clear", Builtin.MAP_PROTO_CLEAR.ordinal)) return false;
    // Add .keys() method
    if (!register_string_proto_method(proto, heap, "keys", Builtin.MAP_PROTO_KEYS.ordinal)) return false;
    // Add .values() method
    if (!register_string_proto_method(proto, heap, "values", Builtin.MAP_PROTO_VALUES.ordinal)) return false;
    // Add .entries() method
    if (!register_string_proto_method(proto, heap, "entries", Builtin.MAP_PROTO_ENTRIES.ordinal)) return false;
    // Add .forEach() method
    if (!register_string_proto_method(proto, heap, "forEach", Builtin.MAP_PROTO_FOREACH.ordinal)) return false;
    // Add .getOrInsert(key, value) method, ES2025 §24.1.3.9
    if (!register_string_proto_method(proto, heap, "getOrInsert", Builtin.MAP_PROTO_GETORINSERT.ordinal)) return false;
    // Add .getOrInsertComputed(key, callbackfn) method, ES2025 §24.1.3.10
    if (!register_string_proto_method(proto, heap, "getOrInsertComputed", Builtin.MAP_PROTO_GETORINSERTCOMPUTED.ordinal)) return false;
    // Map.prototype[Symbol.iterator] must be the *same function object* as
    // .entries (ES6 §23.1.3.10), not merely an equivalent implementation.
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        HString* entries_key = builtin_intern_string(heap, "entries");
        if (iter_sym != null && entries_key != null) {
            PropValue*? entries_prop_opt = proto.find_prop(entries_key, heap);
            if (try entries_prop = entries_prop_opt) {
                proto.put_prop(iter_sym, *entries_prop, hobject::PROP_FLAGS_WC, heap);
            }
        }
    }
    
    // Set @@toStringTag on Map.prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Map"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC, heap);
    }

    // Register .size as a getter accessor property (ES6 §23.1.3.10)
    {
        HString* size_key = builtin_intern_string(heap, "size");
        if (size_key != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.MAP_PROTO_SIZE_GET.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            // Set .name = "get size"
            char[] fn_name = "get size";
            HString* name_str = builtin_intern_string(heap, fn_name);
            if (name_str != null) {
                TVal name_tv;
                name_tv.set_string(name_str);
                HString* name_key = heap.str(heap::BuiltinStr.NAME);
                fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC, heap);
            }
            HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            if (length_key != null) {
                TVal len_tv;
                len_tv.set_fastint(0);
                fn_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC, heap);
            }
            TVal getter_tv;
            getter_tv.set_object(fn_obj);
            TVal undef;
            undef.set_undefined();
            hobject::PropFlags acc_flags;
            acc_flags.writable = false;
            acc_flags.enumerable = false;
            acc_flags.configurable = true;
            acc_flags.is_accessor = true;
            proto.put_prop(size_key, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags, heap);
        }
    }

    // Create Map constructor as a proper function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.MAP.ordinal;

    // Set .constructor on Map.prototype
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    // Set Map.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    // Set Map.length
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC, heap);

    // Map[Symbol.species] accessor, ES6 §23.1.2.2: getter returns `this`.
    {
        HString* species_sym = ensure_species_symbol(heap);
        if (species_sym != null) {
            HObject*? getter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (try getter = getter_raw) {
                getter.flags.callable = true;
                getter.flags.constructable = false;
                getter.prototype = heap.function_proto;
                (*getter.extra_ptr()).func.builtin_fn_index = (int)Builtin.MAP_SPECIES_GETTER.ordinal;
                HString* getter_name_key = heap.str(heap::BuiltinStr.NAME);
                HString* getter_name_str = builtin_intern_string(heap, "get [Symbol.species]");
                if (getter_name_key != null && getter_name_str != null) {
                    TVal gn_tv; gn_tv.set_string(getter_name_str);
                    getter.put_prop(getter_name_key, gn_tv, hobject::PROP_FLAGS_NWC, heap);
                }
                HString* getter_len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                if (getter_len_key != null) {
                    TVal gl_tv; gl_tv.set_fastint(0);
                    getter.put_prop(getter_len_key, gl_tv, hobject::PROP_FLAGS_NWC, heap);
                }
                TVal getter_tv; getter_tv.set_object(getter);
                TVal undef_tv; undef_tv.set_undefined();
                PropFlags acc_flags;
                acc_flags.writable = false;
                acc_flags.enumerable = false;
                acc_flags.configurable = true;
                acc_flags.is_accessor = true;
                ctor.put_prop(species_sym, hobject::hobject_create_accessors(heap, getter_tv, undef_tv), acc_flags, heap);
            }
        }
    }

    // Map.groupBy, ES2024 §24.1.2.1
    HString* groupby_key = builtin_intern_string(heap, "groupBy");
    if (groupby_key == null) return false;
    TVal groupby_tv;
    groupby_tv.set_lightfunc((void*)(usz)Builtin.MAP_GROUPBY.ordinal);
    ctor.put_prop(groupby_key, groupby_tv, hobject::PROP_FLAGS_WC, heap);

    // Map.prototype's [[Prototype]] is set later (to Object.prototype)

    // Register Map constructor globally
    HString* map_key = heap.str_intern("Map");
    if (map_key == null) return false;
    TVal map_val;
    map_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, "Map");
    env::env_declare_nonenum(global_env, map_key, map_val);

    return true;
}
