/// Function constructor and Function.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::bytecode;
import std::math;
import libc;
import duktape::hstring;
import duktape::env;

import duktape::heap;
import duktape::hobject;
import duktape::compiler;
import duktape::lexer;

// ============================================================================
// Function constructor (ES5 §15.3)
// ============================================================================

/// Function(p1, p2, ..., pn, body) — creates a new function dynamically.
/// Called as function or constructor, behavior is identical per ES5 §15.3.1.
fn void builtin_function(BuiltinContext* ctx) {
    // Collect the body string (last arg) and param names (preceding args).
    // Per ES5 §15.3.2.1:
    //   - 0 args  → body = ""
    //   - 1 arg   → body = ToString(arg[0])
    //   > 1 args  → last arg = body, preceding = param names

    char* body_str = "";
    usz body_len = 0;
    char[256] param_buf;  // accumulate param names joined by commas
    int param_pos = 0;

    if (ctx.argc == 0) {
        // Empty body, no params
        body_str = "";
        body_len = 0;
    } else {
        // Get the body from the last argument. Per ES5 §15.3.2.1 step 1,
        // call ToString(body); if ToString returns a non-string, the spec
        // throws TypeError, but the standard ToString table never produces
        // a non-string for primitive inputs we see here, so we can rely on
        // builtin_to_string and fall through with the literal "" if it
        // somehow returns null.
        TVal* body_arg = &ctx.regs[ctx.base_reg + (uint)(ctx.argc - 1)];
        if (body_arg.is_string() && body_arg.get_heapptr() != null) {
            HString* s = (HString*)body_arg.get_heapptr();
            body_str = s.get_cstr();
            body_len = s.blen;
        } else {
            // ToString on non-string arg (null, undefined, number, boolean, object).
            // ToString(null)="null", ToString(undefined)="undefined", etc.
            HString*? s_raw = builtin_to_string(ctx.heap, body_arg);
            if (try s = s_raw) {
                body_str = s.get_cstr();
                body_len = s.blen;
            } else {
                // Object with no clean toString — fall back to empty body
                body_str = "";
                body_len = 0;
            }
        }

        // Process parameter names from preceding args
        for (ushort i = 0; i < ctx.argc - 1; i++) {
            TVal* arg = &ctx.regs[ctx.base_reg + (uint)i];
            char* pname = "";
            usz plen = 0;
            if (arg.is_string() && arg.get_heapptr() != null) {
                HString* s = (HString*)arg.get_heapptr();
                pname = s.get_cstr();
                plen = s.blen;
            } else {
                // ToString on non-string arg (null, undefined, number, boolean)
                HString*? s_raw = builtin_to_string(ctx.heap, arg);
                if (try s = s_raw) {
                    pname = s.get_cstr();
                    plen = s.blen;
                } else {
                    // Skip non-coercible param
                    continue;
                }
            }

            // Add comma separator
            if (param_pos > 0 && param_pos < 255) {
                param_buf[param_pos++] = ',';
            }

            // Copy param name (up to buffer limit)
            for (usz j = 0; j < plen && param_pos < 255; j++) {
                param_buf[param_pos++] = pname[j];
            }
        }
    }

    param_buf[param_pos] = 0;

    // Build source string: "(p1,p2,...){ body }"
    // Use a generously-sized stack buffer
    char[16384] src_buf;
    int src_pos = 0;

    src_pos += libc::snprintf(&src_buf[src_pos], (usz)(16384 - src_pos), "(%s){", param_buf);
    // Copy body (up to remaining buffer space)
    for (usz i = 0; i < body_len && src_pos < 16380; i++) {
        src_buf[src_pos++] = body_str[i];
    }
    src_pos += libc::snprintf(&src_buf[src_pos], (usz)(16384 - src_pos), "}");

    // Lex and compile as a function expression
    Lexer lex = lexer::lexer_init(src_buf[:src_pos], ctx.heap);
    CompiledFunction*? cf = compiler::compile_function(&lex, ctx.heap, true);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
        // Compilation failed: throw SyntaxError
        builtin_throw_no_result_change(ctx, ctx.heap.syntax_err_proto, "SyntaxError in Function constructor");
        return;
    }

    // Create an HObject for the compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    (*func_obj.extra_ptr()).func.comp_func = func;
    (*func_obj.extra_ptr()).func.builtin_fn_index = -1;

    // Use the global environment (per ES5 §15.3.2.1 step 5)
    (*func_obj.extra_ptr()).func.var_env = ctx.global_env;
    (*func_obj.extra_ptr()).func.lex_env = ctx.global_env;

    // Set the function's .prototype property (standard for JS functions)
    // and its internal [[Prototype]] to Function.prototype
    func_obj.prototype = ctx.heap.function_proto;
    HObject*? proto_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (try proto = proto_raw) {
        HString* proto_key = builtin_intern_string(ctx.heap, "prototype");
        TVal proto_tv;
        proto_tv.set_object(proto);
        func_obj.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_WC);
    }

    // Set function length
    uint num_params = 0;
    if (ctx.argc > 0) num_params = (uint)(ctx.argc - 1);
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_tv;
    len_tv.set_fastint((long)num_params);
    func_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);

    // Return the function object
    ctx.result.set_object(func_obj);
}

