/// Array constructor and Array.prototype methods.
module duktape::builtins;

import duktape::types;
import std::math;
import std::io;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::vm;

// ============================================================================
// Additional Array.prototype methods
// ============================================================================

/// Array.of(...items) — ES6 §22.1.2.3
fn void builtin_array_of(BuiltinContext* ctx) {
    uint len = (uint)ctx.argc;

    // Step 3-4: If IsConstructor(C), A = Construct(C, «len»); else ArrayCreate(len).
    // IsConstructor requires callable + constructable: lightfuncs (Math.cos)
    // are not objects so already excluded; bound functions inherit the
    // constructable bit from their target (Math.cos.bind(Math) is therefore
    // NOT a constructor), so they fall through to ArrayCreate here.
    HObject* arr;
    bool ctor_used = false;
    TVal c = ctx.this_val;
    if (c.is_object() && c.get_heapptr() != null) {
        HObject* c_obj = (HObject*)c.get_heapptr();
        if (c_obj.is_callable() && c_obj.is_constructable()
            && ctx.heap.construct_fn != null && ctx.vm != null) {
            TVal len_arg; len_arg.set_fastint((long)len);
            TVal result_tv = ctx.heap.construct_fn(ctx.vm, c, &len_arg, 1, c);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                ctx.result.set_undefined(); return;
            }
            if (!result_tv.is_object() || result_tv.get_heapptr() == null) {
                arr_throw_type_error(ctx, "Array.of: constructor did not return an object");
                return;
            }
            arr = (HObject*)result_tv.get_heapptr();
            ctor_used = true;
        }
    }
    if (!ctor_used) {
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = arr_raw) { ctx.result.set_undefined(); return; }
        arr = arr_raw;
        arr.prototype = ctx.heap.array_proto;
    }

    // Step 8: CreateDataPropertyOrThrow(A, Pk, kValue) for each item.
    for (uint i = 0; i < len; i++) {
        TVal elem = ctx.regs[ctx.base_reg + (uint)i];
        if (!array_set_elem_ulong_checked(ctx, arr, (ulong)i, elem)) return;
    }

    // Step 9: Set(A, "length", len, true). Must go through [[Set]] so an own
    // or inherited "length" setter on the result is invoked (and its abrupt
    // completion propagated). For ARRAY results, array_set_length updates
    // array_len_ptr directly so the descriptor stays
    // {writable, enumerable:false, configurable:false}; for everything else
    // (including proxy results and user-defined constructors), use the
    // arr_set_length_or_throw helper which handles proxy [[Set]], own
    // accessors, inherited accessors, and writable/non-writable data props.
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    if (arr.get_class() == hobject::ObjClass.ARRAY) {
        array_set_length(arr, len, ctx.heap);
    } else {
        if (!arr_set_length_or_throw(ctx, arr, len_key, (ulong)len)) {
            ctx.result.set_undefined();
            return;
        }
    }
    ctx.result.set_object(arr);
}

/// Array.prototype.fill(value, start, end) — ES6 §22.1.3.6
fn void builtin_array_proto_fill(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    TVal fill_val;
    if (ctx.argc > 0) {
        fill_val = ctx.regs[ctx.base_reg];
    } else {
        fill_val.set_undefined();
    }

    long start_i = 0;
    if (ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
        TVal* start_arg = &ctx.regs[ctx.base_reg + 1];
        if (is_symbol_val(*start_arg)) {
            arr_throw_type_error(ctx, "Cannot convert a Symbol value to a number");
            return;
        }
        double sd = builtin_to_integer_vm(ctx, start_arg);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        start_i = (long)sd;
        if (start_i < 0) { start_i = (long)len + start_i; if (start_i < 0) start_i = 0; }
        if ((ulong)start_i > len) start_i = (long)len;
    }

    long end_i = (long)len;
    if (ctx.argc > 2 && !ctx.regs[ctx.base_reg + 2].is_undefined()) {
        TVal* end_arg = &ctx.regs[ctx.base_reg + 2];
        if (is_symbol_val(*end_arg)) {
            arr_throw_type_error(ctx, "Cannot convert a Symbol value to a number");
            return;
        }
        double ed = builtin_to_integer_vm(ctx, end_arg);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        end_i = (long)ed;
        if (end_i < 0) { end_i = (long)len + end_i; if (end_i < 0) end_i = 0; }
        if ((ulong)end_i > len) end_i = (long)len;
    }

    for (ulong i = (ulong)start_i; i < (ulong)end_i; i++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (!array_set_elem_ulong_set(ctx, obj, i, fill_val)) {
            return;
        }
    }
    ctx.result.set_object(obj);
}

/// Practical cap for iterative methods: beyond this many elements we don't
/// Array.prototype.at(index) — ES2022 §22.1.3.1
fn void builtin_array_proto_at(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    // Step 3: ToIntegerOrInfinity(index) — coerces via valueOf/toString and
    // clamps NaN to 0 (ES2022 §23.1.3.1).
    double idx_d = (ctx.argc > 0) ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    long idx = (long)idx_d;
    if (idx < 0) idx = (long)len + idx;
    if (idx < 0 || (ulong)idx >= len) { ctx.result.set_undefined(); return; }

    TVal elem;
    if (arr_get_elem_vm(obj, (ulong)idx, ctx.heap, ctx, &elem)) {
        *ctx.result = elem;
    } else {
        ctx.result.set_undefined();
    }
}

/// Array.prototype.copyWithin(downstream, start, end) — ES6 §22.1.3.3
fn void builtin_array_proto_copyWithin(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    double downstream_d = (ctx.argc > 0 && !ctx.regs[ctx.base_reg].is_undefined())
        ? builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg])
        : 0.0;
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    long downstream_i = (long)downstream_d;
    if (downstream_i < 0) { downstream_i = (long)len + downstream_i; if (downstream_i < 0) downstream_i = 0; }
    if ((ulong)downstream_i > len) downstream_i = (long)len;

    long start_i = 0;
    if (ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
        double sd = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        start_i = (long)sd;
        if (start_i < 0) { start_i = (long)len + start_i; if (start_i < 0) start_i = 0; }
        if ((ulong)start_i > len) start_i = (long)len;
    }

    long end_i = (long)len;
    if (ctx.argc > 2 && !ctx.regs[ctx.base_reg + 2].is_undefined()) {
        double ed = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 2]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        end_i = (long)ed;
        if (end_i < 0) { end_i = (long)len + end_i; if (end_i < 0) end_i = 0; }
        if ((ulong)end_i > len) end_i = (long)len;
    }

    long count = end_i - start_i;
    if (count > (long)len - downstream_i) count = (long)len - downstream_i;
    if (count <= 0) { ctx.result.set_object(obj); return; }

    // Forward copy is safe when downstream < start; otherwise copy backwards.
    // Spec §23.1.3.3 step 17: for each index k in the range, HasProperty(from)
    // determines whether to Set or Delete at the destination.
    // For proxy objects, HasProperty fires the "has" trap explicitly before Get.
    bool is_proxy = obj.flags.exotic_proxyobj;
    if (downstream_i < start_i) {
        for (long i = 0; i < count; i++) {
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            TVal elem;
            ulong from_idx = (ulong)(start_i + i);
            ulong to_idx   = (ulong)(downstream_i + i);
            bool from_present;
            if (is_proxy) {
                from_present = arr_has_prop(obj, from_idx, ctx.heap, ctx.vm);
                if (!from_present && ctx.heap.has_error) {
                    proxy_ctx_ok(ctx); ctx.result.set_undefined(); return;
                }
            } else {
                from_present = arr_get_elem_vm(obj, from_idx, ctx.heap, ctx, &elem);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            }
            if (from_present) {
                if (is_proxy) {
                    if (!arr_get_elem_vm(obj, from_idx, ctx.heap, ctx, &elem)) {
                        ctx.result.set_undefined(); return;
                    }
                }
                // ES2022 §23.1.3.3 step 17.e.iii: Set(O, toKey, fromVal, true).
                if (!array_set_elem_ulong_set(ctx, obj, to_idx, elem)) {
                    ctx.result.set_undefined(); return;
                }
            } else if (!ctx.should_throw) {
                if (!array_delete_elem_ulong_checked(ctx, obj, to_idx)) {
                    ctx.result.set_undefined(); return;
                }
            } else {
                ctx.result.set_undefined(); return;
            }
        }
    } else {
        for (long i = count - 1; i >= 0; i--) {
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            TVal elem;
            ulong from_idx = (ulong)(start_i + i);
            ulong to_idx   = (ulong)(downstream_i + i);
            bool from_present;
            if (is_proxy) {
                from_present = arr_has_prop(obj, from_idx, ctx.heap, ctx.vm);
                if (!from_present && ctx.heap.has_error) {
                    proxy_ctx_ok(ctx); ctx.result.set_undefined(); return;
                }
            } else {
                from_present = arr_get_elem_vm(obj, from_idx, ctx.heap, ctx, &elem);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            }
            if (from_present) {
                if (is_proxy) {
                    if (!arr_get_elem_vm(obj, from_idx, ctx.heap, ctx, &elem)) {
                        ctx.result.set_undefined(); return;
                    }
                }
                // ES2022 §23.1.3.3 step 17.e.iii: Set(O, toKey, fromVal, true).
                if (!array_set_elem_ulong_set(ctx, obj, to_idx, elem)) {
                    ctx.result.set_undefined(); return;
                }
            } else if (!ctx.should_throw) {
                if (!array_delete_elem_ulong_checked(ctx, obj, to_idx)) {
                    ctx.result.set_undefined(); return;
                }
            } else {
                ctx.result.set_undefined(); return;
            }
        }
    }
    ctx.result.set_object(obj);
}

/// Array.prototype.includes(searchElement, fromIndex) — ES7 §22.1.3.13
fn void builtin_array_proto_includes(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    // ES2022 §23.1.3.12 style: If len is 0, return false (no fromIndex eval).
    if (len == 0) {
        ctx.result.set_boolean(false);
        return;
    }

    // Use ToInteger per spec (per ES2022 §23.1.3.11 step 4). Use
    // builtin_to_integer_vm so valueOf abrupt propagates, and reject Symbol
    // inputs with TypeError (ToNumber(Symbol) throws).
    long start_i = 0;
    if (ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        if (is_symbol_val(*arg)) {
            arr_throw_type_error(ctx, "Cannot convert a Symbol value to a number");
            return;
        }
        double sd = builtin_to_integer_vm(ctx, arg);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        start_i = (long)sd;
        if (start_i < 0) { start_i = (long)len + start_i; if (start_i < 0) start_i = 0; }
        if ((ulong)start_i > len) start_i = (long)len;
    }

    TVal search_elem;
    if (ctx.argc > 0) {
        search_elem = ctx.regs[ctx.base_reg];
    } else {
        search_elem.set_undefined();
    }

    for (ulong i = (ulong)start_i; i < len; i++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal v;
        if (!arr_get_elem_vm(obj, i, ctx.heap, ctx, &v)) {
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            v.set_undefined();
        }
        if (same_value_zero(v, search_elem)) {
            ctx.result.set_boolean(true);
            return;
        }
    }
    ctx.result.set_boolean(false);
}

/// Helper: flatten source array into downstream array recursively.
/// Returns the next downstream index after all elements are inserted.
fn ulong flatten_into(HObject* downstream, HObject* source, ulong source_len, ulong downstream_idx, double depth, BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    for (ulong i = 0; i < source_len; i++) {
        if (ctx.should_throw) return downstream_idx;
        if (!arr_has_prop(source, i, heap, ctx.vm)) {
            continue;
        }
        TVal elem;
        if (!arr_get_elem_vm(source, i, heap, ctx, &elem)) {
            continue;
        }
        if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* elem_obj = (HObject*)elem.get_heapptr();
            bool elem_is_array = (elem_obj.get_class() == hobject::ObjClass.ARRAY);
            if (!elem_is_array && elem_obj.flags.exotic_proxyobj) {
                if (!proxy_is_array(heap, elem_obj, &elem_is_array)) {
                    proxy_ctx_ok(ctx);
                    return downstream_idx;
                }
            }
            if (elem_is_array && depth > 0) {
                HObject* inner = elem_obj;
                ulong inner_len;
                if (!array_to_length(inner, heap, ctx, &inner_len)) { return downstream_idx; }
                downstream_idx = flatten_into(downstream, inner, inner_len, downstream_idx, depth - 1, ctx);
                continue;
            }
        }
        if (!array_set_elem_ulong_checked(ctx, downstream, downstream_idx, elem)) {
            return downstream_idx;
        }
        downstream_idx++;
    }
    return downstream_idx;
}

/// Array.prototype.flat(depth) — ES2019 §22.1.3.10
fn void builtin_array_proto_flat(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.flat requires 'this' to be an object");
            TVal msg_tv; msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        return;
    }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    double depth_num = 1.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (!arg.is_undefined()) {
            depth_num = builtin_to_integer_vm(ctx, arg);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        }
    }
    if (depth_num < 0) depth_num = 0;

    // ES2019 §22.1.2.3 step 5: ArraySpeciesCreate(O, 0). Throws TypeError when
    // the species constructor is non-callable or returns a non-object.
    HObject* result = array_species_create_result(ctx, obj, 0);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (result == null) { ctx.result.set_undefined(); return; }

    ulong n = flatten_into(result, obj, len, 0, depth_num, ctx);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    array_set_length_ulong(result, n, ctx.heap, ctx.vm);

    ctx.result.set_object(result);
}

/// Array.prototype.flatMap(mapFn, thisArg) — ES2019 §22.1.3.11
fn void builtin_array_proto_flatMap(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.flatMap requires 'this' to be an object");
            TVal msg_tv; msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        return;
    }

    // ES2019 §22.1.3.11: read LengthOfArrayLike before checking IsCallable.
    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    // mapFn is required and must be callable (ES2019 §22.1.3.11 step 3).
    // When absent or non-callable, throw TypeError.
    TVal flatmap_callback;
    if (ctx.argc >= 1) {
        flatmap_callback = ctx.regs[ctx.base_reg];
    } else {
        flatmap_callback.set_undefined();
    }
    if (!arr_check_callback(flatmap_callback, ctx)) {
        return;
    }

    // flatMap(mapFn, thisArg): map each element then flatten depth 1
    TVal callback = flatmap_callback;
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }

    // ES2019 §22.1.3.11 step 5: ArraySpeciesCreate(O, 0).
    HObject* result = array_species_create_result(ctx, obj, 0);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (result == null) { ctx.result.set_undefined(); return; }

    ulong n = 0;
    for (ulong k = 0; k < len; k++) {
        if (!arr_has_prop(obj, k, ctx.heap, ctx.vm)) continue;
        TVal v;
        if (!arr_get_elem_vm(obj, k, ctx.heap, ctx, &v)) continue;

        TVal mapped = arr_call_callback(ctx, callback, thisArg, v, k, obj);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }

        // Flatten mapped result to depth 1
        bool mapped_is_array = false;
        if (mapped.is_object() && mapped.get_heapptr() != null) {
            HObject* mapped_obj = (HObject*)mapped.get_heapptr();
            mapped_is_array = (mapped_obj.get_class() == hobject::ObjClass.ARRAY);
            if (!mapped_is_array && mapped_obj.flags.exotic_proxyobj) {
                if (!proxy_is_array(ctx.heap, mapped_obj, &mapped_is_array)) {
                    proxy_ctx_ok(ctx);
                    ctx.result.set_undefined(); return;
                }
            }
        }
        if (mapped_is_array) {
            HObject* mapped_arr = (HObject*)mapped.get_heapptr();
            ulong mapped_len;
            if (!array_to_length(mapped_arr, ctx.heap, ctx, &mapped_len)) { ctx.result.set_undefined(); return; }
            for (ulong j = 0; j < mapped_len; j++) {
                if (arr_has_prop(mapped_arr, j, ctx.heap, ctx.vm)) {
                    TVal elem;
                    if (arr_get_elem_vm(mapped_arr, j, ctx.heap, ctx, &elem)) {
                        if (!array_set_elem_ulong_checked(ctx, result, n, elem)) {
                            ctx.result.set_undefined(); return;
                        }
                        n++;
                    }
                }
            }
        } else {
            if (!array_set_elem_ulong_checked(ctx, result, n, mapped)) {
                ctx.result.set_undefined(); return;
            }
            n++;
        }
    }

    // ES2019 §22.1.3.11: FlattenIntoArray does NOT explicitly set length.
    // For ARRAY class, update the internal length to match the written
    // elements so the length property reflects the actual element count.
    // For non-ARRAY results (e.g. from a custom species constructor),
    // do not set length — the spec does not call for it.
    if (result.get_class() == hobject::ObjClass.ARRAY) {
        array_set_length_ulong(result, n, ctx.heap, ctx.vm);
    }
    ctx.result.set_object(result);
}

// ============================================================================
// Array constructor builtins
// ============================================================================

/// Array() as function (ES5 §15.4.1) or new Array() as constructor (§15.4.2).
/// Creates and returns a new Array object.
fn void builtin_array(BuiltinContext* ctx) {
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = builtin_proto_from_new_target(ctx, ctx.heap.array_proto);

    // Array's exotic "length" is not a regular own property — it lives in the
    // dedicated array_len_ptr() slot (ES6 §9.4.2.1 ArraySetLength / [[DefineOwnProperty]]
    // "length" is {writable:true, enumerable:false, configurable:false}, and this
    // engine's array exotic implementation never materialises it as a table entry).
    // Using put_prop() here would wrongly create an enumerable own property that
    // shows up in for-in / JSON.stringify / Object.keys.
    if (ctx.argc == 0) {
        // No args: empty array with length 0
        *arr.array_len_ptr() = 0;
        ctx.result.set_object(arr);
        return;
    }

    if (ctx.argc == 1) {
        // Single arg: check if it's a number
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.is_number() || arg.is_fastint()) {
            // Single numeric arg: set array length
            // ES5 §15.4.2.2: If ToUint32(len) !== ToNumber(len), throw RangeError
            double d;
            if (arg.is_fastint()) {
                d = (double)arg.get_fastint();
            } else {
                d = arg.get_number();
            }
            // ToUint32 check per ES5 §9.6
            uint n = (uint)(long)d;
            if ((double)n != d) {
                // Invalid array length — throw RangeError
                arr_throw_range_error(ctx, "Invalid array length");
                ctx.result.set_object(arr);
                return;
            }
            *arr.array_len_ptr() = n;
        } else {
            // Single non-numeric arg: array with one element
            *arr.array_len_ptr() = 1;

            // Set element at index 0
            HString* zero_key = builtin_intern_string(ctx.heap, "0");
            arr.put_prop(zero_key, arg, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.set_object(arr);
        return;
    }

    // Multiple args: create array with given elements
    *arr.array_len_ptr() = (uint)ctx.argc;

    // Set each element
    for (ushort i = 0; i < ctx.argc; i++) {
        TVal elem = ctx.regs[ctx.base_reg + (uint)i];
        HString* idx_key = ctx.heap.int_to_hstring((long)i);
        if (idx_key != null) {
            arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        }
    }

    ctx.result.set_object(arr);
}

/// Helper: get the 'this' value as an object for Array.prototype methods.
/// Supports ToObject wrapping for primitive `this` values (ES5 §9.9).
fn HObject* array_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        return (HObject*)this_val.get_heapptr();
    }
    // null / undefined → TypeError
    if (this_val.is_null() || this_val.is_undefined()) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap,
                "Array.prototype method called on incompatible value");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
            TVal err_tv;
            err_tv.set_object(err);
            ctx.throw_value = err_tv;
        }
        ctx.should_throw = true;
        return null;
    }
    // Primitive (boolean, number, string) → ToObject wrapper
    return arr_to_object(this_val, ctx.heap);
}

// ============================================================================
// Array.prototype helpers
// ============================================================================

