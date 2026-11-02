module boomkat::vm;

import boomkat::bytecode;
import boomkat::heap;
import boomkat::hobject;
import boomkat::env;
import boomkat::types;
import std::core::mem;

// REPLAY is legal only before an effect. YIELD is an after-effect safepoint;
// resuming it must never execute the bytecode a second time. THROW records the
// faulting instruction, with the before frame still authoritative.
enum SsaHelperOutcome : uint { COMPLETE, THROW, YIELD, REPLAY }
enum SsaEffectPhase : char { BEFORE, AFTER }
enum SsaHelperKind : char { OPERATION, RESOLVE_CALLEE, INLINE_RESERVE }

struct SsaPublishedValue @feat(SLJIT) {
    uint reg;
    TVal value;
}

// Frozen, plan-owned metadata. IDs refer to allocated SSA values, not VM
// registers. live_values preserves typed homes; root_values is its BOXED
// subset (plus before-only boxed operands needed during the helper).
struct SsaHelperSite @feat(SLJIT) {
    SsaHelperSite* next;
    usz allocated_bytes;
    uint pc;
    uint next_pc;
    SsaHelperKind kind;
    uint reserve_regs;
    uint reserve_depth;
    uint callee_value;
    int result_reg;
    CompiledFunction* inline_target;
    SsaFrameId before_frame;
    SsaFrameId after_frame;
    uint* live_values;
    uint live_count;
    uint* root_values;
    uint root_count;
    bool native_resume;
    bool refresh_plan;
    ulong calls @if($feat(SLJIT_STATS));
    SsaFrameEntry* before_entries;
    uint before_count;
    SsaFrameEntry* after_entries;
    uint after_count;
}

