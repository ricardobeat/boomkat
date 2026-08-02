module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hobject;
import duktape::env;

// ============================================================================
// Direct-threaded dispatch (feature THREADED_DISPATCH, on by default). The hot
// loops are dispatch-bound after op-count consolidation, with many trivial
// slot ops:
//
//   assign60 body: 4x(GETGLOBAL + PUTGLOBAL) + INC_GLOBAL + GETVAR + JMP_LT
//   fib34   body:  LDINT/SUBI/ADD + JMP_NLE compare-branch (CALL/RET on switch)
//   emptyloop:     INC_GLOBAL + GETVAR + JMP_LT
//
// The global-slot ops (GETGLOBAL/PUTGLOBAL/INC_GLOBAL/DEC_GLOBAL) thread their
// perf-all VarRef fast path: one prop_alloc pointer compare + a direct slot
// load/store, no shape-id load, no env walk. Any IC miss / slow path bails to
// the switch.
//
// Design constraint (proven): the hot fields (pc, regs base, code end) are
// passed as DIRECT SCALAR ARGUMENTS so LLVM keeps them register-resident. Cold
// state (vm, act, code_base) rides behind one ColdCtx* pointer. Bundling the
// hot fields behind a struct pointer reloads them from memory every handler
// and regresses ~2x.
//
// That ColdCtx is the leading sub-struct of Dispatch, so the burst entry
// passes `&ds.cold` -- a fixed address the switch's own frame-change
// assignments keep current -- rather than materialising a bundle per
// instruction.
//
// Each handler ends in a TAIL CALL through g_threaded_handlers[...], which at
// -O2 LLVM lowers to an indirect tail JUMP (br xN) -- computed-goto-style
// threading with no goto/musttail (which C3 lacks).
// ============================================================================

alias ThreadedHandlerFn = fn Instruction*(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold);

const usz TH_TABLE_SIZE = Opcode.LAST_OP.ordinal + 1;
ThreadedHandlerFn[TH_TABLE_SIZE] g_threaded_handlers;
bool g_threaded_handlers_init = false;

fn void init_threaded_handlers() {
    if (g_threaded_handlers_init) return;
    g_threaded_handlers_init = true;
    for (usz i = 0; i < TH_TABLE_SIZE; i++) {
        g_threaded_handlers[i] = &th_bailout;
    }
    // --- Tight-loop arith ops ---
    g_threaded_handlers[Opcode.ADDI.ordinal]   = &th_addi;
    g_threaded_handlers[Opcode.LDREG.ordinal]  = &th_ldreg;
    g_threaded_handlers[Opcode.JMP_LT.ordinal] = &th_jmp_lt;

    // --- Recursion (fib) cheap ops ---
    g_threaded_handlers[Opcode.LDINT.ordinal]  = &th_ldint;
    g_threaded_handlers[Opcode.SUBI.ordinal]   = &th_subi;
    g_threaded_handlers[Opcode.ADD.ordinal]    = &th_add;
    g_threaded_handlers[Opcode.JMP_NLT.ordinal] = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_NLE.ordinal] = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_NGT.ordinal] = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_NGE.ordinal] = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_LE.ordinal]  = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_GT.ordinal]  = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_GE.ordinal]  = &th_cmp_branch;
    // CALL_VAR / CALL_UNDEF_THIS / RET / RETUNDEF stay on the switch: their
    // handler bodies (activation push/pop, valstack, refcount) are too large
    // to thread cheaply. They bail via th_bailout automatically.

    // --- Assignment (g_assign) hot ops: perf-all global-slot opcodes ---
    g_threaded_handlers[Opcode.GETGLOBAL.ordinal]  = &th_getglobal;
    g_threaded_handlers[Opcode.PUTGLOBAL.ordinal]  = &th_putglobal;
    g_threaded_handlers[Opcode.GETGLOBAL_PRIM.ordinal] = &th_getglobal_prim;
    g_threaded_handlers[Opcode.PUTGLOBAL_PRIM.ordinal] = &th_putglobal_prim;
    g_threaded_handlers[Opcode.MOVE_GG.ordinal] = &th_move_gg;
    g_threaded_handlers[Opcode.JMP_LT_G.ordinal] = &th_jmp_lt_g;
    g_threaded_handlers[Opcode.INC_GLOBAL.ordinal] = &th_inc_global;
    g_threaded_handlers[Opcode.DEC_GLOBAL.ordinal] = &th_dec_global;

    // --- Variable access (VarIC shape and recycle-epoch path) ---
    g_threaded_handlers[Opcode.GETVAR.ordinal]        = &th_getvar;
    g_threaded_handlers[Opcode.PUTVAR_ASSIGN.ordinal] = &th_putvar_assign;
    g_threaded_handlers[Opcode.INC_VAR.ordinal]       = &th_inc_var;
    g_threaded_handlers[Opcode.JUMP.ordinal]          = &th_jump;
    g_threaded_handlers[Opcode.TONUMERIC.ordinal]     = &th_tonumeric;

    // --- Property access: IC hit path (bench_object / bench_property_lookup) ---
    g_threaded_handlers[Opcode.GETPROPC.ordinal]        = &th_getpropc;
    g_threaded_handlers[Opcode.GETPROPC_CACHED.ordinal] = &th_getpropc_cached;
    g_threaded_handlers[Opcode.PUTPROP.ordinal]         = &th_putprop;
}

