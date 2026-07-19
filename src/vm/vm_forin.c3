module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::re_bindings;
import std::io;
import std::math;

const uint FORIN_INITIAL_CAP = 64;

/// Grow an HString** array if needed.
fn bool forin_ensure_cap(Heap* h, HString*** arr, uint* cap, uint need) {
    if (need >= *cap) {
        uint new_cap = *cap * 2;
        HString** new_arr = (HString**)h.realloc_func(h.heap_udata, *arr, new_cap * HString*::size);
        if (new_arr == null) return false;
        *arr = new_arr;
        *cap = new_cap;
    }
    return true;
}

/// Add a key if not already in the seen set (pointer compare for interned strings).
fn bool forin_add_key(Heap* h, HString*** keys, uint* count,
                      HString*** seen, uint* seen_cnt, uint* cap,
                      HString* key) {
    for (uint j = 0; j < *seen_cnt; j++) {
        if ((*seen)[j] == key) return true;
    }
    if (!forin_ensure_cap(h, keys, cap, *count + 1)) return false;
    if (!forin_ensure_cap(h, seen, cap, *seen_cnt + 1)) return false;
    (*keys)[*count] = key;
    (*count)++;
    (*seen)[*seen_cnt] = key;
    (*seen_cnt)++;
    return true;
}

