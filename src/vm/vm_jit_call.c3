// Native calls of the baseline tier (src/jit/baseline.c3): a call site in
// generated code publishes a lean callee's frame through the threaded call
// shapes and runs the callee's native code on the C stack.
module boomkat::vm @feat(SLJIT);

import boomkat::jit;
import boomkat::bytecode;
import boomkat::types;
import boomkat::heap;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::env;

// Native calls nested on one Dispatch's C stack before a call takes the
// slow path, which leaves through Vm.run.
const uint JIT_NATIVE_DEPTH_CAP = 100;

// A call site's result when the callee completed without a frame.
const usz JIT_CALL_DONE = 1;

// A call site's result when the call takes its thunk.
const long JIT_CALL_SLOW = -1;

// The native call at the instruction before `next`: publish the callee's
// frame (jit_call_enter), run its native code on the C stack and resume the
// caller once it returned. Returns 0 to continue at `next`,
// BASELINE_REDISPATCH when the caller resumes elsewhere (a handler caught a
// throw), JIT_CALL_SLOW when the call takes its thunk, or the callee's status
// for Vm.run. One C frame per call keeps the floor in a local.
fn long jit_call(Dispatch* ds, ulong next_arg) {
    Instruction* next = (Instruction*)(usz)next_arg;
    uint old_floor = ds.jit_floor;
    void* entry = jit_call_enter(ds, next);
    if (entry == null) return JIT_CALL_SLOW;
    if (entry == (void*)JIT_CALL_DONE) return 0;
    long status = ((jit::BaselineFn)entry)(ds);
    ds.jit_floor = old_floor;
    ds.jit_depth--;
    if (status != jit::BASELINE_RETURNED) return status;
    Vm* vm = ds.vm;
    Activation* act = &vm.activations[vm.activation_count - 1];
    ds.act = act;
    CompiledFunction* f = (CompiledFunction*)act.func;
    if (vm.heap.realm != f.realm) vm.heap.enter_realm(f.realm);
    vm.current_func = f;
    if (f.code != ds.code_base) jit_view(ds, f);
    ds.regs_base = act.bottom;
    return ds.curr_pc == next ? 0 : jit::BASELINE_REDISPATCH;
}

// Enter the realm of the frame a native call site resumes.
fn void jit_enter_frame_realm(Dispatch* ds) {
    ds.vm.heap.enter_realm(((CompiledFunction*)ds.act.func).realm);
}

// Point ds's code, constant and cache view at `f`, a function that has run
// (its caches exist), as Dispatch.load_frame does.
fn void jit_view(Dispatch* ds, CompiledFunction* f) @private @inline {
    ds.code_base = f.code;
    ds.code_count = f.code_count;
    ds.code_end = f.code + f.code_count;
    ds.constants = f.constants;
    ds.ic_base = (hobject::ICEntry*)f.ic_entries;
    ds.var_ic_base = (hobject::VarICEntry*)f.var_ic_entries;
    ds.nregs = f.num_regs;
}

