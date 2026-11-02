module boomkat::vm;

import boomkat::jit;
import boomkat::types;

// SLJIT numbers each register class with its ABI-saved range at the end.
// Spills live in invocation-owned memory, and rematerialized values have no
// mutable home. Neither needs preservation across an ordinary C ABI call.
fn bool ssa_helper_clobbered(SsaValue value) @feat(SLJIT) {
    if (ssa_rematerialized(value) || value.home == 0) return false;
    int total = jit::sljit_shim_info(value.rep == F64 ? 2 : 0);
    int saved = jit::sljit_shim_info(value.rep == F64 ? 3 : 1);
    return value.home <= total - saved;
}

// Roots need a typed bits copy even when the physical home survives the call.
// Reserved emitter temporaries are never allocated value homes.
fn void SsaEmitter.helper_save(&self, uint value) @feat(SLJIT) {
    if (ssa_rematerialized(self.g.values[value])) return;
    int r0 = jit::reg_r(0);
    int r3 = jit::reg_r(3);
    if (self.g.values[value].rep == F64) {
        self.load_fpr((int)value, 1);
        if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_FROM_F64, 1, r0) != 0) self.e.failed = true;
    } else { self.gpr((int)value, r0); }
    self.e.mov(r3, 0, jit::SLJIT_MEM | self.state, $reflect(LoopState.execution).offset);
    self.e.mov(r3, 0, jit::SLJIT_MEM | r3, $reflect(SsaExecution.saved_bits).offset);
    self.e.mov(jit::SLJIT_MEM | r3, (long)value * ulong::size, r0, 0);
}

fn void SsaEmitter.helper_restore(&self, uint value) @feat(SLJIT) {
    if (ssa_rematerialized(self.g.values[value])) return;
    int r0 = jit::reg_r(0);
    int r3 = jit::reg_r(3);
    self.e.mov(r3, 0, jit::SLJIT_MEM | self.state, $reflect(LoopState.execution).offset);
    self.e.mov(r3, 0, jit::SLJIT_MEM | r3, $reflect(SsaExecution.saved_bits).offset);
    self.e.mov(r0, 0, jit::SLJIT_MEM | r3, (long)value * ulong::size);
    if (self.g.values[value].rep == F64) {
        if (jit::sljit_emit_fcopy(self.e.compiler, jit::SLJIT_COPY_TO_F64, 1, r0) != 0) self.e.failed = true;
        self.store_fpr((int)value, 1);
    } else { self.store_gpr((int)value, r0); }
}

fn void SsaEmitter.helper_save_values(&self, SsaHelperSite* site) @feat(SLJIT) {
    foreach (id : site.live_values[:site.live_count]) {
        if (ssa_helper_clobbered(self.g.values[id])) self.helper_save(id);
    }
    // Both frozen maps contain ascending canonical SSA IDs. Merge them so a
    // boxed caller-clobbered value needed after the call is materialized once.
    uint live;
    foreach (id : site.root_values[:site.root_count]) {
        while (live < site.live_count && site.live_values[live] < id) live++;
        bool saved = live < site.live_count && site.live_values[live] == id
            && ssa_helper_clobbered(self.g.values[id]);
        if (!saved) self.helper_save(id);
    }
}

fn void SsaEmitter.helper_restore_values(&self, SsaHelperSite* site) @feat(SLJIT) {
    foreach (id : site.live_values[:site.live_count]) {
        if (ssa_helper_clobbered(self.g.values[id])) self.helper_restore(id);
    }
}

fn void SsaEmitter.helper(&self, uint value) @feat(SLJIT) {
    SsaHelperSite* site = self.g.values[value].helper;
    if (site == null) { self.e.failed = true; return; }
    if (!site.native_resume) {
        // A RAW address still needed across an unknown mutation has no valid
        // continuation. This individual bytecode uses the exact VM fallback.
        self.publish_id(site.before_frame, site.pc);
        return;
    }
    self.helper_save_values(site);
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int mem = jit::SLJIT_MEM;
    int imm = jit::SLJIT_IMM;
    uint outputs;
    foreach (entry : ssa_frame_entries(self.g, site.before_frame)) {
        self.output(entry.value, self.pc);
        self.e.mov(r2, 0, mem | self.state, $reflect(LoopState.execution).offset);
        self.e.mov(r2, 0, mem | r2, $reflect(SsaExecution.outputs).offset);
        self.e.mov(mem | r2, (long)outputs * SsaPublishedValue::size + $reflect(SsaPublishedValue.reg).offset,
            imm, entry.reg, jit::SLJIT_MOV_U32);
        self.e.mov(mem | r2, (long)outputs * SsaPublishedValue::size + $reflect(SsaPublishedValue.value).offset, r0, 0);
        outputs++;
    }
    self.e.mov(r2, 0, mem | self.state, $reflect(LoopState.execution).offset);
    self.e.mov(mem | r2, $reflect(SsaExecution.output_count).offset, imm, outputs, jit::SLJIT_MOV_U32);
    self.e.mov(mem | self.state, $reflect(LoopState.budget).offset, self.budget, 0);
    self.e.mov(r0, 0, self.state, 0);
    self.e.mov(r1, 0, imm, (long)site);
    if (jit::sljit_emit_icall(self.e.compiler, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW,
            imm, (long)&ssa_helper_state) != 0) self.e.failed = true;
    void* complete = self.e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, (long)SsaHelperOutcome.COMPLETE);
    self.e.mov(r0, 0, mem | self.state, $reflect(LoopState.resume_pc).offset, jit::SLJIT_MOV_U32);
    if (jit::sljit_emit_return(self.e.compiler, jit::SLJIT_MOV, r0, 0) != 0) self.e.failed = true;
    self.e.bind(complete);
    // A routed native callee shares the invocation's progress budget.
    self.e.mov(self.budget, 0, mem | self.state, $reflect(LoopState.budget).offset);
    self.helper_restore_values(site);
    // Descriptor caches are invocation-local but helpers can grow/detach their
    // backing stores. Read the freshly validated descriptors after completion.
    for (uint memory = 0; memory < 2; memory++) {
        if (self.memory_length[memory] == 0) continue;
        self.e.mov(self.memory_length[memory], 0, mem | self.state, self.memory_offset(memory, 2));
        self.e.mov(self.memory_base[memory], 0, mem | self.state, self.memory_offset(memory, 1));
    }
    self.addr_reg = 0;
    self.addr_memory = -1;
    self.addr_numeric_load = false;
    if (self.g.values[value].dst_reg < 0) return;
    if (self.plan.ssa_data != null) {
        self.e.mov(r0, 0, mem | self.state, $reflect(LoopState.execution).offset);
        self.e.mov(r0, 0, mem | r0, $reflect(SsaExecution.input_values).offset);
        self.e.mov(r0, 0, mem | r0, (long)self.g.values[value].dst_reg * TVal::size);
    } else { self.e.mov(r0, 0, mem | self.state, loop_value_offset((uint)self.g.values[value].dst_reg)); }
    self.store_gpr((int)value, r0);
}
