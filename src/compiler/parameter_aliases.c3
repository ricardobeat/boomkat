module boomkat::compiler;

import boomkat::bytecode;
import std::math;

// Entry copies dominate every later read. Immutable formals and homes below
// every call window keep that identity across branches and nested calls.
fn bool eliminate_parameter_aliases(CompilerContext* ctx, bool* targets) {
    if (!register_promotion_eligible(ctx) || ctx.has_captured_local
        || ctx.num_args == 0 || ctx.max_reg > 256) return false;
    uint[256] writes;
    ushort[256] aliases;
    uint call_floor = 256;
    for (uint pc = 0; pc < ctx.code_count; pc++) {
        Instruction ins = ctx.code[pc];
        if (moveelim_producer_allowed(ins.op) || ins.op == Opcode.INC || ins.op == Opcode.DEC) {
            writes[ins.a]++;
            continue;
        }
        switch (ins.op) {
            case Opcode.CALL:
            case Opcode.CALL_UNDEF_THIS:
                call_floor = math::min(call_floor, (uint)ins.b);
                writes[ins.a]++;
            case Opcode.CALL_VAR:
            case Opcode.CALL_GLOBAL:
                call_floor = math::min(call_floor, (uint)ins.a);
                writes[ins.a]++;
            case Opcode.NOP:
            case Opcode.RET:
            case Opcode.RETUNDEF:
            case Opcode.JUMP:
            case Opcode.BREAK:
            case Opcode.CONTINUE:
            case Opcode.IF_TRUE:
            case Opcode.IF_FALSE:
            case Opcode.JMP_NLT..Opcode.JMP_SNEQI:
                continue;
            default:
                return false;
        }
    }
    if (call_floor < ctx.num_args) return false;
    uint end = 0;
    bool changed = false;
    for (; end < ctx.code_count; end++) {
        Instruction ins = ctx.code[end];
        if (targets[end]) break;
        if (ins.op == Opcode.NOP) continue;
        if (ins.op != Opcode.LDREG) break;
        if (ins.b >= ctx.num_args || writes[ins.b] != 0
            || ins.a < ctx.num_args || ins.a >= call_floor || writes[ins.a] != 1) break;
        uint homes = 0;
        bool eligible = false;
        foreach (binding : ctx.bindings) {
            if (binding.reg != ins.a) continue;
            homes++;
            eligible = binding.kind == ScopeKind.VAR && !binding.is_param
                && !binding.is_catch_param && !binding.is_captured;
        }
        if (homes != 1 || !eligible) break;
        aliases[ins.a] = (ushort)ins.b + 1;
        ctx.code[end] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        changed = true;
    }
    if (!changed) return false;
    for (uint pc = end; pc < ctx.code_count; pc++) {
        Instruction* ins = &ctx.code[pc];
        if (ins.op == Opcode.RET || ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE) {
            if (aliases[ins.a] != 0) ins.a = aliases[ins.a] - 1;
        } else if (bytecode::is_cmp_branch(ins.op) || moveelim_producer_allowed(ins.op)) {
            if (bytecode::get_op_format(ins.op) != OpFormat.ABC) continue;
            if (aliases[ins.b] != 0) ins.b = aliases[ins.b] - 1;
            if (!bytecode::is_imm_form(ins.op) && bytecode::reg_form(ins.op) == Opcode.NOP
                && aliases[ins.c] != 0) ins.c = aliases[ins.c] - 1;
        }
    }
    return true;
}
