module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::jit;
import boomkat::types;
import std::core::mem;

enum SsaDeoptKind : char { SAVED_REGISTER, SPILL, CONSTANT }
struct SsaDeoptLocation @feat(SLJIT) {
    SsaDeoptKind kind;
    SsaRep rep;
    uint index;
    uint value;
    ulong bits;
}
struct SsaDeoptEntry @feat(SLJIT) { uint reg; SsaDeoptLocation location; }
struct SsaDeoptFrame @feat(SLJIT) {
    SsaDeoptFrame* next_owned;
    SsaDeoptFrame* parent;
    CompiledFunction* function;
    uint pc;
    uint callsite_pc;
    uint return_reg;
    SsaDeoptLocation callee;
    SsaDeoptLocation receiver;
    SsaDeoptEntry* entries;
    uint count;
    usz allocated_bytes;
    bool complete;
}
struct SsaDeoptSite @feat(SLJIT) {
    SsaDeoptSite* next;
    SsaDeoptFrame* frame;
    SsaFrameId frame_id;
    uint pc;
    usz allocated_bytes;
}
alias SsaDeoptChain @feat(SLJIT) = fn Instruction*(SsaExecution* execution, SsaDeoptSite* site);
struct SsaDeoptHome @feat(SLJIT) { int reg; bool floating; }
struct SsaDeoptStub @feat(SLJIT) { SsaDeoptSite* site; void* label; }

