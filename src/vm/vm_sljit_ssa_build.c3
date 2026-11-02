module boomkat::vm;

import boomkat::bytecode;
import boomkat::compiler;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::builtins;
import boomkat::jit;
import std::core::mem;
import std::io;

// Compute the live frame at the loop's ordinary fallthrough using the same
// backwards CFG analysis as move elimination. Restrict this to instructions
// with modeled control flow and an unaliased bytecode window: aliased loops
// temporarily rewrite only their body, so whole-function liveness would mix
// physical and original register numbers. All refusals use the conservative
// continuation scan below.
fn bool ssa_wide_continuation_op(Opcode op) @feat(SLJIT) {
    return function_op(op) || function_call_op(op);
}
fn bool ssa_continuation_live(SsaGraph* g, bool* exit_live) @feat(SLJIT) {
    CompiledFunction* cf = g.cf;
    LoopPlan* plan = g.plan;
    if (g.single_pass || cf.code_count > 512 || cf.num_regs >= compiler::BYTECODE_REGS_MAX
        || cf.flags.has_direct_eval || cf.mapped_arguments() || cf.flags.is_generator || cf.flags.is_async) return false;
    for (uint reg = 0; reg < g.reg_count; reg++) if (plan.slot_reg[reg] != (int)reg) return false;
    return compiler::moveelim_decoded_continuation(cf.code, cf.code_count, cf.num_regs,
        plan.end + 1, g.heap, &ssa_wide_continuation_op, exit_live, LOOP_REGS);
}

// Rename bytecode definitions into the analyzed SSA graph.