// Publish the frame of the call at the instruction before `next` and return
// the callee's native entry, JIT_CALL_DONE for a trivial callee, or null when
// the call takes its thunk. On a native entry ds describes the callee's frame
// and ds.jit_floor the caller's depth.
fn void* jit_call_enter(Dispatch* ds, Instruction* next) @private @inline {
    Instruction* pc = next - 1;
    Vm* vm = ds.vm;
    jit::JitStats* st = &ds.heap.jit_stats;
    if (ds.jit_depth >= JIT_NATIVE_DEPTH_CAP) { st.calls_depth++; return null; }
    if (ds.ic_base == null || ds.var_ic_base == null) { st.calls_declined++; return null; }
    ds.curr_pc = next;
    ColdCtx* cold = &ds.cold;
    th_bind_ic_bias(cold, ds.code_base, ds.ic_base, ds.var_ic_base);
    TVal* regs = ds.regs_base;
    if (pc.op == Opcode.NEW_OBJ || pc.op == Opcode.APPLY_ARGS) return jit_call_relayed(ds, pc, st);
    LeanCall r;
    uint nargs = pc.op == Opcode.CALL || pc.op == Opcode.CALL_UNDEF_THIS ? pc.c : pc.b;
    switch (pc.op) {
        case CALL: r = @lean_call_method(pc, regs, cold, true);
        case CALL_UNDEF_THIS: r = @lean_call_undef_this(pc, regs, cold, true);
        case CALL_VAR: r = @lean_call_var(pc, regs, cold, true);
        case CALL_GLOBAL: r = @lean_call_global(pc, regs, cold, true);
        default: unreachable("not a native call shape");
    }
    switch (r) {
        case DONE:
            st.calls_trivial++;
            return (void*)JIT_CALL_DONE;
        case NO_CODE:
            st.calls_no_code++;
            return null;
        case NATIVE:
            st.calls_builtin++;
            return null;
        case ENTERED:
        case ENTERED_ARGS:
            break;
        default:
            st.calls_declined++;
            return null;
    }
    Activation* la = ds.act;
    CompiledFunction* target = (CompiledFunction*)la.func;
    if (r == ENTERED_ARGS) {
        bind_register_arguments(vm, la, target, (HObject*)la.tv_func.get_heapptr(), la.bottom, nargs);
    }
    // The publish made the callee's activation and registers current and
    // checked its realm; its code view is all that is left to load.
    jit_view(ds, target);
    ds.curr_pc = target.code;
    ds.jit_floor = vm.activation_count - 1;
    ds.jit_depth++;
    st.calls_native++;
    if (@unlikely(ds.heap.opt.enabled)) jit::opt_note_entry(ds.heap, target);
    return jit::baseline_entry(target);
}

// The compiled function a callee register holds, or null.
fn CompiledFunction* jit_compiled_callee(TVal callee) @inline {
    if (!callee.is_object()) return null;
    HObject* fn_obj = (HObject*)callee.get_heapptr();
    if (fn_obj == null || !fn_obj.is_callable() || fn_obj.callable_kind() != hobject::CallableKind.COMPILED_FN) return null;
    return (*fn_obj.extra_ptr()).func.comp_func;
}

// NEW_OBJ of a simple constructor, completed in place as th_new_obj does:
// 0 when the object is built and stored, JIT_CALL_SLOW to leave the
// instruction to jit_call.
fn long jit_new_simple(Dispatch* ds, Instruction* next) {
    Instruction* pc = next - 1;
    Instruction insn = *pc;
    TVal* regs = ds.regs_base;
    TVal callee = regs[insn.b];
    if (!callee.is_object() || ds.ic_base == null) return JIT_CALL_SLOW;
    HObject* ctor = (HObject*)callee.get_heapptr();
    if (!ctor.is_callable() || !ctor.is_constructable()
        || ctor.callable_kind() != hobject::CallableKind.COMPILED_FN) return JIT_CALL_SLOW;
    CompiledFunction* target = (*ctor.extra_ptr()).func.comp_func;
    if (target == null) return JIT_CALL_SLOW;
    target.classify_lean_call();
    // simple_constructor is only set for a constructable, non-derived function
    // without a brand or field initializers.
    if (!target.call_flags.simple_constructor) return JIT_CALL_SLOW;
    Vm* vm = ds.vm;
    hobject::ICEntry* ic = ds.ic_base + (uint)(pc - ds.code_base);
    if (ic.key.borrow() != (void*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE] || ic.has_proto
        || ic.shape_id != ctor.shape_id || ic.shape_gen != ctor.shape_generation(vm.heap)
        || ic.prop_flags.is_accessor || ic.prop_idx >= ctor.prop_count) return JIT_CALL_SLOW;
    TVal proto = ctor.prop_values()[ic.prop_idx].get();
    if (!proto.is_object()) return JIT_CALL_SLOW;
    ds.curr_pc = next;
    HObject* obj = vm.heap.alloc_plain_object() ?? null;
    if (obj == null) return JIT_CALL_SLOW;
    vm.heap.set_prototype(obj, (HObject*)proto.get_heapptr());
    if (!init_simple_constructor(vm, target, obj, regs + insn.b + 2, insn.c)) return JIT_CALL_SLOW;
    TVal* ra = regs + insn.a;
    ra.set_object(obj);
    track_heap_store(ds.act, ra, (uint)insn.a);
    ds.heap.jit_stats.calls_trivial++;
    return 0;
}

