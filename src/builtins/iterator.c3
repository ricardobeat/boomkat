/// Iterator protocol: %IteratorPrototype%, Array/String/Map/Set/RegExpString iterators.
module duktape::builtins;
import duktape::types;
import std::io;
import std::math;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::re_bindings;
import duktape::vm;
import duktape::env;

// ============================================================================
// Iterator protocol — built-in @@iterator methods and .next() functions
// ============================================================================

/// Helper: create an array iterator with a specific kind.
/// kind: 0=value (default), 1=key, 2=key+value (entries)
fn void create_array_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    HObject* iterable = arr_to_object(this_val, heap);
    if (iterable == null) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.ARRAY_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    iterable.as_header().incref();
    (*iter.extra_ptr()).iter.target = iterable;
    (*iter.extra_ptr()).iter.index = 0;
    (*iter.extra_ptr()).iter.kind = kind;
    // Array iterators inherit the shared %ArrayIteratorPrototype%, whose
    // `next` method is observable and may be replaced by user code.  Do not
    // install an own `next` property here: GetIterator consumers must perform
    // Get(iterator, "next") through the prototype chain.
    iter.prototype = heap.array_iterator_proto;
    ctx.result.set_object(iter);
}

/// Helper: create a Map iterator with a specific kind.
/// kind: 0=values, 1=keys, 2=entries
fn void create_map_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }

    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.MAP_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    map.as_header().incref();
    (*iter.extra_ptr()).iter.target = map;
    (*iter.extra_ptr()).iter.index = 0;
    (*iter.extra_ptr()).iter.kind = kind;
    // MapIterator instances share %MapIteratorPrototype%'s .next and
    // @@toStringTag — mirrors %ArrayIteratorPrototype%'s shared .next.
    iter.prototype = heap.map_iterator_proto;
    ctx.result.set_object(iter);
}

/// Helper: create a Set iterator with a specific kind.
/// kind: 0=values, 1=keys, 2=entries
fn void create_set_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.SET_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    set.as_header().incref();
    (*iter.extra_ptr()).iter.target = set;
    (*iter.extra_ptr()).iter.index = 0;
    (*iter.extra_ptr()).iter.kind = kind;
    // SetIterator instances share %SetIteratorPrototype%'s .next and
    // @@toStringTag — mirrors %ArrayIteratorPrototype%'s shared .next.
    iter.prototype = heap.set_iterator_proto;
    ctx.result.set_object(iter);
}
fn void builtin_array_proto_values(BuiltinContext* ctx) {
    create_array_iterator(ctx, 0);
}

/// Array.prototype.keys — ES2015 §22.1.3.17 (kind=1)
fn void builtin_array_proto_keys(BuiltinContext* ctx) {
    create_array_iterator(ctx, 1);
}

/// Array.prototype.entries — ES2015 §22.1.3.5 (kind=2)
fn void builtin_array_proto_entries(BuiltinContext* ctx) {
    create_array_iterator(ctx, 2);
}

/// String.prototype[Symbol.iterator] — creates a string iterator object.
fn void builtin_string_proto_symbol_iter(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Get `this` — RequireObjectCoercible + ToString, per §22.1.3.30 step 1-2.
    HString* str_data = string_proto_get_this(ctx);
    if (str_data == null) {
        ctx.result.set_undefined();
        return;
    }

    // Create a STRING_ITERATOR object
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.STRING_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    // Store the string as primitive_value (for GC tracing via mark_tval).
    // extra.prim.primitive_value occupies bytes 0-7; extra.iter.index
    // occupies bytes 8-11 — non-overlapping, so both can be used together.
    (*iter.extra_ptr()).prim.primitive_value.set_string(str_data);
    (*iter.extra_ptr()).iter.index = 0;
    // StringIterator instances share %StringIteratorPrototype%'s .next and
    // @@toStringTag — mirrors %ArrayIteratorPrototype%'s shared .next.
    iter.prototype = heap.string_iterator_proto;

    ctx.result.set_object(iter);
}

/// %IteratorPrototype%[@@iterator] (ES6 section 25.1.2.1) — unconditionally
/// returns the `this` value, whatever it is (object, primitive, or even
/// null/undefined) — there is no ReturnIfAbrupt or type check in the spec
/// algorithm.
///
/// `*ctx.result` starts out ALIASING `ctx.this_val` already — every call
/// convention that reaches a builtin (lightfunc or HObject dispatch in
/// vm_call_fn_impl, and the VM's own CALL_PROP handling) seeds the result
/// register with a raw, non-incref'd copy of `this` before the builtin
/// runs, since the result slot doubles as the `this`/callee slot. So
/// `Heap.tval_copy_ref(ctx.result, &ctx.this_val)` is wrong here: it
/// increfs the incoming value but then decrefs `*ctx.result`'s *existing*
/// bits — the same heap object, reached through a different TVal location
/// than `&ctx.this_val`, so the `dst == src` same-pointer guard can't catch
/// the aliasing — silently cancelling the incref and returning an
/// under-refcounted reference (the caller frees it one decref too early).
/// A bare incref (mirroring `set_object`'s convention, extended to every
/// heap-allocated tag) is correct: the stale bits in `*ctx.result` were
/// never independently owned, so nothing needs decrementing.
fn void builtin_iterator_proto_symbol_iter(BuiltinContext* ctx) {
    if (ctx.this_val.is_heap_allocated()) {
        void* ptr = ctx.this_val.get_heapptr();
        if (ptr != null) { ((types::HeapHeader*)ptr).incref(); }
    }
    *ctx.result = ctx.this_val;
}

/// Array iterator .next() — returns {value, done}.
fn void builtin_array_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        builtin_throw(ctx, heap.type_err_proto, "this is not an object");
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.ARRAY_ITERATOR) {
        builtin_throw(ctx, heap.type_err_proto, "this is not an Array Iterator");
        return;
    }

    HObject* target = (*iter.extra_ptr()).iter.target;

    uint idx = (*iter.extra_ptr()).iter.index;

    // Check if done — always use .length (cached array_length for ARRAY exotic)
    bool done = false;
    TVal value;
    value.set_undefined();

    if (target == null) {
        done = true;
    } else {
    // Get length: use cached array_length for ARRAY exotic, TA byte_length for
    // TypedArrays, else .length property for generic objects.
    long len = 0;
    if (target.get_class() == hobject::ObjClass.ARRAY) {
        len = (long)*target.array_len_ptr();
    } else if (is_typed_array_class(target.get_class())) {
        // %ArrayIteratorPrototype%.next re-validates the TypedArray each step
        // (spec: TypedArrayLength on the with-buffer-witness record). A view that
        // has gone out of bounds — e.g. a fixed-length view whose resizable
        // buffer shrank past it mid-iteration — throws a TypeError. A
        // length-tracking view is never OOB from a shrink; its element count
        // simply decreases and iteration ends.
        if (view_is_out_of_bounds(target)) {
            arraybuffer_throw_type_error(ctx, "TypedArray is out of bounds");
            ctx.result.set_undefined();
            return;
        }
        // Re-derive the element count on every next(): length-tracking views
        // over a resizable buffer change length when the buffer is resized.
        len = (long)ta_element_count(target);
    } else {
        TVal? len_val = target.get_prop_proto((HString*)heap.strs[heap::BuiltinStr.LENGTH]);
        if (try lv = len_val) {
            if (lv.is_fastint()) {
                len = lv.get_fastint();
            } else if (lv.is_number()) {
                len = (long)lv.get_number();
            }
        }
    }

    if ((long)idx >= len) {
        done = true;
    } else if (is_typed_array_class(target.get_class())) {
        // TypedArray: read element from backing store directly. Re-derive the
        // data pointer here (a resize may have realloc'd the buffer) and skip
        // the read entirely when the view is out of bounds.
        if (!view_is_out_of_bounds(target)) {
            HObject* ta_buf = (*target.extra_ptr()).view.buffer;
            char* ta_base = (*ta_buf.extra_ptr()).ab.data + (*target.extra_ptr()).view.byte_offset;
            value = ta_load_element(ctx.heap, ta_base, target.get_class(), idx);
        }
        // detached/OOB: value stays undefined (spec: detach mid-iteration -> undefined)
    } else {
        // Try dense array part first, then fall back to property table
        TVal? elem = target.get_array_idx(idx);
        if (try v = elem) {
            value = v;
        } else {
            // Not in dense part — use full [[Get]] semantics (per ES2015 §22.1.5.2
            // step 9): walks the prototype chain, invokes any accessor's getter,
            // and surfaces getter-thrown errors via ctx.should_throw so the
            // surrounding for-of statement propagates them. The previous code
            // called get_prop_proto, which returned the raw accessor slot and
            // silently yielded the GETTER_SETTER object instead of invoking the
            // getter — causing array-key-get-error.js to fail.
            TVal elem_val;
            if (arr_get_elem_vm(target, (ulong)idx, heap, ctx, &elem_val)) {
                value = elem_val;
            } else if (ctx.should_throw) {
                // Getter threw — bail out so the dispatch loop can transfer
                // control to the nearest for-of catcher.
                ctx.result.set_undefined();
                return;
            }
            // else: element is a hole — value stays undefined
        }
    }
    }

    if (done) {
        if ((*iter.extra_ptr()).iter.target != null) {
            heap.decref((types::HeapHeader*)(*iter.extra_ptr()).iter.target);
            (*iter.extra_ptr()).iter.target = null;
        }
    }

    if (!done) {
        (*iter.extra_ptr()).iter.index = idx + 1;

        // Adjust value based on iterator kind (only when not done)
        uint kind = (*iter.extra_ptr()).iter.kind;
        if (kind == 1) {
            // keys() iterator: value = index
            value.set_fastint((long)idx);
        } else if (kind == 2) {
            // entries() iterator: value = [index, value]
            HObject*? pair_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try pair = pair_raw) {
                pair.prototype = heap.array_proto;
                TVal idx_tv;
                idx_tv.set_fastint((long)idx);
                pair.set_array_idx(0, idx_tv);
                pair.set_array_idx(1, value);
                pair.array_used = 2;
                *pair.array_len_ptr() = 2;
                value.set_object(pair);
            }
        }
        // kind==0: value stays as-is (default/@@iterator)
    } else {
        value.set_undefined();
    }

    // Create result object: {value, done}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    // Set .value
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);

    // Set .done
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(done);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result);
}

