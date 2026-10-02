module boomkat::vm;

import boomkat::types;
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
    g_threaded_handlers[Opcode.LDTHIS.ordinal] = &th_ldthis;

    // --- Recursion (fib) cheap ops ---
    g_threaded_handlers[Opcode.LDINT.ordinal]  = &th_ldint;
    g_threaded_handlers[Opcode.SUBI.ordinal]   = &th_subi;
    g_threaded_handlers[Opcode.ADD.ordinal]    = &th_add;
    g_threaded_handlers[Opcode.EQ.ordinal]     = &th_eq;
    g_threaded_handlers[Opcode.NEQ.ordinal]    = &th_eq;
    g_threaded_handlers[Opcode.SEQ.ordinal]    = &th_eq;
    g_threaded_handlers[Opcode.SNEQ.ordinal]   = &th_eq;
    g_threaded_handlers[Opcode.INC.ordinal]    = &th_incdec;
    g_threaded_handlers[Opcode.DEC.ordinal]    = &th_incdec;
    for (Opcode op = Opcode.JMP_NLT; op.ordinal <= Opcode.JMP_SNEQ.ordinal; op = (Opcode)(op.ordinal + 1)) {
        g_threaded_handlers[op.ordinal] = &th_cmp_branch;
    }
    for (Opcode op = Opcode.JMP_NLTI; op.ordinal <= Opcode.JMP_SNEQI.ordinal; op = (Opcode)(op.ordinal + 1)) {
        g_threaded_handlers[op.ordinal] = &th_cmp_branch_i;
    }
    // The relations loops test most get a handler of their own for the fastint
    // pair; the shared one above takes everything else.
    g_threaded_handlers[Opcode.JMP_LT.ordinal]   = &th_jmp_lt;
    g_threaded_handlers[Opcode.JMP_LE.ordinal]   = &th_jmp_le;
    g_threaded_handlers[Opcode.JMP_GT.ordinal]   = &th_jmp_gt;
    g_threaded_handlers[Opcode.JMP_GE.ordinal]   = &th_jmp_ge;
    g_threaded_handlers[Opcode.JMP_NLT.ordinal]  = &th_jmp_nlt;
    g_threaded_handlers[Opcode.JMP_NLE.ordinal]  = &th_jmp_nle;
    g_threaded_handlers[Opcode.JMP_NGT.ordinal]  = &th_jmp_ngt;
    g_threaded_handlers[Opcode.JMP_NGE.ordinal]  = &th_jmp_nge;
    g_threaded_handlers[Opcode.JMP_LTI.ordinal]  = &th_jmp_lti;
    g_threaded_handlers[Opcode.JMP_LEI.ordinal]  = &th_jmp_lei;
    g_threaded_handlers[Opcode.JMP_GTI.ordinal]  = &th_jmp_gti;
    g_threaded_handlers[Opcode.JMP_GEI.ordinal]  = &th_jmp_gei;
    g_threaded_handlers[Opcode.JMP_NLTI.ordinal] = &th_jmp_nlti;
    g_threaded_handlers[Opcode.JMP_NLEI.ordinal] = &th_jmp_nlei;
    g_threaded_handlers[Opcode.JMP_NGTI.ordinal] = &th_jmp_ngti;
    g_threaded_handlers[Opcode.JMP_NGEI.ordinal] = &th_jmp_ngei;
    // CALL threads only the guarded intrinsic array-push case. The plain call
    // forms enter lean compiled functions directly, and RET/RETUNDEF handle
    // guarded primitive and receiver-return pops between ordinary compiled
    // functions.
    g_threaded_handlers[Opcode.RET.ordinal] = &th_ret;
    g_threaded_handlers[Opcode.RETUNDEF.ordinal] = &th_retundef;
    g_threaded_handlers[Opcode.CALL.ordinal] = &th_call;
    g_threaded_handlers[Opcode.CALL_UNDEF_THIS.ordinal] = &th_call_undef_this;
    g_threaded_handlers[Opcode.CALL_VAR.ordinal] = &th_call_var;
    g_threaded_handlers[Opcode.CALL_GLOBAL.ordinal] = &th_call_global;

    // --- Assignment (g_assign) hot ops: perf-all global-slot opcodes ---
    g_threaded_handlers[Opcode.GETGLOBAL.ordinal]  = &th_getglobal;
    g_threaded_handlers[Opcode.PUTGLOBAL.ordinal]  = &th_putglobal;
    g_threaded_handlers[Opcode.INC_GLOBAL.ordinal] = &th_inc_global;
    g_threaded_handlers[Opcode.DEC_GLOBAL.ordinal] = &th_dec_global;

    // --- Variable access (VarIC shape and recycle-epoch path) ---
    g_threaded_handlers[Opcode.GETVAR.ordinal]        = &th_getvar;
    g_threaded_handlers[Opcode.GETCAP.ordinal]        = &th_getcap;
    g_threaded_handlers[Opcode.PUTCAP.ordinal]        = &th_putcap;
    g_threaded_handlers[Opcode.PUTCAP_SNAP.ordinal]   = &th_putcap;
    g_threaded_handlers[Opcode.GETCELL.ordinal]       = &th_getcell;
    g_threaded_handlers[Opcode.SETCELL.ordinal]       = &th_setcell;
    g_threaded_handlers[Opcode.MOVECELL.ordinal]      = &th_movecell;
    g_threaded_handlers[Opcode.PUTVAR_ASSIGN.ordinal] = &th_putvar_assign;
    g_threaded_handlers[Opcode.PUTVAR_SNAP.ordinal]   = &th_putvar_snap_number;
    g_threaded_handlers[Opcode.INC_VAR.ordinal]       = &th_inc_var;
    g_threaded_handlers[Opcode.JUMP.ordinal]          = &th_jump;
    g_threaded_handlers[Opcode.SUB.ordinal]           = &th_sub;
    g_threaded_handlers[Opcode.MUL.ordinal]           = &th_mul;
    g_threaded_handlers[Opcode.MULI.ordinal]          = &th_muli;
    g_threaded_handlers[Opcode.MOD.ordinal]           = &th_mod;
    g_threaded_handlers[Opcode.BAND.ordinal]          = &th_band;
    g_threaded_handlers[Opcode.BANDI.ordinal] = &th_bandi;
    g_threaded_handlers[Opcode.BOR.ordinal]           = &th_bor;
    g_threaded_handlers[Opcode.BORI.ordinal] = &th_bori;
    g_threaded_handlers[Opcode.BXOR.ordinal]          = &th_bxor;
    g_threaded_handlers[Opcode.BXORI.ordinal] = &th_bxori;
    g_threaded_handlers[Opcode.SHL.ordinal]           = &th_shl;
    g_threaded_handlers[Opcode.SHLI.ordinal] = &th_shli;
    g_threaded_handlers[Opcode.SHR.ordinal]           = &th_shr;
    g_threaded_handlers[Opcode.SHRI.ordinal] = &th_shri;
    g_threaded_handlers[Opcode.USHR.ordinal]          = &th_ushr;
    g_threaded_handlers[Opcode.USHRI.ordinal] = &th_ushri;
    g_threaded_handlers[Opcode.LDCONST.ordinal]       = &th_ldconst;
    g_threaded_handlers[Opcode.LDUNDEF.ordinal]       = &th_ldundef;
    g_threaded_handlers[Opcode.TRY.ordinal]           = &th_try;
    g_threaded_handlers[Opcode.ENDTRY.ordinal]        = &th_endtry;
    g_threaded_handlers[Opcode.ITER_NEXT_FAST.ordinal] = &th_iter_next_intrinsic;
    g_threaded_handlers[Opcode.TONUMERIC.ordinal]     = &th_tonumeric;

    // --- Property access: IC hit path (bench_object / bench_property_lookup) ---
    g_threaded_handlers[Opcode.GETPROP.ordinal]         = &th_getprop_array;
    g_threaded_handlers[Opcode.GETPROP_CACHE.ordinal]   = &th_getprop_array;
    g_threaded_handlers[Opcode.GETPROPC.ordinal]        = &th_getpropc;
    g_threaded_handlers[Opcode.GETPROPC_CACHED.ordinal] = &th_getpropc_cached;
    g_threaded_handlers[Opcode.PUTPROP.ordinal]         = &th_putprop;
    g_threaded_handlers[Opcode.PUTPROPC.ordinal]        = &th_putpropc;
    g_threaded_handlers[Opcode.INITPROP.ordinal]        = &th_initprop_array;
    g_threaded_handlers[Opcode.INITELEM.ordinal]        = &th_initelem;
    g_threaded_handlers[Opcode.NEWARR.ordinal]          = &th_newarr;
    g_threaded_handlers[Opcode.NEWOBJ.ordinal]          = &th_newobj;
    g_threaded_handlers[Opcode.NEWOBJ_SHAPE.ordinal]    = &th_newobj;
    g_threaded_handlers[Opcode.INIT_SLOT.ordinal]        = &th_init_slot;
}