// NEW_OBJ and APPLY_ARGS (with the CALL_S it is fused with) through their
// threaded handlers, th_new_obj and th_apply_args, which publish the
// callee's frame, or complete a simple constructor in place, or decline
// before writing anything. A callee without native code declines first, so
// the thunk counts its entry.
fn void* jit_call_relayed(Dispatch* ds, Instruction* pc, jit::JitStats* st) @private {
    Vm* vm = ds.vm;
    TVal* regs = ds.regs_base;
    CompiledFunction* target = jit_compiled_callee(pc.op == Opcode.NEW_OBJ ? regs[pc.b] : regs[pc.a + 1]);
    if (target == null) { st.calls_builtin++; return null; }
    bool simple = pc.op == Opcode.NEW_OBJ && target.call_flags.simple_constructor;
    if (!simple && target.jit_code == null) { st.calls_no_code++; return null; }
    if (!jit_relay_ready) jit_relay_init();
    uint depth = vm.activation_count;
    Instruction* r = pc.op == Opcode.NEW_OBJ
        ? @new_obj(pc, &jit_stop_table, regs, &ds.cold, true)
        : @apply_args(pc, &jit_stop_table, regs, &ds.cold, true);
    if (vm.activation_count == depth) {
        if (r == pc) { st.calls_declined++; return null; }
        st.calls_trivial++;
        return (void*)JIT_CALL_DONE;
    }
    // The caller resumes past the CALL_S an APPLY_ARGS entered; its return
    // redispatches there.
    ds.load_frame();
    ds.jit_floor = vm.activation_count - 1;
    ds.jit_depth++;
    st.calls_native++;
    if (@unlikely(ds.heap.opt.enabled)) jit::opt_note_entry(ds.heap, target);
    return jit::baseline_entry(target);
}

// RET and RETUNDEF as the threaded returns (th_leaf_return and
// th_pop_frame, else th_return_general). For a frame a native call site waits for, returns
// BASELINE_RETURNED with the caller current and ds.curr_pc at its resume
// point; a caller in another realm takes the thunk. For a frame Vm.run
// entered, returns RESTART with the caller's frame to be loaded, as op_ret's
// frame switch does. 0 takes the thunk.
fn long jit_ret(Dispatch* ds, ulong next_arg) {
    Vm* vm = ds.vm;
    bool waiting = ds.jit_floor != 0 && vm.activation_count == ds.jit_floor + 1;
    if (!waiting && (ds.jit_floor != 0 || ds.jit_depth != 0 || vm.activation_count < 2)) return 0;
    Activation* fa = ds.act;
    Activation* up = &vm.activations[vm.activation_count - 2];
    if (waiting && up.func != fa.func && (up.func == null || ((CompiledFunction*)up.func).realm != vm.heap.realm)) return 0;
    Instruction* pc = (Instruction*)(usz)next_arg - 1;
    bool is_undefined = pc.op == Opcode.RETUNDEF;
    TVal value;
    if (is_undefined) {
        value.set_undefined();
    } else {
        value = ds.regs_base[pc.a];
    }
    Activation* caller;
    bool cross_function;
    if (th_leaf_return(vm, fa, value, is_undefined, &caller, &cross_function)) {
        th_pop_frame(&ds.cold, fa, caller);
    } else {
        // Base constructors and frames with tracked string registers, as
        // th_return_general returns them; it pops the frame or declines
        // before writing anything.
        if (!jit_relay_ready) jit_relay_init();
        uint depth = vm.activation_count;
        th_return_general(pc, &jit_stop_table, &ds.cold, value, is_undefined);
        if (vm.activation_count == depth) return 0;
        caller = &vm.activations[vm.activation_count - 1];
    }
    ds.curr_pc = caller.curr_pc;
    if (!waiting) {
        ds.needs_restart = true;
        return (long)OpStatus.RESTART.ordinal;
    }
    return jit::BASELINE_RETURNED;
}

