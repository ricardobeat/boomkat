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

// SSA optimization and register allocation.

// Reuse a load only if its definition dominates this use, and no possibly
// aliased store intervenes. Distinct memory descriptors do not prove disjoint
// objects. Forward graphs use the existing single sweep; a general graph
// needs a fixed point and must ignore unreachable predecessors.
fn void ssa_dominators(SsaGraph* g) @feat(SLJIT) {
    uint count = g.block_count;
    uint words = (count + 31) / 32;
    g.dominator_words = words;
    g.dominators = (uint*)ssa_storage_alloc(g, (usz)count * words, uint::size);
    bool* reachable = (bool*)ssa_storage_alloc(g, count, bool::size);
    uint* mask = (uint*)ssa_storage_alloc(g, words, uint::size);
    if (g.failed) return;
    reachable[0] = true;
    for (uint b = 0; b < count; b++) if (g.blocks[b].external) reachable[b] = true;
    bool changed = true;
    while (changed) {
        if (!ssa_charge_work(g, (usz)count * words + (usz)count * 2)) return;
        changed = false;
        for (uint b = 0; b < count; b++) {
            if (reachable[b]) continue;
            for (uint p = 0; p < g.blocks[b].pred_count; p++) {
                if (!reachable[g.blocks[b].preds[p]]) continue;
                reachable[b] = true; changed = true; break;
            }
        }
    }
    for (uint b = 0; b < count; b++) {
        uint* row = g.dominators + (usz)b * words;
        if (b == 0 || g.blocks[b].external || !reachable[b]) { row[b / 32] |= 1U << (b % 32); }
        else { for (uint d = 0; d < count; d++) if (reachable[d]) row[d / 32] |= 1U << (d % 32); }
    }
    changed = true;
    while (changed) {
        if (!ssa_charge_work(g, (usz)count * words + (usz)count * 2)) return;
        changed = false;
        for (uint b = 1; b < count; b++) {
            if (g.blocks[b].external || !reachable[b]) continue;
            for (uint w = 0; w < words; w++) mask[w] = uint::max;
            for (uint p = 0; p < g.blocks[b].pred_count; p++) {
                uint pred = g.blocks[b].preds[p];
                if (!reachable[pred]) continue;
                for (uint w = 0; w < words; w++) mask[w] &= g.dominators[(usz)pred * words + w];
            }
            mask[b / 32] |= 1U << (b % 32);
            for (uint w = 0; w < words; w++) {
                uint* slot = &g.dominators[(usz)b * words + w];
                if (*slot != mask[w]) { *slot = mask[w]; changed = true; }
            }
        }
    }
}

fn void ssa_cse(SsaGraph* g) @feat(SLJIT) {
    uint count;
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        if (value.op == LOAD) {
            int found = -1;
            for (uint k = 0; k < count; k++) {
                SsaValue prior = g.values[g.cse_value[k]];
                if (g.cse_memory[k] == (int)value.imm && ssa_alias(g, g.cse_index[k]) == ssa_alias(g, value.a) && prior.rep == value.rep
                    && ssa_dominates(g, (uint)prior.block, (uint)value.block)) {
                    found = g.cse_value[k];
                    break;
                }
            }
            if (found >= 0) {
                value.op = COPY;
                value.a = found;
                value.b = 0;
                value.imm = 0;
                if (g.values[found].last < value.last) g.values[found].last = value.last;
            } else if (count < SSA_CSE) {
                g.cse_memory[count] = (int)value.imm;
                g.cse_index[count] = value.a;
                g.cse_value[count] = (int)i;
                count++;
            }
        } else if (value.op == STORE) {
            count = 0;
        }
    }
    // New load aliases can expose common scalar expressions and guards.
    ssa_invariant_cse(g);
}

