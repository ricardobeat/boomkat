module boomkat::heap;

import boomkat::types;
import boomkat::hobject;
import boomkat::bytecode;
import boomkat::esm;

// Scan one constant or inline-cache edge. The caller keeps only indices, so
// compiler array growth cannot leave a cursor pointing into old storage.
fn bool Heap.gc_scan_compiled_slot(&self, bytecode::CompiledFunction* cf, uint* index) {
    if (cf == null) return true;
    if (*index < cf.const_count) {
        if (cf.constants != null) self.mark_tval(&cf.constants[(*index)]);
        (*index)++;
        return false;
    }
    uint ic_index = *index - cf.const_count;
    if (ic_index < cf.ic_count) {
        if (cf.ic_entries != null) {
            hobject::ICEntry* entries = (hobject::ICEntry*)cf.ic_entries;
            self.mark_hobject(hobject::ic_cached_proto(&entries[ic_index]));
        }
        (*index)++;
        return false;
    }
    return true;
}

// Functions published after the main root cursor passes enter this queue.
fn void Heap.gc_scan_new_compiled_step(&self, uint budget) {
    while (budget > 0 && self.gc_new_compiled_index < self.compiled_func_count) {
        bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[self.gc_new_compiled_index];
        if (self.gc_scan_compiled_slot(cf, &self.gc_new_compiled_subindex)) {
            self.gc_new_compiled_index++;
            self.gc_new_compiled_subindex = 0;
        }
        budget--;
    }
    if (self.gc_new_compiled_index >= self.compiled_func_count) self.gc_new_compiled_pending = false;
}

// Fixed intrinsic roots are a bounded group independent of heap size.
fn void Heap.mark_fixed_roots(&self) {
    self.mark_intrinsics(&self.realm_state);
}

