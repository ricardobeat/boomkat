module boomkat::vm;

import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::env;
import boomkat::jit;
import std::io;
import std::core::mem;

const uint FUNCTION_OPS        = 512;
const uint FUNCTION_BAIL       = uint::max;
const uint FUNCTION_MIN_SPAN   = 16;
const uint FUNCTION_CAPTURES   = 8;
const uint FUNCTION_REGION_OPS = 128;
// Callee bodies nested inside one another each own a register window in the
// run block.
const uint INLINE_DEPTH = 4;
// Each invocation owns its budget; generated code never keeps a pointer after
// return. Stop before the final charged edge so the interpreter executes the
// ordinary GC/interrupt safepoint with fully published register state.
struct FunctionRun {
    void* entry;
    long budget;
    FunctionTypedCache[2] typed;
    double[32 * INLINE_DEPTH] inline_values;
}
alias FunctionNative = fn uint(TVal* regs, ColdCtx* cold, FunctionRun* run);

// VM registers own every published value. Calls, allocation and exceptional
// operations return to the interpreter; native backedges consume a bounded
// invocation budget before returning to an interpreter safepoint.
struct FunctionPlan @feat(SLJIT) {
    FunctionNative native;
    uint begin;
    uint count;
    uint min_span;
    void** entries;
    char* short_runs;
    uint capture_writes;
    char[LOOP_REGS] cache;
    uint heap_regs;
    char[4] cached_regs;
    uint cache_count;
    uint[32] shapes;
    uint[32] generations;
    uint shape_count;
    uint shape_clock;
    uint shape_epoch;
    bool receiver;
    usz code_bytes;
    ulong typed_reads @if($feat(SLJIT_STATS));
    ulong typed_writes @if($feat(SLJIT_STATS));
    ulong typed_lengths @if($feat(SLJIT_STATS));
    ulong flow_ops @if($feat(SLJIT_STATS));
    ulong math_calls @if($feat(SLJIT_STATS));
    ulong inline_calls @if($feat(SLJIT_STATS));
    ulong bail_calls @if($feat(SLJIT_STATS));
    ulong bail_ops @if($feat(SLJIT_STATS));
    ulong general_inlines @if($feat(SLJIT_STATS));
    ulong[512] exit_pcs @if($feat(SLJIT_STATS));
    ulong hits @if($feat(SLJIT_STATS));
    ulong completed @if($feat(SLJIT_STATS));
    ulong stalled @if($feat(SLJIT_STATS));
    ulong backedges @if($feat(SLJIT_STATS));
    ulong budget_exits @if($feat(SLJIT_STATS));
}
struct FunctionEmitter @feat(SLJIT) {
    LoopEmitter out;
    FunctionPlan* plan;
    FunctionFlow flow;
    CompiledFunction* cf;
    bool[FUNCTION_OPS] blocks;
    // Nesting level of the callee bodies this emitter expands for itself.
    uint depth;
    // An expanded body keeps its receiver in the window, not in reg_s(3).
    bool this_in_window;
}

fn bool function_op(Opcode op) @feat(SLJIT) {
    switch (op) {
        case NOP:
        case LDREG:
        case LDTHIS:
        case LDINT:
        case LDCONST:
        case LDTRUE:
        case LDFALSE:
        case LDNULL:
        case LDUNDEF:
        case VOID:
        case GETCAP:
        case PUTCAP:
        case INC_VAR:
        case DEC_VAR:
        case GETVAR:
        case GETGLOBAL:
        case GETPROPC:
        case GETPROPC_CACHED:
        case PUTPROPC:
        case GETPROP:
        case GETPROP_CACHE:
        case PUTPROP:
        case GETTHISC:
        case PUTTHISC:
        case BAND:
        case BOR:
        case BXOR:
        case SHL:
        case SHR:
        case USHR:
        case BANDI:
        case BORI:
        case BXORI:
        case SHLI:
        case SHRI:
        case USHRI:
        case BNOT:
        case UNM:
        case UNP:
        case TONUMERIC:
        case INC:
        case INC_LT:
        case DEC:
        case LNOT:
        case TYPEOF:
        case ADD:
        case ADD_FUSED:
        case ADDI:
        case SUB:
        case SUBI:
        case MUL:
        case MULI:
        case DIV:
        case LT:
        case LE:
        case GT:
        case GE:
        case EQ:
        case NEQ:
        case SEQ:
        case SNEQ:
        case IF_TRUE:
        case IF_FALSE:
        case JUMP:
        case JMP_NLT..JMP_NNULL:
        case JMP_NLTI..JMP_SNEQI:
            return true;
        default: return false;
    }
}
fn bool function_call_op(Opcode op) @feat(SLJIT) {
    return op == Opcode.CALL || op == Opcode.CALL_VAR || op == Opcode.CALL_GLOBAL
        || op == Opcode.CALL_UNDEF_THIS;
}
fn int function_capture(CompiledFunction* cf, uint name) @feat(SLJIT) {
    if (name >= cf.const_count) return -1;
    for (uint i = 0; i < cf.capture_count; i++) {
        if (cf.constants[cf.capture_names[i]].same_bits(&cf.constants[name])) return (int)i;
    }
    return -1;
}
fn int function_capture_index(CompiledFunction* cf, Instruction ins) @feat(SLJIT) {
    int index = ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP ? (int)ins.get_bc()
        : function_capture(cf, ins.get_bc());
    return index >= 0 && index < (int)cf.capture_count && index < (int)FUNCTION_CAPTURES ? index : -1;
}
fn bool function_analyze(CompiledFunction* cf, FunctionPlan* plan, Heap* h) @feat(SLJIT) {
    if (cf.code_count > FUNCTION_OPS || cf.flags.is_generator || cf.flags.is_async || cf.flags.has_direct_eval
        || cf.mapped_arguments()
        || cf.sljit_loops != null) return false;
    uint useful;
    uint[LOOP_REGS] frequency;
    for (uint pos = 0; pos < cf.code_count; pos++) {
        Instruction ins = cf.code[pos];
        // WIDE payloads cannot be decoded independently on a native resume.
        if (ins.op == Opcode.WIDE) return false;
        if (function_math_candidate(
            cf,
            pos
        ) >= 0 || function_parseint_candidate(cf, pos) || function_inline_candidate(cf, pos, h) != null) {
            plan.min_span = FUNCTION_MIN_SPAN;
            useful += 2;
            continue;
        }
        if (function_call_inlineable(cf, pos, h)) {
            // A general inline replaces a call but still ends the native run at
            // the callee's own guards, so it does not need the long span the
            // numeric inliner reserves.
            useful += 2;
            continue;
        }
        if (!function_op(ins.op)) continue;
        int backedge = loop_target(ins, pos);
        if (backedge >= 0 && backedge <= (int)pos) useful += 2;
        // Keep the established admission policy for ordinary callback chunks.
        // Expanded integer/indexed/call coverage needs a longer native span.
        if ((ins.op >= Opcode.BANDI && ins.op <= Opcode.USHRI) || (ins.op >= Opcode.UNP && ins.op <= Opcode.BNOT)
            || (ins.op >= Opcode.BAND && ins.op <= Opcode.USHR)) plan.min_span = FUNCTION_MIN_SPAN;
        if (ins.op == Opcode.GETPROP || ins.op == Opcode.GETPROP_CACHE || ins.op == Opcode.PUTPROP) {
            TVal* key = function_key_literal(cf, pos, ins.op == Opcode.PUTPROP ? ins.b : ins.c);
            if (key == null || !key.is_string()) plan.min_span = FUNCTION_MIN_SPAN;
        }
        if (ins.a < LOOP_REGS) frequency[ins.a]++;
        if (ins.b < LOOP_REGS) frequency[ins.b]++;
        if (ins.c < LOOP_REGS) frequency[ins.c]++;
        if (ins.op == Opcode.GETCAP || ins.op == Opcode.GETVAR || ins.op == Opcode.GETGLOBAL || ins.op == Opcode.LDREG
            || ins.op == Opcode.LDCONST
            || ins.op == Opcode.GETPROPC
            || ins.op == Opcode.GETPROPC_CACHED
            || ins.op == Opcode.LDTHIS
            || ins.op == Opcode.TYPEOF
            || ins.op == Opcode.GETPROP
            || ins.op == Opcode.GETPROP_CACHE
            || ins.op == Opcode.GETTHISC) {
            if (ins.a + 1 > plan.heap_regs) plan.heap_regs = (uint)ins.a + 1;
        }
        if (ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP || ins.op == Opcode.INC_VAR
            || ins.op == Opcode.DEC_VAR) {
            int cap = function_capture_index(cf, ins);
            if (cap < 0) continue;
            if (ins.op != Opcode.GETCAP) plan.capture_writes |= 1U << cap;
        }

        if (ins.op == Opcode.LDTHIS || ins.op == Opcode.GETTHISC || ins.op == Opcode.PUTTHISC) plan.receiver = true;
        if (ins.op == Opcode.GETPROPC || ins.op == Opcode.GETPROPC_CACHED || ins.op == Opcode.INC_VAR
            || ins.op == Opcode.PUTCAP
            || ins.op == Opcode.PUTPROPC
            || ins.op == Opcode.GETTHISC
            || ins.op == Opcode.PUTTHISC
            || ins.op == Opcode.GETPROP
            || ins.op == Opcode.GETPROP_CACHE
            || ins.op == Opcode.PUTPROP) useful++;
    }
    for (uint i = 0; i < 4; i++) {
        uint best;
        for (uint j = 1; j < cf.num_regs && j < LOOP_REGS; j++) if (frequency[j] > frequency[best]) best = j;
        if (frequency[best] < 2) break;
        plan.cache[best] = (char)jit::reg_r((int)i + 4);
        frequency[best] = 0;
        plan.cached_regs[plan.cache_count++] = (char)best;
    }
    return useful >= 2;
}
fn long function_cold_offset(uint field) @feat(SLJIT) {
    ColdCtx cold;
    return field == 0 ? (char*)&cold.heap - (char*)&cold : (char*)&cold.act - (char*)&cold;
}
fn void function_store(LoopEmitter* out, uint reg, int source, uint pc, bool inert = false) @feat(SLJIT) {
    TemplateEmitter* e = &out.e;
    if (out.flow != null) out.flow.drop(reg);
    int r0  = jit::reg_r(0);
    int r1  = jit::reg_r(1);
    int r2  = jit::reg_r(2);
    int r3  = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    if (source != r0) e.mov(r0, 0, source, 0);
    // An inlined callee's window only ever holds borrowed bits: arguments and
    // field reads are kept alive by the caller's registers and their owners,
    // and the result is transferred out with ownership by the call site.
    if (out.raw_store) {
        e.mov(mem | out.state_base(), loop_value_offset(reg), r0, 0);
        return;
    }
    if (out.cached(reg) != 0) {
        // Cache values are borrowed until native exit. Original VM slots keep
        // their owners alive; no call, allocation or collection occurs here.
        e.mov(out.cached(reg), 0, r0, 0);
        return;
    }
    out.load(reg, r1);
    HeapHeader header;
    long refs = (char*)&header.refcount - (char*)&header;
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    void* old_inert = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_STRING);
    e.op(jit::SLJIT_AND, r2, r1, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    void* old_null = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, 0);
    void* same     = e.cmp(jit::SLJIT_EQUAL, r0, 0, r1, 0);
    e.mov(r3, 0, mem | r2, refs, jit::SLJIT_MOV_U32);
    out.guard(jit::SLJIT_LESS_EQUAL, r3, 0, imm, 1, pc);
    e.bind(same);
    e.bind(old_null);
    e.bind(old_inert);
    if (!inert) {
        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        void* new_inert = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_STRING);
        e.op(jit::SLJIT_AND, r2, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
        void* new_null = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, 0);
        e.mov(r3, 0, mem | r2, refs, jit::SLJIT_MOV_U32);
        void* new_pinned = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, types::STRING_PINNED_REFCOUNT);
        e.op(jit::SLJIT_ADD, r3, r3, 0, imm, 1);
        e.mov(mem | r2, refs, r3, 0, jit::SLJIT_MOV_U32);
        e.bind(new_pinned);
        e.bind(new_null);
        e.bind(new_inert);
    }
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    void* release_inert = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_STRING);
    e.op(jit::SLJIT_AND, r2, r1, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    void* release_null = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, 0);
    e.mov(r3, 0, mem | r2, refs, jit::SLJIT_MOV_U32);
    void* release_pinned = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, types::STRING_PINNED_REFCOUNT);
    e.op(jit::SLJIT_SUB, r3, r3, 0, imm, 1);
    e.mov(mem | r2, refs, r3, 0, jit::SLJIT_MOV_U32);
    e.bind(release_pinned);
    e.bind(release_null);
    e.bind(release_inert);
    int cached = out.cached(reg);
    e.mov(cached != 0 ? cached : mem | out.state_base(), cached != 0 ? 0 : loop_value_offset(reg), r0, 0);
}
fn void FunctionEmitter.store(&self, uint reg, uint pc, bool known = false) @feat(SLJIT) {
    if (self.out.flow != null && self.flow_hint(reg, pc)) {
        self.flow_value(reg, pc);
        return;
    }
    function_store(&self.out, reg, jit::reg_r(0), pc, known);
}