// ============================================================================
// Function.prototype methods
// ============================================================================

/// Helper: get argument from the value stack by index (0-based within the call).
fn TVal builtin_arg(BuiltinContext* ctx, uint idx) {
    if (idx < ctx.argc) {
        return ctx.regs[ctx.base_reg + idx];
    }
    TVal undef;
    undef.set_undefined();
    return undef;
}

/// Function.prototype.call(thisArg, ...args)
///
/// Calls `this` (the downstream function) with `thisArg` as `this` and the
/// remaining arguments passed individually.
///
/// ES5 §15.3.4.4
fn void builtin_function_proto_call(BuiltinContext* ctx) {
    TVal downstream = ctx.this_val;

    // Validate downstream is callable
    bool callable = false;
    if (downstream.is_lightfunc()) {
        callable = true;
    } else if (downstream.is_object()) {
        HObject* hobj = (HObject*)downstream.get_heapptr();
        if (hobj != null) {
            callable = hobj.is_callable();
        }
    }

    if (!callable) {
        // Throw TypeError (ES5 §15.3.4.4 step 2)
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_call = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Function.prototype.call called on non-callable");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }

    // Determine new this value
    TVal new_this;
    if (ctx.argc > 0) {
        new_this = builtin_arg(ctx, 0);
    } else {
        new_this.set_undefined();
    }

    // Number of remaining args after thisArg
    ushort remaining = (ctx.argc > 0) ? (ushort)(ctx.argc - 1) : 0;

    // For LIGHTFUNC downstreams, dispatch directly after shifting args
    if (downstream.is_lightfunc()) {
        uint fn_idx = (uint)(usz)downstream.get_heapptr();
        builtins::BuiltinContext inner_ctx;
        inner_ctx.vm = ctx.vm;
        inner_ctx.regs = ctx.regs;
        inner_ctx.base_reg = ctx.base_reg;
        inner_ctx.argc = remaining;
        inner_ctx.result = ctx.result;
        inner_ctx.heap = ctx.heap;
        inner_ctx.this_val = new_this;
        inner_ctx.is_constructor = false;
        inner_ctx.needs_re_dispatch = false;
        inner_ctx.re_nargs = 0;
        inner_ctx.should_throw = false;
        // Update the this slot so builtins that read ctx.regs[ctx.base_reg - 1] get the correct receiver
        inner_ctx.regs[ctx.base_reg - 1] = new_this;
        // Shift remaining args to start at base_reg
        for (ushort i = 0; i < remaining; i++) {
            ctx.regs[ctx.base_reg + i] = builtin_arg(ctx, i + 1);
        }
        builtins::dispatch_builtin(fn_idx, &inner_ctx);
        if (inner_ctx.should_throw) {
            ctx.should_throw = true;
            ctx.throw_value = inner_ctx.throw_value;
        }
        return;
    }

    // For OBJECT downstreams — dispatch directly if BUILTIN_FN, else re-dispatch
    if (downstream.is_object()) {
        HObject* hobj = (HObject*)downstream.get_heapptr();
        if (hobj != null && hobj.is_callable() && hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN && (*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
            // Direct dispatch for BUILTIN_FN objects (e.g. Array.prototype.forEach.call(...))
            for (ushort i = 0; i < remaining; i++) {
                ctx.regs[ctx.base_reg + i] = builtin_arg(ctx, i + 1);
            }
            builtins::BuiltinContext inner_ctx;
            inner_ctx.vm = ctx.vm;
            inner_ctx.regs = ctx.regs;
            inner_ctx.base_reg = ctx.base_reg;
            inner_ctx.argc = remaining;
            inner_ctx.result = ctx.result;
            inner_ctx.heap = ctx.heap;
            inner_ctx.this_val = new_this;
            inner_ctx.is_constructor = false;
            inner_ctx.needs_re_dispatch = false;
            inner_ctx.re_nargs = 0;
            inner_ctx.global_env = ctx.global_env;
            inner_ctx.should_throw = false;
            inner_ctx.callee_obj = hobj;
            // Also set the this slot in registers for builtins that read ctx.regs[ctx.base_reg - 1]
            ctx.regs[ctx.base_reg - 1] = new_this;
            builtins::dispatch_builtin((uint)(*hobj.extra_ptr()).func.builtin_fn_index, &inner_ctx);
            if (inner_ctx.should_throw) {
                ctx.should_throw = true;
                ctx.throw_value = inner_ctx.throw_value;
            }
            return;
        }
        // Fallback: re-dispatch for compiled functions and bound functions
        ctx.regs[ctx.base_reg - 2] = downstream;
        ctx.regs[ctx.base_reg - 1] = new_this;
        for (ushort i = 0; i < remaining; i++) {
            ctx.regs[ctx.base_reg + i] = builtin_arg(ctx, i + 1);
        }
        ctx.needs_re_dispatch = true;
        ctx.re_nargs = remaining;
    } else {
        ctx.result.set_undefined();
    }
}

/// Function.prototype.apply(thisArg, argArray)
///
/// Calls `this` (the downstream function) with `thisArg` as `this` and the
/// elements of `argArray` passed as individual arguments.
///
/// ES5 §15.3.4.3
fn void builtin_function_proto_apply(BuiltinContext* ctx) {
    TVal downstream = ctx.this_val;

    // Validate downstream is callable (ES5 §15.3.4.3 step 2: throw TypeError)
    bool callable = false;
    if (downstream.is_lightfunc()) {
        callable = true;
    } else if (downstream.is_object()) {
        HObject* hobj = (HObject*)downstream.get_heapptr();
        if (hobj != null) {
            callable = hobj.is_callable();
        }
    }

    if (!callable) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_call = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Function.prototype.apply called on non-callable");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }

    // Get new this value
    TVal new_this;
    if (ctx.argc > 0) {
        new_this = builtin_arg(ctx, 0);
    } else {
        new_this.set_undefined();
    }

    // If argArray is undefined or null, call with no args
    TVal arg_array;
    bool has_array = ctx.argc > 1;
    if (has_array) {
        arg_array = builtin_arg(ctx, 1);
        if (arg_array.is_undefined() || arg_array.is_null()) {
            has_array = false;
        }
    }

    if (!has_array) {
        // Call with no args
        if (downstream.is_lightfunc()) {
            uint fn_idx = (uint)(usz)downstream.get_heapptr();
            builtins::BuiltinContext inner_ctx;
            inner_ctx.vm = ctx.vm;
            inner_ctx.regs = ctx.regs;
            inner_ctx.base_reg = ctx.base_reg;
            inner_ctx.argc = 0;
            inner_ctx.result = ctx.result;
            inner_ctx.heap = ctx.heap;
            inner_ctx.this_val = new_this;
            inner_ctx.is_constructor = false;
            inner_ctx.needs_re_dispatch = false;
            inner_ctx.re_nargs = 0;
            inner_ctx.should_throw = false;
            builtins::dispatch_builtin(fn_idx, &inner_ctx);
            if (inner_ctx.should_throw) {
                ctx.should_throw = true;
                ctx.throw_value = inner_ctx.throw_value;
            }
            return;
        }
        if (downstream.is_object()) {
            ctx.regs[ctx.base_reg - 2] = downstream;
            ctx.regs[ctx.base_reg - 1] = new_this;
            ctx.needs_re_dispatch = true;
            ctx.re_nargs = 0;
        } else {
            ctx.result.set_undefined();
        }
        return;
    }

    // argArray must be an object (array-like). Per ES5 §15.3.4.3 step 4
    // (CreateListFromArrayLike step 2): throw TypeError if Type(argArray) is not Object.
    if (!arg_array.is_object() || arg_array.get_heapptr() == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_arg = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "CreateListFromArrayLike called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }

    HObject* arr_obj = (HObject*)arg_array.get_heapptr();

    // Get length via property lookup (arrays store length as a named property)
    uint len = 0;
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    TVal? len_val = arr_obj.get_prop_proto(length_key);
    if (try lv = len_val) {
        if (lv.is_number() || lv.is_fastint()) {
            double d = lv.is_fastint() ? (double)lv.get_fastint() : lv.get_number();
            if (d < 0) d = 0;
            if (math::is_nan(d)) d = 0;
            if (d > 4294967295.0) d = 4294967295.0;
            len = (uint)d;
        }
    }

    // Extract elements from argArray — use heap allocation
    uint max_extract = len < 1024 ? len : 1024;
    uint actual_count = 0;
    TVal* extracted_args = null;
    if (max_extract > 0) {
        extracted_args = (TVal*)ctx.heap.alloc_func(ctx.heap.heap_udata, TVal::size * max_extract);
    }
    bool is_dense_array = (arr_obj.get_class() == hobject::ObjClass.ARRAY && arr_obj.array_part() != null);
    for (uint i = 0; i < max_extract; i++) {
        TVal elem;
        if (is_dense_array && i < arr_obj.array_size) {
            elem = arr_obj.array_part()[i];
            if (elem.is_undefined()) {
                char[20] buf;
                int n = libc::snprintf(&buf, 20, "%d", i);
                if (n <= 0 || n >= 20) break;
                HString* key_hstr = builtin_intern_string(ctx.heap, buf[:n]);
                TVal? prop = arr_obj.get_prop_proto(key_hstr);
                if (try p = prop) {
                    elem = p;
                }
            }
        } else {
            char[20] buf;
            int n = libc::snprintf(&buf, 20, "%d", i);
            if (n <= 0 || n >= 20) break;
            HString* key_hstr = builtin_intern_string(ctx.heap, buf[:n]);
            if (key_hstr == null) { break; }
            TVal? prop = arr_obj.get_prop_proto(key_hstr);
            if (try p = prop) {
                elem = p;
            } else {
                elem.set_undefined();
            }
        }
        if (actual_count < max_extract) extracted_args[actual_count++] = elem;
    }

    if (downstream.is_lightfunc()) {
        uint fn_idx = (uint)(usz)downstream.get_heapptr();
        builtins::BuiltinContext inner_ctx;
        inner_ctx.vm = ctx.vm;
        inner_ctx.regs = ctx.regs;
        inner_ctx.base_reg = ctx.base_reg;
        inner_ctx.argc = (ushort)actual_count;
        inner_ctx.result = ctx.result;
        inner_ctx.heap = ctx.heap;
        inner_ctx.this_val = new_this;
        inner_ctx.is_constructor = false;
        inner_ctx.needs_re_dispatch = false;
        inner_ctx.re_nargs = 0;
        inner_ctx.should_throw = false;

        // Write extracted args onto stack
        for (uint i = 0; i < actual_count; i++) {
            ctx.regs[ctx.base_reg + i] = extracted_args[i];
        }

        if (extracted_args != null) ctx.heap.free_func(ctx.heap.heap_udata, extracted_args);
        builtins::dispatch_builtin(fn_idx, &inner_ctx);
        if (inner_ctx.should_throw) {
            ctx.should_throw = true;
            ctx.throw_value = inner_ctx.throw_value;
        }
        return;
    }

    if (downstream.is_object()) {
        ctx.regs[ctx.base_reg - 2] = downstream;
        ctx.regs[ctx.base_reg - 1] = new_this;
        for (uint i = 0; i < actual_count; i++) {
            ctx.regs[ctx.base_reg + i] = extracted_args[i];
        }
        if (extracted_args != null) ctx.heap.free_func(ctx.heap.heap_udata, extracted_args);
        ctx.needs_re_dispatch = true;
        ctx.re_nargs = (ushort)actual_count;
    } else {
        if (extracted_args != null) ctx.heap.free_func(ctx.heap.heap_udata, extracted_args);
        ctx.result.set_undefined();
    }
}

/// Function.prototype.bind(thisArg, ...args)
///
/// Creates a new function that, when called, has its `this` bound to `thisArg`
/// and prepends any additional arguments.
///
/// ES5 §15.3.4.5
fn void builtin_function_proto_bind(BuiltinContext* ctx) {
    TVal downstream = ctx.this_val;

    // Validate downstream is callable (ES5 §15.3.4.5 step 2: throw TypeError)
    bool callable = false;
    if (downstream.is_lightfunc()) {
        callable = true;
    } else if (downstream.is_object()) {
        HObject* hobj = (HObject*)downstream.get_heapptr();
        if (hobj != null) {
            callable = hobj.is_callable();
        }
    }

    if (!callable) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_bind = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Function.prototype.bind called on non-callable");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }

    // Get bound this
    TVal bound_this;
    if (ctx.argc > 0) {
        bound_this = builtin_arg(ctx, 0);
    } else {
        bound_this.set_undefined();
    }

    // Collect bound args
    ushort bound_argc = (ctx.argc > 0) ? (ushort)(ctx.argc - 1) : 0;
    TVal* bound_args_arr = null;

    if (bound_argc > 0) {
        bound_args_arr = (TVal*)ctx.heap.alloc_func(ctx.heap.heap_udata, TVal::size * bound_argc);
        if (bound_args_arr == null) {
            ctx.result.set_undefined();
            return;
        }
        for (ushort i = 0; i < bound_argc; i++) {
            bound_args_arr[i] = builtin_arg(ctx, i + 1);
        }
    }

    // Create bound function object
    HObject*? bound_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = bound_raw) {
        if (bound_args_arr != null) ctx.heap.free_func(ctx.heap.heap_udata, bound_args_arr);
        ctx.result.set_undefined();
        return;
    }
    HObject* bound_obj = bound_raw;

    // Set up bound function properties
    bound_obj.flags.callable = true;
    bound_obj.flags.is_bound = true;
    bound_obj.prototype = ctx.heap.function_proto;
    (*bound_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_BOUND_CALL;

    // Also maintain constructable flag if downstream is constructable
    bool downstream_constructable = false;
    if (downstream.is_object()) {
        HObject* tobj = (HObject*)downstream.get_heapptr();
        if (tobj != null) downstream_constructable = tobj.flags.constructable;
    }
    // ES6 §19.2.1.3: BoundFunctionCreate produces a function exotic object
    // whose [[Construct]] internally invokes the target [[Construct]] — so
    // the bound function IS constructable iff the target is. (ES5 §15.3.4.5
    // had bound functions as non-constructable; ES6 changed this in 2015.)
    bound_obj.flags.constructable = downstream_constructable;

    // Store bound data as internal properties (non-enumerable, non-writable, non-configurable)
    // Key: use special strings "\x00bound_downstream", "\x00bound_this", "\x00bound_args"
    HString* key_downstream = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'a', 'r', 'g', 'e', 't' });
    HString* key_this   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'h', 'i', 's' });
    HString* key_args   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 'a', 'r', 'g', 's' });

    PropFlags internal_flags;
    internal_flags.writable = false;
    internal_flags.enumerable = false;
    internal_flags.configurable = false;
    internal_flags.is_accessor = false;

    bound_obj.put_prop(key_downstream, downstream, internal_flags);
    bound_obj.put_prop(key_this, bound_this, internal_flags);

    // Store bound args as a JS array
    HObject*? args_arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* args_arr = null;
    if (try a = args_arr_raw) {
        args_arr = a;
        args_arr.prototype = ctx.heap.array_proto;
        // Set length
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        TVal len_tv;
        len_tv.set_fastint(bound_argc);
        args_arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
        // Set elements
        for (ushort i = 0; i < bound_argc; i++) {
            char[20] buf;
            int n = libc::snprintf(&buf, 20, "%d", i);
            if (n > 0 && n < 20) {
                HString* elem_key = builtin_intern_string(ctx.heap, buf[:n]);
                args_arr.put_prop(elem_key, bound_args_arr[i], hobject::PROP_FLAGS_WEC);
            }
        }
    }

    if (bound_args_arr != null) ctx.heap.free_func(ctx.heap.heap_udata, bound_args_arr);

    TVal args_tv;
    if (args_arr != null) {
        args_tv.set_object(args_arr);
    } else {
        args_tv.set_undefined();
    }
    bound_obj.put_prop(key_args, args_tv, internal_flags);

    // ── Set .name: "bound " + targetName (ES6 §19.2.3.3) ──────────────
    HString* name_key = builtin_intern_string(ctx.heap, "name");
    char[128] name_buf;
    int name_pos = 0;
    // Copy "bound " prefix
    char[] prefix = "bound ";
    for (usz i = 0; i < prefix.len; i++) name_buf[name_pos++] = prefix[i];

    if (downstream.is_object()) {
        HObject* tobj = (HObject*)downstream.get_heapptr();
        if (tobj != null) {
            TVal? target_name_val = tobj.get_prop_proto(name_key);
            if (try tn = target_name_val) {
                if (tn.is_string() && tn.get_heapptr() != null) {
                    HString* tn_str = (HString*)tn.get_heapptr();
                    char* tn_data = tn_str.get_cstr();
                    uint tn_len = tn_str.blen;
                    for (usz i = 0; i < tn_len && name_pos < 126; i++) {
                        name_buf[name_pos++] = tn_data[i];
                    }
                }
                // Non-string targetName → use "" (nothing after "bound ")
            }
        }
    }
    HString* bound_name = builtin_intern_string(ctx.heap, name_buf[:name_pos]);
    if (bound_name != null) {
        TVal name_tv; name_tv.set_string(bound_name);
        bound_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }

    // ── Set .length (ES6 §19.2.3.3 SetFunctionLength) ────────────────
    int bound_len = 0;
    if (downstream.is_object()) {
        HObject* tobj = (HObject*)downstream.get_heapptr();
        if (tobj != null) {
            HString* tlen_key = builtin_intern_string(ctx.heap, "length");
            // HasOwnProperty: check own properties only
            int own_idx = tobj.find_prop_idx(tlen_key);
            if (own_idx >= 0) {
                TVal tlen_val = tobj.prop_values()[own_idx];
                if (tlen_val.is_number()) {
                    double target_len_d = tlen_val.get_number();
                    if (math::is_nan(target_len_d)) {
                        bound_len = 0;
                    } else if (target_len_d == 0.0) {
                        bound_len = 0;
                    } else if (target_len_d == double::inf) {
                        bound_len = 0x7FFFFFFF;
                    } else if (target_len_d == -double::inf) {
                        bound_len = 0;
                    } else {
                        int target_len_int = (int)math::trunc(target_len_d);
                        bound_len = target_len_int - (int)bound_argc;
                        if (bound_len < 0) bound_len = 0;
                    }
                } else if (tlen_val.is_fastint()) {
                    int target_len_int = (int)tlen_val.get_fastint();
                    bound_len = target_len_int - (int)bound_argc;
                    if (bound_len < 0) bound_len = 0;
                }
                // Non-number length → L = 0
            }
        }
    }

    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_tv;
    if (bound_len == 0x7FFFFFFF) {
        len_tv.set_number(double::inf);
    } else {
        len_tv.set_fastint((long)bound_len);
    }
    PropFlags len_flags;
    len_flags.writable = false;
    len_flags.enumerable = false;
    len_flags.configurable = true;
    len_flags.is_accessor = false;
    bound_obj.put_prop(len_key, len_tv, len_flags);

    // ── Prototype chain for `new` operator ─────────────────────────────
    if (downstream_constructable && downstream.is_object()) {
        HObject* tobj = (HObject*)downstream.get_heapptr();
        if (tobj != null) {
            TVal? proto_val = tobj.get_prop_proto(builtin_intern_string(ctx.heap, "prototype"));
            if (try pv = proto_val) {
                if (pv.is_object() && pv.get_heapptr() != null) {
                    HString* proto_key = builtin_intern_string(ctx.heap, "prototype");
                    bound_obj.put_prop(proto_key, pv, hobject::PROP_FLAGS_WEC);
                }
            }
        }
    }

    // Result
    ctx.result.set_object(bound_obj);
}

