module boomkat::heap;

import boomkat::hobject;
import boomkat::types;

// Range cursors store an owner and an index. Every slice reloads mutable
// backing storage; insertion barriers cover values moved behind the cursor.
fn bool Heap.gc_scan_object_step(&self, uint budget) {
    while (budget > 0) {
        HObject* obj = self.gc_scan_object;
        if (obj == null) {
            obj = self.gray_pop();
            if (obj == null && self.gc_remembered_cursor != null) obj = self.gc_take_remembered_owner();
            if (obj == null) return true;
            self.gc_scan_object = obj;
            self.gc_scan_stage = 0;
            self.gc_scan_index = 0;
        }
        budget--;
        switch (self.gc_scan_stage) {
            case 0:
                self.mark_hobject(obj.prototype);
                self.gc_scan_stage++;
            case 1:
                if (self.gc_scan_index < obj.prop_count) {
                    TVal value = obj.prop_values()[self.gc_scan_index++].get();
                    self.mark_tval(&value);
                } else {
                    self.gc_scan_index = 0;
                    self.gc_scan_stage++;
                }
            case 2:
                if (obj.array_part() != null && self.gc_scan_index < obj.array_size) {
                    TVal value = obj.array_part()[self.gc_scan_index++].get();
                    self.mark_tval(&value);
                } else {
                    self.gc_scan_index = 0;
                    self.gc_scan_stage++;
                }
            case 3:
                if ((obj.flags.obj_class == ObjClass.FUNCTION || obj.flags.obj_class == ObjClass.THREAD)
                    && !obj.flags.is_bound && !obj.flags.is_async_state
                    && (*obj.extra_ptr()).func.capture_refs != null
                    && (*obj.extra_ptr()).func.comp_func != null
                    && self.gc_scan_index < (*obj.extra_ptr()).func.comp_func.capture_count) {
                    CaptureRef* ref = &(*obj.extra_ptr()).func.capture_refs[self.gc_scan_index++];
                    if (ref.is_value) { self.mark_tval(&ref.value); }
                    else { self.mark_hobject(ref.owner); }
                } else { self.gc_scan_stage++; }
            default:
                self.gc_scan_object_fields(obj);
                if (self.gc_kind == GcKind.MINOR && obj.gc.old) {
                    ((HeapHeader*)obj).clear_reachable();
                } else {
                    obj.gc.remembered = false;
                }
                self.gc_scan_object = null;
        }
    }
    return self.gc_scan_object == null && self.gc_gray_head == null;
}