/// String iterator .next() — returns {value, done}.
fn void builtin_string_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        builtin_throw(ctx, heap.type_err_proto, "this is not an object");
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.STRING_ITERATOR) {
        builtin_throw(ctx, heap.type_err_proto, "this is not a String Iterator");
        return;
    }

    HString* str = (HString*)(*iter.extra_ptr()).prim.primitive_value.get_heapptr();
    if (str == null) {
        ctx.result.set_undefined();
        return;
    }

    uint idx = (*iter.extra_ptr()).iter.index;
    char[] data = str.get_data();

    if (idx >= data.len) {
        // Done — return {value: undefined, done: true}
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv;
        done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        TVal undef;
        undef.set_undefined();
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(result);
        return;
    }

    // ES2015 §22.1.5.1 %StringIteratorPrototype%.next: iterates by Unicode
    // codepoint, not UTF-16 code unit. Under CESU-8 storage an astral
    // codepoint is two adjacent 3-byte surrogate-half sequences — if the
    // first is a high surrogate and a second (low-surrogate) unit follows,
    // yield them together as one step; otherwise yield a single code unit
    // (matches a lone/unpaired surrogate too).
    uint seq_len = hstring::utf8_seq_len(data[idx]);
    usz remain = (usz)(data.len - (long)idx);
    if ((usz)seq_len > remain) {
        seq_len = (uint)remain;
    }
    uint first_cp = hstring::decode_codepoint(data, idx);
    if (hstring::is_high_surrogate(first_cp) && (usz)(idx + seq_len) < data.len) {
        uint next_seq_len = hstring::utf8_seq_len(data[idx + seq_len]);
        uint second_cp = hstring::decode_codepoint(data, idx + seq_len);
        if (hstring::is_low_surrogate(second_cp)) {
            seq_len += next_seq_len;
        }
    }

    (*iter.extra_ptr()).iter.index = idx + seq_len;

    // Create result object: {value: char, done: false}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    // Set .value — code point string (1-4 bytes)
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    HString* cp_str = heap.str_intern(data[idx : seq_len]);
    if (cp_str != null) {
        TVal value_tv;
        value_tv.set_string(cp_str);
        result.put_prop(value_key, value_tv, hobject::PROP_FLAGS_WEC);
    }

    // Set .done
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(false);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result);
}

/// RegExpStringIterator .next() — ES2020 §21.2.7.2.1
/// Lazily yields the next regexp match result.
fn void builtin_regexp_string_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    // Validate this
    if (!this_val.is_object()) {
        builtin_throw(ctx, heap.type_err_proto, "this is not an object");
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.REGEXP_STRING_ITERATOR) {
        builtin_throw(ctx, heap.type_err_proto, "this is not a RegExp String Iterator");
        return;
    }

    // If already done, return {value: undefined, done: true}
    uint flags = (*iter.extra_ptr()).regexp_iter.flags;
    if (flags & 2) { // done bit
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv;
        done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        TVal undef;
        undef.set_undefined();
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(result);
        return;
    }

    HObject* rx = (*iter.extra_ptr()).regexp_iter.regexp;
    HString* s_hstr = (HString*)(*iter.extra_ptr()).regexp_iter.string_val.get_heapptr();
    if (rx == null || s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    bool global_flag = (flags & 1) != 0;
    bool unicode_flag = (flags & 4) != 0;

    // 9. Let match be ? RegExpExec(R, S). Per RegExpExec (§22.2.7.1), this
    // dispatches to a user-supplied `exec` method when callable (checked
    // first, ahead of the built-in matcher), and propagates any throw
    // (e.g. from a `lastIndex` valueOf/ToLength coercion inside a custom
    // `exec`, or from Get(R, "exec") itself).
    TVal s_tv; s_tv.set_string(s_hstr);
    if (!regexp_exec_call(ctx, rx, &s_tv)) return;
    TVal match_tv = *ctx.result;

    // 10. If match is null, then
    if (match_tv.is_null()) {
        // a. Set O.[[Done]] to true.
        (*iter.extra_ptr()).regexp_iter.flags |= 2;
        // b. Return CreateIterResultObject(undefined, true).
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv;
        done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        TVal undef;
        undef.set_undefined();
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(result);
        return;
    }

    // 11. Else,
    HObject* match_obj = (match_tv.is_object() && match_tv.get_heapptr() != null)
        ? (HObject*)match_tv.get_heapptr() : null;
    if (global_flag) {
        // a.i. Let matchStr be ? ToString(? Get(match, "0")).
        HString* zero_key = builtin_intern_string(heap, "0");
        TVal ms_tv; ms_tv.set_undefined();
        if (match_obj != null) {
            TVal? ms_opt = builtins_generic_get(match_obj, zero_key, ctx);
            if (ctx.should_throw) return;
            if (try mv = ms_opt) { ms_tv = mv; }
        }
        HString* match_str = builtin_to_string_vm(ctx, &ms_tv);
        if (ctx.should_throw) return;
        if (match_str == null) match_str = builtin_intern_string(heap, "undefined");

        // a.ii. If matchStr is the empty String, then
        if (match_str.blen == 0) {
            // 1. Let thisIndex be ? ToLength(? Get(R, "lastIndex")).
            HString* li_key = builtin_intern_string(heap, "lastIndex");
            TVal? li_opt = builtins_generic_get(rx, li_key, ctx);
            if (ctx.should_throw) return;
            TVal li_raw; li_raw.set_fastint(0);
            if (try lv = li_opt) { li_raw = lv; }
            double this_d = builtin_to_integer_vm(ctx, &li_raw);
            if (ctx.should_throw) return;
            if (this_d < 0.0) this_d = 0.0;
            long this_index = (long)this_d;

            // 2. Let nextIndex be ! AdvanceStringIndex(S, thisIndex, fullUnicode).
            // thisIndex may be >= the string's char length (e.g. a custom
            // `exec` set a `lastIndex` beyond S) — AdvanceStringIndex is
            // still well-defined there (it just adds 1), so guard against
            // clamped byte-offset round-tripping past the string's end.
            long next_index;
            if ((ulong)this_index >= (ulong)s_hstr.char_length()) {
                next_index = this_index + 1;
            } else {
                char* input = s_hstr.get_cstr();
                int input_len = (int)s_hstr.blen;
                uint byte_off = s_hstr.char_offset_to_byte_offset((uint)this_index);
                int adv_bytes = (int)hstring::advance_string_index_byte_len(
                    input[:input_len], byte_off, unicode_flag);
                uint new_byte_off = byte_off + (uint)adv_bytes;
                next_index = (long)hstring::compute_charlen(input[:new_byte_off]);
            }
            TVal next_tv; next_tv.set_fastint(next_index);

            // 3. Perform ? Set(R, "lastIndex", nextIndex, true).
            if (!regexp_set_with_setter(ctx, rx, li_key, next_tv)) return;
        }
    } else {
        // Non-global: yield exactly one match, then done on subsequent calls.
        (*iter.extra_ptr()).regexp_iter.flags |= 2;
    }

    // a.iii / 12. Return ! CreateIterResultObject(match, false).
    HObject*? iter_result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = iter_result_raw) { ctx.result.set_undefined(); return; }
    HObject* iter_result = iter_result_raw;
    iter_result.prototype = null;

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    iter_result.put_prop(value_key, match_tv, hobject::PROP_FLAGS_WEC);

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(false);
    iter_result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(iter_result);
}

