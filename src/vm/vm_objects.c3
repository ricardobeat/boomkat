module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import std::io;
import duktape::re_bindings;
import std::math;

// ============================================================================
// vm_objects — object/array creation, spreads, iterators
// ============================================================================

/// Result of copy_data_property: whether the caller's enumeration loop
/// should keep going, and (independently) whether a hard VM_ERROR occurred.
struct CopyPropResult {
    bool cont;       // false: getter threw (already cleared) — stop enumerating, return success
    bool vm_error;   // true: put_prop failed — caller must propagate VM_ERROR~
}

/// Copy one enumerable own property (by prop-table index `i`, key `key`)
/// from `source` to `target`, invoking the getter for accessor properties
/// ([[Get]] semantics). Mirrors the original single-pass OBJSPRD loop's
/// getter-throw handling: on throw, has_error is cleared and enumeration
/// stops (matching a pre-existing, out-of-scope gap where the throw isn't
/// re-propagated — this refactor preserves that behavior rather than fixing
/// or worsening it). Shared by OBJSPRD's three key-ordering passes.
fn CopyPropResult copy_data_property(Vm* vm, HObject* source, HObject* target, uint i, void* key) {
    hobject::PropFlags flags = source.get_prop_flags(i);
    TVal val;
    if (flags.is_accessor) {
        TVal gs_slot = source.prop_values()[i];
        TVal getter = hobject::hobject_access_getter(gs_slot);
        if (getter.is_undefined() || getter.is_null()) return { true, false };
        if (vm.heap.call_fn == null) return { true, false };
        TVal this_tv;
        this_tv.set_object(source);
        val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
        if (vm.heap.has_error) {
            vm.heap.has_error = false;
            return { false, false };
        }
    } else {
        val = source.prop_values()[i];
    }
    if (!target.put_prop(key, val, hobject::PROP_FLAGS_WEC)) {
        return { false, true };
    }
    return { true, false };
}

