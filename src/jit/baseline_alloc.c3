// Baseline tier allocation ops: NEWARR, NEWARR_CONST, NEWOBJ and
// NEWOBJ_SHAPE call the C helper that runs the threaded handler's body.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::bytecode;

// A direct call to vm::jit_alloc; a failed allocation takes the thunk, which
// repeats it and reports the failure.
fn bool Asm.emit_alloc(&self) {
    void* c = self.c;
    if (self.wide) return false;
    switch (self.w.op) {
        case NEWARR:
        case NEWARR_CONST:
        case NEWOBJ:
        case NEWOBJ_SHAPE:
            break;
        default:
            return false;
    }
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, self.code, 0, SLJIT_IMM, (long)self.next * Instruction::size);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS2WWW, SLJIT_IMM, (long)(usz)&vm::jit_alloc);
    sljit_emit_op1(c, SLJIT_MOV_U8, R0, 0, R0, 0);
    self.call.add(sljit_emit_cmp(c, SLJIT_EQUAL, R0, 0, SLJIT_IMM, 0));
    return true;
}
