// Function constructor and Function.prototype methods.
module boomkat::builtins;
import boomkat::types;
import boomkat::bytecode;
import std::math;
import std::io;
import boomkat::hstring;
import boomkat::env;

import boomkat::heap;
import boomkat::hobject;
import boomkat::vm;
import boomkat::compiler;
import boomkat::lexer;

// ============================================================================
// Function constructor (ES5 §15.3)
// ============================================================================

// Function(p1, p2, ..., pn, body), creates a new function dynamically.
// Called as function or constructor, behavior is identical per ES5 §15.3.1.
fn void builtin_function(BuiltinContext* ctx) {
    // Per ES5 §15.3.1: Function() called as a plain function and `new Function()`
    // are identical, both create a fresh function object and the thisArg is
    // ignored. Nothing below reads ctx.this_val (the new function's var_env/
    // lex_env come unconditionally from the global env), so there is no thisArg
    // path to suppress; called-as-function vs. called-as-constructor need no
    // distinction here.

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
        // Per ES5 §15.3.2.1 step 1: ToString(param[0]), ToString(param[1]), ...,
        // ToString(body). Params must be ToString'd BEFORE body so a param
        // whose toString() throws is the exception that propagates (otherwise
        // body's toString could fire first and report a misleading error).
        // Process parameter names from preceding args FIRST.
        for (ushort i = 0; i < ctx.argc - 1; i++) {
            TVal* arg = &ctx.regs[ctx.base_reg + (uint)i];
            char* pname = "";
            usz plen = 0;
            if (arg.is_string() && arg.get_heapptr() != null) {
                HString* s = (HString*)arg.get_heapptr();
                pname = s.get_cstr();
                plen = s.blen;
            } else {
                // ToString(param) via the VM path so a throwing toString/valueOf
                // propagates rather than silently skipping the parameter.
                HString* s = builtin_to_string_vm(ctx, arg);
                if (ctx.should_throw) return;
                if (s != null) {
                    pname = s.get_cstr();
                    plen = s.blen;
                } else {
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

        // Now ToString the body (last argument). If ToString returns a
        // non-string, the spec throws TypeError, but the standard ToString
        // table never produces a non-string for primitive inputs we see here,
        // so we can rely on builtin_to_string and fall through with the
        // literal "" if it somehow returns null.
        TVal* body_arg = &ctx.regs[ctx.base_reg + (uint)(ctx.argc - 1)];
        if (body_arg.is_string() && body_arg.get_heapptr() != null) {
            HString* s = (HString*)body_arg.get_heapptr();
            body_str = s.get_cstr();
            body_len = s.blen;
        } else {
            // ToString(body), use the VM path so a JS toString()/valueOf() that
            // throws propagates the original exception (§20.2.1.1.1 step 8), not
            // a generic SyntaxError.
            HString* s = builtin_to_string_vm(ctx, body_arg);
            if (ctx.should_throw) return;
            if (s != null) {
                body_str = s.get_cstr();
                body_len = s.blen;
            } else {
                body_str = "";
                body_len = 0;
            }
        }
    }

    param_buf[param_pos] = 0;

    // Build source string for compilation.  The params string may contain
    // `//` line comments, so we must separate params from `)` with a newline
    // (per ES2019 §19.2.1.1.1 CreateDynamicFunction step 14).  We compile as
    // a function expression by wrapping in `(\n%params%\n) {\n%body%\n}`.
    // Use a generously-sized stack buffer
    char[16384] src_buf;
    int src_pos = 0;

    src_pos += (int)(io::bprintf(src_buf[src_pos..], "(%s\n){\n", (ZString)&param_buf) ?? src_buf[:0]).len;
    // A body that does not fit must be REJECTED, not silently truncated.
    // The copy below is bounds-checked, so it never overflowed — but cutting
    // the source mid-token produced a function that compiled and then failed
    // at call time with nonsense like "retu is not defined", or built cleanly
    // and returned undefined. Either way the failure surfaced far from its
    // cause, with nothing pointing at a length limit.
    if (body_len > (usz)(16377 - src_pos)) {
        builtin_throw_no_result_change(ctx, ctx.heap.syntax_err_proto,
            "Function constructor body too large");
        return;
    }
    for (usz i = 0; i < body_len && src_pos < 16377; i++) {
        src_buf[src_pos++] = body_str[i];
    }
    src_pos += (int)(io::bprintf(src_buf[src_pos..], "\n}") ?? src_buf[:0]).len;

    // Lex and compile as a function expression
    Lexer lex = lexer::lexer_init(src_buf[:src_pos], ctx.heap);
    defer lex.free_arena();
    CompiledFunction*? cf = compiler::compile_function(&lex, ctx.heap, true, true);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
        // Compilation failed: throw SyntaxError
        builtin_throw_no_result_change(ctx, ctx.heap.syntax_err_proto, "SyntaxError in Function constructor");
        return;
    }

    // Per ES2019 §19.2.1.1.1 CreateDynamicFunction, the source text retained for
    // Function.prototype.toString is "function anonymous(\n" + params + "\n) {\n" + body + "\n}".
    // Build this spec-formatted string and store it on the CompiledFunction.
    {
        char[16384] spec_buf;
        int spec_pos = 0;
        spec_pos += (int)(io::bprintf(spec_buf[spec_pos..], "function anonymous(%s\n) {\n", (ZString)&param_buf) ?? spec_buf[:0]).len;
        for (usz i = 0; i < body_len && spec_pos < 16378; i++) {
            spec_buf[spec_pos++] = body_str[i];
        }
        spec_pos += (int)(io::bprintf(spec_buf[spec_pos..], "\n}") ?? spec_buf[:0]).len;
        if (spec_pos > 0) {
            char* spec_heap = (char*)alloc::malloc_try(mem, (sz)((usz)spec_pos)) ?? null;
            if (spec_heap != null) {
                for (int i = 0; i < spec_pos; i++) spec_heap[i] = spec_buf[i];
                // Free any existing src_ptr (may have been set by compile_function)
                if (func.src_ptr != null) mem::free(func.src_ptr);
                func.src_ptr = spec_heap;
                func.src_len = (uint)spec_pos;
            }
        }
    }

    // Create an HObject for the compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    (*func_obj.extra_ptr()).func.comp_func = func;
    // -2 sentinel: marks engine-installed JS-defined built-ins (e.g.
    // Array.prototype.toLocaleString) as distinct from user-script functions
    // (which are -1). Function.prototype.toString uses this distinction to
    // return a NativeFunction-style string instead of the literal source
    // text, ES2019 §19.2.3.5 step 3 mandates that any function object
    // created by the engine return NativeFunction grammar.
    (*func_obj.extra_ptr()).func.builtin_fn_index = -2;

    // Use the global environment (per ES5 §15.3.2.1 step 5)
    (*func_obj.extra_ptr()).func.var_env = ctx.global_env;
    (*func_obj.extra_ptr()).func.lex_env = ctx.global_env;

    // Set the function's .prototype property (standard for JS functions)
    // and its internal [[Prototype]] to Function.prototype
    // ES2015 §9.2.2 [[Construct]] step 5/2.a: a base constructor used as super
    // must use OrdinaryCreateFromConstructor(newTarget, "%Function.prototype%"),
    // so `class Sub extends Function {}` produces a function whose [[Prototype]]
    // is Sub.prototype, not Function.prototype.
    func_obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.function_proto);
    HObject*? proto_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (try proto = proto_raw) {
        proto.prototype = ctx.heap.object_proto;
        // ES5 §13.2.2 step 17: .constructor is {writable:true, enumerable:false, configurable:true}
        HString* constr_key = ctx.heap.str(heap::BuiltinStr.CONSTRUCTOR);
        TVal constr_tv;
        constr_tv.set_object(func_obj);
        proto.put_prop(constr_key, constr_tv, hobject::PROP_FLAGS_WC, ctx.heap);

        HString* proto_key = ctx.heap.str(heap::BuiltinStr.PROTOTYPE);
        TVal proto_tv;
        proto_tv.set_object(proto);
        // ES5 §15.3.2.1 step 12: .prototype is {writable:true, enumerable:false, configurable:false}
        func_obj.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_WENC, ctx.heap);
    }
    func_obj.flags.callable = true;
    func_obj.flags.constructable = true;

    // Set function length from the compiled function's formal parameter count.
    // The compiler correctly counts comma-separated params (e.g. "a,b,c" → 3).
    HString* len_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
    TVal len_tv;
    len_tv.set_fastint((long)func.num_formals);
    func_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC, ctx.heap);

    // ES2019 §19.2.1.1.1 CreateDynamicFunction step 29: SetFunctionName(F, "anonymous").
    // {writable:false, enumerable:false, configurable:true}
    HString* name_key = ctx.heap.str(heap::BuiltinStr.NAME);
    TVal name_tv;
    name_tv.set_string(builtin_intern_string(ctx.heap, "anonymous"));
    func_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC, ctx.heap);

    // Return the function object
    ctx.result.set_object(func_obj);
}

