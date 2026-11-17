// Fixed-size block pool that returns empty pages.
//
// std::core::mem::mempool::FixedBlockPool threads every freed block onto one
// freelist and releases pages only when the whole pool is freed, so the heap
// holds the pages of its peak object count for the rest of the process. Here
// each page is aligned to its own size and keeps its own freelist and live
// count: freeing a block finds its page by masking the address, and a page
// whose last block is freed goes back to the allocator (past a small reserve).
//
// Allocation draws from the oldest page with room, so partly free pages fill
// up before new ones are touched and the rest have a chance to drain empty.
// Drawing from the page that most recently gained a free block, the way the
// single LIFO freelist did, kept nearly every page partly used: a long Splay
// loop grew to 1.64 GB that way against 1.16 GB oldest-first, at no speed gain.
module boomkat::pagepool;

import std::core::mem::alloc;
import std::core::mem::allocators;

// SMALL_VM shrinks pages to fit in microcontroller RAM.
const sz PAGE_SIZE = $feat(SMALL_VM) ? 4 * 1024 : 64 * 1024;
// Empty pages kept per pool so a pool hovering at a page boundary does not
// return and fetch the same page over and over. Between trims a pool keeps
// every page it empties, which never holds more pages than it had in use at
// once; a trim keeps as many as the pool took since the last one, which the
// next stretch of allocation is likely to take again.
const uint EMPTY_RESERVE = 4;

struct PoolPage {
    PoolPage* prev;       // all pages
    PoolPage* next;
    PoolPage* avail_prev; // pages with a free block, oldest first
    PoolPage* avail_next;
    void* freelist;
    void* bump;           // first never-used block, or null once the page has handed out all
    uint used;
    bool in_avail;
    bool zeroed;          // blocks from `bump` onwards are still zero
}

const sz PAGE_HEADER = (PoolPage::size + 15) & ~(sz)15;

struct PagePool {
    PoolPage* pages;
    PoolPage* avail_head;
    PoolPage* avail_tail;
    PoolPage* empty;      // reserve, linked through `next`
    sz block_size;
    uint capacity;        // blocks per page
    uint empty_count;
    uint page_count;
    uint taken;           // pages added since the last trim
}

fn void PagePool.init(&self, sz block_size) {
    *self = {};
    if (block_size < 16) block_size = 16;
    block_size = (block_size + 7) & ~(sz)7;
    self.block_size = block_size;
    self.capacity = (uint)((PAGE_SIZE - PAGE_HEADER) / block_size);
    assert(self.capacity > 0, "block size %d does not fit a pool page", block_size);
}

fn void PagePool.free(&self) {
    for (PoolPage* p = self.pages; p != null;) {
        PoolPage* next = p.next;
        release_page(p);
        p = next;
    }
    for (PoolPage* p = self.empty; p != null;) {
        PoolPage* next = p.next;
        release_page(p);
        p = next;
    }
    *self = { .block_size = self.block_size, .capacity = self.capacity };
}

<*
 @return "A zeroed block of `block_size` bytes"
*>
fn void* PagePool.alloc(&self) {
    return self.alloc_cleared(self.block_size);
}

// The caller initializes the whole block before making it observable.
fn void* PagePool.alloc_uninit(&self) @inline {
    return self.alloc_cleared(0);
}

macro void* PagePool.alloc_cleared(&self, sz clear_bytes) {
    PoolPage* p = self.avail_head;
    if (p == null) p = self.add_page();
    void* block;
    if (p.freelist) {
        block = p.freelist;
        p.freelist = *(void**)block;
        mem::clear(block, clear_bytes);
    } else {
        block = p.bump;
        void* next = block + self.block_size;
        p.bump = next + self.block_size <= (void*)p + PAGE_SIZE ? next : null;
        if (!p.zeroed) mem::clear(block, clear_bytes);
    }
    if (++p.used == self.capacity) self.avail_unlink(p);
    return block;
}

fn void PagePool.dealloc(&self, void* block) {
    PoolPage* p = (PoolPage*)((uptr)block & ~(uptr)(PAGE_SIZE - 1));
    *(void**)block = p.freelist;
    p.freelist = block;
    if (!p.in_avail) self.avail_append(p);
    if (--p.used == 0) self.retire_page(p);
}

fn PoolPage* PagePool.add_page(&self) {
    PoolPage* p = self.empty;
    if (p != null) {
        self.empty = p.next;
        self.empty_count--;
    } else {
        p = alloc::calloc_aligned(&allocators::LIBC_ALLOCATOR, PAGE_SIZE, PAGE_SIZE)!!;
        p.zeroed = true;
    }
    self.taken++;
    p.bump = (void*)p + PAGE_HEADER;
    p.freelist = null;
    p.used = 0;
    p.prev = null;
    p.next = self.pages;
    if (self.pages) self.pages.prev = p;
    self.pages = p;
    self.page_count++;
    self.avail_append(p);
    return p;
}

