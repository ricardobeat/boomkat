module boomkat::heap;

import boomkat::env;
import boomkat::types;
import std::io;

// A separate stopped-world traversal checks the incremental result before
// any dead storage is released. Its extra retention never changes the result
// under test: the candidate marks and environment epochs are restored.
fn void Heap.verify_incremental_mark(&self) @feat(GC_VERIFY) {
    assert(self.gc_gray.len == 0 && self.gc_scan_object == null);
    assert(self.gc_env_gray_head == null);
    ulong saved_work = self.mark_work_last;
    uint saved_marked = self.marked_obj_count;
    HeapObjectCursor candidate_objects;
    for (HeapHeader* node = self.next_object(&candidate_objects); node != null;
         node = self.next_object(&candidate_objects)) {
        node.gc.verify_live = node.is_reachable();
        node.clear_reachable();
    }
    env::env_pool_verify_save(self);
    self.gc_oracle_running = true;
    self.mark_roots();
    self.drain_gray();
    self.gc_oracle_running = false;
    HeapObjectCursor oracle_objects;
    for (HeapHeader* node = self.next_object(&oracle_objects); node != null;
         node = self.next_object(&oracle_objects)) {
        bool collected = self.gc_kind == GcKind.MAJOR || !node.gc.old;
        if (collected && node.is_reachable() && !node.gc.verify_live) {
            io::eprintfn("[GC_VERIFY] incremental mark missed reachable node %p type=%d",
                node, (int)node.get_type());
            self.fatal_func(self.heap_udata, "GC_VERIFY: incremental reachability mismatch");
        }
        node.flags.reachable = node.gc.verify_live;
        node.gc.verify_live = false;
    }
    env::env_pool_verify_restore(self);
    self.mark_work_last = saved_work;
    self.marked_obj_count = saved_marked;
}
