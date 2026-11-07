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
    // An inlined body's instruction that had never run was reached.
    COLD {"cold"},
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
// Entries one expiry of the back-edge budget (heap::BWD_GC_INTERVAL backward branches, counted
// across all frames) credits to the function whose branch used it up. A loop that iterates this
// often is as hot as a function entered this many times; OPT_ENTRY_THRESHOLD / OPT_LOOP_CREDIT
// expiries (a few thousand of the function's own iterations) optimize it.
const uint OPT_LOOP_CREDIT = OPT_ENTRY_THRESHOLD / 4;
// The attempts on call feedback alone that found nothing to inline before the function waits for operand feedback.
const char OPT_DECLINE_MAX = 3;
// Own-field accesses with a recorded shape that make a function worth optimizing on their own.
const uint OPT_FIELD_SITES = 2;
const uint OPT_EXIT_MAX = 8;
const char OPT_REOPT_MAX = 2;
const usz OPT_CODE_MAX = 4 * 1024 * 1024;
// Exits at one site that discard a body and make the next build lower the site generically.
const uint OPT_SITE_EXITS = 2;
const uint OPT_BAN_MAX = 16;
// OptBan.pc naming every site of the function.
const uint OPT_BAN_ALL = 0xFFFFFFFF;
const uint OPT_HIT_SLOTS = 8;

// An instruction (word `pc` of `cf`, which may be an inlined callee) whose speculation failed
// repeatedly; the optimizer lowers it as the baseline would instead of guarding it again.
struct OptBan {
    CompiledFunction* cf;
    uint pc;
}

struct OptBans {
    uint count;
    OptBan[OPT_BAN_MAX] items;
}

// Exits taken at one site of an optimized body.
struct OptSiteHit {
    CompiledFunction* cf;
    uint pc;
    uint count;
    bool call;
}

struct OptCode {
    // The code installed as f.jit_code while the function is optimized.
    BaselineCode* code;
    // The baseline code an exit continues in.
    BaselineCode* base;
    CompiledFunction* f;
    OptCode* next_retired;
    uint exits;
    OptSiteHit[OPT_HIT_SLOTS] hits;
    uint hit_next;
    // Test hook (--opt-force-exit): exits still to take at the chosen pc.
    uint forced;
    // The shape id each field access of the code compares against, in memory so that
    // Heap.purge_retired_shapes can clear one whose id is about to be reused.
    uint* cells;
    uint cell_count;
    // The exits taken from inside inlined bodies.
    OptInlineExit* inline_exits;
    // A boxed value the put-absent paths of an inlined constructor read through its address
    // (OptCg.emit_add_field); nothing runs between its store and its use.
    ulong value;
    // The sites of the allocations the code sinks.
    OptSinkSite* sink_sites;
}

// The run-time state of a sunk allocation (opt_sink.c3), which vm::jit_opt_sink_check validates:
// the object `new` of `ctor` builds has prototype `proto`, adding each key keeps a plain own data
// property (no object of the chain has it), and each read key is the data property at byte offset
// read_off of read_owner's values. The emitted code takes it for holding while the constructor,
// its shape, the slot `new` reads the prototype from and the heap's prototype and shape-recycle
// epochs are those it was validated with (every object of the chain is marked observed, so a
// change to any moves the prototype epoch). An exit allocates the object from it, with the field
// values its code stored in `values`.
struct OptSinkSite {
    void* ctor;
    ulong proto_bits;
    ulong epoch;
    uint ctor_shape;
    uint recycle;
    // The byte offset of the prototype slot in the constructor's values.
    ulong proto_off;
    // The NEW_OBJ's cache, and the property count the object is built with room for.
    hobject::ICEntry* new_ic;
    uint want;
    uint add_count;
    uint read_count;
    void* proto;
    void*[OPT_SINK_FIELDS] keys;
    void*[OPT_SINK_READS] read_keys;
    void*[OPT_SINK_READS] read_owner;
    ulong[OPT_SINK_READS] read_off;
    ulong[OPT_SINK_FIELDS] values;
    OptSinkSite* next;
}

