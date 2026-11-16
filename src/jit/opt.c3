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
import boomkat::compiler;
import boomkat::heap;
import boomkat::hobject;
import boomkat::types;
import boomkat::builtins;
import boomkat::features;
import std::io;
import std::collections::list;
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
    // An element access with no recorded class met a receiver that is not an array. The code
    // recorded the class on the way out, so the rebuild specializes on it.
    UNPROFILED {"unprofiled"},
    // An inherited read built for the one receiver shape its entry had ever held met another. The
    // exit adds it to the entry's set, which the rebuild reads through instead.
    RECEIVER {"receiver"},
    // A register call's callee has no code with a call entry now: the baseline makes the call, and
    // a rebuild calls it as it is. The site is no worse a choice for that.
    DECLINED {"declined"},
    // A register call's callee declined it for want of native stack, records or value stack: deep
    // recursion, which the baseline continues. Not a failed speculation.
    DEEP {"deep"},
    // A binding the code folded no longer holds its value, or its holder's layout moved
    // (OptOp.GUARD_BINDING). The rebuild reads the binding instead.
    BINDING {"binding"},
    // The running closure is not the one whose captured bindings the code folded
    // (OptOp.GUARD_CAPTURE). The rebuild folds none of them.
    CAPTURE {"capture"},
    // An entry from the baseline code into a loop met an object or binding other than the loop's
    // code assumes there (OptCg.emit_entry_facts). The rebuild reads the caches the baseline code
    // has updated since.
    ENTRY {"entry"},
    // A watched binding changed (OptPolicy.watch_epoch). The rebuild reads it instead.
    WATCH {"watch"},
    // A parameter checked as a number on entry, for the phi of a loop that carries it
    // (OptBuild.entry_checks), held something else. The rebuild leaves the parameters in the window.
    PARAM {"param"},
}

// A binding whose object value optimized code holds as a constant: slot `idx` of `holder`, a
// bindings_watched object. No store fast path writes the slot (opt_watch), so every write reaches
// opt_watch_store, which fires the watch when the value changes, as a change to the property or
// its deletion does (opt_watch_property).
struct OptWatch {
    HObject* holder;
    uint idx;
    ulong value;
}

// Marks a recorded element class (ICEntry.fwd_callee) as written by optimized code, so that a
// class word of 0 still reads as recorded. No layout mask covers bit 0.
const uint ELEM_CLASS_SEEN = 1;

// Whether optimized code of the element access whose cache entry is word `at` of `f` leaves for
// any object but an array: one its baseline code has recorded no other class for (OptExit.UNPROFILED).
fn bool opt_elem_arrays_only(CompiledFunction* f, uint at) {
$if features::BUFFERS:
    return f.ic_entries != null && (long)((hobject::ICEntry*)f.ic_entries)[at].fwd_callee == 0;
$else
    return true;
$endif
}

const char OPT_NONE = 0;
const char OPT_ACTIVE = 1;
// Compiling failed or hit a cap; the function stays on its baseline code.
const char OPT_REFUSED = 2;
// Optimized code exited too often, too many times.
const char OPT_REFUSED_EXITS = 3;
// The function's graph was refused, as too large or for an instruction the graph does not take,
// and its hot loops may compile on their own (OptRegion) when a frame's back edge asks.
const char OPT_REGION = 4;
// Region builds that may fail before the function is refused; each tries a narrower loop.
const char OPT_REGION_TRIES = 4;
// Loops nested around a region's header that opt_find_region weighs.
const uint OPT_REGION_NEST = 32;

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
// Integer arithmetic, bitwise and element instructions that make a function worth optimizing alone.
const uint OPT_INT_WORK = 8;
const uint OPT_EXIT_MAX = 8;
const char OPT_REOPT_MAX = 2;
// Discards after UNPROFILED exits that do not count as reoptimizations. Each such exit records a
// class, so a function has at most as many as it has element sites; this bounds the rest.
const char OPT_RELEARN_MAX = 16;
// Bytes of optimized code kept; past them the sweep evicts the bodies not entered recently.
const usz OPT_CODE_MAX = 4 * 1024 * 1024;
// Exits at one site that discard a body and make the next build lower the site generically.
const uint OPT_SITE_EXITS = 2;
const uint OPT_BAN_MAX = 16;
// OptBan.pc naming every site of the function.
const uint OPT_BAN_ALL = 0xFFFFFFFF;
// OptBan.pc naming the entry checks of the function's parameters (OptExit.PARAM).
const uint OPT_BAN_PARAMS = 0xFFFFFFFE;
const uint OPT_HIT_SLOTS = 8;
// Global bindings remembered as changing (OptPolicy.unfolded).
const uint OPT_UNFOLD_MAX = 64;
// Bindings watched at once (OptPolicy.watches).
const uint OPT_WATCH_MAX = 128;
// Rebuilds that move phis without a machine register to the window before the function is refused.
const uint OPT_PRESSURE_ROUNDS = 6;

// An instruction (word `pc` of `cf`, which may be an inlined callee) whose speculation failed
// repeatedly; the optimizer lowers it as the baseline would instead of guarding it again.
struct OptBan {
    CompiledFunction* cf;
    uint pc;
    // Only the folding of the binding read there (OptExit.BINDING, CAPTURE): the site still reads it.
    bool fold;
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
    bool fold;
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
    // A constant constructor whose `prototype`, proto, the code watches: no cache is read.
    bool fixed;
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

// Calls an optimized body inlines into each other at most, the outermost included (JSC's DFG
// allows 5 too).
const uint OPT_INLINE_DEPTH = 5;

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
    uint depth;
    // The innermost callee's word the exit resumes at.
    uint pc;
    OptInlineExit* next;
    // `depth` of them.
    OptInlineFrame[*] frames;
}

struct OptPolicy {
    bool enabled;
    // Do not inline calls.
    bool no_inline;
    // Do not compile the loops of a refused function on their own (OptRegion).
    bool no_region;
    // Testing aid (--opt-region-always): refuse every function that has a loop, which then
    // compiles its loops as regions.
    bool region_always;
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
    // Print each exit, discard and refusal with its function (--opt-log).
    bool log;
    // The slots of bindings whose folded value a guard found changed (OptExit.BINDING): no
    // build folds them again, so a binding the program writes costs one body's exits, not every
    // reader's. The oldest give way first.
    void*[OPT_UNFOLD_MAX] unfolded;
    uint unfolded_next;
    // The watched bindings, and the epoch a firing moves: code holding a watched value compares
    // it after anything that runs code (OPT_GUARD_WATCH).
    OptWatch[OPT_WATCH_MAX] watches;
    uint watch_count;
    uint watch_epoch;
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
    // Bytes of optimized code kept, OPT_CODE_MAX when zero (--opt-code-max).
    usz code_max;
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
    // Optimized bodies dropped by the eviction sweep to make room, and the sweeps that ran.
    ulong evicted;
    ulong sweeps;
    ulong[OptRefuse::values.len] refused_why;
    ulong[256] refused_ops;
    ulong[OptExit::values.len] exits;
    // Exits taken at each instruction opcode, for attributing a benchmark's exits to an opcode.
    ulong[Opcode::values.len] exit_ops;
    // Field sites left to the baseline by reason, and the opcodes of functions whose control flow
    // graph the optimizing tier could not build.
    ulong[OptFieldSkip::values.len] field_skipped;
    ulong[Opcode::values.len] refused_cfg_ops;
}