// ============================================================================
// Function.prototype methods
// ============================================================================

// Helper: get argument from the value stack by index (0-based within the call).
fn TVal builtin_arg(BuiltinContext* ctx, uint idx) {
    if (idx < ctx.argc) {
        return ctx.regs[ctx.base_reg + idx];
    }
    TVal undef;
    undef.set_undefined();
    return undef;
}

// Store a heap-valued result into `*ctx.result`, taking a reference for it.
//
// `*ctx.result` does NOT hold an owned reference on entry: every call
// convention that reaches a builtin (both dispatch cases in vm_call_fn_impl,
// invoke_getter's builtin path, and the VM's own CALL_PROP handling) seeds the
// result slot with a RAW, non-incref'd copy of the callee or of `this`, since
// that slot doubles as the callee/`this` slot. `Heap.tval_copy_ref` would
// therefore decref bits the slot never owned, dropping a live reference on the
// callee itself -- for a builtin reachable as an intrinsic accessor (e.g.
// `get Error.prototype.stack`) that frees the intrinsic while the accessor
// cell still points at it, and the object pool then hands the same memory out
// as an unrelated closure.
//
// The correct convention, the one `set_object` and friends already follow, is
// to incref the incoming value and store its bits raw. Use this whenever the
// result is read out of a slot the builtin does not own (an argument register,
// an internal slot such as HObjectError.captured_stack, a property table
// entry). A value the builtin already owns -- notably a `Heap.call_fn` return,
// which is itself a raw copy out of the callee's result slot -- is stored with
// a plain `*ctx.result = v` instead, as array/core/proxy already do.
fn void builtin_store_result(BuiltinContext* ctx, TVal* src) {
    if (src.is_heap_allocated()) {
        void* ptr = src.get_heapptr();
        if (ptr != null) { ((types::HeapHeader*)ptr).incref(); }
    }
    *ctx.result = *src;
}

