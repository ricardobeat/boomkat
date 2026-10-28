module boomkat::heap;

import boomkat::gcprofile;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::types;
import std::time;
import std::io;

// Function-heavy frames reach many safepoints. A small work allowance spreads
// a large live-graph traversal across mutator execution as well as clock slices.
const uint GC_SLICE_WORK = 512;
const uint GC_LOOP_WORK = 65_536;
// Native batches supply few loop safepoints. Proportional work must cover
// multi-property record scanning and reclamation without that subsidy.
const uint GC_WORK_PER_ALLOC = 16;
const NanoDuration GC_SLICE_BUDGET = (NanoDuration)100_000;
// A slice paying allocation debt may run longer, in proportion to the work it owes.
const uint GC_SLICE_DEBT_SCALE = 5;

// A cycle starts only at a quiescent VM boundary, where native locals hold no
// unregistered graph roots. All reachable marks were cleared by the last sweep.
fn void Heap.gc_begin_cycle(&self, bool safepoint, GcKind kind = GcKind.MAJOR) {
    if (!safepoint || self.native_frame_depth != 0 || self.gc_phase != GcPhase.IDLE) return;
    self.gc_start_cycle(false, kind);
}

fn void Heap.gc_start_cycle(&self, bool keep_temproots, GcKind kind = GcKind.MAJOR) {
    self.gc_keep_temproots = keep_temproots;
    self.gc_kind = kind;
    // A major cycle drops the set: its scan clears each owner's flag.
    self.gc_remembered_scan.len = 0;
    self.gc_remembered_pos = 0;
    if (kind == GcKind.MINOR) {
        ObjStack taken = self.gc_remembered;
        self.gc_remembered = self.gc_remembered_scan;
        self.gc_remembered_scan = taken;
    }
    self.gc_remembered.len = 0;
    self.gc_root_generator_cursor = kind == GcKind.MINOR ? self.generator_states : null;
    self.gc_aux_env_cursor = {};
    self.gc_aux_env_cursor.started = true;
    if (kind == GcKind.MINOR) self.gc_aux_env_cursor.block = self.env_pool_blocks;
    if (kind == GcKind.MAJOR) {
        self.gc_aux_alloc_bytes = 0;
        self.gc_young_kept = 0;
        self.gc_young_dead = 0;
    }
    self.gc_phase = GcPhase.MARK;
    self.gc_running = true;
    self.gc_requested = false;
    self.gc_alloc_since_begin = 0;
    self.gc_alloc_paced = 0;
    self.gc_mark_epoch = !self.gc_mark_epoch;
    self.env_mark_epoch = !self.env_mark_epoch;
    self.mark_work_last = 0;
    self.marked_obj_count = 0;
    self.gc_root_stage = 0;
    self.gc_root_index = 0;
    self.gc_root_subindex = 0;
    self.gc_new_compiled_index = 0;
    self.gc_new_compiled_subindex = 0;
    self.gc_new_compiled_pending = false;
    self.gc_vm_root_cursor = 0;
    self.gc_capi_root_cursor = 0;
    self.gc_weak_func_index = 0;
    self.gc_weak_entry_index = 0;
    self.gc_roots_done = false;
    self.gc_weak_done = kind == GcKind.MINOR;
    self.gc_mark_schedule_stage = 0;
    self.gc_gray.len = 0;
    self.gc_scan_object = null;
    self.gray_count = 0;
    self.gc_env_gray_head = null;
    self.gc_env_gray_tail = null;
    self.gc_gen_gray_head = null;
    self.gc_gen_gray_tail = null;
    self.gc_scan_generator = null;
    self.gc_pending = true;
}

fn bool Heap.gc_mark_queues_empty(&self) {
    return self.gc_gray.len == 0 && self.gc_scan_object == null
        && self.gc_env_gray_head == null
        && self.gc_gen_gray_head == null && self.gc_scan_generator == null
        && !self.gc_new_compiled_pending && !self.gc_remembered_pending()
        && self.gc_aux_env_cursor.block == null && self.gc_root_generator_cursor == null;
}

fn bool Heap.gc_mark_stage_ready(&self, uint stage) {
    switch (stage) {
        case 0: return !self.gc_roots_done;
        case 1: return self.gc_env_gray_head != null || self.gc_aux_env_cursor.block != null;
        case 2: return self.gc_gray.len != 0 || self.gc_scan_object != null || self.gc_remembered_pending();
        case 3: return self.gc_gen_gray_head != null || self.gc_scan_generator != null || self.gc_root_generator_cursor != null;
        default: return self.gc_new_compiled_pending;
    }
}

