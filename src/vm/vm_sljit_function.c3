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
    Activation* root;
    uint depth;
    Instruction* start;
    FunctionInlineFrame* recover_frame;
    uint recover_pc;
    void* helper_continuation;
    Instruction* helper_pc;
    ulong clock;
    FunctionTypedCache[2] typed;
    double[32 * INLINE_DEPTH] inline_values;
}
alias FunctionNative = fn Instruction*(TVal* regs, ColdCtx* cold, FunctionRun* run);

// VM registers own every published value. Generated lean calls share the run;
// operations that may allocate, invoke unknown code or throw escape with all
// live activations published. Calls and backedges bound native progress.
struct FunctionPlan @feat(SLJIT) {
    FunctionNative native;
    void* call_entry;
    FunctionCallLink* calls;
    void* resume_fragment;
    usz resume_bytes;
    uint numeric_homes;
    ulong last_use;
    void*[FUNCTION_OPS + 1] map_pcs @if($feat(SLJIT_MAP));
    void* map_calls @if($feat(SLJIT_MAP));
    FunctionInlineFrame* inline_frames;
    ushort inline_count;
    uint begin;
    uint count;
    uint min_span;
    void** entries;
    char* short_runs;
    uint capture_writes;
    uint heap_regs;
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
    ulong direct_calls @if($feat(SLJIT_STATS));
    ulong direct_returns @if($feat(SLJIT_STATS));
    ulong inline_recoveries @if($feat(SLJIT_STATS));
    ulong resumed_allocations @if($feat(SLJIT_STATS));
    ulong resumed_pushes @if($feat(SLJIT_STATS));
    ulong stalled @if($feat(SLJIT_STATS));
    // Calls plus backward branches across the native run.
    ulong charged_edges @if($feat(SLJIT_STATS));
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
    if (function_alloc_op(op)) return true;
    switch (op) {
        case RET:
        case RETUNDEF:
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
    $if $feat(SLJIT_STATS): cf.sljit_rejection = "function eligibility"; $endif
    if (cf.code_count > FUNCTION_OPS || cf.flags.is_generator || cf.flags.is_async || cf.flags.has_direct_eval
        || cf.mapped_arguments()) {
        $if $feat(SLJIT_STATS):
            cf.sljit_rejection = cf.code_count > FUNCTION_OPS ? "region size"
                : cf.flags.is_generator ? "generator"
                : cf.flags.is_async ? "async"
                : cf.flags.has_direct_eval ? "direct eval" : "mapped arguments";
        $endif
        return false;
    }
    for (uint pos = 0; pos < cf.code_count; pos++) {
        Instruction ins = cf.code[pos];
        // WIDE payloads cannot be decoded independently on a native resume.
        if (ins.op == Opcode.WIDE) {
            $if $feat(SLJIT_STATS): cf.sljit_rejection = "WIDE"; $endif
            return false;
        }
        if (ins.op == Opcode.PUTCAP || ins.op == Opcode.INC_VAR || ins.op == Opcode.DEC_VAR) {
            int cap = function_capture_index(cf, ins);
            if (cap >= 0) plan.capture_writes |= 1U << cap;
        }
        if (ins.op == Opcode.LDTHIS || ins.op == Opcode.GETTHISC || ins.op == Opcode.PUTTHISC) plan.receiver = true;
    }
    // Baseline slots own their values at every call and side exit. The old
    // borrowed scratch cache cannot survive nested execution or allocation.
    plan.heap_regs = cf.num_regs;
    plan.min_span = 1;
    $if $feat(SLJIT_STATS): cf.sljit_rejection = null; $endif
    return true;
}
fn long function_cold_offset(uint field) @feat(SLJIT) {
    ColdCtx cold;
    return field == 0 ? (char*)&cold.heap - (char*)&cold : (char*)&cold.act - (char*)&cold;
}
fn void function_store(LoopEmitter* out, uint reg, int source, uint pc, bool inert = false) @feat(SLJIT) {
    TemplateEmitter* e = &out.e;
    bool old_inert = out.flow != null && out.flow.unowned[reg];
    if (out.flow != null) {
        out.flow.drop(reg);
        out.flow.unowned[reg] = inert;
    }
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
        // Recoverable inline windows hold traced/inert values. A counted
        // value stays with the interpreter, before the producing operation.
        if (out.inline_frame != null) {
            e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
            out.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_STRING, pc);
        }
        e.mov(mem | out.state_base(), loop_value_offset(reg), r0, 0);
        return;
    }
    if (out.cached(reg) != 0) {
        // Cache values are borrowed until native exit. Original VM slots keep
        // their owners alive; no call, allocation or collection occurs here.
        e.mov(out.cached(reg), 0, r0, 0);
        return;
    }
    // Both values are proven to need no refcount change in this block. No reference count
    // can change, and no release guard is needed. Calls and entries clear
    // these facts; a later string definition restores the owning store.
    if (old_inert && inert) {
        e.mov(mem | out.state_base(), loop_value_offset(reg), r0, 0);
        return;
    }
    out.load(reg, r1);
    HeapHeader header;
    long refs = (char*)&header.refcount - (char*)&header;
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    void* old_unowned = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_STRING);
    e.op(jit::SLJIT_AND, r2, r1, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    void* old_null = e.cmp(jit::SLJIT_EQUAL, r2, 0, imm, 0);
    void* same     = e.cmp(jit::SLJIT_EQUAL, r0, 0, r1, 0);
    e.mov(r3, 0, mem | r2, refs, jit::SLJIT_MOV_U32);
    out.guard(jit::SLJIT_LESS_EQUAL, r3, 0, imm, 1, pc);
    e.bind(same);
    e.bind(old_null);
    e.bind(old_unowned);
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
    int r1             = jit::reg_r(1);
    int r3             = jit::reg_r(3);
    int imm            = jit::SLJIT_IMM;
    int mem            = jit::SLJIT_MEM;
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
    // An object is truthy, except the document.all sentinel: [[IsHTMLDDA]]
    // makes exactly that object falsy, and the heap holds its identity.
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    Heap heap_view;
    e.mov(r1, 0, mem | jit::reg_s(1), function_cold_offset(0));
    e.mov(r1, 0, mem | r1, (char*)&heap_view.htmldda_obj - (char*)&heap_view);
    void* sentinel = e.cmp(jit::SLJIT_EQUAL, r0, 0, r1, 0);
    e.mov(r0, 0, imm, 1);
    void* object_done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(sentinel);
    e.mov(r0, 0, imm, 0);
    e.bind(object_done);
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
    int mem            = jit::SLJIT_MEM;
    self.out.load(ins.b, r0);
    self.out.load(ins.c, r1);
    e.op(jit::SLJIT_LSHR, r2, r0, 0, imm, 48);
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    void* nonnumber_left = e.cmp(jit::SLJIT_GREATER, r2, 0, imm, (long)types::TAG_FASTINT);
    void* nonnumber_right = e.cmp(jit::SLJIT_GREATER, r3, 0, imm, (long)types::TAG_FASTINT);
    self.out.number(r0, 1, pc);
    self.out.number(r1, 2, pc);
    void* number_equal = self.out.fcmp(jit::SLJIT_ORDERED_EQUAL, 1, 2);
    e.mov(r0, 0, imm, (long)(types::TAG_BOOLEAN << 48) | (negate ? 1 : 0));
    void* number_done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(number_equal);
    e.mov(r0, 0, imm, (long)(types::TAG_BOOLEAN << 48) | (negate ? 0 : 1));
    void* number_equal_done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(nonnumber_left);
    e.bind(nonnumber_right);
    // Null and undefined are equal to each other and to the document.all
    // sentinel, and to nothing else, which is the `x == null` idiom. Their
    // tags are adjacent, so a shifted difference is 0 or 1 for exactly those
    // two values.
    e.op(jit::SLJIT_SUB, r2, r2, 0, imm, (long)types::TAG_UNDEFINED);
    e.op(jit::SLJIT_SUB, r3, r3, 0, imm, (long)types::TAG_UNDEFINED);
    void* n0 = e.cmp(jit::SLJIT_LESS_EQUAL, r2, 0, imm, 1);
    void* n1 = e.cmp(jit::SLJIT_LESS_EQUAL, r3, 0, imm, 1);
    void* neither = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    // Left side nullish: equal when the right side is too, or is the sentinel
    // whose identity the heap holds.
    e.bind(n0);
    void* n2 = e.cmp(jit::SLJIT_LESS_EQUAL, r3, 0, imm, 1);
    e.op(jit::SLJIT_LSHR, r2, r1, 0, imm, 48);
    void* right_obj = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)types::TAG_OBJECT);
    e.op(jit::SLJIT_AND, r2, r1, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    Heap heap_view;
    e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
    e.mov(r3, 0, mem | r3, (char*)&heap_view.htmldda_obj - (char*)&heap_view);
    void* right_dda = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, r3, 0);
    void* right_eq = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    // Right side nullish and left side not: equal only for the sentinel.
    e.bind(n1);
    e.op(jit::SLJIT_LSHR, r2, r0, 0, imm, 48);
    void* left_obj = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)types::TAG_OBJECT);
    e.op(jit::SLJIT_AND, r2, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
    e.mov(r3, 0, mem | r3, (char*)&heap_view.htmldda_obj - (char*)&heap_view);
    void* left_dda = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, r3, 0);
    void* left_eq = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(neither);
    e.op(jit::SLJIT_LSHR, r2, r0, 0, imm, 48);
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    // Two objects compare by reference. Anything else (coercion, symbols,
    // BigInts) is the interpreter's abstract equality.
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)types::TAG_OBJECT, pc);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    void* same = e.cmp(jit::SLJIT_EQUAL, r0, 0, r1, 0);
    e.bind(right_obj);
    e.bind(right_dda);
    e.bind(left_obj);
    e.bind(left_dda);
    e.mov(r0, 0, imm, negate ? (((long)types::TAG_BOOLEAN << 48) | 1) : ((long)types::TAG_BOOLEAN << 48));
    void* finish = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(n2);
    e.bind(right_eq);
    e.bind(left_eq);
    e.bind(same);
    e.mov(r0, 0, imm, negate ? ((long)types::TAG_BOOLEAN << 48) : (((long)types::TAG_BOOLEAN << 48) | 1));
    e.bind(finish);
    e.bind(number_done);
    e.bind(number_equal_done);
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