/// Function.prototype.toString()
///
/// Returns a string representation of the function.
/// ES2019 §19.2.3.5
fn void builtin_function_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    
    if (this_val.is_lightfunc()) {
        // Built-in function: "function name() { [native code] }"
        uint fn_idx = (uint)(usz)this_val.get_heapptr();
        BuiltinMeta meta = builtin_get_metadata(fn_idx);
        
        // Use the name from metadata, or "anonymous" if empty
        char[] name = meta.name;
        if (name.len == 0) {
            name = "anonymous";
        }
        
        // Build "function name() { [native code] }"
        char[256] buf;
        int len = libc::snprintf(&buf, 256, "function %s() { [native code] }", name.ptr);
        if (len > 0 && len < 256) {
            HString* result = builtin_intern_string(ctx.heap, buf[:len]);
            ctx.result.set_string(result);
        } else {
            ctx.result.set_undefined();
        }
    } else if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.is_callable()) {
            // For function objects, try to get the name from the function's .name property
            HString* name_key = builtin_intern_string(ctx.heap, "name");
            char* name_ptr = "anonymous";
            usz name_len = 9;
            
            TVal? name_val = obj.get_prop_proto(name_key);
            if (try nv = name_val) {
                if (nv.is_string() && nv.get_heapptr() != null) {
                    HString* name_str = (HString*)nv.get_heapptr();
                    name_ptr = name_str.get_cstr();
                    name_len = name_str.blen;
                }
            }
            
            // For compiled functions, check if we have source info
            // Currently return "function name() { [native code] }" as placeholder
            char[256] buf;
            // Build "function name() { [native code] }"
            buf[0] = 'f'; buf[1] = 'u'; buf[2] = 'n'; buf[3] = 'c'; buf[4] = 't'; buf[5] = 'i'; buf[6] = 'o'; buf[7] = 'n';
            buf[8] = ' ';
            int pos = 9;
            for (usz i = 0; i < name_len && pos < 250; i++) {
                buf[pos++] = name_ptr[i];
            }
            // Add "() { [native code] }"
            char[] suffix = "() { [native code] }";
            for (usz i = 0; i < suffix.len && pos < 255; i++) {
                buf[pos++] = suffix[i];
            }
            buf[pos] = 0;
            
            HString* result = builtin_intern_string(ctx.heap, buf[:pos]);
            ctx.result.set_string(result);
        } else {
            // TypeError
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err_tostr = err_raw) { ctx.result.set_undefined(); return; }
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            HString* msg_str = builtin_intern_string(ctx.heap, "Function.prototype.toString called on non-callable");
            if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
    } else {
        // TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_tostr = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Function.prototype.toString called on non-function");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
}

