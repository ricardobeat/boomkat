module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hobject;
import duktape::env;

// ============================================================================
// Direct-threaded dispatch prototype (plan-058-adjacent spike; NOT wired into
// the default execution path). Covers only fib(32)'s hottest opcodes:
// LDINT, LDUNDEF, LDREG, SUBI (fastint), ADD (fastint), JMP_NLE (fastint/
// numeric, forward+backward), GETVAR (VarIC hit). Every other opcode, and
// every slow/exceptional path of the opcodes above, bails out of the
// threaded chain and hands control back to Vm.run's ordinary switch loop.
//
// Design constraint (measured in spike/direct-threading/): the hot fields
// (pc, regs base, code end) must be passed as direct scalar arguments, not
// bundled behind the Dispatch* pointer, or LLVM reloads them from memory on
// every handler call and the whole thing is slower than the switch. Cold,
// rarely-touched state (vm, act, ic bases, needs_restart, halt) rides behind
// one ColdCtx* pointer.
// ============================================================================

/// Cold state a threaded handler needs but doesn't touch every dispatch.
struct ColdCtx {
    Vm* vm;
    Activation* act;
    Instruction* code_base;
    TVal* constants;
    hobject::VarICEntry* var_ic_base;
}

/// A threaded handler's outcome: either it tail-called into the next
/// handler (recursively, and this call already returned that terminal
/// value), or it bailed to the switch loop. We signal "bailed" via a
/// out-param write into ColdCtx.exit_pc (the pc value to resume the
/// switch loop at) combined with a bool return.
///
/// Returns true if a bailout occurred (caller must fall back to switch,
/// resuming at *out_pc); false only when it fell off the handled set is
/// not reachable — the burst always ends via a bailout in this prototype
/// (RET/CALL/end-of-code/slow-path are the only exits).
alias ThreadedHandlerFn = fn bool(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, Instruction** out_pc);

ThreadedHandlerFn[152] g_threaded_handlers;
bool g_threaded_handlers_init = false;

fn void init_threaded_handlers() {
    if (g_threaded_handlers_init) return;
    g_threaded_handlers_init = true;
    for (int i = 0; i < 152; i++) {
        g_threaded_handlers[i] = &th_bailout;
    }
    g_threaded_handlers[Opcode.LDINT.ordinal]   = &th_ldint;
    g_threaded_handlers[Opcode.LDUNDEF.ordinal] = &th_ldundef;
    g_threaded_handlers[Opcode.LDREG.ordinal]   = &th_ldreg;
    g_threaded_handlers[Opcode.SUBI.ordinal]    = &th_subi;
    g_threaded_handlers[Opcode.ADD.ordinal]     = &th_add;
    g_threaded_handlers[Opcode.JMP_NLE.ordinal] = &th_jmp_nle;
    g_threaded_handlers[Opcode.GETVAR.ordinal]  = &th_getvar;
}

/// Unhandled opcode (or a handled opcode's slow path): bail immediately,
/// without consuming *pc — the switch loop re-decodes it.
fn bool th_bailout(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, Instruction** out_pc) {
    *out_pc = pc;
    return true;
}

macro bool th_next(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, Instruction** out_pc) {
    if (pc >= code_end) {
        *out_pc = pc;
        return true;
    }
    Instruction next = *pc;
    return g_threaded_handlers[next.op.ordinal](pc, code_end, regs, cold, out_pc);
}

fn bool th_ldint(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, Instruction** out_pc) {
    Instruction insn = *pc;
    pc++;
    TVal* ra = regs + insn.a;
    ra.set_fastint((long)insn.get_sbc());
    return th_next(pc, code_end, regs, cold, out_pc);
}

fn bool th_ldundef(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, Instruction** out_pc) {
    Instruction insn = *pc;
    pc++;
    TVal* ra = regs + insn.a;
    ra.set_undefined();
    return th_next(pc, code_end, regs, cold, out_pc);
}

fn bool th_ldreg(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, Instruction** out_pc) {
    Instruction insn = *pc;
    pc++;
    TVal* ra = regs + insn.a;
    TVal* rb = regs + insn.b;
    if (!rb.is_heap_allocated()) {
        if (ra.is_heap_allocated()) {
            cold.vm.heap.decref_tval(ra);
        }
        *ra = *rb;
    } else {
        cold.vm.heap.tval_copy_ref(ra, rb);
        track_heap_store(cold.act, ra, insn.a);
    }
    return th_next(pc, code_end, regs, cold, out_pc);
}

