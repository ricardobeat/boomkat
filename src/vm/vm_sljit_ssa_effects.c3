module boomkat::vm;

import boomkat::heap;
import boomkat::hobject;
import std::core::mem;

// Effects are explicit so admitting a new IR operation cannot silently make a
// memory proof valid across a call, allocation, or layout mutation. Slot stores
// preserve layouts, but invalidate every read version: different descriptors
// can name the same object or backing store.
enum SsaEffect : char {
    NONE,
    SCALAR,
    LAYOUT,
    READ,
    WRITE,
    ITERATION,
    UNKNOWN
}

fn SsaEffect ssa_effect(SsaOp op) @feat(SLJIT) {
    switch (op) {
        case NOP: case ARG: case COPY: case BRANCH: case GOTO: case RETURN: return NONE;
        case CONST_I: case CONST_F: case CONST_BOXED:
        case ADD: case SUB: case MUL: case DIV:
        case BAND: case BOR: case BXOR: case SHL: case SHR: case USHR:
        case BNOT: case NEG: case TO_INT: case TO_INDEX: case TO_F64:
        case BOX_I: case BOX_F: case COMPARE: case SELECT: return SCALAR;
        case RECEIVER: case BINDING: case STORAGE: case PROTO_STORAGE:
        case CHECKFN: case CHECKPROTO: case CHECKSHAPE: case CHECKWRITE: return LAYOUT;
        case LOAD: return READ;
        case STORE: return WRITE;
        case PHI: case JOIN: return ITERATION;
        default: return UNKNOWN;
    }
}