/// ES5 §9.6 ToUint32 — convert a double to uint32 per the spec algorithm.
/// NaN, ±Infinity, ±0 → 0. Otherwise floor(abs(x)) mod 2^32.
fn uint to_uint32(double val) {
    // NaN: NaN != NaN is true in IEEE 754
    if (val != val) return 0;
    // ±Infinity
    if (val == 1.0 / 0.0 || val == -1.0 / 0.0) return 0;
    // Fast path: value fits in int32 without conversion issues
    if (val >= 0.0 && val < 4294967296.0 && val == math::floor(val)) {
        return (uint)val;
    }
    // General case: val mod 2^32 using floor-based modulo (ES5 §9.6 step 4)
    double two32 = 4294967296.0;
    double n = val - math::floor(val / two32) * two32;
    if (n < 0.0) n += two32;
    return (uint)n;
}

/// Check if a raw double length value is a valid array length per ES5 §15.4.4.x.
/// Returns false for NaN, ±Infinity, negative, non-integer, > 2^32-1, or -0.
fn bool is_valid_array_length(double raw) {
    if (raw != raw) return false;                                      // NaN
    if (raw < 0.0) return false;                                       // negative
    if (raw == 0.0 && 1.0 / raw < 0.0) return false;                  // -0
    if (raw > 4294967295.0) return false;                              // > 2^32-1 or Infinity
    return raw == math::floor(raw);                                     // must be integer
}

/// Throw a RangeError with the given message.
fn void arr_throw_range_error(BuiltinContext* ctx, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.range_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
}

/// Helper to invoke a getter and return the result as double.
/// Propagates getter errors through ctx.should_throw / ctx.throw_value.
fn double invoke_getter_as_length(HObject* obj, TVal getter_fn, Heap* heap, BuiltinContext* ctx) {
    if (getter_fn.is_undefined() || getter_fn.is_null()) return 0;
    if (!getter_fn.is_object() || getter_fn.get_heapptr() == null) return 0;
    HObject* fn_obj = (HObject*)getter_fn.get_heapptr();
    void* vm_ptr = (ctx != null) ? ctx.vm : null;
    if (!fn_obj.is_callable() || heap.call_fn == null || vm_ptr == null) return 0;
    TVal this_val; this_val.set_object(obj);
    TVal result = heap.call_fn(vm_ptr, getter_fn, null, 0, this_val);
    if (heap.has_error) {
        // Propagate getter error instead of swallowing it
        if (ctx != null) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
        }
        heap.has_error = false;
        return 0;
    }
    // Per ES ToLength, the result of the length getter is itself ToNumber'd
    // (which for an object means calling valueOf/toString via the VM). Using
    // builtin_to_number_vm here is what makes `length: { valueOf: ... }`
    // style tests like `15.4.4.14-5-27` / `length-near-integer-limit` work.
    return builtin_to_number_vm(ctx, &result);
}

/// Read the raw 'length' property as a double from an array-like object.
/// Handles accessor properties by invoking the getter.
/// Propagates getter errors through ctx.should_throw / ctx.throw_value.
fn double array_get_length_raw(HObject* obj, Heap* heap, BuiltinContext* ctx) {
    // Proxy exotic: [[Get]]("length") through trap machinery.
    if (obj.flags.exotic_proxyobj) {
        void* vm_ptr = (ctx != null) ? ctx.vm : null;
        if (vm_ptr == null) return 0;
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key == null) return 0;
        TVal out;
        if (!js_get(vm_ptr, heap, obj, len_key, &out)) {
            if (ctx != null && heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = heap.error_value;
                heap.has_error = false;
            }
            return 0;
        }
        if (out.is_fastint()) return (double)out.get_fastint();
        if (out.is_number()) return out.get_number();
        if (ctx != null) return builtin_to_number_vm(ctx, &out);
        return 0;
    }

    if (obj.get_class() == ARRAY) {
        // For ARRAY class, also check if length is an accessor (set via defineProperty)
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            int own_idx = obj.find_prop_idx(len_key);
            if (own_idx >= 0) {
                PropFlags pf = obj.get_prop_flags((uint)own_idx);
                if (pf.is_accessor) {
                    TVal gs_slot = obj.prop_values()[own_idx];
                    TVal getter_fn = hobject::hobject_access_getter(gs_slot);
                    return invoke_getter_as_length(obj, getter_fn, heap, ctx);
                }
            }
        }
        return (double)*obj.array_len_ptr();
    }
    if (obj.get_class() == ARGUMENTS) {
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key == null) return 0;
        // Check own properties first for accessor
        int own_idx = obj.find_prop_idx(len_key);
        if (own_idx >= 0) {
            PropFlags pf = obj.get_prop_flags((uint)own_idx);
            if (pf.is_accessor) {
                TVal gs_slot = obj.prop_values()[own_idx];
                TVal getter_fn = hobject::hobject_access_getter(gs_slot);
                return invoke_getter_as_length(obj, getter_fn, heap, ctx);
            }
        }
        TVal? len_val = obj.get_prop(len_key);
        if (try v = len_val) {
            if (v.is_fastint()) return (double)v.get_fastint();
            if (v.is_number()) return v.get_number();
            // Non-numeric (string/bool/null/object): apply ToNumber per ES ToLength
            return builtin_to_number_vm(ctx, &v);
        }
        len_val = obj.get_prop_proto(len_key);
        if (try v = len_val) {
            if (v.is_fastint()) return (double)v.get_fastint();
            if (v.is_number()) return v.get_number();
            return builtin_to_number_vm(ctx, &v);
        }
        return 0;
    }
    // For plain objects and other classes, use get_prop_or_accessor_proto
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (len_key == null) return 0;

    // Check own properties first for accessor
    int own_idx = obj.find_prop_idx(len_key);
    if (own_idx >= 0) {
        PropFlags pf = obj.get_prop_flags((uint)own_idx);
        if (pf.is_accessor) {
            TVal gs_slot = obj.prop_values()[own_idx];
            TVal getter_fn = hobject::hobject_access_getter(gs_slot);
            return invoke_getter_as_length(obj, getter_fn, heap, ctx);
        }
    }

    // Fallback to normal lookup
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto(len_key, true);
    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        TVal getter_fn = res.acc.accessor_fn;
        return invoke_getter_as_length(obj, getter_fn, heap, ctx);
    } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        TVal v = res.data_val;
        if (v.is_fastint()) return (double)v.get_fastint();
        if (v.is_number()) return v.get_number();
        // Non-numeric (string/bool/null/object): apply ToNumber per ES ToLength
        return builtin_to_number_vm(ctx, &v);
    }
    return 0;
}

/// ES2022 §7.1.21 ToLength conversion for array iteration methods.
/// Converts a raw double to a length value per the spec:
///   1. ToIntegerOrInfinity: NaN → 0, +0/-0 → 0, ±Infinity → 0, otherwise truncate
///   2. If len ≤ 0, return 0
///   3. Return min(len, 2^53 − 1)
fn ulong arr_to_length(double raw) {
    // Step 1: ToIntegerOrInfinity
    if (raw != raw) return 0;           // NaN → 0
    if (raw == 0.0) return 0;           // +0 / -0 → 0
    if (raw == double::inf) return (ulong)types::DUK_MAX_SAFE_INT;  // +Infinity → 2^53-1
    if (raw == -double::inf) return 0;  // -Infinity → 0

    // Step 2-3: clamp to [0, 2^53-1]
    if (raw < 0) return 0;
    if (raw > (double)types::DUK_MAX_SAFE_INT) return (ulong)types::DUK_MAX_SAFE_INT;
    return (ulong)raw;
}

/// ES2022 ToLength for Array.prototype iteration methods.
/// Applies ToLength conversion without RangeError validation.
/// NaN → 0, -0 → 0, Infinity → 2^53-1, negative → 0.
/// Returns true on success (out_len set). Returns false if the length getter threw.
fn bool array_to_length(HObject* obj, Heap* heap, BuiltinContext* ctx, ulong* out_len) {
    double raw = array_get_length_raw(obj, heap, ctx);
    // Check if the length getter threw an error
    if (ctx != null && ctx.should_throw) return false;
    *out_len = arr_to_length(raw);
    return true;
}

/// ES5 §15.4.4.x: Read length, convert via ToLength for indexOf/lastIndexOf.
/// ES2022 ToLength: NaN → 0, -0 → 0, negative → 0, Infinity → 2^53-1.
/// indexOf/lastIndexOf use ToLength, not RangeError validation.
fn bool array_to_length_checked(HObject* obj, Heap* heap, BuiltinContext* ctx, ulong* out_len) {
    double raw = array_get_length_raw(obj, heap, ctx);
    // Check if the length getter threw an error
    if (ctx.should_throw) return false;
    // ES2022: use ToLength conversion, no RangeError for -0 or NaN
    *out_len = arr_to_length(raw);
    return true;
}

/// Get the 'length' property of an array-like object as a uint.
/// Uses proper ToUint32 conversion (safe for Infinity, NaN, etc.).
fn uint array_get_length(HObject* obj, Heap* heap) {
    // Fast path: ARRAY uses cached array_length field (no prop table walk).
    if (obj.get_class() == ARRAY) {
        return *obj.array_len_ptr();
    }
    // For non-array objects, read raw and apply ToUint32.
    // Pass null for ctx since we don't need getter invocation here.
    return to_uint32(array_get_length_raw(obj, heap, null));
}

/// Set the 'length' property of an array-like object.
fn void array_set_length(HObject* obj, uint len_val, Heap* heap) {
    // Fast path: ARRAY uses cached array_length field + prop table sync.
    if (obj.get_class() == ARRAY) {
        uint old_len = *obj.array_len_ptr();
        if (len_val < old_len) {
            // Shrinking length: clear any dense-part slots in [len_val, array_size).
            // Clamped to array_size so this loop is always bounded.
            TVal undef; undef.set_undefined();
            uint dense_limit = old_len < obj.array_size ? old_len : obj.array_size;
            for (uint i = len_val; i < dense_limit; i++) {
                obj.set_array_idx(i, undef);
            }
            // Delete named numeric properties that fall in the dropped range.
            // Walk backwards through the property table; delete_prop compacts the
            // table (shifting higher entries down), so scanning backward is safe.
            // Per ES5 §15.4.5.1 step 3.l: if a non-configurable element is found,
            // stop deletion and set the length to one above it (sloppy mode).
            ushort pc = obj.prop_count;
            if (pc > 0) {
                ushort pi = pc;
                while (pi > 0) {
                    pi--;
                    void* pk = obj.prop_key_at((uint)pi);
                    if (pk != null) {
                        HString* pks = (HString*)pk;
                        if (pks.is_arridx()) {
                            uint ai = pks.array_index();
                            if (ai >= len_val) {
                                PropFlags pf = obj.get_prop_flags((uint)pi);
                                if (!pf.configurable) {
                                    // Cannot delete — adjust target length to ai+1.
                                    len_val = ai + 1;
                                    continue;
                                }
                                obj.delete_prop(pk);
                            }
                        }
                    }
                }
            }
        }
        *obj.array_len_ptr() = len_val;
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            int idx = obj.find_prop_idx(len_key);
            if (idx >= 0) {
                TVal tv;
                tv.set_fastint((long)len_val);
                obj.prop_values()[idx] = tv;
                return;
            }
        }
        return;
    }
    // ARGUMENTS: update prop table directly.
    if (obj.get_class() == ARGUMENTS) {
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            int idx = obj.find_prop_idx(len_key);
            if (idx >= 0) {
                TVal tv;
                tv.set_fastint((long)len_val);
                obj.prop_values()[idx] = tv;
                return;
            }
        }
    }
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (len_key == null) return;
    TVal tv;
    tv.set_fastint((long)len_val);
    obj.put_prop(len_key, tv, hobject::PROP_FLAGS_WEC);
}

/// Get array element at numeric index (returns undefined for holes).
/// Checks the dense array part first, then falls back to named properties.
fn TVal array_get_elem(HObject* obj, uint idx, Heap* heap) {
    // Try the dense array part first.
    if (obj.array_part() != null && idx < obj.array_size) {
        TVal v = obj.array_part()[idx];
        if (!v.is_undefined()) return v;
    }
    // Fall back to named property lookup (elements may be stored as named
    // properties via PUTPROP or Object.defineProperty).
    HString* key = heap.int_to_hstring((long)idx);
    if (key == null) { TVal undef; undef.set_undefined(); return undef; }
    TVal? result = obj.get_prop(key);
    if (try v = result) {
        return v;
    }
    TVal? result2 = obj.get_prop_proto(key);
    if (try v2 = result2) {
        return v2;
    }
    TVal undef; undef.set_undefined(); return undef;
}

/// Set array element at numeric index.
/// Only ARRAY and ARGUMENTS classes use the dense array part (O(1) push/append).
/// For all other classes (OBJECT, etc.), writes go through put_prop so that
/// named numeric properties are visible to subsequent reads and not shadowed
/// by a hidden dense part.
fn void array_set_elem(HObject* obj, uint idx, TVal val, Heap* heap, void* vm = null) {
    // Proxy exotic: route through the [[Set]] MOP trap.
    if (obj.flags.exotic_proxyobj) {
        if (vm == null) unreachable("array_set_elem: proxy target requires vm arg");
        HString* key = heap.int_to_hstring((long)idx);
        if (key == null) return;
        TVal recv; recv.set_object(obj);
        bool sres;
        proxy_mop_set(vm, heap, obj, key, val, recv, &sres);
        return;
    }
    if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS)
        && obj.set_array_idx(idx, val)) {
        return;
    }
    HString* key = heap.int_to_hstring((long)idx);
    if (key != null) {
        obj.put_prop(key, val, hobject::PROP_FLAGS_WEC);
    }
}

/// Delete array element at numeric index (set to undefined in dense part).
fn void array_delete_elem(HObject* obj, uint idx, Heap* heap) {
    TVal undef; undef.set_undefined();
    obj.set_array_idx(idx, undef);
}

/// Set array element at a 53-bit numeric index (array-likes may address up
/// to 2^53-2). Indices below 2^32 use the dense-part fast path; larger
/// indices are always named properties.
fn void array_set_elem_ulong(HObject* obj, ulong idx, TVal val, Heap* heap, void* vm = null) {
    if (idx <= 0xFFFFFFFFUL) {
        array_set_elem(obj, (uint)idx, val, heap, vm);
        return;
    }
    // Proxy exotic: route through the [[Set]] MOP trap.
    if (obj.flags.exotic_proxyobj) {
        if (vm == null) unreachable("array_set_elem_ulong: proxy target requires vm arg");
        HString* key = heap.int_to_hstring((long)idx);
        if (key == null) return;
        TVal recv; recv.set_object(obj);
        bool sres;
        proxy_mop_set(vm, heap, obj, key, val, recv, &sres);
        return;
    }
    HString* key = heap.int_to_hstring((long)idx);
    if (key != null) {
        obj.put_prop(key, val, hobject::PROP_FLAGS_WEC);
    }
}

/// Set 'length' on an array-like to a 53-bit value. ARRAY-class objects can
/// never exceed 2^32-1 so they keep the uint fast path; plain array-likes
/// store length as an ordinary numeric property (fastint holds 2^53-1 exactly).
fn void array_set_length_ulong(HObject* obj, ulong len_val, Heap* heap, void* vm = null) {
    // Proxy exotic: Set("length", val, proxy) via [[Set]] trap.
    if (obj.flags.exotic_proxyobj) {
        if (vm == null) return;
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key == null) return;
        TVal tv;
        if (len_val <= (ulong)types::FASTINT_MAX) {
            tv.set_fastint((long)len_val);
        } else {
            tv.set_number((double)len_val);
        }
        TVal recv; recv.set_object(obj);
        bool sres;
        proxy_mop_set(vm, heap, obj, len_key, tv, recv, &sres);
        return;
    }
    if (len_val <= 0xFFFFFFFFUL || obj.get_class() == ARRAY) {
        array_set_length(obj, (uint)len_val, heap);
        return;
    }
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (len_key == null) return;
    TVal tv;
    if (len_val <= (ulong)types::FASTINT_MAX) {
        tv.set_fastint((long)len_val);
    } else {
        tv.set_number((double)len_val);
    }
    obj.put_prop(len_key, tv, hobject::PROP_FLAGS_WEC);
}

/// Strict equality comparison for Array.prototype.indexOf / lastIndexOf.
/// ECMA-262 SameValueNonNumeric semantics: primitives compare by value,
/// heap pointers compare by identity. NaN compares unequal to NaN (per
/// indexOf/lastIndexOf spec, which uses IsStrictlyEqual, not SameValue).
fn bool array_strict_equals(TVal a, TVal b) {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) || math::is_nan(b.get_number())) return false;
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING:    return a.get_heapptr() == b.get_heapptr();
            case OBJECT:
            case BUFFER:
            case POINTER:
            case LIGHTFUNC:
            case BIGINT:
                // Identity comparison: same heap pointer (or same lightfunc slot).
                return a.get_heapptr() == b.get_heapptr();
            default: return false;
        }
    }
    if ((a.is_number() && b.is_fastint()) || (a.is_fastint() && b.is_number())) {
        double av = a.is_fastint() ? (double)a.get_fastint() : a.get_number();
        double bv = b.is_fastint() ? (double)b.get_fastint() : b.get_number();
        return av == bv;
    }
    return false;
}

