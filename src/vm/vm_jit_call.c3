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
import boomkat::builtins;
import std::math;

// Native calls nested on one Dispatch's C stack before a call takes the
// slow path, which leaves through Vm.run.
const uint JIT_NATIVE_DEPTH_CAP = 100;

// A call site's result when the callee completed without a frame.
const usz JIT_CALL_DONE = 1;

// A call site's result when the call takes its thunk.
const long JIT_CALL_SLOW = -1;

// jit_call_builtin's `raw` when the call left no status of its own for the thunk to return.
const long JIT_NO_RAW = -2;

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
    return jit_run_entered(ds, entry, old_floor, next);
}

// Run the native entry of a published callee frame (jit_call_enter) and resume the caller once
// it returned, as jit_call's contract has it. `old_floor` is the caller's floor.
fn long jit_run_entered(Dispatch* ds, void* entry, uint old_floor, Instruction* next) @inline {
    // The callee's frame, at the floor, returns to the trampoline, which returns here.
    uint callee = ds.jit_floor;
    long status = jit::jit_enter(ds, entry, jit::trampoline().ret);
    ds.jit_floor = old_floor;
    ds.jit_depth--;
    Vm* vm = ds.vm;
    if (status != jit::BASELINE_RETURNED) {
        // Nothing waits for the frame any more, if it is still there.
        if (vm.activation_count > callee) vm.activations[callee].forget_return();
        return status;
    }
    Activation* act = &vm.activations[vm.activation_count - 1];
    ds.act = act;
    CompiledFunction* f = (CompiledFunction*)act.func;
    if (vm.heap.realm != f.realm) vm.heap.enter_realm(f.realm);
    vm.current_func = f;
    if (f.code != ds.code_base) jit_view(ds, f);
    ds.regs_base = act.bottom;
    return ds.curr_pc == next ? 0 : jit::BASELINE_REDISPATCH;
}

// Make the VM's frame state describe `la`, the record of the frame generated code runs, as
// Dispatch.load_frame does but for ds.curr_pc, which each call from generated code into C sets
// itself (a thunk or helper is handed its resume point). Calls and returns
// between generated frames move only the record register; everything that reads the frame state
// (every call into C, every way out of generated code) runs this first (Asm.emit_sync). The state
// is whole whenever ds.act is the record register's: every C path that switches frames for
// generated code to continue in finishes the switch (jit_load).
fn void jit_sync(Dispatch* ds, Activation* la) {
    if (ds.act != la) jit_load(ds, la);
}

fn void jit_load(Dispatch* ds, Activation* la) {
    Vm* vm = ds.vm;
    if (la.flags & ACT_FLAG_LAZY) jit_fill(vm, la);
    CompiledFunction* f = (CompiledFunction*)la.func;
    vm.activation_count = (uint)(la - vm.activations) + 1;
    ds.act = la;
    if (vm.heap.realm != f.realm) vm.heap.enter_realm(f.realm);
    vm.current_func = f;
    vm.valstack_bottom = la.bottom;
    vm.valstack_top = la.bottom + f.num_regs;
    *ds.regs_base_ptr = la.bottom;
    ds.capture_refs = null;
    jit_view(ds, f);
    th_bind_ic_bias(&ds.cold, f.code, f.ic_entries, f.var_ic_entries);
}

// Fill in the frames generated code pushed (ACT_FLAG_LAZY) from the bottom of their run up to
// `top`, as th_publish_lean writes them. Lazy frames sit only above every other frame, each
// called from its parent's code: the function is in the parent's callee register, two slots below
// the frame's window, and the parent's value stack ends at its registers.
fn void jit_fill(Vm* vm, Activation* top) @noinline {
    Activation* low = top;
    while (low > vm.activations && ((low - 1).flags & ACT_FLAG_LAZY) != 0) low--;
    for (Activation* a = low; a <= top; a++) {
        Activation* parent = a - 1;
        HObject* function = (HObject*)a.bottom[-2].get_heapptr();
        HObjectFunction* fd = &(*function.extra_ptr()).func;
        EnvRecord* env = fd.var_env;
        EnvRecord* cap = fd.lex_env;
        a.func = fd.comp_func;
        a.tv_func.set_object_borrowed(function);
        a.caller_valstack_top = parent.bottom + ((CompiledFunction*)parent.func).num_regs;
        a.parent = parent;
        // A function that needs a scope of its own has it from its call entry (jit_entry_scope).
        if (!fd.comp_func.flags.needs_env) {
            a.var_env = env;
            a.lex_env = (cap == null || cap == env || !cap.flags.is_declarative) ? env : cap;
        }
        a.cat = null;
        a.forin = null;
        a.async_gen_state = null;
        a.async_promise = null;
        a.new_target = (a.flags & ACT_FLAG_CONSTRUCT) != 0 ? function : null;
        a.serial = ++vm.activation_serial;
        a.flags &= ~ACT_FLAG_LAZY;
    }
}

// The function scope the call entry of a function that needs one (CompiledFunction.env_call_ok)
// creates for `la`, the record it is publishing for a call of `function`, placed as th_publish_lean
// places the scope @lean_publish creates. Allocating only asks the next safepoint to collect, so
// the frames need not be synced. 1, or 0 with the record untouched when there is no memory.
fn long jit_entry_scope(Dispatch* ds, HObject* function, Activation* la) {
    HObjectFunction* fd = &(*function.extra_ptr()).func;
    CompiledFunction* target = fd.comp_func;
    Heap* h = ds.heap;
    EnvRecord* own = env::env_create_function_scope(h, fd.var_env, target.scope_capacity()) ?? null;
    if (own == null) return 0;
    EnvRecord* cap = fd.lex_env;
    bool plain = cap == null || cap == fd.var_env || !cap.flags.is_declarative;
    EnvRecord* lex = plain && !target.is_namebinding() ? own : resolve_call_lex_env(ds.vm, function, target, own);
    la.var_env = own;
    la.lex_env = lex;
    h.shade_root_env(own);
    h.shade_root_env(lex);
    return 1;
}

// Forget where generated code waits for each live frame (Activation.native_ret), before code a
// frame could return into is freed: each such frame returns through jit_ret's general path.
fn void jit_forget_returns(Vm* vm) {
    for (uint i = 0; i < vm.activation_count; i++) vm.activations[i].forget_return();
    for (ShadowActFrame* s = (ShadowActFrame*)vm.shadow_act_list; s != null; s = (ShadowActFrame*)s.prev) {
        for (uint i = 0; i < s.count; i++) s.acts[i].forget_return();
    }
}