fn void FunctionEmitter.truth(&self, uint reg, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0             = jit::reg_r(0);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    self.out.load(reg, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void* integer = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT);
    void* boolean = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_BOOLEAN);
    void* object  = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    self.out.guard(jit::SLJIT_LESS, r3, 0, imm, (long)types::TAG_UNDEFINED, pc);
    self.out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_NULL_VAL, pc);
    e.mov(r0, 0, imm, 0);
    void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(object);
    e.mov(r0, 0, imm, 1);
    void* object_done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(integer);
    e.bind(boolean);
    e.op(jit::SLJIT_SHL, r0, r0, 0, imm, 16);
    e.op(jit::SLJIT_ASHR, r0, r0, 0, imm, 16);
    e.bind(done);
    e.bind(object_done);
}
fn void FunctionEmitter.equal(&self, Instruction ins, bool immediate, bool negate, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    self.out.load(ins.b, r0);
    if (immediate) {
        TVal v;
        v.set_fastint((ichar)ins.c);
        e.mov(r1, 0, imm, (long)loop_bits(v));
    } else {
        self.out.load(ins.c, r1);
    }
    e.op(jit::SLJIT_LSHR, r2, r0, 0, imm, 48);
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    // Doubles retain the interpreter's numeric equality and NaN handling.
    self.out.guard(jit::SLJIT_LESS, r2, 0, imm, (long)types::TAG_FASTINT, pc);
    self.out.guard(jit::SLJIT_LESS, r3, 0, imm, (long)types::TAG_FASTINT, pc);
    void* same           = e.cmp(jit::SLJIT_EQUAL, r0, 0, r1, 0);
    void* different_type = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, r3, 0);
    self.out.guard(jit::SLJIT_EQUAL, r2, 0, imm, (long)types::TAG_STRING, pc);
    self.out.guard(jit::SLJIT_EQUAL, r2, 0, imm, (long)types::TAG_BIGINT, pc);
    e.bind(different_type);
    e.mov(r0, 0, imm, negate ? 1 : 0);
    void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(same);
    e.mov(r0, 0, imm, negate ? 0 : 1);
    e.bind(done);
}
// Loose equality keeps two cases native: null and undefined compare equal to
// each other and to nothing else, and two objects compare by reference. Any
// other pairing (a string, a BigInt, one object and one primitive) still needs
// the interpreter's abstract equality.
fn void FunctionEmitter.loose_equal(&self, Instruction ins, bool negate, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    self.out.load(ins.b, r0);
    self.out.load(ins.c, r1);
    e.op(jit::SLJIT_LSHR, r2, r0, 0, imm, 48);
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    // Null and undefined are equal to each other and to nothing else, which is
    // the `x == null` idiom. Their tags are adjacent, so a shifted difference
    // is 0 or 1 for exactly those two values.
    e.op(jit::SLJIT_SUB, r2, r2, 0, imm, (long)types::TAG_UNDEFINED);
    e.op(jit::SLJIT_SUB, r3, r3, 0, imm, (long)types::TAG_UNDEFINED);
    void* n0 = e.cmp(jit::SLJIT_LESS_EQUAL, r2, 0, imm, 1);
    void* n1 = e.cmp(jit::SLJIT_LESS_EQUAL, r3, 0, imm, 1);
    void* neither = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    // Left side nullish: equal only when the right side is too.
    e.bind(n0);
    void* n2 = e.cmp(jit::SLJIT_LESS_EQUAL, r3, 0, imm, 1);
    void* one = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(n1);
    void* other = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(n2);
    void* both_eq = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(neither);
    e.op(jit::SLJIT_LSHR, r2, r0, 0, imm, 48);
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    // Two objects compare by reference. Anything else (coercion, symbols,
    // BigInts) is the interpreter's abstract equality.
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)types::TAG_OBJECT, pc);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    void* same = e.cmp(jit::SLJIT_EQUAL, r0, 0, r1, 0);
    e.bind(one);
    e.bind(other);
    e.mov(r0, 0, imm, negate ? (((long)types::TAG_BOOLEAN << 48) | 1) : ((long)types::TAG_BOOLEAN << 48));
    void* finish = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(same);
    e.bind(both_eq);
    e.mov(r0, 0, imm, negate ? ((long)types::TAG_BOOLEAN << 48) : (((long)types::TAG_BOOLEAN << 48) | 1));
    e.bind(finish);
}
// A branch on `x == null` or `x != null`, which never coerces: the operand is
// nullish when it is null or undefined, or the one object the language treats
// as nullish (the HTMLDDA document.all sentinel). Leaves in r0 whether the
// branch's condition holds, so the caller branches on a non-zero result.
fn void FunctionEmitter.null_check(&self, Instruction ins, bool negate, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    int mem            = jit::SLJIT_MEM;
    self.out.load(ins.b, r0);
    // r3 stays zero unless a case below proves the operand nullish.
    e.mov(r3, 0, imm, 0);
    e.op(jit::SLJIT_LSHR, r2, r0, 0, imm, 48);
    // Null and undefined carry adjacent tags and an empty payload.
    e.op(jit::SLJIT_SUB, r1, r2, 0, imm, (long)types::TAG_UNDEFINED);
    void* object_case = e.cmp(jit::SLJIT_GREATER, r1, 0, imm, 1);
    e.op(jit::SLJIT_AND, r1, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    void* done_a      = e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, 0);
    e.mov(r3, 0, imm, 1);
    void* done_b      = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(object_case);
    // Any other value is nullish only as the document.all sentinel, whose
    // identity the heap holds.
    void* done_c      = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)types::TAG_OBJECT);
    e.op(jit::SLJIT_AND, r1, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    Heap heap_view;
    e.mov(r2, 0, mem | jit::reg_s(1), function_cold_offset(0));
    e.mov(r2, 0, mem | r2, (char*)&heap_view.htmldda_obj - (char*)&heap_view);
    void* done_d      = e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, r2, 0);
    e.mov(r3, 0, imm, 1);
    e.bind(done_a);
    e.bind(done_b);
    e.bind(done_c);
    e.bind(done_d);
    e.op(jit::SLJIT_XOR, r0, r3, 0, imm, negate ? 1 : 0);
}
fn TVal* function_key_literal(CompiledFunction* cf, uint pc, uint reg) @feat(SLJIT) {
    for (uint back = pc; back > 0; back--) {
        Instruction ins = cf.code[back - 1];
        if (ins.a != reg || loop_target(
            ins,
            back - 1
        ) >= 0 || ins.op == Opcode.PUTPROP || ins.op == Opcode.PUTPROPC || ins.op == Opcode.PUTTHISC) continue;
        if (ins.op == Opcode.LDREG) {
            reg = ins.b;
            continue;
        }
        if (ins.op == Opcode.LDCONST) return &cf.constants[ins.get_bc()];
        return null;
    }
    return null;
}
fn int function_shape_slot(Shape* shape, void* key, PropFlags* flags) @feat(SLJIT) {
    while (shape != null) {
        for (uint i = 0; i < shape.own_count; i++) {
            ShapeProperty* property = &shape.props()[i];
            if (property.key.borrow() == key) {
                *flags = property.flags;
                return (int)(shape.offset + i);
            }
        }
        shape = shape.parent_shape;
    }
    return -1;
}
fn bool FunctionEmitter.shape(&self, uint id, Heap* h) @feat(SLJIT) {
    Shape* shape = h.get_shape(id);
    if (shape == null) return false;
    for (uint i = 0; i < self.plan.shape_count; i++) if (self.plan.shapes[i]
        == id) return self.plan.generations[i] == shape.generation;
    if (self.plan.shape_count == self.plan.shapes.len) return false;
    uint slot = self.plan.shape_count++;
    self.plan.shapes[slot] = id;
    self.plan.generations[slot] = shape.generation;
    return true;
}
// Store a value into a property slot. Old and new value tags are checked
// first; a traced object is stored only when the write barrier is a no-op.
fn void FunctionEmitter.slot_store(
    &self,
    int owner,
    int slot_base,
    long disp,
    uint value_reg,
    uint pc
) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    int mem            = jit::SLJIT_MEM;
    // Keep the owner for the object-store barrier; r0 takes the values.
    e.mov(r1, 0, owner, 0);
    e.mov(r0, 0, mem | slot_base, disp);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    // Strings are reference counted and carry a decref on replacement, so
    // only primitives and traced objects are stored natively.
    void* old_object = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    self.out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, pc);
    e.bind(old_object);
    self.out.load(value_reg, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void* new_object = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    self.out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, pc);
    e.bind(new_object);
    // Storing a traced object needs the write barrier. Skip it only when the
    // collector is not shading and the owner is young, or the value being
    // stored is already old.
    void* primitive = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT);
    Heap heap_view;
    e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
    e.mov(r3, 0, mem | r3, (char*)&heap_view.gc_phase - (char*)&heap_view, jit::SLJIT_MOV_U8);
    self.out.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)heap::GcPhase.MARK, pc);
    HObjectBase base;
    e.mov(r3, 0, mem | r1, (char*)&base.gc - (char*)&base, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r3, r3, 0, imm, 2);
    void* young_owner = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, 0);
    e.op(jit::SLJIT_AND, r3, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    e.mov(r3, 0, mem | r3, (char*)&base.gc - (char*)&base, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r3, r3, 0, imm, 2);
    self.out.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, pc);
    e.bind(young_owner);
    e.bind(primitive);
    e.mov(mem | slot_base, disp, r0, 0);
}

