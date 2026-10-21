module boomkat::vm;

import boomkat::types;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::env;
import boomkat::builtins;
import boomkat::re_bindings;
import std::io;
import std::math;

const uint FORIN_INITIAL_CAP = 64;

// Membership count above which the seen set switches from a linear scan to
// a hash index.  Below it, scanning a few cache lines of pointers is faster.
const uint FORIN_SEEN_HASH_THRESHOLD = 12;

// Slot count of the index built at promotion, which must be a power of two, since
// ForInSeen probes with `& index_mask` and relies on the walk visiting every
// slot, so a non-power-of-two mask makes a miss loop forever.  Sized to keep
// the load factor at or below 1/2 at the promotion threshold.
const uint FORIN_SEEN_INDEX_CAP = 64;

// Chain levels probed lazily for shadowing before falling back to eager
// recording.  Sized to cover any realistic prototype chain while keeping
// ForInSeen small enough to live on the stack.
const uint FORIN_NEARER_MAX = 16;

// De-duplication state for for-in enumeration.
//
// `entries` holds the keys already yielded, compared by interned-HString
// pointer identity. It is scanned linearly up to FORIN_SEEN_HASH_THRESHOLD
// keys; past that, a power-of-two open-addressing index into `entries` is
// built and kept in sync.
//
// `nearer` holds the ordinary (non-proxy) chain levels already walked. A key
// from a farther level is shadowed if a nearer level has it as an own
// property, enumerable or not (ECMA-262 EnumerateObjectProperties). Probing
// lazily with find_prop_idx avoids recording every non-enumerable key, since
// prototypes are mostly non-enumerable methods that are never yielded. Levels
// beyond FORIN_NEARER_MAX are recorded eagerly (see forin_record_non_enumerable).
struct ForInSeen {
    StringRef* entries;   /// Dense insertion-ordered list of yielded keys; null until the first insert
    uint count;
    uint cap;
    uint* index;         /// Open-addressing table: slot -> entries[] index + 1, 0 = empty
    uint index_mask;     /// index_cap - 1; index_cap is a power of two, 0 when unbuilt
    HObject*[FORIN_NEARER_MAX] nearer;
    uint nearer_count;
}

// Grow an owned-key array if needed, allocating it on first use when `*arr`
// is still null.
fn bool forin_ensure_cap(Heap* h, StringRef** arr, uint* cap, uint need) {
    if (*arr == null) {
        StringRef* new_arr = (StringRef*)h.alloc_func(h.heap_udata, *cap * StringRef::size);
        if (new_arr == null) return false;
        *arr = new_arr;
    }
    if (need >= *cap) {
        uint new_cap = *cap * 2;
        StringRef* new_arr = (StringRef*)h.realloc_func(h.heap_udata, *arr, new_cap * StringRef::size);
        if (new_arr == null) return false;
        *arr = new_arr;
        *cap = new_cap;
    }
    return true;
}

// Probe start for `key`. The interned string's precomputed content hash is
// already well mixed, so it is used directly rather than hashing the pointer.
macro uint forin_seen_slot(ForInSeen* s, HString* key) => key.hash & s.index_mask;

// (Re)build the open-addressing index at `index_cap` slots, which MUST be a
// power of two.  Callers keep the load factor at or below 1/2 so a probe
// always terminates on an empty slot.  Returns false only on allocation
// failure, in which case the set stays valid and simply keeps scanning
// linearly.
fn bool ForInSeen.reindex(&self, Heap* h, uint index_cap) {
    uint* tbl = (uint*)h.alloc_func(h.heap_udata, (usz)index_cap * uint::size);
    if (tbl == null) return false;
    for (uint i = 0; i < index_cap; i++) tbl[i] = 0;
    if (self.index != null) h.free_func(h.heap_udata, self.index);
    self.index = tbl;
    self.index_mask = index_cap - 1;
    for (uint i = 0; i < self.count; i++) {
        uint slot = forin_seen_slot(self, self.entries[i].borrow());
        while (tbl[slot] != 0) slot = (slot + 1) & self.index_mask;
        tbl[slot] = i + 1;
    }
    return true;
}

fn bool ForInSeen.contains(&self, HString* key) {
    if (self.index == null) {
        for (uint i = 0; i < self.count; i++) {
            if (self.entries[i].borrow() == key) return true;
        }
        return false;
    }
    uint slot = forin_seen_slot(self, key);
    while (self.index[slot] != 0) {
        if (self.entries[self.index[slot] - 1].borrow() == key) return true;
        slot = (slot + 1) & self.index_mask;
    }
    return false;
}

