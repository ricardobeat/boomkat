module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;

// ============================================================================
// GC activation marking
// ============================================================================

/// Mark env bindings held by a single activation.  Shared between the live
/// activation array and the shadow frame stack.
fn void mark_activation_envs(heap::Heap* h, Activation* act) @inline {
    if (act.var_env != null && act.var_env.bindings != null) {
        h.mark_hobject(act.var_env.bindings);
    }
    if (act.lex_env != null && act.lex_env.bindings != null && act.lex_env != act.var_env) {
        h.mark_hobject(act.lex_env.bindings);
    }
    // Walk the full var_env parent chain to keep all enclosing scopes alive.
    env::EnvRecord* cur = act.var_env;
    while (cur != null) {
        if (cur.bindings != null) { h.mark_hobject(cur.bindings); }
        cur = cur.parent;
    }
    // Also walk the lex_env parent chain in case it diverges from var_env.
    cur = act.lex_env;
    while (cur != null) {
        if (cur.bindings != null) { h.mark_hobject(cur.bindings); }
        cur = cur.parent;
    }
}

/// Mark every heap value held in a JS activation's [bottom, frame_end) span.
/// The valstack range scanned by mark_roots is bounded by vm.valstack_top,
/// which is only a high-water mark for the deepest frame and can sit below an
/// outer frame's full register span (inline JS-to-JS calls do not raise it),
/// or below scratch slots where a builtin has staged call arguments. A live
/// value in such a slot (e.g. a BigInt box held across a callee) would then be
/// invisible to the GC, collected, and later read as freed memory. Marking each
/// live frame's own span makes register rooting independent of valstack_top.
/// Native/builtin frames have func==null and no registers here. Callers choose
/// frame_end to cover the frame's registers plus any staged-argument scratch.
fn void mark_activation_regs(heap::Heap* h, Activation* act, TVal* frame_end) @inline {
    if (act.func == null || act.bottom == null) return;
    TVal* regs = act.bottom;
    if (frame_end <= regs) return;
    usz span = (usz)(frame_end - regs);
    for (usz i = 0; i < span; i++) {
        h.mark_tval(&regs[i]);
    }
}

