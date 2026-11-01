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

const uint SSA_EFFECT_WORDS = (SSA_MAX_VALUES + 63) / 64;
struct SsaAvailable @feat(SLJIT) { ulong[SSA_EFFECT_WORDS] words; }
struct SsaCfgEffects @feat(SLJIT) {
    SsaValue[SSA_MAX_VALUES] original;
    SsaAvailable[SSA_MAX_VALUES] dependencies;
    SsaAvailable[SSA_MAX_VALUES] definition_kill;
    SsaAvailable[SSA_BLOCKS] input;
    SsaAvailable[SSA_BLOCKS] output;
    SsaAvailable[SSA_BLOCKS] iteration_kill;
    SsaAvailable candidates;
    SsaAvailable memory;
    uint reachable;
}

fn void SsaAvailable.include(&self, uint id) @feat(SLJIT) {
    self.words[id >> 6] |= 1UL << (id & 63);
}
fn bool SsaAvailable.contains(&self, uint id) @feat(SLJIT) {
    return (self.words[id >> 6] & (1UL << (id & 63))) != 0;
}
fn void SsaAvailable.merge(&self, SsaAvailable* other) @feat(SLJIT) {
    for (uint w = 0; w < SSA_EFFECT_WORDS; w++) self.words[w] |= other.words[w];
}
fn void SsaAvailable.intersect(&self, SsaAvailable* other) @feat(SLJIT) {
    for (uint w = 0; w < SSA_EFFECT_WORDS; w++) self.words[w] &= other.words[w];
}
fn void SsaAvailable.exclude(&self, SsaAvailable* other) @feat(SLJIT) {
    for (uint w = 0; w < SSA_EFFECT_WORDS; w++) self.words[w] &= ~other.words[w];
}
fn bool SsaAvailable.same(&self, SsaAvailable* other) @feat(SLJIT) {
    for (uint w = 0; w < SSA_EFFECT_WORDS; w++) if (self.words[w] != other.words[w]) return false;
    return true;
}

// Unlike normal operands, JOIN.a/b name a join record and a bytecode register.
// Its incoming values do not belong to the current dynamic iteration yet.
fn void ssa_effect_dependencies(SsaGraph* g, SsaCfgEffects* facts) @feat(SLJIT) {
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue v = facts.original[i];
        SsaAvailable* deps = &facts.dependencies[i];
        // Every execution replaces this static definition's dynamic value.
        deps.include(i);
        if (v.op == JOIN || v.op == PHI) {
            continue;
        }
        switch (v.op) {
            case ARG: case RECEIVER: case BINDING: case CONST_I: case CONST_F:
            case CONST_BOXED: case NOP: case GOTO: break;
            default:
                if (v.a >= 0 && v.a < (int)i) deps.merge(&facts.dependencies[v.a]);
                if (v.b >= 0 && v.b < (int)i) deps.merge(&facts.dependencies[v.b]);
                if (v.op == SELECT && v.imm >= 0 && v.imm < (long)i) deps.merge(&facts.dependencies[v.imm]);
                break;
        }
    }
    for (uint i = 0; i < g.value_count; i++) {
        if (!facts.candidates.contains(i)) continue;
        for (uint definition = 0; definition < g.value_count; definition++) {
            if (facts.dependencies[i].contains(definition)) facts.definition_kill[definition].include(i);
        }
    }
    // JOIN values are emitted by incoming edges, before block_first. Killing
    // here also handles headers whose value IDs were built after a later block.
    for (uint b = 0; b < g.block_count; b++) {
        SsaAvailable definitions;
        for (uint i = 0; i < g.value_count; i++) {
            SsaValue v = facts.original[i];
            if ((v.op == JOIN || v.op == PHI) && v.block == (int)b) definitions.include(i);
        }
        for (uint i = 0; i < g.value_count; i++) {
            for (uint w = 0; w < SSA_EFFECT_WORDS; w++) {
                if ((facts.dependencies[i].words[w] & definitions.words[w]) == 0) continue;
                facts.iteration_kill[b].include(i);
                break;
            }
        }
    }
}

fn void ssa_effect_step(SsaCfgEffects* facts, uint id, SsaAvailable* available) @feat(SLJIT) {
    available.exclude(&facts.definition_kill[id]);
    SsaEffect effect = ssa_effect(facts.original[id].op);
    if (effect == UNKNOWN) { *available = {}; return; }
    if (effect == WRITE) available.exclude(&facts.memory);
    if (facts.candidates.contains(id)) available.include(id);
}

