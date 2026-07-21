module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::re_bindings;
import std::math;

// ============================================================================
// vm_unary — unary ops, inc/dec, and variable inc/dec fusion (UNP..DEC_VAR).
// Hot arithmetic / bitwise / comparison / load-store / control-flow opcodes are
// inlined directly in Vm.run (src/vm/vm_execute.c3) to avoid per-instruction
// call overhead; only the loop-bearing unary handlers live out-of-line here.
// ============================================================================
fn TVal? dispatch_unary(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) @inline {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.UNP:
            if (rb.is_bigint()) {
                // ES2020 §12.5.4: unary + on a BigInt throws TypeError.
                if (vm_bigint_unary(vm, Opcode.UNP, ra, rb) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                }
                return (TVal){};
            }
            if (rb.is_fastint()) {
                // Unary + on FASTINT stays FASTINT
                ra.set_fastint(rb.get_fastint());
            } else {
                double unp_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number(unp_b);
            }
            return (TVal){};

        case Opcode.TONUMERIC:
            // ES2020 §7.1.3 ToNumeric: BigInt passes through unchanged;
            // everything else behaves like unary plus (ToNumber).
            if (rb.is_bigint()) {
                vm.heap.tval_copy_ref(ra, rb);
                return (TVal){};
            }
            if (rb.is_fastint()) {
                ra.set_fastint(rb.get_fastint());
            } else {
                double tn_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number(tn_b);
            }
            return (TVal){};

        case Opcode.UNM:
            if (rb.is_bigint()) {
                if (vm_bigint_unary(vm, Opcode.UNM, ra, rb) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                }
                return (TVal){};
            }
            if (rb.is_fastint()) {
                long unm_val = rb.get_fastint();
                if (unm_val == 0) {
                    // -0 must be NUMBER, not FASTINT (integers have no -0)
                    ra.set_number(-0.0);
                } else {
                    ra.set_fastint(-unm_val);
                }
            } else if (rb.get_tag() == OBJECT) {
                // ES2020 §12.5.7 UnaryMinus: ToNumeric(operand) — ToPrimitive
                // (hint number) FIRST, then pass a BigInt result through to
                // BigInt::unaryMinus instead of ToNumber (which would throw
                // on BigInt). Handles `-Object(1n)` / `-{[Symbol.toPrimitive]:
                // () => 1n}`.
                TVal prim_b = to_primitive_value(vm, rb, 2);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) return (TVal){};
                if (prim_b.is_bigint()) {
                    if (vm_bigint_unary(vm, Opcode.UNM, ra, &prim_b) == BigIntOpResult.THREW) {
                        if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    }
                } else {
                    double unm_b = vm_to_number(vm, &prim_b);
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    ra.set_number(-unm_b);
                }
            } else {
                double unm_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number(-unm_b);
            }
            return (TVal){};

        case Opcode.BNOT:
            // Bitwise NOT always produces Int32, always fits in FASTINT
        {
            if (rb.is_bigint()) {
                if (vm_bigint_unary(vm, Opcode.BNOT, ra, rb) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                }
                return (TVal){};
            }
            if (rb.get_tag() == OBJECT) {
                // ES2020 §12.5.9 BitwiseNOT: ToNumeric(operand) — ToPrimitive
                // (hint number) FIRST, then pass a BigInt result through to
                // BigInt::bitwiseNOT instead of ToNumber (which would throw
                // on BigInt). Handles `~Object(1n)` / `~{[Symbol.toPrimitive]:
                // () => 1n}`.
                TVal bnot_prim_b = to_primitive_value(vm, rb, 2);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) return (TVal){};
                if (bnot_prim_b.is_bigint()) {
                    if (vm_bigint_unary(vm, Opcode.BNOT, ra, &bnot_prim_b) == BigIntOpResult.THREW) {
                        if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    }
                    return (TVal){};
                }
                int bnot_obj_b = toint32(vm_to_number(vm, &bnot_prim_b));
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_fastint((long)(~bnot_obj_b));
                return (TVal){};
            }
            int bnot_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(~bnot_b));
            return (TVal){};
        }

        case Opcode.LNOT:
            ra.set_boolean(!is_truthy(rb));
            return (TVal){};

        case Opcode.TYPEOF: {
            HString* ts = typeof_string(vm, rb);
            vm.heap.set_reg_string(ra, ts);
            return (TVal){};
        }

        case Opcode.VOID:
            ra.set_undefined();
            return (TVal){};

        // === IN-PLACE FASTINT ++ / -- ===
        // Fused LDINT 1 + ADD/SUB pair. Hot for loop counters and similar.
        case Opcode.INC:
            if (ra.is_fastint()) {
                ra.set_fastint(ra.get_fastint() + 1L);
            } else if (ra.is_bigint()) {
                if (vm_bigint_incdec(vm, ra, true) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                }
            } else {
                // Slow path: convert to number, increment, store back
                double d = vm_to_number(vm,ra);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number(d + 1.0);
            }
            return (TVal){};
        case Opcode.DEC:
            if (ra.is_fastint()) {
                ra.set_fastint(ra.get_fastint() - 1L);
            } else if (ra.is_bigint()) {
                if (vm_bigint_incdec(vm, ra, false) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                }
            } else {
                double d = vm_to_number(vm,ra);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number(d - 1.0);
            }
            return (TVal){};

        // Write a value into the call-argument area at a runtime-computed slot.
        // ABC format: A=base_reg, B=count_reg, C=src_reg.
        // Effect: regs[A + regs[B]] = regs[C]; regs[B]++.
        // Used for non-spread arguments that follow a spread, where the slot
        // index depends on the runtime spread count.
        case Opcode.PUTARG: {
            uint base_reg = insn.a;
            uint count_reg = insn.b;
            uint src_reg = insn.c;
            TVal* count_slot = ds.regs_base + count_reg;
            long idx;
            if (count_slot.is_fastint()) {
                idx = count_slot.get_fastint();
            } else if (count_slot.is_number()) {
                idx = (long)count_slot.get_number();
            } else {
                idx = 0;
            }
            TVal* dest = ds.regs_base + base_reg + (uint)idx;
            *dest = ds.regs_base[src_reg];
            count_slot.set_fastint(idx + 1);
            return (TVal){};
        }

        // === VARIABLE ARITHMETIC FUSION ===
        // Fused GETVAR + INC/PUTVAR.  Reads a variable by name, increments
        // or decrements it, and writes it back in a single dispatch.
        // Hot for loop counters: `for (i = 0; i < N; i++) { ... }`
        case Opcode.INC_VAR:
        case Opcode.DEC_VAR: {
            uint bc = insn.get_bc();
            if (bc >= vm.current_func.const_count) break;
            TVal name_val = ds.constants[bc];
            if (!name_val.is_string()) break;
            void* key = name_val.get_heapptr();
            bool is_inc = (op == Opcode.INC_VAR);

            // --- Variable IC fast path (read + op + write) ---
            if (ds.var_ic_base != null) {
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                if (vic.env != null && vic.key == key && vic.search_head == (void*)ds.act.lex_env) {
                    HObject* b = (HObject*)vic.bindings;
                    if (b.shape_id == vic.shape_id
                        && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                        TVal old_val = b.prop_values()[vic.prop_idx];
                        if (!env::is_tdz_sentinel(&old_val)
                            && b.get_prop_flags(vic.prop_idx).writable) {
                            // ENV_STRICT: INC_VAR/DEC_VAR read traps removed — for needs_env=false
                            // lex_env == parent env, so a hit here is a legitimate parent
                            // lookup, not own-local. Own-local leaks surface as 'not defined'
                            // throws and are caught by test/test_register_locals.js.
                            if (old_val.is_fastint()) {
                                long v = old_val.get_fastint() + (is_inc ? 1L : -1L);
                                if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                                    b.prop_values()[vic.prop_idx].set_fastint(v);
                                    ra.set_fastint(v);
                                } else {
                                    b.prop_values()[vic.prop_idx].set_number((double)v);
                                    ra.set_number((double)v);
                                }
                            } else if (old_val.is_bigint()) {
                                int128? nr = bigint_step(old_val.get_bigint(), is_inc);
                                if (catch nr) {
                                    vm_set_range_error(vm, "BigInt value exceeds supported precision");
                                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                                    return (TVal){};
                                }
                                if (!vm_set_reg_bigint(vm, &b.prop_values()[vic.prop_idx], nr)) {
                                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                                    return (TVal){};
                                }
                                vm.heap.tval_copy_ref(ra, &b.prop_values()[vic.prop_idx]);
                            } else {
                                double d = vm_to_number(vm,&old_val);
                                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                                double new_d = d + (is_inc ? 1.0 : -1.0);
                                b.prop_values()[vic.prop_idx].set_number(new_d);
                                ra.set_number(new_d);
                            }
                            return (TVal){};
                        }
                        vic.env = null;
                    } else {
                        vic.env = null;
                    }
                }
            }

            // --- Slow path: full env walk + op + write ---
            bool found = false;
            EnvRecord* ic_env = null;
            int ic_prop_idx = -1;
            EnvRecord* cur = ds.act.lex_env;
            while (cur != null) {
                int idx = cur.bindings.find_prop_idx(key);
                if (idx >= 0) {
                    // ENV_STRICT: INC_VAR/DEC_VAR read traps removed — for needs_env=false
                    // lex_env == parent env, so a hit here is a legitimate parent
                    // lookup, not own-local. Own-local leaks surface as 'not defined'
                    // throws and are caught by test/test_register_locals.js.

                    TVal old_val = cur.bindings.prop_values()[idx];
                    if (env::is_tdz_sentinel(&old_val)) {
                        HString* name_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "%s is not defined", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    if (!cur.bindings.get_prop_flags((uint)idx).writable) {
                        HString* name_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    if (old_val.is_fastint()) {
                        long v = old_val.get_fastint() + (is_inc ? 1L : -1L);
                        if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                            cur.bindings.prop_values()[idx].set_fastint(v);
                            ra.set_fastint(v);
                        } else {
                            cur.bindings.prop_values()[idx].set_number((double)v);
                            ra.set_number((double)v);
                        }
                    } else if (old_val.is_bigint()) {
                        int128? nr = bigint_step(old_val.get_bigint(), is_inc);
                        if (catch nr) {
                            vm_set_range_error(vm, "BigInt value exceeds supported precision");
                            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                            return (TVal){};
                        }
                        if (!vm_set_reg_bigint(vm, &cur.bindings.prop_values()[idx], nr)) {
                            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                            return (TVal){};
                        }
                        vm.heap.tval_copy_ref(ra, &cur.bindings.prop_values()[idx]);
                    } else {
                        double d = vm_to_number(vm,&old_val);
                        if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                        double new_d = d + (is_inc ? 1.0 : -1.0);
                        cur.bindings.prop_values()[idx].set_number(new_d);
                        ra.set_number(new_d);
                    }
                    found = true;
                    ic_env = cur;
                    ic_prop_idx = idx;
                    return (TVal){};
                }
                cur = cur.parent;
            }

            if (!found) {
                // var_env fallback (with-blocks)
                // ENV_STRICT TODO: own-vs-parent check for var_env walk (currently skipped for conservative correctness)
                if (ds.act.lex_env != ds.act.var_env) {
                    TVal? result = env::env_get(ds.act.var_env, key);
                    if (try v2 = result) {
                        TVal new_val;
                        if (v2.is_fastint()) {
                            long v = v2.get_fastint() + (is_inc ? 1L : -1L);
                            if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                                new_val.set_fastint(v);
                            } else {
                                new_val.set_number((double)v);
                            }
                        } else {
                            double d = vm_to_number(vm,&v2);
                            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                            new_val.set_number(d + (is_inc ? 1.0 : -1.0));
                        }
                        env::env_put(ds.act.var_env, key, new_val);
                        vm.heap.tval_copy_ref(ra, &new_val);
                        found = true;
                    }
                }
                if (!found) {
                    // ReferenceError
                    HString* name_hstr = (HString*)key;
                    if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "%s is not defined", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return VM_ERROR~;
                    }
                }
            }

            // Populate IC for next time
            if (found && ds.var_ic_base != null && ic_env != null) {
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                vic.env = ic_env;
                vic.bindings = ic_env.bindings;
                vic.shape_id = ic_env.bindings.shape_id;
                vic.generation = vm.heap.shapes[ic_env.bindings.shape_id].generation;
                vic.prop_idx = (ushort)ic_prop_idx;
                if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                vic.key = key;
                if (key != null) { ((types::HeapHeader*)key).incref(); }
                vic.search_head = (void*)ds.act.lex_env;
            }
            return (TVal){};
        }

        case Opcode.INC_GLOBAL:
        case Opcode.DEC_GLOBAL: {
            // Global-scope fused read+op+write. Slot IC: single shape-id
            // compare + direct indexed access (no env/key/search_head/generation
            // check). Only writable, non-accessor data slots are cached, so the
            // hit assumes a plain slot.
            uint bc = insn.get_bc();
            if (bc >= vm.current_func.const_count) return (TVal){};
            TVal name_val = ds.constants[bc];
            if (!name_val.is_string()) return (TVal){};
            void* key = name_val.get_heapptr();
            bool is_inc = (op == Opcode.INC_GLOBAL);

            if (ds.var_ic_base != null) {
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::VarICEntry* gic = ds.var_ic_base + pc_off;
                HObject* gb = (HObject*)gic.bindings;
                if (gb != null && gb.shape_id == gic.shape_id) {
                    TVal old_val = gb.prop_values()[gic.prop_idx];
                    if (old_val.is_fastint()) {
                        long v = old_val.get_fastint() + (is_inc ? 1L : -1L);
                        if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                            gb.prop_values()[gic.prop_idx].set_fastint(v);
                            ra.set_fastint(v);
                        } else {
                            gb.prop_values()[gic.prop_idx].set_number((double)v);
                            ra.set_number((double)v);
                        }
                        return (TVal){};
                    } else if (!old_val.is_bigint() && !env::is_tdz_sentinel(&old_val)) {
                        double d = vm_to_number(vm,&old_val);
                        if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                        double new_d = d + (is_inc ? 1.0 : -1.0);
                        gb.prop_values()[gic.prop_idx].set_number(new_d);
                        ra.set_number(new_d);
                        return (TVal){};
                    }
                    // BigInt / TDZ: fall through to slow path.
                }
            }

            // Slow path: resolve against the global objects, apply, populate IC.
            bool found = false;
            EnvRecord* ic_env = null;
            int ic_prop_idx = -1;
            EnvRecord* cur = ds.act.lex_env;
            while (cur != null) {
                int idx = cur.bindings.find_prop_idx(key);
                if (idx >= 0) {
                    TVal old_val = cur.bindings.prop_values()[idx];
                    if (env::is_tdz_sentinel(&old_val)) {
                        HString* name_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    hobject::PropFlags fl = cur.bindings.get_prop_flags((uint)idx);
                    if (!fl.writable) {
                        HString* name_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    if (fl.is_accessor) {
                        // Accessor global: no slot semantics — cannot fast-inc.
                        return VM_ERROR~;
                    }
                    if (old_val.is_fastint()) {
                        long v = old_val.get_fastint() + (is_inc ? 1L : -1L);
                        if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                            cur.bindings.prop_values()[idx].set_fastint(v);
                            ra.set_fastint(v);
                        } else {
                            cur.bindings.prop_values()[idx].set_number((double)v);
                            ra.set_number((double)v);
                        }
                    } else if (old_val.is_bigint()) {
                        int128? nr = bigint_step(old_val.get_bigint(), is_inc);
                        if (catch nr) {
                            vm_set_range_error(vm, "BigInt value exceeds supported precision");
                            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                            return (TVal){};
                        }
                        if (!vm_set_reg_bigint(vm, &cur.bindings.prop_values()[idx], nr)) {
                            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                            return (TVal){};
                        }
                        vm.heap.tval_copy_ref(ra, &cur.bindings.prop_values()[idx]);
                    } else {
                        double d = vm_to_number(vm,&old_val);
                        if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                        double new_d = d + (is_inc ? 1.0 : -1.0);
                        cur.bindings.prop_values()[idx].set_number(new_d);
                        ra.set_number(new_d);
                    }
                    found = true;
                    // Cache only plain data slots (fastint/number path). BigInt
                    // slots are fine to cache too (guard re-reads value), but the
                    // fast path handles only fastint/number, so BigInt re-takes
                    // the slow path via the is_bigint fall-through above.
                    ic_env = cur;
                    ic_prop_idx = idx;
                    break;
                }
                cur = cur.parent;
            }

            if (!found && ds.act.lex_env != ds.act.var_env) {
                int vidx = ds.act.var_env.bindings.find_prop_idx(key);
                if (vidx >= 0) {
                    TVal old_val = ds.act.var_env.bindings.prop_values()[vidx];
                    hobject::PropFlags fl = ds.act.var_env.bindings.get_prop_flags((uint)vidx);
                    if (!fl.is_accessor && fl.writable && !env::is_tdz_sentinel(&old_val)) {
                        if (old_val.is_fastint()) {
                            long v = old_val.get_fastint() + (is_inc ? 1L : -1L);
                            if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
                                ds.act.var_env.bindings.prop_values()[vidx].set_fastint(v);
                                ra.set_fastint(v);
                            } else {
                                ds.act.var_env.bindings.prop_values()[vidx].set_number((double)v);
                                ra.set_number((double)v);
                            }
                        } else if (!old_val.is_bigint()) {
                            double d = vm_to_number(vm,&old_val);
                            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                            double new_d = d + (is_inc ? 1.0 : -1.0);
                            ds.act.var_env.bindings.prop_values()[vidx].set_number(new_d);
                            ra.set_number(new_d);
                        } else {
                            return VM_ERROR~;
                        }
                        found = true;
                        ic_env = ds.act.var_env;
                        ic_prop_idx = vidx;
                    }
                }
            }

            if (!found) {
                HString* name_hstr = (HString*)key;
                if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "%s is not defined", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            if (ds.var_ic_base != null && ic_env != null) {
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::VarICEntry* gic = ds.var_ic_base + pc_off;
                gic.env = (void*)ic_env;
                gic.bindings = (void*)ic_env.bindings;
                gic.shape_id = ic_env.bindings.shape_id;
                gic.prop_idx = (ushort)ic_prop_idx;
            }
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}