// A store that adds a property the receiver and its whole prototype chain
// lack. The absent-property cache names the shape the append moves the
// receiver to, so the store needs no lookup of the key or of the transition.
// The guards mirror the interpreter's absent-put path: a receiver with a
// different chain, flags or storage leaves to the interpreter, which owns
// growth, reference counts and the write barrier. The receiver arrives in r0
// still boxed.
fn void FunctionEmitter.append_property(&self, CompiledFunction* cf, uint pc, ICEntry* ic, Heap* h) @feat(SLJIT) {
    TemplateEmitter* e = &self.out.e;
    Instruction ins = cf.code[pc];
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    uint value_reg = ins.op == Opcode.PUTTHISC ? ins.a : ins.b;
    HObject obj;
    long shape_offset = (char*)&obj.shape_id - (char*)&obj;
    long proto_offset = (char*)&obj.prototype - (char*)&obj;
    // The receiver must be an object.
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    // An ordinary extensible object: the append installs a plain data
    // property, so no exotic [[Set]] may intercept it.
    ObjFlags ordinary; ordinary.obj_class = OBJECT;
    ObjFlags forbidden;
    forbidden.exotic_proxyobj = true;
    forbidden.exotic_module_ns = true;
    forbidden.exotic_deferred_ns = true;
    ObjFlags extensible; extensible.extensible = true;
    e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, 0x003F0000U | (uint)forbidden);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
    e.mov(r2, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, (uint)extensible);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)extensible, pc);
    // The receiver must be on the shape the cache names, and the recycle epoch
    // must still hold, or the recorded transition is stale.
    e.mov(r2, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.shape_id, pc);
    Heap heap_view;
    e.mov(r2, 0, mem | jit::reg_s(1), function_cold_offset(0));
    e.mov(r2, 0, mem | r2, (char*)&heap_view.shape_recycle_epoch - (char*)&heap_view, jit::SLJIT_MOV_U32);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.shape_gen, pc);
    // The property storage must have a free slot and no hash table.
    e.mov(r1, 0, mem | r0, (char*)&obj.prop_count - (char*)&obj, jit::SLJIT_MOV_U32);
    e.mov(r2, 0, mem | r0, (char*)&obj.prop_capacity - (char*)&obj, jit::SLJIT_MOV_U32);
    self.out.guard(jit::SLJIT_GREATER_EQUAL, r1, 0, r2, 0, pc);
    e.mov(r2, 0, mem | r0, (char*)&obj.prop_hash - (char*)&obj);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0, pc);
    // An observed prototype needs the prototype epoch bumped, which only the
    // interpreter does.
    GcBits observed; observed.prototype_observed = true;
    e.mov(r2, 0, mem | r0, (char*)&obj.gc - (char*)&obj, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r2, r2, 0, imm, (uint)observed);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0, pc);
    // The chain must be the one the cache recorded: every link the same
    // object with the same shape, and nothing after the last link.
    e.mov(r3, 0, mem | r0, proto_offset);
    for (uint i = 0; i < ic.chain_len; i++) {
        self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)ic.chain.snapshot.protos[i], pc);
        e.mov(r2, 0, mem | r3, shape_offset, jit::SLJIT_MOV_U32);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, ic.chain.snapshot.shapes[i], pc);
        e.mov(r2, 0, mem | r3, 0, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_AND, r2, r2, 0, imm, 0x003F0000U | (uint)forbidden);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (uint)ordinary, pc);
        e.mov(r3, 0, mem | r3, proto_offset);
    }
    self.out.guard(jit::SLJIT_EQUAL, r3, 0, imm, 0, pc);
    // The value takes the next free slot: the inline storage while the object
    // has none, and the block the heap allocated once it did.
    e.mov(r2, 0, mem | r0, (char*)&obj.prop_alloc - (char*)&obj);
    void* external = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
    e.op(jit::SLJIT_ADD, r2, r0, 0, imm, HObjectBase::size);
    e.bind(external);
    e.op(jit::SLJIT_SHL, r3, r1, 0, imm, 3);
    e.op(jit::SLJIT_ADD, r2, r2, 0, r3, 0);
    // The slot starts empty, so the store has no old value to release.
    e.mov(mem | r2, 0, imm, 0);
    self.slot_store(r0, r2, 0, value_reg, pc);
    // The receiver moves to the shape the cache names. The store keeps the
    // owner in r1.
    e.mov(r2, 0, mem | r1, (char*)&obj.prop_count - (char*)&obj, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_ADD, r2, r2, 0, imm, 1);
    e.mov(mem | r1, (char*)&obj.prop_count - (char*)&obj, r2, 0, jit::SLJIT_MOV_U32);
    e.mov(mem | r1, shape_offset, imm, ic.absent_next_shape, jit::SLJIT_MOV_U32);
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
    // A store that adds a property the receiver and its whole prototype chain
    // lack: the absent-property cache names the shape the append moves the
    // receiver to, so the store needs no lookup of the key or of the
    // transition.
    if (write && !computed && ic.prop_idx == hobject::IC_PROP_ABSENT) {
        if (ic.key.borrow() == null || key == null || ic.key.borrow() != key
            || ic.has_proto || (uint)ic.chain_len > hobject::IC_MAX_CHAIN
            || h.get_shape(ic.absent_next_shape) == null
            || ((HString*)key).is_arridx() || ((HString*)key).flags.is_hidden) {
            self.out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pc, true);
            return false;
        }
        self.append_property(cf, pc, ic, h);
        if (tracking) self.flow.guard_shape(token, ic.absent_next_shape);
        return true;
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
    // whose objects differ in shape keeps a set of own data reads, or of the
    // receiver shapes an inherited read answers for.
    bool epoch_chain = !write && ic.chain_len == hobject::IC_CHAIN_EPOCH;
    bool poly_chain  = !write && ic.chain_len == hobject::IC_CHAIN_POLY;
    bool proto_chain = !write && ic.chain_len == hobject::IC_CHAIN_PROTO;
    bool usable  = key != null && ic.key.borrow() == key && shape != null && shape.generation == ic.shape_gen
        && (epoch_chain || poly_chain || proto_chain || ic.chain_len <= hobject::IC_MAX_CHAIN)
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
        } else if (proto_chain) {
            // The entry's own receiver resolves the read through its recorded
            // link; every arm does the same for one more receiver shape.
            hobject::ICProtoReads* set = &ic.chain.proto;
            usable = index < 0 && !shape.dict && set.primary.owner != null && set.primary.first != null
                && set.count <= hobject::IC_PROTO_ARMS
                && set.primary.owner.find_prop_idx(key, h) == (int)ic.prop_idx;
            for (uint i = 0; usable && i < set.count; i++) {
                Shape* extra = h.get_shape(set.arms[i].shape_id);
                usable = extra != null && !extra.dict && self.shape(set.arms[i].shape_id, h)
                    && set.arms[i].owner != null && set.arms[i].first != null
                    && function_shape_slot(extra, key, &flags) < 0
                    && set.arms[i].owner.find_prop_idx(key, h) == (int)set.arms[i].prop_idx;
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
    } else if (proto_chain) {
        // The epoch guard covers every owner's layout and every repointed link,
        // so each arm only has to name the receiver shape it answers for and
        // the link the read stepped through. Arms are tried in order and the
        // last one's failure leaves to the interpreter.
        if (tracking && saved_flow != null) {
            self.flow_materialize();
            self.out.flow = null;
        }
        hobject::ICProtoReads* set = &ic.chain.proto;
        Heap heap_view;
        e.mov(r3, 0, mem | jit::reg_s(1), function_cold_offset(0));
        e.mov(r3, 0, mem | r3, (char*)&heap_view.prototype_epoch - (char*)&heap_view);
        self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)set.primary.value, pc);
        void*[hobject::IC_PROTO_ARMS + 2] arms;
        uint arm_count = 0;
        for (uint i = 0; i <= set.count; i++) {
            uint     shape_id = i == 0 ? ic.shape_id : set.arms[i - 1].shape_id;
            uint     slot     = i == 0 ? ic.prop_idx : set.arms[i - 1].prop_idx;
            HObject* first    = i == 0 ? set.primary.first : set.arms[i - 1].first;
            HObject* owner    = i == 0 ? set.primary.owner : set.arms[i - 1].owner;
            self.out.load(base_reg, r0);
            e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
            e.mov(r1, 0, mem | r0, shape_offset, jit::SLJIT_MOV_U32);
            void* other = e.cmp(jit::SLJIT_NOT_EQUAL, r1, 0, imm, shape_id);
            e.mov(r2, 0, mem | r0, proto_offset);
            void* link = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)first);
            // The owner keeps its identity while the epoch holds, but its
            // storage may have moved, so the slot is read from the live object.
            e.mov(r1, 0, imm, (long)owner);
            e.mov(r2, 0, mem | r1, (char*)&obj.prop_alloc - (char*)&obj);
            void* allocated = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, 0);
            e.op(jit::SLJIT_ADD, r2, r1, 0, imm, HObjectBase::size);
            e.bind(allocated);
            e.mov(r0, 0, mem | r2, (long)slot * 8);
            self.store(ins.a, pc);
            arms[arm_count++] = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
            if (i == set.count) {
                self.out.link(other, pc, true);
                self.out.link(link, pc, true);
            } else {
                void* next = e.label();
                self.out.bind_to(other, next);
                self.out.bind_to(link, next);
            }
        }
        void* proto_done = e.label();
        for (uint i = 0; i < arm_count; i++) jit::sljit_set_label(arms[i], proto_done);
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
// Calls with an explicit callee/window can use the shared native convention.
fn bool function_native_call(CompiledFunction* cf, uint pc, FunctionPlan* plan) @feat(SLJIT) {
    Instruction ins = cf.code[pc];
    return (ins.op == Opcode.CALL || ins.op == Opcode.CALL_UNDEF_THIS)
        && ins.a + 1 <= plan.heap_regs;
}

