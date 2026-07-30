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

/// Membership count above which the seen set switches from a linear array
/// scan to an open-addressed hash index.  Below it the array is a couple of
/// cache lines of pointers and scanning beats hashing.
const uint FORIN_SEEN_HASH_THRESHOLD = 12;

/// Slot count of the index built at promotion.  MUST be a power of two —
/// ForInSeen probes with `& index_mask` and relies on the walk visiting every
/// slot, so a non-power-of-two mask makes a miss loop forever.  Sized to keep
/// the load factor at or below 1/2 at the promotion threshold.
const uint FORIN_SEEN_INDEX_CAP = 64;

/// Chain levels probed lazily for shadowing before falling back to eager
/// recording.  Sized to cover any realistic prototype chain while keeping
/// ForInSeen small enough to live on the stack.
const uint FORIN_NEARER_MAX = 16;

/// De-duplication state for for-in enumeration.
///
/// `entries` is the set of keys already yielded, keyed on interned-HString
/// pointer identity (string equality is pointer identity engine-wide).  Two
/// representations behind one interface: while `count` stays at or below
/// FORIN_SEEN_HASH_THRESHOLD, `entries` is scanned linearly; past that, a
/// power-of-two open-addressing table of indices into `entries` is built and
/// kept in sync, making membership O(1) instead of quadratic in the number of
/// keys the chain yields.
///
/// `nearer` holds the ordinary (non-proxy) chain levels already walked, so a
/// key about to be yielded from a farther level can be tested for an own
/// property — enumerable or not — on a nearer one.  ES
/// EnumerateObjectProperties records EVERY own key it visits as already-seen,
/// so a non-enumerable own property shadows a same-named enumerable prototype
/// property (plan 062 group F).  Probing lazily via find_prop_idx keeps that
/// rule off the hot path: eagerly recording every non-enumerable own key
/// instead costs O(own props in the whole chain) per enumeration, and
/// prototypes are almost entirely non-enumerable methods that are never
/// yielded.  Chains longer than FORIN_NEARER_MAX fall back to that eager
/// recording for the overflowing levels (see forin_record_non_enumerable).
struct ForInSeen {
    HString** entries;   /// Dense insertion-ordered list of yielded keys; null until the first insert
    uint count;
    uint cap;
    uint* index;         /// Open-addressing table: slot -> entries[] index + 1, 0 = empty
    uint index_mask;     /// index_cap - 1; index_cap is a power of two, 0 when unbuilt
    HObject*[FORIN_NEARER_MAX] nearer;
    uint nearer_count;
}

/// Grow an HString** array if needed, allocating it on first use when `*arr`
/// is still null.
fn bool forin_ensure_cap(Heap* h, HString*** arr, uint* cap, uint need) {
    if (*arr == null) {
        HString** new_arr = (HString**)h.alloc_func(h.heap_udata, *cap * HString*::size);
        if (new_arr == null) return false;
        *arr = new_arr;
    }
    if (need >= *cap) {
        uint new_cap = *cap * 2;
        HString** new_arr = (HString**)h.realloc_func(h.heap_udata, *arr, new_cap * HString*::size);
        if (new_arr == null) return false;
        *arr = new_arr;
        *cap = new_cap;
    }
    return true;
}

/// Probe start for `key`. The interned string's precomputed content hash is
/// already well mixed, so it is used directly rather than hashing the pointer.
macro uint forin_seen_slot(ForInSeen* s, HString* key) => key.hash & s.index_mask;

/// (Re)build the open-addressing index at `index_cap` slots, which MUST be a
/// power of two.  Callers keep the load factor at or below 1/2 so a probe
/// always terminates on an empty slot.  Returns false only on allocation
/// failure, in which case the set stays valid and simply keeps scanning
/// linearly.
fn bool ForInSeen.reindex(&self, Heap* h, uint index_cap) @local {
    uint* tbl = (uint*)h.alloc_func(h.heap_udata, (usz)index_cap * uint::size);
    if (tbl == null) return false;
    for (uint i = 0; i < index_cap; i++) tbl[i] = 0;
    if (self.index != null) h.free_func(h.heap_udata, self.index);
    self.index = tbl;
    self.index_mask = index_cap - 1;
    for (uint i = 0; i < self.count; i++) {
        uint slot = forin_seen_slot(self, self.entries[i]);
        while (tbl[slot] != 0) slot = (slot + 1) & self.index_mask;
        tbl[slot] = i + 1;
    }
    return true;
}

