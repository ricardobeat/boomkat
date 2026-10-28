module boomkat::vm;

import boomkat::jit;
import boomkat::types;
import boomkat::hobject;

// Single-pass own fields: validate the receiver once at entry and derive the
// address without C-side property lookup. Admission excludes dictionary shapes;
// the enclosing header guards the shape-recycle epoch before any slot access.
fn void SsaEmitter.field_entry(&self, uint memory) @feat(SLJIT) {
    LoopMemorySpec spec = self.plan.memory[memory];
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    // One validated layout covers every slot of the same invariant receiver.
    // No helper, write or allocation can change its storage during this region.
    for (uint prior = 0; prior < memory; prior++) {
        LoopMemorySpec earlier = self.plan.memory[prior];
        if (earlier.source != spec.source || earlier.shape != spec.shape) continue;
        self.e.mov(r0, 0, mem | self.state, loop_memory_offset(prior, 0));
        self.e.mov(mem | self.state, loop_memory_offset(memory, 0), r0, 0);
        self.e.mov(r2, 0, mem | self.state, loop_memory_offset(prior, 1));
        self.e.op(jit::SLJIT_ADD, r2, r2, 0, imm, ((long)spec.slot - earlier.slot) * 8);
        self.e.mov(mem | self.state, loop_memory_offset(memory, 1), r2, 0);
        self.e.mov(mem | self.state, loop_memory_offset(memory, 2), imm, 0);
        return;
    }
    LoopState layout;
    long source = spec.source < LOOP_REGS ? loop_value_offset(spec.source)
        : spec.source == LOOP_THIS ? (char*)&layout.receiver - (char*)&layout
        : (char*)&layout.bindings[spec.source - LOOP_REGS] - (char*)&layout;
    if (self.g.direct && spec.source == LOOP_THIS) {
        self.e.mov(r0, 0, jit::reg_s(3), 0);
    } else {
        self.e.mov(r0, 0, mem | (spec.source < LOOP_REGS ? self.regs : self.state), source);
    }
    self.e.mov(mem | self.state, loop_memory_offset(memory, 0), r0, 0);
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.snapshot_none(self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT), self.plan.begin);
    self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.snapshot_none(self.e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0), self.plan.begin);
    ObjFlags forbidden;
    forbidden.exotic_proxyobj = true;
    forbidden.exotic_module_ns = true;
    forbidden.exotic_deferred_ns = true;
    forbidden.exotic_arguments = true;
    forbidden.exotic_stringobj = true;
    forbidden.exotic_array = true;
    ObjFlags ordinary;
    ordinary.obj_class = OBJECT;
    self.e.mov(r3, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    self.e.op(jit::SLJIT_AND, r3, r3, 0, imm, 0x003F0000U | (uint)forbidden);
    self.snapshot_none(self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (uint)ordinary), self.plan.begin);
    HObject object;
    self.e.mov(r3, 0, mem | r0, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
    self.snapshot_none(self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, spec.shape), self.plan.begin);
    self.e.mov(r1, 0, mem | r0, (char*)&object.prop_alloc - (char*)&object);
    void* allocated = self.e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0);
    self.e.op(jit::SLJIT_ADD, r1, r0, 0, imm, HObjectBase::size);
    self.e.bind(allocated);
    self.e.op(jit::SLJIT_ADD, r2, r1, 0, imm, (long)spec.slot * 8);
    self.e.mov(mem | self.state, loop_memory_offset(memory, 1), r2, 0);
    self.e.mov(mem | self.state, loop_memory_offset(memory, 2), imm, 0);
}
