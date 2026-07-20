module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::esm;
import duktape::re_bindings;
import std::io;
import std::math;

/// Set up a named-function-expression's lexical environment.
/// Returns a fresh declarative env with `name_hstr` bound immutably to
/// `func_obj`, or null on failure. The returned env's parent is `var_env`,
/// so lookups for everything else still walk through the function's normal
/// scope chain (per ES2015 §14.1.20 NamedEvaluation).
fn EnvRecord*? setup_named_function_expr_env(Vm* vm, EnvRecord* var_env,
                                              HString* name_hstr,
                                              HObject* func_obj) {
    EnvRecord*? lex_env_raw = env::env_create_declarative(vm.heap, var_env);
    if (catch err = lex_env_raw) return types::ALLOC_ERROR~;
    EnvRecord* lex_env = lex_env_raw;
    TVal func_tv; func_tv.set_object(func_obj);
    // Non-writable, enumerable, configurable — same flags PUTLEX_C uses for const.
    lex_env.bindings.put_prop((void*)name_hstr, func_tv, hobject::PROP_FLAGS_EC);
    return lex_env;
}

/// Resolve the lexical environment for entering a compiled-function call frame.
/// Closures created inside a PUSH_LEX block scope capture that declarative env
/// in func.lex_env; the frame must enter with it as lex_env so the block's
/// let/const bindings stay visible (GETVAR walks lex_env, then var_env).
/// Named function expressions additionally get a fresh declarative env binding
/// their own name (ES2015 §14.1.20), chained above the captured scope.
fn EnvRecord* resolve_call_lex_env(Vm* vm, HObject* func_obj,
                                   CompiledFunction* target, EnvRecord* var_env) {
    EnvRecord* base = var_env;
    EnvRecord* cap_lex = (*func_obj.extra_ptr()).func.lex_env;
    if (cap_lex != null && cap_lex != var_env && cap_lex.is_declarative) {
        // The closure was created inside a PUSH_LEX block (or a class body), so
        // its lexical bindings live in `cap_lex`. When the callee owns a fresh
        // function scope of its own (needs_env — it declares `arguments`,
        // closures, or captured locals), those own bindings (parameters/locals)
        // live in `var_env`, whose natural parent is the captured function
        // var_env (`own_var_env`).
        //
        // If `cap_lex`'s parent chain itself descends to `own_var_env`, the
        // fresh scope can be reparented under `cap_lex` so its own bindings
        // resolve first, then the enclosing block's, and `own_var_env` stays
        // reachable through `cap_lex` — a single lexical chain (search head =
        // var_env). Skip this for functions with a default/rest-parameter lex
        // bridge (that path installs its own lex_env below and reparenting
        // would risk a cycle) and when `var_env` is already on `cap_lex`'s
        // chain. Only a scope freshly allocated for THIS call is safe to
        // reparent; never mutate the shared captured `func.var_env` (reused
        // directly by needs_env=false callees — doing so corrupts every future
        // call).
        //
        // When `cap_lex` does NOT reach `own_var_env` (they are lexical
        // siblings sharing a common ancestor — e.g. the global DeclarativeRecord
        // captured alongside a sibling function/constructor scope), reparenting
        // would sever `var_env` from `own_var_env` and lose the captured
        // parameters. Instead, enter with `cap_lex` as the lexical search head
        // and leave `var_env`'s parent intact: GETVAR walks lex_env (`cap_lex`)
        // first and falls back to var_env (`var_env` → `own_var_env`), so both
        // the block/class lexicals and the captured parameters remain visible.
        EnvRecord* own_var_env = (*func_obj.extra_ptr()).func.var_env;
        bool splice = var_env.is_function_scope
            && var_env != own_var_env
            && !target.needs_lex_bridge();
        bool cap_reaches_own = false;
        if (splice) {
            EnvRecord* w = cap_lex;
            uint depth = 0;
            while (w != null && depth < 256) {
                if (w == var_env) { splice = false; break; }
                if (w == own_var_env) { cap_reaches_own = true; }
                w = w.parent;
                depth++;
            }
        }
        if (splice && cap_reaches_own) {
            var_env.parent = cap_lex;
            base = var_env;
        } else {
            base = cap_lex;
        }
    }
    if (target.is_namebinding()) {
        char[] name_data = target.get_name();
        HString* name_hstr = intern_string(vm, name_data);
        if (name_hstr != null) {
            if (try name_lex = setup_named_function_expr_env(vm, base, name_hstr, func_obj)) {
                return name_lex;
            }
        }
    }
    return base;
}

/// Implementation of Heap.call_fn — calls a JS function with N arguments through the VM.
/// OrdinaryHasInstance chain walk, routing prototype hops through the
/// [[GetPrototypeOf]] trap when a Proxy appears on the chain.
/// Sets ra to true on match. Returns false when an uncaught error unwinds
/// (caller must `return VM_ERROR~`).
fn bool instanceof_walk_chain(Vm* vm, Dispatch* ds, HObject* start, HObject* probe, TVal* ra) {
    HObject* cur = start;
    uint depth = 0;
    while (cur != null && depth < hobject::MAX_PROTO_DEPTH) {
        if (cur == probe) { ra.set_boolean(true); return true; }
        if (cur.flags.exotic_proxyobj) {
            TVal next;
            if (!builtins::proxy_mop_get_proto(vm, vm.heap, cur, &next)) {
                TVal werr = vm.heap.error_value;
                vm.heap.has_error = false;
                if (!vm_throw_value(vm, werr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    vm.heap.tval_copy_ref(&vm.return_val, &werr);
                    vm.has_error = true;
                    vm.heap.has_error = true;
                    return false;
                }
                return true;
            }
            cur = next.is_object() ? (HObject*)next.get_heapptr() : null;
        } else {
            cur = cur.prototype;
        }
        depth++;
    }
    return true;
}

fn TVal vm_call_fn_impl(void* vm_ptr, TVal func, TVal* args, uint nargs, TVal this_val) {
    Vm* vm = (Vm*)vm_ptr;
    TVal undef;
    undef.set_undefined();

    // Save resume_gen before ANY dispatch below runs. Case 2 (builtin, e.g.
    // Generator.prototype.next) may itself set vm.heap.resume_gen for the
    // *callee's* generator before falling through to Case 3's re-dispatch —
    // capturing this after Case 2 runs would save the callee's resume_gen
    // instead of the caller's, corrupting the caller generator's resume
    // state once restored below (e.g. yield* losing track of the delegating
    // generator's own suspend/resume bookkeeping).
    void* saved_resume_gen_outer = vm.heap.resume_gen;

    // Case 1: lightfunc — dispatch directly via BuiltinContext
    if (func.is_lightfunc()) {
        uint fn_idx = (uint)(usz)func.get_heapptr();

        // Temporary register layout: [this, arg0, arg1, ...]
        // Use stack-allocated array for up to 8 args
        uint total = 1 + nargs;
        if (total > 16) total = 16;

        TVal[16] temp_regs;
        temp_regs[0] = this_val;
        for (uint i = 0; i < nargs && i < 16; i++) {
            temp_regs[1 + i] = args[i];
        }

        builtins::BuiltinContext ctx;
        ctx.vm = vm;
        ctx.regs = &temp_regs;
        ctx.base_reg = 1;
        ctx.argc = (ushort)nargs;
        ctx.result = &temp_regs[0];
        ctx.heap = vm.heap;
        ctx.this_val = this_val;
        ctx.is_constructor = false;
        ctx.needs_re_dispatch = false;
        ctx.re_nargs = 0;
        ctx.global_env = vm.global_env;
        ctx.should_throw = false;
        ctx.callee_obj = null;

        builtins::dispatch_builtin(fn_idx, &ctx);
        if (ctx.should_throw) {
            // Propagate the throw on both error channels: vm.has_error /
            // heap.has_error for callers using vm_check_call_fn_error() or
            // ctx.heap.has_error, and vm.throw_pending / vm.throw_value for
            // the vm_to_string / to_primitive coercion paths.
            vm.has_error = true;
            vm.heap.has_error = true;
            vm.heap.tval_copy_ref(&vm.heap.error_value, &ctx.throw_value);
            vm.heap.tval_copy_ref(&vm.return_val, &ctx.throw_value);
            vm.throw_pending = true;
            vm.heap.tval_copy_ref(&vm.throw_value, &ctx.throw_value);
            return undef;
        }
        return *ctx.result;
    }

    // Case 2: HObject with builtin_fn_index — dispatch via BuiltinContext
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* hobj = (HObject*)func.get_heapptr();
        hobject::CallableKind fn_kind = (hobj != null && hobj.is_callable())
            ? hobj.callable_kind() : hobject::CallableKind.OTHER;
        // BOUND_FN also dispatches through its builtin (bound_call), which
        // re-targets via needs_re_dispatch below.
        if (hobj != null && hobj.is_callable()
            && (fn_kind == hobject::CallableKind.BUILTIN_FN
                || (fn_kind == hobject::CallableKind.BOUND_FN
                    && (*hobj.extra_ptr()).func.builtin_fn_index >= 0))) {
            uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;

            // Builtins may modify callee/this via base_reg-2 and base_reg-1.
            // Layout: [callee, this, arg0, arg1, ...]
            uint total = 2 + nargs;
            if (total > 18) total = 18;

            TVal[18] temp_regs;
            temp_regs[0] = func;       // callee at index 0 (base_reg - 2)
            temp_regs[1] = this_val;   // this at index 1   (base_reg - 1)
            for (uint i = 0; i < nargs && i < 16; i++) {
                temp_regs[2 + i] = args[i];
            }

            builtins::BuiltinContext ctx;
            ctx.vm = vm;
            ctx.regs = &temp_regs;
            ctx.base_reg = 2;          // base_reg - 2 = 0 = callee, base_reg - 1 = 1 = this
            ctx.argc = (ushort)nargs;
            ctx.result = &temp_regs[0];
            ctx.heap = vm.heap;
            ctx.this_val = this_val;
            ctx.is_constructor = false;
            ctx.needs_re_dispatch = false;
            ctx.re_nargs = 0;
            ctx.global_env = vm.global_env;
            ctx.should_throw = false;
            ctx.callee_obj = hobj;

            builtins::dispatch_builtin(fn_idx, &ctx);

            if (ctx.should_throw) {
                // Propagate throw via vm.has_error so callers checking
                // vm_check_call_fn_error() or ctx.heap.has_error detect it.
                vm.has_error = true;
                vm.heap.has_error = true;
                vm.heap.tval_copy_ref(&vm.heap.error_value, &ctx.throw_value);
                vm.heap.tval_copy_ref(&vm.return_val, &ctx.throw_value);
                return undef;
            }

            if (ctx.needs_re_dispatch) {
                // Builtin (e.g., generator .next()) modified the callee/this and
                // expects the call to be re-dispatched.
                func = temp_regs[0];
                this_val = temp_regs[1];
                // Rebuild args from temp_regs[2..] with the re-dispatched nargs
                uint new_nargs = ctx.re_nargs;
                for (uint i = 0; i < new_nargs && i < 16; i++) {
                    if (2 + i < 18) args[i] = temp_regs[2 + i];
                }
                nargs = new_nargs;
                // Fall through to Case 3
            } else {
                return *ctx.result;
            }
        }
    }

    // Case 3: compiled function on HObject
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* hobj = (HObject*)func.get_heapptr();
        if (hobj != null && hobj.is_callable() && (*hobj.extra_ptr()).func.comp_func != null) {
            CompiledFunction* target = (*hobj.extra_ptr()).func.comp_func;
            uint nregs = target.num_regs;

            // Compute the true top of the current activation's register file.
            // vm.valstack_top is NOT updated for inline JS-to-JS calls (the
            // CALL fast path in dispatch_calls skips the update), so it may
            // point below the current function's full register space, causing
            // the callee frame to overlap live caller registers.
            TVal* true_top = vm.valstack_top;
            if (vm.activation_count > 0) {
                Activation* cur_act = &vm.activations[vm.activation_count - 1];
                CompiledFunction* cur_func = (CompiledFunction*)cur_act.func;
                if (cur_func != null) {
                    TVal* act_top = cur_act.bottom + cur_func.num_regs;
                    if (act_top > true_top) true_top = act_top;
                }
            }

            // Grow the valstack first (while activation_count is still the
            // caller's, so ensure_valstack_grow relocates all live pointers).
            // The callback frame is placed above all live caller registers.
            uint true_used = (uint)(true_top - vm.valstack);
            if (true_top + nregs > vm.valstack_end) {
                if (!ensure_valstack_grow(vm, true_used + nregs - (uint)(vm.valstack_top - vm.valstack))) {
                    return undef;
                }
                // Recompute true_top after potential realloc
                if (vm.activation_count > 0) {
                    Activation* cur_act2 = &vm.activations[vm.activation_count - 1];
                    CompiledFunction* cur_func2 = (CompiledFunction*)cur_act2.func;
                    if (cur_func2 != null) {
                        TVal* act_top2 = cur_act2.bottom + cur_func2.num_regs;
                        true_top = (act_top2 > vm.valstack_top) ? act_top2 : vm.valstack_top;
                    } else {
                        true_top = vm.valstack_top;
                    }
                } else {
                    true_top = vm.valstack_top;
                }
            }

            // Save current VM state (after potential realloc)
            uint saved_act_count = vm.activation_count;
            TVal* saved_valstack_bottom = vm.valstack_bottom;
            TVal* saved_valstack_top = vm.valstack_top;
            TVal* saved_valstack = vm.valstack;
            CompiledFunction* saved_current_func = vm.current_func;
            void* saved_resume_gen = saved_resume_gen_outer;  // captured before Case 1/2 could overwrite it

            Activation[MAX_CALLS] saved_acts;
            mem::copy(&saved_acts, &vm.activations, (sz)(saved_act_count * Activation::size));

            // Zero out activation slots 1..saved_act_count-1.  The outer
            // activations are safely stored in saved_acts.  The live slots
            // must be cleared so that when the inner run's inline CALL writes
            // a new this_binding into slot 1 (via tval_copy_ref), it decrefs
            // undefined (no-op) rather than the stale global-object reference
            // left behind by the outer activation's memcpy bits.
            if (saved_act_count > 1) {
                mem::clear(&vm.activations[1], (sz)((usz)(saved_act_count - 1) * Activation::size));
            }

            TVal* frame = true_top;

            // Set up activation[0] for the function
            Activation* act = &vm.activations[0];
            vm.activation_count = 1;
            EnvRecord* cfn_var_env = (*hobj.extra_ptr()).func.var_env;
            if (try fv_cfn = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { cfn_var_env = fv_cfn; }
            act.func = target;
            act.parent = null;
            act.var_env = cfn_var_env;
            act.lex_env = resolve_call_lex_env(vm, hobj, target, cfn_var_env);
            act.cat = null;
            act.curr_pc = target.code;
            act.async_promise = null;
            act.async_gen_state = null;

            // Check for generator/async resume: if heap.resume_gen is set
            // and matches this function, restore the saved PC and registers.
            bool did_resume = false;
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs_r = vm.heap.resume_gen;
                if ((CompiledFunction*)gs_r.func == target) {
                    did_resume = true;
                    act.async_gen_state = gs_r;
                    act.curr_pc = (Instruction*)gs_r.saved_pc;
                    act.var_env = (EnvRecord*)gs_r.var_env;
                    act.lex_env = (EnvRecord*)gs_r.lex_env;
                    act.cat = gs_r.cat;
                    // Restore saved registers instead of initializing fresh
                    $if $feature(HEAP_VERIFY):
                        vm.heap.verify_roots("before_resume_restore");
                        if (gs_r.saved_regs != null) {
                            vm.heap.verify_tval_array(gs_r.saved_regs, gs_r.num_regs, "resume_saved_regs");
                        }
                    $endif
                    for (uint i = 0; i < nregs; i++) {
                        if (gs_r.saved_regs != null) {
                            vm.heap.tval_copy_ref(&frame[i], &gs_r.saved_regs[i]);
                        } else {
                            frame[i].set_undefined();
                        }
                    }
                    // Put the resume value into register 0 (LOAD_RESUME will read it)
                    // The resume value is read by LOAD_RESUME from gs_r.resume_value
                    // into the A operand register, so no need to pre-populate frame[0].
                    // vm.heap.tval_copy_ref(&frame[0], &gs_r.resume_value);
                    // Propagate async context so RET can settle the async Promise
                    if (gs_r.async_promise != null) {
                        act.flags |= ACT_FLAG_ASYNC;
                        act.async_promise = (hobject::HObject*)gs_r.async_promise;
                    }
                    // Note: this_binding is set below (after this block).
                    // For generator resumes via call_fn, this_val is the generator
                    // object (from .next()), but the generator's actual 'this' is
                    // in gs_r.this_binding. We restore it after cfn_is_gen_initial is
                    // determined (the restore is conditional on cfn_is_gen_initial=false
                    // and only applied for generators that use 'this' inside their body).
                    // [Restored below in the this_binding section]
                    $if $feature(HEAP_VERIFY):
                        vm.heap.verify_roots("after_resume_restore");
                    $endif
                }
            }

            act.bottom = frame;
            // Preserve any flags already set (e.g. ACT_FLAG_ASYNC for resumed async fns)
            uint preserved_flags = act.flags;
            act.flags = (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0)
                      | preserved_flags;
            act.max_heap_reg = 0;
            act.caller_valstack_top = frame + nregs;
            // Set this_binding. For generator resumes via call_fn where the initial
            // call was also via call_fn (i.e. cfn_is_gen_initial was true for the
            // creation call), the generator's saved this_binding must be restored.
            // For all other cases, use this_val (the passed-in receiver).
            // Set this_binding for the activation.
            // For generator resumes via call_fn, this_val is the generator object
            // (the receiver of .next()), but the generator's actual 'this' is saved
            // in gs_r.this_binding. Restore it directly to avoid running the generator
            // body with the wrong 'this' (e.g. Boolean.prototype[Symbol.iterator] needs
            // this=true/false, not the generator object).
            // IMPORTANT: use a raw assign (no tval_copy_ref) because act.this_binding
            // still contains stale bits from the previous occupant of vm.activations[0].
            // Using tval_copy_ref would incorrectly decref those stale bits.
            if (did_resume && vm.heap.resume_gen != null) {
                GeneratorState* gs_rb2 = vm.heap.resume_gen;
                if (!gs_rb2.this_binding.is_undefined() && !gs_rb2.this_binding.is_null()) {
                    // Restore the generator's saved 'this' (e.g. boolean true/false for
                    // Boolean.prototype[Symbol.iterator] generators).
                    act.this_binding = gs_rb2.this_binding;  // raw copy, no stale-decref
                } else {
                    // Generator was created with undefined/null this — apply ES5 §10.4.3.
                    if (!target.is_arrow() && !target.is_strict()
                        && vm.global_env != null && vm.global_env.bindings != null) {
                        this_val.set_object(vm.global_env.bindings);
                    }
                    act.this_binding = this_val;
                }
            } else if (target.is_arrow()) {
                // Arrow functions have no receiver of their own — `this` is
                // lexically inherited from the enclosing scope, captured once
                // at CLOSURE-creation time (§9.2.1 [[ThisMode]]=lexical), not
                // from the caller-supplied this_val (which for a call routed
                // through a builtin, e.g. Array.prototype.map's thisArg or an
                // iterator's ITER_CLOSE-driven .return(), is unrelated to the
                // arrow's defining scope). Exception: a still-TDZ captured
                // value (arrow defined before super() ran in a derived
                // constructor) must be re-resolved live from the immediate
                // caller — see super_walk_live_this().
                TVal arrow_this = (*hobj.extra_ptr()).func.captured_this;
                if (env::is_tdz_sentinel(&arrow_this) && saved_act_count > 0) {
                    arrow_this = super_walk_live_this(vm, &saved_acts[saved_act_count - 1]);
                }
                act.this_binding = arrow_this;
            } else {
                // Non-resume: ES5 §10.4.3 — substitute global object for undefined/null this.
                if (!target.is_strict()
                    && (this_val.is_undefined() || this_val.is_null())
                    && vm.global_env != null && vm.global_env.bindings != null) {
                    this_val.set_object(vm.global_env.bindings);
                }
                // Raw assign: this_val is kept alive by the caller for the duration
                // of the call; the previous activation[0].this_binding bits are
                // restored verbatim below, so refcounts stay balanced.
                act.this_binding = this_val;
            }

            // For the initial (non-resume) call to a generator function, set up
            // gen_initial_gs / gen_initial_obj so GEN_START can find them.
            // vm.heap.gen_initial_gs may already be set (from the inline CALL opcode)
            // — only allocate when it isn't so we don't double-allocate.
            void* cfn_saved_gen_initial_gs  = vm.heap.gen_initial_gs;
            void* cfn_saved_gen_initial_obj = vm.heap.gen_initial_obj;
            void* cfn_saved_gen_initial_rv  = vm.heap.gen_initial_retval;
            TVal cfn_gen_result_slot; cfn_gen_result_slot.set_undefined();
            bool cfn_is_gen_initial = false;
            if (!did_resume && target.is_generator() && !target.is_async()
                && vm.heap.gen_initial_gs == null) {
                void* cfn_gs_raw = vm.heap.alloc_func(vm.heap.heap_udata, GeneratorState::size);
                if (cfn_gs_raw != null) {
                    mem::clear(cfn_gs_raw, (sz)(GeneratorState::size));
                    GeneratorState* cfn_gs = (GeneratorState*)cfn_gs_raw;
                    cfn_gs.pending_resume_reg = 0xFFFF;
                    cfn_gs.func = target;
                    cfn_gs.func_obj = hobj;
                    cfn_gs.num_regs = target.num_regs;
                    usz cfn_regs_bytes = (usz)target.num_regs * TVal::size;
                    void* cfn_regs_raw = (cfn_regs_bytes > 0)
                        ? vm.heap.alloc_func(vm.heap.heap_udata, cfn_regs_bytes)
                        : null;
                    if (cfn_regs_bytes > 0 && cfn_regs_raw == null) {
                        vm.heap.free_func(vm.heap.heap_udata, cfn_gs_raw);
                    } else {
                        if (cfn_regs_raw != null) mem::clear(cfn_regs_raw, (sz)(cfn_regs_bytes));
                        cfn_gs.saved_regs = (TVal*)cfn_regs_raw;
                        HObject*? cfn_gen_obj_raw = vm.heap.alloc_object(hobject::ObjClass.GENERATOR);
                        if (try cfn_gen_obj = cfn_gen_obj_raw) {
                            // ES2015 §25.3.3 step 1: OrdinaryCreateFromConstructor(
                            // functionObject, "%GeneratorPrototype%"). Deferred to
                            // GEN_START (see vm_calls.c3's matching comment) so a
                            // default-parameter side effect on functionObject.prototype
                            // is observed; default to the shared Generator.prototype
                            // here, corrected by GEN_START if needed.
                            cfn_gen_obj.prototype = vm.heap.generator_proto;
                            (*cfn_gen_obj.extra_ptr()).gen.generator_data = cfn_gs;
                            vm.heap.gen_initial_gs  = cfn_gs;
                            vm.heap.gen_initial_obj = cfn_gen_obj;
                            // Point gen_initial_retval at our local slot so GEN_START
                            // can write the generator object. act.retval is also set to
                            // this slot so GEN_START's ds.act.retval check succeeds.
                            vm.heap.gen_initial_retval = &cfn_gen_result_slot;
                            cfn_is_gen_initial = true;
                        } else {
                            vm.heap.free_func(vm.heap.heap_udata, cfn_regs_raw);
                            vm.heap.free_func(vm.heap.heap_udata, cfn_gs_raw);
                        }
                    }
                }
            }

            act.retval = cfn_is_gen_initial ? &cfn_gen_result_slot : null;

            if (!did_resume) {
                for (uint i = 0; i < nregs; i++) {
                    frame[i].set_undefined();
                }
                if (target.has_rest()) {
                    // Copy the fixed (pre-rest) formals first.
                    uint copy_count = (uint)target.num_formals;
                    uint copy_n = nargs < copy_count ? nargs : copy_count;
                    for (uint i = 0; i < copy_n; i++) {
                        vm.heap.tval_copy_ref(&frame[i], &args[i]);
                    }
                    // Build the rest array from remaining args.
                    uint rest_idx = copy_count;
                    uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;
                    HObject*? arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                    if (try arr = arr_raw) {
                        arr.prototype = vm.heap.array_proto;
                        for (uint i = 0; i < overflow; i++) {
                            arr.set_array_idx(i, args[copy_count + i]);
                        }
                        HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                        TVal len_tv;
                        len_tv.set_fastint((long)overflow);
                        if (len_str != null) arr.put_prop(len_str, len_tv, hobject::PROP_FLAGS_WEC);
                        frame[rest_idx].set_object(arr);
                    }
                } else {
                    uint copy_n = nargs < nregs ? nargs : nregs;
                    for (uint i = 0; i < copy_n; i++) {
                        vm.heap.tval_copy_ref(&frame[i], &args[i]);
                    }
                }
            }
            vm.valstack_top = frame + nregs;
            vm.valstack_bottom = frame;
            vm.current_func = target;

            // Create arguments object if the function references 'arguments'
            if (target.uses_arguments()) {
                HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                if (try args_obj = args_obj_raw) {
                    // Store arguments in dense array_part (avoids O(argc) string key allocs).
                    // Read from the original args[] array (not frame[]) so arguments
                    // beyond num_regs are included when nargs > nregs.
                    for (uint ai = 0; ai < nargs; ai++) {
                        args_obj.set_array_idx(ai, args[ai]);
                    }
                    // ES5 §10.6: [[Prototype]] is Object.prototype
                    args_obj.prototype = vm.heap.object_proto;
                    // ES5 §10.6: define 'callee' property (writable, non-enumerable, configurable)
                    HString* callee_key = (HString*)vm.heap.strs[heap::BuiltinStr.CALLEE];
                    if (callee_key != null) {
                        TVal callee_tv;
                        callee_tv.set_object(hobj);
                        args_obj.put_prop(callee_key, callee_tv, hobject::PROP_FLAGS_WC);
                    }
                    // ES5 §10.6: define 'length' property (writable, non-enumerable, configurable)
                    HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    if (length_key != null) {
                        TVal length_tv;
                        length_tv.set_fastint((long)nargs);
                        args_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
                    }
                    // Declare 'arguments' in the function's var_env
                    HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                    if (args_name != null) {
                        TVal args_tv;
                        args_tv.set_object(args_obj);
                        env::env_declare(act.var_env, args_name, args_tv);
                    }
                }
            }

            // Register saved outer activations in the shadow frame list so that GC
            // (triggered during the inner Vm.run()) can mark their env bindings and
            // keep them alive.  The shadow frame is stack-allocated and is valid for
            // the lifetime of this vm_call_fn_impl invocation.
            ShadowActFrame shadow_frame;
            shadow_frame.prev = vm.shadow_act_list;
            shadow_frame.acts = &saved_acts;
            shadow_frame.count = saved_act_count;
            vm.shadow_act_list = &shadow_frame;

            // Run the function via Vm.run (skip Vm.execute init — we already set up state)
            TVal? result_opt = Vm.run(vm);
            TVal result;
            if (try r = result_opt) {
                result = r;
            } else {
                result = vm.return_val;
            }

            // Deregister the shadow frame now that the inner Vm.run() has returned.
            vm.shadow_act_list = shadow_frame.prev;
            // If the nested run reallocated the valstack, relocate the saved
            // absolute pointers by the same delta (the saved snapshot was not
            // covered by ensure_valstack_grow's relocation pass).
            long reloc = (char*)vm.valstack - (char*)saved_valstack;
            if (reloc != 0) {
                saved_valstack_bottom = (TVal*)((char*)saved_valstack_bottom + reloc);
                saved_valstack_top = (TVal*)((char*)saved_valstack_top + reloc);
                for (uint i = 0; i < saved_act_count; i++) {
                    saved_acts[i].bottom = (TVal*)((char*)saved_acts[i].bottom + reloc);
                    if (saved_acts[i].retval != null) {
                        saved_acts[i].retval = (TVal*)((char*)saved_acts[i].retval + reloc);
                    }
                    if (saved_acts[i].caller_valstack_top != null) {
                        saved_acts[i].caller_valstack_top = (TVal*)((char*)saved_acts[i].caller_valstack_top + reloc);
                    }
                }
            }

            // Restore VM state (caller registers were never touched)
            vm.activation_count = saved_act_count;
            vm.current_func = saved_current_func;
            mem::copy(&vm.activations, &saved_acts, (sz)(saved_act_count * Activation::size));
            vm.valstack_bottom = saved_valstack_bottom;
            vm.valstack_top = saved_valstack_top;
            vm.heap.resume_gen = (GeneratorState*)saved_resume_gen;  // restore after nested generator

            // Restore gen_initial state in case GEN_START didn't clear it
            // (e.g. if the body threw before reaching GEN_START).
            vm.heap.gen_initial_gs      = cfn_saved_gen_initial_gs;
            vm.heap.gen_initial_obj     = cfn_saved_gen_initial_obj;
            vm.heap.gen_initial_retval  = cfn_saved_gen_initial_rv;

            // For generator initial calls, the generator object was written into
            // cfn_gen_result_slot by GEN_START and returned as halt_value.
            if (cfn_is_gen_initial && cfn_gen_result_slot.is_object()
                && cfn_gen_result_slot.get_heapptr() != null) {
                result = cfn_gen_result_slot;
            }

            // Drain microtasks after callback execution
            vm.heap.drain_microtasks((void*)vm);

            return result;
        }
    }

    return undef;
}

