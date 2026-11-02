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
        case UNM: case UNP: case LNOT: case INSTANCEOF:
        case JUMP: case IF_TRUE: case IF_FALSE:
        case JMP_NULL: case JMP_NNULL:
        case RET: case RETUNDEF: return true;
        default: return false;
    }
}
// Validate effective register fields before the renamer indexes its dynamic
// maps. Register roles come from the canonical CFG, including implicit calls.
fn bool ssa_decoded_registers_fit(CompiledFunction* cf, DecodedBytecode view) @feat(SLJIT) {
    DecodedInsn ins = view.insn;
    uint count = cf.num_regs;
    if (!compiler::moveelim_roles_ready) compiler::moveelim_init_roles();
    compiler::MoveelimRoles roles = compiler::bytecode_cfg_roles(ins.op);
    if ((roles.a_read || roles.a_write) && ins.a >= count) return false;
    if (roles.b_read && ins.b >= count) return false;
    if (roles.c_read && bytecode::get_op_format(ins.op) == OpFormat.ABC && ins.c >= count) return false;
    if (function_call_op(ins.op)) {
        bool fused = ins.op == Opcode.CALL_VAR || ins.op == Opcode.CALL_GLOBAL;
        uint base = fused ? ins.a : ins.b;
        uint argc = fused ? ins.b : ins.c;
        if (base + 1 >= count || base + 2 + argc > count) return false;
    }
    if (ins.op == Opcode.INIT_SLOT && (ins.a >= count || ins.c >= count)) return false;
    if (ins.op == Opcode.CLOSURE && ins.get_bc() < cf.inner_count) {
        CompiledFunction* child = cf.inner_funcs[ins.get_bc()];
        if (child.capture_cells != null) for (uint i = 0; i < child.capture_count; i++) {
            if (child.capture_cells[i] != 0 && child.capture_parent_reg >= count) return false;
        }
    }
    return true;
}
fn bool ssa_decoded_body_supported(LoopPlan* plan, CompiledFunction* cf) @feat(SLJIT) {
    if (plan.begin != 0 || plan.end + 1 != cf.code_count
        || cf.code_count > SSA_DEFAULT_BUDGET.max_words
        || cf.num_regs == 0 || cf.num_regs > 65536
        || cf.flags.is_generator || cf.flags.is_async || cf.flags.has_direct_eval
        || cf.flags.needs_lex_bridge || cf.mapped_arguments()) return false;
    for (uint pc = 0; pc < cf.code_count;) {
        DecodedBytecode view = bytecode::decode_bytecode(cf.code, cf.code_count, pc);
        if (!view.valid || !ssa_decoded_body_op(view.insn.op) || !ssa_decoded_registers_fit(cf, view)) {
            $if $feat(SLJIT_STATS): io::eprintfn("SLJIT decoded reject pc=%d op=%s", pc, view.insn.op); $endif
            return false;
        }
        pc = view.next_pc;
    }
    return true;
}