/// Function.prototype[@@species] getter — ES6 §19.2.4.7
/// Returns the this value.
fn void builtin_function_proto_species_getter(BuiltinContext* ctx) {
    *ctx.result = ctx.regs[ctx.base_reg - 1];
}

/// Bound function [[Call]] handler.
/// When a bound function is called, this handler unwraps the bound data,
/// prepends bound args to the call args, and re-dispatches.
fn void builtin_bound_call(BuiltinContext* ctx) {
    TVal func_val = ctx.regs[ctx.base_reg - 2];
    if (!func_val.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* bound_obj = (HObject*)func_val.get_heapptr();
    if (bound_obj == null || !bound_obj.flags.is_bound) {
        ctx.result.set_undefined();
        return;
    }

    // Extract bound data from internal properties
    HString* key_downstream = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'a', 'r', 'g', 'e', 't' });
    HString* key_this   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'h', 'i', 's' });
    HString* key_args   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 'a', 'r', 'g', 's' });

    TVal? downstream_val = bound_obj.get_prop_proto(key_downstream);
    TVal? this_val   = bound_obj.get_prop_proto(key_this);
    TVal? args_val   = bound_obj.get_prop_proto(key_args);

    TVal downstream;
    TVal bound_this;
    if (try tv = downstream_val) { downstream = tv; }
    else { ctx.result.set_undefined(); return; }
    if (try tv = this_val) { bound_this = tv; }
    else { bound_this.set_undefined(); }

    // Extract bound args array
    uint bound_argc = 0;
    if (try av = args_val) {
        if (av.is_object()) {
            HObject* arr = (HObject*)av.get_heapptr();
            if (arr != null && arr.get_class() == hobject::ObjClass.ARRAY) {
                HString* len_key = builtin_intern_string(ctx.heap, "length");
                TVal? lv = arr.get_prop_proto(len_key);
                if (try l = lv) {
                    if (l.is_fastint()) {
                        bound_argc = (uint)l.get_fastint();
                    } else if (l.is_number()) {
                        bound_argc = (uint)l.get_number();
                    }
                }
            }
        }
    }

    TVal* all_args = null;
    uint max_total = bound_argc + ctx.argc;
    if (max_total > 0) {
        all_args = (TVal*)ctx.heap.alloc_func(ctx.heap.heap_udata, TVal::size * max_total);
        if (all_args == null) { ctx.result.set_undefined(); return; }
    }
    defer if (all_args != null) ctx.heap.free_func(ctx.heap.heap_udata, all_args);
    uint actual_total = 0;

    // Copy bound args from stored array
    if (try av = args_val) {
        if (av.is_object()) {
            HObject* arr = (HObject*)av.get_heapptr();
            if (arr != null && arr.get_class() == hobject::ObjClass.ARRAY) {
                for (uint i = 0; i < bound_argc && actual_total < max_total; i++) {
                    char[20] buf;
                    int n = libc::snprintf(&buf, 20, "%d", i);
                    if (n > 0 && n < 20) {
                        HString* ek = builtin_intern_string(ctx.heap, buf[:n]);
                        TVal? e = arr.get_prop_proto(ek);
                        if (try ev = e) all_args[actual_total++] = ev;
                    }
                }
            }
        }
    }

    // Append call args
    uint total_argc = bound_argc + ctx.argc;
    for (uint i = 0; i < (uint)ctx.argc && bound_argc + i < 65535; i++) {
        all_args[bound_argc + i] = ctx.regs[ctx.base_reg + i];
    }

    // Determine if downstream is LIGHTFUNC or OBJECT
    if (downstream.is_lightfunc()) {
        uint fn_idx = (uint)(usz)downstream.get_heapptr();
        builtins::BuiltinContext inner_ctx;
        inner_ctx.vm = ctx.vm;
        inner_ctx.regs = ctx.regs;
        inner_ctx.base_reg = ctx.base_reg;
        inner_ctx.argc = (ushort)total_argc;
        inner_ctx.result = ctx.result;
        inner_ctx.heap = ctx.heap;
        inner_ctx.this_val = bound_this;
        inner_ctx.is_constructor = ctx.is_constructor;
        inner_ctx.needs_re_dispatch = false;
        inner_ctx.re_nargs = 0;
        inner_ctx.should_throw = false;

        for (uint i = 0; i < total_argc && i < 65535; i++) {
            ctx.regs[ctx.base_reg + i] = all_args[i];
        }
        builtins::dispatch_builtin(fn_idx, &inner_ctx);
        if (inner_ctx.should_throw) {
            ctx.should_throw = true;
            ctx.throw_value = inner_ctx.throw_value;
        }
        return;
    }

    if (downstream.is_object()) {
        HObject* tobj = (HObject*)downstream.get_heapptr();
        if (tobj != null && tobj.is_callable()) {
            // Handle nested bound functions directly (avoid needs_re_dispatch crash)
            if (tobj.callable_kind() == hobject::CallableKind.BOUND_FN) {
                int bfn_idx2 = (*tobj.extra_ptr()).func.builtin_fn_index;
                if (bfn_idx2 >= 0) {
                    // Place the inner bound function in the callee slot and dispatch
                    ctx.regs[ctx.base_reg - 2] = downstream;
                    ctx.regs[ctx.base_reg - 1] = bound_this;
                    for (uint i = 0; i < total_argc && i < 65535; i++) {
                        ctx.regs[ctx.base_reg + i] = all_args[i];
                    }
                    builtins::BuiltinContext inner;
                    inner.vm = ctx.vm;
                    inner.regs = ctx.regs;
                    inner.base_reg = ctx.base_reg;
                    inner.argc = (ushort)total_argc;
                    inner.result = ctx.result;
                    inner.heap = ctx.heap;
                    inner.this_val = bound_this;
                    inner.is_constructor = ctx.is_constructor;
                    inner.needs_re_dispatch = false;
                    inner.re_nargs = 0;
                    inner.global_env = ctx.global_env;
                    inner.should_throw = false;
                    inner.callee_obj = tobj;
                    builtins::dispatch_builtin((uint)bfn_idx2, &inner);
                    if (inner.should_throw) {
                        ctx.should_throw = true;
                        ctx.throw_value = inner.throw_value;
                    }
                    if (inner.needs_re_dispatch) {
                        ctx.needs_re_dispatch = true;
                        ctx.re_nargs = inner.re_nargs;
                    }
                    return;
                }
            }
            // Compiled function or BUILTIN_FN — use re-dispatch
            ctx.regs[ctx.base_reg - 2] = downstream;
            ctx.regs[ctx.base_reg - 1] = bound_this;
            for (uint i = 0; i < total_argc && i < 65535; i++) {
                ctx.regs[ctx.base_reg + i] = all_args[i];
            }
            ctx.needs_re_dispatch = true;
            ctx.re_nargs = (ushort)total_argc;
            return;
        }
    }

    ctx.result.set_undefined();
}

