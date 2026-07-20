/// Iterator protocol: %IteratorPrototype%, Array/String/Map/Set/RegExpString iterators.
module duktape::builtins;
import duktape::types;
import std::io;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::re_bindings;

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
    (*iter.extra_ptr()).iter.target = iterable;
    (*iter.extra_ptr()).iter.index = 0;
    (*iter.extra_ptr()).iter.kind = kind;
    iter.prototype = heap.iterator_proto;
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.ARRAY_ITERATOR_NEXT.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
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
    (*iter.extra_ptr()).iter.target = map;
    (*iter.extra_ptr()).iter.index = 0;
    (*iter.extra_ptr()).iter.kind = kind;
    iter.prototype = heap.iterator_proto;

    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.MAP_ITERATOR_NEXT.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
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
    (*iter.extra_ptr()).iter.target = set;
    (*iter.extra_ptr()).iter.index = 0;
    (*iter.extra_ptr()).iter.kind = kind;
    iter.prototype = heap.iterator_proto;

    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.SET_ITERATOR_NEXT.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
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
    iter.prototype = heap.iterator_proto;

    // Add .next method as an own property
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.STRING_ITERATOR_NEXT.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    ctx.result.set_object(iter);
}

/// %IteratorPrototype%[@@iterator] (ES6 section 25.1.2.1) — returns `this`.
/// The spec says iterators are their own iterator (calling `@@iterator` on an
/// iterator returns the iterator itself). `set_object` is required here — a
/// raw `*ctx.result = ctx.this_val` would copy the NaN-boxed bits and skip
/// the `incref`, which crashes as soon as GC reclaims the iterator (the
/// canonical trigger is `for (var v of generator)`, since the loop holds
/// the iterator through the result of this builtin).
fn void builtin_iterator_proto_symbol_iter(BuiltinContext* ctx) {
    if (ctx.this_val.is_object()) {
        ctx.result.set_object(ctx.this_val.get_heapptr());
    } else {
        ctx.result.set_undefined();
    }
}