// Calls an optimized body inlines into each other at most, the outermost included.
const uint OPT_INLINE_DEPTH = 3;

// One frame an exit from inside an inlined body publishes: the call it replaced, as that call
// would have entered `callee`.
struct OptInlineFrame {
    CompiledFunction* callee;
    // The instruction after the call in its caller (the frame published before this one, or the
    // optimized function's).
    Instruction* resume;
    // The callee's register 0 as a register of the optimized function's frame.
    uint base;
    uint nargs;
    // The count of arguments the call passed, which a forwarding callee's `arguments` holds.
    uint argc;
    // The callee registers that hold values there: live at the exit for the innermost frame,
    // live across its own inlined call for the others.
    uint keep;
}

// Where an exit from inside an inlined callee's body goes: the frames of the calls it is nested
// in are published, outermost first, and the innermost callee's baseline code continues at `pc`.
struct OptInlineExit {
    OptInlineFrame[OPT_INLINE_DEPTH] frames;
    uint depth;
    // The innermost callee's word the exit resumes at.
    uint pc;
    OptInlineExit* next;
}

struct OptPolicy {
    bool enabled;
    // Do not inline calls.
    bool no_inline;
    // Bisection aid (--opt-inline-max=N): inline only the first N sites tried, over all compiles.
    uint inline_max;
    uint inline_seen;
    // Callees inlined, and exits taken from inside an inlined body, over all compiles.
    uint inlined;
    uint inline_exits;
    // Do not sink allocations (--opt-no-sink); allocations sunk over all compiles, and the objects
    // exits allocated for them and the validations of their sites at run time.
    bool no_sink;
    uint sunk;
    ulong sink_materialized;
    ulong sink_checks;
    // With --jit-count-ops: inlined NEW_OBJ objects allocated, and not allocated (sunk).
    ulong alloc_runs;
    ulong sink_runs;
    // Call sites with a known callee that were not inlined, by OptInlineReject, and by opcode for
    // the callees refused for one.
    ulong[OptInlineReject::values.len] inline_rejected;
    ulong[Opcode::values.len] inline_rejected_ops;
    // Optimize every function as soon as it has baseline code.
    bool always;
    // Print each optimized function's graph (--opt-dump).
    bool dump;
    // Test hook: zero, or one more than the OptExit every optimized body
    // takes `force_count` times at instruction `force_at`.
    uint force_reason;
    uint force_at;
    uint force_count;
    // The forced exit is taken at a node of an inlined body only, nested at least force_depth deep.
    bool force_inline;
    uint force_depth;
    // Exits that discard a body, OPT_EXIT_MAX when zero.
    uint exit_max;
    // Native code in progress anywhere on the C stack; retired code is freed when it reaches zero.
    uint running;
    OptCode* retired;
    usz live_bytes;
    ulong compiled;
    ulong discards;
    ulong reopts;
    // Sites lowered generically after repeated exits.
    ulong bans;
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
    opt_note_entry(h, f, OPT_LOOP_CREDIT);
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
fn bool opt_has_operand_feedback(CompiledFunction* f) {
    if (f.ic_entries == null) return false;
    hobject::ICEntry* ic = (hobject::ICEntry*)f.ic_entries;
    for (uint i = 0; i < f.code_count; i++) {
        if ((ic[i].feedback & hobject::FB_OPERANDS) != 0) return true;
    }
    return false;
}

fn bool opt_has_feedback(Heap* h, CompiledFunction* f) {
    if (opt_has_operand_feedback(f)) return true;
    if (f.ic_entries == null || f.opt_declined >= OPT_DECLINE_MAX) return false;
    if (opt_has_field_feedback(f)) return true;
    hobject::ICEntry* ic = (hobject::ICEntry*)f.ic_entries;
    // A function of integers alone records no operand feedback, but a call to a body the tier can
    // inline is something to specialize on.
    for (uint i = 0; i < f.code_count; i++) {
        if ((ic[i].feedback & (hobject::FB_CALL | hobject::FB_CTOR)) != 0 && opt_inline_plausible(h, f, i)) return true;
    }
    return false;
}

// Whether `f` has run at least OPT_FIELD_SITES property accesses that the tier can lower to a
// guarded slot access: own data properties with a recorded shape. Such a function has shapes to
// specialize on even though its arithmetic never left int32.
fn bool opt_has_field_feedback(CompiledFunction* f) {
    if (f.ic_entries == null) return false;
    hobject::ICEntry* ic = (hobject::ICEntry*)f.ic_entries;
    uint sites = 0;
    for (uint i = 0; i < f.code_count; i++) {
        switch (f.code[i].op) {
            case GETPROPC: case GETPROPC_CACHED: case GETTHISC: case PUTPROPC: case PUTTHISC:
                hobject::ICEntry* e = &ic[i];
                if (e.key.borrow() == null || e.shape_id == heap::SHAPE_NONE || e.has_proto) break;
                if (e.chain_len != 0 && e.chain_len != hobject::IC_CHAIN_POLY) break;
                if (e.prop_idx == hobject::IC_PROP_ABSENT || e.prop_flags.is_accessor) break;
                if (++sites >= OPT_FIELD_SITES) return true;
            default:
        }
    }
    return false;
}

// Whether the call at word `i` of `f` names a callee that looks like an inline site: the cheap part
// of OptBuild.inline_candidate, the size and the opcodes of its body.
fn bool opt_inline_plausible(Heap* h, CompiledFunction* f, uint i, uint depth = 1) {
    Opcode op = f.code[i].op;
    bool var_call = op == Opcode.CALL_VAR || op == Opcode.CALL_GLOBAL;
    // A forwarding call (APPLY_ARGS) of a forwarding body.
    if (op != Opcode.CALL && op != Opcode.CALL_UNDEF_THIS && op != Opcode.NEW_OBJ && op != Opcode.APPLY_ARGS && !var_call) return false;
    CompiledFunction* cf = opt_site_callee(h, f, i);

    if (cf == null || cf == f || cf.code_count > INLINE_WORDS_MAX || cf.num_regs > 32) return false;
    if (!opt_function_eligible(cf, true)) return false;
    if (op == Opcode.NEW_OBJ && !opt_base_constructor(cf)) return false;
    cf.classify_lean_call();
    if (!cf.call_flags.lean_call || (op != Opcode.CALL && op != Opcode.NEW_OBJ && op != Opcode.APPLY_ARGS && !cf.call_flags.lean_plain)) return false;
    for (uint k = 0; k < cf.code_count; k++) {
        Opcode kop = cf.code[k].op;
        if (!inline_op_ok(kop)) return false;
        // A call in the body must be one to inline in turn (OptBuild.add_children).
        if (inline_call_op(kop) && (depth >= OPT_INLINE_DEPTH || cf.ic_entries == null || !opt_inline_plausible(h, cf, k, depth + 1))) return false;
    }
    return true;
}

// The one compiled function the call or NEW_OBJ at word `i` of `f` has called, by its feedback, or
// null. A NEW_OBJ's entry caches the constructor's `prototype` read and keeps the callee apart
// (hobject::FB_CTOR).
fn CompiledFunction* opt_site_callee(Heap* h, CompiledFunction* f, uint i) {
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[i];
    bool ctor = f.code[i].op == Opcode.NEW_OBJ;
    uint index = ctor ? ic.absent_next_shape : ic.prop_idx;
    if ((ic.feedback & (ctor ? hobject::FB_CTOR : hobject::FB_CALL)) == 0 || (ic.feedback & hobject::FB_POLY) != 0) return null;
    if (index >= h.compiled_func_count) return null;
    return (CompiledFunction*)h.compiled_funcs[index];
}

// Whether `new` of a closure of `cf` builds a plain object and runs `cf` on it: a base
// constructor without private names or field initializers.
fn bool opt_base_constructor(CompiledFunction* cf) {
    return !cf.is_arrow() && !cf.is_derived_ctor() && cf.brand_name_hstr == null && cf.field_init_func == null;
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

// Whether the instruction at word `pc` of `cf` (the function `root` is optimizing, or a callee
// inlined into it) exited from optimized code often enough that it is no longer speculated on.
fn bool opt_site_banned(CompiledFunction* root, CompiledFunction* cf, uint pc) {
    OptBans* bans = root.opt_bans;
    if (bans == null) return false;
    for (uint i = 0; i < bans.count; i++) {
        if (bans.items[i].cf == cf && (bans.items[i].pc == pc || bans.items[i].pc == OPT_BAN_ALL)) return true;
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
    if (!p.always && !opt_has_feedback(h, f)) return false;
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
    uint sunk = why == OptRefuse.NONE && !p.no_sink ? g.sink() : 0;
    if (why == OptRefuse.NONE && !g.allocate(&pools)) why = OptRefuse.PRESSURE;
    if (sunk != 0 && (why != OptRefuse.NONE || g.sink_spilled())) {
        // A field value of a sunk object found no register: build the same graph without sinking.
        b.free();
        g.clear();
        refused_op = Opcode.NOP;
        sunk = 0;
        why = opt_build_graph(h, f, &g, &b, &refused_op, false);
        pools = opt_pools();
        if (why == OptRefuse.NONE && !g.allocate(&pools)) why = OptRefuse.PRESSURE;
    }
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
    // Call feedback alone is worth optimizing for only when the call was inlined.
    if (why == OptRefuse.NONE && inlined == 0 && !p.always && !opt_has_operand_feedback(f) && !(opt_has_field_feedback(f) && g.polys.len() >= OPT_FIELD_SITES)) {
        f.opt_declined++;
        return false;
    }
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
        while (oc.sink_sites != null) {
            OptSinkSite* x = oc.sink_sites;
            oc.sink_sites = x.next;
            h.free_func(h.heap_udata, x);
        }
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
    p.sunk += sunk;
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
    opt_ban_hits(h, oc);
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
    while (oc.sink_sites != null) {
        OptSinkSite* x = oc.sink_sites;
        oc.sink_sites = x.next;
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
    if (f.opt_bans != null) {
        h.free_func(h.heap_udata, f.opt_bans);
        f.opt_bans = null;
    }
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
    bool repeat = false;
    if (oc.f.opt_code == oc && oc.f.ic_entries != null) {
        uint at = (uint)(ds.curr_pc - ds.code_base);
        if (oc.f.code[at].op == Opcode.WIDE) at++;
        repeat = opt_note_site_exit(oc, oc.f, at, reason);
    }
    if (oc.f.opt_code == oc && (repeat || oc.exits >= opt_exit_limit(h))) opt_discard(h, oc.f);
    return 0;
}

fn uint opt_exit_limit(Heap* h) @inline => h.opt.exit_max != 0 ? h.opt.exit_max : OPT_EXIT_MAX;

// Whether `reason` is a failed guard of one instruction that a rebuild can leave unspeculated.
// A guard on a value's type is one a rebuild adapts to by the operand feedback, except in an inlined
// body, whose typed loads it does not re-derive (`inlined`).
fn bool opt_exit_bannable(long reason, bool inlined = false) {
    switch ((OptExit)reason) {
        case SHAPE: case SLOW_PATH: case CALLEE: case BOUNDS: case HOLE:
            return true;
        case NOT_NUMBER: case NOT_INT32:
            return inlined;
        default:
            return false;
    }
}

// Count an exit of `oc` at word `pc` of `cf`; true at the OPT_SITE_EXITS-th exit at one site, which
// discards the body: rebuilding it without those exits is better than taking them OPT_EXIT_MAX
// times. Only a failed guard of one instruction is counted, since only that changes the next build.
fn bool opt_note_site_exit(OptCode* oc, CompiledFunction* cf, uint pc, long reason, bool inlined = false) {
    if (!opt_exit_bannable(reason, inlined)) return false;
    OptSiteHit* hit = null;
    foreach (&x : oc.hits) {
        if (x.cf == cf && x.pc == pc && x.count != 0) hit = x;
    }
    if (hit == null) {
        hit = &oc.hits[oc.hit_next++ % OPT_HIT_SLOTS];
        hit.cf = cf;
        hit.pc = pc;
        hit.count = 0;
        hit.call = reason == OptExit.CALLEE.ordinal;
    }
    return ++hit.count >= OPT_SITE_EXITS;
}

// Record every site `oc` exited from, so that the next build lowers each generically.
fn void opt_ban_hits(Heap* h, OptCode* oc) {
    CompiledFunction* root = oc.f;
    foreach (&x : oc.hits) {
        if (x.count == 0) continue;
        // The cache of one site a body exits from is as stale as its neighbours', which the body would
        // exit from next: the second time a body of the function is discarded, none is speculated on.
        uint pc = root.opt_reopts != 0 && !x.call ? OPT_BAN_ALL : x.pc;
        if (opt_site_banned(root, x.cf, pc)) continue;
        OptBans* bans = root.opt_bans;
        if (bans == null) {
            bans = h.alloc_func(h.heap_udata, OptBans::size);
            if (bans == null) return;
            mem::clear(bans, OptBans::size);
            root.opt_bans = bans;
        }
        if (bans.count >= OPT_BAN_MAX) return;
        bans.items[bans.count++] = { .cf = x.cf, .pc = pc };
        h.opt.bans++;
    }
}

// opt_exit for an exit from inside an inlined body: count it and publish the frames of the calls
// it is nested in. Returns the baseline code of the innermost callee to continue in at the exit's word.
fn void* opt_inline_exit(Dispatch* ds, OptCode* oc, long reason, OptInlineExit* site) {
    Heap* h = ds.heap;
    h.opt.exits[reason]++;
    h.opt.inline_exits++;
    CompiledFunction* callee = site.frames[site.depth - 1].callee;
    if (reason == OptExit.OVERFLOW.ordinal && callee.ic_entries != null) {
        ((hobject::ICEntry*)callee.ic_entries)[site.pc].feedback |= hobject::FB_OVF;
    }
    oc.exits++;
    // A site of an inlined body cannot be lowered generically: the next build leaves the call it is
    // in a call (inline_body_ok), as it does a call site that exited.
    bool repeat = oc.f.opt_code == oc && opt_exit_bannable(reason, true) && opt_note_site_exit(oc, callee, site.pc, reason, true);
    if (oc.f.opt_code == oc && (repeat || oc.exits >= opt_exit_limit(h))) opt_discard(h, oc.f);
    return vm::jit_inline_materialize(ds, site);
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
    io::eprintfn("opt sink: %d allocations sunk, %d site validations, %d objects allocated by exits", p.sunk, p.sink_checks, p.sink_materialized);
    if (h.jit_stats.count_ops) io::eprintfn("opt sink: %d inlined news allocated, %d sunk", p.alloc_runs, p.sink_runs);
    foreach (r : OptInlineReject::values) {
        if (p.inline_rejected[r.ordinal] != 0) io::eprintfn("opt inline rejected %s: %d", r.label, p.inline_rejected[r.ordinal]);
    }
    foreach (op : Opcode::values) {
        if (p.inline_rejected_ops[op.ordinal] != 0) io::eprintfn("opt inline rejected opcode %s: %d", op, p.inline_rejected_ops[op.ordinal]);
    }
    io::eprintfn("opt: compiled %d (%d reoptimized), discarded %d, refused %d; live %d bytes",
                 p.compiled, p.reopts, p.discards, p.refused, p.live_bytes);
    io::eprintfn("opt: %d sites lowered generically after repeated exits", p.bans);
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
    // `inline/REASON` leaves only from a node of an inlined body; `inline2/` and `inline3/` from
    // one nested in that many inlined calls.
    p.force_depth = 1;
    if (name.starts_with("inline/")) {
        p.force_inline = true;
        name = name[7..];
    } else if (name.len > 8 && name.starts_with("inline") && name[7] == '/' && name[6] >= '2' && name[6] <= '3') {
        p.force_inline = true;
        p.force_depth = name[6] - '0';
        name = name[8..];
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