fn bool ForInSeen.contains(&self, HString* key) @local {
    if (self.index == null) {
        for (uint i = 0; i < self.count; i++) {
            if (self.entries[i] == key) return true;
        }
        return false;
    }
    uint slot = forin_seen_slot(self, key);
    while (self.index[slot] != 0) {
        if (self.entries[self.index[slot] - 1] == key) return true;
        slot = (slot + 1) & self.index_mask;
    }
    return false;
}

/// Append a known-absent key.  Callers must have checked `contains` first.
fn bool ForInSeen.append(&self, Heap* h, HString* key) @local {
    if (!forin_ensure_cap(h, &self.entries, &self.cap, self.count + 1)) return false;
    self.entries[self.count] = key;
    self.count++;
    if (self.index == null) {
        // Switch to hashing once linear scanning stops paying off.
        if (self.count > FORIN_SEEN_HASH_THRESHOLD) {
            self.reindex(h, FORIN_SEEN_INDEX_CAP);
        }
        return true;
    }
    if (self.count * 2 > self.index_mask + 1) {
        return self.reindex(h, (self.index_mask + 1) * 2);
    }
    uint slot = forin_seen_slot(self, key);
    while (self.index[slot] != 0) slot = (slot + 1) & self.index_mask;
    self.index[slot] = self.count;   // entries index + 1
    return true;
}

/// Record `level` as walked so keys yielded from farther levels can be probed
/// against its own properties.  Returns false when the list is full, in which
/// case the caller must record the level's non-enumerable keys eagerly.
fn bool ForInSeen.push_level(&self, HObject* level) @local {
    if (self.nearer_count >= FORIN_NEARER_MAX) return false;
    self.nearer[self.nearer_count] = level;
    self.nearer_count++;
    return true;
}

/// True iff `key` is an own named property of an already-walked level.
///
/// Symbols are exempt: they are yielded by their own phase and never
/// participate in shadowing.  A String object's own `length` is NOT exempt —
/// it is non-enumerable, so EnumerateObjectProperties still records it as
/// visited and it suppresses a same-named enumerable property inherited from
/// the prototype chain.
fn bool ForInSeen.shadowed(&self, Heap* h, HString* key) @local {
    if (key.is_symbol()) return false;
    for (uint i = 0; i < self.nearer_count; i++) {
        HObject* lvl = self.nearer[i];
        if (lvl.find_prop_idx((void*)key) < 0) continue;
        return true;
    }
    return false;
}

fn void ForInSeen.free(&self, Heap* h) @local {
    if (self.entries != null) h.free_func(h.heap_udata, self.entries);
    if (self.index != null) h.free_func(h.heap_udata, self.index);
}

/// Eager fallback for chain levels beyond FORIN_NEARER_MAX: copy `level`'s own
/// non-enumerable string keys straight into the seen set, giving the same
/// shadowing effect as a lazy `shadowed` probe would.  The `is_symbol`
/// exemption mirrors `shadowed`.
fn bool forin_record_non_enumerable(Heap* h, ForInSeen* seen, HObject* level) {
    for (uint i = 0; i < level.prop_count; i++) {
        void* pk = level.prop_key_at(i);
        if (pk == null) continue;
        if (level.get_prop_flags(i).enumerable) continue;
        HString* k = (HString*)pk;
        if (k.is_symbol()) continue;
        if (seen.contains(k)) continue;
        if (!seen.append(h, k)) return false;
    }
    return true;
}

