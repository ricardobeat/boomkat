module boomkat::vm;

// A header JOIN that only carries itself on latches is the same immutable
// scalar imported by PH. Never infer this from runtime samples or slot names.
fn int ssa_licm_input(SsaGraph* g, int id, uint ph, uint header) @feat(SLJIT) {
    id = ssa_alias(g, id);
    if (id < 0) return id;
    SsaValue value = g.values[id];
    if (value.op == ARG || (uint)value.block == ph || ssa_dominates(g, (uint)value.block, ph)) return id;
    if (value.op != JOIN || (uint)value.block != header) return -1;
    SsaJoin* join = &g.joins[value.a];
    int imported = -1;
    for (uint p = 0; p < join.pred_count; p++) {
        if (!ssa_charge_work(g, 1)) return -1;
        if (join.preds[p] == ph) imported = ssa_alias(g, join.incoming[p][value.b]);
    }
    if (imported < 0 || g.values[imported].rep != value.rep) return -1;
    for (uint p = 0; p < join.pred_count; p++) {
        if (!ssa_charge_work(g, 1)) return -1;
        int incoming = ssa_alias(g, join.incoming[p][value.b]);
        if (incoming != id && incoming != imported) return -1;
    }
    return imported;
}

fn uint ssa_licm(SsaGraph* g) @feat(SLJIT) {
    if (!g.recoverable || !g.schedule_ready) return 0;
    bool* member = ssa_storage_alloc(g, g.block_count, bool::size);
    if (g.failed) return 0;
    uint moved;
    for (uint ph = 0; ph < g.block_count; ph++) {
        if (!g.blocks[ph].preheader) continue;
        uint h = g.blocks[ph].loop_header;
        foreach (&slot : member[0:g.block_count]) *slot = false;
        member[h] = true;
        for (uint p = 0; p < g.blocks[h].pred_count; p++) {
            uint pred = g.blocks[h].preds[p];
            if (pred != ph && ssa_dominates(g, h, pred)) member[pred] = true;
        }
        bool changed = true;
        while (changed && !g.failed) {
            changed = false;
            for (uint b = 0; b < g.block_count; b++) {
                if (!ssa_charge_work(g, (usz)g.blocks[b].pred_count + 1)) return moved;
                if (!member[b] || b == h) continue;
                for (uint p = 0; p < g.blocks[b].pred_count; p++) {
                    uint pred = g.blocks[b].preds[p];
                    if (pred == ph || member[pred]) continue;
                    member[pred] = true;
                    changed = true;
                }
            }
        }
        changed = true;
        while (changed && !g.failed) {
            changed = false;
            for (uint b = 0; b < g.block_count; b++) {
                if (!member[b] || !ssa_dominates(g, ph, b)) continue;
                for (int id = ssa_block_first_value(g, b); id >= 0;) {
                    int next = ssa_next_value(g, id);
                    if (!ssa_charge_work(g, 4)) return moved;
                    SsaValue value = g.values[id];
                    bool candidate;
                    switch (value.op) {
                        case CONST_I: case CONST_F: case NEG: case BNOT:
                        case BAND: case BOR: case BXOR: case SHL: case SHR:
                        case ADD: case SUB: case MUL: case DIV: case TO_F64:
                            candidate = ssa_op_traits(g, value).total();
                        default: break;
                    }
                    int a = value.a;
                    int bv = value.b;
                    if (candidate) {
                        int[3] operands;
                        uint count = ssa_value_operands(value, &operands);
                        for (uint i = 0; i < count; i++) {
                            int input = ssa_licm_input(g, operands[i], ph, h);
                            if (input < 0) { candidate = false; break; }
                            if (value.a == operands[i]) a = input;
                            if (value.b == operands[i]) bv = input;
                        }
                    }
                    if (candidate) {
                        g.values[id].a = a;
                        g.values[id].b = bv;
                        g.values[id].dst_reg = -1; // do not advance a VM slot before its bytecode
                        g.values[id].pc = g.blocks[ph].begin;
                        g.values[id].before_frame = g.blocks[ph].edge_state.frame;
                        g.values[id].after_frame = SSA_NO_FRAME;
                        g.values[id].proof_bits = 0;
                        ssa_schedule_append(g, ph, id);
                        moved++;
                        changed = true;
                    }
                    id = next;
                }
            }
        }
    }
    return moved;
}

// Stamps are only conservative emitter hints; CFG allocation owns actual
// liveness. Motion must not leave definition-order hints from stable IDs.
fn void ssa_schedule_uses(SsaGraph* g) @feat(SLJIT) {
    uint stamp = 1;
    for (uint i = 0; i < g.value_count; i++) { g.values[i].def = 0; g.values[i].last = 0; }
    for (uint b = 0; b < g.block_count; b++) {
        for (int id = ssa_block_first_value(g, b); id >= 0; id = ssa_next_value(g, id)) {
            if (!ssa_charge_work(g, 1)) return;
            g.values[id].def = stamp;
            g.values[id].last = stamp++;
        }
    }
    g.stamp = stamp;
    for (uint i = 0; i < g.value_count; i++) {
        if (!ssa_charge_work(g, 4)) return;
        SsaValue value = g.values[i];
        int[3] inputs;
        uint count = ssa_value_operands(value, &inputs);
        for (uint j = 0; j < count; j++) {
            int input = ssa_alias(g, inputs[j]);
            if (input < 0) continue;
            ssa_keep(g, input, g.values[input].block == value.block ? value.def : stamp);
        }
        if (value.op == JOIN) {
            SsaJoin* join = &g.joins[value.a];
            if (!ssa_charge_work(g, (usz)join.pred_count + 1)) return;
            for (uint p = 0; p < join.pred_count; p++) ssa_keep(g, join.incoming[p][value.b], stamp);
            if (join.entry) ssa_keep(g, join.entry_incoming[value.b], stamp);
        }
    }
    for (uint f = 0; f < g.frame_count; f++) {
        SsaFrameEntry[] entries = ssa_frame_entries(g, f);
        if (!ssa_charge_work(g, entries.len + 2)) return;
        foreach (entry : entries) ssa_keep(g, entry.value, stamp);
        ssa_keep(g, g.frame_table[f].callee_value, stamp);
        ssa_keep(g, g.frame_table[f].receiver_value, stamp);
    }
}