/// Mark heap references held in an Activation's own struct fields (not the
/// register span, not the env chain). These slots can be the sole surviving
/// root for a value across a safepoint GC:
///  - this_binding: owned ref (ACT_FLAG_THIS_OWNED); for getters/setters the
///    receiver is copied ONLY here (registers are cleared, no arg slot holds it).
///  - this_binding (construct): the freshly allocated constructor instance is
///    parked here by a raw assign and, under GC pressure inside the constructor
///    body, is otherwise collected — its [[Prototype]] then reads as freed
///    memory (confirmed via a Reflect.construct/derived-class stress repro).
///  - new_target: an HObject* for the constructor/newTarget. Defensive — every
///    repro attempted co-rooted it via a caller register or the class binding,
///    but marking it removes the dependence on that incidental rooting.
///  - async_promise: the async function/module's outer Promise, settled only
///    after the body returns. Co-rooted by the caller's result register and the
///    microtask queue in practice, so the mark itself is defensive — but it is
///    UNGUARDED by ACT_FLAG_ASYNC and therefore depends on every push site
///    clearing the field (activation_begin). A stale pointer here is a freed
///    HObject* and marking it corrupts the heap; see Activation.async_promise.
///  - async_gen_state: the GeneratorState this frame is resuming; mark its
///    contents so a suspended-then-resumed async generator is not swept mid-body.
///    Defensive: the gs is normally reachable via its owning generator object.
///  - Catcher.thrown_val: an in-flight exception parked in a catcher across a
///    GC that runs while unwinding (e.g. allocation-heavy finally blocks) —
///    confirmed collectible without this mark via a throw-through-finally repro.
/// Marking a null/undefined slot is a harmless no-op (mark_tval/mark_hobject and
/// mark_generator_state all null-check).
fn void mark_activation_fields(heap::Heap* h, Activation* act) @inline {
    // this_binding can be the sole root of a heap value in two cases:
    //  - ACT_FLAG_THIS_OWNED: the frame incref'd `this` into this slot
    //    (getters/setters, inline CALL) — the register copy may be gone.
    //  - ACT_FLAG_CONSTRUCT: the freshly allocated instance is stored here by a
    //    raw assign (vm_execute construct entry) and is not reliably in any
    //    register during the constructor body (verified collectible under GC).
    // An ordinary call's `this` was copied from a register/env that still roots
    // it, so deep non-method recursion (this === undefined, both flags clear)
    // stays free of the per-frame mark.
    if ((act.flags & (ACT_FLAG_THIS_OWNED | ACT_FLAG_CONSTRUCT)) != 0) {
        h.mark_tval(&act.this_binding);
    }
    if (act.new_target != null) { h.mark_hobject(act.new_target); }
    if (act.async_promise != null) { h.mark_hobject(act.async_promise); }
    if (act.async_gen_state != null) {
        h.mark_generator_state((heap::GeneratorState*)act.async_gen_state);
    }
    // Walk the catcher chain: an in-flight exception parked in Catcher.thrown_val
    // (set by THROW, not yet consumed by CATCH) is not on the valstack and would
    // otherwise be collected across a safepoint GC that runs while unwinding.
    Catcher* c = (Catcher*)act.cat;
    while (c != null) {
        h.mark_tval(&c.thrown_val);
        h.mark_tval(&c.return_val);
        c = c.parent;
    }
    // Walk the for-in chain: each live enumeration holds its target, and the
    // target's temproot pin is NOT durable — a safepoint GC clears every
    // temproot in phase 1 (see Heap.mark_and_sweep). Any for-in whose target
    // is referenced nowhere else — `for (k in {a:1}) ...`, or an object whose
    // only other reference the loop body overwrote — is therefore collectible
    // mid-enumeration, after which NEXTFOR's liveness re-check reads freed
    // memory and the eventual pin release writes to it. Marking here makes the
    // target a real GC root for exactly as long as the frame owns the state.
    heap::ForInState* fi = (heap::ForInState*)act.forin;
    while (fi != null) {
        if (fi.target != null) { h.mark_hobject(fi.target); }
        fi = fi.parent;
    }
}

