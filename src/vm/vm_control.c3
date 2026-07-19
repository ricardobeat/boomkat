module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import std::io;
import duktape::re_bindings;
import std::math;

// ============================================================================
// vm_control — return / variable access / closure / iterator / exceptions / misc
// ============================================================================

/// Complete a generator's return: mark GEN_COMPLETED, wrap `val` in an
/// IteratorResult {value, done:true}, write it to the caller, and pop the
/// activation. Shared by RET_GEN/RETUNDEF_GEN and by ENDFINALLY's
/// generator-aware pending-return completion (a return that was deferred
/// through a try/finally in a generator body).
fn void vm_complete_generator_return(Dispatch* ds, TVal* val) {
    Vm* vm = ds.vm;
    GeneratorState* gs = vm.heap.resume_gen;
    if (gs != null) {
        gs.state = GEN_COMPLETED;
        vm.heap.tval_copy_ref(&vm.heap.yield_value, val);
        vm.heap.did_yield = false;
        vm.heap.resume_gen = null;
    }

    HObject*? robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
    TVal wrapped_val;
    if (try robj = robj_raw) {
        robj.prototype = vm.heap.object_proto;
        HString* val_key = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
        if (val_key != null) robj.put_prop(val_key, *val, hobject::PROP_FLAGS_WEC);
        HString* done_key = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
        TVal done_val;
        done_val.set_boolean(true);
        if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
        wrapped_val.set_object(robj);
    } else {
        wrapped_val = *val;
    }

    Activation* ret_act = &vm.activations[vm.activation_count - 1];
    // retval is null when this activation was entered via the re-entrant
    // call_fn path (e.g. YIELD_STAR calling a delegated generator's .next()
    // directly) rather than the CALL opcode — the result is read back via
    // vm.return_val in that case instead.
    if (ret_act.retval != null) {
        vm.heap.tval_copy_ref(ret_act.retval, &wrapped_val);
    } else {
        vm.heap.tval_copy_ref(&vm.return_val, &wrapped_val);
    }

    vm.activation_count--;
    // activation_count can hit 0 here when this generator body was entered
    // via the re-entrant call_fn path (e.g. YIELD_STAR calling a delegated
    // generator's .next() directly) rather than the CALL opcode, so there is
    // no caller activation in *this* Vm.run invocation to fall back to —
    // halt like the plain RET path does.
    if (vm.activation_count == 0) {
        ds.halt = true;
        ds.halt_value = vm.return_val;
        return;
    }
    Activation* caller_act = &vm.activations[vm.activation_count - 1];
    vm.valstack_bottom = caller_act.bottom;
    if (caller_act.func != null) {
        CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
        vm.valstack_top = caller_act.bottom + caller_func.num_regs;
    }
    ds.needs_restart = true;
}

/// Sub-dispatch for the generator return opcodes RET_GEN/RETUNDEF_GEN.
/// The hot non-generator RET/RETUNDEF paths are inlined directly in Vm.run
/// (src/vm/vm_execute.c3) since they dominate recursion-heavy workloads.
fn TVal? dispatch_returns(Dispatch* ds, Opcode op, TVal* ra) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.RET_GEN: {
            // Check for active finally catchers: if we're returning through
            // a try-finally inside the generator body, save the return value,
            // mark it as a generator-return, and jump to the finally handler
            // instead of completing immediately (mirrors plain RET).
            Catcher* ret_cat = (Catcher*)ds.act.cat;
            if (ret_cat != null && ret_cat.finally_pc != null) {
                ret_cat.return_val = ra[0];
                if (!(ret_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret_cat.flags |= CATCHER_FLAG_PENDING_RETURN | CATCHER_FLAG_PENDING_RETURN_GEN;
                    ds.curr_pc = ret_cat.finally_pc;
                    ds.act.curr_pc = ds.curr_pc;
                }
                return (TVal){};
            }
            vm_complete_generator_return(ds, &ra[0]);
            return (TVal){};
        }

        case Opcode.RETUNDEF_GEN: {
            TVal undef_val;
            undef_val.set_undefined();
            Catcher* ret_cat2 = (Catcher*)ds.act.cat;
            if (ret_cat2 != null && ret_cat2.finally_pc != null) {
                ret_cat2.return_val = undef_val;
                if (!(ret_cat2.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret_cat2.flags |= CATCHER_FLAG_PENDING_RETURN | CATCHER_FLAG_PENDING_RETURN_GEN;
                    ds.curr_pc = ret_cat2.finally_pc;
                    ds.act.curr_pc = ds.curr_pc;
                }
                return (TVal){};
            }
            vm_complete_generator_return(ds, &undef_val);
            return (TVal){};
        }
        default:
            return (TVal){};
    }
}

/// ES2015 §9.2.11 SetFunctionName helper for computed-key methods/accessors —
/// shared by CLASS_INITGET/CLASS_INITSET/CLASS_INITPROP (class bodies) and
/// INITGET/INITSET/INITPROP (object literals).
/// If the accessor function `fn_obj` currently has an empty `.name` property,
/// overwrite it with `prefix + key_str` (string key) or `prefix + "[desc]"`
/// (symbol key), matching the computed-accessor name spec.
fn void class_initaccessor_set_name(Vm* vm, HObject* fn_obj, TVal* key_tval, char[] prefix) {
    if (fn_obj == null) return;
    // Only update if current .name is the empty string (compiler-emitted
    // placeholder for computed keys; non-computed keys already have the
    // correct name set at compile time).
    HString* name_key = (HString*)vm.heap.strs[heap::BuiltinStr.NAME];
    int name_idx = fn_obj.find_prop_idx((void*)name_key);
    if (name_idx < 0) return;
    TVal* name_slot = &fn_obj.prop_values()[name_idx];
    if (!name_slot.is_string()) return;
    HString* cur_name = (HString*)name_slot.get_heapptr();
    if (cur_name == null || cur_name.blen != 0) return;  // non-empty: already set

    // Build "prefix + key_desc" in a stack buffer.
    char[256] buf;
    usz pos = 0;
    for (usz i = 0; i < prefix.len && pos < 255; i++) buf[pos++] = prefix[i];

    if (key_tval.is_string()) {
        HString* key_hstr = (HString*)key_tval.get_heapptr();
        if (key_hstr != null && key_hstr.is_symbol()) {
            // Symbol key: append "[description]" or "" for anonymous symbols.
            if (builtins::symbol_has_description(key_hstr)) {
                char[] desc = builtins::symbol_description(key_hstr);
                buf[pos++] = '[';
                for (uint i = 0; i < desc.len && pos < 254; i++) buf[pos++] = desc[i];
                if (pos < 255) buf[pos++] = ']';
            }
            // anonymous Symbol(): name stays just prefix (e.g. "get ")
        } else if (key_hstr != null) {
            // Plain string key
            char* kstr = key_hstr.get_cstr();
            for (uint i = 0; i < key_hstr.blen && pos < 255; i++) buf[pos++] = kstr[i];
        }
    }

    HString* new_name = intern_string(vm, buf[:pos]);
    if (new_name != null) {
        TVal new_tv;
        new_tv.set_string(new_name);
        vm.heap.tval_copy_ref(name_slot, &new_tv);
    }
}

