// Bounded annotation-directed numeric-region experiment; no general type checker.
module boomkat::compiler;

import boomkat::ast;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;

fn void specialize_numeric_region(CompilerContext* ctx, CompiledFunction* func, Heap* hp) {
    if (numeric_specialization == 0 || ctx.disable_optimize
        || ((numeric_specialization == 1 || numeric_specialization == 3) && !ctx.numeric_annotation_candidate)
        || ctx.is_global || ctx.is_arrow || ctx.is_generator || ctx.is_async
        || ctx.has_wide || ctx.has_rest || ctx.has_destructured_param
        || ctx.defaults.len() != 0 || ctx.destruct_defaults.len() != 0
        || ctx.uses_arguments || ctx.has_direct_eval || ctx.has_with_stmt
        || ctx.outer_with || ctx.capture_all || func.capture_count != 0
        || func.inner_count != 0 || func.flags.needs_env
        || func.num_args == 0 || func.num_args > 8 || func.num_regs > 32
        || func.code_count < 2 || func.code_count > 96) return;

    // Guarded parameters seed the proof. Every instruction must consume only
    // proven Numbers and produce another Number. No call, branch, property,
    // closure, environment access, mutation observable outside this frame,
    // or exit before the single final RET can enter the region.
    bool[32] numeric;
    for (uint i = 0; i < func.num_args; i++) numeric[i] = true;
    uint arithmetic = 0;
    for (uint i = 0; i < func.code_count; i++) {
        Instruction ins = func.code[i];
        if (ins.a >= 32) return;
        switch (ins.op) {
            case Opcode.RET:
                if (i + 1 != func.code_count || !numeric[ins.a]) return;
            case Opcode.LDINT:
                numeric[ins.a] = true;
            case Opcode.LDCONST:
                if (ins.get_bc() >= func.const_count) return;
                TVal* v = func.constants + ins.get_bc();
                if (!v.is_fastint() && !v.is_number()) return;
                numeric[ins.a] = true;
            case Opcode.LDREG:
                if (ins.b >= 32 || !numeric[ins.b]) return;
                numeric[ins.a] = true;
            case Opcode.ADD: case Opcode.ADD_FUSED:
            case Opcode.SUB: case Opcode.MUL: case Opcode.DIV:
                if (ins.b >= 32 || ins.c >= 32 || !numeric[ins.b] || !numeric[ins.c]) return;
                numeric[ins.a] = true;
                arithmetic++;
            case Opcode.ADDI: case Opcode.SUBI: case Opcode.MULI:
                if (ins.b >= 32 || !numeric[ins.b]) return;
                numeric[ins.a] = true;
                arithmetic++;
            default:
                return;
        }
    }
    if (func.code[func.code_count - 1].op != Opcode.RET || arithmetic == 0) return;

    // Reuse the generic instruction operands as the numeric region program:
    // +4 bytes/function, no duplicate body, no new CompiledFunction fields.
    Instruction* code = (Instruction*)hp.alloc_func(hp.heap_udata,
        (usz)(func.code_count + 1) * Instruction::size);
    if (code == null) return;
    code[0] = bytecode::make_abc(Opcode.NUMERIC_REGION, func.num_args, numeric_specialization == 3 ? 1 : 0, 0);
    for (uint i = 0; i < func.code_count; i++) code[i + 1] = func.code[i];
    hp.free_func(hp.heap_udata, func.code);
    func.code = code;
    func.code_count++;
    // No jumps/handlers/eval sites exist. Shift original instruction positions;
    // the guard itself gets the first source entry through normal lookup.
    for (uint i = 0; i < func.source_map_count; i++) func.source_map[i].pc++;
}
