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

// Bodies compile as one unit while they fit this window; a larger one compiles
// a bounded region entered at a hot header.
const uint FUNCTION_OPS        = 512;
const uint FUNCTION_BAIL       = uint::max;
const uint FUNCTION_CAPTURES   = 8;
const uint FUNCTION_REGION_OPS = 256;
// Callee bodies nested inside one another each own a register window in the
// run block.
const uint INLINE_DEPTH = 4;
// Each invocation owns its budget; generated code never keeps a pointer after
// return. Stop before the final charged edge so the interpreter executes the
// ordinary GC/interrupt safepoint with fully published register state.
struct FunctionRun {
    void* entry;
    long budget;
    // The shared run's uncharged native work is budget_base - budget.
    long budget_base;
    Activation* root;
    uint depth;
    Instruction* start;
    FunctionInlineFrame* recover_frame @if($feat(SLJIT));
    uint recover_pc;
    void* helper_continuation;
    Instruction* helper_pc;
    ulong clock;
    FunctionTypedCache[2] typed;
    double[32 * INLINE_DEPTH] inline_values;
    // Entry budget saved across a frameless fast path, which is refunded if
    // that path exits so the ordinary entry does not start with nothing left.
    long ssa_budget @if($feat(SLJIT));
    LoopState* ssa_state @if($feat(SLJIT));
    void* ssa_callee @if($feat(SLJIT));
    ulong ssa_receiver @if($feat(SLJIT));
}
alias FunctionNative = fn Instruction*(TVal* regs, ColdCtx* cold, FunctionRun* run);
struct FunctionNativeCall {
    HObject* callee;
    TVal* arguments;
    TVal* result;
    uint flags;
}
alias FunctionNativeCallEntry = fn Instruction*(ColdCtx* cold, FunctionRun* run, FunctionNativeCall* call);

// VM registers own every published value. Generated lean calls share the run;
// operations that may allocate, invoke unknown code or throw escape with all
// live activations published. Calls and backedges bound native progress.
struct FunctionPlan @feat(SLJIT) {
    FunctionNative native;
    JitArtifact artifact;
    FunctionReadFeedback[4] read_feedback @if($feat(SLJIT_READ_REFRESH));
    bool read_refresh_requested @if($feat(SLJIT_READ_REFRESH));
    char read_refresh_checks @if($feat(SLJIT_READ_REFRESH));
    uint read_refresh_pc @if($feat(SLJIT_READ_REFRESH));
    uint read_refresh_shape @if($feat(SLJIT_READ_REFRESH));
    uint read_refresh_generation @if($feat(SLJIT_READ_REFRESH));
    void* call_entry;
    FunctionNativeCallEntry call_from_c;
    // SSA-only bodies share the ordinary native call ABI through this small
    // adapter. The SSA kernel and adapter have the same artifact owner.
    void* ssa_call_code;
    FunctionCallLink* calls;
    // Watched assumptions remain allocated until this plan is retired. Native
    // code checks the shared cell before entering any dependent SSA body.
    JitWriteDependency* dependencies;
    bool dependencies_live;
    void* resume_fragment;
    usz resume_bytes;
    uint numeric_homes;
    LoopPlan* ssa_region;
    LoopPlan* ssa_leaves;
    ulong ssa_fast_calls @if($feat(SLJIT_STATS));
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
    ulong[FUNCTION_OPS] read_hits @if($feat(SLJIT_STATS));
    ulong[FUNCTION_OPS] read_natives @if($feat(SLJIT_STATS));
    uint[FUNCTION_OPS] read_shapes @if($feat(SLJIT_STATS));
    uint[FUNCTION_OPS] read_changes @if($feat(SLJIT_STATS));
    uint[FUNCTION_OPS] read_classes @if($feat(SLJIT_STATS));
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
    ColdCtx* cold;
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
        case MOD:
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
    // Only heap strings are refcounted, so an assignment of two numeric values
    // needs one tag check each. The first string either side sends both to the
    // shared release/retain path below, which is where every previous store
    // started; the common case now skips it entirely.
    out.load(reg, r1);
    e.op(jit::SLJIT_LSHR, r3, r1, 0, imm, 48);
    void* old_string = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_STRING);
    void* new_string;
    if (!inert) {
        e.op(jit::SLJIT_LSHR, r3, r0, 0, imm, 48);
        new_string = e.cmp(jit::SLJIT_EQUAL, r3, 0, imm, (long)types::TAG_STRING);
    }
    int cached = out.cached(reg);
    e.mov(cached != 0 ? cached : mem | out.state_base(), cached != 0 ? 0 : loop_value_offset(reg), r0, 0);
    void* stored = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(old_string);
    if (new_string != null) e.bind(new_string);
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
    e.mov(cached != 0 ? cached : mem | out.state_base(), cached != 0 ? 0 : loop_value_offset(reg), r0, 0);
    e.bind(stored);
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
    // Tagged integers have one canonical encoding, so equality needs no
    // floating-point conversion. Preserve numeric semantics for mixed tags.
    void* left_float = e.cmp(jit::SLJIT_NOT_EQUAL, r2, 0, imm, (long)types::TAG_FASTINT);
    void* right_float = e.cmp(jit::SLJIT_NOT_EQUAL, r3, 0, imm, (long)types::TAG_FASTINT);
    e.equal_value(r0, r0, r1, negate);
    e.op(jit::SLJIT_OR, r0, r0, 0, imm, (long)(types::TAG_BOOLEAN << 48));
    void* integer_done = jit::sljit_emit_jump(e.compiler, jit::SLJIT_JUMP);
    e.bind(left_float);
    e.bind(right_float);
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
    e.bind(integer_done);
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
    // Mutable capture stores use the resolved slot directly. An observed
    // owner must take the interpreter's notifying store path instead.
    GcBits watched;
    watched.jit_observed = true;
    e.mov(r3, 0, mem | capture, (char*)&object.gc - (char*)&object, jit::SLJIT_MOV_U32);
    e.op(jit::SLJIT_AND, r3, r3, 0, imm, (uint)watched);
    self.out.guard(jit::SLJIT_NOT_EQUAL, r3, 0, imm, 0, FUNCTION_BAIL);
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
    // Prefer an already compiled SSA kernel over a generic boxed backedge.
    // Return at the branch, so the interpreter charges and dispatches the edge
    // exactly once, and can safely retire or replace the loop specialization.
    if (target <= pc && self.depth == 0 && ssa_comparison_op(self.cf.code[pc].op)) {
        for (LoopPlan* loop = self.cf.sljit_loops; loop != null; loop = loop.next) {
            if (loop.ssa && loop.memory_count > 0 && loop.begin == target + self.plan.begin && loop.end == pc + self.plan.begin) {
                self.out.link(jit::sljit_emit_jump(self.out.e.compiler, jit::SLJIT_JUMP), pc, true);
                return;
            }
        }
    }
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

