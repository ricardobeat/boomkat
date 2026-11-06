// Optimizing tier: policy, ownership and exits.
//
// An optimized function is a second native code body for a CompiledFunction.
// While it is installed, `f.jit_code` points at it and every way into native
// code (Vm.run, jit_call_enter, the direct call entry) reaches it without
// knowing; the baseline code it replaced stays in OptCode.base. An exit
// writes whatever the optimized code kept in machine registers back into the
// interpreter's register window, leaves ds.curr_pc at the instruction to
// resume, and tail-calls the baseline code, whose entry table continues the
// frame there. The exit is the only way out of optimized code other than the
// ordinary returns, so a frame is always resumable by a tier that has no
// state of its own.
//
// Discarding code (too many exits) reinstalls the baseline code and retires
// the optimized body to a list. Native frames of it may still be on the C
// stack, so it is freed only when no native code is running at all
// (Heap.opt.running is zero), which the outermost baseline_run notices.
module boomkat::jit @feat(SLJIT);

import boomkat::vm;
import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import std::io;
import std::time::clock;

enum OptExit : char (String label) {
    OVERFLOW {"overflow"},
    NOT_INT32 {"not-int32"},
    NOT_NUMBER {"not-number"},
    SHAPE {"shape"},
    BOUNDS {"bounds"},
    HOLE {"hole"},
    CALLEE {"callee"},
    INLINE_SLOWCALL {"inline-slowcall"},
    ALLOC_SLOW {"alloc-slow"},
    THROW_PATH {"throw-path"},
    FORCED {"forced"},
    // A back edge's budget or interrupt poll fired; not a failed speculation.
    INTERRUPT {"interrupt"},
    SLOW_PATH {"slow-path"},
}

const char OPT_NONE = 0;
const char OPT_ACTIVE = 1;
// Compiling failed or hit a cap; the function stays on its baseline code.
const char OPT_REFUSED = 2;
// Optimized code exited too often, too many times.
const char OPT_REFUSED_EXITS = 3;

// Frame entries (and loop credits) before a function with feedback is
// optimized; exits that discard its code; and the reoptimizations allowed.
const uint OPT_ENTRY_THRESHOLD = 1000;
const uint OPT_EXIT_MAX = 8;
const char OPT_REOPT_MAX = 2;
const usz OPT_CODE_MAX = 512 * 1024;

struct OptCode {
    // The code installed as f.jit_code while the function is optimized.
    BaselineCode* code;
    // The baseline code an exit continues in.
    BaselineCode* base;
    CompiledFunction* f;
    OptCode* next_retired;
    uint exits;
    // Test hook (--opt-force-exit): exits still to take at the chosen pc.
    uint forced;
    // The shape id each field access of the code compares against, in memory so that
    // Heap.purge_retired_shapes can clear one whose id is about to be reused.
    uint* cells;
    uint cell_count;
    // The exits taken from inside inlined bodies.
    OptInlineExit* inline_exits;
}

// Where an exit from inside an inlined callee's body goes: the callee's frame is published, as the
// call it replaced would have, and its baseline code continues at `pc`.
struct OptInlineExit {
    CompiledFunction* callee;
    // The instruction after the call in the caller.
    Instruction* resume;
    uint base;
    uint nargs;
    // The callee's word the exit resumes at.
    uint pc;
    // The callee registers live there.
    uint keep;
    OptInlineExit* next;
}

struct OptPolicy {
    bool enabled;
    // Do not inline calls.
    bool no_inline;
    // Callees inlined, and exits taken from inside an inlined body, over all compiles.
    uint inlined;
    uint inline_exits;
    // Optimize every function as soon as it has baseline code.
    bool always;
    // Print each optimized function's graph (--opt-dump).
    bool dump;
    // Test hook: zero, or one more than the OptExit every optimized body
    // takes `force_count` times at instruction `force_at`.
    uint force_reason;
    uint force_at;
    uint force_count;
    // The forced exit is taken at a node of an inlined body only.
    bool force_inline;
    // Exits that discard a body, OPT_EXIT_MAX when zero.
    uint exit_max;
    // Native code in progress anywhere on the C stack; retired code is freed when it reaches zero.
    uint running;
    OptCode* retired;
    usz live_bytes;
    ulong compiled;
    ulong discards;
    ulong reopts;
    ulong refused;
    ulong[OptRefuse::values.len] refused_why;
    ulong[256] refused_ops;
    ulong[OptExit::values.len] exits;
}

