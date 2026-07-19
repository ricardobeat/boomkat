/// Error constructors: Error, TypeError, RangeError, ReferenceError, SyntaxError, EvalError, URIError, AggregateError.
module duktape::builtins;
import duktape::types;
import duktape::env;
import libc;
import duktape::hstring;
import duktape::hobject;

import duktape::heap;

// ============================================================================
// Error constructor builtins
// ============================================================================

/// Shared constructor: create an error object with ObjClass.ERROR,
/// set prototype to `proto`, and set .message from args[0] if provided.
/// Also handles the ES2022 `options.cause` install (step 4 of the spec).
fn void builtin_error_constructor_shared(BuiltinContext* ctx, HObject* proto) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err = err_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* err = err_raw;
    err.prototype = builtin_proto_from_new_target(ctx, proto);

    // Set .message if first arg is provided and not undefined
    HString* msg_str = null;
    if (ctx.argc > 0) {
        TVal* msg_arg = &ctx.regs[ctx.base_reg];
        if (!msg_arg.is_undefined()) {
            msg_str = builtin_to_string_vm(ctx, msg_arg);
            if (ctx.should_throw) return;
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
        }
    }

    // ES2022 §20.5.8.1 InstallErrorCause (O, options)
    // Called as step 4 of every Error/NativeError constructor. If options is
    // an Object and ? HasProperty(options, "cause") is true, install ? Get(options,
    // "cause") as a non-enumerable data property {writable:true, configurable:true,
    // enumerable:false} on O. Both HasProperty and Get can invoke user code (Proxy
    // traps, accessor getters) and must propagate an abrupt completion.
    if (ctx.argc >= 2) {
        TVal* opt_arg = &ctx.regs[ctx.base_reg + 1];
        if (opt_arg.is_object() && opt_arg.get_heapptr() != null) {
            HObject* opt_obj = (HObject*)opt_arg.get_heapptr();
            HString* cause_key = builtin_intern_string(ctx.heap, "cause");
            bool has_cause;
            if (!js_has_property(ctx.vm, ctx.heap, opt_obj, cause_key, &has_cause)) {
                proxy_ctx_ok(ctx);
                return;
            }
            if (has_cause) {
                TVal? cause_prop = builtins_generic_get(opt_obj, cause_key, ctx);
                if (ctx.should_throw) return;
                if (try cv = cause_prop) {
                    err.put_prop(cause_key, cv, hobject::PROP_FLAGS_WC);
                }
            }
        }
    }

    // Set .stack property (stub — "name: message" format for now)
    {
        HString* stack_key = (HString*)ctx.heap.strs[heap::BuiltinStr.STACK];

        // Get the error name from the prototype's .name property
        HString* name_str = builtin_intern_string(ctx.heap, "Error");
        if (proto != null) {
            HString* name_key = (HString*)ctx.heap.strs[heap::BuiltinStr.NAME];
            TVal? name_prop = proto.get_prop_proto(name_key);
            if (try nv = name_prop) {
                if (!nv.is_undefined()) {
                    HString* tmp = builtin_to_string(ctx.heap, &nv);
                    if (tmp != null) name_str = tmp;
                }
            }
        }

        // Build stack string: "name: message"
        char[512] stack_buf;
        int pos = 0;

        // Copy name
        if (name_str.blen > 0) {
            mem::copy(&stack_buf[pos], name_str.get_cstr(), (sz)(name_str.blen));
            pos += (int)name_str.blen;
        }

        // Add ": "
        stack_buf[pos] = ':'; pos++;
        stack_buf[pos] = ' '; pos++;

        // Copy message (or empty string if no message)
        if (msg_str != null && msg_str.blen > 0) {
            mem::copy(&stack_buf[pos], msg_str.get_cstr(), (sz)(msg_str.blen));
            pos += (int)msg_str.blen;
        }

        HString* stack_str = builtin_intern_string(ctx.heap, stack_buf[:pos]);
        TVal stack_tv;
        stack_tv.set_string(stack_str);
        err.put_prop(stack_key, stack_tv, hobject::PROP_FLAGS_WC);
    }

    ctx.result.set_object(null);
    ctx.result.set_fastint(0);
    ctx.result.set_object(err);
}

