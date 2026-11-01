module boomkat::vm;

import boomkat::compiler;
import std::core::mem;

// Entry normalization runs before renaming, while block-indexed tables contain
// CFG metadata only. Arena growth retains old allocations until graph disposal.
fn bool ssa_reserve_blocks(SsaGraph* g, uint needed) @feat(SLJIT) {
    if (needed <= g.block_capacity) return true;
    if (needed > g.budget.max_blocks) { g.failed = true; return false; }
    uint old = g.block_capacity;
    uint cap = old;
    g.blocks = ssa_storage_grow(g, g.blocks, g.block_count, &cap, needed, g.budget.max_blocks, SsaBlock::size);
    cap = old;
    g.joins = ssa_storage_grow(g, g.joins, g.join_count, &cap, needed, g.budget.max_blocks, SsaJoin::size);
    cap = old;
    g.cyclic_live = ssa_storage_grow(g, g.cyclic_live, old, &cap, needed, g.budget.max_blocks, compiler::RegSet::size);
    uint* words = ssa_storage_alloc(g, (usz)(cap - old) * g.reg_words, uint::size);
    if (g.failed) return false;
    for (uint b = old; b < cap; b++) g.cyclic_live[b] = { .words = words + (usz)(b - old) * g.reg_words, .word_count = g.reg_words };
    g.block_capacity = cap;
    cap = old;
    g.cyclic_order = ssa_storage_grow(g, g.cyclic_order, 0, &cap, needed, g.budget.max_blocks, uint::size);
    cap = old;
    g.block_built = ssa_storage_grow(g, g.block_built, 0, &cap, needed, g.budget.max_blocks, bool::size);
    cap = old;
    g.block_first = ssa_storage_grow(g, g.block_first, 0, &cap, needed, g.budget.max_blocks, uint::size);
    cap = old;
    g.block_last = ssa_storage_grow(g, g.block_last, 0, &cap, needed, g.budget.max_blocks, uint::size);
    return !g.failed;
}

// E imports the published VM state. PH merges that import with ordinary
// preloop edges; latches still enter H directly. Hoists in PH therefore execute
// once per native entry. An unrelated mid-loop external entry remains a real
// root and prevents dominance-based motion through that path.
fn bool ssa_normalize_entries(SsaGraph* g) @feat(SLJIT) {
    uint count = g.block_count;
    bool* external = ssa_storage_alloc(g, count, bool::size);
    bool* header = ssa_storage_alloc(g, count, bool::size);
    uint* preheader = ssa_storage_alloc(g, count, uint::size);
    if (g.failed) return false;
    uint imports;
    for (uint b = 0; b < count; b++) {
        external[b] = g.blocks[b].external;
        if (external[b]) imports++;
        g.blocks[b].external = false;
        preheader[b] = SSA_NO_BLOCK;
    }
    // Semantic dominance identifies natural latches before OSR roots split
    // native dominance. This query is never used as a proof for motion.
    g.recoverable = false;
    ssa_dominators(g);
    g.recoverable = true;
    if (g.failed) return false;
    uint headers;
    for (uint h = 0; h < count; h++) {
        for (uint p = 0; p < g.blocks[h].pred_count; p++) {
            if (!ssa_charge_work(g, 1)) return false;
            if (ssa_dominates(g, h, g.blocks[h].preds[p])) { header[h] = true; break; }
        }
        if (header[h]) headers++;
    }
    if (!ssa_charge_work(g, (usz)(count + imports + headers) * g.reg_words)) return false;
    if (!ssa_reserve_blocks(g, count + imports + headers)) return false;
    for (uint h = 0; h < count; h++) {
        if (!header[h]) continue;
        uint ph = g.block_count++;
        preheader[h] = ph;
        g.blocks[ph] = { .begin = g.blocks[h].begin, .end = g.blocks[h].begin,
            .succ0 = h, .succ1 = SSA_NO_BLOCK, .branch_pc = uint::max,
            .synthetic = true, .preheader = true, .loop_header = h };
        g.cyclic_live[ph].copy_from(&g.cyclic_live[h]);
        for (uint p = 0; p < count; p++) {
            if (!ssa_charge_work(g, 1)) return false;
            if (ssa_dominates(g, h, p)) continue;
            if (g.blocks[p].succ0 == h) g.blocks[p].succ0 = ph;
            if (g.blocks[p].succ1 == h) g.blocks[p].succ1 = ph;
        }
    }
    for (uint h = 0; h < count; h++) {
        if (!external[h]) continue;
        uint entry = g.block_count++;
        uint target = preheader[h] == SSA_NO_BLOCK ? h : preheader[h];
        g.blocks[entry] = { .begin = g.blocks[h].begin, .end = g.blocks[h].begin,
            .succ0 = target, .succ1 = SSA_NO_BLOCK, .branch_pc = uint::max,
            .external = true, .synthetic = true, .loop_header = h };
        g.cyclic_live[entry].copy_from(&g.cyclic_live[h]);
    }
    return ssa_collect_predecessors(g);
}