// Snapshot bindings, identities and guarded ordinary layouts remain valid
// across slot writes. Reuse them only along a dominated path; regions admit
// no operation that changes a layout, prototype or property storage.
fn void ssa_invariant_cse(SsaGraph* g) @feat(SLJIT) {
    int[SSA_CSE] seen;
    uint count;
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        // Scalar guards can be shared in direct in-place regions, where a
        // refusal always resumes the untouched caller and the store is terminal.
        bool constant = value.op == CONST_I || value.op == CONST_F || value.op == CONST_BOXED;
        bool conversion = value.op == TO_INT || value.op == TO_INDEX || value.op == TO_F64;
        bool scalar = g.inplace && g.direct && (constant || conversion || value.op == COMPARE);
        if (!scalar && value.op != BINDING && value.op != CHECKFN && value.op != CHECKPROTO && value.op != RECEIVER && value.op != CHECKSHAPE
            && value.op != STORAGE && value.op != CHECKWRITE && value.op != PROTO_STORAGE) continue;
        bool found;
        for (uint k = 0; k < count; k++) {
            SsaValue prior = g.values[seen[k]];
            if (value.op != prior.op || !ssa_dominates(g, (uint)prior.block, (uint)value.block)) continue;
            if (scalar && prior.rep != value.rep) continue;
            if ((conversion || value.op == COMPARE) && ssa_alias(g, value.a) != ssa_alias(g, prior.a)) continue;
            if (value.op == COMPARE && (value.branch_op != prior.branch_op
                || ssa_alias(g, value.b) != ssa_alias(g, prior.b))) continue;
            if (value.op == CHECKSHAPE) {
                LoopMemorySpec a = g.plan.memory[value.imm];
                LoopMemorySpec b = g.plan.memory[prior.imm];
                if (a.shape != b.shape || a.shape_gen != b.shape_gen) continue;
            } else if (value.op == PROTO_STORAGE) {
                if (!ssa_proto_layout_equal(&g.plan.memory[value.imm], &g.plan.memory[prior.imm])) continue;
            } else if (value.op == CHECKPROTO) {
                if (value.imm != prior.imm || g.plan.memory[value.target].shape != g.plan.memory[prior.target].shape) continue;
            } else if (value.imm != prior.imm) { continue; }
            if ((value.op == CHECKFN || value.op == CHECKPROTO || value.op == CHECKSHAPE || value.op == STORAGE || value.op == CHECKWRITE || value.op == PROTO_STORAGE)
                && ssa_alias(g, value.a) != ssa_alias(g, prior.a)) continue;
            if (scalar || value.op == BINDING || value.op == RECEIVER || value.op == STORAGE || value.op == PROTO_STORAGE) {
                value.op = COPY;
                value.a = seen[k];
                value.b = 0;
                value.imm = 0;
                if (g.values[seen[k]].last < value.last) g.values[seen[k]].last = value.last;
            } else { value.op = NOP; }
            found = true;
            break;
        }
        if (!found && count < seen.len) seen[count++] = (int)i;
    }
}

// A dense element read whose only consumers are numeric conversions cannot
// carry a heap reference or a hole past them.
fn void ssa_numeric_loads(SsaGraph* g) @feat(SLJIT) {
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue v = g.values[i];
        if (v.op != LOAD) continue;
        if (g.plan.memory[v.imm].kind != DENSE && g.plan.memory[v.imm].kind != FIELD
            && g.plan.memory[v.imm].kind != SHAPE_FIELD) continue;
        if (g.plan.memory[v.imm].doubles) {
            g.numeric_load[i] = true;
            continue;
        }
        bool numeric = true;
        for (uint j = 0; j < g.value_count && numeric; j++) {
            SsaValue u = g.values[j];
            if (u.a != (int)i && u.b != (int)i) continue;
            switch (u.op) {
                case TO_F64:
                case TO_INT:
                case TO_INDEX:
                case BOX_F:
                case BOX_I: break;
                default: numeric = false; break;
            }
        }
        g.numeric_load[i] = numeric;
    }
}

// Greedy home assignment over the flat definition order. Loop phis are live
// across the backedge; other values are released at their last use.
fn bool ssa_same_class(SsaRep a, SsaRep b) @feat(SLJIT) => (a == F64) == (b == F64);

fn void ssa_keep(SsaGraph* g, int value, uint stamp) @feat(SLJIT) {
    value = ssa_alias(g, value);
    if (value >= 0 && g.values[value].last < stamp) g.values[value].last = stamp;
}