/// Mark all env bindings held by live activation records.
/// Called from heap's mark_roots to keep per-call var_envs alive during GC.
/// Also marks saved activations stored in vm_call_fn_impl's shadow frame list
/// so that outer call frames remain alive during nested Vm.run() execution.
fn void vm_mark_activations(void* vm_ptr, void* heap_ptr) {
    Vm* vm = (Vm*)vm_ptr;
    heap::Heap* h = (heap::Heap*)heap_ptr;

    // VM-level TVal scratch that outlives any single register span and is not
    // part of the scanned valstack: a heap value parked here (e.g. a closure
    // returned into vm.return_val by a top-level RET, or a pending throw value)
    // must be rooted, or a safepoint GC — which clears temproots — collects it
    // and the next decref of the stale slot is a use-after-free.
    h.mark_tval(&vm.return_val);
    h.mark_tval(&vm.throw_value);

    // Mark live activations (inner-most vm_call_fn_impl's callback + inline callees).
    // Each frame's register span runs from its bottom to the next inner frame's
    // bottom (which contains the argument/scratch slots this frame staged for
    // that callee); the innermost frame runs to the end of the allocated
    // valstack (see below — staged-argument scratch is not tracked precisely).
    for (uint i = 0; i < vm.activation_count; i++) {
        mark_activation_envs(h, &vm.activations[i]);
        mark_activation_fields(h, &vm.activations[i]);
        Activation* a = &vm.activations[i];
        // Lower bound on this frame's span: its own declared registers plus the
        // builtin arg/scratch margin. valstack_top can sit BELOW an outer (or
        // even the current) frame's num_regs because inline JS-to-JS calls do
        // not raise it, so it cannot be trusted as the frame end on its own.
        TVal* frame_end = a.bottom;
        if (a.func != null) {
            CompiledFunction* acf = (CompiledFunction*)a.func;
            frame_end = a.bottom + acf.num_regs + 4;
        }
        // Extend to the next inner frame's bottom (covers args this frame staged
        // for that callee). For the innermost frame, extend to the end of the
        // allocated valstack: builtins stage call arguments in scratch slots
        // above num_regs whose exact extent is not tracked by valstack_top, and
        // a live value there must not be collected. Slots past the live data are
        // zero-initialised (undefined) — marking them is a harmless no-op — so
        // scanning to valstack_end is safe and cannot miss a staged argument.
        if (i + 1 < vm.activation_count) {
            TVal* nb = vm.activations[i + 1].bottom;
            if (nb > frame_end) { frame_end = nb; }
        } else if (vm.valstack_end > frame_end) {
            frame_end = vm.valstack_end;
        }
        mark_activation_regs(h, a, frame_end);
    }

    // Mark saved outer activations from all vm_call_fn_impl frames on the C stack.
    // These are stored in C-stack ShadowActFrame structs linked via vm.shadow_act_list.
    // Their exact physical span is not tracked here, so cover num_regs plus the
    // builtin arg/scratch margin (matches the +4 slots reserved at call sites).
    ShadowActFrame* shadow = (ShadowActFrame*)vm.shadow_act_list;
    while (shadow != null) {
        for (uint i = 0; i < shadow.count; i++) {
            mark_activation_envs(h, &shadow.acts[i]);
            mark_activation_fields(h, &shadow.acts[i]);
            Activation* sa = &shadow.acts[i];
            if (sa.func != null && sa.bottom != null) {
                CompiledFunction* scf = (CompiledFunction*)sa.func;
                TVal* send = sa.bottom + scf.num_regs + 4;
                mark_activation_regs(h, sa, send);
            }
        }
        shadow = (ShadowActFrame*)shadow.prev;
    }
}

// ============================================================================
// Call handling (matches duk_js_call.c)
// ============================================================================

