module boomkat::vm;

import boomkat::bytecode;
import boomkat::compiler;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::builtins;
import boomkat::jit;
import std::core::mem;
import std::io;

// SLJIT emission and interpreter recovery for SSA graphs.

struct SsaEmitter @feat(SLJIT) {
    TemplateEmitter e;
    SsaGraph* g;
    LoopPlan* plan;
    CompiledFunction* cf;
    int state;
    long state_bias;
    int regs;
    int budget;
    ulong dirty_mask;
    int[LOOP_REGS] live;
    uint at_def;
    uint pc;
    void* header;
    void* epoch_constant;
    void*[SSA_EXITS + 1] done_jumps;
    uint done_count;
    int[2] memory_length;
    int[2] memory_base;
    // The address of the last element access, when it was computed for the
    // same memory and index value. A load and the store that follows it in
    // one iteration share it instead of recomputing base plus offset.
    int addr_memory;
    int addr_value;
    int addr_reg;
    bool addr_numeric_load;
    // The label of each block, and the jumps that reach them.
    void*[SSA_BLOCKS] block_label;
    void*[64] pending_jump;
    uint[64] pending_target;
    uint pending_count;
}

// Standalone kernels keep their public LoopState ABI. In-place SSA uses only
// the invocation-local descriptors/bindings/spills, packed into unused windows.
fn long SsaEmitter.memory_offset(&self, uint memory, uint field) @feat(SLJIT) => self.g.inplace
    ? self.state_bias + (long)memory * LoopMemory::size + (long)field * TVal::size : loop_memory_offset(memory, field);
fn long SsaEmitter.binding_offset(&self, uint binding) @feat(SLJIT) {
    LoopState state;
    return self.g.inplace ? self.state_bias + (long)self.plan.memory_count * LoopMemory::size + (long)binding * TVal::size
        : (char*)&state.bindings[binding] - (char*)&state;
}
fn long SsaEmitter.spill_offset(&self, uint spill) @feat(SLJIT) => self.g.inplace
    ? self.state_bias + (long)self.plan.memory_count * LoopMemory::size + (long)self.plan.binding_count * TVal::size
        + (long)spill * double::size : ssa_spill_offset(spill);

fn void SsaEmitter.gpr(&self, int value, int dst) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (v.home != 0) {
        self.e.mov(dst, 0, v.home, 0);
    } else {
        self.e.mov(dst, 0, jit::SLJIT_MEM | self.state, self.spill_offset(v.spill));
    }
}
fn void SsaEmitter.load_fpr(&self, int value, int dst) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (v.home != 0) {
        if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_MOV_F64, dst, 0, v.home, 0) != 0) self.e.failed = true;
    } else {
        if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_MOV_F64, dst, 0,
            jit::SLJIT_MEM | self.state, self.spill_offset(v.spill)) != 0) self.e.failed = true;
    }
}
fn void SsaEmitter.store_gpr(&self, int value, int src) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    bool effect_string = self.plan.ssa_effect_prefix && self.g.inplace && v.rep == BOXED
        && v.op != CONST_BOX && v.op != COMPARE && v.op != BOX_I && v.op != BOX_F;
    if (effect_string || (self.g.inplace && v.home == 0 && !ssa_inert_value(self.g, value))) {
        int tag = src == jit::reg_r(3) ? jit::reg_r(2) : jit::reg_r(3);
        self.e.op(jit::SLJIT_LSHR, tag, src, 0, jit::SLJIT_IMM, 48);
        void* counted = self.e.cmp(jit::SLJIT_EQUAL, tag, 0, jit::SLJIT_IMM, (long)types::TAG_STRING);
        if (self.plan.ssa_effect_prefix) { self.snapshot(counted, self.pc); }
        else { self.snapshot_none(counted, self.plan.begin); }
    }
    if (v.home != 0) {
        self.e.mov(v.home, 0, src, 0);
    } else {
        self.e.mov(jit::SLJIT_MEM | self.state, self.spill_offset(v.spill), src, 0);
    }
}
fn void SsaEmitter.store_fpr(&self, int value, int src) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (v.home != 0) {
        if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_MOV_F64, v.home, 0, src, 0) != 0) self.e.failed = true;
    } else {
        if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_MOV_F64,
            jit::SLJIT_MEM | self.state, self.spill_offset(v.spill), src, 0) != 0) self.e.failed = true;
    }
}
// Register holding an integer or boxed value, spilling into `scratch` only
// when the value has no home. Returning the home directly lets operations
// consume operands in place instead of copying them through a scratch pair.
fn int SsaEmitter.gpr_slot(&self, int value, int scratch) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (v.home != 0) return v.home;
    self.e.mov(scratch, 0, jit::SLJIT_MEM | self.state, self.spill_offset(v.spill));
    return scratch;
}
fn int SsaEmitter.fpr_slot(&self, int value, int scratch) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if (v.home != 0) return v.home;
    self.load_fpr(value, scratch);
    return scratch;
}
// One bounded exit table owns every recovery snapshot. Fixed arrays copy
// by value, so the snapshot remains independent of later graph mutations.
fn void SsaEmitter.snapshot_frame(&self, void* jump, uint pc, int[LOOP_REGS]* regs = null) @feat(SLJIT) {
    if (self.g.exit_count == SSA_EXITS) {
        self.e.failed = true;
        return;
    }
    SsaExit* item = &self.g.exits[self.g.exit_count++];
    item.jump = jump;
    item.pc = pc;
    if (regs != null) {
        item.regs = *regs;
    } else {
        foreach (&reg : item.regs) *reg = -1;
    }
}
fn void SsaEmitter.snapshot_none(&self, void* jump, uint pc) @feat(SLJIT) => self.snapshot_frame(jump, pc);
fn void SsaEmitter.snapshot_phis(&self, void* jump, uint pc) @feat(SLJIT) => self.snapshot_frame(jump, pc, &self.g.phi);
fn void SsaEmitter.snapshot(&self, void* jump, uint pc) @feat(SLJIT) {
    if (self.g.direct) { self.snapshot_none(jump, self.plan.begin); }
    else { self.snapshot_frame(jump, pc, &self.g.frames[pc - self.plan.begin]); }
}
fn void SsaEmitter.guard(&self, int condition, int left, long lw, int right, long rw, uint pc) @feat(SLJIT) {
    self.snapshot(self.e.cmp(condition, left, lw, right, rw), pc);
}
fn void SsaEmitter.float_guard(&self, int condition, int left, long lw, int right, long rw, uint pc) @feat(SLJIT) {
    void* jump = jit::sljit_emit_fcmp(self.e.compiler, condition, left, lw, right, rw);
    if (jump == null) {
        self.e.failed = true;
        return;
    }
    self.snapshot(jump, pc);
}
fn void SsaEmitter.box_gpr(&self, int reg) @feat(SLJIT) {
    self.e.op(jit::SLJIT_AND, reg, reg, 0, jit::SLJIT_IMM, 0x0000FFFFFFFFFFFF);
    self.e.op(jit::SLJIT_OR, reg, reg, 0, jit::SLJIT_IMM, (long)(types::TAG_FASTINT << 48));
}
fn void SsaEmitter.bits_fpr(&self, int freg, int dst) @feat(SLJIT) {
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_FROM_F64, freg, dst) != 0) self.e.failed = true;
    self.e.op(jit::SLJIT_LSHR, jit::reg_r(3), dst, 0, jit::SLJIT_IMM, 48);
    void* ordinary = self.e.cmp(jit::SLJIT_LESS, jit::reg_r(3), 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.e.mov(dst, 0, jit::SLJIT_IMM, 0x7FF8000000000000L);
    self.e.bind(ordinary);
}
fn void SsaEmitter.number(&self, int reg, int freg, uint pc) @feat(SLJIT) {
    int r3 = jit::reg_r(3);
    self.e.op(jit::SLJIT_LSHR, r3, reg, 0, jit::SLJIT_IMM, 48);
    self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
    void* floating = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.e.op(jit::SLJIT_SHL, reg, reg, 0, jit::SLJIT_IMM, 16);
    self.e.op(jit::SLJIT_ASHR, reg, reg, 0, jit::SLJIT_IMM, 16);
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_F64_FROM_SW, freg, 0, reg, 0) != 0) self.e.failed = true;
    void* done = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    self.e.bind(floating);
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, freg, reg) != 0) self.e.failed = true;
    self.e.bind(done);
}
// Sign-extend a boxed fastint into `dst` and exit when the value does not fit
// in int32, keeping INT32 values plain and range-checked.
fn void SsaEmitter.unbox_fastint(&self, int reg, int dst, uint pc) @feat(SLJIT) {
    int r3 = jit::reg_r(3);
    self.e.mov(r3, 0, reg, 0, jit::SLJIT_MOV_S32);
    self.e.op(jit::SLJIT_SHL, dst, reg, 0, jit::SLJIT_IMM, 16);
    self.e.op(jit::SLJIT_ASHR, dst, dst, 0, jit::SLJIT_IMM, 16);
    self.guard(jit::SLJIT_NOT_EQUAL, dst, 0, r3, 0, pc);
}
fn void SsaEmitter.int32(&self, int reg, int dst, uint pc) @feat(SLJIT) {
    int r1 = jit::reg_r(1);
    int r3 = jit::reg_r(3);
    self.e.op(jit::SLJIT_LSHR, r3, reg, 0, jit::SLJIT_IMM, 48);
    void* integer = self.e.cmp(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
    self.e.op(jit::SLJIT_AND, r3, reg, 0, jit::SLJIT_IMM, 0x7FFFFFFFFFFFFFFFL);
    self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, jit::SLJIT_IMM, 0x41E0000000000000L, pc);
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 1, reg) != 0) self.e.failed = true;
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_SW_FROM_F64, dst, 0, 1, 0) != 0) self.e.failed = true;
    void* done = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    self.e.bind(integer);
    self.unbox_fastint(reg, r1, pc);
    self.e.mov(dst, 0, r1, 0);
    self.e.bind(done);
}
// Exact integral conversion used by counters and indices. The value must be
// an integer inside int32 and must not be -0; anything else exits.
fn void SsaEmitter.exact_int(&self, int reg, int dst, uint pc) @feat(SLJIT) {
    int r1 = jit::reg_r(1);
    int r3 = jit::reg_r(3);
    self.e.op(jit::SLJIT_LSHR, r3, reg, 0, jit::SLJIT_IMM, 48);
    void* integer = self.e.cmp(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT);
    self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 1, reg) != 0) self.e.failed = true;
    self.float_guard(jit::SLJIT_UNORDERED, 1, 0, 1, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(-2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.float_guard(jit::SLJIT_ORDERED_LESS, 1, 0, 2, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.float_guard(jit::SLJIT_ORDERED_GREATER_EQUAL, 1, 0, 2, 0, pc);
    self.e.op(jit::SLJIT_SHL, r3, reg, 0, jit::SLJIT_IMM, 1);
    void* nonzero = self.e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, 0);
    self.guard(jit::SLJIT_SIG_LESS, reg, 0, jit::SLJIT_IMM, 0, pc);
    self.e.bind(nonzero);
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_SW_FROM_F64, dst, 0, 1, 0) != 0) self.e.failed = true;
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_F64_FROM_SW, 2, 0, dst, 0) != 0) self.e.failed = true;
    self.float_guard(jit::SLJIT_ORDERED_NOT_EQUAL, 1, 0, 2, 0, pc);
    void* done = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    self.e.bind(integer);
    self.unbox_fastint(reg, r1, pc);
    self.e.mov(dst, 0, r1, 0);
    self.e.bind(done);
}

