module boomkat::vm;

// Edge conversions execute after an ordinary fallthrough instruction commits,
// but before a branch transfers control. A failed conversion must preserve
// that phase, particularly when the completed instruction called JavaScript.
struct SsaEdgeState @feat(SLJIT) {
    SsaFrameId frame;
    uint pc;
}

fn bool ssa_edge_states(SsaGraph* g) @feat(SLJIT) {
    if (!ssa_charge_work(g, (usz)g.block_count * g.reg_count * 2 + g.block_count)) return false;
    int* projected = ssa_storage_alloc(g, g.reg_count, int::size);
    if (projected == null) return false;
    for (uint block = 0; block < g.block_count; block++) {
        SsaBlock* out = &g.blocks[block];
        uint pc = out.branch_pc != uint::max ? out.branch_pc : out.end;
        out.edge_state = { ssa_frame_at_pc(g, pc), pc };
        out.edge_ready = true;
        if (!g.recoverable || out.returns || out.branch_pc != uint::max) continue;
        uint next = ssa_decoded_view(g, out.end).next_pc;
        SsaFrameId frame = ssa_frame_after_pc(g, out.end);
        if (frame == SSA_NO_FRAME) {
            // block_exit holds source IDs before any successor JOIN is written.
            // Filter dead boxed borrows: retention by compiler metadata alone
            // does not make them runtime-owned after a collecting helper.
            ssa_frame_restore(g, g.block_exit[block], projected, g.reg_count);
            for (uint reg = 0; reg < g.reg_count; reg++) {
                if (!ssa_pc_live(g, next, reg)) projected[reg] = -1;
            }
            frame = ssa_frame_capture(g, next, projected, g.reg_count);
            if (g.failed) return false;
        }
        out.edge_state = { frame, next };
    }
    return true;
}

fn SsaEdgeState ssa_edge_state(SsaGraph* g, uint pred, uint succ) @feat(SLJIT) {
    if (pred >= g.block_count) {
        uint pc = succ < g.block_count ? g.blocks[succ].begin : g.plan.begin;
        return { ssa_frame_at_pc(g, pc), pc };
    }
    assert(g.blocks[pred].edge_ready);
    return g.blocks[pred].edge_state;
}
