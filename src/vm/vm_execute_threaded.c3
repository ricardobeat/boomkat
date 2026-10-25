module boomkat::vm;

import boomkat::types;
import std::io;
import std::thread;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::env;
import boomkat::builtins;

// ============================================================================
// Direct-threaded dispatch (feature THREADED_DISPATCH, on by default). The hot
// loops are dispatch-bound after op-count consolidation, with many trivial
// slot ops:
//
//   assign60 body: 4x(GETGLOBAL + PUTGLOBAL) + INC_GLOBAL + GETVAR + JMP_LT
//   fib34   body:  LDINT/SUBI/ADD + JMP_NLE compare-branch + CALL_VAR/RET
//   emptyloop:     INC_GLOBAL + GETVAR + JMP_LT
//
// The global-slot ops (GETGLOBAL/PUTGLOBAL/INC_GLOBAL/DEC_GLOBAL) thread their
// perf-all VarRef fast path: one prop_alloc pointer compare + a direct slot
// load/store, no shape-id load, no env walk. Any IC miss / slow path bails to
// the switch.
//
// Design constraint: the hot fields (pc, handler table, regs base) are
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
// Each handler ends in a TAIL CALL through g_threaded_table.fns[...], which at
// -O2 LLVM lowers to an indirect tail JUMP (br xN) -- computed-goto-style
// threading with no goto/musttail (which C3 lacks).
// ============================================================================

alias ThreadedHandlerFn = fn Instruction*(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold);

// The dispatch table travels as a handler argument, which keeps its address in
// a register across the whole burst: a table reached through its global symbol
// costs an address computation on every dispatch.
struct HandlerTable {
    ThreadedHandlerFn[TH_TABLE_SIZE] fns;
}

const usz TH_TABLE_SIZE = Opcode.LAST_OP.ordinal + 1;
HandlerTable g_threaded_table;
OnceFlag g_threaded_handlers_once;

fn void init_threaded_handlers() => g_threaded_handlers_once.call(&fill_threaded_handlers);

fn void fill_threaded_handlers() {
    for (usz i = 0; i < TH_TABLE_SIZE; i++) {
        g_threaded_table.fns[i] = &th_bailout;
    }
    // --- Tight-loop arith ops ---
    g_threaded_table.fns[Opcode.ADDI.ordinal]   = &th_addi;
    g_threaded_table.fns[Opcode.LDREG.ordinal]  = &th_ldreg;
    g_threaded_table.fns[Opcode.LDTHIS.ordinal] = &th_ldthis;

    // --- Recursion (fib) cheap ops ---
    g_threaded_table.fns[Opcode.LDINT.ordinal]  = &th_ldint;
    g_threaded_table.fns[Opcode.SUBI.ordinal]   = &th_subi;
    g_threaded_table.fns[Opcode.ADD.ordinal]    = &th_add;
    g_threaded_table.fns[Opcode.ADD_FUSED.ordinal] = &th_add_fused;
    g_threaded_table.fns[Opcode.EQ.ordinal]     = &th_eq;
    g_threaded_table.fns[Opcode.NEQ.ordinal]    = &th_eq;
    g_threaded_table.fns[Opcode.SEQ.ordinal]    = &th_eq;
    g_threaded_table.fns[Opcode.SNEQ.ordinal]   = &th_eq;
    g_threaded_table.fns[Opcode.LT.ordinal]     = &th_relational;
    g_threaded_table.fns[Opcode.LE.ordinal]     = &th_relational;
    g_threaded_table.fns[Opcode.GT.ordinal]     = &th_relational;
    g_threaded_table.fns[Opcode.GE.ordinal]     = &th_relational;
    g_threaded_table.fns[Opcode.LNOT.ordinal]   = &th_lnot;
    g_threaded_table.fns[Opcode.TYPEOF.ordinal] = &th_typeof;
    g_threaded_table.fns[Opcode.DECLVAR.ordinal] = &th_declvar;
    g_threaded_table.fns[Opcode.DECLVAR_HOIST.ordinal] = &th_declvar;
    g_threaded_table.fns[Opcode.INSTANCEOF.ordinal] = &th_instanceof;
    g_threaded_table.fns[Opcode.UNM.ordinal]    = &th_unm;
    g_threaded_table.fns[Opcode.INC.ordinal]    = &th_incdec;
    g_threaded_table.fns[Opcode.INC_LT.ordinal] = &th_inc_lt;
    g_threaded_table.fns[Opcode.DEC.ordinal]    = &th_incdec;
    for (Opcode op = Opcode.JMP_NLT; op.ordinal <= Opcode.JMP_SNEQ.ordinal; op = (Opcode)(op.ordinal + 1)) {
        g_threaded_table.fns[op.ordinal] = &th_cmp_branch;
    }
    for (Opcode op = Opcode.JMP_NLTI; op.ordinal <= Opcode.JMP_SNEQI.ordinal; op = (Opcode)(op.ordinal + 1)) {
        g_threaded_table.fns[op.ordinal] = &th_cmp_branch_i;
    }
    // The relations loops test most get a handler of their own for the fastint
    // pair; the shared one above takes everything else.
    g_threaded_table.fns[Opcode.JMP_EQ.ordinal]   = &th_jmp_eq;
    g_threaded_table.fns[Opcode.JMP_NEQ.ordinal]  = &th_jmp_eq;
    g_threaded_table.fns[Opcode.JMP_NULL.ordinal]  = &th_jmp_null;
    g_threaded_table.fns[Opcode.JMP_NNULL.ordinal] = &th_jmp_null;
    g_threaded_table.fns[Opcode.JMP_LT.ordinal]   = &th_jmp_lt;
    g_threaded_table.fns[Opcode.JMP_LE.ordinal]   = &th_jmp_le;
    g_threaded_table.fns[Opcode.JMP_GT.ordinal]   = &th_jmp_gt;
    g_threaded_table.fns[Opcode.JMP_GE.ordinal]   = &th_jmp_ge;
    g_threaded_table.fns[Opcode.JMP_NLT.ordinal]  = &th_jmp_nlt;
    g_threaded_table.fns[Opcode.JMP_NLE.ordinal]  = &th_jmp_nle;
    g_threaded_table.fns[Opcode.JMP_NGT.ordinal]  = &th_jmp_ngt;
    g_threaded_table.fns[Opcode.JMP_NGE.ordinal]  = &th_jmp_nge;
    g_threaded_table.fns[Opcode.JMP_LTI.ordinal]  = &th_jmp_lti;
    g_threaded_table.fns[Opcode.JMP_LEI.ordinal]  = &th_jmp_lei;
    g_threaded_table.fns[Opcode.JMP_GTI.ordinal]  = &th_jmp_gti;
    g_threaded_table.fns[Opcode.JMP_GEI.ordinal]  = &th_jmp_gei;
    g_threaded_table.fns[Opcode.JMP_NLTI.ordinal] = &th_jmp_nlti;
    g_threaded_table.fns[Opcode.JMP_NLEI.ordinal] = &th_jmp_nlei;
    g_threaded_table.fns[Opcode.JMP_NGTI.ordinal] = &th_jmp_ngti;
    g_threaded_table.fns[Opcode.JMP_NGEI.ordinal] = &th_jmp_ngei;
    // CALL threads only the guarded intrinsic array-push case. The plain call
    // forms enter lean compiled functions directly, and RET/RETUNDEF handle
    // guarded primitive and receiver-return pops between ordinary compiled
    // functions.
    g_threaded_table.fns[Opcode.RET.ordinal] = &th_ret;
    g_threaded_table.fns[Opcode.RETUNDEF.ordinal] = &th_retundef;
    g_threaded_table.fns[Opcode.CALL.ordinal] = &th_call;
    g_threaded_table.fns[Opcode.CALL_UNDEF_THIS.ordinal] = &th_call_undef_this;
    g_threaded_table.fns[Opcode.CALL_VAR.ordinal] = &th_call_var;
    g_threaded_table.fns[Opcode.CALL_GLOBAL.ordinal] = &th_call_global;
    g_threaded_table.fns[Opcode.TAILCALL_VAR.ordinal] = &th_tailcall_var;
    g_threaded_table.fns[Opcode.TAILCALL_GLOBAL.ordinal] = &th_tailcall_global;
    g_threaded_table.fns[Opcode.TAILCALL_CALL.ordinal] = &th_tailcall_call;
    g_threaded_table.fns[Opcode.TAILCALL_UNDEF_THIS.ordinal] = &th_tailcall_undef_this;

    // --- Assignment (g_assign) hot ops: perf-all global-slot opcodes ---
    g_threaded_table.fns[Opcode.GETGLOBAL.ordinal]  = &th_getglobal;
    g_threaded_table.fns[Opcode.PUTGLOBAL.ordinal]  = &th_putglobal;
    g_threaded_table.fns[Opcode.INC_GLOBAL.ordinal] = &th_inc_global;
    g_threaded_table.fns[Opcode.DEC_GLOBAL.ordinal] = &th_dec_global;

    // --- Variable access (VarIC shape and recycle-epoch path) ---
    g_threaded_table.fns[Opcode.GETVAR.ordinal]        = &th_getvar;
    g_threaded_table.fns[Opcode.GETCAP.ordinal]        = &th_getcap;
    g_threaded_table.fns[Opcode.PUTCAP.ordinal]        = &th_putcap;
    g_threaded_table.fns[Opcode.PUTCAP_SNAP.ordinal]   = &th_putcap;
    g_threaded_table.fns[Opcode.GETCELL.ordinal]       = &th_getcell;
    g_threaded_table.fns[Opcode.SETCELL.ordinal]       = &th_setcell;
    g_threaded_table.fns[Opcode.MOVECELL.ordinal]      = &th_movecell;
    g_threaded_table.fns[Opcode.PUTVAR_ASSIGN.ordinal] = &th_putvar_assign;
    g_threaded_table.fns[Opcode.PUTVAR_SNAP.ordinal]   = &th_putvar_snap;
    g_threaded_table.fns[Opcode.RESOLVEVAR.ordinal]    = &th_resolvevar;
    g_threaded_table.fns[Opcode.THROW_UNRESOLVED.ordinal] = &th_throw_unresolved;
    g_threaded_table.fns[Opcode.INC_VAR.ordinal]       = &th_inc_var;
    g_threaded_table.fns[Opcode.JUMP.ordinal]          = &th_jump;
    g_threaded_table.fns[Opcode.IF_FALSE.ordinal]      = &th_if;
    g_threaded_table.fns[Opcode.IF_TRUE.ordinal]       = &th_if;
    g_threaded_table.fns[Opcode.CLASS_SCALAR_GUARD.ordinal] = &th_class_scalar_guard;
    g_threaded_table.fns[Opcode.SUB.ordinal]           = &th_sub;
    g_threaded_table.fns[Opcode.MUL.ordinal]           = &th_mul;
    g_threaded_table.fns[Opcode.MULI.ordinal]          = &th_muli;
    g_threaded_table.fns[Opcode.DIV.ordinal]           = &th_div;
    g_threaded_table.fns[Opcode.MOD.ordinal]           = &th_mod;
    g_threaded_table.fns[Opcode.BAND.ordinal]          = &th_band;
    g_threaded_table.fns[Opcode.BANDI.ordinal] = &th_bandi;
    g_threaded_table.fns[Opcode.BOR.ordinal]           = &th_bor;
    g_threaded_table.fns[Opcode.BORI.ordinal] = &th_bori;
    g_threaded_table.fns[Opcode.BXOR.ordinal]          = &th_bxor;
    g_threaded_table.fns[Opcode.BXORI.ordinal] = &th_bxori;
    g_threaded_table.fns[Opcode.SHL.ordinal]           = &th_shl;
    g_threaded_table.fns[Opcode.SHLI.ordinal] = &th_shli;
    g_threaded_table.fns[Opcode.SHR.ordinal]           = &th_shr;
    g_threaded_table.fns[Opcode.SHRI.ordinal] = &th_shri;
    g_threaded_table.fns[Opcode.USHR.ordinal]          = &th_ushr;
    g_threaded_table.fns[Opcode.USHRI.ordinal] = &th_ushri;
    g_threaded_table.fns[Opcode.LDCONST.ordinal]       = &th_ldconst;
    g_threaded_table.fns[Opcode.LDUNDEF.ordinal]       = &th_ldundef;
    g_threaded_table.fns[Opcode.LDNULL.ordinal]        = &th_ldnull;
    g_threaded_table.fns[Opcode.LDTRUE.ordinal]        = &th_ldbool;
    g_threaded_table.fns[Opcode.LDFALSE.ordinal]       = &th_ldbool;
    g_threaded_table.fns[Opcode.TRY.ordinal]           = &th_try;
    g_threaded_table.fns[Opcode.ENDTRY.ordinal]        = &th_endtry;
    g_threaded_table.fns[Opcode.ITER_NEXT_FAST.ordinal] = &th_iter_next_intrinsic;
    g_threaded_table.fns[Opcode.ITER_ENTRY_FAST.ordinal] = &th_iter_entry_guard;
    g_threaded_table.fns[Opcode.ARRAY_PATTERN_GUARD.ordinal] = &th_array_pattern_guard;
    g_threaded_table.fns[Opcode.TONUMERIC.ordinal]     = &th_tonumeric;

    // --- Property access: IC hit path (bench_object / bench_property_lookup) ---
    g_threaded_table.fns[Opcode.GETPROP.ordinal]         = &th_getprop_array;
    g_threaded_table.fns[Opcode.GETPROP_CACHE.ordinal]   = &th_getprop_array;
    g_threaded_table.fns[Opcode.GETPROPC.ordinal]        = &th_getpropc;
    g_threaded_table.fns[Opcode.GETPROPC_CACHED.ordinal] = &th_getpropc_cached;
    g_threaded_table.fns[Opcode.PUTPROP.ordinal]         = &th_putprop;
    g_threaded_table.fns[Opcode.PUTPROPC.ordinal]        = &th_putpropc;
    g_threaded_table.fns[Opcode.GETTHISC.ordinal]        = &th_getthisc;
    g_threaded_table.fns[Opcode.GETPROP_SUPER.ordinal]   = &th_getprop_super;
    g_threaded_table.fns[Opcode.GETPROTO.ordinal]        = &th_getproto;
    g_threaded_table.fns[Opcode.PUTTHISC.ordinal]        = &th_putthisc;
    g_threaded_table.fns[Opcode.INITPROP.ordinal]        = &th_initprop_array;
    g_threaded_table.fns[Opcode.INITELEM.ordinal]        = &th_initelem;
    g_threaded_table.fns[Opcode.NEWARR.ordinal]          = &th_newarr;
    g_threaded_table.fns[Opcode.NEWARR_CONST.ordinal]    = &th_newarr_const;
    g_threaded_table.fns[Opcode.NEW_OBJ.ordinal] = &th_new_obj;
    g_threaded_table.fns[Opcode.NEWOBJ.ordinal]          = &th_newobj;
    g_threaded_table.fns[Opcode.NEWOBJ_SHAPE.ordinal]    = &th_newobj;
    g_threaded_table.fns[Opcode.INIT_SLOT.ordinal]        = &th_init_slot;
}