fn void SsaEmitter.header_guards(&self) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    if (self.g.single_pass && self.plan.ssa_fields) {
        LoopState layout;
        self.epoch_constant = jit::sljit_emit_const(self.e.compiler, jit::SLJIT_MOV, jit::reg_r(1), 0, self.plan.ssa_shape_epoch);
        if (self.epoch_constant == null) self.e.failed = true;
        if (self.g.direct || (self.g.inplace && self.plan.ssa_effect_prefix)) {
            Heap heap;
            self.e.mov(r0, 0, jit::SLJIT_MEM | jit::reg_s(1), $reflect(ColdCtx.heap).offset);
            self.e.mov(r0, 0, jit::SLJIT_MEM | r0, (char*)&heap.shape_recycle_epoch - (char*)&heap, jit::SLJIT_MOV_U32);
        } else {
            self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, (char*)&layout.shape_epoch - (char*)&layout, jit::SLJIT_MOV_U32);
        }
        self.snapshot_none(self.e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, jit::reg_r(1), 0), self.plan.begin);
    }
    for (uint memory = 0; memory < self.plan.memory_count && memory < LOOP_MEMORY; memory++) {
        if (self.g.direct_fields && (self.plan.memory[memory].kind == FIELD || self.plan.memory[memory].kind == PROTO_FIELD)) continue;
        // Layout-only descriptors are checked against the live SSA receiver
        // at each access. They have no invocation-local source to compare.
        if (self.plan.memory[memory].kind == SHAPE_FIELD || !self.g.invariant[memory]) continue;
        uint source = self.plan.memory[memory].source;
        if (self.g.single_pass && self.plan.ssa_fields) {
            if (self.plan.memory[memory].kind == SHAPE_FIELD) continue;
            self.field_entry(memory);
        }
        if (source < LOOP_REGS && !(self.g.direct && self.plan.ssa_fields)) {
            self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, loop_value_offset(source));
            void* jump = self.e.cmp(
                jit::SLJIT_NOT_EQUAL,
                r0,
                0,
                jit::SLJIT_MEM | self.state,
                self.memory_offset(memory, 0)
            );
            self.snapshot_none(jump, self.plan.begin);
        }
        // The descriptor of an invariant memory cannot change during the run,
        // so its data pointer and length stay in registers instead of being
        // reloaded for every element access.
        if (memory < 2 && self.plan.memory[memory].kind != FIELD
            && self.plan.memory[memory].kind != SHAPE_FIELD
            && self.g.registers.saveds >= 7 + memory * 2) {
            self.memory_length[memory] = jit::reg_s(5 + (int)memory * 2);
            self.memory_base[memory] = jit::reg_s(6 + (int)memory * 2);
            self.e.mov(self.memory_length[memory], 0, jit::SLJIT_MEM | self.state, self.memory_offset(memory, 2));
            self.e.mov(self.memory_base[memory], 0, jit::SLJIT_MEM | self.state, self.memory_offset(memory, 1));
        }
    }
}
fn void SsaEmitter.prologue(&self) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        int value = self.g.phi[reg] >= 0 ? self.g.phi[reg] : self.g.arg[reg];
        if (value < 0 || ((self.g.direct || (self.g.inplace && self.plan.ssa_effect_prefix))
            && self.g.values[value].last == self.g.values[value].def)) continue;
        SsaRep rep = self.g.values[value].rep;
        self.e.mov(r0, 0, jit::SLJIT_MEM | self.regs, loop_value_offset(reg + (self.g.inplace && !self.g.callee_entry && !self.plan.ssa_effect_prefix ? self.g.inline_base + 2 : 0)));
        if (rep == INT32) {
            self.exact_int(r0, r0, self.plan.begin);
            self.store_gpr(value, r0);
        } else if (rep == F64) {
            self.number(r0, 1, self.plan.begin);
            self.store_fpr(value, 1);
        } else {
            self.store_gpr(value, r0);
        }
    }
}

fn void SsaEmitter.output(&self, int value, uint pc) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    int r0     = jit::reg_r(0);
    if (v.rep == F64) {
        self.load_fpr(value, 1);
        self.bits_fpr(1, r0);
    } else if (v.rep == INT32) {
        self.gpr(value, r0);
        self.box_gpr(r0);
    } else if (v.rep == RAW) {
        self.e.failed = true;
    } else {
        self.gpr(value, r0);
    }
}

