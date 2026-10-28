module boomkat::heap;

import boomkat::types;
import boomkat::hobject;
import std::core::mem;

// Clients own the list and its live flag. Invalidation never unlinks a node:
// active native code may still hold the flag until the client retires it.
struct JitWriteDependency @feat(SLJIT) {
    HObject* owner;
    PropValue* slot; // null watches the owner's layout and prototype
    bool* live;
    JitWriteDependency* next_bucket;
    JitWriteDependency* next_client;
    uint root_index;
}

fn uint jit_dependency_bucket(void* key) @feat(SLJIT) @inline {
    return (uint)(((uptr)key >> 3) ^ ((uptr)key >> 11)) & 63u;
}

fn JitWriteDependency* Heap.jit_watch(&self, HObject* owner, PropValue* slot, bool* live) @feat(SLJIT) {
    // Native frames can hold pointers that were guarded before this watch.
    // Register only at a gateway with no generated frame active.
    if (!hobject::plain_property_object(owner) || live == null || self.tearing_down
        || self.jit_native_active != 0) return null;
    if (self.jit_write_buckets == null) {
        self.jit_write_buckets = self.alloc_func(self.heap_udata, 64 * void*::size);
        if (self.jit_write_buckets == null) return null;
        mem::clear(self.jit_write_buckets, 64 * void*::size);
    }
    JitWriteDependency* node = self.alloc_func(self.heap_udata, JitWriteDependency::size);
    if (node == null) return null;
    uint root = (uint)self.gc_roots.len();
    for (uint i = 0; i < (uint)self.gc_roots.len(); i++) {
        if (self.gc_roots[i] == null) { root = i; break; }
    }
    if (root == (uint)self.gc_roots.len()) {
        self.register_gc_root((HeapHeader*)owner);
    } else {
        self.gc_roots[root] = (void*)owner;
        self.shade_root_object(owner);
    }
    uint bucket = jit_dependency_bucket(slot != null ? (void*)slot : (void*)owner);
    *node = { .owner = owner, .slot = slot, .live = live, .root_index = root,
        .next_bucket = self.jit_write_buckets[bucket] };
    self.jit_write_buckets[bucket] = node;
    owner.gc.jit_observed = true;
    return node;
}

fn JitWriteDependency* Heap.jit_watch_slot(&self, HObject* owner, uint index, bool* live) @feat(SLJIT) {
    if (owner == null || index >= owner.prop_count) return null;
    return self.jit_watch(owner, &owner.prop_values()[index], live);
}

fn JitWriteDependency* Heap.jit_watch_layout(&self, HObject* owner, bool* live) @feat(SLJIT) {
    return self.jit_watch(owner, null, live);
}

fn void Heap.jit_unwatch(&self, JitWriteDependency* node) @feat(SLJIT) {
    if (node == null) return;
    uint bucket = jit_dependency_bucket(node.slot != null ? (void*)node.slot : (void*)node.owner);
    JitWriteDependency** link = &self.jit_write_buckets[bucket];
    while (*link != null && *link != node) link = &(*link).next_bucket;
    if (*link == null) return;
    *link = node.next_bucket;
    if (node.root_index < (uint)self.gc_roots.len()) self.gc_roots[node.root_index] = null;
    if (!self.tearing_down) {
        bool still_observed = false;
        for (uint i = 0; i < 64 && !still_observed; i++) {
            for (JitWriteDependency* p = self.jit_write_buckets[i]; p != null; p = p.next_bucket) {
                if (p.owner == node.owner) { still_observed = true; break; }
            }
        }
        if (!still_observed) node.owner.gc.jit_observed = false;
    }
    self.free_func(self.heap_udata, node);
}

fn void Heap.jit_notify_write(&self, HObject* owner, PropValue* slot) @feat(SLJIT) @inline {
    if (owner == null || !owner.gc.jit_observed) return;
    self.jit_invalidate_slot(owner, slot);
}

fn void Heap.jit_invalidate_slot(&self, HObject* owner, PropValue* slot) @feat(SLJIT) @noinline {
    uint bucket = jit_dependency_bucket(slot);
    for (JitWriteDependency* node = self.jit_write_buckets[bucket]; node != null; node = node.next_bucket) {
        if (node.owner == owner && node.slot == slot && *node.live) {
            *node.live = false;
            self.jit_dependencies_dirty = true;
        }
    }
}
fn void Heap.jit_notify_write(&self, HObject* owner, PropValue* slot) @feat(!SLJIT) @inline {}

fn void Heap.jit_notify_layout(&self, HObject* owner) @feat(SLJIT) @inline {
    if (owner == null || !owner.gc.jit_observed) return;
    self.jit_invalidate_owner(owner);
}
fn void Heap.jit_notify_layout(&self, HObject* owner) @feat(!SLJIT) @inline {}

fn void Heap.jit_invalidate_owner(&self, HObject* owner) @feat(SLJIT) @noinline {
    for (uint i = 0; i < 64; i++) {
        for (JitWriteDependency* node = self.jit_write_buckets[i]; node != null; node = node.next_bucket) {
            if (node.owner == owner && *node.live) {
                *node.live = false;
                self.jit_dependencies_dirty = true;
            }
        }
    }
}

fn void Heap.jit_invalidate_writes(&self) @feat(SLJIT) @noinline {
    if (self.jit_write_buckets == null) return;
    for (uint i = 0; i < 64; i++) {
        for (JitWriteDependency* node = self.jit_write_buckets[i]; node != null; node = node.next_bucket) {
            if (*node.live) {
                *node.live = false;
                self.jit_dependencies_dirty = true;
            }
        }
    }
}
fn void Heap.jit_invalidate_writes(&self) @feat(!SLJIT) @inline {}

// A client ordinarily unregisters during plan free. Free any remaining nodes
// after compiled functions, without dereferencing owners already torn down.
fn void Heap.jit_free_write_dependencies(&self) @feat(SLJIT) {
    self.jit_dependencies_dirty = false;
    if (self.jit_write_buckets == null) return;
    for (uint i = 0; i < 64; i++) {
        JitWriteDependency* node = self.jit_write_buckets[i];
        while (node != null) {
            JitWriteDependency* next = node.next_bucket;
            *node.live = false;
            self.free_func(self.heap_udata, node);
            node = next;
        }
        self.jit_write_buckets[i] = null;
    }
    self.free_func(self.heap_udata, self.jit_write_buckets);
    self.jit_write_buckets = null;
}
fn void Heap.jit_free_write_dependencies(&self) @feat(!SLJIT) @inline {}