// Bail: return the resume pc WITHOUT consuming *pc -- the switch loop
// re-decodes it.
fn Instruction* th_bailout(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) @noinline {
    return pc;
}

// There is no fall-off-the-end test: the compiler ends every function with an
// explicit RET or RETUNDEF, which the switch loop also relies on.
macro Instruction* th_next(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction next = *pc;
    // Tail call -> indirect tail jump at -O2.
    return g_threaded_handlers[next.op.ordinal](pc, code_end, regs, cold);
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
// landed. No handler is the one-compare fast path; with one installed, a bail
// hands the due poll to the switch site, whose decrement is the one that
// fires.
macro bool th_bwd_edge_needs_safepoint(ColdCtx* cold) {
    vm_charge_interrupt(cold.heap);
    // The interrupt budget runs down inside the burst too. Threaded dispatch
    // consumes the vast majority of back-edges, so a poll that waited for a
    // switch visit would fire roughly BWD_GC_INTERVAL times too rarely, and a
    // runaway loop could run millions of iterations before the host's abort
    // landed. Charging here (and bailing on the due flag) holds the poll
    // cadence at INTERRUPT_BUDGET_INIT back-edges in both dispatch modes; no
    // handler installed is the one-compare fast path.
    if (cold.heap.interrupt_due) return true;
    return cold.heap.bwd_gc_budget <= 1;
}

fn Instruction* th_addi(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) return pc;
    TVal* ra = regs + insn.a;
    long sum = rb.get_fastint() + (long)(ichar)insn.c;
    if (!types::fits_fastint(sum) || !th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_fastint(sum);
    return th_next(pc + 1, code_end, regs, cold);
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

fn Instruction* th_ldreg(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal value = regs[insn.b];
    TVal* ra = regs + insn.a;
    if (!th_can_publish(cold.heap, value) || !th_can_release(ra)) return pc;
    th_do_retain(&value);
    th_do_release(ra);
    *ra = value;
    track_heap_store(cold.act, ra, (uint)insn.a);
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_ldthis(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
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
    return th_next(pc, code_end, regs, cold);
}

// TRY and ENDTRY mirror dispatch_exceptions: push a catcher on entry and pop a
// finally-less one on normal exit. The catcher never allocates on the hot path
// (see catcher_acquire); an exhausted allocator falls back to the switch.
fn Instruction* th_try(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    if (pc + 1 >= code_end) return pc;
    Instruction insn = *pc;
    uint finally_offset = pc[1].get_bc();
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
    return th_next(pc + 2, code_end, regs, cold);
}

fn Instruction* th_endtry(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Activation* act = cold.act;
    Catcher* cat = (Catcher*)act.cat;
    if (cat != null && cat.finally_pc == null) {
        act.cat = (void*)cat.parent;
        catcher_release(cold.heap, cat);
    }
    return th_next(pc + 1, code_end, regs, cold);
}

// Keep guarded built-in iterator steps in threaded dispatch. Refusals return
// the original PC so the switch runs ITER_NEXT_FAST's full guard and protocol
// fallback. Array completion stays on the switch path because it releases the
// iterator target there; string completion has no owned target to release.
fn Instruction* th_iter_next_intrinsic(Instruction* pc, Instruction* code_end,
                                       TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    if (insn.a == insn.b || insn.a == insn.c) return pc;
    TVal* iterator_slot = regs + insn.b;
    TVal* next_slot = regs + insn.c;
    if (!iterator_slot.is_object() || !next_slot.is_object()) return pc;
    HObject* iterator = (HObject*)iterator_slot.get_heapptr();
    HObject* next_fn = (HObject*)next_slot.get_heapptr();
    if (iterator == null || iterator.flags.exotic_proxyobj
        || next_fn == null || !next_fn.is_callable()
        || next_fn.callable_kind() != hobject::CallableKind.BUILTIN_FN) return pc;

    int next_index = (*next_fn.extra_ptr()).func.builtin_fn_index;
    if (iterator.flags.obj_class == hobject::ObjClass.STRING_ITERATOR) {
        if (next_index != (int)builtins::Builtin.STRING_ITERATOR_NEXT.ordinal) return pc;
        hstring::HString* source = (*iterator.extra_ptr()).str_iter.string.borrow();
        if (source == null) return pc;
        uint index = (*iterator.extra_ptr()).str_iter.index;
        char[] data = source.get_data();
        if (index >= data.len) return th_next(pc + 2, code_end, regs, cold);

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
        return th_next(pc + 3, code_end, regs, cold);
    }

    if (iterator.flags.obj_class != hobject::ObjClass.ARRAY_ITERATOR
        || next_index != (int)builtins::Builtin.ARRAY_ITERATOR_NEXT.ordinal
        || (*iterator.extra_ptr()).iter.kind != 0) return pc;

    HObject* target = (*iterator.extra_ptr()).iter.target;
    if (target == null || target.flags.obj_class != hobject::ObjClass.ARRAY
        || target.flags.exotic_proxyobj || target.flags.has_indexed_named_prop
        || target.array_part() == null) return pc;

    uint index = (*iterator.extra_ptr()).iter.index;
    if (index >= *target.array_len_ptr() || index >= target.array_size) return pc;
    TVal value = target.array_part()[index].get();
    if (!value.is_fastint() && !value.is_number()) return pc;

    TVal* dest = regs + insn.a;
    if (!th_can_release(dest)) return pc;
    th_do_release(dest);
    *dest = value;
    (*iterator.extra_ptr()).iter.index = index + 1;

    // The third jump after ITER_NEXT_FAST goes to this step's consumer. It
    // handles for-of, destructuring elements, and array-rest collection.
    return th_next(pc + 3, code_end, regs, cold);
}

// Keep the existing guarded one-argument Array.prototype.push shortcut in
// threaded dispatch. The switch owns call safepoints, so pending GC work makes
// this handler bail before the array is mutated.
fn Instruction* th_call_push_one(Instruction* pc, Instruction* code_end,
                                 TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    if (insn.c != 1 || cold.heap.gc_pending) return pc;

    TVal callee = regs[insn.b];
    if (!callee.is_object()) return pc;
    HObject* function = (HObject*)callee.get_heapptr();
    if (function == null || !function.is_callable()
        || function.callable_kind() != hobject::CallableKind.BUILTIN_FN
        || (*function.extra_ptr()).func.builtin_fn_index
            != (int)builtins::Builtin.ARRAY_PROTO_PUSH.ordinal) return pc;

    TVal receiver = regs[insn.b + 1];
    TVal value = regs[insn.b + 2];
    if (!receiver.is_object() || receiver.get_heapptr() == null) return pc;
    TVal* result = regs + insn.a;
    if (!th_can_release(result)) return pc;

    long new_length = builtins::array_push_one_fast((HObject*)receiver.get_heapptr(), value, cold.heap);
    if (new_length < 0) return pc;

    th_do_release(result);
    result.set_fastint(new_length);
    return th_next(pc + 1, code_end, regs, cold);
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
    if (vm.heap.gc_pending || vm.heap.gc_phase == heap::GcPhase.MARK) return true;
    if (++cold.call_burst < TH_CALL_BURST) return false;
    cold.call_burst = 0;
    return true;
}

// The lean compiled function `callee` names, or null when the call must take
// the general entry: not a compiled function, not (yet) classified lean, a
// `with` scope to splice, no activation slot or value-stack room for the frame.
// `bottom` is the callee's register window; `plain` says the receiver is
// undefined, which only a strict or this-ignoring callee can take as is.
fn CompiledFunction* th_lean_target(Vm* vm, TVal callee, TVal* bottom, bool plain) @private @inline {
    if (!callee.is_object()) return null;
    HObject* function = (HObject*)callee.get_heapptr();
    if (function == null || !function.is_callable()
        || function.callable_kind() != hobject::CallableKind.COMPILED_FN) return null;
    HObjectFunction* fd = &(*function.extra_ptr()).func;
    CompiledFunction* target = fd.comp_func;
    if (target == null || !(plain ? target.call_flags.lean_plain : target.call_flags.lean_call)) return null;
    // A function's first run goes through the switch, which creates its caches.
    if (target.ic_entries == null) return null;
    EnvRecord* cap = fd.lex_env;
    if (fd.var_env == null || (cap != null && cap.flags.is_with)
        || vm.activation_count >= vm.activation_capacity
        || (uint)(bottom - vm.valstack) + target.num_regs
            > (uint)(vm.valstack_end - vm.valstack)) return null;
    return target;
}

// Push the frame of a lean call and continue in its body. The caller has
// checked th_lean_target and th_call_gate, and has stored the callee in
// register `callee_reg`; `borrowed` says the register holds a binding's value
// without a reference of its own (see ACT_FLAG_BORROWED_CALLEE). A receiver
// object stays in the caller's tracked register and the frame borrows it
// (`this_valid`), so a method call has nothing to retain or release.
fn Instruction* th_enter_lean(Instruction* pc, Instruction* code_end, TVal* regs,
                              ColdCtx* cold, CompiledFunction* target,
                              uint callee_reg, uint result_reg, uint nargs,
                              bool borrowed, bool clear_this,
                              TVal this_value, bool this_valid) @private @inline {
    Vm* vm = cold.vm;
    Activation* caller = cold.act;
    HObject* function = (HObject*)regs[callee_reg].get_heapptr();
    HObjectFunction* fd = &(*function.extra_ptr()).func;
    EnvRecord* env = fd.var_env;
    EnvRecord* cap = fd.lex_env;
    uint nregs = target.num_regs;
    TVal* bottom = regs + callee_reg + 2;

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
    la.new_target = null;
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

    caller.curr_pc = pc + 1;
    vm.valstack_top = bottom + nregs;
    vm.valstack_bottom = bottom;
    cold.act = la;
    *cold.regs_base_ptr = bottom;
    Instruction* body_end = code_end;
    if (target != vm.current_func) {
        vm.current_func = target;
        Dispatch* dispatch = (Dispatch*)cold.dispatch_ptr;
        dispatch.code_base = target.code;
        dispatch.code_count = target.code_count;
        dispatch.code_end = target.code + target.code_count;
        dispatch.constants = target.constants;
        dispatch.ic_base = (hobject::ICEntry*)target.ic_entries;
        dispatch.var_ic_base = (hobject::VarICEntry*)target.var_ic_entries;
        dispatch.nregs = nregs;
        body_end = dispatch.code_end;
    }
    return th_next(target.code, body_end, bottom, cold);
}

// A method call (`CALL`) on an object receiver the caller's frame tracks, or on
// a receiver that is not a heap value and a callee that never reads its `this`.
// The receiver stays in the caller's register, which roots it for the whole
// call, so the frame borrows it as its this_binding.
fn Instruction* th_call(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    CompiledFunction* target = th_lean_target(vm, regs[insn.b], regs + insn.b + 2, false);
    if (target == null) return th_call_push_one(pc, code_end, regs, cold);
    TVal receiver = regs[insn.b + 1];
    bool this_valid = false;
    TVal this_value = th_undefined();
    if (receiver.is_heap_allocated()) {
        if (!receiver.is_object() || receiver.get_heapptr() == null
            || insn.b + 1 >= vm.current_func.num_regs
            || cold.act.heap_reg_count <= insn.b + 1) return pc;
        if (!target.call_flags.ignores_this) {
            this_value = receiver;
            this_valid = true;
        }
    } else if (!target.call_flags.ignores_this) {
        return pc;
    }
    if (th_call_gate(cold)) return pc;
    return th_enter_lean(pc, code_end, regs, cold, target, insn.b, insn.a, insn.c, false, false,
                         this_value, this_valid);
}

fn Instruction* th_call_undef_this(Instruction* pc, Instruction* code_end,
                                   TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    if (th_call_gate(cold)) return pc;
    CompiledFunction* target = th_lean_target(vm, regs[insn.b], regs + insn.b + 2, true);
    if (target == null) return pc;
    return th_enter_lean(pc, code_end, regs, cold, target, insn.b, insn.a, insn.c, false, true, th_undefined(), false);
}

// The variable IC entry for the instruction at `pc` when it still describes the
// binding it was filled for: same lex_env chain head, and a bindings object
// whose shape id still names the shape it had then. The epoch check keeps a
// recycled shape id from vouching for a different layout. Null sends the
// handler to the switch.
macro hobject::VarICEntry* th_var_ic_hit(Instruction* pc, ColdCtx* cold) @private {
    hobject::VarICEntry* vic = th_ic_entry(pc, cold);
    if (vic == null || vic.search_head != (void*)cold.act.lex_env) return null;
    return th_ic_shape_hit(vic, cold);
}

// The same for a GETGLOBAL-family instruction. Global-scope code is compiled
// for one run and executes in a single activation, so its lex_env never
// differs from the one the entry was filled under and needs no compare. The
// epoch is read from the heap rather than ColdCtx because a handler can move a
// bound object's storage and then fall through to the next one.
macro hobject::VarICEntry* th_global_ic_hit(Instruction* pc, ColdCtx* cold) @private {
    hobject::VarICEntry* base = cold.var_ic_base;
    if (base == null) return null;
    hobject::VarICEntry* vic = base + (uint)(pc - cold.code_base);
    return (vic.recycle_epoch == cold.heap.shape_recycle_epoch && vic.slot_ptr != null) ? vic : null;
}

macro hobject::VarICEntry* th_ic_entry(Instruction* pc, ColdCtx* cold) @private {
    hobject::VarICEntry* base = cold.var_ic_base;
    return base == null ? null : base + (uint)(pc - cold.code_base);
}

macro hobject::VarICEntry* th_ic_shape_hit(hobject::VarICEntry* vic, ColdCtx* cold) @private {
    HObject* b = (HObject*)vic.bindings;
    if (b == null || b.shape_id != vic.shape_id || cold.shape_epoch != vic.recycle_epoch) return null;
    return vic;
}

fn Instruction* th_call_var(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    if (th_call_gate(cold)) return pc;
    hobject::VarICEntry* vic = th_var_ic_hit(pc, cold);
    if (vic == null || vic.prop_flags.is_accessor) return pc;
    TVal callee = vic.slot().get();
    if (env::is_tdz_sentinel(&callee)) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    CompiledFunction* target = th_lean_target(vm, callee, regs + insn.a + 2, true);
    if (target == null) return pc;
    // An object callee is not counted, so storing it needs no retain; a
    // binding that is not permanent can be reassigned during the call, so the
    // register is tracked and the frame roots its own reference.
    bool borrowed = is_permanent_env(vm, (EnvRecord*)vic.env);
    th_do_release(ra);
    *ra = callee;
    if (!borrowed) track_heap_store(act, ra, insn.a);
    return th_enter_lean(pc, code_end, regs, cold, target, insn.a, insn.a, insn.b, borrowed, true, th_undefined(), false);
}

fn Instruction* th_call_global(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
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
    th_do_release(ra);
    *ra = callee;
    return th_enter_lean(pc, code_end, regs, cold, target, insn.a, insn.a, insn.b, true, true, th_undefined(), false);
}

fn Instruction* th_ldint(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_fastint((long)insn.get_sbc());
    pc++;
    if (pc < code_end) {
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
                if (array != null && !array.flags.exotic_proxyobj
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
                                return th_next(pc + 1, code_end, regs, cold);
                            }
                        }
                    }
                }
            }
        }
    }
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_subi(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) return pc; // bigint / coercion / throw -> switch
    TVal* ra = regs + insn.a;
    long diff = rb.get_fastint() - (long)(ichar)insn.c;
    if (!types::fits_fastint(diff) || !th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_fastint(diff);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_incdec(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    TVal* value = regs + pc.a;
    if (!value.is_fastint()) return pc;
    long next = value.get_fastint() + (pc.op == Opcode.INC ? 1L : -1L);
    if (!types::fits_fastint(next)) return pc;
    value.set_fastint(next);
    return th_next(pc + 1, code_end, regs, cold);
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

// The concatenations that need no coercion. Any other operand pair, and a
// result past the string length cap, leave the registers alone and go to the
// switch, which coerces or raises the RangeError.
fn Instruction* th_add_concat(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    ConcatStatus status = vm_concat_add(cold.vm, cold.act, regs + insn.a, regs + insn.b, regs + insn.c,
                                        (uint)insn.a, pc + 1, code_end);
    if (status != ConcatStatus.DONE) return pc;
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_add(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    TVal* ra = regs + insn.a;
    if (types::both_fastint(rb, rc)) {
        long sum = rb.get_fastint() + rc.get_fastint();
        if (!types::fits_fastint(sum) || !th_can_release(ra)) return pc;
        th_do_release(ra);
        ra.set_fastint(sum);
        return th_next(pc + 1, code_end, regs, cold);
    }
    // Object ToPrimitive and BigInt use the switch. A double operand is
    // handled here too: adding two numbers cannot call user code or throw, so
    // there is nothing for the switch's coercion machinery to guard.
    double x; double y;
    if (!th_numeric_operand(rb, &x) || !th_numeric_operand(rc, &y)) {
        return th_add_concat(pc, code_end, regs, cold);
    }
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_number(x + y);
    return th_next(pc + 1, code_end, regs, cold);
}

// EQ, NEQ, SEQ and SNEQ agree on the operands decided here, so one handler
// serves all four: two fastints compare by value, any other pair of equal
// non-number bit patterns is the same value, and two distinct interned strings
// differ. Everything else, including numbers (NaN) and the coercing cases of
// the loose forms, goes to the switch.
fn Instruction* th_eq(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    TVal* ra = regs + insn.a;
    bool equal;
    if (rb.same_bits(rc) && !rb.is_number()) {
        equal = true;
    } else if (types::both_fastint(rb, rc)) {
        equal = false;
    } else if (rb.is_string() && rc.is_string()
               && ((HString*)rb.get_heapptr()).flags.is_interned
               && ((HString*)rc.get_heapptr()).flags.is_interned) {
        equal = false;
    } else {
        return pc;
    }
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_boolean(equal != (insn.op == Opcode.NEQ || insn.op == Opcode.SNEQ));
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_sub(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    TVal* ra = regs + insn.a;
    if (types::both_fastint(rb, rc)) {
        long diff = rb.get_fastint() - rc.get_fastint();
        if (!types::fits_fastint(diff) || !th_can_release(ra)) return pc;
        th_do_release(ra);
        ra.set_fastint(diff);
        return th_next(pc + 1, code_end, regs, cold);
    }
    double x; double y;
    if (!th_numeric_operand(rb, &x) || !th_numeric_operand(rc, &y)) return pc;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_number(x - y);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_mul(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
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
        return th_next(pc + 1, code_end, regs, cold);
    }
    double x; double y;
    if (!th_numeric_operand(rb, &x) || !th_numeric_operand(rc, &y)) return pc;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_number(x * y);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_muli(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
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
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_mod(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
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
    return th_next(pc + 1, code_end, regs, cold);
}

// Bitwise operators on fastint operands. ToInt32 of an integer is its low 32
// bits, which the (int) cast takes directly.
macro Instruction* th_bitop($op, $imm, Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) @private {
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
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_band(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BAND, false, pc, code_end, regs, cold);
}
fn Instruction* th_bandi(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BAND, true, pc, code_end, regs, cold);
}
fn Instruction* th_bor(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BOR, false, pc, code_end, regs, cold);
}
fn Instruction* th_bori(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BOR, true, pc, code_end, regs, cold);
}
fn Instruction* th_bxor(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BXOR, false, pc, code_end, regs, cold);
}
fn Instruction* th_bxori(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.BXOR, true, pc, code_end, regs, cold);
}
fn Instruction* th_shl(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.SHL, false, pc, code_end, regs, cold);
}
fn Instruction* th_shli(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.SHL, true, pc, code_end, regs, cold);
}
fn Instruction* th_shr(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.SHR, false, pc, code_end, regs, cold);
}
fn Instruction* th_shri(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.SHR, true, pc, code_end, regs, cold);
}
fn Instruction* th_ushr(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.USHR, false, pc, code_end, regs, cold);
}
fn Instruction* th_ushri(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_bitop(Opcode.USHR, true, pc, code_end, regs, cold);
}