// trace_print_tval and trace_instruction are now in vm_trace.c3.

/// Implementation of Heap.call_handler_fn — delegates to vm_call_fn_impl.
fn TVal vm_call_handler_fn_impl(void* vm_ptr, TVal handler, TVal* arg) {
    TVal undef;
    undef.set_undefined();
    return vm_call_fn_impl(vm_ptr, handler, arg, 1, undef);
}

/// Implementation of Heap.construct_fn — `new Fn(args)` semantics.
/// Allocates a fresh this, runs the constructor with ACT_FLAG_CONSTRUCT,
/// and returns the resulting instance.  Used by Promise combinators for
/// NewPromiseCapability(C).
fn TVal vm_construct_fn_impl(void* vm_ptr, TVal func, TVal* args, uint nargs, TVal new_target) {
    Vm* vm = (Vm*)vm_ptr;
    TVal undef;
    undef.set_undefined();
    if (vm == null) return undef;
    Heap* heap = vm.heap;

    // Save resume_gen before any dispatch below runs — a builtin constructor
    // dispatched further down can itself set vm.heap.resume_gen for its own
    // callee before this function's own save point, corrupting the caller's
    // resume state once restored. See vm_call_fn_impl for the same fix.
    void* saved_resume_gen_outer2 = vm.heap.resume_gen;

    // Lightfuncs can't be constructors.
    if (func.is_lightfunc()) return undef;
    if (!func.is_object() || func.get_heapptr() == null) return undef;
    HObject* ctor = (HObject*)func.get_heapptr();
    if (ctor == null || !ctor.flags.callable) return undef;

    // Determine the new.target object. Reflect.construct may supply a different
    // constructor; ordinary `new` calls pass the callee itself.
    HObject* new_target_obj = ctor;
    if (new_target.is_object() && new_target.get_heapptr() != null) {
        new_target_obj = (HObject*)new_target.get_heapptr();
    }

    // Bound function [[Construct]] (ES2015 §9.4.1.2):
    //   5. If SameValue(F, newTarget) is true, let newTarget be target.
    //   6. Return ? Construct(target, args, newTarget).
    // Without the unwrap, a plain `new bound()` would pass the bound function
    // itself as new.target and ordinary `Reflect.construct(bound, [], X)` would
    // not retarget to the underlying target when X === bound.
    if (ctor.flags.is_bound) {
        // Intern the bound-target key on demand. Using builtin_intern_string
        // (not Heap.strs[]) keeps this self-contained — strs[] entries are
        // pinned at vm_create, so a new BuiltinStr slot would need
        // init_builtin_strs() changes too. The string is short and shared
        // across all bound functions, so intern churn is negligible.
        HString* key_downstream = builtins::builtin_intern_string(heap,
            { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'a', 'r', 'g', 'e', 't' });
        if (key_downstream == null) return undef;
        int di = ctor.find_prop_idx(key_downstream);
        if (di < 0) return undef;  // malformed bound fn
        TVal target_tv = ctor.prop_values()[di];
        TVal target_as_new = new_target;
        // SameValue(F, newTarget): if the caller passed the bound fn itself
        // as newTarget, swap it for the underlying target so downstream's
        // `new.target` reflects the original target.
        TVal f_as_tv; f_as_tv.set_object(ctor);
        if (builtins::same_value(f_as_tv, new_target)) {
            target_as_new = target_tv;
        }
        return vm_construct_fn_impl(vm_ptr, target_tv, args, nargs, target_as_new);
    }

    // Allocate a fresh plain object as `this`.
    // GetPrototypeFromConstructor(new_target, "%Object.prototype%") — ES2022
    // §9.1.14: read new_target.prototype; if it isn't an object, fall back to
    // the default intrinsic (heap.object_proto) rather than always using it.
    HObject*? new_this_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err_t = new_this_raw) return undef;
    HObject* new_this = new_this_raw;
    new_this.prototype = heap.object_proto;
    HString* ctor_proto_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    if (ctor_proto_key != null) {
        if (try proto_tv = new_target_obj.get_prop_proto(ctor_proto_key)) {
            if (proto_tv.is_object() && proto_tv.get_heapptr() != null) {
                new_this.prototype = (HObject*)proto_tv.get_heapptr();
            }
        }
    }
    TVal this_tv;
    this_tv.set_object(new_this);

    // HObjectProxy.target overlays HObjectFunction.comp_func (both offset 0),
    // so reading comp_func directly on a Proxy exotic object would reinterpret
    // its [[ProxyTarget]] pointer as a CompiledFunction*. Route Proxies (and
    // any other BUILTIN_FN) through the builtin-dispatch branch below instead.
    CompiledFunction* target = ctor.callable_kind() == hobject::CallableKind.BUILTIN_FN
        ? null : (*ctor.extra_ptr()).func.comp_func;
    // Derived class constructors (`class X extends Y`) do NOT create `this`
    // here — super() creates it inside the base [[Construct]] (ES2015 §9.2.2
    // step 5). Start with an uninitialized (TDZ-sentinel) this_binding and mark
    // the activation DERIVED so SUPER_CALL initializes it; otherwise the
    // constructed instance (e.g. a Promise subclass) is lost and combinator
    // capabilities read back as uninitialized.
    bool is_derived_target = (target != null && target.is_derived_ctor());
    if (is_derived_target) {
        this_tv = env::tdz_sentinel();
    }
    // Note: target == null is the correct signal for "not a compiled
    // function" (e.g. a built-in). A compiled function with num_regs == 0
    // (empty body, no locals/params referenced) is still a real constructor
    // and must run through the compiled-function activation path below —
    // routing it into the builtin-dispatch branch here would silently no-op
    // any user constructor with an empty or trivial body.
    if (target == null) {
        // Built-in constructor — dispatch directly. Bound functions also
        // dispatch through builtin_fn_index (Builtin.BOUND_CALL.ordinal), so route
        // them through the same builtin-dispatch path as BUILTIN_FN.
        if (ctor.callable_kind() == hobject::CallableKind.BUILTIN_FN
            || ctor.callable_kind() == hobject::CallableKind.BOUND_FN) {
            int builtin_idx = (*ctor.extra_ptr()).func.builtin_fn_index;
            // For Promise, allocate as PROMISE class so builtin_promise
            // initialises the right internal slots.
            if (builtin_idx == (int)builtins::Builtin.PROMISE.ordinal) {
                HObject*? prom_this_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
                if (catch err_p = prom_this_raw) return undef;
                HObject* prom_this = prom_this_raw;
                prom_this.prototype = heap.promise_proto;
                builtins::promise_init(prom_this);
                this_tv.set_object(prom_this);
                new_this = prom_this;
            }
            TVal[18] temp_regs;
            temp_regs[0] = func;
            temp_regs[1] = this_tv;
            for (uint i = 0; i < nargs && i < 16; i++) {
                temp_regs[2 + i] = args[i];
            }
            builtins::BuiltinContext bctx;
            bctx.vm = vm;
            bctx.regs = &temp_regs;
            bctx.base_reg = 2;
            bctx.argc = (ushort)nargs;
            bctx.result = &temp_regs[0];
            bctx.heap = heap;
            bctx.this_val = this_tv;
            bctx.is_constructor = true;
            bctx.needs_re_dispatch = false;
            bctx.re_nargs = 0;
            bctx.global_env = vm.global_env;
            bctx.should_throw = false;
            bctx.callee_obj = ctor;
            bctx.new_target = new_target_obj;
            builtins::dispatch_builtin((uint)builtin_idx, &bctx);
            if (bctx.should_throw) {
                vm.has_error = true;
                vm.heap.has_error = true;
                vm.heap.tval_copy_ref(&vm.heap.error_value, &bctx.throw_value);
                vm.heap.tval_copy_ref(&vm.return_val, &bctx.throw_value);
                return undef;
            }
            if (bctx.needs_re_dispatch) {
                // Bound function whose downstream target is a compiled function
                // (or another non-directly-dispatchable callable): builtin_bound_call
                // placed the resolved downstream callee/args in temp_regs and asked
                // for a re-dispatch. ES2015 §9.4.1.2 BoundFunctionExoticObject.[[Construct]]:
                // Construct(BoundTargetFunction, args, newTarget === F ? BoundTargetFunction : newTarget).
                TVal downstream_func = temp_regs[0];
                TVal downstream_new_target = (new_target_obj == ctor) ? downstream_func : new_target;
                uint new_nargs = bctx.re_nargs;
                TVal[16] fwd_args;
                for (uint i = 0; i < new_nargs && i < 16; i++) {
                    fwd_args[i] = temp_regs[2 + i];
                }
                return vm_construct_fn_impl(vm_ptr, downstream_func, &fwd_args, new_nargs, downstream_new_target);
            }
            TVal result = *bctx.result;
            if (result.is_object()) return result;
            if (result.is_undefined()) return this_tv;
            return result;
        }
        return undef;
    }

    // Compiled user-defined function: set up a constructor activation.
    uint nregs = target.num_regs;
    if (vm.activation_count >= MAX_CALLS) return undef;
    if (!vm.valstack_top || !vm.valstack) return undef;
    uint needed_slots = (uint)((char*)vm.valstack_top - (char*)vm.valstack) / TVal::size + nregs;
    if (needed_slots > vm.valstack_size / TVal::size) {
        if (!ensure_valstack(vm, needed_slots)) return undef;
    }

    // Save current VM state for restoration after the constructor returns.
    uint saved_act_count = vm.activation_count;
    TVal* saved_valstack_bottom = vm.valstack_bottom;
    TVal* saved_valstack_top = vm.valstack_top;
    TVal* saved_valstack = vm.valstack;
    CompiledFunction* saved_current_func = vm.current_func;
    void* saved_resume_gen = saved_resume_gen_outer2;  // captured before the builtin-constructor dispatch above could overwrite it

    Activation[MAX_CALLS] saved_acts;
    mem::copy(&saved_acts, &vm.activations, (sz)(saved_act_count * Activation::size));

    // Zero out activation slots 1..saved_act_count-1 (same as vm_call_fn_impl):
    // prevents tval_copy_ref in the inner run's inline CALLs from decreffing
    // stale this_binding values left in these slots by the outer activations.
    if (saved_act_count > 1) {
        mem::clear(&vm.activations[1], (sz)((usz)(saved_act_count - 1) * Activation::size));
    }

    TVal* frame = vm.valstack_top;
    vm.activation_count = 1;
    Activation* act = &vm.activations[0];

    EnvRecord* cfn_var_env = (*ctor.extra_ptr()).func.var_env;
    if (try fv_cfn = env::env_create_function_scope(heap, (*ctor.extra_ptr()).func.var_env)) {
        cfn_var_env = fv_cfn;
    }
    act.func = target;
    act.parent = null;
    act.var_env = cfn_var_env;
    act.lex_env = resolve_call_lex_env(vm, ctor, target, cfn_var_env);
    act.cat = null;
    act.curr_pc = target.code;
    act.async_promise = null;
    act.async_gen_state = null;
    act.bottom = frame;
    act.retval = null;
    act.flags = ACT_FLAG_CONSTRUCT
              | (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0)
              | (is_derived_target ? ACT_FLAG_DERIVED : 0);
    act.max_heap_reg = 0;
    act.caller_valstack_top = frame + nregs;
    act.this_binding = this_tv;
    act.new_target = new_target_obj;

    for (uint i = 0; i < nregs; i++) {
        frame[i].set_undefined();
    }
    uint copy_n = nargs < nregs ? nargs : nregs;
    for (uint i = 0; i < copy_n; i++) {
        vm.heap.tval_copy_ref(&frame[i], &args[i]);
    }
    // Rest parameter: collect overflow args (indices num_formals..nargs-1) into
    // an array in the rest slot, mirroring the normal call path. Without this a
    // rest-param function invoked through construct_fn (e.g. a derived class's
    // implicit `constructor(...args){ super(...args); }`) sees the raw first arg
    // in the rest slot instead of an array, so `super(...args)` forwards nothing
    // and the base constructor's executor never runs.
    if (target.has_rest()) {
        uint formals = (uint)target.num_formals;
        uint rest_idx = formals;
        uint overflow = (nargs > formals) ? (nargs - formals) : 0;
        if (rest_idx < nregs) {
            HObject*? rest_arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try rest_arr = rest_arr_raw) {
                rest_arr.prototype = vm.heap.array_proto;
                for (uint ri = 0; ri < overflow; ri++) {
                    if (rest_idx + ri < nregs) {
                        HString* rkey = vm.heap.int_to_hstring((long)ri);
                        if (rkey != null) {
                            rest_arr.put_prop(rkey, frame[rest_idx + ri], hobject::PROP_FLAGS_WEC);
                        }
                    }
                }
                HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_val; len_val.set_fastint((long)overflow);
                rest_arr.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);
                frame[rest_idx].set_object(rest_arr);
            } else {
                frame[rest_idx].set_undefined();
            }
        }
    }
    if (target.uses_arguments()) {
        HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
        if (try args_obj = args_obj_raw) {
            for (uint ai = 0; ai < nargs; ai++) {
                args_obj.set_array_idx(ai, frame[ai]);
            }
            args_obj.prototype = vm.heap.object_proto;
            HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
            if (length_key != null) {
                TVal length_tv;
                length_tv.set_fastint((long)nargs);
                args_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
            }
            // Declare `arguments` in the function's var_env so the body can access it.
            HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
            if (args_name != null) {
                TVal args_tv;
                args_tv.set_object(args_obj);
                env::env_declare(cfn_var_env, args_name, args_tv);
            }
        }
    }

    vm.valstack_top = frame + nregs;
    vm.valstack_bottom = frame;
    vm.current_func = target;

    TVal? result_opt = Vm.run(vm);
    TVal result;
    if (try r = result_opt) {
        result = r;
    } else {
        result = vm.return_val;
    }

    // ES6 §12.3.5.2: if constructor returns an object, that's the new instance.
    // For a derived constructor `this_tv` started as the TDZ sentinel; the real
    // instance was bound by super() into the activation's this_binding, so read
    // it back from there (act still points at vm.activations[0], pre-restore).
    TVal final_this = this_tv;
    if (is_derived_target) {
        final_this = act.this_binding;
    }
    if (result.is_object() && result.get_heapptr() != null) {
        final_this = result;
    }

    // Relocate saved pointers if valstack moved during the constructor run.
    long reloc = (char*)vm.valstack - (char*)saved_valstack;
    if (reloc != 0) {
        saved_valstack_bottom = (TVal*)((char*)saved_valstack_bottom + reloc);
        saved_valstack_top = (TVal*)((char*)saved_valstack_top + reloc);
        for (uint i = 0; i < saved_act_count; i++) {
            saved_acts[i].bottom = (TVal*)((char*)saved_acts[i].bottom + reloc);
            if (saved_acts[i].retval != null) {
                saved_acts[i].retval = (TVal*)((char*)saved_acts[i].retval + reloc);
            }
            if (saved_acts[i].caller_valstack_top != null) {
                saved_acts[i].caller_valstack_top = (TVal*)((char*)saved_acts[i].caller_valstack_top + reloc);
            }
        }
    }

    // Restore VM state.
    vm.activation_count = saved_act_count;
    vm.current_func = saved_current_func;
    mem::copy(&vm.activations, &saved_acts, (sz)(saved_act_count * Activation::size));
    vm.valstack_bottom = saved_valstack_bottom;
    vm.valstack_top = saved_valstack_top;
    vm.heap.resume_gen = (GeneratorState*)saved_resume_gen;

    vm.heap.drain_microtasks((void*)vm);
    return final_this;
}

