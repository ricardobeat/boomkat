module boomkat::vm;

import boomkat::bytecode;
import boomkat::jit;

// All coercion guards precede the destination write. Non-numbers, BigInts,
// and doubles outside int32's narrow conversion path resume this instruction
// in the interpreter, which owns the complete ToNumeric/ToInt32 semantics.
fn void FunctionEmitter.bitwise(&self, Instruction ins, uint pc) @feat(SLJIT) {
    LoopEmitter* out = &self.out;
    TemplateEmitter* e = &out.e;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1);
    int imm = jit::SLJIT_IMM;
    switch (ins.op) {
        case UNM: case UNP:
            out.number_reg(ins.b, 1, pc);
            if (ins.op == Opcode.UNM) out.fop(jit::SLJIT_NEG_F64, 1, 0, 1, 0);
            out.float_result(1);
        case BNOT:
            out.int32(ins.b, r0, pc);
            e.op(jit::SLJIT_XOR, r0, r0, 0, imm, -1);
            out.box(r0);
        default: {
            out.int32(ins.b, r0, pc);
            bool immediate = ins.op == Opcode.BANDI || ins.op == Opcode.BORI || ins.op == Opcode.BXORI
                || ins.op == Opcode.SHLI || ins.op == Opcode.SHRI || ins.op == Opcode.USHRI;
            if (immediate) { e.mov(r1, 0, imm, (long)ins.c); }
            else { out.int32(ins.c, r1, pc); }
            if (ins.op == Opcode.BAND || ins.op == Opcode.BANDI || ins.op == Opcode.BOR || ins.op == Opcode.BORI
                || ins.op == Opcode.BXOR || ins.op == Opcode.BXORI) {
                int op = ins.op == Opcode.BAND || ins.op == Opcode.BANDI ? jit::SLJIT_AND
                    : (ins.op == Opcode.BOR || ins.op == Opcode.BORI ? jit::SLJIT_OR : jit::SLJIT_XOR);
                e.op(op, r0, r0, 0, r1, 0);
                e.mov(r0, 0, r0, 0, jit::SLJIT_MOV_S32);
            } else {
                e.op(jit::SLJIT_AND, r1, r1, 0, imm, 31);
                bool right = ins.op == Opcode.SHR || ins.op == Opcode.SHRI;
                bool unsigned_right = ins.op == Opcode.USHR || ins.op == Opcode.USHRI;
                if (unsigned_right) e.mov(r0, 0, r0, 0, jit::SLJIT_MOV_U32);
                e.op(right ? jit::SLJIT_ASHR : (unsigned_right ? jit::SLJIT_LSHR : jit::SLJIT_SHL), r0, r0, 0, r1, 0);
                if (!unsigned_right) e.mov(r0, 0, r0, 0, jit::SLJIT_MOV_S32);
            }
            out.box(r0);
        }
    }
    // The result is always numeric; use the function tier's ownership-aware
    // store for cached values and overwritten string destinations.
    function_store(out, ins.a, r0, pc, true);
}