// Function.prototype.call(thisArg, ...args)
//
// Calls `this` (the downstream function) with `thisArg` as `this` and the
// remaining arguments passed individually.
//
// ES5 §15.3.4.4
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
        builtin_throw(ctx, ctx.heap.type_err_proto, "Function.prototype.call called on non-callable");
        return;
    }

    // Strict-only engine: thisArg is passed through unchanged (ES5 §15.3.4.4
    // entry 1 applies only to sloppy callees, no global substitution, no
    // primitive boxing; the callee's own ToObject coercion throws as needed).
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
        // Shift remaining args left by one (dropping thisArg), then clear the
        // now-duplicated tail slots. These registers all lie within the call
        // frame's decref window; a raw copy that left the tail intact would
        // leave a refcounted arg in two slots and decref_callee_regs at RET
        // would over-release it (double free of e.g. the callback function).
        for (ushort i = 0; i < remaining; i++) {
            ctx.regs[ctx.base_reg + i] = builtin_arg(ctx, i + 1);
        }
        for (ushort i = remaining; i < ctx.argc; i++) {
            ctx.regs[ctx.base_reg + i].set_undefined();
        }
        builtins::dispatch_builtin(fn_idx, &inner_ctx);
        if (inner_ctx.should_throw) {
            ctx.should_throw = true;
            ctx.throw_value = inner_ctx.throw_value;
        }
        return;
    }

    // For OBJECT downstreams, dispatch directly if BUILTIN_FN, else re-dispatch
    if (downstream.is_object()) {
        HObject* hobj = (HObject*)downstream.get_heapptr();
        if (hobj != null && hobj.is_callable() && hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN && (*hobj.extra_ptr()).func.builtin_fn_index >= 0) {
            // Direct dispatch for BUILTIN_FN objects (e.g. Array.prototype.forEach.call(...)).
            // Shift args left by one and clear the duplicated tail slots so the
            // frame's RET decref sees each refcounted arg exactly once.
            for (ushort i = 0; i < remaining; i++) {
                ctx.regs[ctx.base_reg + i] = builtin_arg(ctx, i + 1);
            }
            for (ushort i = remaining; i < ctx.argc; i++) {
                ctx.regs[ctx.base_reg + i].set_undefined();
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
        // Fallback: re-dispatch for compiled functions and bound functions.
        // Shift args left by one (dropping thisArg) and clear the now-duplicated
        // tail slots, same hazard as the branches above: base_reg+0 still holds
        // the raw copy of thisArg that new_this was read from, and it now lies
        // outside the re-dispatched call's argc window but still inside this
        // frame's own decref window, so an uncleared slot double-decrefs thisArg
        // (once via the this-slot the re-dispatched call tears down, once via
        // this frame's own RET) without a matching second incref.
        ctx.regs[ctx.base_reg - 2] = downstream;
        ctx.regs[ctx.base_reg - 1] = new_this;
        for (ushort i = 0; i < remaining; i++) {
            ctx.regs[ctx.base_reg + i] = builtin_arg(ctx, i + 1);
        }
        for (ushort i = remaining; i < ctx.argc; i++) {
            ctx.regs[ctx.base_reg + i].set_undefined();
        }
        ctx.needs_re_dispatch = true;
        ctx.re_nargs = remaining;
    } else {
        ctx.result.set_undefined();
    }
}

// Shared apply implementation for Function.prototype.apply and Reflect.apply.
// `target` must already be callable. `this_arg` and `arg_array` are the
// receiver and arguments-list values respectively.
fn void apply_call(BuiltinContext* ctx, TVal target, TVal this_arg, TVal arg_array) {
    // If argArray is undefined or null, call with no args.
    bool has_array = true;
    if (arg_array.is_undefined() || arg_array.is_null()) {
        has_array = false;
    }

    if (!has_array) {
        // Call with no args
        if (target.is_lightfunc()) {
            uint fn_idx = (uint)(usz)target.get_heapptr();
            builtins::BuiltinContext inner_ctx;
            inner_ctx.vm = ctx.vm;
            inner_ctx.regs = ctx.regs;
            inner_ctx.base_reg = ctx.base_reg;
            inner_ctx.argc = 0;
            inner_ctx.result = ctx.result;
            inner_ctx.heap = ctx.heap;
            inner_ctx.this_val = this_arg;
            inner_ctx.is_constructor = false;
            inner_ctx.needs_re_dispatch = false;
            inner_ctx.re_nargs = 0;
            inner_ctx.should_throw = false;
            // Lightfuncs read `this` from regs[base_reg - 1] just like builtins.
            // Stamp this_arg into that slot so the callee sees the correct receiver.
            ctx.regs[ctx.base_reg - 1] = this_arg;
            builtins::dispatch_builtin(fn_idx, &inner_ctx);
            if (inner_ctx.should_throw) {
                ctx.should_throw = true;
                ctx.throw_value = inner_ctx.throw_value;
            }
            return;
        }
        if (target.is_object()) {
            // Owned stores, for the reason spelled out in the argument-carrying
            // re-dispatch branch below.
            ctx.heap.tval_copy_ref(&ctx.regs[ctx.base_reg - 2], &target);
            ctx.heap.tval_copy_ref(&ctx.regs[ctx.base_reg - 1], &this_arg);
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
        builtin_throw(ctx, ctx.heap.type_err_proto, "CreateListFromArrayLike called on non-object");
        return;
    }

    HObject* arr_obj = (HObject*)arg_array.get_heapptr();

    // CreateListFromArrayLike step 3: Let len be ? ToLength(? Get(obj, "length")).
    // array_get_length_raw performs Get (invoking a length getter if present,
    // propagating any abrupt completion via ctx) and applies ToNumber; finish
    // the ToLength conversion (NaN/negative -> 0, clamp to a safe integer).
    double raw_len = array_get_length_raw(arr_obj, ctx.heap, ctx);
    if (ctx.should_throw) { return; }
    if (math::is_nan(raw_len) || raw_len < 0) raw_len = 0;
    if (raw_len > 4294967295.0) raw_len = 4294967295.0;
    uint len = (uint)raw_len;

    // The dispatch plumbing carries argc as ushort, so that is the hard limit
    // on how many arguments a single call can receive.
    if (len > 65535) {
        builtin_throw(ctx, ctx.heap.range_err_proto, "Function.prototype.apply: too many arguments");
        return;
    }

    // CreateListFromArrayLike steps 4-6: for each index 0..len-1, let indexName
    // be ! ToString(index), then next be ? Get(obj, indexName), invoking any
    // accessor getter and propagating an abrupt completion immediately.
    uint max_extract = len;
    uint actual_count = 0;
    TVal* extracted_args = null;
    if (max_extract > 0) {
        extracted_args = (TVal*)ctx.heap.alloc_func(ctx.heap.heap_udata, TVal::size * max_extract);
    }

    // Fast path for plain Arrays: check the dense array part directly without
    // interning the numeric key string.  This avoids 10000 intern lookups per
    // apply(fn, largeArray) call, which would otherwise be O(n²) over many
    // calls due to GC safepoint work growing with the intern table.
    bool is_plain_array = arr_obj.get_class() == hobject::ObjClass.ARRAY
                          && arr_obj.array_part() != null
                          && arr_obj.prop_count <= 1;  // ≤1 own named prop (just "length")

    // TypedArray arg-array: indexed elements live in the backing buffer, not
    // the named-property table. Read them via the TA-aware element getter so
    // apply(fn, typedArray) spreads the real values (and honours a resizable
    // buffer's current bounds) instead of undefined.
    bool is_typed_array_src = is_typed_array_class(arr_obj.get_class());

    for (uint i = 0; i < max_extract; i++) {
        TVal elem;

        if (is_typed_array_src) {
            if (!arr_get_elem_vm(arr_obj, (ulong)i, ctx.heap, ctx, &elem)) {
                if (ctx.should_throw) {
                    if (extracted_args != null) ctx.heap.free_func(ctx.heap.heap_udata, extracted_args);
                    return;
                }
                elem.set_undefined();
            }
            if (actual_count < max_extract) extracted_args[actual_count++] = elem;
            continue;
        }

        // Fast path: dense ARRAY with no accessor overrides (most common case).
        if (is_plain_array && i < arr_obj.array_size) {
            TVal dv = arr_obj.array_part()[i];
            if (!dv.is_undefined()) {
                if (actual_count < max_extract) extracted_args[actual_count++] = dv;
                continue;
            }
            // Slot is undefined, could be a hole; fall through to proto lookup.
        }

        char[20] buf;
        int n = (int)(io::bprintf(&buf, "%d", i) ?? buf[:0]).len;
        if (n <= 0 || n >= 20) break;
        HString* key_hstr = builtin_intern_string(ctx.heap, buf[:n]);
        if (key_hstr == null) { break; }

        // Own accessor property at this index takes precedence over any
        // dense array storage (mirrors arr_get_elem's ordering).
        int own_idx = arr_obj.find_prop_idx(key_hstr, ctx.heap);
        if (own_idx >= 0 && arr_obj.get_prop_flags((uint)own_idx, ctx.heap).is_accessor) {
            TVal gs_slot = arr_obj.prop_values()[own_idx];
            TVal getter_fn = hobject::hobject_access_getter(gs_slot);
            elem = arr_invoke_getter_ctx(arr_obj, getter_fn, ctx.heap, ctx);
            if (ctx.should_throw) {
                if (extracted_args != null) ctx.heap.free_func(ctx.heap.heap_udata, extracted_args);
                return;
            }
        } else if (own_idx >= 0) {
            elem = arr_obj.prop_values()[own_idx];
        } else if (!is_plain_array && arr_obj.get_class() == hobject::ObjClass.ARRAY && arr_obj.array_part() != null
                   && i < arr_obj.array_size && !arr_obj.array_part()[i].is_undefined()) {
            elem = arr_obj.array_part()[i];
        } else {
            hobject::PropLookupResult res = arr_obj.get_prop_or_accessor_proto(key_hstr, true, ctx.heap);
            if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                elem = arr_invoke_getter_ctx(arr_obj, res.acc.accessor_fn, ctx.heap, ctx);
                if (ctx.should_throw) {
                    if (extracted_args != null) ctx.heap.free_func(ctx.heap.heap_udata, extracted_args);
                    return;
                }
            } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                elem = res.data_val;
            } else {
                elem.set_undefined();
            }
        }
        if (actual_count < max_extract) extracted_args[actual_count++] = elem;
    }

    // Grow the valstack so the arg writes at base_reg..base_reg+count land in
    // allocated, GC-visible memory (the caller's frame is usually far smaller
    // than an arbitrary array-like). ctx.regs / ctx.result are raw pointers
    // into the valstack, re-derive them if the realloc moved it.
    {
        Vm* vm = (Vm*)ctx.vm;
        TVal* old_vs = vm.valstack;
        if (!vm::ensure_valstack(vm, (uint)ctx.base_reg + actual_count + 8)) {
            if (extracted_args != null) ctx.heap.free_func(ctx.heap.heap_udata, extracted_args);
            ctx.result.set_undefined();
            return;
        }
        if (vm.valstack != old_vs) {
            ctx.result = vm.valstack + (ctx.result - old_vs);
            ctx.regs = vm.valstack;
        }
        TVal* extended_top = vm.valstack + ctx.base_reg + actual_count + 8;
        if (extended_top > vm.valstack_top) { vm.valstack_top = extended_top; }
    }

    if (target.is_lightfunc()) {
        uint fn_idx = (uint)(usz)target.get_heapptr();
        builtins::BuiltinContext inner_ctx;
        inner_ctx.vm = ctx.vm;
        inner_ctx.regs = ctx.regs;
        inner_ctx.base_reg = ctx.base_reg;
        inner_ctx.argc = (ushort)actual_count;
        inner_ctx.result = ctx.result;
        inner_ctx.heap = ctx.heap;
        inner_ctx.this_val = this_arg;
        inner_ctx.is_constructor = false;
        inner_ctx.needs_re_dispatch = false;
        inner_ctx.re_nargs = 0;
        inner_ctx.should_throw = false;

        // Write extracted args onto stack.
        // Also stamp this_arg into regs[base_reg - 1] so lightfunc callees
        // that read their receiver from that slot see the correct value.
        ctx.regs[ctx.base_reg - 1] = this_arg;
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

    if (target.is_object()) {
        // The callee, this and argument slots all lie inside the calling frame's
        // decref window, so every value written here has to arrive owned: the
        // frame releases each of these slots when it overwrites them or unwinds.
        // target and this_arg are copies of registers that keep their own
        // reference, and the extracted args were read out of the array via a
        // property get (no incref), so a raw store would hand the frame a
        // reference nobody took and drain the value one count per call. That
        // showed up as a receiver or callee freed and recycled after three
        // Reflect.apply / Function.prototype.apply calls on the same values.
        ctx.heap.tval_copy_ref(&ctx.regs[ctx.base_reg - 2], &target);
        ctx.heap.tval_copy_ref(&ctx.regs[ctx.base_reg - 1], &this_arg);
        for (uint i = 0; i < actual_count; i++) {
            ctx.heap.tval_copy_ref(&ctx.regs[ctx.base_reg + i], &extracted_args[i]);
        }
        if (extracted_args != null) ctx.heap.free_func(ctx.heap.heap_udata, extracted_args);
        ctx.needs_re_dispatch = true;
        ctx.re_nargs = (ushort)actual_count;
    } else {
        if (extracted_args != null) ctx.heap.free_func(ctx.heap.heap_udata, extracted_args);
        ctx.result.set_undefined();
    }
}

// Function.prototype.apply(thisArg, argArray)
//
// Calls `this` (the downstream function) with `thisArg` as `this` and the
// elements of `argArray` passed as individual arguments.
//
// ES5 §15.3.4.3
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
        builtin_throw(ctx, ctx.heap.type_err_proto, "Function.prototype.apply called on non-callable");
        return;
    }

    // Get new this value, with ToObject boxing for primitives.
    // ES5 §15.3.4.3 step 1: let thisArg be ToObject(thisArg).
    // undefined/null → global object; primitives → wrapper object.
    // Strict-only engine: thisArg passes through unchanged (see call above).
    TVal new_this;
    if (ctx.argc > 0) {
        new_this = builtin_arg(ctx, 0);
    } else {
        new_this.set_undefined();
    }

    // If argArray is undefined or null, call with no args
    TVal arg_array;
    if (ctx.argc > 1) {
        arg_array = builtin_arg(ctx, 1);
    } else {
        arg_array.set_undefined();
    }

    apply_call(ctx, downstream, new_this, arg_array);
}

