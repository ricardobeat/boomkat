module boomkat::vm;

import boomkat::jit;
import boomkat::types;
import boomkat::hobject;

// A receiver is a value in function SSA, not a prepared loop descriptor.
// Keeping its structure check in the graph lets dominance remove repeated
// checks for other fields of the same object.
fn int ssa_field_storage(SsaGraph* g, uint memory, int dynamic = -1) @feat(SLJIT) {
    LoopMemorySpec spec = g.plan.memory[memory];
    int receiver;
    if (g.recoverable && dynamic >= 0) {
        // The binding helper may have produced a different receiver since
        // entry. Its current SSA value is the authority after aliasing stores.
        receiver = dynamic;
    } else if (spec.kind == PROTO_FIELD && dynamic >= 0) {
        receiver = dynamic;
    } else if (spec.kind == SHAPE_FIELD) {
        receiver = dynamic;
    } else if (spec.source == LOOP_THIS) {
        receiver = ssa_value(g, RECEIVER, BOXED, -1, -1, 0);
    } else if (spec.source >= LOOP_REGS) {
        receiver = ssa_value(g, BINDING, BOXED, -1, -1, (long)(spec.source - LOOP_REGS));
    } else {
        receiver = g.current[spec.source];
    }
    receiver = ssa_convert(g, receiver, BOXED, false);
    ssa_use(g, receiver);
    if (spec.kind == PROTO_FIELD) return ssa_value(g, PROTO_STORAGE, RAW, receiver, -1, memory);
    ssa_value(g, CHECKSHAPE, BOXED, receiver, -1, memory);
    if (spec.written && spec.kind == SHAPE_FIELD) {
        ssa_use(g, receiver);
        ssa_value(g, CHECKWRITE, BOXED, receiver, -1, 0);
    } else if (spec.kind == FIELD) {
        foreach (other : g.plan.memory[:g.plan.memory_count]) {
            if (other.written && other.kind == FIELD && other.source == spec.source) {
                ssa_use(g, receiver);
                ssa_value(g, CHECKWRITE, BOXED, receiver, -1, 0);
                break;
            }
        }
    }
    ssa_use(g, receiver);
    return ssa_value(g, STORAGE, RAW, receiver, -1, 0);
}

fn void SsaEmitter.check_shape(&self, int receiver, uint memory) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    HObject object;
    self.gpr(receiver, r0);
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, self.pc);
    self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, self.pc);
    self.ordinary_receiver(r0, self.pc);
    self.e.mov(r2, 0, jit::SLJIT_MEM | r0, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
    self.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, self.plan.memory[memory].shape, self.pc);
}