// ============================================================================
// Array.prototype.toString (ES5 §15.4.4.2)
// ============================================================================
//
// Per ES5 §15.4.4.3: Let func be Get(array, "join").
// If IsCallable(func) is false, set func to Object.prototype.toString.
// Return Call(func, array).
fn void builtin_array_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    // Step 1: Let array be ToObject(this value)
    // For primitives, ToObject creates a wrapper (e.g. Boolean → Boolean wrapper).
    HObject* obj = null;
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        obj = (HObject*)this_val.get_heapptr();
    } else if (this_val.is_null() || this_val.is_undefined()) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Array.prototype.toString called on null or undefined");
        return;
    } else {
        // Box primitive via ToObject
        HObject*? boxed = arr_to_object(this_val, ctx.heap);
        if (try b = boxed) {
            obj = b;
        } else {
            ctx.result.set_undefined();
            return;
        }
    }

    // Step 2: Let func be Get(array, "join")
    HString* join_key = builtin_intern_string(ctx.heap, "join");
    TVal join_fn;
    bool join_found = false;
    if (obj != null) {
        TVal? join_val = obj.get_prop_proto(join_key);
        if (try jv = join_val) {
            join_fn = jv;
            join_found = true;
        }
    }

    // Step 3: If IsCallable(func) is false, set func to Object.prototype.toString
    bool join_callable = false;
    if (join_found) {
        if (join_fn.is_lightfunc()) {
            join_callable = true;
        } else if (join_fn.is_object() && join_fn.get_heapptr() != null) {
            join_callable = ((HObject*)join_fn.get_heapptr()).is_callable();
        }
    }

    if (!join_callable) {
        // Step 3 (ES2022 §22.1.3.30): set func to the *intrinsic* %Object.prototype.toString%.
        // The user may have deleted Object.prototype.toString (see test262
        // built-ins/Array/prototype/toString/non-callable-join-string-tag.js), so we must NOT
        // re-look it up on Object.prototype. Call the built-in function directly: its
        // BuiltinContext dispatch is keyed off the lightfunc ordinal (Builtin.OBJECT_PROTO_TOSTRING),
        // which is the spec-defined "intrinsic" reference and survives property deletion.
        builtin_object_proto_toString(ctx);
        return;
    }

    // Step 4: Return Call(func, array) — call join with the object as this
    if (ctx.heap.call_fn != null && ctx.vm != null) {
        TVal this_tv;
        if (obj != null) {
            this_tv.set_object(obj);
        } else {
            this_tv = this_val;
        }
        *ctx.result = ctx.heap.call_fn(ctx.vm, join_fn, null, 0, this_tv);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
        }
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// Array.prototype.join (ES2022 §23.1.3.15)
// ============================================================================
fn void builtin_array_proto_join(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    // Get separator — §23.1.3.16 step 3: if undefined (or absent), use ",".
    HString* sep_str = null;
    char[] sep = ",";
    if (ctx.argc > 0 && !ctx.regs[ctx.base_reg].is_undefined()) {
        TVal sep_val = ctx.regs[ctx.base_reg];
        // Use full ToString/ToPrimitive so custom valueOf/toString on objects wins.
        sep_str = builtin_to_string_vm(ctx, &sep_val);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (sep_str != null) {
            ((types::HeapHeader*)sep_str).incref();
            sep = sep_str.get_data();
        }
    }

    ulong raw_len;
    if (!array_to_length(obj, ctx.heap, ctx, &raw_len)) { ctx.result.set_undefined(); return; }

    // Empty array-like returns ""
    if (raw_len == 0) {
        if (sep_str != null) ctx.heap.decref((types::HeapHeader*)sep_str);
        HString* result = builtin_intern_string(ctx.heap, "");
        if (result == null) { ctx.result.set_undefined(); return; }
        ctx.result.set_string(result);
        return;
    }

    // Cap length for buffer allocation; huge lengths beyond uint range iterate
    // correctly but only the first capped elements contribute to the join.
    uint len = raw_len > 0x7FFFFFFF ? 0x7FFFFFFF : (uint)raw_len;

    // PASS 1: Collect HString* pointers for each element and sum total length.
    HString*[] elem_strs;
    HString** elem_strs_heap = null;
    const usz STACK_THRESHOLD = 64;

    HString*[64] elem_strs_stack;
    if (len <= STACK_THRESHOLD) {
        elem_strs = elem_strs_stack[:len];
    } else {
        elem_strs_heap = (HString**)ctx.heap.alloc_func(ctx.heap.heap_udata, HString*::size * len);
        if (elem_strs_heap == null) {
            if (sep_str != null) ctx.heap.decref((types::HeapHeader*)sep_str);
            ctx.result.set_undefined();
            return;
        }
        elem_strs = elem_strs_heap[:len];
    }

    usz total_len = 0;
    for (uint i = 0; i < len; i++) {
        TVal elem;
        bool present = arr_get_elem_vm(obj, (ulong)i, ctx.heap, ctx, &elem);
        if (ctx.should_throw) {
            if (sep_str != null) ctx.heap.decref((types::HeapHeader*)sep_str);
            ctx.result.set_undefined(); return;
        }
        HString* elem_str;
        if (!present || elem.is_undefined() || elem.is_null()) {
            elem_str = (HString*)ctx.heap.strs[heap::BuiltinStr.EMPTY];
        } else {
            // Use full ToPrimitive so objects with custom valueOf/toString convert correctly.
            elem_str = builtin_to_string_vm(ctx, &elem);
            if (ctx.should_throw) {
                if (sep_str != null) ctx.heap.decref((types::HeapHeader*)sep_str);
                for (uint j = 0; j < i; j++) ctx.heap.decref((types::HeapHeader*)elem_strs[j]);
                if (elem_strs_heap != null) ctx.heap.free_func(ctx.heap.heap_udata, elem_strs_heap);
                ctx.result.set_undefined(); return;
            }
            if (elem_str == null) {
                elem_str = (HString*)ctx.heap.strs[heap::BuiltinStr.EMPTY];
            }
        }
        ((types::HeapHeader*)elem_str).incref();
        elem_strs[i] = elem_str;
        total_len += elem_str.blen;
    }
    if (len > 1) {
        total_len += sep.len * (usz)(len - 1);
    }

    // PASS 2: Allocate a single buffer and copy all pieces using memcpy.
    // When total_len is 0 (all elements are empty strings and separator is ""),
    // skip the alloc and return "" directly to avoid a null-from-alloc(0) path.
    if (total_len == 0) {
        if (sep_str != null) ctx.heap.decref((types::HeapHeader*)sep_str);
        for (uint i = 0; i < len; i++) {
            ctx.heap.decref((types::HeapHeader*)elem_strs[i]);
        }
        if (elem_strs_heap != null) ctx.heap.free_func(ctx.heap.heap_udata, elem_strs_heap);
        HString* empty = (HString*)ctx.heap.strs[heap::BuiltinStr.EMPTY];
        if (empty == null) { ctx.result.set_undefined(); return; }
        ctx.result.set_string(empty);
        return;
    }

    char* result_buf = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, total_len);
    if (result_buf == null) {
        if (sep_str != null) ctx.heap.decref((types::HeapHeader*)sep_str);
        for (uint i = 0; i < len; i++) {
            ctx.heap.decref((types::HeapHeader*)elem_strs[i]);
        }
        if (elem_strs_heap != null) ctx.heap.free_func(ctx.heap.heap_udata, elem_strs_heap);
        ctx.result.set_undefined();
        return;
    }

    usz offset = 0;
    for (uint i = 0; i < len; i++) {
        if (i > 0) {
            mem::copy(&result_buf[offset], &sep[0], (sz)(sep.len));
            offset += sep.len;
        }
        HString* elem_str = elem_strs[i];
        char[] elem_data = elem_str.get_data();
        if (elem_data.len > 0) {
            mem::copy(&result_buf[offset], &elem_data[0], (sz)(elem_data.len));
            offset += elem_data.len;
        }
    }

    HString* result = builtin_intern_string(ctx.heap, result_buf[:total_len]);
    ctx.heap.free_func(ctx.heap.heap_udata, result_buf);
    if (sep_str != null) ctx.heap.decref((types::HeapHeader*)sep_str);
    for (uint i = 0; i < len; i++) {
        ctx.heap.decref((types::HeapHeader*)elem_strs[i]);
    }
    if (elem_strs_heap != null) {
        ctx.heap.free_func(ctx.heap.heap_udata, elem_strs_heap);
    }

    if (result == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(result);
}

// ============================================================================
// Array.prototype.pop (ES5 §15.4.4.6)
// ============================================================================
fn void builtin_array_proto_pop(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    HString* len_key_pop = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
    if (len == 0) {
        // ES2022 §23.1.3.20 step 3.a: Set(O, "length", 0, true) — throws if non-writable.
        if (!arr_set_length_or_throw(ctx, obj, len_key_pop, 0)) { ctx.result.set_undefined(); return; }
        ctx.result.set_undefined();
        return;
    }

    ulong idx = len - 1;
    TVal elem;
    bool present = arr_get_elem_vm(obj, idx, ctx.heap, ctx, &elem);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (!present) {
        elem.set_undefined();
    }

    // B30 fix: incref the popped element BEFORE the array slot is cleared.
    if (elem.is_heap_allocated() && elem.get_heapptr() != null) {
        ((types::HeapHeader*)elem.get_heapptr()).incref();
    }

    // Delete the last element: named property for all classes, dense part for ARRAY/ARGUMENTS
    arr_delete_elem_or_throw(ctx, obj, idx);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    // ES2022 §23.1.3.20 step 6: Set(O, "length", idx, true) — throws if non-writable.
    if (!arr_set_length_or_throw(ctx, obj, len_key_pop, idx)) { ctx.result.set_undefined(); return; }

    // Return the popped element
    *ctx.result = elem;
}

// ============================================================================
// Array.prototype.push (ES5 §15.4.4.7)
// ============================================================================
fn void builtin_array_proto_push(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    // ES2022 §23.1.3.23 step 1-2: ToObject — throw for null/undefined, box primitives.
    if (this_val.is_null() || this_val.is_undefined()) {
        arr_throw_type_error(ctx, "Array.prototype.push called on null or undefined");
        return;
    }
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    // ES2022 §23.1.3.23 step 4: throw if result length would exceed 2^53-1.
    if (len + (ulong)ctx.argc > (ulong)types::DUK_MAX_SAFE_INT) {
        arr_throw_type_error(ctx, "Pushing would exceed the maximum array length (2^53-1)");
        ctx.result.set_undefined();
        return;
    }

    // Step 5: write each element (spec uses Set, which walks proto chain).
    for (ushort i = 0; i < ctx.argc; i++) {
        TVal arg = ctx.regs[ctx.base_reg + i];
        if (!array_set_elem_ulong_set(ctx, obj, len + (ulong)i, arg)) {
            ctx.result.set_undefined();
            return;
        }
    }

    // Step 6: Set(O, "length", new_len, true) — throws if length is not writable.
    ulong new_len = len + (ulong)ctx.argc;
    HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
    if (!arr_set_length_or_throw(ctx, obj, len_key, new_len)) {
        ctx.result.set_undefined();
        return;
    }

    if (new_len <= (ulong)types::FASTINT_MAX) {
        ctx.result.set_fastint((long)new_len);
    } else {
        ctx.result.set_number((double)new_len);
    }
}

// ============================================================================
// Array.prototype.reverse (ES2022 §23.1.3.27)
// ============================================================================
fn void builtin_array_proto_reverse(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    ulong middle = len / 2;

    for (ulong lower = 0; lower < middle; lower++) {
        ulong upper = len - 1 - lower;

        // ES2022 §23.1.3.27 steps 5.a-5.d: HasProperty then conditional Get,
        // for lower then upper (in that order — matters for Proxy trap order).
        bool has_lower = arr_has_prop(obj, lower, ctx.heap, ctx.vm);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal lower_val;
        if (has_lower) {
            arr_get_elem_vm(obj, lower, ctx.heap, ctx, &lower_val);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        }
        bool has_upper = arr_has_prop(obj, upper, ctx.heap, ctx.vm);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal upper_val;
        if (has_upper) {
            arr_get_elem_vm(obj, upper, ctx.heap, ctx, &upper_val);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        }

        if (has_lower && has_upper) {
            array_set_elem_ulong(obj, lower, upper_val, ctx.heap, ctx.vm);
            array_set_elem_ulong(obj, upper, lower_val, ctx.heap, ctx.vm);
        } else if (has_upper) {
            array_set_elem_ulong(obj, lower, upper_val, ctx.heap, ctx.vm);
            arr_delete_elem_or_throw(ctx, obj, upper);
        } else if (has_lower) {
            arr_delete_elem_or_throw(ctx, obj, lower);
            array_set_elem_ulong(obj, upper, lower_val, ctx.heap, ctx.vm);
        }
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }

    ctx.result.set_object(obj);
}

// ============================================================================
// Array.prototype.shift (ES2022 §23.1.3.27)
// ============================================================================
fn void builtin_array_proto_shift(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    // Step 2: ToLength
    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    HString* len_key_shift = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
    // Step 3: empty array — Set(O, "length", 0, true) throws if non-writable.
    if (len == 0) {
        if (!arr_set_length_or_throw(ctx, obj, len_key_shift, 0)) { ctx.result.set_undefined(); return; }
        ctx.result.set_undefined();
        return;
    }

    // Step 4: Get(0)
    TVal first;
    bool first_present = arr_get_elem_vm(obj, 0, ctx.heap, ctx, &first);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (!first_present) {
        first.set_undefined();
    }
    // B30: incref the returned element so it survives the deletions below
    if (first.is_heap_allocated() && first.get_heapptr() != null) {
        ((types::HeapHeader*)first.get_heapptr()).incref();
    }

    // Steps 5-6: loop k=1..len-1, shift elements left
    for (ulong k = 1; k < len; k++) {
        TVal elem;
        if (arr_get_elem_vm(obj, k, ctx.heap, ctx, &elem)) {
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            array_set_elem_ulong(obj, k - 1, elem, ctx.heap, ctx.vm);
        } else if (ctx.should_throw) {
            ctx.result.set_undefined(); return;
        } else {
            // fromPresent is false: delete target slot (k-1)
            arr_delete_elem_or_throw(ctx, obj, k - 1);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        }
    }

    // Step 7: delete last element (len - 1)
    arr_delete_elem_or_throw(ctx, obj, len - 1);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    // Step 8: Set(O, "length", len - 1, true) — throws if non-writable.
    if (!arr_set_length_or_throw(ctx, obj, len_key_shift, len - 1)) { ctx.result.set_undefined(); return; }

    // Step 9: return first
    *ctx.result = first;
}

// ============================================================================
// Array.prototype.slice (ES5 §15.4.4.10)
// ============================================================================
fn void builtin_array_proto_slice(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    // Determine start
    double relative_start = 0.0;
    if (ctx.argc > 0) {
        relative_start = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }

    ulong k;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        k = tmp < 0 ? 0 : (ulong)(long)tmp;
    } else {
        k = relative_start > (double)len ? len : (ulong)(long)relative_start;
    }

    // Determine end — ES2022 §23.1.3.25 step 6: if end is undefined, use len.
    double relative_end = (double)len;
    if (ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
        relative_end = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }

    ulong final_val;
    if (relative_end < 0) {
        double tmp = (double)len + relative_end;
        final_val = tmp < 0 ? 0 : (ulong)(long)tmp;
    } else {
        final_val = relative_end > (double)len ? len : (ulong)(long)relative_end;
    }

    // ES2022 §23.1.3.24 step 8: ArraySpeciesCreate(O, count).
    // §9.4.2.2 ArrayCreate: if length > 2^32-1, throw RangeError.
    ulong count = final_val > k ? final_val - k : 0;
    if (count > 0xFFFFFFFF) {
        arr_throw_range_error(ctx, "Array length must not exceed 2^32-1");
        ctx.result.set_undefined();
        return;
    }

    // Create result array via ArraySpeciesCreate (ES2022 §23.1.3.24 step 8).
    HObject* result_arr = array_species_create_result(ctx, obj, count);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (result_arr == null) { ctx.result.set_undefined(); return; }

    // ES2022 §23.1.3.24 steps 9-11: n advances every iteration, so holes in
    // the source stay holes at the same relative position in the result, and
    // the final length is the full count even when it ends in holes.
    ulong n = 0;
    for (ulong i = k; i < final_val; i++) {
        if (arr_has_prop(obj, i, ctx.heap, ctx.vm)) {
            TVal v;
            if (arr_get_elem_vm(obj, i, ctx.heap, ctx, &v)) {
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (!array_set_elem_ulong_checked(ctx, result_arr, n, v)) {
                    ctx.result.set_undefined();
                    return;
                }
            }
        }
        n++;
    }
    array_set_length_ulong(result_arr, n, ctx.heap, ctx.vm);

    ctx.result.set_object(result_arr);
}

/// Compare two values for Array.prototype.sort. Handles both explicit
/// comparefn and default string comparison. Sets ctx.should_throw on
/// comparator error and returns 0 in that case.
fn int array_sort_compare(BuiltinContext* ctx, TVal comparefn, bool has_comparefn, TVal a, TVal b) {
    // ES2022 §23.1.3.30 SortCompare step 3-4: undefined always sorts last,
    // regardless of the comparefn (comparefn is never called with undefined).
    bool a_undef = a.is_undefined();
    bool b_undef = b.is_undefined();
    if (a_undef && b_undef) return 0;
    if (a_undef) return 1;
    if (b_undef) return -1;

    int cmp = 0;
    if (has_comparefn && ctx.heap.call_fn != null && ctx.vm != null) {
        TVal[2] args;
        args[0] = a;
        args[1] = b;
        TVal this_val;
        this_val.set_undefined();
        TVal res = ctx.heap.call_fn(ctx.vm, comparefn, &args[0], 2, this_val);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return 0;
        }
        TVal num;
        builtin_to_number(&res, &num);
        if (num.is_number()) {
            double d = num.get_number();
            if (!math::is_nan(d)) {
                cmp = d < 0 ? -1 : (d > 0 ? 1 : 0);
            }
        } else if (num.is_fastint()) {
            long v = num.get_fastint();
            cmp = v < 0 ? -1 : (v > 0 ? 1 : 0);
        }
    } else {
        HString*? a_str_raw = vm::vm_to_string(ctx.vm, &a);
        HString* a_str = a_str_raw ?? builtin_to_string(ctx.heap, &a);
        HString*? b_str_raw = vm::vm_to_string(ctx.vm, &b);
        HString* b_str = b_str_raw ?? builtin_to_string(ctx.heap, &b);
        cmp = hstring::hstring_compare(a_str, b_str);
    }
    return cmp;
}

// ============================================================================
// Array.prototype.sort (ES2022 §23.1.3.30) — with comparefn support
// ============================================================================
fn void builtin_array_proto_sort(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    // ES2022 step 1: check comparefn BEFORE accessing length
    bool has_comparefn = false;
    TVal comparefn;
    comparefn.set_undefined();
    if (ctx.argc > 0) {
        TVal* arg0 = &ctx.regs[ctx.base_reg];
        if (!arg0.is_undefined()) {
            if (!arg0.is_object() || arg0.get_heapptr() == null ||
                !((HObject*)arg0.get_heapptr()).is_callable()) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_str = builtin_intern_string(ctx.heap,
                        "Array.prototype.sort: comparefn is not a function or undefined");
                    if (msg_str != null) {
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
                    }
                    TVal err_tv;
                    err_tv.set_object(err);
                    ctx.throw_value = err_tv;
                }
                ctx.should_throw = true;
                return;
            }
            comparefn = *arg0;
            has_comparefn = true;
        }
    }

    // ES2022 step 3-4: get length via ToLength
    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    if (len <= 1) {
        ctx.result.set_object(obj);
        return;
    }

    // Collect present elements into a C3 buffer.  Holes are skipped here and
    // restored as deletions at the end, which avoids the dense/named-property
    // mismatch that occurs when writing "undefined" into a slot that still has
    // a named property.
    TVal[4096] stack_items;
    TVal[] items;
    if (len > 4096) {
        uint heap_len = len > 0x7FFFFFFF ? 0x7FFFFFFF : (uint)len;
        items = mem::temp_array(TVal, heap_len);
    } else {
        items = stack_items[0:(uint)len];
    }

    ulong present_count = 0;
    for (ulong i = 0; i < len; i++) {
        // Re-read the current length before each collection step.  Getters may
        // have decreased length, in which case indices at or beyond the new
        // length are treated as absent (matching V8's array semantics), while
        // the loop still stops at the originally-captured length so elements
        // appended during collection are not picked up.
        ulong current_len;
        if (!array_to_length(obj, ctx.heap, ctx, &current_len)) { ctx.result.set_undefined(); return; }
        if (i >= current_len) continue;

        if (arr_has_prop(obj, i, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(obj, i, ctx.heap, ctx, &v)) {
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                items[present_count] = v;
                present_count++;
            }
        }
    }

    // Stable bottom-up merge sort on the collected items.
    if (present_count > 1) {
        TVal[4096] stack_temp;
        TVal[] temp;
        if (present_count > 4096) {
            uint heap_count = present_count > 0x7FFFFFFF ? 0x7FFFFFFF : (uint)present_count;
            temp = mem::temp_array(TVal, heap_count);
        } else {
            temp = stack_temp[0:(uint)present_count];
        }

        for (ulong width = 1; width < present_count; width *= 2) {
            for (ulong i = 0; i < present_count; i += 2 * width) {
                ulong left = i;
                ulong mid = i + width < present_count ? i + width : present_count;
                ulong right = i + 2 * width < present_count ? i + 2 * width : present_count;

                // Copy left run into temp buffer.
                for (ulong j = left; j < mid; j++) {
                    temp[j] = items[j];
                }

                // Merge temp[left..mid-1] and items[mid..right-1] back into items.
                ulong l = left;
                ulong r = mid;
                ulong k = left;
                while (l < mid && r < right) {
                    int cmp = array_sort_compare(ctx, comparefn, has_comparefn, temp[l], items[r]);
                    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                    if (cmp <= 0) {
                        items[k] = temp[l];
                        l++;
                    } else {
                        items[k] = items[r];
                        r++;
                    }
                    k++;
                }
                while (l < mid) {
                    items[k] = temp[l];
                    l++; k++;
                }
                while (r < right) {
                    items[k] = items[r];
                    r++; k++;
                }
            }
        }
    }

    // Write sorted present elements back to indices 0..present_count-1 using
    // [[Set]] semantics so that accessor setters are invoked.
    for (ulong i = 0; i < present_count; i++) {
        if (!array_set_elem_ulong_set(ctx, obj, i, items[i])) {
            ctx.result.set_undefined();
            return;
        }
    }

    // Delete trailing slots so holes remain holes (ES2022 §23.1.3.30 step 9).
    for (ulong i = present_count; i < len; i++) {
        if (!array_delete_elem_ulong_checked(ctx, obj, i)) {
            ctx.result.set_undefined();
            return;
        }
    }

    // The spec does not set length after sorting; any side effects from
    // getters/setters during the sort are allowed to persist.
    ctx.result.set_object(obj);
}

