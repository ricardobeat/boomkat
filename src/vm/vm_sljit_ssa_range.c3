module boomkat::vm;

// Proofs describe the operation at its current schedule position. Rewrites and
// motion clear them; range analysis runs after motion and before allocation.
const uint SSA_PROOF_NO_OVERFLOW = 1;
const uint SSA_PROOF_NO_NEGATIVE_ZERO = 2;
const uint SSA_PROOF_EXACT_INT32 = 4;
const uint SSA_PROOF_INDEX_BOUNDS = 8;

struct SsaRange @feat(SLJIT) {
    bool number;
    bool integral;
    bool may_nan;
    bool may_infinite;
    bool may_negative_zero;
    long lower;
    long upper;
}
fn SsaRange ssa_range_top(SsaRep rep) @feat(SLJIT) {
    if (rep == INT32) return { .number = true, .integral = true, .lower = -2147483648L, .upper = 2147483647L };
    return { .number = rep == F64, .may_nan = true, .may_infinite = true, .may_negative_zero = true,
        .lower = -2147483648L, .upper = 2147483647L };
}
fn SsaRange ssa_range_integer(long lower, long upper) @feat(SLJIT) {
    return { .number = true, .integral = true, .lower = lower, .upper = upper };
}
fn bool SsaRange.exact_i32(&self) @feat(SLJIT) => self.number && self.integral
    && !self.may_nan && !self.may_infinite && !self.may_negative_zero
    && self.lower >= -2147483648L && self.upper <= 2147483647L;
fn bool SsaRange.same(&self, SsaRange other) @feat(SLJIT) => self.number == other.number
    && self.integral == other.integral && self.may_nan == other.may_nan
    && self.may_infinite == other.may_infinite && self.may_negative_zero == other.may_negative_zero
    && self.lower == other.lower && self.upper == other.upper;
