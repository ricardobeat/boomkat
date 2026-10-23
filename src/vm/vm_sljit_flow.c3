module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::jit;

const bool FUNCTION_DATAFLOW = true;
const bool FUNCTION_OBJECT_FLOW = true;
const uint FLOW_THIS = 0xFFFFFFFF;

struct FunctionFlowLoad @feat(SLJIT) { uint base; uint value; void* key; }

// Block-local typed values. FP1/2 are temporaries; FP3..6 retain proven
// numbers. Dirty values own no strings and are published at spills/exits.
struct FunctionFlow @feat(SLJIT) {
    char[256] registers;
    char[4] owners;
    uint used;
    uint dirty;
    uint pinned;
    uint[256] shapes;
    uint[256] versions;
    uint next_version;
    uint this_shape;
    FunctionFlowLoad[8] loads;
    uint next_load;
}
fn void FunctionFlow.forget(&self, uint reg) @feat(SLJIT) {
    self.shapes[reg] = 0;
    self.versions[reg] = ++self.next_version;
    foreach (&load : self.loads) if (load.value == reg) load.key = null;
}
fn void FunctionFlow.heap_write(&self) @feat(SLJIT) {
    foreach (&load : self.loads) load.key = null;
}
fn uint FunctionFlow.token(&self, uint reg, bool receiver) @feat(SLJIT) => receiver ? FLOW_THIS : self.versions[reg];
fn void FunctionFlow.same_value(&self, uint reg, uint token, uint shape) @feat(SLJIT) {
    self.versions[reg] = token; self.shapes[reg] = shape;
}
fn void FunctionFlow.guard_shape(&self, uint token, uint shape) @feat(SLJIT) {
    if (token == FLOW_THIS) self.this_shape = shape + 1;
    for (uint i = 0; i < 256; i++) if (self.versions[i] == token) self.shapes[i] = shape + 1;
}
fn int FunctionFlow.loaded(&self, uint token, void* key) @feat(SLJIT) {
    foreach (load : self.loads) if (load.key != null && load.key == key && load.base == token) return (int)load.value;
    return -1;
}
fn void FunctionFlow.remember(&self, uint token, void* key, uint value) @feat(SLJIT) {
    if (key == null) return;
    self.loads[self.next_load++ & 7] = {token, value, key};
}
fn void FunctionFlow.drop(&self, uint reg) @feat(SLJIT) {
    self.forget(reg);
    uint slot = self.registers[reg];
    if (slot == 0) return;
    // Canonical lanes may only be defined by the admitted numeric operations.
    if ((self.pinned & (1U << (slot - 3))) != 0) return;
    slot -= 3;
    self.used &= ~(1U << slot); self.dirty &= ~(1U << slot);
    self.registers[reg] = 0;
}
fn ulong FunctionFlow.snapshot(&self) @feat(SLJIT) {
    if (self.dirty == 0) return 0;
    ulong state = (ulong)self.dirty << 32;
    for (uint i = 0; i < 4; i++) state |= (ulong)self.owners[i] << (i * 8);
    return state;
}
fn bool function_float_op(Opcode op) @feat(SLJIT) {
    return op == Opcode.ADD || op == Opcode.ADD_FUSED || op == Opcode.SUB || op == Opcode.MUL || op == Opcode.DIV;
}
fn void FunctionEmitter.flow_publish(&self, uint slot, uint reg) @feat(SLJIT) {
    self.out.float_bits((int)slot + 3, jit::reg_r(0));
    int cached = self.out.cached(reg);
    self.out.e.mov(cached != 0 ? cached : jit::SLJIT_MEM | jit::reg_s(0),
        cached != 0 ? 0 : loop_value_offset(reg), jit::reg_r(0), 0);
}
fn void FunctionEmitter.flow_exit(&self, ulong state) @feat(SLJIT) {
    uint dirty = (uint)(state >> 32);
    for (uint i = 0; i < 4; i++) if ((dirty & (1U << i)) != 0) {
        self.flow_publish(i, (uint)((state >> (i * 8)) & 255));
    }
}
fn void FunctionEmitter.flow_flush(&self) @feat(SLJIT) {
    ulong state = self.flow.snapshot();
    state &= ~((ulong)self.flow.pinned << 32);
    self.flow_exit(state);
    for (uint i = 0; i < 4; i++) if ((self.flow.used & ~self.flow.pinned & (1U << i)) != 0) {
        self.flow.registers[self.flow.owners[i]] = 0;
    }
    self.flow.used = self.flow.pinned; self.flow.dirty = self.flow.pinned;
    for (uint i = 0; i < 256; i++) {
        self.flow.shapes[i] = 0; self.flow.versions[i] = i + 1;
    }
    self.flow.this_shape = 0; self.flow.next_version = 256; self.flow.heap_write();
}
fn int FunctionEmitter.flow_slot(&self, uint reg, uint pc) @feat(SLJIT) {
    if (self.flow.registers[reg] != 0) return self.flow.registers[reg];
    uint chosen; uint farthest;
    for (uint i = 0; i < 4; i++) {
        if ((self.flow.used & (1U << i)) == 0) { chosen = i; break; }
        if ((self.flow.pinned & (1U << i)) != 0) continue;
        uint next = self.cf.code_count;
        for (uint pos = pc + 1; pos < self.cf.code_count && !self.blocks[pos]; pos++) {
            Instruction ins = self.cf.code[pos]; uint owner = self.flow.owners[i];
            // Conservative next-use distance; false uses only cause a spill.
            if (ins.a == owner || ins.b == owner || ins.c == owner) { next = pos; break; }
        }
        if (next >= farthest) { chosen = i; farthest = next; }
    }
    if ((self.flow.used & (1U << chosen)) != 0) {
        uint owner = self.flow.owners[chosen];
        if ((self.flow.dirty & (1U << chosen)) != 0) self.flow_publish(chosen, owner);
        self.flow.drop(owner);
    }
    self.flow.used |= 1U << chosen;
    self.flow.owners[chosen] = (char)reg;
    self.flow.registers[reg] = (char)(chosen + 3);
    return (int)chosen + 3;
}
// A dirty FP definition replaces only a non-string value. This allows the
// native spill/exit to publish a number without invoking string destruction.
fn void FunctionEmitter.flow_destination(&self, uint reg, uint pc) @feat(SLJIT) {
    if (self.flow.registers[reg] != 0) return;
    int r1 = jit::reg_r(1); int r3 = jit::reg_r(3);
    self.out.load(reg, r1);
    self.out.e.op(jit::SLJIT_LSHR, r3, r1, 0, jit::SLJIT_IMM, 48);
    self.out.guard(jit::SLJIT_EQUAL, r3, 0, jit::SLJIT_IMM, (long)types::TAG_STRING, pc);
}
fn void FunctionEmitter.flow_number(&self, uint reg, int temporary, uint pc) @feat(SLJIT) {
    int cached = self.flow.registers[reg];
    if (cached != 0) { self.out.fop(jit::SLJIT_MOV_F64, temporary, 0, cached, 0); return; }
    self.out.load(reg, jit::reg_r(0)); self.out.number(jit::reg_r(0), temporary, pc);
    cached = self.flow_slot(reg, pc);
    self.out.fop(jit::SLJIT_MOV_F64, cached, 0, temporary, 0);
}
fn void FunctionEmitter.flow_value(&self, uint reg, uint pc) @feat(SLJIT) {
    self.flow_destination(reg, pc);
    self.out.number(jit::reg_r(0), 1, pc);
    self.flow.forget(reg);
    int slot = self.flow_slot(reg, pc);
    self.out.fop(jit::SLJIT_MOV_F64, slot, 0, 1, 0);
    self.flow.dirty |= 1U << (uint)(slot - 3);
}
fn bool FunctionEmitter.flow_hint(&self, uint reg, uint pc) @feat(SLJIT) {
    uint slot = self.flow.registers[reg];
    if (slot != 0 && (self.flow.pinned & (1U << (slot - 3))) != 0) return true;
    for (uint pos = pc + 1; pos < self.cf.code_count && pos < pc + 9 && !self.blocks[pos]; pos++) {
        Instruction ins = self.cf.code[pos];
        if (function_float_op(ins.op) && (ins.b == reg || ins.c == reg)) return true;
        if (ins.a == reg) return false;
    }
    return false;
}
fn void FunctionEmitter.flow_numeric(&self, Instruction ins, uint pc) @feat(SLJIT) {
    self.flow_destination(ins.a, pc);
    self.flow_number(ins.b, 1, pc); self.flow_number(ins.c, 2, pc);
    int op = ins.op == Opcode.MUL ? jit::SLJIT_MUL_F64 : ins.op == Opcode.DIV ? jit::SLJIT_DIV_F64
        : ins.op == Opcode.SUB ? jit::SLJIT_SUB_F64 : jit::SLJIT_ADD_F64;
    if (jit::sljit_emit_fop2(self.out.e.compiler, op, 1, 0, 1, 0, 2, 0) != 0) self.out.e.failed = true;
    self.flow.forget(ins.a);
    int slot = self.flow_slot(ins.a, pc);
    self.out.fop(jit::SLJIT_MOV_F64, slot, 0, 1, 0);
    self.flow.dirty |= 1U << (uint)(slot - 3);
    self.typed_count(3);
}

// Paths that temporarily disable flow must first expose every canonical lane.
fn void FunctionEmitter.flow_materialize(&self) @feat(SLJIT) {
    self.flow_exit(self.flow.snapshot());
    self.flow_flush();
}