// Cycle-entry boundaries discard all facts, including scalar expressions.
// Every directed cycle has a non-increasing numbered edge, so clearing at each
// such destination prevents facts from describing a previous dynamic execution
// of a static SSA definition. LICM, rather than this availability pass, owns
// proofs that a computation is genuinely invariant across those boundaries.
struct SsaAvailable @feat(SLJIT) { ulong* words; uint count; SsaGraph* graph; }
struct SsaCfgEffects @feat(SLJIT) {
    SsaGraph* graph;
    SsaValue* original;
    uint value_count;
    SsaAvailable* input;
    SsaAvailable* output;
    SsaAvailable candidates;
    SsaAvailable memory;
    SsaAvailable work_in;
    SsaAvailable work_out;
    bool* reachable;
    bool* boundary;
    uint* buckets;
    uint* next;
    uint* order;
    uint bucket_count;
    bool local_only;
}
fn void SsaAvailable.include(&self, uint id) @feat(SLJIT) { self.words[id >> 6] |= 1UL << (id & 63); }
fn bool SsaAvailable.contains(&self, uint id) @feat(SLJIT) => (self.words[id >> 6] & (1UL << (id & 63))) != 0;
fn void SsaAvailable.clear(&self) @feat(SLJIT) {
    if (!ssa_charge_work(self.graph, self.count)) return;
    for (uint w = 0; w < self.count; w++) self.words[w] = 0;
}
fn void SsaAvailable.copy(&self, SsaAvailable* other) @feat(SLJIT) {
    if (!ssa_charge_work(self.graph, self.count)) return;
    for (uint w = 0; w < self.count; w++) self.words[w] = other.words[w];
}
fn void SsaAvailable.intersect(&self, SsaAvailable* other) @feat(SLJIT) {
    if (!ssa_charge_work(self.graph, self.count)) return;
    for (uint w = 0; w < self.count; w++) self.words[w] &= other.words[w];
}
fn void SsaAvailable.exclude(&self, SsaAvailable* other) @feat(SLJIT) {
    if (!ssa_charge_work(self.graph, self.count)) return;
    for (uint w = 0; w < self.count; w++) self.words[w] &= ~other.words[w];
}
fn bool SsaAvailable.same(&self, SsaAvailable* other) @feat(SLJIT) {
    if (!ssa_charge_work(self.graph, self.count)) return false;
    for (uint w = 0; w < self.count; w++) if (self.words[w] != other.words[w]) return false;
    return true;
}
fn void ssa_effect_step(SsaCfgEffects* facts, uint id, SsaAvailable* available) @feat(SLJIT) {
    SsaEffect effect = ssa_effect(facts.original[id].op);
    if (effect == UNKNOWN) { available.clear(); return; }
    if (effect == WRITE) available.exclude(&facts.memory);
    if (facts.candidates.contains(id)) available.include(id);
}
fn void ssa_effect_available(SsaGraph* g, SsaCfgEffects* facts) @feat(SLJIT) {
    for (uint b = 0; b < g.block_count; b++) {
        facts.boundary[b] = b == 0 || g.blocks[b].external;
        facts.reachable[b] = facts.boundary[b];
        for (uint p = 0; p < ssa_pred_count(g, b); p++) {
            if (ssa_pred(g, b, p) >= b) facts.boundary[b] = true;
        }
    }
    bool changed = true;
    while (changed && !g.failed) {
        changed = false;
        if (!ssa_charge_work(g, g.block_count)) return;
        for (uint b = 0; b < g.block_count; b++) {
            if (facts.reachable[b]) continue;
            if (!ssa_charge_work(g, ssa_pred_count(g, b))) return;
            for (uint p = 0; p < ssa_pred_count(g, b); p++) {
                if (!facts.reachable[ssa_pred(g, b, p)]) continue;
                facts.reachable[b] = true;
                changed = true;
                break;
            }
        }
    }
    if (facts.local_only) return;
    for (uint b = 0; b < g.block_count; b++) {
        if (facts.reachable[b] && !facts.boundary[b]) facts.output[b].copy(&facts.candidates);
    }
    changed = true;
    while (changed && !g.failed) {
        changed = false;
        if (!ssa_charge_work(g, g.block_count)) return;
        for (uint b = 0; b < g.block_count; b++) {
            if (!facts.reachable[b]) continue;
            facts.work_in.clear();
            if (!facts.boundary[b]) {
                facts.work_in.copy(&facts.candidates);
                if (!ssa_charge_work(g, ssa_pred_count(g, b))) return;
            for (uint p = 0; p < ssa_pred_count(g, b); p++) {
                    uint pred = ssa_pred(g, b, p);
                    if (facts.reachable[pred]) facts.work_in.intersect(&facts.output[pred]);
                }
            }
            facts.input[b].copy(&facts.work_in);
            facts.work_out.copy(&facts.work_in);
            for (int id = ssa_block_first_value(g, b); id >= 0; id = ssa_next_value(g, id)) {
                if (!ssa_charge_work(g, 1)) return;
                ssa_effect_step(facts, (uint)id, &facts.work_out);
            }
            if (!facts.work_out.same(&facts.output[b])) {
                facts.output[b].copy(&facts.work_out);
                changed = true;
            }
        }
    }
}
fn bool ssa_effect_dominates(SsaGraph* g, SsaCfgEffects* facts, uint prior, uint current) @feat(SLJIT) {
    if (!ssa_charge_work(g, 1)) return false;
    SsaValue a = g.values[prior];
    SsaValue b = g.values[current];
    if (a.block != b.block) return ssa_dominates(g, (uint)a.block, (uint)b.block);
    if (a.op == ARG || a.op == PHI || a.op == JOIN) return true;
    return facts.order[prior] != 0 && facts.order[prior] < facts.order[current];
}
fn int ssa_effect_alias(SsaCfgEffects* facts, int value) @feat(SLJIT) {
    uint guard;
    if (!ssa_charge_work(facts.graph, 1)) return -1;
    while (value >= 0 && guard++ < facts.value_count && facts.original[value].op == COPY) {
        if (!ssa_charge_work(facts.graph, 1)) return -1;
        value = facts.original[value].a;
    }
    return value;
}
fn bool ssa_effect_address(SsaCfgEffects* facts, int left, int right) @feat(SLJIT) {
    left = ssa_effect_alias(facts, left);
    right = ssa_effect_alias(facts, right);
    if (left == right) return true;
    if (left < 0 || right < 0) return false;
    SsaValue a = facts.original[left];
    SsaValue b = facts.original[right];
    return (a.op == STORAGE || a.op == PROTO_STORAGE) && a.op == b.op && a.imm == b.imm
        && ssa_effect_alias(facts, a.a) == ssa_effect_alias(facts, b.a);
}

