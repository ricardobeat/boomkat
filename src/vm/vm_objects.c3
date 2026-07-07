module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import libc;
import duktape::re_bindings;
import std::math;

// ============================================================================
// vm_objects — object/array creation, spreads, iterators
// ============================================================================
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
                        char* pattern_buf_heap = (char*)libc::malloc(plen + 1);
                        if (pattern_buf_heap != null) {
                            libc::memcpy(pattern_buf_heap, pattern_data.ptr, plen);
                            pattern_buf_heap[plen] = 0;
                        }
                        char[128] error_buf;
                        void* compiled = (pattern_buf_heap != null)
                            ? re_bindings::re_compile(pattern_buf_heap, plen, flags, &error_buf, 128)
                            : null;
                        if (pattern_buf_heap != null) libc::free(pattern_buf_heap);

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
                                obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WEC);
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

        case Opcode.ARRSPRD: {
            // A = target array reg, B = index reg (in/out), C = source reg
            // Uses ES6 iterator protocol (§12.2.5.3 ArrayAccumulation SpreadElement)
            if (!ra.is_object() || ra.get_heapptr() == null) break;
            HObject* target = (HObject*)ra.get_heapptr();
            TVal src_tv = *rc;

            // null/undefined → TypeError: not iterable
            if (src_tv.is_null() || src_tv.is_undefined()) {
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[80] spr_buf;
                    int slen = libc::snprintf(&spr_buf, 80, "Cannot spread %s",
                                              (src_tv.is_null() ? "null" : "undefined"));
                    HString* msg_str = null;
                    if (slen > 0 && slen < 80) {
                        msg_str = intern_string(vm, spr_buf[:slen]);
                    }
                    if (msg_str != null) {
                        TVal msg_val; msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &err_val);
                } else { return VM_ERROR~; }
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
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] it_buf;
                    int it_len = libc::snprintf(&it_buf, types::ERROR_MSG_BUF, "%s is not iterable",
                                                type_str.get_cstr());
                    if (it_len > 0 && it_len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, it_buf[:it_len]);
                        if (msg_str != null) {
                            TVal msg_val; msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &err_val);
                } else { return VM_ERROR~; }
                return (TVal){};
            }

            // Call @@iterator() with this = source
            TVal iterator = vm.heap.call_fn(vm, iter_method, null, 0, src_tv);
            if (vm_check_call_fn_error(vm)) return VM_ERROR~;
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
                if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                if (!result.is_object() || result.get_heapptr() == null) { break; }

                HObject* result_obj = (HObject*)result.get_heapptr();
                TVal? done_opt = result_obj.get_prop_proto(done_key);
                bool done = false;
                if (try dv = done_opt) { done = builtins::builtin_to_boolean(&dv); }
                if (done) { break; }

                TVal? value_opt = result_obj.get_prop_proto(value_key);
                if (try vv = value_opt) {
                    HString* pk = vm.heap.int_to_hstring(idx + (long)k);
                    if (pk != null) {
                        target.put_prop(pk, vv, hobject::PROP_FLAGS_WEC);
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

            // Copy enumerable own dense array indices (integer-keyed properties)
            if (source.array_part() != null) {
                char[12] digit_buf;
                for (uint i = 0; i < source.array_size; i++) {
                    if (!source.array_part()[i].is_undefined()) {
                        int dlen = libc::snprintf(&digit_buf, 12, "%u", i);
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

            // Copy own named properties (enumerable only, insertion order)
            for (uint i = 0; i < source.prop_count; i++) {
                void* key = source.prop_key_at(i);
                if (key == null) continue;
                hobject::PropFlags flags = source.get_prop_flags(i);
                if (!flags.enumerable) continue;

                TVal val;
                if (flags.is_accessor) {
                    // Accessor property: invoke the getter ([[Get]] semantics)
                    TVal gs_slot = source.prop_values()[i];
                    TVal getter = hobject::hobject_access_getter(gs_slot);
                    if (getter.is_undefined() || getter.is_null()) continue;
                    // If call_fn is unavailable, skip (shouldn't happen in practice)
                    if (vm.heap.call_fn == null) continue;
                    TVal this_tv;
                    this_tv.set_object(source);
                    val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                    if (vm.heap.has_error) {
                        vm.heap.has_error = false;
                        return (TVal){};
                    }
                } else {
                    // Data property: copy directly
                    val = source.prop_values()[i];
                }

                if (!target.put_prop(key, val, hobject::PROP_FLAGS_WEC)) {
                    return VM_ERROR~;
                }
            }
            return (TVal){};
        }

        case Opcode.SPREAD_ARG: {
            // A = dest start reg, B = count out reg, C = source reg
            // Uses ES6 iterator protocol (§12.3.5.1 ArgumentListEvaluation SpreadElement)
            TVal src_tv = *rc;

            // null/undefined → TypeError
            if (src_tv.is_null() || src_tv.is_undefined()) {
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[80] spr_buf;
                    int slen = libc::snprintf(&spr_buf, 80, "Cannot spread %s",
                                              (src_tv.is_null() ? "null" : "undefined"));
                    HString* msg_str = null;
                    if (slen > 0 && slen < 80) {
                        msg_str = intern_string(vm, spr_buf[:slen]);
                    }
                    if (msg_str != null) {
                        TVal msg_val; msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &err_val);
                } else { return VM_ERROR~; }
                return (TVal){};
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
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] it_buf;
                    int it_len = libc::snprintf(&it_buf, types::ERROR_MSG_BUF, "%s is not iterable",
                                                type_str.get_cstr());
                    if (it_len > 0 && it_len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, it_buf[:it_len]);
                        if (msg_str != null) {
                            TVal msg_val; msg_val.set_string(msg_str);
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    TVal err_val; err_val.set_object(err);
                    if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &err_val);
                } else { return VM_ERROR~; }
                return (TVal){};
            }

            // Call @@iterator() with this = source
            TVal iterator = vm.heap.call_fn(vm, iter_method, null, 0, src_tv);
            if (vm_check_call_fn_error(vm)) return VM_ERROR~;
            if (!iterator.is_object() || iterator.get_heapptr() == null) { break; }

            uint dest_start = insn.a;
            uint count_reg = insn.b;

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
                if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                if (!result.is_object() || result.get_heapptr() == null) { break; }

                HObject* result_obj = (HObject*)result.get_heapptr();
                TVal? done_opt = result_obj.get_prop_proto(done_key);
                bool done = false;
                if (try dv = done_opt) { done = builtins::builtin_to_boolean(&dv); }
                if (done) { break; }

                TVal? value_opt = result_obj.get_prop_proto(value_key);
                if (try vv = value_opt) {
                    TVal* dest_slot = ds.regs_base + dest_start + k;
                    *dest_slot = vv;
                    k++;
                } else { break; }
            }

            // Store count in output register
            TVal* count_slot = ds.regs_base + count_reg;
            count_slot.set_fastint((long)k);
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}