/// Yield `key` unless a nearer chain level already produced or shadowed it.
///
/// `keys` and `seen.entries` grow in lockstep (every yield appends to both)
/// but MUST use separate capacity trackers: forin_ensure_cap mutates *cap in
/// place when it grows, so reusing one `cap` for both calls made the second
/// call's growth check see the already-doubled capacity and wrongly skip
/// reallocating the seen array, leaving it permanently undersized relative to
/// `keys` — a heap buffer overflow on every subsequent write once it fell
/// behind.
///
/// `track` is false on the final chain level: nothing above is left to
/// shadow, so the key is yielded without paying for the insert.
fn bool forin_add_key(Heap* h, HString*** keys, uint* count, uint* keys_cap,
                      ForInSeen* seen, bool track, HString* key) {
    if (seen.count != 0 && seen.contains(key)) return true;
    if (seen.nearer_count != 0 && seen.shadowed(h, key)) return true;
    if (!forin_ensure_cap(h, keys, keys_cap, *count + 1)) return false;
    if (track && !seen.append(h, key)) return false;
    (*keys)[*count] = key;
    (*count)++;
    return true;
}

/// Record `key` as seen without yielding it.
///
/// Ordinary chain levels get this rule for free from the lazy `shadowed`
/// probe, which reads their own properties directly. A proxy's keys are
/// virtual — they exist only as trap results — so a non-enumerable own key of
/// a proxy has to be inserted here to suppress a same-named enumerable key
/// further up the chain (EnumerateObjectProperties).
fn bool forin_mark_seen(Heap* h, ForInSeen* seen, HString* key) {
    if (seen.count != 0 && seen.contains(key)) return true;
    return seen.append(h, key);
}

/// Returns true iff `key` still resolves to a property on `target` (own or
/// inherited) at the moment of the call.  Used by NEXTFOR to honour the
/// EnumerateObjectProperties liveness rule (plan 062 group N): a property
/// deleted from the target before its turn is skipped, never yielded as
/// undefined.  This is a re-check — the snapshot is fixed at INITFOR time.
///
/// Exotic-keyed targets get a dedicated branch because their integer-indexed
/// properties are served by the exotic handler, not via the named-prop table
/// or dense part that `has_prop_proto` consults.  Proxies bypass the check
/// entirely — their keys are virtual (added/removed via traps) and re-
/// invoking [[HasProperty]] could yield inconsistent results, matching
/// Duktape's `check_existence = !IS_PROXY(enum_target)` bypass.
fn bool forin_key_still_exists(HObject* target, HString* key) {
    if (target == null || key == null) return false;
    if (target.flags.exotic_proxyobj) return true;
    if (target.has_prop_proto((void*)key)) return true;

    // TypedArray exotic: integer-indexed elements are accessible via the
    // exotic [[Get]] handler, not find_prop_idx / dense_arridx_lookup.  An
    // index is live as long as the buffer is not detached and the index is
    // within [[ArrayLength]] (mirrors IsValidIntegerIndex, ES2022 §10.4.5.9).
    if (builtins::is_typed_array_class(target.get_class())) {
        if (key.is_arridx()) {
            return (uint)key.array_index() < builtins::ta_element_count(target);
        }
        return false;
    }

    // String exotic: indexed character properties (0..char_length-1) live
    // only in the primitive string's content, not in the wrapper's props.
    // Strings are immutable so this can't be deleted mid-iteration, but a
    // caller asking for a non-arridx key that has_prop_proto already
    // rejected is correctly reported as absent.
    if (target.flags.exotic_stringobj && (*target.extra_ptr()).prim.primitive_value.is_string()) {
        if (key.is_arridx()) {
            HString* prim = (HString*)(*target.extra_ptr()).prim.primitive_value.get_heapptr();
            return prim != null && (uint)key.array_index() < prim.char_length();
        }
    }

    return false;
}