// Count an entry into native code of `f` (one for each `credit`) toward
// optimizing it, and do so when the policy says.
fn void opt_note_entry(Heap* h, CompiledFunction* f, uint credit = 1) @noinline {
    if (f.opt_state != OPT_NONE || f.opt_code != null) {
        // The baseline call entry declines at the threshold; start its count over.
        f.opt_entries = 0;
        return;
    }
    f.opt_entries += credit;
    if (!h.opt.always && f.opt_entries < OPT_ENTRY_THRESHOLD) return;
    // Without the feedback to specialize on, the next attempt waits for another round of entries.
    if (!opt_try_compile(h, f) && f.opt_state == OPT_NONE) f.opt_entries = 0;
}

// The optimized code a baseline frame of `f` continues in at the backward
// branch it just took, compiling `f` when the loop's credit says so; null when
// there is none. The code enters at ds.curr_pc, which it knows when it is a
// loop entry and otherwise hands back to the baseline code.
fn void* opt_osr(Dispatch* ds, CompiledFunction* f) @noinline {
    Heap* h = ds.heap;
    opt_note_entry(h, f, BASELINE_LOOP_CREDIT);
    if (f.opt_code == null || f.opt_state != OPT_ACTIVE) return null;
    return ((BaselineCode*)f.jit_code).exec;
}

// The slow path of a back edge's poll in optimized code: the budget expired or a
// hook is installed. Zero continues the loop; nonzero leaves for the baseline code.
fn long opt_poll(Dispatch* ds) {
    Heap* h = ds.heap;
    if (h.capi_interrupt_fn != null || h.capi_runtime != null) return 1;
    if (--h.bwd_gc_budget == 0) {
        if (h.gc_pending) h.safepoint_gc(heap::GC_LOOP_WORK);
        h.bwd_gc_budget = heap::BWD_GC_INTERVAL;
    }
    return 0;
}

// Whether any instruction of `f` has recorded a non-int32 operand, the sign
// that the baseline has seen what there is to specialize on.
fn bool opt_has_feedback(CompiledFunction* f) {
    if (f.ic_entries == null) return false;
    hobject::ICEntry* ic = (hobject::ICEntry*)f.ic_entries;
    for (uint i = 0; i < f.code_count; i++) {
        if ((ic[i].feedback & hobject::FB_OPERANDS) != 0) return true;
    }
    return false;
}

// Whether any call site of `f` has recorded its callee.
fn bool opt_has_call_feedback(CompiledFunction* f) {
    if (f.ic_entries == null) return false;
    hobject::ICEntry* ic = (hobject::ICEntry*)f.ic_entries;
    for (uint i = 0; i < f.code_count; i++) {
        if ((ic[i].feedback & hobject::FB_CALL) != 0) return true;
    }
    return false;
}

fn bool opt_refuse(Heap* h, CompiledFunction* f, OptRefuse why, Opcode op) {
    h.opt.refused++;
    h.opt.refused_why[why.ordinal]++;
    if (why == OptRefuse.OPCODE) h.opt.refused_ops[op.ordinal]++;
    f.opt_state = OPT_REFUSED;
    return false;
}

fn bool opt_try_compile(Heap* h, CompiledFunction* f) @noinline {
    OptPolicy* p = &h.opt;
    JitStats* st = &h.jit_stats;
    if (f.jit_code == null || f.opt_code != null || f.opt_state != OPT_NONE) return false;
    if (!p.always && !opt_has_feedback(f)) return false;
    // Forcing exits from inlined bodies needs bodies that have a callee to inline.
    if (p.force_inline && !opt_has_call_feedback(f)) return false;
    if (p.live_bytes >= OPT_CODE_MAX) return opt_refuse(h, f, OptRefuse.BUDGET, Opcode.NOP);
    if (!opt_function_eligible(f)) return opt_refuse(h, f, OptRefuse.FUNCTION, Opcode.NOP);
    long t0 = st.timing ? (long)clock::now() : 0;
    OptGraph g;
    g.init();
    defer g.free();
    OptBuild b;
    Opcode refused_op = Opcode.NOP;
    OptRefuse why = opt_build_graph(h, f, &g, &b, &refused_op, false);
    OptPools pools = opt_pools();
    if (why == OptRefuse.NONE && !g.allocate(&pools)) why = OptRefuse.PRESSURE;
    if (why != OptRefuse.NONE && b.sites.len() != 0) {
        // Inlining may be what made the body too big or too hard to allocate: try without it.
        b.free();
        g.clear();
        refused_op = Opcode.NOP;
        why = opt_build_graph(h, f, &g, &b, &refused_op, true);
        pools = opt_pools();
        if (why == OptRefuse.NONE && !g.allocate(&pools)) why = OptRefuse.PRESSURE;
    }
    defer b.free();
    uint inlined = (uint)g.fns.len() - 1;
    if (why != OptRefuse.NONE) return opt_refuse(h, f, why, refused_op);
    OptCode* oc = h.alloc_func(h.heap_udata, OptCode::size);
    if (oc == null) return false;
    mem::clear(oc, OptCode::size);
    oc.f = f;
    oc.base = f.jit_code;
    if (p.force_reason != 0) oc.forced = p.force_count;
    if (p.dump) g.dump(f);
    BaselineCode* code = opt_emit(h, f, &g, oc, pools);
    if (st.timing) st.compile_ns += (ulong)((long)clock::now() - t0);
    if (code == null) {
        if (oc.cells != null) h.free_func(h.heap_udata, oc.cells);
        h.free_func(h.heap_udata, oc);
        return opt_refuse(h, f, OptRefuse.COMPILE, Opcode.NOP);
    }
    oc.code = code;
    usz bytes = code.code_bytes + code.table_bytes;
    p.live_bytes += bytes;
    st.live_bytes += bytes;
    if (st.live_bytes > st.peak_bytes) st.peak_bytes = st.live_bytes;
    p.compiled++;
    p.inlined += inlined;
    if (f.opt_reopts != 0) p.reopts++;
    f.opt_code = oc;
    f.opt_state = OPT_ACTIVE;
    f.jit_code = code;
    return true;
}

