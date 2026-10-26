// Memory shared between agents, and the machinery agents use to wait on it.
//
// An agent is one runtime on one thread. Runtimes share no heap objects; the
// only thing that crosses between them is a SharedArrayBuffer's data block.
// This module owns that block, and the process-wide waiter table behind
// Atomics.wait, Atomics.notify and Atomics.waitAsync.
module boomkat::agent;

import std::atomic;
import std::thread;
import std::time;
import libc;
import boomkat::heap;
import boomkat::hobject;
import boomkat::builtins;

// ============================================================================
// Shared data blocks
// ============================================================================

// A SharedArrayBuffer's bytes live in a libc block with this header in front.
// `ab.data` keeps pointing at the bytes, so every typed array fast path reads
// a shared buffer exactly as it reads an ArrayBuffer.
//
// libc rather than the heap allocator: the last reference can be dropped by
// another agent's thread after the creating heap is gone, and a heap's
// allocator callbacks belong to that heap's embedder.
//
// `length` is the live byte length, which a growable buffer raises from any
// agent; `capacity` is the size of the data region and never changes.
// `growable` records that the buffer was created with a maxByteLength, so an
// agent adopting the block can rebuild the same kind of buffer.
struct BlockHeader {
    uint refs;
    uint length;
    uint capacity;
    uint growable;
}

const usz BLOCK_HEADER_SIZE = BlockHeader::size;

macro BlockHeader* block_header(char* data) @private => (BlockHeader*)(data - BLOCK_HEADER_SIZE);

// A zeroed block holding `capacity` bytes, `length` of them live, with one
// reference. Returns the data pointer, or null when memory is exhausted. The
// data is never null on success, even for an empty buffer, so that every
// SharedArrayBuffer can be shared.
fn char* block_alloc(uint length, uint capacity, bool growable = false) {
    BlockHeader* header = (BlockHeader*)libc::calloc(1, BLOCK_HEADER_SIZE + (usz)capacity);
    if (header == null) return null;
    header.refs = 1;
    header.length = length;
    header.capacity = capacity;
    header.growable = growable ? 1 : 0;
    return (char*)header + BLOCK_HEADER_SIZE;
}

fn void block_retain(char* data) {
    atomic::fetch_add(&block_header(data).refs, 1u, RELAXED);
}

// Drops one reference and frees the block when it was the last.
fn void block_release(char* data) {
    BlockHeader* header = block_header(data);
    if (atomic::fetch_sub(&header.refs, 1u, ACQUIRE_RELEASE) == 1) libc::free(header);
}

fn uint block_length(char* data) {
    return mem::@atomic_load(block_header(data).length);
}

fn uint block_capacity(char* data) {
    return block_header(data).capacity;
}

fn bool block_growable(char* data) {
    return block_header(data).growable != 0;
}

// Raises the live length to `new_length`. False when that would shrink it.
// A concurrent grow can win the race, so the length is retried against the
// freshest value rather than overwritten.
fn bool block_grow(char* data, uint new_length) {
    BlockHeader* header = block_header(data);
    uint seen = mem::@atomic_load(header.length);
    while (seen <= new_length) {
        uint witnessed = mem::compare_exchange(&header.length, seen, new_length);
        if (witnessed == seen) return true;
        seen = witnessed;
    }
    return false;
}

// ============================================================================
// Cells
// ============================================================================

// Atomic read of the `width`-byte cell at `p`, zero-extended.
fn ulong cell_load(char* p, uint width) {
    switch (width) {
        case 1: return (ulong)mem::@atomic_load(*(char*)p);
        case 2: return (ulong)mem::@atomic_load(*(ushort*)p);
        case 4: return (ulong)mem::@atomic_load(*(uint*)p);
        default: return (ulong)mem::@atomic_load(*(ulong*)p);
    }
}

fn ulong width_mask(uint width) {
    return width >= 8 ? ulong::max : (1UL << (width * 8)) - 1;
}

// ============================================================================
// Waiter table
// ============================================================================

// One lock guards every waiter, bucket, and port inbox in the process. Waits
// are rare and short next to the work around them, and one lock is what makes
// the futex rule easy to hold: a waiter compares its cell and joins the queue
// in a single critical section, so a notify that follows the compare cannot
// miss it.
Mutex g_lock;
OnceFlag g_lock_once;