fn bool FunctionEmitter.property(&self, CompiledFunction* cf, uint pc, bool write, Heap* h) @feat(SLJIT) {
    TemplateEmitter* e       = &self.out.e;
    Instruction ins          = cf.code[pc];
    ICEntry* ic              = (ICEntry*)cf.ic_entries + pc;
    FunctionFlow* saved_flow = self.out.flow;
    bool length_join         = (ins.op == Opcode.GETPROPC || ins.op == Opcode.GETPROPC_CACHED)
        && cf.constants[ins.c].get_heapptr() == h.str(
        heap::BuiltinStr.LENGTH
    );
    if (length_join && saved_flow != null) {
        self.flow_materialize();
        self.out.flow = null;
    }
    defer self.out.flow = saved_flow;
    if (!write && ins.op != Opcode.GETTHISC && (ins.op == Opcode.GETPROPC || ins.op == Opcode.GETPROPC_CACHED)
        && cf.constants[ins.c].get_heapptr() == h.str(
        heap::BuiltinStr.LENGTH
    ) && self.typed_length(cf, pc, ic, h)) return true;
    bool receiver_this = ins.op == Opcode.GETTHISC || ins.op == Opcode.PUTTHISC;
    bool computed      = ins.op == Opcode.GETPROP || ins.op == Opcode.GETPROP_CACHE || ins.op == Opcode.PUTPROP;
    uint value_reg     = ins.op == Opcode.PUTTHISC ? ins.a : ins.op == Opcode.PUTPROP ? ins.c : ins.b;
    void* key          = computed ? (void*)ic.key.borrow() : cf.constants[ins.c].get_heapptr();
    TVal* literal      = computed ? function_key_literal(cf, pc, write ? ins.b : ins.c) : null;
    if (computed && literal != null && literal.is_string()) {
        HString* text = literal.get_heapptr();
        if (!text.is_symbol() && (String)text.get_data() == "length") key = h.str(heap::BuiltinStr.LENGTH);
    }
    uint base_reg    = write ? ins.a : ins.b;
    bool tracking    = FUNCTION_OBJECT_FLOW && self.out.flow != null && !computed;
    uint token       = tracking ? self.flow.token(base_reg, receiver_this) : 0;
    bool known_shape = tracking && (receiver_this ? self.flow.this_shape
        : self.flow.shapes[base_reg]) == ic.shape_id + 1;
    if (tracking && write) self.flow.heap_write();
    if (tracking && !write) {
        int previous = self.flow.loaded(token, key);
        if (previous >= 0) {
            uint value_token = self.flow.versions[previous];
            uint value_shape = self.flow.shapes[previous];
            self.out.load((uint)previous, jit::reg_r(0));
            self.store(ins.a, pc);
            self.flow.same_value(ins.a, value_token, value_shape);
            self.flow.remember(token, key, ins.a);
            return true;
        }
    }
    // Shared read-cache hits can leave later sites unpopulated. Borrow a
    // warmed site's layout; generated guards still validate the live receiver.
    if (!computed && ic.key.borrow() == null) {
        for (uint i = 0; i < cf.code_count; i++) {
            if (cf.code[i].op != Opcode.GETPROPC && cf.code[i].op != Opcode.GETPROPC_CACHED) continue;
            ICEntry* candidate = (ICEntry*)cf.ic_entries + i;
            if (candidate.key.borrow() != key || candidate.prop_idx >= hobject::IC_PROP_MISSING
                || candidate.prop_flags.is_accessor) continue;
            Shape* layout = h.get_shape(candidate.shape_id);
            if (layout == null || layout.generation != candidate.shape_gen) continue;
            ic = candidate;
            break;
        }
    }
    known_shape = tracking && (receiver_this ? self.flow.this_shape : self.flow.shapes[base_reg]) == ic.shape_id + 1;
    int mem = jit::SLJIT_MEM;
    int imm = jit::SLJIT_IMM;
    int r0  = jit::reg_r(0);
    int r1  = jit::reg_r(1);
    int r2  = jit::reg_r(2);
    int r3  = jit::reg_r(3);
    bool matching = literal != null && literal.is_string();
    bool element  = false;
    if (computed) {
        self.out.load(write ? ins.b : ins.c, r1);
        if (matching && literal.get_heapptr() != key) {
            HString* left  = literal.get_heapptr();
            HString* right = key;
            matching = right != null && !left.is_symbol() && !right.is_symbol()
                && (String)left.get_data() == (String)right.get_data();
        }
        // A numeric key names an array element, which the dense part answers.
        // The site cache only records string keys, so an unrecorded key is an
        // index and the element path claims it. A write does not: storing into
        // the dense part has to consult the prototype chain and keep the
        // array's hole count in step, which the interpreter owns.
        element = !write && !matching && key == null;
        if (!element) {
            self.out.guard(
                jit::SLJIT_NOT_EQUAL,
                r1,
                0,
                imm,
                matching ? (long)loop_bits(*literal) : (long)((types::TAG_STRING << 48) | (ulong)key),
                pc
            );
        }
    }
    if (receiver_this) {
        if (self.this_in_window) {
            self.out.load(INLINE_THIS_SLOT, r0);
        } else {
            e.mov(r0, 0, jit::reg_s(3), 0);
        }
    } else {
        self.out.load(write ? ins.a : ins.b, r0);
    }
    if (element) {
        self.array_element(cf, pc);
        return true;
    }
    if (!known_shape) {
        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    }
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    if (!known_shape) self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    HObject obj;
    long shape_offset = (char*)&obj.shape_id - (char*)&obj;
    long proto_offset = (char*)&obj.prototype - (char*)&obj;
    ObjFlags forbidden;
    forbidden.exotic_proxyobj = true;
    forbidden.exotic_module_ns = true;
    forbidden.exotic_deferred_ns = true;
    ObjFlags ordinary;
    ordinary.obj_class = OBJECT;
    uint flag_mask = 0x003F0000U | (uint)forbidden;
    void* length_done;
    if (!write && key == h.str(heap::BuiltinStr.LENGTH)) {
        e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_AND, r2, r2, 0, imm, flag_mask);
        ObjFlags array;
        array.obj_class = ARRAY;
        void* other = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)array);
        e.mov(r0, 0, mem | r0, HObjectBase::size, jit::SLJIT_MOV_U32);
        self.out.box(r0);
        self.store(ins.a, pc, true);
        length_done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
        e.bind(other);
    }
    Shape* shape = h.get_shape(ic.shape_id);
    // Inherited reads cache their links on one prototype epoch, and a site
    // whose objects differ in shape keeps a set of own data reads.
    bool epoch_chain = !write && ic.chain_len == hobject::IC_CHAIN_EPOCH;
    bool poly_chain  = !write && ic.chain_len == hobject::IC_CHAIN_POLY;
    bool usable  = key != null && ic.key.borrow() == key && shape != null && shape.generation == ic.shape_gen
        && (epoch_chain || poly_chain || ic.chain_len <= hobject::IC_MAX_CHAIN)
        && !ic.prop_flags.is_accessor
        && ic.prop_idx < hobject::IC_PROP_MISSING
        && (!write || (!ic.has_proto && ic.prop_flags.writable));
    if (usable && epoch_chain) {
        usable = ic.chain.epoch.owner != null && ic.chain.epoch.first != null
            && ic.chain.epoch.owner.find_prop_idx(key, h) == (int)ic.prop_idx;
    }
    if (usable) {
        usable = self.shape(ic.shape_id, h);
        PropFlags flags;
        int index = function_shape_slot(shape, key, &flags);
        if (poly_chain) {
            // Every extra shape is a receiver this site has already read the
            // key from as an own data slot.
            ICPolySet* set = &ic.chain.poly;
            usable = index < 0 && set.count > 0 && set.count <= hobject::IC_POLY_MAX;
            for (uint i = 0; usable && i < set.count; i++) {
                Shape* extra = h.get_shape(set.shapes[i]);
                usable = extra != null && !extra.dict && self.shape(set.shapes[i], h)
                    && function_shape_slot(extra, key, &flags) == (int)set.prop_idx[i];
            }
        } else if (epoch_chain) {
            usable = index < 0 && !shape.dict;
        } else if (ic.chain_len == 0) {
            usable = usable && index == (int)ic.prop_idx && !flags.is_accessor && (!write || flags.writable);
        } else {
            usable = usable && index < 0 && !shape.dict;
            for (uint i = 0; usable && i < ic.chain_len; i++) {
                // Cache links are weak. Validate layouts through the shape table;
                // generated code follows live links before dereferencing objects.
                Shape* proto_shape = h.get_shape(ic.chain.snapshot.shapes[i]);
                usable = ic.chain.snapshot.protos[i] != null && proto_shape != null && self.shape(ic.chain.snapshot.shapes[i], h);
                if (!usable) break;
                index = function_shape_slot(proto_shape, key, &flags);
                if (i + 1 == ic.chain_len) {
                    usable = index == (int)ic.prop_idx && !flags.is_accessor;
                } else {
                    usable = index < 0 && !proto_shape.dict;
                }
            }
        }
    }
    if (!usable) {
        self.out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pc, true);
    } else if (poly_chain) {
        // One compare per recorded shape, each naming the slot that shape's
        // layout gave the key. The entry's own shape is the first and the most
        // common; a receiver matching none leaves to the interpreter.
        if (tracking && saved_flow != null) {
            self.flow_materialize();
            self.out.flow = null;
        }
        ICPolySet* set = &ic.chain.poly;
        void*[hobject::IC_POLY_MAX + 1] arms;
        uint arm_count = 0;
        for (uint i = 0; i <= set.count; i++) {
            uint shape_id = i == 0 ? ic.shape_id : set.shapes[i - 1];
            uint slot     = i == 0 ? ic.prop_idx : set.prop_idx[i - 1];
            self.out.load(base_reg, r0);
            e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
            e.mov(r1, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
            void* other = e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, shape_id);
            e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
            void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
            e.op(jit::SLJIT_ADD, r2, r0, 0, imm, HObjectBase::size);
            e.bind(allocated);
            e.mov(r0, 0, mem | r2, (long)slot * 8);
            self.store(ins.a, pc);
            arms[arm_count++] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
            e.bind(other);
        }
        self.out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pc, true);
        void* arms_done = e.label();
        for (uint i = 0; i < arm_count; i++) jit::sljit_set_label(arms[i], arms_done);
    } else {
        if (!known_shape) {
            e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
            e.op(jit::SLJIT_AND, r2, r2, 0, imm, flag_mask);
            HString* text = key;
            bool math_key = text != null && !text.is_symbol() && (text.equals(
                "min"
            ) || text.equals("max") || text.equals("abs") || text.equals("sqrt") || text.equals("imul"));
            if (math_key) {
                void* plain = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, (uint)ordinary);
                ObjFlags math;
                math.obj_class = MATH;
                self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)math, pc);
                e.bind(plain);
            } else {
                self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
            }
            e.mov(r2, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.shape_id, pc);
            if (tracking) self.flow.guard_shape(token, ic.shape_id);
        }
        if (epoch_chain) {
            // The epoch covers a repointed link and every layout change on the
            // chain, so only the first link and the shared counter remain.
            e.mov(r2, 0, mem | r0, proto_offset);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)ic.chain.epoch.first, pc);
            Heap heap_view;
            e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
            e.mov(r3, 0, mem | r3, (char*)&heap_view.prototype_epoch - (char*)&heap_view);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)ic.chain.epoch.value, pc);
            // The owner keeps its identity while the epoch holds, but its
            // storage may have moved, so the slot is read from the live object.
            e.mov(r1, 0, imm, (long)ic.chain.epoch.owner);
            e.mov(r2, 0, mem | r1, (char*)&obj.prop_alloc - (char*)&obj);
            void* owner_allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
            e.op(jit::SLJIT_ADD, r2, r1, 0, imm, HObjectBase::size);
            e.bind(owner_allocated);
            e.mov(r0, 0, mem | r2, (long)ic.prop_idx * 8);
            self.store(ins.a, pc);
            if (tracking) self.flow.remember(token, key, ins.a);
        } else {
            for (uint i = 0; i < ic.chain_len; i++) {
                e.mov(r0, 0, mem | r0, proto_offset);
                self.out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)ic.chain.snapshot.protos[i], pc);
                e.mov(r2, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
                self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.chain.snapshot.shapes[i], pc);
                e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
                e.op(jit::SLJIT_AND, r2, r2, 0, imm, flag_mask);
                self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
            }
            e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
            void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
            e.op(jit::SLJIT_ADD, r2, r0, 0, imm, HObjectBase::size);
            e.bind(allocated);
            if (write) {
                self.slot_store(r0, r2, (long)ic.prop_idx * 8, value_reg, pc);
            } else {
                e.mov(r0, 0, mem | r2, (long)ic.prop_idx * 8);
                self.store(ins.a, pc);
                if (tracking) self.flow.remember(token, key, ins.a);
            }
        }
    }
    if (length_done != null) e.bind(length_done);
    return usable || length_done != null;
}