fn TVal? Vm.execute(Vm* vm, CompiledFunction* func) {
    // Set up initial activation (matches outer executor setup)
    Activation* entry_act = &vm.activations[0];
    vm.activation_count = 1;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = vm.global_env;
    entry_act.lex_env = vm.global_lex_env != null ? vm.global_lex_env : vm.global_env;
    entry_act.cat = null;
    entry_act.curr_pc = func.code;  // Points into bytecode
    entry_act.bottom = vm.valstack;
    entry_act.retval = null;
    entry_act.flags = 0;
    if (func.has_direct_eval()) {
        entry_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }

    // ES5 §10.4.1: global `this` is the global object for non-strict scripts.
    TVal this_val;
    if (vm.global_env != null && vm.global_env.bindings != null) {
        this_val.set_object(vm.global_env.bindings);
    } else {
        this_val.set_undefined();
    }
    vm.heap.tval_copy_ref(&entry_act.this_binding, &this_val);

    // Allocate value stack slots for the function (nregs = total register count)
    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        return VM_ERROR~;
    }

    // Initialize registers to undefined
    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].set_undefined();
    }
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = vm.valstack;
    // The top-level activation has no caller, but caller_valstack_top must be
    // set to a valid value so that RET restoring back to this activation
    // (after a compiled callee returns) doesn't corrupt vm.valstack_top.
    entry_act.caller_valstack_top = vm.valstack_top;

    vm.current_func = func;

    TVal? result = Vm.run(vm);

    // Drain microtask queue after top-level script execution
    vm.heap.drain_microtasks((void*)vm);

    return result;
}

/// Execute a compiled function with a specific environment (for ESM modules).
/// Same as execute() but uses the provided env for var_env/lex_env instead
/// of the global environment.
fn TVal? Vm.execute_in_env(Vm* vm, CompiledFunction* func, EnvRecord* env) {
    Activation* entry_act = &vm.activations[0];
    vm.activation_count = 1;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = env;
    entry_act.lex_env = env;
    entry_act.cat = null;
    entry_act.curr_pc = func.code;
    entry_act.bottom = vm.valstack;
    entry_act.retval = null;
    entry_act.flags = 0;
    if (func.has_direct_eval()) {
        entry_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }

    TVal this_val;
    if (vm.global_env != null && vm.global_env.bindings != null) {
        this_val.set_object(vm.global_env.bindings);
    } else {
        this_val.set_undefined();
    }
    vm.heap.tval_copy_ref(&entry_act.this_binding, &this_val);

    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        return VM_ERROR~;
    }

    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].set_undefined();
    }
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = vm.valstack;
    entry_act.caller_valstack_top = vm.valstack_top;

    vm.current_func = func;

    TVal? result = Vm.run(vm);

    vm.heap.drain_microtasks((void*)vm);

    return result;
}

/// Execute a module body that may contain top-level await, as an async
/// activation. Allocates the module's evaluation Promise, marks the entry
/// activation ACT_FLAG_ASYNC, runs the body (which suspends on top-level
/// `await` via the same machinery as async functions), then drives the
/// microtask queue until the promise settles.
///
/// Returns true if the module evaluated to completion (promise fulfilled or
/// still pending with an empty queue — treated as success). Returns false if
/// the module's evaluation promise REJECTED; in that case the rejection reason
/// is left in heap.error_value so the caller surfaces it as the module's
/// uncaught error. Returns a fault only on hard setup failure.
fn bool? Vm.execute_module_async(Vm* vm, CompiledFunction* func, EnvRecord* env) {
    // Allocate the module evaluation Promise up front so top-level await can
    // suspend into it and RET can settle it.
    HObject*? prom_raw = vm.heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return err~;
    HObject* mod_promise = prom_raw;
    mod_promise.prototype = vm.heap.promise_proto;
    builtins::promise_init(mod_promise);
    // Pin it across the evaluation + microtask drain so GC can't sweep it
    // (transient — released before returning).
    mod_promise.as_header().incref();

    Activation* entry_act = &vm.activations[0];
    vm.activation_count = 1;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = env;
    entry_act.lex_env = env;
    entry_act.cat = null;
    entry_act.curr_pc = func.code;
    entry_act.bottom = vm.valstack;
    entry_act.retval = null;
    entry_act.flags = ACT_FLAG_ASYNC;
    if (func.has_direct_eval()) {
        entry_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }
    entry_act.async_promise = mod_promise;
    entry_act.async_gen_state = null;

    TVal this_val;
    if (vm.global_env != null && vm.global_env.bindings != null) {
        this_val.set_object(vm.global_env.bindings);
    } else {
        this_val.set_undefined();
    }
    vm.heap.tval_copy_ref(&entry_act.this_binding, &this_val);

    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        vm.heap.decref(mod_promise.as_header());
        return VM_ERROR~;
    }
    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].set_undefined();
    }
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = vm.valstack;
    entry_act.caller_valstack_top = vm.valstack_top;

    vm.current_func = func;

    // Run the body. If it completes synchronously, RET settles mod_promise
    // (fulfilled) or a throw rejects it. If it suspends on top-level await,
    // Vm.run returns and the reactions run during the drain below, eventually
    // settling mod_promise.
    (void)Vm.run(vm);
    // Clear a synchronous throw: for an async body a thrown value must reject
    // the promise (which RET/the unwind already did), not remain a live VM
    // fault, so the drain and the caller see a settled promise instead.
    vm.has_error = false;
    vm.heap.has_error = false;

    // Drive microtasks until the module promise settles (or the queue drains).
    // drain_microtasks resumes suspended async activations via reactions.
    for (uint guard = 0; guard < 100000; guard++) {
        if (builtins::promise_get_state(mod_promise, builtins::PROMISE_PENDING)
            != builtins::PROMISE_PENDING) break;
        if (vm.heap.microtask_count == 0) break;
        vm.heap.drain_microtasks((void*)vm);
    }

    // Inspect the settled promise while it is still pinned.
    bool rejected = builtins::promise_get_state(mod_promise, builtins::PROMISE_PENDING)
                    == builtins::PROMISE_REJECTED;
    if (rejected) {
        TVal reason = builtins::promise_get_result(mod_promise);
        vm.heap.tval_copy_ref(&vm.heap.error_value, &reason);
        vm.heap.has_error = true;
    }

    vm.heap.decref(mod_promise.as_header());
    return !rejected;
}

