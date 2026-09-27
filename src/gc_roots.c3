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
            self.mark_hobject((HObject*)entries[ic_index].proto);
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
    self.mark_hobject(self.err_proto);
    self.mark_hobject(self.type_err_proto);
    self.mark_hobject(self.range_err_proto);
    self.mark_hobject(self.ref_err_proto);
    self.mark_hobject(self.syntax_err_proto);
    self.mark_hobject(self.eval_err_proto);
    self.mark_hobject(self.uri_err_proto);
    self.mark_hobject(self.aggregate_err_proto);
    self.mark_hobject(self.object_proto);
    self.mark_hobject(self.array_proto);
    self.mark_hobject(self.function_proto);
    self.mark_hobject(self.string_proto);
    self.mark_hobject(self.number_proto);
    self.mark_hobject(self.bool_proto);
    self.mark_hobject(self.date_proto);
    self.mark_hobject(self.regexp_proto);
    self.mark_hobject(self.map_proto);
    self.mark_hobject(self.set_proto);
    self.mark_hobject(self.weakmap_proto);
    self.mark_hobject(self.weakset_proto);
    self.mark_hobject(self.weakref_proto);
    self.mark_hobject(self.finalization_registry_proto);
    self.mark_hobject(self.symbol_proto);
    self.mark_hobject(self.bigint_proto);
    self.mark_hobject(self.promise_proto);
    self.mark_hobject(self.promise_ctor);
    self.mark_hobject(self.function_ctor);
    self.mark_hobject(self.generator_proto);
    self.mark_hobject(self.generator_func_proto);
    self.mark_hobject(self.async_func_proto);
    self.mark_hobject(self.abstract_module_source_ctor);
    self.mark_hobject(self.abstract_module_source_proto);
    self.mark_hobject(self.module_source_proto);
    self.mark_hobject(self.iterator_proto);
    self.mark_hobject(self.iterator_ctor);
    self.mark_hobject(self.iterator_helper_proto);
    self.mark_hobject(self.wrap_for_valid_iterator_proto);
    self.mark_hobject(self.async_from_sync_iter_proto);
    self.mark_hobject(self.async_iterator_proto);
    self.mark_hobject(self.async_generator_proto);
    self.mark_hobject(self.async_generator_func_proto);
    self.mark_hobject(self.array_iterator_proto);
    self.mark_hobject(self.map_iterator_proto);
    self.mark_hobject(self.set_iterator_proto);
    self.mark_hobject(self.string_iterator_proto);
    self.mark_hobject(self.regexp_string_iterator_proto);
    self.mark_hobject(self.typedarray_proto);
    self.mark_hobject(self.typedarray_intrinsic);
    self.mark_hobject(self.uint8array_proto);
    self.mark_hobject(self.arraybuffer_proto);
    self.mark_hobject(self.sharedarraybuffer_proto);
    self.mark_hobject(self.dataview_proto);
    self.mark_hobject(self.temporal_iso_calendar);
    self.mark_hobject(self.temporal_duration_proto);
    self.mark_hobject(self.temporal_plain_date_proto);
    self.mark_hobject(self.temporal_plain_time_proto);
    self.mark_hobject(self.temporal_plain_datetime_proto);
    self.mark_hobject(self.temporal_plain_yearmonth_proto);
    self.mark_hobject(self.temporal_plain_monthday_proto);
    self.mark_hobject(self.temporal_instant_proto);
    self.mark_hobject(self.temporal_zoneddatetime_proto);
}

// Each stage keeps an index rather than a pointer into a resizable array.
// A root published after its stage passed must use the root insertion barrier.
fn bool Heap.gc_scan_roots_step(&self, uint budget) {
    while (budget > 0) {
        budget--;
        switch (self.gc_root_stage) {
            case 0:
                self.mark_fixed_roots();
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
                    if (hdr.is_object()) { self.mark_hobject((HObject*)hdr); }
                    else { hdr.set_reachable(); }
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
                if (self.async_waiters[self.gc_root_index].active) {
                    self.mark_hobject(self.async_waiters[self.gc_root_index].buffer);
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
                if (self.gc_root_index >= self.host_scope_depth) {
                    self.gc_root_index = 0;
                    self.gc_root_stage++;
                    continue;
                }
                self.mark_hobject(self.host_scopes[self.gc_root_index++].values);
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
            default:
                return true;
        }
    }
    return self.gc_root_stage >= 19;
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
        if (!survive) hobject::var_ic_clear(vie, self);
    }
    return self.gc_weak_func_index >= self.compiled_func_count;
}