/// Collect all enumerable property keys from an object and its prototype
/// chain, de-duplicated (own keys shadow prototype keys).
///
/// Returns a malloc'd ForInState, or null if allocation fails.
/// The caller (NEXTFOR) is responsible for freeing via `heap.free_func`.
fn ForInState* collect_forin_keys(Vm* vm, HObject* obj) {

    uint cap = FORIN_INITIAL_CAP;
    Heap* h = vm.heap;
    HString** keys = (HString**)h.alloc_func(h.heap_udata, cap * HString*::size);
    if (keys == null) return null;
    uint count = 0;

    HString** seen = (HString**)h.alloc_func(h.heap_udata, cap * HString*::size);
    if (seen == null) { h.free_func(h.heap_udata, keys); return null; }
    uint seen_cnt = 0;

    HObject* cur = obj;
    uint depth = 0;
    while (cur != null && depth < hobject::MAX_PROTO_DEPTH) {
        // Proxy exotic: enumerable string keys via [[OwnPropertyKeys]] +
        // [[GetOwnProperty]]; continue the walk through [[GetPrototypeOf]].
        if (cur.flags.exotic_proxyobj) {
            HString** pkeys;
            uint pn;
            if (!builtins::proxy_filtered_own_keys(vm, h, cur, 0, &pkeys, &pn)) {
                // Trap threw: surface as an empty enumeration; the pending
                // heap error is rethrown by the FORIN opcode handler.
                h.free_func(h.heap_udata, keys);
                h.free_func(h.heap_udata, seen);
                return null;
            }
            for (uint i = 0; i < pn; i++) {
                if (!forin_add_key(h, &keys, &count, &seen, &seen_cnt, &cap, pkeys[i])) {
                    h.free_func(h.heap_udata, pkeys);
                    h.free_func(h.heap_udata, keys);
                    h.free_func(h.heap_udata, seen);
                    return null;
                }
            }
            h.free_func(h.heap_udata, pkeys);
            TVal pproto;
            if (!builtins::proxy_mop_get_proto(vm, h, cur, &pproto)) {
                h.free_func(h.heap_udata, keys);
                h.free_func(h.heap_udata, seen);
                return null;
            }
            cur = pproto.is_object() ? (HObject*)pproto.get_heapptr() : null;
            depth++;
            continue;
        }
        // STRING exotic: enumerate integer indices [0, clen) from the primitive value
        // before the named property list so index order matches the spec.
        if (cur.flags.exotic_stringobj && (*cur.extra_ptr()).prim.primitive_value.is_string()) {
            HString* prim = (HString*)(*cur.extra_ptr()).prim.primitive_value.get_heapptr();
            if (prim != null) {
                for (uint i = 0; i < prim.char_length(); i++) {
                    HString* k = vm.heap.int_to_hstring((long)i);
                    if (k == null) continue;
                    if (!forin_add_key(h, &keys, &count, &seen, &seen_cnt, &cap, k)) {
                        h.free_func(h.heap_udata, keys);
                        h.free_func(h.heap_udata, seen);
                        return null;
                    }
                }
            }
        }

        // TypedArray: enumerate integer indices [0, length) as own enumerable
        // keys before the named property list (mirrors the STRING exotic case
        // above). Detached buffers contribute no indices.
        if (cur.get_class() >= hobject::ObjClass.INT8ARRAY && cur.get_class() <= hobject::ObjClass.FLOAT64ARRAY) {
            HObject* ta_buf = (*cur.extra_ptr()).view.buffer;
            if (ta_buf != null && (*ta_buf.extra_ptr()).ab.data != null) {
                uint ta_shift = builtins::ta_elem_shift(cur.get_class());
                uint ta_count = (*cur.extra_ptr()).view.byte_length >> ta_shift;
                for (uint i = 0; i < ta_count; i++) {
                    HString* k = vm.heap.int_to_hstring((long)i);
                    if (k == null) continue;
                    if (!forin_add_key(h, &keys, &count, &seen, &seen_cnt, &cap, k)) {
                        h.free_func(h.heap_udata, keys);
                        h.free_func(h.heap_udata, seen);
                        return null;
                    }
                }
            }
        }

        // Own dense array part indices — integer keys from dense storage (before named props).
        for (uint i = 0; i < cur.array_size; i++) {
            if (!cur.array_part()[i].is_undefined()) {
                HString* k = vm.heap.int_to_hstring((long)i);
                if (k == null) continue;
                if (!forin_add_key(h, &keys, &count, &seen, &seen_cnt, &cap, k)) {
                    h.free_func(h.heap_udata, keys);
                    h.free_func(h.heap_udata, seen);
                    return null;
                }
            }
        }

        // Own named properties — integer indices ascending, then strings in insertion order.
        // Phase 1: integer-indexed named properties (sorted by numeric index, enumerable only)
        {
            uint int_count = 0;
            for (uint i = 0; i < cur.prop_count; i++) {
                if (cur.prop_key_at(i) != null && ((HString*)cur.prop_key_at(i)).is_arridx()
                    && cur.get_prop_flags(i).enumerable) {
                    int_count++;
                }
            }
            if (int_count > 0) {
                uint* sbuf = (uint*)h.alloc_func(h.heap_udata, (usz)(int_count * 2 * 4));
                if (sbuf != null) {
                    uint p = 0;
                    for (uint i = 0; i < cur.prop_count; i++) {
                        if (cur.prop_key_at(i) != null && cur.get_prop_flags(i).enumerable) {
                            HString* k = (HString*)cur.prop_key_at(i);
                            if (k.is_arridx()) {
                                sbuf[p * 2] = k.array_index();
                                sbuf[p * 2 + 1] = i;
                                p++;
                            }
                        }
                    }
                    // Insertion sort by arridx
                    for (uint i = 1; i < int_count; i++) {
                        uint t0 = sbuf[i * 2];
                        uint t1 = sbuf[i * 2 + 1];
                        uint j = i;
                        while (j > 0 && sbuf[(j - 1) * 2] > t0) {
                            sbuf[j * 2] = sbuf[(j - 1) * 2];
                            sbuf[j * 2 + 1] = sbuf[(j - 1) * 2 + 1];
                            j--;
                        }
                        sbuf[j * 2] = t0;
                        sbuf[j * 2 + 1] = t1;
                    }
                    for (uint i = 0; i < int_count; i++) {
                        uint si = sbuf[i * 2 + 1];
                        HString* k = (HString*)cur.prop_key_at(si);
                        if (!forin_add_key(h, &keys, &count, &seen, &seen_cnt, &cap, k)) {
                            h.free_func(h.heap_udata, sbuf);
                            h.free_func(h.heap_udata, keys);
                            h.free_func(h.heap_udata, seen);
                            return null;
                        }
                    }
                    h.free_func(h.heap_udata, sbuf);
                }
            }
        }
        // Phase 2: non-index string named properties (insertion order, enumerable only)
        for (uint i = 0; i < cur.prop_count; i++) {
            if (cur.get_prop_flags(i).enumerable && cur.prop_key_at(i) != null) {
                HString* k = (HString*)cur.prop_key_at(i);
                if (k.is_arridx()) continue;
                if (k.is_symbol()) continue;
                if (cur.flags.exotic_stringobj && (void*)k == vm.heap.strs[heap::BuiltinStr.LENGTH]) continue;
                if (!forin_add_key(h, &keys, &count, &seen, &seen_cnt, &cap, k)) {
                    h.free_func(h.heap_udata, keys);
                    h.free_func(h.heap_udata, seen);
                    return null;
                }
            }
        }
        // Phase 3: symbol-keyed properties (insertion order, enumerable only)
        for (uint i = 0; i < cur.prop_count; i++) {
            if (cur.get_prop_flags(i).enumerable && cur.prop_key_at(i) != null) {
                HString* k = (HString*)cur.prop_key_at(i);
                if (!k.is_symbol()) continue;
                if (k.is_hidden()) continue;
                if (!forin_add_key(h, &keys, &count, &seen, &seen_cnt, &cap, k)) {
                    h.free_func(h.heap_udata, keys);
                    h.free_func(h.heap_udata, seen);
                    return null;
                }
            }
        }

        cur = cur.prototype;
        depth++;
    }

    h.free_func(h.heap_udata, seen);

    ForInState* state = (ForInState*)h.alloc_func(h.heap_udata, ForInState::size);
    if (state == null) { h.free_func(h.heap_udata, keys); return null; }
    state.keys = keys;
    state.count = count;
    state.index = 0;
    return state;
}

