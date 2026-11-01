module boomkat::vm;

import boomkat::heap;
import std::core::mem;

// Bounded global allocation for cyclic SSA. All bitsets are invocation-local
// heap storage: at 512 values the interference matrix occupies 32 KiB rather
// than growing the native compiler's stack. Allocation failure declines SSA.
struct SsaAllocation @feat(SLJIT) {
    SsaGraph* g;
    uint words;
    ulong* conflicts;
    ulong* inputs;
    ulong* live;
    ulong* edge;
    ulong* destinations;
    ulong* initial;
}

fn void SsaAllocation.add(&self, ulong* set, int value) @feat(SLJIT) {
    value = ssa_alias(self.g, value);
    if (value < 0 || value >= (int)self.g.value_count) return;
    set[(uint)value / 64] |= 1UL << ((uint)value % 64);
}
fn bool SsaAllocation.contains(&self, ulong* set, uint value) @feat(SLJIT) {
    return (set[value / 64] & (1UL << (value % 64))) != 0;
}
fn void SsaAllocation.remove(&self, ulong* set, uint value) @feat(SLJIT) {
    set[value / 64] &= ~(1UL << (value % 64));
}
fn void SsaAllocation.clear(&self, ulong* set) @feat(SLJIT) {
    for (uint w = 0; w < self.words; w++) set[w] = 0;
}
fn void SsaAllocation.copy(&self, ulong* dest, ulong* source) @feat(SLJIT) {
    for (uint w = 0; w < self.words; w++) dest[w] = source[w];
}
fn void SsaAllocation.merge(&self, ulong* dest, ulong* source) @feat(SLJIT) {
    for (uint w = 0; w < self.words; w++) dest[w] |= source[w];
}
fn void SsaAllocation.interfere(&self, uint value, ulong* live) @feat(SLJIT) {
    SsaGraph* g = self.g;
    ulong* row = self.conflicts + (usz)value * self.words;
    for (uint other = 0; other < g.value_count; other++) {
        if (other == value || !self.contains(live, other)
            || !ssa_same_class(g.values[value].rep, g.values[other].rep)) continue;
        row[other / 64] |= 1UL << (other % 64);
        self.conflicts[(usz)other * self.words + value / 64] |= 1UL << (value % 64);
    }
}

// Guard recovery is an allocator use even when no IR instruction reads the
// value again. Keep a pre-bytecode frame through every instruction it lowers
// to, including result writes preceding a later guard in that instruction.
fn void SsaAllocation.recovery(&self, ulong* live, uint pc) @feat(SLJIT) {
    SsaGraph* g = self.g;
    if (g.direct || pc < g.plan.begin || pc > g.plan.end) return;
    foreach (value : g.frames[pc - g.plan.begin]) self.add(live, value);
}
fn void SsaAllocation.operands(&self, ulong* live, SsaValue v) @feat(SLJIT) {
    switch (v.op) {
        case NOP: case ARG: case PHI: case JOIN: case COPY: case GOTO:
        case RECEIVER: case BINDING: case CONST_I: case CONST_F: case CONST_BOXED: break;
        case STORAGE: case PROTO_STORAGE: case CHECKFN: case CHECKPROTO:
        case CHECKSHAPE: case CHECKWRITE: case BNOT: case NEG:
        case TO_INT: case TO_INDEX: case TO_F64: case BOX_I: case BOX_F:
        case LOAD: case RETURN:
            self.add(live, v.a);
            break;
        case SELECT:
            self.add(live, (int)v.imm);
            self.add(live, v.a);
            self.add(live, v.b);
            break;
        default:
            self.add(live, v.a);
            self.add(live, v.b);
            break;
    }
}

// JOIN inputs are uses of their predecessor edge, never of the successor
// block. Keep conservative destination/source and live-through interference
// even when the emitter stages parallel copies. Physical cycles involving the
// same JOIN identity require staging: an interference edge cannot split one ID.
fn void SsaAllocation.transfer_edge(&self, uint pred, uint succ, bool record) @feat(SLJIT) {
    SsaGraph* g = self.g;
    if (succ >= g.block_count) return;
    self.copy(self.edge, self.inputs + (usz)succ * self.words);
    self.clear(self.destinations);
    for (uint j = 0; j < g.join_count; j++) {
        SsaJoin* join = &g.joins[j];
        if (join.block != succ) continue;
        int edge = -1;
        if (pred == SSA_BLOCKS) {
            if (!join.entry) continue;
        } else {
            for (uint p = 0; p < join.pred_count; p++) {
                if (join.preds[p] == pred) { edge = (int)p; break; }
            }
            if (edge < 0) continue;
        }
        for (uint reg = 0; reg < LOOP_REGS; reg++) {
            if (join.phi[reg] < 0) continue;
            self.add(self.destinations, join.phi[reg]);
            self.add(self.edge, pred == SSA_BLOCKS ? join.entry_incoming[reg] : join.incoming[edge][reg]);
        }
    }
    if (pred == SSA_BLOCKS) {
        self.recovery(self.edge, g.blocks[succ].begin);
    } else {
        // A conversion emitted by an edge copy can fail at the last emitted
        // bytecode's PC. Match the emitter's PC even for a fallthrough block.
        int last = ssa_block_last_value(g, pred);
        uint pc = last >= 0 ? g.values[last].pc : g.blocks[pred].begin;
        self.recovery(self.edge, pc);
    }
    if (record) for (uint i = 0; i < g.value_count; i++) {
        if (!self.contains(self.destinations, i)) continue;
        self.interfere(i, self.edge);
        self.interfere(i, self.destinations);
    }
    self.merge(self.live, self.edge);
}