fn void builtin_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.err_proto);
}

fn void builtin_type_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.type_err_proto);
}

fn void builtin_range_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.range_err_proto);
}

fn void builtin_reference_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.ref_err_proto);
}

fn void builtin_syntax_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.syntax_err_proto);
}

fn void builtin_eval_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.eval_err_proto);
}

fn void builtin_uri_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.uri_err_proto);
}

// ============================================================================
// AggregateError constructor — ES2021 §28.1.1.1
// ============================================================================

fn void builtin_aggregate_error(BuiltinContext* ctx) {
    // Get errors argument
    TVal errors_val;
    errors_val.set_undefined();
    if (ctx.argc >= 1) errors_val = ctx.regs[ctx.base_reg];

    // Get message argument (optional)
    TVal msg_val;
    msg_val.set_undefined();
    if (ctx.argc >= 2) msg_val = ctx.regs[ctx.base_reg + 1];

    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err = err_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* err = err_raw;
    err.prototype = builtin_proto_from_new_target(ctx, ctx.heap.aggregate_err_proto);

    // Set .message if provided and not undefined
    HString* msg_str = null;
    if (!msg_val.is_undefined()) {
        msg_str = builtin_to_string(ctx.heap, &msg_val);
        if (msg_str != null) {
            TVal msg_prop;
            msg_prop.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_prop, hobject::PROP_FLAGS_WC);
        }
    }

    // Set .stack property (stub — "AggregateError: message" format for now)
    {
        HString* stack_key = (HString*)ctx.heap.strs[heap::BuiltinStr.STACK];
        char[512] stack_buf;
        int pos = 0;

        // Copy "AggregateError"
        HString* name_str = builtin_intern_string(ctx.heap, "AggregateError");
        if (name_str.blen > 0) {
            mem::copy(&stack_buf[pos], name_str.get_cstr(), (sz)(name_str.blen));
            pos += (int)name_str.blen;
        }

        // Add ": "
        stack_buf[pos] = ':'; pos++;
        stack_buf[pos] = ' '; pos++;

        // Copy message (or empty string if no message)
        if (msg_str != null && msg_str.blen > 0) {
            mem::copy(&stack_buf[pos], msg_str.get_cstr(), (sz)(msg_str.blen));
            pos += (int)msg_str.blen;
        }

        HString* stack_str = builtin_intern_string(ctx.heap, stack_buf[:pos]);
        TVal stack_tv;
        stack_tv.set_string(stack_str);
        err.put_prop(stack_key, stack_tv, hobject::PROP_FLAGS_WC);
    }

    // Set .errors array
    HString* errors_key = builtin_intern_string(ctx.heap, "errors");
    if (!errors_val.is_undefined()) {
        err.put_prop(errors_key, errors_val, hobject::PROP_FLAGS_WC);
    } else {
        HObject*? empty_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (try arr = empty_arr) {
            arr.prototype = ctx.heap.array_proto;
            TVal arr_tv;
            arr_tv.set_object(arr);
            err.put_prop(errors_key, arr_tv, hobject::PROP_FLAGS_WC);
        }
    }

    // ES2022 §20.5.8.1 InstallErrorCause — AggregateError's 3rd arg is options.
    if (ctx.argc >= 3) {
        TVal* opt_arg = &ctx.regs[ctx.base_reg + 2];
        if (opt_arg.is_object() && opt_arg.get_heapptr() != null) {
            HObject* opt_obj = (HObject*)opt_arg.get_heapptr();
            HString* cause_key = builtin_intern_string(ctx.heap, "cause");
            if (opt_obj.has_prop(cause_key)) {
                TVal? cause_prop = opt_obj.get_prop(cause_key);
                if (try cv = cause_prop) {
                    err.put_prop(cause_key, cv, hobject::PROP_FLAGS_WC);
                }
            }
        }
    }

    ctx.result.set_object(null);
    ctx.result.set_fastint(0);
    ctx.result.set_object(err);
}