fn bool ssa_effect_same(SsaCfgEffects* facts, SsaValue a, SsaValue b) @feat(SLJIT) {
    if (a.op != b.op || a.rep != b.rep || a.imm != b.imm || a.target != b.target
        || a.branch_op != b.branch_op) return false;
    if (a.op == LOAD) return ssa_effect_address(facts, a.a, b.a);
    return ssa_effect_alias(facts, a.a) == ssa_effect_alias(facts, b.a)
        && ssa_effect_alias(facts, a.b) == ssa_effect_alias(facts, b.b);
}

// Own property stores preserve the boxed value's exact bits. Typed element
// stores may narrow, round, or clamp, so they cannot use this forwarding rule.
fn int ssa_effect_forward(SsaGraph* g, SsaCfgEffects* facts, SsaValue store, SsaValue load) @feat(SLJIT) {
    if (!g.plan.ssa_commit || store.imm != load.imm
        || !ssa_effect_address(facts, store.a, load.a)) return -1;
    LoopMemoryKind kind = g.plan.memory[load.imm].kind;
    if (kind != FIELD && kind != SHAPE_FIELD) return -1;
    int value = ssa_alias(g, store.b);
    if (value < 0) return -1;
    SsaValue from = g.values[value];
    if (from.rep == load.rep) return value;
    if ((from.op == BOX_I && load.rep == INT32) || (from.op == BOX_F && load.rep == F64)) {
        value = ssa_alias(g, from.a);
        if (value >= 0 && g.values[value].rep == load.rep) return value;
    }
    return -1;
}

fn uint ssa_effect_hash(SsaCfgEffects* facts, SsaValue value) @feat(SLJIT) {
    uint hash = 2166136261;
    bool address = value.op == LOAD || value.op == STORE;
    hash = (hash ^ (uint)(address ? SsaOp.LOAD : value.op)) * 16777619;
    hash = (hash ^ (uint)value.imm) * 16777619;
    hash = (hash ^ (uint)((ulong)value.imm >> 32)) * 16777619;
    int a = ssa_effect_alias(facts, value.a);
    if (address && a >= 0 && (facts.original[a].op == STORAGE || facts.original[a].op == PROTO_STORAGE)) {
        SsaValue storage = facts.original[a];
        hash = (hash ^ (uint)storage.op) * 16777619;
        hash = (hash ^ (uint)storage.imm) * 16777619;
        a = ssa_effect_alias(facts, storage.a);
    }
    hash = (hash ^ (uint)a) * 16777619;
    if (!address) {
        hash = (hash ^ (uint)value.rep) * 16777619;
        hash = (hash ^ (uint)ssa_effect_alias(facts, value.b)) * 16777619;
        hash = (hash ^ (uint)value.target) * 16777619;
        hash = (hash ^ (uint)value.branch_op) * 16777619;
    }
    return hash & (facts.bucket_count - 1);
}

