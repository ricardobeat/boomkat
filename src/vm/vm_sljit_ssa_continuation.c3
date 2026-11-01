module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::types;
import std::core::mem;

// REPLAY is legal only before an effect. YIELD is an after-effect safepoint;
// resuming it must never execute the bytecode a second time. THROW records the
// faulting instruction, with the before frame still authoritative.
enum SsaHelperOutcome : uint { COMPLETE, THROW, YIELD, REPLAY }
enum SsaEffectPhase : char { BEFORE, AFTER }

struct SsaPublishedValue @feat(SLJIT) {
    uint reg;
    TVal value;
}

// Frozen, plan-owned metadata. IDs refer to allocated SSA values, not VM
// registers. live_values preserves typed homes; root_values is its BOXED
// subset (plus before-only boxed operands needed during the helper).
struct SsaHelperSite @feat(SLJIT) {
    SsaHelperSite* next;
    uint pc;
    uint next_pc;
    uint before_frame;
    uint after_frame;
    uint* live_values;
    uint live_count;
    uint* root_values;
    uint root_count;
    bool native_resume;
}

// Reuse the allocator's converged CFG liveness at the actual call node.
// No definition-order interval can describe this across cyclic edges.
fn void ssa_helper_capture(SsaAllocation* allocation, uint node) @feat(SLJIT) {
    SsaGraph* g = allocation.g;
    Heap* h = g.heap;
    SsaHelperSite* site = h.alloc_func(h.heap_udata,
        SsaHelperSite::size + (usz)g.value_count * uint::size * 2);
    if (site == null) { g.failed = true; return; }
    *site = {};
    site.live_values = (uint*)((char*)site + SsaHelperSite::size);
    site.root_values = site.live_values + g.value_count;
    site.native_resume = true;
    site.pc = g.values[node].pc;
    site.next_pc = site.pc + 1;
    site.before_frame = site.pc;
    site.after_frame = site.next_pc;
    for (uint i = 0; i < g.value_count; i++) {
        if (i == node || !allocation.contains(allocation.live, i)) continue;
        if (g.values[i].rep == RAW) {
            site.native_resume = false;
        }
        site.live_values[site.live_count++] = i;
    }
    allocation.recovery(allocation.live, site.pc);
    for (uint i = 0; i < g.value_count; i++) {
        if (i != node && allocation.contains(allocation.live, i) && g.values[i].rep == BOXED) {
            site.root_values[site.root_count++] = i;
        }
    }
    site.next = g.plan.ssa_helpers;
    g.plan.ssa_helpers = site;
    g.plan.ssa_value_capacity = g.value_count;
    g.values[node].helper = site;
}

fn void ssa_helper_sites_free(Heap* h, LoopPlan* plan) @feat(SLJIT) {
    while (plan.ssa_helpers != null) {
        SsaHelperSite* site = plan.ssa_helpers;
        plan.ssa_helpers = site.next;
        h.free_func(h.heap_udata, site);
    }
    plan.ssa_value_capacity = 0;
}

// An invocation owns this storage until its generated frame unwinds. Pointers
// into the movable VM stack are transient; activation_slot is relative to the
// permanent activation_storage, including during nested call_fn segments.
struct SsaExecution @feat(SLJIT) {
    ColdCtx* cold;
    CompiledFunction* function;
    LoopPlan* plan;
    uint activation_slot;
    uint register_count;
    uint value_capacity;
    uint before_pc;
    uint after_pc;
    uint before_frame;
    uint after_frame;
    SsaEffectPhase phase;
    SsaHelperOutcome outcome;
    TVal* input_values;
    ulong* spills;
    ulong* edge;
    ulong* saved_bits;
    SsaPublishedValue* outputs;
    uint output_count;
    ValueRoot* roots;
    bool active;
}

