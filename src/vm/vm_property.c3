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
// vm_property — GETPROP / PUTPROP / DELPROP and inline-cache paths
// ============================================================================
/// Rethrow a pending proxy-op error (heap.error_value) in the current frame.
/// Returns the opcode-handler result: {} when a catcher was found, VM_ERROR~ otherwise.
fn TVal? vm_proxy_rethrow(Vm* vm, Dispatch* ds) {
    TVal errv = vm.heap.error_value;
    vm.heap.has_error = false;
    if (!vm_throw_value(vm, errv, ds.act, &ds.curr_pc, &ds.needs_restart)) {
        return vm_uncaught_error(vm, &errv);
    }
    return (TVal){};
}

/// Auto-box a Symbol primitive (`sym_val`) and resolve `key` on it, invoking
/// an accessor getter (e.g. Symbol.prototype.description) if one is found.
/// Used by the GETPROPC2 fused-hop paths, mirroring the wrapper-object
/// auto-box already done by the single-hop GETPROPC symbol handling — a
/// direct `symbol_proto.get_prop_proto` lookup would return the raw
/// accessor-pair object instead of invoking the getter.
/// Writes the result into `*dst` (register `dst_reg`) and sets
/// `ds.needs_restart` if a JS-defined getter needs a call-frame restart.
fn void getprop2_symbol_hop(Vm* vm, Dispatch* ds, TVal sym_val, HString* key, TVal* dst, uint dst_reg) {
    HObject*? wrapper_raw = vm.heap.alloc_object(hobject::ObjClass.SYMBOL);
    HObject* wrapper;
    if (try w = wrapper_raw) {
        wrapper = w;
    } else {
        dst.set_undefined();
        return;
    }
    wrapper.prototype = vm.heap.symbol_proto;
    wrapper.extra_ptr().prim.primitive_value = sym_val;

    hobject::PropLookupResult res = wrapper.get_prop_or_accessor_proto(key, true);
    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        TVal wrapper_tv;
        wrapper_tv.set_object(wrapper);
        if (invoke_getter(vm, &res.acc, &wrapper_tv, dst_reg, ds.act, &ds.curr_pc, &ds.needs_restart, ds.regs_base)) {
            ds.regs_base = ds.act.bottom;
        }
    } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        vm.heap.tval_copy_ref(dst, &res.data_val);
        track_heap_store(ds.act, dst, dst_reg);
    } else {
        dst.set_undefined();
    }
}

