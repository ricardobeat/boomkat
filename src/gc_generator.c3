module boomkat::heap;

import boomkat::types;
import boomkat::hobject;
import boomkat::vm;

// The queued state owns one reference. Chain-node removal advances these
// cursors before freeing storage, while register scans reload the saved array.
struct GcGeneratorCursor {
    uint stage;
    uint index;
    ForInState* forin;
    Catcher* catcher;
    AsyncGenRequest* request;
}

struct GcGeneratorReleaseCursor {
    GeneratorState* state;
    uint stage;
    uint index;
}

fn void Heap.gc_before_scanned_free(&self, void* pointer) {
    GcGeneratorCursor* c = &self.gc_generator_cursor;
    if (pointer == c.forin && c.forin != null) c.forin = c.forin.parent;
    self.gc_before_catcher_free((Catcher*)pointer);
    if (pointer == c.request && c.request != null) c.request = c.request.next;
}

// The catcher case of gc_before_scanned_free, for TRY/ENDTRY's recycling path.
fn void Heap.gc_before_catcher_free(&self, Catcher* catcher) @inline {
    GcGeneratorCursor* c = &self.gc_generator_cursor;
    if (catcher == c.catcher && catcher != null) c.catcher = catcher.parent;
}

fn bool Heap.gc_scan_generator_step(&self, uint budget) {
    while (budget > 0) {
        GeneratorState* gs = self.gc_scan_generator;
        if (gs == null) {
            gs = self.gc_gen_gray_head;
            if (gs == null) {
                gs = self.gc_root_generator_cursor;
                if (gs == null) return true;
                self.gc_root_generator_cursor = gs.gc_next;
                if (gs.ref_count > 0) self.shade_root_generator_state(gs);
                budget--;
                continue;
            }
            self.gc_gen_gray_head = gs.gc_gray_next;
            if (self.gc_gen_gray_head == null) self.gc_gen_gray_tail = null;
            gs.gc_gray_next = null;
            self.gc_scan_generator = gs;
            self.gc_generator_cursor = {};
        }
        GcGeneratorCursor* c = &self.gc_generator_cursor;
        budget--;
        switch (c.stage) {
            case 0:
                if (gs.saved_regs != null && c.index < gs.num_regs) {
                    self.mark_tval(&gs.saved_regs[c.index++]);
                } else {
                    c.stage++;
                }
            case 1:
                self.mark_env_chain(gs.var_env);
                self.mark_env_chain(gs.lex_env);
                self.mark_tval(&gs.this_binding);
                self.mark_tval(&gs.resume_value);
                self.mark_tval(&gs.throw_value);
                self.mark_tval(&gs.return_value);
                self.mark_tval(&gs.ays_received);
                self.mark_tval(&gs.ays_next_method);
                self.mark_tval(&gs.ag_current_value);
                self.mark_hobject((HObject*)gs.delegated_iter);
                self.mark_hobject((HObject*)gs.func_obj);
                self.mark_hobject((HObject*)gs.async_promise);
                self.mark_hobject((HObject*)gs.gen_obj);
                self.mark_hobject((HObject*)gs.ag_root_promise);
                self.mark_hobject((HObject*)gs.resume_wrapper);
                c.forin = (ForInState*)gs.forin;
                c.catcher = (Catcher*)gs.cat;
                c.request = gs.agr_head;
                c.stage++;
            case 2:
                if (c.forin != null) {
                    self.mark_hobject(c.forin.target);
                    c.forin = c.forin.parent;
                } else { c.stage++; }
            case 3:
                if (c.catcher != null) {
                    self.mark_tval(&c.catcher.thrown_val);
                    self.mark_tval(&c.catcher.return_val);
                    self.mark_env_chain(c.catcher.saved_lex_env);
                    c.catcher = c.catcher.parent;
                } else { c.stage++; }
            case 4:
                if (c.request != null) {
                    self.mark_tval(&c.request.value);
                    self.mark_hobject((HObject*)c.request.capability);
                    c.request = c.request.next;
                } else { c.stage++; }
            default:
                self.gc_scan_generator = null;
                self.gc_generator_cursor = {};
                gs.gc_gray_queued = false;
                gs_release(gs, self, true);
        }
    }
    return self.gc_scan_generator == null && self.gc_gen_gray_head == null;
}

// Zero-owner states contain no observable engine state. Their registry entry
// remains valid until bounded cleanup releases every owned resource.
fn void Heap.retire_generator_state(&self, GeneratorState* gs) {
    assert(gs.ref_count == 0 && !gs.gc_gray_queued);
    gs.gc_gray_next = self.gc_gen_retired;
    self.gc_gen_retired = gs;
    self.gc_pending = true;
}

fn bool Heap.gc_release_generator_step(&self, uint budget) {
    GcGeneratorReleaseCursor* c = &self.gc_generator_release_cursor;
    while (budget > 0) {
        if (c.state == null) {
            c.state = self.gc_gen_retired;
            if (c.state == null) return true;
            self.gc_gen_retired = c.state.gc_gray_next;
            c.state.gc_gray_next = null;
            c.stage = 0;
            c.index = 0;
        }
        GeneratorState* gs = c.state;
        budget--;
        switch (c.stage) {
            case 0:
                if (gs.saved_regs != null && c.index < gs.num_regs) {
                    self.decref_tval(&gs.saved_regs[c.index++]);
                } else {
                    if (gs.saved_regs != null) {
                        self.free_scanned(gs.saved_regs, (usz)gs.num_regs * TVal::size);
                        gs.saved_regs = null;
                    }
                    self.decref_tval(&gs.this_binding);
                    gs.this_binding.set_undefined();
                    self.decref_tval(&gs.ag_current_value);
                    gs.ag_current_value.set_undefined();
                    c.index = 0;
                    c.stage++;
                }
            case 1:
                ForInState* fi = (ForInState*)gs.forin;
                if (fi == null) { c.stage++; continue; }
                if (c.index < fi.count) {
                    fi.keys[c.index++].release(self);
                } else {
                    gs.forin = fi.parent;
                    if (fi.keys != null) self.free_func(self.heap_udata, fi.keys);
                    self.free_scanned(fi, ForInState::size);
                    c.index = 0;
                }
            case 2:
                Catcher* cat = (Catcher*)gs.cat;
                if (cat == null) { c.stage++; continue; }
                gs.cat = cat.parent;
                self.decref_tval(&cat.thrown_val);
                self.free_scanned(cat, Catcher::size);
            case 3:
                AsyncGenRequest* req = gs.agr_head;
                if (req == null) { c.stage++; continue; }
                gs.agr_head = req.next;
                self.decref_tval(&req.value);
                self.free_scanned(req, AsyncGenRequest::size);
            default:
                c.state = null;
                self.free_generator_state(gs);
        }
    }
    return c.state == null && self.gc_gen_retired == null;
}
