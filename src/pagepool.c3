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

import std::core::mem::allocator;

const sz PAGE_SIZE = 64 * 1024;
// Empty pages kept per pool so a pool hovering at a page boundary does not
// return and fetch the same page over and over.
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
    PoolPage* p = self.avail_head;
    if (p == null) p = self.add_page();
    void* block;
    if (p.freelist) {
        block = p.freelist;
        p.freelist = *(void**)block;
        mem::clear(block, self.block_size);
    } else {
        block = p.bump;
        void* next = block + self.block_size;
        p.bump = next + self.block_size <= (void*)p + PAGE_SIZE ? next : null;
        if (!p.zeroed) mem::clear(block, self.block_size);
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
    if (self.empty_count < EMPTY_RESERVE) {
        p.zeroed = false;
        p.next = self.empty;
        self.empty = p;
        self.empty_count++;
        return;
    }
    release_page(p);
}

fn void PagePool.avail_append(&self, PoolPage* p) @inline {
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

fn void PagePool.avail_unlink(&self, PoolPage* p) @inline {
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

fn void release_page(PoolPage* p) @local {
    alloc::free_aligned(&allocators::LIBC_ALLOCATOR, p);
}