// CALL_REG_ARG shares the active window, cold context and run through S0..S2.
// A generated callee entry publishes the VM frame before entering its body.
// A non-null result is a side exit in the deepest live VM frame; unwind the
// machine continuations without replaying calls or popping VM activations.
fn bool FunctionEmitter.native_call(&self, CompiledFunction* cf, uint pc, Heap* h) @feat(SLJIT) {
    if (!function_native_call(cf, pc, self.plan)) return false;
    LoopEmitter* out = &self.out;
    if (out.flow != null) {
        self.flow_materialize();
    }
    TemplateEmitter* e = &out.e;
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int target = jit::reg_r(4);
    int mem = jit::SLJIT_MEM;
    int imm = jit::SLJIT_IMM;
    Instruction ins = cf.code[pc];
    out.load(ins.b, r0);
    e.op(jit::SLJIT_LSHR, r1, r0, 0, imm, 48);
    out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r0, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    out.guard(jit::SLJIT_EQUAL, r0, 0, imm, 0, pc);
    ObjFlags wanted;
    wanted.callable = true;
    wanted.obj_class = FUNCTION;
    ObjFlags forbidden;
    forbidden.is_bound = true;
    forbidden.exotic_proxyobj = true;
    e.mov(r1, 0, mem | r0, 0, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r1, r1, 0, imm, 0x003F0000U | (uint)wanted | (uint)forbidden);
    out.guard(jit::SLJIT_NOT_EQUAL, r1, 0, imm, (uint)wanted, pc);
    HObject object;
    e.mov(r1, 0, mem | r0, (char*)&object.extra.func.comp_func - (char*)&object);
    out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, pc);
    if (ins.op == Opcode.CALL_UNDEF_THIS) {
        e.mov(r2, 0, mem | r1, $reflect(CompiledFunction.call_flags).offset, jit::SLJIT_MOV_U16);
        e.op(jit::SLJIT_AND, r2, r2, 0, imm, 1 << 3); // lean_plain
        out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pc);
    }
    CompiledFunction* known = function_inline_target(cf, pc, h);
    void* specific;
    if (known != null) specific = e.cmp(jit::SLJIT_EQUAL, r1, 0, imm, (long)known);
    e.mov(r1, 0, mem | r1, $reflect(CompiledFunction.sljit_function).offset);
    out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, pc);
    e.mov(target, 0, mem | r1, $reflect(FunctionPlan.call_entry).offset);
    out.guard(jit::SLJIT_EQUAL, target, 0, imm, 0, pc);
    e.mov(mem | jit::reg_s(2), $reflect(FunctionRun.start).offset, imm, (long)(cf.code + pc));
    e.op(jit::SLJIT_ADD, r1, jit::reg_s(0), 0, imm, loop_value_offset(ins.b + 2));
    e.op(jit::SLJIT_ADD, r2, jit::reg_s(0), 0, imm, loop_value_offset(ins.a));
    e.mov(r3, 0, imm, ins.c | (ins.op == Opcode.CALL_UNDEF_THIS ? 256 : 0));
    if (jit::sljit_emit_icall(e.compiler, jit::SLJIT_CALL_REG_ARG, jit::SLJIT_ARGS4WWWW, target, 0) != 0) return false;
    if (specific != null) {
        void* joined = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
        e.bind(specific);
        e.mov(mem | jit::reg_s(2), $reflect(FunctionRun.start).offset, imm, (long)(cf.code + pc));
        e.op(jit::SLJIT_ADD, r1, jit::reg_s(0), 0, imm, loop_value_offset(ins.b + 2));
        e.op(jit::SLJIT_ADD, r2, jit::reg_s(0), 0, imm, loop_value_offset(ins.a));
        e.mov(r3, 0, imm, ins.c | (ins.op == Opcode.CALL_UNDEF_THIS ? 256 : 0));
        FunctionCallLink* link = h.alloc_func(h.heap_udata, FunctionCallLink::size);
        if (link == null) return false;
        *link = { .next = self.plan.calls, .target = known,
            .jump = jit::sljit_emit_call(e.compiler, jit::SLJIT_CALL_REG_ARG | jit::SLJIT_REWRITABLE_JUMP,
                jit::SLJIT_ARGS4WWWW) };
        self.plan.calls = link;
        if (link.jump == null) return false;
        e.bind(joined);
    }
    void* completed = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
    if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) return false;
    e.bind(completed);
    self.flow_reload(pc + 1);
    return true;
}

