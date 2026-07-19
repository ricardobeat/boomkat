module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::re_bindings;
import std::math;

// ============================================================================
// vm_calls — function/object/generator call dispatch
// ============================================================================

/// Finish initializing a strict `arguments` exotic object: set .length,
/// .callee, and @@iterator (ES2017+ §9.4.4.7 CreateUnmappedArgumentsObject).
/// Per spec, @@iterator must be the *same function object* as
/// %Array.prototype.values%, so callers must go through this helper rather
/// than re-deriving the value property-by-property at each call site.
fn void finish_arguments_object(Vm* vm, HObject* args_obj, HObject* callee, uint nargs) {
    HString* callee_key = (HString*)vm.heap.strs[heap::BuiltinStr.CALLEE];
    if (callee_key != null) {
        TVal callee_tv;
        callee_tv.set_object(callee);
        args_obj.put_prop(callee_key, callee_tv, hobject::PROP_FLAGS_WC);
    }
    HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
    if (length_key != null) {
        TVal length_tv;
        length_tv.set_fastint((long)nargs);
        args_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
    }
    HString* iter_sym = builtins::ensure_iterator_symbol(vm.heap);
    if (iter_sym != null && vm.heap.array_proto != null) {
        TVal? values_tv = vm.heap.array_proto.get_prop(iter_sym);
        if (try values_fn = values_tv) {
            args_obj.put_prop(iter_sym, values_fn, hobject::PROP_FLAGS_WC);
        }
    }
}

/// Sub-dispatch for CALL, CALL_S, CALL_PROP, SETPROTO, SUPER_CALL, SUPER_CALL_S, NEWTARGET, NEW_OBJ, NEW_OBJ_S, TAILCALL opcodes.
/// Initialize the pending derived-constructor this_binding after super()
/// produced the constructed object. super() may execute inside an arrow
/// function whose activation inherited the constructor's uninitialized (TDZ)
/// this — walk up through TDZ activations until the derived constructor
/// itself is initialized (§9.2.2 "initialized" state).
///
/// Returns true if the target derived-constructor frame's this_binding was
/// ALREADY initialized (i.e. this was a second super() call) — per §8.1.1.3.1
/// BindThisValue step 3, that must throw ReferenceError. The base-constructor
/// side effects (already executed by the time this runs, per §12.3.5.1 step 4
/// Construct-before-BindThisValue) still happened; only the this-binding is
/// left untouched here so the caller can throw.
fn bool super_init_this_chain(Vm* vm, Activation* act, TVal* constructed, Activation** bound_act = null) {
    // Intermediate frames with a real this (e.g. an object method that
    // invoked the super-capturing arrow) are skipped, not a stop condition;
    // the walk ends at the first derived-constructor frame — the one whose
    // super binding this call resolved through.
    Activation* a = act;
    ShadowActFrame* shadow = (ShadowActFrame*)vm.shadow_act_list;
    while (true) {
        if (a == null) {
            // The chain may cross a vm_call_fn_impl boundary (e.g. super()
            // inside an iterator .return() invoked by ITER_CLOSE). The outer
            // activations were memcpy-saved and their live slots zeroed —
            // continue into the saved copies; they are what gets restored.
            if (shadow == null) break;
            if (shadow.count == 0) { shadow = (ShadowActFrame*)shadow.prev; continue; }
            a = &shadow.acts[shadow.count - 1];
            shadow = (ShadowActFrame*)shadow.prev;
        }
        bool is_tdz = env::is_tdz_sentinel(&a.this_binding);
        if (is_tdz) {
            vm.heap.tval_copy_ref(&a.this_binding, constructed);
            a.flags |= ACT_FLAG_THIS_OWNED;
        }
        if ((a.flags & ACT_FLAG_DERIVED) != 0) {
            if (bound_act != null) *bound_act = a;
            return !is_tdz;
        }
        a = a.parent;
    }
    return false;
}

/// Private class fields (ES2022): stamp the class brand and run
/// `__field_init__(this)` at the spec-mandated point — right after `this` is
/// bound (base constructor: NEW_OBJ; derived constructor: super_init_this_chain).
/// `ctor_lex_env`/`ctor_var_env` are the CONSTRUCTOR ACTIVATION's own
/// environments (not the closure template's captured ones) — these are what
/// GETVAR/PUTLEX inside the constructor body itself resolve private-name
/// slots through, so using the same chain here keeps brand/field-init
/// lookups consistent with the constructor's own view of classScope even
/// when the activation's env was rebased (e.g. named-function-expression
/// self-binding). `target` is the constructor's CompiledFunction template;
/// `this_tv` is the bound instance.
///
/// Returns `true` on success (including "nothing to do" — no brand, no
/// fields). Returns `false` when duplicate initialization or field-init threw
/// and the throw was propagated via vm_throw_value/VM_ERROR — the caller must
/// abort the construct path (mirrors every other opcode-handler error convention:
/// `if (!vm_throw_error(...)) return VM_ERROR~;`).
fn bool? vm_init_private_members(Vm* vm, EnvRecord* ctor_lex_env, EnvRecord* ctor_var_env,
                                  CompiledFunction* target, TVal this_tv,
                                  Activation* act, Instruction** curr_pc, bool* needs_restart) {
    if (target == null) return true;
    if (target.brand_name_hstr == null && target.field_init_func == null) {
        return true;
    }
    if (!this_tv.is_object() || this_tv.get_heapptr() == null) return true;
    HObject* this_hobj = (HObject*)this_tv.get_heapptr();

    if (target.brand_name_hstr != null) {
        if (try brand_sym = env::env_get(ctor_lex_env, target.brand_name_hstr)) {
            if (brand_sym.is_string()) {
                void* brand_key = brand_sym.get_heapptr();
                if (brand_key != null) {
                    if (this_hobj.find_prop_idx(brand_key) >= 0) {
                        if (!vm_throw_error(vm, vm.heap.type_err_proto,
                                "Cannot initialize private members twice", act,
                                curr_pc, needs_restart)) {
                            return VM_ERROR~;
                        }
                        return false;
                    }
                    TVal true_tv;
                    true_tv.set_boolean(true);
                    this_hobj.put_prop(brand_key, true_tv, hobject::PROP_FLAGS_NNC);
                }
            }
        }
    }

    if (target.field_init_func != null) {
        CompiledFunction* field_init_template = target.field_init_func;
        HObject* field_init_fn = instantiate_closure(vm, field_init_template,
            ctor_var_env, ctor_lex_env, null);
        if (field_init_fn != null) {
            TVal field_init_tv;
            field_init_tv.set_object(field_init_fn);
            vm.heap.call_fn(vm, field_init_tv, null, 0, this_tv);
            if (vm.heap.has_error) {
                vm.heap.has_error = false;
                TVal err_val = vm.heap.error_value;
                if (!vm_throw_value(vm, err_val, act, curr_pc, needs_restart)) {
                    return VM_ERROR~;
                }
                return false;
            }
        }
    }
    return true;
}

/// Resolve an arrow's live lexical `this` when its CLOSURE-time captured
/// value was the TDZ sentinel (i.e. the arrow was defined inside a derived
/// constructor before super() ran). A value captured at closure-creation
/// time cannot observe super_init_this_chain()'s later in-place mutation of
/// the owning derived-constructor activation's this_binding, so on the TDZ
/// fallback path we re-walk from the calling activation — using the same
/// parent/shadow_act_list traversal as super_init_this_chain — to find that
/// activation's *current* this_binding. `caller_act` is the activation that
/// is invoking the arrow right now; for a well-formed program this is always
/// either the derived-constructor activation itself or a frame reached from
/// it via a still-live call chain (arrows referencing `this`/`super` cannot
/// legally escape their enclosing constructor's dynamic extent before it
/// returns). Returns the TDZ sentinel unchanged if no such frame is found.
fn TVal super_walk_live_this(Vm* vm, Activation* caller_act) {
    Activation* a = caller_act;
    ShadowActFrame* shadow = (ShadowActFrame*)vm.shadow_act_list;
    while (true) {
        if (a == null) {
            if (shadow == null) break;
            if (shadow.count == 0) { shadow = (ShadowActFrame*)shadow.prev; continue; }
            a = &shadow.acts[shadow.count - 1];
            shadow = (ShadowActFrame*)shadow.prev;
        }
        if ((a.flags & ACT_FLAG_DERIVED) != 0) return a.this_binding;
        a = a.parent;
    }
    return env::tdz_sentinel();
}

/// Same boundary-crossing walk for reading: find the nearest enclosing
/// activation (live or shadow-saved) that has a new_target.
fn HObject* super_walk_new_target(Vm* vm, Activation* act) {
    Activation* a = act;
    ShadowActFrame* shadow = (ShadowActFrame*)vm.shadow_act_list;
    while (true) {
        if (a == null) {
            if (shadow == null) return null;
            if (shadow.count == 0) { shadow = (ShadowActFrame*)shadow.prev; continue; }
            a = &shadow.acts[shadow.count - 1];
            shadow = (ShadowActFrame*)shadow.prev;
        }
        if (a.new_target != null) return a.new_target;
        a = a.parent;
    }
}