fn void SsaEmitter.body(&self) @feat(SLJIT) {
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    int mem            = jit::SLJIT_MEM;
    TemplateEmitter* e = &self.e;
    self.addr_reg = 0;
    for (uint b = 0; b < self.g.block_count; b++) {
        self.addr_reg = 0;
        self.live = self.g.frames[self.g.blocks[b].begin - self.plan.begin];
        self.block_label[b] = e.label();
        uint first = self.g.block_first[b];
        uint last  = self.g.block_last[b];
        for (uint i = first; i < last; i++) {
            SsaValue v = self.g.values[i];
            self.at_def = v.def;
            self.pc = v.pc;
            if (v.op != LOAD && v.op != STORE) self.addr_reg = 0;
            switch (v.op) {
                case NOP:
                case ARG:
                case PHI: break;
                case RECEIVER:
                    {
                        if (self.plan.ssa_effect_prefix && self.g.inplace) { self.e.mov(r0, 0, jit::reg_s(3), 0); }
                        else if (self.g.callee_entry) { self.e.mov(r0, 0, jit::reg_s(3), 0); }
                        else { self.e.mov(r0, 0, jit::SLJIT_MEM | self.regs, loop_value_offset(self.g.inline_base + 1)); }
                        self.store_gpr((int)i, r0);
                        break;
                    }
                case CHECKSHAPE: self.check_shape(v.a, (uint)v.imm); break;
                case CHECKPROTO:
                    {
                        self.check_shape(v.a, (uint)v.target);
                        HObject object;
                        self.e.mov(r2, 0, mem | r0, (char*)&object.prototype - (char*)&object);
                        self.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, v.imm, self.pc);
                        break;
                    }
                case PROTO_STORAGE: self.proto_storage((int)i); break;
                case CHECKWRITE:
                    self.gpr(v.a, r0);
                    self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
                    self.commit_receiver(r0);
                    break;
                case STORAGE:
                    self.gpr(v.a, r0);
                    self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
                    self.field_address(r0, r1);
                    self.store_gpr((int)i, r1);
                    break;
                case BINDING:

                    {
                        // loop_prepare snapshots bindings before entering native code.
                        if ((self.plan.ssa_watched_bindings & (1UL << (uint)v.imm)) != 0) {
                            if (v.last == v.def) break;
                            self.e.mov(r0, 0, jit::SLJIT_IMM,
                                (long)loop_bits(self.plan.ssa_binding_constants[v.imm]));
                        } else {
                            long offset = self.binding_offset((uint)v.imm);
                            self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, offset);
                        }
                        self.store_gpr((int)i, r0);
                        break;
                    }
                case COPY:

                    {
                        SsaValue from = self.g.values[v.a];
                        if (ssa_same_location(v, from)) break;
                        if (v.rep == F64) {
                            self.load_fpr(v.a, 1);
                            self.store_fpr((int)i, 1);
                        } else {
                            self.gpr(v.a, r0);
                            self.store_gpr((int)i, r0);
                        }
                        break;
                    }
                case CONST_BOX:
                case CONST_I:

                    {
                        int dst = v.home != 0 ? v.home : r0;
                        self.e.mov(dst, 0, imm, v.imm);
                        if (v.home == 0) self.store_gpr((int)i, dst);
                        break;
                    }
                case CONST_F:

                    {
                        int dst = v.home != 0 ? v.home : 1;
                        self.e.mov(r0, 0, imm, v.imm);
                        if (jit::sljit_emit_fcopy(
                            self.e.compiler,
                            jit::SLJIT_COPY_TO_F64,
                            dst,
                            r0
                        ) != 0) self.e.failed = true;
                        if (v.home == 0) self.store_fpr((int)i, dst);
                        break;
                    }
                case ADD:
                case SUB:
                case MUL:
                case DIV:

                    {
                        if (v.rep == INT32) {
                            int dst     = v.home != 0 ? v.home : r0;
                            int left    = self.gpr_slot(v.a, r0);
                            int right   = imm;
                            long rightw = v.imm;
                            if (v.b >= 0) {
                                right = self.gpr_slot(v.b, r1);
                                rightw = 0;
                            }
                            if (v.op == MUL) self.e.op(jit::SLJIT_OR, r3, left, 0, right, rightw);
                            self.e.op(
                                v.op == SUB ? jit::SLJIT_SUB : v.op == MUL ? jit::SLJIT_MUL : jit::SLJIT_ADD,
                                dst,
                                left,
                                0,
                                right,
                                rightw
                            );
                            if (v.op == MUL) {
                                void* nonzero = self.e.cmp(jit::SLJIT_NOT_EQUAL, dst, 0, imm, 0);
                                self.guard(jit::SLJIT_SIG_LESS, r3, 0, imm, 0, self.pc);
                                self.e.bind(nonzero);
                            }
                            self.guard(jit::SLJIT_SIG_LESS, dst, 0, imm, -2147483648L, self.pc);
                            self.guard(jit::SLJIT_SIG_GREATER, dst, 0, imm, 2147483647L, self.pc);
                            self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
                            if (v.home == 0) self.store_gpr((int)i, dst);
                            break;
                        }
                        int dst   = v.home != 0 ? v.home : 1;
                        int left  = self.fpr_slot(v.a, 1);
                        int right = 2;
                        if (v.b >= 0) {
                            right = self.fpr_slot(v.b, 2);
                        } else {
                            self.e.mov(r0, 0, imm, (long)bitcast((double)v.imm, ulong));
                            if (jit::sljit_emit_fcopy(
                                self.e.compiler,
                                jit::SLJIT_COPY_TO_F64,
                                2,
                                r0
                            ) != 0) self.e.failed = true;
                        }
                        int op = v.op == ADD ? jit::SLJIT_ADD_F64
                            : v.op == SUB ? jit::SLJIT_SUB_F64
                            : v.op == MUL ? jit::SLJIT_MUL_F64
                            : jit::SLJIT_DIV_F64;
                        if (jit::sljit_emit_fop2(
                            self.e.compiler,
                            op,
                            dst,
                            0,
                            left,
                            0,
                            right,
                            0
                        ) != 0) self.e.failed = true;
                        if (v.home == 0) self.store_fpr((int)i, dst);
                        break;
                    }
                case BAND:
                case BOR:
                case BXOR:
                case SHL:
                case SHR:
                case USHR:
                case BNOT:

                    {
                        int dst  = v.home != 0 ? v.home : r0;
                        int left = self.gpr_slot(v.a, r0);
                        if (v.op == BNOT) {
                            self.e.op(jit::SLJIT_XOR, dst, left, 0, imm, -1);
                        } else {
                            int right   = imm;
                            long rightw = v.imm;
                            if (v.b >= 0) {
                                right = self.gpr_slot(v.b, r1);
                                rightw = 0;
                            }
                            if (v.op == BAND) {
                                self.e.op(jit::SLJIT_AND, dst, left, 0, right, rightw);
                            } else if (v.op == BOR) {
                                self.e.op(jit::SLJIT_OR, dst, left, 0, right, rightw);
                            } else if (v.op == BXOR) {
                                self.e.op(jit::SLJIT_XOR, dst, left, 0, right, rightw);
                            } else {
                                // Masked 32-bit shifts implement JavaScript's low-five-bit
                                // count without copying or clobbering a live operand.
                                if (right == imm) rightw &= 31;
                                int shift = v.op == SHL ? jit::SLJIT_MSHL
                                    : v.op == SHR ? jit::SLJIT_MASHR : jit::SLJIT_MLSHR;
                                self.e.op(shift | jit::SLJIT_32, dst, left, 0, right, rightw);
                                if (v.op == USHR) self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_U32);
                            }
                        }
                        if (v.op == USHR) self.guard(jit::SLJIT_GREATER, dst, 0, imm, 2147483647L, self.pc);
                        self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
                        if (v.home == 0) self.store_gpr((int)i, dst);
                        break;
                    }
                case NEG:

                    {
                        int dst  = v.home != 0 ? v.home : 1;
                        int left = self.fpr_slot(v.a, 1);
                        if (jit::sljit_emit_fop1(
                            self.e.compiler,
                            jit::SLJIT_NEG_F64,
                            dst,
                            0,
                            left,
                            0
                        ) != 0) self.e.failed = true;
                        if (v.home == 0) self.store_fpr((int)i, dst);
                        break;
                    }
                case TO_INT:

                    {
                        SsaValue from = self.g.values[v.a];
                        int dst       = v.home != 0 ? v.home : r0;
                        if (from.rep == BOXED) {
                            self.gpr(v.a, r0);
                            self.int32(r0, dst, self.pc);
                        } else if (from.rep == F64) {
                            self.load_fpr(v.a, 1);
                            self.trunc_int_f64(1, dst, self.pc);
                        } else {
                            self.e.mov(dst, 0, self.gpr_slot(v.a, r0), 0);
                        }
                        if (v.home == 0) self.store_gpr((int)i, dst);
                        break;
                    }
                case TO_INDEX:

                    {
                        SsaValue from = self.g.values[v.a];
                        int dst       = v.home != 0 ? v.home : r0;
                        if (from.rep == BOXED) {
                            self.gpr(v.a, r0);
                            self.exact_int(r0, dst, self.pc);
                        } else if (from.rep == F64) {
                            self.load_fpr(v.a, 1);
                            self.exact_int_f64(1, dst, self.pc);
                        } else {
                            self.e.mov(dst, 0, self.gpr_slot(v.a, r0), 0);
                            self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
                        }
                        if (v.home == 0) self.store_gpr((int)i, dst);
                        break;
                    }
                case TO_F64:

                    {
                        SsaValue from = self.g.values[v.a];
                        int dst       = v.home != 0 ? v.home : 1;
                        if (from.rep == BOXED) {
                            self.gpr(v.a, r0);
                            self.number(r0, dst, self.pc);
                        } else if (from.rep == INT32) {
                            self.gpr(v.a, r0);
                            if (jit::sljit_emit_fop1(
                                self.e.compiler,
                                jit::SLJIT_CONV_F64_FROM_SW,
                                dst,
                                0,
                                r0,
                                0
                            ) != 0) self.e.failed = true;
                        } else {
                            int left = self.fpr_slot(v.a, 1);
                            if (left != dst && jit::sljit_emit_fop1(
                                self.e.compiler,
                                jit::SLJIT_MOV_F64,
                                dst,
                                0,
                                left,
                                0
                            ) != 0) self.e.failed = true;
                        }
                        if (v.home == 0) self.store_fpr((int)i, dst);
                        break;
                    }
                case BOX_I:

                    {
                        self.gpr(v.a, r0);
                        self.box_gpr(r0);
                        self.store_gpr((int)i, r0);
                        break;
                    }
                case BOX_F:

                    {
                        int dst  = v.home != 0 ? v.home : r0;
                        int left = self.fpr_slot(v.a, 1);
                        self.bits_fpr(left, dst);
                        if (v.home == 0) self.store_gpr((int)i, dst);
                        break;
                    }
                case COMPARE: self.compare((int)i); break;
                case SELECT:
                    {
                        int yes = v.rep == F64 ? self.fpr_slot(v.b, 1) : self.gpr_slot(v.b, r1);
                        int no = v.rep == F64 ? self.fpr_slot((int)v.imm, 2) : self.gpr_slot((int)v.imm, r2);
                        self.gpr(v.a, r0);
                        if (jit::sljit_emit_op2u(e.compiler, jit::SLJIT_SUB | jit::SLJIT_SET_Z,
                            r0, 0, imm, (long)(types::TAG_BOOLEAN << 48)) != 0) e.failed = true;
                        if (v.rep == F64) {
                            int dst = v.home != 0 ? v.home : 1;
                            if (jit::sljit_emit_fselect(e.compiler, jit::SLJIT_NOT_EQUAL, dst, yes, 0, no) != 0) e.failed = true;
                            if (v.home == 0) self.store_fpr((int)i, dst);
                        } else {
                            int dst = v.home != 0 ? v.home : r0;
                            if (jit::sljit_emit_select(e.compiler, jit::SLJIT_NOT_EQUAL, dst, yes, 0, no) != 0) e.failed = true;
                            if (v.home == 0) self.store_gpr((int)i, dst);
                        }
                        break;
                    }
                case CHECKFN:

                    {
                        int rr0      = jit::reg_r(0);
                        int rr1      = jit::reg_r(1);
                        int rr3      = jit::reg_r(3);
                        int imm2     = jit::SLJIT_IMM;
                        HObject object;
                        HObjectExtra extra;
                        long address = (char*)&object.extra - (char*)&object
                            + ((char*)&extra.func.comp_func - (char*)&extra);
                        self.gpr(v.a, rr0);
                        self.e.op(jit::SLJIT_LSHR, rr3, rr0, 0, imm2, 48);
                        self.guard(jit::SLJIT_NOT_EQUAL, rr3, 0, imm2, (long)types::TAG_OBJECT, self.pc);
                        self.e.op(jit::SLJIT_AND, rr0, rr0, 0, imm2, (long)types::NANBOX_PAYLOAD_MASK);
                        self.guard(jit::SLJIT_EQUAL, rr0, 0, imm2, 0, self.pc);
                        ObjFlags wanted;
                        wanted.callable = true;
                        wanted.obj_class = FUNCTION;
                        ObjFlags forbidden;
                        forbidden.is_bound = true;
                        forbidden.exotic_proxyobj = true;
                        self.e.mov(rr1, 0, jit::SLJIT_MEM | rr0, 0, jit::SLJIT_MOV_U32);
                        self.e.op(jit::SLJIT_AND, rr1, rr1, 0, imm2,
                            0x003F0000U | (uint)wanted | (uint)forbidden);
                        self.guard(jit::SLJIT_NOT_EQUAL, rr1, 0, imm2, (uint)wanted, self.pc);
                        self.e.mov(rr1, 0, jit::SLJIT_MEM | rr0, address);
                        self.guard(jit::SLJIT_NOT_EQUAL, rr1, 0, imm2, v.imm, self.pc);
                        CompiledFunction* target = (CompiledFunction*)v.imm;
                        self.e.mov(rr1, 0, jit::SLJIT_MEM | rr0, (char*)&object.extra.func.realm - (char*)&object);
                        self.guard(jit::SLJIT_NOT_EQUAL, rr1, 0, imm2, (long)target.realm, self.pc);
                        break;
                    }
                case LOAD:

                    {
                        uint memory = (uint)v.imm;
                        self.load(memory, v.a, (int)i, v.rep);
                        break;
                    }
                case STORE:

                    {
                        uint memory = (uint)v.imm;
                        self.store(memory, v.a, v.b);
                        break;
                    }
                case JOIN: break;
                case BRANCH: self.branch((int)i); break;
                case GOTO: self.goto_block((int)i); break;
                case RETURN: self.direct_return(v.a); break;
            }
            if (v.dst_reg >= 0) self.live[v.dst_reg] = (int)i;
        }
        // A block without a branch hands its state to the block that follows
        // it, so the join's values are written on that path too.
        if (!self.g.blocks[b].returns && self.g.blocks[b].branch_pc == uint::max && b + 1 < self.g.block_count) {
            self.join_copies(b, b + 1);
        }
    }
}