// Facts are reaching expression definitions and reaching store versions. A
// read/store fact survives a join only when that exact version survives EVERY
// reachable predecessor, including backedges. Entry's empty boundary prevents
// a self-supporting loop fact from becoming available on its first iteration.
fn void ssa_effect_available(SsaGraph* g, SsaCfgEffects* facts) @feat(SLJIT) {
    facts.reachable = 1;
    for (uint b = 0; b < g.block_count; b++) {
        if (g.blocks[b].external) facts.reachable |= 1U << b;
    }
    bool changed = true;
    while (changed) {
        changed = false;
        for (uint b = 1; b < g.block_count; b++) {
            if ((facts.reachable & (1U << b)) != 0) continue;
            for (uint p = 0; p < g.blocks[b].pred_count; p++) {
                if ((facts.reachable & (1U << g.blocks[b].preds[p])) == 0) continue;
                facts.reachable |= 1U << b;
                changed = true;
                break;
            }
        }
    }
    for (uint b = 0; b < g.block_count; b++) {
        if (b != 0 && !g.blocks[b].external && (facts.reachable & (1U << b)) != 0) facts.output[b] = facts.candidates;
    }
    changed = true;
    while (changed) {
        changed = false;
        for (uint b = 0; b < g.block_count; b++) {
            if ((facts.reachable & (1U << b)) == 0) continue;
            SsaAvailable incoming;
            // Every external invocation imports fresh interpreter state.
            // Its synthetic predecessor contributes no facts, even when a
            // native backedge also targets this block.
            if (b != 0 && !g.blocks[b].external) {
                incoming = facts.candidates;
                for (uint p = 0; p < g.blocks[b].pred_count; p++) {
                    uint pred = g.blocks[b].preds[p];
                    if ((facts.reachable & (1U << pred)) != 0) incoming.intersect(&facts.output[pred]);
                }
            }
            incoming.exclude(&facts.iteration_kill[b]);
            facts.input[b] = incoming;
            SsaAvailable outgoing = incoming;
            for (int node = ssa_block_first_value(g, b); node >= 0; node = ssa_next_value(g, node)) ssa_effect_step(facts, (uint)node, &outgoing);
            if (!outgoing.same(&facts.output[b])) {
                facts.output[b] = outgoing;
                changed = true;
            }
        }
    }
}

fn bool ssa_effect_dominates(SsaGraph* g, uint prior, uint current) @feat(SLJIT) {
    SsaValue a = g.values[prior];
    SsaValue b = g.values[current];
    return ssa_value_dominates(g, (int)prior, (int)current);
}

// Freeze keys to the analyzed graph. New COPY aliases cannot change the
// dependency relation underneath the fixed-point facts while rewriting.
fn int ssa_effect_alias(SsaCfgEffects* facts, int value) @feat(SLJIT) {
    uint guard;
    while (value >= 0 && guard++ < SSA_MAX_VALUES && facts.original[value].op == COPY) value = facts.original[value].a;
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

// No instruction moves and no store disappears. Failed guards still publish
// their original pre-bytecode frame. Replacing a repeated successful guard is
// safe only while its dominating proof remains available for the same values.
// Frame and edge references keep their IDs; the CFG allocator resolves COPY.
fn void ssa_optimize_cfg(SsaGraph* g) @feat(SLJIT) {
    SsaCfgEffects* facts = (SsaCfgEffects*)g.heap.alloc_func(g.heap.heap_udata, SsaCfgEffects::size);
    if (facts == null) return;
    defer g.heap.free_func(g.heap.heap_udata, facts);
    mem::clear(facts, (sz)SsaCfgEffects::size);
    for (uint i = 0; i < g.value_count; i++) {
        facts.original[i] = g.values[i];
        SsaEffect effect = ssa_effect(g.values[i].op);
        if (effect == SCALAR || effect == LAYOUT || effect == READ || effect == WRITE) facts.candidates.include(i);
        if (effect == READ || effect == WRITE) facts.memory.include(i);
    }
    ssa_effect_dependencies(g, facts);
    ssa_effect_available(g, facts);
    for (uint b = 0; b < g.block_count; b++) {
        if ((facts.reachable & (1U << b)) == 0) continue;
        SsaAvailable available = facts.input[b];
        for (int node = ssa_block_first_value(g, b); node >= 0; node = ssa_next_value(g, node)) {
            uint i = (uint)node;
            // A LOAD (or any other definition) can execute again on a cycle
            // even without a nearby PHI. Its old dependent expressions belong
            // to that earlier execution and must expire before matching.
            available.exclude(&facts.definition_kill[i]);
            SsaValue original = facts.original[i];
            SsaEffect effect = ssa_effect(original.op);
            if (effect == SCALAR || effect == LAYOUT || effect == READ) {
                for (uint prior = 0; prior < g.value_count; prior++) {
                    if (!available.contains(prior) || !ssa_effect_dominates(g, prior, i)) continue;
                    SsaValue earlier = facts.original[prior];
                    int replacement = -1;
                    if (effect == READ && earlier.op == STORE) {
                        replacement = ssa_effect_forward(g, facts, earlier, original);
                    } else if (ssa_effect_same(facts, earlier, original)) {
                        replacement = (int)prior;
                    }
                    if (replacement < 0) continue;
                    if (ssa_has_result(original.op)) {
                        replacement = ssa_alias(g, replacement);
                        if (!ssa_effect_dominates(g, (uint)replacement, i)) continue;
                        SsaValue* value = &g.values[i];
                        value.op = COPY;
                        value.a = replacement;
                        value.b = 0;
                        value.imm = 0;
                        if (g.values[replacement].last < value.last) g.values[replacement].last = value.last;
                    } else { g.values[i].op = NOP; }
                    break;
                }
            }
            ssa_effect_step(facts, i, &available);
        }
    }
}