// The outer loop latch is emitted outside the block instruction ranges. Its
// parallel copies consume every converted PHI input together with the budget
// recovery frame and predicate. PHI definitions occur on this implicit edge.
fn void SsaAllocation.latch(&self, bool record) @feat(SLJIT) {
    SsaGraph* g = self.g;
    self.copy(self.edge, self.inputs);
    self.clear(self.destinations);
    foreach (phi : g.phi) {
        if (phi < 0) continue;
        self.add(self.destinations, phi);
        self.add(self.edge, g.values[phi].a);
    }
    self.add(self.edge, g.cmp_lhs);
    self.add(self.edge, g.cmp_rhs);
    self.recovery(self.edge, g.plan.end);
    if (record) for (uint i = 0; i < g.value_count; i++) {
        if (!self.contains(self.destinations, i)) continue;
        self.interfere(i, self.edge);
        self.interfere(i, self.destinations);
    }
    self.merge(self.live, self.edge);
}

fn void SsaAllocation.block(&self, uint block, bool record) @feat(SLJIT) {
    SsaGraph* g = self.g;
    self.clear(self.live);
    self.transfer_edge(block, g.blocks[block].succ0, record);
    self.transfer_edge(block, g.blocks[block].succ1, record);
    if (block + 1 == g.block_count) {
        if (!g.single_pass) {
            self.latch(record);
        } else if (g.plan.ssa_function == null) {
            if (g.direct) {
                if (g.result_reg < LOOP_REGS) self.add(self.live, g.current[g.result_reg]);
            } else {
                foreach (value : g.current) self.add(self.live, value);
            }
        }
    }
    for (int node = ssa_block_last_value(g, block); node >= 0; node = ssa_previous_value(g, node)) {
        uint i = (uint)node;
        SsaValue v = g.values[i];
        // COPY is a pure alias, so neither a machine definition nor a kill.
        if (v.op == COPY) continue;
        bool definition = ssa_has_result(v.op) && v.op != ARG && v.op != PHI && v.op != JOIN;
        if (record && v.op == HELPER) ssa_helper_capture(self, i);
        self.operands(self.live, v);
        self.recovery(self.live, v.pc);
        if (definition) {
            // Inclusive operand interference also protects lowering sequences
            // that write their destination before their final guard executes.
            if (record) self.interfere(i, self.live);
            self.remove(self.live, i);
        }
    }
    // JOINs precede block_first and are simultaneous edge definitions. ARGs
    // are defined only in the prologue; do not kill invariant arguments each
    // time a backedge enters the first block.
    self.clear(self.destinations);
    for (uint j = 0; j < g.join_count; j++) {
        if (g.joins[j].block != block) continue;
        foreach (phi : g.joins[j].phi) if (phi >= 0) self.add(self.destinations, phi);
    }
    if (block == 0 && !g.single_pass) {
        foreach (phi : g.phi) if (phi >= 0) self.add(self.destinations, phi);
    }
    if (record) for (uint i = 0; i < g.value_count; i++) {
        if (!self.contains(self.destinations, i)) continue;
        self.interfere(i, self.live);
        self.interfere(i, self.destinations);
    }
    for (uint w = 0; w < self.words; w++) self.live[w] &= ~self.destinations[w];
}