// Reinstall the baseline code of `f` and retire its optimized body, which a
// native frame may still be running.
fn void opt_discard(Heap* h, CompiledFunction* f) {
    OptCode* oc = f.opt_code;
    if (oc == null) return;
    f.jit_code = oc.base;
    f.opt_code = null;
    oc.next_retired = h.opt.retired;
    h.opt.retired = oc;
    h.opt.discards++;
    f.opt_entries = 0;
    f.opt_reopts++;
    f.opt_state = f.opt_reopts > OPT_REOPT_MAX ? OPT_REFUSED_EXITS : OPT_NONE;
}

// Clear the shape ids of `oc` that no live shape holds, before the heap reuses them.
fn void OptCode.purge_cells(&self, Heap* h) {
    for (uint i = 0; i < self.cell_count; i++) {
        uint id = self.cells[i];
        if (id != heap::SHAPE_NONE && (id >= h.shape_count || !h.shape_slot_live(id))) self.cells[i] = heap::SHAPE_NONE;
    }
}

// Heap.purge_retired_shapes is about to free shape ids: no optimized code may keep one.
fn void opt_purge_shapes(Heap* h) {
    for (uint fi = 0; fi < h.compiled_func_count; fi++) {
        CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[fi];
        if (cf != null && cf.opt_code != null) ((OptCode*)cf.opt_code).purge_cells(h);
    }
    for (OptCode* oc = h.opt.retired; oc != null; oc = oc.next_retired) oc.purge_cells(h);
}

fn void opt_release(Heap* h, OptCode* oc) {
    BaselineCode* code = oc.code;
    while (oc.inline_exits != null) {
        OptInlineExit* x = oc.inline_exits;
        oc.inline_exits = x.next;
        h.free_func(h.heap_udata, x);
    }
    usz bytes = code.code_bytes + code.table_bytes;
    h.opt.live_bytes -= bytes;
    h.jit_stats.live_bytes -= bytes;
    sljit_free_code(code.exec, null);
    h.free_func(h.heap_udata, code);
    if (oc.cells != null) h.free_func(h.heap_udata, oc.cells);
    h.free_func(h.heap_udata, oc);
}

// Free the retired code, once no native frame can be running it.
fn void opt_reap(Heap* h) @noinline {
    OptCode* oc = h.opt.retired;
    h.opt.retired = null;
    while (oc != null) {
        OptCode* next = oc.next_retired;
        opt_release(h, oc);
        oc = next;
    }
}

// Release the optimized code of `f` with its baseline code (baseline_free).
fn void opt_free(Heap* h, CompiledFunction* f) {
    OptCode* oc = f.opt_code;
    if (oc == null) return;
    f.jit_code = oc.base;
    f.opt_code = null;
    opt_release(h, oc);
}

// Called by an optimized body that is leaving through exit `reason`, before it
// continues in the baseline code: count it, and discard the body when it has
// exited too often.
fn long opt_exit(Dispatch* ds, OptCode* oc, long reason) {
    Heap* h = ds.heap;
    h.opt.exits[reason]++;
    // An overflow of the int32 range is what the next compile specializes on.
    if (reason == OptExit.OVERFLOW.ordinal && oc.f.ic_entries != null) {
        uint at = (uint)(ds.curr_pc - ds.code_base);
        if (oc.f.code[at].op == Opcode.WIDE) at++;
        ((hobject::ICEntry*)oc.f.ic_entries)[at].feedback |= hobject::FB_OVF;
    }
    if (reason == OptExit.INTERRUPT.ordinal) return 0;
    oc.exits++;
    if (oc.f.opt_code == oc && oc.exits >= (h.opt.exit_max != 0 ? h.opt.exit_max : OPT_EXIT_MAX)) opt_discard(h, oc.f);
    return 0;
}