fn void FunctionEmitter.native_return(&self, uint pc) @feat(SLJIT) {
    self.flow_materialize();
    TemplateEmitter* e = &self.out.e;
    int r0 = jit::reg_r(0);
    int r1 = jit::reg_r(1);
    int r2 = jit::reg_r(2);
    int r3 = jit::reg_r(3);
    int regs = jit::reg_s(0);
    int cold = jit::reg_s(1);
    int run = jit::reg_s(2);
    int mem = jit::SLJIT_MEM;
    int imm = jit::SLJIT_IMM;
    Activation act;
    ColdCtx ctx;
    FunctionRun state;
    CompiledFunction cf;
    TVal undef;
    undef.set_undefined();
    // Every non-root frame was published by the generated call entry. It is a lean,
    // same-realm frame, and no native helper collects or enters a catcher.
    // Counted values leave at RET before any cleanup has taken effect.
    e.mov(r1, 0, mem | cold, (char*)&ctx.act - (char*)&ctx);
    e.mov(r2, 0, mem | run, (char*)&state.root - (char*)&state);
    self.out.guard(jit::SLJIT_EQUAL, r1, 0, r2, 0, pc);
    if (self.cf.code[pc].op == Opcode.RET) { self.out.load(self.cf.code[pc].a, r0); }
    else { e.mov(r0, 0, imm, (long)loop_bits(undef)); }
    e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
    void* inert = e.cmp(jit::SLJIT_LESS, r3, 0, imm, (long)types::TAG_STRING);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_OBJECT, pc);
    e.op(jit::SLJIT_AND, r2, r0, 0, imm, (long)types::NANBOX_PAYLOAD_MASK);
    self.out.guard(jit::SLJIT_EQUAL, r2, 0, imm, 0, pc);
    e.bind(inert);
    for (uint i = 0; i < self.cf.num_regs; i++) {
        e.mov(r2, 0, mem | regs, loop_value_offset(i));
        e.op(jit::SLJIT_LSHR, r2, r2, 0, imm, 48);
        self.out.guard(jit::SLJIT_EQUAL, r2, 0, imm, (long)types::TAG_STRING, pc);
    }
    e.mov(r2, 0, mem | r1, (char*)&act.retval - (char*)&act);
    e.mov(r3, 0, mem | r2, 0);
    e.op(jit::SLJIT_LSHR, r3, r3, 0, imm, 48);
    self.out.guard(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_STRING, pc);
    // No exits after this point. The caller's watermark covers its entire
    // baseline window, including the result destination and overlapping args.
    for (uint i = 0; i < self.cf.num_regs; i++) e.mov(mem | regs, loop_value_offset(i), imm, (long)loop_bits(undef));
    e.mov(mem | r2, 0, r0, 0);
    e.mov(r3, 0, mem | r1, (char*)&act.parent - (char*)&act);
    e.mov(r2, 0, mem | cold, (char*)&ctx.vm - (char*)&ctx);
    e.mov(r0, 0, mem | r1, (char*)&act.caller_valstack_top - (char*)&act);
    e.mov(mem | r2, $reflect(Vm.valstack_top).offset, r0, 0);
    e.mov(r0, 0, mem | r2, $reflect(Vm.activation_count).offset, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_SUB, r0, r0, 0, imm, 1);
    e.mov(mem | r2, $reflect(Vm.activation_count).offset, r0, 0, jit::SLJIT_MOV_U32);
    e.mov(mem | cold, (char*)&ctx.act - (char*)&ctx, r3, 0);
    e.mov(regs, 0, mem | r3, (char*)&act.bottom - (char*)&act);
    e.mov(mem | r2, $reflect(Vm.valstack_bottom).offset, regs, 0);
    e.mov(r0, 0, mem | r3, (char*)&act.func - (char*)&act);
    e.mov(mem | r2, $reflect(Vm.current_func).offset, r0, 0);
    e.mov(r1, 0, mem | r0, (char*)&cf.code - (char*)&cf);
    e.op(jit::SLJIT_MUL, r1, r1, 0, imm, (long)TH_IC_SCALE);
    e.mov(r2, 0, mem | r0, (char*)&cf.ic_entries - (char*)&cf);
    e.op(jit::SLJIT_SUB, r2, r2, 0, r1, 0);
    e.mov(mem | cold, (char*)&ctx.ic_bias - (char*)&ctx, r2, 0);
    e.mov(r1, 0, mem | r0, (char*)&cf.code - (char*)&cf);
    e.op(jit::SLJIT_MUL, r1, r1, 0, imm, (long)TH_VAR_IC_SCALE);
    e.mov(r2, 0, mem | r0, (char*)&cf.var_ic_entries - (char*)&cf);
    e.op(jit::SLJIT_SUB, r2, r2, 0, r1, 0);
    e.mov(mem | cold, (char*)&ctx.var_ic_bias - (char*)&ctx, r2, 0);
    e.mov(r2, 0, mem | cold, (char*)&ctx.regs_base_ptr - (char*)&ctx);
    e.mov(mem | r2, 0, regs, 0);
    e.mov(r0, 0, mem | run, (char*)&state.depth - (char*)&state, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_SUB, r0, r0, 0, imm, 1);
    e.mov(mem | run, (char*)&state.depth - (char*)&state, r0, 0, jit::SLJIT_MOV_U32);
    e.mov(mem | run, (char*)&state.typed[0].receiver - (char*)&state, imm, 0);
    e.mov(mem | run, (char*)&state.typed[1].receiver - (char*)&state, imm, 0);
    $if $feat(SLJIT_STATS):
    e.mov(r1, 0, imm, (long)&self.plan.direct_returns);
    e.mov(r0, 0, mem | r1, 0);
    e.op(jit::SLJIT_ADD, r0, r0, 0, imm, 1);
    e.mov(mem | r1, 0, r0, 0);
    $endif
    e.mov(r0, 0, imm, 0);
    if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) e.failed = true;
}

