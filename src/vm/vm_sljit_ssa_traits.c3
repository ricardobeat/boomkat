module boomkat::vm;

// These domains describe semantic dependencies, not machine register classes.
// A helper unknown to this lowering reads and writes every domain by default.
const uint SSA_DOMAIN_HEAP = 1;
const uint SSA_DOMAIN_LAYOUT = 2;
const uint SSA_DOMAIN_BINDING = 4;
const uint SSA_DOMAIN_FRAME = 8;
const uint SSA_DOMAIN_ALL = 15;

struct SsaOpTraits @feat(SLJIT) {
    uint reads;
    uint writes;
    bool may_deopt;
    bool may_coerce;
    bool may_throw;
    bool may_call;
    bool may_collect;
    bool observable;
    bool terminates;
}

fn bool SsaOpTraits.total(&self) @feat(SLJIT) => self.reads == 0 && self.writes == 0
    && !self.may_deopt && !self.may_coerce && !self.may_throw && !self.may_call
    && !self.may_collect && !self.observable && !self.terminates;

fn bool SsaOpTraits.needs_recovery(&self) @feat(SLJIT) => self.may_deopt
    || self.may_coerce || self.may_throw || self.may_call || self.may_collect;

// Guard obligations belong to the operation even when its result is dead.
// In particular, a boxed conversion may leave to JS coercion, integer math
// guards overflow, and USHR can refuse its unsigned result representation.
fn SsaOpTraits ssa_op_traits(SsaGraph* g, SsaValue v) @feat(SLJIT) {
    switch (v.op) {
        case NOP: case ARG: case PHI: case JOIN: case COPY:
        case CONST_I: case CONST_F: case BOX_I: case BOX_F:
            return {};
        case CONST_BOXED:
            return { .may_deopt = g.inplace };
        case ADD: case SUB: case MUL: case DIV:
            return { .may_deopt = v.rep != F64 && ((v.proof_bits & SSA_PROOF_NO_OVERFLOW) == 0
                || (v.op == MUL && (v.proof_bits & SSA_PROOF_NO_NEGATIVE_ZERO) == 0)) };
        case BAND: case BOR: case BXOR: case SHL: case SHR: case BNOT:
        case NEG:
            return {};
        case COMPARE:
            return { .may_deopt = g.values[v.a].rep == BOXED,
                .may_coerce = g.values[v.a].rep == BOXED };
        case USHR:
            return { .may_deopt = true };
        case SELECT:
            return { .may_deopt = g.inplace && v.rep == BOXED };
        case TO_INT: case TO_INDEX:
            return { .may_deopt = g.values[v.a].rep != INT32 && (v.proof_bits & SSA_PROOF_EXACT_INT32) == 0,
                .may_coerce = g.values[v.a].rep == BOXED };
        case TO_F64:
            return { .may_deopt = g.values[v.a].rep == BOXED,
                .may_coerce = g.values[v.a].rep == BOXED };
        case RECEIVER:
            return { .reads = SSA_DOMAIN_FRAME, .may_deopt = g.inplace };
        case FRESH_BINDING:
            return { .reads = SSA_DOMAIN_BINDING | SSA_DOMAIN_LAYOUT, .may_deopt = true };
        case BINDING:
            return { .reads = SSA_DOMAIN_BINDING, .may_deopt = g.inplace };
        case STORAGE: case PROTO_STORAGE:
        case CHECKFN: case CHECKPROTO: case CHECKSHAPE: case CHECKWRITE:
            return { .reads = SSA_DOMAIN_LAYOUT, .may_deopt = true };
        case ACCESS_ADDRESS: case ACCESS_FIELD: case ACCESS_LOAD:
        case LOAD:
            return { .reads = SSA_DOMAIN_HEAP | SSA_DOMAIN_LAYOUT, .may_deopt = true };
        case ACCESS_STORE: case STORE:
            return { .reads = SSA_DOMAIN_HEAP | SSA_DOMAIN_LAYOUT,
                .writes = SSA_DOMAIN_HEAP | SSA_DOMAIN_BINDING,
                .may_deopt = true, .observable = true };
        case BRANCH: case GOTO: case RETURN: case EXIT:
            return { .may_deopt = true, .terminates = true };
        default:
            // Calls, allocation and future helpers must opt into a narrower
            // contract explicitly. No unrecognized operation is pure.
            return { .reads = SSA_DOMAIN_ALL, .writes = SSA_DOMAIN_ALL,
                .may_deopt = true, .may_coerce = true, .may_throw = true,
                .may_call = true, .may_collect = true, .observable = true };
    }
}

// Only SSA IDs appear here. JOIN/PHI have edge operands handled separately;
// their a/b fields and constants' immediates must never become fake inputs.
fn uint ssa_value_operands(SsaValue v, int[3]* operands) @feat(SLJIT) {
    uint count;
    switch (v.op) {
        case NOP: case ARG: case PHI: case JOIN: case RECEIVER: case BINDING: case FRESH_BINDING:
        case CONST_I: case CONST_F: case CONST_BOXED: case GOTO: case EXIT:
            return 0;
        case COPY: case STORAGE: case PROTO_STORAGE: case ACCESS_FIELD:
        case CHECKFN: case CHECKPROTO: case CHECKSHAPE: case CHECKWRITE:
        case BNOT: case NEG: case TO_INT: case TO_INDEX: case TO_F64:
        case BOX_I: case BOX_F: case LOAD: case ACCESS_LOAD: case RETURN:
            if (v.a >= 0) (*operands)[count++] = v.a;
            return count;
        case SELECT:
            if (v.imm >= 0) (*operands)[count++] = (int)v.imm;
            if (v.a >= 0) (*operands)[count++] = v.a;
            if (v.b >= 0) (*operands)[count++] = v.b;
            return count;
        default:
            if (v.a >= 0) (*operands)[count++] = v.a;
            if (v.b >= 0) (*operands)[count++] = v.b;
            return count;
    }
}
