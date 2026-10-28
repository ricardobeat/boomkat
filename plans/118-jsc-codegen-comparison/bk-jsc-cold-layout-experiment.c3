module boomkat::vm;

import boomkat::heap;
import boomkat::hobject;
import boomkat::jit;
import boomkat::bytecode;
import boomkat::types;

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

fn void FunctionEmitter.read_layout_continuation(&self, CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    if (self.plan.numeric_homes != 0 || cf.ic_entries == null) return;
    ICEntry* ic = (ICEntry*)cf.ic_entries + pc;
    if (ic.has_proto || ic.key.borrow() == null || ic.prop_flags.is_accessor || ic.prop_idx >= hobject::IC_PROP_MISSING) return;
    Shape* shape = h.get_shape(ic.shape_id);
    if (shape == null || shape.dict || shape.generation != ic.shape_gen) return;
    PropFlags flags;
    if (function_shape_slot(shape, ic.key.borrow(), &flags) != (int)ic.prop_idx || flags.is_accessor) return;
    Instruction ins = cf.code[pc];
    LoopPlan plan;
    LoopEmitter cold = { .e = self.out.e, .plan = &plan, .function_mode = true };
    TemplateEmitter* e = &cold.e;
    int r0 = jit::reg_r(0);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    if (ins.op == Opcode.GETTHISC) { e.mov(r0, 0, jit::reg_s(3), 0); }
    else { cold.load(ins.b, r0); }
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    cold.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    cold.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    HObject object;
    ObjFlags ordinary;
    ordinary.obj_class = OBJECT;
    ObjFlags forbidden;
    forbidden.exotic_proxyobj = true;
    forbidden.exotic_module_ns = true;
    forbidden.exotic_deferred_ns = true;
    forbidden.exotic_arguments = true;
    forbidden.exotic_stringobj = true;
    forbidden.exotic_array = true;
    e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, 0x003F0000U | (uint)forbidden);
    cold.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
    cold.own_field_layout(ic.shape_id, ic.prop_idx, ic.key.borrow(), h, pc);
    e.mov(r2, 0, mem | r0, (char*)&object.prop_alloc - (char*)&object);
    void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
    e.op(jit::SLJIT_ADD, r2, r0, 0, imm, HObjectBase::size);
    e.bind(allocated);
    e.mov(r0, 0, mem | r2, (long)ic.prop_idx * 8);
    function_store(&cold, ins.a, r0, pc);
    self.out.bind_to(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), self.out.labels[pc + 1]);
    void* refused = e.label();
    for (uint i = 0; i < cold.link_count; i++) cold.bind_to(cold.link_at(i).jump, refused);
    if (cold.e.failed) self.out.e.failed = true;
}