/// Create %IteratorPrototype% (ES6 §25.1.2) and %ArrayIteratorPrototype%.
/// %IteratorPrototype% has [Symbol.iterator]() that returns `this`, while
/// %ArrayIteratorPrototype% owns the shared ArrayIterator.prototype.next method.
fn bool register_iterator_prototype(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // will be wired to object_proto later
    heap.iterator_proto = proto;

    HObject*? array_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = array_proto_raw) return false;
    HObject* array_proto = array_proto_raw;
    array_proto.prototype = proto;
    heap.array_iterator_proto = array_proto;

    // Add [Symbol.iterator]() → returns `this`.
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (catch err = fn_raw) return false;
        HObject* fn_obj = fn_raw;
        (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.ITERATOR_PROTO_SYMBOL_ITER.ordinal;
        fn_obj.flags.callable = true;
        fn_obj.prototype = heap.function_proto;
        // Set .name
        HString* name_key = builtin_intern_string(heap, "name");
        HString* name_val = builtin_intern_string(heap, "[Symbol.iterator]");
        if (name_key != null && name_val != null) {
            TVal name_tv;
            name_tv.set_string(name_val);
            fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
        }
        // Set .length = 0
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            TVal len_tv;
            len_tv.set_fastint(0);
            fn_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
        }
        TVal iter_tv;
        iter_tv.set_object(fn_obj);
        proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_WC);
    }

    // ArrayIteratorPrototype.next is shared by all ArrayIterator instances.
    // Keeping it on the prototype is required so replacing that property is
    // observed by GetIterator consumers such as TypedArray constructors.
    if (!register_string_proto_method(array_proto, heap, "next", Builtin.ARRAY_ITERATOR_NEXT.ordinal)) return false;

    HString* tag_sym = ensure_tostringtag_symbol(heap);
    if (tag_sym != null) {
        TVal tag_tv; tag_tv.set_string(builtin_intern_string(heap, "Array Iterator"));
        array_proto.put_prop(tag_sym, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // %MapIteratorPrototype%, %SetIteratorPrototype%, %StringIteratorPrototype%
    // — dedicated sub-prototypes (mirroring %ArrayIteratorPrototype% above) so
    // each kind gets its own @@toStringTag without polluting %Iterator.prototype%.
    HObject*? map_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = map_proto_raw) return false;
    HObject* map_iter_proto = map_proto_raw;
    map_iter_proto.prototype = proto;
    heap.map_iterator_proto = map_iter_proto;
    if (!register_string_proto_method(map_iter_proto, heap, "next", Builtin.MAP_ITERATOR_NEXT.ordinal)) return false;
    if (tag_sym != null) {
        TVal tag_tv; tag_tv.set_string(builtin_intern_string(heap, "Map Iterator"));
        map_iter_proto.put_prop(tag_sym, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    HObject*? set_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = set_proto_raw) return false;
    HObject* set_iter_proto = set_proto_raw;
    set_iter_proto.prototype = proto;
    heap.set_iterator_proto = set_iter_proto;
    if (!register_string_proto_method(set_iter_proto, heap, "next", Builtin.SET_ITERATOR_NEXT.ordinal)) return false;
    if (tag_sym != null) {
        TVal tag_tv; tag_tv.set_string(builtin_intern_string(heap, "Set Iterator"));
        set_iter_proto.put_prop(tag_sym, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    HObject*? str_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = str_proto_raw) return false;
    HObject* str_iter_proto = str_proto_raw;
    str_iter_proto.prototype = proto;
    heap.string_iterator_proto = str_iter_proto;
    if (!register_string_proto_method(str_iter_proto, heap, "next", Builtin.STRING_ITERATOR_NEXT.ordinal)) return false;
    if (tag_sym != null) {
        TVal tag_tv; tag_tv.set_string(builtin_intern_string(heap, "String Iterator"));
        str_iter_proto.put_prop(tag_sym, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // %RegExpStringIteratorPrototype% (ES2020 §22.2.9.2) — shared by every
    // matchAll iterator instance, mirroring %ArrayIteratorPrototype% above.
    HObject*? regexp_str_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = regexp_str_proto_raw) return false;
    HObject* regexp_str_iter_proto = regexp_str_proto_raw;
    regexp_str_iter_proto.prototype = proto;
    heap.regexp_string_iterator_proto = regexp_str_iter_proto;
    if (!register_string_proto_method(regexp_str_iter_proto, heap, "next", Builtin.REGEXP_STRING_ITERATOR_NEXT.ordinal)) return false;
    if (tag_sym != null) {
        TVal tag_tv; tag_tv.set_string(builtin_intern_string(heap, "RegExp String Iterator"));
        regexp_str_iter_proto.put_prop(tag_sym, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    return true;
}

/// Register an accessor property (getter/setter pair) with the given flags.
fn bool iterhelper_register_accessor(HObject* proto, Heap* heap, void* key, uint getter_idx, uint setter_idx,
                                       char[] getter_name, char[] setter_name) {
    HObject*? getter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = getter_raw) return false;
    HObject* getter = getter_raw;
    getter.flags.callable = true;
    getter.flags.constructable = false;
    getter.prototype = heap.function_proto;
    (*getter.extra_ptr()).func.builtin_fn_index = (int)getter_idx;
    set_func_ctor_name_length(getter, heap, getter_name, 0);

    HObject*? setter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = setter_raw) return false;
    HObject* setter = setter_raw;
    setter.flags.callable = true;
    setter.flags.constructable = false;
    setter.prototype = heap.function_proto;
    (*setter.extra_ptr()).func.builtin_fn_index = (int)setter_idx;
    set_func_ctor_name_length(setter, heap, setter_name, 1);

    TVal getter_tv; getter_tv.set_object(getter);
    TVal setter_tv; setter_tv.set_object(setter);
    hobject::PropFlags acc_flags;
    acc_flags.writable = false;
    acc_flags.enumerable = false;
    acc_flags.configurable = true;
    acc_flags.is_accessor = true;
    proto.put_prop(key, hobject::hobject_create_accessors(heap, getter_tv, setter_tv), acc_flags);
    return true;
}

/// Register the Iterator global constructor, Iterator.prototype's methods
/// (map/filter/take/drop/flatMap/reduce/toArray/forEach/some/every/find),
/// its constructor/@@toStringTag accessor pair, %IteratorHelperPrototype%,
/// and %WrapForValidIteratorPrototype%. Must run after register_iterator_
/// prototype (needs heap.iterator_proto) and after register_function_
/// constructor (needs heap.function_proto).
fn bool register_iterator_ctor_and_helpers(EnvRecord* global_env, Heap* heap) {
    HObject* proto = heap.iterator_proto;
    if (proto == null) return false;

    // Iterator.prototype methods (ES2025 §27.1.3.3).
    if (!register_string_proto_method(proto, heap, "map", Builtin.ITERATOR_PROTO_MAP.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "filter", Builtin.ITERATOR_PROTO_FILTER.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "take", Builtin.ITERATOR_PROTO_TAKE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "drop", Builtin.ITERATOR_PROTO_DROP.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "flatMap", Builtin.ITERATOR_PROTO_FLATMAP.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "reduce", Builtin.ITERATOR_PROTO_REDUCE.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "toArray", Builtin.ITERATOR_PROTO_TOARRAY.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "forEach", Builtin.ITERATOR_PROTO_FOREACH.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "some", Builtin.ITERATOR_PROTO_SOME.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "every", Builtin.ITERATOR_PROTO_EVERY.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "find", Builtin.ITERATOR_PROTO_FIND.ordinal)) return false;

    // Iterator.prototype.constructor — accessor pair (ES2025 §27.1.3.3.1).
    HString* ctor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    if (!iterhelper_register_accessor(proto, heap, ctor_key,
            Builtin.ITERATOR_PROTO_CONSTRUCTOR_GET.ordinal, Builtin.ITERATOR_PROTO_CONSTRUCTOR_SET.ordinal,
            "get constructor", "set constructor")) return false;

    // Iterator.prototype[Symbol.toStringTag] — accessor pair.
    HString* tag_sym = ensure_tostringtag_symbol(heap);
    if (tag_sym != null) {
        if (!iterhelper_register_accessor(proto, heap, tag_sym,
                Builtin.ITERATOR_PROTO_TOSTRINGTAG_GET.ordinal, Builtin.ITERATOR_PROTO_TOSTRINGTAG_SET.ordinal,
                "get [Symbol.toStringTag]", "set [Symbol.toStringTag]")) return false;
    }

    // Create the Iterator constructor function object.
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.prototype = heap.function_proto;
    ctor.flags.callable = true;
    ctor.flags.constructable = true;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.ITERATOR_CTOR.ordinal;
    set_func_ctor_name_length(ctor, heap, "Iterator", 0);
    heap.iterator_ctor = ctor;

    // Iterator.prototype (non-writable, non-enumerable, non-configurable).
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv; proto_tv.set_object(proto);
    hobject::PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Iterator.from(obj).
    if (!register_string_proto_method(ctor, heap, "from", Builtin.ITERATOR_FROM.ordinal)) return false;

    // Iterator.concat(...iterables).
    if (!register_string_proto_method(ctor, heap, "concat", Builtin.ITERATOR_CONCAT.ordinal)) return false;

    // Register the Iterator global binding.
    {
        HString* key = builtin_intern_string(heap, "Iterator");
        if (key == null) return false;
        TVal ctor_tv; ctor_tv.set_object(ctor);
        env::env_declare_nonenum(global_env, key, ctor_tv);
    }

    // %IteratorHelperPrototype% (ES2025 §27.1.2.1): [[Prototype]] is
    // %Iterator.prototype%; owns the shared next()/return() and @@toStringTag.
    HObject*? ih_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = ih_proto_raw) return false;
    HObject* ih_proto = ih_proto_raw;
    ih_proto.prototype = proto;
    heap.iterator_helper_proto = ih_proto;
    if (!register_string_proto_method(ih_proto, heap, "next", Builtin.ITERATOR_HELPER_NEXT.ordinal)) return false;
    if (!register_string_proto_method(ih_proto, heap, "return", Builtin.ITERATOR_HELPER_RETURN.ordinal)) return false;
    if (tag_sym != null) {
        TVal tag_tv; tag_tv.set_string(builtin_intern_string(heap, "Iterator Helper"));
        ih_proto.put_prop(tag_sym, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // %WrapForValidIteratorPrototype% (ES2025 §27.1.3.2.2.1): [[Prototype]]
    // is %Iterator.prototype%; owns the shared next()/return().
    HObject*? wrap_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = wrap_proto_raw) return false;
    HObject* wrap_proto = wrap_proto_raw;
    wrap_proto.prototype = proto;
    heap.wrap_for_valid_iterator_proto = wrap_proto;
    if (!register_string_proto_method(wrap_proto, heap, "next", Builtin.WRAP_FOR_VALID_ITERATOR_NEXT.ordinal)) return false;
    if (!register_string_proto_method(wrap_proto, heap, "return", Builtin.WRAP_FOR_VALID_ITERATOR_RETURN.ordinal)) return false;

    return true;
}

// ============================================================================
// Iterator Helpers (ES2025 §27.1) — Iterator, Iterator.from,
// %IteratorHelperPrototype%, %WrapForValidIteratorPrototype%, and the
// Iterator.prototype methods (map/filter/take/drop/flatMap/reduce/toArray/
// forEach/some/every/find).
// ============================================================================

/// GetV(V, P) — ES2025 §7.3.4: like Get(O, P) but P is looked up on
/// `lookup_obj` (the [[Prototype]]-chain search anchor — a wrapper object
/// for primitive receivers) while any accessor getter found is invoked with
/// Receiver = `receiver` (the true, possibly-primitive, ECMAScript value).
/// Falls back to undefined on a null lookup_obj/key.
fn TVal iterhelper_getv(BuiltinContext* ctx, HObject* lookup_obj, void* key, TVal receiver) {
    TVal undef; undef.set_undefined();
    if (lookup_obj == null || key == null) return undef;
    hobject::PropLookupResult res = lookup_obj.get_prop_or_accessor_proto(key, true);
    switch (res.kind) {
        case hobject::PropLookupKind.PROP_DATA:
            return res.data_val;
        case hobject::PropLookupKind.PROP_ACCESSOR: {
            TVal getter = res.acc.accessor_fn;
            if (getter.is_undefined() || getter.is_null()) return undef;
            if (ctx.heap.call_fn == null || ctx.vm == null) return undef;
            TVal result = ctx.heap.call_fn(ctx.vm, getter, null, 0, receiver);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return undef;
            }
            return result;
        }
        default:
            return undef;
    }
}

/// Build an IteratorResult object {value, done} (ES2015 §7.4.7).
fn HObject* iterhelper_make_result(Heap* heap, TVal value, bool done) {
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) return null;
    HObject* result = result_raw;
    result.prototype = heap.object_proto;
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(done);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
    return result;
}

/// GetIteratorDirect(obj) — ES2025 §7.4.5: Get(obj, "next"), bundled with obj
/// itself as the Iterator Record's [[Iterator]]. Returns false (ctx.should_throw
/// set) only if the `next` lookup itself throws (e.g. a throwing accessor).
fn bool iterhelper_get_iterator_direct(BuiltinContext* ctx, HObject* obj, TVal* out_next) {
    HString* next_key = builtin_intern_string(ctx.heap, "next");
    if (next_key == null) { out_next.set_undefined(); return true; }
    TVal? next_opt = builtins_generic_get(obj, next_key, ctx);
    if (ctx.should_throw) return false;
    if (try nm = next_opt) { *out_next = nm; } else { out_next.set_undefined(); }
    return true;
}

/// IteratorStep + IteratorValue collapsed into one call (IteratorStepValue,
/// ES2025 §7.4.9): calls `next_method` on `iterator`, returns true with
/// *out_value set to the step's .value when not done, false with
/// *out_done = true when done, and false with ctx.should_throw set on error.
fn bool iterhelper_step_value(BuiltinContext* ctx, HObject* iterator, TVal next_method, TVal* out_value, bool* out_done) {
    Heap* heap = ctx.heap;
    *out_done = false;
    bool callable = next_method.is_lightfunc() ||
        (next_method.is_object() && next_method.get_heapptr() != null &&
         ((HObject*)next_method.get_heapptr()).is_callable());
    if (!callable) {
        builtin_throw(ctx, heap.type_err_proto, "next is not a function");
        return false;
    }
    if (heap.call_fn == null || ctx.vm == null) { out_value.set_undefined(); return false; }
    TVal iterator_tv; iterator_tv.set_object(iterator);
    TVal step = heap.call_fn(ctx.vm, next_method, null, 0, iterator_tv);
    if (heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = heap.error_value;
        heap.has_error = false;
        return false;
    }
    if (!step.is_object() || step.get_heapptr() == null) {
        builtin_throw(ctx, heap.type_err_proto, "Iterator result is not an object");
        return false;
    }
    HObject* step_obj = (HObject*)step.get_heapptr();
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal? done_opt = builtins_generic_get(step_obj, done_key, ctx);
    if (ctx.should_throw) return false;
    bool done = false;
    if (try dv = done_opt) { done = builtin_to_boolean(&dv); }
    if (done) { *out_done = true; return false; }
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    TVal? value_opt = builtins_generic_get(step_obj, value_key, ctx);
    if (ctx.should_throw) return false;
    if (try vv = value_opt) { *out_value = vv; } else { out_value.set_undefined(); }
    return true;
}

/// IteratorClose(iteratorRecord, completion) — ES2025 §7.4.11, "closes" the
/// underlying iterator by calling its `.return()` if present. Unlike
/// promise_iterator_close, this can PROPAGATE a throw from return() itself:
/// when `had_error` is false (the original completion was normal) and
/// return() throws, that throw becomes the new completion (ctx.should_throw
/// is set); when `had_error` is true, the original abrupt completion already
/// recorded in ctx takes precedence and return()'s own result/error is
/// discarded, matching "if completion is a throw completion, return ?
/// completion" (step 4).
fn void iterhelper_iterator_close(BuiltinContext* ctx, HObject* iterator, bool had_error) {
    Heap* heap = ctx.heap;
    // `ctx.should_throw`/`ctx.throw_value` already hold the ORIGINAL abrupt
    // completion when had_error is true — clear them before probing `return`
    // so a throw from GetMethod/return() itself can be told apart from the
    // pre-existing one, then restore/override per the rules below.
    TVal saved_throw_value = ctx.throw_value;
    ctx.should_throw = false;

    HString* return_key = builtin_intern_string(heap, "return");
    if (return_key == null) {
        if (had_error) { ctx.should_throw = true; ctx.throw_value = saved_throw_value; }
        return;
    }
    TVal? return_opt = builtins_generic_get(iterator, return_key, ctx);
    if (ctx.should_throw) {
        // GetMethod(iterator, "return") itself threw — this replaces the
        // original completion regardless of whether it was normal or abrupt.
        return;
    }
    TVal return_method;
    if (try rm = return_opt) { return_method = rm; } else { return_method.set_undefined(); }
    if (return_method.is_undefined() || return_method.is_null()) {
        if (had_error) { ctx.should_throw = true; ctx.throw_value = saved_throw_value; }
        return;
    }
    bool callable = return_method.is_lightfunc() ||
        (return_method.is_object() && return_method.get_heapptr() != null &&
         ((HObject*)return_method.get_heapptr()).is_callable());
    if (!callable) {
        if (!had_error) {
            builtin_throw(ctx, heap.type_err_proto, "'return' method is not a function");
        } else {
            ctx.should_throw = true;
            ctx.throw_value = saved_throw_value;
        }
        return;
    }
    if (heap.call_fn == null || ctx.vm == null) {
        if (had_error) { ctx.should_throw = true; ctx.throw_value = saved_throw_value; }
        return;
    }
    TVal iterator_tv; iterator_tv.set_object(iterator);
    heap.call_fn(ctx.vm, return_method, null, 0, iterator_tv);
    if (heap.has_error) {
        if (!had_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
        }
        heap.has_error = false;
        if (had_error) { ctx.should_throw = true; ctx.throw_value = saved_throw_value; }
        return;
    }
    if (had_error) { ctx.should_throw = true; ctx.throw_value = saved_throw_value; }
}

/// GetIteratorFlattenable(obj, primitiveHandling) — ES2025 §7.4.4.
/// primitiveStringsAllowed: when true (Iterator.from), a String primitive is
/// iterated via its own @@iterator; when false (flatMap's inner iterator),
/// any non-Object throws TypeError, no String exception.
/// On success returns true with *out_iterator/*out_next set to the Iterator
/// Record. On failure returns false with ctx.should_throw set.
fn bool iterhelper_get_iterator_flattenable(BuiltinContext* ctx, TVal obj, bool primitive_strings_allowed,
                                             HObject** out_iterator, TVal* out_next) {
    Heap* heap = ctx.heap;
    HObject* obj_obj = null;
    if (obj.is_object() && obj.get_heapptr() != null) {
        obj_obj = (HObject*)obj.get_heapptr();
    } else if (primitive_strings_allowed && obj.is_string() &&
               !(((HString*)obj.get_heapptr()) != null && ((HString*)obj.get_heapptr()).is_symbol())) {
        // Wrap the string primitive so @@iterator can be looked up via
        // String.prototype (mirrors Array.from's primitive-wrapping path).
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) { out_iterator[0] = null; return false; }
        HObject* w = wrapped;
        (*w.extra_ptr()).prim.primitive_value = obj;
        w.prototype = heap.string_proto;
        obj_obj = w;
    } else {
        builtin_throw(ctx, heap.type_err_proto, "not an object");
        return false;
    }

    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym == null) { out_iterator[0] = null; return false; }
    // GetV(obj, @@iterator) — ES2025 §7.3.4: unlike builtins_generic_get
    // (which calls an inherited accessor's getter with `this` = the object
    // that OWNS the accessor), GetV on a wrapped primitive must invoke the
    // getter with Receiver = the ORIGINAL primitive value, matching
    // `Iterator.from('')` observing `typeof this === 'string'` inside a
    // user-defined String.prototype[Symbol.iterator] getter.
    TVal method = iterhelper_getv(ctx, obj_obj, iter_sym, obj);
    if (ctx.should_throw) return false;

    HObject* iterator_obj;
    if (method.is_undefined() || method.is_null()) {
        // No @@iterator: obj itself must already be an iterator object.
        iterator_obj = obj_obj;
    } else {
        bool callable = method.is_lightfunc() ||
            (method.is_object() && method.get_heapptr() != null &&
             ((HObject*)method.get_heapptr()).is_callable());
        if (!callable) {
            builtin_throw(ctx, heap.type_err_proto, "Symbol.iterator is not a function");
            return false;
        }
        if (heap.call_fn == null || ctx.vm == null) { out_iterator[0] = null; return false; }
        // Call with the ORIGINAL value as `this` (not the temporary wrapper
        // object), matching Array.from's primitive-string handling — a
        // String.prototype[Symbol.iterator] call expects a String/string
        // primitive `this`, not a plain OBJECT-class wrapper.
        TVal iterator_val = heap.call_fn(ctx.vm, method, null, 0, obj);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            return false;
        }
        if (!iterator_val.is_object() || iterator_val.get_heapptr() == null) {
            builtin_throw(ctx, heap.type_err_proto, "Result of the Symbol.iterator method is not an object");
            return false;
        }
        iterator_obj = (HObject*)iterator_val.get_heapptr();
    }

    TVal next_method;
    if (!iterhelper_get_iterator_direct(ctx, iterator_obj, &next_method)) return false;
    *out_iterator = iterator_obj;
    *out_next = next_method;
    return true;
}