// Append a key the caller has checked is absent.
fn bool ForInSeen.append(&self, Heap* h, HString* key) {
    if (!forin_ensure_cap(h, &self.entries, &self.cap, self.count + 1)) return false;
    self.entries[self.count] = hstring::string_ref(key);
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

// Record `level` as walked so keys yielded from farther levels can be probed
// against its own properties.  Returns false when the list is full, in which
// case the caller must record the level's non-enumerable keys eagerly.
fn bool ForInSeen.push_level(&self, HObject* level) {
    if (self.nearer_count >= FORIN_NEARER_MAX) return false;
    self.nearer[self.nearer_count] = level;
    self.nearer_count++;
    return true;
}

// True iff `lvl` is an exotic whose `length` is virtual (array / TypedArray):
// the property is an own non-enumerable member but lives outside the named
// property table, so find_prop_idx cannot see it.
fn bool forin_level_has_virtual_length(HObject* lvl) {
    return lvl.get_class() == hobject::ObjClass.ARRAY
        || builtins::is_typed_array_class(lvl.get_class());
}

// True iff `key` is an own named property of an already-walked level.
//
// Symbols are exempt: they are yielded by their own phase and never
// participate in shadowing. A String object's own `length` is not exempt:
// it is non-enumerable, so EnumerateObjectProperties still records it as
// visited and it suppresses a same-named enumerable property inherited from
// the prototype chain.
fn bool ForInSeen.shadowed(&self, Heap* h, HString* key) {
    if (key.is_symbol()) return false;
    for (uint i = 0; i < self.nearer_count; i++) {
        HObject* lvl = self.nearer[i];
        if (lvl.find_prop_idx((void*)key, h) < 0) {
            if (key.equals("length") && forin_level_has_virtual_length(lvl)) return true;
            continue;
        }
        return true;
    }
    return false;
}

fn void ForInSeen.free(&self, Heap* h) {
    hstring::free_string_refs(h, self.entries[:self.count]);
    if (self.index != null) h.free_func(h.heap_udata, self.index);
}

// Eager fallback for levels beyond FORIN_NEARER_MAX: copy `level`'s own
// non-enumerable string keys into the seen set, matching the lazy `shadowed`
// probe.
fn bool forin_record_non_enumerable(Heap* h, ForInSeen* seen, HObject* level) {
    for (uint i = 0; i < level.prop_count; i++) {
        void* pk = level.prop_key_at(i, h);
        if (pk == null) continue;
        if (level.get_prop_flags(i, h).enumerable) continue;
        HString* k = (HString*)pk;
        if (k.is_symbol()) continue;
        if (seen.contains(k)) continue;
        if (!seen.append(h, k)) return false;
    }
    // An array / TypedArray level's virtual `length` shadows a prototype
    // `length` here too, mirroring the lazy `shadowed` probe.
    if (forin_level_has_virtual_length(level)) {
        HString* len_k = h.str_intern("length");
        if (len_k != null && !seen.contains(len_k)) {
            if (!seen.append(h, len_k)) return false;
        }
    }
    return true;
}

// Yield `key` unless a nearer chain level already produced or shadowed it.
//
// `keys` and `seen.entries` grow in lockstep but must use separate capacity
// variables: forin_ensure_cap updates *cap in place, so sharing one would
// leave the seen array undersized.
//
// `track` is false on the final chain level: nothing above is left to
// shadow, so the key is yielded without the insert.
fn bool forin_add_key(Heap* h, StringRef** keys, uint* count, uint* keys_cap,
                      ForInSeen* seen, bool track, HString* key) {
    if (seen.count != 0 && seen.contains(key)) return true;
    if (seen.nearer_count != 0 && seen.shadowed(h, key)) return true;
    if (!forin_ensure_cap(h, keys, keys_cap, *count + 1)) return false;
    if (track && !seen.append(h, key)) return false;
    (*keys)[*count] = hstring::string_ref(key);
    (*count)++;
    return true;
}

// Record `key` as seen without yielding it.
//
// Ordinary levels are covered by the lazy `shadowed` probe. A proxy's keys
// exist only as trap results, so its non-enumerable keys must be inserted
// here to shadow same-named enumerable keys further up the chain.
fn bool forin_mark_seen(Heap* h, ForInSeen* seen, HString* key) {
    if (seen.count != 0 && seen.contains(key)) return true;
    return seen.append(h, key);
}

// Returns true iff `key` still resolves on `target` (own or inherited). NEXTFOR
// uses this so a property deleted before its turn is skipped, not yielded as
// undefined (plan 062 group N). The key snapshot itself is fixed at INITFOR.
//
// Exotic integer-indexed properties are not in the named-prop table or dense
// part that `has_prop_proto` checks, so they get their own branch. Proxies
// are skipped: their keys are virtual, and re-invoking [[HasProperty]] could
// give inconsistent results (as Duktape's `check_existence` bypass does).
fn bool forin_key_still_exists(HObject* target, HString* key, Heap* h) {
    if (target == null || key == null) return false;
    if (target.is_proxy()) return true;
    if (target.has_prop_proto((void*)key, h)) return true;

    // TypedArray: an index is live while its buffer is attached and the index
    // is below the element count (ECMA-262 IsValidIntegerIndex).
    if (builtins::is_typed_array_class(target.get_class())) {
        if (key.is_arridx()) {
            return (uint)key.array_index() < builtins::ta_element_count(target);
        }
        return false;
    }

    // String exotic: indices 0..char_length-1 live in the primitive string,
    // not the wrapper's props. Strings are immutable, so they cannot be
    // deleted mid-iteration.
    if (target.flags.exotic_stringobj && (*target.extra_ptr()).prim.primitive_value.is_string()) {
        if (key.is_arridx()) {
            HString* prim = (HString*)(*target.extra_ptr()).prim.primitive_value.get_heapptr();
            return prim != null && (uint)key.array_index() < prim.char_length();
        }
    }

    return false;
}

// Collect all enumerable property keys from an object and its prototype
// chain, de-duplicated (own keys shadow prototype keys).
//
// Returns a heap-allocated ForInState, or null on allocation failure or a
// thrown error. Freed by forin_state_free.
fn ForInState* collect_forin_keys(Vm* vm, HObject* obj) {

    uint keys_cap = FORIN_INITIAL_CAP;
    Heap* h = vm.heap;
    StringRef* keys = (StringRef*)h.alloc_func(h.heap_udata, keys_cap * StringRef::size);
    if (keys == null) return null;
    uint count = 0;

    // `entries` is allocated on the first insert: a single-level enumeration,
    // or one whose keys all come from the last level, never needs it.
    ForInSeen seen = { .cap = FORIN_INITIAL_CAP };

    HObject* cur = obj;
    uint depth = 0;
    while (cur != null && depth < hobject::MAX_PROTO_DEPTH) {
        // Shadowing bookkeeping is only needed while another level can be
        // reached. A proxy's prototype comes from a trap not yet run, so
        // proxy levels always track.
        bool track = cur.is_proxy() || cur.prototype != null;

        // Proxy exotic: enumerable string keys via [[OwnPropertyKeys]] +
        // [[GetOwnProperty]]; continue the walk through [[GetPrototypeOf]].
        if (cur.is_proxy()) {
            HString** pkeys;
            uint pn;
            uint ptotal;
            if (!builtins::proxy_partitioned_own_keys(vm, h, cur, 0, &pkeys, &pn, &ptotal)) {
                // Trap threw: surface as an empty enumeration; the pending
                // heap error is rethrown by the FORIN opcode handler.
                hstring::free_string_refs(h, keys[:count]);
                seen.free(h);
                return null;
            }
            // [0, pn) are enumerable and yielded; [pn, ptotal) are non-enumerable
            // and only marked seen, to shadow prototype keys.
            for (uint i = 0; i < ptotal; i++) {
                bool ok = i < pn
                    ? forin_add_key(h, &keys, &count, &keys_cap, &seen, track, pkeys[i])
                    : forin_mark_seen(h, &seen, pkeys[i]);
                if (!ok) {
                    h.free_func(h.heap_udata, pkeys);
                    hstring::free_string_refs(h, keys[:count]);
                    seen.free(h);
                    return null;
                }
            }
            h.free_func(h.heap_udata, pkeys);
            TVal pproto;
            if (!builtins::proxy_mop_get_proto(vm, h, cur, &pproto)) {
                hstring::free_string_refs(h, keys[:count]);
                seen.free(h);
                return null;
            }
            cur = pproto.is_object() ? (HObject*)pproto.get_heapptr() : null;
            depth++;
            continue;
        }
        // Module namespace exotic: [[GetOwnProperty]] reads the live binding, so
        // a TDZ export throws ReferenceError. The namespace has a null prototype,
        // so it is always the only object in the walk.
        if (cur.flags.exotic_module_ns) {
            for (uint i = 0; i < cur.prop_count; i++) {
                void* pk = cur.prop_key_at(i, vm.heap);
                if (pk == null) continue;
                HString* ks = (HString*)pk;
                if (ks.is_symbol()) continue;
                if (!cur.get_prop_flags(i, vm.heap).enumerable) continue;
                ProxyDesc nd;
                if (!builtins::module_ns_own_desc(vm, h, cur, ks, &nd)) {
                    // TDZ threw: abort enumeration; FORIN rethrows heap.has_error.
                    hstring::free_string_refs(h, keys[:count]);
                    seen.free(h);
                    return null;
                }
                if (!nd.found || !nd.enumerable) continue;
                if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, track, ks)) {
                    hstring::free_string_refs(h, keys[:count]);
                    seen.free(h);
                    return null;
                }
            }
            cur = null;   // a null prototype ends the walk
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
                        hstring::free_string_refs(h, keys[:count]);
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
                        hstring::free_string_refs(h, keys[:count]);
                        seen.free(h);
                        return null;
                    }
                }
            }
        }

        // Integer keys from the dense array part, which come before named props.
        for (uint i = 0; i < cur.array_size; i++) {
            if (cur.dense_idx_present(i)) {
                HString* k = vm.heap.int_to_hstring((long)i);
                if (k == null) continue;
                if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, track, k)) {
                    hstring::free_string_refs(h, keys[:count]);
                    seen.free(h);
                    return null;
                }
            }
        }

        // Own named properties: integer indices ascending, then strings in insertion order.
        // Phase 1: integer-indexed named properties (sorted by numeric index, enumerable only)
        {
            uint int_count = 0;
            for (uint i = 0; i < cur.prop_count; i++) {
                if (cur.prop_key_at(i, vm.heap) != null && ((HString*)cur.prop_key_at(i, vm.heap)).is_arridx()
                    && cur.get_prop_flags(i, vm.heap).enumerable) {
                    int_count++;
                }
            }
            if (int_count > 0) {
                uint* sbuf = (uint*)h.alloc_func(h.heap_udata, (usz)(int_count * 2 * 4));
                if (sbuf != null) {
                    uint p = 0;
                    for (uint i = 0; i < cur.prop_count; i++) {
                        if (cur.prop_key_at(i, vm.heap) != null && cur.get_prop_flags(i, vm.heap).enumerable) {
                            HString* k = (HString*)cur.prop_key_at(i, vm.heap);
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
                        HString* k = (HString*)cur.prop_key_at(si, vm.heap);
                        if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, track, k)) {
                            h.free_func(h.heap_udata, sbuf);
                            hstring::free_string_refs(h, keys[:count]);
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
            if (cur.get_prop_flags(i, vm.heap).enumerable && cur.prop_key_at(i, vm.heap) != null) {
                HString* k = (HString*)cur.prop_key_at(i, vm.heap);
                if (k.is_arridx()) continue;
                if (k.is_symbol()) continue;
                if (!forin_add_key(h, &keys, &count, &keys_cap, &seen, track, k)) {
                    hstring::free_string_refs(h, keys[:count]);
                    seen.free(h);
                    return null;
                }
            }
        }
        // Symbol keys are never yielded (ECMA-262 EnumerateObjectProperties yields
        // only String keys) and never enter `seen`: a symbol can neither shadow
        // nor be shadowed by a string key.

        if (track && !seen.push_level(cur) && !forin_record_non_enumerable(h, &seen, cur)) {
            hstring::free_string_refs(h, keys[:count]);
            seen.free(h);
            return null;
        }
        cur = cur.prototype;
        depth++;
    }

    seen.free(h);

    ForInState* state = (ForInState*)heap::alloc_scanned_checked(ForInState, h);
    if (state == null) { hstring::free_string_refs(h, keys[:count]); return null; }
    state.keys = keys;
    state.target = obj;
    state.count = count;
    state.index = 0;
    return state;
}