fn SsaRange ssa_range_union(SsaRange a, SsaRange b) @feat(SLJIT) {
    a.number &= b.number;
    a.integral &= b.integral;
    a.may_nan |= b.may_nan;
    a.may_infinite |= b.may_infinite;
    a.may_negative_zero |= b.may_negative_zero;
    if (b.lower < a.lower) a.lower = b.lower;
    if (b.upper > a.upper) a.upper = b.upper;
    return a;
}
fn SsaRange ssa_range_input(SsaGraph* g, SsaRange* facts, int id) @feat(SLJIT) {
    id = ssa_alias(g, id);
    return id < 0 ? ssa_range_top(BOXED) : facts[id];
}
fn SsaRange ssa_range_transfer(SsaGraph* g, SsaRange* facts, uint id) @feat(SLJIT) {
    SsaValue v = g.values[id];
    SsaRange top = ssa_range_top(v.rep);
    if (v.op == CONST_I) return ssa_range_integer(v.imm, v.imm);
    if (v.op == CONST_F) {
        ulong bits = (ulong)v.imm;
        double number = bitcast(bits, double);
        top.may_nan = (bits & 0x7ff0000000000000UL) == 0x7ff0000000000000UL && (bits & 0xfffffffffffffUL) != 0;
        top.may_infinite = (bits & 0x7fffffffffffffffUL) == 0x7ff0000000000000UL;
        top.may_negative_zero = bits == 0x8000000000000000UL;
        if (!top.may_nan && !top.may_infinite && number >= -2147483648.0 && number <= 2147483647.0
            && number == (double)(long)number) {
            top.integral = true; top.lower = (long)number; top.upper = (long)number;
        }
        return top;
    }
    if (v.op == COPY) return ssa_range_input(g, facts, v.a);
    if (v.op == JOIN) {
        SsaJoin* join = &g.joins[v.a];
        SsaRange result;
        bool first = true;
        for (uint p = 0; p < join.pred_count; p++) {
            if (!ssa_charge_work(g, 1)) return top;
            SsaRange input = ssa_range_input(g, facts, join.incoming[p][v.b]);
            result = first ? input : ssa_range_union(result, input);
            first = false;
        }
        if (join.entry) {
            SsaRange input = ssa_range_input(g, facts, join.entry_incoming[v.b]);
            result = first ? input : ssa_range_union(result, input);
            first = false;
        }
        // An import conversion proves its representation, not a sampled value.
        if (first || !result.number || (v.rep == INT32 && !result.exact_i32())) return top;
        return result;
    }
    switch (v.op) {
        case TO_F64: case TO_INT: case TO_INDEX: case BAND: case USHR:
        case ADD: case SUB: case MUL: break;
        default: return top;
    }
    SsaRange a = ssa_range_input(g, facts, v.a);
    SsaRange b = v.b < 0 ? ssa_range_integer(v.imm, v.imm) : ssa_range_input(g, facts, v.b);
    if (v.op == TO_F64 && a.number) return a;
    if ((v.op == TO_INT || v.op == TO_INDEX) && a.exact_i32()) return a;
    if (v.op == BAND && v.b < 0 && v.imm >= 0 && v.imm <= 2147483647L) return ssa_range_integer(0, v.imm);
    if (v.op == USHR && v.b < 0 && (v.imm & 31) != 0) return ssa_range_integer(0, (long)(uint::max >> (uint)(v.imm & 31)));
    if ((v.op != ADD && v.op != SUB && v.op != MUL) || !a.exact_i32() || !b.exact_i32()) return top;
    long lower;
    long upper;
    bool minus_zero;
    if (v.op == ADD) { lower = a.lower + b.lower; upper = a.upper + b.upper; }
    else if (v.op == SUB) { lower = a.lower - b.upper; upper = a.upper - b.lower; }
    else {
        long[4] products = { a.lower * b.lower, a.lower * b.upper, a.upper * b.lower, a.upper * b.upper };
        lower = products[0]; upper = products[0];
        foreach (product : products) { if (product < lower) lower = product; if (product > upper) upper = product; }
        minus_zero = (a.lower <= 0 && a.upper >= 0 && b.lower < 0)
            || (b.lower <= 0 && b.upper >= 0 && a.lower < 0);
    }
    if (lower < -2147483648L || upper > 2147483647L) return top;
    SsaRange result = ssa_range_integer(lower, upper);
    result.may_negative_zero = v.rep == F64 && minus_zero;
    return result;
}

// A successful earlier address check proves a live length bound. Follow only
// unique predecessor chains, with explicit dominance and no mutation/helper.
// Class/storage guards remain on the consumer; no address or sampled length
// survives a call, and no CFG join is assumed to inherit a proof.
fn bool ssa_bounds_proved(SsaGraph* g, SsaRange* facts, uint id) @feat(SLJIT) {
    SsaValue v = g.values[id];
    SsaRange wanted = ssa_range_input(g, facts, v.b);
    if (!wanted.exact_i32() || wanted.lower < 0) return false;
    int receiver = ssa_alias(g, v.a);
    uint block = (uint)v.block;
    int node = ssa_previous_value(g, (int)id);
    uint traversed;
    while (traversed++ <= g.block_count) {
        for (; node >= 0; node = ssa_previous_value(g, node)) {
            if (!ssa_charge_work(g, 1)) return false;
            SsaValue previous = g.values[node];
            SsaOpTraits traits = ssa_op_traits(g, previous);
            if (traits.writes != 0 || traits.may_call || traits.may_collect || traits.may_coerce) return false;
            if (previous.op != ACCESS_ADDRESS || (previous.imm & 255) != (v.imm & 255)
                || ssa_alias(g, previous.a) != receiver) continue;
            SsaRange checked = ssa_range_input(g, facts, previous.b);
            if (checked.exact_i32() && checked.lower >= wanted.upper
                && ssa_value_dominates(g, node, (int)id)) return true;
        }
        if (!ssa_charge_work(g, 1)) return false;
        if (g.blocks[block].external || g.blocks[block].pred_count != 1) return false;
        block = g.blocks[block].preds[0];
        if (block == (uint)v.block) return false;
        node = ssa_block_last_value(g, block);
    }
    return false;
}

