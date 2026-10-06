module boomkat::compiler;

import boomkat::bytecode;
import boomkat::heap;

// Prove every use before rewriting: the rest slot then holds a count instead
// of an array. Unknown instructions keep ordinary allocation.
fn void lower_rest_length(CompilerContext* ctx, CompiledFunction* func, Heap* heap) {
    if (ctx.disable_optimize || ctx.has_wide || !ctx.has_rest
        || ctx.has_direct_eval || ctx.has_with_stmt || ctx.outer_with
        || ctx.uses_arguments || ctx.has_destructured_param
        || ctx.defaults.len() != 0 || ctx.destruct_defaults.len() != 0
        || ctx.is_async || ctx.is_generator || ctx.is_arrow
        || func.inner_count != 0 || func.field_init_func != null
        || func.flags.needs_env) return;
    uint reg = func.num_formals;
    for (uint pc = 0; pc < func.code_count; pc++) {
        Instruction ins = func.code[pc];
        if (ins.op == Opcode.GETPROPC && ins.b == reg) {
            if (ins.a == reg || ins.c >= func.const_count
                || !func.constants[ins.c].is_string()
                || func.constants[ins.c].get_heapptr() != (void*)heap.strs[heap::BuiltinStr.LENGTH]) return;
            continue;
        }
        switch (ins.op) {
            case Opcode.RET:
            case Opcode.IF_TRUE:
            case Opcode.IF_FALSE:
                if (ins.a == reg) return;
            case Opcode.RETUNDEF:
            case Opcode.NOP:
            case Opcode.JUMP:
            case Opcode.BREAK:
            case Opcode.CONTINUE:
            case Opcode.JMP_NLT..Opcode.JMP_SNEQI:
                if (bytecode::is_cmp_branch(ins.op) && fusion_abc_reads_reg(ins, reg)) return;
            default:
                if ((!moveelim_producer_allowed(ins.op) && ins.op != Opcode.GETPROPC)
                    || ins.a == reg) return;
                if (bytecode::get_op_format(ins.op) == OpFormat.ABC
                    && fusion_abc_reads_reg(ins, reg)) return;
        }
    }
    for (uint pc = 0; pc < func.code_count; pc++) {
        Instruction ins = func.code[pc];
        if (ins.op == Opcode.GETPROPC && ins.b == reg) {
            func.code[pc] = bytecode::make_abc(Opcode.LDREG, ins.a, reg, 0);
        }
    }
    func.call_flags.rest_length_only = true;
}
