/// Error constructors: Error, TypeError, RangeError, ReferenceError, SyntaxError, EvalError, URIError, AggregateError.
module duktape::builtins;
import duktape::types;
import duktape::env;
import std::io;
import duktape::hstring;
import duktape::hobject;

import duktape::heap;

// ============================================================================
// Error constructor builtins
// ============================================================================

/// Capture `stack_str` on `err` (an ERROR-class instance) in the object's
/// HObjectError.captured_stack field, NOT a property-table entry, so it is
/// invisible to hasOwnProperty/getOwnPropertyNames/Reflect.ownKeys/for-in.
/// The error-stack-accessor proposal exposes "stack" only via the inherited
/// get/set accessor pair on Error.prototype, never as an own property (see
/// instance-no-own-stack.js). Read back by builtin_error_proto_stack_get.
fn void error_set_captured_stack(HObject* err, Heap* heap, HString* stack_str) {
    TVal tv;
    tv.set_string(stack_str);
    heap.tval_copy_ref(&(*err.extra_ptr()).err.captured_stack, &tv);
}

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
                HString* msg_key = ctx.heap.str(heap::BuiltinStr.MESSAGE);
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

    // Capture .stack (stub, "name: message" format for now) as an internal
    // property; it is exposed to JS only via the get/set accessor pair on
    // Error.prototype (error-stack-accessor proposal), not as an own property.
    {
        // Get the error name from the prototype's .name property
        HString* name_str = builtin_intern_string(ctx.heap, "Error");
        if (proto != null) {
            HString* name_key = (HString*)ctx.heap.strs[heap::BuiltinStr.NAME];
            TVal? name_prop = proto.get_prop_proto(name_key);
            if (try nv = name_prop) {
                // Must not invoke user code here: .stack is captured during
                // construction, and a user-supplied .name accessor/toString
                // must NOT run at construction time (only when .name or
                // .stack is actually read), see instance-name-tostring
                // probe. builtin_to_string on an OBJECT would otherwise
                // fabricate "[object Object]" without ever calling the
                // user's toString, which is worse than just keeping the
                // "Error" default; only coerce values ToString can stringify
                // without invoking user code.
                if (!nv.is_undefined() && !nv.is_object()) {
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
        error_set_captured_stack(err, ctx.heap, stack_str);
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
// AggregateError constructor, ES2021 §28.1.1.1
// ============================================================================

/// IterableToList(items), ES2022 §7.4.11 (used by AggregateError's
/// `errors` argument per §20.5.7.1.1 step 3). GetIterator(items, sync),
/// then IteratorStep/IteratorValue in a loop, appending each value to a
/// fresh Array. Any abrupt completion propagates directly (there is no
/// partial result to close over since the caller hasn't seen `values` yet).
/// Returns the array HObject, or null with ctx.should_throw set on failure.
fn HObject* aggregate_error_iterable_to_list(BuiltinContext* ctx, TVal items) {
    Heap* heap = ctx.heap;

    // GetMethod(items, @@iterator)
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym == null) { ctx.result.set_undefined(); return null; }

    HObject* items_obj = null;
    if (items.is_object() && items.get_heapptr() != null) {
        items_obj = (HObject*)items.get_heapptr();
    } else if (!items.is_undefined() && !items.is_null()) {
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try w = wrapped) {
            items_obj = w;
            HObject* wrap_proto = heap.string_proto;
            if (items.is_string()) {
                (*items_obj.extra_ptr()).prim.primitive_value = items;
            } else if (items.is_fastint() || items.is_number()) {
                wrap_proto = heap.number_proto;
            } else if (items.is_boolean()) {
                wrap_proto = heap.bool_proto;
            } else if (items.is_bigint()) {
                wrap_proto = heap.bigint_proto;
            }
            items_obj.prototype = wrap_proto;
        }
    }

    if (items_obj == null) {
        arr_throw_type_error(ctx, "errors argument is not iterable");
        return null;
    }

    TVal? iter_method_opt = builtins_generic_get(items_obj, iter_sym, ctx);
    if (ctx.should_throw) return null;
    TVal iter_method;
    iter_method.set_undefined();
    if (try im = iter_method_opt) iter_method = im;
    if (iter_method.is_undefined() || iter_method.is_null()) {
        arr_throw_type_error(ctx, "errors argument is not iterable");
        return null;
    }
    if (!arr_from_is_callable(iter_method)) {
        arr_throw_type_error(ctx, "Result of the Symbol.iterator method is not callable");
        return null;
    }
    if (heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return null; }

    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch e = arr_raw) { ctx.result.set_undefined(); return null; }
    HObject* arr = arr_raw;
    arr.prototype = heap.array_proto;

    TVal iterator = heap.call_fn(ctx.vm, iter_method, null, 0, items);
    if (ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        return null;
    }
    if (!iterator.is_object() || iterator.get_heapptr() == null) {
        arr_throw_type_error(ctx, "Result of the Symbol.iterator method is not an object");
        return null;
    }
    HObject* iter_obj = (HObject*)iterator.get_heapptr();

    HString* next_key = builtin_intern_string(heap, "next");
    HString* done_key = heap.str(heap::BuiltinStr.DONE);
    HString* value_key = heap.str(heap::BuiltinStr.VALUE);
    HString* len_key = heap.str(heap::BuiltinStr.LENGTH);

    uint k = 0;
    while (true) {
        TVal? next_method_opt = builtins_generic_get(iter_obj, next_key, ctx);
        if (ctx.should_throw) return null;
        TVal next_method;
        if (try nm = next_method_opt) { next_method = nm; } else { break; }
        if (!arr_from_is_callable(next_method)) {
            arr_throw_type_error(ctx, "iterator.next is not callable");
            return null;
        }

        TVal step_result = heap.call_fn(ctx.vm, next_method, null, 0, iterator);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return null;
        }
        if (!step_result.is_object() || step_result.get_heapptr() == null) {
            arr_throw_type_error(ctx, "Iterator result is not an object");
            return null;
        }
        HObject* result_obj = (HObject*)step_result.get_heapptr();

        TVal? done_opt = builtins_generic_get(result_obj, done_key, ctx);
        if (ctx.should_throw) return null;
        bool done = false;
        if (try dv = done_opt) done = builtin_to_boolean(&dv);
        if (done) {
            if (len_key != null) arr_set_length_or_throw(ctx, arr, len_key, (ulong)k);
            return arr;
        }

        TVal? value_opt = builtins_generic_get(result_obj, value_key, ctx);
        if (ctx.should_throw) {
            arr_iterator_close_after_throw(ctx, iterator);
            return null;
        }
        TVal next_value;
        if (try vv = value_opt) { next_value = vv; } else { next_value.set_undefined(); }

        HString* pk = heap.int_to_hstring((long)k);
        if (pk != null) {
            if (!arr_create_data_property_or_throw(ctx, arr, pk, next_value)) {
                arr_iterator_close_after_throw(ctx, iterator);
                return null;
            }
        }
        k++;
    }

    return arr;
}

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

    // §20.5.7.1.1 step 5: message uses ToString via ToPrimitive (hint
    // "string") so a throwing toString()/valueOf() propagates, builtin_to_string
    // (used elsewhere) does not run ToPrimitive and would swallow the abrupt
    // completion (see commit eea15205 for the same fix on the URI builtins).
    HString* msg_str = null;
    if (!msg_val.is_undefined()) {
        msg_str = builtin_to_string_vm(ctx, &msg_val);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (msg_str != null) {
            TVal msg_prop;
            msg_prop.set_string(msg_str);
            HString* msg_key = ctx.heap.str(heap::BuiltinStr.MESSAGE);
            err.put_prop(msg_key, msg_prop, hobject::PROP_FLAGS_WC);
        }
    }

    // Capture .stack (stub, "AggregateError: message" format for now) as an
    // internal property; exposed to JS only via Error.prototype's accessor.
    {
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
        error_set_captured_stack(err, ctx.heap, stack_str);
    }

    // §20.5.7.1.1 step 3: errorsList = ? IterableToList(errors), `errors` is
    // an ITERABLE, not a pre-built array; must throw if it isn't iterable
    // (including when omitted, since GetMethod(undefined, @@iterator) fails).
    // step 4: set the own "errors" property to a fresh Array from that list.
    HObject* errors_arr = aggregate_error_iterable_to_list(ctx, errors_val);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (errors_arr != null) {
        HString* errors_key = builtin_intern_string(ctx.heap, "errors");
        TVal errors_tv;
        errors_tv.set_object(errors_arr);
        err.put_prop(errors_key, errors_tv, hobject::PROP_FLAGS_WC);
    }

    // ES2022 §20.5.8.1 InstallErrorCause, AggregateError's 3rd arg is options.
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
// Error.prototype.toString, returns "name: message" per ES5 §15.11.4.4
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
    HString* msg_str  = ctx.heap.str(heap::BuiltinStr.EMPTY);

    {
        HObject* obj = (HObject*)this_val.get_heapptr();

        // ES2015 §19.5.3.4 step 3: let name be ? Get(O, "name"). We must use a
        // full [[Get]] (not get_prop_proto) so accessor getters on the
        // prototype chain are invoked, and so their throws propagate via
        // ctx.should_throw per ES2017 §25.4.1.5 step 7 (test262 get-throws).
        HString* name_key = ctx.heap.str(heap::BuiltinStr.NAME);
        TVal? name_prop = builtins_generic_get(obj, name_key, ctx);
        if (ctx.should_throw) return;
        if (try nv = name_prop) {
            if (!nv.is_undefined()) {
                // ES2015 §19.5.3.4 step 4: ? ToString(name), ToString on a
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
        HString* msg_key = ctx.heap.str(heap::BuiltinStr.MESSAGE);
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
        int len = (int)(io::bprintf(&buf, "%s: %s", (ZString)name_cstr, (ZString)msg_cstr) ?? buf[:0]).len;
        if (len > 0 && len < 256) {
            HString* result_str = builtin_intern_string(ctx.heap, buf[:len]);
            ctx.result.set_string(result_str);
        } else {
            ctx.result.set_undefined();
        }
    }
}
// ============================================================================
// Error.captureStackTrace, V8/SpiderMonkey extension (ES6 §19.5.2.1 stub)
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
    HString* stack_key = ctx.heap.str(heap::BuiltinStr.STACK);
    HString* empty = ctx.heap.str(heap::BuiltinStr.EMPTY);
    TVal stack_tv;
    stack_tv.set_string(empty);
    target.put_prop(stack_key, stack_tv, hobject::PROP_FLAGS_WC);
    ctx.result.set_undefined();
}