/// Invoke a getter function found on the prototype chain.
/// Sets up an ECMAScript call frame for the getter with `this` = this_obj,
/// and result register = result_reg (in the caller's frame).
/// Returns true if the call was set up (caller should `break` with needs_restart).
fn bool invoke_getter(Vm* vm, hobject::AccessorResult* acc,
                      TVal* this_val, uint result_reg,
                      Activation* act, Instruction** curr_pc, bool* needs_restart,
                      TVal* regs_base) {
    TVal getter_fn = acc.accessor_fn;

    // If getter is undefined/null, return undefined (no-op)
    if (getter_fn.is_undefined() || getter_fn.is_null()) {
        regs_base[result_reg].set_undefined();
        return false;
    }

    if (!getter_fn.is_object()) return false;
    HObject* func_obj = (HObject*)getter_fn.get_heapptr();
    if (func_obj == null || !func_obj.is_callable()) return false;

    // Fast path: builtin function getter — call directly, no JS frame needed
    if (func_obj.callable_kind() == hobject::CallableKind.BUILTIN_FN &&
        (*func_obj.extra_ptr()).func.builtin_fn_index >= 0) {
        uint fn_idx = (uint)(*func_obj.extra_ptr()).func.builtin_fn_index;
        TVal[1] temp_regs;
        temp_regs[0] = *this_val;  // this at regs[base_reg - 1] = regs[0]
        builtins::BuiltinContext ctx;
        ctx.vm = vm;
        ctx.regs = &temp_regs;
        ctx.base_reg = 1;
        ctx.argc = 0;
        ctx.result = &temp_regs[0];
        ctx.heap = vm.heap;
        ctx.this_val = *this_val;
        ctx.is_constructor = false;
        ctx.needs_re_dispatch = false;
        ctx.re_nargs = 0;
        ctx.global_env = vm.global_env;
        ctx.should_throw = false;
        ctx.callee_obj = func_obj;
        builtins::dispatch_builtin(fn_idx, &ctx);
        if (ctx.should_throw) {
            if (!vm_throw_value(vm, ctx.throw_value, act, curr_pc, needs_restart)) {
                // Uncaught — mark error state so dispatch_property propagates VM_ERROR~.
                vm.has_error = true;
                vm.heap.has_error = true;
                vm.heap.tval_copy_ref(&vm.heap.error_value, &ctx.throw_value);
                vm.heap.tval_copy_ref(&vm.return_val, &ctx.throw_value);
                regs_base[result_reg].set_undefined();
                return false;
            }
            regs_base = act.bottom;
        } else {
            vm.heap.store_builtin_result(&regs_base[result_reg], ctx.result);
        }
        return false;
    }

    CompiledFunction* target = (*func_obj.extra_ptr()).func.comp_func;
    if (target == null) return false;

    // Set up call frame: callee_reg = result_reg (we reuse it)
    uint callee_reg = result_reg;
    uint frame_start = callee_reg + 2;
    TVal* new_bottom = act.bottom + frame_start;
    uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

    if (!ensure_valstack(vm, needed)) {
        regs_base[result_reg].set_undefined();
        return false;
    }

    // Re-acquire regs_base after potential reallocation
    TVal* caller_regs = act.bottom;
    // Recompute new_bottom after realloc (act.bottom may have moved)
    new_bottom = act.bottom + frame_start;
    vm.heap.tval_copy_ref(&caller_regs[callee_reg], &getter_fn);
    vm.heap.tval_copy_ref(&caller_regs[callee_reg + 1], this_val);

    if (vm.activation_count >= MAX_CALLS) {
        if (!vm_throw_error(vm, vm.heap.range_err_proto, "Maximum call stack size exceeded", act, curr_pc, needs_restart)) {
            caller_regs[result_reg].set_undefined();
        }
        return false;
    }

    // Getter invocation is never async and never a construct call: the
    // pooled-slot pointer fields (async_promise, async_gen_state, new_target)
    // are all cleared by activation_begin, so new.target reads undefined here
    // however the property access was reached (including super.prop from a
    // constructor).
    Activation* new_act = activation_begin(vm);

    EnvRecord* invoke_getter_var_env = (*func_obj.extra_ptr()).func.var_env;
    if (try fv_ig = env::env_create_function_scope(vm.heap, (*func_obj.extra_ptr()).func.var_env)) { invoke_getter_var_env = fv_ig; }
    new_act.parent = act;
    new_act.func = target;
    new_act.var_env = invoke_getter_var_env;
    new_act.lex_env = resolve_call_lex_env(vm, func_obj, target, invoke_getter_var_env);
    new_act.cat = null;
    new_act.curr_pc = target.code;
    new_act.bottom = new_bottom;
    new_act.retval = act.bottom + result_reg;
    new_act.flags = 0;
    if (target.has_direct_eval()) {
        new_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }
    vm.heap.tval_copy_ref(&new_act.this_binding, this_val);
    new_act.flags |= ACT_FLAG_THIS_OWNED;

    // Clear registers and copy args (getters have 0 args)
    TVal* new_regs = new_act.bottom;
    uint new_nregs = target.num_regs;
    mem::clear(new_regs, (sz)((usz)new_nregs * TVal::size));

    // Create the arguments object for getters/setters that reference `arguments`.
    // Per ES2015 §14.3 step 7 + §14.5.14 step 11 (Runtime Semantics: ClassDefinitionEvaluation
    // for MethodDefinition), the `arguments` object is bound for getter/setter bodies just
    // like for ordinary methods — without this, a getter body doing `var a = arguments`
    // raises ReferenceError. Getters/setters never receive user-supplied args (the
    // property-access syntax passes none), so the object is always empty.
    if (target.uses_arguments()) {
        HObject*? args_obj_raw_ig = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
        if (try args_obj_ig = args_obj_raw_ig) {
            args_obj_ig.prototype = vm.heap.object_proto;
            finish_arguments_object(vm, args_obj_ig, func_obj, 0);
            HString* args_name_ig = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
            if (args_name_ig != null) {
                TVal args_tv_ig; args_tv_ig.set_object(args_obj_ig);
                env::env_declare(new_act.var_env, args_name_ig, args_tv_ig);
            }
        }
    }

    vm.valstack_top = new_regs + new_nregs;
    vm.valstack_bottom = new_act.bottom;

    // Save caller's PC so it resumes correctly after getter returns
    act.curr_pc = *curr_pc;

    *needs_restart = true;
    return true;
}