// Function exits recover the untouched caller frame. Rebuild their liveness
// from optimized operands, so removed loads/checks do not keep receivers and
// aliases in registers. Loop recovery still uses its conservative frame uses.
fn void ssa_function_liveness(SsaGraph* g) @feat(SLJIT) {
    if (!g.inplace) return;
    for (uint i = 0; i < g.value_count; i++) g.values[i].last = g.values[i].def;
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue v = g.values[i];
        switch (v.op) {
            case NOP: case ARG: case PHI: case RECEIVER: case BINDING:
            case CONST_I: case CONST_F: case CONST_BOXED: case COPY: case GOTO: break;
            case JOIN:
                {
                    SsaJoin* join = &g.joins[v.a];
                    for (uint p = 0; p < join.pred_count; p++) {
                        uint last = g.block_last[join.preds[p]];
                        uint stamp = last != 0 ? g.values[last - 1].def + 1 : v.def;
                        ssa_keep(g, join.incoming[p][v.b], stamp);
                    }
                    break;
                }
            case SELECT:
                ssa_keep(g, v.a, v.def);
                ssa_keep(g, v.b, v.def);
                ssa_keep(g, (int)v.imm, v.def);
                break;
            default:
                ssa_keep(g, v.a, v.def);
                ssa_keep(g, v.b, v.def);
                break;
        }
    }
}
fn bool ssa_same_location(SsaValue a, SsaValue b) @feat(SLJIT) {
    if (!ssa_same_class(a.rep, b.rep)) return false;
    if (a.home != 0 || b.home != 0) return a.home != 0 && a.home == b.home;
    return a.spill == b.spill;
}
fn int ssa_gpr_home(
    SsaGraph* g,
    uint slot
) @feat(SLJIT) => slot < g.registers.scratch_homes ? jit::reg_r((int)slot + 4)
    : jit::reg_s((int)(slot - g.registers.scratch_homes + g.registers.saved_first));

// Private inline scratch never owns strings. Keep unknown boxed spills out
// of it; numeric results and boolean joins need no runtime ownership guard.
fn bool ssa_inert_value(SsaGraph* g, int value, uint depth = 0) @feat(SLJIT) {
    if (value < 0 || depth > g.block_count) return false;
    value = ssa_alias(g, value);
    SsaValue v = g.values[value];
    if (v.rep != BOXED || v.op == COMPARE || v.op == BOX_I || v.op == BOX_F || v.op == RECEIVER) return true;
    if (v.op != JOIN) return false;
    SsaJoin* join = &g.joins[v.a];
    for (uint p = 0; p < join.pred_count; p++) {
        if (!ssa_inert_value(g, join.incoming[p][v.b], depth + 1)) return false;
    }
    return true;
}

