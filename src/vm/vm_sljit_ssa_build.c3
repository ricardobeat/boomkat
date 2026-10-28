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

// Rename bytecode definitions into the analyzed SSA graph.

fn bool ssa_build(SsaGraph* g) @feat(SLJIT) {
    CompiledFunction* cf = g.cf;
    LoopPlan* plan       = g.plan;
    bool[LOOP_REGS] read;
    bool[LOOP_REGS] value_read;
    bool[LOOP_REGS] written;
    bool[LOOP_REGS] live_in;
    bool[LOOP_REGS] base;
    bool[LOOP_REGS] int_need;
    bool[LOOP_REGS] f64_need;
    ssa_infer(g, &read, &value_read, &written, &live_in, &base, &int_need, &f64_need);
    ssa_int_fixpoint(g);
    for (uint i = 0; i < LOOP_REGS; i++) {
        g.current[i] = -1;
        g.phi[i] = -1;
        g.arg[i] = -1;
        // A register the loop rewrites but never uses as a number holds an
        // arbitrary value, not an integer.
        g.rep[i] = ((g.plan.ssa_double | g.force_f64) & (1UL << i)) != 0 ? F64
            : g.int_reg[i] ? INT32
            : ssa_rep_for(int_need[i], f64_need[i], false);
    }
    foreach (&entry : g.conv) *entry = 0;
    // Header values. Written registers get a phi; read-only numeric inputs get
    // an argument. Pure memory bases need no value.
    // Registers written in the loop but not read before their first in-loop
    // definition still need their final value published when the loop exits
    // and later code reads them. They become loop-carried phis for that
    // reason alone; nothing else about them is loop-carried.
    bool[LOOP_REGS] exit_live;
    for (uint pos = plan.end + 1; pos < cf.code_count; pos++) {
        Instruction after = cf.code[pos];
        if (after.a < LOOP_REGS) exit_live[after.a] = true;
        if (after.b < LOOP_REGS) exit_live[after.b] = true;
        if (after.c < LOOP_REGS) exit_live[after.c] = true;
    }
    g.current_pc = plan.begin;
    for (uint reg = 0; reg < cf.num_regs && reg < LOOP_REGS; reg++) {
        if (!g.single_pass && written[reg] && (live_in[reg] || exit_live[reg])) {
            // Recovery-only inputs can hold any value on entry. Their old
            // contents are overwritten before use, so imposing the body's
            // numeric representation here creates a spurious entry guard.
            SsaRep rep = live_in[reg] ? g.rep[reg] : BOXED;
            int phi    = ssa_value(g, PHI, rep, -1, 0, 0);
            g.phi[reg] = phi;
            g.values[phi].arg_reg = (int)reg;
            g.current[reg] = phi;
        } else if ((g.single_pass && live_in[reg]) || (!written[reg] && value_read[reg])) {
            int arg = ssa_value(g, ARG, g.rep[reg], -1, 0, 0);
            g.values[arg].arg_reg = (int)reg;
            g.arg[reg] = arg;
            g.current[reg] = arg;
        }
    }
    for (uint reg = 0; reg < LOOP_REGS; reg++) g.header[reg] = g.current[reg];
    // The body may hold arms: a forward branch splits it into blocks, and a
    // join merges the states its arms leave behind.
    if (!ssa_split_blocks(g)) {
        g.failed = true;
        return false;
    }
    for (uint b = 0; b < g.block_count; b++) {
        g.current_block = b;
        // A conversion emitted in one arm need not execute on another arm.
        foreach (&entry : g.conv) *entry = 0;
        if (!ssa_enter_block(g, b)) {
            g.failed = true;
            return false;
        }
        g.block_first[b] = g.value_count;
        SsaBlock* block = &g.blocks[b];
        for (uint pos = block.begin; pos <= block.end; pos++) {
            Instruction ins = cf.code[pos];
            uint at         = pos - plan.begin;
            g.frames[at] = g.current;
            // Conversions can consume a bytecode operand before a later guard in
            // the same operation. Keep the original value until that operation
            // commits, so replay observes the exact pre-instruction frame.
            defer foreach (value : g.frames[at]) if (value >= 0) ssa_use(g, value);
            g.current_pc = pos;
            int target = loop_target(ins, pos);
            if (target >= 0) {
                if (pos != plan.end) {
                    if (!ssa_arm_branch(g, b, pos, ins)) {
                        g.failed = true;
                        return false;
                    }
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
            switch (ins.op) {
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
                        int binding = (int)plan.binding_at[pos - plan.begin] - 1;
                        int value   = ssa_value(g, BINDING, BOXED, -1, -1, binding);
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
                            g.failed = true;
                            return false;
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

                    {
                        CompiledFunction* callee_fn = function_inline_ssa_candidate(cf, pos, g.heap);
                        if (callee_fn == null || g.current[ins.b] < 0 || ins.c > 8) {
                            g.failed = true;
                            return false;
                        }
                        // The site can be rebound, so the live callee must still be
                        // the compiled body that was expanded here.
                        int callee = g.current[ins.b];
                        ssa_use(g, callee);
                        ssa_use(g, ssa_value(g, CHECKFN, BOXED, callee, -1, (long)callee_fn));
                        int[LOOP_REGS] mapped;
                        for (uint i = 0; i < LOOP_REGS; i++) mapped[i] = -1;
                        for (uint i = 0; i < ins.c; i++) {
                            int arg = g.current[ins.b + 2 + i];
                            if (arg < 0) {
                                g.failed = true;
                                return false;
                            }
                            ssa_use(g, arg);
                            mapped[i] = arg;
                        }
                        int receiver = -1;
                        if (g.current[ins.b + 1] >= 0) {
                            receiver = g.current[ins.b + 1];
                            ssa_use(g, receiver);
                        }
                        int result;
                        for (uint ci_pos = 0; ci_pos < callee_fn.code_count; ci_pos++) {
                            Instruction ci = callee_fn.code[ci_pos];
                            if (ci.a >= LOOP_REGS) {
                                g.failed = true;
                                return false;
                            }
                            switch (ci.op) {
                                case NOP: continue;
                                case RET: result = mapped[ci.a]; continue;
                                case LDINT:

                                    {
                                        long immediate = ci.get_sbc();
                                        mapped[ci.a] = ssa_value(
                                            g,
                                            CONST_F,
                                            F64,
                                            -1,
                                            0,
                                            (long)bitcast((double)immediate, ulong)
                                        );
                                        continue;
                                    }
                                case LDCONST:

                                    {
                                        if (ci.get_bc() >= callee_fn.const_count) {
                                            g.failed = true;
                                            return false;
                                        }
                                        TVal constant = callee_fn.constants[ci.get_bc()];
                                        if (!constant.is_fastint() && !constant.is_number()) {
                                            g.failed = true;
                                            return false;
                                        }
                                        double number = constant.get_number_or_fastint();
                                        mapped[ci.a] = ssa_value(g, CONST_F, F64, -1, 0, (long)bitcast(number, ulong));
                                        continue;
                                    }
                                case LDTHIS:
                                    if (receiver < 0) {
                                        g.failed = true;
                                        return false;
                                    }
                                    mapped[ci.a] = ssa_convert(g, receiver, BOXED, false);
                                    continue;
                                case LDREG:
                                case UNP:
                                    if (ci.b >= LOOP_REGS || mapped[ci.b] < 0) {
                                        g.failed = true;
                                        return false;
                                    }
                                    mapped[ci.a] = mapped[ci.b];
                                    continue;
                                case UNM:

                                    {
                                        if (ci.b >= LOOP_REGS || mapped[ci.b] < 0) {
                                            g.failed = true;
                                            return false;
                                        }
                                        int operand = ssa_convert(g, mapped[ci.b], F64, false);
                                        ssa_use(g, operand);
                                        mapped[ci.a] = ssa_value(g, NEG, F64, operand, -1, 0);
                                        continue;
                                    }
                                case ADD:
                                case ADD_FUSED:
                                case SUB:
                                case MUL:
                                case DIV:

                                    {
                                        if (ci.b >= LOOP_REGS || ci.c >= LOOP_REGS || mapped[ci.b] < 0
                                            || mapped[ci.c] < 0) {
                                            g.failed = true;
                                            return false;
                                        }
                                        int left  = ssa_convert(g, mapped[ci.b], F64, false);
                                        int right = ssa_convert(g, mapped[ci.c], F64, false);
                                        ssa_use(g, left);
                                        ssa_use(g, right);
                                        SsaOp op = ci.op == Opcode.ADD || ci.op == Opcode.ADD_FUSED ? ADD
                                            : (ci.op == Opcode.SUB ? SUB : (ci.op == Opcode.MUL ? MUL : DIV));
                                        mapped[ci.a] = ssa_value(g, op, F64, left, right, 0);
                                        continue;
                                    }
                                case ADDI:
                                case SUBI:
                                case MULI:

                                    {
                                        if (ci.b >= LOOP_REGS || mapped[ci.b] < 0) {
                                            g.failed = true;
                                            return false;
                                        }
                                        int left = ssa_convert(g, mapped[ci.b], F64, false);
                                        int immediate = ssa_value(
                                            g,
                                            CONST_F,
                                            F64,
                                            -1,
                                            0,
                                            (long)bitcast((double)(ichar)ci.c, ulong)
                                        );
                                        ssa_use(g, left);
                                        ssa_use(g, immediate);
                                        SsaOp op = ci.op == Opcode.ADDI ? ADD : (ci.op == Opcode.SUBI ? SUB : MUL);
                                        mapped[ci.a] = ssa_value(g, op, F64, left, immediate, 0);
                                        continue;
                                    }
                                case GETPROPC:
                                case GETPROPC_CACHED:
                                case GETTHISC:

                                    {
                                        bool on_receiver = ci.op == Opcode.GETTHISC;
                                        if (!on_receiver && (ci.b >= LOOP_REGS || mapped[ci.b] < 0)) {
                                            g.failed = true;
                                            return false;
                                        }
                                        if (callee_fn.ic_entries == null) {
                                            g.failed = true;
                                            return false;
                                        }
                                        ICEntry* ic   = (ICEntry*)callee_fn.ic_entries + ci_pos;
                                        Shape* layout = g.heap.get_shape(ic.shape_id);
                                        if (layout == null || layout.generation != ic.shape_gen) {
                                            g.failed = true;
                                            return false;
                                        }
                                        int receiver_value = on_receiver ? ssa_convert(g, receiver, BOXED, false)
                                            : mapped[ci.b];
                                        if (receiver_value < 0) {
                                            g.failed = true;
                                            return false;
                                        }
                                        ssa_use(g, receiver_value);
                                        int memory = loop_memory_shape_layout(
                                            g.plan,
                                            ic.shape_id,
                                            ic.shape_gen,
                                            (int)ic.prop_idx,
                                            false
                                        );
                                        if (memory < 0) {
                                            g.failed = true;
                                            return false;
                                        }
                                        mapped[ci.a] = ssa_value(g, LOAD, BOXED, receiver_value, -1, (long)memory);
                                        continue;
                                    }
                                default:
                                    g.failed = true;
                                    return false;
                            }
                        }
                        if (result < 0) {
                            g.failed = true;
                            return false;
                        }
                        ssa_use(g, result);
                        int nv = ssa_convert(g, result, g.rep[ins.a], false);
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                        break;
                    }
                case GETPROPC:
                case GETPROPC_CACHED:
                case GETTHISC:

                    {
                        uint memory = (uint)plan.memory_at[at] - 1;
                        if (memory >= plan.memory_count) {
                            g.failed = true;
                            return false;
                        }
                        LoopMemorySpec spec =  plan.memory[memory];
                        int base_value      = -1;
                        if (spec.kind == SHAPE_FIELD) {
                            base_value = g.current[ins.b];
                            if (base_value < 0) {
                                g.failed = true;
                                return false;
                            }
                            ssa_use(g, base_value);
                        }
                        int nv = ssa_value(g, LOAD, spec.doubles ? F64 : BOXED, base_value, -1, (long)memory);
                        ssa_result(g, nv, ins.a, pos);
                        g.current[ins.a] = nv;
                        break;
                    }
                case GETPROP:
                case GETPROP_CACHE:

                    {
                        uint memory = (uint)plan.memory_at[at] - 1;
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
                        uint memory = (uint)plan.memory_at[at] - 1;
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

                    {
                        int left  = g.current[ins.b];
                        int right = g.current[ins.c];
                        if (left < 0 || right < 0) {
                            g.failed = true;
                            return false;
                        }
                        SsaOp op     = ins.op == Opcode.ADD || ins.op == Opcode.ADD_FUSED ? ADD
                            : ins.op == Opcode.SUB ? SUB
                            : ins.op == Opcode.MUL ? MUL
                            : DIV;
                        // Integer arithmetic stays in GPRs with overflow exits
                        // instead of round-tripping through doubles.
                        bool integer = op != DIV && g.values[left].rep == INT32 && g.values[right].rep == INT32;
                        SsaRep rep   = integer ? INT32 : F64;
                        left = ssa_convert(g, left, rep, integer);
                        right = ssa_convert(g, right, rep, integer);
                        ssa_use(g, left);
                        ssa_use(g, right);



                        {
                            int nv = ssa_value(g, op, rep, left, right, 0);
                            ssa_result(g, nv, ins.a, pos);
                            g.current[ins.a] = nv;
                        }
                        break;
                    }
                case ADDI:
                case SUBI:
                case MULI:

                    {
                        int left = g.current[ins.b];
                        if (left < 0) {
                            g.failed = true;
                            return false;
                        }
                        SsaOp op     = ins.op == Opcode.SUBI ? SUB : ins.op == Opcode.MULI ? MUL : ADD;
                        bool integer = g.values[left].rep == INT32;
                        SsaRep rep   = integer ? INT32 : F64;
                        left = ssa_convert(g, left, rep, integer);
                        ssa_use(g, left);



                        {
                            int nv = ssa_value(g, op, rep, left, -1, (long)(ichar)ins.c);
                            ssa_result(g, nv, ins.a, pos);
                            g.current[ins.a] = nv;
                        }
                        break;
                    }
                case BAND:
                case BOR:
                case BXOR:
                case SHL:
                case SHR:
                case USHR:

                    {
                        int left  = g.current[ins.b];
                        int right = g.current[ins.c];
                        if (left < 0 || right < 0) {
                            g.failed = true;
                            return false;
                        }
                        left = ssa_convert(g, left, INT32, false);
                        right = ssa_convert(g, right, INT32, false);
                        ssa_use(g, left);
                        ssa_use(g, right);
                        SsaOp op = ins.op == Opcode.BAND ? BAND
                            : ins.op == Opcode.BOR ? BOR
                            : ins.op == Opcode.BXOR ? BXOR
                            : ins.op == Opcode.SHL ? SHL
                            : ins.op == Opcode.SHR ? SHR
                            : USHR;



                        {
                            int nv = ssa_value(g, op, INT32, left, right, 0);
                            ssa_result(g, nv, ins.a, pos);
                            g.current[ins.a] = nv;
                        }
                        break;
                    }
                case BANDI:
                case BORI:
                case BXORI:
                case SHLI:
                case SHRI:
                case USHRI:

                    {
                        int left = g.current[ins.b];
                        if (left < 0) {
                            g.failed = true;
                            return false;
                        }
                        left = ssa_convert(g, left, INT32, false);
                        ssa_use(g, left);
                        SsaOp op = ins.op == Opcode.BANDI ? BAND
                            : ins.op == Opcode.BORI ? BOR
                            : ins.op == Opcode.BXORI ? BXOR
                            : ins.op == Opcode.SHLI ? SHL
                            : ins.op == Opcode.SHRI ? SHR
                            : USHR;



                        {
                            int nv = ssa_value(g, op, INT32, left, -1, (long)(ichar)ins.c);
                            ssa_result(g, nv, ins.a, pos);
                            g.current[ins.a] = nv;
                        }
                        break;
                    }
                case BNOT:

                    {
                        int value = g.current[ins.b];
                        if (value < 0) {
                            g.failed = true;
                            return false;
                        }
                        value = ssa_convert(g, value, INT32, false);
                        ssa_use(g, value);



                        {
                            int nv = ssa_value(g, BNOT, INT32, value, -1, 0);
                            ssa_result(g, nv, ins.a, pos);
                            g.current[ins.a] = nv;
                        }
                        break;
                    }
                default:
                    g.failed = true;
                    return false;
            }
        }
        g.block_last[b] = g.value_count;
        for (uint reg = 0; reg < LOOP_REGS; reg++) g.block_exit[b][reg] = g.current[reg];
    }
    for (uint i = 0; i < plan.memory_count && i < LOOP_MEMORY; i++) {
        uint source = plan.memory[i].source;
        // Binding/this descriptors are invocation-local inputs, not registers.
        g.invariant[i] = source >= LOOP_REGS || !written[source];
    }
    if (g.single_pass) {
        // A function region publishes its final definitions directly. There
        // are no loop-carried phis or backedge representation conversions.
        foreach (value : g.current) if (value >= 0) ssa_use(g, value);
        return !g.failed;
    }
    // Latch inputs for loop phis.
    g.current_pc = plan.end;
    for (uint reg = 0; reg < cf.num_regs && reg < LOOP_REGS; reg++) {
        if (g.phi[reg] < 0) continue;
        int value = g.current[reg];
        if (value < 0) {
            g.failed = true;
            return false;
        }
        if (live_in[reg] && g.values[value].rep == F64 && g.values[g.phi[reg]].rep != F64) g.force_f64 |= 1UL << reg;
        value = ssa_convert(g, value, g.values[g.phi[reg]].rep, false);
        g.values[g.phi[reg]].a = value;
        ssa_use(g, value);
        g.values[g.phi[reg]].last = g.stamp;
    }
    // Representation conversions on backedges are executable IR too. Keep
    // them in the final block before parallel copies, and retain recovery
    // operands through any guards they emit at the backedge bytecode.
    g.block_last[g.block_count - 1] = g.value_count;
    foreach (value : g.frames[plan.end - plan.begin]) if (value >= 0) ssa_use(g, value);
    for (uint i = 0; i < g.value_count; i++) {
        if (g.values[i].op == ARG || g.values[i].op == PHI) g.values[i].last = g.stamp;
    }
    return !g.failed;
}