// Function.prototype.bind(thisArg, ...args)
//
// Creates a new function that, when called, has its `this` bound to `thisArg`
// and prepends any additional arguments.
//
// ES5 §15.3.4.5
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
        builtin_throw(ctx, ctx.heap.type_err_proto, "Function.prototype.bind called on non-callable");
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
    bound_obj.prototype = ctx.heap.function_proto;
    (*bound_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.BOUND_CALL.ordinal;

    // Also maintain constructable flag if downstream is constructable
    bool downstream_constructable = false;
    if (downstream.is_object()) {
        HObject* tobj = (HObject*)downstream.get_heapptr();
        if (tobj != null) downstream_constructable = tobj.flags.constructable;
    }
    // ES6 §19.2.1.3: BoundFunctionCreate produces a function exotic object
    // whose [[Construct]] internally invokes the target [[Construct]], so
    // the bound function IS constructable iff the target is. (ES5 §15.3.4.5
    // had bound functions as non-constructable; ES6 changed this in 2015.)
    bound_obj.flags.constructable = downstream_constructable;

    // Store [[BoundTargetFunction]]/[[BoundThis]] directly on the object
    // (not as property-table entries, see HObjectFunction.bound_target in
    // hobject.c3) and only THEN flip is_bound, so a GC triggered by the
    // args-array allocation below never observes a bound object with an
    // unpopulated bound_target/bound_this (zero bits, not a valid TVal).
    ctx.heap.tval_copy_ref(&(*bound_obj.extra_ptr()).func.bound_target, &downstream);
    ctx.heap.tval_copy_ref(&(*bound_obj.extra_ptr()).func.bound_this, &bound_this);
    bound_obj.flags.is_bound = true;

    // Store bound args as a JS array
    HObject*? args_arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* args_arr = null;
    if (try a = args_arr_raw) {
        args_arr = a;
        args_arr.prototype = ctx.heap.array_proto;
        // Set length
        HString* len_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
        TVal len_tv;
        len_tv.set_fastint(bound_argc);
        args_arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC, ctx.heap);
        // Set elements
        for (ushort i = 0; i < bound_argc; i++) {
            char[20] buf;
            int n = (int)(io::bprintf(&buf, "%d", i) ?? buf[:0]).len;
            if (n > 0 && n < 20) {
                HString* elem_key = builtin_intern_string(ctx.heap, buf[:n]);
                args_arr.put_prop(elem_key, bound_args_arr[i], hobject::PROP_FLAGS_WEC, ctx.heap);
            }
        }
    }

    if (bound_args_arr != null) ctx.heap.free_func(ctx.heap.heap_udata, bound_args_arr);

    if (args_arr != null) {
        ((types::HeapHeader*)args_arr).incref();
        (*bound_obj.extra_ptr()).func.bound_args = args_arr;
    } else {
        (*bound_obj.extra_ptr()).func.bound_args = null;
    }

    // Set .length (ES6 §19.2.3.3 SetFunctionLength).
    // Ordering: BoundFunctionCreate's caller (Function.prototype.bind, ES2022
    // §20.2.3.2) computes and sets L (step 5) before it ever reads targetName
    // (step 6), so "length" must land as an own property before "name",
    // matching creation-order-sensitive consumers like
    // Object.getOwnPropertyNames.
    // Use double throughout so values up to Number.MAX_SAFE_INTEGER (2^53-1)
    // and +Infinity are preserved exactly (spec: ToIntegerOrInfinity then
    // max(0, targetLen - boundArgc)).
    double bound_len_d = 0.0;
    if (downstream.is_object()) {
        HObject* tobj = (HObject*)downstream.get_heapptr();
        if (tobj != null) {
            HString* tlen_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
            // HasOwnProperty: check own properties only
            int own_idx = tobj.find_prop_idx(tlen_key, ctx.heap);
            if (own_idx >= 0) {
                TVal tlen_val = tobj.prop_values()[own_idx];
                double target_len_d = 0.0;
                bool has_numeric = false;
                if (tlen_val.is_number()) {
                    target_len_d = tlen_val.get_number();
                    has_numeric = true;
                } else if (tlen_val.is_fastint()) {
                    target_len_d = (double)tlen_val.get_fastint();
                    has_numeric = true;
                }
                if (has_numeric) {
                    // ToIntegerOrInfinity: NaN → 0, -Inf → 0, +Inf stays
                    if (math::is_nan(target_len_d) || target_len_d == -double::inf) {
                        target_len_d = 0.0;
                    } else if (target_len_d != double::inf) {
                        target_len_d = math::trunc(target_len_d);
                    }
                    // L = max(0, targetLen - boundArgc)
                    if (target_len_d == double::inf) {
                        bound_len_d = double::inf;
                    } else {
                        bound_len_d = target_len_d - (double)bound_argc;
                        if (bound_len_d < 0.0) bound_len_d = 0.0;
                    }
                }
                // Non-number length → L = 0
            }
        }
    }

    HString* len_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
    TVal len_tv;
    // Store as fastint when the value fits (0..2^31-2), otherwise as double.
    // This matches how native function length properties are set elsewhere.
    if (bound_len_d == double::inf || bound_len_d > (double)0x7FFFFFFE) {
        len_tv.set_number(bound_len_d);
    } else {
        len_tv.set_fastint((long)bound_len_d);
    }
    PropFlags len_flags;
    len_flags.writable = false;
    len_flags.enumerable = false;
    len_flags.configurable = true;
    len_flags.is_accessor = false;
    bound_obj.put_prop(len_key, len_tv, len_flags, ctx.heap);

    // Set .name: "bound " + targetName (ES6 §19.2.3.3).
    // Per spec: Get(target, "name"), must invoke accessor getters and
    // propagate any abrupt completion (throw) before creating the bound fn.
    HString* name_key = ctx.heap.str(heap::BuiltinStr.NAME);
    char[128] name_buf;
    int name_pos = 0;
    // Copy "bound " prefix
    char[] prefix = "bound ";
    for (usz i = 0; i < prefix.len; i++) name_buf[name_pos++] = prefix[i];

    if (downstream.is_object()) {
        HObject* tobj = (HObject*)downstream.get_heapptr();
        if (tobj != null) {
            // Use full Get semantics: invokes getter, propagates throw.
            TVal? target_name_val = builtins_generic_get(tobj, name_key, ctx);
            if (ctx.should_throw) {
                // Getter threw, propagate. bound_args_arr already freed above.
                return;
            }
            if (try tn = target_name_val) {
                if (tn.is_string() && tn.get_heapptr() != null) {
                    HString* tn_str = (HString*)tn.get_heapptr();
                    // Symbols are stored as HString with is_symbol flag;
                    // per spec Type(targetName) must be String (not Symbol).
                    if (!tn_str.is_symbol()) {
                        char* tn_data = tn_str.get_cstr();
                        uint tn_len = tn_str.blen;
                        for (usz i = 0; i < tn_len && name_pos < 126; i++) {
                            name_buf[name_pos++] = tn_data[i];
                        }
                    }
                }
                // Non-string targetName (or Symbol) → use "" (nothing after "bound ")
            }
        }
    }
    HString* bound_name = builtin_intern_string(ctx.heap, name_buf[:name_pos]);
    if (bound_name != null) {
        TVal name_tv; name_tv.set_string(bound_name);
        bound_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC, ctx.heap);
    }

    // Bound function exotic objects have no own "prototype" property
    // (ES2015 §19.2.3.2 BoundFunctionCreate step 4 only sets length/name).
    // [[Construct]] forwards to the bound target, which resolves its own
    // .prototype at construct time via the re-dispatch path below.

    // Result
    ctx.result.set_object(bound_obj);
}

