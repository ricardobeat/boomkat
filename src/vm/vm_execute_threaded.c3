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
    g_threaded_handlers[Opcode.LDTHIS.ordinal] = &th_ldthis;
    g_threaded_handlers[Opcode.JMP_LT.ordinal] = &th_jmp_lt;

    // --- Recursion (fib) cheap ops ---
    g_threaded_handlers[Opcode.LDINT.ordinal]  = &th_ldint;
    g_threaded_handlers[Opcode.SUBI.ordinal]   = &th_subi;
    g_threaded_handlers[Opcode.ADD.ordinal]    = &th_add;
    g_threaded_handlers[Opcode.INC.ordinal]    = &th_incdec;
    g_threaded_handlers[Opcode.DEC.ordinal]    = &th_incdec;
    g_threaded_handlers[Opcode.JMP_NLT.ordinal] = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_NLE.ordinal] = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_NGT.ordinal] = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_NGE.ordinal] = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_LE.ordinal]  = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_GT.ordinal]  = &th_cmp_branch;
    g_threaded_handlers[Opcode.JMP_GE.ordinal]  = &th_cmp_branch;
    // CALL handles intrinsic array push; RET handles guarded compiled returns.
    g_threaded_handlers[Opcode.CALL.ordinal] = &th_call_push_one;
    g_threaded_handlers[Opcode.RET.ordinal] = &th_ret;
    g_threaded_handlers[Opcode.RETUNDEF.ordinal] = &th_retundef;

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
    g_threaded_handlers[Opcode.ITER_NEXT_FAST.ordinal] = &th_iter_next_intrinsic;
    g_threaded_handlers[Opcode.TONUMERIC.ordinal]     = &th_tonumeric;

    // --- Property access: IC hit path (bench_object / bench_property_lookup) ---
    g_threaded_handlers[Opcode.GETPROP.ordinal]         = &th_getprop_array;
    g_threaded_handlers[Opcode.GETPROP_CACHE.ordinal]   = &th_getprop_array;
    g_threaded_handlers[Opcode.GETPROPC.ordinal]        = &th_getpropc;
    g_threaded_handlers[Opcode.GETPROPC_CACHED.ordinal] = &th_getpropc_cached;
    g_threaded_handlers[Opcode.PUTPROP.ordinal]         = &th_putprop;
    g_threaded_handlers[Opcode.INITPROP.ordinal]        = &th_initprop_array_numeric;
    g_threaded_handlers[Opcode.INIT_SLOT.ordinal]        = &th_init_slot_numeric;
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
    vm_charge_interrupt(cold.vm.heap);
    // The interrupt budget runs down inside the burst too. Threaded dispatch
    // consumes the vast majority of back-edges, so a poll that waited for a
    // switch visit would fire roughly BWD_GC_INTERVAL times too rarely, and a
    // runaway loop could run millions of iterations before the host's abort
    // landed. Charging here (and bailing on the due flag) holds the poll
    // cadence at INTERRUPT_BUDGET_INIT back-edges in both dispatch modes; no
    // handler installed is the one-compare fast path.
    if (cold.vm.heap.interrupt_due) return true;
    return cold.vm.heap.bwd_gc_budget <= 1;
}