// Reuse the allocator's converged CFG liveness at the actual call node.
// No definition-order interval can describe this across cyclic edges.
fn void ssa_helper_capture(SsaAllocation* allocation, uint node) @feat(SLJIT) {
    SsaGraph* g = allocation.g;
    Heap* h = g.heap;
    if (!ssa_charge_work(g, (usz)g.value_count * 3)) return;
    ulong* after = ssa_storage_alloc(g, allocation.words, ulong::size);
    if (after == null) return;
    allocation.copy(after, allocation.live);
    allocation.remove(after, node);
    allocation.remove(allocation.live, node);
    allocation.recovery(allocation.live, g.values[node].pc, g.values[node].before_frame);
    if (!ssa_record_safepoint(g, node, g.values[node].before_frame, g.values[node].after_frame,
            allocation.live, after, allocation.words)) return;
    SsaSafepoint* point = ssa_live_at_helper(g, node);
    uint roots;
    foreach (id : point.live_before[:point.before_count]) {
        if (id != node && g.values[id].rep == BOXED) roots++;
    }
    SsaFrameEntry[] before_entries = ssa_frame_entries(g, point.before_frame);
    SsaFrameEntry[] after_entries = ssa_frame_entries(g, point.after_frame);
    usz bytes = SsaHelperSite::size + ((usz)point.after_count + roots) * uint::size
        + (before_entries.len + after_entries.len) * SsaFrameEntry::size;
    if (!ssa_persistent_reserve(g, bytes)) return;
    SsaHelperSite* site = h.alloc_func(h.heap_udata, bytes);
    if (site == null) { ssa_persistent_release(g, bytes); g.failed = true; return; }
    *site = {};
    site.allocated_bytes = bytes;
    site.live_values = (uint*)((char*)site + SsaHelperSite::size);
    site.root_values = site.live_values + point.after_count;
    site.before_entries = (SsaFrameEntry*)(site.root_values + roots);
    site.before_count = (uint)before_entries.len;
    site.after_entries = site.before_entries + site.before_count;
    site.after_count = (uint)after_entries.len;
    if (site.before_count != 0) mem::copy(site.before_entries, before_entries.ptr, (sz)site.before_count * SsaFrameEntry::size);
    if (site.after_count != 0) mem::copy(site.after_entries, after_entries.ptr, (sz)site.after_count * SsaFrameEntry::size);
    site.native_resume = true;
    site.pc = g.values[node].pc;
    site.next_pc = ssa_decoded_view(g, site.pc).next_pc;
    site.kind = (SsaHelperKind)g.values[node].imm;
    site.reserve_regs = (uint)g.values[node].target;
    site.reserve_depth = (uint)g.values[node].fallto;
    site.callee_value = (uint)ssa_alias(g, g.values[node].a);
    site.result_reg = g.values[node].dst_reg;
    site.inline_target = g.values[node].inline_target;
    site.before_frame = point.before_frame;
    site.after_frame = point.after_frame;
    // Decoded ACCESS nodes guard live receivers and storage at each use.
    // Only the older descriptor/binding/representation caches require a
    // plan-wide refresh after the helper has changed the heap.
    site.refresh_plan = g.plan.ssa_data == null || !g.plan.ssa_data.decoded_body
        || g.plan.memory_count != 0 || g.plan.binding_count != 0 || g.plan.ssa_fields;
    foreach (cache : g.plan.float_cache) if (cache != 0) site.refresh_plan = true;
    if (site.before_frame != SSA_NO_FRAME && g.frame_table[site.before_frame].parent != SSA_NO_FRAME) {
        // A virtual child must be materialized before a general helper can
        // operate on its real activation and frame-local register numbers.
        site.native_resume = false;
    }
    foreach (id : point.live_after[:point.after_count]) {
        if (g.values[id].rep == RAW) site.native_resume = false;
        site.live_values[site.live_count++] = id;
    }
    foreach (id : point.live_before[:point.before_count]) {
        if (id != node && g.values[id].rep == BOXED) site.root_values[site.root_count++] = id;
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

fn usz ssa_helper_metadata_bytes(LoopPlan* plan) @feat(SLJIT) {
    usz bytes;
    for (SsaHelperSite* site = plan.ssa_helpers; site != null; site = site.next) bytes += site.allocated_bytes;
    return bytes;
}

// One allocation serves every array an invocation needs. Blocks are carved
// from a plan-owned free list, so a hot function reaches the allocator only
// while its recursion depth grows. A block is never grown: a deeper activation
// takes a different block, keeping the addresses already published to generated
// code stable.
struct SsaScratch @feat(SLJIT) {
    SsaScratch* next;
    usz bytes;
}

fn SsaScratch* ssa_scratch_acquire(Heap* h, LoopPlan* plan, usz bytes) @feat(SLJIT) {
    SsaScratch** link = &plan.ssa_scratch_free;
    while (*link != null) {
        SsaScratch* block = *link;
        if (block.bytes >= bytes) {
            *link = block.next;
            return block;
        }
        link = &block.next;
    }
    SsaScratch* block = (SsaScratch*)h.alloc_func(h.heap_udata, bytes);
    if (block == null) return null;
    block.bytes = bytes;
    block.next = null;
    return block;
}

fn void ssa_scratch_release(LoopPlan* plan, SsaScratch* block) @feat(SLJIT) {
    block.next = plan.ssa_scratch_free;
    plan.ssa_scratch_free = block;
}

fn void ssa_scratch_free_all(Heap* h, LoopPlan* plan) @feat(SLJIT) {
    while (plan.ssa_scratch_free != null) {
        SsaScratch* block = plan.ssa_scratch_free;
        plan.ssa_scratch_free = block.next;
        h.free_func(h.heap_udata, block);
    }
}

// An invocation owns this storage until its generated frame unwinds. Pointers
// into the movable VM stack are transient; activation_slot is relative to the
// permanent activation_storage, including during nested call_fn segments.
struct SsaExecution @feat(SLJIT) {
    ColdCtx* cold;
    FunctionRun* run;
    CompiledFunction* function;
    LoopPlan* plan;
    JitArtifact* owner;
    ulong owner_generation;
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
    LoopState* state_storage;
    ulong* spills;
    ulong* edge;
    ulong* saved_bits;
    SsaPublishedValue* outputs;
    uint output_count;
    ValueRoot* roots;
    // Descriptors stay at stable addresses for the incremental collector.
    // Membership and clearing scale with the two live maps, not all SSA IDs.
    uint* live_roots;
    bool* root_marks;
    uint live_root_count;
    uint* root_order;
    bool* root_registered;
    uint root_count;
    SsaScratch* scratch;
    bool active;
    bool caller_lost;
    Instruction* vm_resume;
}

fn usz ssa_align8(usz value) @feat(SLJIT) @inline => (value + 7) & ~(usz)7;

// All arrays are allocated before entering generated code. In particular no
// root descriptor points into a VM register window that a callback can move.
// One pooled block carries them all, so a warm invocation performs no
// allocation and the pointers it published to generated code stay put.
fn bool ssa_execution_init(SsaExecution* execution, ColdCtx* cold, LoopPlan* plan,
    uint values, uint spills, uint edges) @feat(SLJIT) {
    Heap* h = cold.heap;
    *execution = {};
    execution.cold = cold;
    execution.function = cold.vm.current_func;
    execution.plan = plan;
    execution.owner = plan.code_owner;
    execution.activation_slot = (uint)(cold.act - &cold.vm.activation_storage[0]);
    execution.register_count = execution.function.num_regs;
    execution.value_capacity = values;
    usz regs = (usz)execution.register_count;
    usz cap = (usz)max(values, 1u);
    // Each carved array is rounded to eight bytes on its own, so an odd
    // capacity still lands every following pointer on its natural alignment.
    usz uint_map = ssa_align8(cap * uint::size);
    usz bool_map = cap * bool::size;
    usz state_bytes = ssa_align8(LoopState::size) + ((usz)spills + edges) * ulong::size;
    usz runtime_bytes = SsaScratch::size
        + state_bytes
        + ssa_align8(regs * TVal::size)
        + ssa_align8(regs * SsaPublishedValue::size)
        + ssa_align8(cap * ulong::size)
        + ssa_align8(cap * ValueRoot::size)
        + uint_map + uint_map
        + bool_map + bool_map;
    if (runtime_bytes > SSA_DEFAULT_BUDGET.max_bytes) return false;
    SsaScratch* scratch = ssa_scratch_acquire(h, plan, ssa_align8(runtime_bytes));
    if (scratch == null) return false;
    execution.scratch = scratch;
    char* base = (char*)scratch;
    usz offset = SsaScratch::size;
    execution.state_storage = (LoopState*)(base + offset);
    offset += ssa_align8(LoopState::size);
    execution.spills = (ulong*)(base + offset);
    offset += (usz)spills * ulong::size;
    execution.edge = (ulong*)(base + offset);
    offset = ssa_align8(offset + (usz)edges * ulong::size);
    execution.input_values = (TVal*)(base + offset);
    offset = ssa_align8(offset + regs * TVal::size);
    execution.outputs = (SsaPublishedValue*)(base + offset);
    offset = ssa_align8(offset + regs * SsaPublishedValue::size);
    execution.saved_bits = (ulong*)(base + offset);
    offset = ssa_align8(offset + cap * ulong::size);
    execution.roots = (ValueRoot*)(base + offset);
    offset = ssa_align8(offset + cap * ValueRoot::size);
    execution.live_roots = (uint*)(base + offset);
    offset = ssa_align8(offset + cap * uint::size);
    execution.root_order = (uint*)(base + offset);
    offset = ssa_align8(offset + cap * uint::size);
    execution.root_marks = (bool*)(base + offset);
    offset += cap * bool::size;
    execution.root_registered = (bool*)(base + offset);
    mem::clear(execution.root_marks, (sz)cap * bool::size);
    mem::clear(execution.root_registered, (sz)cap * bool::size);
    mem::copy(execution.input_values, cold.act.bottom, (sz)regs * TVal::size);
    // Protect both the calling body and all linked artifacts throughout a
    // collecting/reentrant helper. Retirement may invalidate, never free it.
    execution.active = true;
    execution.owner_generation = sljit_artifact_enter(h, execution.owner);
    if (execution.owner_generation == 0) { ssa_execution_dispose(execution); return false; }
    return true;
}

// A descriptor is linked only when its SSA value first needs an owning root.
// Its address stays stable until invocation disposal, including while an
// incremental collector cursor points into this native root chain.
fn bool ssa_execution_root(SsaExecution* execution, uint value) @feat(SLJIT) {
    if (!execution.active || value >= execution.value_capacity) return false;
    if (execution.root_registered[value]) return true;
    assert(execution.root_count < execution.value_capacity);
    TVal undefined;
    undefined.set_undefined();
    execution.cold.heap.push_value_root(&execution.roots[value], undefined);
    execution.root_order[execution.root_count++] = value;
    execution.root_registered[value] = true;
    return true;
}

fn void ssa_execution_dispose(SsaExecution* execution) @feat(SLJIT) {
    Heap* h = execution.cold.heap;
    if (execution.active) {
        for (uint i = execution.root_count; i > 0; i--) h.pop_value_root(&execution.roots[execution.root_order[i - 1]]);
    }
    if (execution.owner_generation != 0) sljit_artifact_leave(h, execution.owner);
    if (execution.scratch != null) ssa_scratch_release(execution.plan, execution.scratch);
    *execution = {};
}

// Validate the original activation and repair pointers after stack relocation.
// This does not import register contents: callers choose their semantic map.
fn bool ssa_execution_rebind(SsaExecution* execution) @feat(SLJIT) {
    ColdCtx* cold = execution.cold;
    Vm* vm = cold.vm;
    if (execution.activation_slot >= MAX_CALLS) return false;
    Activation* act = &vm.activation_storage[execution.activation_slot];
    if (vm.activation_count == 0 || &vm.activations[vm.activation_count - 1] != act
        || act.func != execution.function || vm.current_func != execution.function) return false;
    cold.act = act;
    cold.capture_refs = null;
    if (cold.regs_base_ptr != null) *cold.regs_base_ptr = act.bottom;
    return true;
}

fn bool ssa_execution_reload(SsaExecution* execution) @feat(SLJIT) {
    if (!ssa_execution_rebind(execution)) return false;
    mem::copy(execution.input_values, execution.cold.act.bottom, (sz)execution.register_count * TVal::size);
    return true;
}

// Native after-edges carry SSA joins, while fresh VM reentries import a full
// snapshot at invocation init. A completed helper needs only its frozen live
// post-frame and declared result, including any aliased or cleared operands.
fn bool ssa_execution_import_after(SsaExecution* execution, SsaHelperSite* site) @feat(SLJIT) {
    if (site.result_reg >= (int)execution.register_count) return false;
    foreach (entry : site.after_entries[:site.after_count]) if (entry.reg >= execution.register_count) return false;
    TVal* regs = execution.cold.act.bottom;
    foreach (entry : site.after_entries[:site.after_count]) execution.input_values[entry.reg] = regs[entry.reg];
    if (site.result_reg >= 0) execution.input_values[site.result_reg] = regs[site.result_reg];
    return true;
}

// Native saved homes contain NaN-boxed bits. The alternate value build keeps
// the interpreter available while JIT admission remains disabled.
fn bool ssa_decode_boxed_bits(ulong bits, TVal* value) @feat(SLJIT) @inline {
    $if types::USE_NANBOX:
        *value = bitcast(bits, TVal);
        return true;
    $else
        value.set_undefined();
        return false;
    $endif
}

// Anchor the entire new root map before releasing ANY prior native root.
// Keeping one stable descriptor per value avoids cursor invalidation when an
// incremental collection is partway through the native root chain.
fn bool ssa_execution_roots(SsaExecution* execution, SsaHelperSite* site) @feat(SLJIT) {
    Heap* h = execution.cold.heap;
    if (site.root_count > execution.value_capacity) return false;
    for (uint i = 0; i < site.root_count; i++) if (site.root_values[i] >= execution.value_capacity) return false;
    for (uint i = 0; i < site.root_count; i++) if (!ssa_execution_root(execution, site.root_values[i])) return false;
    for (uint i = 0; i < site.root_count; i++) {
        uint value = site.root_values[i];
        TVal boxed;
        if (!ssa_decode_boxed_bits(execution.saved_bits[value], &boxed)) return false;
        if (boxed.is_refcounted() && boxed.get_heapptr() != null) ((HeapHeader*)boxed.get_heapptr()).incref();
    }
    // The temporary reference above keeps cross-slot swaps alive while the
    // ordinary owning root update shades the new value and releases the old.
    for (uint i = 0; i < site.root_count; i++) {
        uint value = site.root_values[i];
        TVal boxed;
        if (!ssa_decode_boxed_bits(execution.saved_bits[value], &boxed)) return false;
        h.tval_copy_ref(&execution.roots[value].value, &boxed);
        h.decref_tval(&boxed);
    }
    for (uint i = 0; i < site.root_count; i++) execution.root_marks[site.root_values[i]] = true;
    for (uint i = 0; i < execution.live_root_count; i++) {
        uint value = execution.live_roots[i];
        if (!execution.root_marks[value]) {
            h.decref_tval(&execution.roots[value].value);
            execution.roots[value].value.set_undefined();
        }
    }
    for (uint i = 0; i < site.root_count; i++) {
        uint value = site.root_values[i];
        execution.live_roots[i] = value;
        execution.root_marks[value] = false;
    }
    execution.live_root_count = site.root_count;
    return true;
}

fn bool ssa_execution_publish(SsaExecution* execution) @feat(SLJIT) {
    ColdCtx* cold = execution.cold;
    if (!ssa_execution_rebind(execution) || execution.output_count > execution.register_count) return false;
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
        // Publish exactly the same before-frame into the stable operand
        // snapshot. Call windows are semantic reads in this recovery map.
        execution.input_values[output.reg] = *dest;
    }
    execution.output_count = 0;
    return true;
}

// A helper may allocate and enter arbitrary JavaScript. It is always an
// unknown heap/layout/binding clobber, even when its result is unused.
fn SsaHelperOutcome ssa_helper_execute(SsaExecution* execution, SsaHelperSite* site) @feat(SLJIT) @noinline {
    $if $feat(SLJIT_STATS): site.calls++; $endif
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
    DecodedBytecode view = bytecode::decode_bytecode(cf.code, cf.code_count, site.pc);
    if (!view.valid) return REPLAY;
    DecodedInsn ins = view.insn;
    cold.act.curr_pc = cf.code + site.pc;
    if (site.kind != OPERATION) {
        if (site.kind == RESOLVE_CALLEE) {
            TVal callee;
            if (!loop_binding_effective(cf.code + view.payload_pc, ins, cold, &callee)) return REPLAY;
            cold.heap.tval_copy_ref(cold.act.bottom + ins.a, &callee);
            track_heap_store(cold.act, cold.act.bottom + ins.a, ins.a);
        } else {
            if (site.callee_value >= execution.value_capacity || !execution.root_registered[site.callee_value]) return REPLAY;
            TVal callee = execution.roots[site.callee_value].value;
            if (!callee.is_object() || callee.get_heapptr() == null) return REPLAY;
            HObject* function = callee.get_heapptr();
            if (!function.is_callable() || function.is_bound() || function.is_proxy()
                || function.callable_kind() != hobject::CallableKind.COMPILED_FN) return REPLAY;
            CompiledFunction* target = function.extra.func.comp_func;
            EnvRecord* lex = function.extra.func.lex_env;
            if (target != site.inline_target || target.realm != cold.heap.realm
                || !target.call_flags.lean_plain || !target.call_flags.ignores_this
                || function.extra.func.var_env == null || (lex != null && lex.is_with())) return REPLAY;
            if (site.reserve_depth > cold.vm.activation_capacity - cold.vm.activation_count) return REPLAY;
            TVal* top = callback_frame_top(cold.vm);
            usz needed = (usz)(top - cold.vm.valstack) + site.reserve_regs;
            if (needed > uint::max || !ensure_valstack(cold.vm, (uint)needed)) return REPLAY;
        }
        if (!ssa_execution_rebind(execution)) return REPLAY;
        cold.heap.safepoint_gc_on_call();
        if (!sljit_artifact_is_live(execution.owner, execution.owner_generation)) return REPLAY;
        $if $feat(SLJIT_STATS): if (site.kind == INLINE_RESERVE) execution.plan.ssa_inline_entries++; $endif
        execution.outcome = COMPLETE;
        return COMPLETE;
    }
    if (ins.op == Opcode.CALL || ins.op == Opcode.CALL_UNDEF_THIS
        || ins.op == Opcode.CALL_VAR || ins.op == Opcode.CALL_GLOBAL) {
        bool fused = ins.op == Opcode.CALL_VAR || ins.op == Opcode.CALL_GLOBAL;
        uint base = fused ? ins.a : ins.b;
        uint argc = fused ? ins.b : ins.c;
        if (base + 2 + argc > execution.register_count || ins.a >= execution.register_count) return REPLAY;
        TVal callee = cold.act.bottom[base];
        // The shared non-observable binding resolver refuses accessors/with
        // scopes before invoking anything. Those sites retain exact VM EXIT.
        if (fused && !loop_binding_effective(cf.code + view.payload_pc, ins, cold, &callee)) return REPLAY;
        ValueRoot callee_root;
        cold.heap.push_value_root(&callee_root, callee);
        defer cold.heap.pop_value_root(&callee_root);
        TVal receiver;
        receiver.set_undefined();
        if (ins.op == Opcode.CALL) { receiver = cold.act.bottom[base + 1]; }
        else { cold.heap.set_reg_undefined(cold.act.bottom + base + 1); }
        if (fused) cold.heap.tval_copy_ref(cold.act.bottom + base, &callee);
        SsaNativeCallOutcome native = ssa_helper_native_call(execution, site, view, callee, base, argc);
        if (native == YIELD) return YIELD;
        if (native == DECLINE) {
            if (argc != 0) mem::copy(execution.input_values + base + 2, cold.act.bottom + base + 2, (sz)argc * TVal::size);
            // Stable snapshot arguments survive VM stack relocation. Native
            // roots and the published VM frame own the borrowed references.
            TVal result = cold.heap.call_fn(cold.vm, callee,
                execution.input_values + base + 2, argc, receiver);
            if (!ssa_execution_rebind(execution)) {
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
            track_heap_store(cold.act, cold.act.bottom + ins.a, ins.a);
        }
    } else if (function_alloc_op(ins.op) && !view.wide) {
        long status = sljit_native_operation(cold, site.pc);
        if (status == 0) return REPLAY;
    } else {
        // Feedback may have filled this site's IC after the plan compiled.
        // Ask for one rebuild instead of paying a helper call per execution
        // for the life of the plan. A filled cache also settles the site: the
        // rebuild either lowers it directly or leaves the body to the
        // baseline tier.
        if (!execution.plan.ssa_recompile_wanted && execution.function.sljit_recompiles < 2
            && (ssa_access_would_specialize(cold.heap, execution.function, site.pc)
                || ssa_access_site_refused(cold.heap, execution.function, site.pc))) {
            execution.plan.ssa_recompile_wanted = true;
        }
        SsaHelperOutcome outcome = ssa_vm_step(execution, site);
        if (outcome != COMPLETE) { execution.outcome = outcome; return outcome; }
    }
    execution.phase = AFTER;
    cold.act.curr_pc = cf.code + execution.after_pc;
    // Results are already owned and shaded by the VM frame before collection.
    cold.heap.safepoint_gc_on_call();
    if (!ssa_execution_rebind(execution)) { execution.outcome = YIELD; return YIELD; }
    // Invalidated code remains pinned until unwind, but cannot be continued.
    execution.outcome = execution.plan.ssa_invalid
        || !sljit_artifact_is_live(execution.owner, execution.owner_generation) ? YIELD : COMPLETE;
    return execution.outcome;
}

// Legacy fixed-window adapter. The graph and helper ABI are shared with the
// dynamic execution state; only this gateway copies its older LoopState ABI.
fn SsaHelperOutcome ssa_helper_state(LoopState* state, SsaHelperSite* site) @feat(SLJIT) @noinline {
    SsaExecution* execution = state.execution;
    execution.plan.ssa_helper_calls++;
    SsaHelperOutcome outcome = ssa_helper_execute(execution, site);
    state.dirty = 0;
    state.resume_pc = execution.phase == AFTER ? execution.after_pc : site.pc;
    ColdCtx* cold = execution.cold;
    if (!ssa_execution_rebind(execution)) return YIELD;
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
    if (!ssa_execution_import_after(execution, site)) return YIELD;
    // Bindings and backing stores may have changed while arbitrary JS ran.
    if (site.refresh_plan) {
        for (uint reg = 0; reg < execution.register_count && reg < LOOP_REGS; reg++) state.values[reg] = cold.act.bottom[reg];
        if (!loop_prepare(execution.plan, state, cold, execution.plan.ssa_fields)) return YIELD;
    }
    if (cold.heap.jit_dependencies_dirty || execution.plan.ssa_invalid
        || cold.heap.shape_recycle_epoch != execution.plan.ssa_shape_epoch) return YIELD;
    $if $feat(SLJIT_STATS): execution.plan.ssa_helper_continued++; $endif
    return COMPLETE;
}
