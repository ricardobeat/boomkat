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

// Forward body edges form a DAG (the latch owns the only backedge). Reuse a
// load only if its definition dominates this use, and no possibly aliased
// store intervenes. Distinct memory descriptors do not prove disjoint objects.
fn void ssa_cse(SsaGraph* g) @feat(SLJIT) {
    for (uint b = 0; b < g.block_count; b++) {
        uint mask = b == 0 || g.blocks[b].pred_count == 0 ? 0 : uint::max;
        if (b != 0) for (uint p = 0; p < g.blocks[b].pred_count; p++) {
            mask &= g.dominators[g.blocks[b].preds[p]];
        }
        g.dominators[b] = mask | (1U << b);
    }
    uint count;
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        if (value.op == LOAD) {
            int found = -1;
            for (uint k = 0; k < count; k++) {
                SsaValue prior = g.values[g.cse_value[k]];
                if (g.cse_memory[k] == (int)value.imm && g.cse_index[k] == value.a && prior.rep == value.rep
                    && (g.dominators[value.block] & (1U << (uint)prior.block)) != 0) {
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

// Copies are pure aliases of their source: both hold the same value, so the
// allocator coalesces them onto one home and codegen drops the move.
fn int ssa_alias(SsaGraph* g, int value) @feat(SLJIT) {
    uint guard;
    while (value >= 0 && guard++ < SSA_MAX_VALUES && g.values[value].op == COPY) value = g.values[value].a;
    return value;
}
fn void ssa_allocate(SsaGraph* g) @feat(SLJIT) {
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
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
    // Loop phis live across the backedge. Ordinary joins use bounded intervals
    // and may reuse homes once an earlier join has died.
    for (uint i = 0; i < g.value_count; i++) {
        SsaValue* value = &g.values[i];
        value.home = 0;
        if (value.op != PHI) continue;
        uint homes = value.rep == F64 ? SSA_HOMES : g.registers.scratch_homes + g.registers.saved_homes;
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
        if (value.op == PHI || value.op == COPY) continue;
        uint homes = value.rep == F64 ? SSA_HOMES : g.registers.scratch_homes + g.registers.saved_homes;
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