// A computed read whose key is an array index. The receiver must be a dense
// array and the key a non-negative integer below the dense capacity; the
// element then lives in the array's dense part, whose address is the part
// pointer plus the index. Anything else leaves to the interpreter, which owns
// the named-property and hole paths.
fn void FunctionEmitter.array_element(&self, CompiledFunction* cf, uint pc) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    Instruction ins = cf.code[pc];
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    // The receiver must be an object.
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    // The key must be a fastint: a fractional index names a property.
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pc);
    e.op(jit::SLJIT_AND, r1, r1, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    // The payload is a signed 48-bit value, so a negative index is not an
    // element either.
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 47);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pc);
    // The receiver must be an array that keeps its indices in the dense part:
    // a named index property shadows the dense slot.
    HObject obj;
    e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    ObjFlags array;
    array.obj_class = ARRAY;
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, 0x003F0000U | (1U << 29));
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)array, pc);
    // The index must be below the dense capacity.
    e.mov(r2, 0, mem | r0, (char*)&obj.array_size - (char*)&obj, jit::SLJIT_MOV_U32);
    self.out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r2, 0, pc);
    // The dense part follows the property values.
    e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
    self.out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pc);
    e.mov(r3, 0, mem | r0, (char*)&obj.prop_capacity - (char*)&obj, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_SHL, r3, r3, 0, imm, 3);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r3, 0);
    e.op(jit::SLJIT_SHL, r1, r1, 0, imm, 3);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r1, 0);
    e.mov(r0, 0, mem | r2, 0);
    // A hole is not an element: the interpreter looks the index up by name.
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED, pc);
    self.store(ins.a, pc);
}