// All arrays are allocated before entering generated code. In particular no
// root descriptor points into a VM register window that a callback can move.
fn bool ssa_execution_init(SsaExecution* execution, ColdCtx* cold, LoopPlan* plan,
    uint values, uint spills, uint edges) @feat(SLJIT) {
    Heap* h = cold.heap;
    *execution = {};
    execution.cold = cold;
    execution.function = cold.vm.current_func;
    execution.plan = plan;
    execution.activation_slot = (uint)(cold.act - &cold.vm.activation_storage[0]);
    execution.register_count = execution.function.num_regs;
    execution.value_capacity = values;
    execution.input_values = h.alloc_func(h.heap_udata, (usz)execution.register_count * TVal::size);
    execution.outputs = h.alloc_func(h.heap_udata, (usz)execution.register_count * SsaPublishedValue::size);
    execution.saved_bits = h.alloc_func(h.heap_udata, (usz)max(values, 1u) * ulong::size);
    execution.roots = h.alloc_func(h.heap_udata, (usz)max(values, 1u) * ValueRoot::size);
    execution.spills = h.alloc_func(h.heap_udata, (usz)max(spills, 1u) * ulong::size);
    execution.edge = h.alloc_func(h.heap_udata, (usz)max(edges, 1u) * ulong::size);
    if (execution.input_values == null || execution.outputs == null || execution.saved_bits == null
        || execution.roots == null || execution.spills == null || execution.edge == null) {
        ssa_execution_dispose(execution);
        return false;
    }
    mem::copy(execution.input_values, cold.act.bottom, (sz)execution.register_count * TVal::size);
    TVal undefined;
    undefined.set_undefined();
    for (uint i = 0; i < values; i++) h.push_value_root(&execution.roots[i], undefined);
    // Protect both the calling body and all linked artifacts throughout a
    // collecting/reentrant helper. Retirement may invalidate, never free it.
    h.jit_native_active++;
    execution.active = true;
    return true;
}

fn void ssa_execution_dispose(SsaExecution* execution) @feat(SLJIT) {
    Heap* h = execution.cold.heap;
    if (execution.active) {
        for (uint i = execution.value_capacity; i > 0; i--) h.pop_value_root(&execution.roots[i - 1]);
        h.jit_native_active--;
    }
    if (execution.input_values != null) h.free_func(h.heap_udata, execution.input_values);
    if (execution.outputs != null) h.free_func(h.heap_udata, execution.outputs);
    if (execution.saved_bits != null) h.free_func(h.heap_udata, execution.saved_bits);
    if (execution.roots != null) h.free_func(h.heap_udata, execution.roots);
    if (execution.spills != null) h.free_func(h.heap_udata, execution.spills);
    if (execution.edge != null) h.free_func(h.heap_udata, execution.edge);
    *execution = {};
}

fn bool ssa_execution_reload(SsaExecution* execution) @feat(SLJIT) {
    ColdCtx* cold = execution.cold;
    Vm* vm = cold.vm;
    Activation* act = &vm.activation_storage[execution.activation_slot];
    if (vm.activation_count == 0 || &vm.activations[vm.activation_count - 1] != act
        || act.func != execution.function || vm.current_func != execution.function) return false;
    cold.act = act;
    cold.capture_refs = null;
    if (cold.regs_base_ptr != null) *cold.regs_base_ptr = act.bottom;
    mem::copy(execution.input_values, act.bottom, (sz)execution.register_count * TVal::size);
    return true;
}

