module boomkat::heap;

import boomkat::hobject;
import boomkat::types;
import boomkat::gcprofile;
import boomkat::pagepool;

const uint GC_MAX_MINORS = 64;
const long GC_NURSERY_ALLOCATIONS = 16_384;
// A major cycle that left this many old objects, or visited this many values,
// makes the following cycles minor. Values count too: an array's elements are
// not nodes, so a few large containers cost as much to rescan as many objects.
// The value bound is higher because a growing heap visits many values while
// nearly everything it allocates survives, and a minor then only promotes.
const uint GC_NURSERY_MIN_OLD = 65_536;
const ulong GC_NURSERY_MIN_WORK = 8 * GC_NURSERY_MIN_OLD;
// A heap this large is already worth minor cycles when the last major cycle
// freed most of the young objects it swept: the program mostly allocates
// garbage over a retained set that a major cycle re-marks in full.
const uint GC_NURSERY_MIN_OLD_CHURN = 8_192;
const ulong GC_AUX_MAJOR_BYTES = 256 * 1024;

fn bool Heap.gc_uses_nursery(&self) @inline {
    $if $feat(GC_STRESS):
        return true;
    $else
        return self.gc_major_old_count >= GC_NURSERY_MIN_OLD || self.gc_major_mark_work >= GC_NURSERY_MIN_WORK
            || (self.gc_major_churn && self.gc_major_old_count >= GC_NURSERY_MIN_OLD_CHURN);
    $endif
}

fn ulong Heap.gc_auxiliary_limit(&self) @inline {
    // Include the active and sweep vector slots, keeping pressure independent
    // of the links removed from each object header.
    ulong retained_bytes = (ulong)self.gc_major_old_count * (HeapHeader::size + 2 * uptr::size);
    return retained_bytes > GC_AUX_MAJOR_BYTES ? retained_bytes : GC_AUX_MAJOR_BYTES;
}

fn GcKind Heap.gc_next_kind(&self) {
    // Minor scans amortize their promotion work over a substantial retained heap.
    if (self.gc_quiescent_pending) { gcprofile::gcprof_major_reason(0); return GcKind.MAJOR; }
    if (!self.gc_uses_nursery()) { gcprofile::gcprof_major_reason(1); return GcKind.MAJOR; }
    if (self.gc_minors >= GC_MAX_MINORS) { gcprofile::gcprof_major_reason(2); return GcKind.MAJOR; }
    if ((ulong)self.gc_old_count > (ulong)self.gc_major_old_count * 2 + 4096) { gcprofile::gcprof_major_reason(3); return GcKind.MAJOR; }
    if (self.gc_aux_alloc_bytes >= self.gc_auxiliary_limit()) { gcprofile::gcprof_major_reason(4); return GcKind.MAJOR; }
    return GcKind.MINOR;
}

// An object from a page pool keeps its mark in the page's bitmaps; every other
// node in its header.
fn bool is_pooled(HeapHeader* header) @inline {
$if $feat(POOL_BYPASS):
    return false;
$else
    return header.is_object() && !((HObject*)header).flags.pool_fallback;
$endif
}

// A pooled object that comes to own something its death must release: a
// counted string in a slot, an out-of-line block or hash, a private shape, a
// subtype resource, or the interest of a cache or weak handle. Its page's sweep
// tears it down; a dead pooled object without the bit is reclaimed unvisited.
fn void needs_teardown(HObject* obj) @inline {
    if (obj == null || !is_pooled((HeapHeader*)obj)) return;
    pagepool::bit_set(&pagepool::page_of(obj).teardown, pagepool::granule_of(obj));
}

// A major marks pooled objects in `mark`; a minor marks young ones live, which
// promotes them, and finds the old ones live already. The oracle marks in
// `mark` for either kind (verify_incremental_mark).
fn bool Heap.gc_is_marked(&self, HeapHeader* header) @inline {
    if (!is_pooled(header)) return header.gc.mark == (char)self.gc_epoch;
    ObjPage* p = pagepool::page_of(header);
    usz g = pagepool::granule_of(header);
    if (self.gc_kind == GcKind.MINOR && !self.gc_oracle_running) return pagepool::bit_test(&p.live, g);
    return p.mark_epoch == self.gc_major_epoch && pagepool::bit_test(&p.mark, g);
}

// Register publication and tracing use the same admission rule.
fn bool Heap.gc_needs_mark(&self, HeapHeader* header) @inline {
    if (header == null) return false;
    if (self.gc_kind == GcKind.MINOR && header.gc.old && !self.gc_oracle_running) return false;
    return !self.gc_is_marked(header);
}

fn void Heap.mark_header(&self, HeapHeader* header) @inline {
    if (!self.gc_needs_mark(header)) return;
    self.gc_set_marked(header);
    if (header.is_object()) self.gray_push((HObject*)header);
}

// A marked node survives the cycle, so it is promoted now rather than when the
// sweep reaches it: from here on a store of a young value into it takes the
// old-owner barrier. A cycle that keeps temporary roots runs inside native
// code and promotes nothing; the oracle only observes.
fn void Heap.gc_set_marked(&self, HeapHeader* header) @inline {
    if (is_pooled(header)) {
        ObjPage* p = pagepool::page_of(header);
        usz g = pagepool::granule_of(header);
        if (self.gc_kind == GcKind.MINOR && !self.gc_oracle_running) {
            pagepool::bit_set(&p.live, g);
        } else {
            if (p.mark_epoch != self.gc_major_epoch) {
                p.mark = {};
                p.mark_epoch = self.gc_major_epoch;
            }
            pagepool::bit_set(&p.mark, g);
        }
    } else {
        header.gc.mark = (char)self.gc_epoch;
    }
    if (self.gc_keep_temproots || self.gc_oracle_running) return;
    header.flags.temproot = false;
    header.gc.old = true;
}

fn bool Heap.is_young_value(&self, TVal value) @inline {
    if (!value.is_object() && !value.is_buffer() && !value.is_bigint()) return false;
    HeapHeader* header = (HeapHeader*)value.get_heapptr();
    return header != null && !header.gc.old;
}

// Remembered owners and gray work have independent membership.
fn void Heap.remember(&self, HObject* owner) @inline {
    if (owner.gc.remembered) return;
    owner.gc.remembered = true;
    self.gc_remembered.push(owner);
}

fn bool Heap.gc_remembered_pending(&self) {
    return self.gc_remembered_pos < self.gc_remembered_scan.len;
}

fn HObject* Heap.gc_take_remembered_owner(&self) {
    gcprofile::gcprof_remembered_owner();
    HObject* owner = self.gc_remembered_scan.items[self.gc_remembered_pos++];
    owner.gc.remembered = false;
    assert(owner.gc.old);
    ((HeapHeader*)owner).gc.mark = (char)self.gc_epoch;
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
    self.charge_allocation((long)(bytes >> 10));
}
