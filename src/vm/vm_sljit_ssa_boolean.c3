module boomkat::vm;

import boomkat::jit;
import boomkat::types;

// Both equality forms agree for two booleans. Refuse other actual types at
// the original comparison: loose coercion and strict mismatches belong to
// the VM, with earlier stores already committed in the before-frame.
fn bool SsaEmitter.boolean_compare(&self, int value) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (self.g.values[v.a].rep != BOXED) return false;
    if (v.b < 0 || self.g.values[v.b].rep != BOXED) { self.e.failed = true; return true; }
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1); int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    self.gpr(v.a, r0);
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_BOOLEAN, self.pc);
    self.gpr(v.b, r1);
    self.e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_BOOLEAN, self.pc);
    int condition = loop_condition(v.branch_op);
    if (condition != jit::SLJIT_EQUAL && condition != jit::SLJIT_NOT_EQUAL) { self.e.failed = true; return true; }
    if (jit::sljit_emit_op2u(self.e.compiler, jit::SLJIT_SUB | jit::SLJIT_SET_Z, r0, 0, r1, 0) != 0) self.e.failed = true;
    if (jit::sljit_emit_op_flags(self.e.compiler, jit::SLJIT_MOV, r0, 0, condition) != 0) self.e.failed = true;
    self.e.op(jit::SLJIT_OR, r0, r0, 0, imm, (long)(types::TAG_BOOLEAN << 48));
    self.store_gpr(value, r0);
    return true;
}