/// Iterator() — ES2025 §27.1.3.1.1: abstract, subclassable constructor.
/// Throws unless NewTarget is a strict subclass (super() from `class X
/// extends Iterator`), matching "NewTarget is either undefined or the
/// active function object" -> TypeError.
fn void builtin_iterator_ctor(BuiltinContext* ctx) {
    if (ctx.new_target == null || ctx.new_target == ctx.callee_obj) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "Iterator constructor cannot be called directly");
        return;
    }
    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = obj_raw) { ctx.result.set_undefined(); return; }
    HObject* obj = obj_raw;
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.iterator_proto);
    ctx.result.set_object(obj);
}

/// Iterator.from(obj) — ES2025 §27.1.3.2.2.
fn void builtin_iterator_from(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal obj = builtin_arg(ctx, 0);

    HObject* iterator_obj;
    TVal next_method;
    if (!iterhelper_get_iterator_flattenable(ctx, obj, true, &iterator_obj, &next_method)) {
        ctx.result.set_undefined();
        return;
    }

    // hasInstance = OrdinaryHasInstance(%Iterator%, iteratorRecord.[[Iterator]])
    bool has_instance = false;
    {
        HObject* cur = iterator_obj;
        uint depth = 0;
        while (cur != null && depth < hobject::MAX_PROTO_DEPTH) {
            if (cur == heap.iterator_proto) { has_instance = true; break; }
            if (cur.flags.exotic_proxyobj) {
                TVal next;
                if (!proxy_mop_get_proto(ctx.vm, heap, cur, &next)) {
                    if (heap.has_error) {
                        ctx.should_throw = true;
                        ctx.throw_value = heap.error_value;
                        heap.has_error = false;
                    }
                    ctx.result.set_undefined();
                    return;
                }
                cur = next.is_object() ? (HObject*)next.get_heapptr() : null;
            } else {
                cur = cur.prototype;
            }
            depth++;
        }
    }
    // OrdinaryHasInstance walks C.prototype's chain against V — but we're
    // checking whether %Iterator.prototype% itself appears on iterator_obj's
    // OWN prototype chain, which is exactly "V instanceof %Iterator%".

    if (has_instance) {
        ctx.result.set_object(iterator_obj);
        return;
    }

    HObject*? wrapper_raw = heap.alloc_object(hobject::ObjClass.WRAP_FOR_VALID_ITERATOR);
    if (catch err = wrapper_raw) { ctx.result.set_undefined(); return; }
    HObject* wrapper = wrapper_raw;
    wrapper.prototype = heap.wrap_for_valid_iterator_proto;
    (*wrapper.extra_ptr()).wrap_iter.iterated = iterator_obj;
    (*wrapper.extra_ptr()).wrap_iter.next_method = next_method;
    ctx.result.set_object(wrapper);
}

