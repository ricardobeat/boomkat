module boomkat::vm;

// SSA identity is independent of execution order. Motion changes this linked
// block schedule, never value IDs used by operands, phis or immutable frames.
fn void ssa_schedule_unlink(SsaGraph* g, int id) @feat(SLJIT) {
    SsaValue* value = &g.values[id];
    int block = value.schedule_block;
    if (block < 0) return;
    if (value.schedule_prev < 0) { g.blocks[block].first_value = value.schedule_next; }
    else { g.values[value.schedule_prev].schedule_next = value.schedule_next; }
    if (value.schedule_next < 0) { g.blocks[block].last_value = value.schedule_prev; }
    else { g.values[value.schedule_next].schedule_prev = value.schedule_prev; }
    value.schedule_prev = -1;
    value.schedule_next = -1;
    value.schedule_block = -1;
}
fn void ssa_schedule_append(SsaGraph* g, uint block, int id) @feat(SLJIT) {
    ssa_schedule_unlink(g, id);
    SsaValue* value = &g.values[id];
    int prior = g.blocks[block].last_value;
    value.block = (int)block;
    value.schedule_block = (int)block;
    value.schedule_prev = prior;
    value.schedule_next = -1;
    if (prior >= 0) { g.values[prior].schedule_next = id; }
    else { g.blocks[block].first_value = id; }
    g.blocks[block].last_value = id;
}
fn void ssa_schedule_init(SsaGraph* g) @feat(SLJIT) {
    for (uint i = 0; i < g.value_count; i++) {
        g.values[i].schedule_prev = -1;
        g.values[i].schedule_next = -1;
        g.values[i].schedule_block = -1;
    }
    for (uint b = 0; b < g.block_count; b++) {
        g.blocks[b].first_value = -1;
        g.blocks[b].last_value = -1;
        for (uint i = g.block_first[b]; i < g.block_last[b]; i++) ssa_schedule_append(g, b, (int)i);
    }
    g.schedule_ready = true;
}
fn int ssa_block_first_value(SsaGraph* g, uint block) @feat(SLJIT) => g.blocks[block].first_value;
fn int ssa_block_last_value(SsaGraph* g, uint block) @feat(SLJIT) => g.blocks[block].last_value;
fn int ssa_next_value(SsaGraph* g, int id) @feat(SLJIT) => g.values[id].schedule_next;
fn int ssa_previous_value(SsaGraph* g, int id) @feat(SLJIT) => g.values[id].schedule_prev;

fn bool ssa_insert_before(SsaGraph* g, int before, int id) @feat(SLJIT) {
    if (id < 0 || before < 0 || id >= (int)g.value_count || before >= (int)g.value_count
        || g.values[before].schedule_block < 0) return false;
    if (id == before) return true;
    ssa_schedule_unlink(g, id);
    SsaValue* value = &g.values[id];
    SsaValue* next = &g.values[before];
    value.block = next.block;
    value.schedule_block = next.schedule_block;
    value.schedule_prev = next.schedule_prev;
    value.schedule_next = before;
    if (next.schedule_prev >= 0) { g.values[next.schedule_prev].schedule_next = id; }
    else { g.blocks[next.schedule_block].first_value = id; }
    next.schedule_prev = id;
    return true;
}
fn bool ssa_move_before(SsaGraph* g, int id, int before) @feat(SLJIT) => ssa_insert_before(g, before, id);
fn uint ssa_pred_count(SsaGraph* g, uint block) @feat(SLJIT) => g.blocks[block].pred_count;
fn uint ssa_pred(SsaGraph* g, uint block, uint index) @feat(SLJIT) => g.blocks[block].preds[index];
fn uint ssa_succ_count(SsaGraph* g, uint block) @feat(SLJIT) {
    SsaBlock b = g.blocks[block];
    return (b.succ0 < g.block_count ? 1U : 0U)
        + (b.succ1 < g.block_count && b.succ1 != b.succ0 ? 1U : 0U);
}
fn uint ssa_succ(SsaGraph* g, uint block, uint index) @feat(SLJIT) {
    SsaBlock b = g.blocks[block];
    if (b.succ0 < g.block_count) return index == 0 ? b.succ0 : b.succ1;
    return b.succ1;
}
fn bool ssa_dominates(SsaGraph* g, uint definition_block, uint use_block) @feat(SLJIT) {
    return (g.dominators[(usz)use_block * g.dominator_words + definition_block / 32] & (1U << (definition_block % 32))) != 0;
}
fn bool ssa_value_dominates(SsaGraph* g, int definition, int use) @feat(SLJIT) {
    if (definition < 0 || use < 0) return false;
    SsaValue a = g.values[definition];
    SsaValue b = g.values[use];
    if (a.op == ARG) return true; // imported before every external dispatch
    if (a.block != b.block) return ssa_dominates(g, (uint)a.block, (uint)b.block);
    if (a.op == ARG || a.op == PHI || a.op == JOIN) return true;
    for (int id = ssa_block_first_value(g, (uint)b.block); id >= 0; id = ssa_next_value(g, id)) {
        if (!ssa_charge_work(g, 1)) return false;
        if (id == definition) return true;
        if (id == use) return false;
    }
    return false;
}