// Larger generic bodies can displace the tighter loop tier without reducing
// runtime work. Reserve extra fixups for regions dominated by sampled typed
// memory accesses, whose buffer guards account for much of their code size.
fn uint function_link_limit(CompiledFunction* cf) @feat(SLJIT) {
    uint typed;
    uint named;
    for (uint i = 0; i < cf.code_count; i++) {
        Opcode op = cf.code[i].op;
        if (op == Opcode.GETPROPC || op == Opcode.GETPROPC_CACHED || op == Opcode.GETTHISC
            || op == Opcode.PUTPROPC || op == Opcode.PUTTHISC) named++;
        if (op != Opcode.GETPROP && op != Opcode.GETPROP_CACHE && op != Opcode.PUTPROP) continue;
        ICEntry* ic = (ICEntry*)cf.ic_entries + i;
        if (ic.typed_kind != 0 && ic.typed_kind != 255) typed++;
    }
    return typed >= 8 && typed > named ? LOOP_LINK_LIMIT : 2048;
}

fn bool function_emit(FunctionPlan* plan, CompiledFunction* cf, Heap* h, Activation* act) @feat(SLJIT) {
    $if $feat(SLJIT_STATS): cf.sljit_rejection = "emission failed"; $endif
    LoopPlan layout_plan;
    FunctionEmitter emitter = {
        .out = { .e = { .compiler = jit::sljit_create_compiler(null) }, .plan = &layout_plan },
        .plan = plan
    };
    FunctionEmitter* f = &emitter;
    LoopEmitter* out   = &f.out;
    out.link_limit = function_link_limit(cf);
    out.function_mode = true;
    f.cf = cf;
    if (FUNCTION_DATAFLOW) out.flow = &f.flow;
    f.blocks[0] = true;
    for (uint i = 0; i < cf.code_count; i++) {
        int target = loop_target(cf.code[i], i);
        if ((function_call_op(cf.code[i].op) || function_read_op(cf.code[i].op) || function_alloc_op(cf.code[i].op)
            || function_string_add_candidate(cf, i))
            && i + 1 < cf.code_count) f.blocks[i + 1] = true;
        if (target >= 0 && target < (int)cf.code_count) f.blocks[target] = true;
        if (((!function_op(
            cf.code[i].op
        ) && function_math_candidate(
            cf,
            i
        ) < 0 && !function_parseint_candidate(
            cf,
            i
        ) && !function_call_inlineable(cf, i, h) && !function_native_call(cf, i, plan)) || target >= 0)
            && i + 1 < cf.code_count) f.blocks[i + 1] = true;
    }
    TemplateEmitter* e = &out.e;
    if (e.compiler == null) return false;
    defer jit::sljit_free_compiler(e.compiler);
    // s0..s4 are the state, cold context, run block, `this` and captures;
    // inlining also keeps an inline window base.
    // Only the outer gateway follows the C ABI. Internal calls keep the
    // register window, ColdCtx and shared run in S0..S2.
    if (jit::sljit_emit_enter(e.compiler, 0, jit::SLJIT_ARGS3WWW_R, 3, 3, 0) != 0) return false;
    int r0  = jit::reg_r(0);
    int r1  = jit::reg_r(1);
    int r2  = jit::reg_r(2);
    int r3  = jit::reg_r(3);
    int imm = jit::SLJIT_IMM;
    int mem = jit::SLJIT_MEM;
    e.mov(jit::reg_s(0), 0, r0, 0);
    e.mov(jit::reg_s(1), 0, r1, 0);
    e.mov(jit::reg_s(2), 0, r2, 0);
    void* gateway = jit::sljit_emit_call(e.compiler, jit::SLJIT_CALL_REG_ARG, 1);
    if (gateway == null || jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) return false;
    void* internal = e.label();
    jit::sljit_set_label(gateway, internal);
    if (jit::sljit_emit_enter(e.compiler, jit::SLJIT_ENTER_REG_ARG | jit::enter_keep(3),
            1, 7 | (6 << 8), 6, 0) != 0) return false;
    void* body = e.label();
    if (plan.receiver) {
        Activation layout;
        e.mov(r0, 0, mem | jit::reg_s(1), function_cold_offset(1));
        e.mov(r1, 0, mem | r0, (char*)&layout.flags - (char*)&layout, jit::SLJIT_MOV_U32);
        e.op(jit::SLJIT_AND, r1, r1, 0, imm, ACT_FLAG_THIS_VALID);
        out.guard(jit::SLJIT_EQUAL, r1, 0, imm, 0, FUNCTION_BAIL);
        e.mov(jit::reg_s(3), 0, mem | r0, (char*)&layout.this_binding - (char*)&layout);
    }
    if (!f.capture(cf, act, h)) {
        $if $feat(SLJIT_STATS): cf.sljit_rejection = "capture specialization"; $endif
        return false;
    }
    // The C gateway guards canonical FP homes before entering a continuation.
    // Calls and helpers materialize them before leaving generated code, then
    // reload them before resuming. Native callee entries publish their own
    // start PC before these guards, so an entry refusal recovers that frame.
    f.flow_prepare();
    plan.numeric_homes = f.flow.pinned;
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
        ) >= 0 || function_parseint_candidate(cf, pos) || function_call_inlineable(cf, pos, h)
            || function_native_call(cf, pos, plan);
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
        if (function_string_add_candidate(cf, pos)) {
            f.allocating_operation(pos);
            continue;
        }
        switch (ins.op) {
            case NEWOBJ:
            case NEWOBJ_SHAPE:
            case NEWARR:
            case NEWARR_CONST:
            case NEW_OBJ:
            case INIT_SLOT:
                f.allocating_operation(pos);
                continue;
            case RET:
            case RETUNDEF:
                f.native_return(pos);
                continue;
            case CALL:
            case CALL_UNDEF_THIS:
            case CALL_VAR:
            case CALL_GLOBAL:
                if (function_charcode_candidate(cf, pos)) {
                    f.allocating_operation(pos);
                    continue;
                }
                if (plan.numeric_homes != 0) {
                    f.flow_materialize();
                    if (function_math_candidate(cf, pos) >= 0) { f.math_call(cf, pos); f.flow_reload(pos + 1); }
                    else if (function_array_candidate(cf, pos) >= 0) { f.array_call(cf, pos); f.flow_reload(pos + 1); }
                    else if (function_parseint_candidate(cf, pos)) { f.parseint_call(cf, pos); f.flow_reload(pos + 1); }
                    else if (!f.native_call(cf, pos, h)) out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), pos, true);
                    continue;
                }
                if (function_parseint_candidate(cf, pos)) {
                    f.parseint_call(cf, pos);
                } else if (function_math_candidate(cf, pos) >= 0) {
                    f.math_call(cf, pos);
                } else if (function_array_candidate(cf, pos) >= 0) {
                    f.array_call(cf, pos);
                } else if (function_native_call(cf, pos, plan) && function_call_inlineable(cf, pos, h)) {
                    // Materialize before choosing either implementation. Both
                    // outcomes join with authoritative VM slots and no flow facts.
                    f.flow_materialize();
                    FunctionFlow* saved = out.flow;
                    out.flow = null;
                    uint first = out.link_count;
                    f.inline_call(cf, pos, h);
                    uint last = out.link_count;
                    void* done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
                    void* fallback = e.label();
                    uint keep = first;
                    for (uint i = first; i < last; i++) {
                        LoopLink link = *out.link_at(i);
                        if (link.exit && link.inline_id == 0 && link.target == pos) {
                            out.bind_to(link.jump, fallback);
                        } else {
                            *out.link_at(keep++) = link;
                        }
                    }
                    out.link_count = keep;
                    if (!f.native_call(cf, pos, h)) return false;
                    e.bind(done);
                    out.flow = saved;
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
            || (ins.op == Opcode.LDREG && out.flow != null && out.flow.unowned[ins.b])
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
    $if $feat(SLJIT_MAP): plan.map_pcs[cf.code_count] = e.label(); $endif
    out.link(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), cf.code_count, true);
    if (e.failed) {
        $if $feat(SLJIT_STATS):
            cf.sljit_rejection = out.link_limit_reached ? "guard/link capacity" : "body emission";
        $endif
        return false;
    }
    void*[FUNCTION_OPS + 1] exits;
    for (uint i = 0; i < out.link_count; i++) {
        LoopLink link = *out.link_at(i);
        if (!link.exit) {
            out.bind_to(link.jump, out.labels[link.target]);
            continue;
        }
        void* existing;
        if (link.inline_id == 0 && link.flow == 0 && link.target <= FUNCTION_OPS) {
            existing = exits[link.target];
        } else {
            for (uint j = 0; j < i; j++) {
                if (out.link_at(j).exit && out.link_at(j).target == link.target && out.link_at(j).flow == link.flow
                    && out.link_at(j).inline_id == link.inline_id) {
                    existing = out.link_at(j).resolved;
                    if (existing != null) break;
                }
            }
        }
        if (existing != null) {
            out.link_at(i).resolved = existing;
            out.bind_to(link.jump, existing);
            continue;
        }
        void* label = e.label();
        if (link.inline_id == 0 && link.flow == 0 && link.target <= FUNCTION_OPS) exits[link.target] = label;
        out.link_at(i).resolved = label;
        out.bind_to(link.jump, label);
        if (link.inline_id != 0) {
            FunctionInlineFrame* frame = sljit_inline_frame(plan, link.inline_id);
            e.op(jit::SLJIT_ADD, jit::reg_s(5), jit::reg_s(2), 0, imm, function_inline_window(frame.depth));
            int saved_base = out.state_reg;
            out.state_reg = jit::reg_s(5);
            f.flow_exit(link.flow);
            out.state_reg = saved_base;
            $if $feat(SLJIT_STATS):
                if (link.target < frame.exits.len) {
                    e.mov(r1, 0, imm, (long)&frame.exits[link.target]);
                    e.mov(r2, 0, mem | r1, 0);
                    e.op(jit::SLJIT_ADD, r2, r2, 0, imm, 1);
                    e.mov(mem | r1, 0, r2, 0);
                }
            $endif
            e.mov(mem | jit::reg_s(2), $reflect(FunctionRun.recover_frame).offset, imm, (long)frame);
            e.mov(mem | jit::reg_s(2), $reflect(FunctionRun.recover_pc).offset, imm, link.target, jit::SLJIT_MOV_U32);
            e.mov(r0, 0, imm, (long)(frame.target.code + link.target));
            if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) e.failed = true;
            continue;
        }
        f.flow_exit(link.flow);
        if (link.target < cf.code_count && cf.code[link.target].op == Opcode.CALL
            && function_array_candidate(cf, link.target) >= 0) {
            e.mov(r0, 0, jit::reg_s(1), 0);
            e.mov(r1, 0, imm, (long)(plan.begin + link.target));
            if (jit::sljit_emit_icall(e.compiler, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW,
                    imm, (long)&sljit_native_operation) != 0) return false;
            if (plan.numeric_homes == 0) {
                out.bind_to(e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 1), out.labels[link.target + 1]);
            } else {
                void* incomplete = e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 1);
                f.flow_reload(link.target + 1);
                out.bind_to(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), out.labels[link.target + 1]);
                e.bind(incomplete);
            }
            void* refused = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
            e.mov(r0, 0, imm, (long)(cf.code + link.target + 1));
            if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) return false;
            e.bind(refused);
        }
        if (link.target < cf.code_count && function_read_op(cf.code[link.target].op)
            && link.target + 1 < cf.code_count) {
            e.mov(r0, 0, jit::reg_s(1), 0);
            e.mov(r1, 0, imm, (long)(plan.begin + link.target));
            if (jit::sljit_emit_icall(e.compiler, jit::SLJIT_CALL, jit::SLJIT_ARGS2WWW,
                    imm, (long)&sljit_native_read) != 0) return false;
            if (plan.numeric_homes == 0) {
                out.bind_to(e.cmp(jit::SLJIT_NOT_EQUAL, r0, 0, imm, 0), out.labels[link.target + 1]);
            } else {
                void* refused = e.cmp(jit::SLJIT_EQUAL, r0, 0, imm, 0);
                f.flow_reload(link.target + 1);
                out.bind_to(jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP), out.labels[link.target + 1]);
                e.bind(refused);
            }
        }
        if (link.target == FUNCTION_BAIL) {
            e.mov(r0, 0, mem | jit::reg_s(2), (char*)&run_layout.start - (char*)&run_layout);
        } else {
            e.mov(r0, 0, imm, (long)(cf.code + link.target));
        }
        if (jit::sljit_emit_return(e.compiler, jit::SLJIT_MOV, r0, 0) != 0) e.failed = true;
    }
    void* call_entry = f.emit_call_entry(body);
    void* fallback = f.call_fallback();
    if (e.failed) {
        $if $feat(SLJIT_STATS): cf.sljit_rejection = "exit emission"; $endif
        return false;
    }
    plan.native = (FunctionNative)jit::sljit_generate_code(e.compiler, 0, null);
    if (plan.native == null) return false;
    sljit_calls_generated(plan, e.compiler, fallback);
    $if $feat(SLJIT_MAP):
        for (uint pc = 0; pc < cf.code_count; pc++) plan.map_pcs[pc] = (void*)jit::sljit_shim_label_addr(out.labels[pc]);
        plan.map_pcs[cf.code_count] = (void*)jit::sljit_shim_label_addr(plan.map_pcs[cf.code_count]);
        plan.map_calls = call_entry != null ? (void*)jit::sljit_shim_label_addr(call_entry) : null;
        for (FunctionInlineFrame* frame = plan.inline_frames; frame != null; frame = frame.next) {
            for (uint pc = 0; pc <= frame.target.code_count; pc++) {
                frame.map_pcs[pc] = (void*)jit::sljit_shim_label_addr(frame.map_pcs[pc]);
            }
        }
    $endif
    if (call_entry != null) plan.call_entry = (void*)jit::sljit_shim_label_addr(call_entry);
    plan.code_bytes = jit::sljit_shim_code_size(e.compiler) + plan.resume_bytes;
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
        $if $feat(SLJIT_STATS): cf.sljit_rejection = "no entry reaches minimum span"; $endif
        jit::sljit_free_code((void*)plan.native, null);
        plan.native = null;
        return false;
    }
    return true;
}
fn void sljit_function_free(Heap* h, CompiledFunction* cf) @feat(SLJIT) {
    FunctionPlan* plan = cf.sljit_function;
    if (plan == null) return;
    sljit_relink_calls(h, cf, true);
    $if $feat(SLJIT_STATS):
        io::eprintfn(
            "SLJIT function %s hits=%d returns=%d charged_edges=%d budget_exits=%d code_bytes=%d",
            (String)cf.get_name(),
            plan.hits,
            plan.completed,
            plan.charged_edges,
            plan.budget_exits,
            plan.code_bytes
        );
    $endif
    jit::sljit_free_code((void*)plan.native, null);
    if (plan.resume_fragment != null) jit::sljit_free_code(plan.resume_fragment, null);
    sljit_inline_frames_free(h, plan);
    sljit_call_links_free(h, plan);
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
    if (begin >= cf.code_count || !sljit_code_room(h, 0)) {
        cf.sljit_budget_wait = begin < cf.code_count;
        $if $feat(SLJIT_STATS): cf.sljit_rejection = "code budget or region bounds"; $endif
        return null;
    }
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
    if (plan == null) {
        $if $feat(SLJIT_STATS): cf.sljit_rejection = "plan allocation"; $endif
        return null;
    }
    mem::clear(plan, (sz)bytes);
    plan.begin = begin;
    plan.count = region.code_count;
    plan.min_span = cf.code_count > FUNCTION_OPS || cf.num_regs > LOOP_REGS ? FUNCTION_MIN_SPAN : 6;
    plan.entries = (void**)((char*)plan + FunctionPlan::size);
    plan.short_runs = (char*)(plan.entries + plan.count);
    bool analyzed = function_analyze(&region, plan, h);
    bool emitted  = analyzed && function_emit(plan, &region, h, cold.act);
    $if $feat(SLJIT_STATS):
        cf.sljit_rejection = emitted ? null : region.sljit_rejection;
    $endif
    $if $feat(SLJIT_STATS):
        if (begin != 0) io::eprintfn(
            "SLJIT region result %s ops=%d analyzed=%d emitted=%d code_bytes=%d budget_used=%d limit=%d",
            (String)cf.get_name(),
            cf.code_count,
            analyzed,
            emitted,
            plan.code_bytes,
            h.jit_code_bytes,
            sljit_code_limit(h)
        );
    $endif
    if (!emitted || !sljit_code_room(h, plan.code_bytes)) {
        cf.sljit_budget_wait = emitted;
        $if $feat(SLJIT_STATS): if (emitted) cf.sljit_rejection = "code budget"; $endif
        if (plan.native != null) jit::sljit_free_code((void*)plan.native, null);
        if (plan.resume_fragment != null) jit::sljit_free_code(plan.resume_fragment, null);
        sljit_inline_frames_free(h, plan);
        sljit_call_links_free(h, plan);
        h.free_func(h.heap_udata, plan);
        return null;
    }
    cf.sljit_function = plan;
    for (FunctionCallLink* link = plan.calls; link != null; link = link.next) sljit_link_target(link);
    sljit_relink_calls(h, cf);
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
// Calls a function must see before the tier compiles it. The differential
// test setting compiles on the first call instead.
fn uint sljit_warmup(Heap* h) @feat(SLJIT) @inline => h.jit_stress ? 1 : 64;
fn Instruction* sljit_function_entry(
    Instruction* pc,
    TVal* regs,
    ColdCtx* cold,
    bool region = false
) @feat(SLJIT) @noinline {
    Heap* h              = cold.heap;
    $if $feat(SLJIT_ADAPTIVE): h.jit_clock++; $endif
    CompiledFunction* cf = cold.vm.current_func;
    $if $feat(SLJIT_STATS): cf.sljit_entry_attempts++; $endif
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
            if (++cf.sljit_function_calls < sljit_warmup(h)) return pc;
        } else if (!region || cf.sljit_function_calls < sljit_warmup(h)) return pc;
        cf.sljit_function_calls = uint::max;
        // A hot backedge in an ordinary function must also produce its call
        // entry. Otherwise callers can never enter that callee natively.
        plan = sljit_function_compile(cf, cold, cf.code_count <= FUNCTION_OPS ? 0 : offset);
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
    // Native calls consume the run's progress budget too. A call-only graph
    // can exhaust it without ever taking an interpreter backward branch to
    // replenish it. With no pending collection, that poll is a no-op.
    if (h.bwd_gc_budget <= 1 && !h.gc_pending) h.bwd_gc_budget = heap::BWD_GC_INTERVAL;
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
    run.root = cold.act;
    $if $feat(SLJIT_ADAPTIVE):
        run.clock = h.jit_clock;
        plan.last_use = h.jit_clock;
    $endif
    run.depth = 0;
    run.start = pc;
    run.recover_frame = null;
    run.budget = budget;
    run.typed[0].receiver = null;
    run.typed[1].receiver = null;
    Instruction* resume = plan.native(regs, cold, &run);
    if (run.recover_frame != null) {
        $if $feat(SLJIT_STATS): plan.inline_recoveries++; $endif
        resume = sljit_inline_recover(cold, &run);
    }
    uint consumed = (uint)(budget - run.budget);
    uint progress = consumed;
    if (cold.act == run.root && resume - pc >= 6) progress += 16;
    sljit_budget_progress(h, progress);
    h.bwd_gc_budget -= consumed;
    if (interrupts) h.interrupt_budget -= consumed;
    $if $feat(SLJIT_STATS):
    plan.charged_edges += consumed;
    if (run.budget <= 1 && consumed != 0) plan.budget_exits++;
    $endif
    if (cold.act != run.root) {
        $if $feat(SLJIT_STATS):
        // Charge the exit to the function containing its resume PC, including
        // callees entered entirely from generated code.
        CompiledFunction* active = cold.vm.current_func;
        FunctionPlan* active_plan = active.sljit_function;
        uint exited = (uint)(resume - active.code);
        if (active_plan != null && exited < active.code_count && exited < 512) active_plan.exit_pcs[exited]++;
        plan.hits++;
        $endif
        return resume;
    }
    uint next = (uint)(resume - cf.code);
    // A run that stops at the same unexpandable call without completing a
    // backedge repeats the same prefix on every entry loop iteration. Let the
    // interpreter own the function once that is clearly never going to pay.
    bool at_call = next < cf.code_count && function_call_op(cf.code[next].op);
    bool returned = next < cf.code_count
        && (cf.code[next].op == Opcode.RET || cf.code[next].op == Opcode.RETUNDEF);
    bool stuck = consumed == 0 && next >= offset && !returned
        && (next - offset < 6 || at_call);
    if (stuck) {
        if (!h.jit_stress && ++plan.short_runs[local] >= 8) {
            plan.entries[local] = null;
            if (offset == 0) cf.sljit_function_calls = uint::max;
        }
    } else {
        plan.short_runs[local] = 0;
    }
    $if $feat(SLJIT_STATS):
    plan.hits++;
    if (next < cf.code_count && next < 512) plan.exit_pcs[next]++;
    if (next == offset) plan.stalled++;
    if (next < cf.code_count
        && (cf.code[next].op == Opcode.RET || cf.code[next].op == Opcode.RETUNDEF)) plan.completed++;
    $endif
    return cf.code + next;
}
// Large functions warm a bounded region at a taken loop header. Native
// backedges return before the shared GC/interrupt budget reaches its poll.
fn bool sljit_function_backedge(Instruction* pc, CompiledFunction* cf, Heap* h) @feat(SLJIT) @inline {
    int target = loop_target(*pc, (uint)(pc - cf.code));
    if (target < 0) return false;
    if (cf.sljit_function != null) return sljit_function_resumes(cf.code + target, cf);
    return cf.sljit_function_calls != uint::max && ++cf.sljit_function_calls >= sljit_warmup(h);
}
fn Instruction* sljit_function_region(Instruction* pc, TVal* regs, ColdCtx* cold) @feat(SLJIT) @inline {
    CompiledFunction* cf = cold.vm.current_func;
    if (cf.sljit_function_calls < sljit_warmup(cold.heap)) cf.sljit_function_calls++;
    return sljit_function_entry(pc, regs, cold, true);
}
fn Instruction* sljit_function_dispatch(
    Instruction* pc,
    HandlerTable* handlers,
    TVal* regs,
    ColdCtx* cold
) @feat(SLJIT) @noinline {
    pc = sljit_function_entry(pc, regs, cold);
    return th_next(pc, handlers, cold.act.bottom, cold);
}
// Report the counters the native tiers keep: what compiled, how often it ran,
// where each run ended, and the totals. Driven by the CLI's --stats.
fn void sljit_stats_dump(Heap* h) {
    $if $feat(SLJIT):
        uint functions;
        uint loops;
        uint templates;
        ulong hits;
        for (uint i = 0; i < h.compiled_func_count; i++) {
            CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[i];
            if (cf == null) continue;
            FunctionPlan* plan = cf.sljit_function;
            $if $feat(SLJIT_STATS):
                if (cf.sljit_threaded_entries != 0 || cf.sljit_switch_ops != 0 || cf.sljit_entry_attempts != 0) {
                    uint retired;
                    uint active;
                    if (plan != null) for (uint j = 0; j < plan.count; j++) {
                        if (plan.short_runs[j] >= 8) retired++;
                        if (plan.entries[j] != null) active++;
                    }
                    io::printfn(
                        "SLJIT coverage id=%d line=%d ops=%d regs=%d captures=%d name=%s threaded=%d switch=%d attempts=%d warmup=%d retired=%d active=%d rejection=%s",
                        i,
                        cf.get_line(0),
                        cf.code_count,
                        cf.num_regs,
                        cf.capture_count,
                        (String)cf.get_name(),
                        cf.sljit_threaded_entries,
                        cf.sljit_switch_ops,
                        cf.sljit_entry_attempts,
                        cf.sljit_function_calls,
                        retired,
                        active,
                        (ZString)(plan != null ? "compiled"
                            : cf.sljit_rejection != null ? cf.sljit_rejection
                            : "not attempted")
                    );
                }
            $endif
            if (plan != null) {
                functions++;
                $if $feat(SLJIT_STATS):
                hits += plan.hits;
                io::printfn("SLJIT native id=%d calls=%d returns=%d", i, plan.direct_calls, plan.direct_returns);
                uint links;
                for (FunctionCallLink* link = plan.calls; link != null; link = link.next) links++;
                io::printfn("SLJIT pipeline id=%d inlined=%d recoveries=%d allocations=%d pushes=%d links=%d",
                    i, plan.general_inlines, plan.inline_recoveries, plan.resumed_allocations, plan.resumed_pushes, links);
                io::printfn("SLJIT numeric id=%d homes=%d", i, plan.numeric_homes);
                io::printfn("SLJIT code id=%d start=%p bytes=%d fragment=%p fragment_bytes=%d",
                    i, plan.native, plan.code_bytes - plan.resume_bytes, plan.resume_fragment, plan.resume_bytes);
                $if $feat(SLJIT_MAP): sljit_address_map(plan, cf, i); $endif
                for (FunctionInlineFrame* frame = plan.inline_frames; frame != null; frame = frame.next) {
                    for (uint pc = 0; pc < frame.target.code_count; pc++) {
                        if (frame.exits[pc] == 0) continue;
                        io::printfn("SLJIT inline_exit id=%d frame=%d depth=%d target_line=%d pc=%d opcode=%s count=%d",
                            i, frame.id, frame.depth, frame.target.get_line(0), pc,
                            (ZString)bytecode::get_opcode_name(frame.target.code[pc].op), frame.exits[pc]);
                    }
                }
                io::printfn(
                    "SLJIT function %s begin=%d ops=%d bytes=%d hits=%d returns=%d stalled=%d charged_edges=%d budget_exits=%d id=%d line=%d",
                    (String)cf.get_name(),
                    plan.begin,
                    plan.count,
                    plan.code_bytes,
                    plan.hits,
                    plan.completed,
                    plan.stalled,
                    plan.charged_edges,
                    plan.budget_exits,
                    i,
                    cf.get_line(0)
                );
                for (uint pc = 0; pc < 512; pc++) {
                    if (plan.exit_pcs[pc] == 0) continue;
                    io::printfn(
                        "SLJIT exit %s begin=%d pc=%d op=%d count=%d id=%d line=%d opcode=%s",
                        (String)cf.get_name(),
                        plan.begin,
                        pc,
                        pc < cf.code_count ? (int)cf.code[pc].op : -1,
                        plan.exit_pcs[pc],
                        i,
                        cf.get_line(pc),
                        (ZString)(pc < cf.code_count ? bytecode::get_opcode_name(cf.code[pc].op) : "end")
                    );
                }
                $else
                io::printfn("SLJIT function %s begin=%d ops=%d bytes=%d id=%d line=%d",
                    (String)cf.get_name(), plan.begin, plan.count, plan.code_bytes, i, cf.get_line(0));
                $endif
            }
            for (LoopPlan* lp = cf.sljit_loops; lp != null; lp = lp.next) {
                loops++;
                $if $feat(SLJIT_MAP):
                    io::printfn("SLJIT map id=%d kind=loop pc=%d start=%p end=%p", i, lp.begin,
                        lp.native, (char*)(void*)lp.native + (sz)lp.code_bytes);
                $endif
                io::printfn(
                    "SLJIT loop %s begin=%d end=%d hits=%d iterations=%d",
                    (String)cf.get_name(),
                    lp.begin,
                    lp.end,
                    lp.hits,
                    lp.iterations
                );
                $if $feat(SLJIT_STATS):
                io::printfn("SLJIT ssa name=%s begin=%d end=%d hits=%d iterations=%d",
                    (String)cf.get_name(), lp.begin, lp.end, lp.ssa_hits, lp.ssa_iterations);
                $endif
            }
            if (cf.sljit_template != null) {
                TemplatePlan* tp = (TemplatePlan*)cf.sljit_template;
                templates++;
                io::printfn("SLJIT template %s hits=%d misses=%d", (String)cf.get_name(), tp.hits, tp.misses);
            }
        }
        $if $feat(SLJIT_STATS):
        io::printfn(
            "SLJIT totals functions=%d loops=%d templates=%d hits=%d code_bytes=%d",
            functions,
            loops,
            templates,
            hits,
            h.jit_code_bytes
        );
        $else
        io::printfn("SLJIT totals functions=%d loops=%d templates=%d code_bytes=%d",
            functions, loops, templates, h.jit_code_bytes);
        $endif
        io::printfn("SLJIT budget bytes=%d limit=%d native_work=%d evictions=%d", h.jit_code_bytes,
            sljit_code_limit(h), h.jit_native_work, h.jit_evictions);
        $if $feat(SLJIT_STATS) && $feat(OP_PROFILE): opprof_dump(); $endif
    $endif
}