// ============================================================================
// Error.prototype.toString — returns "name: message" per ES5 §15.11.4.4
// ============================================================================

fn void builtin_error_prototype_to_string(BuiltinContext* ctx) {
    // Get 'this' value (stored at base_reg - 1 in the value stack)
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    // ES2015 §19.5.3.4 step 2-3: if `this` is not an Object, throw a TypeError.
    // (Covers Error.prototype.toString.call(undefined) and calling it as a
    // plain function with no receiver.)
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Error.prototype.toString called on non-object");
        return;
    }

    // Default name is "Error"
    HString* name_str = builtin_intern_string(ctx.heap, "Error");
    HString* msg_str  = builtin_intern_string(ctx.heap, "");

    {
        HObject* obj = (HObject*)this_val.get_heapptr();

        // ES2015 §19.5.3.4 step 3: let name be ? Get(O, "name"). We must use a
        // full [[Get]] (not get_prop_proto) so accessor getters on the
        // prototype chain are invoked — and so their throws propagate via
        // ctx.should_throw per ES2017 §25.4.1.5 step 7 (test262 get-throws).
        HString* name_key = builtin_intern_string(ctx.heap, "name");
        TVal? name_prop = builtins_generic_get(obj, name_key, ctx);
        if (ctx.should_throw) return;
        if (try nv = name_prop) {
            if (!nv.is_undefined()) {
                // ES2015 §19.5.3.4 step 4: ? ToString(name) — ToString on a
                // Symbol must throw TypeError per ES2022 §7.1.4, and on an
                // Object must invoke toPrimitive (h.string/valueOf) first per
                // §7.1.1. builtin_to_string_vm handles both; builtin_to_string
                // would silently stringify a Symbol as "Symbol(desc)".
                HString* tmp = builtin_to_string_vm(ctx, &nv);
                if (ctx.should_throw) return;
                if (tmp != null) name_str = tmp;
            }
        }

        // ES2015 §19.5.3.4 step 5: let msg be ? Get(O, "message"); step 6: ? ToString(msg)
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        TVal? msg_prop = builtins_generic_get(obj, msg_key, ctx);
        if (ctx.should_throw) return;
        if (try mv = msg_prop) {
            if (!mv.is_undefined()) {
                HString* tmp = builtin_to_string_vm(ctx, &mv);
                if (ctx.should_throw) return;
                if (tmp != null) {
                    msg_str = tmp;
                }
            }
        }
    }
    if (name_str.blen == 0) {
        ctx.result.set_string(msg_str);
    } else if (msg_str.blen == 0) {
        ctx.result.set_string(name_str);
    } else {
        // Format: "name: message"
        usz total = (usz)name_str.blen + 2 + (usz)msg_str.blen;
        char[256] buf;
        char* name_cstr = name_str.get_cstr();
        char* msg_cstr = msg_str.get_cstr();
        int len = libc::snprintf(&buf, 256, "%s: %s", name_cstr, msg_cstr);
        if (len > 0 && len < 256) {
            HString* result_str = builtin_intern_string(ctx.heap, buf[:len]);
            ctx.result.set_string(result_str);
        } else {
            ctx.result.set_undefined();
        }
    }
}
// ============================================================================
// Error.captureStackTrace — V8/SpiderMonkey extension (ES6 §19.5.2.1 stub)
// ============================================================================

fn void builtin_error_captureStackTrace(BuiltinContext* ctx) {
    // Error.captureStackTrace(targetObject [, constructorOpt])
    if (ctx.argc < 1 || !ctx.regs[ctx.base_reg].is_object()) {
        // Throw TypeError
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Error.captureStackTrace requires an object argument");
        return;
    }
    HObject* target = (HObject*)ctx.regs[ctx.base_reg].get_heapptr();
    // Set target.stack = "" (empty string stub)
    HString* stack_key = builtin_intern_string(ctx.heap, "stack");
    HString* empty = builtin_intern_string(ctx.heap, "");
    TVal stack_tv;
    stack_tv.set_string(empty);
    target.put_prop(stack_key, stack_tv, hobject::PROP_FLAGS_WC);
    ctx.result.set_undefined();
}

