module boomkat::vm;

import boomkat::heap;
import boomkat::hobject;
import boomkat::jit;

// A different receiver shape can still store the same own data property at
// the same offset. Prove that from the live shape rather than calling the
// generic property helper. R0 remains the ordinary receiver; R1..R3 are scratch.
// This proves one slot, not the receiver's complete shape.
fn void LoopEmitter.own_field_layout(&self, uint shape, uint slot, void* key, Heap* h, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.e;
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int mem = jit::SLJIT_MEM;
    int imm = jit::SLJIT_IMM;
    HObject object;
    Shape layout;
    ShapeProperty property;
    e.mov(r2, 0, mem | r0, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
    void* primary = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, shape);
    e.mov(r3, 0, mem | r0, (char*)&object.prop_count - (char*)&object, jit::SLJIT_MOV_U32);
    self.guard(jit::SLJIT_LESS_EQUAL, r3, 0, imm, slot, pc);
    e.mov(r1, 0, imm, (long)h);
    e.mov(r1, 0, mem | r1, $reflect(Heap.shapes).offset);
    e.op(jit::SLJIT_SHL, r2, r2, 0, imm, 3);
    e.op(jit::SLJIT_ADD, r1, r1, 0, r2, 0);
    e.mov(r1, 0, mem | r1, 0);
    void* probe = e.label();
    self.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, pc);
    e.mov(r2, 0, mem | r1, (char*)&layout.offset - (char*)&layout, jit::SLJIT_MOV_U32);
    void* owner = e.cmp(jit::SLJIT_LESS_EQUAL, r2, 0, imm, slot);
    e.mov(r1, 0, mem | r1, (char*)&layout.parent_shape - (char*)&layout);
    void* parent = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    jit::sljit_set_label(parent, probe);
    e.bind(owner);
    e.op(jit::SLJIT_SUB, r3, imm, slot, r2, 0);
    e.mov(r2, 0, mem | r1, (char*)&layout.own_count - (char*)&layout, jit::SLJIT_MOV_U32);
    self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, r2, 0, pc);
    e.op(jit::SLJIT_MUL, r3, r3, 0, imm, ShapeProperty::size);
    e.op(jit::SLJIT_ADD, r1, r1, 0, r3, 0);
    e.mov(r2, 0, mem | r1, Shape::size + (char*)&property.key - (char*)&property);
    self.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)key, pc);
    e.mov(r2, 0, mem | r1, Shape::size + (char*)&property.flags - (char*)&property, jit::SLJIT_MOV_U8);
    PropFlags accessor;
    accessor.is_accessor = true;
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, (uint)accessor);
    self.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0, pc);
    e.bind(primary);
}