/// Push a fresh activation onto vm.activations[] and initialize every field
/// whose stale value would be READ by a later frame.
///
/// vm.activations[] is a pool indexed by depth and reused WITHOUT zeroing, so a
/// raw pointer field is only sound if EVERY push writes it. Two fields are read
/// unconditionally — without any flag guard — by code that runs for ordinary
/// frames:
///   - async_promise: mark_activation_fields() marks it on every GC for every
///     activation below activation_count. A stale value left by a settled async
///     frame at the same depth is a freed HObject*; mark_hobject then writes
///     set_reachable() into freed memory and drains its (garbage) prototype and
///     property pointers, which ends in sweep() free()ing a pointer it never
///     allocated.
///   - async_gen_state: the unwind walk in vm_throw.c3 and the YIELD parent
///     search in vm_generators.c3 both dereference it on `!= null` alone.
///   - forin: free_forin_chain() walks and frees it on every frame pop. A
///     stale head left by a frame that already drained its chain would be
///     freed a second time.
/// new_target is included because NEWTARGET reads it directly and a plain call
/// must not observe a prior `new` on the same slot.
///
/// Callers must still set parent/func/var_env/lex_env/curr_pc/bottom/retval and
/// OR in their own flags; those are written unconditionally at every site today.
/// Anything new that a non-async or non-generator frame can read must be
/// initialized HERE, not at the individual call sites.
macro Activation* activation_begin(Vm* vm) {
    Activation* act = &vm.activations[vm.activation_count];
    vm.activation_count++;
    act.async_promise = null;
    act.async_gen_state = null;
    act.forin = null;
    act.new_target = null;
    act.max_heap_reg = 0;
    act.caller_valstack_top = vm.valstack_top;
    return act;
}

/// Track a heap-ref store in the current activation.  Call after any
/// instruction that writes an object or buffer TVal into a register.
/// Updates max_heap_reg so decref_callee_regs can skip non-heap registers.
fn void track_heap_store(Activation* act, TVal* val, uint reg_idx) @inline {
    if (val.is_heap_allocated()) {
        if (val.get_heapptr() != null && reg_idx > act.max_heap_reg) {
            act.max_heap_reg = reg_idx;
        }
    }
}

/// ES2015 §9.2.2 step 15 / §8.1.1.3.4: an explicit `return;`, `return undefined;`,
/// or implicit fallthrough from a derived constructor falls through to
/// GetThisBinding() — if super() was never called, this_binding is still the
/// TDZ sentinel and must throw ReferenceError. Shared by RET (when the return
/// value is undefined) and RETUNDEF so both opcodes enforce the same check.
fn bool derived_ctor_returns_undefined_uninitialized(Activation* callee_act) @inline {
    return (callee_act.flags & ACT_FLAG_CONSTRUCT) != 0
        && (callee_act.flags & ACT_FLAG_DERIVED) != 0
        && env::is_tdz_sentinel(&callee_act.this_binding);
}