// Bail: return the resume pc WITHOUT consuming *pc -- the switch loop
// re-decodes it.
fn Instruction* th_bailout(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @noinline {
    return pc;
}

// There is no fall-off-the-end test: the compiler ends every function with an
// explicit RET or RETUNDEF, which the switch loop also relies on. The same
// rule lets a handler read the instruction after its own without a bound
// check, since only a return can be last.
macro Instruction* th_next(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction next = *pc;
    $if $feat(OP_PROFILE):
        opprof_thread_complete();
        opprof_thread_begin(next.op);
    $endif
    opprof_th_record(next.op);
    // Tail call -> indirect tail jump at -O2.
    return handlers.fns[next.op.ordinal](pc, handlers, regs, cold);
}

// Charge one backward jump against the GC safepoint budget, reporting whether
// the caller must bail to the switch.
//
// Running the safepoint here instead would put a call in every branch handler,
// which is what makes them non-leaf: LLVM then wraps each one in a four-pair
// stp/ldp frame that every taken back-edge pays, on handlers whose fast path
// is a compare and a pc add. The budget expires once per BWD_GC_INTERVAL
// back-edges, so handing that iteration to the switch (which charges the
// budget itself and runs the safepoint) is far cheaper than framing the
// common case. The budget is left untouched on a bail so the switch's own
// decrement is the one that fires.
//
// The interrupt budget is charged here for the same reason: threaded dispatch
// consumes the vast majority of back-edges, so a poll that only ran at switch
// sites would fire roughly BWD_GC_INTERVAL times too rarely, and a runaway
// loop could run tens of millions of iterations before the host's abort
// landed. Charging here (and bailing on the due flag) holds the poll cadence
// at INTERRUPT_BUDGET_INIT back-edges in both dispatch modes. The flag is only
// ever set for embedded runtimes or an installed poll callback.
macro bool th_bwd_edge_bails(ColdCtx* cold) @private {
    heap::Heap* h = cold.heap;
    if (h.bwd_gc_budget <= 1) return true;
    if (h.capi_interrupt_fn != null || h.capi_runtime != null) {
        vm_charge_interrupt(h);
        if (h.interrupt_due) return true;
    }
    h.bwd_gc_budget--;
    return false;
}

fn Instruction* th_addi(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) return pc;
    TVal* ra = regs + insn.a;
    long sum = rb.get_fastint() + (long)(ichar)insn.c;
    if (!types::fits_fastint(sum) || !th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_fastint(sum);
    return th_next(pc + 1, handlers, regs, cold);
}

// Inline refcount helpers, split into a test and a mutation.
//
// Calling Heap.incref/decref from a threaded handler makes LLVM frame the whole
// function -- five stp/ldp pairs saving ten callee-saved registers on every
// instruction. Doing the common case inline keeps the handler a leaf, which was
// worth ~8% on captured-variable loops.
//
// The split matters: a handler that touches both sides must confirm BOTH are
// inlinable before mutating either, or a bail after a completed retain leaks
// the reference it took.

// A pinned string (builtin strings, well-known symbols, the small-int cache,
// interned constants) keeps a fixed refcount, so retaining or releasing one is
// a no-op. Only strings are counted.

macro void th_do_retain(TVal* v) @private {
    if (!v.is_refcounted()) return;
    void* p = v.get_heapptr();
    if (p == null) return;
    types::HeapHeader* h = (types::HeapHeader*)p;
    if (!h.is_pinned()) h.refcount++;
}

// True when the reference `slot` holds can be dropped with a plain decrement:
// the fast half of Heap.decref. A string that would hit zero goes to the
// switch, which frees it.
macro bool th_can_release(TVal* slot) @private {
    if (!slot.is_refcounted()) return true;
    void* p = slot.get_heapptr();
    if (p == null) return true;
    types::HeapHeader* h = (types::HeapHeader*)p;
    return h.is_pinned() || h.refcount > 1;
}

macro void th_do_release(TVal* slot) @private {
    if (!slot.is_refcounted()) return;
    void* p = slot.get_heapptr();
    if (p == null) return;
    types::HeapHeader* h = (types::HeapHeader*)p;
    if (!h.is_pinned()) h.refcount--;
}

macro bool th_can_release_slot(hobject::PropValue* slot) @private {
    TVal value = slot.get();
    return th_can_release(&value);
}

macro void th_do_release_slot(hobject::PropValue* slot) @private {
    TVal value = slot.get();
    th_do_release(&value);
}

// The switch shades a publication that needs tracing in this collection. Keep the
// threaded path free of calls into the collector after it mutates a register.
macro bool th_can_publish(heap::Heap* h, TVal value) @private {
    if (h.gc_phase != heap::GcPhase.MARK || !value.is_traced()) return true;
    if (value.is_envref()) return false;
    void* ptr = value.get_heapptr();
    return !h.gc_needs_mark((types::HeapHeader*)ptr);
}

fn Instruction* th_ldreg(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal value = regs[insn.b];
    TVal* ra = regs + insn.a;
    // An inert value needs no publication, retain or tracking, and a register
    // that holds anything but a string has no count to release.
    if (value.is_inert() && !ra.is_refcounted()) {
        *ra = value;
        return th_next(pc + 1, handlers, regs, cold);
    }
    if (!th_can_publish(cold.heap, value) || !th_can_release(ra)) return pc;
    th_do_retain(&value);
    th_do_release(ra);
    *ra = value;
    track_heap_store(cold.act, ra, (uint)insn.a);
    pc++;
    return th_next(pc, handlers, regs, cold);
}

fn Instruction* th_ldthis(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal value = cold.act.this_binding;
    // Derived-constructor TDZ errors and collector shading use the switch.
    if (env::is_tdz_sentinel(&value) || !th_can_publish(cold.heap, value)) return pc;
    TVal* ra = regs + pc.a;
    if (!th_can_release(ra)) return pc;
    th_do_retain(&value);
    th_do_release(ra);
    *ra = value;
    track_heap_store(cold.act, ra, (uint)pc.a);
    pc++;
    return th_next(pc, handlers, regs, cold);
}

// TRY and ENDTRY mirror dispatch_exceptions: push a catcher on entry and pop a
// finally-less one on normal exit. The catcher never allocates on the hot path
// (see catcher_acquire); an exhausted allocator falls back to the switch.
fn Instruction* th_try(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    uint finally_offset = bytecode::try_finally_offset(pc[1]);
    Vm* vm = cold.vm;
    Catcher* cat = catcher_acquire(vm.heap);
    if (cat == null) return pc;
    Activation* act = cold.act;
    cat.parent = (Catcher*)act.cat;
    cat.flags = insn.a;
    cat.thrown_val.set_undefined();
    cat.return_val.set_undefined();
    cat.pending_pc = null;
    cat.catch_pc = pc + (int)insn.get_bc();
    cat.finally_pc = finally_offset != 0 ? pc + (int)finally_offset : null;
    cat.endfinally_pc = null;
    cat.saved_lex_env = (void*)act.lex_env;
    vm.heap.shade_root_env(cat.saved_lex_env);
    act.cat = (void*)cat;
    return th_next(pc + 2, handlers, regs, cold);
}

fn Instruction* th_endtry(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Activation* act = cold.act;
    Catcher* cat = (Catcher*)act.cat;
    if (cat != null && cat.finally_pc == null) {
        act.cat = (void*)cat.parent;
        catcher_release(cold.heap, cat);
    }
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_array_pattern_guard(Instruction* pc, HandlerTable* handlers,
                                      TVal* regs, ColdCtx* cold) {
    return th_next(pc + (array_pattern_intrinsics(cold.vm) ? 2 : 1), handlers, regs, cold);
}

// Non-map sources keep their existing threaded iteration path.
fn Instruction* th_iter_entry_guard(Instruction* pc, HandlerTable* handlers,
                                    TVal* regs, ColdCtx* cold) {
    TVal iterator = regs[pc.b];
    if (iterator.is_object()
        && ((HObject*)iterator.get_heapptr()).get_class() == hobject::ObjClass.MAP_ITERATOR) return pc;
    return th_next(pc + 1, handlers, regs, cold);
}

// Keep guarded built-in iterator steps in threaded dispatch. Refusals return
// the original PC so the switch runs ITER_NEXT_FAST's full guard and protocol
// fallback. Array completion stays on the switch path because it releases the
// iterator target there; string completion has no owned target to release.
fn Instruction* th_iter_next_intrinsic(Instruction* pc, HandlerTable* handlers,
                                       TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    if (insn.a == insn.b || insn.a == insn.c) return pc;
    TVal* iterator_slot = regs + insn.b;
    TVal* next_slot = regs + insn.c;
    if (!iterator_slot.is_object() || !next_slot.is_object()) return pc;
    HObject* iterator = (HObject*)iterator_slot.get_heapptr();
    HObject* next_fn = (HObject*)next_slot.get_heapptr();
    if (iterator == null || iterator.is_proxy()
        || next_fn == null || !next_fn.is_callable()
        || next_fn.callable_kind() != hobject::CallableKind.BUILTIN_FN) return pc;

    int next_index = (*next_fn.extra_ptr()).func.builtin_fn_index;
    if (iterator.flags.obj_class == hobject::ObjClass.STRING_ITERATOR) {
        if (next_index != (int)builtins::Builtin.STRING_ITERATOR_NEXT.ordinal) return pc;
        hstring::HString* source = (*iterator.extra_ptr()).str_iter.string.borrow();
        if (source == null) return pc;
        uint index = (*iterator.extra_ptr()).str_iter.index;
        char[] data = source.get_data();
        if (index >= data.len) return th_next(pc + 2, handlers, regs, cold);

        uint byte = (uint)data[index];
        if (byte >= heap::ASCII_CHAR_CACHE_SIZE) return pc;
        hstring::HString* character = cold.heap.ascii_char_strs[byte];
        if (character == null || !((types::HeapHeader*)character).is_pinned()) return pc;

        TVal* dest = regs + insn.a;
        bool dest_pinned = false;
        if (dest.is_refcounted()) {
            void* dest_ptr = dest.get_heapptr();
            dest_pinned = dest_ptr != null
                && ((types::HeapHeader*)dest_ptr).is_pinned();
        }
        if (!dest_pinned && !th_can_release(dest)) return pc;
        if (!dest_pinned) th_do_release(dest);
        TVal value;
        value.set_string(character);
        *dest = value;
        track_heap_store(cold.act, dest, (uint)insn.a);
        (*iterator.extra_ptr()).str_iter.index = index + 1;
        return th_next(pc + 3, handlers, regs, cold);
    }

    // The kinds that read an element as is (`values`, and `keys` where it is the
    // element); `entries` allocates a pair and stays on the switch, as does
    // reaching the end, which releases the iterator's target. A step reads a
    // number, which needs no reference.
    HObject* target = (*iterator.extra_ptr()).iter.target;
    uint kind = (*iterator.extra_ptr()).iter.kind;
    uint index = (*iterator.extra_ptr()).iter.index;
    if (target == null || kind == 2) return pc;
    TVal value;
    uint resume;
    switch (iterator.flags.obj_class) {
        case hobject::ObjClass.ARRAY_ITERATOR:
            if (next_index != (int)builtins::Builtin.ARRAY_ITERATOR_NEXT.ordinal || kind != 0
                || target.flags.obj_class != hobject::ObjClass.ARRAY
                || target.is_proxy() || target.flags.has_indexed_named_prop
                || target.array_part() == null
                || index >= *target.array_len_ptr() || index >= target.array_size) return pc;
            value = target.array_part()[index].get();
            resume = index + 1;
        case hobject::ObjClass.SET_ITERATOR:
            if (next_index != (int)builtins::Builtin.SET_ITERATOR_NEXT.ordinal) return pc;
            uint slot = index;
            hobject::PropValue* entries = target.array_part();
            while (entries != null && slot < target.array_used && entries[slot].get().is_deleted()) slot++;
            if (entries == null || slot >= target.array_used) return pc;
            value = entries[slot].get();
            resume = slot + 1;
        case hobject::ObjClass.MAP_ITERATOR:
            if (next_index != (int)builtins::Builtin.MAP_ITERATOR_NEXT.ordinal) return pc;
            uint slot = index * 2;
            hobject::PropValue* entries = target.array_part();
            while (entries != null && slot < target.array_used && entries[slot].get().is_deleted()) slot += 2;
            if (entries == null || slot >= target.array_used) return pc;
            value = entries[kind == 1 ? slot : slot + 1].get();
            resume = slot / 2 + 1;
        default:
            return pc;
    }
    if (!value.is_fastint() && !value.is_number()) return pc;

    TVal* dest = regs + insn.a;
    if (!th_can_release(dest)) return pc;
    th_do_release(dest);
    *dest = value;
    (*iterator.extra_ptr()).iter.index = resume;

    // The third jump after ITER_NEXT_FAST goes to this step's consumer. It
    // handles for-of, destructuring elements, and array-rest collection.
    return th_next(pc + 3, handlers, regs, cold);
}

// A call of a native builtin, run as the switch runs it. A call while GC work
// is due bails, since the switch owns call safepoints. The call cannot be run
// again once it has, so a throw is left on the Vm for vm_dispatch to raise at
// the next instruction, and so is a call the builtin re-dispatches that the
// loop cannot enter (th_call_redispatched).
// The rest of a call a builtin re-dispatched over its own window: the callee,
// receiver and `nargs` arguments it left from `callee_reg` up, holding owned
// references the caller's frame now tracks. A lean callee is entered when
// th_enter_lean cannot bail, which it does only to release a temporary above
// the arguments; anything else is handed to vm_dispatch as a plain CALL, which
// is how the switch finishes a re-dispatched call.
fn Instruction* th_call_redispatched(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                                     uint callee_reg, uint result_reg, uint nargs) @private @noinline {
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    uint window_end = callee_reg + 2 + nargs;
    TVal callee = regs[callee_reg];
    CompiledFunction* target = null;
    if (window_end <= vm.current_func.num_regs) {
        for (uint r = callee_reg; r < window_end; r++) track_heap_store(act, regs + r, r);
        // A function first reached through apply or call has not been through
        // the switch's call entry, which classifies it.
        if (callee.is_object()) {
            HObject* callee_obj = (HObject*)callee.get_heapptr();
            if (callee_obj != null && callee_obj.is_callable()
                && callee_obj.callable_kind() == hobject::CallableKind.COMPILED_FN) {
                CompiledFunction* classified = (*callee_obj.extra_ptr()).func.comp_func;
                if (classified != null) classified.classify_lean_call();
            }
        }
        target = th_lean_target(vm, callee, regs + callee_reg + 2, false);
    }
    TVal receiver = regs[callee_reg + 1];
    TVal this_value = th_undefined();
    bool this_valid = false;
    if (target != null) {
        if (receiver.is_heap_allocated()) {
            if (!receiver.is_object() || receiver.get_heapptr() == null) {
                target = null;
            } else if (!target.call_flags.ignores_this) {
                this_value = receiver;
                this_valid = true;
            }
        } else if (!target.call_flags.ignores_this) {
            target = null;
        }
    }
    if (target != null && th_call_gate(cold)) target = null;
    if (target != null && callee_reg + 1 < act.heap_reg_count) {
        TVal* bottom = regs + callee_reg + 2;
        TVal* owned_end = regs + act.heap_reg_count;
        if (owned_end > bottom + target.num_regs) owned_end = bottom + target.num_regs;
        for (TVal* p = bottom + nargs; p < owned_end; p++) {
            if (!th_can_release(p)) { target = null; break; }
        }
    }
    if (target == null) {
        vm.eval_redispatched = builtins::is_intrinsic_eval(callee);
        vm.threaded_call = { .op = Opcode.CALL, .a = result_reg, .b = callee_reg, .c = nargs };
        vm.threaded_handoff = ThreadedHandoff.CALL;
        return pc + 1;
    }
    return th_enter_lean(pc, handlers, regs, cold, target, callee_reg, result_reg, nargs, false, false,
                         this_value, this_valid);
}

fn Instruction* th_call_native(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                               uint callee_reg, uint result_reg, uint nargs) @private @noinline {
    Vm* vm = cold.vm;
    TVal callee = regs[callee_reg];
    HObject* function = null;
    uint fn_idx;
    if (callee.is_lightfunc()) {
        fn_idx = (uint)(usz)callee.get_heapptr();
    } else {
        if (!callee.is_object()) { opprof_bail(NATIVE_KIND); return pc; }
        function = (HObject*)callee.get_heapptr();
        if (function == null || !function.is_callable()
            || function.callable_kind() != hobject::CallableKind.BUILTIN_FN
            || (*function.extra_ptr()).func.builtin_fn_index < 0) { opprof_bail(NATIVE_KIND); return pc; }
        fn_idx = (uint)(*function.extra_ptr()).func.builtin_fn_index;
    }
    if (cold.heap.gc_safepoint_due(true)) { opprof_bail(NATIVE_GATE); return pc; }

    // The actual builtin identity, primitive receiver and integer index make
    // this a non-throwing read; all coercion and Unicode cases stay generic.
    if (fn_idx == builtins::Builtin.STRING_PROTO_CHARCODEAT.ordinal && nargs > 0) {
        HString* text = plain_string_of(regs + callee_reg + 1);
        TVal index = regs[callee_reg + 2];
        if (text != null && text.is_ascii() && index.is_fastint()) {
            long offset = index.get_fastint();
            TVal* dest = regs + result_reg;
            if (offset >= 0 && offset < (long)text.blen && th_can_release(dest)) {
                uint code = text.get_cstr()[offset];
                th_do_release(dest);
                dest.set_fastint((long)code);
                return th_next(pc + 1, handlers, regs, cold);
            }
        }
    }

    Activation* act = cold.act;
    act.curr_pc = pc + 1;
    TVal* top = act.bottom + vm.current_func.num_regs + 4;
    if (top > vm.valstack_top) vm.valstack_top = top;
    TVal result;
    result.set_undefined();
    builtins::BuiltinContext ctx = call_context(cold, callee_reg, nargs, &result,
                                                this_val: &regs[callee_reg + 1], callee: function);
    builtins::dispatch_builtin(fn_idx, &ctx);
    // The builtin may have moved the value stack.
    regs = act.bottom;
    *cold.regs_base_ptr = regs;
    if (ctx.should_throw) {
        vm.threaded_throw = ctx.throw_value;
        vm.threaded_handoff = ThreadedHandoff.THROW;
        return pc + 1;
    }
    if (ctx.needs_re_dispatch) {
        return th_call_redispatched(pc, handlers, regs, cold, callee_reg, result_reg, ctx.re_nargs);
    }
    cold.heap.store_builtin_result(regs + result_reg, &result);
    track_heap_store(act, regs + result_reg, result_reg);
    return th_next(pc + 1, handlers, regs, cold);
}

// The threaded call entry handles a call to a "lean" compiled function (see
// CompiledFunction.lean_call): one whose frame needs no scope object, arguments
// object, rest array, `this` coercion or lexical bridge, so pushing it is plain
// stores. Everything else, and every state that needs the collector's
// attention, bails to the switch, which runs the general entry.
//
// Like th_getvar, the handlers stay leaves: every test happens before the first
// mutation, and the only calls left are the tail jump into the callee.

const uint TH_CALL_BURST = 256;

fn TVal th_undefined() @private @inline {
    TVal v;
    v.set_undefined();
    return v;
}

// Whether a call must take the switch path: a collection is due, or one is
// marking and the frame's roots would need shading as they are published, or
// the burst has entered TH_CALL_BURST calls without returning to the switch.
macro bool th_call_gate(ColdCtx* cold) @private {
    Vm* vm = cold.vm;
    if (vm.heap.gc_safepoint_due(true)) { opprof_bail(GATE_GC); return true; }
    if (++cold.call_burst < TH_CALL_BURST) return false;
    cold.call_burst = 0;
    opprof_bail(GATE_BURST);
    return true;
}

// The lean compiled function `callee` names, or null when the call must take
// the general entry: not a compiled function, not (yet) classified lean, a
// `with` scope to splice, no activation slot or value-stack room for the frame.
// `bottom` is the callee's register window; `plain` says the receiver is
// undefined, which only a strict or this-ignoring callee can take as is.
fn CompiledFunction* th_lean_target(Vm* vm, TVal callee, TVal* bottom, bool plain) @private @inline {
    if (!callee.is_object()) { opprof_bail(NOT_COMPILED); return null; }
    HObject* function = (HObject*)callee.get_heapptr();
    if (function == null || !function.is_callable()
        || function.callable_kind() != hobject::CallableKind.COMPILED_FN) { opprof_bail(NOT_COMPILED); return null; }
    HObjectFunction* fd = &(*function.extra_ptr()).func;
    CompiledFunction* target = fd.comp_func;
    if (target == null || !(plain ? target.call_flags.lean_plain : target.call_flags.lean_call)) {
        opprof_bail(plain && target != null && target.call_flags.lean_call ? PLAIN_THIS : NOT_LEAN_FN);
        return null;
    }
    // A function's first run goes through the switch, which creates its caches.
    if (target.realm != vm.heap.realm || target.ic_entries == null) { opprof_bail(FIRST_RUN); return null; }
    EnvRecord* cap = fd.lex_env;
    if (fd.var_env == null || (cap != null && cap.is_with())
        || vm.activation_count >= vm.activation_capacity
        || (uint)(bottom - vm.valstack) + target.num_regs
            > (uint)(vm.valstack_end - vm.valstack)) { opprof_bail(FRAME); return null; }
    return target;
}

// Push the frame of a lean call and continue in its body. The caller has
// checked th_lean_target and th_call_gate, and has stored the callee in
// register `callee_reg`; `borrowed` says the register holds a binding's value
// without a reference of its own (see ACT_FLAG_BORROWED_CALLEE). A receiver
// object stays in the caller's tracked register and the frame borrows it
// (`this_valid`), so a method call has nothing to retain or release.
fn Instruction* th_enter_lean(Instruction* pc, HandlerTable* handlers, TVal* regs,
                              ColdCtx* cold, CompiledFunction* target,
                              uint callee_reg, uint result_reg, uint nargs,
                              bool borrowed, bool clear_this,
                              TVal this_value, bool this_valid,
                              HObject* new_target = null) @private @inline {
    Vm* vm = cold.vm;
    Activation* caller = cold.act;
    HObject* function = (HObject*)regs[callee_reg].get_heapptr();
    HObjectFunction* fd = &(*function.extra_ptr()).func;
    EnvRecord* env = fd.var_env;
    EnvRecord* cap = fd.lex_env;
    uint nregs = target.num_regs;
    TVal* bottom = regs + callee_reg + 2;

    // The frame takes over the caller's `this` slot and the window above the
    // arguments, where a dead temporary the caller owns may still hold a
    // string. Release it inline; one the release would free sends the call to
    // the switch, which keeps this handler a leaf. The caller has only stored
    // the callee in its register, which the switch repeats.
    if (@unlikely(callee_reg + 1 < caller.heap_reg_count)) {
        TVal* owned_end = regs + caller.heap_reg_count;
        if (owned_end > bottom + nregs) owned_end = bottom + nregs;
        if (clear_this && !th_can_release(regs + callee_reg + 1)) return pc;
        for (TVal* p = bottom + nargs; p < owned_end; p++) {
            if (!th_can_release(p)) return pc;
        }
        if (clear_this) th_do_release(regs + callee_reg + 1);
        for (TVal* p = bottom + nargs; p < owned_end; p++) th_do_release(p);
    }
    if (clear_this) regs[callee_reg + 1].set_undefined();
    Activation* la = &vm.activations[vm.activation_count];
    la.parent = caller;
    la.func = target;
    la.var_env = env;
    la.lex_env = (cap == null || cap == env || !cap.flags.is_declarative) ? env : cap;
    la.cat = null;
    la.forin = null;
    la.async_gen_state = null;
    la.async_promise = null;
    la.new_target = new_target;
    la.curr_pc = target.code;
    la.bottom = bottom;
    la.retval = regs + result_reg;
    la.flags = 0;
    la.tv_func.set_object_borrowed(function);
    if (borrowed) {
        // A function calling itself keeps its own closure alive through the
        // caller's frame; any other callee needs the frame to root it.
        la.flags = ACT_FLAG_BORROWED_CALLEE;
        if (!caller.tv_func.is_object() || caller.tv_func.get_heapptr() != function) {
            la.flags |= ACT_FLAG_CALLEE_OWNED;
        }
    }
    la.heap_reg_count = 0;
    la.caller_valstack_top = vm.valstack_top;
    la.this_binding = this_value;
    if (this_valid) la.flags |= ACT_FLAG_THIS_VALID;
    if (new_target != null) la.flags |= ACT_FLAG_CONSTRUCT;
    vm.activation_count++;

    // Missing formals and every local start undefined; surplus arguments stay.
    // Two slots per iteration halves the loop's branches on every entry.
    TVal* fill = bottom + nargs;
    TVal* fill_end = bottom + nregs;
    for (; fill + 1 < fill_end; fill += 2) {
        fill[0].set_undefined();
        fill[1].set_undefined();
    }
    if (fill < fill_end) fill.set_undefined();

    if (target.call_flags.rest_length_only) {
        uint fixed = target.num_formals;
        bottom[fixed].set_fastint((long)(nargs > fixed ? nargs - fixed : 0));
    }

    caller.curr_pc = pc + 1;
    vm.valstack_top = bottom + nregs;
    vm.valstack_bottom = bottom;
    cold.act = la;
    *cold.regs_base_ptr = bottom;
    if (target != vm.current_func) {
        // The switch's code and cache view follows vm.current_func when the
        // burst returns (Dispatch.sync_code).
        vm.current_func = target;
        th_bind_ic_bias(cold, target.code, target.ic_entries, target.var_ic_entries);
    }
    // The object is built once the frame is published, since building it can
    // run a collection step that scans the frame.
    if (target.arguments_in_reg()) bind_register_arguments(vm, la, target, function, bottom, nargs);
    return th_next(target.code, handlers, bottom, cold);
}

// The numeric case cannot invoke user conversion; other inputs retain their
// activation so ToPrimitive observes the ordinary call and exception context.
fn bool th_trivial_call(TVal* regs, ColdCtx* cold, CompiledFunction* target,
                       uint callee_reg, uint result_reg, uint nargs) @private @inline {
    TVal* args = regs + callee_reg + 2;
    TVal value;
    switch (target.call_flags.trivial_call) {
        case 1:
            value.set_undefined();
        case 2:
            uint index = target.code[0].a;
            if (index < nargs) { value = args[index]; }
            else { value.set_undefined(); }
        case 3:
            Instruction add = target.code[0];
            if (add.b >= nargs || add.c >= nargs) return false;
            TVal left = args[add.b];
            TVal right = args[add.c];
            if (left.is_fastint() && right.is_fastint()) {
                long sum = left.get_fastint() + right.get_fastint();
                if (types::fits_fastint(sum)) { value.set_fastint(sum); }
                else { value.set_number((double)sum); }
            } else if (left.is_numeric() && right.is_numeric()) {
                double l = left.is_fastint() ? (double)left.get_fastint() : left.get_number();
                double r = right.is_fastint() ? (double)right.get_fastint() : right.get_number();
                value.set_number(l + r);
            } else { return false; }
        default:
            return false;
    }
    TVal* dest = regs + result_reg;
    if (!th_can_publish(cold.heap, value) || !th_can_release(dest)) return false;
    th_do_retain(&value);
    th_do_release(dest);
    *dest = value;
    track_heap_store(cold.act, dest, result_reg);
    return true;
}

// A method call (`CALL`) on an object receiver the caller's frame tracks, or on
// a receiver that is not a heap value and a callee that never reads its `this`.
// The receiver stays in the caller's register, which roots it for the whole
// call, so the frame borrows it as its this_binding.
fn Instruction* th_call(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    CompiledFunction* target = th_lean_target(vm, regs[insn.b], regs + insn.b + 2, false);
    if (target == null) return th_call_native(pc, handlers, regs, cold, insn.b, insn.a, insn.c);
    TVal receiver = regs[insn.b + 1];
    bool this_valid = false;
    TVal this_value = th_undefined();
    if (receiver.is_heap_allocated()) {
        if (!receiver.is_object() || receiver.get_heapptr() == null
            || insn.b + 1 >= vm.current_func.num_regs
            || cold.act.heap_reg_count <= insn.b + 1) { opprof_bail(RECEIVER); return pc; }
        if (!target.call_flags.ignores_this) {
            this_value = receiver;
            this_valid = true;
        }
    } else if (!target.call_flags.ignores_this) {
        opprof_bail(PLAIN_THIS);
        return pc;
    }
    if (th_call_gate(cold)) return pc;
    if (th_trivial_call(regs, cold, target, insn.b, insn.a, insn.c)) return th_next(pc + 1, handlers, regs, cold);
    return th_enter_lean(pc, handlers, regs, cold, target, insn.b, insn.a, insn.c, false, false,
                         this_value, this_valid);
}

fn Instruction* th_call_undef_this(Instruction* pc, HandlerTable* handlers,
                                   TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    if (th_call_gate(cold)) return pc;
    CompiledFunction* target = th_lean_target(vm, regs[insn.b], regs + insn.b + 2, true);
    if (target == null) return pc;
    if (th_trivial_call(regs, cold, target, insn.b, insn.a, insn.c)) return th_next(pc + 1, handlers, regs, cold);
    return th_enter_lean(pc, handlers, regs, cold, target, insn.b, insn.a, insn.c, false, true, th_undefined(), false);
}

// The variable IC entry for the instruction at `pc` when it still describes the
// binding it was filled for: no layout move of an object with a cached slot
// pointer since the fill (see HObject.layout_moved). The handler has checked
// the lex_env chain head with th_var_ic_moved.
// The epoch is read from the heap because a handler can move a bound object's
// storage and then fall through to the next one. Null sends the handler to the
// switch.
macro hobject::VarICEntry* th_var_ic_hit(Instruction* pc, ColdCtx* cold) @private {
    return th_ic_epoch_hit(th_ic_entry(pc, cold), cold);
}

// Whether the entry was filled under another environment chain, which the
// handler hands to th_var_rearm before th_var_ic_hit. The rearm makes calls,
// so keeping it out of the handlers leaves variable reads without a frame.
macro bool th_var_ic_moved(Instruction* pc, ColdCtx* cold) @private {
    return th_ic_entry(pc, cold).search_head != (void*)cold.act.lex_env;
}

// Rearm the entry for the current chain and run the instruction again, or
// leave it to the switch when the cached binding no longer applies.
fn Instruction* th_var_rearm(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @private @noinline {
    if (!var_ic_rearm(th_ic_entry(pc, cold), cold.act.lex_env, cold.heap)) return pc;
    return handlers.fns[pc.op.ordinal](pc, handlers, regs, cold);
}

// The same for a GETGLOBAL-family instruction. Global-scope code is compiled
// for one run and executes in a single activation, so its lex_env never
// differs from the one the entry was filled under and needs no compare.
macro hobject::VarICEntry* th_global_ic_hit(Instruction* pc, ColdCtx* cold) @private {
    return th_ic_epoch_hit(th_ic_entry(pc, cold), cold);
}

macro hobject::VarICEntry* th_ic_epoch_hit(hobject::VarICEntry* vic, ColdCtx* cold) @private {
    return (vic.recycle_epoch == cold.heap.shape_recycle_epoch && vic.slot_ptr != null) ? vic : null;
}

// Each instruction has one entry in each IC array, so an entry's address is a
// fixed multiple of the instruction's address plus a per-function bias.
const usz TH_VAR_IC_SCALE = hobject::VarICEntry::size / Instruction::size;
const usz TH_IC_SCALE = hobject::ICEntry::size / Instruction::size;

// Point the IC biases at the arrays of the function whose code starts at
// `code`. The caller has checked that both arrays exist.
macro void th_bind_ic_bias(ColdCtx* cold, Instruction* code, void* ic, void* var_ic) @private {
    cold.ic_bias = (usz)ic - (usz)code * TH_IC_SCALE;
    cold.var_ic_bias = (usz)var_ic - (usz)code * TH_VAR_IC_SCALE;
}

macro hobject::VarICEntry* th_ic_entry(Instruction* pc, ColdCtx* cold) @private {
    return (hobject::VarICEntry*)(cold.var_ic_bias + (usz)pc * TH_VAR_IC_SCALE);
}

fn Instruction* th_call_var(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    if (th_call_gate(cold)) return pc;
    if (th_var_ic_moved(pc, cold)) return th_var_rearm(pc, handlers, regs, cold);
    hobject::VarICEntry* vic = th_var_ic_hit(pc, cold);
    if (vic == null || vic.prop_flags.is_accessor) return pc;
    TVal callee = vic.slot_ptr.get();
    if (env::is_tdz_sentinel(&callee)) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    CompiledFunction* target = th_lean_target(vm, callee, regs + insn.a + 2, true);
    if (target == null) return pc;
    if (th_trivial_call(regs, cold, target, insn.a, insn.a, insn.b)) return th_next(pc + 1, handlers, regs, cold);
    // An object callee is not counted, so storing it needs no retain; a
    // binding that is not permanent can be reassigned during the call, so the
    // register is tracked and the frame roots its own reference.
    bool borrowed = is_permanent_env(vm, (EnvRecord*)vic.env);
    th_do_release(ra);
    *ra = callee;
    if (!borrowed) track_heap_store(act, ra, insn.a);
    return th_enter_lean(pc, handlers, regs, cold, target, insn.a, insn.a, insn.b, borrowed, true, th_undefined(), false);
}

fn Instruction* th_call_global(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    if (th_call_gate(cold)) return pc;
    hobject::VarICEntry* gic = th_global_ic_hit(pc, cold);
    if (gic == null) return pc;
    hobject::PropValue* pv = gic.slot_ptr;
    if (slot_is_tdz(pv)) return pc;
    TVal callee = pv.get();
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    CompiledFunction* target = th_lean_target(vm, callee, regs + insn.a + 2, true);
    if (target == null) return pc;
    if (th_trivial_call(regs, cold, target, insn.a, insn.a, insn.b)) return th_next(pc + 1, handlers, regs, cold);
    th_do_release(ra);
    *ra = callee;
    return th_enter_lean(pc, handlers, regs, cold, target, insn.a, insn.a, insn.b, true, true, th_undefined(), false);
}

// A frame that holds nothing a plain store cannot drop: no owned register, no
// owned `this`, no handler, no for-in state, and a caller to return to. Both a
// return and a tail call replace such a frame without a sweep.
macro bool th_frame_is_plain(Vm* vm, Activation* fa) @private {
    return fa.heap_reg_count == 0 && th_frame_is_replaceable(vm, fa);
}

// A frame a tail call can take over once it has released its tracked
// registers: plain apart from those.
macro bool th_frame_is_replaceable(Vm* vm, Activation* fa) @private {
    return vm.activation_count >= 2 && fa.retval != null
        && (fa.flags & ~(ACT_FLAG_BORROWED_CALLEE | ACT_FLAG_CALLEE_OWNED | ACT_FLAG_THIS_VALID)) == 0
        && fa.cat == null && fa.forin == null
        && fa.func == vm.current_func
        && !((CompiledFunction*)fa.func).maps_formals();
}

// The register half of a tail call from a frame that tracks heap registers: the
// arguments in the callee window become the new frame's own references, and
// every tracked register below the window is released, as the switch's
// takeover does. The callee register is skipped, since a function is not
// counted.
fn void th_tail_release_regs(Vm* vm, Activation* fa, TVal* regs, uint callee_reg, uint nargs) @private @noinline {
    TVal* args = regs + callee_reg + 2;
    for (uint i = 0; i < nargs; i++) {
        if (args[i].is_heap_allocated() && args[i].get_heapptr() != null) {
            ((types::HeapHeader*)args[i].get_heapptr()).incref();
        }
    }
    uint limit = callee_reg + 2;
    if (limit > fa.heap_reg_count) limit = fa.heap_reg_count;
    for (uint i = 0; i < limit; i++) {
        if (i == callee_reg) continue;
        vm.heap.decref_tval(&regs[i]);
        regs[i].set_undefined();
    }
}

// A tail call to the lean function `callee` from a plain frame: the frame is
// reused instead of pushing one, so a chain of tail calls runs in constant
// stack (ECMA-262 proper tail calls). The arguments slide down to the frame's base and the
// callee returns straight to this frame's caller. The callee must be a
// permanent binding's value (see ACT_FLAG_BORROWED_CALLEE): its register is
// overwritten by the slide, so the frame roots it itself. Every test happens
// before the first mutation; anything that fails returns `pc` for the switch.
fn Instruction* th_enter_lean_tail(Instruction* pc, HandlerTable* handlers, TVal* regs,
                                   ColdCtx* cold, CompiledFunction* target,
                                   TVal callee, uint callee_reg, uint nargs,
                                   TVal this_value, bool this_valid) @private @inline {
    Vm* vm = cold.vm;
    // The general entry builds the rest value before retaining arguments for
    // frame replacement; this entry retains its complete argument window.
    if (target.call_flags.rest_length_only || target.arguments_in_reg()) return pc;
    Activation* fa = cold.act;
    if (!th_frame_is_replaceable(vm, fa) || ((CompiledFunction*)fa.func).is_eval_fn()) return pc;
    bool tracked = fa.heap_reg_count != 0;
    HObject* function = (HObject*)callee.get_heapptr();
    HObjectFunction* fd = &(*function.extra_ptr()).func;
    EnvRecord* env = fd.var_env;
    EnvRecord* cap = fd.lex_env;
    uint nregs = target.num_regs;
    TVal* args = regs + callee_reg + 2;

    if (tracked) th_tail_release_regs(vm, fa, regs, callee_reg, nargs);
    for (uint i = 0; i < nargs; i++) regs[i] = args[i];
    fa.func = target;
    fa.var_env = env;
    fa.lex_env = (cap == null || cap == env || !cap.flags.is_declarative) ? env : cap;
    fa.async_gen_state = null;
    fa.async_promise = null;
    fa.new_target = null;
    fa.curr_pc = target.code;
    fa.flags = ACT_FLAG_BORROWED_CALLEE | ACT_FLAG_CALLEE_OWNED;
    if (this_valid) fa.flags |= ACT_FLAG_THIS_VALID;
    fa.tv_func.set_object_borrowed(function);
    fa.this_binding = this_value;
    fa.heap_reg_count = tracked ? nargs : 0;

    TVal* fill = regs + nargs;
    TVal* fill_end = regs + nregs;
    for (; fill + 1 < fill_end; fill += 2) {
        fill[0].set_undefined();
        fill[1].set_undefined();
    }
    if (fill < fill_end) fill.set_undefined();

    vm.valstack_top = regs + nregs;
    if (target != vm.current_func) {
        vm.current_func = target;
        th_bind_ic_bias(cold, target.code, target.ic_entries, target.var_ic_entries);
    }
    return th_next(target.code, handlers, regs, cold);
}

fn Instruction* th_tailcall_var(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    if (th_call_gate(cold)) return pc;
    if (th_var_ic_moved(pc, cold)) return th_var_rearm(pc, handlers, regs, cold);
    hobject::VarICEntry* vic = th_var_ic_hit(pc, cold);
    if (vic == null || vic.prop_flags.is_accessor) return pc;
    TVal callee = vic.slot_ptr.get();
    if (env::is_tdz_sentinel(&callee) || !is_permanent_env(vm, (EnvRecord*)vic.env)) return pc;
    CompiledFunction* target = th_lean_target(vm, callee, regs, true);
    if (target == null) return pc;
    return th_enter_lean_tail(pc, handlers, regs, cold, target, callee, insn.a, insn.b, th_undefined(), false);
}

fn Instruction* th_tailcall_global(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    if (th_call_gate(cold)) return pc;
    hobject::VarICEntry* gic = th_global_ic_hit(pc, cold);
    if (gic == null) return pc;
    hobject::PropValue* pv = gic.slot_ptr;
    if (slot_is_tdz(pv)) return pc;
    TVal callee = pv.get();
    CompiledFunction* target = th_lean_target(vm, callee, regs, true);
    if (target == null) return pc;
    return th_enter_lean_tail(pc, handlers, regs, cold, target, callee, insn.a, insn.b, th_undefined(), false);
}

fn Instruction* th_tailcall_undef_this(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    if (th_call_gate(cold)) return pc;
    TVal callee = regs[insn.b];
    CompiledFunction* target = th_lean_target(vm, callee, regs, true);
    if (target == null) return pc;
    return th_enter_lean_tail(pc, handlers, regs, cold, target, callee, insn.b, insn.c, th_undefined(), false);
}

// A tail method call on an object receiver, which the new frame holds as its
// borrowed `this`: the caller's register that held it goes with the frame.
fn Instruction* th_tailcall_call(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    TVal callee = regs[insn.b];
    CompiledFunction* target = th_lean_target(vm, callee, regs, false);
    // A builtin callee takes no frame to reuse: the switch makes it an
    // ordinary call whose result the return that follows hands back.
    if (target == null) return th_call_native(pc, handlers, regs, cold, insn.b, insn.a, insn.c);
    TVal receiver = regs[insn.b + 1];
    TVal this_value = th_undefined();
    bool this_valid = false;
    if (receiver.is_heap_allocated()) {
        if (!receiver.is_object() || receiver.get_heapptr() == null) return pc;
        if (!target.call_flags.ignores_this) {
            this_value = receiver;
            this_valid = true;
        }
    } else if (!target.call_flags.ignores_this) {
        return pc;
    }
    if (th_call_gate(cold)) return pc;
    return th_enter_lean_tail(pc, handlers, regs, cold, target, callee, insn.b, insn.c, this_value, this_valid);
}

fn Instruction* th_ldint(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_fastint((long)insn.get_sbc());
    pc++;
    {
        Instruction next = *pc;
        if ((next.op == Opcode.GETPROP || next.op == Opcode.GETPROP_CACHE)
            && next.c == insn.a && next.a != insn.a && next.b != insn.a) {
            // GETPROP_CACHE's key write-back is a no-op for a fastint key, so
            // both opcodes share this path.
            // Reuse the decoded immediate for the common numeric dense-array
            // hit. Heap values and every semantic edge keep GETPROP's handler.
            TVal* base = regs + next.b;
            if (base.is_object()) {
                HObject* array = (HObject*)base.get_heapptr();
                long index = (long)insn.get_sbc();
                if (array != null && !array.is_proxy()
                    && array.get_class() == hobject::ObjClass.ARRAY
                    && index >= 0 && index < (long)array.array_size
                    && index < (long)*array.array_len_ptr()) {
                    hobject::PropValue* elements = array.array_part();
                    if (elements != null) {
                        TVal value = elements[index].get();
                        if (value.is_fastint() || value.is_number()) {
                            TVal* destination = regs + next.a;
                            if (th_can_release(destination)) {
                                th_do_release(destination);
                                *destination = value;
                                return th_next(pc + 1, handlers, regs, cold);
                            }
                        }
                    }
                }
            }
        }
    }
    return th_next(pc, handlers, regs, cold);
}

fn Instruction* th_subi(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) return pc; // bigint / coercion / throw -> switch
    TVal* ra = regs + insn.a;
    long diff = rb.get_fastint() - (long)(ichar)insn.c;
    if (!types::fits_fastint(diff) || !th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_fastint(diff);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_incdec(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* value = regs + pc.a;
    if (!value.is_fastint()) return pc;
    long next = value.get_fastint() + (pc.op == Opcode.DEC ? -1L : 1L);
    if (!types::fits_fastint(next)) return pc;
    value.set_fastint(next);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_inc_lt(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* value = regs + pc.a;
    Instruction* branch = pc + 1;
    TVal* bound = regs + branch.c;
    if (!types::both_fastint(value, bound)) return th_inc_lt_number(pc, handlers, regs, cold);
    long next = value.get_fastint() + 1;
    if (!types::fits_fastint(next)) return pc;
    value.set_fastint(next);
    // A safepoint resumes at the ordinary comparison, after the increment.
    $if $feat(OP_PROFILE):
        opprof_thread_complete();
        opprof_thread_begin(branch.op, true);
    $endif
    return th_branch_if(next < bound.get_fastint(), branch, handlers, regs, cold);
}

fn Instruction* th_inc_lt_number(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @private @inline {
    TVal* value = regs + pc.a;
    Instruction* branch = pc + 1;
    TVal* bound = regs + branch.c;
    double limit, next;
    if (!th_numeric_operand(bound, &limit)) return th_incdec(pc, handlers, regs, cold);
    if (value.is_fastint()) {
        long integer = value.get_fastint() + 1;
        if (!types::fits_fastint(integer)) return pc;
        value.set_fastint(integer);
        next = (double)integer;
    } else if (value.is_number()) {
        next = value.get_number() + 1.0;
        value.set_number(next);
    } else {
        return th_incdec(pc, handlers, regs, cold);
    }
    $if $feat(OP_PROFILE):
        opprof_thread_complete();
        opprof_thread_begin(branch.op, true);
    $endif
    return th_branch_if(next < limit, branch, handlers, regs, cold);
}

// Numeric binary operators on plain numbers. Operands that need ToPrimitive,
// BigInt handling or string coercion return to the switch, which owns every
// path that can call user code or throw. Each handler releases the destination
// only after the operand checks pass, so a refusal leaves the registers intact.
macro bool th_numeric_operand(TVal* v, double* out) @private {
    if (v.is_fastint()) { *out = (double)v.get_fastint(); return true; }
    if (v.is_number()) { *out = v.get_number(); return true; }
    return false;
}

// The end of the running function's code, for the callers that scan ahead.
macro Instruction* th_code_end(ColdCtx* cold) @private {
    CompiledFunction* f = cold.vm.current_func;
    return f.code + f.code_count;
}

// The concatenations that need no coercion. Any other operand pair, and a
// result past the string length cap, leave the registers alone and go to the
// switch, which coerces or raises the RangeError.
fn Instruction* th_add_concat(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    HString* left = plain_string_of(regs + pc.b);
    HString* right = plain_string_of(regs + pc.c);
    if (left != null && right != null) {
        HString* cached = cold.heap.cached_concat_string(left, right);
        if (cached != null) {
            TVal value;
            value.set_string_borrowed(cached);
            return th_publish_read(pc, handlers, regs, cold, value);
        }
    }
    return th_add_concat_slow(pc, handlers, regs, cold);
}

// Allocation, accumulation and coercion refusals keep their call frame here.
fn Instruction* th_add_concat_slow(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @private @noinline {
    Instruction insn = *pc;
    ConcatStatus status = vm_concat_add(cold.vm, cold.act, regs + insn.a, regs + insn.b, regs + insn.c,
                                        (uint)insn.a, pc + 1, th_code_end(cold));
    if (status != ConcatStatus.DONE) return pc;
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_add_fused(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction first = pc[0];
    Instruction second = pc[1];
    TVal* left = regs + first.b;
    TVal* right = regs + first.c;
    if (!types::both_fastint(left, right)) return th_add_numeric(pc, handlers, regs, cold, true);
    long sum = left.get_fastint() + right.get_fastint();
    if (!types::fits_fastint(sum)) return pc;
    TVal* intermediate = regs + first.a;
    if (!th_can_release(intermediate)) return pc;
    th_do_release(intermediate);
    intermediate.set_fastint(sum);
    uint other = second.b == first.a ? second.c : second.b;
    if (regs[other].is_fastint()) {
        long total = sum + regs[other].get_fastint();
        TVal* result = regs + second.a;
        if (types::fits_fastint(total) && th_can_release(result)) {
            th_do_release(result);
            result.set_fastint(total);
            $if $feat(OP_PROFILE):
                opprof_thread_complete();
                opprof_record(second.op, true, true);
            $endif
            return th_next(pc + 2, handlers, regs, cold);
        }
    }
    return th_finish_add_numeric(pc, handlers, regs, cold, (double)sum);
}

// The first result is published. The second destination can hold the last
// reference to a string, so a release requiring destruction resumes there.
fn Instruction* th_finish_add_numeric(Instruction* pc, HandlerTable* handlers,
    TVal* regs, ColdCtx* cold, double sum) @private @inline {
    Instruction first = pc[0];
    Instruction second = pc[1];
    $if $feat(OP_PROFILE): opprof_thread_complete(); $endif
    uint other = second.b == first.a ? second.c : second.b;
    double value = sum;
    if (other != first.a && !th_numeric_operand(regs + other, &value)) {
        return th_next(pc + 1, handlers, regs, cold);
    }
    TVal* result = regs + second.a;
    if (!th_can_release(result)) return pc + 1;
    double total = second.b == first.a ? sum + value : value + sum;
    th_do_release(result);
    result.set_number(total);
    $if $feat(OP_PROFILE): opprof_record(second.op, true, true); $endif
    return th_next(pc + 2, handlers, regs, cold);
}

fn Instruction* th_add(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    TVal* ra = regs + insn.a;
    if (types::both_fastint(rb, rc)) {
        long sum = rb.get_fastint() + rc.get_fastint();
        if (!types::fits_fastint(sum) || !th_can_release(ra)) return pc;
        th_do_release(ra);
        ra.set_fastint(sum);
        return th_next(pc + 1, handlers, regs, cold);
    }
    return th_add_numeric(pc, handlers, regs, cold, false);
}

fn Instruction* th_add_numeric(Instruction* pc, HandlerTable* handlers,
    TVal* regs, ColdCtx* cold, bool fused) @private @inline {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    TVal* ra = regs + insn.a;
    // Object ToPrimitive and BigInt use the switch. A double operand is
    // handled here too: adding two numbers cannot call user code or throw, so
    // there is nothing for the switch's coercion machinery to guard.
    double x; double y;
    if (!th_numeric_operand(rb, &x) || !th_numeric_operand(rc, &y)) {
        return th_add_concat(pc, handlers, regs, cold);
    }
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_number(x + y);
    if (fused) return th_finish_add_numeric(pc, handlers, regs, cold, ra.get_number());
    return th_next(pc + 1, handlers, regs, cold);
}

// EQ, NEQ, SEQ and SNEQ agree on the operands decided here, so one handler
// serves all four: two fastints compare by value, any other pair of equal
// non-number bit patterns is the same value, and two distinct interned strings
// differ. Everything else, including numbers (NaN) and the coercing cases of
// the loose forms, goes to the switch.
// Strict equality where it needs no string or BigInt contents: ORDER_EQ,
// ORDER_UN for unequal, or TH_EQ_UNKNOWN. Numbers compare by value; any other
// pair of values of different types, or of the same identity-compared type
// (object, symbol, boolean, null, undefined), compares by bits. Distinct
// interned strings differ.
const uint TH_EQ_UNKNOWN = 4;

fn uint th_strict_order(TVal* b, TVal* c) @private {
    if (types::both_fastint(b, c)) return b.get_fastint() == c.get_fastint() ? ORDER_EQ : ORDER_UN;
    bool b_num = b.is_fastint() || b.is_number();
    bool c_num = c.is_fastint() || c.is_number();
    if (b_num || c_num) {
        if (b_num != c_num) return ORDER_UN;
        return tval_numeric_to_double(b) == tval_numeric_to_double(c) ? ORDER_EQ : ORDER_UN;
    }
    $if !types::USE_NANBOX:
        // A boolean occupies one byte; the rest of its union payload is unused.
        if (b.is_boolean() && c.is_boolean()) {
            return b.get_boolean() == c.get_boolean() ? ORDER_EQ : ORDER_UN;
        }
    $endif
    if (b.same_bits(c)) return ORDER_EQ;
    if (b.is_string() && c.is_string()) {
        return ((HString*)b.get_heapptr()).flags.is_interned && ((HString*)c.get_heapptr()).flags.is_interned
            ? ORDER_UN : TH_EQ_UNKNOWN;
    }
    if (b.is_bigint() && c.is_bigint()) return TH_EQ_UNKNOWN;
    return ORDER_UN;
}

// Loose equality agrees with strict equality on operands of one type, and
// null and undefined equal each other and nothing else, except the realm's
// [[IsHTMLDDA]] object (ES2024 B.3.6). Other mixed pairs coerce and go to the
// switch.
fn uint th_loose_order(TVal* b, TVal* c, heap::Heap* heap) @private {
    if (b.is_nullish() || c.is_nullish()) {
        if (b.is_nullish() && c.is_nullish()) return ORDER_EQ;
        TVal* other = b.is_nullish() ? c : b;
        return other.is_object() && other.get_heapptr() == (void*)heap.htmldda_obj ? ORDER_EQ : ORDER_UN;
    }
    if (b.get_tag() != c.get_tag() && !((b.is_fastint() || b.is_number()) && (c.is_fastint() || c.is_number()))) {
        return TH_EQ_UNKNOWN;
    }
    return th_strict_order(b, c);
}

fn Instruction* th_eq(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    TVal* ra = regs + insn.a;
    bool strict = insn.op == Opcode.SEQ || insn.op == Opcode.SNEQ;
    uint order = strict ? th_strict_order(rb, rc) : th_loose_order(rb, rc, cold.heap);
    if (order == TH_EQ_UNKNOWN || !th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_boolean((order == ORDER_EQ) != (insn.op == Opcode.NEQ || insn.op == Opcode.SNEQ));
    return th_next(pc + 1, handlers, regs, cold);
}

// LT, LE, GT and GE on two numbers. Anything else may coerce through user
// code, and goes to the switch.
fn Instruction* th_relational(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    TVal* ra = regs + insn.a;
    uint order;
    if (types::both_fastint(rb, rc)) {
        order = th_order_int(rb.get_fastint(), rc.get_fastint());
    } else {
        double x; double y;
        if (!th_numeric_operand(rb, &x) || !th_numeric_operand(rc, &y)) return pc;
        order = th_order_num(x, y);
    }
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    // LT..GE take the same rows as JMP_LT..JMP_GE.
    ra.set_boolean(((CMP_BRANCH_ON[insn.op.ordinal - Opcode.LT.ordinal + 4] >> order) & 1) != 0);
    return th_next(pc + 1, handlers, regs, cold);
}

// `v instanceof F` for an ordinary function F that inherits the intrinsic
// @@hasInstance: OrdinaryHasInstance, with both lookups answered by the
// megamorphic cache. Anything else, or a cache miss, takes the switch.
// `v instanceof F` for a plain function F. A primitive `v` is answered without
// reading F.prototype (OrdinaryHasInstance step 3).
fn Instruction* th_instanceof(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* rb = regs + pc.b;
    TVal* rc = regs + pc.c;
    if (!rc.is_object()) return pc;
    heap::Heap* h = cold.heap;
    HObject* rfunc = (HObject*)rc.get_heapptr();
    if (!hobject::uses_default_has_instance(h, rfunc)) return pc;
    if (!rb.is_object()) {
        TVal* ra = regs + pc.a;
        if (!th_can_release(ra)) return pc;
        th_do_release(ra);
        ra.set_boolean(false);
        return th_next(pc + 1, handlers, regs, cold);
    }
    hobject::MegamorphicEntry* me;
    hobject::PropValue* slot = hobject::mega_cache_lookup(h, rfunc, (void*)h.strs[heap::BuiltinStr.PROTOTYPE], &me);
    if (slot == null || me.is_accessor) return pc;
    TVal proto = slot.get();
    if (!proto.is_object()) return pc;
    HObject* probe = (HObject*)proto.get_heapptr();
    bool found = false;
    HObject* cur = (HObject*)rb.get_heapptr();
    for (uint depth = 0; depth < hobject::MAX_PROTO_DEPTH; depth++) {
        if (cur.is_proxy()) return pc;
        cur = cur.prototype;
        if (cur == null) break;
        if (cur == probe) { found = true; break; }
    }
    TVal* ra = regs + pc.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_boolean(found);
    return th_next(pc + 1, handlers, regs, cold);
}

// DECLVAR and DECLVAR_HOIST into a fresh function scope, which every call
// declares on the same shapes: the site's cache names the shape the scope is
// on before the key is added and the one the append moves it to.
fn Instruction* th_declvar(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Vm* vm = cold.vm;
    CompiledFunction* f = vm.current_func;
    EnvRecord* env = cold.act.var_env;
    if (f.ic_entries == null || env == null || !env.flags.is_function_scope || env.flags.is_with
        || f.is_eval_fn()) return pc;
    uint bc = pc.get_bc();
    if (bc >= f.const_count || !f.constants[bc].is_string()) return pc;
    void* key = f.constants[bc].get_heapptr();
    HObject* b = env.bindings;
    hobject::ICEntry* ic = th_ic_at(cold, pc);
    if (ic.prop_idx != hobject::IC_PROP_ABSENT || ic.prop_flags != hobject::PROP_FLAGS_WE
        || ic.key.borrow() != key || ic.shape_id != b.shape_id
        || ic.shape_gen != cold.heap.shape_recycle_epoch || b.prop_hash != null) return pc;
    TVal* value = regs + pc.a;
    // A var binding is not configurable, which get_prop_flags reads from the
    // shape only once the object is marked as holding such a property.
    if (value.is_heap_allocated()) {
        if (!b.append_cached_prop(ic, *value, cold.heap)) return pc;
        b.flags.has_nondefault_flags = true;
        return th_next(pc + 1, handlers, regs, cold);
    }
    if (b.prop_count >= b.prop_capacity) return pc;
    if (b.gc.prototype_observed) cold.heap.bump_prototype_epoch();
    b.flags.has_nondefault_flags = true;
    hobject::PropValue* slot = &b.prop_values()[b.prop_count];
    *slot = (hobject::PropValue)*value;
    b.prop_count++;
    b.shape_id = ic.absent_next_shape;
    return th_next(pc + 1, handlers, regs, cold);
}

// The typeof names are builtin strings, stored as th_ldconst stores a string
// constant.
fn Instruction* th_typeof(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal value;
    value.set_string_borrowed(typeof_string(cold.vm, regs + pc.b));
    TVal* ra = regs + pc.a;
    if (!th_can_publish(cold.heap, value) || !th_can_release(ra)) return pc;
    th_do_retain(&value);
    th_do_release(ra);
    *ra = value;
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_lnot(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* ra = regs + pc.a;
    bool value = !is_truthy(regs + pc.b, cold.heap);
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_boolean(value);
    return th_next(pc + 1, handlers, regs, cold);
}

// Negation of a number. A fastint zero negates to -0, which is not a fastint.
fn Instruction* th_unm(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* rb = regs + pc.b;
    TVal* ra = regs + pc.a;
    double x;
    if (!th_numeric_operand(rb, &x) || !th_can_release(ra)) return pc;
    long n = rb.is_fastint() ? rb.get_fastint() : 0;
    th_do_release(ra);
    if (n != 0 && types::fits_fastint(-n)) {
        ra.set_fastint(-n);
    } else {
        ra.set_number(-x);
    }
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_sub(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    TVal* ra = regs + insn.a;
    if (types::both_fastint(rb, rc)) {
        long diff = rb.get_fastint() - rc.get_fastint();
        if (!types::fits_fastint(diff) || !th_can_release(ra)) return pc;
        th_do_release(ra);
        ra.set_fastint(diff);
        return th_next(pc + 1, handlers, regs, cold);
    }
    double x; double y;
    if (!th_numeric_operand(rb, &x) || !th_numeric_operand(rc, &y)) return pc;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_number(x - y);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_mul(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    TVal* ra = regs + insn.a;
    if (types::both_fastint(rb, rc)) {
        long x = rb.get_fastint();
        long y = rc.get_fastint();
        // Operands within 31 bits keep the product inside a signed 64-bit long.
        if (x < -0x40000000L || x > 0x3FFFFFFFL || y < -0x40000000L || y > 0x3FFFFFFFL) return pc;
        long product = x * y;
        // A zero product of opposite-signed operands is -0, which no fastint holds.
        if ((product == 0 && (x ^ y) < 0) || !types::fits_fastint(product)) return pc;
        if (!th_can_release(ra)) return pc;
        th_do_release(ra);
        ra.set_fastint(product);
        return th_next(pc + 1, handlers, regs, cold);
    }
    double x; double y;
    if (!th_numeric_operand(rb, &x) || !th_numeric_operand(rc, &y)) return pc;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_number(x * y);
    return th_next(pc + 1, handlers, regs, cold);
}

// The quotient is always a double, matching the switch, so there is no
// fastint path to take.
fn Instruction* th_div(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* ra = regs + insn.a;
    double x; double y;
    if (!th_numeric_operand(regs + insn.b, &x) || !th_numeric_operand(regs + insn.c, &y)) return pc;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_number(x / y);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_muli(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* ra = regs + insn.a;
    if (!rb.is_fastint()) return pc;
    long x = rb.get_fastint();
    long y = (long)(ichar)insn.c;
    // Operands within 31 bits keep the product inside a signed 64-bit long.
    if (x < -0x40000000L || x > 0x3FFFFFFFL) return pc;
    long product = x * y;
    // A zero product of opposite-signed operands is -0, which no fastint holds.
    if ((product == 0 && (x ^ y) < 0) || !types::fits_fastint(product)) return pc;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_fastint(product);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_mod(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    TVal* ra = regs + insn.a;
    if (!types::both_fastint(rb, rc)) return pc;
    long x = rb.get_fastint();
    long y = rc.get_fastint();
    // A negative dividend can yield -0 and a zero divisor yields NaN.
    if (x < 0 || y <= 0) return pc;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_fastint(x % y);
    return th_next(pc + 1, handlers, regs, cold);
}

// Bitwise operators on fastint operands. ToInt32 of an integer is its low 32
// bits, which the (int) cast takes directly.
macro Instruction* th_bitop($op, $imm, Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @private {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* ra = regs + insn.a;
    int y;
    $if $imm:
        if (!rb.is_fastint()) return pc;
        y = (int)(insn.c & 0xFF);
    $else
        TVal* rc = regs + insn.c;
        if (!types::both_fastint(rb, rc)) return pc;
        y = (int)rc.get_fastint();
    $endif
    if (!th_can_release(ra)) return pc;
    int x = (int)rb.get_fastint();
    long result;
    $switch $op:
        $case Opcode.BAND: result = (long)(x & y);
        $case Opcode.BOR:  result = (long)(x | y);
        $case Opcode.BXOR: result = (long)(x ^ y);
        $case Opcode.SHL:  result = (long)(x << (y & 0x1F));
        $case Opcode.SHR:  result = (long)(x >> (y & 0x1F));
        $default:          result = (long)((uint)x >> (y & 0x1F));
    $endswitch
    th_do_release(ra);
    ra.set_fastint(result);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_band(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BAND, false, pc, handlers, regs, cold);
}
fn Instruction* th_bandi(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BAND, true, pc, handlers, regs, cold);
}
fn Instruction* th_bor(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BOR, false, pc, handlers, regs, cold);
}
fn Instruction* th_bori(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BOR, true, pc, handlers, regs, cold);
}
fn Instruction* th_bxor(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BXOR, false, pc, handlers, regs, cold);
}
fn Instruction* th_bxori(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BXOR, true, pc, handlers, regs, cold);
}
fn Instruction* th_shl(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.SHL, false, pc, handlers, regs, cold);
}
fn Instruction* th_shli(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.SHL, true, pc, handlers, regs, cold);
}
fn Instruction* th_shr(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.SHR, false, pc, handlers, regs, cold);
}
fn Instruction* th_shri(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.SHR, true, pc, handlers, regs, cold);
}
fn Instruction* th_ushr(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.USHR, false, pc, handlers, regs, cold);
}
fn Instruction* th_ushri(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.USHR, true, pc, handlers, regs, cold);
}

// A constant copies like the switch's counted copy.
fn Instruction* th_ldconst(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    CompiledFunction* f = cold.vm.current_func;
    uint bc = insn.get_bc();
    // The compiler only emits operands inside the constant table, and the safe
    // builds keep this check.
    assert(bc < f.const_count);
    TVal value = f.constants[bc];
    if (!th_can_publish(cold.heap, value)) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    th_do_retain(&value);
    th_do_release(ra);
    *ra = value;
    if (value.is_heap_allocated()) track_heap_store(cold.act, ra, (uint)insn.a);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_ldundef(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* ra = regs + pc.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_undefined();
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_ldnull(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* ra = regs + pc.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_null();
    return th_next(pc + 1, handlers, regs, cold);
}

// LDTRUE and LDFALSE share a handler: the opcode is the value.
fn Instruction* th_ldbool(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* ra = regs + pc.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_boolean(pc.op == Opcode.LDTRUE);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_class_scalar_guard(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* result = regs + pc.a + 1;
    if (!th_can_release(result)) return pc;
    hobject::ICEntry* ic = cold.vm.current_func.ic_entries != null ? th_ic_at(cold, pc) : null;
    bool matches = scalar_class_matches(cold.vm, regs + pc.a, pc.b, pc.c, ic);
    th_do_release(result);
    result.set_boolean(matches);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_if(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    if (is_truthy(regs + pc.a, cold.heap) == (pc.op == Opcode.IF_TRUE)) {
        int off = pc.get_sbc();
        if (off < 0 && th_bwd_edge_bails(cold)) return pc;
        return th_next(pc + 1 + off, handlers, regs, cold);
    }
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_jump(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    // Unconditional relative jump (sABC). No try-finally interception (that is
    // BREAK/CONTINUE, not JUMP). Backward jumps charge the GC safepoint budget.
    int off = insn.get_sabc();
    if (off < 0) {
        if (th_bwd_edge_bails(cold)) return pc;
    }
    pc += (sz)(1 + off);
    return th_next(pc, handlers, regs, cold);
}

// Take or skip a fused compare-and-branch. A backward branch charges the GC
// safepoint budget and bails when it is due.
macro Instruction* th_branch_if(bool take, Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @private {
    if (take) {
        if ((ichar)pc.a < 0) {
            if (th_bwd_edge_bails(cold)) return pc;
        }
        pc += (sz)(1 + (int)(ichar)pc.a);
    } else {
        pc++;
    }
    return th_next(pc, handlers, regs, cold);
}

// How a fused compare-and-branch reads its comparison: the operands order as
// less, equal, greater or unordered (a NaN operand), and each opcode, indexed
// from JMP_NLT or JMP_NLTI, branches on a set of those outcomes. The negated
// forms (JMP_N*) branch when the relation does not hold, so unordered takes
// the branch for them and never for the others. Strict equality uses the
// same ordering on numbers: -0 equals +0 and NaN equals nothing.
const uint ORDER_LT = 0;
const uint ORDER_EQ = 1;
const uint ORDER_GT = 2;
const uint ORDER_UN = 3;
const char[10] CMP_BRANCH_ON = {
    [0] = 0b1110,   // JMP_NLT
    [1] = 0b1100,   // JMP_NLE
    [2] = 0b1011,   // JMP_NGT
    [3] = 0b1001,   // JMP_NGE
    [4] = 0b0001,   // JMP_LT
    [5] = 0b0011,   // JMP_LE
    [6] = 0b0100,   // JMP_GT
    [7] = 0b0110,   // JMP_GE
    [8] = 0b0010,   // JMP_SEQ
    [9] = 0b1101,   // JMP_SNEQ
};

// Integers order without a branch: a switch's case values vary, so a branchy
// ordering would mispredict on them.
macro uint th_order_int(long x, long y) @private => ORDER_EQ + (uint)(x > y) - (uint)(x < y);
macro uint th_order_num(double x, double y) @private => x < y ? ORDER_LT : (x == y ? ORDER_EQ : (x > y ? ORDER_GT : ORDER_UN));

// The fused compare-and-branch family, register and immediate forms. Threads
// the fastint / number fast path only; anything requiring ToPrimitive /
// relational coercion (may call user code or throw) or comparing non-numbers
// bails to the switch. A backward branch charges the GC safepoint budget and
// bails when it is due.
macro Instruction* th_cmp_branch_impl($imm, Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @private {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    uint order;
    $if $imm:
        long lc = (long)(ichar)insn.c;
        if (rb.is_fastint()) {
            order = th_order_int(rb.get_fastint(), lc);
        } else if (rb.is_number()) {
            order = th_order_num(tval_numeric_to_double(rb), (double)lc);
        } else {
            return pc;
        }
        uint first = Opcode.JMP_NLTI.ordinal;
    $else
        TVal* rc = regs + insn.c;
        if (types::both_fastint(rb, rc)) {
            order = th_order_int(rb.get_fastint(), rc.get_fastint());
        } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
            order = th_order_num(tval_numeric_to_double(rb), tval_numeric_to_double(rc));
        } else if (insn.op != Opcode.JMP_SEQ && insn.op != Opcode.JMP_SNEQ) {
            return pc;
        } else {
            // Strict equality has no order, so unequal values report
            // unordered, which only JMP_SNEQ branches on.
            order = th_strict_order(rb, rc);
            if (order == TH_EQ_UNKNOWN) return pc;
        }
        uint first = Opcode.JMP_NLT.ordinal;
    $endif
    if (((CMP_BRANCH_ON[insn.op.ordinal - first] >> order) & 1) != 0) {
        if ((ichar)insn.a < 0) {
            if (th_bwd_edge_bails(cold)) return pc;
        }
        pc += (sz)(1 + (int)(ichar)insn.a);
    } else {
        pc++;
    }
    return th_next(pc, handlers, regs, cold);
}

fn Instruction* th_cmp_branch(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_cmp_branch_impl(false, pc, handlers, regs, cold);
}
fn Instruction* th_cmp_branch_i(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_cmp_branch_impl(true, pc, handlers, regs, cold);
}

// Negating the complementary ordered relation handles NaN without computing
// an order code. The same expression folds to one comparison for integers.
macro bool th_cmp_take($on, x, y) @private {
    const uint ORDERED = ($on & 0b1000) != 0 ? $on ^ 0b1111 : $on;
    bool take = ((ORDERED & 0b0001) != 0 && x < y)
             || ((ORDERED & 0b0010) != 0 && x == y)
             || ((ORDERED & 0b0100) != 0 && x > y);
    return ($on & 0b1000) != 0 ? !take : take;
}

// Each handler knows its relation. Numeric operands therefore branch directly
// instead of computing an order and looking up the opcode's outcome mask.
macro Instruction* th_cmp_fast($imm, $on, Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @private {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    $if !$imm:
        TVal* rc = regs + insn.c;
    $endif
    if (rb.is_fastint()) {
        long x = rb.get_fastint();
        $if $imm:
            long y = (long)(ichar)insn.c;
            return th_branch_if(th_cmp_take($on, x, y), pc, handlers, regs, cold);
        $else
            if (rc.is_fastint()) {
                long y = rc.get_fastint();
                return th_branch_if(th_cmp_take($on, x, y), pc, handlers, regs, cold);
            }
        $endif
    }
    $if $imm:
        if (rb.is_number()) {
            return th_branch_if(th_cmp_take($on, rb.get_number(), (double)(ichar)insn.c), pc, handlers, regs, cold);
        }
    $else
        if (rb.is_number() && rc.is_number()) {
            return th_branch_if(th_cmp_take($on, rb.get_number(), rc.get_number()), pc, handlers, regs, cold);
        }
    $endif
    if (!rb.is_numeric()) return pc;
    double x = tval_numeric_to_double(rb);
    $if $imm:
        double y = (double)(ichar)insn.c;
    $else
        if (!rc.is_numeric()) return pc;
        double y = tval_numeric_to_double(rc);
    $endif
    return th_branch_if(th_cmp_take($on, x, y), pc, handlers, regs, cold);
}

fn Instruction* th_jmp_lt(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b0001, pc, handlers, regs, cold);
fn Instruction* th_jmp_le(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b0011, pc, handlers, regs, cold);
fn Instruction* th_jmp_gt(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b0100, pc, handlers, regs, cold);
fn Instruction* th_jmp_ge(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b0110, pc, handlers, regs, cold);
fn Instruction* th_jmp_nlt(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b1110, pc, handlers, regs, cold);
fn Instruction* th_jmp_nle(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b1100, pc, handlers, regs, cold);
fn Instruction* th_jmp_ngt(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b1011, pc, handlers, regs, cold);
fn Instruction* th_jmp_nge(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b1001, pc, handlers, regs, cold);
fn Instruction* th_jmp_lti(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b0001, pc, handlers, regs, cold);
fn Instruction* th_jmp_lei(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b0011, pc, handlers, regs, cold);
fn Instruction* th_jmp_gti(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b0100, pc, handlers, regs, cold);
fn Instruction* th_jmp_gei(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b0110, pc, handlers, regs, cold);
fn Instruction* th_jmp_nlti(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b1110, pc, handlers, regs, cold);
fn Instruction* th_jmp_nlei(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b1100, pc, handlers, regs, cold);
fn Instruction* th_jmp_ngti(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b1011, pc, handlers, regs, cold);
fn Instruction* th_jmp_ngei(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b1001, pc, handlers, regs, cold);

// Loose-equality branches decide the operand pairs EQ's handler decides and
// leave the coercing ones to the switch.
fn Instruction* th_jmp_eq(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    uint order = th_loose_order(regs + pc.b, regs + pc.c, cold.heap);
    if (order == TH_EQ_UNKNOWN) return pc;
    return th_branch_if((order == ORDER_EQ) == (pc.op == Opcode.JMP_EQ), pc, handlers, regs, cold);
}

// Comparison with null or undefined: C repeats B.
fn Instruction* th_jmp_null(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* rb = regs + pc.b;
    bool nullish = rb.is_nullish() || (rb.is_object() && rb.get_heapptr() == (void*)cold.heap.htmldda_obj);
    return th_branch_if(nullish == (pc.op == Opcode.JMP_NULL), pc, handlers, regs, cold);
}

// --- Global-slot access (perf-all VarRef fast path). ---
//
// pc points at the current instruction, so the IC slot is pc - code_base.
// A hit validates the binding object and shape before reading its slot.

fn Instruction* th_getglobal(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    hobject::VarICEntry* gic = th_global_ic_hit(pc, cold);
    if (gic == null) return pc;
    TVal* ra = regs + insn.a;
    TVal value = gic.slot_ptr.get();
    // A number is never the TDZ marker, so the common case skips that test. An
    // inert value needs neither a mark publication nor a string retain, and a
    // register that holds anything but a string has no count to release.
    if (value.is_numeric() && !ra.is_refcounted()) {
        *ra = value;
        return th_next(pc + 1, handlers, regs, cold);
    }
    if (env::is_tdz_sentinel(&value)) return pc; // TDZ -> switch throws
    if (value.is_inert() && !ra.is_refcounted()) {
        *ra = value;
        return th_next(pc + 1, handlers, regs, cold);
    }
    if (!th_can_publish(cold.heap, value)) return pc;
    // Traced objects have no refcount; only the register's heap-root span changes.
    if (value.is_object() && !ra.is_refcounted()) {
        *ra = value;
        track_heap_store(cold.act, ra, (uint)insn.a);
        return th_next(pc + 1, handlers, regs, cold);
    }
    if (!value.is_heap_allocated() && !ra.is_heap_allocated()) {
        // An ENVREF is traced but has no refcount or heap-register bit.
        if (!th_can_release(ra)) return pc;
        th_do_release(ra);
        *ra = value;
    } else {
        // Retain and release inline so an object-valued global keeps this
        // handler on the same path as primitive globals.
        if (!th_can_release(ra)) return pc;
        th_do_retain(&value);
        th_do_release(ra);
        *ra = value;
        track_heap_store(cold.act, ra, (uint)insn.a);
    }
    pc++;
    return th_next(pc, handlers, regs, cold);
}

fn Instruction* th_putglobal(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    hobject::VarICEntry* gic = th_global_ic_hit(pc, cold);
    // Only writable non-configurable data globals (varref_store_ok) may take
    // the re-check-free store path -- exactly the switch's fast-path gate.
    if (gic == null || !gic.varref_store_ok) return pc;
    TVal* ra = regs + insn.a;
    hobject::PropValue* slot = gic.slot_ptr;
    // Only a traced source needs a barrier, and only a string needs release.
    if (ra.is_traced() || slot.get().is_refcounted()) {
        return th_putglobal_move(pc, handlers, regs, cold, (HObject*)gic.bindings, slot);
    }
    *slot = (hobject::PropValue)*ra;
    ra.set_undefined();
    return th_next(pc + 1, handlers, regs, cold);
}

// The barrier and release path of a global store, out of line so the
// handler's hit path stays a leaf with no frame.
fn Instruction* th_putglobal_move(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                                  HObject* owner, hobject::PropValue* slot) @noinline {
    cold.heap.tval_move_slot_fast(owner, slot, regs + pc.a);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_inc_global_impl(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold, bool is_inc) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    hobject::VarICEntry* gic = th_global_ic_hit(pc, cold);
    if (gic == null || !gic.varref_store_ok) return pc;
    hobject::PropValue* slot = gic.slot_ptr;
    TVal old_val = slot.get();
    // Threaded fast path: fastint only. number/bigint/TDZ -> switch.
    if (!old_val.is_fastint()) return pc;
    long v = old_val.get_fastint() + (is_inc ? 1L : -1L);
    // Leaving the fastint range makes a double, which the switch stores.
    if (v < types::FASTINT_MIN || v > types::FASTINT_MAX) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    slot.set_fastint(v);
    ra.set_fastint(v);
    pc++;
    // A counted loop's condition reloads the counter this instruction just
    // left in `ra`: `for (...; i++) ` ends in INC_GLOBAL then GETGLOBAL of the
    // same name into the same register. The reload is redundant on this path;
    // the loop's entry jump lands on the GETGLOBAL itself and still runs it.
    if (pc.op == Opcode.GETGLOBAL && pc.a == insn.a && pc.get_bc() == insn.get_bc()) {
        $if $feat(OP_PROFILE):
            opprof_thread_complete();
            opprof_record(pc.op, true, true);
        $endif
        pc++;
    }
    return th_next(pc, handlers, regs, cold);
}

fn Instruction* th_inc_global(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_inc_global_impl(pc, handlers, regs, cold, true);
}

fn Instruction* th_dec_global(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    return th_inc_global_impl(pc, handlers, regs, cold, false);
}

// --- Variable access: VarIC (shape and recycle-epoch) hit path only. ---

fn Instruction* th_getcap(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    hobject::PropValue* slot = capture_read_slot(cold.act, pc.get_bc());
    if (slot == null) return pc;
    TVal value = slot.get();
    TVal* dst = regs + pc.a;
    if (!th_can_publish(cold.heap, value)
        || !th_can_release(dst)) return pc;
    th_do_retain(&value);
    th_do_release(dst);
    *dst = value;
    track_heap_store(cold.act, dst, (uint)pc.a);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_putcap(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    uint capture_index = pc.op == Opcode.PUTCAP_SNAP ? pc.c : pc.get_bc();
    HObject* owner;
    hobject::PropValue* slot = capture_value_slot(cold.act, capture_index, cold.heap, true, &owner);
    if (slot == null || !th_can_release_slot(slot)) return pc;
    TVal* src = regs + pc.a;
    th_do_release_slot(slot);
    cold.heap.store_slot(owner, slot, *src);
    src.set_undefined();
    return th_next(pc + 1, handlers, regs, cold);
}

// The value slot a cell instruction names, and in `owner` the cells object
// that holds it, which a store needs for the write barrier.
fn hobject::PropValue* th_cell_slot(Instruction* pc, TVal* regs, HObject** owner) @private @inline {
    TVal* owner_val = regs + pc.b;
    if (!owner_val.is_object()) return null;
    HObject* cells = (HObject*)owner_val.get_heapptr();
    uint slot_idx = (uint)pc.c;
    if (cells == null || cells.get_class() != hobject::ObjClass.OBJECT
        || slot_idx >= cells.prop_count) return null;
    *owner = cells;
    return &cells.prop_values()[slot_idx];
}

fn Instruction* th_getcell(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    HObject* owner;
    hobject::PropValue* slot = th_cell_slot(pc, regs, &owner);
    if (slot == null) return pc;
    TVal value = slot.get();
    TVal* dst = regs + pc.a;
    if (!th_can_publish(cold.heap, value)
        || !th_can_release(dst)) return pc;
    th_do_retain(&value);
    th_do_release(dst);
    *dst = value;
    track_heap_store(cold.act, dst, (uint)pc.a);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_setcell(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    HObject* owner;
    hobject::PropValue* slot = th_cell_slot(pc, regs, &owner);
    TVal* src = regs + pc.a;
    if (slot == null || !th_can_release_slot(slot)) return pc;
    th_do_retain(src);
    th_do_release_slot(slot);
    cold.heap.store_slot(owner, slot, *src);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_movecell(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    HObject* owner;
    hobject::PropValue* slot = th_cell_slot(pc, regs, &owner);
    TVal* src = regs + pc.a;
    if (slot == null || !th_can_release_slot(slot)) return pc;
    th_do_release_slot(slot);
    cold.heap.store_slot(owner, slot, *src);
    src.set_undefined();
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_getvar(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    if (th_var_ic_moved(pc, cold)) return th_var_rearm(pc, handlers, regs, cold);
    hobject::VarICEntry* vic = th_var_ic_hit(pc, cold);
    if (vic == null || vic.prop_flags.is_accessor) return pc; // getter -> switch
    TVal v = vic.slot_ptr.get();
    if (env::is_tdz_sentinel(&v)) return pc; // TDZ error -> switch
    TVal* ra = regs + insn.a;
    // Keep this handler a LEAF. Calling out to Heap.decref makes LLVM frame the
    // whole function: five stp/ldp pairs saving ten callee-saved registers,
    // paid on EVERY variable read.
    //
    // The refcount work is done inline instead of bailing, so heap-valued
    // captures keep the fast path too: an incref is an increment, and a decref
    // is an increment plus a zero test whose free path (the only part needing
    // the call) is rare. Anything that would reach that path, or a pinned or
    // mid-sweep header where decref has extra rules, hands off to the switch.
    // Both sides are tested before either is mutated: bailing out after a
    // completed retain would leak the reference it took.
    if (!th_can_publish(cold.heap, v)
        || !th_can_release(ra)) return pc;
    th_do_retain(&v);
    th_do_release(ra);
    *ra = v;
    track_heap_store(act, ra, (uint)insn.a);
    pc++;
    return th_next(pc, handlers, regs, cold);
}

fn Instruction* th_putvar_assign(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    if (th_var_ic_moved(pc, cold)) return th_var_rearm(pc, handlers, regs, cold);
    hobject::VarICEntry* vic = th_var_ic_hit(pc, cold);
    if (vic == null) return pc;
    hobject::PropValue* pv = vic.slot_ptr;
    hobject::PropFlags fl = vic.prop_flags;
    if (slot_is_tdz(pv) || !fl.writable || fl.is_accessor) return pc;
    TVal* ra = regs + insn.a;
    // Inline release, as in th_getvar: keeps the handler leaf without pushing
    // heap-valued bindings onto the switch.
    if (!th_can_release_slot(pv)) return pc;
    th_do_release_slot(pv);
    vm.heap.store_slot((HObject*)vic.bindings, pv, *ra);
    ra.set_undefined();
    pc++;
    return th_next(pc, handlers, regs, cold);
}

// The store half of a plain assignment, into the binding RESOLVEVAR found
// before the right-hand side ran. The switch caches a writable data binding
// of that owner at this site; the value moves from the register into it.
fn Instruction* th_putvar_snap(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* value = regs + insn.a;
    TVal* probe = regs + insn.b;
    if (!probe.is_envref()) return pc;
    env::EnvRecord* owner = (env::EnvRecord*)probe.get_heapptr();
    if (owner == null || owner.is_with()) return pc;
    hobject::VarICEntry* vic = th_ic_entry(pc, cold);
    // The captured owner, rather than the current scope head, identifies the
    // binding even when evaluation of the RHS changes name resolution.
    if (vic.env != (void*)owner || vic.bindings != (void*)owner.bindings) return pc;
    HObject* bindings = owner.bindings;
    if (bindings.shape_id != vic.shape_id
        || cold.heap.shape_recycle_epoch != vic.recycle_epoch) return pc;
    hobject::PropFlags flags = vic.prop_flags;
    if (!flags.writable || flags.is_accessor) return pc;
    hobject::PropValue* slot = &bindings.prop_values()[vic.prop_idx];
    if (slot_is_tdz(slot) || !th_can_release_slot(slot)) return pc;
    th_do_release_slot(slot);
    cold.heap.store_slot(bindings, slot, *value);
    value.set_undefined();
    return th_next(pc + 1, handlers, regs, cold);
}

// Resolve an assignment target through the site's cache, which holds the
// owning record while the scope head and its shape are unchanged.
fn Instruction* th_resolvevar(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    hobject::VarICEntry* vic = th_ic_entry(pc, cold);
    if (vic.env == null || vic.search_head != (void*)cold.act.lex_env
        || ((HObject*)vic.bindings).shape_id != vic.shape_id
        || cold.heap.shape_recycle_epoch != vic.recycle_epoch) return pc;
    TVal ref;
    ref.set_envref(vic.env);
    TVal* ra = regs + pc.a;
    if (!th_can_publish(cold.heap, ref) || !th_can_release(ra)) return pc;
    th_do_release(ra);
    *ra = ref;
    track_heap_store(cold.act, ra, (uint)pc.a);
    return th_next(pc + 1, handlers, regs, cold);
}

// A resolved reference needs nothing; an unresolvable one is the switch's.
fn Instruction* th_throw_unresolved(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* ra = regs + pc.a;
    if (!ra.is_envref() || ra.get_heapptr() == null) return pc;
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_inc_var(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    if (th_var_ic_moved(pc, cold)) return th_var_rearm(pc, handlers, regs, cold);
    hobject::VarICEntry* vic = th_var_ic_hit(pc, cold);
    if (vic == null) return pc;
    hobject::PropValue* slot = vic.slot_ptr;
    TVal old_val = slot.get();
    if (!old_val.is_fastint() || !vic.prop_flags.writable) return pc;
    long next = old_val.get_fastint() + 1L;
    TVal* ra = regs + insn.a;
    if (!types::fits_fastint(next) || !th_can_release(ra)) return pc;
    th_do_release(ra);
    slot.set_fastint(next);
    ra.set_fastint(next);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_tonumeric(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_fastint(rb.get_fastint());
    pc++;
    return th_next(pc, handlers, regs, cold);
}

// --- Property access: monomorphic inline-cache hit path only. ---
//
// A property op is a call into dispatch_property, whose prologue and sub-switch
// cost more than the cached load or store itself. These handlers serve only the
// IC hit, so the exotic receivers, accessors, prototype walks and shape
// transitions all stay behind one bail to the switch, which re-decodes the
// instruction and runs the full handler.

// The ICEntry for the instruction at `pc`, or null when the function carries
// no IC array.
macro hobject::ICEntry* th_ic_at(ColdCtx* cold, Instruction* pc) {
    return (hobject::ICEntry*)(cold.ic_bias + (usz)pc * TH_IC_SCALE);
}

// A read under a computed string key from a plain object whose only prototype
// is Object.prototype, the shape of `counts[word]` and `seen[key]`. A site that
// has not cached a key yet, or whose cached key meets a changed shape, bails so
// the switch can refill the cache for a monomorphic key; any other key reads by
// lookup, which the cache would only churn. Accessors, a longer chain and a key
// Object.prototype holds bail to the switch.
fn Instruction* th_get_computed(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                                HObject* hobj, HString* key) @private @noinline {
    heap::Heap* h = cold.heap;
    if (hobj.get_class() != hobject::ObjClass.OBJECT || hobj.is_proxy()
        || hobj.flags.exotic_deferred_ns || hobj.flags.exotic_module_ns) return pc;
    hobject::ICEntry* ic = th_ic_at(cold, pc);
    if (ic.key.borrow() == null && key.flags.is_interned) return pc;
    HString* interned = key;
    if (!key.flags.is_interned) {
        interned = h.str_table_lookup(key.get_data(), h.content_hash(key));
        if (interned == null) return pc;
    }
    TVal value;
    if (ic.key.borrow() == (void*)interned) {
        if (ic.shape_id != hobj.shape_id || ic.shape_gen != hobj.live_shape_generation(h)) return pc;
        hobject::PropValue* cached = hobject::ic_resolve_value(ic, hobj);
        if (cached == null) return pc;
        value = cached.get();
    } else {
        int idx = hobj.find_prop_idx((void*)interned, h);
        if (idx >= 0) {
            if (hobj.get_prop_flags((uint)idx, h).is_accessor) return pc;
            value = hobj.prop_values()[idx].get();
        } else {
            HObject* proto = hobj.prototype;
            if (proto != null && (proto != h.object_proto || proto.prototype != null
                || proto.find_prop_idx((void*)interned, h) >= 0)) return pc;
            value.set_undefined();
        }
    }
    TVal* ra = regs + pc.a;
    if (!th_can_publish(h, value) || !th_can_release(ra)) return pc;
    th_do_retain(&value);
    th_do_release(ra);
    *ra = value;
    if (value.is_heap_allocated()) track_heap_store(cold.act, ra, (uint)pc.a);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_getprop_array(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    if (!rb.is_object()) return pc;
    if (rc.is_string()) return th_get_computed(pc, handlers, regs, cold, (HObject*)rb.get_heapptr(), (HString*)rc.get_heapptr());
    if (!rc.is_fastint()) return pc;
    HObject* obj = (HObject*)rb.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.ARRAY) {
        if (builtins::is_typed_array_class(obj.get_class()) && !obj.is_proxy()) return th_get_typed_element(pc, handlers, regs, cold, obj);
        return pc;
    }
    if (obj.is_proxy()) return pc;
    long idx = rc.get_fastint();
    hobject::PropValue* elements = obj.array_part();
    if (elements == null || idx < 0 || idx >= (long)obj.array_size) return pc;
    TVal value = elements[idx].get();
    // Undefined dense slots need named-property and prototype lookup.
    if (value.is_undefined()) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_publish(cold.heap, value)) return pc;
    if (value.is_heap_allocated()) {
        if (!th_can_release(ra)) return pc;
        th_do_retain(&value);
        th_do_release(ra);
        *ra = value;
        track_heap_store(cold.act, ra, (uint)insn.a);
    } else {
        if (!th_can_release(ra)) return pc;
        th_do_release(ra);
        *ra = value;
    }
    pc++;
    return th_next(pc, handlers, regs, cold);
}

// The backing bytes of typed array `obj` and its element count, when `obj` is
// attached and its buffer is not resizable (a resizable one recomputes its
// length, which the switch does). Null otherwise.
fn char* th_typed_array_base(HObject* obj, uint* count) @private {
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    if (buf == null || (*buf.extra_ptr()).ab.data == null || (*buf.extra_ptr()).ab.resizable) return null;
    *count = (*obj.extra_ptr()).view.byte_length >> builtins::ta_elem_shift(obj.get_class());
    return (*buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset;
}

// `ta[i]` for a fastint index into a fixed-length typed array. An element
// reads as a number, which needs no publication or tracking. An index out of
// bounds reads undefined, and the switch handles it.
fn Instruction* th_get_typed_element(Instruction* pc, HandlerTable* handlers, TVal* regs,
                                     ColdCtx* cold, HObject* obj) @private @noinline {
    Instruction insn = *pc;
    long idx = regs[insn.c].get_fastint();
    uint count;
    char* base = th_typed_array_base(obj, &count);
    TVal* ra = regs + insn.a;
    if (base == null || idx < 0 || idx >= (long)count || !th_can_release(ra)
        || builtins::is_bigint_typed_array_class(obj.get_class())) return pc;
    hobject::ObjClass cls = obj.get_class();
    TVal value = builtins::ta_load_number(base + ((uint)idx << builtins::ta_elem_shift(cls)), cls);
    th_do_release(ra);
    *ra = value;
    return th_next(pc + 1, handlers, regs, cold);
}

// `ta[i] = v` for a fastint index into a fixed-length, mutable typed array and
// a number `v`, whose conversion cannot run user code or throw.
fn Instruction* th_put_typed_element(Instruction* pc, HandlerTable* handlers, TVal* regs,
                                     ColdCtx* cold, HObject* obj) @private @noinline {
    Instruction insn = *pc;
    long idx = regs[insn.b].get_fastint();
    TVal* value = regs + insn.c;
    if (!value.is_fastint() && !value.is_number()) return pc;
    uint count;
    char* base = th_typed_array_base(obj, &count);
    hobject::ObjClass cls = obj.get_class();
    // An immutable buffer drops every store; the switch does that.
    if (base == null || idx < 0 || idx >= (long)count
        || (*(*obj.extra_ptr()).view.buffer.extra_ptr()).ab.immutable
        || builtins::is_bigint_typed_array_class(cls)) return pc;
    char* ep = base + ((uint)idx << builtins::ta_elem_shift(cls));
    if (!value.is_fastint()) return th_put_typed_double(pc, handlers, regs, cold, ep, cls, value.get_number());
    builtins::ta_store_int(ep, cls, value.get_fastint());
    return th_next(pc + 1, handlers, regs, cold);
}

// The store of a double, whose conversions make calls; out of line so the
// integer store above needs no frame.
fn Instruction* th_put_typed_double(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                                    char* ep, hobject::ObjClass cls, double num) @private @noinline {
    builtins::TAScalar scalar = { .num = num };
    builtins::ta_store_scalar(ep, cls, &scalar);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_getpropc(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    TVal* rb = regs + insn.b;
    void* key = vm.current_func.constants[(uint)insn.c].get_heapptr();
    HObject* hobj;
    if (rb.is_object()) {
        hobj = (HObject*)rb.get_heapptr();
        // Proxy [[Get]] can run a trap, so it never reaches the cache.
        if (hobj.is_proxy()) return pc;
    } else {
        // A string primitive reads through String.prototype, whose entry the
        // switch filled. Its own `length` is read here; indexed keys are its
        // own properties too and stay in the switch.
        HString* str = (HString*)rb.get_heapptr();
        if (!rb.is_string() || str.is_symbol() || ((HString*)key).is_arridx()) return pc;
        if (key == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
            TVal* destination = regs + insn.a;
            if (!th_can_release(destination)) return pc;
            long length = (long)str.char_length();
            th_do_release(destination);
            destination.set_fastint(length);
            return th_next(pc + 1, handlers, regs, cold);
        }
        hobj = vm.heap.string_proto;
    }
    // Array length lives outside the ordinary property cache and can change
    // without a shape transition, so read its current value on every visit.
    if (hobj.get_class() == hobject::ObjClass.ARRAY
        && key == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
        TVal* destination = regs + insn.a;
        if (!th_can_release(destination)) return pc;
        th_do_release(destination);
        destination.set_fastint((long)*hobj.array_len_ptr());
        pc++;
        return th_next(pc, handlers, regs, cold);
    }
    hobject::ICEntry* ic = th_ic_at(cold, pc);
    if (ic.key.borrow() != key || ic.shape_id != hobj.shape_id
        || ic.shape_gen != hobj.live_shape_generation(cold.heap)) {
        return th_get_shared(pc, handlers, regs, cold, hobj, key);
    }
    hobject::PropValue* ic_value = hobject::ic_resolve_value(ic, hobj);
    if (ic_value == null) {
        if (ic.prop_idx == hobject::IC_PROP_MISSING) return th_get_missing(pc, handlers, regs, cold, hobj, key);
        if (ic.prop_flags.is_accessor) return pc;
        return th_get_shared(pc, handlers, regs, cold, hobj, key);
    }
    return th_publish_read(pc, handlers, regs, cold, ic_value.get());
}

// A cached getter read: calls the lean getter the entry names with `receiver`
// as `this`, the result landing in the instruction's register. The callee goes
// in that register and the frame starts two above it, the window the switch's
// invoke_getter uses. A receiver read from a register has to sit below the
// window, in a tracked register that roots it for the whole call; the frame's
// own `this` (GETTHISC) is rooted by the frame. Anything else (a data entry
// that went stale, a getter that is not lean, a window that would hold the
// receiver) bails to the switch.
fn Instruction* th_call_getter(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                               HObject* hobj, hobject::ICEntry* ic, bool this_receiver) @private @noinline {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    if (!ic.prop_flags.is_accessor) return pc;
    if (!this_receiver && (insn.b >= insn.a || cold.act.heap_reg_count <= insn.b)) return pc;
    hobject::PropValue* slot = hobject::ic_resolve_slot(ic, hobj);
    if (slot == null) return pc;
    TVal getter = hobject::hobject_access_getter(slot.get());
    TVal receiver = this_receiver ? cold.act.this_binding : regs[insn.b];
    TVal* ra = regs + insn.a;
    CompiledFunction* target = th_lean_target(vm, getter, ra + 2, false);
    if (target == null || !th_can_release(ra) || !th_can_release(ra + 1)) return pc;
    if (!receiver.is_object() && !target.is_strict() && !target.ignores_this()) return pc;
    if (th_call_gate(cold)) return pc;
    th_do_release(ra);
    *ra = getter;
    track_heap_store(cold.act, ra, insn.a);
    return th_enter_lean(pc, handlers, regs, cold, target, insn.a, insn.a, 0, false, true,
                         receiver, true);
}

// GETPROPC_CACHED, the warm form GETPROPC rewrites itself into. The key is
// implied by the site, so only the shape and resolved value slot are checked;
// a miss bails so the switch performs the downgrade back to GETPROPC.
fn Instruction* th_getpropc_cached(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* rb = regs + pc.b;
    if (!rb.is_object()) return pc;
    return th_get_cached(pc, handlers, regs, cold, (HObject*)rb.get_heapptr(), false);
}

// GETTHISC: the read of a property of the frame's `this`. The switch fills the
// entry and never rewrites the instruction, so an entry with no key is empty.
fn Instruction* th_getthisc(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal* receiver = &cold.act.this_binding;
    if (!receiver.is_object() || th_ic_at(cold, pc).key.borrow() == null) return pc;
    return th_get_cached(pc, handlers, regs, cold, (HObject*)receiver.get_heapptr(), true);
}

fn Instruction* th_getproto(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal base = regs[pc.b];
    if (!base.is_object()) return pc;
    HObject* obj = (HObject*)base.get_heapptr();
    if (obj == null || obj.is_proxy()) return pc;
    TVal value;
    if (obj.prototype != null) {
        value.set_object(obj.prototype);
    } else {
        value.set_null();
    }
    TVal* ra = regs + pc.a;
    if (!th_can_publish(cold.heap, value) || !th_can_release(ra)) return pc;
    th_do_release(ra);
    *ra = value;
    if (value.is_object()) track_heap_store(cold.act, ra, (uint)pc.a);
    return th_next(pc + 1, handlers, regs, cold);
}

// Lookup starts at the super base; a getter receives the frame's own `this`.
fn Instruction* th_getprop_super(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal base = regs[pc.b];
    TVal key = regs[pc.c];
    if (!base.is_object() || !key.is_string()
        || th_ic_at(cold, pc).key.borrow() != key.get_heapptr()) return pc;
    HObject* obj = (HObject*)base.get_heapptr();
    if (!hobject::plain_property_object(obj)) return pc;
    return th_get_cached(pc, handlers, regs, cold, obj, true);
}

// The cached read shared by GETPROPC_CACHED and GETTHISC, on the object `hobj`
// the receiver names.
fn Instruction* th_get_cached(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                              HObject* hobj, bool this_receiver) @private @inline {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    hobject::ICEntry* ic = th_ic_at(cold, pc);
    if (ic.shape_id != hobj.shape_id || ic.shape_gen != hobj.live_shape_generation(cold.heap)) {
        return th_get_shared(pc, handlers, regs, cold, hobj, ic.key.borrow());
    }
    hobject::PropValue* ic_value = hobject::ic_resolve_value(ic, hobj);
    if (ic_value == null) {
        if (ic.prop_idx == hobject::IC_PROP_MISSING) return th_get_missing(pc, handlers, regs, cold, hobj, ic.key.borrow());
        // A data entry whose prototype chain no longer validates: receivers of
        // one shape with different prototypes alternate at the site.
        if (!ic.prop_flags.is_accessor) return th_get_shared(pc, handlers, regs, cold, hobj, ic.key.borrow());
        return th_call_getter(pc, handlers, regs, cold, hobj, ic, this_receiver);
    }
    return th_publish_read(pc, handlers, regs, cold, ic_value.get());
}

// Keep complete-chain validation off the ordinary own-data hit path.
fn Instruction* th_get_missing(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                               HObject* receiver, void* key) @private @noinline {
    if (!hobject::ic_matches_missing_read(th_ic_at(cold, pc), receiver, key, cold.heap)) return pc;
    TVal missing;
    missing.set_undefined();
    return th_publish_read(pc, handlers, regs, cold, missing);
}

// A read whose site cache holds another shape: the heap's megamorphic cache,
// which the switch's lookups fill, may still answer it with a data property.
// An own property also moves the site's entry to the receiver's shape, the
// refill the switch would make, so a site whose objects changed shape for good
// returns to the site cache.
fn Instruction* th_get_shared(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                              HObject* hobj, void* key) @private @noinline {
    if (key == null || !hobj.mega_cacheable(key, cold.heap)) return pc;
    hobject::MegamorphicEntry* me;
    hobject::PropValue* slot = hobject::mega_cache_lookup(cold.heap, hobj, key, &me);
    if (slot == null || me.is_accessor) return pc;
    hobject::ICEntry* ic = th_ic_at(cold, pc);
    if (me.proto == null && ic.key.borrow() == key) {
        ic.shape_id = hobj.shape_id;
        ic.shape_gen = hobj.live_shape_generation(cold.heap);
        ic.prop_idx = me.prop_idx;
        ic.prop_flags = me.flags;
        ic.chain_len = 0;
        ic.has_proto = false;
    }
    return th_publish_read(pc, handlers, regs, cold, slot.get());
}

// Copy a borrowed value into the instruction's destination register.
fn Instruction* th_publish_read(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                                TVal ic_val) @private @inline {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    TVal* ra = regs + insn.a;
    // An inert value needs no publication, retain or tracking, and a register
    // that holds anything but a string has no count to release. An object
    // needs only the tracking, since it has no count either.
    if (!ra.is_refcounted()) {
        if (ic_val.is_inert()) {
            *ra = ic_val;
            return th_next(pc + 1, handlers, regs, cold);
        }
        if (ic_val.is_object() && th_can_publish(vm.heap, ic_val)) {
            *ra = ic_val;
            track_heap_store(cold.act, ra, (uint)insn.a);
            return th_next(pc + 1, handlers, regs, cold);
        }
    }
    if (!th_can_publish(vm.heap, ic_val)) return pc;
    if (!ic_val.is_heap_allocated()) {
        if (!th_can_release(ra)) return pc;
        th_do_release(ra);
        *ra = ic_val;
    } else {
        // Inline refcount, matching th_getvar/th_ldreg (c32cc52b): tval_copy_ref
        // calls Heap.decref, which frames the handler (ten callee-saved registers
        // saved/restored on every IC hit). An incref is a plain increment, and a
        // decref is a decrement plus a zero test whose free path is rare. Both
        // sides are tested before either is mutated: bailing after a completed
        // retain would leak the reference it took.
        if (!th_can_release(ra)) return pc;
        th_do_retain(&ic_val);
        th_do_release(ra);
        *ra = ic_val;
        track_heap_store(cold.act, ra, (uint)insn.a);
    }
    pc++;
    return th_next(pc, handlers, regs, cold);
}

// The reference-counted and traced half of a slot store. It is a tail call from
// the handler, so the handler itself makes no call and needs no frame.
//
// The barrier takes the address of a local, which would keep a store inlined
// here from ending in a tail call, so the store is its own function.
fn void th_store_slot_ref(Vm* vm, HObject* hobj, hobject::PropValue* slot, TVal* value) @private @noinline {
    vm.heap.store_slot_ref(hobj, slot, value);
}

fn Instruction* th_store_slot_ref_next(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                                       HObject* hobj, hobject::PropValue* slot, TVal* value) @private @noinline {
    th_store_slot_ref(cold.vm, hobj, slot, value);
    return th_next(pc + 1, handlers, regs, cold);
}

// The reference-counted and traced half of an absent-property append, out of
// line for the same reason as th_store_slot_ref_next. A full property table
// bails to the switch, which grows it.
fn Instruction* th_append_ref_next(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                                   HObject* hobj, hobject::ICEntry* ic, void* key, TVal* value) @private @noinline {
    if (!hobj.append_cached_prop(ic, *value, cold.heap)) {
        return th_put_lookup(pc, handlers, regs, cold, hobj, (HString*)key, value, null);
    }
    return th_next(pc + 1, handlers, regs, cold);
}

// A store of a key the receiver and its whole prototype chain lack, the shape of
// every constructor's `this.x = x`. The cache holds the shape the append moves
// to, so a hit needs no lookup of the key or of the transition.
fn Instruction* th_put_absent(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                              HObject* hobj, hobject::ICEntry* ic, void* key, TVal* value) @private @inline {
    if (value.is_heap_allocated()) return th_append_ref_next(pc, handlers, regs, cold, hobj, ic, key, value);
    if (hobj.prop_count >= hobj.prop_capacity || hobj.prop_hash != null) {
        return th_put_lookup(pc, handlers, regs, cold, hobj, (HString*)key, value, null);
    }
    if (hobj.gc.prototype_observed) cold.heap.bump_prototype_epoch();
    hobject::PropValue* slot = &hobj.prop_values()[hobj.prop_count];
    *slot = (hobject::PropValue)*value;
    hobj.prop_count++;
    hobj.shape_id = ic.absent_next_shape;
    return th_next(pc + 1, handlers, regs, cold);
}

// The cached store shared by PUTPROP and PUTPROPC: `key` is the interned
// string the instruction names, `value` the register being stored.
fn Instruction* th_put_cached(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                              TVal* target, void* key, TVal* value, bool computed) @private @inline {
    Vm* vm = cold.vm;
    if (!target.is_object()) return pc;
    HObject* hobj = (HObject*)target.get_heapptr();
    if (hobj.get_class() != hobject::ObjClass.OBJECT
        || hobj.is_proxy() || hobj.flags.exotic_module_ns) return pc;
    hobject::ICEntry* ic = th_ic_at(cold, pc);
    if (ic.prop_idx == hobject::IC_PROP_ABSENT) {
        if (!hobject::ic_matches_absent_put(ic, hobj, key, cold.heap)) {
            return th_put_lookup(pc, handlers, regs, cold, hobj, (HString*)key, value, computed ? null : ic);
        }
        return th_put_absent(pc, handlers, regs, cold, hobj, ic, key, value);
    }
    // Shapes describe slot indices across receivers with distinct storage.
    // Exotic receivers must run their [[Set]] semantics in the switch.
    if (ic.key.borrow() != key || ic.shape_id != hobj.shape_id || ic.has_proto
        || ic.shape_gen != hobj.live_shape_generation(cold.heap)) {
        // A site that has cached nothing bails so the switch can fill the
        // cache. Otherwise the store runs by lookup, and a constant key also
        // moves the site's entry to this receiver, as the switch would.
        if (ic.key.borrow() == null && ((HString*)key).flags.is_interned) return pc;
        return th_put_lookup(pc, handlers, regs, cold, hobj, (HString*)key, value, computed ? null : ic);
    }
    if (ic.prop_flags.is_accessor || !ic.prop_flags.writable) return pc;
    hobject::PropValue* slot = &hobj.prop_values()[ic.prop_idx];
    // Replacing one non-heap value with another has no reference count or
    // barrier to maintain, which keeps the common numeric store a leaf. The
    // reference-counted and traced cases tail-call out of line.
    if (value.is_heap_allocated() || slot.get().is_heap_allocated()) {
        return th_store_slot_ref_next(pc, handlers, regs, cold, hobj, slot, value);
    }
    *slot = (hobject::PropValue)*value;
    return th_next(pc + 1, handlers, regs, cold);
}

// A store by lookup into a plain object: an own writable data property, or a
// new property when the receiver is extensible and the first holder of the key
// on its chain, if any, is a writable data property (OrdinarySet). The chain
// must consist of plain objects, so no proxy or exotic [[Set]] is skipped.
// Any other case bails to the switch, which runs the whole of [[Set]]: an
// accessor or read-only property, an array index or hidden new key, or a
// non-extensible receiver. A non-null `ic` is refilled for the receiver.
fn Instruction* th_put_lookup(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold,
                              HObject* hobj, HString* key, TVal* value, hobject::ICEntry* ic) @private @noinline {
    heap::Heap* h = cold.heap;
    bool fresh_name = pc.op == Opcode.PUTPROP && !key.flags.is_interned;
    HString* interned = h.ensure_interned(key);
    int idx = hobj.find_prop_idx((void*)interned, h);
    if (idx >= 0) {
        hobject::PropFlags flags = hobj.get_prop_flags((uint)idx, h);
        if (flags.is_accessor || !flags.writable) return pc;
        // An own entry stays valid on a dictionary too, since indexes never
        // move. The hit path matches the key by pointer, so only the interned
        // key itself is cached.
        if (ic != null && interned == key) {
            ic.shape_id = hobj.shape_id;
            ic.shape_gen = hobj.shape_generation(h);
            ic.has_proto = false;
            ic.chain_len = 0;
            ic.prop_idx = (uint)idx;
            ic.prop_flags = flags;
            ic.key.set(h, interned);
        }
        hobject::PropValue* slot = &hobj.prop_values()[idx];
        if (value.is_heap_allocated() || slot.get().is_heap_allocated()) {
            return th_store_slot_ref_next(pc, handlers, regs, cold, hobj, slot, value);
        }
        *slot = (hobject::PropValue)*value;
        return th_next(pc + 1, handlers, regs, cold);
    }
    if (!hobj.flags.extensible || interned.flags.is_arridx || interned.flags.is_hidden) return pc;
    HObject* cur = hobj.prototype;
    for (uint depth = 0; cur != null; depth++) {
        if (depth >= hobject::MAX_PROTO_DEPTH || !hobject::plain_property_object(cur)) return pc;
        int at = cur.find_prop_idx((void*)interned, h);
        if (at >= 0) {
            hobject::PropFlags flags = cur.get_prop_flags((uint)at, h);
            if (flags.is_accessor || !flags.writable) return pc;
            break;
        }
        cur = cur.prototype;
    }
    uint incoming = hobj.shape_id;
    uint epoch = h.shape_recycle_epoch;
    if (fresh_name) hobj.note_computed_name(interned);
    if (!hobj.put_prop_new((void*)interned, *value, hobject::PROP_FLAGS_WEC, h)) return pc;
    if (ic != null) {
        hobject::ic_fill_absent_put(ic, hobj, (void*)interned, incoming, hobj.shape_id, epoch, h);
    }
    return th_next(pc + 1, handlers, regs, cold);
}

// a[i] = v on a dense array, for an index inside the dense part: the switch's
// dense indexed store without its growth and named-property cases, which bail.
// The dense part marks a hole with `undefined`, so storing `undefined` bails
// too. An append updates the length here only when no named "length" entry
// needs the switch's sync_named_length.
fn Instruction* th_put_array_element(Instruction* pc, HandlerTable* handlers, TVal* regs,
                                     ColdCtx* cold) @private @inline {
    Instruction insn = *pc;
    TVal* target = regs + insn.a;
    TVal* value = regs + insn.c;
    long index = regs[insn.b].get_fastint();
    if (!target.is_object() || value.is_undefined() || index < 0) return pc;

    HObject* array = (HObject*)target.get_heapptr();
    if (builtins::is_typed_array_class(array.get_class()) && !array.is_proxy()) return th_put_typed_element(pc, handlers, regs, cold, array);
    if (array.get_class() != hobject::ObjClass.ARRAY || array.is_proxy()
        || array.flags.has_indexed_named_prop || index >= (long)array.array_size) return pc;
    hobject::PropValue* elements = array.array_part();
    if (elements == null) return pc;

    hobject::PropValue* slot = &elements[(uint)index];
    if (slot.get().is_undefined()) {
        // A new index runs OrdinarySet, which must consult the prototype
        // chain. Any chain but the clean usual one goes to the switch, keeping
        // this handler free of calls.
        if (array.prototype != cold.heap.index_clean_proto) return pc;
        if ((uint)index >= *array.array_len_ptr()) {
            if (array.prop_count != 0) return pc;
            *array.array_len_ptr() = (uint)index + 1;
        }
        array.array_used++;
    }
    if (value.is_heap_allocated() || slot.get().is_heap_allocated()) {
        return th_store_slot_ref_next(pc, handlers, regs, cold, array, slot, value);
    }
    *slot = (hobject::PropValue)*value;
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_putprop(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (rb.is_fastint()) return th_put_array_element(pc, handlers, regs, cold);
    if (!rb.is_string()) return pc;
    return th_put_cached(pc, handlers, regs, cold, regs + insn.a, rb.get_heapptr(), regs + insn.c, true);
}

fn Instruction* th_putpropc(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    return th_put_cached(pc, handlers, regs, cold, regs + insn.a,
                         cold.vm.current_func.constants[insn.c].get_heapptr(), regs + insn.b, false);
}

// PUTTHISC: `this.name = value`, the value in register A.
fn Instruction* th_putthisc(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    return th_put_cached(pc, handlers, regs, cold, &cold.act.this_binding,
                         cold.vm.current_func.constants[insn.c].get_heapptr(), regs + insn.a, false);
}

// NEWARR. The allocation is a call either way, so the handler is out of line and
// keeps its frame; what it saves is the round trip through the switch. It
// mirrors the switch case, which documents the register-ownership order. A
// failed allocation bails, and the switch repeats it and reports the failure.
fn Instruction* th_newarr(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Vm* vm = cold.vm;
    Instruction insn = *pc;
    TVal* ra = regs + insn.a;
    uint capacity_hint = insn.get_bc();
    vm.heap.set_reg_undefined(ra);
    HObject*? new_arr = vm.heap.alloc_object(hobject::ObjClass.ARRAY, capacity_hint);
    HObject* a = new_arr ?? null;
    if (a == null) return pc;
    a.prototype = vm.heap.array_proto;
    vm.heap.set_reg_object(ra, a);
    track_heap_store(cold.act, ra, (uint)insn.a);
    if (capacity_hint > a.array_size) a.grow_array(capacity_hint, vm.heap);
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_newarr_const(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    TVal* dst = regs + insn.a;
    vm.heap.set_reg_undefined(dst);
    HObject* array = vm.heap.alloc_constant_array(vm.current_func.constants + insn.get_bc()) ?? null;
    if (array == null) return pc;
    vm.heap.set_reg_object(dst, array);
    track_heap_store(cold.act, dst, (uint)insn.a);
    return th_next(pc + 1, handlers, regs, cold);
}

// NEWOBJ and NEWOBJ_SHAPE, out of line like th_newarr for the same reason. A
// failed allocation bails, and the switch repeats it and reports the failure.
fn Instruction* th_newobj(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Vm* vm = cold.vm;
    Instruction insn = *pc;
    TVal* ra = regs + insn.a;
    vm.heap.set_reg_undefined(ra);
    HObject*? new_obj = insn.op == Opcode.NEWOBJ_SHAPE
        ? vm.heap.alloc_shaped_object(insn.get_bc())
        : vm.heap.alloc_object(hobject::ObjClass.OBJECT);
    HObject* o = new_obj ?? null;
    if (o == null) return pc;
    o.prototype = vm.heap.object_proto;
    vm.heap.set_reg_object(ra, o);
    track_heap_store(cold.act, ra, (uint)insn.a);
    return th_next(pc + 1, handlers, regs, cold);
}

// NEW_OBJ of a base constructor whose `prototype` read the switch has cached at
// this site. A constructor the switch has classified as simple has its stores
// replayed from their caches by init_simple_constructor without entering it;
// any other lean one runs on a lean frame that holds the instance as its
// `this`. Anything else, a cold cache or a failed allocation bails before the
// instance is published.
fn Instruction* th_new_obj(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Vm* vm = cold.vm;
    Instruction insn = *pc;
    TVal callee = regs[insn.b];
    if (!callee.is_object()) return pc;
    HObject* ctor = (HObject*)callee.get_heapptr();
    if (!ctor.is_callable() || !ctor.is_constructable()
        || ctor.callable_kind() != hobject::CallableKind.COMPILED_FN) return pc;
    CompiledFunction* target = (*ctor.extra_ptr()).func.comp_func;
    if (target == null || target.is_arrow() || target.is_derived_ctor()
        || target.brand_name_hstr != null || target.field_init_func != null) return pc;
    bool simple = target.call_flags.simple_constructor;
    if (!simple && th_lean_target(vm, callee, regs + insn.b + 2, false) == null) return pc;
    hobject::ICEntry* ic = th_ic_at(cold, pc);
    if (ic.key.borrow() != (void*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE] || ic.has_proto
        || ic.shape_id != ctor.shape_id || ic.shape_gen != ctor.shape_generation(vm.heap)
        || ic.prop_flags.is_accessor || ic.prop_idx >= ctor.prop_count) return pc;
    TVal proto = ctor.prop_values()[ic.prop_idx].get();
    TVal* ra = regs + insn.a;
    if (!proto.is_object() || !th_can_release(ra)) return pc;
    if (!simple && th_call_gate(cold)) return pc;
    HObject* obj = vm.heap.alloc_object(hobject::ObjClass.OBJECT) ?? null;
    if (obj == null) return pc;
    vm.heap.set_prototype(obj, (HObject*)proto.get_heapptr());
    if (!simple) {
        if (target.call_flags.constructor_capacity > hobject::INLINE_PROPS) {
            obj.reserve_props(vm.heap, constructor_reserve_capacity(target.call_flags.constructor_capacity));
        }
        // The frame holds the new object as its `this`, and its return
        // answers it unless the body returns an object.
        TVal this_value;
        this_value.set_object(obj);
        return th_enter_lean(pc, handlers, regs, cold, target, insn.b, insn.a, insn.c, false, false,
                             this_value, true, new_target: ctor);
    }
    if (!init_simple_constructor(vm, target, obj, regs + insn.b + 2, insn.c)) return pc;
    th_do_release(ra);
    ra.set_object(obj);
    track_heap_store(cold.act, ra, (uint)insn.a);
    return th_next(pc + 1, handlers, regs, cold);
}

// Define element `index` on a fresh dense array literal. The generic
// CreateDataPropertyOrThrow cases stay in the switch: this path only handles an
// empty slot on an extensible array with no indexed named properties, holding a
// value that is not `undefined` (an `undefined` element is a hole in the dense
// part).
fn Instruction* th_init_array_element(Instruction* pc, HandlerTable* handlers, TVal* regs,
                                      ColdCtx* cold, TVal* target, long index, TVal* value) @private @inline {
    if (!target.is_object() || value.is_undefined()) return pc;

    HObject* array = (HObject*)target.get_heapptr();
    if (array == null || array.get_class() != hobject::ObjClass.ARRAY
        || array.is_proxy() || !array.flags.extensible
        || array.flags.has_indexed_named_prop) return pc;

    if (index < 0 || index >= (long)array.array_size) return pc;
    hobject::PropValue* elements = array.array_part();
    if (elements == null) return pc;
    hobject::PropValue* slot = &elements[(uint)index];
    if (!slot.get().is_undefined()) return pc;

    array.array_used++;
    if ((uint)index >= *array.array_len_ptr()) {
        *array.array_len_ptr() = (uint)index + 1;
    }
    // A non-heap value has no reference count or barrier to maintain.
    if (value.is_heap_allocated()) {
        return th_store_slot_ref_next(pc, handlers, regs, cold, array, slot, value);
    }
    *slot = (hobject::PropValue)*value;
    return th_next(pc + 1, handlers, regs, cold);
}

fn Instruction* th_initprop_array(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* key = regs + insn.b;
    if (!key.is_fastint()) return pc;
    return th_init_array_element(pc, handlers, regs, cold, regs + insn.a, key.get_fastint(), regs + insn.c);
}

fn Instruction* th_initelem(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    return th_init_array_element(pc, handlers, regs, cold, regs + insn.a, (long)insn.b, regs + insn.c);
}

// Initialize an empty fixed-shape object slot.
fn Instruction* th_init_slot(Instruction* pc, HandlerTable* handlers,
                             TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* target = regs + insn.a;
    TVal* value = regs + insn.c;
    if (!target.is_object()) return pc;

    HObject* object = (HObject*)target.get_heapptr();
    if (object == null || object.is_proxy()
        || object.get_class() != hobject::ObjClass.OBJECT
        || insn.b >= object.prop_count) return pc;
    hobject::PropValue* slots = object.prop_values();
    if (slots == null) return pc;
    hobject::PropValue* slot = &slots[insn.b];
    if (!slot.get().is_undefined()) return pc;

    // Only a heap value has a reference count or needs the write barrier.
    if (value.is_heap_allocated()) return th_store_slot_ref_next(pc, handlers, regs, cold, object, slot, value);
    *slot = (hobject::PropValue)*value;
    return th_next(pc + 1, handlers, regs, cold);
}

// Pop the returning frame `fa` and continue in `caller`. The result is already
// written. A leaf, so the return handlers tail-jump here with no frame of
// their own; an owned `this` is released by the caller of this routine.
fn Instruction* th_resume_caller(HandlerTable* handlers, ColdCtx* cold, Activation* fa,
                                 Activation* caller, bool cross_function) @private {
    $if $feat(OP_PROFILE): opprof_thread_complete(); $endif
    Vm* vm = cold.vm;
    Instruction* caller_pc = caller.curr_pc;
    TVal* caller_top = fa.caller_valstack_top;
    fa.release_callee(vm.heap);
    vm.activation_count--;
    vm.gc_root_frame_count_changed();
    cold.act = caller;
    vm.valstack_bottom = caller.bottom;
    vm.valstack_top = caller_top;
    *cold.regs_base_ptr = caller.bottom;

    if (cross_function) {
        // The current burst's bounds and IC biases belong to the returning
        // callee. The switch picks up the caller from vm.current_func when the
        // burst returns (Dispatch.sync_code).
        CompiledFunction* caller_func = (CompiledFunction*)caller.func;
        if (vm.heap.realm != caller_func.realm) vm.heap.enter_realm(caller_func.realm);
        vm.current_func = caller_func;
        // A caller without caches (their allocation failed) runs on the switch.
        if (caller_func.ic_entries == null) return caller_pc;
        th_bind_ic_bias(cold, caller_func.code, caller_func.ic_entries, caller_func.var_ic_entries);
    }
    return th_next(caller_pc, handlers, caller.bottom, cold);
}

// The outermost frame of a Vm.run, entered by a host call, returning a heap
// value or holding tracked heap registers. The result goes to vm.return_val,
// which owns a reference of its own, so the value is pinned across the
// register sweep that may release its last other holder. Anything the switch's
// RET handles beyond a plain frame -- catchers, for-in state, a mapped
// arguments object, a construct or async frame -- bails to it.
fn Instruction* th_return_entry(Instruction* pc, ColdCtx* cold, TVal value,
                                bool is_undefined) @private @noinline {
    Vm* vm = cold.vm;
    Activation* fa = cold.act;
    if (fa.cat != null || fa.forin != null
        || ((CompiledFunction*)fa.func).maps_formals()
        || (fa.flags & ~(ACT_FLAG_BORROWED_CALLEE | ACT_FLAG_CALLEE_OWNED | ACT_FLAG_THIS_VALID)) != 0
        || vm.heap.gc_safepoint_due(false)) {
        return pc;
    }
    if (is_undefined) value.set_undefined();
    bool pinned = value.is_heap_allocated() && value.get_heapptr() != null;
    if (pinned) ((types::HeapHeader*)value.get_heapptr()).incref();
    sweep_callee_regs(vm, fa);
    vm.activation_count = 0;
    vm.gc_root_frame_count_changed();
    vm.heap.tval_copy_ref(&vm.return_val, &value);
    if (pinned) vm.heap.decref_tval(&value);
    fa.release_callee(vm.heap);
    ((Dispatch*)cold.dispatch_ptr).needs_restart = true;
    $if $feat(OP_PROFILE): opprof_thread_complete(); $endif
    return pc;
}

// The return handlers' general path: a frame with tracked heap registers to
// sweep, an owned `this`, or a returned receiver. It calls into the heap, so it
// carries a full register-saving frame; th_try_fast_return reaches it only when
// its own leaf path does not apply.
fn Instruction* th_return_general(Instruction* pc, HandlerTable* handlers,
                                  ColdCtx* cold, TVal value, bool is_undefined) @private @noinline {
    Vm* vm = cold.vm;
    Activation* fa = cold.act;
    if (vm.activation_count > 1 && fa.retval != null) {
        Activation* caller = &vm.activations[vm.activation_count - 2];
        bool cross_function = caller.func != fa.func;
        // A base constructor's [[Construct]] answers its `this` unless the
        // body returned an object (ES2015 §9.2.2 step 13).
        bool construct = (fa.flags & ACT_FLAG_CONSTRUCT) != 0;
        if (construct && (is_undefined || !value.is_object())) {
            if (!fa.this_binding.is_object()) return pc;
            value = fa.this_binding;
            is_undefined = false;
        }
        bool primitive_return = is_undefined || !value.is_heap_allocated();
        // Objects carry no count, so returning one is a store the caller's
        // watermark tracks. During marking it must already be shaded: the
        // sweep below removes the callee's copy, which may be the last one the
        // collector would scan (th_can_publish). Strings and other heap values
        // keep the switch path's write-back.
        bool object_return = false;
        if (!primitive_return && value.is_object() && value.get_heapptr() != null
            && caller.func != null && caller.bottom != null && th_can_publish(vm.heap, value)) {
            CompiledFunction* caller_func = (CompiledFunction*)caller.func;
            TVal* caller_end = caller.bottom + caller_func.num_regs;
            object_return = fa.retval >= caller.bottom && fa.retval < caller_end;
        }
        if (!primitive_return && !object_return) return pc;
        if (fa.func != vm.current_func) return pc;
        if (cross_function && (caller.func == null || caller.curr_pc == null)) return pc;
        if (fa.cat == null && fa.forin == null
            && !((CompiledFunction*)fa.func).maps_formals()
            && (fa.flags & ~(RET_FAST_FLAGS | ACT_FLAG_CONSTRUCT)) == 0
            && !vm.heap.gc_safepoint_due(false)) {
            if (is_undefined) value.set_undefined();
            if (construct) record_constructor_capacity(fa);
            // Primitive and object return values survive the sweep in this
            // local copy. The tracked registers still need the same cleanup as
            // the general path before the sliding window is reused.
            sweep_callee_regs(vm, fa);
            TVal* result = fa.retval;
            if ((fa.flags & ACT_FLAG_BORROWED_CALLEE) == 0 && result.is_heap_allocated()) {
                vm.heap.decref_tval(result);
            }
            *result = value;
            if (object_return) {
                track_heap_store(caller, result, (uint)(result - caller.bottom));
            }
            fa.release_this(vm.heap);
            return th_resume_caller(handlers, cold, fa, caller, cross_function);
        }
    }
    return pc;
}

// The outermost frame of a Vm.run, entered by a host call: there is no caller
// register to write, so the pop stores the result in vm.return_val and asks
// Vm.run to unwind by restarting with no activation left. The frame has to be
// as plain as th_try_fast_return's leaf path requires; any other goes to
// th_return_entry. Out of line because the release of the previous
// return_val is a call, which would give the leaf path a frame.
fn Instruction* th_return_outermost(Instruction* pc, ColdCtx* cold, TVal value,
                                    bool is_undefined) @private @noinline {
    Vm* vm = cold.vm;
    Activation* fa = cold.act;
    if (fa.heap_reg_count == 0
        && (is_undefined || !value.is_heap_allocated())
        && (fa.flags & ~(ACT_FLAG_BORROWED_CALLEE | ACT_FLAG_CALLEE_OWNED | ACT_FLAG_THIS_VALID)) == 0
        && fa.cat == null && fa.forin == null
        && !((CompiledFunction*)fa.func).maps_formals()
        && !vm.heap.gc_safepoint_due(false)) {
        if (is_undefined) value.set_undefined();
        vm.heap.decref_tval(&vm.return_val);
        vm.return_val = value;
        vm.activation_count = 0;
        vm.gc_root_frame_count_changed();
        fa.release_callee(vm.heap);
        ((Dispatch*)cold.dispatch_ptr).needs_restart = true;
        $if $feat(OP_PROFILE): opprof_thread_complete(); $endif
        return pc;
    }
    return th_return_entry(pc, cold, value, is_undefined);
}

// The registers a frame tracks as holding heap values: those below its
// watermark, within its window.
macro uint th_tracked_reg_count(Activation* fa) @private {
    uint count = fa.heap_reg_count;
    uint nregs = ((CompiledFunction*)fa.func).num_regs;
    return count < nregs ? count : nregs;
}

// Whether every tracked register holds a value with no count to release, such
// as an object, so that popping the frame is plain stores.
macro bool th_tracked_regs_uncounted(Activation* fa) @private {
    uint count = th_tracked_reg_count(fa);
    for (uint i = 0; i < count; i++) {
        if (fa.bottom[i].is_refcounted()) return false;
    }
    return true;
}

// The pop's sweep of such a frame: the stale bits must not outlive it.
macro void th_clear_tracked_regs(Activation* fa) @private {
    uint count = th_tracked_reg_count(fa);
    for (uint i = 0; i < count; i++) fa.bottom[i].set_undefined();
}

// RET and RETUNDEF. The leaf path covers the common return: a primitive
// result from a frame with no tracked heap registers and no owned `this`, so
// the pop is plain stores. The outermost frame goes to th_return_outermost,
// any other to th_return_general, and from there to the switch.
fn Instruction* th_try_fast_return(Instruction* pc, HandlerTable* handlers,
                                  ColdCtx* cold, TVal value, bool is_undefined) {
    Vm* vm = cold.vm;
    Activation* fa = cold.act;
    if (th_frame_is_replaceable(vm, fa) && (is_undefined || !value.is_heap_allocated())
        && (fa.heap_reg_count == 0 || th_tracked_regs_uncounted(fa))
        && !vm.heap.gc_safepoint_due(false)) {
        Activation* caller = &vm.activations[vm.activation_count - 2];
        bool cross_function = caller.func != fa.func;
        TVal* result = fa.retval;
        if ((!cross_function || (caller.func != null && caller.curr_pc != null))
            && ((fa.flags & ACT_FLAG_BORROWED_CALLEE) != 0 || !result.is_refcounted())) {
            if (is_undefined) value.set_undefined();
            th_clear_tracked_regs(fa);
            *result = value;
            return th_resume_caller(handlers, cold, fa, caller, cross_function);
        }
    }
    return th_return_slow(pc, handlers, cold, value, is_undefined);
}

// th_try_fast_return's other cases, in one tail call so that it stays a leaf:
// a direct call to th_return_outermost, which always returns `pc`, is
// lowered as a call plus a return of the original `pc`, and the call frames
// the whole handler.
fn Instruction* th_return_slow(Instruction* pc, HandlerTable* handlers,
                               ColdCtx* cold, TVal value, bool is_undefined) @private @noinline {
    if (cold.vm.activation_count == 1) return th_return_outermost(pc, cold, value, is_undefined);
    return th_return_general(pc, handlers, cold, value, is_undefined);
}

fn Instruction* th_ret(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    return th_try_fast_return(pc, handlers, cold, regs[insn.a], false);
}

fn Instruction* th_retundef(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) {
    TVal value; value.set_undefined();
    return th_try_fast_return(pc, handlers, cold, value, true);
}

// Entry point from Vm.run's inner loop. Runs a burst starting at pc; returns
// the resume pc (== pc if the first opcode isn't in the hot set). Never sets
// needs_restart/halt -- the switch loop re-decodes from the returned pc.
fn Instruction* run_threaded_burst(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    if (pc >= code_end) return pc;
    // Caches are allocated on a function's first run; a function whose
    // allocation failed runs entirely on the switch.
    if (cold.ic_base == null || cold.var_ic_base == null) return pc;
    th_bind_ic_bias(cold, cold.code_base, cold.ic_base, cold.var_ic_base);
    Instruction first = *pc;
    opprof_th_record(first.op);
    $if $feat(OP_PROFILE):
        Opcode saved_op = opprof_pending_op;
        bool saved_valid = opprof_pending_valid;
        bool saved_fused = opprof_pending_fused;
        opprof_thread_begin(first.op);
        defer {
            opprof_pending_op = saved_op;
            opprof_pending_valid = saved_valid;
            opprof_pending_fused = saved_fused;
        }
        return g_threaded_table.fns[first.op.ordinal](pc, &g_threaded_table, regs, cold);
    $else
        return g_threaded_table.fns[first.op.ordinal](pc, &g_threaded_table, regs, cold);
    $endif
}