fn void PagePool.retire_page(&self, PoolPage* p) {
    self.avail_unlink(p);
    if (p.prev) {
        p.prev.next = p.next;
    } else {
        self.pages = p.next;
    }
    if (p.next) p.next.prev = p.prev;
    self.page_count--;
    p.zeroed = false;
    p.next = self.empty;
    self.empty = p;
    self.empty_count++;
}

// Release the empty pages beyond the reserve and the pages taken since the
// last trim.
fn void PagePool.trim(&self) {
    uint keep = max(self.taken, EMPTY_RESERVE);
    while (self.empty_count > keep) {
        PoolPage* p = self.empty;
        self.empty = p.next;
        self.empty_count--;
        release_page(p);
    }
    self.taken = 0;
}

fn void PagePool.avail_append(&self, PoolPage* p) {
    p.in_avail = true;
    p.avail_next = null;
    p.avail_prev = self.avail_tail;
    if (self.avail_tail) {
        self.avail_tail.avail_next = p;
    } else {
        self.avail_head = p;
    }
    self.avail_tail = p;
}

fn void PagePool.avail_unlink(&self, PoolPage* p) {
    if (!p.in_avail) return;
    p.in_avail = false;
    if (p.avail_prev) {
        p.avail_prev.avail_next = p.avail_next;
    } else {
        self.avail_head = p.avail_next;
    }
    if (p.avail_next) {
        p.avail_next.avail_prev = p.avail_prev;
    } else {
        self.avail_tail = p.avail_prev;
    }
}

fn void release_page(void* p) @local {
    alloc::free_aligned(&allocators::LIBC_ALLOCATOR, p);
}

// Pages of traced objects, reclaimed by the collector rather than freed one by
// one. Each page keeps bitmaps with one bit per 32-byte granule, set at the
// granule where a block starts (blocks are at least a granule, so no two start
// in one): `live` holds the objects that survived the page's last sweep and the
// young ones a minor collection marks, `mark` the marks of a major collection,
// valid while `mark_epoch` is the heap's current major epoch. Allocation bumps
// through runs of blocks that are not live, from the bottom of the page up, so
// every block below `top` is allocated and the rest are allocated if live. A
// sweep finds the dead objects as allocated blocks without a mark, and makes the
// survivors the new live set; a page whose objects all survive costs a few
// bitmap words, and dead blocks are not written. Only a dead object whose
// `teardown` bit is set owns anything to release and is visited; a page of
// dead objects without it is reclaimed whole.
const uint GRANULE_SHIFT = 5;
const uint BITMAP_WORDS = (uint)(PAGE_SIZE >> GRANULE_SHIFT) / 64;

alias Bitmap = ulong[BITMAP_WORDS];

struct ObjPage {
    ObjPage* prev;        // all pages of the pool
    ObjPage* next;
    ObjPage* link;        // the list the page is on: available, young, full, queued or empty
    void* top;
    uint live_count;
    uint mark_epoch;
    Bitmap live;
    Bitmap mark;
    Bitmap teardown;
}

const sz OBJ_PAGE_HEADER = (ObjPage::size + 31) & ~(sz)31;

struct PageList {
    ObjPage* head;
    ObjPage* tail;
}

fn void PageList.push(&self, ObjPage* p) @inline {
    p.link = null;
    if (self.tail) {
        self.tail.link = p;
    } else {
        self.head = p;
    }
    self.tail = p;
}

fn ObjPage* PageList.pop(&self) @inline {
    ObjPage* p = self.head;
    if (p == null) return null;
    self.head = p.link;
    if (self.head == null) self.tail = null;
    return p;
}

// Move every page of `other` to the end of this list.
fn void PageList.take(&self, PageList* other) {
    if (other.head == null) return;
    if (self.tail) {
        self.tail.link = other.head;
    } else {
        self.head = other.head;
    }
    self.tail = other.tail;
    *other = {};
}

struct SweepCounts {
    uint dead_old;
    uint dead_young;
    uint kept_young;
}