// One swept object can own a large slot array. The cursor stays on its header
// until bounded teardown finishes, then the header itself is returned.
fn void Heap.gc_sweep_objects_step(&self, uint budget) {
    while (budget > 0) {
        if (self.gc_free_object != null) {
            usz first_slot = self.gc_free_index;
            bool done = hobject::hobject_free_step(self.gc_free_object, self, &self.gc_free_index, budget);
            if (!done) return;
            // The teardown costs one unit per slot it released, plus the free.
            usz cost = self.gc_free_index - first_slot + 1;
            budget = cost >= budget ? 0 : budget - (uint)cost;
            hobject::hobject_free_header(self.gc_free_object, self);
            self.gc_free_object = null;
            self.gc_free_index = 0;
            continue;
        }
        HeapHeader* cur = self.gc_sweep_old.pop() @inline
            ?? self.gc_sweep_young.pop() @inline ?? null;
        if (cur == null) { self.gc_sweep_stage++; return; }
        gcprofile::gcprof_sweep_node(cur.gc.old);
        budget--;
        if (cur.is_reachable()) {
            bool promoted = !cur.gc.old && !self.gc_keep_temproots;
            cur.clear_reachable();
            if (!self.gc_keep_temproots) cur.clear_temproot();
            if (promoted) {
                cur.gc.old = true;
                self.gc_old_count++;
                self.gc_young_kept++;
            }
            push_header(cur.gc.old ? &self.objects_old : &self.objects_young, cur);
            if (cur.gc.old && cur.is_object()) {
                HObject* owner = (HObject*)cur;
                if (promoted || self.gc_keep_temproots || self.gc_has_host_edges(owner)) self.remember(owner);
            }
            continue;
        }
        if (cur.gc.old) {
            self.gc_old_count--;
        } else {
            self.gc_young_dead++;
        }
        if (self.live_obj_count > 0) self.live_obj_count--;
        if (cur.is_object()) {
            HObject* obj = (HObject*)cur;
            // Freeing costs one unit per slot, as hobject_free_step charges.
            uint slots = obj.prop_count + obj.array_size;
            if (slots < budget && hobject::hobject_free_inline(obj, self)) {
                budget -= slots;
                continue;
            }
            self.gc_free_object = obj;
            self.gc_free_index = 0;
        } else {
            self.free_func(self.heap_udata, cur);
        }
    }
}

fn bool Heap.gc_collects_strings(&self) {
    if (self.gc_kind == GcKind.MINOR || self.gc_keep_temproots) return false;
    return !self.gc_blocking || self.string_sweep_safe;
}

fn void Heap.gc_sweep_strings_step(&self, uint budget, bool quiescent) {
    if (!quiescent) return;
    while (budget > 0 && self.gc_string_index < self.str_table_size) {
        self.mark_work_last++;
        HString* entry = self.str_table[self.gc_string_index];
        if (entry != null && entry != STR_TABLE_TOMBSTONE && entry.refcount == 1) {
            self.str_table_tombstone(self.gc_string_index);
            if (self.str_table_used > 0) self.str_table_used--;
            self.free_string(entry);
        }
        self.gc_string_index++;
        budget--;
    }
    if (self.gc_string_index >= self.str_table_size) self.gc_sweep_stage++;
}

fn void Heap.gc_sweep_large_strings_step(&self, uint budget, bool quiescent) {
    if (!quiescent) return;
    while (budget > 0 && self.gc_large_string_index < self.large_string_count) {
        self.mark_work_last++;
        HString* entry = self.large_strings[self.gc_large_string_index];
        if (entry.refcount == 0) {
            self.large_string_count--;
            if (self.gc_large_string_index < self.large_string_count) {
                self.large_strings[self.gc_large_string_index] = self.large_strings[self.large_string_count];
                self.large_strings[self.gc_large_string_index].registry_slot = self.gc_large_string_index + 1;
            }
            self.free_string(entry);
        } else {
            self.gc_large_string_index++;
        }
        budget--;
    }
    if (self.gc_large_string_index >= self.large_string_count) self.gc_sweep_stage++;
}