fn bool ssa_build(SsaGraph* g) @feat(SLJIT) {
    if (g.failed) return false;
    CompiledFunction* cf = g.cf;
    LoopPlan* plan       = g.plan;
    if (!ssa_charge_work(g, (usz)(plan.end - plan.begin + 1) + g.reg_count)) return false;
    bool* read = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    bool* value_read = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    bool* written = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    bool* live_in = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    bool* base = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    bool* int_need = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    bool* f64_need = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    if (g.failed) return false;
    ssa_infer(g, read, value_read, written, live_in, base, int_need, f64_need);
    if (g.failed) return false;
    ssa_int_fixpoint(g);
    if (g.failed) return false;
    for (uint i = 0; i < g.reg_count; i++) {
        g.current[i] = -1;
        g.phi[i] = -1;
        g.arg[i] = -1;
        // A register the loop rewrites but never uses as a number holds an
        // arbitrary value, not an integer.
        g.rep[i] = (g.force_f64.test(i) || (i < 64 && (g.plan.ssa_double & (1UL << i)) != 0)) ? F64
            : g.int_reg[i] ? INT32
            : ssa_rep_for(int_need[i], f64_need[i], false);
    }
    foreach (&entry : g.conv[0:g.value_capacity * 4]) *entry = 0;
    // Header values. Written registers get a phi; read-only numeric inputs get
    // an argument. Pure memory bases need no value.
    // Registers written in the loop but not read before their first in-loop
    // definition still need their final value published when the loop exits
    // and later code reads them. They become loop-carried phis for that
    // reason alone; nothing else about them is loop-carried.
    bool* exit_live = (bool*)ssa_storage_alloc(g, g.reg_count, bool::size);
    if (g.failed) return false;
    foreach (&entry : exit_live[0:g.reg_count]) *entry = false;
    if (plan.end + 1 < cf.code_count && !ssa_continuation_live(g, exit_live)) {
        // The continuation may read implicit call windows; raw operand bytes
        // also include constant indices and offsets that are not registers.
        // Keep all continuation uses and definitions conservatively until a
        // recovery-aware CFG can prove which ones are live on a given exit.
        uint start = plan.end + 1;
        for (uint pc = start; pc < cf.code_count; pc++) {
            int target = loop_target(cf.code[pc], pc);
            if (target >= 0 && target < (int)start) { start = 0; break; }
        }
        uint[32] words;
        compiler::RegSet used = { .words = &words[0], .word_count = 32 };
        compiler::bytecode_register_set(cf.code, start, cf.code_count - 1, &used);
        for (uint reg = 0; reg < g.reg_count; reg++) {
            // The loop window may alias a high VM register to this low slot;
            // continuation bytecode still names the original register.
            int origin = plan.slot_reg[reg];
            exit_live[reg] = origin < 0 || (uint)origin >= compiler::BYTECODE_REGS_MAX || used.test((uint)origin);
        }
    }
    // Exception handlers can observe locals after a guard resumes inside the
    // loop. The ordinary continuation alone does not describe those edges.
    // Until exception frame states are modeled, preserve every written slot.
    for (uint pc = 0; pc < cf.code_count; pc++) if (cf.code[pc].op == Opcode.TRY) {
        for (uint reg = 0; reg < g.reg_count; reg++) exit_live[reg] = true;
        break;
    }
    g.current_pc = plan.begin;
    for (uint reg = 0; reg < cf.num_regs && reg < g.reg_count; reg++) {
        if (!g.single_pass && written[reg] && (live_in[reg] || exit_live[reg])) {
            // Recovery-only inputs can hold any value on entry. Their old
            // contents are overwritten before use, so imposing the body's
            // numeric representation here creates a spurious entry guard.
            SsaRep rep = live_in[reg] ? g.rep[reg] : BOXED;
            int phi    = ssa_value(g, PHI, rep, -1, 0, 0);
            g.phi[reg] = phi;
            g.values[phi].arg_reg = (int)reg;
            g.current[reg] = phi;
        } else if (g.recoverable || (g.cyclic && reg < cf.num_args) || (g.single_pass && (live_in[reg] || exit_live[reg])) || (!written[reg] && value_read[reg])) {
            int arg = ssa_value(g, ARG, g.recoverable || g.cyclic || (g.single_pass && !live_in[reg]) ? BOXED : g.rep[reg], -1, 0, 0);
            g.values[arg].arg_reg = (int)reg;
            g.arg[reg] = arg;
            g.current[reg] = arg;
        }
    }
    for (uint reg = 0; reg < g.reg_count; reg++) g.header[reg] = g.current[reg];
    // The body may hold arms: a forward branch splits it into blocks, and a
    // join merges the states its arms leave behind.
    if (!ssa_split_blocks(g)) {
        g.failed = true;
        return false;
    }
    g.block_exit = (SsaFrameId*)ssa_storage_alloc(g, g.block_count, SsaFrameId::size);
    if (g.failed) return false;
    for (uint b = 0; b < g.block_count; b++) g.block_exit[b] = SSA_NO_FRAME;
    if ((g.cyclic || g.recoverable) && !ssa_cyclic_liveness(g)) return false;
    if (g.cyclic && !g.single_pass && g.block_count > 1) {
        // The outer latch must be built last: its register state is the
        // loop-carried input the final phi wiring below reads.
        uint latch = g.block_count - 1;
        uint at = 0;
        for (uint step = 0; step < g.block_count; step++) {
            if (g.cyclic_order[step] == latch) { at = step; break; }
        }
        g.cyclic_order[at] = g.cyclic_order[g.block_count - 1];
        g.cyclic_order[g.block_count - 1] = latch;
    }
    for (uint step = 0; step < g.block_count; step++) {
        uint b = g.cyclic || g.recoverable ? g.cyclic_order[step] : step;
        g.current_block = b;
        // A conversion emitted in one arm need not execute on another arm.
        if (!ssa_charge_work(g, (usz)g.value_capacity * 4)) return false;
        foreach (&entry : g.conv[0:g.value_capacity * 4]) *entry = 0;
        if (!ssa_enter_block(g, b)) {
            g.failed = true;
            return false;
        }
        g.block_first[b] = g.value_count;
        SsaBlock* block = &g.blocks[b];
        for (uint pos = block.begin; !block.synthetic && pos <= block.end;) {
            DecodedBytecode view = ssa_decoded_view(g, pos);
            if (!view.valid) return false;
            defer pos = view.next_pc;
            DecodedInsn ins = view.insn;
            uint at         = pos - plan.begin;
            if (g.recoverable) {
                // Dead slots remain owned by the VM frame. Sparse states hold
                // only semantic inputs required at this exact prefix PC.
                for (uint reg = 0; reg < cf.num_regs && reg < g.reg_count; reg++) {
                    if (g.recovery_live[at].test(reg) && g.current[reg] < 0) return false;
                }
            }
            g.frames[at] = ssa_frame_capture(g, pos, g.current, g.reg_count,
                g.recoverable ? g.recovery_live[at].words : null, g.recoverable ? g.reg_words : 0);
            if (g.failed) return false;
            // Conversions can consume a bytecode operand before a later guard in
            // the same operation. Keep the original value until that operation
            // commits, so replay observes the exact pre-instruction frame.
            defer if (!g.direct) { foreach (entry : ssa_frame_entries(g, g.frames[at])) ssa_use(g, entry.value); }
            g.current_pc = pos;
            int target = ssa_decoded_target(view);
            if (target >= 0) {
                if (pos != plan.end) {
                    if (!ssa_arm_branch(g, b, pos, ins)) {
                        g.failed = true;
                        return false;
                    }
                    continue;
                }
                if (ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE) {
                    int predicate = g.current[ins.a];
                    if (predicate < 0 || g.values[predicate].rep == F64) return false;
                    g.cmp_lhs = predicate;
                    g.cmp_rhs = -1;
                    g.cmp_op = ins.op;
                    ssa_use(g, predicate);
                    continue;
                }
                if (!ssa_comparison_op(ins.op)) {
                    g.failed = true;
                    return false;
                }
                int lhs =  g.current[ins.b];
                int rhs = -1;
                if (ins.op < Opcode.JMP_NLTI) rhs = g.current[ins.c];
                if (lhs < 0) {
                    g.failed = true;
                    return false;
                }
                bool integer = g.values[lhs].rep == INT32 && (rhs < 0 || g.values[rhs].rep == INT32);
                if (integer) {
                    g.cmp_lhs = ssa_convert(g, lhs, INT32, false);
                    g.cmp_rhs = rhs >= 0 ? ssa_convert(g, rhs, INT32, false) : -1;
                } else {
                    g.cmp_lhs = ssa_convert(g, lhs, F64, false);
                    g.cmp_rhs = rhs >= 0 ? ssa_convert(g, rhs, F64, false) : -1;
                }
                ssa_use(g, g.cmp_lhs);
                if (g.cmp_rhs >= 0) ssa_use(g, g.cmp_rhs);
                g.cmp_imm = ins.op >= Opcode.JMP_NLTI ? (long)(ichar)ins.c : 0;
                g.cmp_op = ins.op;
                continue;
            }
            if (g.recoverable && ssa_binding_build(g, view)) continue;
            if (g.recoverable && plan.ssa_data != null && plan.ssa_data.decoded_body
                && ssa_access_build(g, view)) continue;
            // Unary minus stays in the typed graph so a numeric loop does not
            // pay a one-instruction VM step for every negation. Non-numeric
            // operands fail the conversion and use the helper below.
            if (g.recoverable && plan.ssa_data != null && plan.ssa_data.decoded_body
                && ins.op == Opcode.UNM) {
                int negated = ssa_scalar(g, ins.op, g.current[ins.b]);
                if (negated >= 0) {
                    ssa_result(g, negated, ins.a, pos);
                    g.current[ins.a] = negated;
                    continue;
                }
                g.failed = false;
            }
            if (g.recoverable && plan.ssa_data != null && plan.ssa_data.decoded_body
                && ssa_vm_step_supported(ins.op)) {
                // A property read the body cannot lower would run as one
                // interpreter step per access. Once the site cache is filled
                // such a read never becomes a direct field read, and the
                // baseline region inlines the same read into generated code.
                if (ssa_access_site_refused(g.heap, g.cf, view.payload_pc)) {
                    g.failed = true;
                    return false;
                }
                int value = ssa_value(g, HELPER, BOXED, -1, -1, 0);
                uint destination;
                compiler::MoveelimRoles roles = compiler::bytecode_cfg_roles(ins.op);
                if (compiler::moveelim_get_role_def(roles, ins.a, &destination)) {
                    ssa_result(g, value, destination, pos);
                    g.current[destination] = value;
                }
                g.values[value].before_frame = g.frames[at];
                g.values[value].after_frame = ssa_frame_capture(g, view.next_pc, g.current, g.reg_count,
                    view.next_pc <= plan.end ? g.recovery_live[view.next_pc - plan.begin].words : null, g.reg_words);
                if (g.failed) return false;
                continue;
            }
            switch (ins.op) {
                case NOP: continue;
                case LDTHIS:
                    {
                        if (!g.direct_fields) return false;
                        int value = ssa_value(g, RECEIVER, BOXED, -1, -1, 0);
                        ssa_result(g, value, ins.a, pos);
                        g.current[ins.a] = value;
                        break;
                    }
                case RET:
                case RETUNDEF:
                    {
                        if (g.recoverable) {
                            ssa_value(g, EXIT, BOXED, -1, -1, 0);
                            continue;
                        }
                        if (plan.ssa_function == null || !g.direct) return false;
                        int value = ins.op == Opcode.RET ? g.current[ins.a] : -1;
                        if (ins.op == Opcode.RET && value < 0) return false;
                        if (value >= 0) ssa_use(g, value);
                        ssa_value(g, RETURN, BOXED, value, -1, 0);
                        continue;
                    }
                case PUTTHISC:
                case PUTPROPC:
                    {
                        if (!plan.ssa_commit) return false;
                        int value = g.current[ins.op == Opcode.PUTTHISC ? ins.a : ins.b];
                        // A boxed value may still hold a reference, which the
                        // store guard refuses before anything is released. The
                        // refusal is deterministic in the body's own writes, so
                        // replaying it writes the same slots with the same
                        // values and lets the interpreter do the counted store.
                        if (value < 0 || g.values[value].rep == RAW) return false;
                        value = ssa_convert(g, value, BOXED, false);
                        ssa_use(g, value);
                        uint memory = (uint)ssa_memory_site(plan, at) - 1;
                        int receiver = g.direct_fields ? ssa_field_storage(g, memory,
                            ins.op == Opcode.PUTPROPC ? g.current[ins.a] : -1) : -1;
                        if (g.direct_fields) ssa_use(g, receiver);
                        ssa_value(g, STORE, BOXED, receiver, value, memory);
                        break;
                    }
                case LDREG:
                case TONUMERIC:

                    {
                        if (g.current[ins.b] < 0) {
                            g.failed = true;
                            return false;
                        }
                        int src = g.current[ins.b];
                        ssa_use(g, src);
                        int copy = ssa_value(g, COPY, g.values[src].rep, src, 0, 0);
                        ssa_result(g, copy, ins.a, pos);
                        g.current[ins.a] = copy;
                        break;
                    }
                case GETCAP:
                case GETVAR:
                case GETGLOBAL:

                    {
                        if (g.recoverable) {
                            // A slot store can alias a global/capture binding.
                            // Read the real binding at this operation instead
                            // of reusing an invocation-entry snapshot.
                            int value = ssa_value(g, HELPER, BOXED, -1, -1, 0);
                            ssa_result(g, value, ins.a, pos);
                            g.current[ins.a] = value;
                            g.values[value].before_frame = g.frames[at];
                            g.values[value].after_frame = ssa_frame_capture(g, view.next_pc, g.current, g.reg_count,
                                view.next_pc <= plan.end ? g.recovery_live[view.next_pc - plan.begin].words : null, g.reg_words);
                            break;
                        }
                        int binding = (int)ssa_binding_site(plan, pos - plan.begin) - 1;
                        int value;
                        if ((plan.ssa_binding_mask & (1UL << (uint)binding)) != 0) {
                            TVal constant = plan.ssa_binding_constants[binding];
                            if (constant.is_fastint() && constant.get_fastint() >= -2147483648L
                                && constant.get_fastint() <= 2147483647L) {
                                value = ssa_value(g, CONST_I, INT32, -1, -1, constant.get_fastint());
                            } else {
                                value = ssa_value(g, CONST_F, F64, -1, -1,
                                    (long)bitcast(constant.get_number_or_fastint(), ulong));
                            }
                        } else { value = ssa_value(g, BINDING, BOXED, -1, -1, binding); }
                        ssa_result(g, value, ins.a, pos);
                        g.current[ins.a] = value;
                        break;
                    }
                case LDUNDEF:
                case LDNULL:
                case LDTRUE:
                case LDFALSE:
                    {
                        TVal constant;
                        if (ins.op == Opcode.LDTRUE || ins.op == Opcode.LDFALSE) {
                            constant.set_boolean(ins.op == Opcode.LDTRUE);
                        } else if (ins.op == Opcode.LDNULL) {
                            constant.set_null();
                        } else {
                            constant.set_undefined();
                        }
                        int value = ssa_value(g, CONST_BOXED, BOXED, -1, 0, (long)loop_bits(constant));
                        ssa_result(g, value, ins.a, pos);
                        g.current[ins.a] = value;
                        break;
                    }
                case LDINT:

                    {
                        long value = ins.get_sbc();
                        SsaRep rep = value >= -2147483648L && value <= 2147483647L ? INT32 : F64;



                        {
                            int nv = ssa_value(g, rep == INT32 ? CONST_I : CONST_F, rep, -1, 0, value);
                            ssa_result(g, nv, ins.a, pos);
                            g.current[ins.a] = nv;
                        }
                        break;
                    }
                case LDCONST:

                    {
                        if (ins.get_bc() >= cf.const_count) {
                            g.failed = true;
                            return false;
                        }
                        TVal value = cf.constants[ins.get_bc()];
                        if (!value.is_fastint() && !value.is_number()) {
                            if (!g.recoverable) return false;
                            int constant = ssa_value(g, CONST_BOXED, BOXED, -1, 0, (long)loop_bits(value));
                            ssa_result(g, constant, ins.a, pos);
                            g.current[ins.a] = constant;
                            break;
                        }
                        double number = value.get_number_or_fastint();
                        if (value.is_fastint()) {
                            long integer = value.get_fastint();
                            if (integer >= -2147483648L && integer <= 2147483647L) {

                                {
                                    int nv = ssa_value(g, CONST_I, INT32, -1, 0, integer);
                                    ssa_result(g, nv, ins.a, pos);
                                    g.current[ins.a] = nv;
                                }
                                break;
                            }
                        }



                        {
                            int nv = ssa_value(g, CONST_F, F64, -1, 0, (long)bitcast(number, ulong));
                            ssa_result(g, nv, ins.a, pos);
                            g.current[ins.a] = nv;
                        }
                        break;
                    }
                case CALL:
                case CALL_UNDEF_THIS:
                case CALL_GLOBAL:
                case CALL_VAR:
                    {
                        if (g.recoverable) {
                            int inlined = ssa_effect_inline_call(g, view);
                            if (g.failed) return false;
                            if (inlined >= 0) break;
                            if (function_call_op(ins.op)) {
                                int value = ssa_value(g, HELPER, BOXED, -1, -1, 0);
                                ssa_result(g, value, ins.a, pos);
                                g.current[ins.a] = value;
                                if (ins.op != Opcode.CALL) {
                                    uint receiver = ins.op == Opcode.CALL_UNDEF_THIS ? (uint)ins.b + 1 : (uint)ins.a + 1;
                                    int undefined = ssa_value(g, CONST_BOXED, BOXED, -1, -1,
                                        (long)(types::TAG_UNDEFINED << 48));
                                    ssa_result(g, undefined, receiver, pos);
                                    // The result is written after receiver clearing.
                                    if (receiver != ins.a) g.current[receiver] = undefined;
                                }
                                g.values[value].before_frame = g.frames[at];
                                g.values[value].after_frame = ssa_frame_capture(g, view.next_pc, g.current, g.reg_count,
                                    view.next_pc <= plan.end ? g.recovery_live[view.next_pc - plan.begin].words : null, g.reg_words);
                                break;
                            }
                            // Its successor is a fresh external entry importing
                            // the real post-call result from the VM register.
                            ssa_value(g, EXIT, BOXED, -1, -1, 0);
                            break;
                        }
                        int value = ssa_inline_call(g, cf.code[view.payload_pc], pos);
                        if (value < 0) return false;
                        g.current[ins.a] = value;
                        break;
                    }
                case NEWOBJ:
                case NEWOBJ_SHAPE:
                case NEWARR:
                case NEWARR_CONST:
                case CLOSURE:
                case NEWCELLS: case GETCELL: case SETCELL: case MOVECELL:
                    {
                        if (!g.recoverable) return false;
                        int value = ssa_value(g, HELPER, BOXED, -1, -1, 0);
                        ssa_result(g, value, ins.a, pos);
                        g.current[ins.a] = value;
                        g.values[value].before_frame = g.frames[at];
                        g.values[value].after_frame = ssa_frame_capture(g, view.next_pc, g.current, g.reg_count,
                                    view.next_pc <= plan.end ? g.recovery_live[view.next_pc - plan.begin].words : null, g.reg_words);
                        break;
                    }
                case GETPROPC:
                case GETPROPC_CACHED:
                case GETTHISC:

                    {
                        uint memory = (uint)ssa_memory_site(plan, at) - 1;
                        if (memory >= plan.memory_count) {
                            if (!g.recoverable) return false;
                            int value = ssa_value(g, HELPER, BOXED, -1, -1, 0);
                            ssa_result(g, value, ins.a, pos);
                            g.current[ins.a] = value;
                            g.values[value].before_frame = g.frames[at];
                            g.values[value].after_frame = ssa_frame_capture(g, view.next_pc, g.current, g.reg_count,
                                view.next_pc <= plan.end ? g.recovery_live[view.next_pc - plan.begin].words : null, g.reg_words);
                            break;
                        }
                        LoopMemorySpec spec =  plan.memory[memory];
                        int base_value      = -1;
                        if (g.direct_fields && spec.kind == FIELD) {
                            base_value = ssa_field_storage(g, memory,
                                g.recoverable && ins.op != Opcode.GETTHISC ? g.current[ins.b] : -1);
                            ssa_use(g, base_value);
                        } else if (spec.kind == SHAPE_FIELD || spec.kind == PROTO_FIELD) {
                            base_value = g.current[ins.b];
                            if (base_value < 0) {
                                g.failed = true;
                                return false;
                            }
                            if (g.direct_fields) base_value = ssa_field_storage(g, memory, base_value);
                            ssa_use(g, base_value);
                        }
                        int nv = ssa_value(g, LOAD, spec.integers ? INT32 : spec.doubles ? F64 : BOXED, base_value, -1, (long)memory);
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                        break;
                    }
                case GETPROP:
                case GETPROP_CACHE:

                    {
                        uint memory = (uint)ssa_memory_site(plan, at) - 1;
                        if (memory >= plan.memory_count || g.current[ins.c] < 0) {
                            g.failed = true;
                            return false;
                        }
                        int index = ssa_convert(g, g.current[ins.c], INT32, true);
                        ssa_use(g, index);
                        LoopMemorySpec spec = plan.memory[memory];
                        SsaRep rep          = spec.doubles ? F64
                            : (spec.kind == DENSE ? BOXED : (spec.cls >= FLOAT32ARRAY ? F64 : INT32));



                        {
                            int nv = ssa_value(g, LOAD, rep, index, -1, memory);
                            ssa_result(g, nv, ins.a, pos);
                            g.current[ins.a] = nv;
                        }
                        break;
                    }
                case PUTPROP:

                    {
                        uint memory = (uint)ssa_memory_site(plan, at) - 1;
                        if (memory >= plan.memory_count || g.current[ins.b] < 0 || g.current[ins.c] < 0) {
                            g.failed = true;
                            return false;
                        }
                        int index           = ssa_convert(g, g.current[ins.b], INT32, true);
                        LoopMemorySpec spec = plan.memory[memory];
                        int value;
                        if (spec.doubles) {
                            // Every element is an ordinary double, so store one
                            // instead of boxing the number.
                            value = ssa_convert(g, g.current[ins.c], F64, false);
                        } else if (spec.kind == DENSE) {
                            value = ssa_convert(g, g.current[ins.c], BOXED, false);
                        } else if (spec.cls >= FLOAT32ARRAY) {
                            value = ssa_convert(g, g.current[ins.c], F64, false);
                        } else {
                            value = ssa_convert(g, g.current[ins.c], INT32, false);
                        }
                        ssa_use(g, index);
                        ssa_use(g, value);
                        ssa_value(g, STORE, BOXED, index, value, memory);
                        break;
                    }
                case INC:
                case INC_LT:
                case DEC:

                    {
                        if (g.current[ins.a] < 0) {
                            g.failed = true;
                            return false;
                        }
                        // A double counter increments in place: JavaScript numbers
                        // are doubles, so this is exact and needs no int round trip.
                        bool integer = g.values[g.current[ins.a]].rep != F64;
                        SsaRep rep   = integer ? INT32 : F64;
                        int value    = ssa_convert(g, g.current[ins.a], rep, integer);
                        ssa_use(g, value);



                        {
                            int nv = ssa_value(g, ins.op == Opcode.DEC ? SUB : ADD, rep, value, -1, 1);
                            ssa_result(g, nv, ins.a, pos);
                            g.current[ins.a] = nv;
                        }
                        break;
                    }
                case ADD:
                case ADD_FUSED:
                case SUB:
                case MUL:
                case DIV:
                case LT: case LE: case GT: case GE:
                case EQ: case NEQ: case SEQ: case SNEQ:
                case ADDI:
                case SUBI:
                case MULI:
                case BAND:
                case BOR:
                case BXOR:
                case SHL:
                case SHR:
                case USHR:
                case BANDI:
                case BORI:
                case BXORI:
                case SHLI:
                case SHRI:
                case USHRI:
                case BNOT:
                    {
                        bool binary = ssa_scalar_binary(ins.op);
                        int value = ssa_scalar(g, ins.op, g.current[ins.b], binary ? g.current[ins.c] : -1,
                            bytecode::imm_value(ins.op, ins.c));
                        if (value < 0) return false;
                        ssa_result(g, value, ins.a, pos);
                        g.current[ins.a] = value;
                        break;
                    }
                default:
                    g.failed = true;
                    return false;
            }
        }
        g.block_last[b] = g.value_count;
        g.block_exit[b] = ssa_frame_capture(g, SSA_ENTRY_BAIL, g.current, g.reg_count);
        if (g.failed) return false;
        g.block_built[b] = true;
    }
    if (g.cyclic) {
        for (uint j = 0; j < g.join_count; j++) {
            SsaJoin* join = &g.joins[j];
            if (join.entry) {
                for (uint reg = 0; reg < g.reg_count; reg++) {
                    int phi = join.phi[reg];
                    int incoming = join.entry_incoming[reg];
                    if (phi >= 0 && incoming >= 0 && g.values[phi].rep == INT32 && g.values[incoming].rep == F64) {
                        g.force_f64.set(reg);
                    }
                }
            }
            for (uint p = 0; p < join.pred_count; p++) {
                for (uint reg = 0; reg < g.reg_count; reg++) {
                    int phi = join.phi[reg];
                    if (phi < 0) continue;
                    int incoming = join.incoming[p][reg];
                    if (incoming < 0) {
                        incoming = ssa_frame_lookup(g, g.block_exit[join.preds[p]], reg);
                        if (incoming < 0) return false;
                        join.incoming[p][reg] = incoming;
                        ssa_use(g, incoming);
                    }
                    // Cyclic headers are created before every predecessor is
                    // available. A numeric-use guess must never narrow a real
                    // double producer; rebuild until these representations agree.
                    if (g.values[phi].rep == INT32 && g.values[incoming].rep == F64) {
                        g.force_f64.set(reg);
                    }
                }
            }
        }
    }
    for (uint i = 0; i < plan.memory_count && i < LOOP_MEMORY; i++) {
        uint source = plan.memory[i].source;
        // Binding/this descriptors are invocation-local inputs, not registers.
        g.invariant[i] = source >= LOOP_REGS || !written[source];
    }
    if (g.single_pass) {
        // A function region publishes its final definitions directly. There
        // are no loop-carried phis or backedge representation conversions.
        if (g.direct) {
            if (g.result_reg < g.reg_count) {
                if (g.current[g.result_reg] < 0) return false;
                ssa_use(g, g.current[g.result_reg]);
            }
        } else if (!g.recoverable) {
            // Recoverable CALL/RET exits already consume their exact live
            // pre-bytecode frame; no final whole-frame completion is emitted.
            foreach (value : g.current[0:g.reg_count]) if (value >= 0) ssa_use(g, value);
        }
        return !g.failed;
    }
    // Latch inputs for loop phis.
    g.current_pc = plan.end;
    for (uint reg = 0; reg < cf.num_regs && reg < g.reg_count; reg++) {
        if (g.phi[reg] < 0) continue;
        int value = g.current[reg];
        if (value < 0) {
            g.failed = true;
            return false;
        }
        if (live_in[reg] && g.values[value].rep == F64 && g.values[g.phi[reg]].rep != F64) g.force_f64.set(reg);
        value = ssa_convert(g, value, g.values[g.phi[reg]].rep, false);
        g.values[g.phi[reg]].a = value;
        ssa_use(g, value);
        g.values[g.phi[reg]].last = g.stamp;
    }
    // Representation conversions on backedges are executable IR too. Keep
    // them in the final block before parallel copies, and retain recovery
    // operands through any guards they emit at the backedge bytecode.
    g.block_last[g.block_count - 1] = g.value_count;
    // All converted phi inputs are consumed together by the latch. A later
    // conversion must not reuse an earlier input's home before that point.
    foreach (phi : g.phi[0:g.reg_count]) if (phi >= 0) ssa_use(g, g.values[phi].a);
    foreach (entry : ssa_frame_entries(g, g.frames[plan.end - plan.begin])) ssa_use(g, entry.value);
    for (uint i = 0; i < g.value_count; i++) {
        if (g.values[i].op == ARG || g.values[i].op == PHI) g.values[i].last = g.stamp;
    }
    return !g.failed;
}