// Bail: return the resume pc WITHOUT consuming *pc -- the switch loop
// re-decodes it.
fn Instruction* th_bailout(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) @noinline {
    return pc;
}

macro Instruction* th_next(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    if (pc >= code_end) return pc;
    Instruction next = *pc;
    // Tail call -> indirect tail jump at -O2.
    return g_threaded_handlers[next.op.ordinal](pc, code_end, regs, cold);
}

/// Charge one backward jump against the GC safepoint budget, reporting whether
/// the caller must bail to the switch.
///
/// Running the safepoint here instead would put a call in every branch handler,
/// which is what makes them non-leaf: LLVM then wraps each one in a four-pair
/// stp/ldp frame that every taken back-edge pays, on handlers whose fast path
/// is a compare and a pc add. The budget expires once per BWD_GC_INTERVAL
/// back-edges, so handing that iteration to the switch (which charges the
/// budget itself and runs the safepoint) is far cheaper than framing the
/// common case. The budget is left untouched on a bail so the switch's own
/// decrement is the one that fires.
macro bool th_bwd_edge_needs_safepoint(ColdCtx* cold) {
    return cold.vm.heap.bwd_gc_budget <= 1;
}

fn Instruction* th_addi(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) return pc;
    TVal* ra = regs + insn.a;
    long imm = (long)(ichar)insn.c;
    ra.set_fastint_or_number(rb.get_fastint() + imm);
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_ldreg(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    // Threaded fast path only: non-heap source. Heap source bails so the
    // switch handles refcount + track_heap_store.
    if (rb.is_heap_allocated()) return pc;
    TVal* ra = regs + insn.a;
    if (ra.is_heap_allocated()) {
        cold.vm.heap.decref_tval(ra);
    }
    *ra = *rb;
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_jmp_lt(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    bool cmp_lt;
    if (types::both_fastint(rb, rc)) {
        cmp_lt = rb.get_fastint() < rc.get_fastint();
    } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
        cmp_lt = tval_numeric_to_double(rb) < tval_numeric_to_double(rc);
    } else {
        return pc; // may call user code / throw -- bail
    }
    // JMP_LT branches when TRUE (loop back-edge).
    if (cmp_lt) {
        if ((ichar)insn.a < 0) {
            if (th_bwd_edge_needs_safepoint(cold)) return pc;
            cold.vm.heap.bwd_gc_budget--;
        }
        pc += (sz)(1 + (int)(ichar)insn.a);
    } else {
        pc++;
    }
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_ldint(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* ra = regs + insn.a;
    ra.set_fastint((long)insn.get_sbc());
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_subi(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) return pc; // bigint / coercion / throw -> switch
    TVal* ra = regs + insn.a;
    long imm = (long)(ichar)insn.c;
    ra.set_fastint_or_number(rb.get_fastint() - imm);
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_add(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    // Threaded fast path: FASTINT + FASTINT only. String concat / object
    // ToPrimitive / bigint all bail to the switch.
    if (!types::both_fastint(rb, rc)) return pc;
    TVal* ra = regs + insn.a;
    long sum = rb.get_fastint() + rc.get_fastint();
    if (sum >= types::FASTINT_MIN && sum <= types::FASTINT_MAX) {
        ra.set_fastint(sum);
    } else {
        ra.set_number((double)sum);
    }
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_jump(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    // Unconditional relative jump (sABC). No try-finally interception (that is
    // BREAK/CONTINUE, not JUMP). Backward jumps charge the GC safepoint budget.
    int off = insn.get_sabc();
    if (off < 0) {
        if (th_bwd_edge_needs_safepoint(cold)) return pc;
        cold.vm.heap.bwd_gc_budget--;
    }
    pc += (sz)(1 + off);
    return th_next(pc, code_end, regs, cold);
}

// Fused compare-and-branch family (JMP_N{LT,LE,GT,GE} branch-if-false and
// JMP_{LE,GT,GE} branch-if-true; JMP_LT has its own handler above). Threads
// the fastint / number fast path only; anything requiring ToPrimitive /
// relational coercion (may call user code or throw) bails to the switch.
fn Instruction* th_cmp_branch(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    bool cmp_lt;
    bool cmp_le;
    if (types::both_fastint(rb, rc)) {
        long lb = rb.get_fastint();
        long lc = rc.get_fastint();
        cmp_lt = lb <  lc;
        cmp_le = lb <= lc;
    } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
        double db = tval_numeric_to_double(rb);
        double dc = tval_numeric_to_double(rc);
        cmp_lt = db <  dc;
        cmp_le = db <= dc;
    } else {
        return pc; // coercion / user code / throw -> switch
    }
    bool cmp_result;
    bool branch_on;
    switch (insn.op) {
        case Opcode.JMP_NLT: cmp_result = cmp_lt;  branch_on = false;
        case Opcode.JMP_NLE: cmp_result = cmp_le;  branch_on = false;
        case Opcode.JMP_NGT: cmp_result = !cmp_le; branch_on = false;
        case Opcode.JMP_NGE: cmp_result = !cmp_lt; branch_on = false;
        case Opcode.JMP_LE:  cmp_result = cmp_le;  branch_on = true;
        case Opcode.JMP_GT:  cmp_result = !cmp_le; branch_on = true;
        default:             cmp_result = !cmp_lt; branch_on = true;   // JMP_GE
    }
    if (cmp_result == branch_on) {
        if ((ichar)insn.a < 0) {
            if (th_bwd_edge_needs_safepoint(cold)) return pc;
            cold.vm.heap.bwd_gc_budget--;
        }
        pc += (sz)(1 + (int)(ichar)insn.a);
    } else {
        pc++;
    }
    return th_next(pc, code_end, regs, cold);
}

// Fused `GETGLOBAL_PRIM rX, S` + `JMP_LT off, rB, rX`. Two-word: pc holds the
// jump offset in A and the surviving register operand in B; pc+1 (a NOP) holds
// the global's name index. The IC slot sits at the trailing word's offset, one
// past this handler's own, which is where the switch populates it: it computes
// the index after advancing past both words.
//
// A guard miss returns pc unconsumed, leaving the switch to resolve the global
// by env walk, fill the IC, and advance pc itself.
fn Instruction* th_jmp_lt_g(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint name_off = (uint)(pc + 1 - cold.code_base);
    hobject::VarICEntry* gic = vic_base + name_off;
    HObject* gb = (HObject*)gic.bindings;
    if (gb == null || gic.search_head != (void*)cold.act.lex_env || gb.shape_id != gic.shape_id) return pc;
    TVal* gval = &gb.prop_values()[gic.prop_idx];
    if (env::is_tdz_sentinel(gval)) return pc;

    TVal* rb = regs + insn.b;
    bool cmp_lt;
    if (types::both_fastint(rb, gval)) {
        cmp_lt = rb.get_fastint() < gval.get_fastint();
    } else if ((rb.is_fastint() || rb.is_number()) && (gval.is_fastint() || gval.is_number())) {
        cmp_lt = tval_numeric_to_double(rb) < tval_numeric_to_double(gval);
    } else {
        return pc; // relational coercion may call user code / throw -> switch
    }
    // The fused offset is based on the resume point past BOTH words.
    if (cmp_lt) {
        if ((ichar)insn.a < 0) {
            if (th_bwd_edge_needs_safepoint(cold)) return pc;
            cold.vm.heap.bwd_gc_budget--;
        }
        pc += (sz)(2 + (int)(ichar)insn.a);
    } else {
        pc += 2;
    }
    return th_next(pc, code_end, regs, cold);
}

// --- Global-slot access (perf-all VarRef fast path). ---
//
// pc points AT the current instruction (unlike the switch loop, where curr_pc
// has already been incremented), so the IC slot index is (pc - code_base),
// matching the switch's (curr_pc - 1 - code_base). A hit is one prop_alloc
// pointer compare + a direct slot load/store -- no shape-id, no env walk.

fn Instruction* th_getglobal(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* gic = vic_base + pc_off;
    HObject* gb = (HObject*)gic.bindings;
    if (gb == null || gic.search_head != (void*)cold.act.lex_env || gb.shape_id != gic.shape_id) return pc;
    TVal* pv = &gb.prop_values()[gic.prop_idx];
    if (env::is_tdz_sentinel(pv)) return pc; // TDZ -> switch throws
    TVal* ra = regs + insn.a;
    if (!pv.is_heap_allocated() && !ra.is_heap_allocated()) {
        // prim -> prim: no refcount, no heap ref lands in the register, so no
        // track_heap_store.
        *ra = *pv;
    } else {
        // A heap operand is common here (object-valued globals), so this stays
        // inline rather than bailing: the refcount call frames the handler, but
        // routing every such read through the switch costs more.
        cold.vm.heap.tval_copy_ref(ra, pv);
        track_heap_store(cold.act, ra, (uint)insn.a);
    }
    pc++;
    return th_next(pc, code_end, regs, cold);
}

// Proven primitive-only global read (see GETGLOBAL_PRIM in bytecode.c3): the
// slot can never hold a heap value, so no source incref, no track_heap_store.
// A destination register still holding a stale heap ref needs a decref, which
// is a real call; taking it here would make this handler non-leaf and cost
// every hit a five-pair register save/restore, so that case bails to the
// switch instead (see the leaf-handler note above th_next).
fn Instruction* th_getglobal_prim(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* gic = vic_base + pc_off;
    HObject* gb = (HObject*)gic.bindings;
    if (gb == null || gic.search_head != (void*)cold.act.lex_env || gb.shape_id != gic.shape_id) return pc;
    TVal* pv = &gb.prop_values()[gic.prop_idx];
    if (env::is_tdz_sentinel(pv)) return pc;
    TVal* ra = regs + insn.a;
    if (ra.is_heap_allocated()) return pc;
    *ra = *pv;
    pc++;
    return th_next(pc, code_end, regs, cold);
}

// Proven primitive-only global write: the overwritten slot value is provably
// primitive (no decref) and the stored value is provably primitive (no incref/
// track). Raw slot write.
fn Instruction* th_putglobal_prim(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* gic = vic_base + pc_off;
    HObject* gb = (HObject*)gic.bindings;
    if (gb == null || gic.search_head != (void*)cold.act.lex_env || gb.shape_id != gic.shape_id || !gic.varref_store_ok) return pc;
    TVal* ra = regs + insn.a;
    TVal* pv = &gb.prop_values()[gic.prop_idx];
    *pv = *ra;
    ra.set_undefined();
    pc++;
    return th_next(pc, code_end, regs, cold);
}

// Fused primitive-only global-to-global copy (`a = b`). Two-word instruction:
// pc holds the destination name (BC); pc+1 (a NOP) holds the source name (BC).
// Two inline caches: the dst write at pc_off and the src read at pc_off+1. The
// hot path only,
// any miss bails to the switch VM, which resolves the cold path AND advances
// pc past both words. On hit, advance pc by 2.
fn Instruction* th_move_gg(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Vm* vm = cold.vm;
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint dst_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* dic = vic_base + dst_off;
    hobject::VarICEntry* sic = vic_base + dst_off + 1;
    HObject* dgb = (HObject*)dic.bindings;
    HObject* sgb = (HObject*)sic.bindings;
    if (dgb == null || dic.search_head != (void*)cold.act.lex_env || dgb.shape_id != dic.shape_id || !dic.varref_store_ok) return pc;
    if (sgb == null || sic.search_head != (void*)cold.act.lex_env || sgb.shape_id != sic.shape_id) return pc;
    TVal* spv = &sgb.prop_values()[sic.prop_idx];
    if (env::is_tdz_sentinel(spv)) return pc;
    // Both slots provably primitive: raw copy, no refcount.
    dgb.prop_values()[dic.prop_idx] = *spv;
    pc += 2;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_putglobal(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* gic = vic_base + pc_off;
    HObject* gb = (HObject*)gic.bindings;
    // Only writable non-configurable data globals (varref_store_ok) may take
    // the re-check-free store path -- exactly the switch's fast-path gate.
    if (gb == null || gic.search_head != (void*)cold.act.lex_env || gb.shape_id != gic.shape_id || !gic.varref_store_ok) return pc;
    TVal* ra = regs + insn.a;
    TVal* pv = &gb.prop_values()[gic.prop_idx];
    vm.heap.tval_move_slot_fast(pv, ra);
    ra.set_undefined();
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_inc_global_impl(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, bool is_inc) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* gic = vic_base + pc_off;
    HObject* gb = (HObject*)gic.bindings;
    if (gb == null || gic.search_head != (void*)cold.act.lex_env || gb.shape_id != gic.shape_id || !gic.varref_store_ok) return pc;
    TVal* slot = &gb.prop_values()[gic.prop_idx];
    TVal old_val = *slot;
    // Threaded fast path: fastint only. number/bigint/TDZ -> switch.
    if (!old_val.is_fastint()) return pc;
    TVal* ra = regs + insn.a;
    long v = old_val.get_fastint() + (is_inc ? 1L : -1L);
    if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
        slot.set_fastint(v);
        ra.set_fastint(v);
    } else {
        slot.set_number((double)v);
        ra.set_number((double)v);
    }
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_inc_global(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_inc_global_impl(pc, code_end, regs, cold, true);
}

fn Instruction* th_dec_global(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_inc_global_impl(pc, code_end, regs, cold, false);
}

// --- Variable access: VarIC (shape and recycle-epoch) hit path only. ---

fn Instruction* th_getvar(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    uint bc = insn.get_bc();
    if (bc >= vm.current_func.const_count) return pc;
    TVal name_val = vm.current_func.constants[bc];
    if (!name_val.is_string()) return pc;
    void* key = name_val.get_heapptr();
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* vic = vic_base + pc_off;
    if (vic.env == null || vic.key != key || vic.search_head != (void*)act.lex_env) return pc;
    HObject* b = (HObject*)vic.bindings;
    if (b.shape_id != vic.shape_id
        || vm.heap.shape_recycle_epoch != vic.recycle_epoch) return pc;
    if (b.get_prop_flags(vic.prop_idx).is_accessor) return pc; // getter -> switch
    TVal v = b.prop_values()[vic.prop_idx];
    if (env::is_tdz_sentinel(&v)) return pc; // TDZ error -> switch
    TVal* ra = regs + insn.a;
    vm.heap.tval_copy_ref(ra, &v);
    track_heap_store(act, ra, (uint)insn.a);
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_putvar_assign(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    uint bc = insn.get_bc();
    if (bc >= vm.current_func.const_count) return pc;
    TVal name_val = vm.current_func.constants[bc];
    if (!name_val.is_string()) return pc;
    void* key = name_val.get_heapptr();
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* vic = vic_base + pc_off;
    if (vic.env == null || vic.key != key || vic.search_head != (void*)act.lex_env) return pc;
    HObject* b = (HObject*)vic.bindings;
    if (b.shape_id != vic.shape_id
        || vm.heap.shape_recycle_epoch != vic.recycle_epoch) return pc;
    TVal* pv = &b.prop_values()[vic.prop_idx];
    hobject::PropFlags fl = b.get_prop_flags(vic.prop_idx);
    if (env::is_tdz_sentinel(pv) || !fl.writable || fl.is_accessor) return pc;
    TVal* ra = regs + insn.a;
    vm.heap.decref_tval(pv);
    *pv = *ra;
    ra.set_undefined();
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_inc_var(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    uint bc = insn.get_bc();
    if (bc >= vm.current_func.const_count) return pc;
    TVal name_val = vm.current_func.constants[bc];
    if (!name_val.is_string()) return pc;
    void* key = name_val.get_heapptr();
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* vic = vic_base + pc_off;
    if (vic.env == null || vic.key != key || vic.search_head != (void*)act.lex_env) return pc;
    HObject* b = (HObject*)vic.bindings;
    if (b.shape_id != vic.shape_id
        || vm.heap.shape_recycle_epoch != vic.recycle_epoch) return pc;
    TVal old_val = b.prop_values()[vic.prop_idx];
    if (env::is_tdz_sentinel(&old_val) || !b.get_prop_flags(vic.prop_idx).writable) return pc;
    if (!old_val.is_fastint()) return pc;
    TVal* ra = regs + insn.a;
    long v = old_val.get_fastint() + 1L;
    if (v >= types::FASTINT_MIN && v <= types::FASTINT_MAX) {
        b.prop_values()[vic.prop_idx].set_fastint(v);
        ra.set_fastint(v);
    } else {
        b.prop_values()[vic.prop_idx].set_number((double)v);
        ra.set_number((double)v);
    }
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_tonumeric(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) return pc;
    TVal* ra = regs + insn.a;
    ra.set_fastint(rb.get_fastint());
    pc++;
    return th_next(pc, code_end, regs, cold);
}

// --- Property access: monomorphic inline-cache hit path only. ---
//
// A property op is a call into dispatch_property, whose prologue and sub-switch
// cost more than the cached load or store itself. These handlers serve only the
// IC hit, so the exotic receivers, accessors, prototype walks and shape
// transitions all stay behind one bail to the switch, which re-decodes the
// instruction and runs the full handler.

/// The ICEntry for the instruction at `pc`, or null when the function carries
/// no IC array.
macro hobject::ICEntry* th_ic_at(Vm* vm, ColdCtx* cold, Instruction* pc) {
    hobject::ICEntry* base = (hobject::ICEntry*)vm.current_func.ic_entries;
    return base == null ? null : base + (uint)(pc - cold.code_base);
}

fn Instruction* th_getpropc(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    TVal* rb = regs + insn.b;
    if (!rb.is_object()) return pc;
    HObject* hobj = (HObject*)rb.get_heapptr();
    // Proxy [[Get]] can run a trap, so it never reaches the cache.
    if (hobj.flags.exotic_proxyobj) return pc;
    hobject::ICEntry* ic = th_ic_at(vm, cold, pc);
    if (ic == null) return pc;
    void* key = vm.current_func.constants[(uint)insn.c].get_heapptr();
    if (ic.key != key || ic.shape_id != hobj.shape_id
        || ic.shape_gen != hobj.shape_generation()) return pc;
    HObject* owner = hobject::ic_resolve_owner(ic, hobj);
    if (owner == null || ic.cached_prop_alloc != (void*)owner.prop_values()) return pc;
    TVal ic_val = *ic.prop_value_ptr;
    TVal* ra = regs + insn.a;
    if (!ic_val.is_heap_allocated()) {
        *ra = ic_val;
    } else {
        vm.heap.tval_copy_ref(ra, &ic_val);
        track_heap_store(cold.act, ra, (uint)insn.a);
    }
    pc++;
    return th_next(pc, code_end, regs, cold);
}

/// GETPROPC_CACHED, the warm form GETPROPC rewrites itself into. The key is
/// implied by the site, so only the shape and the storage pointer are checked;
/// a miss bails so the switch performs the downgrade back to GETPROPC.
fn Instruction* th_getpropc_cached(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    TVal* rb = regs + insn.b;
    if (!rb.is_object()) return pc;
    HObject* hobj = (HObject*)rb.get_heapptr();
    hobject::ICEntry* ic = th_ic_at(vm, cold, pc);
    if (ic == null) return pc;
    if (ic.shape_id != hobj.shape_id || ic.shape_gen != hobj.shape_generation()) return pc;
    HObject* owner = hobject::ic_resolve_owner(ic, hobj);
    if (owner == null || ic.cached_prop_alloc != (void*)owner.prop_values()) return pc;
    TVal ic_val = *ic.prop_value_ptr;
    TVal* ra = regs + insn.a;
    if (!ic_val.is_heap_allocated()) {
        *ra = ic_val;
    } else {
        vm.heap.tval_copy_ref(ra, &ic_val);
        track_heap_store(cold.act, ra, (uint)insn.a);
    }
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_putprop(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    TVal* ra = regs + insn.a;
    if (!ra.is_object()) return pc;
    HObject* hobj = (HObject*)ra.get_heapptr();
    TVal* rb = regs + insn.b;
    if (!rb.is_string()) return pc;
    hobject::ICEntry* ic = th_ic_at(vm, cold, pc);
    if (ic == null) return pc;
    // proto == null restricts the entry to an own property, so no exotic
    // receiver, inherited setter or prototype walk can be in play: the switch
    // only ever fills this entry from the plain own-data-property store, and
    // every exotic class it guards against changes the shape id or is not a
    // plain object at all.
    if (ic.key != rb.get_heapptr() || ic.shape_id != hobj.shape_id || ic.proto != null
        || ic.shape_gen != hobj.shape_generation()) return pc;
    if (ic.cached_prop_alloc != (void*)hobj.prop_values()
        || ic.prop_flags.is_accessor || !ic.prop_flags.writable) return pc;
    vm.heap.tval_copy_ref(ic.prop_value_ptr, regs + insn.c);
    pc++;
    return th_next(pc, code_end, regs, cold);
}

// Entry point from Vm.run's inner loop. Runs a burst starting at pc; returns
// the resume pc (== pc if the first opcode isn't in the hot set). Never sets
// needs_restart/halt -- the switch loop re-decodes from the returned pc.
fn Instruction* run_threaded_burst(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    if (pc >= code_end) return pc;
    Instruction first = *pc;
    return g_threaded_handlers[first.op.ordinal](pc, code_end, regs, cold);
}