// ============================================================================
// Error.prototype.stack accessor, error-stack-accessor proposal
// ============================================================================
//
// stack is an accessor pair on Error.prototype (not an own data property of
// each instance): { [[Enumerable]]: false, [[Configurable]]: true }.
//
//   get Error.prototype.stack:
//     1. Let E be the this value.
//     2. If E is not an Object, throw a TypeError exception.
//     3. If E does not have an [[ErrorData]] internal slot, return undefined.
//     4. Return an implementation-defined string that represents the stack
//        trace of E.
//   [[ErrorData]] presence is keyed on ObjClass.ERROR, the tag every
//   Error/NativeError constructor allocates its instances with (mirrors
//   Error.isError). The captured text itself lives in HObjectError.
//   captured_stack (see error_set_captured_stack), never in a JS-visible
//   "stack" own property, a fake "stack" own data property on a non-Error
//   object is ignored, since the getter only reads the internal slot.
fn void builtin_error_proto_stack_get(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Error.prototype.stack getter called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.ERROR) {
        ctx.result.set_undefined();
        return;
    }
    TVal* captured = &(*obj.extra_ptr()).err.captured_stack;
    if (captured.is_string()) {
        ctx.heap.tval_copy_ref(ctx.result, captured);
        return;
    }
    // Foreign new.target (Reflect.construct(Ctor, args, NotAnError)) still
    // acquires [[ErrorData]] via Ctor's [[Construct]], but if the capture
    // above somehow found nothing, produce an empty string rather than
    // undefined, E has [[ErrorData]], so step 4 always returns a String.
    HString* empty = (HString*)ctx.heap.strs[heap::BuiltinStr.EMPTY];
    ctx.result.set_string(empty);
}