/// When an activation whose callee was BORROWED (ACT_FLAG_BORROWED_CALLEE) is
/// unwound abnormally (exception), its retval slot in the surviving caller
/// still holds the borrowed, non-owned callee value. A later decref_callee_regs
/// sweep of that caller frame would decref a reference the caller never owned
/// (the callee register is inside the caller's [0..max_heap_reg] range whenever
/// a heap argument was passed). Neutralize the borrowed bits with a raw
/// overwrite so the sweep skips over harmless undefined. No decref: borrowed.
fn void clear_borrowed_callee_slot(Activation* act) @inline {
    if ((act.flags & ACT_FLAG_BORROWED_CALLEE) != 0 && act.retval != null) {
        act.retval.set_undefined();
    }
}

/// Free every Catcher still chained on an activation that is being popped.
/// A `return` from inside a try block (or an unwind past the frame) leaves
/// the TRY-allocated catcher(s) on act.cat: CATCH/ENDTRY/ENDFINALLY only pop
/// them on their own control paths, which an early return never reaches —
/// without this, each such frame permanently leaks its Catcher allocation(s).
/// thrown_val is the one owned reference a parked catcher can hold (written
/// via tval_copy_ref while routing a throw to a finally); release it too.
///
/// Also drains the frame's for-in chain (see free_forin_chain). The two are
/// deliberately released by ONE function rather than two calls at each of the
/// seven pop sites: a second call is a second thing to forget, and the whole
/// point of moving for-in state onto the activation was to remove per-exit
/// bookkeeping. Anything else a frame owns outright belongs here too.
fn void free_catcher_chain(Vm* vm, Activation* act) @inline {
    free_forin_chain(vm, act);
    Catcher* c = (Catcher*)act.cat;
    if (c == null) return;
    do {
        Catcher* parent = c.parent;
        vm.heap.decref_tval(&c.thrown_val);
        vm.heap.free_func(vm.heap.heap_udata, c);
        c = parent;
    } while (c != null);
    act.cat = null;
}

/// Release one for-in state: drop the target's temproot pin, free the key
/// array, free the struct. The pin and `keys` are released together because
/// the keys are raw interned HString* with no incref of their own — they are
/// kept alive by the pinned target's property table, so unpinning earlier
/// than the free would leave `keys` pointing at collectable strings.
fn void forin_state_free(Vm* vm, ForInState* state) @inline {
    if (state == null) return;
    if (state.target != null) {
        state.target.as_header().clear_temproot();
    }
    if (state.keys != null) {
        vm.heap.free_func(vm.heap.heap_udata, state.keys);
    }
    vm.heap.free_func(vm.heap.heap_udata, state);
}

/// Unlink `state` from `*head` and free it. No-op if it is not on the chain
/// (it may already have been drained by a frame pop).
fn void forin_chain_remove(Vm* vm, void** head, ForInState* state) @inline {
    if (state == null) return;
    ForInState** link = (ForInState**)head;
    while (*link != null) {
        if (*link == state) {
            *link = state.parent;
            forin_state_free(vm, state);
            return;
        }
        link = &(*link).parent;
    }
}

/// Free every for-in state still live on an activation being popped.
///
/// This is the catch-all that makes for-in cleanup unforgettable: `break`,
/// `return`, a propagating `throw`, and a labeled continue out of the loop
/// all reach a frame pop (or an enclosing INITFOR) without the compiler
/// emitting anything loop-specific, so none of them can be the site of a
/// missed free.
///
/// Called from free_catcher_chain, so it runs at every ordinary frame pop
/// without those sites naming it. The one direct caller is
/// vm_complete_generator_return, whose pop is final but deliberately does not
/// touch the catcher chain (still aliased by gs.cat).
fn void free_forin_chain(Vm* vm, Activation* act) @inline {
    ForInState* s = (ForInState*)act.forin;
    if (s == null) return;
    while (s != null) {
        ForInState* parent = s.parent;
        forin_state_free(vm, s);
        s = parent;
    }
    act.forin = null;
}