// ============================================================================
// Array.prototype.splice (ES5 §15.4.4.12)
// ============================================================================
fn void builtin_array_proto_splice(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length_checked(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    // Get relativeStart (argument 0)
    double relative_start = 0.0;
    if (ctx.argc > 0) {
        relative_start = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }

    ulong actual_start;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        actual_start = tmp < 0 ? 0 : (ulong)(long)tmp;
    } else {
        actual_start = relative_start >= (double)len ? len : (ulong)(long)relative_start;
    }

    // Get actualDeleteCount
    ulong actual_delete_count;
    if (ctx.argc == 0) {
        // ES2022 §23.1.3.28 step 8: when no arguments at all, insertCount = 0
        // and actualDeleteCount = 0 — splice is a no-op that just returns an
        // empty result array and writes the (possibly ToLength-clamped)
        // length back to O.
        actual_delete_count = 0;
    } else {
        // ES2022 §23.1.3.28 step 9-10: 1 arg (only start) → actualDeleteCount
        // = len - actualStart; ≥2 args → min(max(dc, 0), len - actualStart).
        if (ctx.argc == 1) {
            actual_delete_count = len - actual_start;
        } else {
            double delete_count = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (delete_count < 0) delete_count = 0;
            ulong dc = (ulong)(long)delete_count;
            actual_delete_count = dc > (len - actual_start) ? (len - actual_start) : dc;
        }
    }

    // Get items to insert
    ushort item_count = 0;
    if (ctx.argc > 2) {
        item_count = ctx.argc - 2;
    }

    // ES2022 §23.1.3.28 step 11: throw before any mutation if the resulting
    // length would exceed 2^53-1.
    if (len - actual_delete_count + (ulong)item_count > (ulong)types::DUK_MAX_SAFE_INT) {
        arr_throw_type_error(ctx, "Splicing would exceed the maximum array length (2^53-1)");
        ctx.result.set_undefined();
        return;
    }

    // Create result array with deleted items via ArraySpeciesCreate.
    // Note: the RangeError for actualDeleteCount > 2^32-1 is thrown by
    // ArrayCreate inside ArraySpeciesCreate (when no species constructor is
    // provided), NOT here. When a species constructor IS provided, it
    // receives the raw length and handles it.
    HObject* result = array_species_create_result(ctx, obj, actual_delete_count);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (result == null) { ctx.result.set_undefined(); return; }

    for (ulong i = 0; i < actual_delete_count; i++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal elem;
        if (arr_has_prop(obj, actual_start + i, ctx.heap, ctx.vm)) {
            if (arr_get_elem_vm(obj, actual_start + i, ctx.heap, ctx, &elem)) {
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (!array_set_elem_ulong_checked(ctx, result, i, elem)) {
                    ctx.result.set_undefined();
                    return;
                }
            }
        }
    }
    array_set_length_ulong(result, actual_delete_count, ctx.heap, ctx.vm);

    // Shift elements left or right
    if (item_count < actual_delete_count) {
        ulong shift_len = len - actual_start - actual_delete_count;
        for (ulong k = 0; k < shift_len; k++) {
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            TVal elem;
            ulong from_idx = actual_start + actual_delete_count + k;
            ulong to_idx = actual_start + item_count + k;
            if (arr_has_prop(obj, from_idx, ctx.heap, ctx.vm)) {
                if (arr_get_elem_vm(obj, from_idx, ctx.heap, ctx, &elem)) {
                    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                    if (!array_set_elem_ulong_checked(ctx, obj, to_idx, elem)) {
                        ctx.result.set_undefined();
                        return;
                    }
                }
            } else {
                // ES2022 §23.1.3.28 step 15.b.v: DeletePropertyOrThrow(O, to).
                if (!array_delete_elem_ulong_checked(ctx, obj, to_idx)) {
                    ctx.result.set_undefined();
                    return;
                }
            }
        }
        ulong new_len = len - actual_delete_count + item_count;
        for (ulong k = new_len; k < len; k++) {
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (!array_delete_elem_ulong_checked(ctx, obj, k)) {
                ctx.result.set_undefined();
                return;
            }
        }
        HString* splice_len_key1 = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        if (!arr_set_length_or_throw(ctx, obj, splice_len_key1, new_len)) {
            ctx.result.set_undefined(); return;
        }
    } else if (item_count > actual_delete_count) {
        ulong shift_len = len - actual_start - actual_delete_count;
        for (ulong k = shift_len; k > 0; k--) {
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            ulong from = actual_start + actual_delete_count + k - 1;
            ulong to = actual_start + item_count + k - 1;
            TVal elem;
            if (arr_has_prop(obj, from, ctx.heap, ctx.vm)) {
                if (arr_get_elem_vm(obj, from, ctx.heap, ctx, &elem)) {
                    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                    if (!array_set_elem_ulong_checked(ctx, obj, to, elem)) {
                        ctx.result.set_undefined();
                        return;
                    }
                }
            } else {
                // ES2022 §23.1.3.28 step 16.b.v: DeletePropertyOrThrow(O, to).
                if (!array_delete_elem_ulong_checked(ctx, obj, to)) {
                    ctx.result.set_undefined();
                    return;
                }
            }
        }
        HString* splice_len_key2 = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        ulong new_len2 = len - actual_delete_count + (ulong)item_count;
        if (!arr_set_length_or_throw(ctx, obj, splice_len_key2, new_len2)) {
            ctx.result.set_undefined(); return;
        }
    } else {
        // item_count == actual_delete_count: no shift needed, but must still
        // write length back (spec step 24: Set(O, "length", len-adc+ic, true))
        // so out-of-range lengths get clamped and accessor setters are invoked.
        ulong new_len3 = len - actual_delete_count + (ulong)item_count;
        HString* splice_len_key3 = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
        if (!arr_set_length_or_throw(ctx, obj, splice_len_key3, new_len3)) {
            ctx.result.set_undefined(); return;
        }
    }

    // Insert new items
    for (ushort i = 0; i < item_count; i++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal item = ctx.regs[ctx.base_reg + 2 + i];
        if (!array_set_elem_ulong_checked(ctx, obj, actual_start + i, item)) {
            ctx.result.set_undefined();
            return;
        }
    }

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.toReversed (ES2023 §23.1.3.33)
// ============================================================================
fn void builtin_array_proto_toReversed(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toReversed called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    for (ulong i = 0; i < len; i++) {
        TVal elem;
        if (arr_get_elem_vm(obj, len - 1 - i, ctx.heap, ctx, &elem)) {
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            array_set_elem_ulong(result, i, elem, ctx.heap);
        }
    }
    array_set_length_ulong(result, len, ctx.heap, ctx.vm);

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.toSorted (ES2023 §23.1.3.34) — default compare (no comparefn)
// ============================================================================
fn void builtin_array_proto_toSorted(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toSorted called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    ulong raw_len;
    if (!array_to_length(obj, ctx.heap, ctx, &raw_len)) { ctx.result.set_undefined(); return; }
    uint len = raw_len > 0x7FFFFFFF ? 0x7FFFFFFF : (uint)raw_len;

    // Create a copy
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    for (uint i = 0; i < len; i++) {
        TVal elem;
        if (arr_get_elem_vm(obj, (ulong)i, ctx.heap, ctx, &elem)) {
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            array_set_elem(result, i, elem, ctx.heap);
        }
    }
    array_set_length(result, len, ctx.heap);

    // Compact defined elements to the front
    uint def_count = 0;
    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(result, i, ctx.heap);
        if (!elem.is_undefined()) {
            array_set_elem(result, def_count, elem, ctx.heap);
            def_count++;
        }
    }

    // Bubble-sort defined elements by string comparison
    for (uint i = 0; i < def_count; i++) {
        for (uint j = 0; j < def_count - 1 - i; j++) {
            TVal a = array_get_elem(result, j, ctx.heap);
            TVal b = array_get_elem(result, j + 1, ctx.heap);
            HString* a_str = builtin_to_string(ctx.heap, &a);
            HString* b_str = builtin_to_string(ctx.heap, &b);
            int cmp = 0;
            if (a_str != null && b_str != null) {
                cmp = hstring::hstring_compare(a_str, b_str);
            } else if (a_str == null && b_str == null) {
                cmp = 0;
            } else if (a_str == null) {
                cmp = 1;
            } else {
                cmp = -1;
            }
            if (cmp > 0) {
                array_set_elem(result, j, b, ctx.heap);
                array_set_elem(result, j + 1, a, ctx.heap);
            }
        }
    }

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.toSpliced (ES2023 §23.1.3.35)
// ============================================================================
fn void builtin_array_proto_toSpliced(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toSpliced called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    // Get relativeStart (argument 0)
    double relative_start = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.is_fastint()) {
            relative_start = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_start = arg.get_number();
        }
    }

    ulong actual_start;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        actual_start = tmp < 0 ? 0 : (ulong)(long)tmp;
    } else {
        actual_start = relative_start > (double)len ? len : (ulong)(long)relative_start;
    }

    // Get actualDeleteCount
    ulong actual_delete_count;
    if (ctx.argc <= 1) {
        actual_delete_count = len - actual_start;
    } else {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        double delete_count;
        if (arg.is_fastint()) {
            delete_count = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            delete_count = arg.get_number();
        } else {
            delete_count = 0;
        }

        if (delete_count < 0) delete_count = 0;
        ulong dc = (ulong)(long)delete_count;
        actual_delete_count = dc > (len - actual_start) ? (len - actual_start) : dc;
    }

    // Get items to insert
    ushort item_count = 0;
    if (ctx.argc > 2) {
        item_count = ctx.argc - 2;
    }

    // Create new array: prefix + items + suffix
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    ulong n = 0;
    // Copy prefix [0, actual_start)
    for (ulong i = 0; i < actual_start; i++) {
        TVal elem;
        if (arr_get_elem_vm(obj, i, ctx.heap, ctx, &elem)) {
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            array_set_elem_ulong(result, n, elem, ctx.heap);
            n++;
        }
    }
    // Insert new items
    for (ushort i = 0; i < item_count; i++) {
        TVal item = ctx.regs[ctx.base_reg + 2 + i];
        array_set_elem_ulong(result, n, item, ctx.heap);
        n++;
    }
    // Copy suffix [actual_start + actual_delete_count, len)
    for (ulong i = actual_start + actual_delete_count; i < len; i++) {
        TVal elem;
        if (arr_get_elem_vm(obj, i, ctx.heap, ctx, &elem)) {
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            array_set_elem_ulong(result, n, elem, ctx.heap);
            n++;
        }
    }
    array_set_length_ulong(result, n, ctx.heap, ctx.vm);

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.with (ES2023 §23.1.3.37)
// ============================================================================
fn void builtin_array_proto_with(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.with called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    // Get index using ToIntegerOrInfinity
    double index_d = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        index_d = builtin_to_integer_vm(ctx, arg);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }

    ulong actual_index;
    if (index_d < 0) {
        double tmp = (double)len + index_d;
        if (tmp < 0) {
            actual_index = len; // Out of range
        } else {
            actual_index = (ulong)(long)tmp;
        }
    } else if (index_d < (double)len) {
        actual_index = (ulong)(long)index_d;
    } else {
        actual_index = len; // Out of range (includes NaN, Infinity, >= len)
    }

    if (actual_index >= len) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.range_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Invalid array index");
            TVal msg_tv; msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        return;
    }

    // Get value to set
    TVal new_val;
    if (ctx.argc > 1) {
        new_val = ctx.regs[ctx.base_reg + 1];
    } else {
        new_val.set_undefined();
    }

    // Create new array
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    for (ulong i = 0; i < len; i++) {
        if (i == actual_index) {
            array_set_elem_ulong(result, i, new_val, ctx.heap);
        } else {
            TVal elem;
            if (arr_get_elem_vm(obj, i, ctx.heap, ctx, &elem)) {
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                array_set_elem_ulong(result, i, elem, ctx.heap);
            }
        }
    }
    array_set_length_ulong(result, len, ctx.heap, ctx.vm);

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.unshift (ES5 §15.4.4.13)
// ============================================================================
fn void builtin_array_proto_unshift(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    ushort arg_count = ctx.argc;

    // ES2022 §23.1.3.31 step 4: with no arguments there is nothing to shift
    // and no overflow to check — length is just re-clamped below.
    if (arg_count > 0) {
        // Step 4.a: throw before any element is moved.
        if (len + (ulong)arg_count > (ulong)types::DUK_MAX_SAFE_INT) {
            arr_throw_type_error(ctx, "Unshifting would exceed the maximum array length (2^53-1)");
            ctx.result.set_undefined();
            return;
        }

        // Shift existing elements right by arg_count using full [[Set]] semantics
        // (invokes prototype chain setters, checks writable, handles holes).
        for (ulong k = len; k > 0; k--) {
            ulong from = k - 1;
            ulong to = k - 1 + arg_count;
            TVal elem;
            if (arr_get_elem_vm(obj, from, ctx.heap, ctx, &elem)) {
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (!array_set_elem_ulong_set(ctx, obj, to, elem)) {
                    ctx.result.set_undefined(); return;
                }
            } else {
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                // Source is a hole — delete the destination element.
                if (!array_delete_elem_ulong_checked(ctx, obj, to)) {
                    ctx.result.set_undefined(); return;
                }
            }
        }

        // Insert new items at the beginning using full [[Set]] semantics.
        for (ushort i = 0; i < arg_count; i++) {
            TVal arg = ctx.regs[ctx.base_reg + i];
            if (!array_set_elem_ulong_set(ctx, obj, (ulong)i, arg)) {
                ctx.result.set_undefined(); return;
            }
        }
    }

    ulong new_len = len + (ulong)arg_count;
    HString* unshift_len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
    if (!arr_set_length_or_throw(ctx, obj, unshift_len_key, new_len)) {
        ctx.result.set_undefined(); return;
    }

    if (new_len <= (ulong)types::FASTINT_MAX) {
        ctx.result.set_fastint((long)new_len);
    } else {
        ctx.result.set_number((double)new_len);
    }
}

// ============================================================================
// Array.prototype.indexOf (ES5 §15.4.4.14)
// ============================================================================
fn void builtin_array_proto_indexOf(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length_checked(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    // ES2022 §23.1.3.12 step 3: If len is 0, return -1.
    // Done before ToInteger(fromIndex) so side-effect order tests (e.g.
    // `length-zero-returns-minus-one.js`) don't trigger fromIndex's valueOf.
    if (len == 0) {
        ctx.result.set_fastint(-1);
        return;
    }

    // Per spec, when searchElement is missing we use undefined, not -1.
    TVal search_elem;
    if (ctx.argc > 0) {
        search_elem = ctx.regs[ctx.base_reg];
    } else {
        search_elem.set_undefined();
    }

    // Get fromIndex (default 0) — per ES5 §15.4.4.14 step 3.
    // builtin_to_integer handles Infinity / -Infinity / NaN / hex strings.
    double relative_start = 0.0;
    if (ctx.argc > 1) {
        relative_start = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }

    // Per ES5 §15.4.4.14 step 4: compute k from n (ToInteger of fromIndex).
    // If n ≥ len → return -1 (handles Infinity cleanly).
    // If n < 0 → k = max(len + n, 0) (n is finite here, since Infinity already returned).
    // Else → k = n.
    if (relative_start >= (double)len) {
        ctx.result.set_fastint(-1);
        return;
    }

    ulong k;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        k = tmp < 0 ? 0 : (ulong)(long)tmp;
    } else {
        k = (ulong)(long)relative_start;
    }

    for (; k < len; k++) {
        TVal v;
        // arr_get_elem_vm returns false if the element is missing OR if the
        // getter threw (sets ctx.should_throw). Spec: terminate iteration on
        // an unhandled exception (tests 15.4.4.14-9-b-i-30/31).
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (arr_get_elem_vm(obj, k, ctx.heap, ctx, &v)) {
            if (array_strict_equals(v, search_elem)) {
                // Indices can exceed the 48-bit fastint range (up to 2^53-1),
                // so use set_number for large values to avoid silent truncation.
                if (k <= (ulong)types::FASTINT_MAX) {
                    ctx.result.set_fastint((long)k);
                } else {
                    ctx.result.set_number((double)k);
                }
                return;
            }
        }
    }

    ctx.result.set_fastint(-1);
}

// ============================================================================
// Array.prototype.lastIndexOf (ES5 §15.4.4.15)
// ============================================================================
fn void builtin_array_proto_lastIndexOf(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ulong len;
    if (!array_to_length_checked(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    // ES2022 §23.1.3.13 step 3: If len is 0, return -1.
    // Done before ToInteger(fromIndex) so side-effect order tests don't
    // trigger fromIndex's valueOf.
    if (len == 0) {
        ctx.result.set_fastint(-1);
        return;
    }

    // Per spec, when searchElement is missing we use undefined, not -1.
    TVal search_elem;
    if (ctx.argc > 0) {
        search_elem = ctx.regs[ctx.base_reg];
    } else {
        search_elem.set_undefined();
    }

    // Get fromIndex (default len - 1) — per ES5 §15.4.4.15 step 3.
    double relative_start = (double)(len - 1);
    if (ctx.argc > 1) {
        relative_start = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }

    // Per ES5 §15.4.4.15 step 4: compute k from n (ToInteger of fromIndex).
    // If n ≥ len → k = len - 1 (handles Infinity correctly).
    // If n < 0 → k = len + n. If len+n < 0 → no match (-1).
    // Else → k = min(n, len - 1).
    // Note: len == 0 means k starts at -1 → loop doesn't execute → -1.
    long k;
    if (relative_start >= (double)len) {
        k = (long)len - 1;
    } else if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        k = tmp < 0 ? -1 : (long)tmp;
    } else {
        k = (long)relative_start;
    }

    for (; k >= 0; k--) {
        TVal v;
        // arr_get_elem_vm returns false if the element is missing OR if the
        // getter threw (sets ctx.should_throw). Spec: terminate iteration on
        // an unhandled exception.
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (arr_get_elem_vm(obj, (ulong)k, ctx.heap, ctx, &v)) {
            if (array_strict_equals(v, search_elem)) {
                // Indices can exceed the 48-bit fastint range (up to 2^53-1),
                // so use set_number for large values to avoid silent truncation.
                if ((ulong)k <= (ulong)types::FASTINT_MAX) {
                    ctx.result.set_fastint(k);
                } else {
                    ctx.result.set_number((double)k);
                }
                return;
            }
        }
    }

    ctx.result.set_fastint(-1);
}

// ============================================================================
// Array.prototype.concat (ES6 §22.1.3.1 — with Symbol.isConcatSpreadable)
// ============================================================================
fn void builtin_array_proto_concat(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    // Create result array via ArraySpeciesCreate (ES2022 §23.1.3.1 step 1).
    HObject* result = array_species_create_result(ctx, obj, 0);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    if (result == null) { ctx.result.set_undefined(); return; }

    ulong n = 0;

    // ES2022 §23.1.3.1 step 5: items = [O, ...args]. Process each item via
    // the shared IsConcatSpreadable path so 'this' follows the same rules
    // as arguments (non-Array 'this' becomes a single element).
    HString* concat_sym = ensure_concatspreadable_symbol(ctx.heap);

    TVal this_tv; this_tv.set_object(obj);
    if (!concat_process_item(ctx, this_tv, concat_sym, result, &n)) {
        ctx.result.set_undefined();
        return;
    }
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }

    for (ushort arg_i = 0; arg_i < ctx.argc; arg_i++) {
        TVal arg = ctx.regs[ctx.base_reg + arg_i];
        if (!concat_process_item(ctx, arg, concat_sym, result, &n)) {
            ctx.result.set_undefined();
            return;
        }
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    }

    array_set_length_ulong(result, n, ctx.heap, ctx.vm);

    ctx.result.set_object(result);
}

