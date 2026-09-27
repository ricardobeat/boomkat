module boomkat::heap;

import boomkat::hobject;
import boomkat::types;
import boomkat::gcprofile;

const uint GC_MAX_MINORS = 64;
const long GC_NURSERY_ALLOCATIONS = 16_384;
const uint GC_NURSERY_MIN_OLD = 65_536;
const ulong GC_AUX_MAJOR_BYTES = 256 * 1024;

fn bool Heap.gc_uses_nursery(&self) @inline {
    $if $feat(GC_STRESS):
        return true;
    $else
        return self.gc_major_old_count >= GC_NURSERY_MIN_OLD;
    $endif
}

fn ulong Heap.gc_auxiliary_limit(&self) @inline {
    ulong retained_bytes = (ulong)self.gc_major_old_count * HeapHeader::size;
    return retained_bytes > GC_AUX_MAJOR_BYTES ? retained_bytes : GC_AUX_MAJOR_BYTES;
}

fn GcKind Heap.gc_next_kind(&self) {
    // Minor scans amortize their promotion work over a substantial retained heap.
    if (self.gc_quiescent_pending) return GcKind.MAJOR;
    if (!self.gc_uses_nursery()) return GcKind.MAJOR;
    if (self.gc_minors >= GC_MAX_MINORS) return GcKind.MAJOR;
    if ((ulong)self.gc_old_count > (ulong)self.gc_major_old_count * 2 + 4096) return GcKind.MAJOR;
    if (self.gc_aux_alloc_bytes >= self.gc_auxiliary_limit()) return GcKind.MAJOR;
    return GcKind.MINOR;
}

// Threaded register publication and tracing share the same admission rule.
fn bool Heap.gc_needs_mark(&self, HeapHeader* header) @inline {
    if (header == null || header.is_reachable()) return false;
    return self.gc_kind == GcKind.MAJOR || !header.gc.old || self.gc_oracle_running;
}

fn void Heap.mark_header(&self, HeapHeader* header) @inline {
    if (!self.gc_needs_mark(header)) return;
    header.set_reachable();
    if (header.is_object()) self.gray_push((HObject*)header);
}

fn bool Heap.is_young_value(&self, TVal value) @inline {
    if (!value.is_object() && !value.is_buffer() && !value.is_bigint()) return false;
    HeapHeader* header = (HeapHeader*)value.get_heapptr();
    return header != null && !header.gc.old;
}

// The extra link keeps mutation bookkeeping independent of the gray queue.
fn void Heap.remember(&self, HObject* owner) @inline {
    if (owner.gc.remembered) return;
    owner.gc.remembered = true;
    owner.gc_remembered_next = self.gc_remembered;
    self.gc_remembered = owner;
}

fn HObject* Heap.gc_take_remembered_owner(&self) {
    gcprofile::gcprof_remembered_owner();
    HObject* owner = self.gc_remembered_cursor;
    self.gc_remembered_cursor = owner.gc_remembered_next;
    owner.gc_remembered_next = null;
    owner.gc.remembered = false;
    assert(owner.gc.old);
    ((HeapHeader*)owner).set_reachable();
    self.marked_obj_count++;
    if (self.gc_has_host_edges(owner)) self.remember(owner);
    return owner;
}

fn bool Heap.gc_has_host_edges(&self, HObject* owner) {
    if (owner.flags.obj_class != ObjClass.HOST) return false;
    HostClassEntry* hc = self.host_class_at((*owner.extra_ptr()).host.class_id);
    return hc != null && hc.gc_mark != null;
}

fn void Heap.acquire_generator_state(&self, GeneratorState* state) {
    gs_acquire(state);
    self.shade_root_generator_state(state);
}

fn void* Heap.alloc_generator_registers(&self, usz bytes) {
    void* ptr = self.alloc_func(self.heap_udata, bytes);
    if (ptr != null) self.account_auxiliary_allocation(bytes);
    return ptr;
}

// Large backing stores share the allocation budget used by large strings.
// Auxiliary bytes select a major when that budget requests collection.
fn void Heap.account_auxiliary_allocation(&self, usz bytes) {
    self.gc_aux_alloc_bytes += bytes;
    self.gc_trigger_counter -= (long)(bytes >> 10);
    if (self.gc_phase != GcPhase.IDLE) self.gc_alloc_since_begin += (ulong)(bytes >> 10);
    if (self.gc_trigger_counter <= 0) self.request_gc();
}