/// Sub-dispatch for NEWOBJ, NEWARR, NEWREGEXP, SETALEN, ARRSPRD, OBJSPRD, SPREAD_ARG opcodes.
fn TVal? dispatch_objects(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.NEWOBJ: {
            HObject*? new_obj = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try o = new_obj) {
                o.prototype = vm.heap.object_proto;
                ra.set_object(o);
                track_heap_store(ds.act, ra, (uint)insn.a);
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.NEWARR: {
            HObject*? new_arr = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try a = new_arr) {
                a.prototype = vm.heap.array_proto;
                ra.set_object(a);
                track_heap_store(ds.act, ra, (uint)insn.a);
                if (insn.a == 251) {
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.NEWREGEXP: {
            // A = dest register, BC = constant pool index of "/pattern/flags" string
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal raw_tv = ds.constants[bc];
                if (raw_tv.is_string()) {
                    HString* raw_hs = (HString*)raw_tv.get_heapptr();
                    char[] raw = raw_hs.get_data();
                    usz len = raw.len;

                    // Parse "/pattern/flags" by finding the closing '/'
                    // Flags are only letters, so scan backwards past them
                    usz end_slash = len - 1;
                    while (end_slash > 0 &&
                           ((raw[end_slash] >= 'a' && raw[end_slash] <= 'z') ||
                            (raw[end_slash] >= 'A' && raw[end_slash] <= 'Z'))) {
                        end_slash--;
                    }

                    if (end_slash > 0 && raw[0] == '/' && raw[end_slash] == '/') {
                        char[] pattern_data = raw[1..end_slash - 1];
                        char[] flag_data = {};
                        if (end_slash + 1 < len) {
                            flag_data = raw[end_slash + 1..len - 1];
                        }

                        // Convert JS flags to libregexp flag bits
                        int flags = 0;
                        int js_flags = 0;  // 1=g, 2=i, 4=m, 8=s, 16=u, 32=y, 64=d, 128=v
                        for (usz i = 0; i < flag_data.len; i++) {
                            char f = flag_data[i];
                            if (f == 'g') {
                                js_flags |= 1;
                            } else if (f == 'i') {
                                flags |= re_bindings::RE_FLAG_IGNORECASE;
                                js_flags |= 2;
                            } else if (f == 'm') {
                                flags |= re_bindings::RE_FLAG_MULTILINE;
                                js_flags |= 4;
                            } else if (f == 's') {
                                flags |= re_bindings::RE_FLAG_DOTALL;
                                js_flags |= 8;
                            } else if (f == 'u') {
                                flags |= re_bindings::RE_FLAG_UNICODE;
                                js_flags |= 16;
                            } else if (f == 'y') {
                                flags |= re_bindings::RE_FLAG_STICKY;
                                js_flags |= 32;
                            } else if (f == 'd') {
                                flags |= re_bindings::RE_FLAG_INDICES;
                                js_flags |= 64;
                            } else if (f == 'v') {
                                flags |= re_bindings::RE_FLAG_UNICODE_SETS;
                                js_flags |= 128;
                            }
                        }

                        // Compile the regexp.
                        // Allocate a heap buffer so patterns of any length are
                        // supported (the old 256-byte stack buffer truncated
                        // patterns longer than 255 chars).
                        usz plen = pattern_data.len;
                        char* pattern_buf_heap = (char*)alloc::malloc_try(mem, (sz)(plen + 1)) ?? null;
                        if (pattern_buf_heap != null) {
                            mem::copy(pattern_buf_heap, pattern_data.ptr, (sz)(plen));
                            pattern_buf_heap[plen] = 0;
                        }
                        char[128] error_buf;
                        void* compiled = (pattern_buf_heap != null)
                            ? re_bindings::re_compile(pattern_buf_heap, plen, flags, &error_buf, 128)
                            : null;
                        if (pattern_buf_heap != null) mem::free(pattern_buf_heap);

                        if (compiled != null) {
                            HObject*? obj_raw = vm.heap.alloc_object(hobject::ObjClass.REGEXP);
                            if (try obj = obj_raw) {
                                obj.prototype = vm.heap.regexp_proto;
                                (*obj.extra_ptr()).regexp.regexp_data = compiled;
                                (*obj.extra_ptr()).regexp.flags = js_flags;
                                // Store pattern string as primitive_value
                                HString* pattern_hs = intern_string(vm, pattern_data);
                                (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);
                                // Set lastIndex (ES5 §15.10.7) — only own data property
                                HString* lastindex_key = intern_string(vm, "lastIndex");
                                TVal lastindex_tv;
                                lastindex_tv.set_fastint(0);
                                obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WENC);
                                ra.set_object(obj);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            } else {
                                // If alloc failed, free the compiled regexp
                                re_bindings::re_free(compiled);
                                ra.set_undefined();
                            }
                        } else {
                            // re_compile failed — still create an empty regexp object
                            // so typeof works correctly
                            HObject*? obj_raw = vm.heap.alloc_object(hobject::ObjClass.REGEXP);
                            if (try obj = obj_raw) {
                                obj.prototype = vm.heap.regexp_proto;
                                (*obj.extra_ptr()).regexp.regexp_data = null;
                                (*obj.extra_ptr()).regexp.flags = js_flags;
                                HString* pattern_hs = intern_string(vm, pattern_data);
                                (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);
                                ra.set_object(obj);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.SETALEN: {
            // A = array register, BC = element count (high-water mark)
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                uint count = insn.get_bc();
                *hobj.array_len_ptr() = count;
                HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_val;
                len_val.set_fastint((long)count);
                hobj.put_prop(len_str, len_val, hobject::PROP_FLAGS_WENC);
            }
            return (TVal){};
        }

        case Opcode.FREEZEOBJ: {
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                hobj.freeze();
            }
            return (TVal){};
        }

        case Opcode.ARRSPRD: {
            // A = target array reg, B = index reg (in/out), C = source reg
            // Uses ES6 iterator protocol (§12.2.5.3 ArrayAccumulation SpreadElement)
            if (!ra.is_object() || ra.get_heapptr() == null) break;
            HObject* target = (HObject*)ra.get_heapptr();
            TVal src_tv = *rc;

            // null/undefined → TypeError: not iterable
            if (src_tv.is_null() || src_tv.is_undefined()) {
                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Cannot spread %s",
                                          (src_tv.is_null() ? "null" : "undefined"),
                                          ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // Get current target index
            long idx = 0;
            if (rb.is_fastint()) {
                idx = rb.get_fastint();
            } else if (rb.is_number()) {
                idx = (long)rb.get_number();
            }

            // --- Iterator protocol ---
            HString* iter_sym = vm.heap.iterator_symbol;
            TVal iter_method;
            bool has_method = false;
            if (iter_sym != null) {
                TVal? method_opt;
                if (src_tv.is_object() && src_tv.get_heapptr() != null) {
                    method_opt = ((HObject*)src_tv.get_heapptr()).get_prop_proto(iter_sym);
                } else if (src_tv.is_string() && vm.heap.string_proto != null) {
                    method_opt = vm.heap.string_proto.get_prop_proto(iter_sym);
                }
                if (try m = method_opt) {
                    iter_method = m;
                    bool callable = iter_method.is_lightfunc() ||
                        (iter_method.is_object() && iter_method.get_heapptr() != null &&
                         ((HObject*)iter_method.get_heapptr()).is_callable());
                    has_method = callable;
                }
            }
            if (!has_method) {
                HString* type_str = typeof_string(vm, &src_tv);
                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not iterable", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // Call @@iterator() with this = source
            TVal iterator = vm.heap.call_fn(vm, iter_method, null, 0, src_tv);
            if (vm.has_error) {
                TVal err_itr = vm.return_val;
                vm.has_error = false;
                if (!vm_throw_value(vm, err_itr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &err_itr);
                }
                return (TVal){};
            }
            if (!iterator.is_object() || iterator.get_heapptr() == null) { break; }

            // Loop: next() → {value, done}
            HString* next_key = intern_string(vm, "next");
            HString* done_key = intern_string(vm, "done");
            HString* value_key = intern_string(vm, "value");
            uint k = 0;
            while (vm.heap.call_fn != null) {
                HObject* iter_obj = (HObject*)iterator.get_heapptr();
                TVal? next_opt = iter_obj.get_prop_proto(next_key);
                TVal next_method;
                if (try nm = next_opt) { next_method = nm; } else { break; }
                bool callable = next_method.is_lightfunc() ||
                    (next_method.is_object() && next_method.get_heapptr() != null &&
                     ((HObject*)next_method.get_heapptr()).is_callable());
                if (!callable) { break; }

                TVal result = vm.heap.call_fn(vm, next_method, null, 0, iterator);
                if (vm.has_error) {
                    TVal err_nxt = vm.return_val;
                    vm.has_error = false;
                    rb.set_fastint(idx + (long)k);
                    if (!vm_throw_value(vm, err_nxt, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &err_nxt);
                    }
                    return (TVal){};
                }
                if (!result.is_object() || result.get_heapptr() == null) { break; }

                HObject* result_obj = (HObject*)result.get_heapptr();

                // ES IteratorComplete: Get(result, "done") — may invoke a getter that throws
                hobject::PropLookupResult done_res = result_obj.get_prop_or_accessor_proto(done_key, true);
                TVal done_val;
                if (done_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                    TVal acc_fn = done_res.acc.accessor_fn;
                    if (!acc_fn.is_undefined() && !acc_fn.is_null() && vm.heap.call_fn != null) {
                        TVal done_this;
                        done_this.set_object(result_obj);
                        done_val = vm.heap.call_fn(vm, acc_fn, null, 0, done_this);
                        if (vm.has_error) {
                            TVal err_done = vm.return_val;
                            vm.has_error = false;
                            rb.set_fastint(idx + (long)k);
                            if (!vm_throw_value(vm, err_done, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return vm_uncaught_error(vm, &err_done);
                            }
                            return (TVal){};
                        }
                    } else {
                        done_val.set_undefined();
                    }
                } else if (done_res.kind == hobject::PropLookupKind.PROP_DATA) {
                    done_val = done_res.data_val;
                } else {
                    done_val.set_undefined();
                }
                bool done = builtins::builtin_to_boolean(&done_val);
                if (done) { break; }

                // ES IteratorValue: Get(result, "value") — may invoke a getter that throws
                hobject::PropLookupResult value_res = result_obj.get_prop_or_accessor_proto(value_key, true);
                TVal value_val;
                bool value_found = true;
                if (value_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                    TVal acc_fn = value_res.acc.accessor_fn;
                    if (!acc_fn.is_undefined() && !acc_fn.is_null() && vm.heap.call_fn != null) {
                        TVal value_this;
                        value_this.set_object(result_obj);
                        value_val = vm.heap.call_fn(vm, acc_fn, null, 0, value_this);
                        if (vm.has_error) {
                            TVal err_val = vm.return_val;
                            vm.has_error = false;
                            rb.set_fastint(idx + (long)k);
                            if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                            return (TVal){};
                        }
                    } else {
                        value_val.set_undefined();
                    }
                } else if (value_res.kind == hobject::PropLookupKind.PROP_DATA) {
                    value_val = value_res.data_val;
                } else {
                    value_val.set_undefined();
                    value_found = false;
                }
                if (value_found) {
                    HString* pk = vm.heap.int_to_hstring(idx + (long)k);
                    if (pk != null) {
                        target.put_prop(pk, value_val, hobject::PROP_FLAGS_WEC);
                    }
                    k++;
                } else { break; }
            }
            // Update index register with elements actually inserted
            rb.set_fastint(idx + (long)k);
            return (TVal){};
        }

        case Opcode.OBJSPRD: {
            // A = target_obj_reg, B = 0 (unused), C = source_reg
            // Copy all own enumerable properties from source to target,
            // matching Object.assign semantics (§19.1.2.2).
            if (!ra.is_object() || ra.get_heapptr() == null) break;
            HObject* target = (HObject*)ra.get_heapptr();
            TVal src_tv = *rc;

            // null/undefined → no-op (Object.assign step 2)
            if (src_tv.is_null() || src_tv.is_undefined()) break;

            // Only objects have own enumerable properties; primitives are no-ops
            if (!src_tv.is_object() || src_tv.get_heapptr() == null) break;
            HObject* source = (HObject*)src_tv.get_heapptr();

            // Proxy source: CopyDataProperties via MOP (ES2022 §19.1.2.1, §10.5).
            // [[OwnPropertyKeys]] → [[GetOwnProperty]] → [[Get]] for enumerable keys.
            if (source.flags.exotic_proxyobj) {
                HObject* karr;
                if (!builtins::proxy_mop_own_keys(vm, vm.heap, source, &karr)) {
                    TVal proxy_err = vm.heap.error_value;
                    vm.heap.has_error = false;
                    if (!vm_throw_value(vm, proxy_err, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &proxy_err);
                    }
                    return (TVal){};
                }
                for (uint pi = 0; pi < karr.array_used; pi++) {
                    TVal pel = karr.array_part()[pi];
                    if (!pel.is_string()) continue;
                    HString* pk = (HString*)pel.get_heapptr();
                    builtins::ProxyDesc pd;
                    if (!builtins::proxy_mop_get_own(vm, vm.heap, source, pk, &pd)) {
                        TVal e2 = vm.heap.error_value;
                        vm.heap.has_error = false;
                        if (!vm_throw_value(vm, e2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &e2);
                        }
                        return (TVal){};
                    }
                    if (!pd.found || !pd.enumerable) continue;
                    TVal recv; recv.set_object(source);
                    TVal pval;
                    if (!builtins::proxy_mop_get(vm, vm.heap, source, pk, recv, &pval)) {
                        TVal e3 = vm.heap.error_value;
                        vm.heap.has_error = false;
                        if (!vm_throw_value(vm, e3, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &e3);
                        }
                        return (TVal){};
                    }
                    if (!target.put_prop((void*)pk, pval, hobject::PROP_FLAGS_WEC)) {
                        return VM_ERROR~;
                    }
                }
                break;
            }

            // Copy enumerable own dense array indices (integer-keyed properties)
            if (source.array_part() != null) {
                char[12] digit_buf;
                for (uint i = 0; i < source.array_size; i++) {
                    if (!source.array_part()[i].is_undefined()) {
                        int dlen = (int)(io::bprintf(&digit_buf, "%d", i) ?? digit_buf[:0]).len;
                        if (dlen > 0) {
                            HString* key = intern_string(vm, digit_buf[:(uint)dlen]);
                            if (key != null) {
                                TVal val = source.array_part()[i];
                                if (!target.put_prop((void*)key, val, hobject::PROP_FLAGS_WEC)) {
                                    return VM_ERROR~;
                                }
                            }
                        }
                    }
                }
            }

            // STRING exotic: enumerate character indices via lazy access
            if (source.flags.exotic_stringobj) {
                HString* prim = (HString*)(*source.extra_ptr()).prim.primitive_value.get_heapptr();
                if (prim != null) {
                    for (uint ci = 0; ci < prim.char_length(); ci++) {
                        HString* ik = vm.heap.int_to_hstring((long)ci);
                        if (ik == null) continue;
                        uint cp = prim.char_at(ci);
                        char[4] cbuf;
                        uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
                        HString* ch_str = intern_string(vm, cbuf[:cblen]);
                        if (ch_str != null) {
                            TVal ch_tv; ch_tv.set_string(ch_str);
                            if (!target.put_prop((void*)ik, ch_tv, hobject::PROP_FLAGS_WEC)) {
                                return VM_ERROR~;
                            }
                        }
                    }
                }
            }

            // Copy own named properties (enumerable only), in spec order
            // (ES2015 §9.1.11.1 OrdinaryOwnPropertyKeys / §7.3.23
            // CopyDataProperties): named-table array-index keys ascending,
            // then other String keys in insertion order, then Symbol keys
            // in insertion order. A single raw insertion-order pass would
            // put a `defineProperty`-added index key wherever it happened
            // to be declared, rather than sorted before the string keys.

            // Pass 1: named-table arridx keys, ascending numeric order (not
            // table-storage order) — sort a small (index-value, table-index)
            // list first.
            {
                uint arridx_count = 0;
                for (uint i = 0; i < source.prop_count; i++) {
                    void* key = source.prop_key_at(i);
                    if (key != null && ((HString*)key).is_arridx() && source.get_prop_flags(i).enumerable) {
                        arridx_count++;
                    }
                }
                if (arridx_count > 0) {
                    usz buf_size = (usz)arridx_count * 2 * 4;
                    uint* sort_buf = (uint*)vm.heap.alloc_func(vm.heap.heap_udata, buf_size);
                    if (sort_buf != null) {
                        uint p = 0;
                        for (uint i = 0; i < source.prop_count; i++) {
                            void* key = source.prop_key_at(i);
                            if (key != null && ((HString*)key).is_arridx() && source.get_prop_flags(i).enumerable) {
                                sort_buf[p * 2]     = ((HString*)key).array_index();
                                sort_buf[p * 2 + 1] = i;
                                p++;
                            }
                        }
                        // Insertion sort by index value (arridx_count is typically small).
                        for (uint a = 1; a < arridx_count; a++) {
                            uint kv = sort_buf[a * 2];
                            uint iv = sort_buf[a * 2 + 1];
                            uint b = a;
                            while (b > 0 && sort_buf[(b - 1) * 2] > kv) {
                                sort_buf[b * 2]     = sort_buf[(b - 1) * 2];
                                sort_buf[b * 2 + 1] = sort_buf[(b - 1) * 2 + 1];
                                b--;
                            }
                            sort_buf[b * 2]     = kv;
                            sort_buf[b * 2 + 1] = iv;
                        }
                        for (uint a = 0; a < arridx_count; a++) {
                            uint i = sort_buf[a * 2 + 1];
                            CopyPropResult r = copy_data_property(vm, source, target, i, source.prop_key_at(i));
                            if (r.vm_error) { vm.heap.free_func(vm.heap.heap_udata, sort_buf); return VM_ERROR~; }
                            if (!r.cont) { vm.heap.free_func(vm.heap.heap_udata, sort_buf); return (TVal){}; }
                        }
                        vm.heap.free_func(vm.heap.heap_udata, sort_buf);
                    }
                }
            }
            // Pass 2: other String keys, insertion (table) order.
            for (uint i = 0; i < source.prop_count; i++) {
                void* key = source.prop_key_at(i);
                if (key == null || !source.get_prop_flags(i).enumerable) continue;
                HString* khs = (HString*)key;
                if (khs.is_arridx() || khs.is_symbol()) continue;
                CopyPropResult r = copy_data_property(vm, source, target, i, key);
                if (r.vm_error) return VM_ERROR~;
                if (!r.cont) return (TVal){};
            }
            // Pass 3: Symbol keys, insertion (table) order.
            for (uint i = 0; i < source.prop_count; i++) {
                void* key = source.prop_key_at(i);
                if (key == null || !source.get_prop_flags(i).enumerable) continue;
                if (!((HString*)key).is_symbol()) continue;
                CopyPropResult r = copy_data_property(vm, source, target, i, key);
                if (r.vm_error) return VM_ERROR~;
                if (!r.cont) return (TVal){};
            }
            return (TVal){};
        }

        case Opcode.SPREAD_ARG: {
            // A = dest start reg, B = count out reg, C = source reg
            // Uses ES6 iterator protocol (§12.3.5.1 ArgumentListEvaluation SpreadElement)
            TVal src_tv = *rc;

            // null/undefined → TypeError
            if (src_tv.is_null() || src_tv.is_undefined()) {
                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Cannot spread %s",
                                          (src_tv.is_null() ? "null" : "undefined"),
                                          ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // --- Iterator protocol ---
            // GetMethod(obj, @@iterator) (§7.3.11): must invoke an accessor
            // getter if @@iterator is defined as one, and propagate any throw
            // from that getter instead of misreporting "not iterable".
            HString* iter_sym = vm.heap.iterator_symbol;
            TVal iter_method;
            bool has_method = false;
            if (iter_sym != null) {
                HObject* iter_lookup_obj = null;
                if (src_tv.is_object() && src_tv.get_heapptr() != null) {
                    iter_lookup_obj = (HObject*)src_tv.get_heapptr();
                } else if (src_tv.is_string() && vm.heap.string_proto != null) {
                    iter_lookup_obj = vm.heap.string_proto;
                }
                if (iter_lookup_obj != null) {
                    hobject::PropLookupResult im_res = iter_lookup_obj.get_prop_or_accessor_proto((void*)iter_sym, true);
                    if (im_res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                        iter_method = vm.heap.call_fn(vm, im_res.acc.accessor_fn, null, 0, src_tv);
                        if (vm.has_error) {
                            TVal err_im = vm.return_val;
                            vm.has_error = false;
                            if (!vm_throw_value(vm, err_im, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return vm_uncaught_error(vm, &err_im);
                            }
                            return (TVal){};
                        }
                        // call_fn may have invoked user JS, reallocating the
                        // register file — re-derive `rc` before reusing it.
                        rc = ds.regs_base + (uint)insn.c;
                    } else if (im_res.kind == hobject::PropLookupKind.PROP_DATA) {
                        iter_method = im_res.data_val;
                    } else {
                        iter_method.set_undefined();
                    }
                    bool callable = iter_method.is_lightfunc() ||
                        (iter_method.is_object() && iter_method.get_heapptr() != null &&
                         ((HObject*)iter_method.get_heapptr()).is_callable());
                    has_method = callable;
                }
            }
            if (!has_method) {
                HString* type_str = typeof_string(vm, &src_tv);
                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not iterable", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // Call @@iterator() with this = source
            TVal iterator = vm.heap.call_fn(vm, iter_method, null, 0, src_tv);
            if (vm.has_error) {
                TVal err_itr2 = vm.return_val;
                vm.has_error = false;
                if (!vm_throw_value(vm, err_itr2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &err_itr2);
                }
                return (TVal){};
            }
            if (!iterator.is_object() || iterator.get_heapptr() == null) {
                // GetIterator (§7.4.1) step 3: a non-object iterator result is a TypeError.
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Result of the Symbol.iterator method is not an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // A = first_arg base reg, B = running-total reg (in/out). The spread
            // is written starting at first_arg + <current running total>, so
            // multiple spreads (and interleaved args via PUTARG) stack in order.
            uint first_arg_reg = insn.a;
            uint count_reg = insn.b;
            TVal* base_count_slot = ds.regs_base + count_reg;
            uint base_off = base_count_slot.is_fastint()
                ? (uint)base_count_slot.get_fastint()
                : (base_count_slot.is_number() ? (uint)base_count_slot.get_number() : 0);
            uint dest_start = first_arg_reg + base_off;

            // Loop: next() → {value, done}
            HString* next_key = intern_string(vm, "next");
            HString* done_key = intern_string(vm, "done");
            HString* value_key = intern_string(vm, "value");
            uint k = 0;
            while (vm.heap.call_fn != null) {
                HObject* iter_obj = (HObject*)iterator.get_heapptr();
                TVal? next_opt = iter_obj.get_prop_proto(next_key);
                TVal next_method;
                if (try nm = next_opt) { next_method = nm; } else { break; }
                bool callable = next_method.is_lightfunc() ||
                    (next_method.is_object() && next_method.get_heapptr() != null &&
                     ((HObject*)next_method.get_heapptr()).is_callable());
                if (!callable) { break; }

                TVal result = vm.heap.call_fn(vm, next_method, null, 0, iterator);
                if (vm.has_error) {
                    TVal err_nxt2 = vm.return_val;
                    vm.has_error = false;
                    TVal* count_slot2 = ds.regs_base + count_reg;
                    count_slot2.set_fastint((long)(base_off + k));
                    if (!vm_throw_value(vm, err_nxt2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &err_nxt2);
                    }
                    return (TVal){};
                }
                if (!result.is_object() || result.get_heapptr() == null) { break; }

                HObject* result_obj = (HObject*)result.get_heapptr();

                // ES IteratorComplete: Get(result, "done") — may invoke a getter that throws
                hobject::PropLookupResult done_res2 = result_obj.get_prop_or_accessor_proto(done_key, true);
                TVal done_val2;
                if (done_res2.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                    TVal acc_fn2 = done_res2.acc.accessor_fn;
                    if (!acc_fn2.is_undefined() && !acc_fn2.is_null() && vm.heap.call_fn != null) {
                        TVal done_this2;
                        done_this2.set_object(result_obj);
                        done_val2 = vm.heap.call_fn(vm, acc_fn2, null, 0, done_this2);
                        if (vm.has_error) {
                            TVal err_done2 = vm.return_val;
                            vm.has_error = false;
                            TVal* count_slot3 = ds.regs_base + count_reg;
                            count_slot3.set_fastint((long)(base_off + k));
                            if (!vm_throw_value(vm, err_done2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return vm_uncaught_error(vm, &err_done2);
                            }
                            return (TVal){};
                        }
                    } else {
                        done_val2.set_undefined();
                    }
                } else if (done_res2.kind == hobject::PropLookupKind.PROP_DATA) {
                    done_val2 = done_res2.data_val;
                } else {
                    done_val2.set_undefined();
                }
                bool done = builtins::builtin_to_boolean(&done_val2);
                if (done) { break; }

                // ES IteratorValue: Get(result, "value") — may invoke a getter that throws
                hobject::PropLookupResult value_res2 = result_obj.get_prop_or_accessor_proto(value_key, true);
                TVal value_val2;
                bool value_found2 = true;
                if (value_res2.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                    TVal acc_fn2 = value_res2.acc.accessor_fn;
                    if (!acc_fn2.is_undefined() && !acc_fn2.is_null() && vm.heap.call_fn != null) {
                        TVal value_this2;
                        value_this2.set_object(result_obj);
                        value_val2 = vm.heap.call_fn(vm, acc_fn2, null, 0, value_this2);
                        if (vm.has_error) {
                            TVal err_val2 = vm.return_val;
                            vm.has_error = false;
                            TVal* count_slot4 = ds.regs_base + count_reg;
                            count_slot4.set_fastint((long)(base_off + k));
                            if (!vm_throw_value(vm, err_val2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return vm_uncaught_error(vm, &err_val2);
                            }
                            return (TVal){};
                        }
                    } else {
                        value_val2.set_undefined();
                    }
                } else if (value_res2.kind == hobject::PropLookupKind.PROP_DATA) {
                    value_val2 = value_res2.data_val;
                } else {
                    value_val2.set_undefined();
                    value_found2 = false;
                }
                if (value_found2) {
                    TVal* dest_slot = ds.regs_base + dest_start + k;
                    *dest_slot = value_val2;
                    k++;
                } else { break; }
            }

            // Store count in output register
            TVal* count_slot = ds.regs_base + count_reg;
            count_slot.set_fastint((long)(base_off + k));
            return (TVal){};
        }

        case Opcode.FWD_ARGS: {
            // A = dest start reg, B = count out reg, C = source reg (array)
            // Like SPREAD_ARG but directly reads array elements by index
            // without calling @@iterator. Used by the default derived
            // constructor to forward arguments.
            TVal src_tv = *rc;
            uint first_arg_reg = insn.a;
            uint count_reg = insn.b;

            // null/undefined → 0 args
            if (src_tv.is_null() || src_tv.is_undefined()) {
                TVal* count_slot = ds.regs_base + count_reg;
                count_slot.set_fastint(0);
                return (TVal){};
            }

            // Source must be an object (Array from rest parameter)
            if (!src_tv.is_object() || src_tv.get_heapptr() == null) {
                TVal* count_slot = ds.regs_base + count_reg;
                count_slot.set_fastint(0);
                return (TVal){};
            }
            HObject* src_obj = (HObject*)src_tv.get_heapptr();

            // Get the array length
            uint len = 0;
            if (src_obj.get_class() == hobject::ObjClass.ARRAY) {
                len = *src_obj.array_len_ptr();
            } else {
                // Fallback: use "length" property
                HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                if (length_key != null) {
                    int idx = src_obj.find_prop_idx(length_key);
                    if (idx >= 0) {
                        TVal len_val = src_obj.prop_values()[idx];
                        if (len_val.is_fastint()) {
                            len = (uint)len_val.get_fastint();
                        } else if (len_val.is_number()) {
                            len = (uint)len_val.get_number();
                        }
                    }
                }
            }

            // Copy elements from array to arg registers
            TVal* dense = src_obj.array_part();
            for (uint i = 0; i < len; i++) {
                TVal* dest = ds.regs_base + first_arg_reg + i;
                if (dense != null && i < src_obj.array_size) {
                    vm.heap.tval_copy_ref(dest, &dense[i]);
                } else {
                    // Beyond dense part — check property table or return undefined
                    TVal idx_val;
                    idx_val.set_fastint((long)i);
                    TVal* idx_slot = ds.regs_base + first_arg_reg + i;
                    // Use the object's indexed access
                    hobject::PropLookupResult plr = src_obj.get_prop_or_accessor_proto(vm.heap.strs[heap::BuiltinStr.EMPTY], false);
                    // Simpler: just check property table for numeric key
                    TVal undef_val;
                    undef_val.set_undefined();
                    vm.heap.tval_copy_ref(dest, &undef_val);
                }
            }

            TVal* count_slot = ds.regs_base + count_reg;
            count_slot.set_fastint((long)len);
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}