/// Process one item for Array.prototype.concat (ES2022 §23.1.3.1 step 5).
/// `item` may be a primitive or an object. Returns false when a pending throw
/// must abort the caller (ctx.should_throw is set).
fn bool concat_process_item(BuiltinContext* ctx, TVal item, HString* concat_sym,
                            HObject* result, ulong* n_ptr) {
    ulong n = *n_ptr;

    if (!item.is_object() || item.get_heapptr() == null) {
        // Primitive — add as single element (§23.1.3.1 step 5.d.ii).
        if (n >= (ulong)types::DUK_MAX_SAFE_INT) {
            arr_throw_type_error(ctx, "Concatenating would exceed the maximum array length (2^53-1)");
            return false;
        }
        // CreateDataPropertyOrThrow — throws TypeError on a non-extensible
        // (species-created) result rather than silently dropping the element.
        if (!array_set_elem_ulong_checked(ctx, result, n, item)) return false;
        n++;
        *n_ptr = n;
        return true;
    }

    HObject* item_obj = (HObject*)item.get_heapptr();

    // ES2022 §23.1.3.1 step 5.b: spreadable = IsConcatSpreadable(E)
    // 5.b.ii: Get(E, @@isConcatSpreadable) — use full Get semantics so
    //         accessor getters are invoked and their throws propagate.
    // 5.b.iii: If undefined, fall back to IsArray(E) — §7.2.2 IsArray recurses
    //          through proxy targets; revoked proxy → TypeError.
    bool spread;
    bool is_array;
    if (item_obj.flags.exotic_proxyobj) {
        if (!proxy_is_array(ctx.heap, item_obj, &is_array)) {
            proxy_ctx_ok(ctx);
            return false;
        }
    } else {
        is_array = (item_obj.get_class() == hobject::ObjClass.ARRAY);
    }
    if (concat_sym != null) {
        TVal? spreadable_val = builtins_generic_get(item_obj, concat_sym, ctx);
        if (ctx.should_throw) return false;
        if (try sv = spreadable_val) {
            spread = sv.is_undefined() ? is_array : builtin_to_boolean(&sv);
        } else {
            spread = is_array;
        }
    } else {
        spread = is_array;
    }

    if (spread) {
        ulong item_len;
        if (!array_to_length(item_obj, ctx.heap, ctx, &item_len)) return false;
        if (n + item_len > (ulong)types::DUK_MAX_SAFE_INT) {
            arr_throw_type_error(ctx, "Concatenating would exceed the maximum array length (2^53-1)");
            return false;
        }
        for (ulong i = 0; i < item_len; i++) {
            if (ctx.should_throw) return false;
            if (arr_has_prop(item_obj, i, ctx.heap)) {
                TVal elem;
                if (arr_get_elem_vm(item_obj, i, ctx.heap, ctx, &elem)) {
                    // ES2022 §23.1.3.1 step 5.c.iv.3.b: CreateDataPropertyOrThrow
                    if (!array_set_elem_ulong_checked(ctx, result, n, elem)) return false;
                }
            }
            n++;
        }
    } else {
        if (n >= (ulong)types::DUK_MAX_SAFE_INT) {
            arr_throw_type_error(ctx, "Concatenating would exceed the maximum array length (2^53-1)");
            return false;
        }
        // ES2022 §23.1.3.1 step 5.d.ii: CreateDataPropertyOrThrow
        if (!array_set_elem_ulong_checked(ctx, result, n, item)) return false;
        n++;
    }

    *n_ptr = n;
    return true;
}

/// Helper: is `v` callable (lightfunc or object with the callable flag)?
/// Used throughout Array.from for IsCallable checks on mapfn/@@iterator/next.
fn bool arr_from_is_callable(TVal v) {
    if (v.is_lightfunc()) return true;
    if (v.is_object() && v.get_heapptr() != null) {
        return ((HObject*)v.get_heapptr()).is_callable();
    }
    return false;
}

/// IteratorClose(iterator, completion) — ES2022 §7.4.8, "poor man's" variant
/// used when abandoning iteration early due to an abrupt completion that has
/// already been recorded in ctx (ctx.should_throw/ctx.throw_value). Calls
/// iterator.return() if present, discarding *its* result but propagating a
/// throw from close itself would override the original completion per spec
/// step 5 — however we keep the original completion (matching most engines'
/// pragmatic behavior for a non-throwing return()) since ctx already holds
/// the completion to propagate. If close() throws, the original completion
/// is preserved (spec step 5 says close()'s throw masks the original only
/// when the original was a normal completion, which is not this call site's
/// use — this helper is only invoked to close on an *abrupt* completion).
fn void arr_iterator_close_after_throw(BuiltinContext* ctx, TVal iterator) {
    if (ctx.heap.call_fn == null || ctx.vm == null) return;
    if (!iterator.is_object() || iterator.get_heapptr() == null) return;
    HObject* iter_obj = (HObject*)iterator.get_heapptr();
    HString* return_key = builtin_intern_string(ctx.heap, "return");
    if (return_key == null) return;
    TVal? return_method_opt = iter_obj.get_prop_proto(return_key);
    if (try return_method = return_method_opt) {
        if (return_method.is_undefined() || return_method.is_null()) return;
        if (!arr_from_is_callable(return_method)) return;
        ctx.heap.call_fn(ctx.vm, return_method, null, 0, iterator);
        // Swallow any error from return() itself — the original abrupt
        // completion already recorded in ctx takes precedence.
        ctx.heap.has_error = false;
    }
}

/// Set(O, "length", value, true) — ES2022 §7.3.4, restricted to the
/// "length" key on the Array.from result object A. Unlike arr_create_data_
/// property_or_throw (which bypasses the prototype chain), this honours an
/// inherited accessor setter for "length" — needed when A came from a custom
/// constructor whose .prototype defines a length setter. Returns true on
/// success; on failure sets ctx.should_throw and returns false.
fn bool arr_set_length_or_throw(BuiltinContext* ctx, HObject* obj, HString* len_key, ulong len_val) {
    // Proxy exotic: Set("length", val, proxy) via the [[Set]] MOP trap.
    if (obj.flags.exotic_proxyobj) {
        if (ctx == null || ctx.vm == null) return false;
        TVal len_tv2;
        if (len_val <= (ulong)types::FASTINT_MAX) {
            len_tv2.set_fastint((long)len_val);
        } else {
            len_tv2.set_number((double)len_val);
        }
        TVal recv; recv.set_object(obj);
        bool sres;
        if (!proxy_mop_set(ctx.vm, ctx.heap, obj, len_key, len_tv2, recv, &sres)) {
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
            }
            return false;
        }
        if (!sres) {
            arr_throw_type_error(ctx, "Cannot set property length on proxy");
            return false;
        }
        return true;
    }

    // ES2022 §10.4.2.4 ArraySetLength: ToUint32(len_val) must equal len_val.
    if (obj.get_class() == hobject::ObjClass.ARRAY && len_val > 0xFFFFFFFFUL) {
        arr_throw_range_error(ctx, "Invalid array length");
        return false;
    }

    // ES2022 §10.4.2.1 ArraySetLength step 3.a: if the exotic "length" is
    // non-writable and the new length differs from the current length,
    // return false (callers translate to TypeError). The prop-table branch
    // below handles the case where "length" is a named property; this
    // guards the ARRAY-only path where length lives in array_len_ptr and
    // no named property exists (e.g. arrays produced by new Array(n) where
    // the descriptor {writable:false} or freeze never materialised a
    // prop-table entry).
    if (obj.get_class() == hobject::ObjClass.ARRAY && !obj.flags.array_len_writable) {
        uint cur_len = *obj.array_len_ptr();
        if (len_val != (ulong)cur_len) {
            arr_throw_type_error(ctx, "Cannot assign to read-only property 'length'");
            return false;
        }
    }

    TVal len_tv;
    if (len_val <= 0x7FFFFFFF) {
        len_tv.set_fastint((long)len_val);
    } else {
        len_tv.set_number((double)len_val);
    }

    // Own property "length" check.
    int own_idx = obj.find_prop_idx(len_key);
    if (own_idx >= 0) {
        hobject::PropFlags cur_flags = obj.get_prop_flags((uint)own_idx);
        if (cur_flags.is_accessor) {
            // Own accessor: invoke the setter, or throw if getter-only.
            TVal gs_slot = obj.prop_values()[own_idx];
            TVal setter_fn = hobject::hobject_access_setter(gs_slot);
            if (setter_fn.is_undefined() || setter_fn.is_null()) {
                arr_throw_type_error(ctx, "Cannot set property length, has only a getter");
                return false;
            }
            if (ctx.heap.call_fn == null || ctx.vm == null) return true;
            TVal this_tv; this_tv.set_object(obj);
            TVal[1] args = { len_tv };
            ctx.heap.call_fn(ctx.vm, setter_fn, &args[0], 1, this_tv);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return false;
            }
            return true;
        }
        // Own data property: reject if non-writable (Set with Throw=true).
        if (!cur_flags.writable) {
            arr_throw_type_error(ctx, "Cannot assign to read-only property 'length'");
            return false;
        }
        // Update value, preserving existing flags.
        if (!obj.put_prop(len_key, len_tv, cur_flags)) {
            arr_throw_type_error(ctx, "Cannot set property length, no space left");
            return false;
        }
        return true;
    }

    // No own property: check the prototype chain for an inherited accessor
    // before falling back to defining a new own data property (Set()'s
    // OrdinarySet walks the chain first per ES2022 §10.1.9.2).
    hobject::AccessorResult acc = obj.find_accessor_proto(len_key, false);
    if (acc.found) {
        if (acc.accessor_fn.is_undefined() || acc.accessor_fn.is_null()) {
            arr_throw_type_error(ctx, "Cannot set property length, has only a getter");
            return false;
        }
        if (ctx.heap.call_fn == null || ctx.vm == null) return true;
        TVal this_tv; this_tv.set_object(obj);
        TVal[1] args = { len_tv };
        ctx.heap.call_fn(ctx.vm, acc.accessor_fn, &args[0], 1, this_tv);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return false;
        }
        return true;
    }

    // No accessor anywhere on the chain (no own property or inherited data
    // property) — define as a new own data property on obj.
    if (!obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC)) {
        arr_throw_type_error(ctx, "Cannot set property length, no space left");
        return false;
    }
    return true;
}

/// Array.from ( items [ , mapfn [ , thisArg ] ] ) — ES2022 §23.1.2.1
fn void builtin_array_from(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Step 1: Let C be the this value.
    TVal c_val = ctx.this_val;

    // Step 2: items (first arg) — use undefined if missing
    TVal items;
    if (ctx.argc > 0) {
        items = ctx.regs[ctx.base_reg];
    } else {
        items.set_undefined();
    }

    // Step 3-4: mapfn (second arg, optional). If not undefined, must be
    // callable — TypeError otherwise. This check (and thisArg capture) must
    // happen before any iteration/construction.
    TVal mapfn;
    bool mapping = false;
    TVal this_arg;
    this_arg.set_undefined();
    if (ctx.argc > 1) {
        mapfn = ctx.regs[ctx.base_reg + 1];
        if (!mapfn.is_undefined()) {
            if (!arr_from_is_callable(mapfn)) {
                arr_throw_type_error(ctx, "The second argument to Array.from is not callable");
                ctx.result.set_undefined();
                return;
            }
            mapping = true;
            if (ctx.argc > 2) {
                this_arg = ctx.regs[ctx.base_reg + 2];
            }
        }
    }

    // Step 5-6: usingIterator = GetMethod(items, @@iterator).
    HString* iter_sym = ensure_iterator_symbol(heap);
    TVal iter_method;
    iter_method.set_undefined();
    bool have_iter_method = false;

    if (iter_sym != null) {
        // GetMethod(items, @@iterator) — ToObject if needed for property access
        HObject* items_obj = null;
        if (items.is_object() && items.get_heapptr() != null) {
            items_obj = (HObject*)items.get_heapptr();
        } else if (!items.is_undefined() && !items.is_null()) {
            // Wrap primitive in temporary object to look up @@iterator
            HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try w = wrapped) {
                items_obj = w;
                // For strings, set the wrapped primitive value
                if (items.is_string()) {
                    (*items_obj.extra_ptr()).prim.primitive_value = items;
                }
                HString* proto_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
                if (proto_key != null && heap.string_proto != null) {
                    TVal proto_tv; proto_tv.set_object(heap.string_proto);
                    PropFlags pf; pf.writable = false; pf.enumerable = false; pf.configurable = false; pf.is_accessor = false;
                    items_obj.put_prop(proto_key, proto_tv, pf);
                }
            }
        }

        if (items_obj != null) {
            TVal? iter_method_opt = builtins_generic_get(items_obj, iter_sym, ctx);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (try im = iter_method_opt) {
                if (!im.is_undefined() && !im.is_null()) {
                    iter_method = im;
                    have_iter_method = true;
                }
            }
        }
    }

    if (have_iter_method) {
        // === Iterable path — ES2022 §23.1.2.1 step 6 ===
        if (!arr_from_is_callable(iter_method)) {
            arr_throw_type_error(ctx, "Result of the Symbol.iterator method is not callable");
            ctx.result.set_undefined();
            return;
        }
        if (heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return; }

        // 6.a-c: If IsConstructor(C), let A be Construct(C); else ArrayCreate(0).
        // This runs BEFORE GetIterator (6.d) per spec order — a throwing
        // constructor must propagate without ever creating the iterator.
        HObject* arr = null;
        if (c_val.is_object() && c_val.get_heapptr() != null && arr_from_is_callable(c_val)) {
            TVal ctor_result = heap.construct_fn(ctx.vm, c_val, null, 0, c_val);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                ctx.result.set_undefined();
                return;
            }
            if (ctor_result.is_object() && ctor_result.get_heapptr() != null) {
                arr = (HObject*)ctor_result.get_heapptr();
            }
        }
        if (arr == null) {
            HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err = arr_raw) { ctx.result.set_undefined(); return; }
            arr = arr_raw;
            arr.prototype = heap.array_proto;
        }

        // 6.d: iterator = GetIterator(items, usingIterator).
        TVal iterator = heap.call_fn(ctx.vm, iter_method, null, 0, items);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            ctx.result.set_undefined();
            return;
        }
        if (!iterator.is_object() || iterator.get_heapptr() == null) {
            arr_throw_type_error(ctx, "Result of the Symbol.iterator method is not an object");
            ctx.result.set_undefined();
            return;
        }

        HString* next_key = builtin_intern_string(heap, "next");
        HString* done_key = builtin_intern_string(heap, "done");
        HString* value_key = builtin_intern_string(heap, "value");
        HString* len_key = builtin_intern_string(heap, "length");
        HObject* iter_obj = (HObject*)iterator.get_heapptr();

        uint k = 0;
        while (true) {
            // g.i: Pk = ToString(k) (implicit via int_to_hstring below).
            // g.ii-iii: next = IteratorStep(iterator); ReturnIfAbrupt.
            TVal? next_method_opt = builtins_generic_get(iter_obj, next_key, ctx);
            if (ctx.should_throw) {
                // GetMethod(iterator, "next") threw — no iterator to close
                // (IteratorStep itself failed before invoking next()).
                ctx.result.set_undefined();
                return;
            }
            TVal next_method;
            if (try nm = next_method_opt) { next_method = nm; } else { break; }
            if (!arr_from_is_callable(next_method)) {
                arr_throw_type_error(ctx, "iterator.next is not callable");
                ctx.result.set_undefined();
                return;
            }

            TVal step_result = heap.call_fn(ctx.vm, next_method, null, 0, iterator);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                ctx.result.set_undefined();
                return;
            }
            if (!step_result.is_object() || step_result.get_heapptr() == null) {
                arr_throw_type_error(ctx, "Iterator result is not an object");
                ctx.result.set_undefined();
                return;
            }
            HObject* result_obj = (HObject*)step_result.get_heapptr();

            // g.iv: If next is false (i.e. done is true), set A.length = k, return A.
            TVal? done_opt = builtins_generic_get(result_obj, done_key, ctx);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            bool done = false;
            if (try dv = done_opt) { done = builtin_to_boolean(&dv); }
            if (done) {
                if (len_key != null) {
                    if (!arr_set_length_or_throw(ctx, arr, len_key, (ulong)k)) {
                        ctx.result.set_undefined();
                        return;
                    }
                }
                ctx.result.set_object(arr);
                return;
            }

            // g.v-vi: nextValue = IteratorValue(next); ReturnIfAbrupt.
            TVal? value_opt = builtins_generic_get(result_obj, value_key, ctx);
            if (ctx.should_throw) {
                arr_iterator_close_after_throw(ctx, iterator);
                ctx.result.set_undefined();
                return;
            }
            TVal next_value;
            if (try vv = value_opt) { next_value = vv; } else { next_value.set_undefined(); }

            // g.vii-viii: if mapping, mappedValue = Call(mapfn, T, «nextValue, k»),
            // closing the iterator on an abrupt completion.
            TVal final_value = next_value;
            if (mapping) {
                TVal[2] map_args;
                map_args[0] = next_value;
                TVal k_tv; k_tv.set_fastint((long)k);
                map_args[1] = k_tv;
                final_value = heap.call_fn(ctx.vm, mapfn, &map_args[0], 2, this_arg);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    arr_iterator_close_after_throw(ctx, iterator);
                    ctx.result.set_undefined();
                    return;
                }
            }

            // g.ix-x: CreateDataPropertyOrThrow(A, Pk, mappedValue), closing
            // the iterator on an abrupt completion.
            HString* pk = heap.int_to_hstring((long)k);
            if (pk != null) {
                if (!arr_create_data_property_or_throw(ctx, arr, pk, final_value)) {
                    arr_iterator_close_after_throw(ctx, iterator);
                    ctx.result.set_undefined();
                    return;
                }
            }
            k++;
        }

        ctx.result.set_object(arr);
        return;
    }

    // === Array-like path — ES2022 §23.1.2.1 steps 7-19 ===
    // items must not be null or undefined (ToObject would throw).
    if (items.is_undefined() || items.is_null()) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        ctx.result.set_undefined();
        return;
    }

    // ToObject — handle strings specially (direct char access)
    HObject* array_like;
    bool is_string_prim = items.is_string();
    HString* str_val = null;
    if (is_string_prim) {
        str_val = (HString*)items.get_heapptr();
    } else if (items.is_object() && items.get_heapptr() != null) {
        array_like = (HObject*)items.get_heapptr();
    } else {
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) { ctx.result.set_undefined(); return; }
        array_like = wrapped;
        (*array_like.extra_ptr()).prim.primitive_value = items;
    }

    // Get .length — Get(arrayLike, "length") then ToLength.
    HString* len_key = builtin_intern_string(heap, "length");
    ulong len = 0;
    if (is_string_prim) {
        len = str_val.char_length();
    } else if (len_key != null) {
        TVal? len_opt = builtins_generic_get(array_like, len_key, ctx);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (try lv = len_opt) {
            double len_d = builtin_to_number_getdouble(ctx, &lv);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            len = arr_to_length(len_d);
        }
    }

    // 12. If IsConstructor(C) is true, let A be Construct(C, «len»); else
    //     let A be ArrayCreate(len).
    HObject* arr = null;
    if (c_val.is_object() && c_val.get_heapptr() != null && arr_from_is_callable(c_val)) {
        TVal len_arg;
        if (len <= 0x7FFFFFFF) {
            len_arg.set_fastint((long)len);
        } else {
            len_arg.set_number((double)len);
        }
        TVal ctor_result = heap.construct_fn(ctx.vm, c_val, &len_arg, 1, c_val);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            ctx.result.set_undefined();
            return;
        }
        if (ctor_result.is_object() && ctor_result.get_heapptr() != null) {
            arr = (HObject*)ctor_result.get_heapptr();
        }
    }
    if (arr == null) {
        HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = arr_raw) { ctx.result.set_undefined(); return; }
        arr = arr_raw;
        arr.prototype = heap.array_proto;
    }

    // 13-17. Repeat, while k < len: read arrayLike[k] (re-fetched from the
    // still-live array_like object each iteration, per spec order — the
    // mapfn/getter side effects visible during iteration reflect the current
    // state of arrayLike, not a value snapshotted before the loop began).
    for (ulong k = 0; k < len; k++) {
        HString* pk = heap.int_to_hstring((long)k);
        TVal k_value;
        k_value.set_undefined();

        if (is_string_prim && str_val != null) {
            // String primitive: `len` above is char_length() (UTF-16 code
            // units), so index by code unit here too, not raw byte —
            // otherwise this silently regresses on any multi-byte string
            // when the iterator-protocol path (spec-preferred) isn't taken.
            // NOTE: this array-like fallback is spec-incorrect for strings
            // in general — Array.from(str) should always go through the
            // @@iterator protocol (codepoint-by-codepoint) per ES6
            // §23.1.1.1 step 3, landing here only means that path wasn't
            // triggered; tracked separately from the CESU-8 migration.
            uint cp = str_val.char_at((uint)k);
            char[4] cbuf;
            uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
            HString* ch_str = builtin_intern_string(heap, cbuf[:cblen]);
            if (ch_str != null) k_value.set_string(ch_str);
        } else if (pk != null) {
            TVal? elem_opt = builtins_generic_get(array_like, pk, ctx);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (try elem = elem_opt) {
                k_value = elem;
            }
        }

        TVal final_value = k_value;
        if (mapping) {
            TVal[2] map_args;
            map_args[0] = k_value;
            TVal k_tv; k_tv.set_fastint((long)k);
            map_args[1] = k_tv;
            if (heap.call_fn != null && ctx.vm != null) {
                final_value = heap.call_fn(ctx.vm, mapfn, &map_args[0], 2, this_arg);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    ctx.result.set_undefined();
                    return;
                }
            }
        }

        if (pk != null) {
            if (!arr_create_data_property_or_throw(ctx, arr, pk, final_value)) {
                ctx.result.set_undefined();
                return;
            }
        }
    }

    // 18. Set A.length = len.
    if (len_key != null) {
        if (!arr_set_length_or_throw(ctx, arr, len_key, len)) {
            ctx.result.set_undefined();
            return;
        }
    }

    ctx.result.set_object(arr);
}