// The native entry of the frame a RESTART leaves current, loaded into ds as
// Vm.run would load it before entering that entry, or null when the restart
// goes to Vm.run: a native caller waits on the C stack, an interrupt hook
// wants the restart poll, a handoff is pending, or the frame has no code
// yet (Vm.run counts the entry and compiles).
fn void* jit_switch(Dispatch* ds) {
    Vm* vm = ds.vm;
    if (ds.jit_depth != 0 || ds.jit_floor != 0 || !ds.needs_restart || vm.activation_count == 0) return null;
    if (vm.threaded_handoff != ThreadedHandoff.NONE) return null;
    if (vm.heap.capi_interrupt_fn != null || vm.heap.capi_runtime != null) return null;
    CompiledFunction* f = (CompiledFunction*)vm.activations[vm.activation_count - 1].func;
    if (f == null || f.jit_code == null) return null;
    ds.needs_restart = false;
    ds.load_frame();
    ds.heap.jit_stats.switches++;
    return jit::baseline_entry(f);
}

// The owner of the cached prototype property entry `ic` names for the
// receiver `hobj`, whose shape matched, as ic_resolve_slot resolves it; null
// when the entry no longer describes the chain or the owner is a proxy.
fn HObject* jit_ic_owner(hobject::ICEntry* ic, HObject* hobj) {
    HObject* owner = hobject::ic_resolve_owner(ic, hobj);
    if (owner == null || owner.is_proxy()) return null;
    return owner;
}

// The slot of the data property `key`, an interned name, on the
// plain object `hobj` or on a plain prototype within JIT_WALK_DEPTH links of
// it, or a slot holding undefined when the key is on none of the chain, after
// the site's cache tests missed; null for
// anything else (an accessor, an exotic object on the way, a longer chain),
// which the thunk resolves. It is get_prop_or_accessor_proto's walk, noting an
// owner on the receiver or its prototype in the megamorphic cache as that does.
fn hobject::PropValue* jit_get_missed(Heap* h, HObject* hobj, void* key) {
    hstring::HString* name = (hstring::HString*)key;
    if (name == null || !name.is_interned() || name.is_arridx() || name.is_hidden()) return null;
    HObject* cur = hobj;
    for (uint depth = 0; cur != null && depth <= JIT_WALK_DEPTH; depth++) {
        if (!hobject::plain_property_object(cur)) return null;
        int idx = cur.find_prop_idx(key, h);
        if (idx >= 0) {
            if (cur.get_prop_flags((uint)idx, h).is_accessor) return null;
            if (depth <= 1) hobject::mega_cache_store(h, hobj, key, cur, idx, false);
            return &cur.prop_values()[idx];
        }
        cur = cur.prototype;
    }
    if (cur != null) return null;
    jit_undefined.set_undefined();
    return (hobject::PropValue*)&jit_undefined;
}

const uint JIT_WALK_DEPTH = 6;
TVal jit_undefined @private;

// An absent-property add through the site entry `ic`, whose key matched, to
// the plain object `hobj`, as th_put_cached's absent case and th_put_absent:
// a value that needs no count or barrier work, appended into spare property
// capacity. False leaves the store to the thunk.
fn bool jit_put_absent(Heap* h, HObject* hobj, hobject::ICEntry* ic, TVal* value) {
    if (!hobject::ic_matches_absent_put(ic, hobj, ic.key.borrow(), h)) return false;
    if (value.is_heap_allocated()) return hobj.append_cached_prop(ic, *value, h);
    if (hobj.prop_count >= hobj.prop_capacity || hobj.prop_hash != null) return false;
    if (hobj.gc.prototype_observed) h.bump_prototype_epoch();
    hobject::PropValue* slot = &hobj.prop_values()[hobj.prop_count];
    *slot = (hobject::PropValue)*value;
    hobj.prop_count++;
    hobj.shape_id = ic.absent_next_shape;
    return true;
}

// NEWARR, NEWARR_CONST, NEWOBJ and NEWOBJ_SHAPE as their threaded handlers
// run them, without the handler's table call and bias setup: true when the
// result register is written, false when the allocation failed and the
// instruction is left to the thunk.
fn bool jit_alloc(Dispatch* ds, Instruction* next) {
    Instruction* pc = next - 1;
    Vm* vm = ds.vm;
    ds.curr_pc = next;
    switch (pc.op) {
        case NEWARR: return alloc_newarr(vm, ds.act, ds.regs_base, *pc);
        case NEWARR_CONST: return alloc_newarr_const(vm, ds.act, ds.regs_base, *pc);
        default: return alloc_newobj(ds.heap, ds.act, ds.regs_base, *pc);
    }
}