/// Execute a module body while the VM is already mid-dispatch (dynamic
/// import from a running module or script). Unlike execute_in_env /
/// execute_module_async — which take over activations[0] and valstack[0]
/// and therefore destroy the caller's live frame — this saves the entire
/// activation stack and runs the module in a fresh frame above the live
/// registers, mirroring vm_call_fn_impl, then restores the caller's state.
///
/// Returns true when the module body evaluated to completion; false when it
/// threw (sync body) or its evaluation promise rejected (async/TLA body) —
/// in that case the thrown value / rejection reason is left in
/// heap.error_value. Faults only on hard setup failure.
fn bool? Vm.execute_module_nested(Vm* vm, CompiledFunction* func, EnvRecord* env) {
    uint nregs = func.num_regs;

    // Compute the true top of the current (topmost live) activation's
    // register file. vm.valstack_top is NOT updated for inline JS-to-JS
    // calls, so it may point below the caller's full register space; the
    // nested module frame must be placed above that to avoid overlap.
    TVal* true_top = vm.valstack_top;
    if (vm.activation_count > 0) {
        Activation* cur_act = &vm.activations[vm.activation_count - 1];
        CompiledFunction* cur_func = (CompiledFunction*)cur_act.func;
        if (cur_func != null) {
            TVal* act_top = cur_act.bottom + cur_func.num_regs;
            if (act_top > true_top) true_top = act_top;
        }
    }

    // Grow the valstack first (while activation_count is still the
    // caller's, so ensure_valstack_grow relocates all live pointers). The
    // module frame is placed above all live caller registers.
    uint true_used = (uint)(true_top - vm.valstack);
    if (true_top + nregs > vm.valstack_end) {
        if (!ensure_valstack_grow(vm, true_used + nregs - (uint)(vm.valstack_top - vm.valstack))) {
            return VM_ERROR~;
        }
        // Recompute true_top after potential realloc
        if (vm.activation_count > 0) {
            Activation* cur_act2 = &vm.activations[vm.activation_count - 1];
            CompiledFunction* cur_func2 = (CompiledFunction*)cur_act2.func;
            if (cur_func2 != null) {
                TVal* act_top2 = cur_act2.bottom + cur_func2.num_regs;
                true_top = (act_top2 > vm.valstack_top) ? act_top2 : vm.valstack_top;
            } else {
                true_top = vm.valstack_top;
            }
        } else {
            true_top = vm.valstack_top;
        }
    }

    // Save current VM state (after potential realloc).
    uint saved_act_count = vm.activation_count;
    TVal* saved_valstack_bottom = vm.valstack_bottom;
    TVal* saved_valstack_top = vm.valstack_top;
    TVal* saved_valstack = vm.valstack;
    CompiledFunction* saved_current_func = vm.current_func;
    void* saved_resume_gen = vm.heap.resume_gen;

    Activation[MAX_CALLS] saved_acts;
    mem::copy(&saved_acts, &vm.activations, (sz)(saved_act_count * Activation::size));

    // Zero out activation slots 1..saved_act_count-1 (same as
    // vm_call_fn_impl). The outer activations are safely stored in
    // saved_acts; the live slots must be cleared so that if the nested
    // run's inline CALL writes a new this_binding into a slot, it decrefs
    // undefined (no-op) rather than the stale reference left behind by the
    // memcpy'd-out outer activation.
    if (saved_act_count > 1) {
        mem::clear(&vm.activations[1], (sz)((usz)(saved_act_count - 1) * Activation::size));
    }

    bool is_async_body = func.is_async();
    HObject* mod_promise = null;
    if (is_async_body) {
        // Allocate the module evaluation Promise up front, before touching
        // activation state, so top-level await can suspend into it and RET
        // can settle it. On failure no VM state has been modified yet.
        HObject*? prom_raw = vm.heap.alloc_object(hobject::ObjClass.PROMISE);
        if (catch err = prom_raw) return err~;
        mod_promise = prom_raw;
        mod_promise.prototype = vm.heap.promise_proto;
        builtins::promise_init(mod_promise);
        // Pin it across the evaluation + microtask drain so GC can't sweep
        // it (transient — released before returning).
        mod_promise.as_header().incref();
    }

    TVal* frame = true_top;

    Activation* act = &vm.activations[0];
    vm.activation_count = 1;
    act.func = func;
    act.parent = null;
    act.var_env = env;
    // A global Script ($262.evalScript / indirect eval at global scope) runs
    // with var_env = the global object record but lex_env = the persistent
    // global DeclarativeRecord, so top-level let/const/class land there rather
    // than on the global object. ESM modules pass their own combined env.
    act.lex_env = (env == vm.global_env && vm.global_lex_env != null) ? vm.global_lex_env : env;
    act.cat = null;
    act.curr_pc = func.code;
    act.async_gen_state = null;
    act.bottom = frame;
    act.retval = null;
    act.max_heap_reg = 0;
    act.caller_valstack_top = frame + nregs;
    act.flags = (func.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0);
    if (is_async_body) {
        act.flags |= ACT_FLAG_ASYNC;
        act.async_promise = mod_promise;
    } else {
        act.async_promise = null;
    }

    TVal this_val;
    if (vm.global_env != null && vm.global_env.bindings != null) {
        this_val.set_object(vm.global_env.bindings);
    } else {
        this_val.set_undefined();
    }
    // Raw assign: the slot still holds stale bits from the memcpy'd-out
    // outer activation (see the zeroing comment above), so a tval_copy_ref
    // here would incorrectly decref garbage.
    act.this_binding = this_val;

    for (uint i = 0; i < nregs; i++) {
        frame[i].set_undefined();
    }
    vm.valstack_top = frame + nregs;
    vm.valstack_bottom = frame;
    vm.current_func = func;
    // The nested body must not accidentally match the caller's pending
    // resume state.
    vm.heap.resume_gen = null;

    // Register saved outer activations in the shadow frame list so that GC
    // (triggered during the inner Vm.run() or the microtask drain below)
    // can mark their env bindings and keep them alive. The shadow frame is
    // stack-allocated and valid for the lifetime of this call.
    ShadowActFrame shadow_frame;
    shadow_frame.prev = vm.shadow_act_list;
    shadow_frame.acts = &saved_acts;
    shadow_frame.count = saved_act_count;
    vm.shadow_act_list = &shadow_frame;

    TVal? run_res = Vm.run(vm);
    bool run_faulted = false;
    if (catch err = run_res) {
        run_faulted = true;
    }

    if (is_async_body) {
        // Clear a synchronous throw: for an async body a thrown value must
        // reject the promise (which RET/the unwind already did), not
        // remain a live VM fault.
        vm.has_error = false;
        vm.heap.has_error = false;

        // Drive microtasks until the module promise settles (or the queue
        // drains). drain_microtasks resumes suspended async activations
        // via reactions.
        for (uint guard = 0; guard < 100000; guard++) {
            if (builtins::promise_get_state(mod_promise, builtins::PROMISE_PENDING)
                != builtins::PROMISE_PENDING) break;
            if (vm.heap.microtask_count == 0) break;
            vm.heap.drain_microtasks((void*)vm);
        }
    }

    // Deregister the shadow frame now that the inner run (and any drains)
    // have finished.
    vm.shadow_act_list = shadow_frame.prev;

    // If the nested run reallocated the valstack, relocate the saved
    // absolute pointers by the same delta (the saved snapshot was not
    // covered by ensure_valstack_grow's relocation pass).
    long reloc = (char*)vm.valstack - (char*)saved_valstack;
    if (reloc != 0) {
        saved_valstack_bottom = (TVal*)((char*)saved_valstack_bottom + reloc);
        saved_valstack_top = (TVal*)((char*)saved_valstack_top + reloc);
        for (uint i = 0; i < saved_act_count; i++) {
            saved_acts[i].bottom = (TVal*)((char*)saved_acts[i].bottom + reloc);
            if (saved_acts[i].retval != null) {
                saved_acts[i].retval = (TVal*)((char*)saved_acts[i].retval + reloc);
            }
            if (saved_acts[i].caller_valstack_top != null) {
                saved_acts[i].caller_valstack_top = (TVal*)((char*)saved_acts[i].caller_valstack_top + reloc);
            }
        }
    }

    // Restore VM state (caller registers were never touched).
    vm.activation_count = saved_act_count;
    vm.current_func = saved_current_func;
    mem::copy(&vm.activations, &saved_acts, (sz)(saved_act_count * Activation::size));
    vm.valstack_bottom = saved_valstack_bottom;
    vm.valstack_top = saved_valstack_top;
    vm.heap.resume_gen = (GeneratorState*)saved_resume_gen;

    if (is_async_body) {
        // Inspect the settled promise while it is still pinned.
        bool rejected = builtins::promise_get_state(mod_promise, builtins::PROMISE_PENDING)
                        == builtins::PROMISE_REJECTED;
        if (rejected) {
            TVal reason = builtins::promise_get_result(mod_promise);
            vm.heap.tval_copy_ref(&vm.heap.error_value, &reason);
            vm.heap.has_error = true;
        }
        vm.heap.decref(mod_promise.as_header());
        return !rejected;
    }

    // Sync body: if the run faulted, the uncaught-error unwind already
    // copied the thrown value into vm.heap.error_value.
    return !run_faulted;
}