fn void SsaEmitter.field_address(&self, int receiver, int storage) @feat(SLJIT) {
    HObject object;
    self.e.mov(storage, 0, jit::SLJIT_MEM | receiver, (char*)&object.prop_alloc - (char*)&object);
    void* allocated = self.e.cmp(jit::SLJIT_NOT_EQUAL, storage, 0, jit::SLJIT_IMM, 0);
    self.e.op(jit::SLJIT_ADD, storage, receiver, 0, jit::SLJIT_IMM, HObjectBase::size);
    self.e.bind(allocated);
}

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
        self.e.mov(r0, 0, mem | self.state, self.memory_offset(prior, 0));
        self.e.mov(mem | self.state, self.memory_offset(memory, 0), r0, 0);
        if (spec.written) {
            self.e.op(jit::SLJIT_AND, r1, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
            self.commit_receiver(r1);
        }
        self.e.mov(r2, 0, mem | self.state, self.memory_offset(prior, 1));
        self.e.op(jit::SLJIT_ADD, r2, r2, 0, imm, ((long)spec.slot - earlier.slot) * 8);
        self.e.mov(mem | self.state, self.memory_offset(memory, 1), r2, 0);
        self.e.mov(mem | self.state, self.memory_offset(memory, 2), imm, 0);
        return;
    }
    LoopState layout;
    long source = spec.source < LOOP_REGS ? loop_value_offset(spec.source)
        : spec.source == LOOP_THIS ? (char*)&layout.receiver - (char*)&layout
        : (char*)&layout.bindings[spec.source - LOOP_REGS] - (char*)&layout;
    if (self.g.inplace && spec.source == LOOP_THIS) {
        self.e.mov(r0, 0, mem | self.regs, loop_value_offset(self.g.inline_base + 1));
    } else if (self.g.direct && spec.source == LOOP_THIS) {
        self.e.mov(r0, 0, jit::reg_s(3), 0);
    } else {
        if (self.g.inplace) {
            if (spec.source < LOOP_REGS) { source += loop_value_offset(self.g.inline_base + 2); }
            else { source = self.binding_offset(spec.source - LOOP_REGS); }
        }
        self.e.mov(r0, 0, mem | (spec.source < LOOP_REGS ? self.regs : self.state), source);
    }
    self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.snapshot_none(self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT), self.plan.begin);
    self.e.mov(mem | self.state, self.memory_offset(memory, 0), r0, 0);
    self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.snapshot_none(self.e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0), self.plan.begin);
    self.ordinary_receiver(r0, self.plan.begin, true);
    HObject object;
    if (spec.written) self.commit_receiver(r0);
    self.e.mov(r3, 0, mem | r0, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
    self.snapshot_none(self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, spec.shape), self.plan.begin);
    self.e.mov(r1, 0, mem | r0, (char*)&object.prop_alloc - (char*)&object);
    void* allocated = self.e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0);
    self.e.op(jit::SLJIT_ADD, r1, r0, 0, imm, HObjectBase::size);
    self.e.bind(allocated);
    self.e.op(jit::SLJIT_ADD, r2, r1, 0, imm, (long)spec.slot * 8);
    self.e.mov(mem | self.state, self.memory_offset(memory, 1), r2, 0);
    self.e.mov(mem | self.state, self.memory_offset(memory, 2), imm, 0);
}

// Updating an observed prototype needs the runtime's epoch bookkeeping.
fn void SsaEmitter.commit_receiver(&self, int receiver) @feat(SLJIT) {
    GcBits observed;
    observed.prototype_observed = true;
    observed.jit_observed = true;
    HObject object;
    int r3 = jit::reg_r(3);
    self.e.mov(r3, 0, jit::SLJIT_MEM | receiver, (char*)&object.gc - (char*)&object, jit::SLJIT_MOV_U32);
    self.e.op(jit::SLJIT_AND, r3, r3, 0, jit::SLJIT_IMM, (uint)observed);
    void* observed_jump = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, 0);
    if (self.g.recoverable) { self.snapshot(observed_jump, self.pc); }
    else { self.snapshot_none(observed_jump, self.plan.begin); }
}

// Own data-slot specialization excludes every object class with custom reads.
fn void SsaEmitter.ordinary_receiver(&self, int receiver, uint pc, bool entry = false) @feat(SLJIT) {
    int r3 = jit::reg_r(3);
    ObjFlags forbidden;
    forbidden.exotic_proxyobj = true;
    forbidden.exotic_module_ns = true;
    forbidden.exotic_deferred_ns = true;
    forbidden.exotic_arguments = true;
    forbidden.exotic_stringobj = true;
    forbidden.exotic_array = true;
    ObjFlags ordinary;
    ordinary.obj_class = OBJECT;
    self.e.mov(r3, 0, jit::SLJIT_MEM | receiver, 0, jit::SLJIT_MOV_U32);
    self.e.op(jit::SLJIT_AND, r3, r3, 0, jit::SLJIT_IMM, 0x003F0000U | (uint)forbidden);
    void* mismatch = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, (uint)ordinary);
    if (entry) { self.snapshot_none(mismatch, pc); }
    else { self.snapshot(mismatch, pc); }
}
