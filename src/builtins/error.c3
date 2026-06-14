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
fn void builtin_error_constructor_shared(BuiltinContext* ctx, HObject* proto) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err = err_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* err = err_raw;

    // Set .message if first arg is provided and not undefined
    if (ctx.argc > 0) {
        TVal* msg_arg = &ctx.regs[ctx.base_reg];
        if (!msg_arg.is_undefined()) {
            HString* msg_str = builtin_to_string(ctx.heap, msg_arg);
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
        }
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

    // Set .message if provided and not undefined
    if (!msg_val.is_undefined()) {
        HString* msg_str = builtin_to_string(ctx.heap, &msg_val);
        if (msg_str != null) {
            TVal msg_prop;
            msg_prop.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_prop, hobject::PROP_FLAGS_WC);
        }
    }

    // Set .errors array
    HString* errors_key = builtin_intern_string(ctx.heap, "errors");
    if (!errors_val.is_undefined()) {
        err.put_prop(errors_key, errors_val, hobject::PROP_FLAGS_WC);
    } else {
        HObject*? empty_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (try arr = empty_arr) {
            TVal arr_tv;
            arr_tv.set_object(arr);
            err.put_prop(errors_key, arr_tv, hobject::PROP_FLAGS_WC);
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

    // Default name is "Error"
    HString* name_str = builtin_intern_string(ctx.heap, "Error");
    HString* msg_str  = builtin_intern_string(ctx.heap, "");

    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();

        // Read .name property
        HString* name_key = builtin_intern_string(ctx.heap, "name");
        TVal? name_prop = obj.get_prop(name_key);
        if (try nv = name_prop) {
            if (!nv.is_undefined()) {
                HString* tmp = builtin_to_string(ctx.heap, &nv);
                if (tmp != null) name_str = tmp;
            }
        }

        // Read .message property
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        TVal? msg_prop = obj.get_prop(msg_key);
        if (try mv = msg_prop) {
            if (!mv.is_undefined()) {
                HString* tmp = builtin_to_string(ctx.heap, &mv);
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
// Error built-in registration
// ============================================================================

/// Helper: create a prototype object for an error type.
/// proto_parent is the [[Prototype]] (e.g. Error.prototype for subclasses).
fn HObject* register_error_prototype(Heap* heap, HObject* proto_parent, char[] name_str) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (catch err = proto_raw) return null;
    HObject* proto = proto_raw;

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
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_ERROR_PROTO_TOSTRING);
    err_proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add .constructor to Error.prototype pointing to Error builtin
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_lightfunc((void*)(usz)BUILTIN_ERROR);
    err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // --- Create TypeError.prototype ---
    HObject* type_err_proto = register_error_prototype(heap, err_proto, "TypeError");
    if (type_err_proto == null) return false;
    type_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.type_err_proto = type_err_proto;

    // --- Create RangeError.prototype ---
    HObject* range_err_proto = register_error_prototype(heap, err_proto, "RangeError");
    if (range_err_proto == null) return false;
    range_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.range_err_proto = range_err_proto;

    // --- Create ReferenceError.prototype ---
    HObject* ref_err_proto = register_error_prototype(heap, err_proto, "ReferenceError");
    if (ref_err_proto == null) return false;
    ref_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.ref_err_proto = ref_err_proto;

    // --- Create SyntaxError.prototype ---
    HObject* syntax_err_proto = register_error_prototype(heap, err_proto, "SyntaxError");
    if (syntax_err_proto == null) return false;
    syntax_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.syntax_err_proto = syntax_err_proto;

    // --- Create EvalError.prototype ---
    HObject* eval_err_proto = register_error_prototype(heap, err_proto, "EvalError");
    if (eval_err_proto == null) return false;
    eval_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.eval_err_proto = eval_err_proto;

    // --- Create URIError.prototype ---
    HObject* uri_err_proto = register_error_prototype(heap, err_proto, "URIError");
    if (uri_err_proto == null) return false;
    uri_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    heap.uri_err_proto = uri_err_proto;

    // Set .constructor on each error sub-prototype to point to its own builtin
    // (type_err_proto already done above — fix it now with correct index)
    TVal type_err_constr;
    type_err_constr.set_lightfunc((void*)(usz)BUILTIN_TYPE_ERROR);
    type_err_proto.put_prop(constructor_key, type_err_constr, hobject::PROP_FLAGS_WC);

    TVal range_err_constr;
    range_err_constr.set_lightfunc((void*)(usz)BUILTIN_RANGE_ERROR);
    range_err_proto.put_prop(constructor_key, range_err_constr, hobject::PROP_FLAGS_WC);

    TVal ref_err_constr;
    ref_err_constr.set_lightfunc((void*)(usz)BUILTIN_REFERENCE_ERROR);
    ref_err_proto.put_prop(constructor_key, ref_err_constr, hobject::PROP_FLAGS_WC);

    TVal syntax_err_constr;
    syntax_err_constr.set_lightfunc((void*)(usz)BUILTIN_SYNTAX_ERROR);
    syntax_err_proto.put_prop(constructor_key, syntax_err_constr, hobject::PROP_FLAGS_WC);

    TVal eval_err_constr;
    eval_err_constr.set_lightfunc((void*)(usz)BUILTIN_EVAL_ERROR);
    eval_err_proto.put_prop(constructor_key, eval_err_constr, hobject::PROP_FLAGS_WC);

    TVal uri_err_constr;
    uri_err_constr.set_lightfunc((void*)(usz)BUILTIN_URI_ERROR);
    uri_err_proto.put_prop(constructor_key, uri_err_constr, hobject::PROP_FLAGS_WC);

    // --- Register Error global constructor ---
    if (!register_simple_builtin(global_env, heap, "Error", BUILTIN_ERROR)) return false;

    // --- Register TypeError ---
    if (!register_simple_builtin(global_env, heap, "TypeError", BUILTIN_TYPE_ERROR)) return false;

    // --- Register RangeError ---
    if (!register_simple_builtin(global_env, heap, "RangeError", BUILTIN_RANGE_ERROR)) return false;

    // --- Register ReferenceError ---
    if (!register_simple_builtin(global_env, heap, "ReferenceError", BUILTIN_REFERENCE_ERROR)) return false;

    // --- Register SyntaxError ---
    if (!register_simple_builtin(global_env, heap, "SyntaxError", BUILTIN_SYNTAX_ERROR)) return false;

    // --- Register EvalError ---
    if (!register_simple_builtin(global_env, heap, "EvalError", BUILTIN_EVAL_ERROR)) return false;

    // --- Register URIError ---
    if (!register_simple_builtin(global_env, heap, "URIError", BUILTIN_URI_ERROR)) return false;

    // --- Create AggregateError.prototype (parent = err_proto) ---
    HObject* aggregate_err_proto = register_error_prototype(heap, err_proto, "AggregateError");
    if (aggregate_err_proto == null) return false;
    TVal aggregate_err_constr;
    aggregate_err_constr.set_lightfunc((void*)(usz)BUILTIN_AGGREGATE_ERROR);
    aggregate_err_proto.put_prop(constructor_key, aggregate_err_constr, hobject::PROP_FLAGS_WC);
    heap.aggregate_err_proto = aggregate_err_proto;

    if (!register_simple_builtin(global_env, heap, "AggregateError", BUILTIN_AGGREGATE_ERROR)) return false;

    return true;
}