/// get Iterator.prototype.constructor — ES2025 §27.1.3.3.1.1.
fn void builtin_iterator_proto_constructor_get(BuiltinContext* ctx) {
    if (ctx.heap.iterator_ctor != null) {
        ctx.result.set_object(ctx.heap.iterator_ctor);
    } else {
        ctx.result.set_undefined();
    }
}

/// set Iterator.prototype.constructor — ES2025 §27.1.3.3.1.2:
/// SetterThatIgnoresPrototypeProperties(this, %Iterator.prototype%, "constructor", v).
fn void builtin_iterator_proto_constructor_set(BuiltinContext* ctx) {
    HString* key = (HString*)ctx.heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    iterhelper_setter_ignores_prototype_properties(ctx, ctx.heap.iterator_proto, key);
    ctx.result.set_undefined();
}

/// get Iterator.prototype[Symbol.toStringTag] — ES2025 §27.1.3.3.13(ish).
fn void builtin_iterator_proto_tostringtag_get(BuiltinContext* ctx) {
    HString* s = builtin_intern_string(ctx.heap, "Iterator");
    if (s != null) { ctx.result.set_string(s); } else { ctx.result.set_undefined(); }
}

/// set Iterator.prototype[Symbol.toStringTag] —
/// SetterThatIgnoresPrototypeProperties(this, %Iterator.prototype%, %Symbol.toStringTag%, v).
fn void builtin_iterator_proto_tostringtag_set(BuiltinContext* ctx) {
    HString* key = ensure_tostringtag_symbol(ctx.heap);
    iterhelper_setter_ignores_prototype_properties(ctx, ctx.heap.iterator_proto, key);
    ctx.result.set_undefined();
}

/// SetterThatIgnoresPrototypeProperties(thisValue, home, propertyKey, value)
/// — ES2025 §7.3.37. `value` is the setter's sole argument (ctx.regs[base_reg]).
fn void iterhelper_setter_ignores_prototype_properties(BuiltinContext* ctx, HObject* home, void* property_key) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    TVal value = builtin_arg(ctx, 0);

    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, heap.type_err_proto, "cannot set property on a non-object");
        return;
    }
    HObject* this_obj = (HObject*)this_val.get_heapptr();
    if (this_obj == home) {
        builtin_throw(ctx, heap.type_err_proto, "cannot assign to read only property");
        return;
    }
    if (property_key == null) return;

    // "Let propertyDesc be ? thisValue.[[GetOwnProperty]](propertyKey)." — an
    // own accessor property must invoke its setter (Set semantics); an own
    // data property is simply overwritten in place. Neither case exists here
    // beyond a plain data-property lookup since thisValue is arbitrary
    // ECMAScript-authored code (own accessor "constructor"/@@toStringTag
    // properties are vanishingly rare test surface but handled below).
    int idx = this_obj.find_prop_idx(property_key);
    if (idx >= 0) {
        hobject::PropFlags pf = this_obj.get_prop_flags((uint)idx);
        if (pf.is_accessor) {
            TVal setter = hobject::hobject_access_setter(this_obj.prop_values()[idx]);
            bool callable = setter.is_lightfunc() ||
                (setter.is_object() && setter.get_heapptr() != null &&
                 ((HObject*)setter.get_heapptr()).is_callable());
            if (callable && heap.call_fn != null && ctx.vm != null) {
                TVal[1] args = { value };
                heap.call_fn(ctx.vm, setter, &args[0], 1, this_val);
                if (heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = heap.error_value;
                    heap.has_error = false;
                }
            }
            return;
        }
        if (!pf.writable) {
            builtin_throw(ctx, heap.type_err_proto, "cannot assign to read only property");
            return;
        }
        this_obj.put_prop(property_key, value, pf);
        return;
    }

    // "If propertyDesc is undefined ... CreateDataPropertyOrThrow" — own
    // property is absent, so create a plain WEC data property (matching
    // CreateDataProperty on a non-exotic ordinary object).
    if (!this_obj.is_extensible()) {
        builtin_throw(ctx, heap.type_err_proto, "object is not extensible");
        return;
    }
    if (!this_obj.put_prop(property_key, value, hobject::PROP_FLAGS_WEC)) {
        builtin_throw(ctx, heap.type_err_proto, "Cannot add property, no space left");
    }
}

