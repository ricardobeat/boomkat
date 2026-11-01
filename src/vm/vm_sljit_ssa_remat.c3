module boomkat::vm;

// Locationless values have an explicit allocation property. home==0 remains a
// real spill for ordinary values; no spill index is overloaded as a sentinel.
const uint SSA_PROOF_REMATERIALIZE = 16;
fn bool ssa_rematerialized(SsaValue value) @feat(SLJIT) => (value.proof_bits & SSA_PROOF_REMATERIALIZE) != 0;
fn void ssa_rematerialize(SsaGraph* g) @feat(SLJIT) {
    for (uint i = 0; i < g.value_count; i++) {
        if (!ssa_charge_work(g, 1)) return;
        if (g.values[i].op == CONST_I || g.values[i].op == CONST_F) g.values[i].proof_bits |= SSA_PROOF_REMATERIALIZE;
    }
    for (uint i = 0; i < g.value_count; i++) {
        if (!ssa_charge_work(g, 1)) return;
        if (g.values[i].op != COPY) continue;
        int root = ssa_alias(g, (int)i);
        if (root >= 0 && ssa_rematerialized(g.values[root])) g.values[i].proof_bits |= SSA_PROOF_REMATERIALIZE;
    }
}