// Copy the values a join merges into the phi's home. Each predecessor
// writes the home before it arrives, so the path that reaches the join
// carries its own value.
fn void SsaEmitter.join_copies(&self, uint block, uint succ) @feat(SLJIT) {
    if (succ >= self.g.block_count) return;
    TemplateEmitter* e = &self.e;
    int r0             = jit::reg_r(0);
    for (uint j = 0; j < self.g.join_count; j++) {
        SsaJoin* join = &self.g.joins[j];
        if (join.block != succ) continue;
        for (uint p = 0; p < join.pred_count; p++) {
            if (join.preds[p] != block) continue;
            for (uint reg = 0; reg < LOOP_REGS; reg++) {
                int phi = join.phi[reg];
                if (phi < 0) continue;
                int incoming = join.incoming[p][reg];
                if (incoming < 0) continue;
                SsaValue pv = self.g.values[phi];
                SsaValue sv = self.g.values[incoming];
                // The merged values may differ in representation, so the copy
                // converts the incoming value to the phi's.
                if (pv.rep == F64) {
                    if (sv.rep == F64) {
                        if (sv.home != 0 && pv.home != 0) {
                            if (jit::sljit_emit_fop1(
                                e.compiler,
                                jit::SLJIT_MOV_F64,
                                pv.home,
                                0,
                                sv.home,
                                0
                            ) != 0) e.failed = true;
                        } else {
                            self.load_fpr(incoming, 1);
                            self.store_fpr(phi, 1);
                        }
                    } else {
                        int dst = pv.home != 0 ? pv.home : 1;
                        if (sv.rep == INT32) {
                            int src = self.gpr_slot(incoming, r0);
                            if (jit::sljit_emit_fop1(
                                e.compiler,
                                jit::SLJIT_CONV_F64_FROM_SW,
                                dst,
                                0,
                                src,
                                0
                            ) != 0) e.failed = true;
                        } else {
                            self.gpr(incoming, r0);
                            self.number(r0, dst, self.pc);
                        }
                        if (pv.home == 0) self.store_fpr(phi, dst);
                    }
                } else if (pv.rep == BOXED) {
                    if (sv.rep == BOXED) {
                        if (sv.home != 0 && pv.home != 0) {
                            e.mov(pv.home, 0, sv.home, 0);
                        } else {
                            self.gpr(incoming, r0);
                            self.store_gpr(phi, r0);
                        }
                    } else if (sv.rep == INT32) {
                        int dst = pv.home != 0 ? pv.home : r0;
                        self.gpr(incoming, r0);
                        self.box_gpr(r0);
                        if (dst != r0) e.mov(dst, 0, r0, 0);
                        if (pv.home == 0) self.store_gpr(phi, dst);
                    } else {
                        int src = self.fpr_slot(incoming, 1);
                        int dst = pv.home != 0 ? pv.home : r0;
                        self.bits_fpr(src, dst);
                        if (pv.home == 0) self.store_gpr(phi, dst);
                    }
                } else {
                    if (sv.rep == INT32) {
                        if (sv.home != 0 && pv.home != 0) {
                            e.mov(pv.home, 0, sv.home, 0);
                        } else {
                            self.gpr(incoming, r0);
                            self.store_gpr(phi, r0);
                        }
                    } else {
                        int dst = pv.home != 0 ? pv.home : r0;
                        if (sv.rep == F64) {
                            self.load_fpr(incoming, 1);
                            self.trunc_int_f64(1, dst, self.pc);
                        } else {
                            self.gpr(incoming, r0);
                            self.exact_int(r0, dst, self.pc);
                        }
                        if (pv.home == 0) self.store_gpr(phi, dst);
                    }
                }
            }
        }
    }
}