fn void init_lock() @private {
    g_lock.init()!!;
}

macro void lock() @private {
    g_lock_once.call(&init_lock);
    g_lock.lock();
}

macro void unlock() @private => g_lock.unlock();

enum WaitState : char {
    QUEUED,       // in a bucket, waiting for a notify or its deadline
    NOTIFIED,     // claimed by a notify; out of the bucket
    TIMED_OUT,
    INTERRUPTED,
}

// One thread blocked in Atomics.wait, or one pending Atomics.waitAsync.
// A synchronous waiter lives on its thread's stack; an asynchronous one is
// calloc'd and owned by its heap slot until the promise settles.
struct Waiter {
    Waiter*   next;        // bucket FIFO, oldest first
    Waiter*   prev;
    Waiter*   inbox_next;  // port inbox, for a notified asynchronous waiter
    char*     addr;        // the cell, absolute so every agent derives the same key
    Port*     port;        // the waiting agent's mailbox
    char*     block;       // asynchronous: the shared block, retained
    ulong     deadline;    // clock ns; 0 waits forever
    uint      slot;        // asynchronous: index into the heap's async_waiters
    WaitState state;
    bool      is_async;
}

struct Bucket {
    Waiter* head;
    Waiter* tail;
}

const uint BUCKET_COUNT = 64;
Bucket[BUCKET_COUNT] g_buckets;

fn Bucket* bucket_of(char* addr) @private {
    ulong h = (ulong)(usz)addr * 0x9E37_79B9_7F4A_7C15UL;
    return &g_buckets[(uint)(h >> 58)];
}

fn void link_waiter(Waiter* w) @private {
    Bucket* b = bucket_of(w.addr);
    w.prev = b.tail;
    w.next = null;
    if (b.tail != null) {
        b.tail.next = w;
    } else {
        b.head = w;
    }
    b.tail = w;
}

fn void unlink_waiter(Waiter* w) @private {
    Bucket* b = bucket_of(w.addr);
    if (w.prev != null) {
        w.prev.next = w.next;
    } else {
        b.head = w.next;
    }
    if (w.next != null) {
        w.next.prev = w.prev;
    } else {
        b.tail = w.prev;
    }
    w.next = null;
    w.prev = null;
}

// ============================================================================
// Ports
// ============================================================================

// An agent's mailbox. Refcounted because the host record for an agent thread
// outlives the heap that created the port, and notifiers outlive both.
// Everything below `refs` is guarded by g_lock, apart from the two words the
// drain loop reads without it.
struct Port {
    uint              refs;
    ConditionVariable cv;
    Waiter*           inbox_head;     // notified asynchronous waiters, oldest first
    Waiter*           inbox_tail;
    uint              pending;        // inbox length; read without the lock
    ulong             next_deadline;  // earliest asynchronous deadline, 0 none; read without the lock
    bool              host_event;     // the host posted work for the agent loop
    bool              stop;           // the host wants the agent loop gone
}

fn Port* port_create() {
    Port* port = (Port*)libc::calloc(1, Port::size);
    if (port == null) abort("out of memory creating an agent port");
    port.refs = 1;
    port.cv.init()!!;
    return port;
}

fn void port_retain(Port* port) {
    atomic::fetch_add(&port.refs, 1u, RELAXED);
}

fn void port_release(Port* port) {
    if (atomic::fetch_sub(&port.refs, 1u, ACQUIRE_RELEASE) != 1) return;
    port.cv.destroy();
    libc::free(port);
}

// The heap's port, created on first use. A heap that never touches shared
// memory never pays for one, and its drain loop skips the poll.
fn Port* port_for(Heap* heap) {
    if (heap.agent_port == null) {
        heap.agent_poll_fn = &builtins::atomics_poll;
        mem::@atomic_store(heap.agent_port, (void*)port_create());
    }
    return (Port*)heap.agent_port;
}

// Wakes whatever the port's thread is blocked on so it re-checks its flags.
// Taking the lock orders the wake after the waiter's check-then-sleep.
fn void port_wake(Port* port) {
    lock();
    port.cv.signal();
    unlock();
}

