module boomkat::heap;

import boomkat::types;
import boomkat::hobject;
import boomkat::hstring;
import std::collections::map;

// Weak handles: references to an object or symbol that do not keep it alive.
//
// One entry per target, shared by every handle to it and counted in `handles`.
// The entry forgets its target when the target dies: at the switch to sweep for
// an object the cycle found unreachable, or in the free path for an object or
// symbol released another way. The target carries a `weak_target` bit so the
// free paths test one flag and only weak targets reach the index.
struct WeakEntry {
    HeapHeader* target;     // null once the target died or the entry is free
    uint        gen;        // bumped on reuse, so a stale handle reads as collected
    uint        handles;
    uint        next_free;
}

const uint WEAK_NONE = 0xFFFF_FFFF;

fn bool weak_flag(HeapHeader* h) @inline {
    return h.flags.htype == HType.STRING ? ((HString*)h).flags.weak_target : h.gc.weak_target;
}

fn void set_weak_flag(HeapHeader* h, bool on) @inline {
    if (h.flags.htype == HType.STRING) {
        ((HString*)h).flags.weak_target = on;
    } else {
        h.gc.weak_target = on;
    }
}

// A handle to `target`: the entry index plus one in the low word, its
// generation in the high word. Zero when memory is exhausted.
fn ulong Heap.weak_new(&self, HeapHeader* target) {
    if (!self.weak_index.is_initialized()) self.weak_index.init(mem);
    if (weak_flag(target)) {
        if (try index = self.weak_index.get((usz)target)) {
            self.weak_entries[index].handles++;
            return ((ulong)self.weak_entries[index].gen << 32) | ((ulong)index + 1);
        }
    }
    uint index = self.weak_free;
    if (index != WEAK_NONE) {
        self.weak_free = self.weak_entries[index].next_free;
    } else {
        if (self.weak_count == 0xFFFF_FFFE) return 0;
        if (self.weak_count >= self.weak_capacity) {
            uint new_cap = self.weak_capacity == 0 ? 16 : self.weak_capacity * 2;
            void* grown = self.realloc_func(self.heap_udata, (void*)self.weak_entries, (usz)new_cap * WeakEntry::size);
            if (grown == null) return 0;
            self.weak_entries = (WeakEntry*)grown;
            self.weak_capacity = new_cap;
        }
        index = self.weak_count++;
        self.weak_entries[index].gen = 0;
    }
    WeakEntry* e = &self.weak_entries[index];
    e.gen++;
    e.target = target;
    e.handles = 1;
    e.next_free = WEAK_NONE;
    self.weak_index.set((usz)target, index);
    set_weak_flag(target, true);
    return ((ulong)e.gen << 32) | ((ulong)index + 1);
}

// The live entry behind a handle, or null for a handle that was freed or never
// issued.
fn WeakEntry* Heap.weak_entry(&self, ulong weak) {
    ulong low = weak & 0xFFFF_FFFF;
    if (low == 0 || low > self.weak_count) return null;
    WeakEntry* e = &self.weak_entries[low - 1];
    if (e.handles == 0 || e.gen != (uint)(weak >> 32)) return null;
    return e;
}

// The target, or null once it died.
fn HeapHeader* Heap.weak_get(&self, ulong weak) {
    WeakEntry* e = self.weak_entry(weak);
    return e == null ? null : e.target;
}

fn void Heap.weak_free_handle(&self, ulong weak) {
    WeakEntry* e = self.weak_entry(weak);
    if (e == null || --e.handles > 0) return;
    if (e.target != null) {
        set_weak_flag(e.target, false);
        self.weak_index.remove((usz)e.target);
        e.target = null;
    }
    uint index = (uint)((weak & 0xFFFF_FFFF) - 1);
    e.next_free = self.weak_free;
    self.weak_free = index;
}

// Forget a dying target. Called from the free paths of flagged nodes.
fn void Heap.weak_target_died(&self, HeapHeader* target) {
    set_weak_flag(target, false);
    if (!self.weak_index.is_initialized()) return;
    if (try index = self.weak_index.get((usz)target)) {
        self.weak_entries[index].target = null;
        self.weak_index.remove((usz)target);
    }
}

// At the switch to sweep, every object the cycle is about to free is exactly
// the unreachable ones of the swept generations. Forgetting them here, before
// the sweep starts, means a weak read during the sweep cannot hand out an
// object that is about to be freed.
fn void Heap.weak_condemn(&self) {
    for (uint i = 0; i < self.weak_count; i++) {
        WeakEntry* e = &self.weak_entries[i];
        HeapHeader* t = e.target;
        if (t == null || t.flags.htype == HType.STRING) continue;
        if (t.is_reachable() || (t.gc.old && self.gc_kind != GcKind.MAJOR)) continue;
        self.weak_target_died(t);
    }
}

fn void Heap.weak_destroy(&self) {
    self.weak_index.free();
    self.weak_index = {};
    if (self.weak_entries != null) self.free_func(self.heap_udata, self.weak_entries);
    self.weak_entries = null;
    self.weak_count = 0;
    self.weak_capacity = 0;
    self.weak_free = WEAK_NONE;
}