/// %WrapForValidIteratorPrototype%.next() — ES2025 §27.1.3.2.2.1.1.
fn void builtin_wrap_for_valid_iterator_next(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null ||
        ((HObject*)this_val.get_heapptr()).get_class() != hobject::ObjClass.WRAP_FOR_VALID_ITERATOR) {
        builtin_throw(ctx, heap.type_err_proto, "not a WrapForValidIterator object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    HObject* iterated = (*obj.extra_ptr()).wrap_iter.iterated;
    TVal next_method = (*obj.extra_ptr()).wrap_iter.next_method;

    bool callable = next_method.is_lightfunc() ||
        (next_method.is_object() && next_method.get_heapptr() != null &&
         ((HObject*)next_method.get_heapptr()).is_callable());
    if (!callable) {
        builtin_throw(ctx, heap.type_err_proto, "next is not a function");
        return;
    }
    if (heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return; }
    TVal iterated_tv; iterated_tv.set_object(iterated);
    TVal step = heap.call_fn(ctx.vm, next_method, null, 0, iterated_tv);
    if (heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = heap.error_value;
        heap.has_error = false;
        ctx.result.set_undefined();
        return;
    }
    *ctx.result = step;
}

/// %WrapForValidIteratorPrototype%.return() — ES2025 §27.1.3.2.2.1.2.
fn void builtin_wrap_for_valid_iterator_return(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null ||
        ((HObject*)this_val.get_heapptr()).get_class() != hobject::ObjClass.WRAP_FOR_VALID_ITERATOR) {
        builtin_throw(ctx, heap.type_err_proto, "not a WrapForValidIterator object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    HObject* iterator = (*obj.extra_ptr()).wrap_iter.iterated;

    HString* return_key = builtin_intern_string(heap, "return");
    TVal? return_opt = builtins_generic_get(iterator, return_key, ctx);
    if (ctx.should_throw) { ctx.result.set_undefined(); return; }
    TVal return_method;
    if (try rm = return_opt) { return_method = rm; } else { return_method.set_undefined(); }

    if (return_method.is_undefined() || return_method.is_null()) {
        TVal undef; undef.set_undefined();
        HObject* result = iterhelper_make_result(heap, undef, true);
        if (result != null) { ctx.result.set_object(result); } else { ctx.result.set_undefined(); }
        return;
    }
    bool callable = return_method.is_lightfunc() ||
        (return_method.is_object() && return_method.get_heapptr() != null &&
         ((HObject*)return_method.get_heapptr()).is_callable());
    if (!callable) {
        builtin_throw(ctx, heap.type_err_proto, "return is not a function");
        return;
    }
    if (heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return; }
    TVal iterator_tv; iterator_tv.set_object(iterator);
    TVal step = heap.call_fn(ctx.vm, return_method, null, 0, iterator_tv);
    if (heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = heap.error_value;
        heap.has_error = false;
        ctx.result.set_undefined();
        return;
    }
    *ctx.result = step;
}

// ----------------------------------------------------------------------------
// Iterator Helper object state machine (backs %IteratorHelperPrototype%).
// ----------------------------------------------------------------------------

const uint IH_STATE_SUSPENDED = 0;  /// Not yet exhausted, safe to resume.
const uint IH_STATE_EXECUTING = 1;  /// Re-entered from within its own step (throws).
const uint IH_STATE_COMPLETED = 2;  /// Exhausted or closed; next() always returns done.

const uint IH_KIND_MAP     = 0;
const uint IH_KIND_FILTER  = 1;
const uint IH_KIND_TAKE    = 2;
const uint IH_KIND_DROP    = 3;
const uint IH_KIND_FLATMAP = 4;
const uint IH_KIND_CONCAT  = 5;

/// Shared constructor for every lazy Iterator Helper object.
fn HObject* iterhelper_create(Heap* heap, HObject* underlying, TVal next_method, TVal callback, uint kind, double remaining) {
    HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.ITERATOR_HELPER);
    if (catch err = obj_raw) return null;
    HObject* obj = obj_raw;
    obj.prototype = heap.iterator_helper_proto;
    (*obj.extra_ptr()).iter_helper.underlying = underlying;
    (*obj.extra_ptr()).iter_helper.next_method = next_method;
    (*obj.extra_ptr()).iter_helper.callback = callback;
    (*obj.extra_ptr()).iter_helper.remaining = remaining;
    (*obj.extra_ptr()).iter_helper.counter = 0;
    (*obj.extra_ptr()).iter_helper.kind = kind;
    (*obj.extra_ptr()).iter_helper.state = IH_STATE_SUSPENDED;
    (*obj.extra_ptr()).iter_helper.inner_iter = null;
    (*obj.extra_ptr()).iter_helper.inner_next.set_undefined();
    return obj;
}

/// %IteratorHelperPrototype%.next() — drives one step of the helper's
/// closure. Real generators suspend mid-closure; this state machine instead
/// re-derives "where the closure would be" from `counter`/`remaining`/
/// `inner_iter` and runs straight through to the next yield point (or to
/// exhaustion) on every call — equivalent because every helper kind here
/// yields at most once per external next() call, except flatMap, whose inner
/// loop is resumed via the persisted inner_iter/inner_next fields.
fn void builtin_iterator_helper_next(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null ||
        ((HObject*)this_val.get_heapptr()).get_class() != hobject::ObjClass.ITERATOR_HELPER) {
        builtin_throw(ctx, heap.type_err_proto, "not an Iterator Helper object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    HObjectIteratorHelper* ih = &(*obj.extra_ptr()).iter_helper;

    if (ih.state == IH_STATE_EXECUTING) {
        builtin_throw(ctx, heap.type_err_proto, "Iterator Helper is already executing");
        return;
    }
    if (ih.state == IH_STATE_COMPLETED) {
        TVal undef; undef.set_undefined();
        HObject* result = iterhelper_make_result(heap, undef, true);
        if (result != null) { ctx.result.set_object(result); } else { ctx.result.set_undefined(); }
        return;
    }

    ih.state = IH_STATE_EXECUTING;
    TVal out_value;
    bool done_result = false;
    bool ok = iterhelper_run_step(ctx, obj, ih, &out_value, &done_result);
    // ctx.should_throw firing mid-closure is itself an abrupt completion —
    // the helper is finished either way once run_step returns.
    if (!ok || done_result) {
        ih.state = IH_STATE_COMPLETED;
        if (!ok) { ctx.result.set_undefined(); return; }
        TVal undef; undef.set_undefined();
        HObject* result = iterhelper_make_result(heap, undef, true);
        if (result != null) { ctx.result.set_object(result); } else { ctx.result.set_undefined(); }
        return;
    }
    ih.state = IH_STATE_SUSPENDED;
    HObject* result = iterhelper_make_result(heap, out_value, false);
    if (result != null) { ctx.result.set_object(result); } else { ctx.result.set_undefined(); }
}

/// Runs the closure body for one step. Returns false (ctx.should_throw set)
/// on an abrupt completion the underlying iterator has already been closed
/// for (via IfAbruptCloseIterator); returns true with *out_done=true when
/// the closure reaches its natural ReturnCompletion(undefined) end; returns
/// true with *out_done=false and *out_value set when it yields a value.
fn bool iterhelper_run_step(BuiltinContext* ctx, HObject* obj, HObjectIteratorHelper* ih, TVal* out_value, bool* out_done) {
    Heap* heap = ctx.heap;
    switch (ih.kind) {
        case IH_KIND_MAP: {
            TVal value;
            bool step_done;
            if (!iterhelper_step_value(ctx, ih.underlying, ih.next_method, &value, &step_done)) {
                if (step_done) { *out_done = true; return true; }
                iterhelper_iterator_close(ctx, ih.underlying, true);
                return false;
            }
            TVal counter_tv; counter_tv.set_fastint((long)ih.counter);
            TVal[2] args = { value, counter_tv };
            if (heap.call_fn == null || ctx.vm == null) { out_value.set_undefined(); return false; }
            TVal undef_this; undef_this.set_undefined();
            TVal mapped = heap.call_fn(ctx.vm, ih.callback, &args[0], 2, undef_this);
            if (heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = heap.error_value;
                heap.has_error = false;
                iterhelper_iterator_close(ctx, ih.underlying, true);
                return false;
            }
            ih.counter += 1;
            *out_value = mapped;
            return true;
        }
        case IH_KIND_FILTER: {
            while (true) {
                TVal value;
                bool step_done;
                if (!iterhelper_step_value(ctx, ih.underlying, ih.next_method, &value, &step_done)) {
                    if (step_done) { *out_done = true; return true; }
                    iterhelper_iterator_close(ctx, ih.underlying, true);
                    return false;
                }
                TVal counter_tv; counter_tv.set_fastint((long)ih.counter);
                TVal[2] args = { value, counter_tv };
                if (heap.call_fn == null || ctx.vm == null) { out_value.set_undefined(); return false; }
                TVal undef_this; undef_this.set_undefined();
                TVal selected = heap.call_fn(ctx.vm, ih.callback, &args[0], 2, undef_this);
                if (heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = heap.error_value;
                    heap.has_error = false;
                    iterhelper_iterator_close(ctx, ih.underlying, true);
                    return false;
                }
                ih.counter += 1;
                if (builtin_to_boolean(&selected)) {
                    *out_value = value;
                    return true;
                }
            }
        }
        case IH_KIND_TAKE: {
            if (ih.remaining == 0.0) {
                iterhelper_iterator_close(ctx, ih.underlying, false);
                if (ctx.should_throw) return false;
                *out_done = true;
                return true;
            }
            if (ih.remaining != double::inf) {
                ih.remaining -= 1.0;
            }
            TVal value;
            bool step_done;
            if (!iterhelper_step_value(ctx, ih.underlying, ih.next_method, &value, &step_done)) {
                if (step_done) { *out_done = true; return true; }
                return false;
            }
            *out_value = value;
            return true;
        }
        case IH_KIND_DROP: {
            while (ih.remaining > 0.0) {
                if (ih.remaining != double::inf) {
                    ih.remaining -= 1.0;
                }
                TVal value;
                bool step_done;
                if (!iterhelper_step_value(ctx, ih.underlying, ih.next_method, &value, &step_done)) {
                    if (step_done) { *out_done = true; return true; }
                    return false;
                }
            }
            TVal value;
            bool step_done;
            if (!iterhelper_step_value(ctx, ih.underlying, ih.next_method, &value, &step_done)) {
                if (step_done) { *out_done = true; return true; }
                return false;
            }
            *out_value = value;
            return true;
        }
        case IH_KIND_FLATMAP: {
            while (true) {
                if (ih.inner_iter != null) {
                    TVal inner_value;
                    bool inner_done;
                    if (!iterhelper_step_value(ctx, ih.inner_iter, ih.inner_next, &inner_value, &inner_done)) {
                        if (!inner_done) {
                            // Inner iterator itself threw — close it (backup
                            // completion is discarded per spec step) then
                            // close the outer iterator with this completion.
                            bool inner_had_error = ctx.should_throw;
                            iterhelper_iterator_close(ctx, ih.inner_iter, true);
                            ih.inner_iter = null;
                            iterhelper_iterator_close(ctx, ih.underlying, inner_had_error);
                            return false;
                        }
                        ih.inner_iter = null;
                    } else {
                        *out_value = inner_value;
                        return true;
                    }
                }

                TVal value;
                bool step_done;
                if (!iterhelper_step_value(ctx, ih.underlying, ih.next_method, &value, &step_done)) {
                    if (step_done) { *out_done = true; return true; }
                    iterhelper_iterator_close(ctx, ih.underlying, true);
                    return false;
                }
                TVal counter_tv; counter_tv.set_fastint((long)ih.counter);
                TVal[2] args = { value, counter_tv };
                if (heap.call_fn == null || ctx.vm == null) { out_value.set_undefined(); return false; }
                TVal undef_this; undef_this.set_undefined();
                TVal mapped = heap.call_fn(ctx.vm, ih.callback, &args[0], 2, undef_this);
                if (heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = heap.error_value;
                    heap.has_error = false;
                    iterhelper_iterator_close(ctx, ih.underlying, true);
                    return false;
                }
                HObject* inner_iterator;
                TVal inner_next_method;
                if (!iterhelper_get_iterator_flattenable(ctx, mapped, false, &inner_iterator, &inner_next_method)) {
                    iterhelper_iterator_close(ctx, ih.underlying, true);
                    return false;
                }
                ih.counter += 1;
                ih.inner_iter = inner_iterator;
                ih.inner_next = inner_next_method;
            }
        }
        case IH_KIND_CONCAT: {
            // concat sequences through multiple iterables stored in a wrapper.
            // wrapper.iterables: array of iterables (validated at concat() time)
            // wrapper.methods: array of their @@iterator methods (pre-fetched at concat() time)
            // counter: current index into the arrays
            while (true) {
                // If we have an active inner iterator, try to get its next value
                if (ih.inner_iter != null) {
                    TVal value;
                    bool step_done;
                    if (!iterhelper_step_value(ctx, ih.inner_iter, ih.inner_next, &value, &step_done)) {
                        if (step_done) {
                            // Inner iterator exhausted (returned done=true).
                            // Per spec, we don't call return() on exhausted iterators.
                            // Just clear it and move to the next iterable.
                            ih.inner_iter = null;
                            ih.counter += 1;
                            continue;
                        }
                        // Inner iterator threw — close the outer iterator too
                        iterhelper_iterator_close(ctx, ih.underlying, true);
                        return false;
                    }
                    // Yielded a value
                    *out_value = value;
                    return true;
                }

                // No active inner iterator — get the next iterable and its method
                HObject* wrapper = ih.underlying;
                if (wrapper == null) { *out_done = true; return true; }

                // Get the total count of iterables
                HString* count_key = builtin_intern_string(heap, "count");
                if (count_key == null) { *out_done = true; return true; }
                TVal? count_opt = wrapper.get_prop_proto(count_key);
                if (ctx.should_throw) return false;
                long count = 0;
                if (try count_tv = count_opt) {
                    if (count_tv.is_fastint()) {
                        count = count_tv.get_fastint();
                    } else if (count_tv.is_number()) {
                        count = (long)count_tv.get_number();
                    }
                }

                // Check if we've exhausted all iterables
                if ((long)ih.counter >= count) {
                    *out_done = true;
                    return true;
                }

                // Get iterables and methods arrays
                HString* iterables_key = builtin_intern_string(heap, "iterables");
                if (iterables_key == null) { *out_done = true; return true; }
                TVal? iterables_opt = wrapper.get_prop_proto(iterables_key);
                if (ctx.should_throw) return false;
                TVal iterables_tv;
                if (try itv = iterables_opt) { iterables_tv = itv; } else { *out_done = true; return true; }

                if (!iterables_tv.is_object() || iterables_tv.get_heapptr() == null) {
                    *out_done = true;
                    return true;
                }
                HObject* iterables_arr = (HObject*)iterables_tv.get_heapptr();

                HString* methods_key = builtin_intern_string(heap, "methods");
                if (methods_key == null) { *out_done = true; return true; }
                TVal? methods_opt = wrapper.get_prop_proto(methods_key);
                if (ctx.should_throw) return false;
                TVal methods_tv;
                if (try mtv = methods_opt) { methods_tv = mtv; } else { *out_done = true; return true; }

                if (!methods_tv.is_object() || methods_tv.get_heapptr() == null) {
                    *out_done = true;
                    return true;
                }
                HObject* methods_arr = (HObject*)methods_tv.get_heapptr();

                // Get the current iterable and its pre-fetched method
                TVal? iterable_opt = iterables_arr.get_array_idx((uint)ih.counter);
                TVal iterable_tv;
                if (try itv = iterable_opt) { iterable_tv = itv; } else {
                    // Hole in array, skip to next
                    ih.counter += 1;
                    continue;
                }

                TVal? method_opt = methods_arr.get_array_idx((uint)ih.counter);
                TVal method_tv;
                if (try mtv = method_opt) { method_tv = mtv; } else {
                    // Should not happen if stored correctly
                    ih.counter += 1;
                    continue;
                }

                // Call the pre-fetched @@iterator method on the iterable
                bool callable = method_tv.is_lightfunc() ||
                    (method_tv.is_object() && method_tv.get_heapptr() != null &&
                     ((HObject*)method_tv.get_heapptr()).is_callable());
                if (!callable) {
                    // Should not happen if validated correctly, but close and fail gracefully
                    iterhelper_iterator_close(ctx, ih.underlying, true);
                    builtin_throw(ctx, heap.type_err_proto, "Iterator method is not callable");
                    return false;
                }

                if (heap.call_fn == null || ctx.vm == null) {
                    iterhelper_iterator_close(ctx, ih.underlying, true);
                    return false;
                }

                // Call method(iterable) to get the iterator
                TVal iterator_val = heap.call_fn(ctx.vm, method_tv, null, 0, iterable_tv);
                if (heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = heap.error_value;
                    heap.has_error = false;
                    iterhelper_iterator_close(ctx, ih.underlying, true);
                    return false;
                }

                // Validate the returned iterator
                if (!iterator_val.is_object() || iterator_val.get_heapptr() == null) {
                    builtin_throw(ctx, heap.type_err_proto, "Iterator method did not return an object");
                    iterhelper_iterator_close(ctx, ih.underlying, true);
                    return false;
                }

                HObject* iterator = (HObject*)iterator_val.get_heapptr();

                // Get the next method from the iterator
                TVal next_method;
                if (!iterhelper_get_iterator_direct(ctx, iterator, &next_method)) {
                    iterhelper_iterator_close(ctx, ih.underlying, true);
                    return false;
                }

                // Set as active inner iterator
                ih.inner_iter = iterator;
                ih.inner_next = next_method;
                // Note: counter will be incremented when this iterator is exhausted
            }
        }
        default:
            *out_done = true;
            return true;
    }
}

/// %IteratorHelperPrototype%.return() — ES2025 §27.1.2.1.2.
fn void builtin_iterator_helper_return(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null ||
        ((HObject*)this_val.get_heapptr()).get_class() != hobject::ObjClass.ITERATOR_HELPER) {
        builtin_throw(ctx, heap.type_err_proto, "not an Iterator Helper object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    HObjectIteratorHelper* ih = &(*obj.extra_ptr()).iter_helper;

    if (ih.state == IH_STATE_EXECUTING) {
        builtin_throw(ctx, heap.type_err_proto, "Iterator Helper is already executing");
        return;
    }

    if (ih.state != IH_STATE_COMPLETED) {
        ih.state = IH_STATE_EXECUTING;
        if (ih.inner_iter != null) {
            iterhelper_iterator_close(ctx, ih.inner_iter, false);
            ih.inner_iter = null;
            // A throw here still must close the outer/underlying iterator
            // before propagating (IteratorCloseAll closes in reverse order).
            bool had_error = ctx.should_throw;
            iterhelper_iterator_close(ctx, ih.underlying, had_error);
            ih.state = IH_STATE_COMPLETED;
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        } else {
            iterhelper_iterator_close(ctx, ih.underlying, false);
            ih.state = IH_STATE_COMPLETED;
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
        }
    }

    TVal undef; undef.set_undefined();
    HObject* result = iterhelper_make_result(heap, undef, true);
    if (result != null) { ctx.result.set_object(result); } else { ctx.result.set_undefined(); }
}

// ----------------------------------------------------------------------------
// Iterator.prototype lazy methods: map, filter, take, drop, flatMap.
// ----------------------------------------------------------------------------

/// Iterator.prototype.map(mapper) — ES2025 §27.1.3.3.8.
fn void builtin_iterator_proto_map(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, heap.type_err_proto, "Iterator.prototype.map called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    TVal mapper = builtin_arg(ctx, 0);
    if (!arr_from_is_callable(mapper)) {
        builtin_throw(ctx, heap.type_err_proto, "mapper is not a function");
        bool had_error = ctx.should_throw;
        iterhelper_iterator_close(ctx, obj, had_error);
        ctx.result.set_undefined();
        return;
    }
    TVal next_method;
    if (!iterhelper_get_iterator_direct(ctx, obj, &next_method)) { ctx.result.set_undefined(); return; }

    HObject* helper = iterhelper_create(heap, obj, next_method, mapper, IH_KIND_MAP, 0.0);
    if (helper != null) { ctx.result.set_object(helper); } else { ctx.result.set_undefined(); }
}

/// Iterator.prototype.filter(predicate) — ES2025 §27.1.3.3.4.
fn void builtin_iterator_proto_filter(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, heap.type_err_proto, "Iterator.prototype.filter called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    TVal predicate = builtin_arg(ctx, 0);
    if (!arr_from_is_callable(predicate)) {
        builtin_throw(ctx, heap.type_err_proto, "predicate is not a function");
        bool had_error = ctx.should_throw;
        iterhelper_iterator_close(ctx, obj, had_error);
        ctx.result.set_undefined();
        return;
    }
    TVal next_method;
    if (!iterhelper_get_iterator_direct(ctx, obj, &next_method)) { ctx.result.set_undefined(); return; }

    HObject* helper = iterhelper_create(heap, obj, next_method, predicate, IH_KIND_FILTER, 0.0);
    if (helper != null) { ctx.result.set_object(helper); } else { ctx.result.set_undefined(); }
}

/// Shared ToIntegerOrInfinity(limit) + RangeError(NaN/negative) validation for
/// take/drop. On failure closes `this_obj` (IfAbruptCloseIterator against an
/// Iterator Record whose [[NextMethod]] is still unset, per spec — the
/// underlying `.next` must not be read before validation succeeds) and sets
/// ctx.should_throw. Returns true with *out_limit set on success.
fn bool iterhelper_validate_limit(BuiltinContext* ctx, HObject* this_obj, double* out_limit) {
    Heap* heap = ctx.heap;
    TVal limit = builtin_arg(ctx, 0);
    double num_limit = builtin_to_number_vm(ctx, &limit);
    if (ctx.should_throw) {
        iterhelper_iterator_close(ctx, this_obj, true);
        return false;
    }
    if (math::is_nan(num_limit)) {
        builtin_throw(ctx, heap.range_err_proto, "Invalid limit");
        bool had_error = ctx.should_throw;
        iterhelper_iterator_close(ctx, this_obj, had_error);
        return false;
    }
    double int_limit = math::is_inf(num_limit) ? num_limit : math::trunc(num_limit);
    if (int_limit < 0) {
        builtin_throw(ctx, heap.range_err_proto, "Invalid limit");
        bool had_error = ctx.should_throw;
        iterhelper_iterator_close(ctx, this_obj, had_error);
        return false;
    }
    *out_limit = int_limit;
    return true;
}

/// Iterator.prototype.take(limit) — ES2025 §27.1.3.3.11.
fn void builtin_iterator_proto_take(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, heap.type_err_proto, "Iterator.prototype.take called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    double limit;
    if (!iterhelper_validate_limit(ctx, obj, &limit)) { ctx.result.set_undefined(); return; }

    TVal next_method;
    if (!iterhelper_get_iterator_direct(ctx, obj, &next_method)) { ctx.result.set_undefined(); return; }

    TVal unused; unused.set_undefined();
    HObject* helper = iterhelper_create(heap, obj, next_method, unused, IH_KIND_TAKE, limit);
    if (helper != null) { ctx.result.set_object(helper); } else { ctx.result.set_undefined(); }
}

/// Iterator.prototype.drop(limit) — ES2025 §27.1.3.3.2.
fn void builtin_iterator_proto_drop(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, heap.type_err_proto, "Iterator.prototype.drop called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    double limit;
    if (!iterhelper_validate_limit(ctx, obj, &limit)) { ctx.result.set_undefined(); return; }

    TVal next_method;
    if (!iterhelper_get_iterator_direct(ctx, obj, &next_method)) { ctx.result.set_undefined(); return; }

    TVal unused; unused.set_undefined();
    HObject* helper = iterhelper_create(heap, obj, next_method, unused, IH_KIND_DROP, limit);
    if (helper != null) { ctx.result.set_object(helper); } else { ctx.result.set_undefined(); }
}

/// Iterator.prototype.flatMap(mapper) — ES2025 §27.1.3.3.6.
fn void builtin_iterator_proto_flatmap(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, heap.type_err_proto, "Iterator.prototype.flatMap called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    TVal mapper = builtin_arg(ctx, 0);
    if (!arr_from_is_callable(mapper)) {
        builtin_throw(ctx, heap.type_err_proto, "mapper is not a function");
        bool had_error = ctx.should_throw;
        iterhelper_iterator_close(ctx, obj, had_error);
        ctx.result.set_undefined();
        return;
    }
    TVal next_method;
    if (!iterhelper_get_iterator_direct(ctx, obj, &next_method)) { ctx.result.set_undefined(); return; }

    HObject* helper = iterhelper_create(heap, obj, next_method, mapper, IH_KIND_FLATMAP, 0.0);
    if (helper != null) { ctx.result.set_object(helper); } else { ctx.result.set_undefined(); }
}

// ----------------------------------------------------------------------------
// Iterator.prototype eager methods: reduce, toArray, forEach, some, every, find.
// ----------------------------------------------------------------------------

/// Validate `this` is an object and IsCallable(fn); on success returns the
/// Iterator Record (obj, next_method) via GetIteratorDirect. On any failure
/// closes obj (if the callable check failed) and sets ctx.should_throw.
fn bool iterhelper_eager_setup(BuiltinContext* ctx, TVal callback, char[] not_callable_msg, HObject** out_obj, TVal* out_next) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, heap.type_err_proto, "called on non-object");
        return false;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (!arr_from_is_callable(callback)) {
        builtin_throw(ctx, heap.type_err_proto, not_callable_msg);
        bool had_error = ctx.should_throw;
        iterhelper_iterator_close(ctx, obj, had_error);
        return false;
    }
    TVal next_method;
    if (!iterhelper_get_iterator_direct(ctx, obj, &next_method)) return false;
    *out_obj = obj;
    *out_next = next_method;
    return true;
}

/// Iterator.prototype.reduce(reducer[, initialValue]) — ES2025 §27.1.3.3.9.
fn void builtin_iterator_proto_reduce(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal reducer = builtin_arg(ctx, 0);
    HObject* obj;
    TVal next_method;
    if (!iterhelper_eager_setup(ctx, reducer, "reducer is not a function", &obj, &next_method)) {
        ctx.result.set_undefined();
        return;
    }

    TVal accumulator;
    double counter;
    if (ctx.argc < 2) {
        bool step_done;
        if (!iterhelper_step_value(ctx, obj, next_method, &accumulator, &step_done)) {
            if (step_done) {
                builtin_throw(ctx, heap.type_err_proto, "Reduce of empty iterator with no initial value");
            }
            ctx.result.set_undefined();
            return;
        }
        counter = 1;
    } else {
        accumulator = builtin_arg(ctx, 1);
        counter = 0;
    }

    while (true) {
        TVal value;
        bool step_done;
        if (!iterhelper_step_value(ctx, obj, next_method, &value, &step_done)) {
            if (step_done) { *ctx.result = accumulator; return; }
            ctx.result.set_undefined();
            return;
        }
        TVal counter_tv; counter_tv.set_fastint((long)counter);
        TVal[3] args = { accumulator, value, counter_tv };
        if (heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return; }
        TVal undef_this; undef_this.set_undefined();
        TVal result = heap.call_fn(ctx.vm, reducer, &args[0], 3, undef_this);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            iterhelper_iterator_close(ctx, obj, true);
            ctx.result.set_undefined();
            return;
        }
        accumulator = result;
        counter += 1;
    }
}