// Posts work for the agent loop (a broadcast, or the host's stop request).
fn void port_post_event(Port* port, bool stop = false) {
    lock();
    port.host_event = true;
    if (stop) port.stop = true;
    port.cv.signal();
    unlock();
}

// True once per posted event.
fn bool port_take_event(Port* port) {
    lock();
    defer unlock();
    bool had = port.host_event;
    port.host_event = false;
    return had;
}

fn bool port_stopped(Port* port) {
    lock();
    defer unlock();
    return port.stop;
}

// A watchdog calls this after raising the interrupt flag, so a blocked
// Atomics.wait notices instead of sleeping out its timeout.
fn void wake_interrupt(Heap* heap) {
    Port* port = (Port*)mem::@atomic_load(heap.agent_port);
    if (port != null) port_wake(port);
}

// ============================================================================
// Time
// ============================================================================

fn ulong now_ns() @private => (ulong)clock::now();

// The deadline `timeout_ms` from now, or 0 for one that never comes (NaN,
// +Infinity, or too large to matter). A timeout that has already elapsed
// yields `now`, which is never 0.
fn ulong deadline_after(double timeout_ms) @private {
    if (timeout_ms != timeout_ms || timeout_ms > 1.0e12) return 0;
    ulong now = now_ns();
    if (timeout_ms <= 0.0) return now;
    return now + (ulong)(timeout_ms * 1.0e6);
}

// Sleeps on the port's condition until `until` (clock ns; 0 sleeps until
// signalled). Spurious returns are fine: every caller re-checks its state.
// Caller holds g_lock.
fn void sleep_until(Port* port, ulong until) @private {
    if (until == 0) {
        port.cv.wait(&g_lock);
        return;
    }
    ulong now = now_ns();
    if (now >= until) return;
    Duration span = time::us((long)((until - now + 999) / 1000));
    if (catch port.cv.wait_timeout(&g_lock, span)) {}
}

// ============================================================================
// Atomics.wait / Atomics.notify
// ============================================================================

enum WaitOutcome : char { NOT_EQUAL, OK, TIMED_OUT, INTERRUPTED }

// Atomics.wait on the `width`-byte cell at `cell`: blocks while it holds
// `expected`, until a notify, the timeout, or an interrupt of this heap.
fn WaitOutcome wait_sync(Heap* heap, char* cell, uint width, ulong expected, double timeout_ms) {
    Port* port = port_for(heap);
    Waiter w;
    w.addr = cell;
    w.port = port;
    w.deadline = deadline_after(timeout_ms);

    lock();
    defer unlock();
    if (cell_load(cell, width) != (expected & width_mask(width))) return NOT_EQUAL;

    link_waiter(&w);
    while (w.state == QUEUED) {
        if (mem::@atomic_load(heap.interrupt_requested) != 0 || port.stop) {
            unlink_waiter(&w);
            w.state = INTERRUPTED;
        } else if (w.deadline != 0 && now_ns() >= w.deadline) {
            unlink_waiter(&w);
            w.state = TIMED_OUT;
        } else {
            sleep_until(port, w.deadline);
        }
    }
    switch (w.state) {
        case NOTIFIED:    return OK;
        case TIMED_OUT:   return TIMED_OUT;
        default:          return INTERRUPTED;
    }
}

// Atomics.notify: claims up to `count` waiters on `cell`, oldest first, and
// wakes them. A synchronous waiter wakes on its own condition; an
// asynchronous one is queued for its heap, whose next poll settles the promise.
fn uint notify(char* cell, double count) {
    lock();
    defer unlock();
    uint woken = 0;
    Waiter* w = bucket_of(cell).head;
    while (w != null && (double)woken < count) {
        Waiter* next = w.next;
        if (w.addr == cell) {
            unlink_waiter(w);
            w.state = NOTIFIED;
            woken++;
            Port* port = w.port;
            if (w.is_async) {
                w.inbox_next = null;
                if (port.inbox_tail != null) {
                    port.inbox_tail.inbox_next = w;
                } else {
                    port.inbox_head = w;
                }
                port.inbox_tail = w;
                mem::@atomic_store(port.pending, port.pending + 1);
            }
            port.cv.signal();
        }
        w = next;
    }
    return woken;
}