// A constant copies like the switch's counted copy.
fn Instruction* th_ldconst(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Dispatch* ds = (Dispatch*)cold.dispatch_ptr;
    uint bc = insn.get_bc();
    // The compiler only emits operands inside the constant table, and the safe
    // builds keep this check.
    assert(bc < cold.vm.current_func.const_count);
    TVal value = ds.constants[bc];
    if (!th_can_publish(cold.heap, value)) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    th_do_retain(&value);
    th_do_release(ra);
    *ra = value;
    if (value.is_heap_allocated()) track_heap_store(cold.act, ra, (uint)insn.a);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_ldundef(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    TVal* ra = regs + pc.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    ra.set_undefined();
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_jump(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    // Unconditional relative jump (sABC). No try-finally interception (that is
    // BREAK/CONTINUE, not JUMP). Backward jumps charge the GC safepoint budget.
    int off = insn.get_sabc();
    if (off < 0) {
        if (th_bwd_edge_needs_safepoint(cold)) return pc;
        cold.heap.bwd_gc_budget--;
    }
    pc += (sz)(1 + off);
    return th_next(pc, code_end, regs, cold);
}

// Take or skip a fused compare-and-branch. A backward branch charges the GC
// safepoint budget and bails when it is due.
macro Instruction* th_branch_if(bool take, Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) @private {
    if (take) {
        if ((ichar)pc.a < 0) {
            if (th_bwd_edge_needs_safepoint(cold)) return pc;
            cold.heap.bwd_gc_budget--;
        }
        pc += (sz)(1 + (int)(ichar)pc.a);
    } else {
        pc++;
    }
    return th_next(pc, code_end, regs, cold);
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
macro Instruction* th_cmp_branch_impl($imm, Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) @private {
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
        } else {
            return pc;
        }
        uint first = Opcode.JMP_NLT.ordinal;
    $endif
    if (((CMP_BRANCH_ON[insn.op.ordinal - first] >> order) & 1) != 0) {
        if ((ichar)insn.a < 0) {
            if (th_bwd_edge_needs_safepoint(cold)) return pc;
            cold.heap.bwd_gc_budget--;
        }
        pc += (sz)(1 + (int)(ichar)insn.a);
    } else {
        pc++;
    }
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_cmp_branch(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_cmp_branch_impl(false, pc, code_end, regs, cold);
}
fn Instruction* th_cmp_branch_i(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_cmp_branch_impl(true, pc, code_end, regs, cold);
}

// One relation's fastint-pair path. `$on` is that opcode's CMP_BRANCH_ON row,
// so the outcome test folds to a single compare; a pair that is not two
// fastints takes the shared handler.
macro Instruction* th_cmp_fast($imm, $on, Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) @private {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) return th_cmp_branch_impl($imm, pc, code_end, regs, cold);
    long x = rb.get_fastint();
    long y;
    $if $imm:
        y = (long)(ichar)insn.c;
    $else
        TVal* rc = regs + insn.c;
        if (!rc.is_fastint()) return th_cmp_branch_impl($imm, pc, code_end, regs, cold);
        y = rc.get_fastint();
    $endif
    bool take = ((($on >> ORDER_LT) & 1) != 0 && x < y)
             || ((($on >> ORDER_EQ) & 1) != 0 && x == y)
             || ((($on >> ORDER_GT) & 1) != 0 && x > y);
    return th_branch_if(take, pc, code_end, regs, cold);
}

fn Instruction* th_jmp_lt(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b0001, pc, code_end, regs, cold);
fn Instruction* th_jmp_le(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b0011, pc, code_end, regs, cold);
fn Instruction* th_jmp_gt(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b0100, pc, code_end, regs, cold);
fn Instruction* th_jmp_ge(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b0110, pc, code_end, regs, cold);
fn Instruction* th_jmp_nlt(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b1110, pc, code_end, regs, cold);
fn Instruction* th_jmp_nle(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b1100, pc, code_end, regs, cold);
fn Instruction* th_jmp_ngt(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b1011, pc, code_end, regs, cold);
fn Instruction* th_jmp_nge(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(false, 0b1001, pc, code_end, regs, cold);
fn Instruction* th_jmp_lti(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b0001, pc, code_end, regs, cold);
fn Instruction* th_jmp_lei(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b0011, pc, code_end, regs, cold);
fn Instruction* th_jmp_gti(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b0100, pc, code_end, regs, cold);
fn Instruction* th_jmp_gei(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b0110, pc, code_end, regs, cold);
fn Instruction* th_jmp_nlti(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b1110, pc, code_end, regs, cold);
fn Instruction* th_jmp_nlei(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b1100, pc, code_end, regs, cold);
fn Instruction* th_jmp_ngti(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b1011, pc, code_end, regs, cold);
fn Instruction* th_jmp_ngei(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) => th_cmp_fast(true, 0b1001, pc, code_end, regs, cold);

// --- Global-slot access (perf-all VarRef fast path). ---
//
// pc points at the current instruction, so the IC slot is pc - code_base.
// A hit validates the binding object and shape before reading its slot.

fn Instruction* th_getglobal(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
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
        return th_next(pc + 1, code_end, regs, cold);
    }
    if (env::is_tdz_sentinel(&value)) return pc; // TDZ -> switch throws
    if (value.is_inert() && !ra.is_refcounted()) {
        *ra = value;
        return th_next(pc + 1, code_end, regs, cold);
    }
    if (!th_can_publish(cold.heap, value)) return pc;
    // Traced objects have no refcount; only the register's heap-root span changes.
    if (value.is_object() && !ra.is_refcounted()) {
        *ra = value;
        track_heap_store(cold.act, ra, (uint)insn.a);
        return th_next(pc + 1, code_end, regs, cold);
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
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_putglobal(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    hobject::VarICEntry* gic = th_global_ic_hit(pc, cold);
    // Only writable non-configurable data globals (varref_store_ok) may take
    // the re-check-free store path -- exactly the switch's fast-path gate.
    if (gic == null || !gic.varref_store_ok) return pc;
    TVal* ra = regs + insn.a;
    hobject::PropValue* slot = gic.slot_ptr;
    // Only a traced source needs a barrier, and only a string needs release.
    if (ra.is_traced() || slot.get().is_refcounted()) {
        return th_putglobal_move(pc, code_end, regs, cold, (HObject*)gic.bindings, slot);
    }
    *slot = (hobject::PropValue)*ra;
    ra.set_undefined();
    return th_next(pc + 1, code_end, regs, cold);
}

// The barrier and release path of a global store, out of line so the
// handler's hit path stays a leaf with no frame.
fn Instruction* th_putglobal_move(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold,
                                  HObject* owner, hobject::PropValue* slot) @noinline {
    cold.heap.tval_move_slot_fast(owner, slot, regs + pc.a);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_inc_global_impl(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, bool is_inc) {
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
    if (pc < code_end && pc.op == Opcode.GETGLOBAL && pc.a == insn.a && pc.get_bc() == insn.get_bc()) pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_inc_global(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_inc_global_impl(pc, code_end, regs, cold, true);
}

fn Instruction* th_dec_global(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    return th_inc_global_impl(pc, code_end, regs, cold, false);
}

// --- Variable access: VarIC (shape and recycle-epoch) hit path only. ---

fn Instruction* th_getcap(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    hobject::PropValue* slot = capture_value_slot(cold.act, pc.get_bc(), cold.heap);
    if (slot == null) return pc;
    TVal value = slot.get();
    TVal* dst = regs + pc.a;
    if (!th_can_publish(cold.heap, value)
        || !th_can_release(dst)) return pc;
    th_do_retain(&value);
    th_do_release(dst);
    *dst = value;
    track_heap_store(cold.act, dst, (uint)pc.a);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_putcap(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    uint capture_index = pc.op == Opcode.PUTCAP_SNAP ? pc.c : pc.get_bc();
    HObject* owner;
    hobject::PropValue* slot = capture_value_slot(cold.act, capture_index, cold.heap, true, &owner);
    if (slot == null || !th_can_release_slot(slot)) return pc;
    TVal* src = regs + pc.a;
    th_do_release_slot(slot);
    cold.heap.store_slot(owner, slot, *src);
    src.set_undefined();
    return th_next(pc + 1, code_end, regs, cold);
}

// The dense slot a cell instruction names, and in `owner` the cells object
// that holds it, which a store needs for the write barrier.
fn hobject::PropValue* th_cell_slot(Instruction* pc, TVal* regs, HObject** owner) @private @inline {
    TVal* owner_val = regs + pc.b;
    if (!owner_val.is_object()) return null;
    HObject* cells = (HObject*)owner_val.get_heapptr();
    uint slot_idx = (uint)pc.c;
    if (cells == null || cells.get_class() != hobject::ObjClass.OBJECT
        || cells.array_part() == null || slot_idx >= cells.array_size) return null;
    *owner = cells;
    return &cells.array_part()[slot_idx];
}

fn Instruction* th_getcell(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
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
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_setcell(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    HObject* owner;
    hobject::PropValue* slot = th_cell_slot(pc, regs, &owner);
    TVal* src = regs + pc.a;
    if (slot == null || !th_can_release_slot(slot)) return pc;
    th_do_retain(src);
    th_do_release_slot(slot);
    cold.heap.store_slot(owner, slot, *src);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_movecell(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    HObject* owner;
    hobject::PropValue* slot = th_cell_slot(pc, regs, &owner);
    TVal* src = regs + pc.a;
    if (slot == null || !th_can_release_slot(slot)) return pc;
    th_do_release_slot(slot);
    cold.heap.store_slot(owner, slot, *src);
    src.set_undefined();
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_getvar(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    hobject::VarICEntry* vic = th_var_ic_hit(pc, cold);
    if (vic == null || vic.prop_flags.is_accessor) return pc; // getter -> switch
    TVal v = vic.slot().get();
    if (env::is_tdz_sentinel(&v)) return pc; // TDZ error -> switch
    TVal* ra = regs + insn.a;
    // Keep this handler a LEAF. Calling out to Heap.decref makes LLVM frame the
    // whole function: five stp/ldp pairs saving ten callee-saved registers,
    // paid on EVERY variable read. That prologue was most of this handler's
    // cost -- 163 instructions against th_addi's 34, on what should be a load.
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
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_putvar_assign(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    hobject::VarICEntry* vic = th_var_ic_hit(pc, cold);
    if (vic == null) return pc;
    hobject::PropValue* pv = vic.slot();
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
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_putvar_snap_number(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* value = regs + insn.a;
    TVal* probe = regs + insn.b;
    if ((!value.is_fastint() && !value.is_number()) || !probe.is_envref()) return pc;
    env::EnvRecord* owner = (env::EnvRecord*)probe.get_heapptr();
    if (owner == null || !owner.flags.is_declarative || owner.flags.is_with) return pc;
    if (cold.var_ic_base == null) return pc;
    hobject::VarICEntry* vic = cold.var_ic_base + (uint)(pc - cold.code_base);
    // The captured owner, rather than the current scope head, identifies the
    // binding even when evaluation of the RHS changes name resolution.
    if (vic.env != (void*)owner || vic.bindings != (void*)owner.bindings) return pc;
    HObject* bindings = owner.bindings;
    if (bindings.shape_id != vic.shape_id
        || cold.heap.shape_recycle_epoch != vic.recycle_epoch) return pc;
    hobject::PropFlags flags = vic.prop_flags;
    if (!flags.writable || flags.is_accessor) return pc;
    hobject::PropValue* slot = &bindings.prop_values()[vic.prop_idx];
    if (!slot.get().is_fastint() && !slot.get().is_number()) return pc;
    slot.set_untraced(*value);
    value.set_undefined();
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_inc_var(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    Activation* act = cold.act;
    hobject::VarICEntry* vic = th_var_ic_hit(pc, cold);
    if (vic == null) return pc;
    hobject::PropValue* slot = vic.slot();
    TVal old_val = slot.get();
    if (!old_val.is_fastint() || !vic.prop_flags.writable) return pc;
    long next = old_val.get_fastint() + 1L;
    TVal* ra = regs + insn.a;
    if (!types::fits_fastint(next) || !th_can_release(ra)) return pc;
    th_do_release(ra);
    slot.set_fastint(next);
    ra.set_fastint(next);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_tonumeric(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
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

// The ICEntry for the instruction at `pc`, or null when the function carries
// no IC array.
macro hobject::ICEntry* th_ic_at(ColdCtx* cold, Instruction* pc) {
    hobject::ICEntry* base = cold.ic_base;
    return base == null ? null : base + (uint)(pc - cold.code_base);
}

fn Instruction* th_getprop_array(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    if (!rb.is_object() || !rc.is_fastint()) return pc;
    HObject* obj = (HObject*)rb.get_heapptr();
    if (obj.flags.exotic_proxyobj || obj.get_class() != hobject::ObjClass.ARRAY) return pc;
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
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_getpropc(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    TVal* rb = regs + insn.b;
    void* key = vm.current_func.constants[(uint)insn.c].get_heapptr();
    HObject* hobj;
    if (rb.is_object()) {
        hobj = (HObject*)rb.get_heapptr();
        // Proxy [[Get]] can run a trap, so it never reaches the cache.
        if (hobj.flags.exotic_proxyobj) return pc;
    } else {
        // A string primitive reads through String.prototype, whose entry the
        // switch filled. `length` and indexed keys are the string's own
        // properties and stay in the switch.
        HString* str = (HString*)rb.get_heapptr();
        if (!rb.is_string() || str.is_symbol() || key == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]
            || ((HString*)key).is_arridx()) return pc;
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
        return th_next(pc, code_end, regs, cold);
    }
    hobject::ICEntry* ic = th_ic_at(cold, pc);
    if (ic == null) return pc;
    if (ic.key.borrow() != key || ic.shape_id != hobj.shape_id
        || ic.shape_gen != hobj.live_shape_generation(cold.heap)) return pc;
    hobject::PropValue* ic_value = hobject::ic_resolve_value(ic, hobj);
    if (ic_value == null) return pc;
    TVal ic_val = ic_value.get();
    TVal* ra = regs + insn.a;
    if (ic_val.is_fastint() && ra.is_fastint()) {
        *ra = ic_val;
        return th_next(pc + 1, code_end, regs, cold);
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
    return th_next(pc, code_end, regs, cold);
}

// GETPROPC_CACHED, the warm form GETPROPC rewrites itself into. The key is
// implied by the site, so only the shape and resolved value slot are checked;
// a miss bails so the switch performs the downgrade back to GETPROPC.
fn Instruction* th_getpropc_cached(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    Vm* vm = cold.vm;
    TVal* rb = regs + insn.b;
    if (!rb.is_object()) return pc;
    HObject* hobj = (HObject*)rb.get_heapptr();
    hobject::ICEntry* ic = th_ic_at(cold, pc);
    if (ic == null) return pc;
    if (ic.shape_id != hobj.shape_id || ic.shape_gen != hobj.live_shape_generation(cold.heap)) return pc;
    hobject::PropValue* ic_value = hobject::ic_resolve_value(ic, hobj);
    if (ic_value == null) return pc;
    TVal ic_val = ic_value.get();
    TVal* ra = regs + insn.a;
    if (ic_val.is_fastint() && ra.is_fastint()) {
        *ra = ic_val;
        return th_next(pc + 1, code_end, regs, cold);
    }
    if (!th_can_publish(vm.heap, ic_val)) return pc;
    if (!ic_val.is_heap_allocated()) {
        if (!th_can_release(ra)) return pc;
        th_do_release(ra);
        *ra = ic_val;
    } else {
        // Same inline-refcount pattern as th_getpropc above.
        if (!th_can_release(ra)) return pc;
        th_do_retain(&ic_val);
        th_do_release(ra);
        *ra = ic_val;
        track_heap_store(cold.act, ra, (uint)insn.a);
    }
    pc++;
    return th_next(pc, code_end, regs, cold);
}

// The reference-counted and traced half of a slot store. It is a tail call from
// the handler, so the handler itself makes no call and needs no frame.
//
// The barrier takes the address of a local, which would keep a store inlined
// here from ending in a tail call, so the store is its own function.
fn void th_store_slot_ref(Vm* vm, HObject* hobj, hobject::PropValue* slot, TVal* value) @private @noinline {
    vm.heap.store_slot_ref(hobj, slot, value);
}

fn Instruction* th_store_slot_ref_next(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold,
                                       HObject* hobj, hobject::PropValue* slot, TVal* value) @private @noinline {
    th_store_slot_ref(cold.vm, hobj, slot, value);
    return th_next(pc + 1, code_end, regs, cold);
}

// The reference-counted and traced half of an absent-property append, out of
// line for the same reason as th_store_slot_ref_next. A full property table
// bails to the switch, which grows it.
fn Instruction* th_append_ref_next(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold,
                                   HObject* hobj, hobject::ICEntry* ic, TVal* value) @private @noinline {
    if (!hobj.append_cached_prop(ic, *value, cold.heap)) return pc;
    return th_next(pc + 1, code_end, regs, cold);
}

// A store of a key the receiver and its whole prototype chain lack, the shape of
// every constructor's `this.x = x`. The cache holds the shape the append moves
// to, so a hit needs no lookup of the key or of the transition.
fn Instruction* th_put_absent(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold,
                              HObject* hobj, hobject::ICEntry* ic, void* key, TVal* value) @private @inline {
    if (!hobject::ic_matches_absent_put(ic, hobj, key, cold.heap)) return pc;
    if (value.is_heap_allocated()) return th_append_ref_next(pc, code_end, regs, cold, hobj, ic, value);
    if (hobj.prop_count >= hobj.prop_capacity || hobj.prop_hash != null) return pc;
    hobject::PropValue* slot = &hobj.prop_values()[hobj.prop_count];
    *slot = (hobject::PropValue)*value;
    hobj.prop_count++;
    hobj.shape_id = ic.absent_next_shape;
    return th_next(pc + 1, code_end, regs, cold);
}

// The cached store shared by PUTPROP and PUTPROPC: `key` is the interned
// string the instruction names, `value` the register being stored.
fn Instruction* th_put_cached(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold,
                              TVal* target, void* key, TVal* value) @private @inline {
    Vm* vm = cold.vm;
    if (!target.is_object()) return pc;
    HObject* hobj = (HObject*)target.get_heapptr();
    if (hobj.get_class() != hobject::ObjClass.OBJECT
        || hobj.flags.exotic_proxyobj || hobj.flags.exotic_module_ns) return pc;
    hobject::ICEntry* ic = th_ic_at(cold, pc);
    if (ic == null) return pc;
    if (ic.prop_idx == hobject::IC_PROP_ABSENT) {
        return th_put_absent(pc, code_end, regs, cold, hobj, ic, key, value);
    }
    // Shapes describe slot indices across receivers with distinct storage.
    // Exotic receivers must run their [[Set]] semantics in the switch.
    if (ic.key.borrow() != key || ic.shape_id != hobj.shape_id || ic.proto != null
        || ic.shape_gen != hobj.live_shape_generation(cold.heap)) return pc;
    if (ic.prop_flags.is_accessor || !ic.prop_flags.writable) return pc;
    hobject::PropValue* slot = &hobj.prop_values()[ic.prop_idx];
    // Replacing one non-heap value with another has no reference count or
    // barrier to maintain, which keeps the common numeric store a leaf. The
    // reference-counted and traced cases tail-call out of line.
    if (value.is_heap_allocated() || slot.get().is_heap_allocated()) {
        return th_store_slot_ref_next(pc, code_end, regs, cold, hobj, slot, value);
    }
    *slot = (hobject::PropValue)*value;
    return th_next(pc + 1, code_end, regs, cold);
}

// a[i] = v on a dense array, for an index inside the dense part: the switch's
// dense indexed store without its growth and named-property cases, which bail.
// The dense part marks a hole with `undefined`, so storing `undefined` bails
// too. An append updates the length here only when no named "length" entry
// needs the switch's sync_named_length.
fn Instruction* th_put_array_element(Instruction* pc, Instruction* code_end, TVal* regs,
                                     ColdCtx* cold) @private @inline {
    Instruction insn = *pc;
    TVal* target = regs + insn.a;
    TVal* value = regs + insn.c;
    long index = regs[insn.b].get_fastint();
    if (!target.is_object() || value.is_undefined() || index < 0) return pc;

    HObject* array = (HObject*)target.get_heapptr();
    if (array.get_class() != hobject::ObjClass.ARRAY || array.flags.exotic_proxyobj
        || array.flags.has_indexed_named_prop || index >= (long)array.array_size) return pc;
    hobject::PropValue* elements = array.array_part();
    if (elements == null) return pc;

    hobject::PropValue* slot = &elements[(uint)index];
    if (slot.get().is_undefined()) {
        if ((uint)index >= *array.array_len_ptr()) {
            if (array.prop_count != 0) return pc;
            *array.array_len_ptr() = (uint)index + 1;
        }
        array.array_used++;
    }
    if (value.is_heap_allocated() || slot.get().is_heap_allocated()) {
        return th_store_slot_ref_next(pc, code_end, regs, cold, array, slot, value);
    }
    *slot = (hobject::PropValue)*value;
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_putprop(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (rb.is_fastint()) return th_put_array_element(pc, code_end, regs, cold);
    if (!rb.is_string()) return pc;
    return th_put_cached(pc, code_end, regs, cold, regs + insn.a, rb.get_heapptr(), regs + insn.c);
}

fn Instruction* th_putpropc(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    return th_put_cached(pc, code_end, regs, cold, regs + insn.a,
                         cold.vm.current_func.constants[insn.c].get_heapptr(), regs + insn.b);
}

// NEWARR. The allocation is a call either way, so the handler is out of line and
// keeps its frame; what it saves is the round trip through the switch. It
// mirrors the switch case, which documents the register-ownership order. A
// failed allocation bails, and the switch repeats it and reports the failure.
fn Instruction* th_newarr(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Vm* vm = cold.vm;
    Instruction insn = *pc;
    TVal* ra = regs + insn.a;
    uint capacity_hint = insn.get_bc();
    uint alloc_hint = capacity_hint > 0 && capacity_hint <= hobject::ARRAY_INLINE_LITERAL_CAPACITY
        ? hobject::ARRAY_INLINE_LITERAL_CAPACITY : capacity_hint;
    vm.heap.set_reg_undefined(ra);
    HObject*? new_arr = vm.heap.alloc_object(hobject::ObjClass.ARRAY, alloc_hint);
    HObject* a = new_arr ?? null;
    if (a == null) return pc;
    a.prototype = vm.heap.array_proto;
    vm.heap.set_reg_object(ra, a);
    track_heap_store(cold.act, ra, (uint)insn.a);
    if (capacity_hint > a.array_size) a.grow_array(capacity_hint, vm.heap);
    return th_next(pc + 1, code_end, regs, cold);
}

// NEWOBJ and NEWOBJ_SHAPE, out of line like th_newarr for the same reason. A
// failed allocation bails, and the switch repeats it and reports the failure.
fn Instruction* th_newobj(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
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
    return th_next(pc + 1, code_end, regs, cold);
}

// Define element `index` on a fresh dense array literal. The generic
// CreateDataPropertyOrThrow cases stay in the switch: this path only handles an
// empty slot on an extensible array with no indexed named properties, holding a
// value that is not `undefined` (an `undefined` element is a hole in the dense
// part).
fn Instruction* th_init_array_element(Instruction* pc, Instruction* code_end, TVal* regs,
                                      ColdCtx* cold, TVal* target, long index, TVal* value) @private @inline {
    if (!target.is_object() || value.is_undefined()) return pc;

    HObject* array = (HObject*)target.get_heapptr();
    if (array == null || array.get_class() != hobject::ObjClass.ARRAY
        || array.flags.exotic_proxyobj || !array.flags.extensible
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
        return th_store_slot_ref_next(pc, code_end, regs, cold, array, slot, value);
    }
    *slot = (hobject::PropValue)*value;
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_initprop_array(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* key = regs + insn.b;
    if (!key.is_fastint()) return pc;
    return th_init_array_element(pc, code_end, regs, cold, regs + insn.a, key.get_fastint(), regs + insn.c);
}

fn Instruction* th_initelem(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    return th_init_array_element(pc, code_end, regs, cold, regs + insn.a, (long)insn.b, regs + insn.c);
}

// Initialize an empty fixed-shape object slot.
fn Instruction* th_init_slot(Instruction* pc, Instruction* code_end,
                             TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* target = regs + insn.a;
    TVal* value = regs + insn.c;
    if (!target.is_object()) return pc;

    HObject* object = (HObject*)target.get_heapptr();
    if (object == null || object.flags.exotic_proxyobj
        || object.get_class() != hobject::ObjClass.OBJECT
        || insn.b >= object.prop_count) return pc;
    hobject::PropValue* slots = object.prop_values();
    if (slots == null) return pc;
    hobject::PropValue* slot = &slots[insn.b];
    if (!slot.get().is_undefined()) return pc;

    // Only a heap value has a reference count or needs the write barrier.
    if (value.is_heap_allocated()) return th_store_slot_ref_next(pc, code_end, regs, cold, object, slot, value);
    *slot = (hobject::PropValue)*value;
    return th_next(pc + 1, code_end, regs, cold);
}

// Pop the returning frame `fa` and continue in `caller`. The result is already
// written. A leaf, so the return handlers tail-jump here with no frame of
// their own; an owned `this` is released by the caller of this routine.
fn Instruction* th_resume_caller(Instruction* code_end, ColdCtx* cold, Activation* fa,
                                 Activation* caller, bool cross_function) @private {
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

    Instruction* caller_code_end = code_end;
    if (cross_function) {
        // The current burst's bounds and IC arrays belong to the returning
        // callee. Restore the full Dispatch view before threading the caller,
        // so either a later bailout to the switch or another threaded IC hit
        // sees caller-owned state.
        CompiledFunction* caller_func = (CompiledFunction*)caller.func;
        vm.current_func = caller_func;
        Dispatch* dispatch = (Dispatch*)cold.dispatch_ptr;
        dispatch.code_base = caller_func.code;
        dispatch.code_count = caller_func.code_count;
        dispatch.code_end = caller_func.code + caller_func.code_count;
        dispatch.constants = caller_func.constants;
        dispatch.ic_base = (hobject::ICEntry*)caller_func.ic_entries;
        dispatch.var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
        dispatch.nregs = caller_func.num_regs;
        caller_code_end = dispatch.code_end;
    }
    return th_next(caller_pc, caller_code_end, caller.bottom, cold);
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
    if (vm.heap.gc_pending || fa.cat != null || fa.forin != null
        || ((CompiledFunction*)fa.func).mapped_arguments()
        || (fa.flags & ~(ACT_FLAG_BORROWED_CALLEE | ACT_FLAG_CALLEE_OWNED | ACT_FLAG_THIS_VALID)) != 0) {
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
    return pc;
}

// The return handlers' general path: a frame with tracked heap registers to
// sweep, an owned `this`, or a returned receiver. It calls into the heap, so it
// carries a full register-saving frame; th_try_fast_return reaches it only when
// its own leaf path does not apply.
fn Instruction* th_return_general(Instruction* pc, Instruction* code_end,
                                  ColdCtx* cold, TVal value, bool is_undefined) @private @noinline {
    Vm* vm = cold.vm;
    Activation* fa = cold.act;
    if (vm.activation_count > 1 && fa.retval != null) {
        Activation* caller = &vm.activations[vm.activation_count - 2];
        bool cross_function = caller.func != fa.func;
        bool primitive_return = is_undefined || !value.is_heap_allocated();
        bool receiver_return = false;
        if (!primitive_return && !is_undefined && value.is_object()
            && value.get_heapptr() != null && fa.this_binding.is_object()
            && fa.this_binding.get_heapptr() == value.get_heapptr()
            && (fa.flags & (ACT_FLAG_THIS_VALID | ACT_FLAG_THIS_OWNED)) != 0
            && caller.func != null && caller.bottom != null) {
            CompiledFunction* caller_func = (CompiledFunction*)caller.func;
            TVal* caller_end = caller.bottom + caller_func.num_regs;
            receiver_return = fa.retval >= caller.bottom && fa.retval < caller_end;
        }
        // Heap returns other than the current receiver keep the switch path's
        // full write-back handling. Reject them before checking the caller's
        // saved dispatch state; recursion keeps the original two pointer
        // checks.
        if (cross_function && !primitive_return && !receiver_return) return pc;
        if (fa.func != vm.current_func) return pc;
        if (cross_function && (caller.func == null || caller.curr_pc == null)) return pc;
        if (!vm.heap.gc_pending
            && fa.cat == null && fa.forin == null
            && fa.heap_reg_count <= RET_FAST_MAX_HEAP_REGS
            && !((CompiledFunction*)fa.func).mapped_arguments()
            && (fa.flags & ~RET_FAST_FLAGS) == 0
            && (primitive_return || receiver_return)) {
            // A receiver return needs its object shaded before the register
            // sweep removes the callee's last scanned copy, and shading takes
            // the value's address, which would keep this function from tail
            // jumping into the next handler. The switch handles it.
            if (receiver_return && vm.heap.gc_phase == heap::GcPhase.MARK) return pc;
            if (is_undefined) value.set_undefined();
            // Primitive return values survive the sweep in this local copy;
            // receiver returns are non-refcounted objects. The tracked
            // registers still need the same cleanup as the general path before
            // the sliding window is reused.
            sweep_callee_regs(vm, fa);
            TVal* result = fa.retval;
            if ((fa.flags & ACT_FLAG_BORROWED_CALLEE) == 0 && result.is_heap_allocated()) {
                vm.heap.decref_tval(result);
            }
            *result = value;
            if (receiver_return) {
                track_heap_store(caller, result, (uint)(result - caller.bottom));
            }
            fa.release_this(vm.heap);
            return th_resume_caller(code_end, cold, fa, caller, cross_function);
        }
    }
    return pc;
}

// RET and RETUNDEF. The leaf path covers the common return: a primitive
// result from a frame with no tracked heap registers and no owned `this`, so
// the pop is plain stores. An entry frame that is not plain goes to
// th_return_entry, any other to th_return_general, and from there to the switch.
fn Instruction* th_try_fast_return(Instruction* pc, Instruction* code_end,
                                  ColdCtx* cold, TVal value, bool is_undefined) {
    Vm* vm = cold.vm;
    Activation* fa = cold.act;
    // The outermost frame of a Vm.run, entered by a host call: there is no
    // caller register to write, so the pop stores the result in vm.return_val
    // and asks Vm.run to unwind by restarting with no activation left. The
    // frame has to be as plain as the leaf path below requires.
    if (vm.activation_count == 1 && fa.heap_reg_count == 0
        && (is_undefined || !value.is_heap_allocated())
        && (fa.flags & ~(ACT_FLAG_BORROWED_CALLEE | ACT_FLAG_CALLEE_OWNED | ACT_FLAG_THIS_VALID)) == 0
        && fa.cat == null && fa.forin == null && !vm.heap.gc_pending
        && !((CompiledFunction*)fa.func).mapped_arguments()) {
        if (is_undefined) value.set_undefined();
        vm.heap.decref_tval(&vm.return_val);
        vm.return_val = value;
        vm.activation_count = 0;
        vm.gc_root_frame_count_changed();
        fa.release_callee(vm.heap);
        ((Dispatch*)cold.dispatch_ptr).needs_restart = true;
        return pc;
    }
    if (vm.activation_count >= 2 && fa.retval != null && fa.heap_reg_count == 0
        && (is_undefined || !value.is_heap_allocated())
        && (fa.flags & ~(ACT_FLAG_BORROWED_CALLEE | ACT_FLAG_CALLEE_OWNED | ACT_FLAG_THIS_VALID)) == 0
        && fa.cat == null && fa.forin == null && !vm.heap.gc_pending
        && fa.func == vm.current_func
        && !((CompiledFunction*)fa.func).mapped_arguments()) {
        Activation* caller = &vm.activations[vm.activation_count - 2];
        bool cross_function = caller.func != fa.func;
        TVal* result = fa.retval;
        if ((!cross_function || (caller.func != null && caller.curr_pc != null))
            && ((fa.flags & ACT_FLAG_BORROWED_CALLEE) != 0 || !result.is_refcounted())) {
            if (is_undefined) value.set_undefined();
            *result = value;
            return th_resume_caller(code_end, cold, fa, caller, cross_function);
        }
    }
    if (vm.activation_count == 1) return th_return_entry(pc, cold, value, is_undefined);
    return th_return_general(pc, code_end, cold, value, is_undefined);
}

fn Instruction* th_ret(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    return th_try_fast_return(pc, code_end, cold, regs[insn.a], false);
}

fn Instruction* th_retundef(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    TVal value; value.set_undefined();
    return th_try_fast_return(pc, code_end, cold, value, true);
}

// Entry point from Vm.run's inner loop. Runs a burst starting at pc; returns
// the resume pc (== pc if the first opcode isn't in the hot set). Never sets
// needs_restart/halt -- the switch loop re-decodes from the returned pc.
fn Instruction* run_threaded_burst(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    if (pc >= code_end) return pc;
    cold.shape_epoch = cold.heap.shape_recycle_epoch;
    Instruction first = *pc;
    return g_threaded_handlers[first.op.ordinal](pc, code_end, regs, cold);
}