// Count an entry into native code of `f` (one for each `credit`) toward
// optimizing it, and do so when the policy says. A frame looping in `f` passes the loop header
// it branched back to and its window, which a function compiled by loops needs.
//
// Entries count in rounds of OPT_ENTRY_THRESHOLD, the count at which the baseline call entry
// calls this (jit_entry_service): each round folds into f.opt_rounds and starts the count
// over, so that a function waiting out a longer cool-off (opt_rounds_due) keeps its direct calls.
fn void opt_note_entry(Heap* h, CompiledFunction* f, Activation* act, uint credit = 1, uint osr_pc = uint::max, TVal* regs = null) @noinline {
    if (f.opt_state == OPT_REGION && f.opt_code == null) {
        // Calls count toward the loop's round as well; only a back edge can compile it.
        if (osr_pc != uint::max) f.opt_entries += credit;
        if (!opt_round_due(h, f) || osr_pc == uint::max) return;
        opt_reset_count(f);
        opt_try_compile(h, f, act, osr_pc, regs);
        return;
    }
    if (f.opt_state != OPT_NONE || f.opt_code != null) {
        // The baseline call entry calls at the threshold; start its count over.
        opt_reset_count(f);
        if (f.opt_code != null) ((BaselineCode*)f.jit_code).touched = 1;
        return;
    }
    f.opt_entries += credit;
    if (!opt_round_due(h, f)) return;
    // Without the feedback to specialize on, the next attempt waits for another round of entries.
    if (!opt_try_compile(h, f, act) && f.opt_state == OPT_NONE) opt_reset_count(f);
}

// Fold f's completed rounds of entries into f.opt_rounds and say whether the rounds due are in. A
// function whose body was discarded must earn a longer cool-off before each rebuild.
fn bool opt_round_due(Heap* h, CompiledFunction* f) @inline {
    if (f.opt_entries >= OPT_ENTRY_THRESHOLD) {
        uint rounds = f.opt_rounds + f.opt_entries / OPT_ENTRY_THRESHOLD;
        f.opt_rounds = rounds > 127 ? 127 : (char)rounds;
        f.opt_entries %= OPT_ENTRY_THRESHOLD;
    }
    return h.opt.always || f.opt_rounds >= 1u << (f.opt_reopts > 2 ? 2 : (uint)f.opt_reopts);
}

fn void opt_reset_count(CompiledFunction* f) @inline {
    f.opt_entries = 0;
    f.opt_rounds = 0;
}

// The optimized code a baseline frame of `f` continues in at the backward
// branch it just took, compiling `f` when the loop's credit says so; null when
// there is none. The code enters at ds.curr_pc, which it knows when it is a
// loop entry and otherwise hands back to the baseline code.
fn void* opt_osr(Dispatch* ds, CompiledFunction* f) @noinline {
    Heap* h = ds.heap;
    opt_note_entry(h, f, ds.act, OPT_LOOP_CREDIT, (uint)(ds.curr_pc - ds.code_base), ds.regs_base);
    if (f.opt_code == null || f.opt_state != OPT_ACTIVE) return null;
    return baseline_jump_entry(f);
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
    if (opt_has_operand_feedback(f) || opt_has_int_work(f)) return true;
    if (f.ic_entries == null || f.opt_declined >= OPT_DECLINE_MAX) return false;
    if (opt_has_field_feedback(f)) return true;
    hobject::ICEntry* ic = (hobject::ICEntry*)f.ic_entries;
    // A function of integers alone records no operand feedback, but a call to a body the tier can
    // inline is something to specialize on.
    for (uint i = 0; i < f.code_count; i++) {
        OptCallees set;
        if ((ic[i].feedback & (hobject::FB_CALL | hobject::FB_CTOR)) != 0 && (opt_inline_plausible(h, f, i) || opt_direct_targets(h, f, i, &set))) return true;
        if (opt_node_call_site(h, f, i) || opt_string_regexp_site(f, i)) return true;
    }
    return false;
}

// Whether the CALL at word `i` of `f` has always called a String.prototype method the tier builds
// as a STRING_REGEXP (OptBuild.string_regexp_call).
fn bool opt_string_regexp_site(CompiledFunction* f, uint i) {
    if (f.code[i].op != Opcode.CALL) return false;
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[i];
    if (hobject::ic_call_count(ic) != 1 || (ic.prop_idx & hobject::IC_BUILTIN_TARGET) == 0) return false;
    return vm::string_regexp_kind(ic.prop_idx & ~hobject::IC_BUILTIN_TARGET, f.code[i].c) >= 0;
}

// Whether `f` is mostly integer work the baseline runs boxed: at least OPT_INT_WORK arithmetic,
// bitwise and element instructions whose feedback (none) says int32 throughout, as asm.js-style
// code compiled from C is. Its operands never leave int32, so it records no operand feedback, yet
// unboxed registers are what the tier gives it.
fn bool opt_has_int_work(CompiledFunction* f) {
    if (f.ic_entries == null) return false;
    uint work = 0;
    for (uint i = 0; i < f.code_count; i++) {
        Opcode op = f.code[i].op;
        if (vm::has_feedback(op) || op == Opcode.GETPROP || op == Opcode.PUTPROP) {
            if (++work >= OPT_INT_WORK) return true;
        }
    }
    return false;
}