// Function.prototype.toString()
//
// Returns a string representation of the function.
// ES2019 §19.2.3.5
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
        int len = (int)(io::bprintf(&buf, "function %s() { [native code] }", (String)name) ?? buf[:0]).len;
        if (len > 0 && len < 256) {
            HString* result = builtin_intern_string(ctx.heap, buf[:len]);
            ctx.result.set_string(result);
        } else {
            ctx.result.set_undefined();
        }
    } else if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.is_callable()) {
            // ES2019 §19.2.3.5: callable Proxy objects have no source text,
            // return a NativeFunction-style string without touching the proxy's
            // internal slots (which hold proxy data, not function data).
            if (obj.flags.exotic_proxyobj) {
                HString* result = builtin_intern_string(ctx.heap, "function () { [native code] }");
                ctx.result.set_string(result);
                return;
            }

            // Compiled JS functions retain their original source text (ES2019
            // §19.2.3.5 / Function.prototype.toString), if the compiler kept it,
            // return that exact text instead of the [native code] placeholder.
            // A callable with a non-null comp_func and `builtin_fn_index == -1`
            // identifies a user-script (compiled) function; `== -2` is the
            // sentinel used by register_compiled_proto_method for engine-installed
            // built-ins (e.g. Array.prototype.toLocaleString) that are JS-defined
            // but NOT user-script, they must return a NativeFunction string
            // per spec, so we fall through to the .name branch below.
            CompiledFunction* cf = null;
            if ((*obj.extra_ptr()).func.comp_func != null
                    && (*obj.extra_ptr()).func.builtin_fn_index == -1) {
                cf = (*obj.extra_ptr()).func.comp_func;
            }
            if (cf != null && cf.src_ptr != null && cf.src_len > 0) {
                HString* result = builtin_intern_string(ctx.heap, cf.src_ptr[:cf.src_len]);
                ctx.result.set_string(result);
                return;
            }

            // For function objects, try to get the name from the function's .name property
            HString* name_key = ctx.heap.str(heap::BuiltinStr.NAME);
            char* name_ptr = "anonymous";
            usz name_len = 9;

            TVal? name_val = obj.get_prop_proto(name_key, ctx.heap);
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
            builtin_throw(ctx, ctx.heap.type_err_proto, "Function.prototype.toString called on non-callable");
        }
    } else {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Function.prototype.toString called on non-function");
    }
}