fn void FunctionEmitter.typeof_value(&self, CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    self.out.load(cf.code[pc].b, r0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void*[5] cases;
    cases[0] = e.cmp(jit::SLJIT_LESS_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT);
    cases[1] = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED);
    cases[2] = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_NULL_VAL);
    cases[3] = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_BOOLEAN);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r1, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, pc);
    e.mov(r3, 0, jit::SLJIT_MEM | r1, 0, jit::SLJIT_MOV_U32);
    ObjFlags callable;
    callable.callable = true;
    e.op(jit::SLJIT_AND, r3, r3, 0, imm, (uint)callable);
    cases[4] = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0);
    TVal v;
    v.set_string_borrowed(h.str(heap::BuiltinStr.OBJECT));
    e.mov(r0, 0, imm, (long)loop_bits(v));
    void*[6] finished;
    finished[0] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    heap::BuiltinStr[5] names = { NUMBER, UNDEFINED, OBJECT, BOOLEAN, FUNCTION };
    for (uint i = 0; i < 5; i++) {
        e.bind(cases[i]);
        v.set_string_borrowed(h.str(names[i]));
        e.mov(r0, 0, imm, (long)loop_bits(v));
        finished[i + 1] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    }
    void* end = e.label();
    foreach (jump : finished) self.out.bind_to(jump, end);
    self.store(cf.code[pc].a, pc, true);
}
// Resolve the mutable capture once in the native prologue. Private cells need
// no name lookup; named captures guard skipped scopes and the writable layout.
fn bool FunctionEmitter.capture(&self, CompiledFunction* cf, Activation* act, Heap* h) @feat(SLJIT) {
    uint mask = self.plan.capture_writes;
    if (mask == 0) return true;
    if ((mask & (mask - 1)) != 0 || !act.tv_func.is_object()) return false;
    uint index;
    while ((mask & (1U << index)) == 0) index++;
    HObject* function = act.tv_func.get_heapptr();
    CaptureRef* refs  = function.extra.func.capture_refs;
    HObject* owner;
    PropValue* slot   = capture_value_slot(act, index, h, true, &owner);
    if (slot == null || owner == null || !slot.get().is_fastint() || owner.get_class() != OBJECT) return false;
    CaptureRef* ref = &refs[index];
    if (ref.is_value || (!ref.is_cell && !self.shape(owner.shape_id, h))) return false;
    TemplateEmitter* e = &self.out.e;
    int mem            = jit::SLJIT_MEM;
    int imm            = jit::SLJIT_IMM;
    int r0             = jit::reg_r(0);
    int r1             = jit::reg_r(1);
    int r2             = jit::reg_r(2);
    int r3             = jit::reg_r(3);
    int capture        = jit::reg_s(4);
    Activation activation;
    HObject object;
    CaptureRef layout;
    EnvRecord scope_layout;
    e.mov(r2, 0, mem | jit::reg_s(1), function_cold_offset(1));
    e.mov(r0, 0, mem | r2, (char*)&activation.tv_func - (char*)&activation);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, FUNCTION_BAIL);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    e.mov(r1, 0, mem | r0, (char*)&object.extra.func.capture_refs - (char*)&object);
    self.out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, FUNCTION_BAIL);
    e.op(jit::SLJIT_ADD, r1, r1, 0, imm, (long)(index * CaptureRef::size));
    e.mov(r3, 0, mem | r1, (char*)&layout.is_value - (char*)&layout, jit::SLJIT_MOV_U8);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, FUNCTION_BAIL);
    e.mov(r3, 0, mem | r1, (char*)&layout.is_cell - (char*)&layout, jit::SLJIT_MOV_U8);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, ref.is_cell ? 1 : 0, FUNCTION_BAIL);
    e.mov(r3, 0, mem | r1, (char*)&layout.guard_shadow - (char*)&layout, jit::SLJIT_MOV_U8);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, ref.guard_shadow ? 1 : 0, FUNCTION_BAIL);
    e.mov(capture, 0, mem | r1, (char*)&layout.owner - (char*)&layout);
    self.out.guard(jit::SLJIT_EQUAL, capture, 0, imm, 0, FUNCTION_BAIL);
    e.mov(r3, 0, mem | r1, (char*)&layout.prop_idx - (char*)&layout, jit::SLJIT_MOV_U32);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, ref.prop_idx, FUNCTION_BAIL);
    e.mov(r0, 0, mem | capture, 0, jit::SLJIT_MOV_U32);
    ObjFlags flags;
    flags.obj_class = OBJECT;
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, 0x003F0000);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (uint)flags, FUNCTION_BAIL);
    if (ref.is_cell) {
        e.mov(r0, 0, mem | capture, (char*)&object.prop_count - (char*)&object, jit::SLJIT_MOV_U32);
        self.out.guard(jit::SLJIT_LESS_EQUAL, r0, 0, imm, ref.prop_idx, FUNCTION_BAIL);
    } else {
        e.mov(r0, 0, mem | capture, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, owner.shape_id, FUNCTION_BAIL);
        if (ref.guard_shadow) {
            e.mov(r0, 0, mem | r2, (char*)&activation.lex_env - (char*)&activation);
            self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, FUNCTION_BAIL);
            EnvRecord* scope = act.lex_env;
            uint depth;
            while (scope != null && scope.bindings != owner) {
                if (++depth > 8 || scope.is_with()) return false;
                EnvFlags with_flag;
                with_flag.is_with = true;
                e.mov(r3, 0, mem | r0, (char*)&scope_layout.flags - (char*)&scope_layout, jit::SLJIT_MOV_U8);
                e.op(jit::SLJIT_AND, r3, r3, 0, imm, (char)with_flag);
                self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, FUNCTION_BAIL);
                e.mov(r3, 0, mem | r0, (char*)&scope_layout.bindings - (char*)&scope_layout);
                if (scope.bindings == null) {
                    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, FUNCTION_BAIL);
                } else {
                    Shape* sh = scope.bindings.get_shape(h);
                    PropFlags ignored;
                    void* key = cf.constants[cf.capture_names[index]].get_heapptr();
                    if (sh == null || sh.dict || function_shape_slot(
                        sh,
                        key,
                        &ignored
                    ) >= 0 || !self.shape(scope.bindings.shape_id, h)) return false;
                    self.out.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, FUNCTION_BAIL);
                    e.mov(r3, 0, mem | r3, (char*)&object.shape_id - (char*)&object, jit::SLJIT_MOV_U32);
                    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, scope.bindings.shape_id, FUNCTION_BAIL);
                }
                e.mov(r0, 0, mem | r0, (char*)&scope_layout.parent - (char*)&scope_layout);
                self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, FUNCTION_BAIL);
                scope = scope.parent;
            }
            if (scope == null || scope.is_with()) return false;
            EnvFlags with_flag;
            with_flag.is_with = true;
            e.mov(r3, 0, mem | r0, (char*)&scope_layout.flags - (char*)&scope_layout, jit::SLJIT_MOV_U8);
            e.op(jit::SLJIT_AND, r3, r3, 0, imm, (char)with_flag);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, FUNCTION_BAIL);
            e.mov(r3, 0, mem | r0, (char*)&scope_layout.bindings - (char*)&scope_layout);
            self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, capture, 0, FUNCTION_BAIL);
        }
    }
    e.mov(r0, 0, mem | capture, (char*)&object.prop_alloc - (char*)&object);
    void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0);
    e.op(jit::SLJIT_ADD, r0, capture, 0, imm, HObjectBase::size);
    e.bind(allocated);
    e.op(jit::SLJIT_ADD, capture, r0, 0, imm, (long)ref.prop_idx * 8);
    e.mov(r0, 0, mem | capture, 0);
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, FUNCTION_BAIL);
    return true;
}
// Emit only on the taken path: an exhausted budget resumes at the branch
// instruction, so the interpreter rechecks its condition and owns the poll.
fn void FunctionEmitter.branch_target(&self, uint pc, uint target) @feat(SLJIT) {
    if (target <= pc && target < self.cf.code_count) {
        FunctionRun layout;
        int r0  = jit::reg_r(0);
        int run = jit::reg_s(2);
        self.out.e.mov(r0, 0, jit::SLJIT_MEM | run, (char*)&layout.budget - (char*)&layout);
        self.out.guard(jit::SLJIT_LESS_EQUAL, r0, 0, jit::SLJIT_IMM, 1, pc);
        self.out.e.op(jit::SLJIT_SUB, r0, r0, 0, jit::SLJIT_IMM, 1);
        self.out.e.mov(jit::SLJIT_MEM | run, (char*)&layout.budget - (char*)&layout, r0, 0);
    }
    self.out.link(jit::sljit_emit_jump(self.out.e.compiler, jit::SLJIT_JUMP), target, target >= self.cf.code_count);
}
fn bool function_emit(FunctionPlan* plan, CompiledFunction* cf, Heap* h, Activation* act) @feat(SLJIT) {
    LoopPlan layout_plan;
    layout_plan.cache = plan.cache;
    FunctionEmitter emitter = {
        .out = { .e = { .compiler = jit::sljit_create_compiler(null) }, .plan = &layout_plan },
        .plan = plan
    };
    FunctionEmitter* f = &emitter;
    LoopEmitter* out   = &f.out;
    out.function_mode = true;
    f.cf = cf;
    if (FUNCTION_DATAFLOW) out.flow = &f.flow;
    f.blocks[0] = true;
    for (uint i = 0; i < cf.code_count; i++) {
        int target = loop_target(cf.code[i], i);
        if (target >= 0 && target < (int)cf.code_count) f.blocks[target] = true;
        if (((!function_op(
            cf.code[i].op
        ) && function_math_candidate(
            cf,
            i
        ) < 0 && !function_parseint_candidate(
            cf,
            i
        ) && !function_call_inlineable(cf, i, h)) || target >= 0) && i + 1 < cf.code_count) f.blocks[i + 1] = true;
    }
    TemplateEmitter* e = &out.e;
    if (e.compiler == null) return false;
    defer jit::sljit_free_compiler(e.compiler);
    // s0..s4 are the state, cold context, run block, `this` and captures;
    // inlining also keeps an inline window base and a saved `this`.
    if (jit::sljit_emit_enter(e.compiler, 0, jit::SLJIT_ARGS3WWW, 8 | (6 << 8), 7, 0) != 0) return false;
    int r0  = jit::reg_r(0);
    int r1  = jit::reg_r(1);
    int r2  = jit::reg_r(2);
    int r3  = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    e.mov(jit::reg_s(0), 0, r0, 0);
    e.mov(jit::reg_s(1), 0, r1, 0);
    e.mov(jit::reg_s(2), 0, r2, 0);
    for (uint i = 0; i < cf.num_regs && i < LOOP_REGS; i++) if (plan.cache[i] != 0) {
        e.mov(plan.cache[i], 0, mem | jit::reg_s(0), loop_value_offset(i));
    }
    if (plan.receiver) {
        Activation layout;
        e.mov(r0, 0, mem | jit::reg_s(1), function_cold_offset(1));
        e.mov(r1, 0, mem | r0, (char*)&layout.flags - (char*)&layout, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_AND, r1, r1, 0, imm, ACT_FLAG_THIS_VALID);
        out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, FUNCTION_BAIL);
        e.mov(jit::reg_s(3), 0, mem | r0, (char*)&layout.this_binding - (char*)&layout);
    }
    if (!f.capture(cf, act, h)) return false;
    if (out.flow != null) f.flow_prepare();
    FunctionRun run_layout;
    e.mov(r0, 0, mem | jit::reg_s(2), (char*)&run_layout.entry - (char*)&run_layout);
    if (jit::sljit_emit_ijump(e.compiler, jit::SLJIT_JUMP, r0, 0) != 0) return false;
    bool[FUNCTION_OPS] supported;
    for (uint pos = 0; pos < cf.code_count; pos++) {
        Instruction ins = cf.code[pos];
        if (out.flow != null && f.blocks[pos]) f.flow_flush();
        out.labels[pos] = e.label();
        bool active = function_op(
            ins.op
        ) || function_math_candidate(
            cf,
            pos
        ) >= 0 || function_parseint_candidate(cf, pos) || function_call_inlineable(cf, pos, h);
        if ((ins.op == Opcode.GETCAP || ins.op == Opcode.PUTCAP || ins.op == Opcode.INC_VAR
            || ins.op == Opcode.DEC_VAR)
            && function_capture_index(
            cf,
            ins
        ) < 0) active = false;
        int target = loop_target(ins, pos);
        // A region-relative target before the window cannot be represented by
        // a native label (nor by the unsigned resume ABI). Replay that branch
        // in the interpreter, preserving its absolute destination exactly.
        if (target < 0 && loop_target(ins, pos + plan.begin) >= 0) active = false;
        if (!active) {
            if (out.flow != null) f.flow_flush();
            $if $feat(SLJIT_STATS):
            {
                e.mov(r3, 0, imm, (long)&plan.bail_ops);
                e.mov(r1, 0, mem | r3, 0);
                e.op(jit::SLJIT_ADD, r1, r1, 0, imm, 1);
                e.mov(mem | r3, 0, r1, 0);
            }
            $endif
            out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pos, true);
            if (pos + 1 < cf.code_count) f.blocks[pos + 1] = true;
            continue;
        }
        supported[pos] = true;
        uint copy_token;
        uint copy_shape;
        if (out.flow != null) {
            if (ins.op == Opcode.LDREG) {
                copy_token = f.flow.versions[ins.b];
                copy_shape = f.flow.shapes[ins.b];
            }
            if (ins.op == Opcode.LDTHIS) {
                copy_token = FLOW_THIS;
                copy_shape = f.flow.this_shape;
            }
            if (ins.op == Opcode.PUTCAP || ins.op == Opcode.INC_VAR || ins.op == Opcode.DEC_VAR) f.flow.heap_write();
        }

        if (target >= 0) {
            if (out.flow != null) f.flow_flush();
            if (ins.op == Opcode.JUMP) {
                f.branch_target(pos, (uint)target);
            } else if (ins.op == Opcode.IF_TRUE || ins.op == Opcode.IF_FALSE) {
                f.truth(ins.a, pos);
                void* skip = e.cmp(ins.op == Opcode.IF_TRUE ? jit::SLJIT_EQUAL : jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0);
                f.branch_target(pos, (uint)target);
                e.bind(skip);
            } else if (ins.op == Opcode.JMP_SEQ || ins.op == Opcode.JMP_SNEQ || ins.op == Opcode.JMP_SEQI
                || ins.op == Opcode.JMP_SNEQI) {
                f.equal(
                    ins,
                    ins.op == Opcode.JMP_SEQI || ins.op == Opcode.JMP_SNEQI,
                    ins.op == Opcode.JMP_SNEQ || ins.op == Opcode.JMP_SNEQI,
                    pos
                );
                void* skip = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
                f.branch_target(pos, (uint)target);
                e.bind(skip);
            } else if (ins.op == Opcode.JMP_EQ || ins.op == Opcode.JMP_NEQ) {
                f.loose_equal(ins, ins.op == Opcode.JMP_NEQ, pos);
                // loose_equal leaves a boxed boolean, so `false` is its tag
                // with an empty payload.
                void* skip = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, (long)types::TAG_BOOLEAN << 48);
                f.branch_target(pos, (uint)target);
                e.bind(skip);
            } else if (ins.op == Opcode.JMP_NULL || ins.op == Opcode.JMP_NNULL) {
                f.null_check(ins, ins.op == Opcode.JMP_NNULL, pos);
                void* skip = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
                f.branch_target(pos, (uint)target);
                e.bind(skip);
            } else {
                void*[2] skips = out.condition(ins, pos);
                f.branch_target(pos, (uint)target);
                void* next = e.label();
                foreach (jump : skips) if (jump != null) out.bind_to(jump, next);
            }
            continue;
        }
        switch (ins.op) {
            case CALL:
            case CALL_UNDEF_THIS:
            case CALL_VAR:
            case CALL_GLOBAL:
                if (function_parseint_candidate(cf, pos)) {
                    f.parseint_call(cf, pos);
                } else if (function_math_candidate(cf, pos) >= 0) {
                    f.math_call(cf, pos);
                } else if (function_array_candidate(cf, pos) >= 0) {
                    f.array_call(cf, pos);
                } else {
                    f.inline_call(cf, pos, h);
                }
                continue;
            case NOP: continue;
            case LDREG: out.load(ins.b, r0);
            case LDTHIS: e.mov(r0, 0, jit::reg_s(3), 0);
            case LDINT: { TVal v; v.set_fastint(ins.get_sbc()); e.mov(r0, 0, imm, (long)loop_bits(v)); }
            case LDCONST: e.mov(r0, 0, imm, (long)loop_bits(cf.constants[ins.get_bc()]));
            case LDTRUE:
            case LDFALSE:
            case LDNULL:
            case LDUNDEF:
            case VOID:

                {
                    TVal v;
                    if (ins.op == Opcode.LDTRUE || ins.op == Opcode.LDFALSE) {
                        v.set_boolean(ins.op == Opcode.LDTRUE);
                    } else if (ins.op == Opcode.LDNULL) {
                        v.set_null();
                    } else {
                        v.set_undefined();
                    }
                    e.mov(r0, 0, imm, (long)loop_bits(v));
                }
            case GETCAP:

                {
                    uint capture = ins.get_bc();
                    if ((plan.capture_writes & (1U << capture)) != 0) {
                        e.mov(r0, 0, mem | jit::reg_s(4), 0);
                    } else {
                        CaptureRef ref;
                        HObject owner;
                        Activation activation;
                        HObject function;
                        e.mov(r1, 0, mem | jit::reg_s(1), function_cold_offset(1));
                        e.mov(r1, 0, mem | r1, (char*)&activation.tv_func - (char*)&activation);
                        e.op(jit::SLJIT_AND, r1, r1, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
                        e.mov(r1, 0, mem | r1, (char*)&function.extra.func.capture_refs - (char*)&function);
                        out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, pos);
                        e.op(jit::SLJIT_ADD, r1, r1, 0, imm, (long)(capture * CaptureRef::size));
                        e.mov(r3, 0, mem | r1, (char*)&ref.is_value - (char*)&ref, jit::SLJIT_MOV_U8);
                        void* indirect = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, 0);
                        e.mov(r0, 0, mem | r1, (char*)&ref.value - (char*)&ref);
                        void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
                        e.bind(indirect);
                        e.mov(r3, 0, mem | r1, (char*)&ref.guard_shadow - (char*)&ref, jit::SLJIT_MOV_U8);
                        out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pos);
                        e.mov(r2, 0, mem | r1, (char*)&ref.owner - (char*)&ref);
                        out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pos);
                        e.mov(r0, 0, mem | r1, (char*)&ref.prop_idx - (char*)&ref, jit::SLJIT_MOV_U32);
                        e.mov(r3, 0, mem | r2, (char*)&owner.prop_count - (char*)&owner, jit::SLJIT_MOV_U32);
                        out.guard(jit::SLJIT_GREATER_EQUAL, r0, 0, r3, 0, pos);
                        // Capture owners use ordinary binding/cell objects.
                        e.mov(r3, 0, mem | r2, 0, jit::SLJIT_MOV_U32);
                        e.op(jit::SLJIT_AND, r3, r3, 0, imm, 0x003F0000);
                        out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)(ObjClass.OBJECT.ordinal << 16), pos);
                        e.op(jit::SLJIT_SHL, r0, r0, 0, imm, 3);
                        e.mov(r3, 0, mem | r2, (char*)&owner.prop_alloc - (char*)&owner);
                        void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0);
                        e.op(jit::SLJIT_ADD, r3, r2, 0, imm, HObjectBase::size);
                        e.bind(allocated);
                        e.op(jit::SLJIT_ADD, r3, r3, 0, r0, 0);
                        e.mov(r0, 0, mem | r3, 0);
                        e.bind(done);
                        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                        void* initialized = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED);
                        out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)(types::TAG_UNDEFINED << 48), pos);
                        e.bind(initialized);
                    }
                }
            case GETVAR:
            case GETGLOBAL:

                {
                    VarICEntry* vic = (VarICEntry*)cf.var_ic_entries + pos;
                    VarICEntry view;
                    Activation activation;
                    Heap heap_view;
                    e.mov(r2, 0, imm, (long)vic);
                    if (ins.op == Opcode.GETVAR) {
                        e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(1));
                        e.mov(r3, 0, mem | r3, (char*)&activation.lex_env - (char*)&activation);
                        out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, mem | r2, (char*)&view.search_head - (char*)&view, pos);
                    }
                    e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
                    e.mov(
                        r3,
                        0,
                        mem | r3,
                        (char*)&heap_view.shape_recycle_epoch - (char*)&heap_view,
                        jit::SLJIT_MOV_U32
                    );
                    e.mov(r1, 0, mem | r2, (char*)&view.recycle_epoch - (char*)&view, jit::SLJIT_MOV_U32);
                    out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, r1, 0, pos);
                    e.mov(r3, 0, mem | r2, (char*)&view.prop_flags - (char*)&view, jit::SLJIT_MOV_U8);
                    e.op(jit::SLJIT_AND, r3, r3, 0, imm, 8);
                    out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, pos);
                    e.mov(r2, 0, mem | r2, (char*)&view.slot_ptr - (char*)&view);
                    out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pos);
                    e.mov(r0, 0, mem | r2, 0);
                    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                    void* initialized = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_UNDEFINED);
                    out.guard(jit::SLJIT_NOT_EQUAL, r0, 0, imm, (long)(types::TAG_UNDEFINED << 48), pos);
                    e.bind(initialized);
                }
            case PUTCAP:
                e.mov(r2, 0, jit::reg_s(4), 0);
                e.mov(r0, 0, mem | r2, 0);
                e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, pos);
                out.load(ins.a, r0);
                e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                out.guard(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_BOOLEAN, pos);
                e.mov(mem | r2, 0, r0, 0);
                if (out.flow != null) out.flow.drop(ins.a);
                e.mov(
                    out.cached(ins.a) != 0 ? out.cached(ins.a) : mem | jit::reg_s(0),
                    out.cached(ins.a) != 0 ? 0 : loop_value_offset(ins.a),
                    imm,
                    (long)(types::TAG_UNDEFINED << 48)
                );
                continue;
            case INC_VAR:
            case DEC_VAR:
                e.mov(r2, 0, jit::reg_s(4), 0);
                e.mov(r0, 0, mem | r2, 0);
                e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
                out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT, pos);
                e.op(jit::SLJIT_SHL, r0, r0, 0, imm, 16);
                e.op(jit::SLJIT_ASHR, r0, r0, 0, imm, 16);
                e.op(ins.op == Opcode.INC_VAR ? jit::SLJIT_ADD : jit::SLJIT_SUB, r0, r0, 0, imm, 1);
                out.range(r0, pos);
                out.box(r0);
                f.store(ins.a, pos, true);
                e.mov(r2, 0, jit::reg_s(4), 0);
                e.mov(mem | r2, 0, r0, 0);
                continue;
            case GETPROPC:
            case GETPROPC_CACHED:
            case PUTPROPC:
            case GETPROP:
            case GETPROP_CACHE:
            case PUTPROP:
            case GETTHISC:
            case PUTTHISC:
                if (ins.op == Opcode.GETPROP || ins.op == Opcode.GETPROP_CACHE || ins.op == Opcode.PUTPROP) {
                    supported[pos] = f.indexed(cf, pos, ins.op == Opcode.PUTPROP, h);
                } else {
                    supported[pos] = f.property(cf, pos, ins.op == Opcode.PUTPROPC || ins.op == Opcode.PUTTHISC, h);
                }
                if (!supported[pos] && pos + 1 < cf.code_count) f.blocks[pos + 1] = true;
                continue;
            case BAND:
            case BOR:
            case BXOR:
            case SHL:
            case SHR:
            case USHR:
            case BANDI:
            case BORI:
            case BXORI:
            case SHLI:
            case SHRI:
            case USHRI:
            case BNOT:
            case UNM:
            case UNP:
                f.bitwise(ins, pos);
                continue;
            case TONUMERIC:
                out.integer(ins.b, r0, pos);
                out.box(r0);
            case INC:
            case INC_LT:
            case DEC:
                out.integer(ins.a, r0, pos);
                e.op(ins.op == Opcode.DEC ? jit::SLJIT_SUB : jit::SLJIT_ADD, r0, r0, 0, imm, 1);
                out.range(r0, pos);
                out.box(r0);
            case LNOT:

                {
                    f.truth(ins.b, pos);
                    void* truthy = e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0);
                    e.mov(r0, 0, imm, (long)((types::TAG_BOOLEAN << 48) | 1));
                    void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
                    e.bind(truthy);
                    e.mov(r0, 0, imm, (long)(types::TAG_BOOLEAN << 48));
                    e.bind(done);
                }
            case TYPEOF: f.typeof_value(cf, pos, h); continue;
            case LT:
            case LE:
            case GT:
            case GE:

                {
                    Instruction compare = ins;
                    compare.op = loop_compare(ins.op);
                    void*[2] skips = out.condition(compare, pos);
                    e.mov(r0, 0, imm, (long)((types::TAG_BOOLEAN << 48) | 1));
                    void* done   = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
                    void* failed = e.label();
                    foreach (jump : skips) if (jump != null) out.bind_to(jump, failed);
                    e.mov(r0, 0, imm, (long)(types::TAG_BOOLEAN << 48));
                    e.bind(done);
                }
            case SEQ:
            case SNEQ:
                f.equal(ins, false, ins.op == Opcode.SNEQ, pos);
                e.op(jit::SLJIT_OR, r0, r0, 0, imm, (long)(types::TAG_BOOLEAN << 48));
            case EQ:
            case NEQ:
                f.loose_equal(ins, ins.op == Opcode.NEQ, pos);
            default:
                if (out.flow != null && function_float_op(ins.op)) {
                    f.flow_numeric(ins, pos);
                } else {
                    out.numeric(ins, pos);
                }
                continue;
        }
        bool known = ins.op == Opcode.LDINT || ins.op == Opcode.LDTRUE || ins.op == Opcode.LDFALSE
            || ins.op == Opcode.LDNULL
            || ins.op == Opcode.LDUNDEF
            || ins.op == Opcode.VOID
            || ins.op == Opcode.INC
            || ins.op == Opcode.INC_LT
            || ins.op == Opcode.DEC
            || ins.op == Opcode.TONUMERIC
            || ins.op == Opcode.LNOT
            || ins.op == Opcode.SEQ
            || ins.op == Opcode.SNEQ
            || (ins.op >= Opcode.LT && ins.op <= Opcode.GE)
            || (ins.op == Opcode.GETCAP && (plan.capture_writes & (1U << ins.get_bc())) != 0);
        if (ins.op == Opcode.LDCONST) {
            TVal value = cf.constants[ins.get_bc()];
            known = !value.is_refcounted() || value.get_heapptr() == null
                || ((HeapHeader*)value.get_heapptr()).is_pinned();
        }
        f.store(ins.a, pos, known);
        if (out.flow != null && (ins.op == Opcode.LDREG || ins.op == Opcode.LDTHIS)) {
            f.flow.same_value(ins.a, copy_token, copy_shape);
        }
    }
    out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), cf.code_count, true);
    if (e.failed) return false;
    void*[FUNCTION_OPS + 1] exits;
    void*[2048] flow_exits;
    for (uint i = 0; i < out.link_count; i++) {
        LoopLink link = out.links[i];
        if (!link.exit) {
            out.bind_to(link.jump, out.labels[link.target]);
            continue;
        }
        void* existing;
        if (link.flow == 0 && link.target <= FUNCTION_OPS) {
            existing = exits[link.target];
        } else {
            for (uint j = 0; j < i; j++) {
                if (out.links[j].exit && out.links[j].target == link.target && out.links[j].flow == link.flow) {
                    existing = flow_exits[j];
                    if (existing != null) break;
                }
            }
        }
        if (existing != null) {
            flow_exits[i] = existing;
            out.bind_to(link.jump, existing);
            continue;
        }
        void* label = e.label();
        if (link.flow == 0 && link.target <= FUNCTION_OPS) exits[link.target] = label;
        flow_exits[i] = label;
        out.bind_to(link.jump, label);
        f.flow_exit(link.flow);
        for (uint j = 0; j < cf.num_regs && j < LOOP_REGS; j++) if (plan.cache[j] != 0) {
            e.mov(mem | jit::reg_s(0), loop_value_offset(j), plan.cache[j], 0);
        }
        if (link.target == FUNCTION_BAIL) {
            e.mov(r0, 0, imm, uint::max);
        } else {
            e.mov(r0, 0, imm, link.target);
        }
        if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) e.failed = true;
    }
    if (e.failed) return false;
    plan.native = (FunctionNative)jit::sljit_generate_code(e.compiler, 0, null);
    if (plan.native == null) return false;
    plan.code_bytes = jit::sljit_shim_code_size(e.compiler);
    uint entries;
    bool[FUNCTION_OPS] loop_headers;
    for (uint i = 0; i < cf.code_count; i++) {
        int target = loop_target(cf.code[i], i);
        if (!supported[i] || target < 0 || target > (int)i) continue;
        bool complete = true;
        for (uint j = (uint)target; j <= i; j++) if (!supported[j]) {
            complete = false;
            break;
        }
        if (complete) loop_headers[target] = true;
    }
    uint[FUNCTION_OPS + 1] span;
    for (uint reverse = cf.code_count; reverse > 0; reverse--) {
        uint i = reverse - 1;
        if (!supported[i]) continue;
        uint following = span[i + 1];
        int target     = loop_target(cf.code[i], i);
        if (target > (int)i && target < (int)cf.code_count && span[target] > following) following = span[target];
        span[i] = following + 1;
        if ((span[i] >= plan.min_span || loop_headers[i]) && (!FUNCTION_DATAFLOW || f.blocks[i])) {
            plan.entries[i] = (void*)jit::sljit_shim_label_addr(out.labels[i]);
            entries++;
        }
    }
    if (entries == 0) {
        jit::sljit_free_code((void*)plan.native, null);
        plan.native = null;
        return false;
    }
    return true;
}
fn void sljit_function_free(Heap* h, CompiledFunction* cf) @feat(SLJIT) {
    FunctionPlan* plan = cf.sljit_function;
    if (plan == null) return;
    $if $feat(SLJIT_STATS):
        io::eprintfn(
            "SLJIT function %s hits=%d returns=%d backedges=%d budget_exits=%d code_bytes=%d",
            (String)cf.get_name(),
            plan.hits,
            plan.completed,
            plan.backedges,
            plan.budget_exits,
            plan.code_bytes
        );
    $endif
    jit::sljit_free_code((void*)plan.native, null);
    h.jit_code_bytes -= plan.code_bytes;
    h.free_func(h.heap_udata, plan);
    cf.sljit_function = null;
}
macro bool sljit_function_resumes(Instruction* pc, CompiledFunction* cf) @feat(SLJIT) {
    FunctionPlan* plan = cf.sljit_function;
    uint offset        = (uint)(pc - cf.code);
    return plan != null && offset >= plan.begin && offset - plan.begin < plan.count
        && plan.entries[offset - plan.begin] != null;
}
fn FunctionPlan* sljit_function_compile(CompiledFunction* cf, ColdCtx* cold, uint begin = 0) @feat(SLJIT) @noinline {
    Heap* h = cold.heap;
    $if $feat(SLJIT_STATS):
        if (begin != 0) io::eprintfn(
            "SLJIT region attempt ops=%d regs=%d begin=%d budget_used=%d",
            cf.code_count,
            cf.num_regs,
            begin,
            h.jit_code_bytes
        );
    $endif
    if (begin >= cf.code_count || h.jit_code_bytes >= LOOP_CODE_LIMIT) return null;
    // The view borrows the original bytecode, constants and site caches. Only
    // the region's instruction window consumes compiler tables/code budget.
    CompiledFunction region = *cf;
    region.code += begin;
    uint limit = cf.code_count > FUNCTION_OPS || cf.num_regs > LOOP_REGS ? FUNCTION_REGION_OPS : FUNCTION_OPS;
    // At a hot header select its whole loop, including nested loops and
    // forward exits inside the body. A loop exceeding the bounded compiler
    // tables retains the existing forward-region fallback.
    uint loop_end;
    bool oversized;
    if (begin != 0 || cf.code_count > FUNCTION_OPS) {
        for (uint i = begin; i < cf.code_count; i++) {
            if (loop_target(cf.code[i], i) != (int)begin) continue;
            if (i - begin >= FUNCTION_OPS) {
                oversized = true;
                break;
            }
            loop_end = i - begin + 1;
        }
    }
    if (!oversized && loop_end > limit) limit = loop_end;
    region.code_count = cf.code_count - begin < limit ? cf.code_count - begin : limit;
    region.ic_entries = (ICEntry*)cf.ic_entries + begin;
    region.var_ic_entries = (VarICEntry*)cf.var_ic_entries + begin;
    usz bytes          = FunctionPlan::size + region.code_count * (void*::size + 1);
    FunctionPlan* plan = (FunctionPlan*)h.alloc_func(h.heap_udata, bytes);
    if (plan == null) return null;
    mem::clear(plan, (sz)bytes);
    plan.begin = begin;
    plan.count = region.code_count;
    plan.min_span = cf.code_count > FUNCTION_OPS || cf.num_regs > LOOP_REGS ? FUNCTION_MIN_SPAN : 6;
    plan.entries = (void**)((char*)plan + FunctionPlan::size);
    plan.short_runs = (char*)(plan.entries + plan.count);
    bool analyzed = function_analyze(&region, plan, h);
    bool emitted  = analyzed && function_emit(plan, &region, h, cold.act);
    $if $feat(SLJIT_STATS):
        if (begin != 0) io::eprintfn(
            "SLJIT region result %s ops=%d analyzed=%d emitted=%d code_bytes=%d budget_used=%d limit=%d",
            (String)cf.get_name(),
            cf.code_count,
            analyzed,
            emitted,
            plan.code_bytes,
            h.jit_code_bytes,
            LOOP_CODE_LIMIT
        );
    $endif
    if (!emitted || h.jit_code_bytes + plan.code_bytes > LOOP_CODE_LIMIT) {
        if (plan.native != null) jit::sljit_free_code((void*)plan.native, null);
        h.free_func(h.heap_udata, plan);
        return null;
    }
    cf.sljit_function = plan;
    h.jit_code_bytes += plan.code_bytes;
    plan.shape_clock = h.shape_gen_clock;
    plan.shape_epoch = h.shape_recycle_epoch;
    if (begin == 0 && plan.entries[0] != null) cf.sljit_function_calls = uint::max - 1;
    $if $feat(SLJIT_STATS):
        io::eprintfn(
            "SLJIT function compiled %s pc=%d..%d function_ops=%d regs=%d code_bytes=%d plan_bytes=%d",
            (String)cf.get_name(),
            begin,
            begin + plan.count,
            cf.code_count,
            cf.num_regs,
            plan.code_bytes,
            bytes
        );
    $endif
    return plan;
}
fn Instruction* sljit_function_entry(
    Instruction* pc,
    TVal* regs,
    ColdCtx* cold,
    bool region = false
) @feat(SLJIT) @noinline {
    Heap* h              = cold.heap;
    CompiledFunction* cf = cold.vm.current_func;
    if (!h.jit_enabled || !types::USE_NANBOX || usz::size != 8 || h.gc_phase != heap::GcPhase.IDLE
        || h.uncatchable_throw
        || std::core::mem::@atomic_load(
        h.interrupt_requested
    ) != 0) return pc;
    uint offset        = (uint)(pc - cf.code);
    FunctionPlan* plan = cf.sljit_function;
    if (plan == null) {
        if (cf.sljit_function_calls == uint::max) return pc;
        // Every function size warms on taken backedges as well as calls. A
        // region may start at a hot header, not only at bytecode zero.
        if (offset == 0) {
            if (++cf.sljit_function_calls < 64) return pc;
        } else if (!region || cf.sljit_function_calls < 64) return pc;
        cf.sljit_function_calls = uint::max;
        plan = sljit_function_compile(cf, cold, offset);
        if (plan == null) return pc;
    }
    if (!sljit_function_resumes(pc, cf)) return pc;
    uint local = offset - plan.begin;
    if (plan.shape_clock != h.shape_gen_clock || plan.shape_epoch != h.shape_recycle_epoch) {
        for (uint i = 0; i < plan.shape_count; i++) {
            Shape* shape = h.get_shape(plan.shapes[i]);
            if (shape == null || shape.generation != plan.generations[i]) {
                sljit_function_free(h, cf);
                cf.sljit_function_calls = 0;
                return pc;
            }
        }
        plan.shape_clock = h.shape_gen_clock;
        plan.shape_epoch = h.shape_recycle_epoch;
    }
    if (cold.act.heap_reg_count < plan.heap_regs) cold.act.heap_reg_count = plan.heap_regs;
    TVal[4] previous @noinit;
    for (uint i = 0; i < plan.cache_count; i++) previous[i] = regs[plan.cached_regs[i]];
    long budget     = h.bwd_gc_budget;
    bool interrupts = h.capi_runtime != null || h.capi_interrupt_fn != null;
    if (interrupts && (long)h.interrupt_budget < budget) budget = h.interrupt_budget;
    if (h.interrupt_due || budget <= 1) return pc;
    // Bound publication even when the host configures a very large poll budget.
    if (budget > 1024) budget = 1024;
    // Inline scratch is written before each read; avoid clearing 256 bytes
    // on every native entry. Only metadata-cache keys require initialization.
    FunctionRun run @noinit;
    run.entry = plan.entries[local];
    run.budget = budget;
    run.typed[0].receiver = null;
    run.typed[1].receiver = null;
    uint next     = plan.native(regs, cold, &run);
    uint consumed = (uint)(budget - run.budget);
    h.bwd_gc_budget -= consumed;
    if (interrupts) h.interrupt_budget -= consumed;
    // Native exit publishes the borrowed cache. Retain every new string before
    // releasing any old one: values can move between cached registers.
    for (uint i = 0; i < plan.cache_count; i++) {
        TVal value = regs[plan.cached_regs[i]];
        if (!value.same_bits(&previous[i]) && value.is_refcounted() && value.get_heapptr() != null) {
            ((HeapHeader*)value.get_heapptr()).incref();
        }
    }
    for (uint i = 0; i < plan.cache_count; i++) {
        if (!regs[plan.cached_regs[i]].same_bits(&previous[i])) h.decref_tval(&previous[i]);
    }
    next = next == uint::max ? offset : plan.begin + next;
    // A run that stops at the same unexpandable call without completing a
    // backedge repeats the same prefix on every entry loop iteration. Let the
    // interpreter own the function once that is clearly never going to pay.
    bool at_call = next < cf.code_count && function_call_op(cf.code[next].op);
    bool stuck = consumed == 0 && next >= offset
        && (next - offset < plan.min_span || at_call);
    if (stuck) {
        if (++plan.short_runs[local] >= 8) {
            plan.entries[local] = null;
            if (offset == 0) cf.sljit_function_calls = uint::max;
        }
    } else {
        plan.short_runs[local] = 0;
    }
    $if $feat(SLJIT_STATS):
        plan.hits++;
        plan.backedges += consumed;
        if (next < cf.code_count && next < 512) plan.exit_pcs[next]++;
        if (run.budget <= 1 && consumed != 0) plan.budget_exits++;
        if (next == offset) plan.stalled++;
        if (next < cf.code_count
            && (cf.code[next].op == Opcode.RET || cf.code[next].op == Opcode.RETUNDEF)) plan.completed++;
        if (plan.hits == 1 || plan.hits == 1000) io::eprintfn(
            "SLJIT function native %s function_ops=%d begin=%d hits=%d returns=%d stalled=%d pc=%d",
            (String)cf.get_name(),
            cf.code_count,
            plan.begin,
            plan.hits,
            plan.completed,
            plan.stalled,
            next
        );
        if (plan.hits == 1 || plan.hits == 1000) io::eprintfn(
            "SLJIT residency function_ops=%d begin=%d backedges=%d budget_exits=%d",
            cf.code_count,
            plan.begin,
            plan.backedges,
            plan.budget_exits
        );
        if (plan.hits == 1 || plan.hits == 1000) io::eprintfn(
            "SLJIT typed function_ops=%d begin=%d reads=%d writes=%d lengths=%d fp_ops=%d math_calls=%d inline_calls=%d bail_calls=%d bail_ops=%d general=%d",
            cf.code_count,
            plan.begin,
            plan.typed_reads,
            plan.typed_writes,
            plan.typed_lengths,
            plan.flow_ops,
            plan.math_calls,
            plan.inline_calls,
            plan.bail_calls,
            plan.bail_ops,
            plan.general_inlines
        );
        if (plan.hits % 10000 == 0) {
            uint shown;
            for (uint i = 0; i < 512; i++) {
                if (plan.exit_pcs[i] == 0) continue;
                io::eprintfn(
                    "SLJIT exit %s ops=%d begin=%d pc=%d op=%d count=%d",
                    (String)cf.get_name(),
                    cf.code_count,
                    plan.begin,
                    i,
                    i < cf.code_count ? (int)cf.code[i].op : -1,
                    plan.exit_pcs[i]
                );
                shown++;
            }
            if (shown == 0) io::eprintfn("SLJIT exit %s none", (String)cf.get_name());
        }
    $endif
    return cf.code + next;
}
// Large functions warm a bounded region at a taken loop header. Native
// backedges return before the shared GC/interrupt budget reaches its poll.
fn bool sljit_function_backedge(Instruction* pc, CompiledFunction* cf) @feat(SLJIT) @inline {
    int target = loop_target(*pc, (uint)(pc - cf.code));
    if (target < 0) return false;
    if (cf.sljit_function != null) return sljit_function_resumes(cf.code + target, cf);
    return cf.sljit_function_calls != uint::max && ++cf.sljit_function_calls >= 64;
}
fn Instruction* sljit_function_region(Instruction* pc, TVal* regs, ColdCtx* cold) @feat(SLJIT) @inline {
    CompiledFunction* cf = cold.vm.current_func;
    if (cf.sljit_function_calls < 64) cf.sljit_function_calls++;
    return sljit_function_entry(pc, regs, cold, true);
}
fn Instruction* sljit_function_dispatch(
    Instruction* pc,
    HandlerTable* handlers,
    TVal* regs,
    ColdCtx* cold
) @feat(SLJIT) @noinline {
    return th_next(sljit_function_entry(pc, regs, cold), handlers, regs, cold);
}