fn void Heap.gc_scan_object_fields(&self, HObject* obj) {
        // Fields that only some subtypes have.
        switch (obj.flags.obj_class) {
            case ObjClass.FUNCTION:
            case ObjClass.THREAD:
                // Bound functions leave var_env, lex_env, captured_this, and
                // captured_new_target unset, so only the bound_* fields matter.
                if (obj.flags.is_bound) {
                    self.mark_tval(&(*obj.extra_ptr()).func.bound.target);
                    self.mark_tval(&(*obj.extra_ptr()).func.bound.this_arg);
                    if ((*obj.extra_ptr()).func.bound.args != null) {
                        self.mark_hobject((*obj.extra_ptr()).func.bound.args);
                    }
                    break;
                }
                // The async/await resume and reject builtins keep a
                // GeneratorState* in var_env rather than an EnvRecord*. Walking
                // it as an EnvRecord would read gs.func, a CompiledFunction*,
                // through the bindings offset and mark a non-HObject pointer.
                // Marking the GeneratorState covers the real var_env and lex_env.
                if (obj.flags.is_async_state) {
                    GeneratorState* gs = (GeneratorState*)(*obj.extra_ptr()).func.var_env;
                    self.mark_generator_state(gs);
                    break;
                }
                // A closure's captured scope chain, in full: reading an outer
                // variable after a sweep that only rooted the innermost link
                // dereferences a recycled EnvRecord.bindings.
                self.mark_env_chain((void*)(*obj.extra_ptr()).func.var_env);
                self.mark_env_chain((void*)(*obj.extra_ptr()).func.lex_env);
                self.mark_tval(&(*obj.extra_ptr()).func.captured_this);
                if ((*obj.extra_ptr()).func.captured_new_target != null) {
                    self.mark_hobject((*obj.extra_ptr()).func.captured_new_target);
                }
                break;
            case ObjClass.GENERATOR:
                self.mark_env_chain((void*)(*obj.extra_ptr()).gen.var_env);
                self.mark_env_chain((void*)(*obj.extra_ptr()).gen.lex_env);
                // Mark GeneratorState fields for suspended generators
                GeneratorState* gs = (GeneratorState*)(*obj.extra_ptr()).gen.generator_data;
                self.mark_generator_state(gs);
                break;
            case ObjClass.PROXY:
                // Keep [[ProxyTarget]] and [[ProxyHandler]] alive.
                if ((*obj.extra_ptr()).proxy.target != null) {
                    self.mark_hobject((*obj.extra_ptr()).proxy.target);
                }
                if ((*obj.extra_ptr()).proxy.handler != null) {
                    self.mark_hobject((*obj.extra_ptr()).proxy.handler);
                }
                break;
            case ObjClass.PROMISE:
                // The settled value and the list of pending reaction records.
                // A reaction's link to the next one is a hidden TVal property
                // (BuiltinStr.REACTION_NEXT, written by
                // builtins::reaction_set_next). HeapHeader.next threads the
                // heap_allocated GC list instead, so walking it here would
                // follow unrelated objects.
                self.mark_tval(&(*obj.extra_ptr()).promise.result);
                self.mark_hobject((*obj.extra_ptr()).promise.reactions_head);
                self.mark_hobject((*obj.extra_ptr()).promise.reactions_tail);
                break;
            case ObjClass.ARRAYBUFFER:
                // Views chained off the buffer live as long as it does.
                self.mark_hobject((*obj.extra_ptr()).ab.views_head);
                break;
            case ObjClass.DATAVIEW:
            case ObjClass.INT8ARRAY:
            case ObjClass.UINT8ARRAY:
            case ObjClass.UINT8CLAMPEDARRAY:
            case ObjClass.INT16ARRAY:
            case ObjClass.UINT16ARRAY:
            case ObjClass.INT32ARRAY:
            case ObjClass.UINT32ARRAY:
            case ObjClass.FLOAT16ARRAY:
            case ObjClass.FLOAT32ARRAY:
            case ObjClass.FLOAT64ARRAY:
            case ObjClass.BIGINT64ARRAY:
            case ObjClass.BIGUINT64ARRAY:
                if ((*obj.extra_ptr()).view.buffer != null) {
                    self.mark_hobject((*obj.extra_ptr()).view.buffer);
                }
                self.mark_hobject((*obj.extra_ptr()).view.next_view);
                break;
            case ObjClass.BOOLEAN:
            case ObjClass.NUMBER:
            case ObjClass.STRING:
            case ObjClass.DATE:
                self.mark_tval(&(*obj.extra_ptr()).prim.primitive_value);
                break;
            case ObjClass.HOST:
                // Hand the payload to the class's own mark callback so values
                // it holds stay reachable. A class with no JS values in its
                // payload registers a null gc_mark and costs one branch.
                HostClassEntry* hc = self.host_class_at((*obj.extra_ptr()).host.class_id);
                if (hc != null && hc.gc_mark != null) {
                    HostClassMarkFn mark_fn = (HostClassMarkFn)hc.gc_mark;
                    mark_fn((*obj.extra_ptr()).host.payload, self, hc.udata);
                }
                break;
            case ObjClass.ARRAY_ITERATOR:
            case ObjClass.MAP_ITERATOR:
            case ObjClass.SET_ITERATOR:
                // extra.iter.target holds the iterated object for these three
                // classes.
                if ((*obj.extra_ptr()).iter.target != null) {
                    self.mark_hobject((*obj.extra_ptr()).iter.target);
                }
                break;
            case ObjClass.STRING_ITERATOR:
                $if $feat(GC_VERIFY):
                    self.verify_string_owner((*obj.extra_ptr()).str_iter.string.borrow());
                $endif
                break;
            case ObjClass.REGEXP_STRING_ITERATOR:
                $if $feat(GC_VERIFY):
                    self.verify_string_owner((*obj.extra_ptr()).regexp_iter.string.borrow());
                $endif
                if ((*obj.extra_ptr()).regexp_iter.regexp != null) {
                    self.mark_hobject((*obj.extra_ptr()).regexp_iter.regexp);
                }
                break;
            case ObjClass.WRAP_FOR_VALID_ITERATOR:
                if ((*obj.extra_ptr()).wrap_iter.iterated != null) {
                    self.mark_hobject((*obj.extra_ptr()).wrap_iter.iterated);
                }
                self.mark_tval(&(*obj.extra_ptr()).wrap_iter.next_method);
                break;
            case ObjClass.ITERATOR_HELPER:
                if ((*obj.extra_ptr()).iter_helper.underlying != null) {
                    self.mark_hobject((*obj.extra_ptr()).iter_helper.underlying);
                }
                self.mark_tval(&(*obj.extra_ptr()).iter_helper.next_method);
                self.mark_tval(&(*obj.extra_ptr()).iter_helper.callback);
                if ((*obj.extra_ptr()).iter_helper.inner_iter != null) {
                    self.mark_hobject((*obj.extra_ptr()).iter_helper.inner_iter);
                }
                self.mark_tval(&(*obj.extra_ptr()).iter_helper.inner_next);
                if ((*obj.extra_ptr()).iter_helper.buffer != null) {
                    self.mark_hobject((*obj.extra_ptr()).iter_helper.buffer);
                }
                break;
            case ObjClass.GETTER_SETTER:
                self.mark_tval(&(*obj.extra_ptr()).gs.getter);
                self.mark_tval(&(*obj.extra_ptr()).gs.setter);
                break;
            case ObjClass.ERROR:
                self.mark_tval(&(*obj.extra_ptr()).err.captured_stack);
                break;
            case ObjClass.TEMPORAL_CALENDAR:
            case ObjClass.TEMPORAL_DURATION:
            case ObjClass.TEMPORAL_PLAIN_DATE:
            case ObjClass.TEMPORAL_PLAIN_TIME:
            case ObjClass.TEMPORAL_PLAIN_DATETIME:
            case ObjClass.TEMPORAL_PLAIN_YEARMONTH:
            case ObjClass.TEMPORAL_PLAIN_MONTHDAY:
            case ObjClass.TEMPORAL_INSTANT:
            case ObjClass.TEMPORAL_TIMEZONE:
            case ObjClass.TEMPORAL_ZONEDDATETIME:
                self.mark_temporal(&(*obj.extra_ptr()).temporal, obj.flags.obj_class);
                break;
            default:
                break;
        }
}