/// Shared INITPROP/INITPROPN body: define a data property with WEC flags
/// using DefinePropertyOrThrow semantics — if the property already exists
/// and is configurable, it is replaced; non-configurable existing properties
/// are silently left untouched (caller has already coerced the key on
/// computed-key paths via TOPROPKEY, so `get_prop_key` here is idempotent).
fn void initprop_define(Vm* vm, HObject* hobj, TVal* key_val, TVal* val) {
    void* key = get_prop_key(vm, key_val);
    if (key == null) return;
    int idx = hobj.find_prop_idx(key);
    if (idx >= 0) {
        hobject::PropFlags ef = hobj.get_prop_flags((uint)idx);
        if (ef.configurable) {
            TVal put_val = *val;
            vm.heap.tval_copy_ref(&hobj.prop_values()[idx], &put_val);
            hobject::PropFlags nf;
            nf.writable = true;
            nf.enumerable = true;
            nf.configurable = true;
            nf.is_accessor = false;
            hobj.set_prop_flags((uint)idx, nf);
        }
        // non-configurable: do nothing (silent)
    } else {
        hobj.put_prop(key, *val, hobject::PROP_FLAGS_WEC);
    }
}

/// Instantiate a function closure from a CompiledFunction template, capturing
/// the given var/lex environments. Sets .name/.length and, for constructable
/// functions, .prototype (with .constructor). Returns null only on allocation
/// failure. Shared by the CLOSURE opcode and by the ESM linker, which
/// instantiates exported `function` declarations eagerly at link time so a
/// cyclic early import observes the hoisted function rather than `undefined`
/// (ECMA-262 16.2.1.5.5 step 17).
fn HObject* instantiate_closure(Vm* vm, CompiledFunction* template, EnvRecord* var_env, EnvRecord* lex_env, TVal* enclosing_this = null, HObject* enclosing_new_target = null) {
    HObject*? func_obj_raw = vm.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch _e = func_obj_raw) return null;
    HObject* func_obj = func_obj_raw;

    // Generator function objects inherit from GeneratorFunction.prototype,
    // all other functions inherit from Function.prototype (ES6 §25.2.3).
    if (template.is_async() && vm.heap.async_func_proto != null) {
        func_obj.prototype = vm.heap.async_func_proto;
    } else if (template.is_generator() && vm.heap.generator_func_proto != null) {
        func_obj.prototype = vm.heap.generator_func_proto;
    } else {
        func_obj.prototype = vm.heap.function_proto;
    }
    func_obj.flags.callable = true;
    func_obj.flags.constructable = template.is_constructable();
    (*func_obj.extra_ptr()).func.comp_func = template;
    (*func_obj.extra_ptr()).func.var_env = var_env;
    (*func_obj.extra_ptr()).func.lex_env = lex_env;
    // ES2015 §9.2.1 [[ThisMode]]=lexical: capture the enclosing activation's
    // `this` once, at closure-creation time, so it survives being called from
    // any later call site (bare call, .call/.apply/.bind, builtin callback
    // thisArg, or a call routed through vm_call_fn_impl's nested-Vm.run
    // boundary) — none of which reflect the arrow's true lexical `this`.
    if (template.is_arrow() && enclosing_this != null) {
        vm.heap.tval_copy_ref(&(*func_obj.extra_ptr()).func.captured_this, enclosing_this);
    }
    // ES2015 §9.2.1 [[NewTarget]]=lexical: capture the enclosing function's
    // new.target once, at closure-creation time (same rationale as
    // captured_this — the enclosing construct frame may have returned by the
    // time the arrow runs). Borrowed reference kept reachable through the GC
    // mark path (objects are mark-and-swept, not refcount-freed).
    (*func_obj.extra_ptr()).func.captured_new_target = template.is_arrow() ? enclosing_new_target : null;

    // Set .length property (ES5 §15.3.5.1: non-writable, non-enumerable, configurable).
    // Must be defined before .name — SetFunctionLength/SetFunctionName ordering
    // (e.g. FunctionDeclarationInstantiation / ClassDefinitionEvaluation set
    // length first) is observable via Object.getOwnPropertyNames insertion order.
    HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_val;
    len_val.set_fastint((long)template.num_formals);
    func_obj.put_prop(len_key, len_val, hobject::PROP_FLAGS_NWC);

    // Set .name property (ES6 §14.1.20: non-writable, non-enumerable, configurable)
    // Always set name — anonymous functions get "" per spec
    char[] name_data = template.get_name();
    HString* name_hstr;
    if (name_data.len > 0) {
        name_hstr = intern_string(vm, name_data);
    } else {
        name_hstr = (HString*)vm.heap.strs[heap::BuiltinStr.EMPTY];
    }
    if (name_hstr != null) {
        TVal name_tv;
        name_tv.set_string(name_hstr);
        func_obj.put_prop((HString*)vm.heap.strs[heap::BuiltinStr.NAME], name_tv, hobject::PROP_FLAGS_NWC);
    }

    // `is_generator()` is overloaded at compile time (compile_inner_function /
    // arrow contexts): async functions also set it so the body can use the
    // same YIELD/LOAD_RESUME suspend machinery as real generators via AWAIT.
    // `is_generator() && !is_async()` is the idiom used elsewhere in the VM
    // (see the CALL_FN generator-init check in vm_execute.c3) to mean "really
    // is a spec GeneratorFunction" — async generators aren't supported by
    // this engine (rejected at parse time), so a true generator never has
    // is_async() set.
    bool is_true_generator = template.is_generator() && !template.is_async();

    // Constructable functions, plus generator functions (which are never
    // constructable but still expose a `.prototype` used as the generator
    // instance's prototype per ES2015 §14.4 GeneratorFunction), get a
    // .prototype property. Arrow functions, async functions, and (non-
    // generator) methods/accessors are not constructable and must not have
    // .prototype (ES6 §14.2.16, ES2017 §14.7.5, ES2015 §14.3.9 —
    // DefineMethod creates functions without .prototype).
    if (template.is_constructable() || is_true_generator) {
        // ES5 §13.2.2 step 15: create .prototype property on the function
        // (plain object with .constructor).  For regular functions the
        // flags are {writable:true, enumerable:false, configurable:false}.
        // For class constructors ES2015 §14.5.14 step 25 requires
        // {writable:false, enumerable:false, configurable:false} so
        // that `class C { static ['prototype']() {} }` throws TypeError.
        hobject::PropFlags proto_pflags = template.is_class_ctor()
            ? hobject::PROP_FLAGS_NNC   // non-writable, non-enumerable, non-configurable
            : hobject::PROP_FLAGS_WENC;  // writable, non-enumerable, non-configurable
        HObject*? proto_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try proto_obj = proto_obj_raw) {
            if (is_true_generator && vm.heap.generator_proto != null) {
                // Generator function .prototype inherits from Generator.prototype
                proto_obj.prototype = vm.heap.generator_proto;
                // .constructor is inherited from Generator.prototype,
                // no need to set it here.
            } else {
                proto_obj.prototype = vm.heap.object_proto;
                // Set .constructor on the prototype object
                // ES5 §13.2.2 step 17: {writable:true, enumerable:false, configurable:true}
                HString* constr_key = (HString*)vm.heap.strs[heap::BuiltinStr.CONSTRUCTOR];
                TVal constr_val;
                constr_val.set_object(func_obj);
                proto_obj.put_prop(constr_key, constr_val, hobject::PROP_FLAGS_WC);
            }
            // Set .prototype on the function
            HString* proto_key = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
            TVal proto_tv;
            proto_tv.set_object(proto_obj);
            func_obj.put_prop(proto_key, proto_tv, proto_pflags);
        }
    }

    return func_obj;
}