/// Save an activation's state chains into the GeneratorState that will resume
/// it, at every point where a generator body suspends.
///
/// `cat` is ALIASED, not moved: the .throw()/.return() resume paths re-enter
/// the still-live activation looking for a catcher, so clearing act.cat here
/// would break try/catch inside a suspended generator. The pop that follows a
/// suspend deliberately skips free_catcher_chain for the same reason.
///
/// `forin` is MOVED: the activation must stop owning the states, because the
/// pooled slot it occupies gets reused by an unrelated later frame whose pop
/// DOES run free_catcher_chain — which would free ForInStates that this
/// generator's saved_regs still points at. Ownership lives on the gs until
/// either a resume hands it back (forin_restore_from_gen) or the generator is
/// discarded (gs_release).
///
/// Saving both in one call is deliberate: a suspend site that remembered the
/// catcher chain but not the for-in chain is exactly the omission this whole
/// change exists to make impossible.
macro forin_save_to_gen(Activation* act, gs) {
    gs.cat = act.cat;
    gs.forin = act.forin;
    act.forin = null;
}

/// Inverse of forin_save_to_gen: hand the for-in chain back to the frame that
/// is resuming the body, leaving the GeneratorState owning nothing (so a later
/// gs_release cannot free states the live frame is now using). `cat` is
/// restored by aliasing, matching the save side.
macro forin_restore_from_gen(Activation* act, gs) {
    act.cat = gs.cat;
    act.forin = gs.forin;
    gs.forin = null;
}

/// Decrement the reference count of every register in the given activation.
/// Must be called BEFORE the activation is popped, while the register range
/// is still valid.  Safe to call on activations with null func (no registers).
/// Fast-path: if max_heap_reg == 0, no register ever held a heap ref — skip.
fn void decref_callee_regs(Vm* vm, Activation* callee_act) {
    if (callee_act.func == null) return;
    if (callee_act.max_heap_reg == 0) return;  // fast path: no heap refs
    CompiledFunction* callee_func = (CompiledFunction*)callee_act.func;
    uint nregs = callee_func.num_regs;
    if (nregs == 0) return;  // no registers to decref
    TVal* regs = callee_act.bottom;
    uint limit = callee_act.max_heap_reg;
    if (limit >= nregs) limit = nregs - 1;
    for (uint i = 0; i <= limit; i++) {
        // Clear the slot after releasing the ref: callee frames overlap the
        // caller's register window (sliding-window calls), and the caller's
        // own decref_callee_regs would otherwise decref the stale bits a
        // second time, underflowing the refcount.
        vm.heap.decref_tval(&regs[i]);
        regs[i].set_undefined();
    }
}

/// val: the return value (or undefined for RETUNDEF)
/// @inline: critical hot-path, called on every RET instruction.
/// Zero-initialize a range of registers to undefined.  For the small ranges
/// typical of function prologues, an inline scalar-store loop beats a bulk
/// memset call overhead.  A pointer-increment loop (rather than an index loop)
/// is deliberate: at -O2 LLVM's loop-idiom-recognition pass re-derives a
/// `memset_pattern16` libc call from the index form when this helper is inlined
/// at the call sites, re-introducing exactly the call overhead we mean to
/// avoid — measured ~9% of fib(32) samples.  The pointer form is not lowered to
/// memset. Verify with `objdump` after any change here (the lowering decision is
/// sensitive to the surrounding inlined context, not just this loop's shape).
fn void zero_regs_undefined(TVal* regs, uint start, uint end) @inline {
    TVal* p = regs + start;
    TVal* stop = regs + end;
    while (p < stop) {
        p.set_undefined();
        p++;
    }
}