// A comparison used as a value remains a JavaScript boolean at publication.
fn void SsaEmitter.compare(&self, int value) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    void* taken;
    if (self.g.values[v.a].rep == INT32) {
        int left = self.gpr_slot(v.a, r0);
        int right = v.b >= 0 ? self.gpr_slot(v.b, r1) : jit::SLJIT_IMM;
        int condition = loop_condition(v.branch_op);
        int flags = condition <= jit::SLJIT_NOT_EQUAL ? jit::SLJIT_SET_Z : jit::set_flags(condition & ~1);
        if (jit::sljit_emit_op2u(self.e.compiler, jit::SLJIT_SUB | flags,
                left, 0, right, v.b >= 0 ? 0 : v.imm) != 0) self.e.failed = true;
        if (jit::sljit_emit_op_flags(self.e.compiler, jit::SLJIT_MOV, r0, 0, condition) != 0) self.e.failed = true;
        self.e.op(jit::SLJIT_OR, r0, r0, 0, jit::SLJIT_IMM, (long)(types::TAG_BOOLEAN << 48));
        self.store_gpr(value, r0);
        return;
    } else {
        self.load_fpr(v.a, 1);
        self.load_fpr(v.b, 2);
        taken = jit::sljit_emit_fcmp(self.e.compiler, loop_float_condition(v.branch_op), 1, 0, 2, 0);
        if (taken == null) self.e.failed = true;
    }
    self.e.mov(r0, 0, jit::SLJIT_IMM, (long)(types::TAG_BOOLEAN << 48));
    void* done = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    self.e.bind(taken);
    self.e.mov(r0, 0, jit::SLJIT_IMM, (long)((types::TAG_BOOLEAN << 48) | 1));
    self.e.bind(done);
    self.store_gpr(value, r0);
}

// An arm's branch: the condition decides which block the loop continues in.
fn void SsaEmitter.branch(&self, int value) @feat(SLJIT) {
    SsaValue v         = self.g.values[value];
    TemplateEmitter* e = &self.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    void* taken;
    if (v.branch_op == Opcode.JMP_NULL || v.branch_op == Opcode.JMP_NNULL) {
        taken = self.effect_null_branch(v);
    } else if ((int)v.branch_op == 0) {
        // The truthiness of the condition's value.
        if (self.g.values[v.a].rep == INT32) {
            int src = self.gpr_slot(v.a, r0);
            e.op(jit::SLJIT_SUB, r1, src, 0, imm, 0);
            taken = e.cmp(v.imm != 0 ? jit::SLJIT_NOT_EQUAL : jit::SLJIT_EQUAL, r1, 0, imm, 0);
        } else {
            // A boxed boolean carries its value in the payload.
            self.gpr(v.a, r0);
            e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
            self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_BOOLEAN, self.pc);
            e.op(jit::SLJIT_AND, r1, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
            taken = e.cmp(v.imm != 0 ? jit::SLJIT_NOT_EQUAL : jit::SLJIT_EQUAL, r1, 0, imm, 0);
        }
    } else {
        SsaValue lhs = self.g.values[v.a];
        if (lhs.rep == INT32) {
            int left = self.gpr_slot(v.a, r0);
            int right;
            if (v.b >= 0) {
                right = self.gpr_slot(v.b, r1);
            } else {
                e.mov(r1, 0, imm, v.imm);
                right = r1;
            }
            taken = e.cmp(loop_condition(v.branch_op), left, 0, right, 0);
        } else {
            self.load_fpr(v.a, 1);
            if (v.b >= 0) {
                self.load_fpr(v.b, 2);
            } else {
                e.mov(r0, 0, imm, (long)bitcast((double)v.imm, ulong));
                if (jit::sljit_emit_fcopy(e.compiler, jit::SLJIT_COPY_TO_F64, 2, r0) != 0) e.failed = true;
            }
            taken = jit::sljit_emit_fcmp(e.compiler, loop_float_condition(v.branch_op), 1, 0, 2, 0);
        }
    }
    if (taken == null) {
        e.failed = true;
        return;
    }
    // The arm that falls through, then the arm the branch takes.
    self.join_copies((uint)v.block, (uint)v.fallto);
    void* fall = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(taken);
    if ((uint)v.target == SSA_BLOCKS && self.plan.ssa_effect_prefix) {
        uint destination = (uint)loop_target(self.cf.code[v.pc], v.pc);
        self.publish(&self.g.frames[v.pc - self.plan.begin], destination);
        if (self.pending_count == (uint)self.pending_jump.len) { e.failed = true; return; }
        self.pending_jump[self.pending_count] = fall;
        self.pending_target[self.pending_count++] = (uint)v.fallto;
        return;
    }
    self.join_copies((uint)v.block, (uint)v.target);
    void* target = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    if (self.pending_count + 2 > (uint)self.pending_jump.len) {
        e.failed = true;
        return;
    }
    self.pending_jump[self.pending_count] = fall;
    self.pending_target[self.pending_count] = (uint)v.fallto;
    self.pending_count++;
    self.pending_jump[self.pending_count] = target;
    self.pending_target[self.pending_count] = (uint)v.target;
    self.pending_count++;
}

// The end of an arm: the block continues at the block the jump names.
fn void SsaEmitter.goto_block(&self, int value) @feat(SLJIT) {
    SsaValue v = self.g.values[value];
    if ((uint)v.target == SSA_BLOCKS && self.plan.ssa_effect_prefix) {
        uint destination = (uint)loop_target(self.cf.code[v.pc], v.pc);
        self.publish(&self.g.frames[v.pc - self.plan.begin], destination);
        return;
    }
    self.join_copies((uint)v.block, (uint)v.target);
    void* jump = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    if (jump == null || self.pending_count + 1 > (uint)self.pending_jump.len) {
        self.e.failed = true;
        return;
    }
    self.pending_jump[self.pending_count] = jump;
    self.pending_target[self.pending_count] = (uint)v.target;
    self.pending_count++;
}

// Bind the jumps that reach a block to the label it starts at.
fn void SsaEmitter.resolve_blocks(&self) @feat(SLJIT) {
    for (uint i = 0; i < self.pending_count; i++) {
        uint target = self.pending_target[i];
        if (target >= self.g.block_count) {
            self.e.failed = true;
            continue;
        }
        void* label = self.block_label[target];
        if (label == null) {
            self.e.failed = true;
            continue;
        }
        jit::sljit_set_label(self.pending_jump[i], label);
    }
}

fn void SsaEmitter.exact_int_f64(&self, int freg, int dst, uint pc) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    self.float_guard(jit::SLJIT_UNORDERED, freg, 0, freg, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(-2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.float_guard(jit::SLJIT_ORDERED_LESS, freg, 0, 2, 0, pc);
    self.e.mov(r1, 0, jit::SLJIT_IMM, (long)bitcast(2147483648.0, ulong));
    if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r1) != 0) self.e.failed = true;
    self.float_guard(jit::SLJIT_ORDERED_GREATER_EQUAL, freg, 0, 2, 0, pc);
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_SW_FROM_F64, dst, 0, freg, 0) != 0) self.e.failed = true;
    if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_CONV_F64_FROM_SW, 2, 0, dst, 0) != 0) self.e.failed = true;
    void* equal = jit::sljit_emit_fcmp(self.e.compiler, jit::SLJIT_ORDERED_EQUAL, freg, 0, 2, 0);
    self.snapshot(jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP), pc);
    self.e.bind(equal);
    self.e.mov(dst, 0, dst, 0, jit::SLJIT_MOV_S32);
}