// The frame returns through jit_ret's general path: nothing in generated code waits for it.
fn void Activation.forget_return(&self) @inline {
    self.native_ret = null;
    self.flags &= ~ACT_FLAG_JIT_CALLED;
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
    LeanCall r;
    uint nargs = pc.op == Opcode.CALL || pc.op == Opcode.CALL_UNDEF_THIS || pc.op == Opcode.NEW_OBJ ? pc.c : pc.b;
    switch (pc.op) {
        case NEW_OBJ: r = jit_new_lean(pc, regs, ds, cold, vm);
        case APPLY_ARGS: r = jit_apply_lean(pc, regs, cold, vm, &nargs);
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
    return jit_enter_published(ds, nargs, r == ENTERED_ARGS);
}

// The callee frame a lean publish just made current becomes the native frame: bind its register
// arguments, load its code view and record the caller's depth as the floor. Returns its entry.
fn void* jit_enter_published(Dispatch* ds, uint nargs, bool needs_arguments) @private @inline {
    Vm* vm = ds.vm;
    Activation* la = ds.act;
    CompiledFunction* target = (CompiledFunction*)la.func;
    if (needs_arguments) {
        bind_register_arguments(vm, la, target, (HObject*)la.tv_func.get_heapptr(), la.bottom, nargs);
    }
    // The publish made the callee's activation and registers current and
    // checked its realm; its code view is all that is left to load.
    jit_view(ds, target);
    ds.curr_pc = target.code;
    ds.jit_floor = vm.activation_count - 1;
    ds.jit_depth++;
    ds.heap.jit_stats.calls_native++;
    if (@unlikely(ds.heap.opt.enabled)) jit::opt_note_entry(ds.heap, target, la);
    return jit::baseline_entry(target);
}

// The registers of the frames inside the outermost one an inline exit publishes, at most.
const uint INLINE_SAVE_MAX = 3 * 32;

// The frames of the calls that optimized code inlined, published when an inlined body leaves for
// the innermost callee's baseline code at `site.pc`. Outermost first, each call at `resume - 1` of
// its caller (its function checked by the optimized code, which also stored the live registers of
// every window) enters its callee as th_publish_lean does, which leaves the caller's frame at the
// resume word: when the callee returns, the interpreter continues the caller there with the result
// in the register the call names. Callee registers outside the frame's `keep` mask start undefined,
// as an entry's would; the slots from the next frame's window up are that frame's. Returns the
// baseline code to continue in. No frame is one a native call site waits for (jit_floor and
// jit_depth stay), so the innermost's return unwinds to the interpreter, as after a thunk call.
fn void* jit_inline_materialize(Dispatch* ds, jit::OptInlineExit* site) {
    ds.curr_pc = site.frames[0].resume;
    ColdCtx* cold = &ds.cold;
    th_bind_ic_bias(cold, ds.code_base, ds.ic_base, ds.var_ic_base);
    TVal* frame0 = ds.regs_base;
    uint prev_base = 0;
    // A publish clears the scratch slots above its frame, which hold the windows of the frames
    // inside it: they are put back from a copy after each publish.
    jit::OptInlineFrame* last = &site.frames[site.depth - 1];
    uint inner = site.frames[site.depth > 1 ? 1 : 0].base;
    uint inner_end = last.base + last.callee.num_regs;
    TVal[INLINE_SAVE_MAX] saved @noinit;
    if (site.depth > 1) mem::copy(&saved, frame0 + inner, (usz)(inner_end - inner) * TVal::size);
    CompiledFunction* callee = null;
    for (uint level = 0; level < site.depth; level++) {
        jit::OptInlineFrame* fr = &site.frames[level];
        callee = fr.callee;
        Instruction* pc = fr.resume - 1;
        TVal* regs = frame0 + prev_base;
        uint callee_reg = fr.base - 2 - prev_base;
        TVal this_value = th_undefined();
        bool this_valid = false;
        // A NEW_OBJ's frame constructs the object the optimized code built, which it stored in the
        // receiver slot, as jit_new_lean's frame would.
        bool construct = pc.op == Opcode.NEW_OBJ;
        // A forwarding call (CALL_S after APPLY_ARGS) has the receiver a method call has.
        bool method = pc.op == Opcode.CALL || pc.op == Opcode.CALL_S;
        HObject* new_target = construct ? (HObject*)regs[callee_reg].get_heapptr() : null;
        if ((construct || (method && !callee.call_flags.ignores_this)) && regs[callee_reg + 1].is_object()) {
            this_value = regs[callee_reg + 1];
            this_valid = true;
        }
        // The publish's own fill would overwrite the registers the optimized code stored.
        bool needs_arguments = th_publish_lean(pc, regs, cold, callee, callee_reg, pc.a, callee.num_regs, false, !method && !construct,
                                               this_value, this_valid, new_target);
        Activation* la = ds.act;
        TVal* bottom = la.bottom;
        if (level + 1 < site.depth) {
            uint from = site.frames[level + 1].base;
            mem::copy(frame0 + from, &saved[from - inner], (usz)(inner_end - from) * TVal::size);
        }
        uint own = level + 1 < site.depth ? site.frames[level + 1].base - fr.base : callee.num_regs;
        if (own > callee.num_regs) own = callee.num_regs;
        // An argument no longer live is not stored either.
        for (uint r = 0; r < own; r++) {
            if ((fr.keep & (1u << r)) == 0) bottom[r].set_undefined();
        }
        // A forwarding callee's `arguments` is the count of the arguments it keeps in its first
        // registers (CallFlags.forward_args), which the optimizer checked fits.
        if (needs_arguments) bind_register_arguments(ds.vm, la, callee, (HObject*)la.tv_func.get_heapptr(), bottom, fr.argc);
        // Every slot of the frame holds a valid value now, and the optimized code stored heap values
        // into some without raising a count the new frame owns.
        la.heap_reg_count = callee.num_regs;
        prev_base = fr.base;
    }
    jit_view(ds, callee);
    ds.curr_pc = callee.code + site.pc;
    ds.act.curr_pc = ds.curr_pc;
    return jit::baseline_jump_entry(callee);
}

// The compiled function a callee register holds, or null.
fn CompiledFunction* jit_compiled_callee(TVal callee) @inline {
    if (!callee.is_object()) return null;
    HObject* fn_obj = (HObject*)callee.get_heapptr();
    if (fn_obj == null || !fn_obj.is_callable() || fn_obj.callable_kind() != hobject::CallableKind.COMPILED_FN) return null;
    return (*fn_obj.extra_ptr()).func.comp_func;
}

// The notes @apply_args makes for a forwarding call that baseline code makes itself
// (Asm.emit_forward_call): its callee, on the APPLY_ARGS two instructions before `next`, and on the
// call that entered the frame `la`. Needs no synced state: it only fills `la` should it be lazy.
fn void jit_note_forward(Vm* vm, Activation* la, Instruction* next) {
    if (la.flags & ACT_FLAG_LAZY) jit_fill(vm, la);
    CompiledFunction* f = (CompiledFunction*)la.func;
    Instruction* pc = next - 2;
    CompiledFunction* target = jit_compiled_callee(la.bottom[pc.a + 1]);
    if (target == null) return;
    hobject::ic_note_callee(&((hobject::ICEntry*)f.ic_entries)[pc - f.code], target.func_index);
    @note_forward(la, target);
}

// APPLY_ARGS (with the CALL_S it is fused with) as th_apply_args runs it: the
// register `arguments` of the running function spread into the callee's
// window, whose frame is published for the CALL_S. `nargs` receives the count.
fn LeanCall jit_apply_lean(Instruction* pc, TVal* regs, ColdCtx* cold, Vm* vm, uint* nargs_out) @private @inline {
    Instruction insn = *pc;
    Instruction call = pc[1];
    uint callee = insn.a;
    Activation* act = cold.act;
    TVal args_slot = regs[((CompiledFunction*)act.func).arguments_reg];
    if (call.op != Opcode.CALL_S || call.b != callee || !args_slot.is_fastint()
        || !builtins::is_intrinsic_apply(regs[callee])) return DECLINE;
    CompiledFunction* target = jit_compiled_callee(regs[callee + 1]);
    if (target == null) return NATIVE;
    if (target.jit_code == null) return NO_CODE;
    target = th_lean_target(vm, regs[callee + 1], regs + callee + 2, false);
    uint nargs = (uint)args_slot.get_fastint();
    if (target == null || nargs > target.num_regs) return DECLINE;
    @note_callee(pc, cold, target);
    @note_forward(act, target);
    TVal this_arg = regs[callee + 2];
    bool this_valid = false;
    if (this_arg.is_heap_allocated()) {
        if (!this_arg.is_object() || this_arg.get_heapptr() == null) return DECLINE;
        this_valid = !target.call_flags.ignores_this;
    } else if (!target.call_flags.ignores_this) {
        return DECLINE;
    }
    TVal* window = regs + callee + 2;
    if (!th_can_publish(cold.heap, regs[callee + 1]) || !th_can_publish(cold.heap, this_arg)) return DECLINE;
    for (uint i = 0; i < nargs; i++) {
        if (!th_can_publish(cold.heap, regs[i])) return DECLINE;
    }
    if (@lean_gate(cold, true)) return DECLINE;

    regs[callee] = regs[callee + 1];
    regs[callee + 1] = this_arg;
    track_heap_store(act, regs + callee, callee);
    track_heap_store(act, regs + callee + 1, callee + 1);
    if (nargs == 0) window[0].set_undefined();
    for (uint i = 0; i < nargs; i++) {
        TVal value = regs[i];
        window[i] = value;
        track_heap_store(act, &window[i], callee + 2 + i);
    }
    regs[insn.c].set_fastint((long)nargs);
    *nargs_out = nargs;
    return th_publish_lean(pc + 1, regs, cold, target, callee, call.a, nargs, false, !this_valid,
                           this_valid ? this_arg : th_undefined(), this_valid, null) ? ENTERED_ARGS : ENTERED;
}

// Mark `value`, which the optimized code stores to the window from a machine register while the
// collector is marking (Trampoline.shade). Allocates nothing for the collector and runs no code.
// Returns `value`.
fn ulong jit_opt_shade(Heap* h, ulong value) {
$if types::USE_NANBOX:
    h.shade_root_tval({ .bits = value });
$endif
    return value;
}

// jit_store_slot of `value`, which the optimized code holds in a machine register.
fn void jit_opt_store_slot(Heap* h, HObject* hobj, hobject::PropValue* slot, ulong value) {
$if types::USE_NANBOX:
    TVal v = { .bits = value };
    h.store_slot_ref(hobj, slot, &v);
$endif
}

// NEW_OBJ of a lean constructor jit_new_simple left: its object and its
// frame are published as th_new_obj does. DECLINE leaves the instruction to its thunk before
// anything is written.
fn LeanCall jit_new_lean(Instruction* pc, TVal* regs, Dispatch* ds, ColdCtx* cold, Vm* vm) @private @inline {
    Instruction insn = *pc;
    TVal callee = regs[insn.b];
    if (!callee.is_object()) return NATIVE;
    HObject* ctor = (HObject*)callee.get_heapptr();
    if (!ctor.is_callable() || !ctor.is_constructable()
        || ctor.callable_kind() != hobject::CallableKind.COMPILED_FN) return NATIVE;
    CompiledFunction* target = (*ctor.extra_ptr()).func.comp_func;
    if (target == null) return NATIVE;
    // jit_new_simple completed a simple constructor or declined it.
    if (target.call_flags.simple_constructor) return DECLINE;
    if (!target.plain_constructor()) return DECLINE;
    if (target.jit_code == null) return NO_CODE;
    if (th_lean_target(vm, callee, regs + insn.b + 2, false) == null) return DECLINE;
    hobject::ICEntry* ic = ds.ic_base + (uint)(pc - ds.code_base);
    hobject::ic_note_constructor(ic, target.func_index);
    if (@lean_gate(cold, true)) return DECLINE;
    HObject* obj = jit_construct_object(vm, ctor, ic, target.call_flags.constructor_capacity);
    if (obj == null) return DECLINE;
    // The frame holds the new object as its `this`, and its return answers it
    // unless the body returns an object.
    TVal this_value;
    this_value.set_object(obj);
    return th_publish_lean(pc, regs, cold, target, insn.b, insn.a, insn.c, false, false,
                           this_value, true, ctor) ? ENTERED_ARGS : ENTERED;
}

// The object of a NEW_OBJ whose constructor optimized code inlines (jit::OptCg.emit_new_object): a
// plain object with the prototype the site's cache `ic` reads from `ctor`, with room for `want`
// properties, as th_new_obj builds it; returned boxed. 0, having allocated nothing, for a constructor
// that is not constructable, a cache that does not hold or a failed allocation. The allocation does
// not collect (Heap.request_gc), so the optimized code's values stay where they are.
fn ulong jit_opt_new_object(Dispatch* ds, HObject* ctor, hobject::ICEntry* ic, ulong want) {
    HObject* obj = jit_construct_object(ds.vm, ctor, ic, (uint)want);
    if (obj == null) return 0;
    TVal value;
    value.set_object(obj);
$if types::USE_NANBOX:
    return value.bits;
$else
    return 0;
$endif
}

// A plain object for `new ctor`, with the prototype the NEW_OBJ's cache `ic` reads from `ctor`
// and room for `want` properties, as th_new_obj builds it. Null, having allocated nothing, for a
// constructor that is not constructable, a cache that does not hold or a failed allocation. The
// allocation does not collect (Heap.request_gc).
fn HObject* jit_construct_object(Vm* vm, HObject* ctor, hobject::ICEntry* ic, uint want) @private {
    if (!ctor.is_constructable()) return null;
    if (ic.key.borrow() != (void*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE] || ic.has_proto
        || ic.shape_id != ctor.shape_id || ic.shape_gen != ctor.shape_generation(vm.heap)
        || ic.prop_flags.is_accessor || ic.prop_idx >= ctor.prop_count) return null;
    TVal proto = ctor.prop_values()[ic.prop_idx].get();
    if (!proto.is_object()) return null;
    HObject* obj = alloc_constructor_receiver(vm.heap, want) ?? null;
    if (obj == null) return null;
    vm.heap.set_prototype(obj, (HObject*)proto.get_heapptr());
    return obj;
}

// The object of an inlined NEW_OBJ whose site (jit::OptSinkSite) the optimized code has validated:
// empty, with room for site.want properties and the prototype the site recorded, returned boxed;
// 0 for a failed allocation. The allocation does not collect (Heap.request_gc).
fn ulong jit_opt_site_object(Dispatch* ds, jit::OptSinkSite* site) {
    HObject* obj = alloc_constructor_receiver(ds.vm.heap, site.want) ?? null;
    if (obj == null) return 0;
    ds.vm.heap.set_prototype(obj, (HObject*)site.proto);
    TVal value;
    value.set_object(obj);
$if types::USE_NANBOX:
    return value.bits;
$else
    return 0;
$endif
}

// Validate the site of a sunk allocation (jit::OptSinkSite) for `ctor`, whose NEW_OBJ optimized
// code does not allocate: what jit_opt_new_object would allocate with, every key the constructor
// adds absent from the prototype chain or a writable data property there (so each add makes a plain
// own data property), and every key
// read from the chain a data property. The chain's objects are marked observed, so the prototype
// epoch recorded with the rest moves when any of that changes. False, having recorded nothing,
// leaves for the baseline code. Allocates nothing and runs no code.
fn bool jit_opt_sink_check(Dispatch* ds, HObject* ctor, jit::OptSinkSite* site) {
    Heap* h = ds.vm.heap;
    h.opt.sink_checks++;
    hobject::ICEntry* ic = site.new_ic;
    if (!ctor.is_constructable()) return false;
    if (ic.key.borrow() != (void*)h.strs[heap::BuiltinStr.PROTOTYPE] || ic.has_proto
        || ic.shape_id != ctor.shape_id || ic.shape_gen != ctor.shape_generation(h)
        || ic.prop_flags.is_accessor || ic.prop_idx >= ctor.prop_count) return false;
    TVal proto = ctor.prop_values()[ic.prop_idx].get();
    if (!proto.is_object()) return false;
    HObject* first = (HObject*)proto.get_heapptr();
    for (HObject* cur = first; cur != null; cur = cur.prototype) {
        if (!hobject::plain_property_object(cur)) return false;
        // A writable data property of the chain is shadowed by the add; any other kind changes it.
        for (uint k = 0; k < site.add_count; k++) {
            int idx = cur.find_prop_idx(site.keys[k], h);
            if (idx < 0) continue;
            hobject::PropFlags pf = cur.get_prop_flags((uint)idx, h);
            if (pf.is_accessor || !pf.writable) return false;
        }
    }
    void*[jit::OPT_SINK_READS] owner;
    ulong[jit::OPT_SINK_READS] off;
    for (uint k = 0; k < site.read_count; k++) {
        owner[k] = null;
        for (HObject* cur = first; cur != null; cur = cur.prototype) {
            int idx = cur.find_prop_idx(site.read_keys[k], h);
            if (idx < 0) continue;
            if (cur.get_prop_flags((uint)idx, h).is_accessor) return false;
            owner[k] = cur;
            off[k] = (ulong)idx * hobject::PropValue::size;
            break;
        }
        if (owner[k] == null) return false;
    }
    for (HObject* cur = first; cur != null; cur = cur.prototype) cur.gc.prototype_observed = true;
    for (uint k = 0; k < site.read_count; k++) {
        site.read_owner[k] = owner[k];
        site.read_off[k] = off[k];
    }
    site.ctor = ctor;
    site.ctor_shape = ctor.shape_id;
    site.proto_off = (ulong)ic.prop_idx * hobject::PropValue::size;
    site.proto = first;
$if types::USE_NANBOX:
    site.proto_bits = proto.bits;
$endif
    site.recycle = h.shape_recycle_epoch;
    site.epoch = h.prototype_epoch;
    return true;
}

// The object of a sunk allocation that an exit sees, with its first `count` fields from
// site.values, as the constructor's adds would have left it; returned boxed. The site was
// validated by the code before the exit and nothing ran since. The allocation does not collect.
fn ulong jit_opt_sink_materialize(Dispatch* ds, jit::OptSinkSite* site, ulong count) {
    Heap* h = ds.vm.heap;
    h.opt.sink_materialized++;
    HObject* obj = h.alloc_plain_object() ?? null;
    if (obj == null) unreachable("out of memory allocating a sunk object at an exit");
    h.set_prototype(obj, (HObject*)site.proto);
    if (site.want > hobject::INLINE_PROPS) obj.reserve_props(h, constructor_reserve_capacity(site.want));
    for (uint k = 0; k < (uint)count; k++) {
        TVal value;
$if types::USE_NANBOX:
        value = { .bits = site.values[k] };
$endif
        obj.put_prop_new(site.keys[k], value, hobject::PROP_FLAGS_WEC, h);
    }
    TVal boxed;
    boxed.set_object(obj);
$if types::USE_NANBOX:
    return boxed.bits;
$else
    return 0;
$endif
}

// Arm the site of an inlined NEW_OBJ (jit::NewSite) for `ctor`, whose `prototype` the entry `ic`
// reads as `proto`: what the emitted code allocates stays valid while the state recorded here is
// the state it compares. Every object of the prototype chain is marked observed first, so that a
// change to any of them moves the prototype epoch the site records. `count` and `final_shape`
// are what the site's stores leave (none for jit::NEW_SITE_CALLS, which runs the body); the
// caller fills the store arguments. False, with the site as it was, for a state that is not
// covered (another realm, a chain that is not plain or has a dictionary).
fn bool jit_new_arm(Heap* h, HObject* ctor, CompiledFunction* target, hobject::ICEntry* ic, HObject* proto,
                    uint count, uint final_shape, uint capacity, jit::NewSite* site) @private {
$if types::USE_NANBOX:
    if (h.realms != null) return false;
    for (HObject* cur = proto; cur != null; cur = cur.prototype) {
        if (!hobject::plain_property_object(cur) || cur.in_dict_mode(h)) return false;
    }
    for (HObject* cur = proto; cur != null; cur = cur.prototype) cur.gc.prototype_observed = true;
    TVal value;
    value.set_object(proto);
    site.proto_bits = value.bits;
    site.proto_off = (ulong)ic.prop_idx * hobject::PropValue::size;
    uint shaped = capacity > hobject::INLINE_PROPS ? capacity - hobject::INLINE_PROPS : 0;
    site.pool = (ulong)((char*)hobject::plain_object_pool(h, false, shaped) - (char*)h);
    site.gc = (uint)hobject::plain_object_gc(false, shaped);
    site.capacity = capacity;
    site.ctor_shape = ctor.shape_id;
    site.recycle = h.shape_recycle_epoch;
    site.proto_shape = proto.shape_id;
    site.final_shape = final_shape;
    site.count = count;
    foreach (&arg : site.arg) *arg = jit::NEW_ARG_NONE;
    site.cf = target;
    site.epoch = h.prototype_epoch;
    return true;
$else
    return false;
$endif
}

// NEW_OBJ of a simple constructor, completed in place as th_new_obj does:
// 0 when the object is built and stored, JIT_CALL_SLOW to leave the
// instruction to jit_call. `site`, when the emitted code has an inline path for this
// instruction, is armed once the object is built; for another plain constructor the site can
// enter through its call entry, it is armed to allocate and call from the next construction on.
fn long jit_new_simple(Dispatch* ds, Instruction* next, jit::NewSite* site) {
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
    // simple_constructor is only set for a constructable, non-derived function without a brand
    // or field initializers. Any other is left to jit_call, once the site is armed for the
    // constructions after this one when the body can run on an object the site allocates.
    bool simple = target.call_flags.simple_constructor;
    if (!simple && (site == null || !jit::entry_constructs(target) || target.jit_code == null
                    || ((jit::BaselineCode*)target.jit_code).call_entry == null
                    || target.call_flags.constructor_capacity > hobject::SHAPED_INLINE_MAX_PROPS)) return JIT_CALL_SLOW;
    Vm* vm = ds.vm;
    hobject::ICEntry* ic = ds.ic_base + (uint)(pc - ds.code_base);
    hobject::ic_note_constructor(ic, target.func_index);
    if (ic.key.borrow() != (void*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE] || ic.has_proto
        || ic.shape_id != ctor.shape_id || ic.shape_gen != ctor.shape_generation(vm.heap)
        || ic.prop_flags.is_accessor || ic.prop_idx >= ctor.prop_count) return JIT_CALL_SLOW;
    TVal proto = ctor.prop_values()[ic.prop_idx].get();
    if (!proto.is_object()) return JIT_CALL_SLOW;
    if (!simple) {
        jit_new_arm(vm.heap, ctor, target, ic, (HObject*)proto.get_heapptr(), jit::NEW_SITE_CALLS, 0,
                    constructor_inline_capacity(target.call_flags.constructor_capacity), site);
        return JIT_CALL_SLOW;
    }
    ds.curr_pc = next;
    HObject* obj = vm.heap.alloc_plain_object() ?? null;
    if (obj == null) return JIT_CALL_SLOW;
    vm.heap.set_prototype(obj, (HObject*)proto.get_heapptr());
    if (!init_simple_constructor(vm, target, obj, regs + insn.b + 2, insn.c)) return JIT_CALL_SLOW;
    if (site != null && obj.prop_count <= hobject::INLINE_PROPS && !obj.has_prop_block() && obj.prop_hash == null
        && jit_new_arm(vm.heap, ctor, target, ic, obj.prototype, obj.prop_count, obj.shape_id, hobject::INLINE_PROPS, site)) {
        for (uint j = 0; j < obj.prop_count; j++) {
            site.arg[j] = target.code[j].a < insn.c ? target.code[j].a : jit::NEW_ARG_UNDEF;
        }
    }
    TVal* ra = regs + insn.a;
    ra.set_object(obj);
    track_heap_store(ds.act, ra, (uint)insn.a);
    ds.heap.jit_stats.calls_trivial++;
    return 0;
}

// RET and RETUNDEF as the threaded returns (th_leaf_return and
// th_pop_frame, else th_return_general). For a frame generated code waits for
// (Activation.native_ret), returns BASELINE_RETURNED with the caller current,
// ds.curr_pc at its resume point and the waiter in ds.jit_waiter; a caller in
// another realm takes the thunk. For a frame Vm.run entered, returns RESTART
// with the caller's frame to be loaded, as op_ret's frame switch does. 0
// takes the thunk.
fn long jit_ret(Dispatch* ds, ulong next_arg) {
    Vm* vm = ds.vm;
    Activation* fa = ds.act;
    void* waiter = fa.native_ret;
    bool waiting = waiter != null;
    if (!waiting && (ds.jit_floor != 0 || ds.jit_depth != 0 || vm.activation_count < 2)) return 0;
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
    // Registers hold no counts, so tracked strings clear like objects; only the threaded
    // handler keeps them off its leaf path, to stay free of the clearing loop's libc call.
    if (th_leaf_return(vm, fa, value, is_undefined, &caller, &cross_function, true)) {
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
    // Generated code continues in the caller with the frame state whole.
    jit_load(ds, caller);
    ds.jit_waiter = waiter;
    return jit::BASELINE_RETURNED;
}

// The native entry of the frame a RESTART leaves current, loaded into ds as
// Vm.run would load it before entering that entry, or null when the restart
// goes to Vm.run: a native caller waits on the C stack, an interrupt hook
// wants the restart poll, a handoff is pending, the frame has no code yet
// (Vm.run counts the entry and compiles), or it lies below the frame the
// innermost entry from C ran.
fn void* jit_switch(Dispatch* ds) {
    Vm* vm = ds.vm;
    if (ds.jit_depth != 0 || ds.jit_floor != 0 || !ds.needs_restart || vm.activation_count == 0) return null;
    if (vm.threaded_handoff != ThreadedHandoff.NONE) return null;
    if (vm.heap.capi_interrupt_fn != null || vm.heap.capi_runtime != null) return null;
    // A frame below the one this entry from C ran runs on an outer entry's native frames.
    Activation* top = &vm.activations[vm.activation_count - 1];
    if (top < ds.enter_act) return null;
    CompiledFunction* f = (CompiledFunction*)top.func;
    if (f == null || f.jit_code == null) return null;
    ds.needs_restart = false;
    ds.load_frame();
    ds.heap.jit_stats.switches++;
    return jit::baseline_jump_entry(f);
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
fn hobject::PropValue* jit_get_missed(Heap* h, HObject* hobj, void* key, hobject::ICEntry* ic) {
    hstring::HString* name = (hstring::HString*)key;
    if (name == null || !name.is_interned() || name.is_arridx() || name.is_hidden()) return null;
    HObject* cur = hobj;
    for (uint depth = 0; cur != null && depth <= JIT_WALK_DEPTH; depth++) {
        if (!hobject::plain_property_object(cur)) return null;
        int idx = cur.find_prop_idx(key, h);
        if (idx >= 0) {
            if (cur.get_prop_flags((uint)idx, h).is_accessor) return null;
            // The entry follows the receiver as the switch's lookup refills it, except that a
            // polymorphic set keeps its shapes.
            if (ic != null && ic.key.borrow() == key && depth == 0 && jit_poly_read(h, ic, hobj, (uint)idx)) {
                // The receiver joined the entry's polymorphic set.
            } else if (ic != null && (ic.key.borrow() == null || (ic.key.borrow() == key && ic.chain_len != hobject::IC_CHAIN_POLY))) {
                ic_fill_read_heap(h, ic, hobj, key, cur);
            }
            if (depth <= 1) hobject::mega_cache_store(h, hobj, key, cur, idx, false);
            return &cur.prop_values()[idx];
        }
        cur = cur.prototype;
    }
    if (cur != null) return null;
    jit_undefined.set_undefined();
    return (hobject::PropValue*)&jit_undefined;
}

// An own data read of `hobj` at `idx` through the entry `ic` caching the same key for another shape
// joins the entry's polymorphic set, as th_get_shared does, so the optimizing tier sees every shape
// of the site. With the set full, an entry that is already polymorphic moves to the receiver's shape.
// False leaves the entry to the caller.
fn bool jit_poly_read(Heap* h, hobject::ICEntry* ic, HObject* hobj, uint idx) {
    if (ic.shape_id == hobj.shape_id || ic.has_proto) return false;
    if (hobject::ic_poly_add(ic, hobj.shape_id, idx, h)) return true;
    if (ic.chain_len != hobject::IC_CHAIN_POLY) return false;
    ic.shape_id = hobj.shape_id;
    ic.prop_idx = idx;
    ic.prop_flags = hobj.get_prop_flags(idx, h);
    return true;
}

// A read the megamorphic cache answered, `value` its result: when the property is an own data
// property of the plain receiver, the site's entry takes the receiver's shape into its polymorphic
// set (th_get_shared does the same), so the optimizing tier sees every shape the site meets. A set
// that is full is left alone. Returns `value`.
fn ulong jit_poly_note(Heap* h, HObject* hobj, hobject::ICEntry* ic, ulong value) {
    if (ic.chain_len == hobject::IC_CHAIN_POLY && ic.chain.poly.count == hobject::IC_POLY_MAX) return value;
    void* key = (void*)ic.key.borrow();
    if (key == null) return value;
    int idx = hobj.find_prop_idx(key, h);
    if (idx < 0 || hobj.get_prop_flags((uint)idx, h).is_accessor) return value;
    jit_poly_read(h, ic, hobj, (uint)idx);
    return value;
}

const uint JIT_WALK_DEPTH = 6;
TVal jit_undefined @private;

// An absent-property add through the site entry `ic`, whose key matched, to
// the plain object `hobj`, as th_put_cached's absent case and th_put_absent:
// a value that needs no count or barrier work, appended into spare property
// capacity. Anything else is jit_put_missed's.
fn bool jit_put_absent(Heap* h, HObject* hobj, hobject::ICEntry* ic, TVal* value) {
    if (hobject::ic_matches_absent_put(ic, hobj, ic.key.borrow(), h)) {
        if (hobj.prop_count >= hobj.prop_capacity && hobj.prop_hash == null) hobj.grow_props(h);
        if (value.is_heap_allocated()) {
            if (hobj.append_cached_prop(ic, *value, h)) return true;
        } else if (hobj.prop_count < hobj.prop_capacity && hobj.prop_hash == null) {
            if (hobj.gc.prototype_observed) h.bump_prototype_epoch(hobj);
            hobject::PropValue* slot = &hobj.prop_values()[hobj.prop_count];
            *slot = (hobject::PropValue)*value;
            hobj.prop_count++;
            hobj.shape_id = ic.absent_next_shape;
            return true;
        }
    }
    return jit_put_missed(h, hobj, ic, value);
}

// A store of the site's constant key, which matched the entry `ic`, to the
// plain object `hobj` when the entry's cached state does not fit it, as
// th_put_lookup runs it. The entry is left as it is, so a site that sees
// several shapes keeps the one it has. False leaves the store to the thunk.
fn bool jit_put_missed(Heap* h, HObject* hobj, hobject::ICEntry* ic, TVal* value) {
    HString* key = (HString*)ic.key.borrow();
    return key != null && put_by_lookup(h, hobj, key, value, ic, false);
}

// jit_put_missed for a site whose entry does not hold the site's constant key,
// which the emitted code left in h.jit_site_key: an entry that never filled
// stays empty for a receiver the cache cannot describe, and every store of the
// site would otherwise take its thunk.
fn bool jit_put_site(Heap* h, HObject* hobj, hobject::ICEntry* ic, TVal* value) {
    HString* key = (HString*)h.jit_site_key;
    return key != null && put_by_lookup(h, hobj, key, value, ic, false);
}

// NEWARR, NEWARR_CONST, NEWARR_FILL, NEWOBJ and NEWOBJ_SHAPE as their threaded handlers
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
        case NEWARR_FILL: return alloc_newarr_fill(vm, ds.act, ds.regs_base, *pc);
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

fn Instruction* jit_stop(Instruction* pc, HandlerTable* handlers, TVal* regs, ColdCtx* cold) @private {
    // th_next charged the instruction after the one the handler ran; no
    // instruction is dispatched here.
    $if $feat(OP_PROFILE): opprof_pending_valid = false; $endif
    return pc;
}

fn void jit_relay_init() @private @noinline {
    init_threaded_handlers();
    for (usz i = 0; i < TH_TABLE_SIZE; i++) jit_stop_table.fns[i] = &jit_stop;
    foreach (i, &kind : jit_leaf_kinds) *kind = leaf_kind((uint)i);
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

// The call a builtin re-dispatched (Function.prototype.call and apply rewrite their window and
// ask for a plain CALL over it), run as a native call when its callee is a lean compiled function
// with native code, as th_call_redispatched enters it for the threaded handlers. op_calls would
// push the frame and restart, which leaves every native frame above it. Returns what jit_call
// returns, or JIT_CALL_SLOW with nothing written for the caller to run op_calls.
fn long jit_enter_redispatched(Dispatch* ds, Instruction* next, DecodedInsn call) @private {
    Vm* vm = ds.vm;
    if (ds.jit_depth >= JIT_NATIVE_DEPTH_CAP) return JIT_CALL_SLOW;
    TVal* regs = ds.regs_base;
    uint callee_reg = call.b;
    uint nargs = call.c;
    uint window_end = callee_reg + 2 + nargs;
    if (window_end > vm.current_func.num_regs || vm.heap.gc_safepoint_due(true)) return JIT_CALL_SLOW;
    TVal callee = regs[callee_reg];
    if (!callee.is_object()) return JIT_CALL_SLOW;
    HObject* callee_obj = (HObject*)callee.get_heapptr();
    if (callee_obj == null || !callee_obj.is_callable()
        || callee_obj.callable_kind() != hobject::CallableKind.COMPILED_FN) return JIT_CALL_SLOW;
    CompiledFunction* classified = (*callee_obj.extra_ptr()).func.comp_func;
    if (classified == null) return JIT_CALL_SLOW;
    classified.classify_lean_call();
    CompiledFunction* target = th_lean_target(vm, callee, regs + callee_reg + 2, false);
    if (target == null || target.jit_code == null) return JIT_CALL_SLOW;
    TVal receiver = regs[callee_reg + 1];
    TVal this_value = th_undefined();
    bool this_valid = false;
    if (receiver.is_heap_allocated()) {
        if (!receiver.is_object() || receiver.get_heapptr() == null) return JIT_CALL_SLOW;
        if (!target.call_flags.ignores_this) {
            this_value = receiver;
            this_valid = true;
        }
    } else if (!target.call_flags.ignores_this) {
        return JIT_CALL_SLOW;
    }
    for (uint r = callee_reg; r < window_end; r++) track_heap_store(ds.act, regs + r, r);
    uint old_floor = ds.jit_floor;
    ColdCtx* cold = &ds.cold;
    th_bind_ic_bias(cold, ds.code_base, ds.ic_base, ds.var_ic_base);
    bool needs_arguments = th_publish_lean(next - 1, regs, cold, target, callee_reg, call.a, nargs, false, false,
                                           this_value, this_valid, null);
    void* entry = jit_enter_published(ds, nargs, needs_arguments);
    return jit_run_entered(ds, entry, old_floor, next);
}

// A call the operation function entered by pushing the callee's frame and asking for a restart
// (a callee the lean shapes decline: one with a scope object of its own, a class constructor):
// run the callee's native code as a nested native call instead of unwinding every native frame
// above it to Vm.run. `count_before` is the activation count before the operation; the frame
// must be the one new, fresh frame. Returns what jit_call returns, or JIT_NO_RAW when the frame
// is left to the restart.
fn long jit_enter_pushed(Dispatch* ds, Instruction* next, uint count_before) {
    long entered = jit_try_enter_pushed(ds, next, count_before);
    if (entered == JIT_NO_RAW) ds.heap.jit_stats.calls_restarted++;
    return entered;
}

fn long jit_try_enter_pushed(Dispatch* ds, Instruction* next, uint count_before) @private @inline {
    Vm* vm = ds.vm;
    if (vm.activation_count != count_before + 1 || ds.jit_depth >= JIT_NATIVE_DEPTH_CAP
        || vm.threaded_handoff != ThreadedHandoff.NONE
        || vm.heap.capi_interrupt_fn != null || vm.heap.capi_runtime != null) return JIT_NO_RAW;
    Activation* act = &vm.activations[vm.activation_count - 1];
    CompiledFunction* f = (CompiledFunction*)act.func;
    if (f == null || act.curr_pc != f.code || f.ic_entries == null || f.var_ic_entries == null) return JIT_NO_RAW;
    void* entry = jit::baseline_code(vm.heap, f, act);
    if (entry == null) return JIT_NO_RAW;
    uint old_floor = ds.jit_floor;
    ds.needs_restart = false;
    ds.load_frame();
    ds.jit_floor = vm.activation_count - 1;
    ds.jit_depth++;
    ds.heap.jit_stats.calls_native++;
    ds.heap.jit_stats.calls_pushed++;
    return jit_run_entered(ds, entry, old_floor, next);
}

// The number of the builtin function `v` is (builtins::Builtin), or -1 for any other value.
fn int jit_builtin_index(TVal v) @inline {
$if types::USE_NANBOX:
    if (v.bits >> 48 == types::TAG_LIGHTFUNC) {
        ulong index = v.bits & 0xFFFFFFFFFFFF;
        return index < 0x10000 ? (int)index : -1;
    }
$endif
    if (!v.is_object()) return -1;
    HObject* fo = (HObject*)v.get_heapptr();
    if (fo == null || !fo.is_callable() || fo.callable_kind() != hobject::CallableKind.BUILTIN_FN) return -1;
    return (*fo.extra_ptr()).func.builtin_fn_index;
}

alias MathFn1 @local = fn double(double);
alias MathFn2 @local = fn double(double, double);

macro bool leaf_number(TVal v, double* out) @local {
    if (v.is_fastint()) {
        *out = (double)v.get_fastint();
        return true;
    }
    if (!v.is_number()) return false;
    *out = v.get_number();
    return true;
}

// The cached string of one Latin-1 unit, as a register's value.
macro bool leaf_unit_string(Heap* h, uint unit, TVal* dest) @local {
    if (unit >= heap::UNIT_STR_CACHE_SIZE || h.unit_strs[unit] == null) return false;
    h.set_reg_string(dest, h.unit_strs[unit]);
    return true;
}

// The builtins jit_builtin_leaf answers, by builtin number, so a call of any
// other skips it with one load.
enum LeafKind : char @local { NONE, CHAR_AT, FROM_CHAR_CODE, PUSH, PARSE_INT, MATH }
LeafKind[builtins::Builtin::values.len] jit_leaf_kinds @private;

fn LeafKind leaf_kind(uint builtin) @local {
    switch ((builtins::Builtin)builtin) {
        case STRING_PROTO_CHARAT: return CHAR_AT;
        case STRING_FROMCHARCODE: return FROM_CHAR_CODE;
        case ARRAY_PROTO_PUSH: return PUSH;
        case PARSE_INT: return PARSE_INT;
        default:
            jit::OptMath m;
            return jit::opt_math_of(builtin, &m) ? LeafKind.MATH : LeafKind.NONE;
    }
}

// A builtin call that needs no frame: the case the builtin itself answers
// without coercing, throwing, collecting or entering JavaScript, computed
// from the receiver and arguments into `dest`. False with nothing done
// leaves the call to the builtin.
fn bool jit_builtin_leaf(Dispatch* ds, LeafKind kind, uint builtin, TVal this_val, TVal* args, uint nargs, TVal* dest) {
    if (nargs == 0) return false;
    TVal x = args[0];
    switch (kind) {
        case NONE:
            return false;
        case CHAR_AT:
            HString* text = plain_string_of(&this_val);
            if (text == null || !text.is_ascii() || !x.is_fastint()) return false;
            long at = x.get_fastint();
            if (at < 0 || at >= (long)text.unit_len()) return false;
            return leaf_unit_string(ds.heap, text.unit_at((uint)at), dest);
        case FROM_CHAR_CODE:
            if (nargs != 1 || !x.is_fastint()) return false;
            return leaf_unit_string(ds.heap, (uint)(x.get_fastint() & 0xFFFF), dest);
        case PUSH:
            $if types::USE_NANBOX:
                if (nargs != 1 || !this_val.is_object()) return false;
                long len = jit::opt_array_push(ds, (HObject*)this_val.get_heapptr(), x.bits);
                if (len < 0) return false;
                dest.set_fastint(len);
                return true;
            $else
                return false;
            $endif
        case PARSE_INT:
            // A number whose decimal string has no exponent and whose integer
            // part is exact parses to that part.
            if (nargs != 1) return false;
            if (x.is_fastint()) {
                *dest = x;
                return true;
            }
            if (!x.is_number()) return false;
            double d = x.get_number();
            double size = math::abs(d);
            if (!(size >= 1e-6 && size < 0x1p53)) return false;
            double whole = math::trunc(d);
            if (whole != 0 && size < 0x1p31) {
                dest.set_fastint((long)whole);
            } else {
                dest.set_number(whole);
            }
            return true;
        case MATH:
            jit::OptMath m;
            double a;
            double b;
            if (!jit::opt_math_of(builtin, &m) || nargs != m.args || !leaf_number(x, &a)) return false;
            if (m.args == 2 && !leaf_number(args[1], &b)) return false;
            switch (m) {
                case MIN:
                case MAX:
                    return false;
                case ABS:
                    dest.set_number(math::abs(a));
                default:
                    void* f = jit::opt_math_fn(m);
                    dest.set_number(m.args == 2 ? ((MathFn2)f)(a, b) : ((MathFn1)f)(a));
            }
            return true;
    }
}

// A method CALL of a builtin function object that is no leaf, run as th_call_native
// runs it without the generic path's classification of every callee and call
// shape: the frame is published, the builtin runs, and its value lands in the
// call's register. A throw or re-dispatch completes through the generic
// handoffs. Returns false, having run nothing, for every other call.
fn bool jit_call_builtin_method(Dispatch* ds, Instruction* next, OpStatus* status, long* raw) @inline {
    Instruction* pc = next - 1;
    if (pc.op != Opcode.CALL || ds.ic_base == null) return false;
    TVal* regs = ds.regs_base;
    uint callee = pc.b;
    TVal cv = regs[callee];
    if (!cv.is_object()) return false;
    HObject* function = (HObject*)cv.get_heapptr();
    if (function == null || !function.is_callable()
        || function.callable_kind() != hobject::CallableKind.BUILTIN_FN) return false;
    int idx = (*function.extra_ptr()).func.builtin_fn_index;
    // Leaves, and charCodeAt, which th_call_native answers inline, keep the generic path.
    if (idx < 0 || (idx < jit_leaf_kinds.len && jit_leaf_kinds[idx] != NONE)
        || idx == (int)builtins::Builtin.STRING_PROTO_CHARCODEAT.ordinal) return false;
    Heap* heap = ds.heap;
    if (heap.gc_safepoint_due(true)) return false;
    if (idx != (int)builtins::Builtin.FUNCTION_PROTO_CALL.ordinal) {
        hobject::ic_note_callee((hobject::ICEntry*)ds.ic_base + (pc - ds.code_base), hobject::IC_BUILTIN_TARGET | (uint)idx);
    }
    Vm* vm = ds.vm;
    Activation* act = ds.act;
    act.curr_pc = next;
    TVal* top = act.bottom + vm.current_func.num_regs + FRAME_SCRATCH_SLOTS;
    if (top > vm.valstack_top) vm.valstack_top = top;
    TVal result;
    result.set_undefined();
    builtins::BuiltinContext ctx = call_context(&ds.cold, callee, pc.c, &result,
                                                this_val: &regs[callee + 1], callee: function);
    builtins::dispatch_builtin((uint)idx, &ctx);
    // The builtin may have moved the value stack.
    regs = act.bottom;
    ds.regs_base = regs;
    heap.jit_stats.calls_builtin++;
    heap.jit_stats.calls_builtin_direct++;
    if (@unlikely(ctx.should_throw)) {
        vm.threaded_throw = ctx.throw_value;
        vm.threaded_handoff = ThreadedHandoff.THROW;
        return jit_builtin_handoff(ds, next, next, status, raw);
    }
    if (@unlikely(ctx.needs_re_dispatch)) {
        th_bind_ic_bias(&ds.cold, ds.code_base, ds.ic_base, ds.var_ic_base);
        Instruction* r = th_call_redispatched(pc, &jit_stop_table, regs, &ds.cold, callee, pc.a, ctx.re_nargs,
                                              idx == (int)builtins::Builtin.FUNCTION_PROTO_CALL.ordinal);
        // A decline leaves the call to the site's slow path, as th_call_native's does.
        if (!jit_builtin_handoff(ds, next, r, status, raw)) *raw = JIT_CALL_SLOW;
        return true;
    }
    heap.store_builtin_result(regs + pc.a, &result);
    track_heap_store(act, regs + pc.a, pc.a);
    ds.curr_pc = next;
    *status = NEXT;
    return true;
}

// A builtin CALL a baseline call site makes of RegExp.prototype.exec or test
// (`builtin`) on a RegExp builtins::regexp_plain accepts, with a string
// argument: RegExpBuiltinExec runs without a builtin frame, and its value lands
// in the call's register. 0 continues at `next`; JIT_CALL_SLOW, having run
// nothing, leaves the call to jit_call_builtin_native.
fn long jit_call_regexp(Dispatch* ds, Instruction* next, long builtin) {
    Instruction* pc = next - 1;
    TVal* regs = ds.regs_base;
    if (pc.op != Opcode.CALL || pc.c == 0 || ds.ic_base == null) return JIT_CALL_SLOW;
    TVal recv = regs[pc.b + 1];
    HString* s = builtins::regexp_plain_input(&regs[pc.b + 2]);
    if (s == null || !recv.is_object()) return JIT_CALL_SLOW;
    HObject* rx = (HObject*)recv.get_heapptr();
    Heap* heap = ds.heap;
    if (rx == null || !builtins::regexp_plain(heap, rx)) return JIT_CALL_SLOW;
    // test runs RegExpExec, whose Get(R, "exec") must find the intrinsic.
    bool test = builtin == builtins::Builtin.REGEXP_PROTO_TEST.ordinal;
    if (test && !builtins::regexp_inherits_exec(heap, rx)) return JIT_CALL_SLOW;
    if (heap.gc_safepoint_due(true)) return JIT_CALL_SLOW;
    hobject::ic_note_callee((hobject::ICEntry*)ds.ic_base + (pc - ds.code_base), hobject::IC_BUILTIN_TARGET | (uint)builtin);
    // The match array is allocated with the frame's registers published (the
    // site has stored its resume point).
    Vm* vm = ds.vm;
    TVal* top = ds.act.bottom + vm.current_func.num_regs + FRAME_SCRATCH_SLOTS;
    if (top > vm.valstack_top) vm.valstack_top = top;
    TVal result;
    result.set_undefined();
    if (!builtins::regexp_exec_plain(heap, rx, s, test, &result)) return JIT_CALL_SLOW;
    if (result.is_object()) {
        heap.store_builtin_result(regs + pc.a, &result);
        track_heap_store(ds.act, regs + pc.a, pc.a);
    } else {
        regs[pc.a] = result;
    }
    ds.curr_pc = next;
    return 0;
}

// A CALL, CALL_UNDEF_THIS or CALL_GLOBAL whose callee is a builtin, through th_call_native
// as the threaded burst runs it (identity fast paths such as charCodeAt, then
// the builtin's own dispatch) instead of op_call. False when it declined before
// running anything but clearing a plain call's receiver slot, as op_call clears
// it too; otherwise `status` is what the operation function would return, with
// the burst's throw and re-dispatch handoffs completed as vm_dispatch completes
// them.
fn bool jit_call_builtin(Dispatch* ds, Instruction* next, OpStatus* status, long* raw) {
    if (!jit_relay_ready) jit_relay_init();
    if (ds.ic_base == null || ds.var_ic_base == null) return false;
    Vm* vm = ds.vm;
    Instruction* pc = next - 1;
    // A CALL_GLOBAL's site has stored the callee in its register (load_global_callee).
    bool global = pc.op == Opcode.CALL_GLOBAL;
    bool plain = global || pc.op == Opcode.CALL_UNDEF_THIS;
    if (pc.op != Opcode.CALL && !plain) return false;
    uint callee = global ? pc.a : pc.b;
    TVal* regs = ds.regs_base;
    if (th_lean_target(vm, regs[callee], regs + callee + 2, plain) != null) return false;
    if (plain) clear_call_regs(vm, ds.act, regs, callee + 1, callee + 2);
    ColdCtx* cold = &ds.cold;
    th_bind_ic_bias(cold, ds.code_base, ds.ic_base, ds.var_ic_base);
    int builtin = jit_builtin_index(regs[callee]);
    // Function.prototype.call's site records the function it runs instead (th_call_redispatched).
    if (builtin >= 0 && builtin != (int)builtins::Builtin.FUNCTION_PROTO_CALL.ordinal) {
        hobject::ic_note_callee(th_ic_at(cold, pc), hobject::IC_BUILTIN_TARGET | (uint)builtin);
    }
    uint nargs = global ? pc.b : pc.c;
    LeafKind leaf = (uint)builtin < jit_leaf_kinds.len ? jit_leaf_kinds[builtin] : LeafKind.NONE;
    if (leaf != NONE && jit_builtin_leaf(ds, leaf, (uint)builtin, regs[callee + 1], regs + callee + 2, nargs, regs + pc.a)) {
        track_heap_store(ds.act, regs + pc.a, pc.a);
        ds.curr_pc = next;
        *status = NEXT;
        return true;
    }
    Instruction* r = th_call_native(pc, &jit_stop_table, regs, cold, callee, pc.a, nargs) @inline;
    return jit_builtin_handoff(ds, next, r, status, raw);
}

// The end of a builtin call th_call_native or th_call_redispatched ran, which
// returned `r`: the throw or call the builtin handed off completes as
// vm_dispatch completes it. False when the call declined before running.
fn bool jit_builtin_handoff(Dispatch* ds, Instruction* next, Instruction* r, OpStatus* status, long* raw) {
    Vm* vm = ds.vm;
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
            long native = jit_enter_redispatched(ds, next, vm.threaded_call);
            if (native != JIT_CALL_SLOW) {
                *raw = native;
                return true;
            }
            *status = op_calls(ds, vm.threaded_call);
            return true;
        case NONE:
            break;
    }
    if (r == next - 1) return false;
    ds.curr_pc = r;
    *status = NEXT;
    return true;
}

// A builtin or lightfunc CALL completed by a baseline native call site itself,
// without the CALL thunk: th_call_native classifies both callee forms, and the
// call runs as jit_call_builtin runs it. The caller continues natively at
// `next` when the call left it there. 0 continues at `next`, JIT_CALL_SLOW
// declines before anything ran (the site takes its slow path), and every other
// value is what the thunk would have returned.
fn long jit_call_builtin_native(Dispatch* ds, Instruction* next) {
    Activation* act = ds.act;
    CompiledFunction* func = ds.vm.current_func;
    uint count_before = ds.vm.activation_count;
    ds.curr_pc = next;
    long raw = JIT_NO_RAW;
    OpStatus status;
    if (jit_call_builtin_method(ds, next, &status, &raw)) {
        if (raw != JIT_NO_RAW) return raw;
        // The builtin returned to this frame, as nearly every call does.
        if (status == NEXT && !ds.needs_restart && ds.act == act && ds.vm.current_func == func
            && ds.curr_pc == next) return 0;
        return jit::jit_call_status(ds, next, act, func, count_before, status);
    }
    if (!jit_call_builtin(ds, next, &status, &raw) @inline) return JIT_CALL_SLOW;
    jit::JitStats* st = &ds.heap.jit_stats;
    st.calls_builtin++;
    st.calls_builtin_direct++;
    if (raw != JIT_NO_RAW) return raw;
    return jit::jit_call_status(ds, next, act, func, count_before, status);
}
