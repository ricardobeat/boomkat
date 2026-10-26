module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::jit;

// Emit before property(), then bind the returned success jump after it. Type
// mismatches fall through to that property's existing path. Once a dense-array
// read is selected, every refusal resumes the original opcode before storing.
fn void* FunctionEmitter.array_read(&self, CompiledFunction* cf, uint pc) @feat(SLJIT) {
    Instruction ins = cf.code[pc];
    if (ins.op != Opcode.GETPROP && ins.op != Opcode.GETPROP_CACHE) return null;
    LoopEmitter* out = &self.out; TemplateEmitter* e = &out.e;
    int r0 = jit::reg_r(0); int r1 = jit::reg_r(1); int r2 = jit::reg_r(2); int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM; int mem = jit::SLJIT_MEM;
    HObject obj;
    out.load(ins.b, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void* nonobject = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    void* nullobject = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
    e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r3, r2, 0, imm, 0x003F0000U);
    ObjFlags array; array.obj_class = ARRAY;
    void* nonarray = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (uint)array);
    out.load(ins.c, r1);
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    void* nonindex = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT);
    e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 16);
    e.op(jit::SLJIT_ASHR, r1, r1, 0, imm, 16);
    void* negative = e.cmp(jit::SLJIT_SIG_LESS, r1, 0, imm, 0);
    ObjFlags forbidden;
    forbidden.exotic_proxyobj = true; forbidden.exotic_module_ns = true; forbidden.exotic_deferred_ns = true;
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, (uint)forbidden);
    out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0, pc);
    e.mov(r3, 0, mem | r0, (char*)&obj.array_size - (char*)&obj, jit::SLJIT_MOV_U32);
    out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, pc);
    e.mov(r3, 0, mem | r0, HObjectBase::size, jit::SLJIT_MOV_U32);
    out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r3, 0, pc);
    // Resolve array_part() from the live object; named properties precede
    // external elements, while short literals keep elements in their header.
    e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
    void* external = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
    e.mov(r3, 0, mem | r0, HObjectBase::size + uint::size, jit::SLJIT_MOV_U32);
    out.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, pc);
    e.op(jit::SLJIT_ADD, r2, r0, 0, imm, hobject::OBJ_SIZE_ARRAY);
    void* base_ready = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(external);
    e.mov(r3, 0, mem | r0, (char*)&obj.prop_capacity - (char*)&obj, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_SHL, r3, r3, 0, imm, 3);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r3, 0);
    e.bind(base_ready);
    e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 3);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
    e.mov(r0, 0, mem | r2, 0);
    // Undefined denotes an absent dense slot, including values moved to the
    // named table by defineProperty. Prototype lookup belongs to the VM.
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    out.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED, pc);
    self.store(ins.a, pc);
    void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(nonobject); e.bind(nullobject); e.bind(nonarray); e.bind(nonindex); e.bind(negative);
    return done;
}