fn void ssa_allocate_cfg(SsaGraph* g) @feat(SLJIT) {
    if (g.value_count == 0 || g.block_count == 0) { g.failed = true; return; }
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        if ((value.op == CONST_I || value.op == CONST_F) && value.last == value.def) value.op = NOP;
    }
    uint words = (g.value_count + 63) / 64;
    usz matrix_words = (usz)g.value_count * words;
    usz input_words = (usz)g.block_count * words;
    usz count = matrix_words + input_words + (usz)4 * words;
    ulong* storage = (ulong*)g.heap.alloc_func(g.heap.heap_udata, count * ulong::size);
    if (storage == null) { g.failed = true; return; }
    defer g.heap.free_func(g.heap.heap_udata, storage);
    mem::clear(storage, (sz)(count * ulong::size));
    SsaAllocation a = { .g = g, .words = words, .conflicts = storage,
        .inputs = storage + matrix_words, .live = storage + matrix_words + input_words,
        .edge = storage + matrix_words + input_words + words,
        .destinations = storage + matrix_words + input_words + (usz)2 * words,
        .initial = storage + matrix_words + input_words + (usz)3 * words };
    // Monotone backwards dataflow, including edge operands and the implicit
    // latch. The finite value sets converge even for nested/multiple backedges.
    bool changed = true;
    while (changed) {
        changed = false;
        for (uint b = g.block_count; b > 0; b--) {
            a.block(b - 1, false);
            ulong* input = a.inputs + (usz)(b - 1) * words;
            for (uint w = 0; w < words; w++) {
                if (input[w] != a.live[w]) { input[w] = a.live[w]; changed = true; }
            }
        }
    }
    for (uint b = 0; b < g.block_count; b++) a.block(b, true);
    // Every synthetic entry (initial entry or a resumed call successor)
    // consumes arguments initialized by that entry's prologue, then copies
    // them to its own JOINs. There is no native edge across an interpreted call.
    for (uint j = 0; j < g.join_count; j++) {
        if (!g.joins[j].entry) continue;
        a.clear(a.live);
        a.transfer_edge(SSA_BLOCKS, g.joins[j].block, true);
    }
    for (uint reg = 0; reg < g.cf.num_regs && reg < LOOP_REGS; reg++) {
        int value = g.phi[reg] >= 0 ? g.phi[reg] : g.arg[reg];
        if (value < 0 || (g.direct && g.values[value].last == g.values[value].def)) continue;
        a.add(a.initial, value);
    }
    // Even a dead argument is a prologue write and must not overwrite an
    // earlier initialized live input before entry copies/body consume it.
    for (uint i = 0; i < g.value_count; i++) {
        if (a.contains(a.initial, i)) a.interfere(i, a.initial);
        g.values[i].home = 0;
        g.values[i].spill = 0;
    }
    g.spill_count = 0;
    // Prefer loop-carried definitions, then greedily color the remaining
    // interference graph. Non-overlapping joins can now reuse the same home.
    for (uint pass = 0; pass < 2; pass++) for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        if (value.op == COPY || !ssa_has_result(value.op)) continue;
        bool join = value.op == PHI || value.op == JOIN;
        if (join != (pass == 0)) continue;
        uint homes = value.rep == F64 ? g.fpr_homes : g.registers.scratch_homes + g.registers.saved_homes;
        for (uint slot = 0; slot < homes; slot++) {
            int home = value.rep == F64 ? 3 + (int)slot : ssa_gpr_home(g, slot);
            bool free = true;
            ulong* conflicts = a.conflicts + (usz)i * words;
            for (uint other = 0; other < g.value_count; other++) {
                if (g.values[other].home == home && ssa_same_class(g.values[other].rep, value.rep)
                    && a.contains(conflicts, other)) { free = false; break; }
            }
            if (free) { value.home = home; break; }
        }
        if (value.home == 0) value.spill = g.spill_count++;
    }
    for (uint i = 0; i < g.value_count; i++) {
        if (g.values[i].op != COPY) continue;
        int root = ssa_alias(g, (int)i);
        if (root < 0 || root == (int)i) { g.failed = true; return; }
        g.values[i].home = g.values[root].home;
        g.values[i].spill = g.values[root].spill;
    }
}

// An edge may copy sequentially only when no conversion can refuse and no
// destination overwrites a source still needed by another parallel copy.
// Share this predicate with preparation so packed inline state reserves exactly
// the temporary storage the emitter can use after allocation.
fn bool ssa_phi_staging(SsaGraph* g, SsaJoin* join, int[LOOP_REGS]* incoming) @feat(SLJIT) {
    for (uint reg = 0; reg < LOOP_REGS; reg++) {
        if (join.phi[reg] < 0 || (*incoming)[reg] < 0) continue;
        SsaValue dest = g.values[join.phi[reg]];
        SsaValue source = g.values[(*incoming)[reg]];
        if ((dest.rep == F64 && source.rep != F64 && source.rep != INT32)
            || (dest.rep == INT32 && source.rep != INT32)) return true;
        if (dest.rep == source.rep && ssa_same_location(dest, source)) continue;
        for (uint other = 0; other < LOOP_REGS; other++) {
            if (join.phi[other] < 0 || (*incoming)[other] < 0) continue;
            SsaValue read = g.values[(*incoming)[other]];
            if (ssa_same_location(dest, read)) return true;
        }
    }
    return false;
}

fn uint ssa_edge_copy_temps(SsaGraph* g) @feat(SLJIT) {
    if (!g.inplace || !g.cyclic) return 0;
    uint maximum;
    for (uint j = 0; j < g.join_count; j++) {
        SsaJoin* join = &g.joins[j];
        bool staged = join.entry && ssa_phi_staging(g, join, &join.entry_incoming);
        for (uint p = 0; p < join.pred_count && !staged; p++) {
            staged = ssa_phi_staging(g, join, &join.incoming[p]);
        }
        if (!staged) continue;
        uint count;
        foreach (phi : join.phi) if (phi >= 0) count++;
        if (count > maximum) maximum = count;
    }
    return maximum;
}