fn TVal handle_return(Vm* vm, TVal val) @inline {
    if (vm.activation_count == 0) {
        vm.heap.tval_copy_ref(&vm.return_val, &val);
        return val;
    }

    Activation* callee_act = curr_act(vm);
    TVal* callee_result = callee_act.retval;

    // Free catchers a return-from-try left on the chain (frame is popping).
    free_catcher_chain(vm, callee_act);
    // Decrement references for all callee registers before popping
    decref_callee_regs(vm, callee_act);

    // Pop activation
    vm.activation_count--;

    // If we just popped the last activation, there is no caller
    if (vm.activation_count == 0) {
        vm.heap.tval_copy_ref(&vm.return_val, &val);
        // Release the this_binding reference after the return value is saved.
        // Clear the slot after releasing the ref: activation slots are pooled
        // by depth index and reused without zeroing (see the fast-call path's
        // matching comment), so a future call reusing this same slot would
        // otherwise decref these stale bits a second time via tval_copy_ref's
        // own dst-decref, underflowing the refcount of whatever object this
        // this_binding used to hold.
        if ((callee_act.flags & ACT_FLAG_THIS_OWNED) != 0) {
            vm.heap.decref_tval(&callee_act.this_binding);
            callee_act.this_binding.set_undefined();
        }
        return val;
    }

    Activation* caller_act = curr_act(vm);
    assert(caller_act != null);

    // Restore valstack_bottom to caller's
    vm.valstack_bottom = caller_act.bottom;

    // Write result to caller's frame at the saved retval
    if (callee_result != null && callee_result >= vm.valstack && callee_result < vm.valstack_end) {
        // For construct calls: if return value is not an object, use this_binding.
        // (The inline RET path in vm_execute.c3 already converts derived-ctor
        // non-object non-undefined returns into throws before reaching here.
        // This handle_return path is only reached from vm_call_fn_impl, which
        // handles its own derived-ctor check via ACT_FLAG_DERIVED.)
        TVal final_val = val;
        if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
            if (!final_val.is_object() || final_val.get_heapptr() == null) {
                // Return the instance (this) instead of the constructor's return value
                if (callee_act.this_binding.is_object() && callee_act.this_binding.get_heapptr() != null) {
                    final_val = callee_act.this_binding;
                }
            }
        }
        TVal* result_slot = callee_result;
        if ((callee_act.flags & ACT_FLAG_BORROWED_CALLEE) != 0) {
            // Borrowed callee: the old value in result_slot is the non-owned
            // borrowed closure — incref the result and raw-overwrite, never
            // decref the borrowed value.
            if (final_val.is_heap_allocated() && final_val.get_heapptr() != null) {
                ((HeapHeader*)final_val.get_heapptr()).incref();
            }
            *result_slot = final_val;
        } else {
            vm.heap.tval_copy_ref(result_slot, &final_val);
        }
        // A heap result (e.g. a large non-interned string) now lives in a
        // caller register the caller may never have tracked. Raise the
        // caller's max_heap_reg so its decref_callee_regs sweep releases the
        // reference instead of leaking it.
        if (result_slot >= caller_act.bottom && result_slot.is_heap_allocated()) {
            track_heap_store(caller_act, result_slot, (uint)(result_slot - caller_act.bottom));
        }
    }

    // Release the this_binding reference AFTER the result has been written
    // (construct returns may read this_binding to produce the result value).
    // ACT_FLAG_THIS_OWNED is set by paths that incref this_binding (inline CALL,
    // getter invocation) and NOT set by vm_call_fn_impl (raw assign + restore).
    // Clear the slot after releasing the ref: activation slots are pooled by
    // depth index and reused without zeroing, so a future call reusing this
    // same slot would otherwise decref these stale bits a second time via
    // tval_copy_ref's own dst-decref, underflowing the refcount of whatever
    // object this this_binding used to hold.
    if ((callee_act.flags & ACT_FLAG_THIS_OWNED) != 0) {
        vm.heap.decref_tval(&callee_act.this_binding);
        callee_act.this_binding.set_undefined();
    }

    // Restore valstack_top to match caller's nregs
    if (caller_act.func != null) {
        CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
        vm.valstack_top = caller_act.bottom + caller_func.num_regs;
    }

    return val;
}