struct ObjectPool {
    // The run of free blocks allocation takes from, in `cur`. Generated code
    // bumps it inline.
    void* bump;
    void* limit;
    sz block_size;
    ObjPage* cur;
    ObjPage* pages;
    PageList avail;       // swept, with free blocks, oldest first
    PageList young;       // allocated into since their last sweep, `cur` among them
    PageList full;        // swept, with no free block
    PageList queued;      // waiting for the sweep in progress
    ObjPage* empty;       // reserve, linked through `link`
    uint empty_count;
    uint page_count;
    uint taken;           // pages added since the last trim
    uint capacity;        // blocks per page
    sz end;               // the offset where the last block ends
    Bitmap starts;        // the granules where blocks start
}

fn void ObjectPool.init(&self, sz block_size) {
    *self = {};
    block_size = (block_size + 7) & ~(sz)7;
    assert(block_size >= 1 << GRANULE_SHIFT, "object block of %d bytes is smaller than a granule", block_size);
    self.block_size = block_size;
    self.capacity = (uint)((PAGE_SIZE - OBJ_PAGE_HEADER) / block_size);
    assert(self.capacity > 0, "block size %d does not fit a pool page", block_size);
    self.end = OBJ_PAGE_HEADER + (sz)self.capacity * block_size;
    for (sz off = OBJ_PAGE_HEADER; off < self.end; off += block_size) {
        usz g = (usz)off >> GRANULE_SHIFT;
        self.starts[g >> 6] |= 1UL << (g & 63);
    }
}

fn void ObjectPool.free(&self) {
    for (ObjPage* p = self.pages; p != null;) {
        ObjPage* next = p.next;
        release_page(p);
        p = next;
    }
    for (ObjPage* p = self.empty; p != null;) {
        ObjPage* next = p.link;
        release_page(p);
        p = next;
    }
    sz block_size = self.block_size;
    self.init(block_size);
}

fn ObjPage* page_of(void* block) @inline {
    return (ObjPage*)((uptr)block & ~(uptr)(PAGE_SIZE - 1));
}

fn usz granule_of(void* block) @inline {
    return ((uptr)block & (uptr)(PAGE_SIZE - 1)) >> GRANULE_SHIFT;
}

// The offset of a page's `live` or `mark` bitmap, for generated code.
fn usz bitmap_offset(bool live) {
    ObjPage* p = (ObjPage*)(uptr)PAGE_SIZE;
    return (usz)((char*)(live ? (void*)&p.live : (void*)&p.mark) - (char*)p);
}

macro bool bit_test(ulong* map, usz g) => (map[g >> 6] & (1UL << (g & 63))) != 0;
macro void bit_set(ulong* map, usz g) { map[g >> 6] |= 1UL << (g & 63); }

// The block that starts in granule `g` of page `p`.
fn void* ObjectPool.block_at(&self, ObjPage* p, usz g) @inline {
    usz off = (g << GRANULE_SHIFT) + (1 << GRANULE_SHIFT) - 1 - (usz)OBJ_PAGE_HEADER;
    return (void*)p + OBJ_PAGE_HEADER + (sz)(off / (usz)self.block_size) * self.block_size;
}

// The blocks of page `p` allocated as `w`'s word of the bitmaps: the live ones
// and every one below the page's top.
fn ulong ObjectPool.allocated_word(&self, ObjPage* p, usz w) @inline {
    usz top = ((uptr)p.top - (uptr)p) >> GRANULE_SHIFT;
    usz first = w << 6;
    ulong below = top >= first + 64 ? ~0UL : top <= first ? 0 : (1UL << (top - first)) - 1;
    return p.live[w] | (below & self.starts[w]);
}

<*
 Allocate one block. `epoch` is the heap's major epoch: a page taken for
 allocation drops the marks of an older major.
 @return "An uninitialized block, or null when the system allocator fails"
*>
fn void* ObjectPool.alloc(&self, uint epoch) @inline {
    void* block = self.bump;
    void* next = block + self.block_size;
    if (next > self.limit) return self.alloc_slow(epoch);
    self.bump = next;
    return block;
}

fn void* ObjectPool.alloc_slow(&self, uint epoch) @noinline {
    ObjPage* p = self.cur;
    if (p == null || !self.next_run(p, self.limit)) {
        if (p != null) p.top = (void*)p + self.end;
        p = self.avail.pop();
        if (p == null) p = self.add_page();
        if (p == null) return null;
        if (p.mark_epoch != epoch) {
            p.mark = {};
            p.mark_epoch = epoch;
        }
        self.young.push(p);
        self.cur = p;
        bool found = self.next_run(p, (void*)p + OBJ_PAGE_HEADER);
        assert(found, "a page offered for allocation has no free block");
    }
    void* block = self.bump;
    self.bump = block + self.block_size;
    return block;
}