fn bool ssa_deopt_prepare(SsaGraph* g) @feat(SLJIT) {
    uint capacity = g.registers.scratches + g.registers.saveds + g.fpr_homes;
    if (capacity > g.value_count) capacity = g.value_count;
    g.deopt_homes = (SsaDeoptHome*)ssa_storage_alloc(g, capacity, SsaDeoptHome::size);
    g.deopt_frames = (SsaDeoptFrame**)ssa_storage_alloc(g, g.frame_count, SsaDeoptFrame*::size);
    if (g.failed) return false;
    for (uint id = 0; id < g.value_count; id++) {
        if (!ssa_charge_work(g, (usz)g.deopt_home_count + 1)) return false;
        SsaValue value = g.values[id];
        if (value.home == 0 || value.op == COPY || !ssa_has_result(value.op)) continue;
        bool floating = value.rep == F64;
        bool found;
        for (uint i = 0; i < g.deopt_home_count; i++) {
            if (g.deopt_homes[i].reg == value.home && g.deopt_homes[i].floating == floating) { found = true; break; }
        }
        if (found) continue;
        if (g.deopt_home_count == capacity) { g.failed = true; return false; }
        g.deopt_homes[g.deopt_home_count++] = { value.home, floating };
    }
    return true;
}
fn SsaDeoptLocation ssa_deopt_location(SsaGraph* g, int id) @feat(SLJIT) {
    SsaDeoptLocation location = { .kind = CONSTANT, .rep = BOXED, .value = uint::max,
        .bits = types::TAG_UNDEFINED << 48 };
    if (id < 0) return location;
    id = ssa_alias(g, id);
    if (id < 0 || id >= (int)g.value_count) { g.failed = true; return location; }
    SsaValue value = g.values[id];
    location.value = (uint)id;
    location.rep = value.rep;
    if (value.rep == RAW) { g.failed = true; return location; }
    if (value.op == CONST_I || value.op == CONST_F || value.op == CONST_BOXED) {
        location.bits = (ulong)value.imm;
        return location;
    }
    if (value.home == 0) {
        location.kind = SPILL;
        location.index = value.spill;
        return location;
    }
    location.kind = SAVED_REGISTER;
    for (uint i = 0; i < g.deopt_home_count; i++) {
        if (!ssa_charge_work(g, 1)) return location;
        if (g.deopt_homes[i].reg == value.home && g.deopt_homes[i].floating == (value.rep == F64)) {
            location.index = i;
            return location;
        }
    }
    g.failed = true;
    return location;
}
fn SsaDeoptFrame* ssa_deopt_freeze_frame(SsaGraph* g, SsaFrameId id) @feat(SLJIT) {
    if (id == SSA_NO_FRAME) return null;
    SsaFrameId cursor = id;
    SsaDeoptFrame* child;
    while (cursor != SSA_NO_FRAME) {
        if (cursor >= g.frame_count || !ssa_charge_work(g, 1)) { g.failed = true; return null; }
        SsaDeoptFrame* known = g.deopt_frames[cursor];
        if (known != null) {
            if (!known.complete) { g.failed = true; return null; } // parent cycle
            if (child != null) child.parent = known;
            break;
        }
        SsaFrame origin = g.frame_table[cursor];
        if (origin.parent != SSA_NO_FRAME && g.plan.ssa_deopt_chain == null) { g.failed = true; return null; }
        SsaFrameEntry[] entries = ssa_frame_entries(g, cursor);
        usz bytes = SsaDeoptFrame::size + entries.len * SsaDeoptEntry::size;
        if (!ssa_persistent_reserve(g, bytes)) return null;
        SsaDeoptFrame* frame = (SsaDeoptFrame*)g.heap.alloc_func(g.heap.heap_udata, bytes);
        if (frame == null) { ssa_persistent_release(g, bytes); g.failed = true; return null; }
        mem::clear(frame, (sz)bytes);
        frame.next_owned = g.plan.ssa_deopt_frames;
        g.plan.ssa_deopt_frames = frame;
        g.deopt_frames[cursor] = frame;
        if (child != null) child.parent = frame;
        frame.allocated_bytes = bytes;
        frame.function = origin.function;
        frame.pc = origin.pc;
        frame.callsite_pc = origin.callsite_pc;
        frame.return_reg = origin.return_reg;
        frame.callee = ssa_deopt_location(g, origin.callee_value);
        frame.receiver = ssa_deopt_location(g, origin.receiver_value);
        frame.entries = (SsaDeoptEntry*)((char*)frame + SsaDeoptFrame::size);
        frame.count = (uint)entries.len;
        if (!ssa_charge_work(g, entries.len)) return null;
        foreach (i, entry : entries) frame.entries[i] = { entry.reg, ssa_deopt_location(g, entry.value) };
        if (g.failed) return null;
        child = frame;
        cursor = origin.parent;
    }
    // The graph directory supplies an explicit stack: freezing deep logical
    // chains never consumes the native compiler's C stack.
    SsaDeoptFrame* result = g.deopt_frames[id];
    for (SsaDeoptFrame* frame = result; frame != null && !frame.complete; frame = frame.parent) frame.complete = true;
    return result;
}
fn SsaDeoptSite* ssa_deopt_freeze_site(SsaGraph* g, SsaFrameId frame, uint pc) @feat(SLJIT) {
    if (!ssa_persistent_reserve(g, SsaDeoptSite::size)) return null;
    SsaDeoptSite* site = (SsaDeoptSite*)g.heap.alloc_func(g.heap.heap_udata, SsaDeoptSite::size);
    if (site == null) { ssa_persistent_release(g, SsaDeoptSite::size); g.failed = true; return null; }
    *site = {};
    site.next = g.plan.ssa_deopt_sites;
    g.plan.ssa_deopt_sites = site;
    site.allocated_bytes = SsaDeoptSite::size;
    site.frame_id = frame;
    site.pc = pc;
    site.frame = ssa_deopt_freeze_frame(g, frame);
    return g.failed ? null : site;
}
fn void ssa_deopt_free(Heap* h, LoopPlan* plan) @feat(SLJIT) {
    while (plan.ssa_deopt_sites != null) {
        SsaDeoptSite* site = plan.ssa_deopt_sites;
        plan.ssa_deopt_sites = site.next;
        h.free_func(h.heap_udata, site);
    }
    while (plan.ssa_deopt_frames != null) {
        SsaDeoptFrame* frame = plan.ssa_deopt_frames;
        plan.ssa_deopt_frames = frame.next_owned;
        h.free_func(h.heap_udata, frame);
    }
}
fn usz ssa_deopt_metadata_bytes(LoopPlan* plan) @feat(SLJIT) {
    usz bytes;
    for (SsaDeoptSite* site = plan.ssa_deopt_sites; site != null; site = site.next) bytes += site.allocated_bytes;
    for (SsaDeoptFrame* frame = plan.ssa_deopt_frames; frame != null; frame = frame.next_owned) bytes += frame.allocated_bytes;
    return bytes;
}