// opt_exit for an exit from inside an inlined body: count it and publish the callee's frame. Returns
// the baseline code of the callee to continue in at the exit's word.
fn void* opt_inline_exit(Dispatch* ds, OptCode* oc, long reason, OptInlineExit* site) {
    Heap* h = ds.heap;
    h.opt.exits[reason]++;
    h.opt.inline_exits++;
    CompiledFunction* callee = site.callee;
    if (reason == OptExit.OVERFLOW.ordinal && callee.ic_entries != null) {
        ((hobject::ICEntry*)callee.ic_entries)[site.pc].feedback |= hobject::FB_OVF;
    }
    oc.exits++;
    if (oc.f.opt_code == oc && oc.exits >= (h.opt.exit_max != 0 ? h.opt.exit_max : OPT_EXIT_MAX)) opt_discard(h, oc.f);
    return vm::jit_inline_materialize(ds, callee, site.base, site.nargs, site.resume, site.pc, site.keep);
}

// An exit at the start of instruction `i` through `reason`, taken `oc.forced`
// times (the test hook, --opt-force-exit).
fn void Asm.emit_opt_exit(&self, OptCode* oc, uint reason, bool counted) {
    void* c = self.c;
    void* skip = null;
    if (counted) {
        sljit_emit_op1(c, SLJIT_MOV, R0, 0, SLJIT_IMM, (long)(usz)&oc.forced);
        sljit_emit_op1(c, SLJIT_MOV_U32, R1, 0, SLJIT_MEM | R0, 0);
        skip = sljit_emit_cmp(c, SLJIT_EQUAL, R1, 0, SLJIT_IMM, 0);
        sljit_emit_op2(c, SLJIT_SUB, R1, 0, R1, 0, SLJIT_IMM, 1);
        sljit_emit_op1(c, SLJIT_MOV_U32, SLJIT_MEM | R0, 0, R1, 0);
    }
    sljit_emit_op2(c, SLJIT_ADD, R1, 0, self.code, 0, SLJIT_IMM, (long)self.i * Instruction::size);
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | self.ds, self.pc_off, R1, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)oc);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)reason);
    sljit_emit_icall(c, SLJIT_CALL, SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&opt_exit);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    sljit_emit_icall(c, SLJIT_CALL | SLJIT_CALL_RETURN, SLJIT_ARGS1WW, SLJIT_IMM, (long)(usz)oc.base.exec);
    if (skip != null) sljit_set_label(skip, sljit_emit_label(c));
}

fn void opt_print_stats(Heap* h) {
    OptPolicy* p = &h.opt;
    io::eprintfn("opt inline: %d callees inlined, %d exits from inlined bodies", p.inlined, p.inline_exits);
    io::eprintfn("opt: compiled %d (%d reoptimized), discarded %d, refused %d; live %d bytes",
                 p.compiled, p.reopts, p.discards, p.refused, p.live_bytes);
    foreach (r : OptExit::values) {
        if (p.exits[r.ordinal] != 0) io::eprintfn("opt exit %s: %d", r.label, p.exits[r.ordinal]);
    }
    foreach (r : OptRefuse::values) {
        if (p.refused_why[r.ordinal] != 0) io::eprintfn("opt refused %s: %d", r.label, p.refused_why[r.ordinal]);
    }
    foreach (op : Opcode::values) {
        if (p.refused_ops[op.ordinal] != 0) io::eprintfn("opt refused opcode %s: %d", op, p.refused_ops[op.ordinal]);
    }
}

// Parse REASON[:INSN[:COUNT]] of --opt-force-exit.
fn bool opt_parse_force(OptPolicy* p, String spec) {
    String[] parts = spec.tsplit(":");
    if (parts.len == 0 || parts.len > 3) return false;
    bool found = false;
    String name = parts[0];
    // `inline/REASON` leaves only from a node of an inlined body.
    if (name.starts_with("inline/")) {
        p.force_inline = true;
        name = name[7..];
    }
    foreach (r : OptExit::values) {
        if (r.label == name) { p.force_reason = (uint)r.ordinal + 1; found = true; }
    }
    if (!found) return false;
    p.force_count = 1;
    if (parts.len > 1) { uint? v = parts[1].to_uint(); if (catch v) return false; p.force_at = v; }
    if (parts.len > 2) { uint? v = parts[2].to_uint(); if (catch v) return false; p.force_count = v; }
    return true;
}