// Point bump and limit at the first run of free blocks in `p` at or above
// `from`; false when there is none.
fn bool ObjectPool.next_run(&self, ObjPage* p, void* from) {
    if (from >= (void*)p + self.end) return false;
    usz g = granule_of(from);
    usz w = g >> 6;
    if (w >= BITMAP_WORDS) return false;
    ulong free = self.starts[w] & ~p.live[w] & (~0UL << (g & 63));
    while (free == 0) {
        if (++w == BITMAP_WORDS) return false;
        free = self.starts[w] & ~p.live[w];
    }
    usz start = (w << 6) + (usz)free.ctz();
    ulong live = p.live[w] & (~0UL << (start & 63));
    void* end = (void*)p + self.end;
    while (live == 0 && ++w < BITMAP_WORDS) live = p.live[w];
    if (live != 0) end = self.block_at(p, (w << 6) + (usz)live.ctz());
    self.bump = self.block_at(p, start);
    self.limit = end;
    return true;
}

fn ObjPage* ObjectPool.add_page(&self) {
    ObjPage* p = self.empty;
    if (p != null) {
        self.empty = p.link;
        self.empty_count--;
    } else {
        p = alloc::malloc_aligned(&allocators::LIBC_ALLOCATOR, PAGE_SIZE, PAGE_SIZE) ?? null;
        if (p == null) return null;
    }
    self.taken++;
    self.page_count++;
    p.prev = null;
    p.next = self.pages;
    if (self.pages) self.pages.prev = p;
    self.pages = p;
    p.link = null;
    p.top = (void*)p + OBJ_PAGE_HEADER;
    p.live = {};
    p.teardown = {};
    p.live_count = 0;
    p.mark_epoch = uint::max;
    return p;
}

fn void ObjectPool.retire(&self, ObjPage* p) {
    if (p.prev) {
        p.prev.next = p.next;
    } else {
        self.pages = p.next;
    }
    if (p.next) p.next.prev = p.prev;
    self.page_count--;
    p.link = self.empty;
    self.empty = p;
    self.empty_count++;
}

// Release the empty pages beyond the reserve and the pages taken since the
// last trim.
fn void ObjectPool.trim(&self) {
    uint keep = max(self.taken, EMPTY_RESERVE);
    while (self.empty_count > keep) {
        ObjPage* p = self.empty;
        self.empty = p.link;
        self.empty_count--;
        release_page(p);
    }
    self.taken = 0;
}

// Record how far allocation has come in the current page.
fn void ObjectPool.sync(&self) @inline {
    if (self.cur != null) self.cur.top = self.bump;
}

// Queue the pages a collection sweeps: those allocated into since their last
// sweep, and for a major every page. Allocation moves on to other pages.
fn void ObjectPool.begin_sweep(&self, bool major) {
    self.sync();
    self.cur = null;
    self.bump = null;
    self.limit = null;
    self.queued.take(&self.young);
    if (major) {
        self.queued.take(&self.avail);
        self.queued.take(&self.full);
    }
}

// Sweep page `p` as far as its bitmaps go: the dead objects with something to
// release go to `dead` for teardown, and the survivors become its live set. A
// major's survivors are its marks; a minor marked its survivors live already.
// The page is not offered for allocation until ObjectPool.finish_page.
fn SweepCounts ObjectPool.sweep_page(&self, ObjPage* p, bool major, uint epoch, ulong* dead) {
    SweepCounts n;
    bool marked = p.mark_epoch == epoch;
    uint live_count = 0;
    for (usz w = 0; w < BITMAP_WORDS; w++) {
        ulong old = p.live[w];
        ulong allocated = self.allocated_word(p, w);
        ulong kept = major ? (marked ? p.mark[w] & allocated : 0) : old;
        ulong gone = allocated & ~kept;
        dead[w] = gone & p.teardown[w];
        p.teardown[w] &= kept;
        n.dead_old += (uint)(gone & old).popcount();
        n.dead_young += (uint)(gone & ~old).popcount();
        if (major) n.kept_young += (uint)(kept & ~old).popcount();
        p.live[w] = kept;
        live_count += (uint)kept.popcount();
    }
    if (!major) n.kept_young = live_count - p.live_count;
    p.live_count = live_count;
    p.top = (void*)p + OBJ_PAGE_HEADER;
    return n;
}

// Offer a swept page whose dead objects are torn down: for allocation when it
// has room, back to the reserve when it holds nothing.
fn void ObjectPool.finish_page(&self, ObjPage* p) {
    if (p.live_count == 0) {
        self.retire(p);
    } else if (p.live_count == self.capacity) {
        self.full.push(p);
    } else {
        self.avail.push(p);
    }
}