/// set Error.prototype.stack, error-stack-accessor proposal:
///   1. Let E be the this value.
///   2. If E is not an Object, throw a TypeError exception.
///   3. If v is not a String, throw a TypeError exception.
///   4. Perform ? SetterThatIgnoresPrototypeProperties(this value,
///      %Error.prototype%, "stack", v).
///   5. Return undefined.
fn void builtin_error_proto_stack_set(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Error.prototype.stack setter called on non-object");
        return;
    }
    TVal value = builtin_arg(ctx, 0);
    // Symbols share TVal's TAG_STRING representation (an HString with
    // is_symbol set), so is_string() alone would wrongly accept them, a
    // Symbol is not a String value per step 3.
    bool is_real_string = value.is_string() && value.get_heapptr() != null
        && !((HString*)value.get_heapptr()).is_symbol();
    if (!is_real_string) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Error.prototype.stack setter requires a String value");
        return;
    }
    HString* key = (HString*)ctx.heap.strs[heap::BuiltinStr.STACK];
    error_setter_ignores_prototype_properties(ctx, ctx.heap.err_proto, key, value);
    ctx.result.set_undefined();
}

/// SetterThatIgnoresPrototypeProperties(thisValue, home, propertyKey, value),
/// ES2025 §7.3.37, specialised for "stack" on Error.prototype.
///   1. If thisValue is not an Object, throw a TypeError exception.
///   2. If SameValue(thisValue, home) is true, throw a TypeError exception
///      (emulates assignment to a non-writable data property on home).
///   3. Let desc be ? thisValue.[[GetOwnProperty]](propertyKey).
///   4. If desc is undefined, perform ? CreateDataPropertyOrThrow(thisValue,
///      propertyKey, value), a plain WEC data property.
///   5. Else, perform ? Set(thisValue, propertyKey, value, true), routes
///      through the own accessor's setter, or overwrites the own data
///      property (throwing if non-writable).
/// thisValue was already confirmed to be an Object by the caller.
fn void error_setter_ignores_prototype_properties(BuiltinContext* ctx, HObject* home, HString* key, TVal value) {
    Heap* heap = ctx.heap;
    HObject* this_obj = (HObject*)ctx.this_val.get_heapptr();

    if (this_obj == home) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "Cannot assign to read only property 'stack'");
        return;
    }

    ProxyDesc desc;
    if (!own_property_desc(ctx.vm, heap, this_obj, key, &desc)) {
        proxy_ctx_ok(ctx);
        return;
    }

    if (!desc.found) {
        // CreateDataPropertyOrThrow: full {writable:true, enumerable:true,
        // configurable:true} data property.
        ProxyDesc nd = {};
        nd.found = true;
        nd.has_value = true; nd.value = value;
        nd.has_writable = true; nd.writable = true;
        nd.has_enumerable = true; nd.enumerable = true;
        nd.has_configurable = true; nd.configurable = true;
        bool res;
        if (!object_define_own(ctx.vm, heap, this_obj, key, &nd, &res)) {
            proxy_ctx_ok(ctx);
            return;
        }
        if (!res) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto, "Cannot add property 'stack', object is not extensible");
        }
        return;
    }

    // Set(thisValue, propertyKey, value, Throw=true), receiver is thisValue
    // itself (no separate Receiver argument in the proposal's algorithm).
    bool sres;
    if (!js_set_with_receiver(ctx.vm, heap, this_obj, key, value, ctx.this_val, &sres)) {
        proxy_ctx_ok(ctx);
        return;
    }
    if (!sres) {
        builtin_throw_no_result_change(ctx, heap.type_err_proto, "Cannot assign to read only property 'stack'");
    }
}