// Global facts are budgeted dynamically. If a large block/value product would
// exceed analysis workspace, keep the same guard-safe CSE within each block;
// there is no fixed graph-size refusal and no unbounded dependency matrix.
fn uint ssa_optimize_cfg(SsaGraph* g) @feat(SLJIT) {
    if (g.value_count == 0 || g.block_count == 0) return 0;
    uint words = (g.value_count + 63) / 64;
    uint buckets = 1;
    while (buckets < g.value_count * 2) buckets *= 2;
    usz fixed_bytes = (usz)g.value_count * SsaValue::size
        + (usz)g.block_count * 2 * SsaAvailable::size
        + (usz)(buckets + g.value_count * 2) * uint::size
        + (usz)g.block_count * 2 * bool::size;
    usz remaining = g.budget.max_bytes > g.storage_bytes ? g.budget.max_bytes - g.storage_bytes : 0;
    uint rows = g.block_count * 2 + 4;
    usz bytes = fixed_bytes + (usz)rows * words * ulong::size;
    bool local_only = bytes > remaining;
    if (local_only) { rows = 4; bytes = fixed_bytes + (usz)rows * words * ulong::size; }
    if (bytes > remaining) return 0;
    char* arena = (char*)g.heap.alloc_func(g.heap.heap_udata, bytes);
    if (arena == null) return 0;
    defer g.heap.free_func(g.heap.heap_udata, arena);
    if (!ssa_charge_work(g, bytes / ulong::size + (usz)g.value_count * 3)) return 0;
    mem::clear(arena, (sz)bytes);
    SsaCfgEffects facts;
    facts.graph = g;
    facts.value_count = g.value_count;
    facts.bucket_count = buckets;
    facts.local_only = local_only;
    char* cursor = arena;
    facts.original = (SsaValue*)cursor; cursor += (usz)g.value_count * SsaValue::size;
    facts.input = (SsaAvailable*)cursor; cursor += (usz)g.block_count * SsaAvailable::size;
    facts.output = (SsaAvailable*)cursor; cursor += (usz)g.block_count * SsaAvailable::size;
    ulong* bits = (ulong*)cursor; cursor += (usz)rows * words * ulong::size;
    facts.work_in = { bits, words, g };
    facts.work_out = { bits + words, words, g };
    facts.candidates = { bits + words * 2, words, g };
    facts.memory = { bits + words * 3, words, g };
    if (!local_only) for (uint b = 0; b < g.block_count; b++) {
        facts.input[b] = { bits + (usz)(4 + b * 2) * words, words, g };
        facts.output[b] = { bits + (usz)(5 + b * 2) * words, words, g };
    }
    facts.buckets = (uint*)cursor; cursor += (usz)buckets * uint::size;
    facts.next = (uint*)cursor; cursor += (usz)g.value_count * uint::size;
    facts.order = (uint*)cursor; cursor += (usz)g.value_count * uint::size;
    facts.reachable = (bool*)cursor; cursor += g.block_count * bool::size;
    facts.boundary = (bool*)cursor;
    for (uint id = 0; id < g.value_count; id++) facts.original[id] = g.values[id];
    for (uint block = 0; block < g.block_count; block++) {
        uint position = 1;
        for (int id = ssa_block_first_value(g, block); id >= 0; id = ssa_next_value(g, id)) {
            facts.order[id] = position++;
        }
    }
    for (uint id = 0; id < g.value_count; id++) {
        SsaEffect effect = ssa_effect(facts.original[id].op);
        if (effect == READ || effect == WRITE) facts.memory.include(id);
        if (effect != SCALAR && effect != LAYOUT && effect != READ && effect != WRITE) continue;
        facts.candidates.include(id);
        uint bucket = ssa_effect_hash(&facts, facts.original[id]);
        facts.next[id] = facts.buckets[bucket];
        facts.buckets[bucket] = id + 1;
    }
    ssa_effect_available(g, &facts);
    if (g.failed) return 0;
    uint rewritten;
    for (uint b = 0; b < g.block_count; b++) {
        if (!facts.reachable[b]) continue;
        facts.work_in.clear();
        if (!local_only) facts.work_in.copy(&facts.input[b]);
        for (int node = ssa_block_first_value(g, b); node >= 0; node = ssa_next_value(g, node)) {
            if (!ssa_charge_work(g, 1)) return 0;
            uint id = (uint)node;
            SsaValue original = facts.original[id];
            SsaEffect effect = ssa_effect(original.op);
            if (effect == SCALAR || effect == LAYOUT || effect == READ) {
                uint bucket = ssa_effect_hash(&facts, original);
                for (uint item = facts.buckets[bucket]; item != 0; item = facts.next[item - 1]) {
                    if (!ssa_charge_work(g, 1)) return 0;
                    uint prior = item - 1;
                    if (prior == id || !facts.work_in.contains(prior) || !ssa_effect_dominates(g, &facts, prior, id)) continue;
                    SsaValue earlier = facts.original[prior];
                    int replacement = -1;
                    if (effect == READ && earlier.op == STORE) {
                        replacement = ssa_effect_forward(g, &facts, earlier, original);
                    } else if (ssa_effect_same(&facts, earlier, original)) {
                        replacement = (int)prior;
                    }
                    if (replacement < 0) continue;
                    if (ssa_has_result(original.op)) {
                        replacement = ssa_alias(g, replacement);
                        if (!ssa_effect_dominates(g, &facts, (uint)replacement, id)) continue;
                        SsaValue* value = &g.values[id];
                        value.op = COPY;
                        value.a = replacement;
                        value.b = 0;
                        value.imm = 0;
                        value.proof_bits = 0;
                        if (g.values[replacement].last < value.last) g.values[replacement].last = value.last;
                    } else {
                        g.values[id].op = NOP;
                        g.values[id].proof_bits = 0;
                    }
                    rewritten++;
                    break;
                }
            }
            ssa_effect_step(&facts, id, &facts.work_in);
        }
    }
    return rewritten;
}