fn TVal? dispatch_calls(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.CALL:
        case Opcode.CALL_S: {
            // Safe point: run deferred GC before entering callee
            if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
            // Compiler convention: A=result_reg, B=callee_reg, C=nargs (or nargs_reg for CALL_S)
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs;
            if (op == Opcode.CALL_S) {
                // Read nargs from the register at index C
                TVal* nargs_slot = ds.regs_base + insn.c;
                if (nargs_slot.is_fastint()) {
                    nargs = (uint)nargs_slot.get_fastint();
                } else if (nargs_slot.is_number()) {
                    nargs = (uint)nargs_slot.get_number();
                } else {
                    nargs = 0;
                }
            } else {
                nargs = insn.c;
            }

            TVal* func_slot = ds.regs_base + callee_reg;
            TVal func_val = *func_slot;

            // === Fast path: direct compiled HObject call (most common) ===
            if (func_val.is_object()) {
                HObject* hobj_fast = (HObject*)func_val.get_heapptr();
                if (hobj_fast != null && hobj_fast.is_callable() && hobj_fast.callable_kind() == hobject::CallableKind.COMPILED_FN) {
                    CompiledFunction* target_fast = (*hobj_fast.extra_ptr()).func.comp_func;
                    if (target_fast == null) { ds.regs_base[result_reg].set_undefined(); break; }
                    // ES2015 §9.2.1 step 1: class constructors cannot be called without 'new'
                    if (target_fast.is_class_ctor()) {
                        char[256] name_buf;
                        uint copy_len = target_fast.name_len < 255 ? target_fast.name_len : 255;
                        mem::copy(&name_buf, target_fast.name_ptr, (sz)(copy_len));
                        name_buf[copy_len] = 0;
                        if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Class constructor %s cannot be invoked without 'new'", &name_buf[0], ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    if (!target_fast.is_generator()) {

                    // Async function: create Promise before entering body
                    HObject* async_prom = null;
                    if (target_fast.is_async()) {
                        HObject*? prom_raw = builtins::promise_create(vm.heap);
                        if (try p = prom_raw) {
                            async_prom = p;
                        } else {
                            ds.regs_base[result_reg].set_undefined();
                            return (TVal){};
                        }
                    }

                    // New callee frame starts right after func and this in the caller frame
                    uint frame_start = callee_reg + 2;
                    TVal* new_bottom = ds.regs_base + frame_start;
                    uint needed = (uint)(new_bottom - vm.valstack) + target_fast.num_regs;

                    if (!ensure_valstack(vm, needed)) {
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }

                    ds.regs_base = ds.act.bottom;
                    // Recompute new_bottom after realloc (ds.act.bottom may have moved)
                    new_bottom = ds.regs_base + frame_start;

                    if (vm.activation_count >= MAX_CALLS) {
                        if (!vm_throw_error(vm, vm.heap.range_err_proto, "Maximum call stack size exceeded", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }

                    // Save the 'this' value before clearing the slot, so that GC
                    // during env creation doesn't follow a stale object pointer
                    // from a previous call in the sliding-window model.
                    TVal saved_this = ds.regs_base[callee_reg + 1];
                    ds.regs_base[callee_reg + 1].set_undefined();

                    Activation* new_act = &vm.activations[vm.activation_count];

                    EnvRecord* fast_var_env;
                    // Arrow functions inherit their enclosing lexical environment —
                    // they don't get a fresh function scope, and they don't have a
                    // var_env of their own.  Use the captured lex_env directly.
                    if (target_fast.is_arrow()) {
                        EnvRecord* arrow_lex = (*hobj_fast.extra_ptr()).func.lex_env;
                        if (arrow_lex == null) {
                            ds.regs_base[result_reg].set_undefined();
                            return (TVal){};
                        }
                        fast_var_env = arrow_lex;
                    } else if (target_fast.needs_env()) {
                        // needs_env=true → the function actually accesses its scope at
                        // runtime (closures / eval / arguments / default-or-rest params /
                        // captured locals), so allocate a fresh scope object.
                        // Functions with plain parameters but needs_env=false no longer
                        // need one: the compiler elides their param/local DECLVARs (see
                        // the register-resident-locals pass in context.c3), so their
                        // bindings live purely in registers and cannot clobber the
                        // parent env. They reuse func.var_env (the parent) directly,
                        // skipping the per-call scope HObject allocation entirely.
                        fast_var_env = (*hobj_fast.extra_ptr()).func.var_env;
                        if (try fv_f = env::env_create_function_scope(vm.heap, (*hobj_fast.extra_ptr()).func.var_env)) { fast_var_env = fv_f; }
                    } else {
                        fast_var_env = (*hobj_fast.extra_ptr()).func.var_env;
                    }
                    if (fast_var_env == null) {
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }
                    new_act.parent = ds.act;
                    new_act.func = target_fast;
                    new_act.var_env = fast_var_env;
                    // Captured block scope + named-function-expression name
                    // binding (ES2015 §14.1.20) — shared with every other call
                    // path; see resolve_call_lex_env.
                    new_act.lex_env = resolve_call_lex_env(vm, hobj_fast, target_fast, fast_var_env);
                    // Bridge captured lex scope for default thunks that need
                    // to see TDZ sentinels in the parent's param scope.
                    if (target_fast.needs_lex_bridge()) {
                        EnvRecord* cap_lex = (*hobj_fast.extra_ptr()).func.lex_env;
                        if (cap_lex != null && cap_lex != fast_var_env) {
                            EnvRecord*? bridge = env::env_create_declarative(vm.heap, cap_lex);
                            if (try b = bridge) {
                                new_act.lex_env = b;
                            }
                        }
                    }
                    new_act.cat = null;
                    new_act.curr_pc = target_fast.code;
                    new_act.bottom = new_bottom;
                    new_act.retval = ds.regs_base + result_reg;
                    new_act.flags = 0;
                    if (target_fast.has_direct_eval()) {
                        new_act.flags |= ACT_FLAG_DIRECT_EVAL;
                    }
                    new_act.async_promise = null;
                    if (async_prom != null) {
                        new_act.flags |= ACT_FLAG_ASYNC;
                        new_act.async_promise = async_prom;
                    }
                    // A regular (non-construct) call has no [[NewTarget]]. The
                    // activation slot is pooled, so clear the stale value left
                    // by a prior `new` on the same slot; otherwise `new.target`
                    // inside a method called on a freshly-constructed object
                    // spuriously observes that constructor. Arrow functions
                    // instead resolve new.target lexically, from the value
                    // captured at their closure creation (§9.2.1).
                    new_act.new_target = target_fast.is_arrow()
                        ? (*hobj_fast.extra_ptr()).func.captured_new_target
                        : null;
                    new_act.max_heap_reg = 0;
                    new_act.caller_valstack_top = vm.valstack_top;
                    // Arrow functions use lexical this — captured once at
                    // CLOSURE-creation time (§9.2.1 [[ThisMode]]=lexical), not
                    // the calling activation's this_binding (which only
                    // coincidentally matches when an arrow is invoked from
                    // exactly the activation it was defined in). Exception: if
                    // the captured value is still the TDZ sentinel (arrow
                    // defined inside a derived constructor before super()
                    // ran), re-resolve the *live* this_binding via the same
                    // parent/shadow_act_list walk super_init_this_chain() uses
                    // to mutate it — a stale TDZ snapshot would never observe
                    // that later mutation.
                    TVal arrow_live_this;
                    if (target_fast.is_arrow() && env::is_tdz_sentinel(&(*hobj_fast.extra_ptr()).func.captured_this)) {
                        arrow_live_this = super_walk_live_this(vm, ds.act);
                    }
                    // ES5 §10.4.3: for non-strict (non-arrow) compiled functions,
                    // coerce null/undefined thisArg → global object.
                    {
                        TVal* this_src = target_fast.is_arrow()
                            ? (env::is_tdz_sentinel(&(*hobj_fast.extra_ptr()).func.captured_this) ? &arrow_live_this : &(*hobj_fast.extra_ptr()).func.captured_this)
                            : &saved_this;
                        TVal coerced_this;
                        bool used_coerced = false;
                        if (!target_fast.is_arrow() && !target_fast.is_strict() && (this_src.is_undefined() || this_src.is_null())) {
                            if (vm.global_env != null && vm.global_env.bindings != null) {
                                coerced_this.set_object(vm.global_env.bindings);
                                this_src = &coerced_this;
                                used_coerced = true;
                            }
                        }
                        if (!this_src.is_heap_allocated()) {
                            // this_binding for the previous use of this activation slot
                            // was already decreffed by handle_return (ACT_FLAG_THIS_OWNED).
                            // Plain overwrite — no ownership; handle_return will not decref.
                            new_act.this_binding = *this_src;
                        } else {
                            vm.heap.tval_copy_ref(&new_act.this_binding, this_src);
                            new_act.flags |= ACT_FLAG_THIS_OWNED;
                        }
                        (void)used_coerced;
                    }

                    // Activation fully initialized — now make it visible to GC.
                    vm.activation_count++;

                    TVal* new_regs = new_act.bottom;
                    uint new_nregs = target_fast.num_regs;

                    // Create arguments object BEFORE the rest parameter handling
                    // below overwrites new_regs[0] with the rest array. (Sliding
                    // window: new_regs aliases the caller's arg slots at this point.)
                    if (target_fast.uses_arguments()) {
                        HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                        if (try args_obj = args_obj_raw) {
                            for (uint ai = 0; ai < nargs; ai++) {
                                args_obj.set_array_idx(ai, new_regs[ai]);
                            }
                            args_obj.prototype = vm.heap.object_proto;
                            finish_arguments_object(vm, args_obj, hobj_fast, nargs);
                            HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                            if (args_name != null) {
                                TVal args_tv;
                                args_tv.set_object(args_obj);
                                env::env_declare(new_act.var_env, args_name, args_tv);
                            }
                        }
                    }

                    // Copy args: in the sliding-window model new_regs == old_args
                    // Values are already in place — set missing parameter registers
                    // to undefined so default parameter checks (param !== undefined) work.
                    uint formals = (uint)target_fast.num_formals;
                    if (target_fast.has_rest()) {
                        // Build rest array from overflow args (indices formals..nargs-1)
                        uint rest_idx = formals;
                        uint overflow = (nargs > formals) ? (nargs - formals) : 0;
                        HObject*? rest_arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                        if (try rest_arr = rest_arr_raw) {
                            rest_arr.prototype = vm.heap.array_proto;
                            for (uint ri = 0; ri < overflow; ri++) {
                                HString* rkey = vm.heap.int_to_hstring((long)ri);
                                if (rkey != null) {
                                    rest_arr.put_prop(rkey, new_regs[rest_idx + ri], hobject::PROP_FLAGS_WEC);
                                }
                            }
                            HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                            TVal len_val;
                            len_val.set_fastint((long)overflow);
                            rest_arr.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);
                            new_regs[rest_idx].set_object(rest_arr);
                        } else {
                            new_regs[rest_idx].set_undefined();
                        }
                        // Set missing formals (after rest) to undefined
                        if (nargs < formals) {
                            for (uint i = nargs; i < formals; i++) {
                                new_regs[i].set_undefined();
                            }
                        }
                        // Zero remaining registers (temps after rest)
                        uint zero_start = rest_idx + 1;
                        if (zero_start < new_nregs) {
                            zero_regs_undefined(new_regs, zero_start, new_nregs);
                        }
                    } else {
                        uint undef_limit = formals < new_nregs ? formals : new_nregs;
                        if (nargs < undef_limit) {
                            zero_regs_undefined(new_regs, nargs, undef_limit);
                        }
                        // Zero remaining registers (temps), but skip past any
                        // actual arguments already in the sliding-window slots.
                        uint zero_start = undef_limit > nargs ? undef_limit : nargs;
                        if (zero_start < new_nregs) {
                            zero_regs_undefined(new_regs, zero_start, new_nregs);
                        }
                    }

                    vm.valstack_top = new_regs + new_nregs;
                    vm.valstack_bottom = new_act.bottom;

                    // Save caller resume point before switching activations
                    ds.act.curr_pc = ds.curr_pc;

                    // Direct dispatch to new activation (avoid restart overhead)
                    ds.act = new_act;
                    vm.current_func = target_fast;
                    ds.code_base = target_fast.code;
                    ds.code_count = target_fast.code_count;
                    ds.code_end = ds.code_base + ds.code_count;
                    ds.ic_base = (hobject::ICEntry*)target_fast.ic_entries;
                    ds.var_ic_base = (hobject::VarICEntry*)target_fast.var_ic_entries;
                    ds.constants = target_fast.constants;
                    ds.nregs = target_fast.num_regs;
                    ds.curr_pc = ds.act.curr_pc;
                    ds.regs_base = ds.act.bottom;
                    return (TVal){};
                    }
                }
            }

            if (func_val.is_lightfunc()) {
                uint fn_idx = (uint)(usz)func_val.get_heapptr();

                {
                    TVal* lf_extended_top = ds.act.bottom + ds.nregs + 4;
                    if (lf_extended_top > vm.valstack_top) { vm.valstack_top = lf_extended_top; }
                }

                // Local result slot: builtins write pass-through results as
                // borrowed references (no incref). Written directly into a
                // register, a borrowed value below the frame's max_heap_reg
                // high-water mark is over-decrefed by decref_callee_regs at
                // RET and freed prematurely. The local + tval_copy_ref makes
                // the register reference owned (and survives a valstack
                // realloc inside the builtin) — same pattern as the HObject
                // builtin path below.
                TVal lf_result; lf_result.set_undefined();
                builtins::BuiltinContext ctx;
                ctx.vm = vm;
                ctx.regs = vm.valstack;
                ctx.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                ctx.argc = (ushort)nargs;
                ctx.result = &lf_result;
                ctx.heap = vm.heap;
                ctx.this_val = ds.regs_base[callee_reg + 1];
                ctx.is_constructor = false;
                ctx.needs_re_dispatch = false;
                ctx.re_nargs = 0;
                ctx.global_env = vm.global_env;
                ctx.should_throw = false;
                ctx.callee_obj = null;

                builtins::dispatch_builtin(fn_idx, &ctx);
                // Refresh ds.regs_base after possible valstack realloc inside builtin.
                ds.regs_base = ds.act.bottom;

                if (ctx.should_throw) {
                    if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &ctx.throw_value);
                    }
                    return (TVal){};
                }

                if (ctx.needs_re_dispatch) {
                    // Builtin (.call/.apply/bound) modified the stack — re-dispatch
                    func_val = ds.regs_base[callee_reg];
                    nargs = ctx.re_nargs;
                    // Fall through to OBJECT handling
                } else {
                    vm.heap.tval_copy_ref(ds.regs_base + result_reg, &lf_result);
                    track_heap_store(ds.act, ds.regs_base + result_reg, result_reg);
                    return (TVal){};
                }
            }

            if (!func_val.is_object()) {
                // TypeError: value is not a function
                HString* type_str = typeof_string(vm, &func_val);
                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a function", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // === OBJECT CALL HANDLING ===
            HObject* hobj = (HObject*)func_val.get_heapptr();
            if (hobj == null || !hobj.is_callable()) {
                // TypeError: object is not callable (e.g., a non-function object)
                HString* type_str = typeof_string(vm, &func_val);
                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a function", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // Handle bound function objects — dispatch to builtin_bound_call
            if (hobj.callable_kind() == hobject::CallableKind.BOUND_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    // Pre-grow the valstack so that bound_call's arg-prepend write
                    // (which extends past the current nargs into the frame's tail)
                    // lands in valid, GC-visible memory.  We must also advance
                    // vm.valstack_top past ds.nregs so the extra slots are within
                    // the allocated+visible range (even if no realloc is needed).
                    {
                        uint bound_margin = (uint)(ds.act.bottom - vm.valstack) + ds.nregs + 4;
                        if (!ensure_valstack(vm, bound_margin)) {
                            ds.regs_base[result_reg].set_undefined();
                            return (TVal){};
                        }
                        ds.regs_base = ds.act.bottom;
                        TVal* extended_top = ds.act.bottom + ds.nregs + 4;
                        if (extended_top > vm.valstack_top) { vm.valstack_top = extended_top; }
                    }
                    // Local result slot: keeps the register reference owned
                    // (borrowed pass-through results would be over-decrefed by
                    // the RET sweep) and survives valstack reallocs. See the
                    // lightfunc CALL path above.
                    TVal bound_result; bound_result.set_undefined();
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = &bound_result;
                    ctx.heap = vm.heap;
                    ctx.this_val = ds.regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                    // Refresh ds.regs_base after possible valstack realloc inside builtin.
                    ds.regs_base = ds.act.bottom;

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        return (TVal){};
                    }

                    if (ctx.needs_re_dispatch) {
                        func_val = ds.regs_base[callee_reg];
                        nargs = ctx.re_nargs;
                        // Safety: re-dispatch may produce a lightfunc (e.g., bound eval)
                        if (func_val.is_lightfunc()) {
                            uint lf_idx = (uint)(usz)func_val.get_heapptr();
                            TVal inner_result; inner_result.set_undefined();
                            builtins::BuiltinContext inner;
                            inner.vm = vm;
                            inner.regs = vm.valstack;
                            inner.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                            inner.argc = (ushort)nargs;
                            inner.result = &inner_result;
                            inner.heap = vm.heap;
                            inner.this_val = ds.regs_base[callee_reg + 1];
                            inner.is_constructor = false;
                            inner.needs_re_dispatch = false;
                            inner.re_nargs = 0;
                            inner.global_env = vm.global_env;
                            inner.should_throw = false;
                            inner.callee_obj = null;
                            builtins::dispatch_builtin(lf_idx, &inner);
                            // Refresh ds.regs_base after possible valstack realloc inside builtin.
                            ds.regs_base = ds.act.bottom;
                            if (inner.should_throw) {
                                if (!vm_throw_value(vm, inner.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return vm_uncaught_error(vm, &inner.throw_value);
                                }
                                return (TVal){};
                            }
                            vm.heap.tval_copy_ref(ds.regs_base + result_reg, &inner_result);
                            track_heap_store(ds.act, ds.regs_base + result_reg, result_reg);
                            return (TVal){};
                        }
                        if (func_val.is_object()) {
                            hobj = (HObject*)func_val.get_heapptr();
                            // If re-dispatch target is a builtin function, dispatch it directly.
                            if (hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN && (*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                                uint inner_fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                                TVal bound_inner_result; bound_inner_result.set_undefined();
                                builtins::BuiltinContext inner2;
                                inner2.vm = vm;
                                inner2.regs = vm.valstack;
                                inner2.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                                inner2.argc = (ushort)nargs;
                                inner2.result = &bound_inner_result;
                                inner2.heap = vm.heap;
                                inner2.this_val = ds.regs_base[callee_reg + 1];
                                inner2.is_constructor = false;
                                inner2.needs_re_dispatch = false;
                                inner2.re_nargs = 0;
                                inner2.global_env = vm.global_env;
                                inner2.should_throw = false;
                                inner2.callee_obj = hobj;
                                builtins::dispatch_builtin(inner_fn_idx, &inner2);
                                ds.regs_base = ds.act.bottom;
                                if (inner2.should_throw) {
                                    if (!vm_throw_value(vm, inner2.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        return vm_uncaught_error(vm, &inner2.throw_value);
                                    }
                                    return (TVal){};
                                }
                                vm.heap.tval_copy_ref(ds.regs_base + result_reg, &bound_inner_result);
                                track_heap_store(ds.act, ds.regs_base + result_reg, result_reg);
                                return (TVal){};
                            }
                            // Fall through to compiled function handling below
                        } else {
                            return (TVal){};
                        }
                    } else {
                        vm.heap.tval_copy_ref(ds.regs_base + result_reg, &bound_result);
                        track_heap_store(ds.act, ds.regs_base + result_reg, result_reg);
                        return (TVal){};
                    }
                } else {
                    return (TVal){};
                }
            } else if (hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    // Use a local result slot so that heap.call_fn-triggered valstack
                    // reallocations inside the builtin don't leave a stale ctx.result ptr.
                    TVal builtin_result; builtin_result.set_undefined();
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = &builtin_result;
                    ctx.heap = vm.heap;
                    ctx.this_val = ds.regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);

                    // Refresh ds.regs_base: valstack may have been reallocated if the
                    // builtin called heap.call_fn (e.g. TypedArray ctor with iterable arg).
                    ds.regs_base = ds.act.bottom;

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        return (TVal){};
                    }

                    if (!ctx.needs_re_dispatch) {
                        vm.heap.tval_copy_ref(ds.regs_base + result_reg, &builtin_result);
                        track_heap_store(ds.act, ds.regs_base + result_reg, result_reg);
                    }

                    if (ctx.needs_re_dispatch) {
                        // Re-dispatch: re-read target from stack
                        func_val = ds.regs_base[callee_reg];
                        nargs = ctx.re_nargs;
                        // Safety: check for lightfunc before casting to HObject*
                        if (func_val.is_lightfunc()) {
                            uint lf_idx = (uint)(usz)func_val.get_heapptr();
                            // Local result slot: a borrowed pass-through result
                            // written straight into the register file would be
                            // over-decrefed by the RET sweep (this exact path —
                            // boundFn(...) re-dispatching to a pass-through
                            // lightfunc like Promise.resolve — freed a live
                            // promise prematurely).
                            TVal inner_result; inner_result.set_undefined();
                            builtins::BuiltinContext inner;
                            inner.vm = vm;
                            inner.regs = vm.valstack;
                            inner.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                            inner.argc = (ushort)nargs;
                            inner.result = &inner_result;
                            inner.heap = vm.heap;
                            inner.this_val = ds.regs_base[callee_reg + 1];
                            inner.is_constructor = false;
                            inner.needs_re_dispatch = false;
                            inner.re_nargs = 0;
                            inner.global_env = vm.global_env;
                            inner.should_throw = false;
                            inner.callee_obj = null;
                            builtins::dispatch_builtin(lf_idx, &inner);
                            // Refresh ds.regs_base after possible valstack realloc inside builtin.
                            ds.regs_base = ds.act.bottom;
                            if (inner.should_throw) {
                                if (!vm_throw_value(vm, inner.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return vm_uncaught_error(vm, &inner.throw_value);
                                }
                                return (TVal){};
                            }
                            vm.heap.tval_copy_ref(ds.regs_base + result_reg, &inner_result);
                            track_heap_store(ds.act, ds.regs_base + result_reg, result_reg);
                            return (TVal){};
                        }
                        if (func_val.is_object()) {
                            hobj = (HObject*)func_val.get_heapptr();
                            // If re-dispatch target is a builtin function, dispatch it directly.
                            if (hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN && (*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                                uint inner_fn_idx2 = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                                TVal bfn_inner_result; bfn_inner_result.set_undefined();
                                builtins::BuiltinContext bfn_inner;
                                bfn_inner.vm = vm;
                                bfn_inner.regs = vm.valstack;
                                bfn_inner.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                                bfn_inner.argc = (ushort)nargs;
                                bfn_inner.result = &bfn_inner_result;
                                bfn_inner.heap = vm.heap;
                                bfn_inner.this_val = ds.regs_base[callee_reg + 1];
                                bfn_inner.is_constructor = false;
                                bfn_inner.needs_re_dispatch = false;
                                bfn_inner.re_nargs = 0;
                                bfn_inner.global_env = vm.global_env;
                                bfn_inner.should_throw = false;
                                bfn_inner.callee_obj = hobj;
                                builtins::dispatch_builtin(inner_fn_idx2, &bfn_inner);
                                ds.regs_base = ds.act.bottom;
                                if (bfn_inner.should_throw) {
                                    if (!vm_throw_value(vm, bfn_inner.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        return vm_uncaught_error(vm, &bfn_inner.throw_value);
                                    }
                                    return (TVal){};
                                }
                                vm.heap.tval_copy_ref(ds.regs_base + result_reg, &bfn_inner_result);
                                track_heap_store(ds.act, ds.regs_base + result_reg, result_reg);
                                return (TVal){};
                            }
                            if ((*hobj.extra_ptr()).func.comp_func != null) {
                                // Continue to compiled function handling below (skip error)
                            } else {
                                return (TVal){};
                            }
                        } else {
                            return (TVal){};
                        }
                    } else {
                        return (TVal){};
                    }
                } else {
                    // Callable object with no compiled function and no builtin index: error
                    HString* type_str = typeof_string(vm, &func_val);
                    if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a function", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return VM_ERROR~;
                    }
                    return (TVal){};
                }
            }

            CompiledFunction* target = null;
            // Safety: hobj may not have a comp_func (e.g., after bound function re-dispatch).
            // Only dereference if hobj is a compiled-function HObject.
            if (hobj != null && (*hobj.extra_ptr()).func.comp_func != null) {
                target = (*hobj.extra_ptr()).func.comp_func;
            } else {
                // Not a compiled function — result should already be set by the handler
                ds.regs_base[result_reg].set_undefined();
                return (TVal){};
            }

            // ES2015 §9.2.1 step 1: class constructors cannot be called without 'new'
            if (target.is_class_ctor()) {
                char[256] name_buf;
                uint copy_len = target.name_len < 255 ? target.name_len : 255;
                mem::copy(&name_buf, target.name_ptr, (sz)(copy_len));
                name_buf[copy_len] = 0;
                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Class constructor %s cannot be invoked without 'new'", &name_buf[0], ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // === Generator function handling (ES6 §25.3) ===
            HObject* async_prom = null;
            if (target.is_generator()) {
                // Resume path: .next()/.throw()/.return() set heap.resume_gen
                if (vm.heap.resume_gen != null && (CompiledFunction*)vm.heap.resume_gen.func == target) {
                    GeneratorState* gs = vm.heap.resume_gen;

                    if (gs.state == GEN_COMPLETED) {
                        vm.heap.resume_gen = null;
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }

                    // .throw() on SUSPENDED_START: exception before any body code
                    // (ES6 §25.3.3.4 step 8: resume with abrupt throw completion)
                    if (gs.state == GEN_SUSPENDED_START && gs.resume_kind == THROW) {
                        gs.state = GEN_COMPLETED;
                        vm.heap.resume_gen = null;
                        // Propagate exception to the .throw() caller
                        if (!vm_throw_value(vm, gs.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            vm.has_error = true;
                            vm.heap.has_error = true;
                            if (ds.act.retval != null) {
                                vm.heap.tval_copy_ref(ds.act.retval, &gs.throw_value);
                            }
                        }
                        ds.needs_restart = true;
                        return (TVal){};
                    }

                    // Set state to EXECUTING
                    gs.state = GEN_EXECUTING;

                    // Calculate register layout
                    uint frame_start_r = callee_reg + 2;
                    TVal* new_bottom_r = ds.regs_base + frame_start_r;
                    uint needed_r = (uint)(new_bottom_r - vm.valstack) + target.num_regs;

                    if (!ensure_valstack(vm, needed_r)) {
                        gs.state = GEN_SUSPENDED_YIELD;
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }

                    ds.regs_base = ds.act.bottom;
                    // Recompute new_bottom after realloc (ds.act.bottom may have moved)
                    new_bottom_r = ds.regs_base + frame_start_r;

                    if (vm.activation_count >= MAX_CALLS) {
                        gs.state = GEN_SUSPENDED_YIELD;
                        if (!vm_throw_error(vm, vm.heap.range_err_proto, "Maximum call stack size exceeded", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }

                    // Push activation
                    Activation* new_act_r = &vm.activations[vm.activation_count];
                    vm.activation_count++;
                    new_act_r.max_heap_reg = 0;
                    new_act_r.caller_valstack_top = vm.valstack_top;

                    new_act_r.parent = ds.act;
                    new_act_r.func = target;
                    new_act_r.var_env = gs.var_env;
                    new_act_r.lex_env = gs.lex_env;
                    new_act_r.cat = gs.cat;
                    new_act_r.curr_pc = gs.saved_pc;
                    new_act_r.bottom = new_bottom_r;
                    new_act_r.retval = ds.regs_base + result_reg;
                    new_act_r.async_gen_state = gs;
                    new_act_r.flags = ACT_FLAG_PREVENT_YIELD
                                    | (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0);
                    vm.heap.tval_copy_ref(&new_act_r.this_binding, &gs.this_binding);
                    new_act_r.flags |= ACT_FLAG_THIS_OWNED;

                    // Copy saved registers to valstack
                    $if $feature(HEAP_VERIFY):
                        vm.heap.verify_roots("before_call_resume_restore");
                        vm.heap.verify_tval_array(gs.saved_regs, gs.num_regs, "call_resume_saved_regs");
                    $endif
                    TVal* new_regs_r = new_act_r.bottom;
                    uint new_nregs_r = target.num_regs;
                    for (uint i = 0; i < new_nregs_r; i++) {
                        vm.heap.tval_copy_ref(&new_regs_r[i], &gs.saved_regs[i]);
                    }
                    // If yield fired inside a non-generator inner function
                    // (default expression thunk), place the resume value into
                    // the call result register so the code after CALL sees it.
                    bool thunk_yield_resume = (gs.pending_resume_reg != 0xFFFF);
                    if (gs.pending_resume_reg != 0xFFFF && gs.pending_resume_reg < new_nregs_r) {
                        vm.heap.tval_copy_ref(&new_regs_r[gs.pending_resume_reg], &gs.resume_value);
                        gs.pending_resume_reg = 0xFFFF;
                    }
                    $if $feature(HEAP_VERIFY):
                        vm.heap.verify_roots("after_call_resume_restore");
                    $endif

                    vm.valstack_top = new_regs_r + new_nregs_r;
                    vm.valstack_bottom = new_act_r.bottom;

                    // Save caller resume point before switching activation
                    ds.act.curr_pc = ds.curr_pc;

                    // A .return()/.throw() that resumes a yield suspended inside a
                    // non-generator thunk (e.g. `[x = yield]` default or `{}[yield]`
                    // computed key) is an ABRUPT completion at the generator's
                    // resume point — it must NOT resume normally with the value.
                    // The generator's frame has been restored above; now inject the
                    // completion into it so any enclosing try/finally (e.g. the
                    // destructuring IteratorClose guard) runs before the generator
                    // completes. Mirrors LOAD_RESUME's THROW/RETURN handling.
                    if (thunk_yield_resume &&
                        (gs.resume_kind == ResumeKind.RETURN || gs.resume_kind == ResumeKind.THROW)) {
                        ResumeKind tk = gs.resume_kind;
                        // Switch the dispatch state onto the restored generator
                        // activation so the injection targets its catcher chain.
                        ds.act = new_act_r;
                        ds.curr_pc = new_act_r.curr_pc;
                        ds.regs_base = new_act_r.bottom;
                        ds.nregs = new_nregs_r;

                        if (tk == ResumeKind.THROW) {
                            gs.resume_kind = NEXT;
                            TVal tval = gs.throw_value;
                            if (!vm_throw_value(vm, tval, ds.act, &ds.curr_pc, &ds.needs_restart, true)) {
                                gs.state = GEN_COMPLETED;
                                vm.heap.resume_gen = null;
                                vm.activation_count--;
                                vm.has_error = true; vm.heap.has_error = true;
                                if (new_act_r.retval != null) {
                                    vm.heap.tval_copy_ref(new_act_r.retval, &tval);
                                }
                            }
                            ds.needs_restart = true;
                            return (TVal){};
                        }

                        // RETURN: route through the nearest enclosing finally in
                        // the generator's catcher chain, else complete now.
                        TVal ret_raw = gs.return_value;
                        gs.resume_kind = NEXT;
                        Catcher* ret_fin_cat = (Catcher*)ds.act.cat;
                        while (ret_fin_cat != null && ret_fin_cat.finally_pc == null) {
                            ret_fin_cat = (Catcher*)ret_fin_cat.parent;
                        }
                        if (ret_fin_cat != null && ret_fin_cat.finally_pc != null) {
                            ret_fin_cat.return_val = ret_raw;
                            if (!(ret_fin_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                                ret_fin_cat.flags |= CATCHER_FLAG_PENDING_RETURN | CATCHER_FLAG_PENDING_RETURN_GEN;
                                ds.curr_pc = ret_fin_cat.finally_pc;
                                ds.act.curr_pc = ds.curr_pc;
                            }
                            ds.needs_restart = true;
                            return (TVal){};
                        }
                        gs.state = GEN_COMPLETED;
                        vm.heap.resume_gen = null;
                        vm_complete_generator_return(ds, &ret_raw);
                        return (TVal){};
                    }

                    ds.needs_restart = true;
                    return (TVal){};
                }

                // Async initial call: create Promise, fall through to non-generator path
                if (target.is_async()) {
                    HObject*? prom_raw = builtins::promise_create(vm.heap);
                    if (try p = prom_raw) {
                        async_prom = p;
                    } else {
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }
                    // Don't break — fall through to non-generator path below
                } else {
                // Initial call: run parameter initialization eagerly, then
                // suspend at the GEN_START opcode and return the generator object.
                // This ensures FunctionDeclarationInstantiation side-effects
                // (throwing defaults, destructuring errors) happen at call time
                // per ES2022 §27.5.3.2.

                // Calculate register layout
                uint frame_start = callee_reg + 2;
                TVal* new_bottom = ds.regs_base + frame_start;
                uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                if (!ensure_valstack(vm, needed)) {
                    ds.regs_base[result_reg].set_undefined();
                    return (TVal){};
                }

                ds.regs_base = ds.act.bottom;
                // Recompute new_bottom after realloc (ds.act.bottom may have moved)
                new_bottom = ds.regs_base + frame_start;

                if (vm.activation_count >= MAX_CALLS) {
                    {
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.range_err_proto;
                            HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                            HString* msg_val = intern_string(vm, "Maximum call stack size exceeded");
                            TVal msg_tv; msg_tv.set_string(msg_val);
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                            TVal err_val; err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                    }
                    return (TVal){};
                }

                // Allocate GeneratorState
                void* gs_raw = vm.heap.alloc_func(vm.heap.heap_udata, GeneratorState::size);
                if (gs_raw == null) {
                    ds.regs_base[result_reg].set_undefined();
                    return (TVal){};
                }
                GeneratorState* gs = (GeneratorState*)gs_raw;
                mem::clear(gs_raw, (sz)(GeneratorState::size));
                gs.pending_resume_reg = 0xFFFF;

                gs.func = target;
                gs.func_obj = hobj;
                gs.num_regs = target.num_regs;

                // Allocate saved register storage
                usz regs_bytes = (usz)target.num_regs * TVal::size;
                void* regs_raw;
                if (regs_bytes > 0) {
                    regs_raw = vm.heap.alloc_func(vm.heap.heap_udata, regs_bytes);
                    if (regs_raw == null) {
                        vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                        ds.regs_base[result_reg].set_undefined();
                        return (TVal){};
                    }
                    mem::clear(regs_raw, (sz)(regs_bytes));
                } else {
                    regs_raw = null;
                }
                gs.saved_regs = (TVal*)regs_raw;

                // Create Generator HObject before pushing the activation so the
                // GC can see it while param-init code runs.
                HObject*? gen_obj_raw = vm.heap.alloc_object(hobject::ObjClass.GENERATOR);
                HObject* gen_obj;
                if (try go = gen_obj_raw) {
                    gen_obj = go;
                } else {
                    vm.heap.free_func(vm.heap.heap_udata, gs.saved_regs);
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    ds.regs_base[result_reg].set_undefined();
                    return (TVal){};
                }
                // ES2015 §25.3.3 GeneratorFunction instance creation step 1:
                // OrdinaryCreateFromConstructor(functionObject, "%GeneratorPrototype%").
                // Deferred to GEN_START (after FunctionDeclarationInstantiation/
                // param-init has run) rather than resolved here: a default
                // parameter's side effect can still mutate functionObject.prototype
                // between this point and GEN_START, and step 1 must observe that
                // (generator-created-after-decl-inst.js). Default to the shared
                // Generator.prototype for now; GEN_START corrects it if needed.
                gen_obj.prototype = vm.heap.generator_proto;
                (*gen_obj.extra_ptr()).gen.generator_data = gs;

                // If a generator param-init is already in progress (gen_initial_gs
                // is non-null), save the outer state onto a small stack so it can
                // be restored when the inner generator's GEN_START completes.
                // Example: `*outer([[,] = innerGen()])` — calling innerGen() during
                // outer's param-init would otherwise clobber gen_initial_*.
                if (vm.heap.gen_initial_gs != null) {
                    uint depth = vm.heap.gen_init_stack_depth;
                    if (depth < 8) {
                        vm.heap.gen_init_stack_gs[depth] = vm.heap.gen_initial_gs;
                        vm.heap.gen_init_stack_obj[depth] = vm.heap.gen_initial_obj;
                        vm.heap.gen_init_stack_retval[depth] = vm.heap.gen_initial_retval;
                        vm.heap.gen_init_stack_depth = depth + 1;
                    }
                }

                // Stash the pending initial-call state so GEN_START can find it.
                vm.heap.gen_initial_gs = gs;
                vm.heap.gen_initial_obj = gen_obj;
                vm.heap.gen_initial_retval = ds.regs_base + result_reg;

                // Build a fresh var_env for the generator's param scope
                EnvRecord* gen_var_env = (*hobj.extra_ptr()).func.var_env;
                if (target.needs_env()) {
                    if (try fv_g = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) {
                        gen_var_env = fv_g;
                    }
                }

                // Push activation frame (same pattern as non-generator compiled calls)
                Activation* new_act_g = &vm.activations[vm.activation_count];
                vm.activation_count++;
                new_act_g.max_heap_reg = 0;
                new_act_g.caller_valstack_top = vm.valstack_top;
                new_act_g.parent = ds.act;
                new_act_g.func = target;
                new_act_g.var_env = gen_var_env;
                new_act_g.lex_env = resolve_call_lex_env(vm, hobj, target, gen_var_env);
                if (target.needs_lex_bridge()) {
                    EnvRecord* cap_lex_g = (*hobj.extra_ptr()).func.lex_env;
                    if (cap_lex_g != null && cap_lex_g != gen_var_env) {
                        EnvRecord*? bridge_g = env::env_create_declarative(vm.heap, cap_lex_g);
                        if (try b_g = bridge_g) {
                            new_act_g.lex_env = b_g;
                        }
                    }
                }
                new_act_g.cat = null;
                new_act_g.curr_pc = target.code;
                new_act_g.bottom = new_bottom;
                new_act_g.retval = ds.regs_base + result_reg;
                new_act_g.flags = 0;
                if (target.has_direct_eval()) {
                    new_act_g.flags |= ACT_FLAG_DIRECT_EVAL;
                }
                new_act_g.async_promise = null;
                new_act_g.async_gen_state = null;
                {
                    TVal raw_this_g = ds.regs_base[callee_reg + 1];
                    vm.heap.tval_copy_ref(&new_act_g.this_binding, &raw_this_g);
                    new_act_g.flags |= ACT_FLAG_THIS_OWNED;
                }

                // Initialize the valstack registers for the new activation.
                // Arguments are already in position at new_bottom via the
                // sliding-window layout: new_bottom == old_args start.
                TVal* new_regs_g = new_act_g.bottom;
                uint new_nregs_g = target.num_regs;

                if (target.has_rest()) {
                    uint copy_count_g = (uint)target.num_formals;
                    TVal* old_args_g = ds.regs_base + callee_reg + 2;
                    for (uint i = nargs; i < copy_count_g; i++) {
                        new_regs_g[i].set_undefined();
                    }
                    uint rest_idx_g = copy_count_g;
                    uint overflow_g = (nargs > copy_count_g) ? (nargs - copy_count_g) : 0;
                    HObject*? arr_raw_g = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                    if (try a_g = arr_raw_g) {
                        a_g.prototype = vm.heap.array_proto;
                        for (uint i = 0; i < overflow_g; i++) {
                            HString* key = vm.heap.int_to_hstring((long)i);
                            if (key != null) {
                                a_g.put_prop(key, old_args_g[copy_count_g + i], hobject::PROP_FLAGS_WEC);
                            }
                        }
                        HString* len_str_g = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                        TVal len_val_g;
                        len_val_g.set_fastint((long)overflow_g);
                        a_g.put_prop(len_str_g, len_val_g, hobject::PROP_FLAGS_WEC);
                        new_regs_g[rest_idx_g].set_object(a_g);
                    } else {
                        new_regs_g[rest_idx_g].set_undefined();
                    }
                    if (rest_idx_g + 1 < new_nregs_g) {
                        zero_regs_undefined(new_regs_g, rest_idx_g + 1, new_nregs_g);
                    }
                } else {
                    uint formals_g = (uint)target.num_formals;
                    uint undef_lim_g = formals_g < new_nregs_g ? formals_g : new_nregs_g;
                    if (nargs < undef_lim_g) {
                        zero_regs_undefined(new_regs_g, nargs, undef_lim_g);
                    }
                    uint zero_start_g = undef_lim_g > nargs ? undef_lim_g : nargs;
                    if (zero_start_g < new_nregs_g) {
                        zero_regs_undefined(new_regs_g, zero_start_g, new_nregs_g);
                    }
                }

                // arguments object for generators that reference it
                if (target.uses_arguments()) {
                    HObject*? args_obj_raw_g = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                    if (try args_obj_g = args_obj_raw_g) {
                        for (uint ai = 0; ai < nargs; ai++) {
                            args_obj_g.set_array_idx(ai, new_regs_g[ai]);
                        }
                        args_obj_g.prototype = vm.heap.object_proto;
                        finish_arguments_object(vm, args_obj_g, hobj, nargs);
                        HString* args_name_g = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                        if (args_name_g != null) {
                            TVal args_tv_g;
                            args_tv_g.set_object(args_obj_g);
                            env::env_declare(new_act_g.var_env, args_name_g, args_tv_g);
                        }
                    }
                }

                vm.valstack_top = new_regs_g + new_nregs_g;
                vm.valstack_bottom = new_act_g.bottom;

                // Save caller resume point and switch into the new activation.
                // The run loop will execute param-init code and stop at GEN_START.
                ds.act.curr_pc = ds.curr_pc;
                ds.act = new_act_g;
                vm.current_func = target;
                ds.code_base = target.code;
                ds.code_count = target.code_count;
                ds.code_end = ds.code_base + ds.code_count;
                ds.ic_base = (hobject::ICEntry*)target.ic_entries;
                ds.var_ic_base = (hobject::VarICEntry*)target.var_ic_entries;
                ds.constants = target.constants;
                ds.nregs = target.num_regs;
                ds.curr_pc = ds.act.curr_pc;
                ds.regs_base = ds.act.bottom;
                return (TVal){};
                } // end else (non-async generator initial call)
            }

            // New callee frame starts right after func and this in the caller frame
            // Layout: callee_reg = func, callee_reg+1 = this, callee_reg+2.. callee_reg+1+nargs = args
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = ds.regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                ds.regs_base[result_reg].set_undefined();
                return (TVal){};
            }

            ds.regs_base = ds.act.bottom;
            // Recompute new_bottom after realloc (ds.act.bottom may have moved)
            new_bottom = ds.regs_base + frame_start;

            if (vm.activation_count >= MAX_CALLS) {
                if (!vm_throw_error(vm, vm.heap.range_err_proto, "Maximum call stack size exceeded", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* call_var_env2 = (*hobj.extra_ptr()).func.var_env;
            // Only allocate a fresh scope when the function actually uses its env
            // (see the fast-call path above and the register-resident-locals pass).
            if (target.needs_env()) {
                if (try fv_c2 = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { call_var_env2 = fv_c2; }
            }
            new_act.parent = ds.act;
            new_act.func = target;
            new_act.var_env = call_var_env2;
            new_act.lex_env = resolve_call_lex_env(vm, hobj, target, call_var_env2);
            new_act.cat = null;
            new_act.curr_pc = target.code;
            new_act.bottom = new_bottom;
            new_act.retval = ds.regs_base + result_reg;
            new_act.flags = 0;
            if (target.has_direct_eval()) {
                new_act.flags |= ACT_FLAG_DIRECT_EVAL;
            }
            new_act.async_promise = null;
            new_act.async_gen_state = null;
            // A regular (non-construct) call has no [[NewTarget]]; clear the
            // stale value from a prior `new` that reused this pooled slot.
            // Arrows resolve new.target lexically from their captured value.
            new_act.new_target = target.is_arrow()
                ? (*hobj.extra_ptr()).func.captured_new_target
                : null;
            if (async_prom != null) {
                // Async function entered from the generator block above
                new_act.flags |= ACT_FLAG_ASYNC;
                new_act.async_promise = async_prom;
                // Write Promise to result register now so the caller gets it
                // if the function suspends at an AWAIT before returning.
                ds.regs_base[result_reg].set_object(async_prom);
            } else if (target.is_async()) {
                // Async function from the fast path or other path
                HObject*? prom_raw = builtins::promise_create(vm.heap);
                if (try p = prom_raw) {
                    new_act.flags |= ACT_FLAG_ASYNC;
                    new_act.async_promise = p;
                }
            }
            // Arrow functions use lexical this — captured once at
            // CLOSURE-creation time (§9.2.1 [[ThisMode]]=lexical), not the
            // calling activation's this_binding. Exception: a still-TDZ
            // captured value (arrow defined before super() ran) must be
            // re-resolved live — see super_walk_live_this().
            // ES5 §10.4.3: for non-arrow compiled functions, coerce null/undefined → global.
            if (target.is_arrow()) {
                TVal arrow_this2 = (*hobj.extra_ptr()).func.captured_this;
                if (env::is_tdz_sentinel(&arrow_this2)) {
                    arrow_this2 = super_walk_live_this(vm, ds.act);
                }
                vm.heap.tval_copy_ref(&new_act.this_binding, &arrow_this2);
            } else {
                TVal raw_this = ds.regs_base[callee_reg + 1];
                if (!target.is_strict() && (raw_this.is_undefined() || raw_this.is_null()) && vm.global_env != null && vm.global_env.bindings != null) {
                    raw_this.set_object(vm.global_env.bindings);
                }
                vm.heap.tval_copy_ref(&new_act.this_binding, &raw_this);
            }
            new_act.flags |= ACT_FLAG_THIS_OWNED;

            TVal* new_regs = new_act.bottom;
            uint new_nregs = target.num_regs;

            // Copy args
            TVal* old_args = ds.regs_base + callee_reg + 2;
            if (target.has_rest()) {
                // Only copy the formal parameters (not the rest parameter)
                uint copy_count = (uint)target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                }

                // Set missing formals to undefined (for default param checks)
                for (uint i = nargs; i < copy_count; i++) {
                    new_regs[i].set_undefined();
                }

                // Build rest array from overflow args
                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;

                HObject*? arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try a = arr_raw) {
                    a.prototype = vm.heap.array_proto;
                    // Copy overflow args into the array
                    for (uint i = 0; i < overflow; i++) {
                        HString* key = vm.heap.int_to_hstring((long)i);
                        if (key != null) {
                            TVal elem = old_args[copy_count + i];
                            a.put_prop(key, elem, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    // Set .length
                    HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val;
                    len_val.set_fastint((long)overflow);
                    a.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);

                    new_regs[rest_idx].set_object(a);
                } else {
                    new_regs[rest_idx].set_undefined();
                }

                // Fill remaining registers with UNDEFINED (after the rest param)
                if (rest_idx + 1 < new_nregs) {
                    mem::clear(&new_regs[rest_idx + 1], (sz)((usz)(new_nregs - rest_idx - 1) * TVal::size));
                }
            } else {
                // Args are already in position (new_regs == old_args, sliding window).
                // Skip self-copy when they point to the same location.
                if (new_regs != old_args) {
                    for (uint i = 0; i < nargs && i < (uint)target.num_args; i++) {
                        vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                    }
                }
                if (nargs < new_nregs) {
                    // Mirror the fast-path register-zeroing: only formal
                    // parameter slots that don't have a value are set to
                    // undefined, and the temp-register zeroing starts at
                    // max(formals, nargs) so the call args themselves stay
                    // in place. Without this, a bound re-dispatch where
                    // nargs > num_formals zeros the arg slots and the
                    // arguments object built from new_regs[0..nargs-1] is
                    // filled with zeros.
                    uint formals = (uint)target.num_formals;
                    uint undef_limit = formals < new_nregs ? formals : new_nregs;
                    if (nargs < undef_limit) {
                        for (uint zi = nargs; zi < undef_limit; zi++) {
                            new_regs[zi].set_undefined();
                        }
                    }
                    uint zero_start = undef_limit > nargs ? undef_limit : nargs;
                    if (zero_start < new_nregs) {
                        zero_regs_undefined(new_regs, zero_start, new_nregs);
                    }
                }
            }

            // Create arguments object for the new activation if the target
            // function references it. This is the slow-path mirror of the
            // fast-path version above — needed when the call re-dispatched
            // through a bound function (BUILTIN_FN → bound call → compiled
            // target via the fallback generic path) and the target uses
            // `arguments`. Without this, the function sees `arguments is
            // not defined` because the arguments object was never created.
            if (target.uses_arguments()) {
                HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                if (try args_obj = args_obj_raw) {
                    for (uint ai = 0; ai < nargs; ai++) {
                        args_obj.set_array_idx(ai, new_regs[ai]);
                    }
                    args_obj.prototype = vm.heap.object_proto;
                    finish_arguments_object(vm, args_obj, hobj, nargs);
                    HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                    if (args_name != null) {
                        TVal args_tv;
                        args_tv.set_object(args_obj);
                        env::env_declare(new_act.var_env, args_name, args_tv);
                    }
                }
            }

            vm.valstack_top = new_regs + new_nregs;
            vm.valstack_bottom = new_act.bottom;

            // Save caller resume point before switching activations
            ds.act.curr_pc = ds.curr_pc;

            // Direct dispatch to new activation (avoid restart overhead)
            ds.act = new_act;
            vm.current_func = target;
            ds.code_base = target.code;
            ds.code_count = target.code_count;
            ds.code_end = ds.code_base + ds.code_count;
            ds.ic_base = (hobject::ICEntry*)target.ic_entries;
            ds.var_ic_base = (hobject::VarICEntry*)target.var_ic_entries;
            ds.constants = target.constants;
            ds.nregs = target.num_regs;
            ds.curr_pc = ds.act.curr_pc;
            ds.regs_base = ds.act.bottom;
            return (TVal){};
        }

        case Opcode.CALL_PROP:
            ra.set_undefined();
            return (TVal){};

        case Opcode.SETPROTO: {
            // A.[[Prototype]] = B
            // ABC format: A=obj_reg, B=proto_reg
            // Used both for class inheritance and for `{ __proto__: value }` object literals.
            // Silently ignore non-object/non-null values (§12.2.6.1 step 3c).
            if (!ra.is_object()) return (TVal){};
            HObject* obj = (HObject*)ra.get_heapptr();
            if (obj == null) return (TVal){};
            if (rb.is_null()) {
                // `{ __proto__: null }` — set prototype to null (no prototype chain).
                obj.prototype = null;
            } else if (rb.is_object()) {
                HObject* proto = (HObject*)rb.get_heapptr();
                if (proto != null) {
                    obj.prototype = proto;
                }
            }
            // Non-object, non-null values are silently ignored per spec.
            return (TVal){};
        }

        case Opcode.GETPROTO: {
            // A = GetPrototypeOf(B) — proxy-aware prototype read for `super`
            // in object-literal methods (HomeObject semantics).
            if (!rb.is_object()) {
                ra.set_undefined();
                return (TVal){};
            }
            HObject* pobj = (HObject*)rb.get_heapptr();
            if (pobj == null) { ra.set_undefined(); return (TVal){}; }
            TVal proto_out;
            if (!builtins::object_get_proto(vm, vm.heap, pobj, &proto_out)) {
                TVal gp_err = vm.heap.error_value;
                vm.heap.has_error = false;
                if (!vm_throw_value(vm, gp_err, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &gp_err);
                }
                return (TVal){};
            }
            vm.heap.tval_copy_ref(ra, &proto_out);
            return (TVal){};
        }

        case Opcode.SUPER_CALL:
        case Opcode.SUPER_CALL_S: {
            // A = super(B, args...) — call superclass constructor
            // SUPER_CALL: C = immediate arg count
            // SUPER_CALL_S: C = register holding runtime arg count
            // Uses current activation's new.target
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs;
            if (op == Opcode.SUPER_CALL_S) {
                TVal* nargs_slot = ds.regs_base + insn.c;
                if (nargs_slot.is_fastint()) {
                    nargs = (uint)nargs_slot.get_fastint();
                } else if (nargs_slot.is_number()) {
                    nargs = (uint)nargs_slot.get_number();
                } else {
                    nargs = 0;
                }
            } else {
                nargs = insn.c;
            }

            TVal* super_slot = ds.regs_base + callee_reg;
            TVal super_val = *super_slot;

            // Handle lightfunc super constructors (Boolean, Number, String, etc.)
            if (super_val.is_lightfunc()) {
                uint fn_idx = (uint)(usz)super_val.get_heapptr();
                HObject* lf_ctor_proto = lightfunc_get_proto(vm, fn_idx);
                if (lf_ctor_proto == null) {
                    HString* type_str = typeof_string(vm, &super_val);
                    vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a constructor", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart);
                    return (TVal){};
                }
                HObject* lf_new_target = super_walk_new_target(vm, ds.act);
                if (lf_new_target == null) { ra.set_undefined(); return (TVal){}; }
                builtins::BuiltinContext ctx;
                ctx.vm = vm;
                ctx.regs = vm.valstack;
                ctx.base_reg = (ushort)((uint)(ds.act.bottom - vm.valstack) + callee_reg + 2);
                ctx.argc = (ushort)nargs;
                ctx.result = ds.regs_base + result_reg;
                ctx.heap = vm.heap;
                ctx.this_val = ds.regs_base[callee_reg + 1];
                ctx.is_constructor = true;
                ctx.needs_re_dispatch = false;
                ctx.re_nargs = 0;
                ctx.global_env = vm.global_env;
                ctx.should_throw = false;
                ctx.callee_obj = null;
                ctx.new_target = lf_new_target;
                builtins::dispatch_builtin(fn_idx, &ctx);
                if (ctx.should_throw) {
                    vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart);
                } else if (env::is_tdz_sentinel(&ds.act.this_binding)) {
                    // Initialize the derived constructor's this_binding with the
                    // object returned by the builtin super constructor (§9.2.2).
                    TVal* sc_result_lf = ds.regs_base + result_reg;
                    bool sc_already_bound = false;
                    Activation* sc_bound_act_lf = null;
                    if (sc_result_lf.is_object()) {
                        sc_already_bound = super_init_this_chain(vm, ds.act, sc_result_lf, &sc_bound_act_lf);
                    }
                    if (sc_already_bound) {
                        // §8.1.1.3.1 BindThisValue step 3: the derived-ctor
                        // frame this walk resolved to was already initialized.
                        vm_throw_error(vm, vm.heap.ref_err_proto, "Super constructor may only be called once", ds.act, &ds.curr_pc, &ds.needs_restart);
                    } else if (sc_bound_act_lf != null) {
                        CompiledFunction* sc_target_lf = (CompiledFunction*)sc_bound_act_lf.func;
                        vm_init_private_members(vm, sc_bound_act_lf.lex_env, sc_bound_act_lf.var_env,
                            sc_target_lf, sc_bound_act_lf.this_binding, ds.act, &ds.curr_pc, &ds.needs_restart)!;
                    }
                } else {
                    // §8.1.1.3.1 BindThisValue step 3: this_binding is already
                    // initialized (a prior super() call already bound it) —
                    // a second super() call throws ReferenceError.
                    vm_throw_error(vm, vm.heap.ref_err_proto, "Super constructor may only be called once", ds.act, &ds.curr_pc, &ds.needs_restart);
                }
                return (TVal){};
            }

            if (!super_val.is_object()) {
                // TypeError: superclass is not a constructor
                HString* type_str = typeof_string(vm, &super_val);
                vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a constructor", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart);
                return (TVal){};
            }

            HObject* super_hobj = (HObject*)super_val.get_heapptr();
            if (super_hobj == null || !super_hobj.is_callable() || !super_hobj.is_constructable()) {
                // TypeError: not a constructor
                HString* type_str = typeof_string(vm, &super_val);
                vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a constructor", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart);
                return (TVal){};
            }

            // Use new.target from the current activation (set by NEW_OBJ),
            // walking past arrow activations that carry none.
            HObject* new_target = super_walk_new_target(vm, ds.act);
            if (new_target == null) {
                // Not in a constructor — new.target is undefined
                // Fall back to simple call behavior
                // This shouldn't normally happen since super() is only valid in constructors
                ra.set_undefined();
                return (TVal){};
            }

            // Handle bound-function superclass: unwrap via bound_call, then re-dispatch.
            if (super_hobj.callable_kind() == hobject::CallableKind.BOUND_FN) {
                if ((*super_hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint sc_bound_fn_idx = (uint)(*super_hobj.extra_ptr()).func.builtin_fn_index;
                    {
                        uint bound_margin = (uint)(ds.act.bottom - vm.valstack) + ds.nregs + 4;
                        if (!ensure_valstack(vm, bound_margin)) { ra.set_undefined(); return (TVal){}; }
                        ds.regs_base = ds.act.bottom;
                        TVal* extended_top = ds.act.bottom + ds.nregs + 4;
                        if (extended_top > vm.valstack_top) { vm.valstack_top = extended_top; }
                    }
                    builtins::BuiltinContext sc_bound_ctx;
                    sc_bound_ctx.vm = vm;
                    sc_bound_ctx.regs = vm.valstack;
                    sc_bound_ctx.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                    sc_bound_ctx.argc = (ushort)nargs;
                    sc_bound_ctx.result = ds.regs_base + result_reg;
                    sc_bound_ctx.heap = vm.heap;
                    sc_bound_ctx.this_val = ds.regs_base[callee_reg + 1];
                    sc_bound_ctx.is_constructor = true;
                    sc_bound_ctx.needs_re_dispatch = false;
                    sc_bound_ctx.re_nargs = 0;
                    sc_bound_ctx.global_env = vm.global_env;
                    sc_bound_ctx.should_throw = false;
                    sc_bound_ctx.callee_obj = super_hobj;
                    sc_bound_ctx.new_target = new_target;
                    builtins::dispatch_builtin(sc_bound_fn_idx, &sc_bound_ctx);
                    ds.regs_base = ds.act.bottom;
                    if (sc_bound_ctx.should_throw) {
                        vm_throw_value(vm, sc_bound_ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart);
                        return (TVal){};
                    }
                    if (sc_bound_ctx.needs_re_dispatch) {
                        // bound_call rewrote callee_reg — re-read the target
                        super_val = ds.regs_base[callee_reg];
                        nargs = sc_bound_ctx.re_nargs;
                        if (super_val.is_lightfunc()) {
                            super_hobj = null;
                        } else if (super_val.is_object()) {
                            super_hobj = (HObject*)super_val.get_heapptr();
                        } else {
                            ra.set_undefined(); return (TVal){};
                        }
                        // Fall through to lightfunc / BUILTIN_FN / CompiledFunction handling below
                    } else {
                        // Bound target was a builtin that returned directly
                        if (env::is_tdz_sentinel(&ds.act.this_binding)) {
                            TVal* sc_bound_result = ds.regs_base + result_reg;
                            bool sc_bound_already_bound = false;
                            Activation* sc_bound_act_bd = null;
                            if (sc_bound_result.is_object()) {
                                sc_bound_already_bound = super_init_this_chain(vm, ds.act, sc_bound_result, &sc_bound_act_bd);
                            }
                            if (sc_bound_already_bound) {
                                // §8.1.1.3.1 BindThisValue step 3: already initialized.
                                vm_throw_error(vm, vm.heap.ref_err_proto, "Super constructor may only be called once", ds.act, &ds.curr_pc, &ds.needs_restart);
                            } else if (sc_bound_act_bd != null) {
                                CompiledFunction* sc_target_bd = (CompiledFunction*)sc_bound_act_bd.func;
                                vm_init_private_members(vm, sc_bound_act_bd.lex_env, sc_bound_act_bd.var_env,
                                    sc_target_bd, sc_bound_act_bd.this_binding, ds.act, &ds.curr_pc, &ds.needs_restart)!;
                            }
                        } else {
                            // §8.1.1.3.1 BindThisValue step 3: already initialized.
                            vm_throw_error(vm, vm.heap.ref_err_proto, "Super constructor may only be called once", ds.act, &ds.curr_pc, &ds.needs_restart);
                        }
                        return (TVal){};
                    }
                } else {
                    ra.set_undefined(); return (TVal){};
                }
            }

            // Re-check for lightfunc after potential bound-function re-dispatch
            if (super_hobj == null && super_val.is_lightfunc()) {
                uint sc_lf_idx = (uint)(usz)super_val.get_heapptr();
                HObject* sc_lf_proto = lightfunc_get_proto(vm, sc_lf_idx);
                if (sc_lf_proto == null) {
                    HString* type_str = typeof_string(vm, &super_val);
                    vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a constructor", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart);
                    return (TVal){};
                }
                builtins::BuiltinContext sc_lf_ctx;
                sc_lf_ctx.vm = vm;
                sc_lf_ctx.regs = vm.valstack;
                sc_lf_ctx.base_reg = (ushort)((uint)(ds.act.bottom - vm.valstack) + callee_reg + 2);
                sc_lf_ctx.argc = (ushort)nargs;
                sc_lf_ctx.result = ds.regs_base + result_reg;
                sc_lf_ctx.heap = vm.heap;
                sc_lf_ctx.this_val = ds.regs_base[callee_reg + 1];
                sc_lf_ctx.is_constructor = true;
                sc_lf_ctx.needs_re_dispatch = false;
                sc_lf_ctx.re_nargs = 0;
                sc_lf_ctx.global_env = vm.global_env;
                sc_lf_ctx.should_throw = false;
                sc_lf_ctx.callee_obj = null;
                sc_lf_ctx.new_target = new_target;
                builtins::dispatch_builtin(sc_lf_idx, &sc_lf_ctx);
                if (sc_lf_ctx.should_throw) {
                    vm_throw_value(vm, sc_lf_ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart);
                } else if (env::is_tdz_sentinel(&ds.act.this_binding)) {
                    TVal* sc_lf_result = ds.regs_base + result_reg;
                    bool sc_lf_already_bound = false;
                    Activation* sc_lf_bound_act = null;
                    if (sc_lf_result.is_object()) {
                        sc_lf_already_bound = super_init_this_chain(vm, ds.act, sc_lf_result, &sc_lf_bound_act);
                    }
                    if (sc_lf_already_bound) {
                        // §8.1.1.3.1 BindThisValue step 3: already initialized.
                        vm_throw_error(vm, vm.heap.ref_err_proto, "Super constructor may only be called once", ds.act, &ds.curr_pc, &ds.needs_restart);
                    } else if (sc_lf_bound_act != null) {
                        CompiledFunction* sc_lf_target = (CompiledFunction*)sc_lf_bound_act.func;
                        vm_init_private_members(vm, sc_lf_bound_act.lex_env, sc_lf_bound_act.var_env,
                            sc_lf_target, sc_lf_bound_act.this_binding, ds.act, &ds.curr_pc, &ds.needs_restart)!;
                    }
                } else {
                    // §8.1.1.3.1 BindThisValue step 3: already initialized.
                    vm_throw_error(vm, vm.heap.ref_err_proto, "Super constructor may only be called once", ds.act, &ds.curr_pc, &ds.needs_restart);
                }
                return (TVal){};
            }

            // Handle builtin super constructors
            if (super_hobj != null && super_hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*super_hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*super_hobj.extra_ptr()).func.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((uint)(ds.act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = ds.regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = ds.regs_base[callee_reg + 1];
                    ctx.is_constructor = true;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = super_hobj;
                    ctx.new_target = new_target;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                    if (ctx.should_throw) {
                        vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart);
                    } else if (env::is_tdz_sentinel(&ds.act.this_binding)) {
                        // Initialize the derived constructor's this_binding with the
                        // object returned by the builtin super constructor (§9.2.2).
                        TVal* sc_result_bi = ds.regs_base + result_reg;
                        bool sc_bi_already_bound = false;
                        Activation* sc_bi_bound_act = null;
                        if (sc_result_bi.is_object()) {
                            sc_bi_already_bound = super_init_this_chain(vm, ds.act, sc_result_bi, &sc_bi_bound_act);
                        }
                        if (sc_bi_already_bound) {
                            // §8.1.1.3.1 BindThisValue step 3: already initialized.
                            vm_throw_error(vm, vm.heap.ref_err_proto, "Super constructor may only be called once", ds.act, &ds.curr_pc, &ds.needs_restart);
                        } else if (sc_bi_bound_act != null) {
                            CompiledFunction* sc_bi_target = (CompiledFunction*)sc_bi_bound_act.func;
                            vm_init_private_members(vm, sc_bi_bound_act.lex_env, sc_bi_bound_act.var_env,
                                sc_bi_target, sc_bi_bound_act.this_binding, ds.act, &ds.curr_pc, &ds.needs_restart)!;
                        }
                    } else {
                        // §8.1.1.3.1 BindThisValue step 3: already initialized.
                        vm_throw_error(vm, vm.heap.ref_err_proto, "Super constructor may only be called once", ds.act, &ds.curr_pc, &ds.needs_restart);
                    }
                }
                return (TVal){};
            }

            if (super_hobj == null) { ra.set_undefined(); return (TVal){}; }
            CompiledFunction* super_target = (*super_hobj.extra_ptr()).func.comp_func;

            // OrdinaryCreateFromConstructor (§9.1.13): allocate the new object
            // using new.target.prototype — but only when the superclass is a
            // BASE constructor. A derived superclass gets an uninitialized
            // `this` (TDZ) and allocates in its own super() (§9.2.2 step 5);
            // allocating here too would construct two objects and initialize
            // the wrong one.
            bool super_is_derived = super_target.is_derived_ctor();
            if (super_is_derived) {
                TVal sc_tdz = env::tdz_sentinel();
                vm.heap.tval_copy_ref(&ds.regs_base[callee_reg + 1], &sc_tdz);
            } else {
                HObject*? sc_new_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch _sc_err = sc_new_obj_raw) {
                    ra.set_undefined();
                    return (TVal){};
                }
                HObject* sc_new_obj = sc_new_obj_raw;
                // OrdinaryCreateFromConstructor: set [[Prototype]] from new.target.prototype
                if (new_target != null) {
                    HString* proto_key_sc = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
                    TVal? proto_sc = new_target.get_prop_proto(proto_key_sc);
                    if (try psc = proto_sc) {
                        if (psc.is_object() && psc.get_heapptr() != null) {
                            sc_new_obj.prototype = (HObject*)psc.get_heapptr();
                        } else {
                            sc_new_obj.prototype = vm.heap.object_proto;
                        }
                    } else {
                        sc_new_obj.prototype = vm.heap.object_proto;
                    }
                }
                TVal sc_this_tval;
                sc_this_tval.set_object(sc_new_obj);
                // Place in callee_reg+1 (the this-slot for SUPER_CALL's base constructor).
                vm.heap.tval_copy_ref(&ds.regs_base[callee_reg + 1], &sc_this_tval);

                // Private class fields (ES2022 §9.2.2 step 8
                // InitializeInstanceElements): a BASE superclass invoked via
                // super() runs its OWN brand stamp + field init right after
                // creating `this`, exactly like the direct-`new` path in
                // NEW_OBJ. The RET-side hook only covers the DERIVED caller's
                // members after `this` binds — without this call, a base
                // class's private members never initialize on super()
                // construction (e.g. `class D extends B {}` with B's fields).
                if (!vm_init_private_members(vm,
                        (*super_hobj.extra_ptr()).func.lex_env,
                        (*super_hobj.extra_ptr()).func.var_env,
                        super_target, sc_this_tval, ds.act, &ds.curr_pc, &ds.needs_restart)!) {
                    return (TVal){};
                }
                // Field init re-enters the VM; refresh the frame base in case
                // the value stack was reallocated.
                ds.regs_base = ds.act.bottom;
            }

            // Set up activation frame for superclass constructor
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = ds.regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + super_target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                ra.set_undefined();
                return (TVal){};
            }

            ds.regs_base = ds.act.bottom;
            // Recompute new_bottom after realloc (ds.act.bottom may have moved)
            new_bottom = ds.regs_base + frame_start;

            if (vm.activation_count >= MAX_CALLS) {
                if (!vm_throw_error(vm, vm.heap.range_err_proto, "Maximum call stack size exceeded", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* super_var_env = (*super_hobj.extra_ptr()).func.var_env;
            if (try fv_su = env::env_create_function_scope(vm.heap, (*super_hobj.extra_ptr()).func.var_env)) { super_var_env = fv_su; }
            new_act.parent = ds.act;
            new_act.func = super_target;
            new_act.var_env = super_var_env;
            // Captured block scope + named-function-expression name
            // binding — shared with every other call path; see
            // resolve_call_lex_env.
            new_act.lex_env = resolve_call_lex_env(vm, super_hobj, super_target, super_var_env);
            new_act.cat = null;
            new_act.curr_pc = super_target.code;
            new_act.bottom = new_bottom;
            new_act.retval = ds.regs_base + result_reg;
            new_act.flags = ACT_FLAG_CONSTRUCT | ACT_FLAG_SUPER_CTOR
                          | (super_is_derived ? ACT_FLAG_DERIVED : 0)
                          | (super_target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0);
            new_act.async_promise = null;
            new_act.async_gen_state = null;
            vm.heap.tval_copy_ref(&new_act.this_binding, &ds.regs_base[callee_reg + 1]);
            new_act.flags |= ACT_FLAG_THIS_OWNED;
            new_act.new_target = new_target;  // Pass through new.target

            TVal* new_regs = new_act.bottom;
            uint new_nregs = super_target.num_regs;

            // Copy args
            TVal* old_args = ds.regs_base + callee_reg + 2;

            // Create arguments object BEFORE the rest parameter handling below
            // overwrites new_regs[0] with the rest array.
            if (super_target.uses_arguments()) {
                HObject*? args_obj_raw_su = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                if (try args_obj_su = args_obj_raw_su) {
                    for (uint ai = 0; ai < nargs; ai++) {
                        args_obj_su.set_array_idx(ai, old_args[ai]);
                    }
                    args_obj_su.prototype = vm.heap.object_proto;
                    finish_arguments_object(vm, args_obj_su, super_hobj, nargs);
                    HString* args_name_su = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                    if (args_name_su != null) {
                        TVal args_tv_su; args_tv_su.set_object(args_obj_su);
                        env::env_declare(super_var_env, args_name_su, args_tv_su);
                    }
                }
            }

            if (super_target.has_rest()) {
                uint copy_count = (uint)super_target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                }
                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;
                HObject*? rest_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try rest_obj = rest_obj_raw) {
                    rest_obj.prototype = vm.heap.array_proto;
                    // Copy overflow args into the array
                    for (uint j = 0; j < overflow; j++) {
                        HString* key = vm.heap.int_to_hstring((long)j);
                        if (key != null) {
                            TVal elem = old_args[copy_count + j];
                            rest_obj.put_prop(key, elem, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    // Set .length
                    HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val;
                    len_val.set_fastint((long)overflow);
                    rest_obj.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
                    new_regs[rest_idx].set_object(rest_obj);
                } else {
                    new_regs[rest_idx].set_undefined();
                }
                for (uint i = copy_count + 1; i < new_nregs; i++) {
                    new_regs[i].set_undefined();
                }
            } else {
                for (uint i = 0; i < nargs && i < new_nregs; i++) {
                    vm.heap.tval_copy_ref(&new_regs[i], &old_args[i]);
                }
                if (nargs < new_nregs) {
                    mem::clear(&new_regs[nargs], (sz)((usz)(new_nregs - nargs) * TVal::size));
                }
            }

            vm.valstack_top = new_regs + new_nregs;
            vm.valstack_bottom = new_act.bottom;

            // Save caller resume point before switching activation
            ds.act.curr_pc = ds.curr_pc;

            ds.needs_restart = true;
            return (TVal){};
        }

        case Opcode.NEWTARGET: {
            // A = new.target
            HObject* nt = ds.act.new_target;
            if (nt != null) {
                ra.set_object(nt);
                track_heap_store(ds.act, ra, (uint)insn.a);
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.NEW_OBJ:
        case Opcode.NEW_OBJ_S: {
            // Compiler convention: A=result_reg, B=callee_reg, C=nargs (NEW_OBJ)
            // or C=nargs_reg (NEW_OBJ_S — reads nargs at runtime).
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs;
            if (op == Opcode.NEW_OBJ_S) {
                TVal* nargs_slot = ds.regs_base + insn.c;
                if (nargs_slot.is_fastint()) {
                    nargs = (uint)nargs_slot.get_fastint();
                } else if (nargs_slot.is_number()) {
                    nargs = (uint)nargs_slot.get_number();
                } else {
                    nargs = 0;
                }
            } else {
                nargs = insn.c;
            }

            TVal* func_slot = ds.regs_base + callee_reg;
            TVal func_val = *func_slot;

            // Handle lightfunc built-in constructors (Error, TypeError, etc.)
            if (func_val.is_lightfunc()) {
                uint fn_idx = (uint)(usz)func_val.get_heapptr();

                // Check if this lightfunc is actually constructable.
                // lightfunc_get_proto returns null for non-constructors
                // (e.g. Object.seal, Object.freeze, Math.max, etc.)
                HObject* ctor_proto = lightfunc_get_proto(vm, fn_idx);
                if (ctor_proto == null) {
                    HString* type_str = typeof_string(vm, &func_val);
                    if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a constructor", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return VM_ERROR~;
                    }
                    return (TVal){};
                }

                builtins::BuiltinContext ctx;
                ctx.vm = vm;
                ctx.regs = vm.valstack;
                ctx.base_reg = (ushort)((uint)(ds.act.bottom - vm.valstack) + callee_reg + 2);
                ctx.argc = (ushort)nargs;
                ctx.result = ds.regs_base + result_reg;
                ctx.heap = vm.heap;
                // [[Construct]]: the this slot at callee_reg+1 is not written by the
                // compiler for `new` — its content is stale frame data. Constructor
                // builtins allocate their own instance and ignore this_val; pass
                // undefined so non-constructor builtins fail their receiver checks
                // deterministically instead of acting on garbage.
                ctx.this_val.set_undefined();
                ctx.is_constructor = true;
                ctx.needs_re_dispatch = false;
                ctx.re_nargs = 0;
                ctx.global_env = vm.global_env;
                ctx.should_throw = false;
                builtins::dispatch_builtin(fn_idx, &ctx);
                // Refresh ds.regs_base after possible valstack realloc inside builtin.
                ds.regs_base = ds.act.bottom;
                if (ctx.should_throw) {
                    if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &ctx.throw_value);
                    }
                    return (TVal){};
                }
                return (TVal){};
            }

            if (!func_val.is_object()) {
                // TypeError: value is not a constructor
                HString* type_str = typeof_string(vm, &func_val);
                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a constructor", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            HObject* hobj = (HObject*)func_val.get_heapptr();
            if (hobj == null || !hobj.is_callable() || !hobj.is_constructable()) {
                // TypeError: object is not a constructor
                HString* type_str = typeof_string(vm, &func_val);
                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a constructor", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // Handle bound function objects — dispatch to builtin_bound_call
            if (hobj.callable_kind() == hobject::CallableKind.BOUND_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    // Pre-grow the valstack so that bound_call's arg-prepend write
                    // (which extends past the current nargs into the frame's tail)
                    // lands in valid, GC-visible memory.  We must also advance
                    // vm.valstack_top past ds.nregs so the extra slots are within
                    // the allocated+visible range (even if no realloc is needed).
                    {
                        uint bound_margin = (uint)(ds.act.bottom - vm.valstack) + ds.nregs + 4;
                        if (!ensure_valstack(vm, bound_margin)) {
                            ds.regs_base[result_reg].set_undefined();
                            return (TVal){};
                        }
                        ds.regs_base = ds.act.bottom;
                        TVal* extended_top = ds.act.bottom + ds.nregs + 4;
                        if (extended_top > vm.valstack_top) { vm.valstack_top = extended_top; }
                    }
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((ds.act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = ds.regs_base + result_reg;
                    ctx.heap = vm.heap;
                    // [[Construct]]: the this slot at callee_reg+1 is not written by the
                    // compiler for `new` — its content is stale frame data. Constructor
                    // builtins allocate their own instance and ignore this_val; pass
                    // undefined so non-constructor builtins fail their receiver checks
                    // deterministically instead of acting on garbage.
                    ctx.this_val.set_undefined();
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                    // Refresh ds.regs_base after possible valstack realloc inside builtin.
                    ds.regs_base = ds.act.bottom;

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        return (TVal){};
                    }

                    if (ctx.needs_re_dispatch) {
                        func_val = ds.regs_base[callee_reg];
                        hobj = (HObject*)func_val.get_heapptr();
                        nargs = ctx.re_nargs;
                        // BOUND_FN re-dispatch may surface a BUILTIN_FN downstream
                        // (e.g. `new (Function.prototype.bind.apply(Date, [...]))()`).
                        // Route those to the BUILTIN_FN constructor path instead of
                        // the compiled-function path below, which would deref a
                        // null comp_func and crash. Repeat the constructable check
                        // first — `bind` does not change constructability.
                        if (hobj != null && hobj.is_constructable()
                            && hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN
                            && (*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                            uint rfn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                            if (!builtin_fn_is_constructor(vm, rfn_idx)) {
                                HString* rnc_type_str = typeof_string(vm, &func_val);
                                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a constructor", rnc_type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return VM_ERROR~;
                                }
                                return (TVal){};
                            }
                            TVal rd_result; rd_result.set_undefined();
                            builtins::BuiltinContext rd_ctx;
                            rd_ctx.vm = vm;
                            rd_ctx.regs = vm.valstack;
                            rd_ctx.base_reg = (ushort)((uint)(ds.act.bottom - vm.valstack) + callee_reg + 2);
                            rd_ctx.argc = (ushort)nargs;
                            rd_ctx.result = &rd_result;
                            rd_ctx.heap = vm.heap;
                            rd_ctx.this_val.set_undefined();
                            rd_ctx.is_constructor = true;
                            rd_ctx.needs_re_dispatch = false;
                            rd_ctx.re_nargs = 0;
                            rd_ctx.global_env = vm.global_env;
                            rd_ctx.should_throw = false;
                            rd_ctx.callee_obj = hobj;
                            // Same as the un-bound BUILTIN_FN branch below: a plain
                            // `new BoundBuiltin()` sees the unwrapped callee as its
                            // new.target (mirroring `new Date()` where Date is the
                            // new.target, not Object).
                            rd_ctx.new_target = hobj;
                            builtins::dispatch_builtin(rfn_idx, &rd_ctx);
                            ds.regs_base = ds.act.bottom;
                            if (rd_ctx.should_throw) {
                                if (!vm_throw_value(vm, rd_ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return vm_uncaught_error(vm, &rd_ctx.throw_value);
                                }
                                return (TVal){};
                            }
                            vm.heap.tval_copy_ref(ds.regs_base + result_reg, &rd_result);
                            track_heap_store(ds.act, ds.regs_base + result_reg, result_reg);
                            return (TVal){};
                        }
                        // Fall through to compiled function handling below
                    } else {
                        return (TVal){};
                    }
                } else {
                    return (TVal){};
                }
            } else if (hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
                if ((*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;
                    // ES §10.3: built-in functions are constructors only when
                    // specified. `new String.prototype.charAt` must throw here;
                    // the flags.constructable default cannot express this (see
                    // builtin_fn_is_constructor).
                    if (!builtin_fn_is_constructor(vm, fn_idx)) {
                        HString* nc_type_str = typeof_string(vm, &func_val);
                        if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a constructor", nc_type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    // Local result to avoid stale ptr if heap.call_fn triggers valstack realloc.
                    TVal ctor_result; ctor_result.set_undefined();
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((uint)(ds.act.bottom - vm.valstack) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = &ctor_result;
                    ctx.heap = vm.heap;
                    // [[Construct]]: the this slot at callee_reg+1 is not written by the
                    // compiler for `new` — its content is stale frame data. Constructor
                    // builtins allocate their own instance and ignore this_val; pass
                    // undefined so non-constructor builtins fail their receiver checks
                    // deterministically instead of acting on garbage.
                    ctx.this_val.set_undefined();
                    ctx.is_constructor = true;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    ctx.callee_obj = hobj;
                    // For a plain `new Builtin()` the new.target IS the callee, so
                    // GetPrototypeFromConstructor(hobj, default) will find the same
                    // intrinsic prototype that the constructor would hardcode — no
                    // change in behaviour for non-subclassed calls.
                    ctx.new_target = hobj;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                    // Refresh ds.regs_base after possible valstack realloc inside builtin.
                    ds.regs_base = ds.act.bottom;
                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return vm_uncaught_error(vm, &ctx.throw_value);
                        }
                        return (TVal){};
                    }
                    vm.heap.tval_copy_ref(ds.regs_base + result_reg, &ctor_result);
                    return (TVal){};
                }
                // Object claims to be callable but has no compiled function
                // and no builtin index — treat as non-constructor
                HString* type_str = typeof_string(vm, &func_val);
                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a constructor", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            CompiledFunction* target = (*hobj.extra_ptr()).func.comp_func;

            // Arrow functions cannot be used as constructors (ES6 §14.2.2)
            if (target.is_arrow()) {
                HString* type_str = typeof_string(vm, &func_val);
                if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "%s is not a constructor", type_str.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            // Step 1: Create new object — skip for derived constructors, which get
            // an uninitialized `this` until super() allocates and sets it.
            // ES2015 §9.2.2 step 5: "derived" constructors do not OrdinaryCreateFromConstructor
            // here; super() does it inside the base class [[Construct]].
            TVal this_tval;
            if (target.is_derived_ctor()) {
                // Derived constructor: this_binding = TDZ sentinel (uninitialized).
                // LDTHIS will throw ReferenceError; SUPER_CALL will initialize it.
                this_tval = env::tdz_sentinel();
            } else {
                // Base constructor: allocate the new object now.
                HObject*? new_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch err = new_obj_raw) {
                    ds.regs_base[result_reg].set_undefined();
                    return (TVal){};
                }
                HObject* new_obj = new_obj_raw;

                // Set prototype from constructor.prototype (OrdinaryCreateFromConstructor).
                HString* proto_key = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
                TVal? proto_val = hobj.get_prop_proto(proto_key);
                if (try pv = proto_val) {
                    if (pv.is_object() && pv.get_heapptr() != null) {
                        new_obj.prototype = (HObject*)pv.get_heapptr();
                    }
                }
                this_tval.set_object(new_obj);

                // Private class fields (ES2022 §9.2.2 step 8 InitializeInstanceElements,
                // called for BASE constructors right after `this` is created).
                if (!vm_init_private_members(vm, (*hobj.extra_ptr()).func.lex_env, (*hobj.extra_ptr()).func.var_env,
                        target, this_tval, ds.act, &ds.curr_pc, &ds.needs_restart)!) {
                    return (TVal){};
                }
                ds.regs_base = ds.act.bottom;
                func_slot = ds.regs_base + callee_reg;
            }
            vm.heap.tval_copy_ref(&ds.regs_base[callee_reg + 1], &this_tval);
            uint frame_start = callee_reg + 2;
            TVal* new_bottom = ds.regs_base + frame_start;
            uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                ds.regs_base[result_reg].set_undefined();
                return (TVal){};
            }

            ds.regs_base = ds.act.bottom;
            // Recompute new_bottom after realloc (ds.act.bottom may have moved)
            new_bottom = ds.regs_base + frame_start;
            func_slot = ds.regs_base + callee_reg;

            if (vm.activation_count >= MAX_CALLS) {
                if (!vm_throw_error(vm, vm.heap.range_err_proto, "Maximum call stack size exceeded", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;
            new_act.max_heap_reg = 0;
            new_act.caller_valstack_top = vm.valstack_top;

            EnvRecord* ctor_var_env = (*hobj.extra_ptr()).func.var_env;
            if (try fv_ct = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { ctor_var_env = fv_ct; }
            new_act.parent = ds.act;
            new_act.func = target;
            new_act.var_env = ctor_var_env;
            // Named function expressions get a fresh declarative lex_env
            // with the function name bound immutably (ES2015 §14.1.20).
            if (target.is_namebinding()) {
                char[] name_data = target.get_name();
                HString* name_hstr = intern_string(vm, name_data);
                if (name_hstr != null) {
                    if (try name_lex = setup_named_function_expr_env(vm, ctor_var_env, name_hstr, hobj)) {
                        new_act.lex_env = name_lex;
                    } else {
                        new_act.lex_env = ctor_var_env;
                    }
                } else {
                    new_act.lex_env = ctor_var_env;
                }
            } else {
                // Use the captured lex_env so block-scoped let/const bindings
                // from the enclosing function body are visible.  Mirrors the
                // CALL fast path (line ~4503) which also honors func.lex_env
                // when it's a *declarative* (block) scope.  Without this,
                // constructors for `class B extends A { constructor() { super(); } }`
                // can't see the classScope's `__super__` binding — the
                // constructor's CLOSURE captures func.lex_env = classScope but
                // NEW_OBJ was unconditionally resetting it to ctor_var_env.
                EnvRecord* cap_lex_noname = (*hobj.extra_ptr()).func.lex_env;
                if (cap_lex_noname != null
                    && cap_lex_noname != ctor_var_env
                    && cap_lex_noname.is_declarative) {
                    new_act.lex_env = cap_lex_noname;
                } else {
                    new_act.lex_env = ctor_var_env;
                }
            }
            new_act.cat = null;
            new_act.curr_pc = target.code;
            new_act.bottom = new_bottom;
            new_act.retval = ds.regs_base + result_reg;
            new_act.flags = ACT_FLAG_CONSTRUCT
                          | (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0)
                          | ACT_FLAG_THIS_OWNED
                          | (target.is_derived_ctor() ? ACT_FLAG_DERIVED : 0);
            vm.heap.tval_copy_ref(&new_act.this_binding, &this_tval);
            new_act.new_target = hobj;  // constructor function, not instance

            TVal* new_regs2 = new_act.bottom;
            uint new_nregs2 = target.num_regs;

            // Copy args
            TVal* old_args2 = ds.regs_base + callee_reg + 2;

            // Create arguments object BEFORE the rest parameter handling below
            // overwrites new_regs2[0] with the rest array.  Capture the original
            // (pre-overwrite) args via the same stack pointer the rest code will
            // mutate.
            if (target.uses_arguments()) {
                HObject*? args_obj_raw2 = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                if (try args_obj2 = args_obj_raw2) {
                    for (uint ai = 0; ai < nargs; ai++) {
                        args_obj2.set_array_idx(ai, old_args2[ai]);
                    }
                    args_obj2.prototype = vm.heap.object_proto;
                    finish_arguments_object(vm, args_obj2, hobj, nargs);
                    HString* args_name2 = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                    if (args_name2 != null) {
                        TVal args_tv2; args_tv2.set_object(args_obj2);
                        env::env_declare(ctor_var_env, args_name2, args_tv2);
                    }
                }
            }

            if (target.has_rest()) {
                uint copy_count = (uint)target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    vm.heap.tval_copy_ref(&new_regs2[i], &old_args2[i]);
                }

                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;

                HObject*? arr2_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try a2 = arr2_raw) {
                    a2.prototype = vm.heap.array_proto;
                    for (uint i = 0; i < overflow; i++) {
                        HString* key2 = vm.heap.int_to_hstring((long)i);
                        if (key2 != null) {
                            TVal elem2 = old_args2[copy_count + i];
                            a2.put_prop(key2, elem2, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    HString* len_str2 = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val2;
                    len_val2.set_fastint((long)overflow);
                    a2.put_prop(len_str2, len_val2, hobject::PROP_FLAGS_WEC);

                    new_regs2[rest_idx].set_object(a2);
                } else {
                    new_regs2[rest_idx].set_undefined();
                }

                if (rest_idx + 1 < new_nregs2) {
                    mem::clear(&new_regs2[rest_idx + 1], (sz)((usz)(new_nregs2 - rest_idx - 1) * TVal::size));
                }
            } else {
                for (uint i = 0; i < nargs && i < (uint)target.num_args; i++) {
                    vm.heap.tval_copy_ref(&new_regs2[i], &old_args2[i]);
                }
                if (nargs < new_nregs2) {
                    zero_regs_undefined(new_regs2, nargs, new_nregs2);
                }
            }

            vm.valstack_top = (TVal*)((usz)new_regs2 + (usz)new_nregs2 * (usz)TVal::size);
            vm.valstack_bottom = new_act.bottom;

            ds.act.curr_pc = ds.curr_pc;
            ds.needs_restart = true;
            return (TVal){};
        }

        case Opcode.TAILCALL:
            return (TVal){};

        default:
            return (TVal){};
    }
    return (TVal){};
}