// ============================================================================
// Error.isError, ES2026 §20.5.2.2
// ============================================================================

/// Error.isError(arg), true iff arg is an object carrying the [[ErrorData]]
/// internal slot. We key this on ObjClass.ERROR (the tag every Error/NativeError
/// constructor allocates its instances with) rather than the prototype chain,
/// so it's cross-realm safe and returns false for objects that merely look
/// like errors (e.g. `{ __proto__: Error.prototype }`).
fn void builtin_error_isError(BuiltinContext* ctx) {
    TVal arg;
    arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];

    bool is_error = arg.is_object() && arg.get_heapptr() != null &&
        ((HObject*)arg.get_heapptr()).get_class() == hobject::ObjClass.ERROR;
    ctx.result.set_boolean(is_error);
}

// ============================================================================
// Error built-in registration
// ============================================================================

/// Helper: create a prototype object for an error type.
/// proto_parent is the [[Prototype]] (e.g. Error.prototype for subclasses).
/// The prototype is an ordinary object (ObjClass.OBJECT) per ES2015 §19.5.6.3,
/// so it must not be an Error instance itself.
fn HObject* register_error_prototype(Heap* heap, HObject* proto_parent, char[] name_str) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return null;
    HObject* proto = proto_raw;
    proto.prototype = proto_parent;

    // Set .name property
    HString* name_key = heap.str(heap::BuiltinStr.NAME);
    HString* name_hstr = builtin_intern_string(heap, name_str);
    TVal name_tv;
    name_tv.set_string(name_hstr);
    proto.put_prop(name_key, name_tv, hobject::PROP_FLAGS_WC);

    // Set .message property (empty string)
    HString* msg_key = (HString*)heap.strs[heap::BuiltinStr.MESSAGE];
    HString* msg_hstr = heap.str(heap::BuiltinStr.EMPTY);
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

    // Error.prototype.stack, accessor pair (error-stack-accessor proposal).
    // { [[Enumerable]]: false, [[Configurable]]: true }.
    {
        HString* stack_key = (HString*)heap.strs[heap::BuiltinStr.STACK];
        if (!iterhelper_register_accessor(err_proto, heap, stack_key,
                Builtin.ERROR_PROTO_STACK_GET.ordinal, Builtin.ERROR_PROTO_STACK_SET.ordinal,
                "get stack", "set stack")) return false;
    }

    // constructor_key used throughout, HObject ctors are wired by register_native_error_ctor below.
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

    // Register static method: Error.isError
    {
        HString* iserror_key = builtin_intern_string(heap, "isError");
        TVal iserror_tv;
        iserror_tv.set_lightfunc((void*)(usz)Builtin.ERROR_ISERROR.ordinal);
        err_ctor.put_prop(iserror_key, iserror_tv, hobject::PROP_FLAGS_WC);
    }

    // Register Error in global environment
    {
        HString* err_key = heap.str_intern("Error");
        if (err_key == null) return false;
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

    if (!register_native_error_ctor(global_env, heap, "AggregateError", Builtin.AGGREGATE_ERROR.ordinal, aggregate_err_proto, err_ctor, 2)) return false;

    return true;
}

/// Create and register a NativeError constructor as a real HObject.
/// Sets [[Prototype]] = err_ctor (Error constructor HObject) per §19.5.6.1,
/// wires own "prototype" property (NWC) to native_proto, and updates
/// native_proto.constructor to point at the new ctor HObject.
fn bool register_native_error_ctor(EnvRecord* global_env, Heap* heap, char[] name,
                                   uint fn_index, HObject* native_proto, HObject* err_ctor,
                                   int ctor_length = 1) {
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
    set_func_ctor_name_length(ctor, heap, name, ctor_length);

    // Register in global environment
    HString* key = heap.str_intern(name);
    if (key == null) return false;
    TVal val;
    val.set_object(ctor);
    env::env_declare_nonenum(global_env, key, val);
    return true;
}