fn Instruction* th_addi(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    long imm = (long)(ichar)insn.c;
    ra.set_fastint_or_number(rb.get_fastint() + imm);
    pc++;
    return th_next(pc, code_end, regs, cold);
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

// True when `v` can be retained with a plain increment: anything but a pinned
// string (builtin strings, well-known symbols, the small-int cache), whose
// fixed refcount the switch is left to handle. Only strings are counted.
macro bool th_can_retain(TVal* v) @private {
    if (!v.is_refcounted()) return true;
    void* p = v.get_heapptr();
    if (p == null) return true;
    return !((types::HeapHeader*)p).is_pinned();
}

macro void th_do_retain(TVal* v) @private {
    if (!v.is_refcounted()) return;
    void* p = v.get_heapptr();
    if (p == null) return;
    ((types::HeapHeader*)p).refcount++;
}

// True when the reference `slot` holds can be dropped with a plain decrement:
// the fast half of Heap.decref. A string that would hit zero, or a pinned one,
// goes to the switch, which frees it.
macro bool th_can_release(TVal* slot) @private {
    if (!slot.is_refcounted()) return true;
    void* p = slot.get_heapptr();
    if (p == null) return true;
    types::HeapHeader* h = (types::HeapHeader*)p;
    return !(h.is_pinned() || h.refcount <= 1);
}

macro void th_do_release(TVal* slot) @private {
    if (!slot.is_refcounted()) return;
    void* p = slot.get_heapptr();
    if (p == null) return;
    ((types::HeapHeader*)p).refcount--;
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
    TVal* rb = regs + insn.b;
    // Threaded fast path only: non-heap source. Heap source bails so the
    // switch handles refcount + track_heap_store.
    if (rb.is_heap_allocated()) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_publish(cold.vm.heap, *rb) || !th_can_release(ra)) return pc;
    th_do_release(ra);
    *ra = *rb;
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_ldthis(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    TVal value = cold.act.this_binding;
    // Derived-constructor TDZ errors and collector shading use the switch.
    if (env::is_tdz_sentinel(&value) || !th_can_publish(cold.vm.heap, value)
        || !th_can_retain(&value)) return pc;
    TVal* ra = regs + pc.a;
    if (!th_can_release(ra)) return pc;
    th_do_retain(&value);
    th_do_release(ra);
    *ra = value;
    track_heap_store(cold.act, ra, (uint)pc.a);
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

// Thread intrinsic array and cached ASCII string iterator steps. Every
// refusal resumes ITER_NEXT_FAST in the switch for the full protocol.
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
        hstring::HString* character = cold.vm.heap.ascii_char_strs[byte];
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
    if (insn.c != 1 || cold.vm.heap.gc_pending) return pc;

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

    uint new_length;
    if (!builtins::array_push_one_fast((HObject*)receiver.get_heapptr(), value,
                                       cold.vm.heap, &new_length)) return pc;

    th_do_release(result);
    result.set_fastint((long)new_length);
    return th_next(pc + 1, code_end, regs, cold);
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
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
    long imm = (long)(ichar)insn.c;
    ra.set_fastint_or_number(rb.get_fastint() - imm);
    pc++;
    return th_next(pc, code_end, regs, cold);
}

fn Instruction* th_incdec(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    TVal* value = regs + pc.a;
    if (!value.is_fastint()) return pc;
    long delta = pc.op == Opcode.INC ? 1L : -1L;
    value.set_fastint_or_number(value.get_fastint() + delta);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_add(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    TVal* dst = regs + insn.a;
    if (types::both_fastint(rb, rc) && dst.is_fastint()) {
        long sum = rb.get_fastint() + rc.get_fastint();
        dst.set_fastint_or_number(sum);
        return th_next(pc + 1, code_end, regs, cold);
    }
    // String concat, object ToPrimitive, and BigInt use the switch.
    if (!types::both_fastint(rb, rc)) {
        // A double operand is handled here too. Adding two numbers cannot call
        // user code or throw, so there is nothing for the switch's coercion
        // machinery to guard; bailing instead sent every iteration of a
        // floating-point loop back through decode.
        if ((!rb.is_fastint() && !rb.is_number()) || (!rc.is_fastint() && !rc.is_number())) {
            return pc;
        }
        TVal* ra = regs + insn.a;
        if (!th_can_release(ra)) return pc;
        th_do_release(ra);
        double bnum = rb.is_fastint() ? (double)rb.get_fastint() : rb.get_number();
        double cnum = rc.is_fastint() ? (double)rc.get_fastint() : rc.get_number();
        ra.set_number(bnum + cnum);
        pc++;
        return th_next(pc, code_end, regs, cold);
    }
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
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

// --- Global-slot access (perf-all VarRef fast path). ---
//
// pc points at the current instruction, so the IC slot is pc - code_base.
// A hit validates the binding object and shape before reading its slot.

fn Instruction* th_getglobal(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* gic = vic_base + pc_off;
    HObject* gb = (HObject*)gic.bindings;
    if (gb == null || gic.search_head != (void*)cold.act.lex_env || gb.shape_id != gic.shape_id) return pc;
    hobject::PropValue* pv = &gb.prop_values()[gic.prop_idx];
    if (slot_is_tdz(pv)) return pc; // TDZ -> switch throws
    TVal* ra = regs + insn.a;
    TVal value = pv.get();
    // A non-heap value needs neither a mark publication nor a string retain.
    if (!value.is_heap_allocated() && !ra.is_heap_allocated() && !value.is_envref()) {
        *ra = value;
        return th_next(pc + 1, code_end, regs, cold);
    }
    if (!th_can_publish(cold.vm.heap, value)) return pc;
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
        if (!th_can_retain(&value) || !th_can_release(ra)) return pc;
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
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* gic = vic_base + pc_off;
    HObject* gb = (HObject*)gic.bindings;
    // Only writable non-configurable data globals (varref_store_ok) may take
    // the re-check-free store path -- exactly the switch's fast-path gate.
    if (gb == null || gic.search_head != (void*)cold.act.lex_env || gb.shape_id != gic.shape_id || !gic.varref_store_ok) return pc;
    TVal* ra = regs + insn.a;
    hobject::PropValue* slot = &gb.prop_values()[gic.prop_idx];
    TVal old = slot.get();
    // Only traced sources need a barrier, and only strings need release.
    if (ra.is_traced() || old.is_refcounted()) return pc;
    *slot = (hobject::PropValue)*ra;
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
    hobject::PropValue* slot = &gb.prop_values()[gic.prop_idx];
    TVal old_val = slot.get();
    // Threaded fast path: fastint only. number/bigint/TDZ -> switch.
    if (!old_val.is_fastint()) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
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

fn Instruction* th_getcap(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    hobject::PropValue* slot = capture_value_slot(cold.act, pc.get_bc(), cold.vm.heap);
    if (slot == null) return pc;
    TVal value = slot.get();
    TVal* dst = regs + pc.a;
    if (!th_can_publish(cold.vm.heap, value)
        || !th_can_retain(&value) || !th_can_release(dst)) return pc;
    th_do_retain(&value);
    th_do_release(dst);
    *dst = value;
    track_heap_store(cold.act, dst, (uint)pc.a);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_putcap(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    uint capture_index = pc.op == Opcode.PUTCAP_SNAP ? pc.c : pc.get_bc();
    HObject* owner;
    hobject::PropValue* slot = capture_value_slot(cold.act, capture_index, cold.vm.heap, true, &owner);
    if (slot == null || !th_can_release_slot(slot)) return pc;
    TVal* src = regs + pc.a;
    th_do_release_slot(slot);
    cold.vm.heap.store_slot(owner, slot, *src);
    src.set_undefined();
    return th_next(pc + 1, code_end, regs, cold);
}

// The dense slot a cell instruction names, and in `owner` the cells object
// that holds it, which a store needs for the write barrier.
fn hobject::PropValue* th_cell_slot(Instruction* pc, TVal* regs, HObject** owner) @private {
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
    if (!th_can_publish(cold.vm.heap, value)
        || !th_can_retain(&value) || !th_can_release(dst)) return pc;
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
    if (slot == null || !th_can_retain(src) || !th_can_release_slot(slot)) return pc;
    th_do_retain(src);
    th_do_release_slot(slot);
    cold.vm.heap.store_slot(owner, slot, *src);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_movecell(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    HObject* owner;
    hobject::PropValue* slot = th_cell_slot(pc, regs, &owner);
    TVal* src = regs + pc.a;
    if (slot == null || !th_can_release_slot(slot)) return pc;
    th_do_release_slot(slot);
    cold.vm.heap.store_slot(owner, slot, *src);
    src.set_undefined();
    return th_next(pc + 1, code_end, regs, cold);
}

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
    if (vic.env == null || vic.key.borrow() != key || vic.search_head != (void*)act.lex_env) return pc;
    HObject* b = (HObject*)vic.bindings;
    if (b.shape_id != vic.shape_id
        || vm.heap.shape_recycle_epoch != vic.recycle_epoch) return pc;
    if (vic.prop_flags.is_accessor) return pc; // getter -> switch
    TVal v = b.prop_values()[vic.prop_idx].get();
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
    if (!th_can_publish(cold.vm.heap, v)
        || !th_can_retain(&v) || !th_can_release(ra)) return pc;
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
    uint bc = insn.get_bc();
    if (bc >= vm.current_func.const_count) return pc;
    TVal name_val = vm.current_func.constants[bc];
    if (!name_val.is_string()) return pc;
    void* key = name_val.get_heapptr();
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* vic = vic_base + pc_off;
    if (vic.env == null || vic.key.borrow() != key || vic.search_head != (void*)act.lex_env) return pc;
    HObject* b = (HObject*)vic.bindings;
    if (b.shape_id != vic.shape_id
        || vm.heap.shape_recycle_epoch != vic.recycle_epoch) return pc;
    hobject::PropValue* pv = &b.prop_values()[vic.prop_idx];
    hobject::PropFlags fl = vic.prop_flags;
    if (slot_is_tdz(pv) || !fl.writable || fl.is_accessor) return pc;
    TVal* ra = regs + insn.a;
    // Inline release, as in th_getvar: keeps the handler leaf without pushing
    // heap-valued bindings onto the switch.
    if (!th_can_release_slot(pv)) return pc;
    th_do_release_slot(pv);
    vm.heap.store_slot(b, pv, *ra);
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
        || cold.vm.heap.shape_recycle_epoch != vic.recycle_epoch) return pc;
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
    uint bc = insn.get_bc();
    if (bc >= vm.current_func.const_count) return pc;
    TVal name_val = vm.current_func.constants[bc];
    if (!name_val.is_string()) return pc;
    void* key = name_val.get_heapptr();
    hobject::VarICEntry* vic_base = cold.var_ic_base;
    if (vic_base == null) return pc;
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* vic = vic_base + pc_off;
    if (vic.env == null || vic.key.borrow() != key || vic.search_head != (void*)act.lex_env) return pc;
    HObject* b = (HObject*)vic.bindings;
    if (b.shape_id != vic.shape_id
        || vm.heap.shape_recycle_epoch != vic.recycle_epoch) return pc;
    TVal old_val = b.prop_values()[vic.prop_idx].get();
    if (env::is_tdz_sentinel(&old_val) || !vic.prop_flags.writable) return pc;
    if (!old_val.is_fastint()) return pc;
    TVal* ra = regs + insn.a;
    if (!th_can_release(ra)) return pc;
    th_do_release(ra);
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
macro hobject::ICEntry* th_ic_at(Vm* vm, ColdCtx* cold, Instruction* pc) {
    hobject::ICEntry* base = (hobject::ICEntry*)vm.current_func.ic_entries;
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
    if (!th_can_publish(cold.vm.heap, value)) return pc;
    if (value.is_heap_allocated()) {
        if (!th_can_retain(&value) || !th_can_release(ra)) return pc;
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
    if (!rb.is_object()) return pc;
    HObject* hobj = (HObject*)rb.get_heapptr();
    // Proxy [[Get]] can run a trap, so it never reaches the cache.
    if (hobj.flags.exotic_proxyobj) return pc;
    void* key = vm.current_func.constants[(uint)insn.c].get_heapptr();
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
    hobject::ICEntry* ic = th_ic_at(vm, cold, pc);
    if (ic == null) return pc;
    if (ic.key.borrow() != key || ic.shape_id != hobj.shape_id
        || ic.shape_gen != hobj.shape_generation(vm.heap)) return pc;
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
        if (!th_can_retain(&ic_val) || !th_can_release(ra)) return pc;
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
    hobject::ICEntry* ic = th_ic_at(vm, cold, pc);
    if (ic == null) return pc;
    if (ic.shape_id != hobj.shape_id || ic.shape_gen != hobj.shape_generation(vm.heap)) return pc;
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
        if (!th_can_retain(&ic_val) || !th_can_release(ra)) return pc;
        th_do_retain(&ic_val);
        th_do_release(ra);
        *ra = ic_val;
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
    if (hobj.get_class() != hobject::ObjClass.OBJECT
        || hobj.flags.exotic_proxyobj || hobj.flags.exotic_module_ns) return pc;
    TVal* rb = regs + insn.b;
    if (!rb.is_string()) return pc;
    hobject::ICEntry* ic = th_ic_at(vm, cold, pc);
    if (ic == null) return pc;
    // Missing-property stores carry a sentinel instead of a value-slot index;
    // their prototype and extensibility checks run in the PUTPROP slow path.
    if (ic.prop_idx == hobject::IC_PROP_ABSENT) return pc;
    // Shapes describe slot indices across receivers with distinct storage.
    // Exotic receivers must run their [[Set]] semantics in the switch.
    if (ic.key.borrow() != rb.get_heapptr() || ic.shape_id != hobj.shape_id || ic.proto != null
        || ic.shape_gen != hobj.shape_generation(vm.heap)) return pc;
    if (ic.prop_flags.is_accessor || !ic.prop_flags.writable) return pc;
    vm.heap.store_slot_ref(hobj, &hobj.prop_values()[ic.prop_idx], regs + insn.c);
    pc++;
    return th_next(pc, code_end, regs, cold);
}

// Define a numeric element on a fresh dense array literal. Keep all generic
// CreateDataPropertyOrThrow cases in the switch: this path only handles an
// empty slot on an extensible array with no indexed named properties.
fn Instruction* th_initprop_array_numeric(Instruction* pc, Instruction* code_end,
                                         TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* target = regs + insn.a;
    TVal* key = regs + insn.b;
    TVal* value = regs + insn.c;
    if (!target.is_object() || !key.is_fastint()
        || !(value.is_fastint() || value.is_number())) return pc;

    HObject* array = (HObject*)target.get_heapptr();
    if (array == null || array.get_class() != hobject::ObjClass.ARRAY
        || array.flags.exotic_proxyobj || !array.flags.extensible
        || array.flags.has_indexed_named_prop) return pc;

    long index = key.get_fastint();
    if (index < 0 || index >= (long)array.array_size) return pc;
    hobject::PropValue* elements = array.array_part();
    if (elements == null) return pc;
    hobject::PropValue* slot = &elements[(uint)index];
    if (!slot.get().is_undefined()) return pc;

    // The primitive guard makes this store ownership-neutral; use the normal
    // slot helper so the collector still sees its barrier contract.
    cold.vm.heap.store_slot(array, slot, *value);
    array.array_used++;
    if ((uint)index >= *array.array_len_ptr()) {
        *array.array_len_ptr() = (uint)index + 1;
    }
    return th_next(pc + 1, code_end, regs, cold);
}

// Initialize an empty fixed-shape object slot from a number. Heap values keep
// INIT_SLOT's reference-count and root-tracking path in the switch.
fn Instruction* th_init_slot_numeric(Instruction* pc, Instruction* code_end,
                                    TVal* regs, ColdCtx* cold) {
    Instruction insn = *pc;
    TVal* target = regs + insn.a;
    TVal* value = regs + insn.c;
    if (!target.is_object() || !(value.is_fastint() || value.is_number())) return pc;

    HObject* object = (HObject*)target.get_heapptr();
    if (object == null || object.flags.exotic_proxyobj
        || object.get_class() != hobject::ObjClass.OBJECT
        || insn.b >= object.prop_count) return pc;
    hobject::PropValue* slots = object.prop_values();
    if (slots == null) return pc;
    hobject::PropValue* slot = &slots[insn.b];
    if (!slot.get().is_undefined()) return pc;

    // The numeric guard makes this ownership-neutral. Keep the normal write
    // barrier so the collector sees the same slot-store contract.
    cold.vm.heap.store_slot(object, slot, *value);
    return th_next(pc + 1, code_end, regs, cold);
}

fn Instruction* th_try_fast_return(Instruction* pc, Instruction* code_end,
                                  ColdCtx* cold, TVal value, bool is_undefined) {
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
            if (is_undefined) value.set_undefined();
            // Root shading must happen before the register sweep removes the
            // callee's last scanned copy of an object returned as `this`.
            if (receiver_return) vm.heap.shade_root_tval(value);
            // Primitive return values survive the sweep in this local copy;
            // receiver returns are non-refcounted objects. The tracked
            // registers still need the same cleanup as the general path before
            // the sliding window is reused.
            if (fa.heap_reg_count != 0) decref_callee_regs(vm, fa);
            TVal* result = fa.retval;
            if ((fa.flags & ACT_FLAG_BORROWED_CALLEE) == 0 && result.is_heap_allocated()) {
                vm.heap.decref_tval(result);
            }
            *result = value;
            if (receiver_return) {
                track_heap_store(caller, result, (uint)(result - caller.bottom));
            }

            Instruction* caller_pc = caller.curr_pc;
            TVal* caller_top = fa.caller_valstack_top;
            fa.release_refs(vm.heap);
            vm.activation_count--;
            vm.gc_root_frame_count_changed();
            cold.act = caller;
            vm.valstack_bottom = caller.bottom;
            vm.valstack_top = caller_top;
            *cold.regs_base_ptr = caller.bottom;

            Instruction* caller_code_end = code_end;
            CompiledFunction* caller_func = (CompiledFunction*)caller.func;
            if (cross_function) {
                // The current burst's bounds and IC arrays belong to the
                // returning callee. Restore the full Dispatch view before
                // threading the caller, so either a later bailout to the
                // switch or another threaded IC hit sees caller-owned state.
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
    }
    return pc;
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
    Instruction first = *pc;
    return g_threaded_handlers[first.op.ordinal](pc, code_end, regs, cold);
}
