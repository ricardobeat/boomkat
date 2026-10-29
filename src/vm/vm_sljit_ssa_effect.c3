module boomkat::vm;

import boomkat::heap;
import boomkat::hobject;
import boomkat::jit;
import boomkat::types;
import boomkat::bytecode;

// Nullish equality does not coerce. Keep the HTMLDDA case, even though most
// engines never install a sentinel in the heap.
fn void* SsaEmitter.effect_null_branch(&self, SsaValue v) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    self.gpr(v.a, r0);
    self.e.mov(r3, 0, imm, 0);
    self.e.op(jit::SLJIT_LSHR, r2, r0, 0, imm, 48);
    self.e.op(jit::SLJIT_SUB, r1, r2, 0, imm, (long)types::TAG_UNDEFINED);
    void* object_case = self.e.cmp(jit::SLJIT_GREATER, r1, 0, imm, 1);
    self.e.op(jit::SLJIT_AND, r1, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    void* done_a = self.e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0);
    self.e.mov(r3, 0, imm, 1);
    void* done_b = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    self.e.bind(object_case);
    void* done_c = self.e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)types::TAG_OBJECT);
    self.e.op(jit::SLJIT_AND, r1, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.e.mov(r2, 0, mem | jit::reg_s(1), $reflect(ColdCtx.heap).offset);
    Heap heap_view;
    self.e.mov(r2, 0, mem | r2, (char*)&heap_view.htmldda_obj - (char*)&heap_view);
    void* done_d = self.e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, r2, 0);
    self.e.mov(r3, 0, imm, 1);
    self.e.bind(done_a); self.e.bind(done_b); self.e.bind(done_c); self.e.bind(done_d);
    return self.e.cmp(v.branch_op == Opcode.JMP_NULL ? jit::SLJIT_NOT_EQUAL : jit::SLJIT_EQUAL, r3, 0, imm, 0);
}

// Existing own writable slot, guarded before the effect. Counted values and
// object writes requiring a collector barrier exit to the interpreter.
fn void SsaEmitter.effect_store(&self, uint memory, int index, int value) @feat(SLJIT) {
    int storage = ssa_alias(self.g, index);
    if (storage < 0 || self.g.values[storage].op != STORAGE) { self.e.failed = true; return; }
    int owner = self.g.values[storage].a;
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    self.gpr(index, r2);
    self.gpr(owner, r1);
    self.e.op(jit::SLJIT_AND, r1, r1, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    long offset = (long)self.plan.memory[memory].slot * 8;
    self.e.mov(r0, 0, mem | r2, offset);
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void* old_object = self.e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    self.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, self.pc);
    self.e.bind(old_object);
    self.gpr(value, r0);
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void* new_object = self.e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    self.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, self.pc);
    self.e.bind(new_object);
    void* primitive = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    self.e.mov(r3, 0, mem | jit::reg_s(1), $reflect(ColdCtx.heap).offset);
    self.e.mov(r3, 0, mem | r3, $reflect(Heap.gc_phase).offset, jit::SLJIT_MOV_U8);
    self.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)heap::GcPhase.MARK, self.pc);
    self.e.mov(r3, 0, mem | r1, $reflect(HObjectBase.gc).offset, jit::SLJIT_MOV_U32);
    self.e.op(jit::SLJIT_AND, r3, r3, 0, imm, 2);
    void* young = self.e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, 0);
    self.e.op(jit::SLJIT_AND, r3, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.e.mov(r3, 0, mem | r3, $reflect(HObjectBase.gc).offset, jit::SLJIT_MOV_U32);
    self.e.op(jit::SLJIT_AND, r3, r3, 0, imm, 2);
    self.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, self.pc);
    self.e.bind(young); self.e.bind(primitive);
    self.e.mov(mem | r2, offset, r0, 0);
}