// The counted and traced store of `value` over `slot`, owned by `hobj`, that
// th_store_slot_ref_next runs for a store the plain path declines.
fn bool jit_store_slot(Heap* h, HObject* hobj, hobject::PropValue* slot, TVal* value) {
    h.store_slot_ref(hobj, slot, value);
    return true;
}

// A handler table whose every entry stops: a threaded handler called with it
// runs its own instruction and returns the next pc instead of continuing.
HandlerTable jit_stop_table @private;
bool jit_relay_ready @private;

fn Instruction* jit_stop(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @private => pc;

fn void jit_relay_init() @private @noinline {
    init_threaded_handlers();
    for (usz i = 0; i < TH_TABLE_SIZE; i++) jit_stop_table.fns[i] = &jit_stop;
    jit_relay_ready = true;
}

// Run the instruction before `next` through its threaded handler, as the
// burst would: true when the handler completed it and fell through to
// `next`, false when it declined (the operation function runs it).
fn bool jit_relay(Dispatch* ds, Instruction* next) {
    if (!jit_relay_ready) jit_relay_init();
    if (ds.ic_base == null || ds.var_ic_base == null) return false;
    ds.curr_pc = next;
    Instruction* pc = next - 1;
    $if $feat(OP_PROFILE): opprof_relay[pc.op.ordinal]++; opprof_relay_site((CompiledFunction*)ds.act.func, pc);
    $endif
    ColdCtx* cold = &ds.cold;
    th_bind_ic_bias(cold, ds.code_base, ds.ic_base, ds.var_ic_base);
    // The handler completes numbers and concatenations without the operation
    // function, so the operand classes are recorded here.
    if (has_feedback(pc.op)) note_feedback(ds, { .op = pc.op, .a = pc.a, .b = pc.b, .c = pc.c }, false);
    // A variable site filled under another activation's scope chain is
    // rearmed first, as th_var_rearm does before running the handler again.
    if ((pc.op == Opcode.GETVAR || pc.op == Opcode.PUTVAR_ASSIGN || pc.op == Opcode.INC_VAR)
        && th_var_ic_moved(pc, cold)
        && !var_ic_rearm(th_ic_entry(pc, cold), cold.act.lex_env, cold.heap)) return false;
    return g_threaded_table.fns[pc.op.ordinal](pc, &jit_stop_table, ds.regs_base, cold) == next;
}

// A CALL whose callee is a builtin, through th_call_native as the threaded
// burst runs it (identity fast paths such as charCodeAt, then the builtin's
// own dispatch) instead of op_call. False when it declined before running
// anything; otherwise `status` is what the operation function would return,
// with the burst's throw and re-dispatch handoffs completed as vm_dispatch
// completes them.
fn bool jit_call_builtin(Dispatch* ds, Instruction* next, OpStatus* status) {
    if (!jit_relay_ready) jit_relay_init();
    if (ds.ic_base == null || ds.var_ic_base == null) return false;
    Vm* vm = ds.vm;
    Instruction* pc = next - 1;
    TVal* regs = ds.regs_base;
    if (th_lean_target(vm, regs[pc.b], regs + pc.b + 2, false) != null) return false;
    ColdCtx* cold = &ds.cold;
    th_bind_ic_bias(cold, ds.code_base, ds.ic_base, ds.var_ic_base);
    Instruction* r = th_call_native(pc, &jit_stop_table, regs, cold, pc.b, pc.a, pc.c);
    ThreadedHandoff handoff = vm.threaded_handoff;
    vm.threaded_handoff = ThreadedHandoff.NONE;
    switch (handoff) {
        case THROW:
            TVal err_val = vm.threaded_throw;
            ds.curr_pc = next;
            if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                *status = op_uncaught(ds, &err_val);
            } else {
                *status = ds.needs_restart ? RESTART : NEXT;
            }
            return true;
        case CALL:
            ds.curr_pc = next;
            *status = op_calls(ds, vm.threaded_call);
            return true;
        case NONE:
            break;
    }
    if (r == pc) return false;
    ds.curr_pc = r;
    *status = NEXT;
    return true;
}