/// Execute the bytecode dispatch loop. Assumes activation stack and registers
/// are already set up by the caller.
fn TVal? Vm.run(Vm* vm) {
    vm.run_depth++;
    defer vm.run_depth--;

    Dispatch ds;
    ds.vm = vm;
    ds.needs_restart = true;
    ds.halt = false;

    // Outer restart loop: on ECMAScript-to-ECMAScript calls, reload state
    for (;;) {
        if (!ds.needs_restart) {
            break;
        }
        ds.needs_restart = false;

        // A restart with no remaining activation means the top-level frame
        // just unwound (e.g. an uncaught throw in a top-level async/module
        // body: vm_throw_value settles the promise, pops to count 0, and
        // requests a restart to "resume the caller" — but there is no caller).
        // Halt cleanly instead of indexing activations[-1].
        if (vm.activation_count == 0) {
            return vm.return_val;
        }

        ds.act = &vm.activations[vm.activation_count - 1];
        vm.current_func = (CompiledFunction*)ds.act.func;
        ds.code_base = vm.current_func.code;
        ds.code_count = vm.current_func.code_count;
        ds.constants = vm.current_func.constants;
        ds.ic_base = (hobject::ICEntry*)vm.current_func.ic_entries;
        ds.var_ic_base = (hobject::VarICEntry*)vm.current_func.var_ic_entries;
        ds.nregs = vm.current_func.num_regs;

        ds.curr_pc = ds.act.curr_pc;
        ds.code_end = ds.code_base + ds.code_count;

        ds.regs_base = ds.act.bottom;

        // Inner dispatch loop
        for (; !ds.needs_restart; ) {
            if (ds.halt) {
                return ds.halt_value;
            }
            if (ds.curr_pc >= ds.code_end) {
                // Inline handle_return for fall-off-end — avoids function call overhead.
                Activation* callee_act = &vm.activations[vm.activation_count - 1];
                TVal* callee_result = callee_act.retval;

                // Decref callee registers before popping
                decref_callee_regs(vm, callee_act);

                vm.activation_count--;

                if (vm.activation_count == 0) {
                    TVal undef_val;
                    undef_val.set_undefined();
                    vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                    return vm.return_val;
                }

                Activation* caller_act = &vm.activations[vm.activation_count - 1];
                vm.valstack_bottom = caller_act.bottom;

                TVal undef_val;
                undef_val.set_undefined();
                TVal final_val = undef_val;
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    if (!final_val.is_object() || final_val.get_heapptr() == null) {
                        if (callee_act.this_binding.is_object() && callee_act.this_binding.get_heapptr() != null) {
                            final_val = callee_act.this_binding;
                        }
                    }
                }
                vm.heap.tval_copy_ref(callee_result, &final_val);

                CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;

                ds.act = caller_act;
                vm.valstack_top = callee_act.caller_valstack_top;
                if (caller_func != vm.current_func) {
                    vm.current_func = caller_func;
                    ds.code_base = caller_func.code;
                    ds.code_count = caller_func.code_count;
                    ds.code_end = ds.code_base + ds.code_count;
                    ds.constants = caller_func.constants;
                    ds.ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                    ds.var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                    ds.nregs = caller_func.num_regs;
                }
                ds.curr_pc = ds.act.curr_pc;
                ds.regs_base = ds.act.bottom;
                continue;
            }

            Instruction insn = *ds.curr_pc;
            ds.curr_pc++;

            Opcode op = insn.op;

            TVal* ra = ds.regs_base + ((uint)insn.a);
            TVal* rb = ds.regs_base + ((uint)insn.b);
            TVal* rc = ds.regs_base + ((uint)insn.c);

        $if $feature(TRACE_VM):
        if (@unlikely(vm.trace)) {
            trace_instruction(vm, ds.curr_pc - 1, (uint)((ds.curr_pc - 1) - ds.code_base),
                              ra, rb, rc, ds.regs_base, ds.act);
        }
        $endif

        switch (op) @jump {

        // === LOAD / STORE ===
        case Opcode.LDREG:
            // Fast path: if source is not a heap ref (fastint, undefined, etc.),
            // skip full refcounting — only decref dst if it held a heap pointer.
            if (!rb.is_heap_allocated()) {
                if (ra.is_heap_allocated()) {
                    vm.heap.decref_tval(ra);
                }
                *ra = *rb;
            } else {
                vm.heap.tval_copy_ref(ra, rb);
                track_heap_store(ds.act, ra, (uint)insn.a);
            }
            continue;

        case Opcode.LDCONST: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                vm.heap.tval_copy_ref(ra, &ds.constants[bc]);
            } else {
                ra.set_undefined();
            }
            continue;
        }

        case Opcode.SETCONST: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                vm.heap.tval_copy_ref(&ds.constants[bc], ra);
            }
            continue;
        }

        case Opcode.LDINT:
            ra.set_fastint((long)insn.get_sbc());
            continue;

        case Opcode.LDINTX: {
            long ix_high = ra.get_fastint();
            ra.set_fastint((ix_high << 16) | (long)insn.get_bc());
            continue;
        }

        case Opcode.LDUNDEF:
            ra.set_undefined();
            continue;

        case Opcode.LDNULL:
            ra.set_null();
            continue;

        case Opcode.LDTRUE:
            ra.set_boolean(true);
            continue;

        case Opcode.LDFALSE:
            ra.set_boolean(false);
            continue;

        case Opcode.LDTHIS:
            // Derived constructors have an uninitialized `this` (TDZ sentinel)
            // until super() is called. Accessing `this` before super() → ReferenceError.
            if (env::is_tdz_sentinel(&ds.act.this_binding)) {
                if (!vm_throw_error(vm, vm.heap.ref_err_proto,
                        "Must call super constructor in derived class before accessing 'this' or returning from derived constructor",
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &vm.throw_value);
                }
                continue;
            }
            vm.heap.tval_copy_ref(ra, &ds.act.this_binding);
            track_heap_store(ds.act, ra, (uint)insn.a);
            continue;

        // === ARITHMETIC ===
        case Opcode.ADD: {
            // ES5 §11.6.1: ToPrimitive both, then string concat or numeric add
            // Fast path: FASTINT + FASTINT — most common in arithmetic benchmarks.
            // Check this BEFORE OBJECT/STRING to avoid unnecessary tag dispatch.
            if (types::both_fastint(rb, rc)) {
                long sum = rb.get_fastint() + rc.get_fastint();
                if (sum >= types::FASTINT_MIN && sum <= types::FASTINT_MAX) {
                    ra.set_fastint(sum);
                } else {
                    ra.set_number((double)sum);
                }
                continue;
            }
            // Fast path: STRING + FASTINT or FASTINT + STRING
            // Format the integer directly into the concat buffer, avoiding
            // the intermediate HString allocation for the integer.
            if ((rb.is_string() && rc.is_fastint()) || (rb.is_fastint() && rc.is_string())) {
                HString* str;
                long int_val;
                if (rb.is_string()) {
                    str = (HString*)rb.get_heapptr();
                    int_val = rc.get_fastint();
                } else {
                    str = (HString*)rc.get_heapptr();
                    int_val = rb.get_fastint();
                }
                if (str != null) {
                    char[32] int_buf;
                    int int_len = hstring::int_to_buf(int_val, &int_buf, 32);
                    if (int_len > 0) {
                        uint s_len = str.blen;
                        uint total = s_len + (uint)int_len;
                        char[544] stack_buf;
                        char* buf;
                        bool heap_allocated = false;
                        if (total <= 544) {
                            buf = &stack_buf;
                        } else {
                            buf = (char*)vm.heap.alloc_func(vm.heap.heap_udata, total);
                            if (buf == null) { ra.set_undefined(); break; }
                            heap_allocated = true;
                        }
                        if (rb.is_string()) {
                            mem::copy(buf, str.get_cstr(), (sz)(s_len));
                            mem::copy(buf + s_len, &int_buf, (sz)((usz)int_len));
                        } else {
                            mem::copy(buf, &int_buf, (sz)((usz)int_len));
                            mem::copy(buf + int_len, str.get_cstr(), (sz)(s_len));
                        }
                        // Skip interning for accumulator (ra == source register),
                        // intern for new strings that may be used as property keys.
                        bool is_accum = (ra == rb || ra == rc);
                        if (is_accum) {
                            uint hash = vm.heap.hash_string(buf[:total]);
                            HString*? maybe_s = hstring::hstring_alloc((void*)vm.heap, buf[:total], hash);
                            if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                            if (try s = maybe_s) {
                                vm.heap.set_reg_string(ra, s);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            HString* interned = intern_string(vm, buf[:total]);
                            if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                            vm.heap.set_reg_string(ra, interned);
                        }
                        continue;
                    }
                }
                // Fall through to generic path if str is null or int_to_buf failed
            }
            TVal prim_b = *rb;
            TVal prim_c = *rc;
            // ES5 §11.6.1: + operator uses ToPrimitive with no hint (default "number")
            if (rb.get_tag() == OBJECT) { prim_b = to_primitive_value(vm, rb, 0); }
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            if (rc.get_tag() == OBJECT) { prim_c = to_primitive_value(vm, rc, 0); }
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            TValTag pt_b = prim_b.get_tag();
            TValTag pt_c = prim_c.get_tag();
            if (pt_b == STRING || pt_c == STRING) {
                HString*? left_str = vm_to_string(vm, &prim_b);
                if (vm.throw_pending) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    continue;
                }
                HString*? right_str = vm_to_string(vm, &prim_c);
                if (vm.throw_pending) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    continue;
                }
                if (try ls = left_str && try rs = right_str) {
                    uint a_len = ls.blen;
                    uint b_len = rs.blen;
                    uint total = a_len + b_len;

                    // Use stack buffer for small strings, heap for large
                    char[512] stack_buf;
                    char* buf;
                    bool heap_allocated = false;
                    if (total <= 512) {
                        buf = &stack_buf;
                    } else {
                        buf = (char*)vm.heap.alloc_func(vm.heap.heap_udata, total);
                        if (buf == null) { ra.set_undefined(); break; }
                        heap_allocated = true;
                    }

                    // Copy both halves directly into buffer
                    if (a_len > 0) {
                        mem::copy(buf, ls.get_cstr(), (sz)(a_len));
                    }
                    if (b_len > 0) {
                        mem::copy(buf + a_len, rs.get_cstr(), (sz)(b_len));
                    }

                    // Skip interning for accumulator (ra == source register),
                    // intern for new strings that may be used as property keys.
                    bool is_accum = (ra == rb || ra == rc);
                    if (is_accum) {
                        uint hash = vm.heap.hash_string(buf[:total]);
                        HString*? maybe_s = hstring::hstring_alloc((void*)vm.heap, buf[:total], hash);
                        if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                        if (try s = maybe_s) {
                            vm.heap.set_reg_string(ra, s);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        HString* interned = intern_string(vm, buf[:total]);
                        if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                        vm.heap.set_reg_string(ra, interned);
                    }
                } else {
                    ra.set_undefined();
                }
            } else if (prim_b.is_bigint() || prim_c.is_bigint()) {
                // ES2020 §12.8.5: neither primitive is a String → numeric add.
                // BigInt operands: both must be BigInt (else TypeError).
                if (vm_bigint_binop(vm, Opcode.ADD, ra, &prim_b, &prim_c) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
            } else {
                double add_b = vm_to_number(vm,&prim_b);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                double add_c = vm_to_number(vm,&prim_c);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number(add_b + add_c);
            }
        }

        case Opcode.SUB:
            if (rb.is_bigint() || rc.is_bigint()) {
                if (vm_bigint_binop(vm, Opcode.SUB, ra, rb, rc) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
                continue;
            }
            if (types::both_fastint(rb, rc)) {
                long diff = rb.get_fastint() - rc.get_fastint();
                if (diff >= types::FASTINT_MIN && diff <= types::FASTINT_MAX) {
                    ra.set_fastint(diff);
                } else {
                    ra.set_number((double)diff);
                }
            } else {
                double sub_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double sub_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number(sub_b - sub_c);
            }
            continue;

        case Opcode.MUL:
            if (rb.is_bigint() || rc.is_bigint()) {
                if (vm_bigint_binop(vm, Opcode.MUL, ra, rb, rc) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
                continue;
            }
            if (types::both_fastint(rb, rc)) {
                // 48-bit operands can overflow 64-bit signed long (2^47 * 2^47 = 2^94).
                // Guard: if both operands fit in 31 bits the product fits in 62 bits
                // and is safely range-checked; otherwise fall through to double path.
                long mul_b = rb.get_fastint();
                long mul_c = rc.get_fastint();
                if (mul_b >= -0x40000000L && mul_b <= 0x3FFFFFFFL &&
                    mul_c >= -0x40000000L && mul_c <= 0x3FFFFFFFL) {
                    long mul_result = mul_b * mul_c;
                    if (mul_result >= types::FASTINT_MIN && mul_result <= types::FASTINT_MAX) {
                        ra.set_fastint(mul_result);
                    } else {
                        ra.set_number((double)mul_result);
                    }
                } else {
                    ra.set_number((double)mul_b * (double)mul_c);
                }
            } else {
                double mul_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double mul_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number(mul_b * mul_c);
            }
            continue;

        case Opcode.DIV: {
            if (rb.is_bigint() || rc.is_bigint()) {
                if (vm_bigint_binop(vm, Opcode.DIV, ra, rb, rc) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
                continue;
            }
            double div_b = vm_to_number(vm,rb);
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            double div_c = vm_to_number(vm,rc);
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_number(div_b / div_c);
            continue;
        }

        case Opcode.MOD:
            if (rb.is_bigint() || rc.is_bigint()) {
                if (vm_bigint_binop(vm, Opcode.MOD, ra, rb, rc) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
                continue;
            }
            if (types::both_fastint(rb, rc) && rc.get_fastint() != 0) {
                long mod_result = rb.get_fastint() % rc.get_fastint();
                if (mod_result == 0 && rb.get_fastint() < 0) {
                    // -1 % 1 → -0: sign of zero matches dividend per ES5 §11.5.3
                    ra.set_number(-0.0);
                } else {
                    ra.set_fastint(mod_result);
                }
            } else {
                double mod_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double mod_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number((mod_b % mod_c));
            }
            continue;

        case Opcode.EXP: {
            if (rb.is_bigint() || rc.is_bigint()) {
                if (vm_bigint_binop(vm, Opcode.EXP, ra, rb, rc) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
                continue;
            }
            double exp_b = vm_to_number(vm,rb);
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            double exp_c = vm_to_number(vm,rc);
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            // ES2016 §12.6.4: abs(base) == 1 && exp is ±Infinity → NaN (C99 pow returns 1)
            double exp_r;
            if (math::abs(exp_b) == 1.0 && !math::is_finite(exp_c) && !math::is_nan(exp_c)) {
                exp_r = double::nan;
            } else {
                exp_r = math::pow(exp_b, exp_c);
            }
            ra.set_number(exp_r);
            continue;
        }

        // === UNARY ===
        case Opcode.UNP:
        case Opcode.UNM:
        case Opcode.BNOT:
        case Opcode.LNOT:
        case Opcode.TYPEOF:
        case Opcode.VOID:
        case Opcode.TONUMERIC:
        case Opcode.INC:
        case Opcode.DEC:
        case Opcode.PUTARG:
        case Opcode.INC_VAR:
        case Opcode.DEC_VAR:
            if (catch err = dispatch_unary(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === BITWISE ===
        case Opcode.BAND:
            // Bitwise ops always produce Int32, always fit in FASTINT.
            // Fast path: FASTINTs are already integer-valued; cast directly to int
            // instead of round-tripping through double + toint32.
        {
            if (rb.is_bigint() || rc.is_bigint()) {
                if (vm_bigint_binop(vm, Opcode.BAND, ra, rb, rc) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
                continue;
            }
            if (types::both_fastint(rb, rc)) {
                ra.set_fastint((long)((int)rb.get_fastint() & (int)rc.get_fastint()));
                continue;
            }
            int band_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int band_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(band_b & band_c));
            continue;
        }

        case Opcode.BOR:
        {
            if (rb.is_bigint() || rc.is_bigint()) {
                if (vm_bigint_binop(vm, Opcode.BOR, ra, rb, rc) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
                continue;
            }
            if (types::both_fastint(rb, rc)) {
                ra.set_fastint((long)((int)rb.get_fastint() | (int)rc.get_fastint()));
                continue;
            }
            int bor_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int bor_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(bor_b | bor_c));
            continue;
        }

        case Opcode.BXOR:
        {
            if (rb.is_bigint() || rc.is_bigint()) {
                if (vm_bigint_binop(vm, Opcode.BXOR, ra, rb, rc) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
                continue;
            }
            if (types::both_fastint(rb, rc)) {
                ra.set_fastint((long)((int)rb.get_fastint() ^ (int)rc.get_fastint()));
                continue;
            }
            int bxor_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int bxor_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(bxor_b ^ bxor_c));
            continue;
        }

        case Opcode.SHL:
        {
            if (rb.is_bigint() || rc.is_bigint()) {
                if (vm_bigint_binop(vm, Opcode.SHL, ra, rb, rc) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
                continue;
            }
            if (types::both_fastint(rb, rc)) {
                ra.set_fastint((long)((int)rb.get_fastint() << ((int)rc.get_fastint() & 0x1F)));
                continue;
            }
            int shl_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int shl_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(shl_b << (shl_c & 0x1F)));
            continue;
        }

        case Opcode.SHR:
        {
            if (rb.is_bigint() || rc.is_bigint()) {
                if (vm_bigint_binop(vm, Opcode.SHR, ra, rb, rc) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
                continue;
            }
            if (types::both_fastint(rb, rc)) {
                ra.set_fastint((long)((int)rb.get_fastint() >> ((int)rc.get_fastint() & 0x1F)));
                continue;
            }
            int shr_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int shr_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(shr_b >> (shr_c & 0x1F)));
            continue;
        }

        case Opcode.USHR:
        {
            if (rb.is_bigint() || rc.is_bigint()) {
                if (vm_bigint_binop(vm, Opcode.USHR, ra, rb, rc) == BigIntOpResult.THREW) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    if (ds.needs_restart) break;
                }
                continue;
            }
            uint ushr_b = (uint)toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int  ushr_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(ushr_b >> (ushr_c & 0x1F)));
            continue;
        }

        // === COMPARISON ===
        case Opcode.EQ:
            ra.set_boolean(abstract_eq(vm, rb, rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            continue;

        case Opcode.NEQ:
            ra.set_boolean(!abstract_eq(vm, rb, rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            continue;

        case Opcode.SEQ: {
            // Fast path: FASTINT === FASTINT — most common in loop counters and
            // arithmetic benchmarks. Short-circuit before full tag dispatch.
            if (types::both_fastint(rb, rc)) {
                ra.set_boolean(rb.get_fastint() == rc.get_fastint());
                continue;
            }
            bool seq_r = false;
            TValTag tag_b = rb.get_tag();
            TValTag tag_c = rc.get_tag();
            if (tag_b == tag_c) {
                switch (tag_b) {
                    case UNDEFINED: seq_r = true; break;
                    case NULL_VAL:  seq_r = true; break;
                    case BOOLEAN:   seq_r = (rb.get_boolean() == rc.get_boolean()); break;
                    case NUMBER:
                        if (math::is_nan(rb.get_number()) || math::is_nan(rc.get_number())) {
                            seq_r = false;
                        } else {
                            seq_r = (rb.get_number() == rc.get_number());
                        }
                        break;
                    case FASTINT:   seq_r = (rb.get_fastint() == rc.get_fastint()); break;
                    case STRING: {
                        HString* sa = (HString*)rb.get_heapptr();
                        HString* sb = (HString*)rc.get_heapptr();
                        seq_r = sa != null && sb != null && sa.equals_hstring(sb);
                        break;
                    }
                    case OBJECT:    seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case LIGHTFUNC: seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case POINTER:   seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case BUFFER:    seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case BIGINT:    seq_r = (rb.get_bigint() == rc.get_bigint()); break;
                    default: break;
                }
            } else if ((tag_b == NUMBER && tag_c == FASTINT) ||
                       (tag_b == FASTINT && tag_c == NUMBER)) {
                double nb = (tag_b == FASTINT) ? (double)rb.get_fastint() : rb.get_number();
                double nc = (tag_c == FASTINT) ? (double)rc.get_fastint() : rc.get_number();
                seq_r = (nb == nc);
            }
            // Cross-type (e.g. BigInt === Number) is always false for ===.
            ra.set_boolean(seq_r);
            continue;
        }

        case Opcode.SNEQ: {
            // Fast path: FASTINT !== FASTINT — short-circuit before full tag dispatch.
            if (rb.is_fastint() && rc.is_fastint()) {
                ra.set_boolean(rb.get_fastint() != rc.get_fastint());
                continue;
            }
            bool sneq_r = true;
            TValTag tag_b = rb.get_tag();
            TValTag tag_c = rc.get_tag();
            if (tag_b == tag_c) {
                switch (tag_b) {
                    case UNDEFINED: sneq_r = false; break;
                    case NULL_VAL:  sneq_r = false; break;
                    case BOOLEAN:   sneq_r = (rb.get_boolean() != rc.get_boolean()); break;
                    case NUMBER:
                        if (math::is_nan(rb.get_number()) || math::is_nan(rc.get_number())) {
                            sneq_r = true;
                        } else {
                            sneq_r = (rb.get_number() != rc.get_number());
                        }
                        break;
                    case FASTINT:   sneq_r = (rb.get_fastint() != rc.get_fastint()); break;
                    case STRING: {
                        HString* sa = (HString*)rb.get_heapptr();
                        HString* sb = (HString*)rc.get_heapptr();
                        sneq_r = !(sa != null && sb != null && sa.equals_hstring(sb));
                        break;
                    }
                    case OBJECT:    sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case LIGHTFUNC: sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case POINTER:   sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case BUFFER:    sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case BIGINT:    sneq_r = (rb.get_bigint() != rc.get_bigint()); break;
                    default: break;
                }
            } else if ((tag_b == NUMBER && tag_c == FASTINT) ||
                       (tag_b == FASTINT && tag_c == NUMBER)) {
                double nb = (tag_b == FASTINT) ? (double)rb.get_fastint() : rb.get_number();
                double nc = (tag_c == FASTINT) ? (double)rc.get_fastint() : rc.get_number();
                sneq_r = (nb != nc);
            }
            ra.set_boolean(sneq_r);
            continue;
        }

        case Opcode.LT:
        case Opcode.LE:
        case Opcode.GT:
        case Opcode.GE: {
            bool result;
            if (types::both_fastint(rb, rc)) {
                long lb = rb.get_fastint();
                long lc = rc.get_fastint();
                switch (op) {
                    case Opcode.LT: result = lb <  lc;
                    case Opcode.LE: result = lb <= lc;
                    case Opcode.GT: result = lb >  lc;
                    default:        result = lb >= lc;
                }
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                double db = tval_numeric_to_double(rb);
                double dc = tval_numeric_to_double(rc);
                switch (op) {
                    case Opcode.LT: result = db <  dc;
                    case Opcode.LE: result = db <= dc;
                    case Opcode.GT: result = db >  dc;
                    default:        result = db >= dc;
                }
            } else {
                bool is_undef;
                int cmp = vm_relational_compare(vm, rb, rc, &is_undef);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                if (is_undef) {
                    // NaN comparisons all yield false
                    result = false;
                } else {
                    switch (op) {
                        case Opcode.LT: result = cmp <  0;
                        case Opcode.LE: result = cmp <= 0;
                        case Opcode.GT: result = cmp >  0;
                        default:        result = cmp >= 0;
                    }
                }
            }
            ra.set_boolean(result);
            continue;
        }

        // === FUSED COMPARE-AND-BRANCH ===
        // Each op replicates the corresponding compare's exact semantics, then
        // branches if the result is FALSE (i.e. branches when condition does NOT hold).
        // Offset in A (signed 8-bit, cast via char) is relative to the already-
        // incremented pc (same convention as IF_FALSE).
        // NaN: !(NaN op x) is always true, so the branch IS taken — correct because
        // we negate the same compare result that IF_FALSE would have tested.

        case Opcode.JMP_NLT:
        case Opcode.JMP_NLE:
        case Opcode.JMP_NGT:
        case Opcode.JMP_NGE:
        case Opcode.JMP_LT:
        case Opcode.JMP_LE:
        case Opcode.JMP_GT:
        case Opcode.JMP_GE: {
            bool cmp_lt;   // was b < c ?
            bool cmp_le;   // was b <= c ?
            bool cmp_undef = false;
            if (types::both_fastint(rb, rc)) {
                long lb = rb.get_fastint();
                long lc = rc.get_fastint();
                cmp_lt = lb <  lc;
                cmp_le = lb <= lc;
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                double db = tval_numeric_to_double(rb);
                double dc = tval_numeric_to_double(rc);
                cmp_lt = db <  dc;
                cmp_le = db <= dc;
            } else {
                int cmp = vm_relational_compare(vm, rb, rc, &cmp_undef);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                cmp_lt = cmp <  0;
                cmp_le = cmp <= 0;
            }
            // Map opcode to compare result and branch polarity.
            //   JMP_N* branches when the compare is FALSE (used by if/while exits)
            //   JMP_*  branches when the compare is TRUE  (used by loop back-edges)
            bool cmp_result;
            bool branch_on;
            switch (op) {
                case Opcode.JMP_NLT: cmp_result = cmp_lt;  branch_on = false;
                case Opcode.JMP_NLE: cmp_result = cmp_le;  branch_on = false;
                case Opcode.JMP_NGT: cmp_result = !cmp_le; branch_on = false;
                case Opcode.JMP_NGE: cmp_result = !cmp_lt; branch_on = false;
                case Opcode.JMP_LT:  cmp_result = cmp_lt;  branch_on = true;
                case Opcode.JMP_LE:  cmp_result = cmp_le;  branch_on = true;
                case Opcode.JMP_GT:  cmp_result = !cmp_le; branch_on = true;
                default:             cmp_result = !cmp_lt; branch_on = true;   // JMP_GE
            }
            // NaN comparisons all yield false; equivalent to !cmp_lt && !cmp_le
            // when cmp_undef is set (both cmp_lt/cmp_le are false above), so
            // JMP_NGT / JMP_NGE would wrongly branch. Force to false here.
            if (cmp_undef) cmp_result = false;
            if (cmp_result == branch_on) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } ds.curr_pc += (int)(ichar)insn.a; }
            continue;
        }

        case Opcode.INSTANCEOF: {
            // ES5 §11.8.6: RelationalExpression instanceof ShiftExpression
            // ra may alias rb (compiler optimization), so read rb before writing ra.
            TVal lval = *rb;
            TVal rval = *rc;
            ra.set_boolean(false);

            if (rval.is_lightfunc()) {
                // LIGHTFUNC builtins are callable; look up their prototype
                uint fn_idx = (uint)(usz)rval.get_heapptr();
                HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                if (proto_obj != null && lval.is_object()) {
                    HObject* lbh = (HObject*)lval.get_heapptr();
                    if (lbh.is_prototype_of(proto_obj)) {
                        ra.set_boolean(true);
                    }
                }
                continue;
            }

            if (!rval.is_object()) {
                // TypeError: right-hand side must be an object
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Right-hand side of instanceof is not an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                continue;
            }

            HObject* rfunc = (HObject*)rval.get_heapptr();

            // ES6 §12.9.4: GetMethod(C, @@hasInstance) is step 2 — must run
            // BEFORE the IsCallable check (step 5). Get() must invoke any
            // accessor getter and propagate its error (test get-err).
            if (vm.heap.hasinstance_symbol != null) {
                HString* hasinst_key = vm.heap.hasinstance_symbol;
                TVal hasinst_val;
                hasinst_val.set_undefined();
                bool have_value = false;
                AccessorResult hi_acc = rfunc.find_accessor_proto(hasinst_key, true);
                if (hi_acc.found) {
                    // Accessor property: invoke the getter (this = original
                    // receiver = rfunc). Getter may throw — propagate.
                    TVal this_for_getter;
                    this_for_getter.set_object(rfunc);
                    TVal getter_result = vm.heap.call_fn(vm, hi_acc.accessor_fn, null, 0, this_for_getter);
                    if (vm_check_call_fn_error(vm)) {
                        if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                        continue;
                    }
                    hasinst_val = getter_result;
                    have_value = true;
                } else {
                    // Data property (or not present). Read raw value via the
                    // prototype chain; fall back to undefined if missing.
                    TVal? raw = rfunc.get_prop_proto(hasinst_key);
                    if (try raw_v = raw) {
                        hasinst_val = raw_v;
                        have_value = true;
                    }
                }
                // ES6 §7.3.9 GetMethod: undefined/null → no method (fall through).
                // Anything else must be callable; otherwise TypeError.
                if (have_value && !hasinst_val.is_undefined() && !hasinst_val.is_null()) {
                    bool hasinst_callable = hasinst_val.is_lightfunc() ||
                        (hasinst_val.is_object() && hasinst_val.get_heapptr() != null &&
                         ((HObject*)hasinst_val.get_heapptr()).is_callable());
                    if (!hasinst_callable) {
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "Symbol.hasInstance value is not a function", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        continue;
                    }
                    // Call @@hasInstance with this=C(rval), arg=O(lval)
                    TVal result = vm.heap.call_fn(vm, hasinst_val, &lval, 1, rval);
                    if (vm_check_call_fn_error(vm)) {
                        if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                        continue;
                    }
                    ra.set_boolean(builtins::builtin_to_boolean(&result));
                    continue;
                }
            }

            // Proxy exotic on the RHS: OrdinaryHasInstance with [[Get]] of
            // "prototype" routed through the proxy.
            if (rfunc.flags.exotic_proxyobj) {
                if (!lval.is_object()) { continue; }
                HString* pk = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
                TVal pproto;
                if (!builtins::proxy_mop_get(vm, vm.heap, rfunc, pk, rval, &pproto)) {
                    TVal perr = vm.heap.error_value;
                    vm.heap.has_error = false;
                    if (!vm_throw_value(vm, perr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &perr);
                    }
                    continue;
                }
                if (!pproto.is_object()) {
                    if (!vm_throw_error(vm, vm.heap.type_err_proto, "'prototype' property is not an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return VM_ERROR~;
                    }
                    continue;
                }
                HObject* pproto_obj = (HObject*)pproto.get_heapptr();
                HObject* pcur = (HObject*)lval.get_heapptr();
                if (!instanceof_walk_chain(vm, &ds, pcur, pproto_obj, ra)) {
                    return VM_ERROR~;
                }
                continue;
            }

            // ES6 §12.9.4 step 5: If IsCallable(C) is false, throw TypeError.
            // (Reached only when @@hasInstance is undefined/missing.)
            if (!rfunc.is_callable()) {
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Right-hand side of instanceof is not callable", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                continue;
            }

            // §15.3.5.3 step 1: If Type(lval) is not Object → false
            if (!lval.is_object()) {
                continue;
            }

            // Get rval.prototype — ES6 §7.3.19 OrdinaryHasInstance step 4: Let P be Get(C, "prototype").
            // Get() must invoke accessor getters (per ES6 §7.3.1), so we first
            // check for an accessor property in the prototype chain and call
            // its getter; otherwise fall back to the raw data-property value.
            HString* proto_key_str = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
            TVal proto_val;
            AccessorResult acc = rfunc.find_accessor_proto(proto_key_str, true);
            if (acc.found) {
                // ES6 §7.3.1 Get(O, P) — if accessor has a getter, call it with
                // `this` bound to the original receiver (rfunc). The getter
                // may throw or return any value.
                TVal this_for_getter;
                this_for_getter.set_object(rfunc);
                proto_val = vm.heap.call_fn(vm, acc.accessor_fn, null, 0, this_for_getter);
                if (vm_check_call_fn_error(vm)) {
                            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                            continue;
                        }
            } else {
                proto_val = get_prop_with_proto(rfunc, proto_key_str);
            }
            if (!proto_val.is_object()) {
                // ES6 §7.3.19 OrdinaryHasInstance step 6: If Type(P) is not
                // Object, throw a TypeError exception. The spec does NOT
                // allow the silent-false fallback — the result must always
                // be defined (or an abrupt completion).
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "'prototype' property is not an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                continue;
            }

            HObject* proto_obj = (HObject*)proto_val.get_heapptr();
            HObject* cur = (HObject*)lval.get_heapptr();
            if (!instanceof_walk_chain(vm, &ds, cur, proto_obj, ra)) {
                return VM_ERROR~;
            }
            continue;
        }

        case Opcode.IN: {
            // ES5 §11.8.7: RelationalExpression in ShiftExpression
            // Right side must be an object; TypeError otherwise.
            // Returns true if the object has a property with the given name
            // (own or inherited — check via [[HasProperty]]).
            //
            // NOTE: Read rb (key) BEFORE writing ra, because ra may alias rb
            // (compiler can emit IN r3, r3, r4 when result overwrites the key).
            if (!rc.is_object()) {
                ra.set_boolean(false);
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "in requires an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                continue;
            }

            HObject* obj = (HObject*)rc.get_heapptr();

            // Proxy exotic: route through [[Has]].
            if (obj.flags.exotic_proxyobj) {
                void* pkey = get_prop_key(vm, rb);
                bool has = false;
                if (pkey != null) {
                    if (!builtins::proxy_mop_has(vm, vm.heap, obj, (HString*)pkey, &has)) {
                        TVal perr = vm.heap.error_value;
                        vm.heap.has_error = false;
                        if (!vm_throw_value(vm, perr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &perr);
                        }
                        continue;
                    }
                }
                ra.set_boolean(has);
                continue;
            }

            // TypedArray: numeric index membership (0..length-1, not detached).
            if (builtins::is_typed_array_class(obj.get_class())) {
                long idx_long = -1;
                bool is_int_idx = false;
                if (rb.is_fastint()) { idx_long = rb.get_fastint(); is_int_idx = true; }
                else if (rb.is_number()) {
                    double d = rb.get_number();
                    idx_long = (long)d;
                    is_int_idx = (d == (double)idx_long);
                } else if (rb.is_string()) {
                    HString* skey = (HString*)rb.get_heapptr();
                    if (skey != null && skey.is_arridx()) { idx_long = (long)skey.array_index(); is_int_idx = true; }
                }
                if (is_int_idx) {
                    HObject* buf = (*obj.extra_ptr()).view.buffer;
                    uint shift = builtins::ta_elem_shift(obj.get_class());
                    uint elem_count = (*obj.extra_ptr()).view.byte_length >> shift;
                    ra.set_boolean(idx_long >= 0 && buf != null && (*buf.extra_ptr()).ab.data != null
                        && (ulong)idx_long < (ulong)elem_count);
                    continue;
                }
            }

            // Fast path: dense array / arguments indexed check (numeric keys)
            if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) && obj.array_part() != null && (rb.is_fastint() || rb.is_number())) {
                long idx_long = rb.is_fastint() ? rb.get_fastint() : (long)rb.get_number();
                if (idx_long >= 0 && idx_long < (long)obj.array_size) {
                    TVal? av = obj.get_array_idx((uint)idx_long);
                    if (try v = av) {
                        ra.set_boolean(true);
                        continue;
                    }
                    // Array hole — fall through to prototype chain lookup
                } else {
                    // Index out of bounds — check prototype only
                    void* key = get_prop_key(vm, rb);
                    if (key != null) {
                        ra.set_boolean(obj.prototype != null && obj.prototype.has_prop_proto(key));
                    } else {
                        ra.set_boolean(false);
                    }
                    continue;
                }
            }

            // Fast path: dense array with string key that might be an index
            if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) && obj.array_part() != null && rb.is_string()) {
                HString* skey = (HString*)rb.get_heapptr();
                uint skey_idx = skey.array_index();
                if (skey_idx != hstring::ARRIDX_NONE && skey_idx < (uint)obj.array_size) {
                    TVal? av = obj.get_array_idx(skey_idx);
                    if (try v = av) {
                        ra.set_boolean(true);
                        continue;
                    }
                }
            }

            void* key = get_prop_key(vm, rb);
            if (key != null) {
                // STRING exotic: integer index keys in [0, clen) are own properties served lazily.
                if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
                    HString* key_hstr = (HString*)key;
                    if (key_hstr != null && key_hstr.is_arridx()) {
                        HString* prim_str = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
                        if (prim_str != null && key_hstr.array_index() < prim_str.char_length()) {
                            ra.set_boolean(true);
                            continue;
                        }
                    }
                }
                ra.set_boolean(obj.has_prop_proto(key));
            } else {
                ra.set_boolean(false);
            }
            continue;
        }

        // === CONTROL FLOW ===
        case Opcode.JUMP: {
            int sabc = insn.get_sabc();
            int target = (int)((long)(ds.curr_pc - ds.code_base) + (long)sabc);
            if (target < (ds.curr_pc - ds.code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
            ds.curr_pc = ds.code_base + target;
            continue;
        }

        case Opcode.IF_TRUE:
            if (is_truthy(ra)) {
                int sbx = insn.get_sbc();
                int target = (int)((long)(ds.curr_pc - ds.code_base) + (long)sbx);
                if (target < (ds.curr_pc - ds.code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
                ds.curr_pc = ds.code_base + target;
            }
            continue;

        case Opcode.IF_FALSE:
            if (!is_truthy(ra)) {
                int sbx = insn.get_sbc();
                int target = (int)((long)(ds.curr_pc - ds.code_base) + (long)sbx);
                if (target < (ds.curr_pc - ds.code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
                ds.curr_pc = ds.code_base + target;
            }
            continue;

        // === PROPERTY ACCESS ===
        // GETPROPC_CACHED is the warm monomorphic IC read — the single hottest
        // property op in tight loops (`p.x`). Inlined; all other property ops
        // (and the IC-miss downgrade path) go through dispatch_property.
        case Opcode.GETPROPC_CACHED: {
            // Specialized GETPROPC: IC is known warm. Only checks shape_id + prop_alloc.
            // Falls back to GETPROPC if the check fails (shape changed or props reallocated).
            // key_tval/key_hstr are only needed on miss; defer them to avoid wasted loads on hit.
            if (rb.is_object() && ds.ic_base != null) {
                HObject* hobj = (HObject*)rb.get_heapptr();
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::ICEntry* ic = ds.ic_base + pc_off;
                if (ic.shape_id == hobj.shape_id) {
                    HObject* ic_owner;
                    if (ic.proto == null) {
                        // Own-property IC: owner is the receiver itself.
                        ic_owner = hobj;
                    } else if (hobj.prototype == (HObject*)ic.proto) {
                        // Proto IC: receiver's prototype still points to the cached owner.
                        // setPrototypeOf does not change shape_id, so we check explicitly.
                        ic_owner = (HObject*)ic.proto;
                    } else {
                        ic_owner = null;
                    }
                    if (ic_owner != null && ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                        TVal ic_val = *ic.prop_value_ptr;
                        if (!ic_val.is_heap_allocated()) {
                            *ra = ic_val;
                        } else {
                            vm.heap.tval_copy_ref(ra, &ic_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        }
                        continue;
                    }
                }
            }
            // IC miss or ds.ic_base null: downgrade back to GETPROPC and re-execute
            ds.curr_pc[-1] = bytecode::make_abc(bytecode::Opcode.GETPROPC,
                                            (uint)insn.a, (uint)insn.b, (uint)insn.c);
            ds.curr_pc--;
            continue;
        }
        case Opcode.GETPROP:
        case Opcode.GETPROP_CACHE:
        case Opcode.GETPROPC:
        case Opcode.GETPROPC2:
        case Opcode.PUTPROP:
        case Opcode.PUTPROP_NE:
        case Opcode.PUTPROP_SUPER:
        case Opcode.GETPROP_SUPER:
        case Opcode.DELPROP:
            if (catch err = dispatch_property(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        case Opcode.TOPROPKEY: {
            // In-place ToPropertyKey coercion (see bytecode.c3 doc comment).
            // Mirrors dispatch_property's GETPROP key-coercion cache-back so a
            // later GETPROP/PUTPROP on this same register is a no-op re-coercion.
            if (!ra.is_string()) {
                void* key = get_prop_key(vm, ra);
                if (key == null && vm.throw_pending) {
                    vm.throw_pending = false;
                    if (!vm_throw_value(vm, vm.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &vm.throw_value);
                    }
                    continue;
                }
                if (key != null) {
                    TVal key_tv;
                    key_tv.set_string(key);
                    vm.heap.tval_copy_ref(ra, &key_tv);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                }
            }
            continue;
        }

        case Opcode.TOSTR: {
            // In-place ToString coercion (see bytecode.c3 doc comment) — used
            // by template literal substitutions, which call ToString directly
            // rather than going through ToPrimitive(default) like `+`.
            if (!ra.is_string() || (ra.get_heapptr() != null && ((HString*)ra.get_heapptr()).is_symbol())) {
                HString*? str = vm_to_string(vm, ra);
                // vm_to_string may call user code (toString/@@toPrimitive) that
                // reallocates the valstack — refresh before touching ra again.
                ds.regs_base = ds.act.bottom;
                ra = &ds.regs_base[insn.a];
                if (vm.throw_pending) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    continue;
                }
                if (try s = str) {
                    TVal str_tv;
                    str_tv.set_string(s);
                    vm.heap.tval_copy_ref(ra, &str_tv);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                }
            }
            continue;
        }

        // === OBJECT / ARRAY CREATION ===
        case Opcode.NEWOBJ:
        case Opcode.NEWARR:
        case Opcode.NEWREGEXP:
        case Opcode.SETALEN:
        case Opcode.FREEZEOBJ:
        case Opcode.ARRSPRD:
        case Opcode.OBJSPRD:
        case Opcode.SPREAD_ARG:
        case Opcode.FWD_ARGS:
            if (catch err = dispatch_objects(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === FUNCTION CALLS ===
        case Opcode.CALL:
        case Opcode.CALL_S:
        case Opcode.CALL_PROP:
        case Opcode.SETPROTO:
        case Opcode.GETPROTO:
        case Opcode.SUPER_CALL:
        case Opcode.SUPER_CALL_S:
        case Opcode.NEWTARGET:
        case Opcode.NEW_OBJ:
        case Opcode.NEW_OBJ_S:
        case Opcode.TAILCALL:
            if (catch err = dispatch_calls(&ds, op, ra, rb, rc, insn)) { return err~; }
            // Refresh regs_base after builtin calls that may have triggered valstack
            // reallocation via heap.call_fn (compiled-function paths set needs_restart
            // and reload via the outer loop; builtin paths return without setting it).
            if (!ds.needs_restart) { ds.regs_base = ds.act.bottom; }
            continue;

        // === GENERATORS ===
        case Opcode.LOAD_RESUME:
        case Opcode.AWAIT:
        case Opcode.YIELD:
        case Opcode.YIELD_STAR:
        case Opcode.GEN_START:
            if (catch err = dispatch_generators(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === DYNAMIC IMPORT ===
        case Opcode.DYN_IMPORT: {
            // Read the specifier before any write to A (A may reuse B's slot).
            TVal spec_tv = *rb;
            HString*? spec_opt = vm_to_string(vm, &spec_tv);
            // vm_to_string can call a user toString (re-enters the VM) — refresh.
            ds.regs_base = ds.act.bottom;
            if (vm.throw_pending) {
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &vm.throw_value);
                }
                continue;
            }
            HString* spec_str = null;
            if (try s = spec_opt) spec_str = s;
            if (spec_str == null) {
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "invalid dynamic import specifier", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                continue;
            }
            TVal? prom_opt = esm::dynamic_import(vm.heap, vm, spec_str.get_data());
            // The nested module evaluation may have reallocated the valstack.
            ds.regs_base = ds.act.bottom;
            if (catch err = prom_opt) {
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "dynamic import failed", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                continue;
            }
            TVal prom_tv = prom_opt;
            TVal* dst = ds.regs_base + (uint)insn.a;
            vm.heap.tval_copy_ref(dst, &prom_tv);
            // Drop the caller-owned reference dynamic_import returned.
            vm.heap.decref_tval(&prom_tv);
            continue;
        }

        // === RETURNS ===
        // RET / RETUNDEF are extremely hot in recursion; inline them here.
        // RET_GEN / RETUNDEF_GEN are generator-only and stay out-of-line.
        case Opcode.RET: {
            // Safe point: run deferred GC before returning to caller
            if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
            // Check for active finally catchers: if we're returning through
            // a try-finally, save the return value and jump to the finally
            // handler.  After ENDFINALLY, the saved value will be used.
            Catcher* ret_cat = (Catcher*)ds.act.cat;
            if (ret_cat != null && ret_cat.finally_pc != null) {
                // Save return value
                ret_cat.return_val = *ra;
                // If PENDING_RETURN is already set, we're inside the finally
                // block that was entered due to an earlier return.  Just update
                // the return value and let execution continue normally —
                // ENDFINALLY at the end of the finally block will complete the
                // return with the new value.  Without this check, we'd loop
                // infinitely back to the same finally block.
                if (!(ret_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                    // Jump to finally handler
                    ds.curr_pc = ret_cat.finally_pc;
                    ds.act.curr_pc = ds.curr_pc;
                }
                continue;
            }

            // Inline handle_return — eliminates function call overhead on every return.
            TVal val = *ra;
            Activation* callee_act = &vm.activations[vm.activation_count - 1];
            TVal* callee_result = callee_act.retval;

            // ES2015 §9.2.2 step 13.c: derived constructor returning a non-object
            // non-undefined value must throw TypeError — but the throw must be
            // raised in the caller's context (not catchable inside the constructor),
            // so we set a flag to throw after restoring the caller frame.
            bool derived_return_error = (callee_act.flags & ACT_FLAG_CONSTRUCT) != 0
                    && (callee_act.flags & ACT_FLAG_DERIVED) != 0
                    && !val.is_object()
                    && !val.is_undefined();

            // `return undefined;` from a derived constructor is equivalent to
            // bare `return;` (RETUNDEF) — same TDZ check applies.
            if (val.is_undefined() && derived_ctor_returns_undefined_uninitialized(callee_act)) {
                if (!vm_throw_error(vm, vm.heap.ref_err_proto,
                        "Must call super constructor in derived class before returning from derived constructor",
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &vm.throw_value);
                }
                continue;
            }

            // Protect the return value: if its only reference lives in a
            // callee register, decref_callee_regs below would free it.
            bool val_pinned = false;
            if (val.is_heap_allocated() && val.get_heapptr() != null) {
                ((HeapHeader*)val.get_heapptr()).incref();
                val_pinned = true;
            }

            // Decref callee registers before popping
            decref_callee_regs(vm, callee_act);

            vm.activation_count--;

            // Async function: resolve the promise with the return value and
            // return the promise. This must go through promise_resolve_with_value
            // (not a bare promise_settle) so that a returned thenable/Promise is
            // adopted per ES2015 §25.5.5.4 AsyncFunctionStart / §27.2.1.3.2 — the
            // async function's promise takes on the eventual settlement of the
            // returned promise rather than fulfilling with the promise object.
            if ((callee_act.flags & ACT_FLAG_ASYNC) != 0 && callee_act.async_promise != null) {
                builtins::promise_resolve_with_value(callee_act.async_promise, val, vm.heap, (void*)vm);
                // Release pin on original return value (promise now holds a ref)
                if (val_pinned) {
                    vm.heap.decref_tval(&val);
                }
                // Replace val with promise; its birth ref (refcount=1) acts as the pin
                val.set_object(callee_act.async_promise);
                val_pinned = true;
            }

            if (vm.activation_count == 0) {
                vm.heap.tval_copy_ref(&vm.return_val, &val);
                if (val_pinned) vm.heap.decref_tval(&val);
                ds.halt = true;
                ds.halt_value = vm.return_val;
                continue;
            }
            // Write return value to caller's result register
            if (callee_result != null) {
                // Constructor: if callee returned an object, use it; otherwise use 'this'.
                // (Derived non-object non-undefined case was already converted to a throw above.)
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    if (val.is_object()) {
                        vm.heap.tval_copy_ref(callee_result, &val);
                    } else {
                        vm.heap.tval_copy_ref(callee_result, &callee_act.this_binding);
                    }
                } else {
                    // Fast path: skip refcounting when return value is not a heap ref
                    if (!val.is_heap_allocated()) {
                        if (callee_result.is_heap_allocated()) {
                            vm.heap.decref_tval(callee_result);
                        }
                        *callee_result = val;
                    } else if (val_pinned) {
                        // Transfer the pin reference: decref dst, raw write.
                        vm.heap.decref_tval(callee_result);
                        *callee_result = val;
                        val_pinned = false;
                    } else {
                        vm.heap.tval_copy_ref(callee_result, &val);
                    }
                }
            }
            if (val_pinned) vm.heap.decref_tval(&val);
            // Restore caller state inline — skip outer loop restart.
            ds.act = &vm.activations[vm.activation_count - 1];
            vm.valstack_bottom = ds.act.bottom;
            vm.valstack_top = callee_act.caller_valstack_top;
            CompiledFunction* caller_func = (CompiledFunction*)ds.act.func;
            if (caller_func != vm.current_func) {
                vm.current_func = caller_func;
                ds.code_base = caller_func.code;
                ds.code_count = caller_func.code_count;
                ds.code_end = ds.code_base + ds.code_count;
                ds.constants = caller_func.constants;
                ds.ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                ds.var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                ds.nregs = caller_func.num_regs;
            }
            ds.curr_pc = ds.act.curr_pc;
            ds.regs_base = ds.act.bottom;

            // After a super-constructor returns (callee was CONSTRUCT, caller is DERIVED),
            // initialize the derived constructor's this_binding with the constructed object.
            // This is §9.2.2's "initialized" state — subsequent LDTHIS will succeed.
            bool super_already_bound = false;
            Activation* super_bound_act = null;
            if ((callee_act.flags & ACT_FLAG_SUPER_CTOR) != 0
                    && vm.activation_count > 0
                    && callee_result != null && callee_result.is_object()) {
                // The result of super() is in callee_result (already written
                // above). The immediate caller may be an arrow or a method the
                // arrow was invoked through — walk up to the derived ctor.
                super_already_bound = super_init_this_chain(vm, &vm.activations[vm.activation_count - 1], callee_result, &super_bound_act);
            }

            // ES2015 §9.2.2 step 13.c: now in the caller's context, throw TypeError.
            // The activation has already been popped, so this throw is not catchable
            // inside the constructor's own try-catch handlers.
            if (derived_return_error) {
                if (!vm_throw_error(vm, vm.heap.type_err_proto,
                        "Derived constructors may only return object or undefined",
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &vm.throw_value);
                }
                continue;
            }
            // §8.1.1.3.1 BindThisValue step 3: this_binding was already
            // initialized by a prior super() call — the superclass constructor
            // still ran (its side effects already happened above), but binding
            // the result to `this` a second time is a ReferenceError.
            if (super_already_bound) {
                if (!vm_throw_error(vm, vm.heap.ref_err_proto,
                        "Super constructor may only be called once",
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &vm.throw_value);
                }
                continue;
            }
            // Private class fields (ES2022 §9.2.2 step 8 InitializeInstanceElements,
            // called for DERIVED constructors right after `this` is bound by super()).
            if (super_bound_act != null) {
                CompiledFunction* super_bound_target = (CompiledFunction*)super_bound_act.func;
                if (catch verr = vm_init_private_members(vm, super_bound_act.lex_env, super_bound_act.var_env,
                        super_bound_target, super_bound_act.this_binding, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
            }
            continue;
        }

        case Opcode.RETUNDEF: {
            // Safe point: run deferred GC before returning to caller
            if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
            // Check for active finally catchers (same as RET)
            Catcher* ret2_cat = (Catcher*)ds.act.cat;
            if (ret2_cat != null && ret2_cat.finally_pc != null) {
                ret2_cat.return_val.set_undefined();
                if (!(ret2_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret2_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                    ds.curr_pc = ret2_cat.finally_pc;
                    ds.act.curr_pc = ds.curr_pc;
                }
                continue;
            }

            TVal undef_val;
            undef_val.set_undefined();

            // Inline handle_return — eliminates function call overhead.
            Activation* callee_act = &vm.activations[vm.activation_count - 1];
            TVal* callee_result = callee_act.retval;

            // ES2015 §9.2.2 step 13.d / §8.1.1.3.4: derived constructor returning
            // without calling super() → this_binding is still TDZ sentinel → ReferenceError.
            if (derived_ctor_returns_undefined_uninitialized(callee_act)) {
                if (!vm_throw_error(vm, vm.heap.ref_err_proto,
                        "Must call super constructor in derived class before returning from derived constructor",
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &vm.throw_value);
                }
                continue;
            }

            // Decref callee registers before popping
            decref_callee_regs(vm, callee_act);

            vm.activation_count--;

            // Async function: settle promise with undefined, return promise
            bool async_ret = false;
            if ((callee_act.flags & ACT_FLAG_ASYNC) != 0 && callee_act.async_promise != null) {
                builtins::promise_settle(callee_act.async_promise, 1, &undef_val, vm.heap);
                builtins::promise_trigger_reactions(callee_act.async_promise, vm.heap, (void*)vm);
                undef_val.set_object(callee_act.async_promise);
                async_ret = true;
            }

            if (vm.activation_count == 0) {
                vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                if (async_ret) vm.heap.decref_tval(&undef_val);
                ds.halt = true;
                ds.halt_value = vm.return_val;
                continue;
            }
            // Write return value to caller's result register
            if (callee_result != null) {
                // Constructor: return 'this' (the newly created object)
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    vm.heap.tval_copy_ref(callee_result, &callee_act.this_binding);
                } else {
                    if (callee_result.is_heap_allocated()) {
                        vm.heap.decref_tval(callee_result);
                    }
                    *callee_result = undef_val;
                }
            }
            // Restore caller state inline — skip outer loop restart.
            ds.act = &vm.activations[vm.activation_count - 1];
            vm.valstack_bottom = ds.act.bottom;
            vm.valstack_top = ds.act.caller_valstack_top;
            CompiledFunction* caller_func = (CompiledFunction*)ds.act.func;
            if (caller_func != vm.current_func) {
                vm.current_func = caller_func;
                ds.code_base = caller_func.code;
                ds.code_count = caller_func.code_count;
                ds.code_end = ds.code_base + ds.code_count;
                ds.constants = caller_func.constants;
                ds.ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                ds.var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                ds.nregs = caller_func.num_regs;
            }
            ds.curr_pc = ds.act.curr_pc;
            ds.regs_base = ds.act.bottom;
            // After base-constructor returns, initialize the derived constructor's this_binding.
            if ((callee_act.flags & ACT_FLAG_SUPER_CTOR) != 0
                    && vm.activation_count > 0
                    && callee_result != null && callee_result.is_object()) {
                Activation* su_bound_act = null;
                bool su_already_bound = super_init_this_chain(vm, &vm.activations[vm.activation_count - 1], callee_result, &su_bound_act);
                // §8.1.1.3.1 BindThisValue step 3: a second super() call — the
                // superclass constructor already ran (side effects above), but
                // binding its result to `this` again is a ReferenceError.
                if (su_already_bound) {
                    if (!vm_throw_error(vm, vm.heap.ref_err_proto,
                            "Super constructor may only be called once",
                            ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &vm.throw_value);
                    }
                } else if (su_bound_act != null) {
                    // Private class fields (ES2022 §9.2.2 step 8) for DERIVED
                    // constructors, right after `this` is bound by super().
                    CompiledFunction* su_bound_target = (CompiledFunction*)su_bound_act.func;
                    if (catch verr2 = vm_init_private_members(vm, su_bound_act.lex_env, su_bound_act.var_env,
                            su_bound_target, su_bound_act.this_binding, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return VM_ERROR~;
                    }
                }
            }
            continue;
        }
        case Opcode.RET_GEN:
        case Opcode.RETUNDEF_GEN:
            if (catch err = dispatch_returns(&ds, op, ra)) { return err~; }
            continue;

        // === VARIABLE ACCESS (inlined: hot in var-heavy / recursive code) ===
        case Opcode.GETVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- Variable IC fast path ---
                    if (ds.var_ic_base != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                        if (vic.env != null && vic.key == key && vic.search_head == (void*)ds.act.lex_env) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                if (b.get_prop_flags(vic.prop_idx).is_accessor) {
                                    // Accessor property: fall through to slow path which invokes getter
                                } else {
                                    TVal v = b.prop_values()[vic.prop_idx];
                                    if (!env::is_tdz_sentinel(&v)) {
                                        // ENV_STRICT: GETVAR read traps removed — for needs_env=false
                                        // lex_env == parent env, so a hit here is a legitimate parent
                                        // lookup, not own-local. Own-local leaks surface as 'not defined'
                                        // throws and are caught by test/test_register_locals.js.
                                        vm.heap.tval_copy_ref(ra, &v);
                                        track_heap_store(ds.act, ra, (uint)insn.a);
                                        break;
                                    }
                                    // TDZ: fall through to slow path (error)
                                }
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path: full environment chain walk ---
                    bool found = false;
                    EnvRecord* ic_env = null;
                    int ic_prop_idx = -1;

                    // Search lexical environment first (for let/const bindings)
                    EnvRecord* cur = ds.act.lex_env;
                    while (cur != null) {
                        int idx = cur.bindings.find_prop_idx(key);
                        if (idx >= 0) {
                            // ENV_STRICT: GETVAR read traps removed — for needs_env=false
                            // lex_env == parent env, so a hit here is a legitimate parent
                            // lookup, not own-local. Own-local leaks surface as 'not defined'
                            // throws and are caught by test/test_register_locals.js.

                            TVal v_raw = cur.bindings.prop_values()[idx];
                            if (env::is_tdz_sentinel(&v_raw)) {
                                HString* name_hstr = (HString*)key;
                                if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return VM_ERROR~;
                                }
                                found = true; // prevent duplicate error
                            } else if (cur.bindings.get_prop_flags((uint)idx).is_accessor) {
                                // Accessor property: invoke getter
                                TVal getter = hobject::hobject_access_getter(v_raw);
                                if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                                    TVal this_tv;
                                    this_tv.set_object(cur.bindings);
                                    TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                                    if (vm.heap.has_error) {
                                        // Route through vm_throw_value so a JS try/catch can
                                        // still catch it and an async module/function body's
                                        // uncaught throw rejects its own promise instead of
                                        // hard-faulting the VM (mirrors dispatch_property's
                                        // getter-throw handling in vm_property.c3).
                                        vm.heap.has_error = false;
                                        TVal err_val = vm.heap.error_value;
                                        if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                            vm.has_error = true;
                                            vm.heap.has_error = true;
                                            return VM_ERROR~;
                                        }
                                        found = true; // prevent duplicate error
                                    } else {
                                        vm.heap.tval_copy_ref(ra, &getter_val);
                                        track_heap_store(ds.act, ra, (uint)insn.a);
                                        found = true;
                                        ic_env = cur;
                                        ic_prop_idx = idx;
                                    }
                                } else {
                                    ra.set_undefined();
                                    track_heap_store(ds.act, ra, (uint)insn.a);
                                    found = true;
                                    ic_env = cur;
                                    ic_prop_idx = idx;
                                }
                            } else {
                                vm.heap.tval_copy_ref(ra, &v_raw);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            }
                            break;
                        }
                        cur = cur.parent;
                    }

                    if (!found && ds.act.lex_env != ds.act.var_env) {
                        // Not in lex_env — search var_env (only needed with `with` blocks)
                        EnvRecord* vcur = ds.act.var_env;
                        while (vcur != null) {
                            int vidx = vcur.bindings.find_prop_idx(key);
                            if (vidx >= 0) {
                                // ENV_STRICT: no trap here. For needs_env=false
                                // functions ds.act.var_env IS the parent env (no
                                // own scope), so a binding found at this hop is a
                                // legitimate parent/global lookup, not an own-local
                                // access. A genuine own-local leak instead surfaces
                                // as a "not defined" throw (its DECLVAR was elided
                                // and nothing else defines it), caught by the corpus.

                                if (vcur.bindings.get_prop_flags((uint)vidx).is_accessor) {
                                    TVal gs_slot = vcur.bindings.prop_values()[vidx];
                                    TVal getter = hobject::hobject_access_getter(gs_slot);
                                    if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                                        TVal this_tv;
                                        this_tv.set_object(vcur.bindings);
                                        TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                                        if (vm.heap.has_error) {
                                            // Route through vm_throw_value (see the lex_env
                                            // accessor branch above for why: async body
                                            // rejection + try/catch must both still work).
                                            vm.heap.has_error = false;
                                            TVal err_val = vm.heap.error_value;
                                            if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                                vm.has_error = true;
                                                vm.heap.has_error = true;
                                                return VM_ERROR~;
                                            }
                                            found = true;
                                            break;
                                        }
                                        vm.heap.tval_copy_ref(ra, &getter_val);
                                    } else {
                                        ra.set_undefined();
                                    }
                                } else {
                                    TVal v2 = vcur.bindings.prop_values()[vidx];
                                    vm.heap.tval_copy_ref(ra, &v2);
                                }
                                track_heap_store(ds.act, ra, (uint)insn.a);
                                found = true;
                                break;
                            }
                            vcur = vcur.parent;
                        }
                    }

                    if (found) {
                        // Populate IC
                        if (ds.var_ic_base != null && ic_env != null) {
                            uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                            hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                            vic.env = ic_env;
                            vic.bindings = ic_env.bindings;
                            vic.shape_id = ic_env.bindings.shape_id;
                            vic.generation = vm.heap.shapes[ic_env.bindings.shape_id].generation;
                            vic.prop_idx = (ushort)ic_prop_idx;
                            if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                            vic.key = key;
                            if (key != null) { ((types::HeapHeader*)key).incref(); }
                            vic.search_head = (void*)ds.act.lex_env;
                        }
                    } else {
                        // ReferenceError: variable not declared
                        HString* name_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "%s is not defined", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            continue;
        }

        case Opcode.TYPEOFIDENT: {
            // ES5 §11.4.3: typeof on an unresolvable reference returns "undefined"
            // instead of throwing ReferenceError.
            // ES6: typeof on a TDZ variable THROWS ReferenceError.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- Variable IC fast path ---
                    if (ds.var_ic_base != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                        if (vic.env != null && vic.key == key && vic.search_head == (void*)ds.act.lex_env) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                // Accessor properties store a getter/setter pair, not the
                                // actual value.  Fall through to slow path which invokes the getter.
                                if (b.get_prop_flags(vic.prop_idx).is_accessor) {
                                    // Invalidate IC — slow path will handle it.
                                } else {
                                    TVal v = b.prop_values()[vic.prop_idx];
                                    if (!env::is_tdz_sentinel(&v)) {
                                        // ENV_STRICT: TYPEOFIDENT read traps removed — for needs_env=false
                                        // lex_env == parent env, so a hit here is a legitimate parent
                                        // lookup, not own-local. Own-local leaks surface as 'not defined'
                                        // throws and are caught by test/test_register_locals.js.
                                        HString* ts = typeof_string(vm, &v);
                                        vm.heap.set_reg_string(ra, ts);
                                        break;
                                    }
                                    // TDZ: fall through to slow path (error)
                                }
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path ---
                    bool found = false;
                    EnvRecord* ic_env = null;
                    int ic_prop_idx = -1;

                    // Search lexical environment first (for let/const bindings)
                    EnvRecord* cur = ds.act.lex_env;
                    while (cur != null) {
                        int idx = cur.bindings.find_prop_idx(key);
                        if (idx >= 0) {
                            // ENV_STRICT: TYPEOFIDENT read traps removed — for needs_env=false
                            // lex_env == parent env, so a hit here is a legitimate parent
                            // lookup, not own-local. Own-local leaks surface as 'not defined'
                            // throws and are caught by test/test_register_locals.js.

                            TVal v_raw = cur.bindings.prop_values()[idx];
                            if (env::is_tdz_sentinel(&v_raw)) {
                                // TDZ: throw ReferenceError (ES6 behavior)
                                HString* name_hstr = (HString*)key;
                                if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return VM_ERROR~;
                                }
                            } else if (cur.bindings.get_prop_flags((uint)idx).is_accessor) {
                                // Accessor property: invoke getter for typeof
                                TVal getter = hobject::hobject_access_getter(v_raw);
                                bool getter_threw = false;
                                if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                                    TVal this_tv;
                                    this_tv.set_object(cur.bindings);
                                    TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                                    if (vm.heap.has_error) {
                                        // Route through vm_throw_value (see GETVAR's accessor
                                        // branch above for why).
                                        vm.heap.has_error = false;
                                        TVal err_val = vm.heap.error_value;
                                        if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                            vm.has_error = true;
                                            vm.heap.has_error = true;
                                            return VM_ERROR~;
                                        }
                                        getter_threw = true;
                                    } else {
                                        HString* ts = typeof_string(vm, &getter_val);
                                        vm.heap.set_reg_string(ra, ts);
                                    }
                                } else {
                                    // No getter → typeof returns "undefined"
                                    HString* ts = (HString*)vm.heap.strs[heap::BuiltinStr.UNDEFINED];
                                    vm.heap.set_reg_string(ra, ts);
                                }
                                found = true;
                                // A caught/rejected throw already unwound curr_pc/activations —
                                // must not cache an IC entry keyed on this (now stale) pc_off.
                                if (!getter_threw) {
                                    ic_env = cur;
                                    ic_prop_idx = idx;
                                }
                            } else {
                                HString* ts = typeof_string(vm, &v_raw);
                                vm.heap.set_reg_string(ra, ts);
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            }
                            break;
                        }
                        cur = cur.parent;
                    }

                    if (!found) {
                        // Not in lex_env — search var_env
                        EnvRecord* vcur2 = ds.act.var_env;
                        while (vcur2 != null) {
                            int vidx2 = vcur2.bindings.find_prop_idx(key);
                            if (vidx2 >= 0) {
                                // ENV_STRICT: no trap here (var_env == parent env
                                // when needs_env=false; see GETVAR note above).

                                if (vcur2.bindings.get_prop_flags((uint)vidx2).is_accessor) {
                                    TVal gs_slot2 = vcur2.bindings.prop_values()[vidx2];
                                    TVal getter2 = hobject::hobject_access_getter(gs_slot2);
                                    if (!getter2.is_undefined() && !getter2.is_null() && vm.heap.call_fn != null) {
                                        TVal this_tv2;
                                        this_tv2.set_object(vcur2.bindings);
                                        TVal getter_val2 = vm.heap.call_fn(vm, getter2, null, 0, this_tv2);
                                        if (vm.heap.has_error) {
                                            // Route through vm_throw_value (see GETVAR's
                                            // accessor branch above for why).
                                            vm.heap.has_error = false;
                                            TVal err_val = vm.heap.error_value;
                                            if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                                vm.has_error = true;
                                                vm.heap.has_error = true;
                                                return VM_ERROR~;
                                            }
                                        } else {
                                            HString* ts2 = typeof_string(vm, &getter_val2);
                                            vm.heap.set_reg_string(ra, ts2);
                                        }
                                    } else {
                                        HString* ts2 = (HString*)vm.heap.strs[heap::BuiltinStr.UNDEFINED];
                                        vm.heap.set_reg_string(ra, ts2);
                                    }
                                } else {
                                    TVal v2 = vcur2.bindings.prop_values()[vidx2];
                                    HString* ts = typeof_string(vm, &v2);
                                    vm.heap.set_reg_string(ra, ts);
                                }
                                found = true;
                                break;
                            }
                            vcur2 = vcur2.parent;
                        }
                        if (!found) {
                            // Unresolvable reference → "undefined" (no error)
                            HString* ts = (HString*)vm.heap.strs[heap::BuiltinStr.UNDEFINED];
                            vm.heap.set_reg_string(ra, ts);
                        }
                    }

                    // Populate IC (skip for unresolvable — no env to cache)
                    if (found && ds.var_ic_base != null && ic_env != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                        vic.env = ic_env;
                        vic.bindings = ic_env.bindings;
                        vic.shape_id = ic_env.bindings.shape_id;
                        vic.generation = vm.heap.shapes[ic_env.bindings.shape_id].generation;
                        vic.prop_idx = (ushort)ic_prop_idx;
                        if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                        vic.key = key;
                        if (key != null) { ((types::HeapHeader*)key).incref(); }
                        vic.search_head = (void*)ds.act.lex_env;
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            continue;
        }

        case Opcode.PUTVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    // ENV_STRICT TODO: own-vs-parent check for lex_env and var_env walks.
                    // Would need to introspect env_try_put_lex or rewrite walk here.
                    // Combined single-walk: check lex_env, writability, and update in one pass
                    int put_result = env::env_try_put_lex(ds.act.lex_env, key, *ra);
                    if (put_result == -1) {
                        // Const violation — throw TypeError
                        HString* name_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        break;
                    } else if (put_result == 0) {
                        // Not in lex_env — fall through to var_env
                        env::env_put(ds.act.var_env, key, *ra);
                    }
                    // put_result == 1: already updated in lex_env
                    // Release ra's ref — the binding now owns the reference.
                    // Without this, ra holds a stale ref into the next iteration,
                    // causing strings to leak (not reach rc=0 on binding overwrite).
                    vm.heap.decref_tval(ra);
                    ra.set_undefined();
                }
            }
            continue;
        }

        case Opcode.PUTVAR_ASSIGN: {
            // User assignment: like PUTVAR but throws ReferenceError for a
            // let/const binding still in its temporal dead zone.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- VarIC fast path: skip the env-chain walk on repeat writes ---
                    // Mirrors the GETVAR/INC_VAR ICs. Only hits for a binding that
                    // already resolved (below) to a writable, non-accessor, non-TDZ
                    // slot; const/TDZ/accessor cases never populate, so they always
                    // take the slow path (which throws or invokes a setter). The
                    // search_head guard ties the cache to the current lex_env chain,
                    // so a shadowing let/const in an enclosing block invalidates it.
                    if (ds.var_ic_base != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                        if (vic.env != null && vic.key == key && vic.search_head == (void*)ds.act.lex_env) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                TVal* pv = &b.prop_values()[vic.prop_idx];
                                hobject::PropFlags fl = b.get_prop_flags(vic.prop_idx);
                                if (!env::is_tdz_sentinel(pv) && fl.writable && !fl.is_accessor) {
                                    // Move ra's value into the slot: decref the old
                                    // slot value, take ra's reference, clear ra. Net
                                    // refcount effect matches the slow path
                                    // (binding gains a ref, register loses one).
                                    vm.heap.decref_tval(pv);
                                    *pv = *ra;
                                    ra.set_undefined();
                                    break;
                                }
                            }
                            vic.env = null;
                        }
                    }

                    int put_result = env::env_try_put_lex(ds.act.lex_env, key, *ra, true);
                    if (put_result == -1) {
                        HString* name_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        break;
                    } else if (put_result == -2) {
                        HString* name_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        break;
                    } else if (put_result == 0) {
                        // Not in lex env — check var env. In strict mode, assigning
                        // to an identifier that does not exist anywhere in the scope
                        // chain throws ReferenceError (ES5 §11.13.1 / ES2015 §12.15.4).
                        if (vm.current_func.is_strict() && !env::env_has(ds.act.var_env, key)) {
                            HString* name_hstr = (HString*)key;
                            if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "'%s' is not defined", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            break;
                        }
                        env::env_put(ds.act.var_env, key, *ra);
                    }
                    vm.heap.decref_tval(ra);
                    ra.set_undefined();

                    // Populate the VarIC for next time. The binding just resolved
                    // either in the lex chain (put_result == 1) or in var_env
                    // (put_result == 0); cache whichever env actually owns it so a
                    // shadowing same-named binding elsewhere can never be picked up.
                    // Only cache writable, non-accessor slots — the fast path's
                    // guard trusts a plain write.
                    if (ds.var_ic_base != null) {
                        EnvRecord* owner = null;
                        int owner_idx = -1;
                        if (put_result == 1) {
                            EnvRecord* cur = ds.act.lex_env;
                            while (cur != null) {
                                int idx = cur.bindings.find_prop_idx(key);
                                if (idx >= 0) { owner = cur; owner_idx = idx; break; }
                                cur = cur.parent;
                            }
                        } else {
                            int idx = ds.act.var_env.bindings.find_prop_idx(key);
                            if (idx >= 0) { owner = ds.act.var_env; owner_idx = idx; }
                        }
                        if (owner != null && owner_idx >= 0) {
                            hobject::PropFlags fl = owner.bindings.get_prop_flags((uint)owner_idx);
                            if (fl.writable && !fl.is_accessor) {
                                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                                hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                                vic.env = (void*)owner;
                                vic.bindings = (void*)owner.bindings;
                                vic.shape_id = owner.bindings.shape_id;
                                vic.generation = vm.heap.shapes[owner.bindings.shape_id].generation;
                                vic.prop_idx = (ushort)owner_idx;
                                if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                                vic.key = key;
                                if (key != null) { ((types::HeapHeader*)key).incref(); }
                                vic.search_head = (void*)ds.act.lex_env;
                            }
                        }
                    }
                }
            }
            continue;
        }

        case Opcode.DECLVAR: {
            // Declare a `var` binding in the immediate var_env only (no chain walk).
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    $if types::ENV_STRICT:
                    if (vm.current_func.needs_env() == false) { unreachable("ENV_STRICT: needs_env=false fn touched own env: DECLVAR"); }
                    $endif

                    // --- VarIC fast path: skip find_prop_idx on repeat calls ---
                    if (ds.var_ic_base != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                        if (vic.env == (void*)ds.act.var_env && vic.key == key) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b != null && b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                // Direct write — skip find_prop_idx + put_prop overhead
                                TVal* pv = &b.prop_values()[vic.prop_idx];
                                if (hobject::_active_heap != null && pv.is_string()) {
                                    ((heap::Heap*)hobject::_active_heap).decref_tval(pv);
                                }
                                *pv = *ra;
                                if (hobject::_active_heap != null && ra.is_string()) {
                                    void* ptr = ra.get_heapptr();
                                    if (ptr != null) ((types::HeapHeader*)ptr).incref();
                                }
                                break;
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path: full env_declare ---
                    // Global-scope var/function declarations install a
                    // non-configurable own property on the global object for
                    // Script code, but a configurable one for eval code
                    // (ES2015 §8.1.1.4.15/.17, §15.1.11 vs §18.2.1.2).
                    env::env_declare_var(ds.act.var_env, key, *ra,
                        ds.act.var_env == vm.global_env,
                        ((CompiledFunction*)ds.act.func).is_eval_fn());

                    // Populate VarIC for next time
                    if (ds.var_ic_base != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                        HObject* b = ds.act.var_env.bindings;
                        if (b != null) {
                            int idx = b.find_prop_idx(key);
                            if (idx >= 0) {
                                vic.env = (void*)ds.act.var_env;
                                vic.bindings = (void*)b;
                                vic.shape_id = b.shape_id;
                                vic.generation = vm.heap.shapes[b.shape_id].generation;
                                vic.prop_idx = (ushort)idx;
                                vic.key = key;
                                vic.search_head = null;
                            }
                        }
                    }
                }
            }
            continue;
        }

        case Opcode.PUTLEX: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    $if types::ENV_STRICT:
                    if (vm.current_func.needs_env() == false) { unreachable("ENV_STRICT: needs_env=false fn touched own env: PUTLEX"); }
                    $endif

                    env::env_declare_lex(ds.act.lex_env, key, *ra);
                }
            }
            continue;
        }

        case Opcode.PUTLEX_C: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    $if types::ENV_STRICT:
                    if (vm.current_func.needs_env() == false) { unreachable("ENV_STRICT: needs_env=false fn touched own env: PUTLEX_C"); }
                    $endif

                    ds.act.lex_env.bindings.put_prop(key, *ra, hobject::PROP_FLAGS_EC);
                }
            }
            continue;
        }

        case Opcode.INITTZ: {
            // Store the TDZ sentinel for a variable name in the current
            // lexical environment.  This marks the binding as uninitialized
            // so that GETVAR throws a ReferenceError (temporal dead zone)
            // if the variable is accessed before its PUTLEX/PUTLEX_C.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // No ENV_STRICT trap here: INITTZ targets the innermost
                    // PUSH_LEX block environment, which exists even for
                    // needs_env=false functions — the elide pass keeps a
                    // sentinel alive when a TYPEOFIDENT references its name.

                    TVal tdz = env::tdz_sentinel();
                    ds.act.lex_env.bindings.put_prop(key, tdz, hobject::PROP_FLAGS_WEC);
                }
            }
            continue;
        }

        case Opcode.CHKGLOBALLEX:
        case Opcode.CHKGLOBALVAR:
        case Opcode.CHKGLOBALFUNC: {
            // GlobalDeclarationInstantiation static checks (ES2015 §15.1.11),
            // run before any binding is instantiated so a collision throws
            // with no observable side effects.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    HObject* globals = vm.global_env.bindings;
                    HObject* lex = vm.global_lex_env != null ? vm.global_lex_env.bindings : null;

                    bool has_lex = lex != null && lex.find_prop_idx(key) >= 0;
                    int gidx = globals.find_prop_idx(key);
                    bool has_global = gidx >= 0;

                    if (op == Opcode.CHKGLOBALLEX) {
                        // A lexical name may not collide with an existing var
                        // binding (own global property) or global lexical
                        // binding, nor a restricted (non-configurable) global
                        // property (HasRestrictedGlobalProperty).
                        bool restricted = has_global
                            && !globals.get_prop_flags((uint)gidx).configurable;
                        if (has_lex || restricted) {
                            HString* nm = (HString*)key;
                            if (!vm_throw_error_fmt(vm, vm.heap.syntax_err_proto,
                                "Identifier '%s' has already been declared", nm.get_cstr(),
                                ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            break;
                        }
                    } else if (op == Opcode.CHKGLOBALVAR) {
                        // A var name may not collide with a global lexical
                        // binding (SyntaxError); otherwise CanDeclareGlobalVar
                        // must hold (TypeError when the global is not
                        // extensible and has no matching own property).
                        if (has_lex) {
                            HString* nm = (HString*)key;
                            if (!vm_throw_error_fmt(vm, vm.heap.syntax_err_proto,
                                "Identifier '%s' has already been declared", nm.get_cstr(),
                                ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            break;
                        }
                        if (!has_global && !globals.is_extensible()) {
                            HString* nm = (HString*)key;
                            if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto,
                                "Cannot declare global variable '%s'", nm.get_cstr(),
                                ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            break;
                        }
                    } else {
                        // CHKGLOBALFUNC — a function name is a var-declared
                        // name, so it may not collide with a global lexical
                        // binding (SyntaxError); otherwise
                        // CanDeclareGlobalFunction must hold: definable when no
                        // own prop and extensible, or the prop is configurable,
                        // or it is a writable+enumerable data property; else
                        // TypeError.
                        if (has_lex) {
                            HString* nm = (HString*)key;
                            if (!vm_throw_error_fmt(vm, vm.heap.syntax_err_proto,
                                "Identifier '%s' has already been declared", nm.get_cstr(),
                                ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            break;
                        }
                        bool definable;
                        if (!has_global) {
                            definable = globals.is_extensible();
                        } else {
                            hobject::PropFlags pf = globals.get_prop_flags((uint)gidx);
                            definable = pf.configurable
                                || (!pf.is_accessor && pf.writable && pf.enumerable);
                        }
                        if (!definable) {
                            HString* nm = (HString*)key;
                            if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto,
                                "Cannot declare global function '%s'", nm.get_cstr(),
                                ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            break;
                        }
                    }
                }
            }
            continue;
        }

        case Opcode.DELVAR:
            ra.set_boolean(true);
            continue;

        // === CLOSURES ===
        case Opcode.CLOSURE:
        case Opcode.GETBOUND:
            if (catch err = dispatch_closures(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === ITERATOR ===
        case Opcode.INITFOR:
        case Opcode.NEXTFOR:
            if (catch err = dispatch_iterator(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === EXCEPTION HANDLING ===
        case Opcode.TRY:
        case Opcode.ENDTRY:
        case Opcode.THROW:
        case Opcode.THROW_REF:
        case Opcode.THROW_SYNTAX:
        case Opcode.CATCH:
        case Opcode.FINALLY:
        case Opcode.ENDFINALLY:
            if (catch err = dispatch_exceptions(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === MISC ===
        case Opcode.NOP:
        case Opcode.DEBUGGER:
        case Opcode.BREAK:
        case Opcode.CONTINUE:
        case Opcode.INITGET:
        case Opcode.INITSET:
        case Opcode.INITSETI:
        case Opcode.INITPROP:
        case Opcode.INITPROPN:
        case Opcode.CLASS_INITGET:
        case Opcode.CLASS_INITSET:
        case Opcode.CLASS_INITPROP:
        case Opcode.CSVARI:
        case Opcode.PUSH_LEX:
        case Opcode.POP_LEX:
        case Opcode.PUSH_VAR:
        case Opcode.POP_VAR:
        case Opcode.REQUIRE_OBJ:
        case Opcode.CHKOBJ:
        case Opcode.ITER_CLOSE:
        case Opcode.CHKCTOR:
        case Opcode.CHK_PROT:
        case Opcode.NEW_PRIV_SYM:
        case Opcode.ADD_BRAND:
        case Opcode.CHK_BRAND:
        case Opcode.INITPROP_PRIV:
            if (catch err = dispatch_misc(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        default:
            return VM_ERROR~;
        }
    }
    }
    return vm.return_val;
}