// ============================================================================
// Error built-in registration
// ============================================================================

/// Helper: create a prototype object for an error type.
/// proto_parent is the [[Prototype]] (e.g. Error.prototype for subclasses).
/// The prototype is an ordinary object (ObjClass.OBJECT) per ES2015 §19.5.6.3 —
/// it must NOT be an Error instance itself.
fn HObject* register_error_prototype(Heap* heap, HObject* proto_parent, char[] name_str) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return null;
    HObject* proto = proto_raw;
    proto.prototype = proto_parent;

    // Set .name property
    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_hstr = builtin_intern_string(heap, name_str);
    TVal name_tv;
    name_tv.set_string(name_hstr);
    proto.put_prop(name_key, name_tv, hobject::PROP_FLAGS_WC);

    // Set .message property (empty string)
    HString* msg_key = (HString*)heap.strs[heap::BuiltinStr.MESSAGE];
    HString* msg_hstr = builtin_intern_string(heap, "");
    TVal msg_tv;
    msg_tv.set_string(msg_hstr);
    proto.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);

    return proto;
}

/// Register all Error constructors and prototypes.
fn bool register_error_builtins(EnvRecord* global_env, Heap* heap) {
    // --- Create Error.prototype ---
    HObject* err_proto = register_error_prototype(heap, null, "Error");
    if (err_proto == null) return false;
    heap.err_proto = err_proto;

    // Add .toString() method to Error.prototype
    HString* tostring_key = (HString*)heap.strs[heap::BuiltinStr.TO_STRING];
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)Builtin.ERROR_PROTO_TOSTRING.ordinal);
    err_proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // constructor_key used throughout — HObject ctors are wired by register_native_error_ctor below.
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];

    // --- Create TypeError.prototype ---
    HObject* type_err_proto = register_error_prototype(heap, err_proto, "TypeError");
    if (type_err_proto == null) return false;
    heap.type_err_proto = type_err_proto;

    // --- Create RangeError.prototype ---
    HObject* range_err_proto = register_error_prototype(heap, err_proto, "RangeError");
    if (range_err_proto == null) return false;
    heap.range_err_proto = range_err_proto;

    // --- Create ReferenceError.prototype ---
    HObject* ref_err_proto = register_error_prototype(heap, err_proto, "ReferenceError");
    if (ref_err_proto == null) return false;
    heap.ref_err_proto = ref_err_proto;

    // --- Create SyntaxError.prototype ---
    HObject* syntax_err_proto = register_error_prototype(heap, err_proto, "SyntaxError");
    if (syntax_err_proto == null) return false;
    heap.syntax_err_proto = syntax_err_proto;

    // --- Create EvalError.prototype ---
    HObject* eval_err_proto = register_error_prototype(heap, err_proto, "EvalError");
    if (eval_err_proto == null) return false;
    heap.eval_err_proto = eval_err_proto;

    // --- Create URIError.prototype ---
    HObject* uri_err_proto = register_error_prototype(heap, err_proto, "URIError");
    if (uri_err_proto == null) return false;
    heap.uri_err_proto = uri_err_proto;

    // --- Register Error global constructor as HObject (for static methods like captureStackTrace) ---
    HObject*? err_ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch e2 = err_ctor_raw) return false;
    HObject* err_ctor = err_ctor_raw;
    (*err_ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.ERROR.ordinal;

    // Wire Error.prototype.constructor → err_ctor
    {
        TVal ctor_tv;
        ctor_tv.set_object(err_ctor);
        err_proto.put_prop(constructor_key, ctor_tv, hobject::PROP_FLAGS_WC);
    }

    // Wire err_ctor["prototype"] → err_proto (non-writable, non-enumerable, non-configurable)
    {
        HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal proto_tv;
        proto_tv.set_object(err_proto);
        PropFlags proto_pflags;
        proto_pflags.writable = false;
        proto_pflags.enumerable = false;
        proto_pflags.configurable = false;
        proto_pflags.is_accessor = false;
        err_ctor.put_prop(prototype_key, proto_tv, proto_pflags);
    }

    // Register static method: Error.captureStackTrace
    {
        HString* capture_key = builtin_intern_string(heap, "captureStackTrace");
        TVal capture_tv;
        capture_tv.set_lightfunc((void*)(usz)Builtin.ERROR_CAPTURE_STACK_TRACE.ordinal);
        err_ctor.put_prop(capture_key, capture_tv, hobject::PROP_FLAGS_WC);
    }

    // Register Error in global environment
    {
        uint hash = heap.hash_string("Error");
        HString* existing = heap.str_table_lookup("Error", hash);
        HString* err_key;
        if (existing != null) {
            err_key = existing;
        } else {
            HString*? new_key = hstring::hstring_alloc(heap, "Error", hash);
            if (catch e3 = new_key) return false;
            heap.str_table_insert(new_key);
            err_key = new_key;
        }
        TVal err_val;
        err_val.set_object(err_ctor);
        set_func_ctor_name_length(err_ctor, heap, "Error", 1);
        env::env_declare_nonenum(global_env, err_key, err_val);
    }

    // --- Register NativeError constructors as proper HObjects ---
    // Per ES2015 §19.5.6.1: [[Prototype]] of each NativeError constructor is the Error constructor.
    // Each has an own "prototype" property (NWC) pointing to its prototype object.

    if (!register_native_error_ctor(global_env, heap, "TypeError",       Builtin.TYPE_ERROR.ordinal,       type_err_proto,   err_ctor)) return false;
    if (!register_native_error_ctor(global_env, heap, "RangeError",      Builtin.RANGE_ERROR.ordinal,      range_err_proto,  err_ctor)) return false;
    if (!register_native_error_ctor(global_env, heap, "ReferenceError",  Builtin.REFERENCE_ERROR.ordinal,  ref_err_proto,    err_ctor)) return false;
    if (!register_native_error_ctor(global_env, heap, "SyntaxError",     Builtin.SYNTAX_ERROR.ordinal,     syntax_err_proto, err_ctor)) return false;
    if (!register_native_error_ctor(global_env, heap, "EvalError",       Builtin.EVAL_ERROR.ordinal,       eval_err_proto,   err_ctor)) return false;
    if (!register_native_error_ctor(global_env, heap, "URIError",        Builtin.URI_ERROR.ordinal,        uri_err_proto,    err_ctor)) return false;

    // --- Create AggregateError.prototype (parent = err_proto) ---
    HObject* aggregate_err_proto = register_error_prototype(heap, err_proto, "AggregateError");
    if (aggregate_err_proto == null) return false;
    heap.aggregate_err_proto = aggregate_err_proto;

    if (!register_native_error_ctor(global_env, heap, "AggregateError", Builtin.AGGREGATE_ERROR.ordinal, aggregate_err_proto, err_ctor)) return false;

    return true;
}

/// Create and register a NativeError constructor as a real HObject.
/// Sets [[Prototype]] = err_ctor (Error constructor HObject) per §19.5.6.1,
/// wires own "prototype" property (NWC) to native_proto, and updates
/// native_proto.constructor to point at the new ctor HObject.
fn bool register_native_error_ctor(EnvRecord* global_env, Heap* heap, char[] name,
                                   uint fn_index, HObject* native_proto, HObject* err_ctor) {
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch e = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)fn_index;

    // [[Prototype]] = Error constructor (so getPrototypeOf(TypeError) === Error)
    ctor.prototype = err_ctor;

    // Own "prototype" property (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(native_proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Update native_proto.constructor → ctor HObject
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal ctor_tv;
    ctor_tv.set_object(ctor);
    native_proto.put_prop(constructor_key, ctor_tv, hobject::PROP_FLAGS_WC);

    // Set .name and .length on the constructor
    set_func_ctor_name_length(ctor, heap, name, 1);

    // Register in global environment
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    HString* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch e2 = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal val;
    val.set_object(ctor);
    env::env_declare_nonenum(global_env, key, val);
    return true;
}
