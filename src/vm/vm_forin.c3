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
/// `keys` and `seen` grow in lockstep (every add appends to both) but MUST use
/// separate capacity trackers: forin_ensure_cap mutates *cap in place when it
/// grows, so reusing one `cap` for both calls made the second call's growth
/// check see the already-doubled capacity and wrongly skip reallocating
/// `seen`, leaving it permanently undersized relative to `keys` — a heap
/// buffer overflow on every subsequent write once `seen` fell behind.
fn bool forin_add_key(Heap* h, HString*** keys, uint* count, uint* keys_cap,
                      HString*** seen, uint* seen_cnt, uint* seen_cap,
                      HString* key) {
    for (uint j = 0; j < *seen_cnt; j++) {
        if ((*seen)[j] == key) return true;
    }
    if (!forin_ensure_cap(h, keys, keys_cap, *count + 1)) return false;
    if (!forin_ensure_cap(h, seen, seen_cap, *seen_cnt + 1)) return false;
    (*keys)[*count] = key;
    (*count)++;
    (*seen)[*seen_cnt] = key;
    (*seen_cnt)++;
    return true;
}

/// Mark a key in the seen set without adding it to the yielded-keys list.
///
/// Used by the for-in own-property pre-passes: ES spec EnumerateObjectProperties
/// records EVERY own property key it visits — including non-enumerable ones —
/// as already-seen, so a same-named enumerable property on a prototype further
/// up the chain is suppressed (plan 062 group F). Yielding is reserved for
/// keys that pass the enumerable filter, which the calling code applies after
/// this pre-pass.
fn bool forin_mark_seen(Heap* h, HString*** seen, uint* seen_cnt, uint* seen_cap,
                        HString* key) {
    for (uint j = 0; j < *seen_cnt; j++) {
        if ((*seen)[j] == key) return true;
    }
    if (!forin_ensure_cap(h, seen, seen_cap, *seen_cnt + 1)) return false;
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

    uint keys_cap = FORIN_INITIAL_CAP;
    uint seen_cap = FORIN_INITIAL_CAP;
    Heap* h = vm.heap;
    HString** keys = (HString**)h.alloc_func(h.heap_udata, keys_cap * HString*::size);
    if (keys == null) return null;
    uint count = 0;

    HString** seen = (HString**)h.alloc_func(h.heap_udata, seen_cap * HString*::size);
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
                if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, &seen_cnt, &seen_cap, pkeys[i])) {
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
        // Module Namespace Exotic: for-in (EnumerateObjectProperties, §14.7.5.9)
        // obtains own keys via [[OwnPropertyKeys]] and each key's attributes via
        // [[GetOwnProperty]], which reads the live binding and throws
        // ReferenceError for a TDZ export (§10.4.6.5 step 4). The namespace has a
        // null prototype, so it is always the sole object in the walk.
        if (cur.flags.exotic_module_ns) {
            for (uint i = 0; i < cur.prop_count; i++) {
                void* pk = cur.prop_key_at(i);
                if (pk == null) continue;
                HString* ks = (HString*)pk;
                if (ks.is_symbol()) continue;
                if (!cur.get_prop_flags(i).enumerable) continue;
                ProxyDesc nd;
                if (!builtins::module_ns_own_desc(vm, h, cur, ks, &nd)) {
                    // TDZ threw: abort enumeration; FORIN rethrows heap.has_error.
                    h.free_func(h.heap_udata, keys);
                    h.free_func(h.heap_udata, seen);
                    return null;
                }
                if (!nd.found || !nd.enumerable) continue;
                if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, &seen_cnt, &seen_cap, ks)) {
                    h.free_func(h.heap_udata, keys);
                    h.free_func(h.heap_udata, seen);
                    return null;
                }
            }
            cur = null;   // null prototype — walk ends here
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
                    if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, &seen_cnt, &seen_cap, k)) {
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
        if (builtins::is_typed_array_class(cur.get_class())) {
            HObject* ta_buf = (*cur.extra_ptr()).view.buffer;
            if (ta_buf != null && (*ta_buf.extra_ptr()).ab.data != null) {
                uint ta_count = builtins::ta_element_count(cur);
                for (uint i = 0; i < ta_count; i++) {
                    HString* k = vm.heap.int_to_hstring((long)i);
                    if (k == null) continue;
                    if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, &seen_cnt, &seen_cap, k)) {
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
                if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, &seen_cnt, &seen_cap, k)) {
                    h.free_func(h.heap_udata, keys);
                    h.free_func(h.heap_udata, seen);
                    return null;
                }
            }
        }

        // Own named properties — integer indices ascending, then strings in insertion order.
        // Phase 1: integer-indexed named properties (sorted by numeric index, enumerable only)
        //
        // Pre-pass: mark each OWN non-enumerable arridx named key as seen.
        // Per spec EnumerateObjectProperties, non-enumerable own keys are
        // still recorded as "already seen" so a same-named enumerable
        // prototype key on the next loop level is suppressed (plan 062
        // group F). Enumerable own indexes are NOT pre-marked here: they
        // are added to both `seen` and `keys` by the yield step below via
        // `forin_add_key`, and pre-marking would make that step
        // early-return without yielding them.
        {
            for (uint i = 0; i < cur.prop_count; i++) {
                if (cur.prop_key_at(i) == null) continue;
                if (cur.get_prop_flags(i).enumerable) continue;
                HString* k = (HString*)cur.prop_key_at(i);
                if (!k.is_arridx()) continue;
                if (!forin_mark_seen(h, &seen, &seen_cnt, &seen_cap, k)) {
                    h.free_func(h.heap_udata, keys);
                    h.free_func(h.heap_udata, seen);
                    return null;
                }
            }
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
                        if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, &seen_cnt, &seen_cap, k)) {
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
        //
        // Pre-pass: mark each OWN non-enumerable non-arridx non-symbol
        // string key as seen. Same EnumerateObjectProperties rule as
        // Phase 1 (plan 062 group F); the yield loop below handles the
        // enumerable ones through `forin_add_key`, which also inserts
        // into seen, so we skip pre-marking those to avoid the
        // early-return swallowing them.
        for (uint i = 0; i < cur.prop_count; i++) {
            if (cur.prop_key_at(i) == null) continue;
            if (cur.get_prop_flags(i).enumerable) continue;
            HString* k = (HString*)cur.prop_key_at(i);
            if (k.is_arridx()) continue;
            if (k.is_symbol()) continue;
            if (cur.flags.exotic_stringobj && (void*)k == vm.heap.strs[heap::BuiltinStr.LENGTH]) continue;
            if (!forin_mark_seen(h, &seen, &seen_cnt, &seen_cap, k)) {
                h.free_func(h.heap_udata, keys);
                h.free_func(h.heap_udata, seen);
                return null;
            }
        }
        for (uint i = 0; i < cur.prop_count; i++) {
            if (cur.get_prop_flags(i).enumerable && cur.prop_key_at(i) != null) {
                HString* k = (HString*)cur.prop_key_at(i);
                if (k.is_arridx()) continue;
                if (k.is_symbol()) continue;
                if (cur.flags.exotic_stringobj && (void*)k == vm.heap.strs[heap::BuiltinStr.LENGTH]) continue;
                if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, &seen_cnt, &seen_cap, k)) {
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
                if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, &seen_cnt, &seen_cap, k)) {
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

