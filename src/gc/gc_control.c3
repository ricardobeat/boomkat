module boomkat::heap;

import boomkat::types;
import std::time;

// Host control of the collector and of the heap's byte budget.
//
// Byte accounting is chosen when the heap is created: the allocator callbacks
// are wrapped so that each block carries its size in a header in front of it,
// and `heap_bytes` follows every allocation, reallocation and free made
// through the heap allocator. The size-class pools and page pools draw their
// memory through the same callbacks, so they are counted by the block.
//
// The limit is a budget, not a cap on each allocation: crossing it sets
// `heap_limit_hit`, which the interrupt poll turns into an uncatchable
// termination at the next safepoint. A single block of MEM_LIMIT_LARGE_BLOCK
// bytes or more that would cross it is refused instead, so one huge buffer
// cannot take the process far past the limit before the poll.

const usz ACCOUNT_HEADER = 16;
const ulong HEAP_UNLIMITED = ulong::max;

// The size header in front of an accounted block.
macro usz* account_header(void* ptr) => (usz*)((char*)ptr - ACCOUNT_HEADER);

// True when `size` more bytes may be handed out. Records a crossing.
fn bool Heap.account_admit(&self, usz size) @inline {
    if (self.heap_bytes + size <= self.heap_limit) return true;
    if (!self.heap_limit_hit) {
        self.heap_limit_hit = true;
        self.interrupt_due = true;
    }
    return size < MEM_LIMIT_LARGE_BLOCK;
}

fn void* accounted_alloc(void* udata, usz size) {
    Heap* h = (Heap*)udata;
    if (size == 0 || !h.account_admit(size)) return null;
    char* raw = (char*)h.user_alloc(h.user_udata, size + ACCOUNT_HEADER);
    if (raw == null) return null;
    *(usz*)raw = size;
    h.heap_bytes += size;
    return raw + ACCOUNT_HEADER;
}

fn void accounted_free(void* udata, void* ptr) {
    if (ptr == null) return;
    Heap* h = (Heap*)udata;
    usz* header = account_header(ptr);
    h.heap_bytes -= *header;
    h.user_free(h.user_udata, header);
}

fn void* accounted_realloc(void* udata, void* ptr, usz size) {
    if (ptr == null) return accounted_alloc(udata, size);
    Heap* h = (Heap*)udata;
    if (size == 0) {
        accounted_free(udata, ptr);
        return null;
    }
    usz* header = account_header(ptr);
    usz old = *header;
    if (size > old && !h.account_admit(size - old)) return null;
    char* raw = (char*)h.user_realloc(h.user_udata, header, size + ACCOUNT_HEADER);
    if (raw == null) return null;
    *(usz*)raw = size;
    h.heap_bytes = h.heap_bytes - old + size;
    return raw + ACCOUNT_HEADER;
}

// Route the heap allocator through the accounting wrappers. Called once,
// before the heap allocates anything but its own struct.
fn void Heap.enable_accounting(&self, ulong limit) {
    self.accounting = true;
    self.user_alloc = self.alloc_func;
    self.user_realloc = self.realloc_func;
    self.user_free = self.free_func;
    self.user_udata = self.heap_udata;
    self.alloc_func = &accounted_alloc;
    self.realloc_func = &accounted_realloc;
    self.free_func = &accounted_free;
    self.heap_udata = self;
    self.heap_limit = limit;
}

// Change the budget of an accounting heap. A lower limit takes effect at the
// next allocation.
fn void Heap.set_heap_limit(&self, ulong limit) {
    self.heap_limit = limit == 0 ? HEAP_UNLIMITED : limit;
    self.heap_limit_hit = false;
}

// After a heap-limit termination reaches the host: collect, then stay armed
// only while the heap is still over budget.
fn void Heap.settle_heap_limit(&self) {
    self.heap_limit_hit = false;
    if (self.native_frame_depth == 0) self.mark_and_sweep(true, true);
    self.heap_limit_hit = self.heap_bytes > self.heap_limit;
}

// A blocking collection requested by the host. A minor cycle needs a quiescent
// heap with the nursery in use; otherwise the collection is a full one.
fn void Heap.host_collect(&self, bool minor) {
    if (minor && self.native_frame_depth == 0 && self.gc_phase == GcPhase.IDLE
        && !self.gc_in_step && !self.gc_running && self.gc_uses_nursery()) {
        self.gc_blocking = true;
        defer self.gc_blocking = false;
        self.gc_start_cycle(false, GcKind.MINOR);
        while (self.gc_phase != GcPhase.IDLE) self.gc_step(uint::max, true);
        return;
    }
    self.mark_and_sweep(self.native_frame_depth == 0, true);
}

// Collector work for at most `budget_ns`, starting a cycle when none is
// running. True while the cycle is still in progress.
fn bool Heap.host_gc_step(&self, ulong budget_ns) {
    bool quiescent = self.native_frame_depth == 0;
    if (self.gc_phase == GcPhase.IDLE) self.gc_requested = true;
    long ns = budget_ns > (ulong)long::max ? long::max : (long)budget_ns;
    self.gc_step(uint::max, quiescent, (NanoDuration)ns);
    return self.gc_phase != GcPhase.IDLE;
}

fn void Heap.gc_set_inhibit(&self, bool inhibit) {
    if (inhibit) {
        self.gc_inhibit++;
        return;
    }
    if (self.gc_inhibit == 0) return;
    if (--self.gc_inhibit == 0 && self.gc_inhibited_request) {
        self.gc_inhibited_request = false;
        self.request_gc();
    }
}

// External memory counts toward collection pressure in kilobyte units, as
// large strings do.
fn void Heap.add_external_memory(&self, long delta) {
    self.external_bytes += delta;
    if (self.external_bytes < 0) self.external_bytes = 0;
    if (delta > 0) self.charge_allocation(delta >> 10);
}