fn void FunctionEmitter.native_return(&self, uint pc, int result_reg = -2) @feat(SLJIT) {
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
    if (result_reg == -2) result_reg = self.cf.code[pc].op == Opcode.RET ? (int)self.cf.code[pc].a : -1;
    if (result_reg >= 0) { self.out.load((uint)result_reg, r0); }
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
    e.mov(mem | cold, $reflect(ColdCtx.capture_refs).offset, imm, 0);
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

// Typed memory reads and writes, sampled during interpreter warmup, outnumber
// named property sites in asm.js-shaped code. Those bodies are the ones whose
// generated code beats the interpreter, so they alone earn the extra fixups.
fn bool function_typed_body(CompiledFunction* cf) @feat(SLJIT) {
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
    return typed >= 8 && typed > named;
}
// Every guard and every exit records a fixup, and typed-memory reads record
// several each, so a typed body gets three times the eight fixups per bytecode
// that every other body is allowed.
const uint REGION_LINK_LIMIT = 8192;
// A guard-rich but modest body (a long switch is the common case) can need
// more fixups than its admission estimate. Larger bodies keep the hard bound:
// spending the shared code budget on them starves the functions that do pay.
const uint FUNCTION_LINK_GROWTH_OPS = 256;
fn uint function_link_limit(CompiledFunction* cf) @feat(SLJIT) {
    if (function_typed_body(cf)) return LINK_LIMIT_MAX;
    uint sized = cf.code_count * 8;
    return sized < 2048 ? 2048 : sized > REGION_LINK_LIMIT ? REGION_LINK_LIMIT : sized;
}
fn bool function_emit(FunctionPlan* plan, CompiledFunction* cf, Heap* h, Activation* act, ColdCtx* cold = null) @feat(SLJIT) {
    $if $feat(SLJIT_STATS): cf.sljit_rejection = "emission failed"; $endif
    LoopPlan layout_plan;
    FunctionEmitter emitter = {
        .out = { .e = { .compiler = jit::sljit_create_compiler(null) }, .plan = &layout_plan, .heap = h },
        .plan = plan
    };
    FunctionEmitter* f = &emitter;
    LoopEmitter* out   = &f.out;
    out.link_limit = function_link_limit(cf);
    out.link_growth = plan.begin == 0 && cf.code_count <= FUNCTION_LINK_GROWTH_OPS ? LINK_LIMIT_MAX : 0;
    out.function_mode = true;
    f.cf = cf;
    f.cold = cold;
    if (FUNCTION_DATAFLOW) out.flow = &f.flow;
    f.blocks[0] = true;
    if (plan.ssa_region != null && plan.ssa_region.end + 1 < cf.code_count) {
        f.blocks[plan.ssa_region.end + 1] = true;
    }
    for (uint i = 0; i < cf.code_count; i++) {
        // SSA hands off with published VM slots. These labels must not
        // inherit temporary FP mappings from baseline instructions it skipped.
        if (plan.ssa_region != null && plan.ssa_region.ssa_recoverable
            && (cf.code[i].op == Opcode.RET || cf.code[i].op == Opcode.RETUNDEF
                || function_call_op(cf.code[i].op))) f.blocks[i] = true;
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
    out.labels = out.labels_alloc(cf.code_count);
    if (out.labels == null) return false;
    defer out.labels_free();
    defer out.link_release();
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
            1, jit::scratch_register_count(6) | (6 << 8), 6, 0) != 0) return false;
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
        if (plan.ssa_region != null && (pos == 0 || (plan.ssa_region.ssa_recoverable && pos < SSA_SPAN
            && (plan.ssa_region.ssa_resume_pcs[pos >> 6] & (1UL << (pos & 63))) != 0))) f.ssa_entry(pos);
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
            || ins.op == Opcode.EQ
            || ins.op == Opcode.NEQ
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
    // Open-addressed table of earlier exit links. The table is at most half
    // full and compares the entire recovery state after hashing; collisions
    // never merge different frame IDs, flow snapshots, or resume PCs.
    uint exit_capacity = 2;
    while (exit_capacity < out.link_count * 2) exit_capacity *= 2;
    uint* exit_table = (uint*)h.alloc_func(h.heap_udata, exit_capacity * uint::size);
    if (exit_table == null) return false;
    defer h.free_func(h.heap_udata, exit_table);
    mem::clear(exit_table, (sz)(exit_capacity * uint::size));
    for (uint i = 0; i < out.link_count; i++) {
        LoopLink link = *out.link_at(i);
        if (!link.exit) {
            out.bind_to(link.jump, out.labels[link.target]);
            continue;
        }
        uint hash = link.target * 0x9e3779b9u ^ (uint)link.inline_id * 0x85ebca6bu
            ^ (uint)link.flow ^ (uint)(link.flow >> 32);
        hash ^= hash >> 16;
        hash *= 0x7feb352du;
        hash ^= hash >> 15;
        hash *= 0x846ca68bu;
        hash ^= hash >> 16;
        uint slot = hash & (exit_capacity - 1);
        void* existing;
        while (exit_table[slot] != 0) {
            LoopLink* prev = out.link_at(exit_table[slot] - 1);
            if (prev.target == link.target && prev.flow == link.flow && prev.inline_id == link.inline_id) {
                existing = prev.resolved;
                break;
            }
            slot = (slot + 1) & (exit_capacity - 1);
        }
        if (existing != null) {
            out.link_at(i).resolved = existing;
            out.bind_to(link.jump, existing);
            continue;
        }
        void* label = e.label();
        exit_table[slot] = i + 1;
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
    void* call_from_c = f.emit_c_call_entry(call_entry);
    if (e.failed) {
        $if $feat(SLJIT_STATS): cf.sljit_rejection = "exit emission"; $endif
        return false;
    }
    plan.native = (FunctionNative)jit::sljit_generate_code(e.compiler, 0, null);
    if (plan.native == null) return false;
    sljit_calls_generated(plan, e.compiler, fallback);
    for (LoopPlan* leaf = plan.ssa_leaves; leaf != null; leaf = leaf.next) {
        $if $feat(SLJIT_MAP):
            leaf.ssa_map_begin = (void*)jit::sljit_shim_label_addr(leaf.ssa_map_begin);
            leaf.ssa_map_end = (void*)jit::sljit_shim_label_addr(leaf.ssa_map_end);
        $endif
        if (leaf.ssa_epoch_constant == null) continue;
        leaf.ssa_epoch_patch = jit::sljit_shim_const_addr(leaf.ssa_epoch_constant);
        leaf.ssa_executable_offset = jit::sljit_shim_executable_offset(e.compiler);
        leaf.ssa_epoch_constant = null;
    }
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
    if (call_from_c != null) plan.call_from_c = (FunctionNativeCallEntry)jit::sljit_shim_label_addr(call_from_c);
    plan.code_bytes = jit::sljit_shim_code_size(e.compiler) + plan.resume_bytes
        + (plan.ssa_region != null ? plan.ssa_region.code_bytes : 0);
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