// Anchor the entire new root map before releasing ANY prior native root.
// Keeping one stable descriptor per value avoids cursor invalidation when an
// incremental collection is partway through the native root chain.
fn bool ssa_execution_roots(SsaExecution* execution, SsaHelperSite* site) @feat(SLJIT) {
    Heap* h = execution.cold.heap;
    for (uint i = 0; i < site.root_count; i++) {
        uint value = site.root_values[i];
        if (value >= execution.value_capacity) return false;
        TVal boxed = bitcast(execution.saved_bits[value], TVal);
        if (boxed.is_refcounted() && boxed.get_heapptr() != null) ((HeapHeader*)boxed.get_heapptr()).incref();
    }
    // The temporary reference above keeps cross-slot swaps alive while the
    // ordinary owning root update shades the new value and releases the old.
    for (uint i = 0; i < site.root_count; i++) {
        uint value = site.root_values[i];
        TVal boxed = bitcast(execution.saved_bits[value], TVal);
        h.tval_copy_ref(&execution.roots[value].value, &boxed);
        h.decref_tval(&boxed);
    }
    for (uint value = 0; value < execution.value_capacity; value++) {
        bool live;
        for (uint i = 0; i < site.root_count; i++) if (site.root_values[i] == value) { live = true; break; }
        if (!live) {
            h.decref_tval(&execution.roots[value].value);
            execution.roots[value].value.set_undefined();
        }
    }
    return true;
}

fn bool ssa_execution_publish(SsaExecution* execution) @feat(SLJIT) {
    ColdCtx* cold = execution.cold;
    if (!ssa_execution_reload(execution) || execution.output_count > execution.register_count) return false;
    // Validate first; malformed metadata cannot publish half a frame.
    for (uint i = 0; i < execution.output_count; i++) {
        if (execution.outputs[i].reg >= execution.register_count) return false;
    }
    for (uint i = 0; i < execution.output_count; i++) {
        TVal* value = &execution.outputs[i].value;
        if (value.is_refcounted() && value.get_heapptr() != null) ((HeapHeader*)value.get_heapptr()).incref();
    }
    for (uint i = 0; i < execution.output_count; i++) {
        SsaPublishedValue* output = &execution.outputs[i];
        TVal* dest = cold.act.bottom + output.reg;
        cold.heap.tval_copy_ref(dest, &output.value);
        cold.heap.decref_tval(&output.value);
        if (dest.is_heap_allocated()) track_heap_store(cold.act, dest, output.reg);
    }
    execution.output_count = 0;
    // Helper operands must describe the newly committed before-frame, not
    // the snapshot that was current when native entry began.
    mem::copy(execution.input_values, cold.act.bottom, (sz)execution.register_count * TVal::size);
    return true;
}