// Whether `f` has run at least OPT_FIELD_SITES property accesses that the tier can lower to a
// guarded slot access: own data properties with a recorded shape, or elements of arrays. Such a function has shapes to
// specialize on even though its arithmetic never left int32.
fn bool opt_has_field_feedback(CompiledFunction* f) {
    if (f.ic_entries == null) return false;
    hobject::ICEntry* ic = (hobject::ICEntry*)f.ic_entries;
    uint sites = 0;
    for (uint i = 0; i < f.code_count; i++) {
        switch (f.code[i].op) {
            case GETPROP:
                // An element read of arrays alone, which the tier loads inline with its index
                // unboxed.
                if (opt_elem_arrays_only(f, i)) return true;
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

fn bool opt_call_op(Opcode op) {
    switch (op) {
        case CALL: case CALL_PROP: case CALL_UNDEF_THIS: case NEW_OBJ: case CALL_S: case NEW_OBJ_S:
        case CALL_VAR: case CALL_GLOBAL:
            return true;
        default:
            return false;
    }
}

// Why the call at word `i` of `f` is not one opt_direct_targets proves, for --opt-log.
fn String opt_generic_reason(Heap* h, CompiledFunction* f, uint i) {
    Instruction w = f.code[i];
    bool var_call = w.op == Opcode.CALL_VAR || w.op == Opcode.CALL_GLOBAL;
    if (w.op != Opcode.CALL && w.op != Opcode.CALL_UNDEF_THIS && !var_call) return "opcode";
    if (opt_site_banned(f, f, i)) return "banned";
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[i];
    if ((ic.feedback & hobject::FB_CALL) == 0) return "no-feedback";
    if ((ic.feedback & hobject::FB_POLY) != 0) return "megamorphic";
    if ((ic.feedback & hobject::FB_DOTCALL) != 0) return "dotcall";
    uint count = hobject::ic_call_count(ic);
    uint nargs = var_call ? w.b : w.c;
    for (uint k = 0; k < count; k++) {
        uint index = hobject::ic_call_target(ic, k);
        if ((index & hobject::IC_BUILTIN_TARGET) != 0) {
            uint b = index & ~hobject::IC_BUILTIN_TARGET;
            if (b >= builtins::Builtin::values.len) return "builtin";
            return string::tformat("builtin%s:%d", builtins::leaf_of(b) == null ? "" : "-leaf", b);
        }
        if (index >= h.compiled_func_count) return "target-index";
        CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[index];
        if (cf == null) return "target-gone";
        if (cf.realm != f.realm) return "realm";
        if (!call_entry_eligible(cf)) return "no-call-entry";
        if (!entry_takes(cf, nargs, w.op != Opcode.CALL)) return "entry-refuses-args";
    }
    return "operands";
}

// The functions optimized code enters the call at word `i` of `f` into directly
// (OptBuild.direct_callee): every one its feedback names, each with a call entry that takes the
// call (entry_takes). Several only with register calls, which enter the function the callee holds.
// False, with `set` unfinished, when any is not such a function.
fn bool opt_direct_targets(Heap* h, CompiledFunction* f, uint i, OptCallees* set) {
    Instruction w = f.code[i];
    bool var_call = w.op == Opcode.CALL_VAR || w.op == Opcode.CALL_GLOBAL;
    if (w.op != Opcode.CALL && w.op != Opcode.CALL_UNDEF_THIS && !var_call) return false;
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[i];
    uint count = hobject::ic_call_count(ic);
    if (count == 0 || (count > 1 && !REG_CALLS) || (ic.feedback & hobject::FB_DOTCALL) != 0) return false;
    uint nargs = var_call ? w.b : w.c;
    for (uint k = 0; k < count; k++) {
        uint index = hobject::ic_call_target(ic, k);
        if (index >= h.compiled_func_count) return false;
        CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[index];
        if (cf == null || cf.realm != f.realm || !call_entry_eligible(cf) || !entry_takes(cf, nargs, w.op != Opcode.CALL)) return false;
        set.fns[k] = cf;
    }
    set.count = count;
    return true;
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
        // A call in the body must be one to inline in turn, or one to make from the body as a
        // register call (OptBuild.add_children).
        if (!inline_call_op(kop) || opt_node_call_site(h, cf, k)) continue;
        if (cf.ic_entries == null) return false;
        OptCallees set;
        if ((depth >= OPT_INLINE_DEPTH || !opt_inline_plausible(h, cf, k, depth + 1)) && !opt_direct_targets(h, cf, k, &set)) return false;
    }
    return true;
}

// Whether the CALL at word `i` of `f` is one the optimizer builds as a node rather than a call:
// a push (opt_push_site) or a RegExp exec or test (OptBuild.regexp_call).
fn bool opt_node_call_site(Heap* h, CompiledFunction* f, uint i) {
    if (opt_push_site(h, f, i)) return true;
    if (f.ic_entries == null || i == 0 || i >= f.code_count) return false;
    Instruction w = f.code[i];
    if (w.op != Opcode.CALL || w.c != 1 || f.code[i - 1].op == Opcode.WIDE) return false;
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[i];
    if (hobject::ic_call_count(ic) != 1 || (ic.prop_idx & hobject::IC_BUILTIN_TARGET) == 0) return false;
    uint builtin = ic.prop_idx & ~hobject::IC_BUILTIN_TARGET;
    return builtin == builtins::Builtin.REGEXP_PROTO_EXEC.ordinal || builtin == builtins::Builtin.REGEXP_PROTO_TEST.ordinal;
}

// Whether the CALL at word `i` of `f` passes one argument to Array.prototype.push as far as the
// read that loaded its callee says: the nearest instruction before it naming the callee register as
// its A operand, through register copies, is a GETPROPC or GETPROPC_CACHED whose cache holds that
// builtin on a prototype. The optimized code guards the callee itself (OptBuild.push_call).
fn bool opt_push_site(Heap* h, CompiledFunction* f, uint i) {
    if (f.ic_entries == null || i == 0 || i >= f.code_count) return false;
    Instruction w = f.code[i];
    if (w.op != Opcode.CALL || w.c != 1 || f.code[i - 1].op == Opcode.WIDE) return false;
    uint reg = w.b;
    for (uint k = i; k > 0 && i - k < 8; k--) {
        Instruction p = f.code[k - 1];
        if (p.op == Opcode.WIDE) return false;
        if (p.a != reg) continue;
        if (p.op == Opcode.LDREG) {
            reg = p.b;
            continue;
        }
        if (p.op != Opcode.GETPROPC && p.op != Opcode.GETPROPC_CACHED) return false;
        if (k >= 2 && f.code[k - 2].op == Opcode.WIDE) return false;
        return opt_cached_builtin(&((hobject::ICEntry*)f.ic_entries)[k - 1]) == (int)builtins::Builtin.ARRAY_PROTO_PUSH.ordinal;
    }
    return false;
}

// The number of the builtin function the read cache `ic` holds as a data property of a prototype,
// or -1.
fn int opt_cached_builtin(hobject::ICEntry* ic) {
$if types::USE_NANBOX:
    if (ic.key.borrow() == null || !ic.has_proto || ic.prop_flags.is_accessor) return -1;
    HObject* owner;
    if (ic.chain_len == hobject::IC_CHAIN_EPOCH) {
        owner = ic.chain.epoch.owner;
    } else if (ic.chain_len > 0 && (uint)ic.chain_len <= hobject::IC_MAX_CHAIN) {
        owner = (HObject*)ic.chain.snapshot.protos[(uint)ic.chain_len - 1];
    } else {
        return -1;
    }
    if (owner == null || ic.prop_idx >= owner.prop_count) return -1;
    return vm::jit_builtin_index(owner.prop_values()[ic.prop_idx].get());
$else
    return -1;
$endif
}

// The one compiled function the call or NEW_OBJ at word `i` of `f` has called, by its feedback, or
// null. A NEW_OBJ's entry caches the constructor's `prototype` read and keeps the callee apart
// (hobject::FB_CTOR).
fn CompiledFunction* opt_site_callee(Heap* h, CompiledFunction* f, uint i) {
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[i];
    bool ctor = f.code[i].op == Opcode.NEW_OBJ;
    uint index = ctor ? ic.absent_next_shape : ic.prop_idx;
    if ((ic.feedback & (ctor ? hobject::FB_CTOR : hobject::FB_CALL)) == 0 || (ic.feedback & hobject::FB_POLY) != 0) return null;
    if (!ctor && hobject::ic_call_count(ic) != 1) return null;
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

// The epoch case of the inherited data read entry `ic`, when the heap's epoch still proves it: the
// owner holds the property at the entry's slot. Else null.
fn hobject::ICChainEpoch* opt_epoch_entry(Heap* h, hobject::ICEntry* ic) {
    if (!ic.has_proto || ic.chain_len != hobject::IC_CHAIN_EPOCH || ic.chain == null || ic.prop_flags.is_accessor) return null;
    hobject::ICChainEpoch* e = &ic.chain.epoch;
    if (e.value != h.prototype_epoch || e.owner == null || ic.prop_idx >= e.owner.prop_count) return null;
    return e;
}

// Whether the prototype-read set of the read entry `ic` holds cases of the prototype epoch as it
// stands (OptCg.retained_cases): an own read then also reads other receivers.
fn bool opt_has_retained(Heap* h, hobject::ICEntry* ic) {
    return ic.chain != null && ic.chain.protos != null && ic.chain.protos.count != 0 && ic.chain.protos.epoch == h.prototype_epoch;
}

// The shape of the receiver that entry holds, when it is the one the entry saw and a shared one,
// whose id can be pinned and compared as a constant. Else null.
fn hobject::Shape* opt_settled_shape(Heap* h, hobject::ICEntry* ic) {
    hobject::ICChainEpoch* e = opt_epoch_entry(h, ic);
    if (e == null || e.first == null) return null;
    hobject::Shape* sh = h.get_shape(ic.shape_id);
    if (sh == null || sh.generation != ic.shape_gen || sh.parent == hobject::PRIVATE_SHAPE_PARENT) return null;
    return sh;
}

// Whether the instruction at word `pc` of `cf` (the function `root` is optimizing, or a callee
// inlined into it) exited from optimized code often enough that it is no longer speculated on.
// `fold` asks about folding a GETGLOBAL there, which a ban of its fold alone stops too.
fn bool opt_site_banned(CompiledFunction* root, CompiledFunction* cf, uint pc, bool fold = false) {
    OptBans* bans = root.opt_bans;
    if (bans == null) return false;
    for (uint i = 0; i < bans.count; i++) {
        OptBan* b = &bans.items[i];
        if (b.cf == cf && (b.pc == pc || b.pc == OPT_BAN_ALL) && (fold || !b.fold)) return true;
    }
    return false;
}

// The opcode of `f` whose control flow the builder does not support, or NOP when it refused for a
// shape of the graph (a bad branch target, a size) that the refusal counts already cover.
fn Opcode opt_cfg_refusal_op(CompiledFunction* f) {
    for (uint pc = 0; pc < f.code_count;) {
        bytecode::DecodedBytecode d = bytecode::decode_bytecode(f.code, f.code_count, pc);
        if (!d.valid || d.next_pc <= pc) return Opcode.NOP;
        // The graph decoder takes these two for a consumer that knows their write (OptBuild.analyze).
        if (!compiler::bytecode_cfg_control_supported(d.insn.op) && d.insn.op != Opcode.RESOLVEVAR && d.insn.op != Opcode.THROW_UNRESOLVED) return d.insn.op;
        pc = d.next_pc;
    }
    return Opcode.NOP;
}

fn bool opt_refuse(Heap* h, CompiledFunction* f, OptRefuse why, Opcode op) {
    h.opt.refused++;
    h.opt.refused_why[why.ordinal]++;
    if (why == OptRefuse.OPCODE) h.opt.refused_ops[op.ordinal]++;
    if (why == OptRefuse.CFG) {
        Opcode at = opt_cfg_refusal_op(f);
        if (at != Opcode.NOP) h.opt.refused_cfg_ops[at.ordinal]++;
    }
    f.opt_state = OPT_REFUSED;
    if (h.opt.log) {
        io::eprintf("opt refuse ");
        opt_log_fn(f);
        io::eprintfn(" %s %s words %d registers %d", why.label, op, f.code_count, f.num_regs);
    }
    return false;
}

// Retry allocation with unallocated phis kept in frame slots, preserving the
// current inlining policy. The incoming graph has already failed allocation.
fn OptRefuse opt_window_phis(Heap* h, CompiledFunction* f, OptGraph* g, OptBuild* b, Opcode* refused_op, List{OptJoin}* windowed) {
    OptRefuse why = OptRefuse.PRESSURE;
    for (uint round = 0; why == OptRefuse.PRESSURE && round < OPT_PRESSURE_ROUNDS; round++) {
        if (round == 0) {
            // The graph that failed names its phis.
            OptPools pools = opt_pools();
            g.allocate(&pools, windowed);
        }
        bool plain = b.no_inline;
        b.free();
        g.clear();
        *refused_op = Opcode.NOP;
        why = opt_build_graph(h, f, g, b, refused_op, plain, windowed);
        OptPools pools = opt_pools();
        if (why == OptRefuse.NONE && !g.allocate(&pools, windowed)) why = OptRefuse.PRESSURE;
    }
    return why;
}

// The loop of `f` to compile on its own for a frame whose back edge went to `pc`: of the loops
// that hold the one headed at `pc` (each the span from a header to its last back edge), the widest
// of at most OPT_REGION_WORDS_MAX words, or the `skip`-th narrower after it.
fn bool opt_find_region(CompiledFunction* f, uint pc, uint skip, OptRegion* out) {
    uint[OPT_REGION_NEST] starts;
    uint[OPT_REGION_NEST] ends;
    uint n = 0;
    uint own_end = 0;
    for (uint at = 0; at < f.code_count;) {
        bytecode::DecodedBytecode d = bytecode::decode_bytecode(f.code, f.code_count, at);
        if (!d.valid || d.next_pc <= at) return false;
        long t;
        if (compiler::bytecode_cfg_branch(d, &t) && t >= 0 && t <= (long)at && t <= (long)pc && d.next_pc > pc) {
            uint head = (uint)t;
            if (head == pc && d.next_pc > own_end) own_end = d.next_pc;
            uint k = 0;
            while (k < n && starts[k] != head) k++;
            if (k == n) {
                if (n == OPT_REGION_NEST) return false;
                starts[n] = head;
                ends[n++] = d.next_pc;
            } else if (d.next_pc > ends[k]) {
                ends[k] = d.next_pc;
            }
        }
        at = d.next_pc;
    }
    if (own_end == 0) return false;
    // The candidates, widest first; each holds the loop at `pc` whole, so that pc is an entry.
    while (true) {
        uint best = n;
        for (uint k = 0; k < n; k++) {
            if (ends[k] < own_end || ends[k] - starts[k] > OPT_REGION_WORDS_MAX) continue;
            if (best == n || ends[k] - starts[k] > ends[best] - starts[best]) best = k;
        }
        if (best == n) return false;
        if (skip-- == 0) {
            *out = { .start = starts[best], .end = ends[best] };
            return true;
        }
        ends[best] = 0;
    }
}

fn bool opt_has_loop(CompiledFunction* f) {
    for (uint at = 0; at < f.code_count;) {
        bytecode::DecodedBytecode d = bytecode::decode_bytecode(f.code, f.code_count, at);
        if (!d.valid || d.next_pc <= at) return false;
        long t;
        if (compiler::bytecode_cfg_branch(d, &t) && t >= 0 && t <= (long)at) return true;
        at = d.next_pc;
    }
    return false;
}

// Refuse `f` after a failed build. A function refused at its graph may still compile its loops,
// and a loop that failed leaves the narrower ones to try.
fn bool opt_refuse_build(Heap* h, CompiledFunction* f, OptRefuse why, Opcode op, bool region) {
    opt_refuse(h, f, why, op);
    if (region) {
        if (++f.opt_region_fails < OPT_REGION_TRIES) f.opt_state = OPT_REGION;
    } else if ((why == OptRefuse.CFG || why == OptRefuse.BUDGET) && !h.opt.no_region) {
        f.opt_state = OPT_REGION;
    }
    opt_reset_count(f);
    return false;
}

// Optimize `f`: the whole function, or for one in OPT_REGION the loop holding the header `osr_pc`
// that a frame with window `regs` branched back to.
fn bool opt_try_compile(Heap* h, CompiledFunction* f, Activation* act, uint osr_pc = uint::max, TVal* regs = null) @noinline {
    OptPolicy* p = &h.opt;
    JitStats* st = &h.jit_stats;
    bool region = f.opt_state == OPT_REGION;
    if (f.jit_code == null || f.opt_code != null || (f.opt_state != OPT_NONE && !region)) return false;
    if (!p.always && !opt_has_feedback(h, f)) return false;
    // Forcing exits from inlined bodies needs bodies that have a callee to inline.
    if (p.force_inline && !opt_has_call_feedback(f)) return false;
    if (p.live_bytes >= opt_code_limit(h) && !opt_make_room(h)) {
        // Not a verdict on `f`: it is considered again after its next round of entries.
        h.opt.refused++;
        h.opt.refused_why[OptRefuse.BUDGET.ordinal]++;
        return false;
    }
    if (!opt_function_eligible(f)) return opt_refuse(h, f, OptRefuse.FUNCTION, Opcode.NOP);
    if (!region && p.region_always && !p.no_region && opt_has_loop(f)) return opt_refuse_build(h, f, OptRefuse.CFG, Opcode.NOP, false);
    long t0 = st.timing ? (long)clock::now() : 0;
    OptGraph g;
    g.init();
    defer g.free();
    g.frame = act;
    g.folded_epoch = h.folded_epoch;
    g.watch_epoch = p.watch_epoch;
    if (region) {
        if (!opt_find_region(f, osr_pc, f.opt_region_fails, &g.region)) return opt_refuse_build(h, f, OptRefuse.CFG, Opcode.NOP, true);
        g.region.regs = regs;
    }
    OptBuild b;
    Opcode refused_op = Opcode.NOP;
    // A region's calls stay calls: an inlined body would bring its own pcs into the loop's.
    OptRefuse why = opt_build_graph(h, f, &g, &b, &refused_op, region);
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
    // Try frame slots for excess phis before discarding otherwise useful inlined bodies.
    List{OptJoin} windowed;
    windowed.init(mem);
    defer windowed.free();
    if (why == OptRefuse.PRESSURE) why = opt_window_phis(h, f, &g, &b, &refused_op, &windowed);
    if (why != OptRefuse.NONE && b.sites.len() != 0) {
        // Inlining may be what made the body too big or too hard to allocate: try without it.
        b.free();
        g.clear();
        windowed.clear();
        refused_op = Opcode.NOP;
        why = opt_build_graph(h, f, &g, &b, &refused_op, true);
        OptPools pools2 = opt_pools();
        if (why == OptRefuse.NONE && !g.allocate(&pools2)) why = OptRefuse.PRESSURE;
        if (why == OptRefuse.PRESSURE) why = opt_window_phis(h, f, &g, &b, &refused_op, &windowed);
    }
    defer b.free();
    uint inlined = (uint)g.fns.len() - 1;
    // Call feedback alone is worth optimizing for only when the call was inlined or is entered
    // directly.
    if (why == OptRefuse.NONE && inlined == 0 && b.builtin_calls == 0 && b.direct_calls == 0 && !p.always && !opt_has_operand_feedback(f) && !opt_has_int_work(f) && !(opt_has_field_feedback(f) && (g.polys.len() >= OPT_FIELD_SITES || g.loads_elements()))) {
        f.opt_declined++;
        return false;
    }
    if (why != OptRefuse.NONE) return opt_refuse_build(h, f, why, refused_op, region);
    // The window is the frame's only while it waits for this compile.
    g.region.regs = null;
    OptCode* oc = h.alloc_func(h.heap_udata, OptCode::size);
    if (oc == null) return false;
    mem::clear(oc, OptCode::size);
    oc.f = f;
    oc.base = f.jit_code;
    if (p.force_reason != 0) oc.forced = p.force_count;
    if (p.dump) g.dump(f);
    BaselineCode* code = opt_emit(h, f, &g, oc, pools);
    // The total and the longest single compile cover both tiers: what a host bounds its budget by.
    if (st.timing) {
        ulong ns = (ulong)((long)clock::now() - t0);
        st.compile_ns += ns;
        if (ns > st.compile_max_ns) {
            st.compile_max_ns = ns;
            st.compile_max_insns = f.code_count;
        }
    }
    if (code == null) {
        while (oc.sink_sites != null) {
            OptSinkSite* x = oc.sink_sites;
            oc.sink_sites = x.next;
            h.free_func(h.heap_udata, x);
        }
        if (oc.cells != null) h.free_func(h.heap_udata, oc.cells);
        h.free_func(h.heap_udata, oc);
        return opt_refuse_build(h, f, OptRefuse.COMPILE, Opcode.NOP, region);
    }
    oc.code = code;
    code.touched = 1;
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
    uint first_watch = p.watch_count;
    foreach (&x : g.bindings) if (x.watch) opt_watch(h, g.holders[x.holder].obj, x.slot, x.value);
    opt_watch_disarm_stores(h, first_watch);
    if (p.log) {
        io::eprintf("opt compile ");
        opt_log_fn(f);
        io::eprintf(" words %d nodes %d inlined %d reopt %d", f.code_count, g.nodes.len(), inlined, f.opt_reopts);
        if (region) io::eprintf(" region %d-%d", g.region.start, g.region.end);
        uint[3] calls;
        foreach (&nd : g.nodes) {
            if (nd.op == OptOp.CALL_REG) {
                calls[0]++;
            } else if (nd.op == OptOp.GENERIC) {
                switch (f.code[(uint)nd.imm].op) {
                    case CALL: case CALL_PROP: case CALL_UNDEF_THIS: case NEW_OBJ: case CALL_S: case NEW_OBJ_S:
                    case CALL_VAR: case CALL_GLOBAL:
                        calls[nd.key != null ? 1 : 2]++;
                    default:
                }
            }
        }
        io::eprintfn(" calls reg %d direct %d generic %d", calls[0], calls[1], calls[2]);
        foreach (&nd : g.nodes) {
            if (nd.op != OptOp.GENERIC || nd.key != null || nd.fidx != 0) continue;
            Instruction w = f.code[(uint)nd.imm];
            if (!opt_call_op(w.op)) continue;
            io::eprintf("opt generic-call ");
            opt_log_fn(f);
            io::eprintfn(" +%d %s %s", nd.imm, w.op, opt_generic_reason(h, f, (uint)nd.imm));
        }
    }
    return true;
}

// Reinstall the baseline code of `f` and retire its optimized body, which a native frame may
// still be running. Its bytes stop counting toward the budgets now; they are freed once no
// native code is running (opt_reap).
fn void opt_retire(Heap* h, CompiledFunction* f, OptCode* oc) {
    f.jit_code = oc.base;
    f.opt_code = null;
    oc.next_retired = h.opt.retired;
    h.opt.retired = oc;
    usz bytes = oc.code.code_bytes + oc.code.table_bytes;
    h.opt.live_bytes -= bytes;
    h.jit_stats.live_bytes -= bytes;
    opt_reset_count(f);
}

// Retire the optimized bodies that were not entered since the previous sweep, and mark the rest
// as not entered. Their functions go back to counting entries toward a fresh optimization: an
// eviction is neither an exit nor a refusal. True when the code now has room.
fn bool opt_make_room(Heap* h) @noinline {
    h.opt.sweeps++;
    for (uint fi = 0; fi < h.compiled_func_count; fi++) {
        CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[fi];
        if (cf == null || cf.opt_code == null) continue;
        OptCode* oc = cf.opt_code;
        if (oc.code.touched != 0) {
            oc.code.touched = 0;
            continue;
        }
        opt_retire(h, cf, oc);
        cf.opt_state = OPT_NONE;
        h.opt.evicted++;
    }
    return h.opt.live_bytes < opt_code_limit(h);
}

// "fn#N name:line" for the --opt-log lines.
fn void opt_log_fn(CompiledFunction* f) {
    String name = f.name_len != 0 ? (String)f.name_ptr[:f.name_len] : "<anonymous>";
    io::eprintf("fn#%d %s:%d", f.func_index, name, f.code_count != 0 ? f.get_line(0) : 0);
}

fn void opt_discard(Heap* h, CompiledFunction* f) {
    OptCode* oc = f.opt_code;
    if (oc == null) return;
    if (h.opt.log) {
        io::eprintf("opt discard ");
        opt_log_fn(f);
        io::eprintf(" exits %d:", oc.exits);
        foreach (&x : oc.hits) {
            if (x.count == 0) continue;
            if (x.pc == OPT_BAN_ALL) {
                io::eprintf(" fn#%d captures x%d", x.cf.func_index, x.count);
            } else {
                io::eprintf(" fn#%d+%d %s x%d", x.cf.func_index, x.pc, x.cf.code[x.pc].op, x.count);
            }
        }
        io::eprintfn("");
    }
    // A rebuild is worth its compile only when the discard teaches the next build something. A body
    // whose exit sites were all already banned would repeat the same speculation; one that exited
    // where nothing is bannable (a forced exit, an int32 overflow) keeps its retries, which
    // OPT_REOPT_MAX bounds.
    uint hit_sites = 0;
    uint added = opt_ban_hits(h, oc, &hit_sites);
    bool fresh = hit_sites == 0 || added != 0;
    opt_retire(h, f, oc);
    h.opt.discards++;
    f.opt_reopts++;
    f.opt_state = fresh && f.opt_reopts <= OPT_REOPT_MAX ? OPT_NONE : OPT_REFUSED_EXITS;
}

// Discard `oc` after an UNPROFILED exit, without charging a reoptimization up to OPT_RELEARN_MAX:
// the exit recorded the class the rebuild lacked, and a site exits so at most once, since a
// recorded class is never unrecorded again.
fn void opt_relearn(Heap* h, OptCode* oc) {
    CompiledFunction* f = oc.f;
    if (f.opt_code != oc) return;
    if (f.opt_relearns >= OPT_RELEARN_MAX) {
        opt_discard(h, f);
        return;
    }
    f.opt_relearns++;
    if (h.opt.log) {
        io::eprintf("opt relearn ");
        opt_log_fn(f);
        io::eprintfn("");
    }
    opt_retire(h, f, oc);
    h.opt.discards++;
    f.opt_state = OPT_NONE;
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
    usz bytes = oc.code.code_bytes + oc.code.table_bytes;
    h.opt.live_bytes -= bytes;
    h.jit_stats.live_bytes -= bytes;
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
    // A failed type guard: record the operand classes the instruction met, as the baseline would
    // have off its integer path, so that the rebuild lowers it for them instead of guarding again.
    // Feedback the build had not seen makes it rebuild at once, as an unprofiled site does.
    bool widened = (reason == OptExit.NOT_INT32.ordinal || reason == OptExit.NOT_NUMBER.ordinal) && oc.f.ic_entries != null
        && opt_note_operands(ds, oc.f, (uint)(ds.curr_pc - ds.code_base), reason);
    if (reason == OptExit.SLOW_PATH.ordinal && oc.f.ic_entries != null) widened = widened || opt_note_string_elem(ds, oc.f, (uint)(ds.curr_pc - ds.code_base));
    if (reason == OptExit.INTERRUPT.ordinal) return 0;
    if (reason == OptExit.UNPROFILED.ordinal || reason == OptExit.WATCH.ordinal || widened) {
        opt_relearn(h, oc);
        return 0;
    }
    opt_note_exit_op(&h.opt, oc.f, (uint)(ds.curr_pc - ds.code_base));
    if (reason == OptExit.BINDING.ordinal) opt_note_unfold(&h.opt, oc.f, (uint)(ds.curr_pc - ds.code_base), ds.act);
    if (h.opt.log) {
        uint at = (uint)(ds.curr_pc - ds.code_base);
        io::eprintf("opt exit ");
        opt_log_fn(oc.f);
        io::eprintfn(" +%d %s %s", at, oc.f.code[at].op, ((OptExit)reason).label);
    }
    if (opt_exit_transient(h, reason)) return 0;
    if (reason == OptExit.PARAM.ordinal) {
        opt_ban(h, oc.f, oc.f, OPT_BAN_PARAMS);
        opt_relearn(h, oc);
        return 0;
    }
    oc.exits++;
    bool repeat = false;
    if (oc.f.opt_code == oc && oc.f.ic_entries != null) {
        uint at = (uint)(ds.curr_pc - ds.code_base);
        if (oc.f.code[at].op == Opcode.WIDE) at++;
        // A receiver the read lacked that a rebuild reads (opt_learn_receiver) does not count towards
        // leaving the site to the baseline.
        bool learnt = (reason == OptExit.SHAPE.ordinal || reason == OptExit.RECEIVER.ordinal) && opt_learn_receiver(ds, oc.f, (uint)(ds.curr_pc - ds.code_base));
        if (learnt) {
            opt_relearn(h, oc);
            return 0;
        }
        repeat = opt_note_site_exit(oc, oc.f, at, reason);
    }
    if (oc.f.opt_code == oc && (repeat || oc.exits >= opt_exit_limit(h))) opt_discard(h, oc.f);
    return 0;
}

// A shape or receiver exit at the read at word `pc` of `f` (GETPROPC, GETPROPC_CACHED), whose
// register 0 is register `base` of the frame: true when a rebuild reads the receiver. One that
// inherits the property where the entry has it own, or has it own where the entry inherits it,
// joins the entry's prototype-read set (vm::ic_note_proto_read); one with another own shape joins
// the entry's own shapes when the baseline runs the read, while they have room.
fn bool opt_learn_receiver(Dispatch* ds, CompiledFunction* f, uint pc, uint base = 0) {
    if (f.ic_entries == null) return false;
    DecodedBytecode d = bytecode::decode_bytecode(f.code, f.code_count, pc);
    if (!d.valid || (d.insn.op != Opcode.GETPROPC && d.insn.op != Opcode.GETPROPC_CACHED)) return false;
    TVal* recv = ds.regs_base + base + d.insn.b;
    if (!recv.is_object()) return false;
    HObject* hobj = (HObject*)recv.get_heapptr();
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[d.payload_pc];
    if (vm::ic_note_proto_read(ds.heap, ic, hobj)) return true;
    void* key = (void*)ic.key.borrow();
    if (key == null || ic.has_proto || (ic.chain_len != 0 && ic.chain_len != hobject::IC_CHAIN_POLY)) return false;
    if (!hobject::plain_property_object(hobj) || hobj.in_dict_mode(ds.heap)) return false;
    int idx = hobj.find_prop_idx(key, ds.heap);
    if (idx < 0 || hobj.get_prop_flags((uint)idx, ds.heap).is_accessor) return false;
    OptPoly p;
    return field_shapes(ic, &p) && p.count < OPT_POLY_MAX;
}

// A slow path of the element read at word `pc` of `f` taken for a string receiver: the rebuild
// reads its units too (OptCg.string_elem). True when that is new.
fn bool opt_note_string_elem(Dispatch* ds, CompiledFunction* f, uint pc) {
    if (f.code[pc].op != Opcode.GETPROP || !ds.regs_base[f.code[pc].b].is_string()) return false;
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[pc];
    if ((ic.feedback & hobject::FB_STRING_RECV) != 0) return false;
    ic.feedback |= hobject::FB_STRING_RECV;
    return true;
}

// OR the classes of the operands the instruction at word `pc` of `f` reads from the window into its
// feedback, for the instructions whose feedback the optimizer reads.
fn bool opt_note_operands(Dispatch* ds, CompiledFunction* f, uint pc, long reason) {
    DecodedBytecode d = bytecode::decode_bytecode(f.code, f.code_count, pc);
    if (!d.valid) return false;
    hobject::ICEntry* ic = &((hobject::ICEntry*)f.ic_entries)[d.payload_pc];
    char before = ic.feedback;
    TVal* regs = ds.regs_base;
    if (!vm::has_feedback(d.insn.op)) {
        // A typed load found a value that is no number: the rebuild reads it into the window
        // (OptBuild.asked_rep).
        if (reason != OptExit.NOT_INT32.ordinal) {
            if (d.insn.op == Opcode.PUTPROP) return false;
            ic.feedback |= hobject::FB_VALUE;
            return ic.feedback != before;
        }
        // An element access whose key was no int32: the rebuild reads it by key (OptBuild.index_ok).
        // Else a typed load (an element, field, closure or global read) found a value its int32
        // node cannot hold, which the rebuild reads as a double (OptBuild.typed_load).
        TVal* key = d.insn.op == Opcode.GETPROP ? regs + d.insn.c : (d.insn.op == Opcode.PUTPROP ? regs + d.insn.b : null);
        ic.feedback |= key != null && !key.is_fastint() ? hobject::FB_KEY : hobject::FB_DBL;
        return ic.feedback != before;
    }
    TVal imm;
    char bits;
    switch (d.insn.op) {
        case INC: case DEC: case INC_LT:
            bits = hobject::fb_class(regs + d.insn.a);
        case UNM: case UNP: case BNOT: case TONUMERIC:
            bits = hobject::fb_class(regs + d.insn.b);
        default:
            bits = hobject::fb_class(regs + d.insn.b) | hobject::fb_class(vm::op_operand_c(ds, d.insn, &imm));
    }
    ic.feedback |= bits;
    return ic.feedback != before;
}

fn usz opt_code_limit(Heap* h) @inline => h.opt.code_max != 0 ? h.opt.code_max : OPT_CODE_MAX;

fn uint opt_exit_limit(Heap* h) @inline => h.opt.exit_max != 0 ? h.opt.exit_max : OPT_EXIT_MAX;

// Whether `reason` is a failed guard of one instruction that a rebuild can leave unspeculated.
// A guard on a value's type is one a rebuild adapts to by the operand feedback, except in an inlined
// body, whose typed loads it does not re-derive (`inlined`).
fn bool opt_exit_bannable(long reason, bool inlined = false) {
    switch ((OptExit)reason) {
        case SHAPE: case RECEIVER: case SLOW_PATH: case CALLEE: case BOUNDS: case HOLE: case BINDING: case CAPTURE:
            return true;
        case NOT_NUMBER: case NOT_INT32:
            return inlined;
        default:
            return false;
    }
}

// The guard of the folded GETGLOBAL or GETCAP at word `pc` of `cf`, run by the frame `act`, failed:
// remember its binding as changing.
fn void opt_note_unfold(OptPolicy* p, CompiledFunction* cf, uint pc, Activation* act) {
    if (cf.code[pc].op == Opcode.WIDE) pc++;
    void* slot = null;
    if (cf.code[pc].op == Opcode.GETCAP) {
        // A captured binding of the frame's closure; a value snapshot never changes.
        CaptureRef* ref = act != null ? vm::capture_ref(act, cf.code[pc].get_bc()) : null;
        if (ref != null && !ref.is_value) slot = vm::capture_read_slot(ref);
    } else if (cf.var_ic_entries != null) {
        slot = ((hobject::VarICEntry*)cf.var_ic_entries)[pc].slot_ptr;
    }
    if (slot == null || opt_unfolded(p, slot)) return;
    p.unfolded[p.unfolded_next++ % OPT_UNFOLD_MAX] = slot;
}

fn bool opt_unfolded(OptPolicy* p, void* slot) {
    foreach (s : p.unfolded) if (s == slot) return true;
    return false;
}

// Make `holder` one whose bindings code may watch. A property cache filled for it before could
// store to a watched slot: its shape's storage generation moves, which every such cache compares.
fn void opt_watch_holder(Heap* h, HObject* holder) {
    if (holder.gc.bindings_watched) return;
    holder.gc.bindings_watched = true;
    h.bump_shape_gen(holder.shape_id);
}

fn bool opt_watching(Heap* h, HObject* holder, uint idx) {
    OptPolicy* p = &h.opt;
    for (uint w = 0; w < p.watch_count; w++) if (p.watches[w].holder == holder && p.watches[w].idx == idx) return true;
    return false;
}

// Watch the binding at `slot` of `holder` (opt_watch_holder), which holds `value`. The variable
// caches naming the slot keep their store fast paths until opt_watch_disarm_stores runs for the
// watches the compile added. The build reserved the room.
fn void opt_watch(Heap* h, HObject* holder, hobject::PropValue* slot, ulong value) {
    OptPolicy* p = &h.opt;
    uint idx = (uint)(slot - holder.prop_values());
    if (opt_watching(h, holder, idx)) return;
    p.watches[p.watch_count++] = { .holder = holder, .idx = idx, .value = value };
    // Code stores the value to frames the collector may have scanned already.
    TVal v = { .bits = value };
    if (h.gc_phase == heap::GcPhase.MARK) h.shade_value(v);
}

// Take the store fast paths from the variable caches filled before watches `first`.. were added
// (a fill after checks Heap.binding_watched): a store then takes the full path, which fires the
// watch. One pass over every cache serves all the watches of a compile.
fn void opt_watch_disarm_stores(Heap* h, uint first) {
    OptPolicy* p = &h.opt;
    if (first >= p.watch_count) return;
    for (uint fi = 0; fi < h.compiled_func_count; fi++) {
        CompiledFunction* cf = (CompiledFunction*)h.compiled_funcs[fi];
        if (cf == null || cf.var_ic_entries == null) continue;
        hobject::VarICEntry* vics = (hobject::VarICEntry*)cf.var_ic_entries;
        for (uint i = 0; i < cf.var_ic_count; i++) {
            hobject::PropValue* slot = vics[i].slot_ptr;
            if (slot == null || (!vics[i].varref_store_ok && !vics[i].prop_flags.writable)) continue;
            for (uint w = first; w < p.watch_count; w++) {
                OptWatch* x = &p.watches[w];
                if (slot != &x.holder.prop_values()[x.idx]) continue;
                vics[i].varref_store_ok = false;
                vics[i].prop_flags.writable = false;
                break;
            }
        }
    }
}

fn void opt_watch_fire(Heap* h, uint w) {
    OptPolicy* p = &h.opt;
    OptWatch* x = &p.watches[w];
    void* slot = &x.holder.prop_values()[x.idx];
    if (!opt_unfolded(p, slot)) p.unfolded[p.unfolded_next++ % OPT_UNFOLD_MAX] = slot;
    p.watches[w] = p.watches[--p.watch_count];
    p.watch_epoch++;
}

// A store into `slot` of `owner`: the watch on it fires when the value changed.
fn void opt_watch_store(Heap* h, HObject* owner, hobject::PropValue* slot) @noinline {
    OptPolicy* p = &h.opt;
    uint idx = (uint)(slot - owner.prop_values());
    for (uint w = 0; w < p.watch_count; w++) {
        OptWatch* x = &p.watches[w];
        if (x.holder != owner || x.idx != idx) continue;
        if (slot.get().bits != x.value) opt_watch_fire(h, w);
        return;
    }
}

// A change to the property at `idx` of `owner`, or its deletion: the watch on it fires, and a
// deletion moves the watches of the slots after it down by one, as it moves their values.
fn void opt_watch_property(Heap* h, HObject* owner, uint idx, bool deleted) @noinline {
    OptPolicy* p = &h.opt;
    for (uint w = p.watch_count; w-- > 0;) {
        OptWatch* x = &p.watches[w];
        if (x.holder != owner) continue;
        if (x.idx == idx) {
            opt_watch_fire(h, w);
        } else if (deleted && x.idx > idx) {
            x.idx--;
        }
    }
}

// `owner` gained an own symbol-keyed property or another [[Prototype]]: what the code assumed of its
// `instanceof` may not hold, and its watches fire.
fn void opt_watch_holder_changed(Heap* h, HObject* owner) @noinline {
    OptPolicy* p = &h.opt;
    for (uint w = p.watch_count; w-- > 0;) if (p.watches[w].holder == owner) opt_watch_fire(h, w);
}

// The watched values are roots: code stores them to frames without a barrier.
fn void opt_mark_watches(Heap* h) {
    OptPolicy* p = &h.opt;
    for (uint w = 0; w < p.watch_count; w++) {
        TVal v = { .bits = p.watches[w].value };
        h.mark_tval(&v);
    }
}

fn void opt_clear_watches(Heap* h) {
    h.opt.watch_count = 0;
    h.opt.watch_epoch++;
}

// Whether an exit says nothing about the body's speculation: a slow path taken while the collector
// marks, when the baseline's fast paths leave to their helpers each value still to mark, each
// allocation and each return. It is not counted against the body or its site.
fn bool opt_exit_transient(Heap* h, long reason) @inline {
    return (reason == OptExit.SLOW_PATH.ordinal && h.gc_phase == heap::GcPhase.MARK) || reason == OptExit.DEEP.ordinal;
}

// Count an exit of `oc` at word `pc` of `cf`; true at the OPT_SITE_EXITS-th exit at one site, which
// discards the body: rebuilding it without those exits is better than taking them OPT_EXIT_MAX
// times. Only a failed guard of one instruction is counted, since only that changes the next build.
fn bool opt_note_site_exit(OptCode* oc, CompiledFunction* cf, uint pc, long reason, bool inlined = false) {
    if (!opt_exit_bannable(reason, inlined)) return false;
    // Another closure runs the code: none of its captured bindings is folded again.
    if (reason == OptExit.CAPTURE.ordinal) pc = OPT_BAN_ALL;
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
        hit.fold = reason == OptExit.BINDING.ordinal || reason == OptExit.CAPTURE.ordinal;
    }
    return ++hit.count >= OPT_SITE_EXITS;
}

// Record every site `oc` exited from, so that the next build lowers each generically. Returns the
// bans added; `hit_sites` counts the sites the body exited from, banned ones included.
fn uint opt_ban_hits(Heap* h, OptCode* oc, uint* hit_sites) {
    uint sites = 0;
    uint added = 0;
    CompiledFunction* root = oc.f;
    foreach (&x : oc.hits) {
        if (x.count == 0) continue;
        sites++;
        // The cache of one site a body exits from is as stale as its neighbours', which the body would
        // exit from next: the second time a body of the function is discarded, none is speculated on.
        uint pc = root.opt_reopts != 0 && !x.call && !x.fold ? OPT_BAN_ALL : x.pc;
        if (opt_site_banned(root, x.cf, pc, x.fold)) continue;
        if (!opt_ban(h, root, x.cf, pc, x.fold)) { *hit_sites = sites; return added; }
        added++;
    }
    *hit_sites = sites;
    return added;
}

// Ban word `pc` of `cf` in the builds of `root` (OptBan). False when there is no room.
fn bool opt_ban(Heap* h, CompiledFunction* root, CompiledFunction* cf, uint pc, bool fold = false) {
    OptBans* bans = root.opt_bans;
    if (bans == null) {
        bans = h.alloc_func(h.heap_udata, OptBans::size);
        if (bans == null) return false;
        mem::clear(bans, OptBans::size);
        root.opt_bans = bans;
    }
    if (bans.count >= OPT_BAN_MAX) return false;
    bans.items[bans.count++] = { .cf = cf, .pc = pc, .fold = fold };
    h.opt.bans++;
    return true;
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
    if (reason == OptExit.UNPROFILED.ordinal) {
        opt_relearn(h, oc);
        return vm::jit_inline_materialize(ds, site);
    }
    opt_note_exit_op(&h.opt, callee, site.pc);
    if (reason == OptExit.BINDING.ordinal) opt_note_unfold(&h.opt, callee, site.pc, null);
    if (h.opt.log) {
        io::eprintf("opt exit ");
        opt_log_fn(callee);
        io::eprintf(" +%d %s %s inlined in ", site.pc, callee.code[site.pc].op, ((OptExit)reason).label);
        opt_log_fn(oc.f);
        io::eprintfn("");
    }
    if (opt_exit_transient(h, reason)) return vm::jit_inline_materialize(ds, site);
    // A receiver the callee's read lacked teaches its entry, which every caller shares, as at a
    // site of the function's own (the exit stored the registers the callee's frame holds).
    if ((reason == OptExit.SHAPE.ordinal || reason == OptExit.RECEIVER.ordinal)
        && opt_learn_receiver(ds, callee, site.pc, site.frames[site.depth - 1].base)) {
        opt_relearn(h, oc);
        return vm::jit_inline_materialize(ds, site);
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
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.f.code + (long)self.i * Instruction::size);
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | self.ds, self.pc_off, R1, 0);
    sljit_emit_op1(c, SLJIT_MOV, R0, 0, self.ds, 0);
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)oc);
    sljit_emit_op1(c, SLJIT_MOV, R2, 0, SLJIT_IMM, (long)reason);
    self.c_call(SLJIT_ARGS3WWW, SLJIT_IMM, (long)(usz)&opt_exit);
    sljit_emit_ijump(c, SLJIT_JUMP, SLJIT_IMM, (long)(usz)oc.base.exec_jump);
    if (skip != null) sljit_set_label(skip, sljit_emit_label(c));
}