/// Collect all enumerable property keys from an object and its prototype
/// chain, de-duplicated (own keys shadow prototype keys).
///
/// Returns a malloc'd ForInState, or null if allocation fails.
/// The caller (NEXTFOR) is responsible for freeing via `heap.free_func`.
fn ForInState* collect_forin_keys(Vm* vm, HObject* obj) {

    uint keys_cap = FORIN_INITIAL_CAP;
    Heap* h = vm.heap;
    HString** keys = (HString**)h.alloc_func(h.heap_udata, keys_cap * HString*::size);
    if (keys == null) return null;
    uint count = 0;

    // `entries` is allocated on the first insert: a single-level enumeration,
    // or one whose keys all come from the last level, never needs it.
    ForInSeen seen = { .cap = FORIN_INITIAL_CAP };

    HObject* cur = obj;
    uint depth = 0;
    while (cur != null && depth < hobject::MAX_PROTO_DEPTH) {
        // Shadowing bookkeeping only matters while another chain level can
        // still be reached: on the final level nothing above is left to
        // suppress, so the seen-set inserts and the walked-level record are
        // pure overhead and are skipped.  A proxy's prototype comes from a
        // trap that has not run yet at this point, so proxy levels
        // conservatively keep tracking.
        bool track = cur.flags.exotic_proxyobj || cur.prototype != null;

        // Proxy exotic: enumerable string keys via [[OwnPropertyKeys]] +
        // [[GetOwnProperty]]; continue the walk through [[GetPrototypeOf]].
        if (cur.flags.exotic_proxyobj) {
            HString** pkeys;
            uint pn;
            uint ptotal;
            if (!builtins::proxy_partitioned_own_keys(vm, h, cur, 0, &pkeys, &pn, &ptotal)) {
                // Trap threw: surface as an empty enumeration; the pending
                // heap error is rethrown by the FORIN opcode handler.
                h.free_func(h.heap_udata, keys);
                seen.free(h);
                return null;
            }
            // [0, pn) are enumerable and get yielded; [pn, ptotal) are the
            // non-enumerable own keys, marked seen only so they shadow a
            // same-named enumerable prototype key (EnumerateObjectProperties).
            // A proxy's keys are virtual, so the lazy find_prop_idx probe used
            // for ordinary levels cannot see them — they must be recorded here.
            for (uint i = 0; i < ptotal; i++) {
                bool ok = i < pn
                    ? forin_add_key(h, &keys, &count, &keys_cap, &seen, track, pkeys[i])
                    : forin_mark_seen(h, &seen, pkeys[i]);
                if (!ok) {
                    h.free_func(h.heap_udata, pkeys);
                    h.free_func(h.heap_udata, keys);
                    seen.free(h);
                    return null;
                }
            }
            h.free_func(h.heap_udata, pkeys);
            TVal pproto;
            if (!builtins::proxy_mop_get_proto(vm, h, cur, &pproto)) {
                h.free_func(h.heap_udata, keys);
                seen.free(h);
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
                    seen.free(h);
                    return null;
                }
                if (!nd.found || !nd.enumerable) continue;
                if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, track, ks)) {
                    h.free_func(h.heap_udata, keys);
                    seen.free(h);
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
                    if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, track, k)) {
                        h.free_func(h.heap_udata, keys);
                        seen.free(h);
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
                    if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, track, k)) {
                        h.free_func(h.heap_udata, keys);
                        seen.free(h);
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
                if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, track, k)) {
                    h.free_func(h.heap_udata, keys);
                    seen.free(h);
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
                        if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, track, k)) {
                            h.free_func(h.heap_udata, sbuf);
                            h.free_func(h.heap_udata, keys);
                            seen.free(h);
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
                if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, track, k)) {
                    h.free_func(h.heap_udata, keys);
                    seen.free(h);
                    return null;
                }
            }
        }
        // Symbol-keyed properties are deliberately never yielded:
        // EnumerateObjectProperties (§14.7.5.9) yields only keys of type
        // String. Symbols also need no place in `seen` — a symbol key can
        // never be pointer-equal to a string key, so it can neither shadow
        // nor be shadowed by one.

        if (track && !seen.push_level(cur) && !forin_record_non_enumerable(h, &seen, cur)) {
            h.free_func(h.heap_udata, keys);
            seen.free(h);
            return null;
        }
        cur = cur.prototype;
        depth++;
    }

    seen.free(h);

    ForInState* state = (ForInState*)h.alloc_func(h.heap_udata, ForInState::size);
    if (state == null) { h.free_func(h.heap_udata, keys); return null; }
    state.keys = keys;
    state.target = obj;
    state.count = count;
    state.index = 0;
    return state;
}