fn uint ssa_ranges(SsaGraph* g) @feat(SLJIT) {
    SsaRange* facts = ssa_storage_alloc(g, g.value_count, SsaRange::size);
    if (g.failed) return 0;
    if (!ssa_charge_work(g, g.value_count)) return 0;
    for (uint i = 0; i < g.value_count; i++) {
        // Re-running this pass after a transform rebuilds every local proof.
        g.values[i].proof_bits &= ~(SSA_PROOF_NO_OVERFLOW | SSA_PROOF_NO_NEGATIVE_ZERO
            | SSA_PROOF_EXACT_INT32 | SSA_PROOF_INDEX_BOUNDS);
        facts[i] = ssa_range_top(g.values[i].rep);
    }
    bool changed = true;
    // Start at representation top and narrow from all incoming edges. Cyclic
    // imports remain full range; no iteration is inferred from entry samples.
    // The common work budget bounds convergence and refuses an unfinished
    // analysis, rather than publishing proofs from a fixed number of rounds.
    while (changed && !g.failed) {
        changed = false;
        for (uint i = 0; i < g.value_count; i++) {
            if (!ssa_charge_work(g, 4)) return 0;
            SsaRange next = ssa_range_transfer(g, facts, i);
            if (!facts[i].same(next)) { facts[i] = next; changed = true; }
        }
    }
    uint proofs;
    for (uint i = 0; i < g.value_count; i++) {
        if (!ssa_charge_work(g, 4)) return 0;
        SsaValue* v = &g.values[i];
        SsaRange a = ssa_range_top(BOXED);
        SsaRange b = ssa_range_top(BOXED);
        if (v.op == TO_INDEX || v.op == TO_INT || v.op == ADD || v.op == SUB || v.op == MUL) {
            a = ssa_range_input(g, facts, v.a);
            b = v.b < 0 ? ssa_range_integer(v.imm, v.imm) : ssa_range_input(g, facts, v.b);
        }
        if (v.op == TO_INDEX || v.op == TO_INT) {
            if (g.values[v.a].rep == F64 && a.exact_i32()) v.proof_bits |= SSA_PROOF_EXACT_INT32;
        }
        if (v.rep == INT32 && (v.op == ADD || v.op == SUB || v.op == MUL) && a.exact_i32() && b.exact_i32()) {
            // Compute mathematical endpoints from the operands, independently
            // of the successful result representation. Its existing overflow
            // guard must never become a proof of that guard's absence.
            long lo;
            long hi;
            if (v.op == ADD) { lo = a.lower + b.lower; hi = a.upper + b.upper; }
            else if (v.op == SUB) { lo = a.lower - b.upper; hi = a.upper - b.lower; }
            else {
                long[4] products = { a.lower * b.lower, a.lower * b.upper, a.upper * b.lower, a.upper * b.upper };
                lo = products[0]; hi = products[0];
                foreach (product : products) { if (product < lo) lo = product; if (product > hi) hi = product; }
            }
            if (lo >= -2147483648L && hi <= 2147483647L) v.proof_bits |= SSA_PROOF_NO_OVERFLOW;
            if (v.op == MUL && !((a.lower <= 0 && a.upper >= 0 && b.lower < 0)
                || (b.lower <= 0 && b.upper >= 0 && a.lower < 0))) v.proof_bits |= SSA_PROOF_NO_NEGATIVE_ZERO;
        }
        if (v.op == ACCESS_ADDRESS && ssa_bounds_proved(g, facts, i)) v.proof_bits |= SSA_PROOF_INDEX_BOUNDS;
        if (v.proof_bits != 0) proofs++;
    }
    return proofs;
}