// Each stage keeps an index rather than a pointer into a resizable array.
// A root published after its stage passed must use the root insertion barrier.
fn bool Heap.gc_scan_roots_step(&self, uint budget) {
    while (budget > 0) {
        budget--;
        switch (self.gc_root_stage) {
            case 0:
                self.mark_fixed_roots();
                self.gc_root_realm_cursor = self.realms;
                self.gc_root_object_cursor = self.object_roots;
                self.gc_root_env_cursor = self.env_roots;
                self.gc_root_value_cursor = self.value_roots;
                self.gc_root_stage++;
            case 1:
                ObjectRoot* r = self.gc_root_object_cursor;
                if (r == null) { self.gc_root_stage++; continue; }
                self.gc_root_object_cursor = r.previous;
                self.mark_hobject(r.object);
            case 2:
                EnvRoot* r = self.gc_root_env_cursor;
                if (r != null) {
                    self.gc_root_env_cursor = r.previous;
                    self.mark_env_chain(r.env);
                    continue;
                }
                ValueRoot* value_root = self.gc_root_value_cursor;
                if (value_root == null) { self.gc_root_stage++; continue; }
                self.gc_root_value_cursor = value_root.previous;
                self.mark_tval(&value_root.value);
            case 3:
                if (self.gc_root_index >= (uint)self.gc_roots.len()) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                HeapHeader* hdr = (HeapHeader*)self.gc_roots[self.gc_root_index++];
                if (hdr != null) {
                    self.mark_header(hdr);
                }
            case 4:
                if (self.capi_mark_slice != null && self.capi_roots != null) {
                    if (!self.capi_mark_slice(self.capi_roots, self, &self.gc_capi_root_cursor, budget + 1)) return false;
                    budget = 0;
                } else if (self.capi_mark != null) {
                    self.capi_mark(self.capi_roots);
                }
                self.gc_root_stage++;
            case 5:
                if (self.gc_root_index >= self.promoted_builtin_capacity) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                if (self.promoted_builtins != null) self.mark_hobject(self.promoted_builtins[self.gc_root_index]);
                self.gc_root_index++;
            case 6:
                if (self.gc_root_index >= self.addon_handle_count) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                self.mark_tval(&self.addon_handles[self.gc_root_index++]);
            case 7:
                if (self.gc_root_index >= self.host_class_count) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                self.mark_hobject(self.host_classes[self.gc_root_index++].proto);
            case 8:
                if (self.valstack_base == null || self.valstack_top_ptr == null
                    || self.gc_root_index >= (uint)(*self.valstack_top_ptr - self.valstack_base)) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                self.mark_tval(&self.valstack_base[self.gc_root_index++]);
            case 9:
                if (self.gc_root_index >= self.microtask_count * 3) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                if (self.gc_root_index < self.microtask_head * 3) self.gc_root_index = self.microtask_head * 3;
                self.mark_tval(&self.microtask_queue[self.gc_root_index++]);
            case 10:
                if (self.gc_root_index >= self.unhandled_count) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                self.mark_tval(&self.unhandled_rejections[self.gc_root_index++]);
            case 11:
                if (self.gc_root_index >= self.async_waiter_count) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                if (self.async_waiters[self.gc_root_index].promise != null) {
                    self.mark_hobject(self.async_waiters[self.gc_root_index].promise);
                }
                self.gc_root_index++;
            case 12:
                if (self.gc_root_index >= self.compiled_func_count) {
                    self.gc_root_index = 0;
                    self.gc_root_subindex = 0;
                    self.gc_root_stage++;
                    continue;
                }
                bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[self.gc_root_index];
                if (self.gc_scan_compiled_slot(cf, &self.gc_root_subindex)) {
                    self.gc_root_index++;
                    self.gc_root_subindex = 0;
                }
            case 13:
                if (self.gc_root_index >= self.checkpoint_count) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                self.mark_tval(&self.checkpoint_entries[self.gc_root_index++].value);
            case 14:
                if (self.mark_activations_slice_fn != null && self.curr_thread != null) {
                    if (!self.mark_activations_slice_fn(self.curr_thread, self, &self.gc_vm_root_cursor, budget + 1)) return false;
                    budget = 0;
                } else if (self.mark_activations_fn != null && self.curr_thread != null) {
                    self.mark_activations_fn(self.curr_thread, self);
                }
                self.gc_root_stage++;
            case 15:
                self.mark_tval(&self.error_value);
                self.mark_tval(&self.yield_value);
                self.mark_generator_state(self.resume_gen);
                self.mark_generator_state(self.gen_initial_gs);
                self.mark_hobject((HObject*)self.gen_initial_obj);
                self.gc_root_stage++;
            case 16:
                if (self.gc_root_index >= self.gen_init_stack_depth) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                self.mark_generator_state(self.gen_init_stack_gs[self.gc_root_index]);
                self.mark_hobject((HObject*)self.gen_init_stack_obj[self.gc_root_index++]);
            case 17:
                if (self.gc_root_index >= self.host_vals_len) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                TVal* hv = &self.host_vals[self.gc_root_index++];
                if (hv.is_traced()) self.mark_tval(hv);
            case 18:
                if (self.gc_root_index >= self.module_cache_count) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                if (self.module_cache != null) {
                    esm::ModuleDef** cache = (esm::ModuleDef**)self.module_cache;
                    esm::ModuleDef* mod = cache[self.gc_root_index];
                    if (mod != null) {
                        self.mark_env_chain((void*)mod.env);
                        if (mod.has_eval_error) self.mark_tval(&mod.eval_error);
                        if (mod.is_synthetic) self.mark_tval(&mod.synth_value);
                        self.mark_hobject(mod.import_meta_obj);
                        self.mark_hobject(mod.namespace_obj);
                        self.mark_hobject(mod.deferred_namespace_obj);
                        self.mark_hobject(mod.module_source_obj);
                        self.mark_hobject(mod.defer_pending_promise);
                        self.mark_hobject(mod.eval_promise);
                    }
                }
                self.gc_root_index++;
            case 19:
                Realm* realm = self.gc_root_realm_cursor;
                if (realm == null) { self.gc_root_stage++; continue; }
                if (realm != self.realm && !(realm == self.realms && self.realm == null)) {
                    if (self.gc_root_subindex == 0) {
                        self.mark_intrinsics(&realm.state);
                        self.mark_env_chain(realm.global_env);
                        self.mark_env_chain(realm.global_lex_env);
                        self.gc_root_subindex = 1;
                        continue;
                    }
                    uint i = self.gc_root_index++;
                    if (i < realm.state.promoted_builtin_capacity) {
                        self.mark_hobject(realm.state.promoted_builtins[i]);
                        continue;
                    }
                    i -= realm.state.promoted_builtin_capacity;
                    if (i < realm.state.checkpoint_count) {
                        self.mark_tval(&realm.state.checkpoint_entries[i].value);
                        continue;
                    }
                    i -= realm.state.checkpoint_count;
                    if (i < realm.state.module_cache_count) {
                        self.mark_realm_module(realm, i);
                        continue;
                    }
                }
                self.gc_root_realm_cursor = realm.next;
                self.gc_root_subindex = 0;
                self.gc_root_index = 0;
            default:
                return true;
        }
    }
    return self.gc_root_stage >= 20;
}

fn bool Heap.gc_prune_weak_step(&self, uint budget) {
    while (budget > 0 && self.gc_weak_func_index < self.compiled_func_count) {
        budget--;
        bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[self.gc_weak_func_index];
        if (cf == null || cf.var_ic_entries == null || self.gc_weak_entry_index >= cf.var_ic_count) {
            self.gc_weak_func_index++;
            self.gc_weak_entry_index = 0;
            continue;
        }
        hobject::VarICEntry* entries = (hobject::VarICEntry*)cf.var_ic_entries;
        hobject::VarICEntry* vie = &entries[self.gc_weak_entry_index++];
        if (vie.env == null && vie.bindings == null && vie.search_head == null) continue;
        bool survive = false;
        if (hobject::env_record_is_allocated(vie.env)
            && hobject::env_record_get_epoch(vie.env) == self.env_mark_epoch
            && hobject::env_record_is_allocated(vie.search_head)
            && hobject::env_record_get_epoch(vie.search_head) == self.env_mark_epoch) {
            HObject* b = (HObject*)vie.bindings;
            if (b != null && ((HeapHeader*)b).is_reachable()
                && hobject::env_record_bindings(vie.env) == b) survive = true;
        }
        if (!survive) hobject::var_ic_clear(vie);
    }
    return self.gc_weak_func_index >= self.compiled_func_count;
}
