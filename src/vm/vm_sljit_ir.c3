module boomkat::vm;

import boomkat::bytecode;
import boomkat::jit;
import boomkat::compiler;

// A deliberately small typed IR: canonical F64 homes, selected by a backwards
// live-in fixed point. Every incoming native edge has the same representation;
// unsupported definitions exclude a register instead of requiring phi moves.
struct FunctionNumericIR @feat(SLJIT) {
    char[3] owners;
    uint count;
}
fn bool function_ir_def(Instruction ins) @feat(SLJIT) {
    uint reg;
    return compiler::moveelim_get_def(ins, &reg);
}
fn FunctionNumericIR function_numeric_ir(CompiledFunction* cf, bool whole) @feat(SLJIT) {
    FunctionNumericIR ir;
    if (!compiler::moveelim_roles_ready) compiler::moveelim_init_roles();
    // Reserve cross-block homes only for compact, supported regions. Mixed
    // regions otherwise spend their scarce FP lanes on values spanning exits.
    if (cf.code_count > FUNCTION_REGION_OPS) return ir;
    for (uint pc = 0; pc < cf.code_count; pc++) {
        Opcode op = cf.code[pc].op;
        if (!function_op(op) && !function_call_op(op)) return ir;
    }
    ulong[4][FUNCTION_OPS + 1] live;
    bool[256] excluded;
    uint[256] weight;
    for (uint pc = 0; pc < cf.code_count; pc++) {
        Instruction ins = cf.code[pc];
        if (function_float_op(ins.op)) { weight[ins.a] += 2; weight[ins.b]++; weight[ins.c]++; }
        bool numeric = function_float_op(ins.op) || ins.op == Opcode.LDREG || ins.op == Opcode.LDINT;
        if (ins.op == Opcode.LDCONST) numeric = cf.constants[ins.get_bc()].is_numeric();
        if (!numeric) {
            uint[8] words;
            compiler::RegSet writes = { .words = &words[0], .word_count = 8 };
            compiler::register_may_writes(ins, &writes);
            for (uint reg = 0; reg < 256; reg++) if (writes.test(reg)) excluded[reg] = true;
        }
    }
    // Copies connect accumulator homes to arithmetic temporaries.
    for (uint pc = 0; pc < cf.code_count; pc++) {
        Instruction ins = cf.code[pc];
        if (ins.op == Opcode.LDREG) weight[ins.a] += weight[ins.b];
    }
    bool changed = true;
    while (changed) {
        changed = false;
        for (uint reverse = cf.code_count; reverse > 0; reverse--) {
            uint pc = reverse - 1; Instruction ins = cf.code[pc];
            ulong[4] incoming = live[pc + 1];
            int target = loop_target(ins, pc);
            if (ins.op == Opcode.JUMP || ins.op == Opcode.RET || ins.op == Opcode.RETUNDEF) incoming = {};
            if (target >= 0 && target < (int)cf.code_count) {
                for (uint word = 0; word < 4; word++) incoming[word] |= live[target][word];
            }
            if (function_ir_def(ins)) incoming[ins.a >> 6] &= ~(1UL << (ins.a & 63));
            // Use the compiler's operand roles, including call windows. Bytecode
            // immediates and constant indices must not become phantom live values.
            uint[8] words;
            compiler::RegSet reads = { .words = &words[0], .word_count = 8 };
            compiler::moveelim_add_uses(ins, &reads, true);
            for (uint word = 0; word < 4; word++) {
                incoming[word] |= (ulong)words[word * 2] | ((ulong)words[word * 2 + 1] << 32);
            }
            for (uint word = 0; word < 4; word++) if (live[pc][word] != incoming[word]) {
                live[pc][word] = incoming[word]; changed = true;
            }
        }
    }
    ulong[4] carried;
    for (uint pc = 0; pc < cf.code_count; pc++) {
        int target = loop_target(cf.code[pc], pc);
        if (target >= 0 && target <= (int)pc) {
            for (uint word = 0; word < 4; word++) carried[word] |= live[target][word];
        }
    }
    for (uint lane = 0; lane < 3; lane++) {
        uint best; uint score;
        for (uint reg = 0; reg < cf.num_regs && reg < 256; reg++) {
            // Fresh native calls must not refuse entry on undefined locals.
            // Region entries can guard already initialized local values.
            if (whole && reg >= cf.num_formals) continue;
            if (!excluded[reg] && (carried[reg >> 6] & (1UL << (reg & 63))) != 0 && weight[reg] > score) {
                best = reg; score = weight[reg];
            }
        }
        if (score == 0) break;
        ir.owners[ir.count++] = (char)best; excluded[best] = true;
    }
    return ir;
}
fn void FunctionEmitter.flow_prepare(&self) @feat(SLJIT) {
    if (self.out.flow == null) return;
    FunctionNumericIR ir = function_numeric_ir(self.cf, self.plan.begin == 0);
    // No lane is dirty until every entry guard has succeeded. Prologue bailouts
    // therefore never materialize an uninitialized FP register.
    for (uint i = 0; i < ir.count; i++) {
        uint reg = ir.owners[i];
        self.out.load(reg, jit::reg_r(0));
        self.out.number(jit::reg_r(0), (int)i + 3, FUNCTION_BAIL);
    }
    for (uint i = 0; i < ir.count; i++) {
        uint reg = ir.owners[i];
        self.flow.owners[i] = (char)reg;
        self.flow.registers[reg] = (char)(i + 3);
        self.flow.pinned |= 1U << i;
    }
    self.flow.used = self.flow.pinned; self.flow.dirty = self.flow.pinned;
}