fn void SsaEmitter.memory_guard(&self, uint source, uint memory, uint pc) @feat(SLJIT) {
    if (memory < LOOP_MEMORY && self.g.invariant[memory]) return;
    int r0 = jit::reg_r(0);
    self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, loop_value_offset(source));
    self.guard(jit::SLJIT_NOT_EQUAL, r0, 0, jit::SLJIT_MEM | self.state, self.memory_offset(memory, 0), pc);
}
fn void SsaEmitter.index(&self, int value, uint memory, uint pc) @feat(SLJIT) {
    int r1  = jit::reg_r(1);
    int r2  = jit::reg_r(2);
    // Separate bytecode loads of one index become different copies of it; the
    // allocator coalesces them, so compare the copy chains' common root.
    int key = ssa_alias(self.g, value);
    if (self.addr_reg != 0 && self.addr_memory == (int)memory && self.addr_value == key) {
        // r2 still holds this address: nothing emitted between two accesses
        // through one index value writes it.
        return;
    }
    self.addr_memory = (int)memory;
    self.addr_value = key;
    self.addr_reg = r2;
    self.addr_numeric_load = false;
    self.gpr(value, r1);
    // The first memory keeps its length in a saved register for the whole
    // loop, so bounds checks are a register comparison.
    if (memory < 2 && self.memory_length[memory] != 0) {
        self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, self.memory_length[memory], 0, pc);
    } else {
        self.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, jit::SLJIT_MEM | self.state, self.memory_offset(memory, 2), pc);
    }
    uint shift = self.plan.memory[memory].kind == DENSE ? 3 : builtins::ta_elem_shift(self.plan.memory[memory].cls);
    if (shift != 0) self.e.op(jit::SLJIT_SHL, r1, r1, 0, jit::SLJIT_IMM, shift);
    if (memory < 2 && self.memory_base[memory] != 0) {
        self.e.op(jit::SLJIT_ADD, r2, self.memory_base[memory], 0, r1, 0);
    } else {
        self.e.mov(r2, 0, jit::SLJIT_MEM | self.state, self.memory_offset(memory, 1));
        self.e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
    }
}
fn void SsaEmitter.load(&self, uint memory, int index, int dst_value, SsaRep rep) @feat(SLJIT) {
    LoopMemorySpec spec = self.plan.memory[memory];
    uint pc             = self.pc;
    if (spec.kind == SHAPE_FIELD && !self.g.direct_fields) {
        int r0  = jit::reg_r(0);
        int r1  = jit::reg_r(1);
        int r2  = jit::reg_r(2);
        int r3  = jit::reg_r(3);
        int imm = jit::SLJIT_IMM;
        self.gpr(index, r0);
        self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
        self.e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        self.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
        self.ordinary_receiver(r0, pc);
        HObject obj;
        long shape_offset = (char*)&obj.shape_id - (char*)&obj;
        long alloc_offset = (char*)&obj.prop_alloc - (char*)&obj;
        self.e.mov(r2, 0, jit::SLJIT_MEM | r0, shape_offset, jit::SLJIT_MOV_U32);
        self.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)spec.shape, pc);
        self.e.mov(r1, 0, jit::SLJIT_MEM | r0, alloc_offset);
        void* allocated = self.e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0);
        self.e.op(jit::SLJIT_ADD, r1, r0, 0, imm, HObjectBase::size);
        self.e.bind(allocated);
        self.e.mov(r0, 0, jit::SLJIT_MEM | r1, (long)spec.slot * 8);
        if (spec.integers) {
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
            self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pc);
            int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : r0;
            self.unbox_fastint(r0, dst, pc);
            if (self.g.values[dst_value].home == 0) self.store_gpr(dst_value, dst);
        } else if (spec.doubles) {
            int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : 1;
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
            self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pc);
            if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, dst, r0) != 0) self.e.failed = true;
            if (self.g.values[dst_value].home == 0) self.store_fpr(dst_value, dst);
            self.addr_numeric_load = true;
        } else {
            int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : r0;
            if (dst != r0) self.e.mov(dst, 0, r0, 0);
            if (self.g.values[dst_value].home == 0) self.store_gpr(dst_value, dst);
        }
        return;
    }
    if (spec.kind == FIELD || ((spec.kind == SHAPE_FIELD || spec.kind == PROTO_FIELD) && self.g.direct_fields)) {
        int r1 = jit::reg_r(1);
        int r0 = jit::reg_r(0);
        int r3 = jit::reg_r(3);
        long offset;
        if (self.g.direct_fields) {
            self.gpr(index, r1);
            offset = (long)spec.slot * 8;
        } else {
            self.e.mov(r1, 0, jit::SLJIT_MEM | self.state, self.memory_offset(memory, 1));
        }
        if (spec.integers) {
            self.e.mov(r0, 0, jit::SLJIT_MEM | r1, offset);
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_NOT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
            int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : r0;
            self.unbox_fastint(r0, dst, pc);
            if (self.g.values[dst_value].home == 0) self.store_gpr(dst_value, dst);
        } else if (spec.doubles) {
            int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : 1;
            self.e.mov(r0, 0, jit::SLJIT_MEM | r1, offset);
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
            if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, dst, r0) != 0) self.e.failed = true;
            if (self.g.values[dst_value].home == 0) self.store_fpr(dst_value, dst);
        } else {
            int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : r0;
            self.e.mov(dst, 0, jit::SLJIT_MEM | r1, offset);
            if (self.g.values[dst_value].home == 0) { self.store_gpr(dst_value, dst); }
            else if (self.plan.ssa_effect_prefix && self.g.inplace) {
                // A homed boxed field bypasses store_gpr; still refuse counted
                // values before they can be published without ownership work.
                self.e.op(jit::SLJIT_LSHR, r3, dst, 0, jit::SLJIT_IMM, 48);
                self.snapshot(self.e.cmp(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM,
                    (long)types::TAG_STRING), self.pc);
            }
        }
        return;
    }
    self.memory_guard(spec.source, memory, pc);
    self.index(index, memory, pc);
    int r0 = jit::reg_r(0);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    if (spec.doubles) {
        // Fastest element read: an ordinary double is already its own bits, so
        // one guard replaces the tag test, the representation branch and the
        // conversion. Anything else exits and the interpreter reruns the loop.
        int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : 1;
        self.e.mov(r0, 0, jit::SLJIT_MEM | r2, 0);
        self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
        self.guard(jit::SLJIT_GREATER_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
        if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, dst, r0) != 0) self.e.failed = true;
        if (self.g.values[dst_value].home == 0) self.store_fpr(dst_value, dst);
        self.addr_numeric_load = true;
    } else if (spec.kind == DENSE) {
        int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : r0;
        self.e.mov(dst, 0, jit::SLJIT_MEM | r2, 0);
        if (self.g.numeric_load[dst_value]) {
            // Every consumer rejects a non-number, which also covers a hole,
            // and the stored value can then never hold a heap reference.
            self.e.op(jit::SLJIT_LSHR, r3, dst, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
            self.addr_numeric_load = true;
        } else if (rep == BOXED) {
            self.e.op(jit::SLJIT_LSHR, r3, dst, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_UNDEFINED, pc);
        }
        if (self.g.values[dst_value].home == 0) self.store_gpr(dst_value, dst);
    } else if (spec.cls >= FLOAT32ARRAY) {
        bool small = spec.cls == FLOAT32ARRAY;
        int dst    = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : 1;
        if (jit::sljit_emit_fop1(
            self.e.compiler,
            jit::SLJIT_MOV_F64 | (small ? jit::SLJIT_32 : 0),
            dst,
            0,
            jit::SLJIT_MEM | r2,
            0
        ) != 0) self.e.failed = true;
        if (small && jit::sljit_emit_fop1(
            self.e.compiler,
            jit::SLJIT_CONV_F64_FROM_F32,
            dst,
            0,
            dst,
            0
        ) != 0) self.e.failed = true;
        if (self.g.values[dst_value].home == 0) self.store_fpr(dst_value, dst);
    } else {
        int dst = self.g.values[dst_value].home != 0 ? self.g.values[dst_value].home : r0;
        self.e.mov(dst, 0, jit::SLJIT_MEM | r2, 0, loop_load_op(spec.cls));
        if (self.g.values[dst_value].home == 0) self.store_gpr(dst_value, dst);
    }
}
fn void SsaEmitter.store(&self, uint memory, int index, int value) @feat(SLJIT) {
    if (self.plan.ssa_effect_prefix) { self.effect_store(memory, index, value); return; }
    if (self.plan.ssa_commit && (self.plan.memory[memory].kind == FIELD || self.plan.memory[memory].kind == SHAPE_FIELD)) {
        int r0 = jit::reg_r(0);
        int r2 = jit::reg_r(2);
        int r3 = jit::reg_r(3);
        self.gpr(value, r0);
        self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
        self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, self.pc);
        long offset;
        if (self.g.direct_fields) {
            self.gpr(index, r2);
            offset = (long)self.plan.memory[memory].slot * 8;
        } else {
            self.e.mov(r2, 0, jit::SLJIT_MEM | self.state, self.memory_offset(memory, 1));
        }
        self.e.mov(r3, 0, jit::SLJIT_MEM | r2, offset);
        self.e.op(jit::SLJIT_LSHR, r3, r3, 0, jit::SLJIT_IMM, 48);
        self.guard(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_STRING, self.pc);
        self.e.mov(jit::SLJIT_MEM | r2, offset, r0, 0);
        return;
    }
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        int live = ssa_alias(self.g, self.live[reg]);
        if (live >= 0 && self.g.values[live].rep == BOXED && self.g.values[live].op == LOAD
            && self.g.values[live].last >= self.at_def) {
            // Dense numeric loads guard their tag at the read itself, so no
            // borrowed heap reference survives the write. Other boxed loads
            // still need the fallback, including aliases introduced by CSE.
            uint source = (uint)self.g.values[live].imm;
            if (self.plan.memory[source].kind != DENSE || !self.g.numeric_load[live]) self.e.failed = true;
        }
    }
    LoopMemorySpec spec = self.plan.memory[memory];
    uint pc             = self.pc;
    self.memory_guard(spec.source, memory, pc);
    self.index(index, memory, pc);
    int r0       = jit::reg_r(0);
    int r2       = jit::reg_r(2);
    int r3       = jit::reg_r(3);
    SsaValue src = self.g.values[value];
    if (spec.doubles) {
        // The element being replaced must also be numeric: checking
        // that is both the reference-release test and the invariant guard. An
        // earlier numeric read of this exact slot already proved it.
        if (!self.addr_numeric_load) {
            self.e.mov(r0, 0, jit::SLJIT_MEM | r2, 0);
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
        }
        self.load_fpr(value, 1);
        self.bits_fpr(1, r0);
        self.e.mov(jit::SLJIT_MEM | r2, 0, r0, 0);
        return;
    }
    if (spec.kind == DENSE) {
        // A numeric read of this exact slot earlier in the iteration already
        // proved the stored value holds no reference to release.
        if (!(self.addr_reg != 0 && self.addr_numeric_load && self.addr_memory == (int)memory)) {
            self.e.mov(r0, 0, jit::SLJIT_MEM | r2, 0);
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
        }
        self.gpr(value, r0);
        // BOX_I and BOX_F produce a fastint or an ordinary double, so the
        // stored value needs no tag check.
        if (src.op != BOX_I && src.op != BOX_F) {
            self.e.op(jit::SLJIT_LSHR, r3, r0, 0, jit::SLJIT_IMM, 48);
            self.guard(jit::SLJIT_GREATER, r3, 0, jit::SLJIT_IMM, (long)types::TAG_FASTINT, pc);
        }
        self.e.mov(jit::SLJIT_MEM | r2, 0, r0, 0);
    } else if (spec.cls >= FLOAT32ARRAY) {
        self.load_fpr(value, 1);
        bool small = spec.cls == FLOAT32ARRAY;
        if (small && jit::sljit_emit_fop1(
            self.e.compiler,
            jit::SLJIT_CONV_F64_FROM_F32 | jit::SLJIT_32,
            1,
            0,
            1,
            0
        ) != 0) self.e.failed = true;
        if (jit::sljit_emit_fop1(
            self.e.compiler,
            jit::SLJIT_MOV_F64 | (small ? jit::SLJIT_32 : 0),
            jit::SLJIT_MEM | r2,
            0,
            1,
            0
        ) != 0) self.e.failed = true;
    } else {
        self.gpr(value, r0);
        self.e.mov(jit::SLJIT_MEM | r2, 0, r0, 0, loop_load_op(spec.cls));
    }
}