// Function.prototype[Symbol.hasInstance](V), ES6 §19.2.3.6
// Implements OrdinaryHasInstance(this, V): returns true iff V is an object
// whose prototype chain contains this.prototype. `this` (the constructor C)
// must be callable; if C is a bound function, its [[BoundTargetFunction]] is
// used instead. Non-callable `this` or non-object V → false (no throw for V).
fn void builtin_function_proto_hasInstance(BuiltinContext* ctx) {
    TVal c_val = ctx.regs[ctx.base_reg - 1];  // this = constructor C

    // ES6 §7.3.19 step 1: If IsCallable(C) is false, return false.
    bool callable = false;
    if (c_val.is_lightfunc()) {
        callable = true;
    } else if (c_val.is_object() && c_val.get_heapptr() != null) {
        callable = ((HObject*)c_val.get_heapptr()).is_callable();
    }
    if (!callable) { ctx.result.set_boolean(false); return; }

    // Step 2: If C has a [[BoundTargetFunction]] slot, recurse on the target.
    if (c_val.is_object() && c_val.get_heapptr() != null) {
        HObject* c_obj = (HObject*)c_val.get_heapptr();
        if (c_obj.flags.is_bound) {
            c_val = (*c_obj.extra_ptr()).func.bound_target;
        }
    }

    // Step 3: If Type(V) is not Object, return false.
    TVal v_val = (ctx.argc > 0) ? builtin_arg(ctx, 0) : (TVal){};
    if (ctx.argc == 0 || !v_val.is_object() || v_val.get_heapptr() == null) {
        ctx.result.set_boolean(false);
        return;
    }

    // Step 4: Let P be Get(C, "prototype"). Invoke a getter if present so a
    // poisoned/throwing prototype accessor propagates the abrupt completion.
    HString* proto_key = (HString*)ctx.heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_val;
    if (c_val.is_object() && c_val.get_heapptr() != null) {
        HObject* c_obj = (HObject*)c_val.get_heapptr();
        hobject::AccessorResult acc = c_obj.find_accessor_proto(proto_key, true, ctx.heap);
        if (acc.found) {
            if (ctx.heap.call_fn == null || ctx.vm == null) { ctx.result.set_boolean(false); return; }
            TVal this_for_getter; this_for_getter.set_object(c_obj);
            proto_val = ctx.heap.call_fn(ctx.vm, acc.accessor_fn, null, 0, this_for_getter);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return;
            }
        } else {
            TVal? pv = c_obj.get_prop_proto(proto_key, ctx.heap);
            if (try p = pv) { proto_val = p; } else { proto_val.set_undefined(); }
        }
    } else if (c_val.is_lightfunc()) {
        // LIGHTFUNC constructors expose their prototype via lightfunc metadata;
        // ordinary builtins used as C here are rare, fall through to TypeError.
        proto_val.set_undefined();
    }

    // Step 5: If Type(P) is not Object, throw a TypeError.
    if (!proto_val.is_object() || proto_val.get_heapptr() == null) {
        arr_throw_type_error(ctx, "Function has non-object prototype in instanceof check");
        return;
    }

    // Step 6: walk V's prototype chain looking for P, routing hops through
    // the [[GetPrototypeOf]] trap when a Proxy appears on the chain.
    HObject* p_obj = (HObject*)proto_val.get_heapptr();
    HObject* v_obj = (HObject*)v_val.get_heapptr();
    uint wdepth = 0;
    bool matched = false;
    while (v_obj != null && wdepth < 256) {
        if (v_obj == p_obj) { matched = true; break; }
        if (v_obj.flags.exotic_proxyobj) {
            TVal next;
            if (!proxy_mop_get_proto(ctx.vm, ctx.heap, v_obj, &next)) { proxy_ctx_ok(ctx); return; }
            v_obj = next.is_object() ? (HObject*)next.get_heapptr() : null;
        } else {
            v_obj = v_obj.prototype;
        }
        wdepth++;
    }
    ctx.result.set_boolean(matched);
}

