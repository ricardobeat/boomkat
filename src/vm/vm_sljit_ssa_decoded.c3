module boomkat::vm;

import boomkat::bytecode;
import boomkat::compiler;
import std::io;

// Scalable full bodies consume the same typed IR and lowering. This positive
// opcode contract is distinct from storage capacities and uses the existing
// shared helper boundary for operations with runtime effects.
fn bool ssa_decoded_helper_op(Opcode op) @feat(SLJIT) {
    return function_call_op(op) || function_alloc_op(op) || ssa_vm_step_supported(op);
}
fn bool ssa_decoded_body_op(Opcode op) @feat(SLJIT) {
    if (ssa_decoded_helper_op(op)) return true;
    if (ssa_comparison_op(op)) return true;
    switch (op) {
        case NOP: case LDREG: case LDTHIS: case LDINT: case LDCONST:
        case LDUNDEF: case LDNULL: case LDTRUE: case LDFALSE:
        case TONUMERIC: case INC: case INC_LT: case DEC:
        case ADD: case ADD_FUSED: case ADDI: case SUB: case SUBI: case MUL: case MULI: case DIV:
        case LT: case LE: case GT: case GE: case EQ: case NEQ: case SEQ: case SNEQ:
        case BAND: case BOR: case BXOR: case SHL: case SHR: case USHR: case BNOT:
        case BANDI: case BORI: case BXORI: case SHLI: case SHRI: case USHRI:
        case JUMP: case IF_TRUE: case IF_FALSE: case RET: case RETUNDEF: return true;
        default: return false;
    }
}
fn bool ssa_decoded_body_supported(LoopPlan* plan, CompiledFunction* cf) @feat(SLJIT) {
    if (plan.begin != 0 || plan.end + 1 != cf.code_count
        || cf.code_count > SSA_DEFAULT_BUDGET.max_words
        || cf.num_regs == 0 || cf.num_regs > 65536
        || cf.flags.is_generator || cf.flags.is_async || cf.flags.has_direct_eval
        || cf.flags.needs_lex_bridge || cf.mapped_arguments()) return false;
    for (uint pc = 0; pc < cf.code_count;) {
        DecodedBytecode view = bytecode::decode_bytecode(cf.code, cf.code_count, pc);
        if (!view.valid || !ssa_decoded_body_op(view.insn.op)) {
            $if $feat(SLJIT_STATS): io::eprintfn("SLJIT decoded reject pc=%d op=%s", pc, view.insn.op); $endif
            return false;
        }
        pc = view.next_pc;
    }
    return true;
}