// All native function exits use one result convention. A side exit leaves the
// original caller frame untouched; a return transfers only the selected value.
fn void SsaEmitter.direct_return(&self, int value, bool refused = false) @feat(SLJIT) {
    int r0 = jit::reg_r(0);
    if (refused || value < 0) {
        self.e.mov(r0, 0, jit::SLJIT_IMM, refused ? (long)SSA_REFUSED : (long)(types::TAG_UNDEFINED << 48));
    } else {
        self.output(value, self.pc);
        self.e.op(jit::SLJIT_LSHR, jit::reg_r(1), r0, 0, jit::SLJIT_IMM, 48);
        self.snapshot_none(self.e.cmp(jit::SLJIT_EQUAL, jit::reg_r(1), 0,
            jit::SLJIT_IMM, (long)types::TAG_STRING), self.plan.begin);
    }
    if (self.g.inplace) {
        if (self.done_count == self.done_jumps.len) { self.e.failed = true; return; }
        self.done_jumps[self.done_count++] = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
    } else if (jit::sljit_emit_return(self.e.compiler, jit::SLJIT_MOV, r0, 0) != 0) self.e.failed = true;
}

fn void SsaEmitter.publish(&self, int[LOOP_REGS]* regs, uint pc) @feat(SLJIT) {
    int r0      = jit::reg_r(0);
    if (self.plan.ssa_effect_prefix && self.g.inplace) {
        for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
            int value = (*regs)[reg];
            if (value < 0 || (self.g.arg[reg] >= 0 && ssa_alias(self.g, value) == self.g.arg[reg])) continue;
            self.output(value, pc);
            self.e.mov(jit::SLJIT_MEM | self.regs, loop_value_offset(reg), r0, 0);
        }
        if (pc == self.plan.end + 1) {
            if (self.done_count == self.done_jumps.len) { self.e.failed = true; return; }
            self.done_jumps[self.done_count++] = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
        } else {
            $if $feat(SLJIT_STATS):
                if (pc == self.plan.begin) { ssa_counter(&self.e, &self.plan.ssa_entry_misses); }
                else { ssa_counter(&self.e, &self.plan.ssa_body_misses); }
            $endif
            // Re-enter only labels whose baseline flow state is known empty.
            // Label zero is the baseline body after the separate prefix entry.
            if (pc == self.plan.begin && pc != 0 && self.g.effect_out != null) {
                if (self.g.effect_retry_count == self.g.effect_retries.len) { self.e.failed = true; return; }
                self.g.effect_retries[self.g.effect_retry_count++] = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
            } else if (self.g.effect_out != null && pc < self.cf.code_count
                && self.g.effect_blocks != null && self.g.effect_blocks[pc]) {
                self.g.effect_out.link(jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP), pc, false);
                if (self.g.effect_out.e.failed) self.e.failed = true;
            } else {
                self.e.mov(r0, 0, jit::SLJIT_IMM, (long)(self.cf.code + pc));
                if (jit::sljit_emit_return(self.e.compiler, jit::SLJIT_MOV, r0, 0) != 0) self.e.failed = true;
            }
        }
        return;
    }
    if (self.g.direct) {
        self.direct_return(self.g.result_reg < LOOP_REGS ? self.g.current[self.g.result_reg] : -1, pc != self.plan.end + 1);
        return;
    }

    LoopState layout;
    ulong dirty = self.dirty_mask;
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        int value = (*regs)[reg];
        if (value < 0) continue;
        self.output(value, pc);
        self.e.mov(jit::SLJIT_MEM | self.state, loop_value_offset(reg), r0, 0);
        dirty |= 1UL << reg;
    }
    self.e.mov(jit::SLJIT_MEM | self.state, (char*)&layout.dirty - (char*)&layout, jit::SLJIT_IMM, (long)dirty);
    self.e.mov(jit::SLJIT_MEM | self.state, (char*)&layout.budget - (char*)&layout, self.budget, 0);
    self.e.mov(r0, 0, jit::SLJIT_IMM, (long)pc);
    if (jit::sljit_emit_return(self.e.compiler, jit::SLJIT_MOV, r0, 0) != 0) self.e.failed = true;
}
fn void SsaEmitter.exit_stubs(&self) @feat(SLJIT) {
    void*[SSA_EXITS] labels;
    for (uint i = 0; i < self.g.exit_count; i++) {
        SsaExit* item = &self.g.exits[i];
        // Several guards in one bytecode recover the same frame from fixed
        // SSA homes. Share their materialization and return sequence; matching
        // only the PC would be insufficient for header versus body exits.
        for (uint prior = 0; prior < i; prior++) {
            SsaExit* candidate = &self.g.exits[prior];
            if (candidate.pc != item.pc) continue;
            bool same = true;
            for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
                if (candidate.regs[reg] != item.regs[reg]) {
                    same = false;
                    break;
                }
            }
            if (same) {
                labels[i] = labels[prior];
                break;
            }
        }
        if (labels[i] != null) {
            jit::sljit_set_label(item.jump, labels[i]);
            continue;
        }
        labels[i] = self.e.label();
        jit::sljit_set_label(item.jump, labels[i]);
        self.publish(&item.regs, item.pc);
    }
}
fn void SsaEmitter.latch(&self) @feat(SLJIT) {
    int r0         = jit::reg_r(0);
    int r1         = jit::reg_r(1);
    // A postfix comparison may still read a header value whose home the phi
    // copies replace (while (count-- > 0)). Save the predicate before copies.
    bool truth = self.g.cmp_op == Opcode.IF_TRUE || self.g.cmp_op == Opcode.IF_FALSE;
    bool[2] saved_predicate;
    uint predicate = self.g.spill_count;
    foreach (phi : self.g.phi) if (phi >= 0) predicate++;
    for (uint operand = 0; operand < 2; operand++) {
        int value = operand == 0 ? self.g.cmp_lhs : self.g.cmp_rhs;
        if (value < 0) continue;
        if (truth && operand == 0) saved_predicate[operand] = true;
        foreach (phi : self.g.phi) {
            if (phi < 0) continue;
            SsaValue dest = self.g.values[phi];
            if (ssa_same_location(
                dest,
                self.g.values[value]
            ) && !ssa_same_location(dest, self.g.values[dest.a])) saved_predicate[operand] = true;
        }
        if (!saved_predicate[operand]) continue;
        if (self.g.values[value].rep == F64) {
            self.load_fpr(value, 1);
            self.bits_fpr(1, r0);
        } else {
            self.gpr(value, r0);
        }
        self.e.mov(jit::SLJIT_MEM | self.state, self.spill_offset(predicate + operand), r0, 0);
    }
    // Parallel copies include spill slots as well as register homes. A spill
    // is not a temporary: another pending phi may still need its old value.
    bool[LOOP_REGS] pending;
    uint remaining;
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        int phi = self.g.phi[reg];
        if (phi < 0) continue;
        if (ssa_same_location(self.g.values[phi], self.g.values[self.g.values[phi].a])) continue;
        pending[reg] = true;
        remaining++;
    }
    while (remaining > 0) {
        bool progress;
        for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
            if (!pending[reg]) continue;
            int phi       = self.g.phi[reg];
            SsaValue dest = self.g.values[phi];
            bool blocked;
            for (uint other = 0; other < self.cf.num_regs && other < LOOP_REGS; other++) {
                if (!pending[other] || other == reg) continue;
                int source = self.g.values[self.g.phi[other]].a;
                if (ssa_same_location(dest, self.g.values[source])) {
                    blocked = true;
                    break;
                }
            }
            if (blocked) continue;
            int source   = dest.a;
            SsaValue src = self.g.values[source];
            if (dest.home != 0 && src.home != 0) {
                if (dest.rep == F64) {
                    if (jit::sljit_emit_fop1(
                        self.e.compiler,
                        jit::SLJIT_MOV_F64,
                        dest.home,
                        0,
                        src.home,
                        0
                    ) != 0) self.e.failed = true;
                } else {
                    self.e.mov(dest.home, 0, src.home, 0);
                }
            } else if (dest.rep == F64) {
                self.load_fpr(source, 1);
                self.store_fpr(phi, 1);
            } else {
                self.gpr(source, r0);
                self.store_gpr(phi, r0);
            }
            pending[reg] = false;
            remaining--;
            progress = true;
        }
        if (!progress) break;
    }
    // Break all remaining cycles before mutating any destination.
    uint temp = self.g.spill_count;
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        if (!pending[reg]) continue;
        int source = self.g.values[self.g.phi[reg]].a;
        if (self.g.values[source].rep == F64) {
            self.load_fpr(source, 1);
            self.bits_fpr(1, r0);
        } else {
            self.gpr(source, r0);
        }
        self.e.mov(jit::SLJIT_MEM | self.state, self.spill_offset(temp++), r0, 0);
    }
    temp = self.g.spill_count;
    for (uint reg = 0; reg < self.cf.num_regs && reg < LOOP_REGS; reg++) {
        if (!pending[reg]) continue;
        int phi = self.g.phi[reg];
        self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, self.spill_offset(temp++));
        if (self.g.values[phi].rep == F64) {
            if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 1, r0) != 0) self.e.failed = true;
            self.store_fpr(phi, 1);
        } else {
            self.store_gpr(phi, r0);
        }
    }
    if (truth) {
        // The condition temporary is also observable when the interpreter
        // replays this backedge. Preserve it even when no loop phi needs it.
        uint reg = self.cf.code[self.plan.end].a;
        self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, self.spill_offset(predicate));
        if (self.g.values[self.g.cmp_lhs].rep == INT32) self.box_gpr(r0);
        self.e.mov(jit::SLJIT_MEM | self.state, loop_value_offset(reg), r0, 0);
        self.dirty_mask |= 1UL << reg;
    }
    // A failed budget polls the interpreter at the backedge; post-body values
    // are published, not the edge copies.
    self.at_def = self.g.stamp;
    self.snapshot_phis(self.e.cmp(jit::SLJIT_LESS_EQUAL, self.budget, 0, jit::SLJIT_IMM, 1), self.plan.end);
    self.e.op(jit::SLJIT_SUB, self.budget, self.budget, 0, jit::SLJIT_IMM, 1);
    int r2       = jit::reg_r(2);
    SsaValue lhs = self.g.values[self.g.cmp_lhs];
    if (truth) {
        self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, self.spill_offset(predicate));
        if (lhs.rep != INT32) {
            self.e.op(jit::SLJIT_LSHR, r1, r0, 0, jit::SLJIT_IMM, 48);
            self.snapshot_phis(self.e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, jit::SLJIT_IMM,
                (long)types::TAG_BOOLEAN), self.plan.end);
            self.e.op(jit::SLJIT_AND, r0, r0, 0, jit::SLJIT_IMM, (long)types::NANBOX_PAYLOAD_MASK);
        }
        void* taken = self.e.cmp(self.g.cmp_op == Opcode.IF_TRUE ? jit::SLJIT_NOT_EQUAL : jit::SLJIT_EQUAL,
            r0, 0, jit::SLJIT_IMM, 0);
        if (taken != null) { jit::sljit_set_label(taken, self.header); }
        else { self.e.failed = true; }
        return;
    }
    if (lhs.rep == INT32) {
        int left = r0;
        if (saved_predicate[0]) {
            self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, self.spill_offset(predicate));
        } else {
            left = self.gpr_slot(self.g.cmp_lhs, r0);
        }
        int right;
        if (self.g.cmp_rhs >= 0) {
            if (saved_predicate[1]) {
                self.e.mov(r1, 0, jit::SLJIT_MEM | self.state, self.spill_offset(predicate + 1));
                right = r1;
            } else {
                right = self.gpr_slot(self.g.cmp_rhs, r1);
            }
        } else {
            self.e.mov(r1, 0, jit::SLJIT_IMM, self.g.cmp_imm);
            right = r1;
        }
        void* taken = self.e.cmp(loop_condition(self.g.cmp_op), left, 0, right, 0);
        if (taken == null) {
            self.e.failed = true;
        } else {
            jit::sljit_set_label(taken, self.header);
        }
    } else {
        if (saved_predicate[0]) {
            self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, self.spill_offset(predicate));
            if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 1, r0) != 0) self.e.failed = true;
        } else {
            self.load_fpr(self.g.cmp_lhs, 1);
        }
        if (self.g.cmp_rhs >= 0) {
            if (saved_predicate[1]) {
                self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, self.spill_offset(predicate + 1));
                if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r0) != 0) self.e.failed = true;
            } else {
                self.load_fpr(self.g.cmp_rhs, 2);
            }
        } else {
            self.e.mov(r0, 0, jit::SLJIT_IMM, (long)bitcast((double)self.g.cmp_imm, ulong));
            if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 2, r0) != 0) self.e.failed = true;
        }
        void* taken = jit::sljit_emit_fcmp(self.e.compiler, loop_float_condition(self.g.cmp_op), 1, 0, 2, 0);
        if (taken == null) {
            self.e.failed = true;
        } else {
            jit::sljit_set_label(taken, self.header);
        }
    }
    r2 = r2;
}