fn bool ssa_deopt_read(SsaExecution* execution, SsaDeoptLocation location, TVal* value) @feat(SLJIT) {
    ulong bits = location.bits;
    switch (location.kind) {
        case SAVED_REGISTER:
            if (location.index >= execution.value_capacity) return false;
            bits = execution.saved_bits[location.index];
        case SPILL:
            if (execution.plan.ssa_data == null || location.index >= execution.plan.ssa_data.spill_count) return false;
            bits = execution.spills[location.index];
        case CONSTANT: break;
    }
    switch (location.rep) {
        case BOXED: if (!ssa_decode_boxed_bits(bits, value)) return false;
        case INT32: value.set_fastint((long)(int)bits);
        case F64: value.set_number(bitcast(bits, double));
        case RAW: return false;
    }
    return true;
}
fn bool ssa_deopt_anchor_location(SsaExecution* execution, SsaDeoptLocation location, uint pass) @feat(SLJIT) {
    if (location.rep != BOXED || location.value == uint::max) return true;
    TVal value;
    if (location.value >= execution.value_capacity || !ssa_deopt_read(execution, location, &value)) return false;
    if (pass == 0 && !ssa_execution_root(execution, location.value)) return false;
    Heap* h = execution.cold.heap;
    if (pass == 1 && value.is_refcounted() && value.get_heapptr() != null) ((HeapHeader*)value.get_heapptr()).incref();
    if (pass == 2) {
        h.tval_copy_ref(&execution.roots[location.value].value, &value);
        h.decref_tval(&value);
    }
    return true;
}
fn bool ssa_deopt_anchor_chain(SsaExecution* execution, SsaDeoptSite* site) @feat(SLJIT) {
    // Validate all sources, retain all new roots, then release any old roots.
    for (uint pass = 0; pass < 3; pass++) {
        for (SsaDeoptFrame* frame = site.frame; frame != null; frame = frame.parent) {
            if (!ssa_deopt_anchor_location(execution, frame.callee, pass)
                || !ssa_deopt_anchor_location(execution, frame.receiver, pass)) return false;
            foreach (entry : frame.entries[0:frame.count]) {
                if (!ssa_deopt_anchor_location(execution, entry.location, pass)) return false;
            }
        }
    }
    return true;
}
fn ulong ssa_deopt_execute(SsaExecution* execution, SsaDeoptSite* site) @feat(SLJIT) @noinline {
    if (site.frame == null) return site.pc == SSA_ENTRY_BAIL ? execution.state_storage.resume_pc : site.pc;
    if (site.frame.parent != null) {
        assert(execution.plan.ssa_deopt_chain != null);
        if (!ssa_deopt_anchor_chain(execution, site)) return site.pc;
        Instruction* resume = execution.plan.ssa_deopt_chain(execution, site);
        execution.caller_lost = true;
        execution.vm_resume = resume;
        return 0;
    }
    SsaDeoptFrame* frame = site.frame;
    assert(frame.function == execution.function && frame.count <= execution.register_count);
    execution.output_count = 0;
    foreach (i, entry : frame.entries[0:frame.count]) {
        assert(entry.reg < execution.register_count);
        execution.outputs[i].reg = entry.reg;
        if (!ssa_deopt_read(execution, entry.location, &execution.outputs[i].value)) return site.pc;
    }
    execution.output_count = frame.count;
    // No allocation or GC occurs while decoding locations. The common VM
    // publication retains every new value before releasing any old slot.
    bool published = ssa_execution_publish(execution);
    assert(published && execution.output_count == 0);
    return site.pc;
}