// ============================================================================
// Atomics.waitAsync
// ============================================================================

// Parks `promise` on the cell unless it no longer holds `expected`. The compare
// and the enqueue share one critical section, as in wait_sync. Returns false
// when the cell differs, and the caller reports "not-equal". The block is
// retained until the promise settles, so a timeout still fires after every
// other holder of the memory has let go.
fn bool wait_async(Heap* heap, HObject* promise, char* block, char* cell, uint width, ulong expected, double timeout_ms) {
    Port* port = port_for(heap);
    Waiter* w = (Waiter*)libc::calloc(1, Waiter::size);
    if (w == null) abort("out of memory parking an Atomics.waitAsync waiter");
    w.addr = cell;
    w.port = port;
    w.block = block;
    w.is_async = true;
    w.deadline = deadline_after(timeout_ms);

    uint slot = async_slot(heap);

    lock();
    if (cell_load(cell, width) != (expected & width_mask(width))) {
        unlock();
        libc::free(w);
        return false;
    }
    block_retain(block);
    w.slot = slot;
    heap.async_waiters[slot] = { .promise = promise, .node = w };
    heap.shade_root_object(promise);
    link_waiter(w);
    refresh_deadline(heap, port);
    unlock();
    return true;
}

// A free slot in the heap's waiter array, growing it when none is.
fn uint async_slot(Heap* heap) @private {
    for (uint i = 0; i < heap.async_waiter_count; i++) {
        if (heap.async_waiters[i].node == null && heap.async_waiters[i].promise == null) return i;
    }
    if (heap.async_waiter_count == heap.async_waiter_capacity) {
        uint capacity = heap.async_waiter_capacity == 0 ? 8 : heap.async_waiter_capacity * 2;
        void* grown = libc::realloc(heap.async_waiters, (usz)capacity * heap::AtomicsWaiter::size);
        if (grown == null) abort("out of memory growing the Atomics.waitAsync table");
        heap.async_waiters = (heap::AtomicsWaiter*)grown;
        heap.async_waiter_capacity = capacity;
    }
    uint slot = heap.async_waiter_count++;
    heap.async_waiters[slot] = {};
    return slot;
}

// Recomputes the port's earliest deadline from the heap's queued waiters.
// Caller holds g_lock.
fn void refresh_deadline(Heap* heap, Port* port) @private {
    ulong earliest = 0;
    for (uint i = 0; i < heap.async_waiter_count; i++) {
        Waiter* w = (Waiter*)heap.async_waiters[i].node;
        if (w == null || w.state != QUEUED || w.deadline == 0) continue;
        if (earliest == 0 || w.deadline < earliest) earliest = w.deadline;
    }
    mem::@atomic_store(port.next_deadline, earliest);
}

// True when polling the port would settle something. The drain loop asks this
// between jobs, so the common answer must not take the lock.
fn bool port_ready(Port* port) {
    if (mem::@atomic_load(port.pending) != 0) return true;
    ulong deadline = mem::@atomic_load(port.next_deadline);
    return deadline != 0 && now_ns() >= deadline;
}

// Detaches one waiter that is ready to settle (notified, or past its
// deadline) from the heap's table and returns its promise, with
// `*timed_out` telling which. Null when nothing is ready. Only the promise
// leaves the table: the caller settles it outside the lock.
fn HObject* take_ready(Heap* heap, bool* timed_out) {
    Port* port = (Port*)heap.agent_port;
    lock();
    defer unlock();
    Waiter* ready = port.inbox_head;
    if (ready != null) {
        port.inbox_head = ready.inbox_next;
        if (port.inbox_head == null) port.inbox_tail = null;
        mem::@atomic_store(port.pending, port.pending - 1);
        *timed_out = false;
    } else {
        ulong now = now_ns();
        for (uint i = 0; i < heap.async_waiter_count && ready == null; i++) {
            Waiter* w = (Waiter*)heap.async_waiters[i].node;
            if (w == null || w.state != QUEUED || w.deadline == 0 || now < w.deadline) continue;
            unlink_waiter(w);
            w.state = TIMED_OUT;
            ready = w;
        }
        if (ready == null) return null;
        *timed_out = true;
    }
    heap::AtomicsWaiter* entry = &heap.async_waiters[ready.slot];
    HObject* promise = entry.promise;
    *entry = {};
    block_release(ready.block);
    libc::free(ready);
    refresh_deadline(heap, port);
    return promise;
}