/// Iterator.prototype.toArray() — ES2025 §27.1.3.3.12.
fn void builtin_iterator_proto_toarray(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw(ctx, heap.type_err_proto, "Iterator.prototype.toArray called on non-object");
        return;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    TVal next_method;
    if (!iterhelper_get_iterator_direct(ctx, obj, &next_method)) { ctx.result.set_undefined(); return; }

    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = heap.array_proto;

    uint idx = 0;
    while (true) {
        TVal value;
        bool step_done;
        if (!iterhelper_step_value(ctx, obj, next_method, &value, &step_done)) {
            if (step_done) { ctx.result.set_object(arr); return; }
            ctx.result.set_undefined();
            return;
        }
        arr.set_array_idx(idx, value);
        idx++;
        *arr.array_len_ptr() = idx;
    }
}

/// Iterator.prototype.forEach(procedure) — ES2025 §27.1.3.3.7.
fn void builtin_iterator_proto_foreach(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal procedure = builtin_arg(ctx, 0);
    HObject* obj;
    TVal next_method;
    if (!iterhelper_eager_setup(ctx, procedure, "procedure is not a function", &obj, &next_method)) {
        ctx.result.set_undefined();
        return;
    }

    double counter = 0;
    while (true) {
        TVal value;
        bool step_done;
        if (!iterhelper_step_value(ctx, obj, next_method, &value, &step_done)) {
            if (step_done) { ctx.result.set_undefined(); return; }
            ctx.result.set_undefined();
            return;
        }
        TVal counter_tv; counter_tv.set_fastint((long)counter);
        TVal[2] args = { value, counter_tv };
        if (heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return; }
        TVal undef_this; undef_this.set_undefined();
        heap.call_fn(ctx.vm, procedure, &args[0], 2, undef_this);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            iterhelper_iterator_close(ctx, obj, true);
            ctx.result.set_undefined();
            return;
        }
        counter += 1;
    }
}