/// Array.isArray(arg) — ES6 §22.1.2.2
fn void builtin_array_isArray(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object() || arg.get_heapptr() == null) {
        ctx.result.set_boolean(false);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    if (obj.flags.exotic_proxyobj) {
        // §7.2.2 IsArray recurses through the proxy target (revoked → TypeError).
        bool is_arr;
        if (!proxy_is_array(ctx.heap, obj, &is_arr)) { proxy_ctx_ok(ctx); return; }
        ctx.result.set_boolean(is_arr);
        return;
    }
    ctx.result.set_boolean(obj.get_class() == hobject::ObjClass.ARRAY);
}

// ============================================================================
// Array constructor registration

// ============================================================================
// Array.prototype callback methods — native implementations using heap.call_fn
// ============================================================================

/// Helper: ToObject for Array.prototype methods (ES5 §9.9).
/// Wraps primitives (Boolean/Number/String) into wrapper objects.
/// Returns null-optional for null/undefined (caller should throw TypeError).
fn HObject* arr_to_object(TVal val, Heap* heap) {
    if (val.is_object() && val.get_heapptr() != null) {
        return (HObject*)val.get_heapptr();
    }
    if (val.is_null() || val.is_undefined()) {
        return null;
    }
    // Boolean → Boolean wrapper
    if (val.is_boolean()) {
        HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.BOOLEAN);
        if (try obj = obj_raw) {
            obj.prototype = heap.bool_proto;
            (*obj.extra_ptr()).prim.primitive_value.set_boolean(val.get_boolean());
            return obj;
        }
        return null;
    }
    // Number/fastint → Number wrapper
    if (val.is_number() || val.is_fastint()) {
        HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.NUMBER);
        if (try obj = obj_raw) {
            obj.prototype = heap.number_proto;
            (*obj.extra_ptr()).prim.primitive_value = val;
            return obj;
        }
        return null;
    }
    // String or Symbol → respective wrapper object.
    // Symbol primitives share the is_string() TVal tag; distinguish via is_symbol().
    if (val.is_string()) {
        HString* prim_str = (HString*)val.get_heapptr();
        if (prim_str != null && prim_str.is_symbol()) {
            // Symbol → Symbol wrapper (no exotic properties; no length).
            HObject*? sym_raw = heap.alloc_object(hobject::ObjClass.SYMBOL);
            if (try sym_obj = sym_raw) {
                sym_obj.prototype = heap.symbol_proto;
                (*sym_obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
                return sym_obj;
            }
            return null;
        }
        // Regular string → String wrapper with indexed properties.
        HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.STRING);
        if (try obj = obj_raw) {
            obj.flags.exotic_stringobj = true;
            obj.prototype = heap.string_proto;
            (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
            HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            TVal len_tv;
            len_tv.set_fastint((long)prim_str.char_length());
            obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
            // Indexed character properties are served lazily via the exotic_stringobj flag;
            // no per-character own properties are materialised at construction time.
            return obj;
        }
        return null;
    }
    return null;
}

/// Helper: throw TypeError with a message.
fn void arr_throw_type_error(BuiltinContext* ctx, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
}

/// CreateDataPropertyOrThrow(O, P, V) — ES2022 §7.3.7 / §7.3.6 CreateDataProperty.
/// Used by Array.from to define each result index with {writable:true,
/// enumerable:true, configurable:true} semantics rather than plain [[Set]] —
/// this matters when the result object's index was pre-defined as
/// non-configurable with different attributes (must throw), or when the
/// object is non-extensible and the property doesn't already exist (must
/// throw). Returns true on success; on failure sets ctx.should_throw and
/// returns false.
fn bool arr_create_data_property_or_throw(BuiltinContext* ctx, HObject* obj, HString* key, TVal val) {
    int idx = obj.find_prop_idx(key);
    if (idx >= 0) {
        hobject::PropFlags existing = obj.get_prop_flags((uint)idx);
        // If the existing property is already {W:true, E:true, C:true} and a
        // plain data property, CreateDataProperty may simply overwrite the
        // value. Otherwise, since configurable is false, redefining to the
        // desired attributes is disallowed — throw per DefineOwnProperty's
        // "reject" path (ES2022 §10.1.6.3 step 4/5 validation).
        if (!existing.configurable
            && (existing.is_accessor || !existing.writable || !existing.enumerable)) {
            arr_throw_type_error(ctx, "Cannot redefine property");
            return false;
        }
    } else if (!obj.is_extensible()) {
        arr_throw_type_error(ctx, "Cannot add property, object is not extensible");
        return false;
    }
    if (!obj.put_prop(key, val, hobject::PROP_FLAGS_WEC)) {
        arr_throw_type_error(ctx, "Cannot add property, no space left");
        return false;
    }
    return true;
}

/// Helper: check if numeric key exists on object (ES5 §15.4.5.1 step 4 "k in O").
/// Uses get_prop_or_accessor_proto to handle accessor properties.
fn bool arr_has_prop(HObject* obj, ulong key, Heap* heap, void* vm = null) {
    // Proxy exotic: route through the [[HasProperty]] MOP trap.
    if (obj.flags.exotic_proxyobj) {
        if (vm == null) return false;
        HString* pk = heap.int_to_hstring((long)key);
        if (pk == null) return false;
        bool out;
        if (!proxy_mop_has(vm, heap, obj, pk, &out)) return false;
        return out;
    }
    // Fast path: dense array storage (also used by the arguments object,
    // which stores its indexed values in array_part rather than as named props).
    // Indices ≥ 2^32 can never live in dense storage (array indices cap at 2^32-2).
    if (key <= 0xFFFFFFFFUL
        && (obj.get_class() == hobject::ObjClass.ARRAY
            || obj.get_class() == hobject::ObjClass.ARGUMENTS)) {
        if (try v = obj.get_array_idx((uint)key)) { return true; }
        // Fall through: element may also be stored as a named property (sparse)
    }
    // STRING exotic: integer indices [0, char_length) are own properties served lazily
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        return prim != null && (long)key < prim.char_length();
    }
    // TypedArray: integer indices in [0, length) are own data properties served
    // from the backing buffer (they never appear in the named-property table).
    if (is_typed_array_class(obj.get_class())) {
        uint ta_shift = ta_elem_shift(obj.get_class());
        ulong ta_len = (ulong)((*obj.extra_ptr()).view.byte_length >> ta_shift);
        return key < ta_len;
    }
    HString* pk = heap.int_to_hstring((long)key);
    if (pk == null) return false;
    // Check own properties first (handles accessor properties set via defineProperty)
    int own_idx = obj.find_prop_idx(pk);
    if (own_idx >= 0) return true;
    // Then check prototype chain
    TVal? found = obj.get_prop_proto(pk);
    return @ok(found);
}

/// Helper: DeletePropertyOrThrow(obj, key) for a numeric array index — used by
/// methods (e.g. reverse) that must delete a hole through the Proxy
/// [[Delete]] trap rather than mutating the target's property table directly.
/// Sets ctx.should_throw on a proxy trap failure/throw.
fn void arr_delete_elem_or_throw(BuiltinContext* ctx, HObject* obj, ulong key) {
    if (obj.flags.exotic_proxyobj) {
        if (ctx.vm == null) return;
        HString* pk = ctx.heap.int_to_hstring((long)key);
        if (pk == null) return;
        bool out;
        if (!proxy_mop_delete(ctx.vm, ctx.heap, obj, pk, &out)) {
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
            }
            return;
        }
        if (!out) {
            arr_throw_type_error(ctx, "Cannot delete property");
        }
        return;
    }
    HString* del_key = ctx.heap.int_to_hstring((long)key);
    if (del_key != null) obj.delete_prop(del_key);
}

/// Helper: invoke a getter function. Returns the getter result or undefined.
/// Used by arr_get_elem to handle accessor properties at numeric indices.
fn TVal arr_invoke_getter(HObject* obj, TVal getter_fn, Heap* heap, void* vm_ptr) {
    if (getter_fn.is_undefined() || getter_fn.is_null()) {
        TVal undef; undef.set_undefined(); return undef;
    }
    if (!getter_fn.is_object() || getter_fn.get_heapptr() == null) {
        TVal undef; undef.set_undefined(); return undef;
    }
    HObject* fn_obj = (HObject*)getter_fn.get_heapptr();
    if (!fn_obj.is_callable()) {
        TVal undef; undef.set_undefined(); return undef;
    }
    if (heap.call_fn != null && vm_ptr != null) {
        TVal this_val;
        this_val.set_object(obj);
        TVal result = heap.call_fn(vm_ptr, getter_fn, null, 0, this_val);
        if (heap.has_error) {
            heap.has_error = false;
            TVal undef; undef.set_undefined(); return undef;
        }
        return result;
    }
    TVal undef; undef.set_undefined(); return undef;
}

/// Like arr_invoke_getter but propagates a thrown error back to the BuiltinContext
/// instead of swallowing it. The caller checks ctx.should_throw after invoking.
fn TVal arr_invoke_getter_ctx(HObject* obj, TVal getter_fn, Heap* heap, BuiltinContext* ctx) {
    if (getter_fn.is_undefined() || getter_fn.is_null()) {
        TVal undef; undef.set_undefined(); return undef;
    }
    if (!getter_fn.is_object() || getter_fn.get_heapptr() == null) {
        TVal undef; undef.set_undefined(); return undef;
    }
    HObject* fn_obj = (HObject*)getter_fn.get_heapptr();
    if (!fn_obj.is_callable()) {
        TVal undef; undef.set_undefined(); return undef;
    }
    if (heap.call_fn != null && ctx != null && ctx.vm != null) {
        TVal this_val;
        this_val.set_object(obj);
        TVal result = heap.call_fn(ctx.vm, getter_fn, null, 0, this_val);
        if (heap.has_error) {
            // Propagate the thrown error to the surrounding JS try/catch.
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            heap.error_value.set_undefined();
            TVal undef; undef.set_undefined(); return undef;
        }
        return result;
    }
    TVal undef; undef.set_undefined(); return undef;
}

/// Check whether an object is the built-in Array constructor.
fn bool is_builtin_array_ctor(HObject* obj) {
    if (obj == null) return false;
    if (!obj.is_callable()) return false;
    return obj.callable_kind() == hobject::CallableKind.BUILTIN_FN &&
           (*obj.extra_ptr()).func.builtin_fn_index == (int)Builtin.ARRAY.ordinal;
}

/// ArraySpeciesCreate helper — ES2022 §9.4.2.3
/// Determines the constructor to use for derived array results.
/// Returns true if out_constructor is set (caller should construct with new);
/// returns false if the caller should fall back to a plain Array.
fn bool array_species_create(BuiltinContext* ctx, HObject* original, HObject** out_constructor) {
    *out_constructor = null;

    // 1. Let C be original.[[Get]]("constructor").
    HString* ctor_key = (HString*)ctx.heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    if (ctor_key == null) return false;

    TVal ctor_val;
    if (try c = builtins_generic_get(original, ctor_key, ctx)) {
        ctor_val = c;
        if (ctx.should_throw) return true;
    } else {
        // Getter threw (ctx.should_throw already set).
        return true;
    }
    if (ctor_val.is_undefined()) return false;

    // 3. If Type(C) is not Object, throw TypeError.
    if (!ctor_val.is_object() || ctor_val.get_heapptr() == null) {
        arr_throw_type_error(ctx, "ArraySpeciesCreate: constructor is not an object");
        return true;
    }
    HObject* ctor_obj = (HObject*)ctor_val.get_heapptr();

    // 4. If C is Array, use Array (skip species lookup).
    if (is_builtin_array_ctor(ctor_obj)) {
        *out_constructor = ctor_obj;
        return true;
    }

    // 5. Let S be Get(C, @@species).
    HString* species_sym = ensure_species_symbol(ctx.heap);
    if (species_sym == null) return false;

    TVal species_val;
    if (try s = builtins_generic_get(ctor_obj, species_sym, ctx)) {
        species_val = s;
        if (ctx.should_throw) return true;
    } else {
        return true;
    }

    // 6. If S is undefined or null, return Array.
    if (species_val.is_undefined() || species_val.is_null()) return false;

    // 7. If IsConstructor(S) is true, return S.
    if (species_val.is_object() && species_val.get_heapptr() != null) {
        HObject* s_obj = (HObject*)species_val.get_heapptr();
        if (s_obj.is_callable()) {
            *out_constructor = s_obj;
            return true;
        }
    }

    // 8. Throw TypeError.
    arr_throw_type_error(ctx, "SpeciesConstructor result is not a constructor");
    return true;
}

/// Construct a result array using ArraySpeciesCreate semantics.
/// Returns the result array, or null on allocation/throw error (caller should
/// check ctx.should_throw).
fn HObject* array_species_create_result(BuiltinContext* ctx, HObject* original, ulong len) {
    // ES2022 §9.4.2.3 ArraySpeciesCreate step 3: IsArray(original).
    // Proxy objects must recurse through their target (revoked → TypeError).
    bool orig_is_array;
    if (original.flags.exotic_proxyobj) {
        if (!proxy_is_array(ctx.heap, original, &orig_is_array)) {
            proxy_ctx_ok(ctx);
            return null;
        }
    } else {
        orig_is_array = (original.get_class() == hobject::ObjClass.ARRAY);
    }
    // Step 4: if original is not an Array, return ArrayCreate(length) directly
    // without consulting the constructor property.
    // §9.4.2.2 ArrayCreate step 3: if length > 2^32-1, throw RangeError.
    if (!orig_is_array) {
        if (len > 0xFFFFFFFFUL) {
            arr_throw_range_error(ctx, "Invalid array length");
            return null;
        }
        HObject*? fallback_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = fallback_raw) return null;
        HObject* fallback = fallback_raw;
        fallback.prototype = ctx.heap.array_proto;
        return fallback;
    }

    HObject* species_ctor;
    bool use_species = array_species_create(ctx, original, &species_ctor);
    if (ctx.should_throw) return null;

    if (use_species && species_ctor != null && !is_builtin_array_ctor(species_ctor)) {
        TVal ctor_tv; ctor_tv.set_object(species_ctor);
        TVal len_arg;
        if (len <= 0x7FFFFFFF) {
            len_arg.set_fastint((long)len);
        } else {
            len_arg.set_number((double)len);
        }
        TVal result_tv = ctx.heap.construct_fn(ctx.vm, ctor_tv, &len_arg, 1, ctor_tv);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return null;
        }
        if (result_tv.is_object() && result_tv.get_heapptr() != null) {
            return (HObject*)result_tv.get_heapptr();
        }
    }

    // §9.4.2.2 ArrayCreate step 3: if length > 2^32-1, throw RangeError.
    if (len > 0xFFFFFFFFUL) {
        arr_throw_range_error(ctx, "Invalid array length");
        return null;
    }
    HObject*? fallback_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = fallback_raw) return null;
    HObject* fallback = fallback_raw;
    fallback.prototype = ctx.heap.array_proto;
    return fallback;
}

/// Check whether CreateDataPropertyOrThrow(obj, idx, val) would succeed.
/// Returns true if allowed, otherwise sets ctx.should_throw and returns false.
/// Implements CreateDataProperty semantics (always requests writable+enum+config=true).
fn bool array_can_set_index(BuiltinContext* ctx, HObject* obj, ulong idx) {
    // Check own named property for all object types.
    if (idx <= 0xFFFFFFFFUL) {
        HString* key = ctx.heap.int_to_hstring((long)idx);
        if (key != null) {
            int own_idx = obj.find_prop_idx(key);
            if (own_idx >= 0) {
                PropFlags pf = obj.get_prop_flags((uint)own_idx);
                if (pf.is_accessor) {
                    arr_throw_type_error(ctx, "Cannot redefine accessor as data property");
                    return false;
                }
                // CreateDataProperty always requests {configurable:true, enumerable:true}.
                // ValidateAndApplyPropertyDescriptor rejects if the existing prop is
                // non-configurable (because configurable/enumerable would change).
                // Non-writable but configurable is fine — defineProperty can change it.
                if (!pf.configurable) {
                    arr_throw_type_error(ctx, "Cannot redefine non-configurable property");
                    return false;
                }
                return true;
            }
        }
        if (obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) {
            // Dense array elements are own writable+enumerable+configurable data properties.
            if (try v = obj.get_array_idx((uint)idx)) { return true; }
        }
    }
    // New property: object must be extensible.
    if (!obj.is_extensible()) {
        arr_throw_type_error(ctx, "Cannot add property to non-extensible object");
        return false;
    }
    return true;
}

/// Set an array element using CreateDataPropertyOrThrow semantics.
/// Returns true on success, false if an error was thrown (ctx.should_throw set).
fn bool array_set_elem_ulong_checked(BuiltinContext* ctx, HObject* obj, ulong idx, TVal val) {
    // Proxy exotic: CreateDataPropertyOrThrow routes through [[DefineOwnProperty]].
    if (obj.flags.exotic_proxyobj) {
        if (ctx == null || ctx.vm == null) return false;
        HString* pk = ctx.heap.int_to_hstring((long)idx);
        if (pk == null) return false;
        ProxyDesc nd = {};
        nd.found = true;
        nd.has_value = true; nd.value = val;
        nd.has_writable = true; nd.writable = true;
        nd.has_enumerable = true; nd.enumerable = true;
        nd.has_configurable = true; nd.configurable = true;
        bool res;
        if (!proxy_mop_define(ctx.vm, ctx.heap, obj, pk, &nd, &res)) {
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
            }
            return false;
        }
        if (!res) {
            arr_throw_type_error(ctx, "Cannot define property on proxy");
            return false;
        }
        return true;
    }
    if (!array_can_set_index(ctx, obj, idx)) return false;
    if (idx <= 0xFFFFFFFFUL) {
        HString* key = ctx.heap.int_to_hstring((long)idx);
        if (key != null) {
            // Use put_prop when: (a) a named property exists that may have non-WEC
            // flags, or (b) the value is undefined — because undefined == hole in
            // the dense array and would make the slot appear absent.
            bool has_named = obj.find_prop_idx(key) >= 0;
            bool is_undef = val.is_undefined();
            if (has_named || (is_undef && (obj.get_class() == hobject::ObjClass.ARRAY
                                        || obj.get_class() == hobject::ObjClass.ARGUMENTS))) {
                obj.put_prop(key, val, hobject::PROP_FLAGS_WEC);
                return true;
            }
        }
    }
    array_set_elem_ulong(obj, idx, val, ctx.heap);
    return true;
}

