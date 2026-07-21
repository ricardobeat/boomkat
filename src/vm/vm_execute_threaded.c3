module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hobject;

// ============================================================================
// Direct-threaded dispatch CEILING SPIKE (feature THREADED_DISPATCH; NOT wired
// into the default build). Covers the three hot opcodes of the tight,
// dispatch-dominated loop `while(i<N){s=s+1;i=i+1;}`:
//
//   ADDI    (fastint fast path)   -- s=s+1 / i=i+1
//   LDREG   (non-heap fast path)  -- write-back of the accumulator
//   JMP_LT  (fastint fast path)   -- loop back-edge
//
// Everything else, and every slow/exceptional path of the three above, bails
// out of the threaded chain and hands control back to Vm.run's switch loop.
//
// Design constraint (from spike/direct-threading/): the hot fields (pc, regs
// base, code end) are passed as DIRECT SCALAR ARGUMENTS so LLVM keeps them
// register-resident. Cold state (vm, act, code_base) rides behind one
// ColdCtx* pointer. A struct-pointer-only port reloads pc/regs from memory on
// every handler call and regresses -- do not bundle the hot fields.
//
// Each handler ends in a TAIL CALL through g_threaded_handlers[...], which at
// -O2 LLVM lowers to an indirect tail JUMP (br xN), giving computed-goto-style
// threading with no goto/musttail (which C3 lacks).
// ============================================================================

struct ColdCtx {
    Vm* vm;
    Activation* act;
    Instruction* code_base;
}

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
    g_threaded_handlers[Opcode.ADDI.ordinal]   = &th_addi;
    g_threaded_handlers[Opcode.LDREG.ordinal]  = &th_ldreg;
    g_threaded_handlers[Opcode.JMP_LT.ordinal] = &th_jmp_lt;
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
    pc++;
    // JMP_LT branches when TRUE (loop back-edge).
    if (cmp_lt) {
        if ((ichar)insn.a < 0) {
            if (--cold.vm.heap.bwd_gc_budget == 0) {
                if (cold.vm.heap.gc_pending) { cold.vm.heap.safepoint_gc(); }
                cold.vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL;
            }
        }
        pc += (int)(ichar)insn.a;
    }
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