fn bool th_subi(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, Instruction** out_pc) {
    Instruction insn = *pc;
    TVal* ra = regs + insn.a;
    TVal* rb = regs + insn.b;
    if (!rb.is_fastint()) {
        *out_pc = pc;
        return true;
    }
    long imm = (long)(ichar)insn.c;
    long diff = rb.get_fastint() - imm;
    ra.set_fastint_or_number(diff);
    pc++;
    return th_next(pc, code_end, regs, cold, out_pc);
}

fn bool th_add(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, Instruction** out_pc) {
    Instruction insn = *pc;
    TVal* ra = regs + insn.a;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    if (!types::both_fastint(rb, rc)) {
        *out_pc = pc;
        return true;
    }
    long sum = rb.get_fastint() + rc.get_fastint();
    if (sum >= types::FASTINT_MIN && sum <= types::FASTINT_MAX) {
        ra.set_fastint(sum);
    } else {
        ra.set_number((double)sum);
    }
    pc++;
    return th_next(pc, code_end, regs, cold, out_pc);
}

fn bool th_jmp_nle(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, Instruction** out_pc) {
    Instruction insn = *pc;
    TVal* rb = regs + insn.b;
    TVal* rc = regs + insn.c;
    bool cmp_le;
    if (types::both_fastint(rb, rc)) {
        cmp_le = rb.get_fastint() <= rc.get_fastint();
    } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
        double db = tval_numeric_to_double(rb);
        double dc = tval_numeric_to_double(rc);
        cmp_le = db <= dc;
    } else {
        // Relational compare on non-numeric operands can call user code
        // (valueOf/toString) and throw — not worth threading; bail.
        *out_pc = pc;
        return true;
    }
    pc++;
    // JMP_NLE branches when NOT (b <= c), i.e. cmp_le == false.
    if (!cmp_le) {
        if ((ichar)insn.a < 0) {
            if (--cold.vm.heap.bwd_gc_budget == 0) {
                if (cold.vm.heap.gc_pending) { cold.vm.heap.safepoint_gc(); }
                cold.vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL;
            }
        }
        pc += (int)(ichar)insn.a;
    }
    return th_next(pc, code_end, regs, cold, out_pc);
}

fn bool th_getvar(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold, Instruction** out_pc) {
    Instruction insn = *pc;
    TVal* ra = regs + insn.a;
    uint bc = insn.get_bc();
    if (bc >= ((CompiledFunction*)cold.act.func).const_count || cold.var_ic_base == null) {
        *out_pc = pc;
        return true;
    }
    TVal name_val = cold.constants[bc];
    if (!name_val.is_string()) {
        *out_pc = pc;
        return true;
    }
    void* key = name_val.get_heapptr();
    uint pc_off = (uint)(pc - cold.code_base);
    hobject::VarICEntry* vic = cold.var_ic_base + pc_off;
    if (vic.env == null || vic.key != key || vic.search_head != (void*)cold.act.lex_env) {
        *out_pc = pc;
        return true;
    }
    HObject* b = (HObject*)vic.bindings;
    if (b.shape_id != vic.shape_id || cold.vm.heap.shapes[b.shape_id].generation != vic.generation) {
        *out_pc = pc;
        return true;
    }
    if (b.get_prop_flags(vic.prop_idx).is_accessor) {
        *out_pc = pc;
        return true;
    }
    TVal v = b.prop_values()[vic.prop_idx];
    if (env::is_tdz_sentinel(&v)) {
        *out_pc = pc;
        return true;
    }
    cold.vm.heap.tval_copy_ref(ra, &v);
    track_heap_store(cold.act, ra, insn.a);
    pc++;
    return th_next(pc, code_end, regs, cold, out_pc);
}

/// Entry point called from Vm.run's inner loop. Runs a burst of threaded
/// handlers starting at ds.curr_pc; returns the resume pc (== ds.curr_pc
/// unchanged if the very first opcode isn't in the hot set). Never sets
/// needs_restart/halt itself — the switch loop re-decodes and handles
/// those cases normally starting from the returned pc.
fn Instruction* run_threaded_burst(Instruction* pc, Instruction* code_end, TVal* regs, ColdCtx* cold) {
    if (pc >= code_end) return pc;
    Instruction* resume_pc;
    Instruction first = *pc;
    g_threaded_handlers[first.op.ordinal](pc, code_end, regs, cold, &resume_pc);
    return resume_pc;
}