/// Check whether an indexed delete would succeed on obj. Returns true if the
/// delete is allowed, otherwise sets ctx.should_throw and returns false.
fn bool array_can_delete_index(BuiltinContext* ctx, HObject* obj, ulong idx) {
    HString* key = ctx.heap.int_to_hstring((long)idx);
    if (key != null) {
        int own_idx = obj.find_prop_idx(key);
        if (own_idx >= 0) {
            PropFlags pf = obj.get_prop_flags((uint)own_idx);
            if (!pf.configurable) {
                arr_throw_type_error(ctx, "Cannot delete non-configurable property");
                return false;
            }
            return true;
        }
    }
    // Dense array slots and holes are deletable.
    return true;
}

/// Delete an array element, throwing TypeError if the delete is not allowed.
/// Returns true on success, false if an error was thrown.
fn bool array_delete_elem_ulong_checked(BuiltinContext* ctx, HObject* obj, ulong idx) {
    // Proxy exotic: DeletePropertyOrThrow routes through [[Delete]] trap.
    if (obj.flags.exotic_proxyobj) {
        if (ctx == null || ctx.vm == null) return false;
        HString* pk = ctx.heap.int_to_hstring((long)idx);
        if (pk == null) return true;
        bool res;
        if (!proxy_mop_delete(ctx.vm, ctx.heap, obj, pk, &res)) {
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
            }
            return false;
        }
        if (!res) {
            arr_throw_type_error(ctx, "Cannot delete property on proxy");
            return false;
        }
        return true;
    }
    if (!array_can_delete_index(ctx, obj, idx)) return false;
    HString* key = ctx.heap.int_to_hstring((long)idx);
    if (key != null) {
        obj.delete_prop(key);
    }
    return true;
}

/// Perform [[Set]] for a numeric array index (Throw=true). Invokes own and
/// inherited accessor setters, throws TypeError for non-writable data
/// properties or non-extensible objects, and uses the dense array part for
/// ARRAY/ARGUMENTS class when creating new data properties. For ARRAY class,
/// writing at or beyond the current length grows the length.
fn bool array_set_elem_ulong_set(BuiltinContext* ctx, HObject* obj, ulong idx, TVal val) {
    HString* key = ctx.heap.int_to_hstring((long)idx);
    if (key == null) return true;

    // Proxy exotic: route through the [[Set]] MOP trap.
    if (obj.flags.exotic_proxyobj) {
        if (ctx == null || ctx.vm == null) return false;
        TVal recv; recv.set_object(obj);
        bool sres;
        if (!proxy_mop_set(ctx.vm, ctx.heap, obj, key, val, recv, &sres)) {
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
            }
            return false;
        }
        if (!sres) {
            arr_throw_type_error(ctx, "Cannot set property on proxy");
            return false;
        }
        return true;
    }

    // Cache current length for ARRAY class so we can grow it when writing at
    // or beyond the boundary.
    ulong current_len = 0;
    bool know_current_len = false;
    if (obj.get_class() == hobject::ObjClass.ARRAY) {
        know_current_len = array_to_length(obj, ctx.heap, ctx, &current_len);
    }

    // Step 1: own property
    int own_idx = obj.find_prop_idx(key);
    if (own_idx >= 0) {
        PropFlags f = obj.get_prop_flags((uint)own_idx);
        if (f.is_accessor) {
            TVal setter = hobject::hobject_access_setter(obj.prop_values()[(uint)own_idx]);
            if (setter.is_undefined() || setter.is_null()) {
                // Own getter-only accessor — [[Set]] returns false → TypeError.
                arr_throw_type_error(ctx, "Cannot set property, has only a getter");
                return false;
            }
            if (ctx.heap.call_fn != null && ctx.vm != null) {
                TVal this_tv;
                this_tv.set_object(obj);
                TVal[1] args = { val };
                ctx.heap.call_fn(ctx.vm, setter, &args[0], 1, this_tv);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    return false;
                }
            }
            return true;
        }
        if (!f.writable) {
            arr_throw_type_error(ctx, "Cannot assign to read-only property");
            return false;
        }
        TVal* entry = &obj.prop_values()[(uint)own_idx];
        ctx.heap.tval_copy_ref(entry, &val);
        if (know_current_len && idx >= current_len) {
            array_set_length_ulong(obj, idx + 1, ctx.heap);
        }
        return true;
    }

    // Step 2: prototype chain accessor
    hobject::AccessorResult acc = obj.find_accessor_proto((void*)key, false);
    if (acc.found) {
        TVal setter = acc.accessor_fn;
        if (setter.is_undefined() || setter.is_null()) {
            // Inherited getter-only accessor — [[Set]] returns false → TypeError.
            arr_throw_type_error(ctx, "Cannot set property, has only a getter");
            return false;
        }
        if (ctx.heap.call_fn != null && ctx.vm != null) {
            TVal this_tv;
            this_tv.set_object(obj);
            TVal[1] args = { val };
            ctx.heap.call_fn(ctx.vm, setter, &args[0], 1, this_tv);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return false;
            }
        }
        return true;
    }

    // Step 3: create new property
    if (!obj.is_extensible()) {
        arr_throw_type_error(ctx, "Cannot add property to non-extensible object");
        return false;
    }
    if (idx <= 0xFFFFFFFFUL
        && (obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS)) {
        // ARRAY dense slots cannot distinguish an explicit undefined value
        // from a hole, so store undefined as a named property.
        if (obj.get_class() == hobject::ObjClass.ARRAY && val.is_undefined()) {
            obj.put_prop(key, val, hobject::PROP_FLAGS_WEC);
        } else {
            // Try dense array first; fall back to named property when the
            // dense part can't grow (e.g. index >= 2^31).
            if (obj.set_array_idx((uint)idx, val)) {
                // Dense write succeeded — auto-grow length.
                if (know_current_len && idx >= current_len) {
                    array_set_length_ulong(obj, idx + 1, ctx.heap);
                }
                return true;
            }
            // Dense write failed — store as named property (sparse array).
            // Do NOT auto-grow length here; the caller is responsible.
            obj.put_prop(key, val, hobject::PROP_FLAGS_WEC);
        }
        return true;
    }
    obj.put_prop(key, val, hobject::PROP_FLAGS_WEC);
    return true;
}

/// Helper: get value at numeric index, returns false if not present.
/// Handles accessor properties by invoking the getter.
fn bool arr_get_elem(HObject* obj, uint key, Heap* heap, TVal* out) {
    // STRING exotic: serve indexed character properties lazily
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null && (long)key < prim.char_length()) {
            char[] data = prim.get_data();
            usz byte_start = (usz)prim.char_offset_to_byte_offset(key);
            usz byte_end = (usz)prim.char_offset_to_byte_offset(key + 1);
            if (byte_start < byte_end) {
                char[8] one;
                usz copy_len = byte_end - byte_start;
                if (copy_len >= one.len) copy_len = one.len - 1;
                for (usz j = 0; j < copy_len; j++) { one[j] = data[byte_start + j]; }
                one[copy_len] = 0;
                HString*? ch_raw = builtin_intern_string(heap, one[:copy_len]);
                if (try ch = ch_raw) { out.set_string(ch); return true; }
            }
            return false;
        }
        return false;
    }

    HString* pk = heap.int_to_hstring((long)key);
    if (pk == null) return false;

    // Check own properties first — may be an accessor (set via defineProperty)
    // This must come BEFORE the dense array fast path because accessor properties
    // at numeric indices override the dense array value.
    int own_idx = obj.find_prop_idx(pk);
    if (own_idx >= 0) {
        PropFlags pf = obj.get_prop_flags((uint)own_idx);
        if (pf.is_accessor) {
            TVal gs_slot = obj.prop_values()[own_idx];
            TVal getter_fn = hobject::hobject_access_getter(gs_slot);
            *out = arr_invoke_getter(obj, getter_fn, heap, null);
            return true;
        }
        *out = obj.prop_values()[own_idx];
        return true;
    }

    // Fast path: dense array storage (no accessor at this index)
    if (obj.get_class() == hobject::ObjClass.ARRAY) {
        if (try v = obj.get_array_idx(key)) {
            *out = v;
            return true;
        }
        // Fall through: element may be stored as a named property (sparse or pre-dense)
    }

    // Prototype chain lookup
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto(pk, true);
    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        *out = arr_invoke_getter(obj, res.acc.accessor_fn, heap, null);
        return true;
    } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        *out = res.data_val;
        return true;
    }
    return false;
}

/// Helper: get value at numeric index with VM context (for getter invocation).
/// Handles accessor properties by invoking the getter via VM, and propagates
/// any thrown error from the getter back to ctx.should_throw/ctx.throw_value
/// so the surrounding JS try/catch can catch it.
fn bool arr_get_elem_vm(HObject* obj, ulong key, Heap* heap, BuiltinContext* ctx, TVal* out) {
    // Proxy exotic: route through [[Get]] trap machinery.
    if (obj.flags.exotic_proxyobj) {
        if (ctx == null || ctx.vm == null) return false;
        HString* pk = heap.int_to_hstring((long)key);
        if (pk == null) return false;
        TVal recv; recv.set_object(obj);
        if (!proxy_mop_get(ctx.vm, heap, obj, pk, recv, out)) {
            if (heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = heap.error_value;
                heap.has_error = false;
            }
            return false;
        }
        return true;
    }
    // STRING exotic: serve indexed character properties lazily
    if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
        HString* prim = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        if (prim != null && (long)key < prim.char_length()) {
            char[] data = prim.get_data();
            usz byte_start = (usz)prim.char_offset_to_byte_offset((uint)key);
            usz byte_end = (usz)prim.char_offset_to_byte_offset((uint)key + 1);
            if (byte_start < byte_end) {
                char[8] one;
                usz copy_len = byte_end - byte_start;
                if (copy_len >= one.len) copy_len = one.len - 1;
                for (usz j = 0; j < copy_len; j++) { one[j] = data[byte_start + j]; }
                one[copy_len] = 0;
                HString*? ch_raw = builtin_intern_string(heap, one[:copy_len]);
                if (try ch = ch_raw) { out.set_string(ch); return true; }
            }
            return false;
        }
        return false;
    }

    // TypedArray: integer indices in [0, length) load from the backing buffer.
    if (is_typed_array_class(obj.get_class())) {
        hobject::ObjClass ta_cls = obj.get_class();
        uint ta_shift = ta_elem_shift(ta_cls);
        ulong ta_len = (ulong)((*obj.extra_ptr()).view.byte_length >> ta_shift);
        if (key >= ta_len) return false;
        HObject* ta_buf = (*obj.extra_ptr()).view.buffer;
        char* ta_base = (*ta_buf.extra_ptr()).ab.data + (*obj.extra_ptr()).view.byte_offset;
        *out = ta_load_element(heap, ta_base, ta_cls, (uint)key);
        return true;
    }

    // Fast path: dense array storage (also used by the arguments object,
    // which stores its indexed values in array_part rather than as named props).
    // Indices ≥ 2^32 can never live in dense storage (array indices cap at 2^32-2).
    if (key <= 0xFFFFFFFFUL
        && (obj.get_class() == hobject::ObjClass.ARRAY
            || obj.get_class() == hobject::ObjClass.ARGUMENTS)) {
        if (try v = obj.get_array_idx((uint)key)) {
            *out = v;
            return true;
        }
    }

    HString* pk = heap.int_to_hstring((long)key);
    if (pk == null) return false;

    // Check own properties — may be an accessor (set via defineProperty)
    int own_idx = obj.find_prop_idx(pk);
    if (own_idx >= 0) {
        PropFlags pf = obj.get_prop_flags((uint)own_idx);
        if (pf.is_accessor) {
            TVal gs_slot = obj.prop_values()[own_idx];
            TVal getter_fn = hobject::hobject_access_getter(gs_slot);
            *out = arr_invoke_getter_ctx(obj, getter_fn, heap, ctx);
            // If the getter threw, bubble ctx.should_throw up to the caller.
            return !ctx.should_throw;
        }
        *out = obj.prop_values()[own_idx];
        return true;
    }

    // Prototype chain lookup
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto(pk, true);
    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        *out = arr_invoke_getter_ctx(obj, res.acc.accessor_fn, heap, ctx);
        return !ctx.should_throw;
    } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        *out = res.data_val;
        return true;
    }
    return false;
}

/// Helper: check if callback is callable, throw TypeError if not.
fn bool arr_check_callback(TVal val, BuiltinContext* ctx) {
    if (val.is_object() && val.get_heapptr() != null && ((HObject*)val.get_heapptr()).is_callable()) {
        return true;
    }
    arr_throw_type_error(ctx, "callback is not a function");
    return false;
}

/// Helper: call a function with (v, k, O) args and thisArg.
/// If the callback throws, set ctx.should_throw and ctx.throw_value so the
/// CALL handler in vm.c3 propagates the error back to an outer JS try/catch.
fn TVal arr_call_callback(BuiltinContext* ctx, TVal callback, TVal thisArg, TVal v, ulong k, HObject* o) {
    TVal[3] args;
    args[0] = v;
    TVal k_tv;
    if (k <= (ulong)types::FASTINT_MAX) {
        k_tv.set_fastint((long)k);
    } else {
        k_tv.set_number((double)k);
    }
    args[1] = k_tv;
    args[2].set_object((void*)o);
    TVal res = ctx.heap.call_fn(ctx.vm, callback, &args[0], 3, thisArg);
    if (ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
    }
    return res;
}

/// Array.prototype.forEach(callbackfn[, thisArg]) — ES5 §15.4.4.18
fn void builtin_array_proto_forEach(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* o = arr_to_object(this_val, ctx.heap);
    if (o == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    ulong len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    // Per ES5 §15.4.4.18 step 2: IsCallable(callbackfn) must be true even
    // when argc < 1 (i.e. callbackfn is undefined). Always check so the
    // TypeError is thrown.
    TVal cb_val;
    if (ctx.argc >= 1) { cb_val = ctx.regs[ctx.base_reg]; } else { cb_val.set_undefined(); }
    if (!arr_check_callback(cb_val, ctx)) return;
    TVal callback = cb_val;
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    for (ulong k = 0; k < len; k++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx, &v)) {
                arr_call_callback(ctx, callback, thisArg, v, k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            }
        }
    }
    ctx.result.set_undefined();
}

/// Array.prototype.map(callbackfn[, thisArg]) — ES5 §15.4.4.19
fn void builtin_array_proto_map(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* o = arr_to_object(this_val, ctx.heap);
    if (o == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    // ES2022 §23.1.3.18 step 2: get LengthOfArrayLike before checking IsCallable.
    ulong len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    // ArraySpeciesCreate(O, len) → ArrayCreate(len) throws RangeError if len > 2^32-1
    // (per ES2022 §23.1.3.18 step 5 → §9.4.2.3 → §9.4.2.2 step 1).
    if (len > 0xFFFFFFFFUL) {
        arr_throw_range_error(ctx, "Invalid array length");
        return;
    }
    // Step 3: IsCallable(callbackfn) check.
    TVal cb_val;
    if (ctx.argc >= 1) { cb_val = ctx.regs[ctx.base_reg]; } else { cb_val.set_undefined(); }
    if (!arr_check_callback(cb_val, ctx)) return;
    TVal callback = cb_val;
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    // Step 5: ArraySpeciesCreate(O, len) — use species constructor if available.
    HObject* arr = array_species_create_result(ctx, o, len);
    if (arr == null) { ctx.result.set_undefined(); return; }
    // Ensure result length is set to source length (ArrayCreate sets it, but
    // array_species_create_result fallback doesn't for plain arrays).
    array_set_length_ulong(arr, len, ctx.heap);
    for (ulong k = 0; k < len; k++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (!arr_get_elem_vm(o, k, ctx.heap, ctx, &v)) {
                v.set_undefined();
            }
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            TVal mapped = arr_call_callback(ctx, callback, thisArg, v, k, o);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            if (!array_set_elem_ulong_checked(ctx, arr, k, mapped)) {
                ctx.result.set_undefined();
                return;
            }
        }
    }
    ctx.result.set_object((void*)arr);
}

/// Array.prototype.filter(callbackfn[, thisArg]) — ES5 §15.4.4.20
fn void builtin_array_proto_filter(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* o = arr_to_object(this_val, ctx.heap);
    if (o == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    // ES2022 §23.1.3.12 step 2: get LengthOfArrayLike before checking IsCallable.
    ulong len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    TVal cb_val;
    if (ctx.argc >= 1) { cb_val = ctx.regs[ctx.base_reg]; } else { cb_val.set_undefined(); }
    if (!arr_check_callback(cb_val, ctx)) return;
    TVal callback = cb_val;
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    // Step 7: ArraySpeciesCreate(O, 0) — result length is not known in advance.
    HObject* arr = array_species_create_result(ctx, o, 0);
    if (arr == null) { ctx.result.set_undefined(); return; }
    ulong aj = 0;
    for (ulong k = 0; k < len; k++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx, &v)) {
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                TVal sel = arr_call_callback(ctx, callback, thisArg, v, k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (builtin_to_boolean(&sel)) {
                    if (!array_set_elem_ulong_checked(ctx, arr, aj, v)) {
                        ctx.result.set_undefined();
                        return;
                    }
                    aj++;
                }
            }
        }
    }
    HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv; len_tv.set_fastint((long)aj);
    arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object((void*)arr);
}