// Copies are pure aliases of their source: both hold the same value, so the
// allocator coalesces them onto one home and codegen drops the move.
fn int ssa_alias(SsaGraph* g, int value) @feat(SLJIT) {
    if (value < 0) return value;
    if ((uint)value >= g.value_count) { g.failed = true; return 0; }
    int original = value;
    uint guard;
    if (!ssa_charge_work(g, 1)) return original;
    while (g.values[value].op == COPY) {
        if (guard++ == g.value_count || !ssa_charge_work(g, 1)) {
            g.failed = true;
            return original;
        }
        int next = g.values[value].a;
        if (next < 0 || (uint)next >= g.value_count) { g.failed = true; return original; }
        value = next;
    }
    return value;
}
fn void ssa_allocate_linear(SsaGraph* g) @feat(SLJIT) {
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        if ((value.op == CONST_I || value.op == CONST_F) && value.last == value.def) value.op = NOP;
        value.alloc_begin = value.def;
        if (value.op != JOIN) continue;
        SsaJoin* join = &g.joins[value.a];
        // An edge writes the join before the successor's first instruction.
        // Its interval starts at the earliest incoming copy, not at the JOIN
        // node. Inclusive interference keeps every incoming source intact.
        for (uint p = 0; p < join.pred_count; p++) {
            uint last = g.block_last[join.preds[p]];
            if (last == 0) continue;
            uint edge = g.values[last - 1].def;
            if (edge < value.alloc_begin) value.alloc_begin = edge;
        }
    }
    for (uint i = 0; i < g.value_count; i++) {
        if (g.values[i].op != COPY) continue;
        int root = ssa_alias(g, (int)i);
        if (root < 0 || root == (int)i) continue;
        if (g.values[root].last < g.values[i].last) g.values[root].last = g.values[i].last;
    }
    // A cyclic join is live across the backedge, where the next iteration may
    // still be reading its incoming values. Extend every such join over the
    // whole graph so no ordinary value can take a phi home and be clobbered by
    // an edge copy that still has to read it.
    if (g.cyclic) for (uint i = 0; i < g.value_count; i++) {
        if (g.values[i].op == JOIN) g.values[i].last = g.stamp;
    }
    // Loop phis live across the backedge. Ordinary joins use bounded intervals
    // and may reuse homes once an earlier join has died.
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        value.home = 0;
        // A cyclic join lives across a backedge: the value written on this
        // iteration is read by the next. Give it a private home.
        if (value.op != PHI && !(g.cyclic && value.op == JOIN)) continue;
        uint homes = value.rep == F64 ? g.fpr_homes : g.registers.scratch_homes + g.registers.saved_homes;
        for (uint s = 0; s < homes; s++) {
            int home = value.rep == F64 ? 3 + (int)s : ssa_gpr_home(g, s);
            bool used;
            for (uint j = 0; j < i; j++) {
                SsaValue other = g.values[j];
                if (other.home == 0) continue;
                if (ssa_same_class(other.rep, value.rep) && other.home == home) {
                    used = true;
                    break;
                }
            }
            if (!used) {
                value.home = home;
                break;
            }
        }
        if (value.home == 0) value.spill = g.spill_count++;
    }
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        if (value.op == PHI || value.op == COPY || !ssa_has_result(value.op)) continue;
        if (g.cyclic && value.op == JOIN) continue;
        // An in-place direct region can reuse a dying incoming value's register
        // for the join. Its untouched caller frame remains the recovery source.
        if (value.op == JOIN && !g.cyclic && g.inplace && g.direct && g.single_pass) {
            SsaJoin* join = &g.joins[value.a];
            for (uint p = 0; p < join.pred_count && value.home == 0; p++) {
                int source = ssa_alias(g, join.incoming[p][value.b]);
                if (source < 0 || source >= (int)i) continue;
                SsaValue input = g.values[source];
                // No conversion may overwrite the source, and it must not be
                // used after the join. Spills are not candidates here.
                if (input.rep != value.rep || input.home == 0 || input.last > value.def) continue;
                bool free = true;
                for (uint j = 0; j < g.value_count; j++) {
                    if (j == (uint)source || j == i) continue;
                    SsaValue other = g.values[j];
                    if (other.home != input.home || !ssa_same_class(other.rep, value.rep)) continue;
                    if (other.alloc_begin <= value.last && value.alloc_begin <= other.last) { free = false; break; }
                }
                // On another edge this phi may overwrite the coalesced home
                // before a later parallel copy has read that same location.
                for (uint edge = 0; edge < join.pred_count && free; edge++) {
                    int own = ssa_alias(g, join.incoming[edge][value.b]);
                    if (own >= 0 && g.values[own].home == input.home && g.values[own].rep == value.rep) continue;
                    for (uint reg = 0; reg < LOOP_REGS; reg++) {
                        if ((int)reg == value.b || join.phi[reg] < 0) continue;
                        int other = ssa_alias(g, join.incoming[edge][reg]);
                        if (other >= 0 && g.values[other].home == input.home
                            && ssa_same_class(g.values[other].rep, value.rep)) { free = false; break; }
                    }
                }
                if (free) value.home = input.home;
            }
        }
        if (value.home != 0) continue;
        uint homes = value.rep == F64 ? g.fpr_homes : g.registers.scratch_homes + g.registers.saved_homes;
        for (uint s = 0; s < homes; s++) {
            int home  = value.rep == F64 ? 3 + (int)s : ssa_gpr_home(g, s);
            bool free = true;
            for (uint j = 0; j < g.value_count; j++) {
                if (j == i) continue;
                SsaValue other = g.values[j];
                if (other.home != home || !ssa_same_class(other.rep, value.rep)) continue;
                if (other.alloc_begin <= value.last && value.alloc_begin <= other.last) {
                    free = false;
                    break;
                }
            }
            if (free) {
                value.home = home;
                break;
            }
        }
        if (value.home == 0) value.spill = g.spill_count++;
    }
    for (uint i = 0; i < g.value_count; i++) {
        if (g.values[i].op != COPY) continue;
        int root = ssa_alias(g, (int)i);
        if (root < 0 || root == (int)i) continue;
        g.values[i].home = g.values[root].home;
        g.values[i].spill = g.values[root].spill;
    }
}

// General cyclic graphs require CFG liveness; flat definition stamps are not
// live ranges across a backedge. Keep the established acyclic allocation.
fn void ssa_allocate(SsaGraph* g) @feat(SLJIT) {
    if (g.recoverable || (g.cyclic && !$feat(SLJIT_NO_CFG_ALLOCATION))) { ssa_allocate_cfg(g); }
    else { ssa_allocate_linear(g); }
    $if $feat(SLJIT_STATS):
        if (g.cyclic) io::eprintfn("SLJIT cyclic allocation line=%d values=%d joins=%d spills=%d cfg=%d",
            g.cf.get_line(0), g.value_count, g.join_count, g.spill_count, !$feat(SLJIT_NO_CFG_ALLOCATION));
    $endif
}