// Restricted function property getter, throws TypeError on access. Used as
// the [[Get]] accessor for `Function.prototype.caller` and
// `Function.prototype.arguments` (ES2017 §9.2.7 AddRestrictedFunctionProperties).
fn void builtin_function_proto_restricted_getter(BuiltinContext* ctx) {
    builtin_throw(ctx, ctx.heap.type_err_proto,
        "'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
}

// Restricted function property setter, throws TypeError on assignment. Used as
// the [[Set]] accessor for `Function.prototype.caller` and
// `Function.prototype.arguments` (ES2017 §9.2.7 AddRestrictedFunctionProperties).
fn void builtin_function_proto_restricted_setter(BuiltinContext* ctx) {
    builtin_throw(ctx, ctx.heap.type_err_proto,
        "'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
}

// Bound function [[Call]] handler.
// When a bound function is called, this handler unwraps the bound data,
// prepends bound args to the call args, and re-dispatches.
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

    // Extract bound data, stored directly on the object (not property-table
    // entries; see HObjectFunction.bound_target in hobject.c3).
    TVal downstream = (*bound_obj.extra_ptr()).func.bound_target;
    TVal bound_this = (*bound_obj.extra_ptr()).func.bound_this;
    HObject* args_arr = (*bound_obj.extra_ptr()).func.bound_args;

    // Extract bound args array
    uint bound_argc = 0;
    if (args_arr != null) {
        HString* len_key = ctx.heap.str(heap::BuiltinStr.LENGTH);
        TVal? lv = args_arr.get_prop_proto(len_key, ctx.heap);
        if (try l = lv) {
            if (l.is_fastint()) {
                bound_argc = (uint)l.get_fastint();
            } else if (l.is_number()) {
                bound_argc = (uint)l.get_number();
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
    if (args_arr != null) {
        for (uint i = 0; i < bound_argc && actual_total < max_total; i++) {
            char[20] buf;
            int n = (int)(io::bprintf(&buf, "%d", i) ?? buf[:0]).len;
            if (n > 0 && n < 20) {
                HString* ek = builtin_intern_string(ctx.heap, buf[:n]);
                TVal? e = args_arr.get_prop_proto(ek, ctx.heap);
                if (try ev = e) all_args[actual_total++] = ev;
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

        // Lightfunc builtins read their receiver from ctx.regs[base_reg - 1]
        // (and the callee from base_reg - 2), not ctx.this_val, mirror the
        // object-downstream branch below so a bound lightfunc builtin (e.g.
        // Promise.resolve.bind(Promise)) sees bound_this, not a stale slot.
        ctx.regs[ctx.base_reg - 2] = downstream;
        ctx.regs[ctx.base_reg - 1] = bound_this;
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
            // Compiled function or BUILTIN_FN, use re-dispatch.
            // Decref the old callee slot (bound function g) and incref the downstream
            // function being installed: the register slot transfers ownership and the
            // next GETVAR/tval_copy_ref will decref whatever is in the slot.
            ctx.heap.decref_tval(&ctx.regs[ctx.base_reg - 2]);
            ctx.regs[ctx.base_reg - 2] = downstream;
            if (downstream.is_heap_allocated()) {
                ((types::HeapHeader*)downstream.get_heapptr()).incref();
            }
            // Same ownership transfer for the this-slot: decref old, write new.
            ctx.heap.decref_tval(&ctx.regs[ctx.base_reg - 1]);
            ctx.regs[ctx.base_reg - 1] = bound_this;
            if (bound_this.is_heap_allocated()) {
                ((types::HeapHeader*)bound_this.get_heapptr()).incref();
            }
            for (uint i = 0; i < total_argc && i < 65535; i++) {
                // The callee frame takes ownership of each arg register and will
                // decref it when the slot is overwritten or the frame unwinds.
                // The bound args (indices < bound_argc) were read out of the
                // stored args array via get_prop_proto without an incref, so we
                // must add the reference here to balance that future decref,
                // otherwise a bound-and-passed heap value (e.g. a constructor)
                // is over-decreffed and freed while still live. The appended
                // call args (i >= bound_argc) were moved out of the caller's
                // own registers, which relinquish their reference, so they need
                // no extra incref.
                if (i < bound_argc && all_args[i].is_heap_allocated()) {
                    ((types::HeapHeader*)all_args[i].get_heapptr()).incref();
                }
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

// Create Function.prototype, register call/apply/bind, and register
// the Function constructor globally.
fn bool register_function_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Function constructor as a proper function object FIRST
    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.FUNCTION.ordinal;

    // Create Function.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    // ES5 §15.3.4: Function.prototype accepts any arguments and returns
    // undefined when called as a function, and has no [[Construct]],
    // `new Function.prototype` must throw TypeError.
    proto.flags.constructable = false;
    heap.function_proto = proto;

    // Back-patch: register_object_constructor created the Object.prototype
    // `__proto__` getter/setter pair BEFORE heap.function_proto existed
    // (it would be null at that point). Now that we have Function.prototype,
    // re-stamp those accessors' [[Prototype]] so they inherit
    // Function.prototype.{apply,call,bind,toString}. Without this back-patch,
    // test262's built-in-function-object test fails: Reflect.ownKeys walks
    // every reachable function, and Object.getOwnPropertyDescriptors on a
    // descriptor's `get` field ends up calling Function.prototype.toString
    // on the `__proto__` getter (its [[Prototype]] was null).
    HObject* op_getter = heap.object_proto___proto___getter;
    HObject* op_setter = heap.object_proto___proto___setter;
    if (op_getter != null) op_getter.prototype = proto;
    if (op_setter != null) op_setter.prototype = proto;

    // Add .call method
    HString* call_key = builtin_intern_string(heap, "call");
    TVal call_tv;
    call_tv.set_lightfunc((void*)(usz)Builtin.FUNCTION_PROTO_CALL.ordinal);
    proto.put_prop(call_key, call_tv, hobject::PROP_FLAGS_WC, heap);

    // Add .apply method
    HString* apply_key = builtin_intern_string(heap, "apply");
    TVal apply_tv;
    apply_tv.set_lightfunc((void*)(usz)Builtin.FUNCTION_PROTO_APPLY.ordinal);
    proto.put_prop(apply_key, apply_tv, hobject::PROP_FLAGS_WC, heap);

    // Add .bind method
    HString* bind_key = builtin_intern_string(heap, "bind");
    TVal bind_tv;
    bind_tv.set_lightfunc((void*)(usz)Builtin.FUNCTION_PROTO_BIND.ordinal);
    proto.put_prop(bind_key, bind_tv, hobject::PROP_FLAGS_WC, heap);

    // Add .toString method
    HString* tostring_key = heap.str(heap::BuiltinStr.TO_STRING);
    TVal tostring_tv;
    tostring_tv.set_lightfunc((void*)(usz)Builtin.FUNCTION_PROTO_TOSTRING.ordinal);
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WC, heap);

    // Add [Symbol.hasInstance] method (ES6 §19.2.3.6).
    // Property descriptor: writable:false, enumerable:false, configurable:false.
    HString* hasinst_sym = ensure_hasinstance_symbol(heap);
    if (hasinst_sym != null) {
        TVal hasinst_tv;
        hasinst_tv.set_lightfunc((void*)(usz)Builtin.FUNCTION_PROTO_HASINSTANCE.ordinal);
        PropFlags hi_flags;
        hi_flags.writable = false;
        hi_flags.enumerable = false;
        hi_flags.configurable = false;
        hi_flags.is_accessor = false;
        proto.put_prop(hasinst_sym, hasinst_tv, hi_flags, heap);
    }

    // Set .constructor to the Function constructor object itself
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(func_obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC, heap);

    // ES5 §15.3.5.1: Function.prototype.length is 0
    // { [[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: true }
    HString* proto_len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal proto_len_tv;
    proto_len_tv.set_fastint(0);
    proto.put_prop(proto_len_key, proto_len_tv, hobject::PROP_FLAGS_NWC, heap);

    // ES6 §19.2.3: Function.prototype.name is "", must be defined immediately
    // after .length (property insertion order matters for property-order.js).
    // { [[Writable]]: false, [[Enumerable]]: false, [[Configurable]]: true }
    HString* proto_name_key = (HString*)heap.strs[heap::BuiltinStr.NAME];
    TVal proto_name_tv;
    proto_name_tv.set_string((HString*)heap.strs[heap::BuiltinStr.EMPTY]);
    proto.put_prop(proto_name_key, proto_name_tv, hobject::PROP_FLAGS_NWC, heap);

    // ES2017 §9.2.7 AddRestrictedFunctionProperties(F): attach `caller` and
    // `arguments` accessor properties on Function.prototype whose get/set
    // both throw TypeError. Both slots share a single thrower function
    // (matching the spec's %ThrowTypeError% intrinsic), so
    // `callerDesc.get === argumentsDesc.get` per accessor-properties.js AND
    // each property's own get === set.
    // { [[Get]]: thrower, [[Set]]: thrower, [[Enumerable]]: false,
    //   [[Configurable]]: true }
    {
        // Build ONE shared thrower function. ES2017 §9.2.7 attaches the
        // same intrinsic thrower to both `caller` and `arguments`.
        HObject*? get_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try get_fn = get_raw) {
            (*get_fn.extra_ptr()).func.builtin_fn_index =
                (int)Builtin.FUNCTION_PROTO_RESTRICTED_GETTER.ordinal;
            get_fn.flags.callable = true;
            get_fn.flags.constructable = false;
            get_fn.prototype = heap.function_proto;
            // Name per V8/SpiderMonkey convention. The exact name isn't
            // asserted by the failing tests, but a real name makes
            // toString output more readable.
            // %ThrowTypeError% is anonymous: name is the empty string
            // (ES2017 §9.2.7, asserted by built-ins/ThrowTypeError/name.js).
            // length is defined first: built-ins/ThrowTypeError/property-order.js
            // requires the order "length", "name".
            HString* len_str = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            if (len_str != null) {
                TVal ltv; ltv.set_fastint(0);
                get_fn.put_prop(len_str, ltv, hobject::PROP_FLAGS_NNC, heap);
            }
            HString* get_name = builtin_intern_string(heap, "");
            if (get_name != null) {
                TVal ntv; ntv.set_string(get_name);
                HString* nkey = heap.str(heap::BuiltinStr.NAME);
                if (nkey != null) get_fn.put_prop(nkey, ntv, hobject::PROP_FLAGS_NNC, heap);
            }

            // %ThrowTypeError% is frozen: [[Extensible]] false and every own
            // property non-configurable (ES2017 §9.2.7 step 6, §9.4.4.7).
            // Also the only way the Function.prototype and arguments-object
            // poison pills share one intrinsic, which the descriptor-based
            // tests rely on.
            get_fn.flags.extensible = false;
            heap.throw_type_error = get_fn;

            TVal shared_thrower; shared_thrower.set_object(get_fn);
            // Setter is the same function as the getter.
            TVal shared_setter = shared_thrower;

            PropFlags restricted_flags;
            restricted_flags.writable = false;
            restricted_flags.enumerable = false;
            restricted_flags.configurable = true;
            restricted_flags.is_accessor = true;

            HString* caller_key = builtin_intern_string(heap, "caller");
            if (caller_key != null) {
                TVal gs_caller = hobject::hobject_create_accessors(heap,
                    shared_thrower, shared_setter);
                proto.put_prop(caller_key, gs_caller, restricted_flags, heap);
            }

            HString* args_key = heap.str(heap::BuiltinStr.ARGUMENTS);
            if (args_key != null) {
                TVal gs_args = hobject::hobject_create_accessors(heap,
                    shared_thrower, shared_setter);
                proto.put_prop(args_key, gs_args, restricted_flags, heap);
            }
        }
    }

    // Set Function.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    func_obj.put_prop(prototype_key, proto_tv, proto_pflags, heap);

    // Set Function.length (ES5 §15.3.3)
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv;
    len_tv.set_fastint(1);
    func_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC, heap);

    // Register Function constructor globally as an OBJECT
    HString* func_key = heap.str_intern("Function");
    if (func_key == null) return false;
    TVal func_val;
    func_val.set_object(func_obj);
    set_func_ctor_name(func_obj, heap, "Function");
    env::env_declare_nonenum(global_env, func_key, func_val);

    // Stash so later registration passes (GeneratorFunction, AsyncFunction,
    // AsyncGeneratorFunction) can wire their [[Prototype]] to %Function%.
    heap.function_ctor = func_obj;

    return true;
}