fn void Heap.gc_finish_cycle(&self) {
    self.gc_cycles++;
    gcprofile::gcprof_generation(self.gc_kind == GcKind.MINOR);
    self.gc_phase = GcPhase.IDLE;
    self.gc_running = false;
    self.sweep_active = false;
    self.gc_roots_done = false;
    self.gc_weak_done = false;
    if (self.gc_kind == GcKind.MINOR) {
        self.gc_minors++;
    } else {
        self.gc_minors = 0;
        self.gc_major_old_count = self.gc_old_count;
        self.gc_major_mark_work = self.mark_work_last;
        self.gc_major_churn = self.gc_young_dead > self.gc_young_kept * 2;
        self.gc_quiescent_pending = self.gc_keep_temproots;
    }
    // RSS includes memory the collector cannot reclaim, so the check is coarse.
    // One read is cheap next to a cycle. Checking minor cycles too keeps the
    // overshoot small while a growing heap spaces its majors out.
    self.check_mem_limit(0);
    long by_nodes = (long)self.marked_obj_count * GC_TRIGGER_GROW_FACTOR;
    long by_work = (long)self.mark_work_last / GC_MARK_WORK_DIVISOR;
    long trigger = by_work > by_nodes ? by_work : by_nodes;
    if (trigger < GC_NURSERY_ALLOCATIONS) trigger = GC_NURSERY_ALLOCATIONS;
    $if $feat(GC_STRESS):
        trigger = 1;
    $endif
    long debt = (long)self.gc_alloc_since_begin;
    self.gc_trigger_counter = trigger > debt ? trigger - debt : GC_INITIAL_TRIGGER;
    if (trigger <= debt) self.gc_requested = true;
    long env_budget = (long)self.env_live_cells;
    if (env_budget < 1024) env_budget = 1024;
    $if $feat(GC_STRESS):
        env_budget = 1;
    $endif
    self.env_alloc_budget = env_budget;
    gcprofile::gcprof_cycle((ulong)self.marked_obj_count);
    $if $feat(GC_PROFILE):
        uint[9] pg;
        pg[0] = self.obj_pool_plain.page_count + self.obj_pool_compact.page_count; pg[1] = self.obj_pool_array.page_count;
        pg[2] = self.obj_pool_dense_array.page_count; pg[3] = 0; foreach (&pool : self.obj_pool_inline_arrays) pg[3] += pool.page_count;
        pg[4] = self.obj_pool_small.page_count; pg[5] = self.obj_pool_func.page_count; pg[6] = self.obj_pool_big.page_count;
        pg[7] = 0; foreach (&sp : self.small_pools) pg[7] += sp.page_count;
        pg[8] = 0; foreach (v : pg[:8]) pg[8] += v;
        io::eprintfn("#TRACE %s marked=%d old=%d live=%d alloc=%d young_kept=%d young_dead=%d pages=%d plain=%d arr=%d dense=%d lit=%d small=%d props=%d",
            self.gc_kind == GcKind.MINOR ? "minor" : "MAJOR", self.marked_obj_count, self.gc_old_count, self.live_obj_count,
            (long)gcprofile::gcprof_allocations - self.gc_trace_allocs, self.gc_young_kept, self.gc_young_dead, pg[8], pg[0], pg[1], pg[2], pg[3], pg[4], pg[7]);
        self.gc_trace_allocs = (long)gcprofile::gcprof_allocations;
    $endif
    self.gc_pending = self.gc_requested || self.gc_gen_retired != null
        || self.gc_generator_release_cursor.state != null;
}

// The work cap limits graph operations. The clock cap bounds the whole slice,
// including roots, weak pruning, teardown and string cleanup. Batches are at
// most 64 units, so the clock is read every few batches. It starts after the
// first batch, which always runs.
const uint GC_CLOCK_BATCH_INTERVAL = 4;

fn bool gc_slice_expired(Clock* started, uint batches, NanoDuration budget) @inline {
    if (batches == 0) return false;
    if (batches == 1) { *started = clock::now(); return false; }
    if (batches % GC_CLOCK_BATCH_INTERVAL != 0) return false;
    return started.to_now() >= budget;
}

