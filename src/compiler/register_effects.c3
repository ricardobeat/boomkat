module boomkat::compiler;

import boomkat::bytecode;

// Conservative MAY-write effects, distinct from move elimination's MUST-def
// kill set and retargetable producers. Unknown instructions invalidate all
// homes; adding an opcode never silently preserves a stale typed value.
fn void register_may_writes(Instruction ins, RegSet* writes) {
    if (moveelim_a_is_write(ins.op)) { writes.set(ins.a); return; }
    switch (ins.op) {
        case Opcode.NEWOBJ:
        case Opcode.NEWOBJ_SHAPE:
        case Opcode.NEWARR:
        case Opcode.NEWARR_CONST:
        case Opcode.ADD_FUSED:
        case Opcode.GETCAP:
        case Opcode.GETPROP_CACHE:
        case Opcode.PUTCAP:
        case Opcode.INC_VAR:
        case Opcode.DEC_VAR:
        case Opcode.TONUMERIC:
        case Opcode.INC:
        case Opcode.INC_LT:
        case Opcode.DEC:
            writes.set(ins.a);
        case Opcode.NEW_OBJ:
        case Opcode.CALL:
        case Opcode.CALL_UNDEF_THIS:
            writes.set(ins.a);
            moveelim_mark_range(writes, ins.b, writes.word_count * 32 - 1);
        case Opcode.CALL_VAR:
        case Opcode.CALL_GLOBAL:
            moveelim_mark_range(writes, ins.a, writes.word_count * 32 - 1);
        case Opcode.INIT_SLOT:
        case Opcode.NOP:
        case Opcode.RET:
        case Opcode.RETUNDEF:
        case Opcode.PUTPROP:
        case Opcode.PUTPROPC:
        case Opcode.PUTTHISC:
        case Opcode.IF_TRUE:
        case Opcode.IF_FALSE:
        case Opcode.JUMP:
        case Opcode.JMP_NLT..Opcode.JMP_NNULL:
        case Opcode.JMP_NLTI..Opcode.JMP_SNEQI:
            return;
        default:
            for (uint word = 0; word < writes.word_count; word++) writes.words[word] = 0xFFFFFFFF;
    }
}
