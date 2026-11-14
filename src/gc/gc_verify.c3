module boomkat::heap;

import boomkat::env;
import boomkat::pagepool;
import boomkat::types;
import std::io;

// A separate stopped-world traversal checks the incremental result before
// any dead storage is released. Its extra retention never changes the result
// under test: the candidate marks and environment epochs are restored. The
// oracle marks pooled objects in the pages' `mark` bitmaps, which a minor does
// not use and a major's are saved for.
fn void Heap.verify_incremental_mark(&self) @feat(GC_VERIFY) {
    assert(self.gc_gray.len == 0 && self.gc_scan_object == null);
    assert(self.gc_env_gray_head == null);
    ulong saved_work = self.mark_work_last;
    uint saved_marked = self.marked_obj_count;
    bool major = self.gc_kind == GcKind.MAJOR;
    HeapObjectCursor candidate_objects;
    for (HeapHeader* node = self.next_object(&candidate_objects); node != null;
         node = self.next_object(&candidate_objects)) {
        if (is_pooled(node)) continue;
        node.gc.verify_live = self.gc_is_marked(node);
        node.gc.mark = (char)(self.gc_epoch - 1);
    }
    usz page_count = 0;
    foreach (pool : self.obj_pools) page_count += pool.page_count;
    Bitmap[] saved = mem::new_array(Bitmap, (sz)page_count);
    defer free(saved);
    usz n = 0;
    foreach (pool : self.obj_pools) {
        for (ObjPage* p = pool.pages; p != null; p = p.next) {
            if (!major) {
                saved[n] = p.live;
            } else if (p.mark_epoch == self.gc_major_epoch) {
                saved[n] = p.mark;
            }
            n++;
            p.mark = {};
            p.mark_epoch = self.gc_major_epoch;
        }
    }
    env::env_pool_verify_save(self);
    self.gc_oracle_running = true;
    self.mark_roots();
    self.drain_gray();
    self.gc_oracle_running = false;
    HeapObjectCursor oracle_objects;
    for (HeapHeader* node = self.next_object(&oracle_objects); node != null;
         node = self.next_object(&oracle_objects)) {
        if (is_pooled(node)) continue;
        bool collected = major || !node.gc.old;
        if (collected && self.gc_is_marked(node) && !node.gc.verify_live) self.verify_missed(node);
        node.gc.mark = (char)(node.gc.verify_live ? self.gc_epoch : self.gc_epoch - 1);
        node.gc.verify_live = false;
    }
    n = 0;
    foreach (pool : self.obj_pools) {
        for (ObjPage* p = pool.pages; p != null; p = p.next) {
            for (usz w = 0; w < pagepool::BITMAP_WORDS; w++) {
                ulong missed = p.mark[w] & ~saved[n][w];
                if (missed != 0) self.verify_missed((HeapHeader*)pool.block_at(p, (w << 6) + (usz)missed.ctz()));
            }
            p.mark = major ? saved[n] : {};
            n++;
        }
    }
    env::env_pool_verify_restore(self);
    self.mark_work_last = saved_work;
    self.marked_obj_count = saved_marked;
}

fn void Heap.verify_missed(&self, HeapHeader* node) @feat(GC_VERIFY) {
    io::eprintfn("[GC_VERIFY] incremental mark missed reachable node %p type=%d", node, (int)node.get_type());
    self.fatal("GC_VERIFY: incremental reachability mismatch");
}