/// Array.prototype.find(callbackfn[, thisArg]) — ES6 §22.1.3.8
/// Returns the first element for which callbackfn returns truthy,
/// or undefined if none.
/// Per spec, every index in [0, len) is visited in order — the
/// callback is called even for missing indices (treated as undefined),
/// so there is no hole-skipping HasProperty precheck.
fn void builtin_array_proto_find(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* o = arr_to_object(this_val, ctx.heap);
    if (o == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    ulong len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    TVal cb_val;
    if (ctx.argc >= 1) { cb_val = ctx.regs[ctx.base_reg]; } else { cb_val.set_undefined(); }
    if (!arr_check_callback(cb_val, ctx)) return;
    TVal callback = cb_val;
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    for (ulong k = 0; k < len; k++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal v;
        TVal undef; undef.set_undefined();
        bool have = arr_get_elem_vm(o, k, ctx.heap, ctx, &v);
        if (!have) v = undef;
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal test = arr_call_callback(ctx, callback, thisArg, v, k, o);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (builtin_to_boolean(&test)) {
            (*ctx.result) = v;
            return;
        }
    }
    ctx.result.set_undefined();
}

/// Array.prototype.findLast(callbackfn[, thisArg]) — ES2023 §22.1.3.9
/// Returns the last element for which callbackfn returns truthy,
/// or undefined if none.
/// Per spec, every index in [0, len) is visited in reverse — the
/// callback is called even for missing indices (treated as undefined),
/// so there is no hole-skipping HasProperty precheck.
fn void builtin_array_proto_findLast(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* o = arr_to_object(this_val, ctx.heap);
    if (o == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    ulong len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    TVal cb_val;
    if (ctx.argc >= 1) { cb_val = ctx.regs[ctx.base_reg]; } else { cb_val.set_undefined(); }
    if (!arr_check_callback(cb_val, ctx)) return;
    TVal callback = cb_val;
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    for (long k = (long)len - 1; k >= 0; k--) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal v;
        TVal undef; undef.set_undefined();
        bool have = arr_get_elem_vm(o, (ulong)k, ctx.heap, ctx, &v);
        if (!have) v = undef;
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal test = arr_call_callback(ctx, callback, thisArg, v, (ulong)k, o);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (builtin_to_boolean(&test)) {
            (*ctx.result) = v;
            return;
        }
    }
    ctx.result.set_undefined();
}

/// Array.prototype.findLastIndex(callbackfn[, thisArg]) — ES2023 §22.1.3.10
/// Returns the last index for which callbackfn returns truthy,
/// or -1 if none.
/// Per spec, every index in [0, len) is visited in reverse — the
/// callback is called even for missing indices (treated as undefined),
/// so there is no hole-skipping HasProperty precheck.
fn void builtin_array_proto_findLastIndex(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* o = arr_to_object(this_val, ctx.heap);
    if (o == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    TVal cb_val;
    if (ctx.argc >= 1) { cb_val = ctx.regs[ctx.base_reg]; } else { cb_val.set_undefined(); }
    if (!arr_check_callback(cb_val, ctx)) return;
    TVal callback = cb_val;
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    ulong len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    for (long k = (long)len - 1; k >= 0; k--) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal v;
        TVal undef; undef.set_undefined();
        bool have = arr_get_elem_vm(o, (ulong)k, ctx.heap, ctx, &v);
        if (!have) v = undef;
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal test = arr_call_callback(ctx, callback, thisArg, v, (ulong)k, o);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (builtin_to_boolean(&test)) {
            TVal k_tv;
            if ((ulong)k <= (ulong)types::FASTINT_MAX) {
                k_tv.set_fastint(k);
            } else {
                k_tv.set_number((double)(ulong)k);
            }
            (*ctx.result) = k_tv;
            return;
        }
    }
    TVal neg; neg.set_fastint(-1);
    (*ctx.result) = neg;
}

/// Array.prototype.findIndex(callbackfn[, thisArg]) — ES6 §22.1.3.9
/// Returns the index of the first element for which callbackfn returns truthy,
/// or -1 if none.
/// Per spec, every index in [0, len) is visited in order — the
/// callback is called even for missing indices (treated as undefined),
/// so there is no hole-skipping HasProperty precheck.
fn void builtin_array_proto_findIndex(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* o = arr_to_object(this_val, ctx.heap);
    if (o == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    TVal cb_val;
    if (ctx.argc >= 1) { cb_val = ctx.regs[ctx.base_reg]; } else { cb_val.set_undefined(); }
    if (!arr_check_callback(cb_val, ctx)) return;
    TVal callback = cb_val;
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    ulong len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    for (ulong k = 0; k < len; k++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal v;
        TVal undef; undef.set_undefined();
        bool have = arr_get_elem_vm(o, k, ctx.heap, ctx, &v);
        if (!have) v = undef;
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        TVal test = arr_call_callback(ctx, callback, thisArg, v, k, o);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (builtin_to_boolean(&test)) {
            TVal k_tv;
            if (k <= (ulong)types::FASTINT_MAX) {
                k_tv.set_fastint((long)k);
            } else {
                k_tv.set_number((double)k);
            }
            (*ctx.result) = k_tv;
            return;
        }
    }
    TVal neg; neg.set_fastint(-1);
    (*ctx.result) = neg;
}

/// Array.prototype.every(callbackfn[, thisArg]) — ES5 §15.4.4.17
fn void builtin_array_proto_every(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* o = arr_to_object(this_val, ctx.heap);
    if (o == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    // ES5 §15.4.4.16: read LengthOfArrayLike before checking IsCallable.
    ulong len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    TVal cb_val;
    if (ctx.argc >= 1) { cb_val = ctx.regs[ctx.base_reg]; } else { cb_val.set_undefined(); }
    if (!arr_check_callback(cb_val, ctx)) return;
    TVal callback = cb_val;
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    for (ulong k = 0; k < len; k++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx, &v)) {
                TVal test = arr_call_callback(ctx, callback, thisArg, v, k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (!builtin_to_boolean(&test)) {
                    ctx.result.set_boolean(false);
                    return;
                }
            }
        }
    }
    ctx.result.set_boolean(true);
}

/// Array.prototype.some(callbackfn[, thisArg]) — ES5 §15.4.4.16
fn void builtin_array_proto_some(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* o = arr_to_object(this_val, ctx.heap);
    if (o == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    // ES5 §15.4.4.17: read LengthOfArrayLike before checking IsCallable.
    ulong len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    TVal cb_val;
    if (ctx.argc >= 1) { cb_val = ctx.regs[ctx.base_reg]; } else { cb_val.set_undefined(); }
    if (!arr_check_callback(cb_val, ctx)) return;
    TVal callback = cb_val;
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    for (ulong k = 0; k < len; k++) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx, &v)) {
                TVal test = arr_call_callback(ctx, callback, thisArg, v, k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (builtin_to_boolean(&test)) {
                    ctx.result.set_boolean(true);
                    return;
                }
            }
        }
    }
    ctx.result.set_boolean(false);
}

/// Array.prototype.reduce(callbackfn[, initialValue]) — ES5 §15.4.4.21
fn void builtin_array_proto_reduce(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* o = arr_to_object(this_val, ctx.heap);
    if (o == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    ulong len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    TVal callback_val;
    if (ctx.argc >= 1) { callback_val = ctx.regs[ctx.base_reg]; } else { callback_val.set_undefined(); }
    if (!arr_check_callback(callback_val, ctx)) {
        return;
    }
    TVal callback = callback_val;
    ulong k = 0;
    TVal acc;
    bool has_acc;
    if (ctx.argc > 1) {
        acc = ctx.regs[ctx.base_reg + 1];
        has_acc = true;
    } else {
        has_acc = false;
        while (k < len && !arr_has_prop(o, k, ctx.heap)) { k++; }
        if (k >= len) {
            arr_throw_type_error(ctx, "Reduce of empty array with no initial value");
            return;
        }
        arr_get_elem_vm(o, k, ctx.heap, ctx, &acc);
        has_acc = true;
        k++;
    }
    TVal undef_this; undef_this.set_undefined();
    while (k < len) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx, &v)) {
                TVal[4] args;
                args[0] = acc;
                args[1] = v;
                TVal k_tv;
                if (k <= (ulong)types::FASTINT_MAX) { k_tv.set_fastint((long)k); } else { k_tv.set_number((double)k); }
                args[2] = k_tv;
                args[3].set_object((void*)o);
                acc = ctx.heap.call_fn(ctx.vm, callback, &args[0], 4, undef_this);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    ctx.result.set_undefined();
                    return;
                }
            }
        }
        k++;
    }
    (*ctx.result) = acc;
}

/// Array.prototype.reduceRight(callbackfn[, initialValue]) — ES5 §15.4.4.22
fn void builtin_array_proto_reduceRight(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* o = arr_to_object(this_val, ctx.heap);
    if (o == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    ulong len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    TVal callback_val;
    if (ctx.argc >= 1) { callback_val = ctx.regs[ctx.base_reg]; } else { callback_val.set_undefined(); }
    if (!arr_check_callback(callback_val, ctx)) {
        return;
    }
    TVal callback = callback_val;
    if (len == 0 && ctx.argc < 2) {
        arr_throw_type_error(ctx, "Reduce of empty array with no initial value");
        return;
    }
    long k = (len > 0) ? (long)len - 1 : -1;
    TVal acc;
    bool has_acc;
    if (ctx.argc > 1) {
        acc = ctx.regs[ctx.base_reg + 1];
        has_acc = true;
    } else {
        has_acc = false;
        while (k >= 0 && !arr_has_prop(o, (ulong)k, ctx.heap)) { k--; }
        if (k < 0) {
            arr_throw_type_error(ctx, "Reduce of empty array with no initial value");
            return;
        }
        arr_get_elem_vm(o, (ulong)k, ctx.heap, ctx, &acc);
        has_acc = true;
        k--;
    }
    TVal undef_this; undef_this.set_undefined();
    while (k >= 0) {
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        if (arr_has_prop(o, (ulong)k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, (ulong)k, ctx.heap, ctx, &v)) {
                TVal[4] args;
                args[0] = acc;
                args[1] = v;
                TVal k_tv;
                if (k <= types::FASTINT_MAX) { k_tv.set_fastint(k); } else { k_tv.set_number((double)k); }
                args[2] = k_tv;
                args[3].set_object((void*)o);
                acc = ctx.heap.call_fn(ctx.vm, callback, &args[0], 4, undef_this);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    ctx.result.set_undefined();
                    return;
                }
            }
        }
        k--;
    }
    (*ctx.result) = acc;
}

/// Array[@@species] getter — ES2022 §23.1.2.5. Returns the this value (the
/// constructor itself), so a subclass like `class MyArray extends Array {}`
/// gets MyArray back from ArraySpeciesCreate by inheriting this accessor
/// through its constructor's prototype chain.
fn void builtin_array_species_getter(BuiltinContext* ctx) {
    *ctx.result = ctx.regs[ctx.base_reg - 1];
}

fn bool register_array_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Array.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.array_proto = proto;

    // Create Array constructor as a proper HObject (not LIGHTFUNC)
    // so it can carry static methods like Array.isArray
    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = arr_raw) return false;
    HObject* arr = arr_raw;
    (*arr.extra_ptr()).func.builtin_fn_index = (int)Builtin.ARRAY.ordinal;

    // Set .constructor on Array.prototype to point to the actual Array constructor object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(arr);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Array.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    arr.put_prop(prototype_key, proto_tv, proto_pflags);

    // Register Array.prototype methods
    if (!register_array_proto_method(proto, heap, "toString",  Builtin.ARRAY_PROTO_TOSTRING.ordinal))  return false;
    if (!register_array_proto_method(proto, heap, "join",      Builtin.ARRAY_PROTO_JOIN.ordinal))      return false;
    if (!register_array_proto_method(proto, heap, "pop",       Builtin.ARRAY_PROTO_POP.ordinal))       return false;
    if (!register_array_proto_method(proto, heap, "push",      Builtin.ARRAY_PROTO_PUSH.ordinal))      return false;
    if (!register_array_proto_method(proto, heap, "reverse",   Builtin.ARRAY_PROTO_REVERSE.ordinal))   return false;
    if (!register_array_proto_method(proto, heap, "shift",     Builtin.ARRAY_PROTO_SHIFT.ordinal))     return false;
    if (!register_array_proto_method(proto, heap, "slice",     Builtin.ARRAY_PROTO_SLICE.ordinal))     return false;
    if (!register_array_proto_method(proto, heap, "sort",      Builtin.ARRAY_PROTO_SORT.ordinal))      return false;
    if (!register_array_proto_method(proto, heap, "splice",    Builtin.ARRAY_PROTO_SPLICE.ordinal))    return false;
    if (!register_array_proto_method(proto, heap, "unshift",   Builtin.ARRAY_PROTO_UNSHIFT.ordinal))   return false;
    if (!register_array_proto_method(proto, heap, "indexOf",   Builtin.ARRAY_PROTO_INDEXOF.ordinal))   return false;
    if (!register_array_proto_method(proto, heap, "lastIndexOf", Builtin.ARRAY_PROTO_LASTINDEXOF.ordinal)) return false;
    if (!register_array_proto_method(proto, heap, "concat",    Builtin.ARRAY_PROTO_CONCAT.ordinal))    return false;
    if (!register_array_proto_method(proto, heap, "fill",      Builtin.ARRAY_PROTO_FILL.ordinal))      return false;
    if (!register_array_proto_method(proto, heap, "includes",  Builtin.ARRAY_PROTO_INCLUDES.ordinal))  return false;
    if (!register_array_proto_method(proto, heap, "at",        Builtin.ARRAY_PROTO_AT.ordinal))        return false;
    if (!register_array_proto_method(proto, heap, "copyWithin", Builtin.ARRAY_PROTO_COPYWITHIN.ordinal)) return false;
    if (!register_array_proto_method(proto, heap, "find",       Builtin.ARRAY_PROTO_FIND.ordinal))       return false;
    if (!register_array_proto_method(proto, heap, "findIndex",  Builtin.ARRAY_PROTO_FINDINDEX.ordinal))  return false;
    if (!register_array_proto_method(proto, heap, "findLast",      Builtin.ARRAY_PROTO_FINDLAST.ordinal))      return false;
    if (!register_array_proto_method(proto, heap, "findLastIndex", Builtin.ARRAY_PROTO_FINDLASTINDEX.ordinal)) return false;
    if (!register_array_proto_method(proto, heap, "flat",      Builtin.ARRAY_PROTO_FLAT.ordinal))      return false;
    if (!register_array_proto_method(proto, heap, "flatMap",    Builtin.ARRAY_PROTO_FLATMAP.ordinal))   return false;
    if (!register_array_proto_method(proto, heap, "toReversed", Builtin.ARRAY_PROTO_TOREVERSED.ordinal)) return false;
    if (!register_array_proto_method(proto, heap, "toSorted",  Builtin.ARRAY_PROTO_TOSORTED.ordinal))  return false;
    if (!register_array_proto_method(proto, heap, "toSpliced", Builtin.ARRAY_PROTO_TOSPLICED.ordinal)) return false;
    if (!register_array_proto_method(proto, heap, "with",      Builtin.ARRAY_PROTO_WITH.ordinal))      return false;

// Array.prototype.keys/values/entries (ES2015 §22.1.3.x)
    if (!register_array_proto_method(proto, heap, "keys",      Builtin.ARRAY_PROTO_KEYS.ordinal))      return false;
    if (!register_array_proto_method(proto, heap, "values",    Builtin.ARRAY_PROTO_VALUES.ordinal))    return false;
    if (!register_array_proto_method(proto, heap, "entries",   Builtin.ARRAY_PROTO_ENTRIES.ordinal))   return false;

    // Register callback-based Array.prototype methods as native builtins.
    // Uses heap.call_fn for proper this-binding via Function.prototype.call semantics.
    if (!register_array_proto_method(proto, heap, "forEach",   Builtin.ARRAY_PROTO_FOREACH.ordinal))   return false;
    if (!register_array_proto_method(proto, heap, "map",        Builtin.ARRAY_PROTO_MAP.ordinal))        return false;
    if (!register_array_proto_method(proto, heap, "filter",     Builtin.ARRAY_PROTO_FILTER.ordinal))     return false;
    if (!register_array_proto_method(proto, heap, "every",      Builtin.ARRAY_PROTO_EVERY.ordinal))      return false;
    if (!register_array_proto_method(proto, heap, "some",       Builtin.ARRAY_PROTO_SOME.ordinal))       return false;
    if (!register_array_proto_method(proto, heap, "reduce",     Builtin.ARRAY_PROTO_REDUCE.ordinal))     return false;
    if (!register_array_proto_method(proto, heap, "reduceRight",Builtin.ARRAY_PROTO_REDUCERIGHT.ordinal)) return false;

    // Array.prototype.toLocaleString — ES5 §15.4.4.3
    // Delegates to Object.prototype.toLocaleString for each element, then joins with ", ".
    if (!register_compiled_proto_method(proto, heap, global_env, "toLocaleString",
        "(){if(this==null)throw new TypeError('toLocaleString called on null or undefined');var O=Object(this);var len=O.length>>>0;if(len>>>0!==len)len=0;var separator=\",\";var elements=[];for(var k=0;k<len;k++){if(k in O){var nextElement=O[k];var s=(nextElement===null||nextElement===void 0)?\"\":nextElement.toLocaleString();elements.push(s)}}return elements.join(separator)}", 0)) return false;

    // Register Array.prototype[@@iterator] (ES6 §22.1.3.30)
    // Per spec, @@iterator must be the *same function object* as .values.
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        if (iter_sym != null) {
            HString* values_key = builtin_intern_string(heap, "values");
            if (values_key != null) {
                TVal? values_tv = proto.get_prop(values_key);
                if (try values_func = values_tv) {
                    // Set @@iterator to the same function as .values
                    proto.put_prop(iter_sym, values_func, hobject::PROP_FLAGS_WC);
                }
            }
        }
    }

    // Array.prototype[@@unscopables] (ES2023 §23.1.3.34): a null-prototype
    // object listing the for-in-shadowing method names, each a data property
    // with value true. The property itself is { writable:false, enumerable:false,
    // configurable:true }.
    {
        HString* unsc_sym = ensure_unscopables_symbol(heap);
        if (unsc_sym != null) {
            HObject*? list_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
            if (catch err = list_raw) return false;
            HObject* list = list_raw;
            list.prototype = null;  // ObjectCreate(null)
            String[*] names = {
                "at", "copyWithin", "entries", "fill", "find", "findIndex",
                "findLast", "findLastIndex", "flat", "flatMap", "includes",
                "keys", "toReversed", "toSorted", "toSpliced", "values",
            };
            TVal true_tv; true_tv.set_boolean(true);
            foreach (nm : names) {
                HString* k = builtin_intern_string(heap, nm);
                if (k == null) return false;
                list.put_prop(k, true_tv, hobject::PROP_FLAGS_WEC);
            }
            TVal list_tv; list_tv.set_object(list);
            // { writable:false, enumerable:false, configurable:true }
            hobject::PropFlags unsc_flags = { .writable = false, .enumerable = false, .configurable = true, .is_accessor = false };
            proto.put_prop(unsc_sym, list_tv, unsc_flags);
        }
    }

    // Array.prototype has no own @@toStringTag (ES2022 §23.1.3.31): the
    // "Array" tag in Object.prototype.toString comes from the IsArray()
    // internal-slot check, not from a @@toStringTag property.

    // Add Array.isArray (ES6 §22.1.2.2) as static method on the constructor
    HString* isarray_key = builtin_intern_string(heap, "isArray");
    if (isarray_key == null) return false;
    TVal isarray_tv;
    isarray_tv.set_lightfunc((void*)(usz)Builtin.ARRAY_ISARRAY.ordinal);
    arr.put_prop(isarray_key, isarray_tv, hobject::PROP_FLAGS_WC);

    // Add Array.of (ES6 §22.1.2.3) as static method on the constructor
    HString* of_key = builtin_intern_string(heap, "of");
    if (of_key == null) return false;
    TVal of_tv;
    of_tv.set_lightfunc((void*)(usz)Builtin.ARRAY_OF.ordinal);
    arr.put_prop(of_key, of_tv, hobject::PROP_FLAGS_WC);

    // Add Array.from (ES6 §22.1.2.1) as static method on the constructor
    HString* from_key = builtin_intern_string(heap, "from");
    if (from_key == null) return false;
    TVal from_tv;
    from_tv.set_lightfunc((void*)(usz)Builtin.ARRAY_FROM.ordinal);
    arr.put_prop(from_key, from_tv, hobject::PROP_FLAGS_WC);

    // Add @@species accessor (ES2022 §23.1.2.5): getter returns `this`.
    HString* species_sym = ensure_species_symbol(heap);
    if (species_sym != null) {
        HObject*? getter_fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try getter_fn = getter_fn_raw) {
            (*getter_fn.extra_ptr()).func.builtin_fn_index = (int)Builtin.ARRAY_SPECIES_GETTER.ordinal;
            getter_fn.flags.callable = true;
            getter_fn.prototype = heap.function_proto;
            HString* getter_name = builtin_intern_string(heap, "get [Symbol.species]");
            if (getter_name != null) {
                TVal name_tv; name_tv.set_string(getter_name);
                getter_fn.put_prop((void*)builtin_intern_string(heap, "name"), name_tv, hobject::PROP_FLAGS_NWC);
            }
            HString* len_key_sp = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            TVal zero_tv; zero_tv.set_fastint(0);
            getter_fn.put_prop(len_key_sp, zero_tv, hobject::PROP_FLAGS_NWC);

            TVal getter_tv; getter_tv.set_object(getter_fn);
            TVal undef; undef.set_undefined();
            hobject::PropFlags acc_flags;
            acc_flags.writable = false;
            acc_flags.enumerable = false;
            acc_flags.configurable = true;
            acc_flags.is_accessor = true;
            arr.put_prop(species_sym, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags);
        }
    }

    // Register Array constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("Array");
    HString* existing = heap.str_table_lookup("Array", hash);
    HString* arr_key;
    if (existing != null) {
        arr_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Array", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        arr_key = new_key;
    }
    TVal arr_val;
    arr_val.set_object(arr);
    set_func_ctor_name_length(arr, heap, "Array", 1);
    env::env_declare_nonenum(global_env, arr_key, arr_val);

    return true;
}