// Register calls (OptCg.emit_call_reg) need a stack pointer the shim can move.
const bool REG_CALLS = env::AARCH64 || env::X86_64;

// Leave `oc` for the baseline code at the instruction self.i without an exit: a region's branch out
// of its loop, which is the code's normal way out and teaches the next build nothing.
fn void Asm.emit_opt_leave(&self, OptCode* oc) {
    void* c = self.c;
    sljit_emit_op1(c, SLJIT_MOV, R1, 0, SLJIT_IMM, (long)(usz)self.f.code + (long)self.i * Instruction::size);
    sljit_emit_op1(c, SLJIT_MOV, SLJIT_MEM | self.ds, self.pc_off, R1, 0);
    self.emit_sync();
    sljit_emit_ijump(c, SLJIT_JUMP, SLJIT_IMM, (long)(usz)oc.base.exec_jump);
}

// Count an exit that resumes at word `pc` of `cf` under the opcode found there, for --jit-stats.
fn void opt_note_exit_op(OptPolicy* p, CompiledFunction* cf, uint pc) {
    if (pc >= cf.code_count) return;
    if (cf.code[pc].op == Opcode.WIDE && pc + 1 < cf.code_count) pc++;
    p.exit_ops[cf.code[pc].op.ordinal]++;
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
    io::eprintfn("opt: %d evicted by %d sweeps", p.evicted, p.sweeps);
    io::eprintfn("opt: compiled %d (%d reoptimized), discarded %d, refused %d; live %d bytes",
                 p.compiled, p.reopts, p.discards, p.refused, p.live_bytes);
    io::eprintfn("opt: %d sites lowered generically after repeated exits", p.bans);
    foreach (r : OptExit::values) {
        if (p.exits[r.ordinal] != 0) io::eprintfn("opt exit %s: %d", r.label, p.exits[r.ordinal]);
    }
    foreach (op : Opcode::values) {
        if (p.exit_ops[op.ordinal] != 0) io::eprintfn("opt exit op %s: %d", op, p.exit_ops[op.ordinal]);
    }
    foreach (r : OptFieldSkip::values) {
        if (p.field_skipped[r.ordinal] != 0) io::eprintfn("opt field skipped %s: %d", r.label, p.field_skipped[r.ordinal]);
    }
    foreach (op : Opcode::values) {
        if (p.refused_cfg_ops[op.ordinal] != 0) io::eprintfn("opt refused cfg op %s: %d", op, p.refused_cfg_ops[op.ordinal]);
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
    // `inline/REASON` leaves only from a node of an inlined body; `inline2/` to `inline5/` from
    // one nested in that many inlined calls.
    p.force_depth = 1;
    if (name.starts_with("inline/")) {
        p.force_inline = true;
        name = name[7..];
    } else if (name.len > 8 && name.starts_with("inline") && name[7] == '/' && name[6] >= '2' && name[6] <= '0' + OPT_INLINE_DEPTH) {
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