// ============================================================================
// Function constructor + Function.prototype registration
// ============================================================================

/// Create Function.prototype, register call/apply/bind, and register
/// the Function constructor globally.
fn bool register_function_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Function constructor as a proper function object FIRST
    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_FUNCTION;

    // Create Function.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype
    heap.function_proto = proto;

    // Add .call method
    HString* call_key = builtin_intern_string(heap, "call");
    TVal call_tv;
    call_tv.set_lightfunc((void*)(usz)BUILTIN_FUNCTION_PROTO_CALL);
    proto.put_prop(call_key, call_tv, hobject::PROP_FLAGS_WC);

    // Add .apply method
    HString* apply_key = builtin_intern_string(heap, "apply");
    TVal apply_tv;
    apply_tv.set_lightfunc((void*)(usz)BUILTIN_FUNCTION_PROTO_APPLY);
    proto.put_prop(apply_key, apply_tv, hobject::PROP_FLAGS_WC);

    // Add .bind method
    HString* bind_key = builtin_intern_string(heap, "bind");
    TVal bind_tv;
    bind_tv.set_lightfunc((void*)(usz)BUILTIN_FUNCTION_PROTO_BIND);
    proto.put_prop(bind_key, bind_tv, hobject::PROP_FLAGS_WC);

    // Add .toString method
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)BUILTIN_FUNCTION_PROTO_TOSTRING);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC);

    // Add @@species accessor (ES6 §19.2.4.7): getter returns this.
    HString* species_sym = ensure_species_symbol(heap);
    if (species_sym != null) {
        HObject*? getter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try getter = getter_raw) {
            getter.flags.callable = true;
            (*getter.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_FUNCTION_PROTO_SPECIES_GETTER;
            TVal getter_tv;
            getter_tv.set_object(getter);
            TVal undef;
            undef.set_undefined();
            hobject::PropFlags acc_flags;
            acc_flags.writable = false;
            acc_flags.enumerable = false;
            acc_flags.configurable = true;
            acc_flags.is_accessor = true;
            proto.put_prop(species_sym, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags);
        }
    }

    // Set .constructor to the Function constructor object itself
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(func_obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Function.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    func_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Function.length (ES5 §15.3.3)
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv;
    len_tv.set_fastint(1);
    func_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);

    // Register Function constructor globally as an OBJECT
    uint hash = heap.hash_string("Function");
    HString* existing = heap.str_table_lookup("Function", hash);
    HString* func_key;
    if (existing != null) {
        func_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Function", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        func_key = new_key;
    }
    TVal func_val;
    func_val.set_object(func_obj);
    set_func_ctor_name(func_obj, heap, "Function");
    env::env_declare_nonenum(global_env, func_key, func_val);

    return true;
}