fn uint Heap.gc_step(&self, uint work_budget, bool quiescent, NanoDuration clock_budget = GC_SLICE_BUDGET) {
    if (self.gc_in_step || (self.gc_running && self.gc_phase == GcPhase.IDLE)) return 0;
    uint completed = 0;
    self.gc_in_step = true;
    defer self.gc_in_step = false;
    Clock started;
    uint batches = 0;
    if (self.gc_phase == GcPhase.IDLE) {
        if (self.gc_requested && quiescent) { self.gc_begin_cycle(true, self.gc_next_kind()); }
        else if (self.gc_gen_retired != null || self.gc_generator_release_cursor.state != null) {
            uint left = work_budget;
            while (left > 0 && !gc_slice_expired(&started, batches, clock_budget)) {
                uint batch = left > 64 ? 64 : left;
                self.gc_release_generator_step(batch);
                completed += batch;
                batches++;
                left -= batch;
                if (self.gc_gen_retired == null && self.gc_generator_release_cursor.state == null) break;
            }
            self.gc_pending = self.gc_requested || self.gc_gen_retired != null
                || self.gc_generator_release_cursor.state != null;
        }
        if (self.gc_phase == GcPhase.IDLE) return completed;
    }
    uint remaining = work_budget;
    batches = 0;
    while (remaining > 0 && !gc_slice_expired(&started, batches, clock_budget)) {
        batches++;
        uint batch = remaining > 64 ? 64 : remaining;
        if (self.gc_phase == GcPhase.MARK) {
            // Only a queue with work consumes the slice allowance. Empty
            // queues stay in the round-robin order when they receive edges.
            for (uint skipped = 0; skipped < 5; skipped++) {
                uint stage = self.gc_mark_schedule_stage;
                if (self.gc_mark_stage_ready(stage)) break;
                self.gc_mark_schedule_stage = (stage + 1) % 5;
            }
            remaining -= batch;
            completed += batch;
            long phase_start = gcprofile::gcprof_now();
            if (self.gc_roots_done && self.gc_mark_queues_empty() && !self.gc_weak_done) {
                self.gc_weak_done = self.gc_prune_weak_step(batch);
                gcprofile::gcprof_phase(26, &phase_start);
            } else {
                switch (self.gc_mark_schedule_stage) {
                case 0:
                    if (!self.gc_roots_done) self.gc_roots_done = self.gc_scan_roots_step(batch);
                    gcprofile::gcprof_phase(24, &phase_start);
                case 1:
                    for (uint i = 0; i < batch && self.scan_env_step(); i++) {}
                    gcprofile::gcprof_phase(25, &phase_start);
                case 2:
                    self.gc_scan_object_step(batch);
                    gcprofile::gcprof_phase(25, &phase_start);
                case 3:
                    self.gc_scan_generator_step(batch);
                    gcprofile::gcprof_phase(25, &phase_start);
                default:
                    if (self.gc_new_compiled_pending) self.gc_scan_new_compiled_step(batch);
                    gcprofile::gcprof_phase(24, &phase_start);
                }
            }
            self.gc_mark_schedule_stage = (self.gc_mark_schedule_stage + 1) % 5;
            if (self.gc_roots_done && self.gc_mark_queues_empty()) {
                if (self.gc_weak_done && (quiescent || self.gc_blocking)) {
                    $if $feat(GC_VERIFY):
                        self.verify_incremental_mark();
                    $endif
                    self.gc_phase = GcPhase.SWEEP;
                    self.weak_condemn();
                    self.prepare_object_sweep();
                    self.sweep_active = true;
                    self.gc_sweep_stage = 0;
                    self.gc_string_index = 0;
                    self.gc_large_string_index = 0;
                    self.gc_env_sweep_cursor = {};
                }
            }
            continue;
        }
        remaining -= batch;
        if (!quiescent && !self.gc_blocking) break;
        completed += batch;
        long phase_start = gcprofile::gcprof_now();
        if (self.gc_sweep_stage == 0) {
            self.gc_sweep_objects_step(batch);
            gcprofile::gcprof_phase(27, &phase_start);
        }
        else if (self.gc_sweep_stage == 1) {
            if (self.gc_kind == GcKind.MINOR || hobject::env_pool_sweep_slice(self, batch)) self.gc_sweep_stage++;
            gcprofile::gcprof_phase(28, &phase_start);
        } else if (self.gc_sweep_stage == 2) {
            // Before the string stages, so key strings the dropped shapes held
            // are reclaimed in this same cycle.
            if (self.gc_collects_strings() && self.native_frame_depth == 0) self.sweep_shapes();
            self.gc_sweep_stage++;
            gcprofile::gcprof_phase(28, &phase_start);
        } else if (self.gc_sweep_stage == 3) {
            if (!self.gc_collects_strings()) {
                self.gc_sweep_stage++;
            } else { self.gc_sweep_strings_step(batch, quiescent); }
            gcprofile::gcprof_phase(29, &phase_start);
        }
        else if (self.gc_sweep_stage == 4) {
            if (!self.gc_collects_strings()) {
                self.gc_sweep_stage++;
            } else { self.gc_sweep_large_strings_step(batch, quiescent); }
            gcprofile::gcprof_phase(29, &phase_start);
        }
        else if (self.gc_sweep_stage == 5) {
            if (self.gc_release_generator_step(batch)) self.gc_sweep_stage++;
            gcprofile::gcprof_phase(30, &phase_start);
        } else {
            self.gc_finish_cycle();
            return completed;
        }
    }
    self.gc_pending = true;
    return completed;
}