fn void SsaEmitter.deopt_stubs(&self) @feat(SLJIT) {
    SsaGraph* g = self.g;
    if (self.e.failed || g.failed) return;
    if (!ssa_deopt_prepare(g)) { self.e.failed = true; return; }
    uint capacity = 8;
    while (capacity < g.exit_count * 2) capacity *= 2;
    SsaDeoptStub* table = (SsaDeoptStub*)ssa_storage_alloc(g, capacity, SsaDeoptStub::size);
    void** common_jumps = (void**)ssa_storage_alloc(g, g.exit_count, void*::size);
    if (g.failed) { self.e.failed = true; return; }
    uint count;
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    for (uint i = 0; i < g.exit_count; i++) {
        if (!ssa_charge_work(g, 1)) { self.e.failed = true; return; }
        SsaExit item = g.exits[i];
        uint slot = (item.frame * 2654435761U ^ item.pc) & (capacity - 1);
        while (table[slot].site != null && (table[slot].site.frame_id != item.frame || table[slot].site.pc != item.pc)) {
            if (!ssa_charge_work(g, 1)) { self.e.failed = true; return; }
            slot = (slot + 1) & (capacity - 1);
        }
        if (table[slot].site == null) {
            SsaDeoptSite* site = ssa_deopt_freeze_site(g, item.frame, item.pc);
            if (site == null) { self.e.failed = true; return; }
            table[slot].site = site;
            table[slot].label = self.e.label();
            if (self.e.failed || table[slot].label == null) return;
            self.e.mov(r0, 0, jit::SLJIT_IMM, (long)site);
            void* next = jit::sljit_emit_jump(self.e.compiler, jit::SLJIT_JUMP);
            if (next == null) { self.e.failed = true; return; }
            common_jumps[count++] = next;
        }
        jit::sljit_set_label(item.jump, table[slot].label);
    }
    void* common = self.e.label();
    if (self.e.failed || common == null) return;
    for (uint i = 0; i < count; i++) jit::sljit_set_label(common_jumps[i], common);
    self.e.mov(r1, 0, jit::SLJIT_MEM | self.state, $reflect(LoopState.execution).offset);
    self.e.mov(r2, 0, jit::SLJIT_MEM | r1, $reflect(SsaExecution.saved_bits).offset);
    for (uint i = 0; i < g.deopt_home_count; i++) {
        SsaDeoptHome home = g.deopt_homes[i];
        if (home.floating) {
            if (jit::sljit_emit_fop1(self.e.compiler, jit::SLJIT_MOV_F64,
                jit::SLJIT_MEM | r2, (long)i * ulong::size, home.reg, 0) != 0) self.e.failed = true;
        } else { self.e.mov(jit::SLJIT_MEM | r2, (long)i * ulong::size, home.reg, 0); }
    }
    self.e.mov(jit::SLJIT_MEM | self.state, $reflect(LoopState.budget).offset, self.budget, 0);
    self.e.mov(r1, 0, r0, 0); // immutable site pointer survives home saving
    self.e.mov(r0, 0, jit::SLJIT_MEM | self.state, $reflect(LoopState.execution).offset);
    if (jit::sljit_emit_icall(self.e.compiler, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW,
        jit::SLJIT_IMM, (long)&ssa_deopt_execute) != 0) self.e.failed = true;
    if (jit::sljit_emit_return(self.e.compiler, jit::SLJIT_MOV, r0, 0) != 0) self.e.failed = true;
}