/// Array iterator .next() — returns {value, done}.
fn void builtin_array_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.ARRAY_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
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
        HObject* ta_buf = (*target.extra_ptr()).view.buffer;
        if (ta_buf != null && (*ta_buf.extra_ptr()).ab.data != null) {
            uint ta_shift = ta_elem_shift(target.get_class());
            len = (long)((*target.extra_ptr()).view.byte_length >> ta_shift);
        }
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
        // TypedArray: read element from backing store directly.
        HObject* ta_buf = (*target.extra_ptr()).view.buffer;
        if (ta_buf != null && (*ta_buf.extra_ptr()).ab.data != null) {
            char* ta_base = (*ta_buf.extra_ptr()).ab.data + (*target.extra_ptr()).view.byte_offset;
            value = ta_load_element(ctx.heap, ta_base, target.get_class(), idx);
        }
        // detached: value stays undefined (spec: detach mid-iteration -> undefined)
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
        (*iter.extra_ptr()).iter.target = null;
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
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.STRING_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
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
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.REGEXP_STRING_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
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

    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;
    bool global_flag = (flags & 1) != 0;
    bool unicode_flag = (flags & 4) != 0;

    // Get lastIndex from the regexp — a UTF-16 code-unit index; convert to a
    // CESU-8 byte offset for re_exec (which takes byte offsets).
    HString* li_key = builtin_intern_string(heap, "lastIndex");
    long search_charunit = 0;
    if (try liv = rx.get_prop_proto(li_key)) {
        if (liv.is_fastint()) {
            search_charunit = liv.get_fastint();
        } else if (liv.is_number()) {
            search_charunit = (long)liv.get_number();
        }
    }
    if (search_charunit < 0) search_charunit = 0;
    uint str_charlen = s_hstr.char_length();
    int search_pos = (int)s_hstr.char_offset_to_byte_offset((uint)search_charunit);
    if ((ulong)search_charunit > (ulong)str_charlen) {
        // lastIndex beyond end — no match per ES2020 §21.2.5.2.2 step 6
        // Also handles empty-match-at-end-of-string advance.
        (*iter.extra_ptr()).regexp_iter.flags |= 2;
        if (global_flag) {
            TVal zero_tv; zero_tv.set_fastint(0);
            rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
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

    // Execute regexp
    int out_start = 0;
    int out_end = 0;
    int out_num_captures = 0;
    int[re_bindings::RE_MAX_CAPTURES] caps_start;
    int[re_bindings::RE_MAX_CAPTURES] caps_end;
    mem::clear(&caps_start, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));
    mem::clear(&caps_end, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));

    int exec_result = re_bindings::re_exec(
        (*rx.extra_ptr()).regexp.regexp_data, input, input_len, search_pos,
        (int)s_hstr.is_ascii(),
        &out_start, &out_end, &out_num_captures,
        &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
    );

    if (exec_result != re_bindings::RE_MATCH) {
        // No match — mark done and reset lastIndex to 0 if global
        (*iter.extra_ptr()).regexp_iter.flags |= 2;
        if (global_flag) {
            TVal zero_tv; zero_tv.set_fastint(0);
            rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
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

    // Match found — for non-global iterators, mark done so subsequent
    // calls return {value:undefined, done:true} per ES2022 §22.2.7.2.1.
    if (!global_flag) {
        (*iter.extra_ptr()).regexp_iter.flags |= 2;
    }

    // Update lastIndex for global iterators only. lastIndex is a UTF-16
    // code-unit index; convert the byte-offset match end back to units.
    if (global_flag) {
        int next_pos = out_end;
        if (out_end == search_pos) {
            // Empty match: AdvanceStringIndex(S, lastIndex, unicode) — per
            // ES2022 §22.2.7.2.2, advances by one code unit, or by a full
            // surrogate pair when the `u`/`v` flag is set.
            next_pos = out_end + (int)hstring::advance_string_index_byte_len(
                input[:input_len], (uint)out_end, unicode_flag);
        }
        long next_charunit = (long)hstring::compute_charlen(input[:next_pos]);
        TVal next_tv; next_tv.set_fastint(next_charunit);
        rx.put_prop(li_key, next_tv, hobject::PROP_FLAGS_WEC);
    }

    // Create match result array (same layout as RegExp.prototype.exec)
    HObject*? match_arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = match_arr_raw) { ctx.result.set_undefined(); return; }
    HObject* match_arr = match_arr_raw;
    match_arr.prototype = heap.array_proto;

    // Element 0: full match string
    usz match_len = (usz)(out_end - out_start);
    HString* match_str;
    if (match_len == 0) {
        match_str = builtin_intern_string(heap, "");
    } else {
        match_str = builtin_intern_string(heap, input[out_start : match_len]);
    }
    TVal elem;
    elem.set_string(match_str);
    HString* zero_key = builtin_intern_string(heap, "0");
    match_arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

    // Capture groups
    uint match_arr_len = 1;
    int num_caps = out_num_captures;
    if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
    for (int i = 0; i < num_caps; i++) {
        HString* cap_str;
        if (caps_start[i] >= 0 && caps_end[i] >= 0) {
            usz cap_len = (usz)(caps_end[i] - caps_start[i]);
            cap_str = cap_len == 0
                ? builtin_intern_string(heap, "")
                : builtin_intern_string(heap, input[caps_start[i] : cap_len]);
        } else {
            cap_str = null;
        }
        TVal cap_elem;
        if (cap_str != null) {
            cap_elem.set_string(cap_str);
        } else {
            cap_elem.set_undefined();
        }
        match_arr.put_prop(heap.int_to_hstring((long)(i + 1)), cap_elem, hobject::PROP_FLAGS_WEC);
        match_arr_len++;
    }

    // Set index property — convert byte offset to UTF-16 code-unit index.
    TVal idx_tv;
    idx_tv.set_fastint((long)hstring::compute_charlen(input[:out_start]));
    HString* idx_key = builtin_intern_string(heap, "index");
    match_arr.put_prop(idx_key, idx_tv, hobject::PROP_FLAGS_WEC);

    // Set input property
    TVal input_tv;
    input_tv.set_string(s_hstr);
    HString* input_key = builtin_intern_string(heap, "input");
    match_arr.put_prop(input_key, input_tv, hobject::PROP_FLAGS_WEC);

    // Set length
    TVal mlen_tv;
    mlen_tv.set_fastint((long)match_arr_len);
    HString* mlen_key = builtin_intern_string(heap, "length");
    match_arr.put_prop(mlen_key, mlen_tv, hobject::PROP_FLAGS_WEC);

    // Create result iterator result: {value: matchArr, done: false}
    HObject*? iter_result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = iter_result_raw) { ctx.result.set_undefined(); return; }
    HObject* iter_result = iter_result_raw;
    iter_result.prototype = null;

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    TVal match_tv;
    match_tv.set_object(match_arr);
    iter_result.put_prop(value_key, match_tv, hobject::PROP_FLAGS_WEC);

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(false);
    iter_result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(iter_result);
}

/// Create %IteratorPrototype% (ES6 §25.1.2).
/// %IteratorPrototype% has [Symbol.iterator]() that returns `this`.
fn bool register_iterator_prototype(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // will be wired to object_proto later
    heap.iterator_proto = proto;

    // Add [Symbol.iterator]() → returns `this`
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

    return true;
}