// Asynchronous waiters this heap still has pending.
fn uint async_pending(Heap* heap) {
    uint n = 0;
    for (uint i = 0; i < heap.async_waiter_count; i++) {
        if (heap.async_waiters[i].promise != null) n++;
    }
    return n;
}

// Blocks the calling agent until its port has something: a notified waiter, a
// deadline, a host event, or `limit_ms` passing (0 for no limit).
fn void wait_events(Heap* heap, double limit_ms) {
    Port* port = port_for(heap);
    ulong limit = limit_ms > 0.0 ? deadline_after(limit_ms) : 0;
    lock();
    defer unlock();
    while (true) {
        if (port.pending != 0 || port.host_event || port.stop) return;
        if (mem::@atomic_load(heap.interrupt_requested) != 0) return;
        ulong now = now_ns();
        ulong until = port.next_deadline;
        if (limit != 0 && (until == 0 || limit < until)) until = limit;
        if (until != 0 && now >= until) return;
        sleep_until(port, until);
    }
}

// ============================================================================
// Agent lifetime
// ============================================================================

// Agents (threads other than the main one) that exist and can still notify.
// run_event_loop uses it to tell a wait that may yet be woken from one that
// never will be.
uint g_live_agents;

fn void agent_enter() => (void)atomic::fetch_add(&g_live_agents, 1u, RELAXED);
fn void agent_exit()  => (void)atomic::fetch_sub(&g_live_agents, 1u, RELAXED);
fn uint live_agents() => mem::@atomic_load(g_live_agents);

// Drops everything the heap holds in the table, ahead of its reset or
// destruction: queued waiters leave their buckets (so no other agent can
// touch them), and the blocks they retain are released.
fn void heap_release(Heap* heap) {
    if (heap.agent_port == null) return;
    Port* port = (Port*)heap.agent_port;
    lock();
    for (uint i = 0; i < heap.async_waiter_count; i++) {
        Waiter* w = (Waiter*)heap.async_waiters[i].node;
        if (w == null) continue;
        if (w.state == QUEUED) unlink_waiter(w);
        block_release(w.block);
        libc::free(w);
    }
    port.inbox_head = null;
    port.inbox_tail = null;
    mem::@atomic_store(port.pending, 0u);
    mem::@atomic_store(port.next_deadline, 0UL);
    unlock();
    if (heap.async_waiters != null) libc::free(heap.async_waiters);
    heap.async_waiters = null;
    heap.async_waiter_count = 0;
    heap.async_waiter_capacity = 0;
    mem::@atomic_store(heap.agent_port, null);
    heap.agent_poll_fn = null;
    port_release(port);
}

// Runs the heap's jobs and settles whatever other agents or timers have made
// ready, until neither has anything left to do.
fn void run_ready(Heap* heap, void* vm) {
    while (true) {
        heap.drain_microtasks(vm, true, 0xFFFF_FFFFu, true);
        if (heap.agent_port == null || !builtins::atomics_poll(heap, vm)) return;
    }
}

// Runs the heap's jobs, then keeps going for as long as an asynchronous
// waiter could still settle: notified by another agent, or timed out. Returns
// once nothing is pending, or only waits that nothing can end remain.
fn void run_event_loop(Heap* heap, void* vm) {
    while (true) {
        run_ready(heap, vm);
        if (heap.agent_port == null || async_pending(heap) == 0) return;
        Port* port = (Port*)heap.agent_port;
        bool can_end = mem::@atomic_load(port.next_deadline) != 0 || live_agents() != 0;
        if (!can_end) return;
        if (mem::@atomic_load(heap.interrupt_requested) != 0) return;
        // A bounded sleep: the last agent leaving cannot signal this port, so
        // the loop re-checks `can_end` itself.
        wait_events(heap, 50.0);
    }
}
