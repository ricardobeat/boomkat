module boomkat::vm;

import boomkat::jit;
import boomkat::types;

// All caller-clobbered homes have stable, representation-preserving storage.
// Callee-saved homes use the same contract, so target ABI details cannot leak
// into graph allocation. Reserved emitter temporaries are never value homes.
fn void SsaEmitter.helper_save(&self, uint value) @feat(SLJIT) {
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

fn void SsaEmitter.helper(&self, uint value) @feat(SLJIT) {
    SsaHelperSite* site = self.g.values[value].helper;
    if (site == null) { self.e.failed = true; return; }
    if (!site.native_resume) {
        // A RAW address still needed across an unknown mutation has no valid
        // continuation. This individual bytecode uses the exact VM fallback.
        self.publish_id(ssa_frame_at_pc(self.g, self.pc), self.pc);
        return;
    }
    foreach (id : site.live_values[:site.live_count]) self.helper_save(id);
    foreach (id : site.root_values[:site.root_count]) self.helper_save(id);
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
    foreach (id : site.live_values[:site.live_count]) self.helper_restore(id);
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
    self.e.mov(r0, 0, mem | self.state, loop_value_offset((uint)self.g.values[value].dst_reg));
    self.store_gpr((int)value, r0);
}