/// Sub-dispatch for CLOSURE, GETBOUND opcodes.
fn TVal? dispatch_closures(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.CLOSURE: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.inner_count) {
                CompiledFunction* template = vm.current_func.inner_funcs[bc];
                HObject* func_obj = instantiate_closure(vm, template, ds.act.var_env, ds.act.lex_env, &ds.act.this_binding, ds.act.new_target);
                if (func_obj != null) {
                    ra.set_object(func_obj);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.GETBOUND: {
            uint bc = insn.get_bc();
            // Constants[bc] = FASTINT depth, ds.constants[bc+1] = STRING name
            if (bc + 1 < vm.current_func.const_count) {
                TVal depth_val = ds.constants[bc];
                TVal name_val = ds.constants[bc + 1];
                if ((depth_val.is_fastint() || depth_val.is_number()) && name_val.is_string()) {
                    uint depth = (uint)(depth_val.is_fastint() ? depth_val.get_fastint() : (long)depth_val.get_number());
                    void* key = name_val.get_heapptr();
                    TVal? result = env::env_get_at_depth(ds.act.lex_env, depth, key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(ds.act, ra, (uint)insn.a);
                    } else {
                        // Also check var_env if different
                        if (ds.act.lex_env != ds.act.var_env) {
                            result = env::env_get_at_depth(ds.act.var_env, depth, key);
                            if (try v2 = result) {
                                vm.heap.tval_copy_ref(ra, &v2);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                                break;
                            }
                        }
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}

/// Sub-dispatch for INITFOR, NEXTFOR opcodes.
fn TVal? dispatch_iterator(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.INITFOR: {
            // ra = object to enumerate, rb = iter_state (output)
            // null/undefined → skip loop (rb = null marker)
            if (ra.is_null() || ra.is_undefined()) {
                rb.set_null();
                break;
            }

            // Get the object (ToObject for primitives)
            HObject* obj;
            if (ra.is_object()) {
                obj = (HObject*)ra.get_heapptr();
            } else if (ra.is_boolean()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.BOOLEAN);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.prototype = vm.heap.bool_proto;
                (*obj.extra_ptr()).prim.primitive_value.set_boolean(ra.get_boolean());
            } else if (ra.is_string()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.STRING);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.flags.exotic_stringobj = true;
                obj.prototype = vm.heap.string_proto;
                HString* prim_str = (HString*)ra.get_heapptr();
                (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
                // Set .length own property (ES5 §15.5.5.1) — non-writable, non-enumerable, non-configurable.
                // Indexed character properties are served lazily via exotic_stringobj during enumeration.
                HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_tv;
                len_tv.set_fastint((long)prim_str.char_length());
                obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
            } else if (ra.is_number() || ra.is_fastint()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.NUMBER);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.prototype = vm.heap.number_proto;
                vm.heap.tval_copy_ref(&(*obj.extra_ptr()).prim.primitive_value, ra);
            } else {
                rb.set_null();
                break;
            }

            // Collect enumerable keys
            ForInState* state = collect_forin_keys(vm, obj);
            if (state == null) {
                // A proxy trap may have thrown during key collection.
                if (vm.heap.has_error) {
                    TVal perr = vm.heap.error_value;
                    vm.heap.has_error = false;
                    if (!vm_throw_value(vm, perr, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &perr);
                    }
                    return (TVal){};
                }
                rb.set_null();
                break;
            }
            rb.set_pointer(state);
            return (TVal){};
        }

        case Opcode.NEXTFOR: {
            // ra = iter_var (output key), rb = has_next (output bool)
            // rc = iter_state (input ForInState*)
            ForInState* state = (ForInState*)rc.get_heapptr();
            if (state == null || state.index >= state.count) {
                // No more keys — clean up and signal done
                if (state != null) {
                    vm.heap.free_func(vm.heap.heap_udata, state.keys);
                    vm.heap.free_func(vm.heap.heap_udata, state);
                }
                rb.set_boolean(false);
                ra.set_undefined();
                break;
            }

            // Return the next key
            vm.heap.set_reg_string(ra, state.keys[state.index]);
            state.index++;
            rb.set_boolean(true);
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}


/// Sub-dispatch for NOP, DEBUGGER, BREAK, CONTINUE, INITGET, INITSET, INITSETI, CSVARI, PUSH_LEX, POP_LEX, REQUIRE_OBJ, CHKOBJ opcodes.
fn TVal? dispatch_misc(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.NOP:
            return (TVal){};

        case Opcode.DEBUGGER:
            return (TVal){};

        case Opcode.BREAK:
        case Opcode.CONTINUE: {
            // Compute the jump target from the signed 24-bit offset
            int sabc = insn.get_sabc();
            int target = (int)((long)(ds.curr_pc - ds.code_base) + (long)sabc);
            Instruction* target_pc = ds.code_base + target;

            // Check if any active catcher has a finally handler that
            // would be bypassed by this jump.  If so, save the target
            // and redirect to the finally handler.
            // If the current catcher's own finally is what we're executing
            // right now (CATCHER_FLAG_IN_FINALLY), redirecting to it again
            // would loop forever — this break/continue overrides whatever
            // pending completion it was carrying, so pop and discard it; it
            // will never reach ENDFINALLY. The next catcher up the chain may
            // itself be IN_FINALLY too (nested try/finally within the first
            // one's finally block) — in that case the jump target already
            // lies inside its still-active finally, so we don't redirect at
            // all and just let the jump proceed there directly.
            Catcher* bc_cat = (Catcher*)ds.act.cat;
            bool bc_target_in_active_finally = false;
            if (bc_cat != null && (bc_cat.flags & CATCHER_FLAG_IN_FINALLY) != 0) {
                Catcher* bc_parent = (Catcher*)bc_cat.parent;
                ds.act.cat = (void*)bc_parent;
                vm.heap.free_func(vm.heap.heap_udata, bc_cat);
                bc_cat = bc_parent;
                if (bc_cat != null && (bc_cat.flags & CATCHER_FLAG_IN_FINALLY) != 0) {
                    bc_target_in_active_finally = true;
                }
            }
            if (!bc_target_in_active_finally && bc_cat != null && bc_cat.finally_pc != null
                && (bc_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                // Save the pending jump target and flag on the catcher
                bc_cat.pending_pc = target_pc;
                if (insn.op == Opcode.BREAK) {
                    bc_cat.flags |= CATCHER_FLAG_PENDING_BREAK;
                } else {
                    bc_cat.flags |= CATCHER_FLAG_PENDING_CONTINUE;
                }
                // Jump to the finally handler
                ds.curr_pc = bc_cat.finally_pc;
                ds.act.curr_pc = ds.curr_pc;
                break;
            }
            // No active finally handler — jump directly to target
            if (target < (ds.curr_pc - ds.code_base)) {
                if (--vm.heap.bwd_gc_budget == 0) {
                    if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
                    vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL;
                }
            }
            ds.curr_pc = target_pc;
            return (TVal){};
        }

        case Opcode.INITGET: {
            // A=object, B=key, C=getter_function
            // Define a getter accessor property on object A with key B.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                TVal getter_val = *rc;
                if (key != null && hobj != null) {
                    // Check if property already exists as accessor
                    int idx = hobj.find_prop_idx(key);
                    TVal* initget_props = hobj.prop_values();
                    // DefinePropertyOrThrow: redefining a non-configurable
                    // non-accessor property (e.g. a static computed getter named
                    // "prototype"/"length" on the class constructor) throws.
                    if (idx >= 0 && !hobj.get_prop_flags((uint)idx).configurable
                        && !hobj.get_prop_flags((uint)idx).is_accessor) {
                        HString* nm = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Cannot redefine non-configurable property '%s'", nm.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    if (idx >= 0 && hobj.get_prop_flags((uint)idx).is_accessor) {
                        // Update existing accessor's getter
                        hobject::hobject_set_access_getter(initget_props[idx], getter_val, vm.heap);
                    } else {
                        // Create new accessor property
                        TVal undef;
                        undef.set_undefined();
                        hobj.put_prop(key, hobject::hobject_create_accessors(vm.heap, getter_val, undef), hobject::PROP_FLAGS_ACCESSOR);
                    }
                }
                // ES2015 §14.3 + §9.2.11 SetFunctionName: for computed-key
                // getters the compiler leaves the function name empty; set it
                // to "get <key>" or "get [desc]" (symbol) at object-creation time.
                if (rc.is_object() && key != null) {
                    class_initaccessor_set_name(vm, (HObject*)rc.get_heapptr(), rb, "get ");
                }
            }
            return (TVal){};
        }

        case Opcode.INITSET: {
            // A=object, B=key, C=setter_function
            // Define a setter accessor property on object A with key B.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                TVal setter_val = *rc;
                if (key != null && hobj != null) {
                    // Check if property already exists as accessor
                    int idx = hobj.find_prop_idx(key);
                    TVal* initset_props = hobj.prop_values();
                    if (idx >= 0 && !hobj.get_prop_flags((uint)idx).configurable
                        && !hobj.get_prop_flags((uint)idx).is_accessor) {
                        HString* nm = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Cannot redefine non-configurable property '%s'", nm.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    if (idx >= 0 && hobj.get_prop_flags((uint)idx).is_accessor) {
                        // Update existing accessor's setter
                        hobject::hobject_set_access_setter(initset_props[idx], setter_val, vm.heap);
                    } else {
                        // Create new accessor property
                        TVal undef;
                        undef.set_undefined();
                        hobj.put_prop(key, hobject::hobject_create_accessors(vm.heap, undef, setter_val), hobject::PROP_FLAGS_ACCESSOR);
                    }
                }
                // ES2015 §14.3 + §9.2.11 SetFunctionName: for computed-key
                // setters the compiler leaves the function name empty; set it
                // to "set <key>" or "set [desc]" (symbol) at object-creation time.
                if (rc.is_object() && key != null) {
                    class_initaccessor_set_name(vm, (HObject*)rc.get_heapptr(), rb, "set ");
                }
            }
            return (TVal){};
        }

        case Opcode.INITPROP: {
            // A=object, B=key, C=value
            // Define a data property with WEC flags using DefinePropertyOrThrow
            // semantics: if the property already exists and is configurable, it
            // is replaced. Used for array literals and class static methods.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();

                // Fast path for ARRAY/ARGUMENTS with integer keys: write directly
                // to the dense part (always WEC, no proto-chain check needed).
                // Skip for undefined values: undefined == hole in dense arrays,
                // so explicit `undefined` elements need a named property instead.
                if (!rc.is_undefined()
                    && (hobj.get_class() == hobject::ObjClass.ARRAY || hobj.get_class() == hobject::ObjClass.ARGUMENTS)
                    && (rb.is_fastint() || rb.is_number())) {
                    long idx_long = rb.is_fastint() ? rb.get_fastint() : (long)rb.get_number();
                    if (idx_long >= 0 && idx_long < 0xFFFFFFFFL && idx_long < 0x1000000L) {
                        uint idx = (uint)idx_long;
                        if (hobj.set_array_idx(idx, *rc)) {
                            if (hobj.get_class() == hobject::ObjClass.ARRAY && idx >= *hobj.array_len_ptr()) {
                                *hobj.array_len_ptr() = idx + 1;
                            }
                            return (TVal){};
                        }
                        // Dense write failed (capacity cap) — fall through to named-prop.
                    }
                }

                initprop_define(vm, hobj, rb, rc);
            }
            return (TVal){};
        }

        case Opcode.INITPROPN: {
            // A=object, B=key, C=value — identical to INITPROP (minus the
            // array dense-write fast path, since this opcode is only emitted
            // for object-literal data/method properties), but additionally
            // performs SetFunctionName if the value is a function with an
            // empty name. Used for object-literal data properties (`key:
            // value`) whose value is statically known to be an
            // AnonymousFunctionDefinition (ES2015 §12.2.6.9 step 6), and for
            // computed-key method shorthand (always renamed unconditionally,
            // like class methods) — the compiler already names static-key
            // cases directly, so this only fires for computed keys.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                initprop_define(vm, hobj, rb, rc);
                if (rc.is_object()) {
                    class_initaccessor_set_name(vm, (HObject*)rc.get_heapptr(), rb, "");
                }
            }
            return (TVal){};
        }

        case Opcode.INITSETI:
            return (TVal){};

        case Opcode.CLASS_INITGET: {
            // A=object, B=key, C=getter_function
            // Define a getter accessor property on object A with key B.
            // Per ES2015 §14.5.14 step 9: {enumerable:false, configurable:true}.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                // ToPropertyKey abrupt completion: propagate as throw (§14.5.14 step 9.a.i).
                if (vm.throw_pending) {
                    vm.throw_pending = false;
                    if (!vm_throw_value(vm, vm.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &vm.throw_value);
                    }
                    return (TVal){};
                }
                TVal getter_val = *rc;
                if (key != null && hobj != null) {
                    // Check if property already exists as accessor
                    int idx = hobj.find_prop_idx(key);
                    TVal* initget_props = hobj.prop_values();
                    // A private get/set pair (`get #x` + `set #x`) shares one
                    // hidden-symbol key and is installed non-configurable —
                    // merging the other half of the pair into the SAME
                    // accessor cell must take precedence over the
                    // non-configurable rejection below (which exists to catch
                    // genuine PUBLIC-key redefinition attempts, e.g. a
                    // non-configurable `.prototype`).
                    if (idx >= 0 && hobj.get_prop_flags((uint)idx).is_accessor) {
                        // Update existing accessor's getter
                        hobject::hobject_set_access_getter(initget_props[idx], getter_val, vm.heap);
                    } else if (idx >= 0 && !hobj.get_prop_flags((uint)idx).configurable) {
                        // Non-configurable: DefinePropertyOrThrow throws TypeError
                        // (e.g. redefining the class constructor's non-configurable
                        // .prototype via `static get ['prototype']() {}`).
                        HString* key_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto,
                            "Cannot redefine non-configurable property '%s'", key_hstr.get_cstr(),
                            ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    } else {
                        // Create new accessor property. Private accessors
                        // (hidden-symbol key — ES2022 §7.3.28) are
                        // non-configurable; public class accessors remain
                        // configurable per §14.5.14 step 9.
                        TVal undef;
                        undef.set_undefined();
                        HString* key_hs_g = (HString*)key;
                        hobject::PropFlags initget_flags = key_hs_g.is_hidden()
                            ? hobject::PROP_FLAGS_PRIVATE_ACCESSOR : hobject::PROP_FLAGS_CLASS_ACCESSOR;
                        hobj.put_prop(key, hobject::hobject_create_accessors(vm.heap, getter_val, undef), initget_flags);
                    }
                }
                // ES2015 §14.5.14 + §9.2.11 SetFunctionName: for computed-key
                // accessors the compiler leaves the function name empty; set it
                // to "get <key>" or "get [desc]" (symbol) at class evaluation time.
                // Private accessors have their "get #name" set at compile time
                // (non-empty), so this is a no-op for them.
                if (rc.is_object() && key != null) {
                    class_initaccessor_set_name(vm, (HObject*)rc.get_heapptr(), rb, "get ");
                }
            }
            return (TVal){};
        }

        case Opcode.CLASS_INITSET: {
            // A=object, B=key, C=setter_function
            // Define a setter accessor property on object A with key B.
            // Per ES2015 §14.5.14 step 9: {enumerable:false, configurable:true}.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                // ToPropertyKey abrupt completion: propagate as throw (§14.5.14 step 9.a.i).
                if (vm.throw_pending) {
                    vm.throw_pending = false;
                    if (!vm_throw_value(vm, vm.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &vm.throw_value);
                    }
                    return (TVal){};
                }
                TVal setter_val = *rc;
                if (key != null && hobj != null) {
                    // Check if property already exists as accessor
                    int idx = hobj.find_prop_idx(key);
                    TVal* initset_props = hobj.prop_values();
                    // See CLASS_INITGET: a private get/set pair merge must be
                    // checked before the non-configurable rejection.
                    if (idx >= 0 && hobj.get_prop_flags((uint)idx).is_accessor) {
                        // Update existing accessor's setter
                        hobject::hobject_set_access_setter(initset_props[idx], setter_val, vm.heap);
                    } else if (idx >= 0 && !hobj.get_prop_flags((uint)idx).configurable) {
                        // Non-configurable: DefinePropertyOrThrow throws TypeError
                        // (e.g. redefining the class constructor's non-configurable
                        // .prototype via `static set ['prototype'](_) {}`).
                        HString* key_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto,
                            "Cannot redefine non-configurable property '%s'", key_hstr.get_cstr(),
                            ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    } else {
                        // Create new accessor property. Private accessors
                        // (hidden-symbol key) are non-configurable; public
                        // class accessors remain configurable (§14.5.14 step 9).
                        TVal undef;
                        undef.set_undefined();
                        HString* key_hs_s = (HString*)key;
                        hobject::PropFlags initset_flags = key_hs_s.is_hidden()
                            ? hobject::PROP_FLAGS_PRIVATE_ACCESSOR : hobject::PROP_FLAGS_CLASS_ACCESSOR;
                        hobj.put_prop(key, hobject::hobject_create_accessors(vm.heap, undef, setter_val), initset_flags);
                    }
                }
                // ES2015 §14.5.14 + §9.2.11 SetFunctionName: for computed-key
                // accessors the compiler leaves the function name empty; set it
                // to "set <key>" or "set [desc]" (symbol) at class evaluation time.
                if (rc.is_object() && key != null) {
                    class_initaccessor_set_name(vm, (HObject*)rc.get_heapptr(), rb, "set ");
                }
            }
            return (TVal){};
        }

        case Opcode.CLASS_INITPROP: {
            // A=object, B=key, C=value
            // Define a class method property with {writable:true, enumerable:false, configurable:true}
            // using DefinePropertyOrThrow semantics (overrides any existing configurable property).
            // Per ES2015 §14.5.14 step 9.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                // ToPropertyKey abrupt completion: propagate as throw (§14.5.14 step 9.a.i).
                if (vm.throw_pending) {
                    vm.throw_pending = false;
                    if (!vm_throw_value(vm, vm.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &vm.throw_value);
                    }
                    return (TVal){};
                }
                if (key != null && hobj != null) {
                    int idx = hobj.find_prop_idx(key);
                    if (idx >= 0) {
                        // Existing property — if configurable, replace it.
                        hobject::PropFlags ef = hobj.get_prop_flags((uint)idx);
                        if (ef.configurable) {
                            TVal put_val = *rc;
                            vm.heap.tval_copy_ref(&hobj.prop_values()[idx], &put_val);
                            hobject::PropFlags nf;
                            nf.writable = true;
                            nf.enumerable = false;
                            nf.configurable = true;
                            nf.is_accessor = false;
                            hobj.set_prop_flags((uint)idx, nf);
                        } else {
                            // Non-configurable: DefinePropertyOrThrow throws TypeError
                            // (§14.3.9 MethodDefinitionEvaluation, §10.1.6.3 ValidateAndApplyPropertyDescriptor).
                            HString* key_hstr = (HString*)key;
                            if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto,
                                "Cannot redefine non-configurable property '%s'", key_hstr.get_cstr(),
                                ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            return (TVal){};
                        }
                    } else {
                        // Private methods (hidden-symbol key) are non-writable
                        // per ES2022 §7.3.28 PrivateMethodOrAccessorAdd; public
                        // class methods remain writable (§14.5.14 step 9).
                        HString* key_hs_m = (HString*)key;
                        hobject::PropFlags initprop_flags = key_hs_m.is_hidden()
                            ? hobject::PROP_FLAGS_NNC : hobject::PROP_FLAGS_CLASS_METHOD;
                        hobj.put_prop(key, *rc, initprop_flags);
                    }
                }
                // ES2015 §9.2.11 SetFunctionName for computed-key methods:
                // if the function's .name is empty, set it to the key name
                // (string) or "[desc]" (symbol) — no prefix for plain methods.
                if (rc.is_object() && key != null) {
                    class_initaccessor_set_name(vm, (HObject*)rc.get_heapptr(), rb, "");
                }
            }
            return (TVal){};
        }

        case Opcode.CSVARI:
            return (TVal){};

        // === WITH STATEMENT REMOVED IN STRICT-ONLY MODE ===

        case Opcode.PUSH_LEX: {
            // Push a new declarative environment record onto ds.act.lex_env.
            EnvRecord*? env_raw = env::env_create_declarative(vm.heap, ds.act.lex_env);
            if (try new_env = env_raw) {
                ds.act.lex_env = new_env;
            } else {
                return VM_ERROR~;
            }
            return (TVal){};
        }

        case Opcode.POP_LEX: {
            // Pop the current lexical environment from the scope chain.
            if (ds.act.lex_env != null && ds.act.lex_env.parent != null) {
                ds.act.lex_env = ds.act.lex_env.parent;
            }
            return (TVal){};
        }

        case Opcode.PUSH_VAR: {
            // Push a new declarative environment for the function body's var scope.
            // Per §9.2.10 step 27: when hasParameterExpressions is true, body vars
            // must not share the same environment as parameter bindings.
            EnvRecord*? pvar_raw = env::env_create_declarative(vm.heap, ds.act.var_env);
            if (try new_var_env = pvar_raw) {
                ds.act.var_env = new_var_env;
                // lex_env must also advance so PUTLEX / GETVAR resolve in the right scope
                ds.act.lex_env = new_var_env;
            } else {
                return VM_ERROR~;
            }
            return (TVal){};
        }

        case Opcode.POP_VAR: {
            // Restore the variable environment to its parent (undo PUSH_VAR).
            if (ds.act.var_env != null && ds.act.var_env.parent != null) {
                ds.act.var_env = ds.act.var_env.parent;
            }
            if (ds.act.lex_env != null && ds.act.lex_env.parent != null) {
                ds.act.lex_env = ds.act.lex_env.parent;
            }
            return (TVal){};
        }

        case Opcode.REQUIRE_OBJ: {
            // Throw TypeError if the value in register A is null or undefined.
            // Used for object destructuring pattern null/undefined check.
            if (ra.is_null() || ra.is_undefined()) {
                vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Cannot destructure '%s'",
                                    (ra.is_null() ? "null" : "undefined"),
                                    ds.act, &ds.curr_pc, &ds.needs_restart);
            }
            return (TVal){};
        }

        case Opcode.CHKOBJ: {
            // Throw TypeError if the value in register A is not an Object.
            // Used by for-of to validate the .next() result (ES2022 §14.7.5.6 step 3.b).
            if (!ra.is_object() || ra.get_heapptr() == null) {
                vm_throw_error(vm, vm.heap.type_err_proto,
                    "Iterator result is not an object",
                    ds.act, &ds.curr_pc, &ds.needs_restart);
            }
            return (TVal){};
        }

        case Opcode.ITER_CLOSE: {
            // IteratorClose (ES2022 §7.4.6): if the value in A is an
            // object with a callable `.return` method, call it with
            // this = A. Discards the result; any error from `.return()`
            // propagates as a normal throw. If A is not an object, or
            // has no `.return` method, do nothing (per spec).
            //
            // B field encodes the completion type:
            //   B=0 — non-throw completion (break / return / exhaustion):
            //         propagate errors from .return access (TypeError if
            //         non-callable) and from .return() call.
            //   B=1 — throw completion (body threw):
            //         suppress all errors from .return access / call; the
            //         original throw takes precedence (§7.4.6 steps 6,8).
            //   B=2 — auto: emitted inside a finally that handles ANY completion.
            //         Inspect the enclosing (in-finally) catcher's pending state:
            //         a pending throw suppresses (§7.4.6 step 6/8), while a
            //         pending return/break/continue or a normal completion
            //         propagates .return() errors.
            bool is_throw_completion = (insn.b == 1);
            if (insn.b == 2) {
                is_throw_completion = false;
                Catcher* icc = (Catcher*)ds.act.cat;
                if (icc != null && !icc.thrown_val.is_undefined()) {
                    is_throw_completion = true;
                }
            }

            if (!ra.is_object() || ra.get_heapptr() == null) return (TVal){};
            HObject* iter = (HObject*)ra.get_heapptr();
            HString* ret_key = intern_string(vm, "return");

            // Use get_with_accessors to properly invoke accessor getters
            // (ES2022 §7.4.6 step 4: GetMethod calls GetV which invokes getters).
            hobject::PropLookupResult ret_lookup = iter.get_with_accessors(ret_key);

            // If .return accessor threw during access, propagate for non-throw,
            // suppress for throw completion.
            if (vm.has_error) {
                if (is_throw_completion) {
                    vm.has_error = false;
                    vm.heap.has_error = false;
                    return (TVal){};
                }
                TVal thrown = vm.return_val;
                vm.has_error = false;
                vm.heap.has_error = false;
                if (!vm_throw_value(vm, thrown, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &thrown);
                }
                return (TVal){};
            }

            // Not found or undefined — no close needed.
            if (ret_lookup.kind == hobject::PropLookupKind.PROP_NOT_FOUND) {
                return (TVal){};
            }

            TVal ret_method;
            if (ret_lookup.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                // Accessor property: invoke the getter to get the actual value.
                hobject::AccessorResult acc = ret_lookup.acc;
                if (acc.accessor_fn.is_object() && acc.accessor_fn.get_heapptr() != null) {
                    HObject* getter = (HObject*)acc.accessor_fn.get_heapptr();
                    if (getter.is_callable()) {
                        TVal this_arg; this_arg.set_object(iter);
                        ret_method = vm.heap.call_fn(vm, acc.accessor_fn, null, 0, this_arg);
                        if (vm.has_error) {
                            if (is_throw_completion) {
                                vm.has_error = false;
                                vm.heap.has_error = false;
                                return (TVal){};
                            }
                            TVal thrown = vm.return_val;
                            vm.has_error = false;
                            vm.heap.has_error = false;
                            if (!vm_throw_value(vm, thrown, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return vm_uncaught_error(vm, &thrown);
                            }
                            return (TVal){};
                        }
                    } else {
                        ret_method = acc.accessor_fn;
                    }
                } else {
                    // Getter returned non-object (null / undefined) — treat as undefined.
                    return (TVal){};
                }
            } else {
                ret_method = ret_lookup.data_val;
            }

            // If result is undefined or null, no close needed (§7.4.6 step 5).
            if (ret_method.is_nullish()) return (TVal){};

            // Must be callable (§7.4.6 step 4: GetMethod checks IsCallable).
            if (!ret_method.is_object() || ret_method.get_heapptr() == null) {
                if (is_throw_completion) return (TVal){};
                // Non-throw: throw TypeError for non-callable .return.
                HObject*? te_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try te = te_raw) {
                    te.prototype = vm.heap.type_err_proto;
                    HString* mk = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                    HString* ms = intern_string(vm, "Iterator .return is not a function");
                    TVal mv; mv.set_string(ms);
                    te.put_prop(mk, mv, hobject::PROP_FLAGS_WEC);
                    TVal tv; tv.set_object(te);
                    if (!vm_throw_value(vm, tv, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &tv);
                    }
                }
                return (TVal){};
            }
            HObject* rm_obj = (HObject*)ret_method.get_heapptr();
            if (rm_obj == null || !rm_obj.is_callable()) {
                if (is_throw_completion) return (TVal){};
                HObject*? te_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try te = te_raw) {
                    te.prototype = vm.heap.type_err_proto;
                    HString* mk = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                    HString* ms = intern_string(vm, "Iterator .return is not a function");
                    TVal mv; mv.set_string(ms);
                    te.put_prop(mk, mv, hobject::PROP_FLAGS_WEC);
                    TVal tv; tv.set_object(te);
                    if (!vm_throw_value(vm, tv, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &tv);
                    }
                }
                return (TVal){};
            }

            // Call .return() (§7.4.6 step 7).
            TVal this_arg; this_arg.set_object(iter);
            TVal ret_result = vm.heap.call_fn(vm, ret_method, null, 0, this_arg);
            if (vm.has_error) {
                if (is_throw_completion) {
                    vm.has_error = false;
                    vm.heap.has_error = false;
                    return (TVal){};
                }
                TVal thrown = vm.return_val;
                vm.has_error = false;
                vm.heap.has_error = false;
                if (!vm_throw_value(vm, thrown, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return vm_uncaught_error(vm, &thrown);
                }
                return (TVal){};
            }
            // ES2022 §7.4.6 step 8: result must be an Object.
            if (!ret_result.is_object() || ret_result.get_heapptr() == null) {
                if (is_throw_completion) return (TVal){};
                HObject*? te_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try te = te_raw) {
                    te.prototype = vm.heap.type_err_proto;
                    HString* mk = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                    HString* ms = intern_string(vm, "Iterator .return() must return an object");
                    TVal mv; mv.set_string(ms);
                    te.put_prop(mk, mv, hobject::PROP_FLAGS_WEC);
                    TVal tv; tv.set_object(te);
                    if (!vm_throw_value(vm, tv, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &tv);
                    }
                }
                return (TVal){};
            }
            return (TVal){};
        }

        case Opcode.CHKCTOR: {
            // ES2022 §15.7.14 step 5.f: throw TypeError if the superclass
            // value is not null and not a constructor, before .prototype access.
            bool is_ctor = false;
            if (ra.is_lightfunc()) {
                uint lf_idx = (uint)(usz)ra.get_heapptr();
                is_ctor = lightfunc_get_proto(vm, lf_idx) != null;
            } else if (ra.is_null()) {
                is_ctor = true;   // null extends is explicitly legal
            } else if (ra.is_object() && ra.get_heapptr() != null) {
                HObject* base_obj = (HObject*)ra.get_heapptr();
                is_ctor = base_obj.flags.constructable;
            }
            if (!is_ctor) {
                if (!vm_throw_error(vm, vm.heap.type_err_proto,
                        "class extends value is not a constructor or null",
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
            }
            return (TVal){};
        }

        case Opcode.CHK_PROT: {
            // ES2015 §14.5.14 step 5.g.ii-iv: after Get(superclass, "prototype"),
            // throw TypeError if the result is neither Object nor Null.
            // Used for `class P extends Proxy {}` (Proxy.prototype is undefined).
            bool ok = ra.is_null() || (ra.is_object() && ra.get_heapptr() != null);
            if (!ok) {
                if (!vm_throw_error(vm, vm.heap.type_err_proto,
                        "Class extends value prototype is not an object or null",
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
            }
            return (TVal){};
        }

        case Opcode.NEW_PRIV_SYM: {
            // A=dst register, BC=constant pool index of the description string.
            // dst := a fresh hidden symbol, unique per execution of this
            // instruction (per §6.2.4 each class evaluation creates a fresh
            // PrivateEnvironment).
            uint bc = insn.get_bc();
            char[] desc = {};
            if (bc < vm.current_func.const_count) {
                TVal desc_tv = ds.constants[bc];
                if (desc_tv.is_string()) {
                    HString* desc_hs = (HString*)desc_tv.get_heapptr();
                    desc = desc_hs.get_data();
                }
            }
            HString* sym = builtins::create_hidden_symbol(vm.heap, desc);
            if (sym == null) { ra.set_undefined(); return (TVal){}; }
            ra.set_string(sym);
            track_heap_store(ds.act, ra, (uint)insn.a);
            return (TVal){};
        }

        case Opcode.ADD_BRAND: {
            // A=object, B=register holding the brand symbol.
            // obj[brand_sym] = true as a non-writable, non-enumerable,
            // non-configurable own property, bypassing the extensibility
            // check (PrivateBrandAdd has no [[Extensible]] gate).
            if (ra.is_object() && rb.is_string()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = rb.get_heapptr();
                if (hobj != null && key != null) {
                    TVal true_tv;
                    true_tv.set_boolean(true);
                    hobj.put_prop(key, true_tv, hobject::PROP_FLAGS_NNC);
                }
            }
            return (TVal){};
        }

        case Opcode.CHK_BRAND: {
            // A=object, B=register holding the brand symbol, C=constant pool
            // index of the private name (0xFF = unknown — not encodable in
            // 8 bits). Throws TypeError unless A is an object AND has the
            // brand symbol as an OWN property (own-only: must not walk the
            // prototype chain, or Object.create(instance).#x would falsely pass).
            bool ok = false;
            if (ra.is_object() && rb.is_string()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = rb.get_heapptr();
                if (hobj != null && key != null) {
                    ok = hobj.find_prop_idx(key) >= 0;
                }
            }
            if (!ok) {
                char[] priv_name = "?";
                uint c = insn.c;
                if (c != 0xFF && c < vm.current_func.const_count) {
                    TVal name_tv = ds.constants[c];
                    if (name_tv.is_string()) {
                        HString* name_hs = (HString*)name_tv.get_heapptr();
                        priv_name = name_hs.get_data();
                    }
                }
                char[160] msg_buf;
                int len = (int)(io::bprintf(&msg_buf,
                    "Cannot access private member #%s from an object whose class did not declare it",
                    (String)priv_name) ?? msg_buf[:0]).len;
                char[] msg = len > 0 && (usz)len < msg_buf.len ? msg_buf[:(usz)len] : (char[])"Cannot access private member from an object whose class did not declare it";
                if (!vm_throw_error(vm, vm.heap.type_err_proto, msg,
                        ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
            }
            return (TVal){};
        }

        case Opcode.INITPROP_PRIV: {
            // A=object, B=key register (private symbol), C=value register.
            // Define an own data property {writable:true, enumerable:false,
            // configurable:false}, bypassing setters, proxies, and the
            // extensibility check (spec PrivateFieldAdd).
            if (ra.is_object() && rb.is_string()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = rb.get_heapptr();
                if (hobj != null && key != null) {
                    hobj.put_prop(key, *rc, hobject::PROP_FLAGS_WENC);
                }
            }
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}