// A helper may allocate and enter arbitrary JavaScript. It is always an
// unknown heap/layout/binding clobber, even when its result is unused.
fn SsaHelperOutcome ssa_helper_execute(SsaExecution* execution, SsaHelperSite* site) @feat(SLJIT) @noinline {
    ColdCtx* cold = execution.cold;
    execution.before_pc = site.pc;
    execution.after_pc = site.next_pc;
    execution.before_frame = site.before_frame;
    execution.after_frame = site.after_frame;
    execution.phase = BEFORE;
    execution.outcome = REPLAY;
    if (!ssa_execution_roots(execution, site) || !ssa_execution_publish(execution)) return REPLAY;
    CompiledFunction* cf = execution.function;
    if (site.pc >= cf.code_count || site.next_pc > cf.code_count) return REPLAY;
    Instruction ins = cf.code[site.pc];
    cold.act.curr_pc = cf.code + site.pc;
    if (ins.op == Opcode.CALL || ins.op == Opcode.CALL_UNDEF_THIS
        || ins.op == Opcode.CALL_VAR || ins.op == Opcode.CALL_GLOBAL) {
        bool fused = ins.op == Opcode.CALL_VAR || ins.op == Opcode.CALL_GLOBAL;
        uint base = fused ? ins.a : ins.b;
        uint argc = fused ? ins.b : ins.c;
        if (base + 2 + argc > execution.register_count || ins.a >= execution.register_count) return REPLAY;
        TVal callee = execution.input_values[base];
        // The shared non-observable binding resolver refuses accessors/with
        // scopes before invoking anything. Those sites retain exact VM EXIT.
        if (fused && !loop_binding(cf.code + site.pc, cold, &callee)) return REPLAY;
        ValueRoot callee_root;
        cold.heap.push_value_root(&callee_root, callee);
        defer cold.heap.pop_value_root(&callee_root);
        TVal receiver;
        receiver.set_undefined();
        if (ins.op == Opcode.CALL) { receiver = execution.input_values[base + 1]; }
        else { cold.heap.set_reg_undefined(cold.act.bottom + base + 1); }
        if (fused) cold.heap.tval_copy_ref(cold.act.bottom + base, &callee);
        // Stable snapshot arguments survive VM stack relocation. Native roots
        // and the published VM frame keep their borrowed references alive.
        TVal result = cold.heap.call_fn(cold.vm, callee,
            execution.input_values + base + 2, argc, receiver);
        if (!ssa_execution_reload(execution)) {
            execution.outcome = YIELD;
            execution.phase = AFTER;
            return YIELD;
        }
        if (vm_check_call_fn_error(cold.vm) || cold.vm.throw_pending) {
            execution.outcome = THROW;
            return THROW;
        }
        cold.heap.tval_copy_ref(cold.act.bottom + ins.a, &result);
        // call_fn returns a borrow from vm.return_val (including strings).
        // The VM result slot keeps its reference after the caller copies it.
        track_heap_store(cold.act, cold.act.bottom + ins.a, ins.a);
    } else if (function_alloc_op(ins.op)) {
        long status = sljit_native_operation(cold, site.pc);
        if (status == 0) return REPLAY;
    } else {
        return REPLAY;
    }
    execution.phase = AFTER;
    cold.act.curr_pc = cf.code + site.next_pc;
    // Results are already owned and shaded by the VM frame before collection.
    cold.heap.safepoint_gc_on_call();
    if (!ssa_execution_reload(execution)) { execution.outcome = YIELD; return YIELD; }
    // Invalidated code remains pinned until unwind, but cannot be continued.
    execution.outcome = execution.plan != null && execution.plan.ssa_invalid ? YIELD : COMPLETE;
    return execution.outcome;
}

// Legacy fixed-window adapter. The graph and helper ABI are shared with the
// dynamic execution state; only this gateway copies its older LoopState ABI.
fn SsaHelperOutcome ssa_helper_state(LoopState* state, SsaHelperSite* site) @feat(SLJIT) @noinline {
    SsaExecution* execution = state.execution;
    $if $feat(SLJIT_STATS): execution.plan.ssa_helper_calls++; $endif
    SsaHelperOutcome outcome = ssa_helper_execute(execution, site);
    state.dirty = 0;
    state.resume_pc = execution.phase == AFTER ? site.next_pc : site.pc;
    ColdCtx* cold = execution.cold;
    if (!ssa_execution_reload(execution)) return YIELD;
    for (uint reg = 0; reg < execution.register_count; reg++) state.values[reg] = execution.input_values[reg];
    state.receiver = cold.act.this_binding;
    state.shape_epoch = cold.heap.shape_recycle_epoch;
    if (outcome == THROW) {
        $if $feat(THREADED_DISPATCH):
            cold.heap.tval_copy_ref(&cold.vm.threaded_throw, &cold.vm.throw_value);
            cold.vm.threaded_handoff = ThreadedHandoff.THROW;
            cold.vm.throw_pending = false;
        $endif
        return THROW;
    }
    if (outcome != COMPLETE) return outcome;
    // Bindings and backing stores may have changed while arbitrary JS ran.
    if (!loop_prepare(execution.plan, state, cold, execution.plan.ssa_fields)
        || cold.heap.jit_dependencies_dirty || execution.plan.ssa_invalid
        || cold.heap.shape_recycle_epoch != execution.plan.ssa_shape_epoch) return YIELD;
    $if $feat(SLJIT_STATS): execution.plan.ssa_helper_continued++; $endif
    return COMPLETE;
}