/// Iterator.prototype.some(predicate) — ES2025 §27.1.3.3.10.
fn void builtin_iterator_proto_some(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal predicate = builtin_arg(ctx, 0);
    HObject* obj;
    TVal next_method;
    if (!iterhelper_eager_setup(ctx, predicate, "predicate is not a function", &obj, &next_method)) {
        ctx.result.set_undefined();
        return;
    }

    double counter = 0;
    while (true) {
        TVal value;
        bool step_done;
        if (!iterhelper_step_value(ctx, obj, next_method, &value, &step_done)) {
            if (step_done) { ctx.result.set_boolean(false); return; }
            ctx.result.set_undefined();
            return;
        }
        TVal counter_tv; counter_tv.set_fastint((long)counter);
        TVal[2] args = { value, counter_tv };
        if (heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return; }
        TVal undef_this; undef_this.set_undefined();
        TVal result = heap.call_fn(ctx.vm, predicate, &args[0], 2, undef_this);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            iterhelper_iterator_close(ctx, obj, true);
            ctx.result.set_undefined();
            return;
        }
        if (builtin_to_boolean(&result)) {
            iterhelper_iterator_close(ctx, obj, false);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            ctx.result.set_boolean(true);
            return;
        }
        counter += 1;
    }
}

/// Iterator.prototype.every(predicate) — ES2025 §27.1.3.3.3.
fn void builtin_iterator_proto_every(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal predicate = builtin_arg(ctx, 0);
    HObject* obj;
    TVal next_method;
    if (!iterhelper_eager_setup(ctx, predicate, "predicate is not a function", &obj, &next_method)) {
        ctx.result.set_undefined();
        return;
    }

    double counter = 0;
    while (true) {
        TVal value;
        bool step_done;
        if (!iterhelper_step_value(ctx, obj, next_method, &value, &step_done)) {
            if (step_done) { ctx.result.set_boolean(true); return; }
            ctx.result.set_undefined();
            return;
        }
        TVal counter_tv; counter_tv.set_fastint((long)counter);
        TVal[2] args = { value, counter_tv };
        if (heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return; }
        TVal undef_this; undef_this.set_undefined();
        TVal result = heap.call_fn(ctx.vm, predicate, &args[0], 2, undef_this);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            iterhelper_iterator_close(ctx, obj, true);
            ctx.result.set_undefined();
            return;
        }
        if (!builtin_to_boolean(&result)) {
            iterhelper_iterator_close(ctx, obj, false);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            ctx.result.set_boolean(false);
            return;
        }
        counter += 1;
    }
}

/// Iterator.prototype.find(predicate) — ES2025 §27.1.3.3.5.
fn void builtin_iterator_proto_find(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal predicate = builtin_arg(ctx, 0);
    HObject* obj;
    TVal next_method;
    if (!iterhelper_eager_setup(ctx, predicate, "predicate is not a function", &obj, &next_method)) {
        ctx.result.set_undefined();
        return;
    }

    double counter = 0;
    while (true) {
        TVal value;
        bool step_done;
        if (!iterhelper_step_value(ctx, obj, next_method, &value, &step_done)) {
            if (step_done) { ctx.result.set_undefined(); return; }
            ctx.result.set_undefined();
            return;
        }
        TVal counter_tv; counter_tv.set_fastint((long)counter);
        TVal[2] args = { value, counter_tv };
        if (heap.call_fn == null || ctx.vm == null) { ctx.result.set_undefined(); return; }
        TVal undef_this; undef_this.set_undefined();
        TVal result = heap.call_fn(ctx.vm, predicate, &args[0], 2, undef_this);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            iterhelper_iterator_close(ctx, obj, true);
            ctx.result.set_undefined();
            return;
        }
        if (builtin_to_boolean(&result)) {
            iterhelper_iterator_close(ctx, obj, false);
            if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            *ctx.result = value;
            return;
        }
        counter += 1;
    }
}

/// Iterator.concat(...iterables) — TC39 iterator-sequencing proposal.
/// Returns a lazy iterator that sequences through all iterables in order.
/// Validates all arguments upfront: each must be an object with callable @@iterator.
fn void builtin_iterator_concat(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Validate and collect all iterables and their methods upfront
    // Step 1: For each argument, validate it's an object with callable @@iterator
    HObject*? iterables_arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = iterables_arr_raw) { ctx.result.set_undefined(); return; }
    HObject* iterables_arr = iterables_arr_raw;
    iterables_arr.prototype = heap.array_proto;

    // Also need a methods array to store the @@iterator methods
    HObject*? methods_arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = methods_arr_raw) { ctx.result.set_undefined(); return; }
    HObject* methods_arr = methods_arr_raw;
    methods_arr.prototype = heap.array_proto;

    uint num_args = ctx.argc;
    long count = 0;

    for (uint i = 0; i < num_args; i++) {
        TVal arg = builtin_arg(ctx, i);

        // Check if arg is an object
        if (!arg.is_object() || arg.get_heapptr() == null) {
            builtin_throw(ctx, heap.type_err_proto, "Iterator.concat argument must be an object");
            ctx.result.set_undefined();
            return;
        }

        HObject* arg_obj = (HObject*)arg.get_heapptr();

        // Get @@iterator method
        HString* iter_sym = ensure_iterator_symbol(heap);
        if (iter_sym == null) { ctx.result.set_undefined(); return; }

        TVal? method_opt = builtins_generic_get(arg_obj, iter_sym, ctx);
        if (ctx.should_throw) { ctx.result.set_undefined(); return; }

        TVal method;
        if (try m = method_opt) { method = m; } else { method.set_undefined(); }

        // Check if method is callable
        if (method.is_undefined() || method.is_null()) {
            builtin_throw(ctx, heap.type_err_proto, "Iterator.concat argument has no iterator method");
            ctx.result.set_undefined();
            return;
        }

        bool callable = method.is_lightfunc() ||
            (method.is_object() && method.get_heapptr() != null &&
             ((HObject*)method.get_heapptr()).is_callable());
        if (!callable) {
            builtin_throw(ctx, heap.type_err_proto, "Iterator.concat argument's iterator method is not callable");
            ctx.result.set_undefined();
            return;
        }

        // Add to the arrays
        iterables_arr.set_array_idx((uint)count, arg);
        methods_arr.set_array_idx((uint)count, method);
        count += 1;
    }

    iterables_arr.array_used = (uint)count;
    *iterables_arr.array_len_ptr() = (uint)count;
    methods_arr.array_used = (uint)count;
    *methods_arr.array_len_ptr() = (uint)count;

    // Create wrapper object to hold iterables array, methods array, and metadata
    HObject*? wrapper_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = wrapper_raw) { ctx.result.set_undefined(); return; }
    HObject* wrapper = wrapper_raw;
    wrapper.prototype = null;

    // Store the iterables array
    HString* iterables_key = builtin_intern_string(heap, "iterables");
    if (iterables_key != null) {
        TVal iterables_tv; iterables_tv.set_object(iterables_arr);
        wrapper.put_prop(iterables_key, iterables_tv, hobject::PROP_FLAGS_WEC);
    }

    // Store the methods array
    HString* methods_key = builtin_intern_string(heap, "methods");
    if (methods_key != null) {
        TVal methods_tv; methods_tv.set_object(methods_arr);
        wrapper.put_prop(methods_key, methods_tv, hobject::PROP_FLAGS_WEC);
    }

    // Store the count
    HString* count_key = builtin_intern_string(heap, "count");
    if (count_key != null) {
        TVal count_tv; count_tv.set_fastint(count);
        wrapper.put_prop(count_key, count_tv, hobject::PROP_FLAGS_WEC);
    }

    // Create the iterator helper with concat kind
    // underlying: wrapper object (holds iterables, methods, count)
    // next_method: undefined (unused for concat)
    // callback: undefined (unused for concat)
    // remaining: 0 (unused for concat)
    TVal undef; undef.set_undefined();
    HObject* helper = iterhelper_create(heap, wrapper, undef, undef, IH_KIND_CONCAT, 0.0);
    if (helper != null) { ctx.result.set_object(helper); } else { ctx.result.set_undefined(); }
}