/// Sub-dispatch for GETPROP, GETPROPC, GETPROPC_CACHED, GETPROPC2, PUTPROP, DELPROP opcodes.
fn TVal? dispatch_property(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.GETPROP:
        case Opcode.GETPROP_CACHE:
            if (rb.is_object()) {
                HObject* hobj = (HObject*)rb.get_heapptr();

                // Proxy exotic: route through [[Get]] before any cache/fast path.
                if (hobj.flags.exotic_proxyobj) {
                    void* pkey = get_prop_key(vm, rc);
                    if (pkey == null) { ra.set_undefined(); return (TVal){}; }
                    TVal pout;
                    if (!builtins::proxy_mop_get(vm, vm.heap, hobj, (HString*)pkey, *rb, &pout)) {
                        return vm_proxy_rethrow(vm, ds);
                    }
                    vm.heap.tval_copy_ref(ra, &pout);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                    return (TVal){};
                }

                // Inline Cache fast path: check shape + key + prop_values pointer
                // NOTE: We use prop_values() (not prop_alloc) because prop_alloc is
                // NULL for objects with ≤4 inline properties, making the check always
                // true for all small objects. prop_values() returns a unique pointer
                // per object even for inline properties.
                if (ds.ic_base != null) {
                    uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                    hobject::ICEntry* ic = ds.ic_base + pc_off;
                    void* lookup_key = null;
                    if (rc.is_string()) lookup_key = rc.get_heapptr();
                    // Check shape_id first: most likely to differ on polymorphic sites.
                    if (lookup_key != null && ic.shape_id == hobj.shape_id && ic.key == lookup_key) {
                        HObject* ic_owner = ic.proto == null ? hobj : (HObject*)ic.proto;
                        if (ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                            // Ultra-fast path: when the IC value is not a heap
                            // pointer (common for fastint/number results), skip
                            // decref/incref/track_heap_store entirely.
                            TVal ic_val = *ic.prop_value_ptr;
                            if (!ic_val.is_heap_allocated()) {
                                *ra = ic_val;
                            } else {
                                vm.heap.tval_copy_ref(ra, &ic_val);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            }
                            return (TVal){};
                        }
                    }
                }

                // Fast path: dense array indexed access (a[i] where i is a non-negative integer)
                // Also handles ARGUMENTS exotic objects for arguments[i] access
                hobject::ObjClass hobj_cls = hobj.get_class();
                if ((hobj_cls == hobject::ObjClass.ARRAY || hobj_cls == hobject::ObjClass.ARGUMENTS) && hobj.array_part() != null && (rc.is_fastint() || rc.is_number())) {
                    long idx_long = rc.is_fastint() ? rc.get_fastint() : (long)rc.get_number();
                    if (idx_long >= 0 && idx_long < (long)hobj.array_size) {
                        TVal? av = hobj.get_array_idx((uint)idx_long);
                        if (try v = av) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                            return (TVal){};
                        }
                        // Array hole — fall through to prototype chain lookup
                    }
                }

                // ARRAY exotic: .length fast path — return array_length directly
                if (hobj_cls == hobject::ObjClass.ARRAY && rc.is_string() && rc.get_heapptr() == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                    ra.set_fastint((long)*hobj.array_len_ptr());
                    return (TVal){};
                }

                // TypedArray element access: ta[i] where i is a numeric index.
                // OOB/detached is spec undefined (not a hole) — never falls
                // through to the prototype chain.
                if (builtins::is_typed_array_class(hobj_cls)
                    && (rc.is_fastint() || rc.is_number())) {
                    long idx_long = rc.is_fastint() ? rc.get_fastint() : (long)rc.get_number();
                    bool is_int_idx = rc.is_fastint() || rc.get_number() == (double)idx_long;
                    HObject* buf = (*hobj.extra_ptr()).view.buffer;
                    uint shift = builtins::ta_elem_shift(hobj.get_class());
                    uint elem_count = (*hobj.extra_ptr()).view.byte_length >> shift;
                    if (is_int_idx && idx_long >= 0 && buf != null
                        && (*buf.extra_ptr()).ab.data != null
                        && (ulong)idx_long < (ulong)elem_count) {
                        char* base = (*buf.extra_ptr()).ab.data + (*hobj.extra_ptr()).view.byte_offset;
                        TVal v = builtins::ta_load_element(vm.heap, base, hobj.get_class(), (uint)idx_long);
                        *ra = v;
                        return (TVal){};
                    }
                    ra.set_undefined();
                    return (TVal){};
                }

                void* key = get_prop_key(vm, rc);
                if (key == null && vm.throw_pending) {
                    vm.throw_pending = false;
                    if (!vm_throw_value(vm, vm.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &vm.throw_value);
                    }
                    return (TVal){};
                }
                // ToPropertyKey (§7.1.19) must be idempotent when a compound
                // assignment reuses this same key register for the follow-up
                // PUTPROP: `base[prop] *= expr()` may only call prop.toString()
                // once. GETPROP_CACHE (opt-in — see bytecode.c3) writes the
                // resolved string key back into rc so that a later
                // get_prop_key(vm, rc) on this register is a no-op (STRING
                // tag short-circuits without re-invoking ToPrimitive). Plain
                // GETPROP never does this: rc may alias a live local-variable
                // register (e.g. `arr[i]` where `i` is a parameter), and
                // unconditional writeback would silently corrupt the local.
                if (op == Opcode.GETPROP_CACHE && key != null && !rc.is_string()) {
                    TVal key_tv;
                    key_tv.set_string(key);
                    vm.heap.tval_copy_ref(rc, &key_tv);
                    track_heap_store(ds.act, rc, (uint)insn.c);
                }

                // Integer-indexed exotic [[Get]] (ES2022 §9.4.5.4):
                // For TypedArray objects, any canonical numeric index string must
                // bypass OrdinaryGet and go through IntegerIndexedElementGet.
                // - Non-arridx numeric strings ("1.5", "-0", "NaN"): always undefined.
                // - Arridx strings ("0", "1", "2"): read element if in-bounds, else undefined.
                // Neither case walks the prototype chain, preventing spurious accessor hits.
                if (key != null
                    && builtins::is_typed_array_class(hobj_cls)) {
                    HString* key_hstr = (HString*)key;
                    if (!key_hstr.is_symbol()) {
                        if (key_hstr.is_arridx()) {
                            // Array-index string key ("0", "1", …): use II-exotic element read.
                            uint idx = key_hstr.array_index();
                            HObject* buf = (*hobj.extra_ptr()).view.buffer;
                            uint shift = builtins::ta_elem_shift(hobj_cls);
                            uint elem_count = (*hobj.extra_ptr()).view.byte_length >> shift;
                            if (buf != null && (*buf.extra_ptr()).ab.data != null
                                && (ulong)idx < (ulong)elem_count) {
                                char* base = (*buf.extra_ptr()).ab.data + (*hobj.extra_ptr()).view.byte_offset;
                                TVal v = builtins::ta_load_element(vm.heap, base, hobj_cls, idx);
                                *ra = v;
                            } else {
                                ra.set_undefined();
                            }
                            return (TVal){};
                        } else {
                            double cni_d;
                            if (builtins::is_canonical_numeric_index(vm.heap, key_hstr, &cni_d)) {
                                ra.set_undefined();
                                return (TVal){};
                            }
                        }
                    }
                }

                if (key != null) {
                    // ES5 strict mode: arguments.callee throws TypeError.
                    // Strict-only engine: always throws.
                    if (hobj_cls == hobject::ObjClass.ARGUMENTS
                        && key == (void*)vm.heap.strs[heap::BuiltinStr.CALLEE]) {
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "'callee', 'arguments', and 'arguments.caller' may not be accessed in strict mode", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    // ES5 strict mode: function.caller and function.arguments throw TypeError
                    // (AddRestrictedFunctionProperties poison pill) — but only when the
                    // function has no own property of that name (e.g. a class's own
                    // `static get arguments() {}` shadows the poison pill; ES2015
                    // ClassDefinitionEvaluation defines own properties before the pill
                    // would apply, and OrdinaryGet checks own properties first).
                    if (hobj.is_callable() && hobj_cls == hobject::ObjClass.FUNCTION) {
                        HString* key_hstr = (HString*)key;
                        if (key_hstr != null && (key_hstr.equals("caller") || key_hstr.equals("arguments"))
                            && hobj.find_prop_idx(key) < 0) {
                            if (!vm_throw_error(vm, vm.heap.type_err_proto, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            return (TVal){};
                        }
                    }
                    // STRING exotic: indexed access reads characters lazily from the primitive value.
                    // Handles both fastint/number keys (e.g. s[0]) and array-index string keys
                    // (e.g. s["0"]), avoiding the need to materialise per-character own properties.
                    if (hobj.flags.exotic_stringobj && (*hobj.extra_ptr()).prim.primitive_value.is_string()) {
                        long sidx = -1;
                        if (rc.is_fastint()) {
                            sidx = rc.get_fastint();
                        } else if (rc.is_number()) {
                            double d = rc.get_number();
                            if (d >= 0 && d == (double)(long)d) sidx = (long)d;
                        } else if (rc.is_string()) {
                            // String key that is a canonical array index (cached on HString)
                            HString* key_hstr = (HString*)rc.get_heapptr();
                            if (key_hstr != null && key_hstr.is_arridx()) {
                                sidx = (long)key_hstr.array_index();
                            }
                        }
                        if (sidx >= 0) {
                            HString* prim_str = (HString*)(*hobj.extra_ptr()).prim.primitive_value.get_heapptr();
                            if (sidx < (long)prim_str.char_length()) {
                                uint cp = prim_str.char_at((uint)sidx);
                                char[4] sbuf;
                                uint sblen = hstring::encode_codepoint(cp, sbuf[:4]);
                                HString* interned = intern_string(vm, sbuf[:sblen]);
                                if (interned != null) {
                                    vm.heap.set_reg_string(ra, interned);
                                } else {
                                    return VM_ERROR~;
                                }
                                return (TVal){};
                            }
                            // Out-of-range index on a string exotic: fall through to own-property
                            // lookup so that explicitly assigned out-of-range slots are still found.
                        }
                    }
                    // Megamorphic cache: try global (shape, key) → offset cache before full chain walk
                    hobject::MegamorphicEntry* mega = hobject::mega_cache_lookup(vm.heap, hobj, key);
                    if (mega != null) {
                        TVal mega_val = *mega.prop_value_ptr;
                        if (!mega_val.is_heap_allocated()) {
                            *ra = mega_val;
                        } else {
                            vm.heap.tval_copy_ref(ra, &mega_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        }
                        return (TVal){};
                    }
                    hobject::PropLookupResult res = hobj.get_prop_or_accessor_proto(key, true);
                    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                        // ES2022 §7.3.25 PrivateGet: a set-only private
                        // accessor throws TypeError on read (unlike a public
                        // set-only accessor, which reads as undefined —
                        // §10.1.9.2 OrdinaryGet returns undefined when no
                        // [[Get]]). Hidden-symbol keys are exclusively used
                        // for private members, so this check never fires for
                        // public accessors.
                        HString* key_hs_get = (HString*)key;
                        if ((!res.acc.accessor_fn.is_object() || res.acc.accessor_fn.get_heapptr() == null)
                            && key_hs_get.is_hidden()) {
                            char[] priv_desc = key_hs_get.blen > 2 ? key_hs_get.get_data()[2..] : (char[])"?";
                            char[160] set_only_buf;
                            int set_only_len = (int)(io::bprintf(&set_only_buf,
                                "Cannot read private member #%s from an object because it only has a setter",
                                (String)priv_desc) ?? set_only_buf[:0]).len;
                            char[] set_only_msg = set_only_len > 0 && (usz)set_only_len < set_only_buf.len
                                ? set_only_buf[:(usz)set_only_len]
                                : (char[])"Cannot read private member from an object because it only has a setter";
                            if (!vm_throw_error(vm, vm.heap.type_err_proto, set_only_msg,
                                    ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            return (TVal){};
                        }
                        TVal obj_val;
                        obj_val.set_object(hobj);
                        if (invoke_getter(vm, &res.acc, &obj_val, (uint)insn.a,
                                          ds.act, &ds.curr_pc, &ds.needs_restart, ds.regs_base)) {
                            ds.regs_base = ds.act.bottom;
                            return (TVal){};
                        }
                        if (vm.has_error) return VM_ERROR~;
                        return (TVal){};
                        } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                            vm.heap.tval_copy_ref(ra, &res.data_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                            // Populate IC for this site.
                            // Only cache OWN property lookups. Inherited lookups are not cached
                            // because the IC would have no way to detect modifications to
                            // intermediate objects in the prototype chain (e.g. when
                            // B.prototype.foo = ... is set, an IC that previously resolved
                            // b.foo via A.prototype would return a stale value). This matches
                            // the QuickJS approach where the shape itself encodes the proto
                            // and lookups always walk the current chain.
                            if (res.owner == hobj && res.owner != null && ds.ic_base != null) {
                                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                                hobject::ICEntry* ic = ds.ic_base + pc_off;
                                int owner_idx = res.owner.find_prop_idx(key);
                                if (owner_idx >= 0) {
                                    ic.shape_id = hobj.shape_id;
                                    ic.proto = null;  // own property
                                    ic.prop_idx = (ushort)owner_idx;
                                    ic.prop_flags = res.owner.get_prop_flags((uint)owner_idx);
                                    // incref the new key before decref-ing the old one: when the
                                    // same string is re-cached at this slot (ic.key == key) whose
                                    // only live reference is the IC entry itself, decref-first would
                                    // free it and the following incref would touch freed memory.
                                    if (key != null) { ((types::HeapHeader*)key).incref(); }
                                    if (ic.key != null) { vm.heap.decref((types::HeapHeader*)ic.key); }
                                    ic.key = key;
                                    ic.prop_value_ptr = &res.owner.prop_values()[owner_idx];
                                    ic.cached_prop_alloc = (void*)res.owner.prop_values();
                                    // Also populate megamorphic cache for cross-site benefit
                                    hobject::mega_cache_store(vm.heap, hobj, key, res.owner, owner_idx);
                                }
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
            } else if (rb.is_null() || rb.is_undefined()) {
                // TypeError: Cannot read properties of null/undefined
                HString* name_hstr = null;
                if (rc.is_string()) {
                    name_hstr = (HString*)rc.get_heapptr();
                }
                char[types::ERROR_MSG_BUF] msg_buf;
                int msg_len;
                if (name_hstr != null) {
                    msg_len = (int)(io::bprintf(&msg_buf, "Cannot read properties of %s (reading '%s')",
                                              (rb.is_null() ? "null" : "undefined"),
                                              (ZString)name_hstr.get_cstr()) ?? msg_buf[:0]).len;
                } else {
                    msg_len = (int)(io::bprintf(&msg_buf, "Cannot read properties of %s",
                                              (rb.is_null() ? "null" : "undefined")) ?? msg_buf[:0]).len;
                }
                char[] msg_slice = (msg_len > 0 && msg_len < types::ERROR_MSG_BUF) ? msg_buf[:msg_len] : msg_buf[:0];
                if (!vm_throw_error(vm, vm.heap.type_err_proto, msg_slice, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
            } else if (rb.is_string()) {
                // Check if this is a Symbol (0xFF-prefixed string)
                HString* h_str = (HString*)rb.get_heapptr();
                if (h_str != null && h_str.is_symbol() && vm.heap.symbol_proto != null) {
                    // Auto-box symbol primitive: create a temporary wrapper object
                    // so that accessor properties (like description getter) work correctly.
                    HString* key = get_prop_key(vm, rc);
                    if (key != null) {
                        HObject*? wrapper_raw = vm.heap.alloc_object(hobject::ObjClass.SYMBOL);
                        HObject* wrapper;
                        if (try w = wrapper_raw) {
                            wrapper = w;
                            wrapper.prototype = vm.heap.symbol_proto;
                            // Store the symbol primitive as [[SymbolData]]
                            wrapper.extra_ptr().prim.primitive_value = *rb;
                        } else {
                            ra.set_undefined();
                            return (TVal){};
                        }
                        hobject::PropLookupResult res = wrapper.get_prop_or_accessor_proto(key, true);
                        if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            TVal wrapper_tv;
                            wrapper_tv.set_object(wrapper);
                            if (invoke_getter(vm, &res.acc, &wrapper_tv, (uint)insn.a,
                                              ds.act, &ds.curr_pc, &ds.needs_restart, ds.regs_base)) {
                                ds.regs_base = ds.act.bottom;
                                return (TVal){};
                            }
                            if (vm.has_error) return VM_ERROR~;
                            return (TVal){};
                        } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                            vm.heap.tval_copy_ref(ra, &res.data_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    // Auto-box string primitive
                    HString* str_prim = (HString*)rb.get_heapptr();

                    // Fast path: numeric index → character at index
                    long str_idx = -1;
                    if (rc.is_fastint()) {
                        str_idx = rc.get_fastint();
                    } else if (rc.is_number()) {
                        double d = rc.get_number();
                        if (d >= 0 && d == (double)(long)d) {
                            str_idx = (long)d;
                        }
                    }
                    if (str_idx >= 0 && str_idx < (long)str_prim.char_length()) {
                        uint cp = str_prim.char_at((uint)str_idx);
                        char[4] cbuf;
                        uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
                        HString* interned = intern_string(vm, cbuf[:cblen]);
                        if (interned != null) {
                            vm.heap.set_reg_string(ra, interned);
                        } else {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }

                    HString* key = get_prop_key(vm, rc);
                    if (key != null) {
                        // Fast path: .length → string character count
                        if (key == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra.set_fastint((long)h_str.char_length());
                            return (TVal){};
                        }
                        // Slow path: walk String.prototype chain
                        if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto(key);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra, &v);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                }
            } else if (rb.is_number() || rb.is_fastint()) {
                // Auto-box number primitive: walk Number.prototype chain
                HString* key = get_prop_key(vm, rc);
                if (key != null && vm.heap.number_proto != null) {
                    TVal? result = vm.heap.number_proto.get_prop_proto(key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(ds.act, ra, (uint)insn.a);
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else if (rb.is_boolean()) {
                // Auto-box boolean primitive: walk Boolean.prototype chain
                HString* key = get_prop_key(vm, rc);
                if (key != null && vm.heap.bool_proto != null) {
                    TVal? result = vm.heap.bool_proto.get_prop_proto(key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(ds.act, ra, (uint)insn.a);
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else if (rb.is_bigint()) {
                // Auto-box BigInt primitive: walk BigInt.prototype chain.
                HString* key = get_prop_key(vm, rc);
                if (key != null && vm.heap.bigint_proto != null) {
                    TVal? result = vm.heap.bigint_proto.get_prop_proto(key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(ds.act, ra, (uint)insn.a);
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else if (rb.is_lightfunc()) {
                // LIGHTFUNC: resolve .name and .length from metadata, other props from Function.prototype
                uint fn_idx = (uint)(usz)rb.get_heapptr();
                HString* key = get_prop_key(vm, rc);
                if (key != null) {
                    if (key.equals("name")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 0)) {
                            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                            if (meta.name.len > 0) {
                                HString* name_str = intern_string(vm, meta.name);
                                vm.heap.set_reg_string(ra, name_str);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key.equals("length")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 1)) {
                            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                            if (meta.arity >= 0) {
                                ra.set_number(meta.arity);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key.equals("prototype")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 2)) {
                            // Resolve .prototype for constructor lightfuncs (Boolean, Number, etc.)
                            HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                            if (proto_obj != null) {
                                ra.set_object(proto_obj);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key.equals("caller") || key.equals("arguments")) {
                        // ES5 strict mode: accessing .caller and .arguments throws TypeError
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                    } else if (vm.heap.function_proto != null) {
                        // Walk Function.prototype for .call, .apply, .bind, etc.
                        TVal? result = vm.heap.function_proto.get_prop_proto(key);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
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

        case Opcode.GETPROPC:
            // Fused LDCONST+GETPROP: key comes from constant pool (always a string).
            {
                TVal key_tval = ds.constants[(uint)insn.c];
                HString* key_hstr = (HString*)key_tval.get_heapptr();
                if (rb.is_object()) {
                    HObject* hobj = (HObject*)rb.get_heapptr();

                    // Proxy exotic: route through [[Get]] before the IC.
                    if (hobj.flags.exotic_proxyobj) {
                        TVal pout;
                        if (!builtins::proxy_mop_get(vm, vm.heap, hobj, key_hstr, *rb, &pout)) {
                            return vm_proxy_rethrow(vm, ds);
                        }
                        vm.heap.tval_copy_ref(ra, &pout);
                        track_heap_store(ds.act, ra, (uint)insn.a);
                        return (TVal){};
                    }

                    // Inline Cache fast path: key is always non-null, skip lookup_key check.
                    if (ds.ic_base != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::ICEntry* ic = ds.ic_base + pc_off;
                        if (ic.key == (void*)key_hstr && ic.shape_id == hobj.shape_id) {
                            HObject* ic_owner;
                            if (ic.proto == null) {
                                ic_owner = hobj;
                            } else if (hobj.prototype == (HObject*)ic.proto) {
                                ic_owner = (HObject*)ic.proto;
                            } else {
                                ic_owner = null;
                            }
                            if (ic_owner != null && ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                                TVal ic_val = *ic.prop_value_ptr;
                                if (!ic_val.is_heap_allocated()) {
                                    *ra = ic_val;
                                } else {
                                    vm.heap.tval_copy_ref(ra, &ic_val);
                                    track_heap_store(ds.act, ra, (uint)insn.a);
                                }
                                return (TVal){};
                            }
                        }
                    }

                    // ARRAY exotic: .length fast path
                    if (hobj.get_class() == hobject::ObjClass.ARRAY && (void*)key_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                        ra.set_fastint((long)*hobj.array_len_ptr());
                        return (TVal){};
                    }

                    void* key = (void*)key_hstr;
                    if (key != null) {
                        // ES5 strict mode: arguments.callee throws TypeError.
                        // Strict-only engine: always throws.
                        if (hobj.get_class() == hobject::ObjClass.ARGUMENTS
                            && key == (void*)vm.heap.strs[heap::BuiltinStr.CALLEE]) {
                            if (!vm_throw_error(vm, vm.heap.type_err_proto, "'callee', 'arguments', and 'arguments.caller' may not be accessed in strict mode", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            return (TVal){};
                        }
                        // ES5 strict mode: function.caller and function.arguments throw TypeError
                        // (AddRestrictedFunctionProperties poison pill) — skipped when the
                        // function has its own property of that name (see GETPROP above).
                        if (hobj.is_callable() && hobj.get_class() == hobject::ObjClass.FUNCTION
                            && (key_hstr.equals("caller") || key_hstr.equals("arguments"))
                            && hobj.find_prop_idx(key) < 0) {
                            if (!vm_throw_error(vm, vm.heap.type_err_proto, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            return (TVal){};
                        }
                        // STRING exotic: string-key indexed access (array-index string keys like "0")
                        if (hobj.flags.exotic_stringobj && (*hobj.extra_ptr()).prim.primitive_value.is_string()) {
                            if (key_hstr != null && key_hstr.is_arridx()) {
                                long sidx = (long)key_hstr.array_index();
                                HString* prim_str = (HString*)(*hobj.extra_ptr()).prim.primitive_value.get_heapptr();
                                if (sidx < (long)prim_str.char_length()) {
                                    uint cp = prim_str.char_at((uint)sidx);
                                    char[4] sbuf;
                                    uint sblen = hstring::encode_codepoint(cp, sbuf[:4]);
                                    HString* interned = intern_string(vm, sbuf[:sblen]);
                                    if (interned != null) {
                                        vm.heap.set_reg_string(ra, interned);
                                    } else {
                                        return VM_ERROR~;
                                    }
                                    return (TVal){};
                                }
                            }
                        }
                        // Integer-indexed exotic [[Get]] (ES2022 §9.4.5.4) for GETPROPC.
                        // TypedArray string keys that are canonical numeric indices must
                        // bypass OrdinaryGet (no prototype chain walk).
                        {
                            hobject::ObjClass cls_c = hobj.get_class();
                            if (key_hstr != null && !key_hstr.is_symbol()
                                && builtins::is_typed_array_class(cls_c)) {
                                if (key_hstr.is_arridx()) {
                                    uint cidx = key_hstr.array_index();
                                    HObject* cbuf = (*hobj.extra_ptr()).view.buffer;
                                    uint cshift = builtins::ta_elem_shift(cls_c);
                                    uint ccount = (*hobj.extra_ptr()).view.byte_length >> cshift;
                                    if (cbuf != null && (*cbuf.extra_ptr()).ab.data != null
                                        && (ulong)cidx < (ulong)ccount) {
                                        char* cbase = (*cbuf.extra_ptr()).ab.data + (*hobj.extra_ptr()).view.byte_offset;
                                        TVal cv = builtins::ta_load_element(vm.heap, cbase, cls_c, cidx);
                                        *ra = cv;
                                    } else {
                                        ra.set_undefined();
                                    }
                                    return (TVal){};
                                } else {
                                    double cni_d;
                                    if (builtins::is_canonical_numeric_index(vm.heap, key_hstr, &cni_d)) {
                                        ra.set_undefined();
                                        return (TVal){};
                                    }
                                }
                            }
                        }
                        // Megamorphic cache: try global (shape, key) → offset cache before full chain walk
                        hobject::MegamorphicEntry* mega = hobject::mega_cache_lookup(vm.heap, hobj, key);
                        if (mega != null) {
                            TVal mega_val = *mega.prop_value_ptr;
                            if (!mega_val.is_heap_allocated()) {
                                *ra = mega_val;
                            } else {
                                vm.heap.tval_copy_ref(ra, &mega_val);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            }
                            return (TVal){};
                        }
                        hobject::PropLookupResult res = hobj.get_prop_or_accessor_proto(key, true);
                        if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            TVal obj_val;
                            obj_val.set_object(hobj);
                            if (invoke_getter(vm, &res.acc, &obj_val, (uint)insn.a,
                                              ds.act, &ds.curr_pc, &ds.needs_restart, ds.regs_base)) {
                                ds.regs_base = ds.act.bottom;
                                return (TVal){};
                            }
                            if (vm.has_error) return VM_ERROR~;
                            return (TVal){};
                        } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                            vm.heap.tval_copy_ref(ra, &res.data_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                            // Populate IC for this site.
                            // Cache own-property lookups and single-level prototype lookups.
                            // For proto: ic.proto stores the owning prototype; the IC hit path
                            // validates hobj.prototype == ic.proto to guard setPrototypeOf.
                            if (res.owner != null && ds.ic_base != null) {
                                bool is_own = res.owner == hobj;
                                bool is_direct_proto = !is_own && hobj.prototype == res.owner;
                                if (is_own || is_direct_proto) {
                                    uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                                    hobject::ICEntry* ic = ds.ic_base + pc_off;
                                    int owner_idx = res.owner.find_prop_idx(key);
                                    if (owner_idx >= 0) {
                                        ic.shape_id = hobj.shape_id;
                                        ic.proto = is_own ? null : (void*)res.owner;
                                        ic.prop_idx = (ushort)owner_idx;
                                        ic.prop_flags = res.owner.get_prop_flags((uint)owner_idx);
                                        // incref the new key before decref-ing the old one: when the
                                        // same string is re-cached at this slot (ic.key == key) whose
                                        // only live reference is the IC entry itself, decref-first would
                                        // free it and the following incref would touch freed memory.
                                        if (key != null) { ((types::HeapHeader*)key).incref(); }
                                        if (ic.key != null) { vm.heap.decref((types::HeapHeader*)ic.key); }
                                        ic.key = key;
                                        ic.prop_value_ptr = &res.owner.prop_values()[owner_idx];
                                        ic.cached_prop_alloc = (void*)res.owner.prop_values();
                                        // Upgrade to cached variant now that IC is populated
                                        // Keep A, B, C operands the same, just change the opcode
                                        ds.curr_pc[-1] = bytecode::make_abc(bytecode::Opcode.GETPROPC_CACHED,
                                                                          (uint)insn.a, (uint)insn.b, (uint)insn.c);
                                        // Also populate megamorphic cache for cross-site benefit
                                        if (is_own) {
                                            hobject::mega_cache_store(vm.heap, hobj, key, res.owner, owner_idx);
                                        }
                                    }
                                }
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_null() || rb.is_undefined()) {
                    char[types::ERROR_MSG_BUF] msg_buf;
                    int msg_len;
                    if (key_hstr != null) {
                        msg_len = (int)(io::bprintf(&msg_buf, "Cannot read properties of %s (reading '%s')",
                                                  (rb.is_null() ? "null" : "undefined"),
                                                  (ZString)key_hstr.get_cstr()) ?? msg_buf[:0]).len;
                    } else {
                        msg_len = (int)(io::bprintf(&msg_buf, "Cannot read properties of %s",
                                                  (rb.is_null() ? "null" : "undefined")) ?? msg_buf[:0]).len;
                    }
                    char[] msg_slice = (msg_len > 0 && msg_len < types::ERROR_MSG_BUF) ? msg_buf[:msg_len] : msg_buf[:0];
                    if (!vm_throw_error(vm, vm.heap.type_err_proto, msg_slice, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return VM_ERROR~;
                    }
                } else if (rb.is_string()) {
                    HString* h_str = (HString*)rb.get_heapptr();
                    if (h_str != null && h_str.is_symbol() && vm.heap.symbol_proto != null) {
                        if (key_hstr != null) {
                            // Auto-box symbol primitive: create a temporary wrapper object
                            // so that accessor properties (like description getter) work correctly.
                            HObject*? wrapper_raw = vm.heap.alloc_object(hobject::ObjClass.SYMBOL);
                            HObject* wrapper;
                            if (try w = wrapper_raw) {
                                wrapper = w;
                                wrapper.prototype = vm.heap.symbol_proto;
                                wrapper.extra_ptr().prim.primitive_value = *rb;
                            } else {
                                ra.set_undefined();
                                return (TVal){};
                            }
                            hobject::PropLookupResult res = wrapper.get_prop_or_accessor_proto(key_hstr, true);
                            if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                                TVal wrapper_tv;
                                wrapper_tv.set_object(wrapper);
                                if (invoke_getter(vm, &res.acc, &wrapper_tv, (uint)insn.a,
                                                  ds.act, &ds.curr_pc, &ds.needs_restart, ds.regs_base)) {
                                    ds.regs_base = ds.act.bottom;
                                    return (TVal){};
                                }
                                if (vm.has_error) return VM_ERROR~;
                                return (TVal){};
                            } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra, &res.data_val);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        // Auto-box string primitive: constant string key — skip numeric-index fast path
                        if (key_hstr != null) {
                            // Fast path: .length → string character count
                            if ((void*)key_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                                ra.set_fastint((long)h_str.char_length());
                                return (TVal){};
                            }
                            if (vm.heap.string_proto != null) {
                                TVal? result = vm.heap.string_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) {
                                    vm.heap.tval_copy_ref(ra, &v);
                                    track_heap_store(ds.act, ra, (uint)insn.a);
                                } else {
                                    ra.set_undefined();
                                }
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    }
                } else if (rb.is_number() || rb.is_fastint()) {
                    if (key_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_boolean()) {
                    if (key_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_bigint()) {
                    if (key_hstr != null && vm.heap.bigint_proto != null) {
                        TVal? result = vm.heap.bigint_proto.get_prop_proto((void*)key_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_lightfunc()) {
                    // LIGHTFUNC: resolve .name and .length from metadata, other props from Function.prototype
                    uint fn_idx = (uint)(usz)rb.get_heapptr();
                    if (key_hstr != null) {
                        if (key_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 0)) {
                                builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                                if (meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, meta.name);
                                    vm.heap.set_reg_string(ra, name_str);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (key_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 1)) {
                                builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                                if (meta.arity >= 0) {
                                    ra.set_number(meta.arity);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (key_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 2)) {
                                HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                                if (proto_obj != null) {
                                    ra.set_object(proto_obj);
                                    track_heap_store(ds.act, ra, (uint)insn.a);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (key_hstr.equals("caller") || key_hstr.equals("arguments")) {
                            // ES5 strict mode: accessing .caller and .arguments throws TypeError
                            if (!vm_throw_error(vm, vm.heap.type_err_proto, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                        } else if (vm.heap.function_proto != null) {
                            // Walk Function.prototype for .call, .apply, .bind, etc.
                            TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra, &v);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
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
            }
            return (TVal){};

        case Opcode.GETPROPC_CACHED: {
            // Specialized GETPROPC: IC is known warm. Only checks shape_id + prop_alloc.
            // Falls back to GETPROPC if the check fails (shape changed or props reallocated).
            // key_tval/key_hstr are only needed on miss; defer them to avoid wasted loads on hit.
            if (rb.is_object() && ds.ic_base != null) {
                HObject* hobj = (HObject*)rb.get_heapptr();
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::ICEntry* ic = ds.ic_base + pc_off;
                if (ic.shape_id == hobj.shape_id) {
                    HObject* ic_owner;
                    if (ic.proto == null) {
                        ic_owner = hobj;
                    } else if (hobj.prototype == (HObject*)ic.proto) {
                        ic_owner = (HObject*)ic.proto;
                    } else {
                        ic_owner = null;
                    }
                    if (ic_owner != null && ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                        TVal ic_val = *ic.prop_value_ptr;
                        if (!ic_val.is_heap_allocated()) {
                            *ra = ic_val;
                        } else {
                            vm.heap.tval_copy_ref(ra, &ic_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        }
                        return (TVal){};
                    }
                }
            }
            // IC miss or ds.ic_base null: downgrade back to GETPROPC and re-execute
            ds.curr_pc[-1] = bytecode::make_abc(bytecode::Opcode.GETPROPC,
                                            (uint)insn.a, (uint)insn.b, (uint)insn.c);
            ds.curr_pc--;
            return (TVal){};
        }

        case Opcode.GETPROPC2: {
            // Fused two-hop property access. Executes GETPROPC twice in one dispatch.
            // Format: insn[i] = GETPROPC2 A=dst_temp, B=src, C=key1
            //         insn[i+1] = (data: A=dst_final, C=key2)
            // After execution, ds.curr_pc advances past insn[i+1] (skips the data slot).

            TVal key1_tval = ds.constants[(uint)insn.c];
            HString* key1_hstr = (HString*)key1_tval.get_heapptr();

            // Read second hop's destination and key from the next instruction slot
            Instruction next_insn = ds.curr_pc[0];  // ds.curr_pc has already advanced past insn
            uint dst2_reg = (uint)next_insn.a;
            TVal key2_tval = ds.constants[(uint)next_insn.c];
            HString* key2_hstr = (HString*)key2_tval.get_heapptr();

            // Advance ds.curr_pc past the data slot
            ds.curr_pc++;

            TVal* ra2 = ds.regs_base + dst2_reg;

            if (rb.is_object()) {
                HObject* hobj1 = (HObject*)rb.get_heapptr();
                uint pc1 = (uint)(ds.curr_pc - 2 - ds.code_base);  // pc of GETPROPC2

                // === Hop 1: hobj1[key1] ===
                TVal mid_val;
                mid_val.set_undefined();
                bool hop1_proxy = hobj1.flags.exotic_proxyobj;
                if (hop1_proxy) {
                    if (!builtins::proxy_mop_get(vm, vm.heap, hobj1, key1_hstr, *rb, &mid_val)) {
                        return vm_proxy_rethrow(vm, ds);
                    }
                }
                if (!hop1_proxy && ds.ic_base != null) {
                    hobject::ICEntry* ic1 = ds.ic_base + pc1;
                    if (ic1.key == (void*)key1_hstr && ic1.shape_id == hobj1.shape_id) {
                        HObject* owner1;
                        if (ic1.proto == null) {
                            owner1 = hobj1;
                        } else if (hobj1.prototype == (HObject*)ic1.proto) {
                            owner1 = (HObject*)ic1.proto;
                        } else {
                            owner1 = null;
                        }
                        if (owner1 != null && ic1.cached_prop_alloc == (void*)owner1.prop_values()) {
                            mid_val = *ic1.prop_value_ptr;
                        }
                    }
                }

                // Full lookup for hop 1 if IC miss
                if (!hop1_proxy && mid_val.is_undefined() && key1_hstr != null) {
                    // ARRAY .length fast path
                    if (hobj1.get_class() == hobject::ObjClass.ARRAY
                        && (void*)key1_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                        mid_val.set_fastint((long)*hobj1.array_len_ptr());
                    } else {
                        void* key1 = (void*)key1_hstr;
                        hobject::PropLookupResult r1 = hobj1.get_prop_or_accessor_proto(key1, true);
                        if (r1.kind == hobject::PropLookupKind.PROP_DATA) {
                            mid_val = r1.data_val;
                            // Populate IC1 — only cache OWN property lookups (see GETPROP).
                            if (r1.owner == hobj1 && r1.owner != null && ds.ic_base != null) {
                                hobject::ICEntry* ic1 = ds.ic_base + pc1;
                                int idx1 = r1.owner.find_prop_idx(key1);
                                if (idx1 >= 0) {
                                    ic1.shape_id = hobj1.shape_id;
                                    ic1.proto = null;  // own property
                                    ic1.prop_idx = (ushort)idx1;
                                    if (ic1.key != null) { vm.heap.decref((types::HeapHeader*)ic1.key); }
                                    ic1.key = key1;
                                    if (key1 != null) { ((types::HeapHeader*)key1).incref(); }
                                    ic1.prop_value_ptr = &r1.owner.prop_values()[idx1];
                                    ic1.cached_prop_alloc = (void*)r1.owner.prop_values();
                                }
                            }
                        } else if (r1.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            // Accessor on the first hop: invoke the getter
                            // synchronously via the reentrant call_fn path.
                            // (A frame-based invoke_getter would resume past
                            // the fused pair and skip hop 2 entirely.)
                            TVal getter1 = r1.acc.accessor_fn;
                            if (!getter1.is_undefined() && !getter1.is_null() && vm.heap.call_fn != null) {
                                TVal this_tv1;
                                this_tv1.set_object(hobj1);
                                mid_val = vm.heap.call_fn(vm, getter1, null, 0, this_tv1);
                                if (vm.heap.has_error) {
                                    vm.heap.has_error = false;
                                    TVal err_val = vm.heap.error_value;
                                    if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        vm.has_error = true;
                                        vm.heap.has_error = true;
                                        return VM_ERROR~;
                                    }
                                    return (TVal){};
                                }
                            } else {
                                mid_val.set_undefined();
                            }
                        }
                    }
                }

                // === Hop 2: mid_val[key2] ===
                if (mid_val.is_object()) {                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    uint pc2 = (uint)(ds.curr_pc - 1 - ds.code_base);  // pc of the data slot

                    // Proxy exotic on the second hop: route through [[Get]].
                    if (hobj2.flags.exotic_proxyobj) {
                        TVal pout2;
                        if (!builtins::proxy_mop_get(vm, vm.heap, hobj2, key2_hstr, mid_val, &pout2)) {
                            return vm_proxy_rethrow(vm, ds);
                        }
                        vm.heap.tval_copy_ref(ra2, &pout2);
                        track_heap_store(ds.act, ra2, dst2_reg);
                        return (TVal){};
                    }

                    // ES5 strict mode: function.caller and function.arguments throw
                    // TypeError (AddRestrictedFunctionProperties poison pill) — unless
                    // the function has its own property of that name (see GETPROP).
                    if (hobj2.is_callable() && hobj2.get_class() == hobject::ObjClass.FUNCTION
                        && key2_hstr != null
                        && (key2_hstr.equals("caller") || key2_hstr.equals("arguments"))
                        && hobj2.find_prop_idx((void*)key2_hstr) < 0) {
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }

                    // IC fast path for hop 2
                    if (ds.ic_base != null && key2_hstr != null) {
                        hobject::ICEntry* ic2 = ds.ic_base + pc2;
                        if (ic2.key == (void*)key2_hstr && ic2.shape_id == hobj2.shape_id) {
                            HObject* owner2;
                            if (ic2.proto == null) {
                                owner2 = hobj2;
                            } else if (hobj2.prototype == (HObject*)ic2.proto) {
                                owner2 = (HObject*)ic2.proto;
                            } else {
                                owner2 = null;
                            }
                            if (owner2 != null && ic2.cached_prop_alloc == (void*)owner2.prop_values()) {
                                TVal ic2_val = *ic2.prop_value_ptr;
                                if (!ic2_val.is_heap_allocated()) {
                                    *ra2 = ic2_val;
                                } else {
                                    vm.heap.tval_copy_ref(ra2, &ic2_val);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                }
                                // Also store the intermediate result in ra (temp register)
                                if (mid_val.is_heap_allocated()) {
                                    vm.heap.tval_copy_ref(ra, &mid_val);
                                    track_heap_store(ds.act, ra, (uint)insn.a);
                                } else {
                                    *ra = mid_val;
                                }
                                return (TVal){};
                            }
                        }
                    }

                    // Full lookup for hop 2 if IC miss
                    if (key2_hstr != null) {
                        // ARRAY .length fast path
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            void* key2 = (void*)key2_hstr;
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto(key2, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(ds.act, ra2, dst2_reg);
                                // Populate IC2 — only cache OWN property lookups (see GETPROP).
                                if (r2.owner == hobj2 && r2.owner != null && ds.ic_base != null) {
                                    hobject::ICEntry* ic2 = ds.ic_base + pc2;
                                    int idx2 = r2.owner.find_prop_idx(key2);
                                    if (idx2 >= 0) {
                                        ic2.shape_id = hobj2.shape_id;
                                        ic2.proto = null;  // own property
                                        ic2.prop_idx = (ushort)idx2;
                                        if (ic2.key != null) { vm.heap.decref((types::HeapHeader*)ic2.key); }
                                        ic2.key = key2;
                                        if (key2 != null) { ((types::HeapHeader*)key2).incref(); }
                                        ic2.prop_value_ptr = &r2.owner.prop_values()[idx2];
                                        ic2.cached_prop_alloc = (void*)r2.owner.prop_values();
                                    }
                                }
                            } else if (r2.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                                // Accessor on the second hop: synchronous
                                // getter call with this = the hop-1 result.
                                TVal getter2 = r2.acc.accessor_fn;
                                if (!getter2.is_undefined() && !getter2.is_null() && vm.heap.call_fn != null) {
                                    TVal gv2 = vm.heap.call_fn(vm, getter2, null, 0, mid_val);
                                    if (vm.heap.has_error) {
                                        vm.heap.has_error = false;
                                        TVal err_gv2 = vm.heap.error_value;
                                        if (!vm_throw_value(vm, err_gv2, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                            vm.has_error = true;
                                            vm.heap.has_error = true;
                                            return VM_ERROR~;
                                        }
                                        return (TVal){};
                                    }
                                    vm.heap.tval_copy_ref(ra2, &gv2);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else {
                                    ra2.set_undefined();
                                }
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_lightfunc()) {
                    // LIGHTFUNC intermediate: resolve .name/.length/.prototype from metadata,
                    // other props from Function.prototype (mirrors GETPROPC lightfunc handling).
                    uint lf_fn_idx = (uint)(usz)mid_val.get_heapptr();
                    if (key2_hstr != null) {
                        if (key2_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 0)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx);
                                if (lf_meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, lf_meta.name);
                                    vm.heap.set_reg_string(ra2, name_str);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 1)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx);
                                if (lf_meta.arity >= 0) {
                                    ra2.set_number(lf_meta.arity);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 2)) {
                                HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx);
                                if (lf_proto != null) {
                                    ra2.set_object(lf_proto);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                            else { ra2.set_undefined(); }
                        } else { ra2.set_undefined(); }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    // STRING intermediate: auto-box for hop 2 (mirrors GETPROPC string handling).
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && mid_str.is_symbol() && vm.heap.symbol_proto != null) {
                        if (key2_hstr != null) {
                            getprop2_symbol_hop(vm, ds, mid_val, key2_hstr, ra2, dst2_reg);
                            if (vm.has_error) return VM_ERROR~;
                            if (ds.needs_restart) return (TVal){};
                        } else {
                            ra2.set_undefined();
                        }
                    } else if (key2_hstr != null) {
                        // .length fast path
                        if ((void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    // NUMBER intermediate: auto-box for hop 2.
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    // BOOLEAN intermediate: auto-box for hop 2.
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store intermediate result in ra (temp register)
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else if (rb.is_string()) {
                // rb is a string primitive — auto-box for hop 1, then hop 2 on the result.
                TVal mid_val;
                mid_val.set_undefined();
                HString* rb_str = (HString*)rb.get_heapptr();
                if (rb_str != null && key1_hstr != null) {
                    if (rb_str.is_symbol() && vm.heap.symbol_proto != null) {
                        // Auto-box symbol primitive: wrapper object so accessor
                        // properties (like description) work correctly. Getter is
                        // invoked synchronously (mirrors the object-hop1 accessor
                        // case above) since a frame-based invoke_getter would
                        // resume past the fused pair and skip hop 2 entirely.
                        HObject*? wrapper_raw1 = vm.heap.alloc_object(hobject::ObjClass.SYMBOL);
                        HObject* wrapper1;
                        if (try w = wrapper_raw1) {
                            wrapper1 = w;
                            wrapper1.prototype = vm.heap.symbol_proto;
                            wrapper1.extra_ptr().prim.primitive_value = *rb;
                            hobject::PropLookupResult r1s = wrapper1.get_prop_or_accessor_proto((void*)key1_hstr, true);
                            if (r1s.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                                TVal getter1s = r1s.acc.accessor_fn;
                                if (!getter1s.is_undefined() && !getter1s.is_null() && vm.heap.call_fn != null) {
                                    TVal wrapper1_tv;
                                    wrapper1_tv.set_object(wrapper1);
                                    mid_val = vm.heap.call_fn(vm, getter1s, null, 0, wrapper1_tv);
                                    if (vm.heap.has_error) {
                                        vm.heap.has_error = false;
                                        TVal err1s = vm.heap.error_value;
                                        if (!vm_throw_value(vm, err1s, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                            vm.has_error = true;
                                            vm.heap.has_error = true;
                                            return VM_ERROR~;
                                        }
                                        return (TVal){};
                                    }
                                }
                            } else if (r1s.kind == hobject::PropLookupKind.PROP_DATA) {
                                mid_val = r1s.data_val;
                            }
                        }
                    } else {
                        if ((void*)key1_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            mid_val.set_fastint((long)rb_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key1_hstr);
                            if (try v = result) { mid_val = v; }
                        }
                    }
                }

                // Hop 2: mid_val[key2] (simplified — no IC)
                if (mid_val.is_object()) {
                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    if (hobj2 != null && key2_hstr != null) {
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto((void*)key2_hstr, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_lightfunc()) {
                    uint lf_fn_idx2 = (uint)(usz)mid_val.get_heapptr();
                    if (key2_hstr != null) {
                        if (key2_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 0)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, lf_meta.name);
                                    vm.heap.set_reg_string(ra2, name_str);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 1)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.arity >= 0) {
                                    ra2.set_number(lf_meta.arity);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 2)) {
                                HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx2);
                                if (lf_proto != null) {
                                    ra2.set_object(lf_proto);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                            else { ra2.set_undefined(); }
                        } else { ra2.set_undefined(); }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && key2_hstr != null) {
                        // Always check for "length" by string content, not just
                        // by pointer identity — the constant pool may have a
                        // different HString instance for "length" than the
                        // BuiltinStr.LENGTH sentinel. Same pattern as in GETPROPC.
                        bool key2_is_length = (key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH])
                            || key2_hstr.equals("length");
                        if (key2_is_length) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (mid_str.is_symbol() && vm.heap.symbol_proto != null) {
                            getprop2_symbol_hop(vm, ds, mid_val, key2_hstr, ra2, dst2_reg);
                            if (vm.has_error) return VM_ERROR~;
                            if (ds.needs_restart) return (TVal){};
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store mid_val in ra
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else if (rb.is_lightfunc()) {
                // LIGHTFUNC source for hop 1: resolve .name/.length/.prototype from
                // metadata, other props from Function.prototype. Mirrors the
                // non-fused GETPROP lightfunc handling so chained accesses like
                // `URIError.prototype.constructor` work (session 219 B16 fix).
                TVal mid_val;
                mid_val.set_undefined();
                uint lf_fn_idx = (uint)(usz)rb.get_heapptr();
                if (key1_hstr != null) {
                    if (key1_hstr.equals("name")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 0)) {
                            builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx);
                            if (lf_meta.name.len > 0) {
                                HString* name_str = intern_string(vm, lf_meta.name);
                                vm.heap.set_reg_string(ra, name_str);
                                mid_val.set_string(name_str);
                            } else { ra.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key1_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); mid_val = v; }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key1_hstr.equals("length")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 1)) {
                            builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx);
                            if (lf_meta.arity >= 0) {
                                ra.set_number(lf_meta.arity);
                                mid_val.set_number(lf_meta.arity);
                            } else { ra.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key1_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); mid_val = v; }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key1_hstr.equals("prototype")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 2)) {
                            HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx);
                            if (lf_proto != null) {
                                ra.set_object(lf_proto);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                                mid_val.set_object(lf_proto);
                            } else { ra.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key1_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); mid_val = v; }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (vm.heap.function_proto != null) {
                        TVal? r = vm.heap.function_proto.get_prop_proto((void*)key1_hstr);
                        if (try v = r) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); mid_val = v; }
                        else { ra.set_undefined(); }
                    } else { ra.set_undefined(); }
                } else { ra.set_undefined(); }

                // === Hop 2: mid_val[key2] (full dispatch, same as object-source path) ===
                if (mid_val.is_object()) {
                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    uint pc2 = (uint)(ds.curr_pc - 1 - ds.code_base);  // pc of the data slot

                    // IC fast path for hop 2
                    if (ds.ic_base != null && key2_hstr != null) {
                        hobject::ICEntry* ic2 = ds.ic_base + pc2;
                        if (ic2.key == (void*)key2_hstr && ic2.shape_id == hobj2.shape_id) {
                            HObject* owner2;
                            if (ic2.proto == null) {
                                owner2 = hobj2;
                            } else if (hobj2.prototype == (HObject*)ic2.proto) {
                                owner2 = (HObject*)ic2.proto;
                            } else {
                                owner2 = null;
                            }
                            if (owner2 != null && ic2.cached_prop_alloc == (void*)owner2.prop_values()) {
                                TVal ic2_val = *ic2.prop_value_ptr;
                                if (!ic2_val.is_heap_allocated()) {
                                    *ra2 = ic2_val;
                                } else {
                                    vm.heap.tval_copy_ref(ra2, &ic2_val);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                }
                                // Also store the intermediate result in ra (temp register)
                                if (mid_val.is_heap_allocated()) {
                                    vm.heap.tval_copy_ref(ra, &mid_val);
                                    track_heap_store(ds.act, ra, (uint)insn.a);
                                } else {
                                    *ra = mid_val;
                                }
                                return (TVal){};
                            }
                        }
                    }

                    // Full lookup for hop 2 if IC miss
                    if (key2_hstr != null) {
                        // ARRAY .length fast path
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            void* key2 = (void*)key2_hstr;
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto(key2, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(ds.act, ra2, dst2_reg);
                                // Populate IC2 — only cache OWN property lookups (see GETPROP).
                                if (r2.owner == hobj2 && r2.owner != null && ds.ic_base != null) {
                                    hobject::ICEntry* ic2 = ds.ic_base + pc2;
                                    int idx2 = r2.owner.find_prop_idx(key2);
                                    if (idx2 >= 0) {
                                        ic2.shape_id = hobj2.shape_id;
                                        ic2.proto = null;  // own property
                                        ic2.prop_idx = (ushort)idx2;
                                        if (ic2.key != null) { vm.heap.decref((types::HeapHeader*)ic2.key); }
                                        ic2.key = key2;
                                        if (key2 != null) { ((types::HeapHeader*)key2).incref(); }
                                        ic2.prop_value_ptr = &r2.owner.prop_values()[idx2];
                                        ic2.cached_prop_alloc = (void*)r2.owner.prop_values();
                                    }
                                }
                            } else if (r2.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                                // Accessor on the second hop: synchronous
                                // getter call with this = the hop-1 result.
                                TVal getter2 = r2.acc.accessor_fn;
                                if (!getter2.is_undefined() && !getter2.is_null() && vm.heap.call_fn != null) {
                                    TVal gv2 = vm.heap.call_fn(vm, getter2, null, 0, mid_val);
                                    if (vm.heap.has_error) {
                                        vm.heap.has_error = false;
                                        TVal err_gv2b = vm.heap.error_value;
                                        if (!vm_throw_value(vm, err_gv2b, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                            vm.has_error = true;
                                            vm.heap.has_error = true;
                                            return VM_ERROR~;
                                        }
                                        return (TVal){};
                                    }
                                    vm.heap.tval_copy_ref(ra2, &gv2);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else {
                                    ra2.set_undefined();
                                }
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_lightfunc()) {
                    // LIGHTFUNC intermediate: resolve .name/.length/.prototype from metadata,
                    // other props from Function.prototype (mirrors GETPROPC lightfunc handling).
                    uint lf_fn_idx2 = (uint)(usz)mid_val.get_heapptr();
                    if (key2_hstr != null) {
                        if (key2_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 0)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, lf_meta.name);
                                    vm.heap.set_reg_string(ra2, name_str);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 1)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.arity >= 0) {
                                    ra2.set_number(lf_meta.arity);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 2)) {
                                HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx2);
                                if (lf_proto != null) {
                                    ra2.set_object(lf_proto);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                            else { ra2.set_undefined(); }
                        } else { ra2.set_undefined(); }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    // STRING intermediate: auto-box for hop 2 (mirrors GETPROPC string handling).
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && mid_str.is_symbol() && vm.heap.symbol_proto != null) {
                        if (key2_hstr != null) {
                            getprop2_symbol_hop(vm, ds, mid_val, key2_hstr, ra2, dst2_reg);
                            if (vm.has_error) return VM_ERROR~;
                            if (ds.needs_restart) return (TVal){};
                        } else {
                            ra2.set_undefined();
                        }
                    } else if (key2_hstr != null) {
                        // .length fast path — check by content, not just pointer identity.
                        bool key2_is_length = ((void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH])
                            || key2_hstr.equals("length");
                        if (key2_is_length) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    // NUMBER intermediate: auto-box for hop 2.
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    // BOOLEAN intermediate: auto-box for hop 2.
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store intermediate result in ra (temp register)
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else if (rb.is_number() || rb.is_fastint()) {
                // NUMBER source: auto-box via Number.prototype for hop 1.
                TVal mid_val;
                mid_val.set_undefined();
                if (key1_hstr != null && vm.heap.number_proto != null) {
                    TVal? result = vm.heap.number_proto.get_prop_proto((void*)key1_hstr);
                    if (try v = result) { mid_val = v; }
                }

                // Common hop 2 dispatch (simplified, no IC — same pattern as string source).
                if (mid_val.is_object()) {
                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    if (hobj2 != null && key2_hstr != null) {
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto((void*)key2_hstr, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_lightfunc()) {
                    uint lf_fn_idx2 = (uint)(usz)mid_val.get_heapptr();
                    if (key2_hstr != null) {
                        if (key2_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 0)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, lf_meta.name);
                                    vm.heap.set_reg_string(ra2, name_str);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 1)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.arity >= 0) {
                                    ra2.set_number(lf_meta.arity);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 2)) {
                                HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx2);
                                if (lf_proto != null) {
                                    ra2.set_object(lf_proto);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                            else { ra2.set_undefined(); }
                        } else { ra2.set_undefined(); }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && key2_hstr != null) {
                        bool key2_is_length = ((void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH])
                            || key2_hstr.equals("length");
                        if (key2_is_length) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store mid_val in ra
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else if (rb.is_boolean()) {
                // BOOLEAN source: auto-box via Boolean.prototype for hop 1.
                TVal mid_val;
                mid_val.set_undefined();
                if (key1_hstr != null && vm.heap.bool_proto != null) {
                    TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key1_hstr);
                    if (try v = result) { mid_val = v; }
                }

                // Common hop 2 dispatch (simplified, no IC — same pattern as string source).
                if (mid_val.is_object()) {
                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    if (hobj2 != null && key2_hstr != null) {
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto((void*)key2_hstr, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_lightfunc()) {
                    uint lf_fn_idx2 = (uint)(usz)mid_val.get_heapptr();
                    if (key2_hstr != null) {
                        if (key2_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 0)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, lf_meta.name);
                                    vm.heap.set_reg_string(ra2, name_str);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 1)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.arity >= 0) {
                                    ra2.set_number(lf_meta.arity);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 2)) {
                                HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx2);
                                if (lf_proto != null) {
                                    ra2.set_object(lf_proto);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                            else { ra2.set_undefined(); }
                        } else { ra2.set_undefined(); }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && key2_hstr != null) {
                        bool key2_is_length = ((void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH])
                            || key2_hstr.equals("length");
                        if (key2_is_length) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store mid_val in ra
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else {
                // rb is not a recognised type — both hops fail
                ra.set_undefined();
                ra2.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.PUTPROP:
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();

                // ES5 strict mode: function.caller = ... and function.arguments = ...
                // throw TypeError (AddRestrictedFunctionProperties poison pill).
                // Strict-only engine: always throws — unless the function has its own
                // property of that name (e.g. a class's own `static set arguments`).
                if (hobj.is_callable() && hobj.get_class() == hobject::ObjClass.FUNCTION && rb.is_string()) {
                    HString* key_hstr = (HString*)rb.get_heapptr();
                    if (key_hstr != null && (key_hstr.equals("caller") || key_hstr.equals("arguments"))
                        && hobj.find_prop_idx((void*)key_hstr) < 0) {
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                }

                // Proxy exotic: route through [[Set]].
                if (hobj.flags.exotic_proxyobj) {
                    void* pkey = get_prop_key(vm, rb);
                    if (pkey == null) { return (TVal){}; }
                    bool set_ok;
                    if (!builtins::proxy_mop_set(vm, vm.heap, hobj, (HString*)pkey, *rc, *ra, &set_ok)) {
                        return vm_proxy_rethrow(vm, ds);
                    }
                    if (!set_ok) {
                        // Strict-only engine: [[Set]] returning false throws.
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "'set' on proxy: trap returned falsish", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                    }
                    return (TVal){};
                }

                // TypedArray element write: convert FIRST, bounds-check AFTER
                // (ToNumber on rc can run user code — e.g. valueOf — that
                // detaches the buffer; spec requires the conversion to happen
                // regardless, then silently drop the store if now OOB).
                if (builtins::is_typed_array_class(hobj.get_class())
                    && (rb.is_fastint() || rb.is_number())) {
                    long idx_long = rb.is_fastint() ? rb.get_fastint() : (long)rb.get_number();
                    bool is_int_idx = rb.is_fastint() || rb.get_number() == (double)idx_long;
                    hobject::ObjClass ta_cls = hobj.get_class();

                    BuiltinContext conv_ctx;
                    conv_ctx.vm = vm;
                    conv_ctx.heap = vm.heap;
                    conv_ctx.should_throw = false;
                    TVal converted = *rc;
                    // Only run the (possibly side-effecting) conversion when
                    // the index is a plausible integer — non-integer/negative
                    // indices are ignored per CanonicalNumericIndexString
                    // without needing to touch the value at all here, matching
                    // the "assignment is a no-op" spec outcome.
                    if (is_int_idx && idx_long >= 0) {
                        char[8] scratch;
                        builtins::ta_write_element((char*)&scratch, ta_cls, &converted, &conv_ctx);
                        if (conv_ctx.should_throw) {
                            if (!vm_throw_value(vm, conv_ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return vm_uncaught_error(vm, &conv_ctx.throw_value);
                            }
                            return (TVal){};
                        }

                        HObject* buf = (*hobj.extra_ptr()).view.buffer;
                        uint shift = builtins::ta_elem_shift(ta_cls);
                        uint elem_count = (*hobj.extra_ptr()).view.byte_length >> shift;
                        if (buf != null && (*buf.extra_ptr()).ab.data != null
                            && (ulong)idx_long < (ulong)elem_count) {
                            char* base = (*buf.extra_ptr()).ab.data + (*hobj.extra_ptr()).view.byte_offset;
                            char* p = base + (idx_long << shift);
                            builtins::ta_write_element(p, ta_cls, &converted, &conv_ctx);
                        }
                        // OOB/detached after conversion — spec: silently succeed.
                    }
                    return (TVal){};
                }

                // Fast path: dense array indexed store (a[i] = v where i is a valid array index)
                // ES5 §15.4: array index P satisfies ToString(ToUint32(P))===P && ToUint32(P)≠2^32−1
                // Cap at 2^24 to avoid insane allocations for sparse arrays with huge indices.
                // Guard with array_part() != null — after seal/freeze the array part is
                // abandoned and elements live as named properties with proper flags.
                if ((hobj.get_class() == hobject::ObjClass.ARRAY || hobj.get_class() == hobject::ObjClass.ARGUMENTS)
                    && hobj.array_part() != null
                    && (rb.is_fastint() || rb.is_number())) {
                    long idx_long = rb.is_fastint() ? rb.get_fastint() : (long)rb.get_number();
                    if (idx_long >= 0 && idx_long < 0xFFFFFFFFL && idx_long < 0x1000000L) {
                        uint idx = (uint)idx_long;
                        if (hobj.set_array_idx(idx, *rc)) {
                            // Update .length fast: use array_length field directly (ARRAY only)
                            if (hobj.get_class() == hobject::ObjClass.ARRAY && idx >= *hobj.array_len_ptr()) {
                                *hobj.array_len_ptr() = idx + 1;
                            }
                            return (TVal){};
                        }
                        // Dense write failed (index beyond capacity cap) — fall through to put_prop.
                    }
                }

                // Integer-indexed exotic [[Set]] (ES2022 §9.4.5.5) for TypedArray string keys.
                // This handles the case where receiver == hobj (the TypedArray itself).
                // - Arridx string key ("0", "1", …): IntegerIndexedElementSet — convert value,
                //   write if in-bounds (or no-op if OOB/detached).
                // - Non-arridx numeric-looking keys ("1.5", "-0", "NaN"): silently no-op.
                if (rb.is_string()
                    && builtins::is_typed_array_class(hobj.get_class())) {
                    HString* key_hstr = (HString*)rb.get_heapptr();
                    if (key_hstr != null && !key_hstr.is_symbol()) {
                        if (key_hstr.is_arridx()) {
                            // Array-index string key: perform IntegerIndexedElementSet.
                            // Value conversion (ToNumber) runs FIRST, THEN bounds check.
                            hobject::ObjClass ta_cls = hobj.get_class();
                            BuiltinContext conv_ctx;
                            conv_ctx.vm = vm;
                            conv_ctx.heap = vm.heap;
                            conv_ctx.should_throw = false;
                            TVal converted = *rc;
                            char[8] scratch;
                            builtins::ta_write_element((char*)&scratch, ta_cls, &converted, &conv_ctx);
                            if (conv_ctx.should_throw) {
                                if (!vm_throw_value(vm, conv_ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return vm_uncaught_error(vm, &conv_ctx.throw_value);
                                }
                                return (TVal){};
                            }
                            uint idx = key_hstr.array_index();
                            HObject* buf = (*hobj.extra_ptr()).view.buffer;
                            uint shift = builtins::ta_elem_shift(ta_cls);
                            uint elem_count = (*hobj.extra_ptr()).view.byte_length >> shift;
                            if (buf != null && (*buf.extra_ptr()).ab.data != null
                                && (ulong)idx < (ulong)elem_count) {
                                char* base = (*buf.extra_ptr()).ab.data + (*hobj.extra_ptr()).view.byte_offset;
                                char* p = base + ((ulong)idx << shift);
                                builtins::ta_write_element(p, ta_cls, &converted, &conv_ctx);
                            }
                            // OOB/detached after conversion: spec says silently succeed.
                            return (TVal){};
                        } else {
                            double cni_d;
                            if (builtins::is_canonical_numeric_index(vm.heap, key_hstr, &cni_d)) {
                                return (TVal){};
                            }
                        }
                    }
                }

                // Inline Cache fast path for own property writes (string keys only)
                if (ds.ic_base != null && rb.is_string()) {
                    uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                    hobject::ICEntry* ic = ds.ic_base + pc_off;
                    void* wkey = rb.get_heapptr();
                    if (wkey != null && ic.key == wkey && ic.shape_id == hobj.shape_id && ic.proto == null) {
                        if (ic.cached_prop_alloc == (void*)hobj.prop_values()
                            && !ic.prop_flags.is_accessor
                            && ic.prop_flags.writable) {
                            vm.heap.tval_copy_ref(ic.prop_value_ptr, rc);
                            return (TVal){};
                        }
                    }
                }

                // ARRAY exotic: .length write fast path — update array_length directly
                if (hobj.get_class() == hobject::ObjClass.ARRAY && rb.is_string() && rb.get_heapptr() == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                    // ES5 §15.4.5.1 step 2 (ArraySetLength): validate the new length value
                    // before truncating. ToUint32(v) must equal ToNumber(v), and the result
                    // must be < 2^32. Otherwise throw RangeError.
                    bool length_valid = true;
                    uint new_len = 0;
                    if (rc.is_undefined()) {
                        // Per ES2024 §10.4.2.1 ArraySetLength: ToUint32(undefined)=0,
                        // ToNumber(undefined)=NaN, 0 ≠ NaN → throw RangeError.
                        length_valid = false;
                        new_len = 0;
                    } else if (rc.is_fastint()) {
                        long v = rc.get_fastint();
                        if (v < 0L || v > 0xFFFFFFFFL) {
                            length_valid = false;
                        } else {
                            new_len = (uint)v;
                        }
                    } else if (rc.is_number()) {
                        double raw = rc.get_number();
                        // NaN, ±Infinity, or non-integer, or negative, or > 2^32-1
                        if (raw != raw || raw < 0.0 || raw > 4294967295.0 || raw != math::floor(raw)) {
                            length_valid = false;
                        } else {
                            new_len = (uint)raw;
                        }
                    } else {
                        // Non-number primitives or objects: coerce to number per
                        // ES2024 §10.4.2.1 ArraySetLength step 3 (ToNumber on v),
                        // then re-validate as uint32. The slow put_prop path uses
                        // [[DefineOwnProperty]] and never reaches here — and even
                        // if it did, set_length would still need a number, so we
                        // do it ourselves with proper valueOf/toString propagation.
                        TVal conv_src = *rc;
                        if (conv_src.is_string()) {
                            HString* s = (HString*)conv_src.get_heapptr();
                            if (s != null && s.is_symbol()) {
                                if (!vm_throw_error(vm, vm.heap.type_err_proto,
                                    "Cannot convert a Symbol value to a number",
                                    ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return VM_ERROR~;
                                }
                                return (TVal){};
                            }
                        }
                        if (conv_src.is_object() && conv_src.get_heapptr() != null) {
                            TVal prim = vm::to_primitive_value(vm, &conv_src, 2);
                            if (vm.throw_pending) {
                                TVal t = vm.throw_value;
                                vm.throw_pending = false;
                                if (!vm_throw_value(vm, t, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return vm_uncaught_error(vm, &t);
                                }
                                return (TVal){};
                            }
                            conv_src = prim;
                        }
                        // Coerce to number via the same string_to_double helper
                        // the cast machinery uses. Boolean primitive: ToNumber
                        // yields 0/1; null=0; undefined=NaN.
                        double d;
                        if (conv_src.is_boolean()) {
                            d = conv_src.get_boolean() ? 1.0 : 0.0;
                        } else if (conv_src.is_null()) {
                            d = 0.0;
                        } else if (conv_src.is_undefined()) {
                            d = 0.0 / 0.0;  // NaN — ToUint32(0)≠NaN → RangeError below
                        } else if (conv_src.is_fastint() || conv_src.is_number()) {
                            d = conv_src.is_fastint() ? (double)conv_src.get_fastint()
                                                     : conv_src.get_number();
                        } else if (conv_src.is_string()) {
                            d = builtins::string_to_double(&conv_src);
                        } else {
                            // Should have been handled above (symbols thrown, objects
                            // converted). Fall back to NaN to surface a RangeError.
                            d = 0.0 / 0.0;
                        }
                        if (d != d || d < 0.0 || d > 4294967295.0 || d != math::floor(d)) {
                            length_valid = false;
                        } else {
                            new_len = (uint)d;
                        }
                    }
                    if (!length_valid) {
                        if (!vm_throw_error(vm, vm.heap.range_err_proto, "Invalid array length", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    // Per ES2024 §10.4.2.1 ArraySetLength, undefined is coerced via
                    // ToUint32→0 / ToNumber→NaN, and 0 ≠ NaN → RangeError. Other
                    // primitive/object fall through to the general coercion path
                    // below; if it produces an invalid new_len, we already threw
                    // RangeError, so nothing extra here.
                    bool length_coerced_ok = length_valid;
                    if (length_coerced_ok) {
                        // Check that the length property is writable before modifying it.
                        // A non-writable array length must silently reject in sloppy mode.
                        bool len_writable = true;
                        HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                        if (len_str != null) {
                            int len_idx = hobj.find_prop_idx(len_str);
                            if (len_idx >= 0) {
                                len_writable = hobj.get_prop_flags((uint)len_idx).writable;
                            }
                        }
                        if (len_writable) {
                            // Use the array helper so shrinking length deletes stale
                            // dense slots and named properties.
                            builtins::array_set_length(hobj, new_len, vm.heap);
                        }
                        // Non-writable: sloppy mode silently ignores the write.
                        // Strict mode would throw, but that is handled by the caller.
                    }
                    return (TVal){};
                }

                void* key = get_prop_key(vm, rb);
                if (key == null && vm.throw_pending) {
                    vm.throw_pending = false;
                    if (!vm_throw_value(vm, vm.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &vm.throw_value);
                    }
                    return (TVal){};
                }
                if (key != null) {
                    // Save the value before ensure_valstack may reallocate
                    TVal put_val = *rc;

                    // Single find_prop_idx call for both existence check and accessor check
                    int exist_idx = hobj.find_prop_idx(key);
                    if (exist_idx >= 0) {
                        TVal* entry = &hobj.prop_values()[exist_idx];
                        hobject::PropFlags exist_flags = hobj.get_prop_flags((uint)exist_idx);
                        if (exist_flags.is_accessor) {
                            // Accessor property — invoke setter
                            TVal setter_fn = hobject::hobject_access_setter(*entry);
                            // No setter (get-only accessor): §10.1.9.3 / OrdinarySet
                            // step returns false; PutValue only turns that into a
                            // TypeError for a strict reference (§13.15.2) — code
                            // compiled without "use strict" silently no-ops instead.
                            if (!setter_fn.is_object() || setter_fn.get_heapptr() == null) {
                                if (vm.current_func != null && vm.current_func.is_strict()) {
                                    HString* nm = (HString*)key;
                                    if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Cannot set property '%s' which has only a getter", nm.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        return VM_ERROR~;
                                    }
                                }
                                return (TVal){};
                            }
                            if (setter_fn.is_object() && setter_fn.get_heapptr() != null) {
                                HObject* setter_obj = (HObject*)setter_fn.get_heapptr();
                                // BUILTIN_FN setter (e.g. Function.prototype.caller/arguments
                                // thrower). Stage a call frame with [callee, this, value]
                                // mirroring the regular BUILTIN_FN dispatch — the setter
                                // receives one argument (the assigned value) and the receiver
                                // is the accessor-owning object. Stage above the current
                                // activation's frame (not at vm.valstack[0..2]) so parent
                                // activation data is preserved.
                                if (setter_obj.is_callable()
                                    && setter_obj.callable_kind() == hobject::CallableKind.BUILTIN_FN
                                    && (*setter_obj.extra_ptr()).func.builtin_fn_index >= 0) {
                                    uint setter_fn_idx = (uint)(*setter_obj.extra_ptr()).func.builtin_fn_index;
                                    // Determine staging slot above the current activation's
                                    // register frame. PUTPROP's A/B/C are arbitrary live
                                    // locals so A+1.. cannot be used as scratch (unlike
                                    // GETPROP). num_regs may be unreliable for builtin-driven
                                    // frames; use vm.valstack_top clamped to bottom+num_regs.
                                    uint cur_num_regs = ds.act.func != null
                                        ? ((CompiledFunction*)ds.act.func).num_regs
                                        : (uint)(vm.valstack_top - ds.act.bottom);
                                    uint stage_offset = cur_num_regs;
                                    uint needed = (uint)(ds.act.bottom - vm.valstack) + stage_offset + 4;
                                    if (!ensure_valstack(vm, needed)) {
                                        return VM_ERROR~;
                                    }
                                    ds.regs_base = ds.act.bottom;
                                    TVal* stage = ds.act.bottom + stage_offset;
                                    // Advance valstack_top past the staged frame so builtin
                                    // dispatchers (e.g. those that re-enter the VM) see
                                    // GC-visible memory.
                                    TVal* stage_top = stage + 4;
                                    if (stage_top > vm.valstack_top) { vm.valstack_top = stage_top; }

                                    TVal setter_result; setter_result.set_undefined();
                                    builtins::BuiltinContext sctx;
                                    sctx.vm = vm;
                                    // regs = vm.valstack; base_reg = offset to stage, so the
                                    // builtin reads regs[base_reg-2] = stage[0] = callee,
                                    // regs[base_reg-1] = stage[1] = this, regs[base_reg] =
                                    // stage[2] = put_val. No incref on the staged callee/this
                                    // slots because the thrower builtin never reads its args
                                    // (and any future builtin setter would own these slots
                                    // for the dispatch's lifetime).
                                    sctx.regs = vm.valstack;
                                    sctx.base_reg = (ushort)((uint)(stage - vm.valstack) + 2);
                                    sctx.argc = 1;
                                    sctx.result = &setter_result;
                                    sctx.heap = vm.heap;
                                    TVal setter_this; setter_this.set_object(hobj);
                                    sctx.this_val = setter_this;
                                    sctx.is_constructor = false;
                                    sctx.needs_re_dispatch = false;
                                    sctx.re_nargs = 0;
                                    sctx.global_env = vm.global_env;
                                    sctx.should_throw = false;
                                    sctx.callee_obj = setter_obj;
                                    stage[0] = setter_fn;
                                    stage[1] = setter_this;
                                    // incref the assigned value's heap ptr so the builtin
                                    // dispatch's cleanup decref balances the copy at stage[2].
                                    if (put_val.is_heap_allocated()) {
                                        ((types::HeapHeader*)put_val.get_heapptr()).incref();
                                    }
                                    stage[2] = put_val;
                                    builtins::dispatch_builtin(setter_fn_idx, &sctx);
                                    ds.regs_base = ds.act.bottom;
                                    // Cleanup: decrement the borrowed reference at stage[2]
                                    // (the builtin dispatch path doesn't always decref args).
                                    vm.heap.decref_tval(&stage[2]);
                                    if (sctx.should_throw) {
                                        if (!vm_throw_value(vm, sctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                            return vm_uncaught_error(vm, &sctx.throw_value);
                                        }
                                        return (TVal){};
                                    }
                                    return (TVal){};
                                }
                                if (setter_obj.is_callable() && (*setter_obj.extra_ptr()).func.comp_func != null) {
                                    CompiledFunction* target = (*setter_obj.extra_ptr()).func.comp_func;
                                    // Stage the call frame above the caller's live registers:
                                    // PUTPROP's A/B/C are arbitrary live locals, so A+1.. cannot
                                    // be used as scratch (unlike GETPROP where A is a fresh temp).
                                    // Note: vm.valstack_top is not reliable here (builtin calls
                                    // may leave it below bottom + num_regs), so use num_regs.
                                    uint callee_reg = ds.act.func != null
                                        ? ((CompiledFunction*)ds.act.func).num_regs
                                        : (uint)(vm.valstack_top - ds.act.bottom);
                                    uint frame_start = callee_reg + 2;
                                    TVal* new_bottom = ds.act.bottom + frame_start;
                                    uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                                    if (ensure_valstack(vm, needed) && vm.activation_count < MAX_CALLS) {
                                        new_bottom = ds.act.bottom + frame_start;
                                        TVal* caller_regs = ds.act.bottom;

                                        // Raw stores: these slots are above the initialized frame,
                                        // so tval_copy_ref would decref stale garbage. The setter fn
                                        // and object are kept alive by the property entry and ra.
                                        caller_regs[callee_reg] = setter_fn;
                                        TVal obj_tv;
                                        obj_tv.set_object(hobj);
                                        caller_regs[callee_reg + 1] = obj_tv;

                                        Activation* new_act = &vm.activations[vm.activation_count];
                                        vm.activation_count++;
                                        new_act.max_heap_reg = 0;
                                        new_act.caller_valstack_top = vm.valstack_top;

                                        EnvRecord* setter_var_env = (*setter_obj.extra_ptr()).func.var_env;
                                        if (try fv_s = env::env_create_function_scope(vm.heap, (*setter_obj.extra_ptr()).func.var_env)) { setter_var_env = fv_s; }
                                        new_act.parent = ds.act;
                                        new_act.func = target;
                                        new_act.var_env = setter_var_env;
                                        new_act.lex_env = resolve_call_lex_env(vm, setter_obj, target, setter_var_env);
                                        new_act.cat = null;
                                        new_act.curr_pc = target.code;
                                        new_act.bottom = new_bottom;
                                        new_act.retval = null;  // setter return value is discarded
                                        new_act.flags = 0;
                                        if (target.has_direct_eval()) {
                                            new_act.flags |= ACT_FLAG_DIRECT_EVAL;
                                        }
                                        vm.heap.tval_copy_ref(&new_act.this_binding, &obj_tv);

                                        TVal* new_regs = new_act.bottom;
                                        mem::clear(new_regs, (sz)((usz)target.num_regs * TVal::size));
                                        // A setter always receives exactly one argument (the
                                        // assigned value). Any additional declared formal
                                        // parameters must be `undefined`, not the raw zeroed
                                        // bytes from memset (which decode as fastint 0 in this
                                        // TVal encoding, not undefined).
                                        for (uint pi = 1; pi < target.num_regs; pi++) {
                                            new_regs[pi].set_undefined();
                                        }
                                        vm.heap.tval_copy_ref(&new_regs[0], &put_val);

                                        vm.valstack_top = new_regs + target.num_regs;
                                        vm.valstack_bottom = new_act.bottom;

                                        ds.act.curr_pc = ds.curr_pc;

                                        ds.needs_restart = true;
                                        return (TVal){};
                                    }
                                }
                            }
                        } else if (!exist_flags.writable) {
                            // Strict-only engine: non-writable property assignment always throws.
                            if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot assign to read only property", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            return (TVal){};
                        } else {
                            // Update value, preserve existing flags
                            vm.heap.tval_copy_ref(entry, &put_val);
                        }
                    } else {
                        // ARRAY exotic: element may live in the dense array part even when
                        // absent from the named-property table (string key "0" on an array
                        // that only has a dense slot at 0). Treat dense elements as own
                        // writable data properties (§10.1.9.2 — own property found → update).
                        TVal dense_existing;
                        if (hobj.dense_arridx_lookup(key, &dense_existing)) {
                            HString* dense_key = (HString*)key;
                            uint dense_ai = (uint)dense_key.array_index();
                            vm.heap.tval_copy_ref(&hobj.array_part()[dense_ai], &put_val);
                            return (TVal){};
                        }

                        // Proxy or TypedArray anywhere on the prototype chain: both
                        // have exotic [[Set]] methods that OrdinarySetWithOwnDescriptor
                        // must recurse into (§9.1.9.2 step 2.b), not treat as a flat
                        // OrdinaryGetOwnProperty lookup — run the full [[Set]]
                        // (receiver = hobj) through js_set_with_receiver.
                        {
                            HObject* pscan = hobj.prototype;
                            uint pdepth = 0;
                            while (pscan != null && pdepth < 256) {
                                if (pscan.flags.exotic_proxyobj || builtins::is_typed_array_class(pscan.get_class())) {
                                    bool sres;
                                    TVal recv_tv; recv_tv.set_object(hobj);
                                    if (!builtins::js_set_with_receiver(vm, vm.heap, hobj, (HString*)key, put_val, recv_tv, &sres)) {
                                        return vm_proxy_rethrow(vm, ds);
                                    }
                                    if (!sres) {
                                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "'set' on proxy: trap returned falsish", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                            return VM_ERROR~;
                                        }
                                    }
                                    return (TVal){};
                                }
                                pscan = pscan.prototype;
                                pdepth++;
                            }
                        }

                        // Property doesn't exist: check prototype for accessors
                        hobject::AccessorResult acc = hobj.find_accessor_proto(key, false);
                        // find_accessor_proto sets found=true for any accessor property on
                        // the chain, even a get-only one (accessor_fn left as undefined in
                        // that case). ES2024 §10.1.9.2 OrdinarySet step 2 returns false for
                        // an inherited accessor with no [[Set]]; PutValue only turns that
                        // into a TypeError for a strict reference (§13.15.2) — code compiled
                        // without "use strict" silently no-ops instead of creating an own
                        // property.
                        if (acc.found && (!acc.accessor_fn.is_object() || acc.accessor_fn.get_heapptr() == null)) {
                            if (vm.current_func != null && vm.current_func.is_strict()) {
                                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot set property which has only a getter", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return VM_ERROR~;
                                }
                            }
                            return (TVal){};
                        }
                        if (acc.found && acc.accessor_fn.is_object() && acc.accessor_fn.get_heapptr() != null) {
                            // Invoke setter from prototype
                            HObject* setter_obj = (HObject*)acc.accessor_fn.get_heapptr();
                            // BUILTIN_FN setter (e.g. Object.prototype.__proto__). Stage a
                            // call frame with [callee, this, value] above the current
                            // activation (mirrors the own-property setter path).
                            if (setter_obj.is_callable()
                                && setter_obj.callable_kind() == hobject::CallableKind.BUILTIN_FN
                                && (*setter_obj.extra_ptr()).func.builtin_fn_index >= 0) {
                                uint setter_fn_idx = (uint)(*setter_obj.extra_ptr()).func.builtin_fn_index;
                                uint cur_num_regs = ds.act.func != null
                                    ? ((CompiledFunction*)ds.act.func).num_regs
                                    : (uint)(vm.valstack_top - ds.act.bottom);
                                uint stage_offset = cur_num_regs;
                                uint needed = (uint)(ds.act.bottom - vm.valstack) + stage_offset + 4;
                                if (!ensure_valstack(vm, needed)) {
                                    return VM_ERROR~;
                                }
                                ds.regs_base = ds.act.bottom;
                                TVal* stage = ds.act.bottom + stage_offset;
                                TVal* stage_top = stage + 4;
                                if (stage_top > vm.valstack_top) { vm.valstack_top = stage_top; }

                                TVal setter_result; setter_result.set_undefined();
                                builtins::BuiltinContext sctx;
                                sctx.vm = vm;
                                sctx.regs = vm.valstack;
                                sctx.base_reg = (ushort)((uint)(stage - vm.valstack) + 2);
                                sctx.argc = 1;
                                sctx.result = &setter_result;
                                sctx.heap = vm.heap;
                                TVal setter_this; setter_this.set_object(hobj);
                                sctx.this_val = setter_this;
                                sctx.is_constructor = false;
                                sctx.needs_re_dispatch = false;
                                sctx.re_nargs = 0;
                                sctx.global_env = vm.global_env;
                                sctx.should_throw = false;
                                sctx.callee_obj = setter_obj;
                                stage[0] = acc.accessor_fn;
                                stage[1] = setter_this;
                                if (put_val.is_heap_allocated()) {
                                    ((types::HeapHeader*)put_val.get_heapptr()).incref();
                                }
                                stage[2] = put_val;
                                builtins::dispatch_builtin(setter_fn_idx, &sctx);
                                ds.regs_base = ds.act.bottom;
                                vm.heap.decref_tval(&stage[2]);
                                if (sctx.should_throw) {
                                    if (!vm_throw_value(vm, sctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        return vm_uncaught_error(vm, &sctx.throw_value);
                                    }
                                }
                                return (TVal){};
                            }
                            if (setter_obj.is_callable() && (*setter_obj.extra_ptr()).func.comp_func != null) {
                                CompiledFunction* target = (*setter_obj.extra_ptr()).func.comp_func;

                                // Stage the call frame above the caller's live registers
                                // (see own-property setter path above).
                                uint callee_reg = ds.act.func != null
                                    ? ((CompiledFunction*)ds.act.func).num_regs
                                    : (uint)(vm.valstack_top - ds.act.bottom);
                                uint frame_start = callee_reg + 2;
                                TVal* new_bottom = ds.act.bottom + frame_start;
                                uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                                if (ensure_valstack(vm, needed) && vm.activation_count < MAX_CALLS) {
                                    new_bottom = ds.act.bottom + frame_start;
                                    TVal* caller_regs = ds.act.bottom;

                                    caller_regs[callee_reg] = acc.accessor_fn;
                                    TVal obj_tv;
                                    obj_tv.set_object(acc.this_obj);
                                    caller_regs[callee_reg + 1] = obj_tv;

                                    Activation* new_act = &vm.activations[vm.activation_count];
                                    vm.activation_count++;
                                    new_act.max_heap_reg = 0;
                                    new_act.caller_valstack_top = vm.valstack_top;

                                    EnvRecord* setter_var_env = (*setter_obj.extra_ptr()).func.var_env;
                                    if (try fv_s = env::env_create_function_scope(vm.heap, (*setter_obj.extra_ptr()).func.var_env)) { setter_var_env = fv_s; }
                                    new_act.parent = ds.act;
                                    new_act.func = target;
                                    new_act.var_env = setter_var_env;
                                    new_act.lex_env = resolve_call_lex_env(vm, setter_obj, target, setter_var_env);
                                    new_act.cat = null;
                                    new_act.curr_pc = target.code;
                                    new_act.bottom = new_bottom;
                                    new_act.retval = null;  // setter return value is discarded
                                    new_act.flags = 0;
                                    if (target.has_direct_eval()) {
                                        new_act.flags |= ACT_FLAG_DIRECT_EVAL;
                                    }
                                    vm.heap.tval_copy_ref(&new_act.this_binding, &obj_tv);

                                    TVal* new_regs = new_act.bottom;
                                    mem::clear(new_regs, (sz)((usz)target.num_regs * TVal::size));
                                    vm.heap.tval_copy_ref(&new_regs[0], &put_val);

                                    vm.valstack_top = new_regs + target.num_regs;
                                    vm.valstack_bottom = new_act.bottom;

                                    ds.act.curr_pc = ds.curr_pc;

                                    ds.needs_restart = true;
                                    return (TVal){};
                                }
                            }
                        } else {
                            // ES5 §8.12.5 [[Set]] step 4 / ES2024 §10.1.9.2 OrdinarySet
                            // step 3: if no accessor on the chain, walk the chain for a
                            // data property. If found and not writable, return false
                            // (silent in sloppy, TypeError in strict). We're strict-only
                            // so always throw.
                            HObject* data_cur = hobj.prototype;
                            uint data_depth = 0;
                            bool proto_nonwritable = false;
                            while (data_cur != null && data_depth < hobject::MAX_PROTO_DEPTH) {
                                int d_idx = data_cur.find_prop_idx(key);
                                if (d_idx >= 0) {
                                    hobject::PropFlags d_flags = data_cur.get_prop_flags((uint)d_idx);
                                    if (!d_flags.is_accessor && !d_flags.writable) {
                                        proto_nonwritable = true;
                                    }
                                    break;  // found a property (data or accessor) — stop
                                }
                                data_cur = data_cur.prototype;
                                data_depth++;
                            }
                            if (proto_nonwritable) {
                                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot assign to read only property", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return VM_ERROR~;
                                }
                                return (TVal){};
                            }
                            // No accessor, no non-writable data on chain: insert new property
                            if (hobj.flags.extensible) {
                                hobj.put_prop(key, put_val, hobject::PROP_FLAGS_WEC);
                            } else {
                                // ES5 §9.1.2 step 5b: if O is not extensible, throw TypeError.
                                // Strict-only engine: always throws.
                                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot add property to non-extensible object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return VM_ERROR~;
                                }
                            }
                        }
                    }
                }
            } else if (ra.is_null() || ra.is_undefined()) {
                // TypeError: Cannot set properties of null/undefined
                HString* name_hstr = null;
                if (rb.is_string()) {
                    name_hstr = (HString*)rb.get_heapptr();
                }
                char[types::ERROR_MSG_BUF] msg_buf;
                int msg_len;
                if (name_hstr != null) {
                    msg_len = (int)(io::bprintf(&msg_buf, "Cannot set properties of %s (setting '%s')",
                                              (ra.is_null() ? "null" : "undefined"),
                                              (ZString)name_hstr.get_cstr()) ?? msg_buf[:0]).len;
                } else {
                    msg_len = (int)(io::bprintf(&msg_buf, "Cannot set properties of %s",
                                              (ra.is_null() ? "null" : "undefined")) ?? msg_buf[:0]).len;
                }
                char[] msg_slice = (msg_len > 0 && msg_len < types::ERROR_MSG_BUF) ? msg_buf[:msg_len] : msg_buf[:0];
                if (!vm_throw_error(vm, vm.heap.type_err_proto, msg_slice, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
            } else {
                // ES6 §6.2.3.2 PutValue: a primitive property base is first
                // boxed with ToObject, then [[Set]] is called with the original
                // primitive as Receiver.  Using the primitive Receiver preserves
                // strict-mode failures for ordinary writes (including immutable
                // string indices), while still allowing inherited setters and
                // Proxy [[Set]] traps to observe the assignment.
                TVal error_base = *ra;
                HString* error_name = rb.is_string() ? (HString*)rb.get_heapptr() : null;
                bool boxable_primitive = ra.is_boolean() || ra.is_number() || ra.is_fastint()
                    || ra.is_bigint() || ra.is_string();  // strings include Symbols
                if (boxable_primitive) {
                    TVal primitive_base = *ra;
                    TVal put_val = *rc;
                    TVal boxed_base;
                    boxed_base.set_undefined();
                    builtins::BuiltinContext box_ctx;
                    box_ctx.heap = vm.heap;
                    box_ctx.result = &boxed_base;
                    if (!builtins::builtin_to_object(&box_ctx, primitive_base)
                        || !boxed_base.is_object() || boxed_base.get_heapptr() == null) {
                        return VM_ERROR~;
                    }

                    void* key = get_prop_key(vm, rb);
                    if (key == null) {
                        if (vm.throw_pending) {
                            vm.throw_pending = false;
                            if (!vm_throw_value(vm, vm.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return vm_uncaught_error(vm, &vm.throw_value);
                            }
                        }
                        return (TVal){};
                    }

                    error_name = (HString*)key;
                    bool set_ok;
                    if (!builtins::js_set_with_receiver(vm, vm.heap,
                        (HObject*)boxed_base.get_heapptr(), (HString*)key,
                        put_val, primitive_base, &set_ok)) {
                        return vm_proxy_rethrow(vm, ds);
                    }
                    if (set_ok) return (TVal){};
                }

                // Strict mode turns [[Set]] returning false into a TypeError.
                // This is the normal result when no inherited setter/proxy
                // handles a write whose Receiver is still primitive.
                HString* type_hstr = typeof_string(vm, &error_base);
                char[types::ERROR_MSG_BUF] msg_buf;
                int msg_len;
                if (error_name != null) {
                    msg_len = (int)(io::bprintf(&msg_buf, "Cannot create property '%s' on %s",
                                              (ZString)error_name.get_cstr(), (ZString)type_hstr.get_cstr()) ?? msg_buf[:0]).len;
                } else {
                    msg_len = (int)(io::bprintf(&msg_buf, "Cannot create property on %s",
                                              (ZString)type_hstr.get_cstr()) ?? msg_buf[:0]).len;
                }
                char[] msg_slice = (msg_len > 0 && msg_len < types::ERROR_MSG_BUF) ? msg_buf[:msg_len] : msg_buf[:0];
                if (!vm_throw_error(vm, vm.heap.type_err_proto, msg_slice, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
            }
            return (TVal){};

        case Opcode.PUTPROP_NE: {
            // A[B] = C as a fresh non-enumerable data property. Only used by
            // the compiler for the `.raw` property of tagged template
            // objects, on a plain array we just created — no exotic
            // receiver (Proxy/TypedArray) is ever passed here.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                if (key != null) {
                    hobj.put_prop(key, *rc, hobject::PROP_FLAGS_NWC);
                }
            }
            return (TVal){};
        }

        case Opcode.PUTPROP_SUPER: {
            // super.x = v — [[Set]] on the super base with receiver = this.
            if (!ra.is_object()) {
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot set property on non-object super base", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }
            void* skey = get_prop_key(vm, rb);
            if (skey == null) {
                if (vm.throw_pending) {
                    vm.throw_pending = false;
                    if (!vm_throw_value(vm, vm.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &vm.throw_value);
                    }
                }
                return (TVal){};
            }
            HObject* super_base = (HObject*)ra.get_heapptr();
            bool sres;
            if (!builtins::js_set_with_receiver(vm, vm.heap, super_base, (HString*)skey, *rc, ds.act.this_binding, &sres)) {
                return vm_proxy_rethrow(vm, ds);
            }
            if (!sres) {
                // Strict-only engine: failed [[Set]] throws.
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot assign to read only property", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
            }
            return (TVal){};
        }

        case Opcode.GETPROP_SUPER: {
            // super[key] / super.prop get — property lookup starts at super base (ra)
            // but accessor getters are invoked with this = current this_binding.
            // Format: A=result, B=super_base, C=key.
            if (!rb.is_object()) {
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot read properties of non-object super base", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }
            void* gkey = get_prop_key(vm, rc);
            if (gkey == null) {
                if (vm.throw_pending) {
                    vm.throw_pending = false;
                    if (!vm_throw_value(vm, vm.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &vm.throw_value);
                    }
                    return (TVal){};
                }
                ra.set_undefined();
                return (TVal){};
            }
            HObject* super_base = (HObject*)rb.get_heapptr();
            hobject::PropLookupResult gres = super_base.get_prop_or_accessor_proto(gkey, true);
            if (gres.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                // Use this_binding as receiver for the getter call.
                TVal this_val = ds.act.this_binding;
                if (invoke_getter(vm, &gres.acc, &this_val, (uint)insn.a,
                                  ds.act, &ds.curr_pc, &ds.needs_restart, ds.regs_base)) {
                    ds.regs_base = ds.act.bottom;
                }
                if (vm.has_error) return VM_ERROR~;
            } else if (gres.kind == hobject::PropLookupKind.PROP_DATA) {
                vm.heap.tval_copy_ref(ra, &gres.data_val);
                track_heap_store(ds.act, ra, (uint)insn.a);
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.DELPROP: {
            // ES5 §11.4.1: delete operator
            // A = delete B[C], where B = object, C = property key
            // Returns boolean: true if deleted or not found,
            // false if the property exists and is non-configurable.

            // ES6 §12.5.3.2 step 5.b: ToObject(base) — throws TypeError
            // for null/undefined. This must run BEFORE the value check,
            // because the runtime semantics require ToObject on the base.
            if (rb.is_null() || rb.is_undefined()) {
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot delete property of null or undefined", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            ra.set_boolean(true);

            if (rb.is_object()) {
                HObject* hobj = (HObject*)rb.get_heapptr();

                // Proxy exotic: route through [[Delete]].
                if (hobj.flags.exotic_proxyobj) {
                    void* pkey = get_prop_key(vm, rc);
                    if (pkey == null) { return (TVal){}; }
                    bool deleted;
                    if (!builtins::proxy_mop_delete(vm, vm.heap, hobj, (HString*)pkey, &deleted)) {
                        return vm_proxy_rethrow(vm, ds);
                    }
                    ra.set_boolean(deleted);
                    if (!deleted) {
                        // Strict-only engine: failed delete throws.
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "'deleteProperty' on proxy: trap returned falsish", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                    }
                    return (TVal){};
                }

                // TypedArray: in-range indices are non-configurable (delete
                // returns false without deleting); out-of-range/detached
                // indices return true per spec (nothing to delete).
                if (builtins::is_typed_array_class(hobj.get_class())
                    && (rc.is_fastint() || rc.is_number())) {
                    long idx_long = rc.is_fastint() ? rc.get_fastint() : (long)rc.get_number();
                    bool is_int_idx = rc.is_fastint() || rc.get_number() == (double)idx_long;
                    if (is_int_idx) {
                        HObject* buf = (*hobj.extra_ptr()).view.buffer;
                        uint shift = builtins::ta_elem_shift(hobj.get_class());
                        uint elem_count = (*hobj.extra_ptr()).view.byte_length >> shift;
                        bool in_range = idx_long >= 0 && buf != null && (*buf.extra_ptr()).ab.data != null
                            && (ulong)idx_long < (ulong)elem_count;
                        ra.set_boolean(!in_range);
                        return (TVal){};
                    }
                }

                void* key = get_prop_key(vm, rc);
                if (key != null) {
                    if (!hobj.es_delete_prop(key)) {
                        ra.set_boolean(false);
                        // Strict-only engine: non-configurable delete always throws.
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "Delete failed: property is non-configurable", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    } else {
                        ra.set_boolean(true);
                    }
                }
            } else if (rb.is_lightfunc()) {
                // Handle deletion of virtual properties (name, length, prototype).
                // These are configurable:true per ES5 §15.3.5.1, so delete returns true.
                // Mark as deleted so subsequent GETPROP/hasOwn check the bitset.
                uint fn_idx = (uint)(usz)rb.get_heapptr();
                HString* key = get_prop_key(vm, rc);
                if (key != null) {
                    int bit = heap::lf_key_to_prop_bit(key);
                    if (bit >= 0) {
                        heap::lf_mark_deleted(&vm.heap.lf_deleted_props[0], fn_idx, (uint)bit);
                    }
                }
            }
            // For other primitives (number, string, boolean), the spec's
            // ToObject() would box them — but our base is already a primitive
            // TVal, so property deletion on it returns true (the property
            // simply doesn't exist on the boxed wrapper).
            return (TVal){};
        }

        default:
            return (TVal){};
    }
}

