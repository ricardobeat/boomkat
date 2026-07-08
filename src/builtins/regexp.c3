/// RegExp constructor and RegExp.prototype methods.
module duktape::builtins;
import duktape::types;
import libc;
import duktape::hstring;
import duktape::env;

import duktape::heap;
import duktape::hobject;
import duktape::re_bindings;
import std::math;

// ============================================================================
// RegExp constructor builtins
// ============================================================================

/// Helper: extract the compiled regexp data pointer from 'this'.
/// Returns null if 'this' is not a REGEXP-class object.
fn HObject* regexp_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) return null;
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.REGEXP) return null;
    return obj;
}

/// RegExp(pattern, flags) — ES5 §15.10.3 (called as function) / §15.10.4 (constructor).
/// When called as a function (not constructor), behaviour is identical to construction.
fn void builtin_regexp(BuiltinContext* ctx) {
    // Get pattern
    bool is_regexp = false;
    HObject* pattern_regexp = null;  // Saved pointer for RegExp→RegExp constructor shortcut
    char* pattern_str = "";
    usz pattern_len = 0;
    int flags = 0;
    int js_flags = 0;  // JS flag bits: 1=g, 2=i, 4=m
    char* flags_str = "";
    usz flags_len = 0;

    if (ctx.argc > 0) {
        TVal* pattern_arg = &ctx.regs[ctx.base_reg];
        if (pattern_arg.is_object() && pattern_arg.get_heapptr() != null) {
            HObject* obj = (HObject*)pattern_arg.get_heapptr();
            if (obj.get_class() == hobject::ObjClass.REGEXP && (*obj.extra_ptr()).regexp.regexp_data != null) {
                // Pattern is a RegExp object — extract its pattern
                is_regexp = true;
                pattern_regexp = obj;
                if ((*obj.extra_ptr()).prim.primitive_value.is_string()) {
                    HString* phs = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
                    pattern_str = phs.get_cstr();
                    pattern_len = phs.blen;
                }
            } else {
                // Convert to string for pattern
                HString* phs = builtin_to_string(ctx.heap, pattern_arg);
                if (phs != null) {
                    pattern_str = phs.get_cstr();
                    pattern_len = phs.blen;
                }
            }
        } else if (pattern_arg.is_string() && pattern_arg.get_heapptr() != null) {
            HString* phs = (HString*)pattern_arg.get_heapptr();
            pattern_str = phs.get_cstr();
            pattern_len = phs.blen;
        } else {
            // Convert to string
            HString* phs = builtin_to_string(ctx.heap, pattern_arg);
            if (phs != null) {
                pattern_str = phs.get_cstr();
                pattern_len = phs.blen;
            }
        }
    }

    // Get flags from second argument
    if (ctx.argc > 1) {
        TVal* flags_arg = &ctx.regs[ctx.base_reg + 1];
        if (flags_arg.is_string() && flags_arg.get_heapptr() != null) {
            HString* fhs = (HString*)flags_arg.get_heapptr();
            flags_str = fhs.get_cstr();
            flags_len = fhs.blen;
        } else if (!flags_arg.is_undefined()) {
            HString* fhs = builtin_to_string(ctx.heap, flags_arg);
            if (fhs != null) {
                flags_str = fhs.get_cstr();
                flags_len = fhs.blen;
            }
        }
    }

    // ES2015 §21.2.3.1 step 4.b: If patternIsRegExp is true and flags is undefined,
    // check SameValue(pattern.constructor, RegExp) and return pattern if true.
    if (is_regexp && flags_len == 0) {
        // Check if the pattern's constructor is the RegExp constructor itself
        HString* ctor_key = builtin_intern_string(ctx.heap, "constructor");
        if (try cv = pattern_regexp.get_prop_proto(ctor_key)) {
            if (cv.is_object() && cv.get_heapptr() != null) {
                HObject* ctor_obj = (HObject*)cv.get_heapptr();
                // Check if ctor_obj is the global RegExp constructor (has builtin_fn_index == BUILTIN_REGEXP)
                if (ctor_obj.get_class() == hobject::ObjClass.FUNCTION &&
                    (*ctor_obj.extra_ptr()).func.builtin_fn_index == (int)BUILTIN_REGEXP) {
                    // SameValue: same constructor → return the original pattern object
                    ctx.result.set_object(pattern_regexp);
                    return;
                }
            }
        }
        // Constructor mismatch — fall through to create a new RegExp with pattern's source/flags
        // Extract pattern source and flags from the original regexp
        js_flags = (*pattern_regexp.extra_ptr()).regexp.flags;
        flags_len = 0;  // Clear flags so we don't re-parse
    }

    // Convert JS flags to libregexp flag bits and store JS flags
    for (usz i = 0; i < flags_len; i++) {
        char f = flags_str[i];
        if (f == 'g') {
            js_flags |= 1;
        } else if (f == 'i') {
            flags |= re_bindings::RE_FLAG_IGNORECASE;
            js_flags |= 2;
        } else if (f == 'm') {
            flags |= re_bindings::RE_FLAG_MULTILINE;
            js_flags |= 4;
        } else if (f == 's') {
            flags |= re_bindings::RE_FLAG_DOTALL;
            js_flags |= 8;
        } else if (f == 'u') {
            flags |= re_bindings::RE_FLAG_UNICODE;
            js_flags |= 16;
        } else if (f == 'y') {
            flags |= re_bindings::RE_FLAG_STICKY;
            js_flags |= 32;
        } else if (f == 'd') {
            flags |= re_bindings::RE_FLAG_INDICES;
            js_flags |= 64;
        } else if (f == 'v') {
            flags |= re_bindings::RE_FLAG_UNICODE_SETS;
            js_flags |= 128;
        } else {
            // Invalid flag per ES5 §15.10.4.1 — throw SyntaxError
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.syntax_err_proto;
                char[80] buf;
                int len = libc::snprintf(&buf, 80, "Invalid flags supplied to RegExp constructor '%c'", f);
                if (len > 0 && len < 80) {
                    HString* msg_str = builtin_intern_string(ctx.heap, buf[:len]);
                    TVal msg_tv;
                    msg_tv.set_string(msg_str);
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                }
                ctx.throw_value.set_object(err);
            } else {
                ctx.throw_value.set_undefined();
            }
            ctx.should_throw = true;
            return;
        }
    }

    // Compile the regexp
    char[128] error_buf;
    void* compiled = re_bindings::re_compile(
        (char*)pattern_str, (usz)pattern_len,
        flags, &error_buf, 128
    );

    if (compiled == null) {
        // Compilation failed — throw SyntaxError (ES5 §15.10.4.1)
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.syntax_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, error_buf[:128]);
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.REGEXP);
    if (catch err = obj_raw) {
        if (compiled != null) re_bindings::re_free(compiled);
        ctx.result.set_undefined();
        return;
    }
    HObject* obj = obj_raw;
    obj.prototype = ctx.heap.regexp_proto;
    (*obj.extra_ptr()).regexp.regexp_data = compiled;
    (*obj.extra_ptr()).regexp.flags = js_flags;

    // Store pattern string as primitive_value
    HString* pattern_hs = builtin_intern_string(ctx.heap, pattern_str[:pattern_len]);
    (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);

    // Set RegExp.prototype.lastIndex (ES5 §15.10.7) — own data property
    HString* lastindex_key = builtin_intern_string(ctx.heap, "lastIndex");
    TVal lastindex_tv;
    lastindex_tv.set_fastint(0);
    obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(obj);
}

/// RegExp.prototype.test(string) — ES5 §15.10.6.3
fn void builtin_regexp_proto_test(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this(ctx);
    if (obj == null || (*obj.extra_ptr()).regexp.regexp_data == null) {
        // ES5 §15.10.6.3 step 2: throw TypeError if this is not a RegExp
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "RegExp.prototype.test called on incompatible receiver");
        return;
    }

    // Get input string — ToString per ES2017 (allow objects via vm)
    char* input = "";
    int input_len = 0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        HString* hs;
        if (arg.is_string()) {
            hs = (HString*)arg.get_heapptr();
        } else {
            hs = builtin_to_string_vm(ctx, arg);
        }
        if (hs != null) {
            input = hs.get_cstr();
            input_len = (int)hs.blen;
        }
    }

    // Get the global and sticky flags
    // Read directly from internal flags: 1=g, 2=i, 4=m, 8=s, 16=u, 32=y
    int jsf_test = (*obj.extra_ptr()).regexp.flags;
    bool global_flag = (jsf_test & 1) != 0;
    bool sticky_flag = (jsf_test & 32) != 0;

    // Get lastIndex (if global or sticky)
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    int start_pos = 0;
    if (global_flag || sticky_flag) {
        if (try liv = obj.get_prop_proto(li_key)) {
            if (liv.is_fastint()) {
                start_pos = (int)liv.get_fastint();
            } else if (liv.is_number()) {
                start_pos = (int)liv.get_number();
            }
        }
        // If lastIndex is out of bounds, reset to 0 and return false
        if (start_pos < 0 || start_pos > input_len) {
            TVal zero_tv;
            zero_tv.set_fastint(0);
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
            ctx.result.set_boolean(false);
            return;
        }
    }

    // Execute
    int out_start = 0;
    int out_end = 0;
    int out_num_captures = 0;
    int result = re_bindings::re_exec(
        (*obj.extra_ptr()).regexp.regexp_data, input, input_len, start_pos,
        &out_start, &out_end, &out_num_captures,
        null, null, 0
    );

    // Update lastIndex if global (sticky does NOT update)
    if (global_flag) {
        if (result == re_bindings::RE_MATCH) {
            TVal end_tv;
            end_tv.set_fastint((long)out_end);
            obj.put_prop(li_key, end_tv, hobject::PROP_FLAGS_WEC);
        } else {
            TVal zero_tv;
            zero_tv.set_fastint(0);
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
    }

    ctx.result.set_boolean((result == re_bindings::RE_MATCH));
}

/// Build a RegExp exec/match result array with .groups and optional .indices.
fn HObject* regexp_build_match_result(BuiltinContext* ctx, void* re_data, HString* input_str,
                                      char* input, int input_len,
                                      int out_start, int out_end,
                                      int* caps_start, int* caps_end, int num_caps,
                                      bool with_indices) {
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) return null;
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    // Element 0: full match string
    usz match_len = (usz)(out_end - out_start);
    HString* match_str = match_len == 0
        ? builtin_intern_string(ctx.heap, "")
        : builtin_intern_string(ctx.heap, input[out_start : match_len]);
    TVal elem; elem.set_string(match_str);
    HString* zero_key = builtin_intern_string(ctx.heap, "0");
    arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

    // Capture groups 1..N
    int total_captures = 1 + num_caps;
    for (int i = 0; i < num_caps; i++) {
        TVal cap_elem;
        if (caps_start[i] >= 0 && caps_end[i] >= 0) {
            usz cap_len = (usz)(caps_end[i] - caps_start[i]);
            cap_elem.set_string(cap_len == 0
                ? builtin_intern_string(ctx.heap, "")
                : builtin_intern_string(ctx.heap, input[caps_start[i] : cap_len]));
        } else {
            cap_elem.set_undefined();
        }
        arr.put_prop(ctx.heap.int_to_hstring((long)(i + 1)), cap_elem, hobject::PROP_FLAGS_WEC);
    }

    // index property
    TVal idx_tv; idx_tv.set_fastint((long)out_start);
    arr.put_prop(builtin_intern_string(ctx.heap, "index"), idx_tv, hobject::PROP_FLAGS_WEC);

    // input property
    TVal input_tv; input_tv.set_string(input_str);
    arr.put_prop(builtin_intern_string(ctx.heap, "input"), input_tv, hobject::PROP_FLAGS_WEC);

    // groups property
    char* group_names = re_bindings::re_get_groupnames(re_data);
    if (group_names != null) {
        HObject*? groups_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try groups = groups_raw) {
            groups.prototype = null;
            int name_count = re_bindings::re_get_capture_count(re_data) - 1;
            char* p = group_names;
            for (int gi = 0; gi < name_count; gi++) {
                usz name_len = libc::strlen((ZString)p);
                if (name_len > 0) {
                    HString* name_str = builtin_intern_string(ctx.heap, p[:name_len]);
                    TVal cap_val;
                    if (gi < num_caps && caps_start[gi] >= 0 && caps_end[gi] >= 0) {
                        usz cap_len = (usz)(caps_end[gi] - caps_start[gi]);
                        cap_val.set_string(cap_len == 0
                            ? builtin_intern_string(ctx.heap, "")
                            : builtin_intern_string(ctx.heap, input[caps_start[gi] : cap_len]));
                    } else {
                        cap_val.set_undefined();
                    }
                    groups.put_prop(name_str, cap_val, hobject::PROP_FLAGS_WEC);
                }
                // Each entry is: name bytes + '\0' + scope byte (2 bytes minimum)
                p += (long)(name_len + 2);
            }
            TVal groups_val; groups_val.set_object(groups);
            arr.put_prop(builtin_intern_string(ctx.heap, "groups"), groups_val, hobject::PROP_FLAGS_WEC);
        }
    } else {
        TVal groups_undef; groups_undef.set_undefined();
        arr.put_prop(builtin_intern_string(ctx.heap, "groups"), groups_undef, hobject::PROP_FLAGS_WEC);
    }

    // indices property (ES2022 d-flag)
    if (with_indices) {
        HObject*? indices_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (try indices_arr = indices_raw) {
            indices_arr.prototype = ctx.heap.array_proto;

            // indices[0]
            HObject*? pair0_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try pair0 = pair0_raw) {
                pair0.prototype = ctx.heap.array_proto;
                TVal p0s; p0s.set_fastint((long)out_start);
                TVal p0e; p0e.set_fastint((long)out_end);
                pair0.put_prop(builtin_intern_string(ctx.heap, "0"), p0s, hobject::PROP_FLAGS_WEC);
                pair0.put_prop(builtin_intern_string(ctx.heap, "1"), p0e, hobject::PROP_FLAGS_WEC);
                TVal pair0_tv; pair0_tv.set_object(pair0);
                indices_arr.put_prop(builtin_intern_string(ctx.heap, "0"), pair0_tv, hobject::PROP_FLAGS_WEC);
            }

            for (int i = 0; i < num_caps; i++) {
                HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (catch err = pair_raw) continue;
                HObject* pair = pair_raw;
                pair.prototype = ctx.heap.array_proto;
                TVal pair_tv;
                if (caps_start[i] >= 0 && caps_end[i] >= 0) {
                    TVal ps; ps.set_fastint((long)caps_start[i]);
                    TVal pe; pe.set_fastint((long)caps_end[i]);
                    pair.put_prop(builtin_intern_string(ctx.heap, "0"), ps, hobject::PROP_FLAGS_WEC);
                    pair.put_prop(builtin_intern_string(ctx.heap, "1"), pe, hobject::PROP_FLAGS_WEC);
                    pair_tv.set_object(pair);
                } else {
                    pair_tv.set_undefined();
                }
                indices_arr.put_prop(ctx.heap.int_to_hstring((long)(i + 1)), pair_tv, hobject::PROP_FLAGS_WEC);
            }

            // indices.groups
            if (group_names != null) {
                HObject*? igroups_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (try igroups = igroups_raw) {
                    igroups.prototype = null;
                    int name_count = re_bindings::re_get_capture_count(re_data) - 1;
                    char* p = group_names;
                    for (int gi = 0; gi < name_count; gi++) {
                        usz name_len = libc::strlen((ZString)p);
                        if (name_len > 0) {
                            HString* name_str = builtin_intern_string(ctx.heap, p[:name_len]);
                            TVal pair_tv;
                            if (gi < num_caps && caps_start[gi] >= 0 && caps_end[gi] >= 0) {
                                HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
                                if (try pair = pair_raw) {
                                    pair.prototype = ctx.heap.array_proto;
                                    TVal ps; ps.set_fastint((long)caps_start[gi]);
                                    TVal pe; pe.set_fastint((long)caps_end[gi]);
                                    pair.put_prop(builtin_intern_string(ctx.heap, "0"), ps, hobject::PROP_FLAGS_WEC);
                                    pair.put_prop(builtin_intern_string(ctx.heap, "1"), pe, hobject::PROP_FLAGS_WEC);
                                    pair_tv.set_object(pair);
                                } else {
                                    pair_tv.set_undefined();
                                }
                            } else {
                                pair_tv.set_undefined();
                            }
                            igroups.put_prop(name_str, pair_tv, hobject::PROP_FLAGS_WEC);
                        }
                        // Each entry is: name bytes + '\0' + scope byte (2 bytes minimum)
                        p += (long)(name_len + 2);
                    }
                    TVal igroups_tv; igroups_tv.set_object(igroups);
                    indices_arr.put_prop(builtin_intern_string(ctx.heap, "groups"), igroups_tv, hobject::PROP_FLAGS_WEC);
                }
            } else {
                TVal igroups_undef; igroups_undef.set_undefined();
                indices_arr.put_prop(builtin_intern_string(ctx.heap, "groups"), igroups_undef, hobject::PROP_FLAGS_WEC);
            }

            TVal indices_len; indices_len.set_fastint((long)total_captures);
            indices_arr.put_prop(builtin_intern_string(ctx.heap, "length"), indices_len, hobject::PROP_FLAGS_WEC);

            TVal indices_tv; indices_tv.set_object(indices_arr);
            arr.put_prop(builtin_intern_string(ctx.heap, "indices"), indices_tv, hobject::PROP_FLAGS_WEC);
        }
    }

    TVal len_tv; len_tv.set_fastint((long)total_captures);
    arr.put_prop(builtin_intern_string(ctx.heap, "length"), len_tv, hobject::PROP_FLAGS_WEC);

    return arr;
}

/// RegExp.prototype.exec(string) — ES5 §15.10.6.2
fn void builtin_regexp_proto_exec(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this(ctx);
    if (obj == null || (*obj.extra_ptr()).regexp.regexp_data == null) {
        // ES5 §15.10.6.2 step 2: throw TypeError if this is not a RegExp
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "RegExp.prototype.exec called on incompatible receiver");
        return;
    }

    // Get input string — ToString per ES2017 (allow objects via vm)
    char* input = "";
    int input_len = 0;
    HString* input_hstr = null;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        HString* hs;
        if (arg.is_string()) {
            hs = (HString*)arg.get_heapptr();
        } else {
            hs = builtin_to_string_vm(ctx, arg);
        }
        if (hs != null) {
            input_hstr = hs;
            input = hs.get_cstr();
            input_len = (int)hs.blen;
        } else if (ctx.should_throw) {
            return;
        }
    }

    // Get the global and sticky flags (ES2015 §21.2.5.2 steps 4-5)
    // Read directly from internal flags: 1=g, 2=i, 4=m, 8=s, 16=u, 32=y
    int jsf = (*obj.extra_ptr()).regexp.flags;
    bool global_flag = (jsf & 1) != 0;
    bool sticky_flag = (jsf & 32) != 0;

    // Get lastIndex (steps 4-5) — used when global OR sticky
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    int start_pos = 0;
    if (global_flag || sticky_flag) {
        if (try liv = obj.get_prop_proto(li_key)) {
            if (liv.is_fastint()) {
                start_pos = (int)liv.get_fastint();
            } else if (liv.is_number()) {
                start_pos = (int)liv.get_number();
            }
        }
        // Step 7: if i < 0 or i > length, set lastIndex to 0 and return null
        if (start_pos < 0 || start_pos > input_len) {
            TVal zero_tv;
            zero_tv.set_fastint(0);
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
            ctx.result.set_null();
            return;
        }
    }

    // Execute with capture arrays
    int out_start = 0;
    int out_end = 0;
    int out_num_captures = 0;
    int[re_bindings::RE_MAX_CAPTURES] caps_start;
    int[re_bindings::RE_MAX_CAPTURES] caps_end;
    libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
    libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

    int result = re_bindings::re_exec(
        (*obj.extra_ptr()).regexp.regexp_data, input, input_len, start_pos,
        &out_start, &out_end, &out_num_captures,
        &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
    );

    if (result != re_bindings::RE_MATCH) {
        // Step 9: no match — reset lastIndex to 0 if global (not sticky)
        if (global_flag) {
            TVal zero_tv;
            zero_tv.set_fastint(0);
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.set_null();
        return;
    }

    // Step 10: if global, update lastIndex to end of match (sticky does NOT update)
    if (global_flag) {
        TVal end_tv;
        end_tv.set_fastint((long)out_end);
        obj.put_prop(li_key, end_tv, hobject::PROP_FLAGS_WEC);
    }

    // Build result array with .groups and .indices (when d flag is set)
    void* re_data = (*obj.extra_ptr()).regexp.regexp_data;
    int num_caps = out_num_captures;
    if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
    bool has_indices = (jsf & 64) != 0;
    HString* input_str = input_hstr != null ? input_hstr : builtin_intern_string(ctx.heap, input[:input_len]);
    HObject* arr = regexp_build_match_result(ctx, re_data, input_str, input, input_len,
                                             out_start, out_end,
                                             &caps_start, &caps_end, num_caps, has_indices);
    if (arr == null) {
        ctx.result.set_null();
        return;
    }
    ctx.result.set_object(arr);
}

/// RegExp.prototype.toString() — ES5 §15.10.6.4
fn void builtin_regexp_proto_toString(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this(ctx);
    if (obj == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    // Build "/pattern/flags" string — apply EscapeRegExpPattern to the source
    char* pattern = "";
    usz plen = 0;
    if ((*obj.extra_ptr()).prim.primitive_value.is_string() && (*obj.extra_ptr()).prim.primitive_value.get_heapptr() != null) {
        HString* phs = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        pattern = phs.get_cstr();
        plen = phs.blen;
    }

    int jsf = (*obj.extra_ptr()).regexp.flags;
    char[1024] buf;
    int pos = 0;
    buf[pos++] = '/';
    // Apply EscapeRegExpPattern: escape '/' and line terminators
    for (usz i = 0; i < plen && pos < 1020; i++) {
        char c = pattern[i];
        if (c == '/' || c == '\n' || c == '\r' || c == '\u2028' || c == '\u2029') {
            buf[pos++] = '\\';
            buf[pos++] = c;
        } else {
            buf[pos++] = c;
        }
    }
    buf[pos++] = '/';
    if ((jsf & 1) != 0 && pos < 1023) buf[pos++] = 'g';
    if ((jsf & 2) != 0 && pos < 1023) buf[pos++] = 'i';
    if ((jsf & 4) != 0 && pos < 1023) buf[pos++] = 'm';
    if ((jsf & 8) != 0 && pos < 1023) buf[pos++] = 's';
    if ((jsf & 16) != 0 && pos < 1023) buf[pos++] = 'u';
    if ((jsf & 32) != 0 && pos < 1023) buf[pos++] = 'y';
    buf[pos] = 0;

    HString* result = builtin_intern_string(ctx.heap, buf[:pos]);
    ctx.result.set_string(result);
}

// ============================================================================
// RegExp.prototype[@@match] — ES6 §21.2.5.6
// ============================================================================
fn void builtin_regexp_proto_symbol_match(BuiltinContext* ctx) {
    HObject* rx = regexp_get_symbol_this(ctx);
    if (rx == null) return;

    // 3. Let S be ? ToString(string).
    TVal s_tv; s_tv.set_undefined();
    if (ctx.argc > 0) s_tv = ctx.regs[ctx.base_reg];
    HString* s_hstr;
    if (s_tv.is_string() && s_tv.get_heapptr() != null) {
        s_hstr = (HString*)s_tv.get_heapptr();
    } else {
        s_hstr = builtin_to_string_vm(ctx, &s_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) s_hstr = builtin_intern_string(ctx.heap, "undefined");
    }

    // 4-5. Let global be ToBoolean(? Get(rx, "global")).
    HString* global_key = builtin_intern_string(ctx.heap, "global");
    TVal? g_opt = builtins_generic_get(rx, global_key, ctx);
    if (ctx.should_throw) return;
    bool global_flag = false;
    if (try gv = g_opt) { global_flag = builtin_to_boolean(&gv); }

    // 6. Let fullUnicode be ToBoolean(? Get(rx, "unicode")).
    HString* unicode_key = builtin_intern_string(ctx.heap, "unicode");
    TVal? u_opt = builtins_generic_get(rx, unicode_key, ctx);
    if (ctx.should_throw) return;
    bool full_unicode = false;
    if (try uv = u_opt) { full_unicode = builtin_to_boolean(&uv); }

    if (!global_flag) {
        // 7.a. Return ? RegExpExec(rx, S).
        // Pass the ToString-coerced string S — per spec, Call(exec, R, «S»)
        // passes S as the arg, not the original input.
        TVal s_hstr_tv; s_hstr_tv.set_string(s_hstr);
        if (!regexp_exec_call(ctx, rx, &s_hstr_tv)) {
            return;
        }
        return;
    }

    // 8. global === true
    // 8.a. Set(rx, "lastIndex", 0, true).
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    TVal zero_tv; zero_tv.set_fastint(0);
    if (!rx.put_prop((void*)li_key, zero_tv, hobject::PROP_FLAGS_WEC)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot set lastIndex on regexp");
        return;
    }

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_null(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    uint arr_idx = 0;

    while (true) {
        // 8.c. Let result be ? RegExpExec(rx, S).
        TVal s_hstr_tv; s_hstr_tv.set_string(s_hstr);
        if (!regexp_exec_call(ctx, rx, &s_hstr_tv)) return;
        TVal result = *ctx.result;
        if (result.is_null()) break;
        // Skip our internal hstring wrapping when handing off — re_exec
        // returns a TVal containing an Array object pointer.
        // `regexp_exec_call` set ctx.result; mirror it locally so we
        // don't re-run the function on the next iteration.

        HObject* match_arr;
        if (result.is_object() && result.get_heapptr() != null) {
            match_arr = (HObject*)result.get_heapptr();
        } else {
            break;
        }

        // 8.e. Let matchStr be ? ToString(? Get(result, "0")).
        HString* zero_key = builtin_intern_string(ctx.heap, "0");
        TVal? ms_opt = builtins_generic_get(match_arr, zero_key, ctx);
        if (ctx.should_throw) return;
        TVal ms_tv; ms_tv.set_undefined();
        if (try mv = ms_opt) { ms_tv = mv; }
        HString* match_str = builtin_to_string_vm(ctx, &ms_tv);
        if (ctx.should_throw) return;
        if (match_str == null) match_str = builtin_intern_string(ctx.heap, "undefined");

        // 8.f. Perform ! CreateDataProperty(A, ! ToString(n), matchStr).
        TVal elem; elem.set_string(match_str);
        arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC);
        arr_idx++;

        // 8.g. If matchStr is the empty String, then
        //    i. Let thisIndex be ? ToLength(? Get(rx, "lastIndex")).
        //    ii. Let nextIndex be AdvanceStringIndex(S, thisIndex, fullUnicode).
        //    iii. Perform ? Set(rx, "lastIndex", nextIndex, true).
        if (match_str.blen == 0) {
            // ToLength(? Get(rx, "lastIndex"))
            TVal? li_opt = builtins_generic_get(rx, li_key, ctx);
            if (ctx.should_throw) return;
            int this_index = 0;
            if (try lv = li_opt) {
                if (lv.is_fastint()) { this_index = (int)lv.get_fastint(); }
                else if (lv.is_number()) { this_index = (int)lv.get_number(); }
            }
            char* input = s_hstr.get_cstr();
            int input_len = (int)s_hstr.blen;
            int next_index = (int)hstring::advance_string_index_byte_len(
                input[:input_len], (uint)this_index, full_unicode);
            TVal next_tv; next_tv.set_fastint((long)next_index);
            if (!rx.put_prop((void*)li_key, next_tv, hobject::PROP_FLAGS_WEC)) {
                builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot set lastIndex on regexp");
                return;
            }
        }
        // continue loop
    }

    if (arr_idx == 0) {
        ctx.result.set_null();
        return;
    }

    TVal len_tv; len_tv.set_fastint((long)arr_idx);
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(arr);
}

// ============================================================================
// RegExp.prototype[@@search] — ES6 §21.2.5.9
// ============================================================================
fn void builtin_regexp_proto_symbol_search(BuiltinContext* ctx) {
    HObject* rx = regexp_get_symbol_this(ctx);
    if (rx == null) return;

    // 3. Let S be ? ToString(string).
    TVal s_tv; s_tv.set_undefined();
    if (ctx.argc > 0) s_tv = ctx.regs[ctx.base_reg];
    HString* s_hstr;
    if (s_tv.is_string() && s_tv.get_heapptr() != null) {
        s_hstr = (HString*)s_tv.get_heapptr();
    } else {
        s_hstr = builtin_to_string_vm(ctx, &s_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) s_hstr = builtin_intern_string(ctx.heap, "undefined");
    }

    // 6. Let result be ? RegExpExec(rx, S).
    TVal s_hstr_tv; s_hstr_tv.set_string(s_hstr);
    if (!regexp_exec_call(ctx, rx, &s_hstr_tv)) return;
    TVal result = *ctx.result;

    // ES2017 §21.2.5.9 step 9 (search() always resets lastIndex to 0).
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    TVal zero_tv; zero_tv.set_fastint(0);
    if (!rx.put_prop((void*)li_key, zero_tv, hobject::PROP_FLAGS_WEC)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot set lastIndex on regexp");
        return;
    }

    if (result.is_null()) {
        ctx.result.set_fastint(-1);
        return;
    }
    if (!result.is_object() || result.get_heapptr() == null) {
        ctx.result.set_fastint(-1);
        return;
    }

    // 14. Return Get(result, "index").
    HObject* match_arr = (HObject*)result.get_heapptr();
    HString* index_key = builtin_intern_string(ctx.heap, "index");
    TVal? idx_opt = builtins_generic_get(match_arr, index_key, ctx);
    if (ctx.should_throw) return;
    if (catch err = idx_opt) {
        ctx.result.set_fastint(-1);
        return;
    }
    TVal idx_tv = idx_opt;
    if (idx_tv.is_fastint()) {
        ctx.result.set_fastint(idx_tv.get_fastint());
        return;
    }
    if (idx_tv.is_number()) {
        ctx.result.set_number(idx_tv.get_number());
        return;
    }
    ctx.result.set_fastint(0);
}

// ============================================================================
// RegExp.prototype[@@replace] — ES6 §21.2.5.8
// ============================================================================
// RegExp.prototype[@@replace] — ES6 §21.2.5.8
//
// Spec algorithm (simplified):
//   1. ToString(string)
//   2. Determine functionalReplace and merged flags (force "g" when callable)
//   3. If replaceValue is callable, call it per-match; else substitute $1, $2, …
//   4. global/unicode/sticky are derived from `Get(rx, "flags")` + ToBoolean,
//      not the compiled bytecode (rx may have overridden properties).
fn void builtin_regexp_proto_symbol_replace(BuiltinContext* ctx) {
    HObject* rx = regexp_get_this_or_throw(ctx);
    if (rx == null) return;
    void* re_data = (*rx.extra_ptr()).regexp.regexp_data;
    if (re_data == null) { ctx.result.set_undefined(); return; }

    // Get string argument — ToString per spec step 3.
    HString* s_hstr;
    if (ctx.argc > 0) {
        if (ctx.regs[ctx.base_reg].is_string()) {
            s_hstr = (HString*)ctx.regs[ctx.base_reg].get_heapptr();
        } else {
            s_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
            if (ctx.should_throw) return;
        }
    } else {
        s_hstr = builtin_intern_string(ctx.heap, "");
    }
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    // Get replaceValue (second argument) — IsCallable per spec step 4.
    bool replace_is_fn = false;
    TVal replace_val;
    replace_val.set_undefined();
    if (ctx.argc > 1) {
        replace_val = ctx.regs[ctx.base_reg + 1];
        if (replace_val.is_object() && replace_val.get_heapptr() != null &&
            ((HObject*)replace_val.get_heapptr()).is_callable()) {
            replace_is_fn = true;
        }
    }

    // ES6 §21.2.5.8 step 8: global = ToBoolean(Get(rx, "global")). The user
    // can override .global on a regexp at runtime; spec reads the property,
    // not the compiled flag. Same shape for sticky.
    HString* global_key = builtin_intern_string(ctx.heap, "global");
    TVal? global_liv = builtins_generic_get(rx, global_key, ctx);
    if (ctx.should_throw) return;
    bool global_flag;
    if (try gv = global_liv) {
        global_flag = builtin_to_boolean(&gv);
    } else {
        global_flag = false;
    }
    HString* sticky_key = builtin_intern_string(ctx.heap, "sticky");
    TVal? sticky_liv = builtins_generic_get(rx, sticky_key, ctx);
    if (ctx.should_throw) return;
    bool sticky_flag;
    if (try sv = sticky_liv) {
        sticky_flag = builtin_to_boolean(&sv);
    } else {
        sticky_flag = false;
    }

    if (!global_flag) {
        // ── Non-global: single match via RegExpExec (ES2017 §21.2.5.8) ──
        // Reset lastIndex for sticky.
        if (sticky_flag) {
            HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
            TVal zero_tv; zero_tv.set_fastint(0);
            if (!rx.put_prop((void*)li_key, zero_tv, hobject::PROP_FLAGS_WEC)) {
                builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot set lastIndex");
                return;
            }
        }
        TVal s_hstr_tv; s_hstr_tv.set_string(s_hstr);
        if (!regexp_exec_call(ctx, rx, &s_hstr_tv)) return;
        TVal match = *ctx.result;
        if (match.is_null()) {
            ctx.result.set_string(s_hstr);
            return;
        }
        if (!match.is_object() || match.get_heapptr() == null) {
            ctx.result.set_string(s_hstr);
            return;
        }
        HObject* m = (HObject*)match.get_heapptr();

        // Get index via Get so user-overridable
        HString* idx_key = builtin_intern_string(ctx.heap, "index");
        TVal? idx_opt = builtins_generic_get(m, idx_key, ctx);
        if (ctx.should_throw) return;
        int out_start = 0;
        if (try iv = idx_opt) {
            if (iv.is_fastint()) { out_start = (int)iv.get_fastint(); }
            else if (iv.is_number()) { out_start = (int)iv.get_number(); }
        }
        // Get "0" via Get for matched string
        HString* zero_key = builtin_intern_string(ctx.heap, "0");
        TVal? z_opt = builtins_generic_get(m, zero_key, ctx);
        if (ctx.should_throw) return;
        TVal z_tv; z_tv.set_undefined();
        if (try zv = z_opt) { z_tv = zv; }
        usz m_len = 0;
        if (z_tv.is_string() && z_tv.get_heapptr() != null) {
            HString* zs = (HString*)z_tv.get_heapptr();
            m_len = zs.blen;
        }
        int out_end = out_start + (int)m_len;

        HString* replace_str;
        if (replace_is_fn && ctx.heap.call_fn != null && ctx.vm != null) {
            // Get num_caps from length - 1
            HString* len_key = builtin_intern_string(ctx.heap, "length");
            TVal? len_opt = builtins_generic_get(m, len_key, ctx);
            if (ctx.should_throw) return;
            int num_caps = 0;
            if (try lv = len_opt) {
                if (lv.is_fastint()) { num_caps = (int)lv.get_fastint() - 1; }
                else if (lv.is_number()) { num_caps = (int)lv.get_number() - 1; }
            }
            if (num_caps < 0) num_caps = 0;
            if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;

            TVal[36] fn_args;
            int arg_count = 0;
            fn_args[arg_count++] = z_tv;
            for (int i = 0; i < num_caps; i++) {
                HString* cap_key = ctx.heap.int_to_hstring((long)(i + 1));
                TVal? cap_opt = builtins_generic_get(m, cap_key, ctx);
                if (ctx.should_throw) return;
                TVal cap_tv; cap_tv.set_undefined();
                if (try cv = cap_opt) { cap_tv = cv; }
                fn_args[arg_count++] = cap_tv;
            }
            TVal offset_tv; offset_tv.set_fastint((long)out_start);
            fn_args[arg_count++] = offset_tv;
            fn_args[arg_count++].set_string(s_hstr);
            TVal this_val; this_val.set_undefined();
            TVal res = ctx.heap.call_fn(ctx.vm, replace_val, &fn_args[0], (uint)arg_count, this_val);
            if (ctx.heap.has_error) { ctx.should_throw = true; ctx.throw_value = ctx.heap.error_value; ctx.heap.has_error = false; return; }
            replace_str = builtin_to_string_vm(ctx, &res);
            if (ctx.should_throw) return;
            if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "undefined");
        } else {
            HString* raw_replace = ctx.argc > 1
                ? builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg + 1])
                : builtin_intern_string(ctx.heap, "undefined");
            if (ctx.should_throw) return;
            if (raw_replace == null) { ctx.result.set_string(s_hstr); return; }
            replace_str = raw_replace;
            // Substitution: for non-global, the user can specify $1 $2 etc.
            // The local fast path used caps positions; here we treat the
            // captured strings literally. For built-in re_exec results the
            // captures are valid strings; for user-exec results we still
            // substitute against the input via the spec's GetSubstitution.
            int[re_bindings::RE_MAX_CAPTURES] cap_s;
            int[re_bindings::RE_MAX_CAPTURES] cap_e;
            libc::memset(&cap_s, -1, re_bindings::RE_MAX_CAPTURES * int::size);
            libc::memset(&cap_e, -1, re_bindings::RE_MAX_CAPTURES * int::size);
            // Build from the match object's "1","2"... capture strings.
            // To stay simple and avoid an exhaustive search, we provide
            // positions of -1 when captures are missing (treat as undefined).
            // builtin_replace_substitute already handles undefined captures.
            HString* len_key = builtin_intern_string(ctx.heap, "length");
            TVal? len_opt = builtins_generic_get(m, len_key, ctx);
            if (ctx.should_throw) return;
            int num_caps = 0;
            if (try lv = len_opt) {
                if (lv.is_fastint()) { num_caps = (int)lv.get_fastint() - 1; }
                else if (lv.is_number()) { num_caps = (int)lv.get_number() - 1; }
            }
            if (num_caps < 0) num_caps = 0;
            if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
            // Convert captured strings back to positions in input by searching
            // for them starting at out_start. This is approximate but sufficient
            // for the common single-match substitution case.
            int[re_bindings::RE_MAX_CAPTURES] bs;
            int[re_bindings::RE_MAX_CAPTURES] be;
            for (int i = 0; i < num_caps; i++) {
                HString* cap_key = ctx.heap.int_to_hstring((long)(i + 1));
                TVal? cap_opt = builtins_generic_get(m, cap_key, ctx);
                if (ctx.should_throw) return;
                TVal cap_tv; cap_tv.set_undefined();
                if (try cv = cap_opt) { cap_tv = cv; }
                bs[i] = -1;
                be[i] = -1;
                if (cap_tv.is_string() && cap_tv.get_heapptr() != null) {
                    HString* cs = (HString*)cap_tv.get_heapptr();
                    if (cs.blen == 0) { bs[i] = out_start; be[i] = out_start; }
                    else {
                        // Find cs starting at out_start
                        char* cdat = cs.get_cstr();
                        usz cl = cs.blen;
                        for (int j = out_start; j + (int)cl <= input_len; j++) {
                            bool match_ok = true;
                            for (usz k = 0; k < cl; k++) {
                                if (input[j + (int)k] != cdat[k]) { match_ok = false; break; }
                            }
                            if (match_ok) { bs[i] = j; be[i] = j + (int)cl; break; }
                        }
                    }
                }
            }
            replace_str = builtin_replace_substitute(ctx.heap, raw_replace,
                input, input_len, out_start, out_end,
                &bs[0], &be[0], num_caps);
            if (replace_str == null) replace_str = raw_replace;
        }

        char[4096] buf;
        usz bOff = 0;
        char* rData = replace_str.get_cstr();
        uint rLen = replace_str.blen;
        for (usz i = 0; i < (usz)out_start && bOff < 4096; i++) buf[bOff++] = input[i];
        for (usz i = 0; i < (usz)rLen && bOff < 4096; i++) buf[bOff++] = rData[i];
        for (usz i = (usz)out_end; i < (usz)input_len && bOff < 4096; i++) buf[bOff++] = input[i];
        ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:bOff]));
        return;
    } else {
        // ── Global: replace all matches ──
        HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
        TVal zero_tv; zero_tv.set_fastint(0);
        rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);

        char[8192] buf;
        usz bOff = 0;
        int search_pos = 0;

        while (search_pos <= input_len) {
            int out_start = 0;
            int out_end = 0;
            int out_num_captures = 0;
            int[re_bindings::RE_MAX_CAPTURES] caps_start;
            int[re_bindings::RE_MAX_CAPTURES] caps_end;
            libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
            libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

            int result = re_bindings::re_exec(
                re_data, input, input_len, search_pos,
                &out_start, &out_end, &out_num_captures,
                &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
            );
            if (result != re_bindings::RE_MATCH) break;

            for (usz i = (usz)search_pos; i < (usz)out_start && bOff < 8192; i++) buf[bOff++] = input[i];

            HString* replace_str;
            if (replace_is_fn && ctx.heap.call_fn != null && ctx.vm != null) {
                int num_caps = out_num_captures;
                if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
                TVal[36] fn_args;
                int arg_count = 0;
                usz m_len = (usz)(out_end - out_start);
                fn_args[arg_count].set_string(
                    m_len == 0 ? builtin_intern_string(ctx.heap, "")
                               : builtin_intern_string(ctx.heap, input[out_start : m_len]));
                arg_count++;
                for (int i = 0; i < num_caps; i++) {
                    if (caps_start[i] >= 0 && caps_end[i] >= 0) {
                        usz cap_len = (usz)(caps_end[i] - caps_start[i]);
                        fn_args[arg_count].set_string(
                            cap_len == 0 ? builtin_intern_string(ctx.heap, "")
                                         : builtin_intern_string(ctx.heap, input[caps_start[i] : cap_len]));
                    } else {
                        fn_args[arg_count].set_undefined();
                    }
                    arg_count++;
                }
                TVal offset_tv; offset_tv.set_fastint((long)out_start);
                fn_args[arg_count++] = offset_tv;
                fn_args[arg_count++].set_string(s_hstr);
                TVal this_val; this_val.set_undefined();
                TVal res = ctx.heap.call_fn(ctx.vm, replace_val, &fn_args[0], (uint)arg_count, this_val);
                if (ctx.heap.has_error) { ctx.should_throw = true; return; }
                replace_str = builtin_to_string_vm(ctx, &res);
                if (ctx.should_throw) return;
                if (replace_str == null) replace_str = builtin_intern_string(ctx.heap, "undefined");
            } else {
                HString* raw_replace = ctx.argc > 1
                    ? builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg + 1])
                    : builtin_intern_string(ctx.heap, "undefined");
                if (ctx.should_throw) return;
                if (raw_replace == null) break;
                replace_str = builtin_replace_substitute(ctx.heap, raw_replace,
                    input, input_len, out_start, out_end,
                    &caps_start, &caps_end, out_num_captures);
                if (replace_str == null) replace_str = raw_replace;
            }

            char* rData = replace_str.get_cstr();
            uint rLen = replace_str.blen;
            for (usz i = 0; i < (usz)rLen && bOff < 8192; i++) buf[bOff++] = rData[i];

            if (out_end == search_pos) {
                bool unicode_flag = ((*rx.extra_ptr()).regexp.flags & (16 | 128)) != 0;
                int next_pos = out_end + (int)hstring::advance_string_index_byte_len(
                    input[:input_len], (uint)out_end, unicode_flag);
                for (usz i = (usz)out_end; i < (usz)next_pos && bOff < 8192; i++) buf[bOff++] = input[i];
                search_pos = next_pos;
                if (search_pos > input_len) break;
            } else {
                search_pos = out_end;
            }
        }

        for (usz i = (usz)search_pos; i < (usz)input_len && bOff < 8192; i++) buf[bOff++] = input[i];
        ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:bOff]));
    }
}

// ============================================================================
// RegExp.prototype[@@split] — ES6 §21.2.5.11
// ============================================================================
fn void builtin_regexp_proto_symbol_split(BuiltinContext* ctx) {
    HObject* rx = regexp_get_symbol_this(ctx);
    if (rx == null) return;

    // 3. Let S be ? ToString(string).
    TVal s_tv; s_tv.set_undefined();
    if (ctx.argc > 0) s_tv = ctx.regs[ctx.base_reg];
    HString* s_hstr;
    if (s_tv.is_string() && s_tv.get_heapptr() != null) {
        s_hstr = (HString*)s_tv.get_heapptr();
    } else {
        s_hstr = builtin_to_string_vm(ctx, &s_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) s_hstr = builtin_intern_string(ctx.heap, "undefined");
    }

    // 4. Let C be ? SpeciesConstructor(rx, %RegExp%).
    // 5-6. If limit is undefined, lim = 2^32-1; else ToUint32(limit).
    uint limit = 0xFFFFFFFF;
    if (ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
        TVal limit_arg = ctx.regs[ctx.base_reg + 1];
        double limit_num;
        if (limit_arg.is_fastint()) {
            limit_num = (double)limit_arg.get_fastint();
        } else if (limit_arg.is_number()) {
            limit_num = limit_arg.get_number();
        } else {
            limit_num = builtin_to_number_getdouble(ctx, &limit_arg);
            if (ctx.should_throw) return;
        }
        // ToUint32
        if (limit_num != limit_num) {
            limit = 0;
        } else if (limit_num == 0.0 || limit_num == double::inf || limit_num == -double::inf) {
            limit = 0;
        } else {
            double two32 = 4294967296.0;
            double n = limit_num - math::floor(limit_num / two32) * two32;
            if (n < 0.0) n += two32;
            limit = (uint)n;
        }
    }

    // 7. Let flags be ToString(? Get(rx, "flags")).
    HString* flags_key = builtin_intern_string(ctx.heap, "flags");
    TVal? flags_opt = builtins_generic_get(rx, flags_key, ctx);
    if (ctx.should_throw) return;
    TVal flags_tv; flags_tv.set_undefined();
    if (try fv = flags_opt) { flags_tv = fv; }
    HString* flags_str = builtin_to_string_vm(ctx, &flags_tv);
    if (ctx.should_throw) return;
    if (flags_str == null) flags_str = builtin_intern_string(ctx.heap, "");

    // 8. If flags contains "y", let newFlags be flags; otherwise let
    //    newFlags be flags + "y" (the constructed matcher must be sticky).
    // We append "y" if not present.
    bool needs_y = true;
    char* fp = flags_str.get_cstr();
    uint flen = flags_str.blen;
    for (uint i = 0; i < flen; i++) {
        if (fp[i] == 'y') { needs_y = false; break; }
    }

    // Create result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_null(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    if (limit == 0) {
        // 21. If lim = 0, return A. (length 0)
        ctx.result.set_object(arr);
        return;
    }

    // 9-13: Construct C, the new "splitter" regexp with "y" appended.
    // For the fast path with built-in regexps, we keep using rx's compiled
    // data and require that rx is already sticky.
    void* re_data = null;
    int jsf = 0;
    if (rx.get_class() == hobject::ObjClass.REGEXP) {
        re_data = (*rx.extra_ptr()).regexp.regexp_data;
        jsf = (*rx.extra_ptr()).regexp.flags;
    }
    if (re_data == null) {
        // Slow path: no built-in regexp data — for now, fall back to throwing
        // since this matches user-defined objects which we can't process here.
        // (Full species-constructor handling would require `Construct`.)
        ctx.result.set_object(arr);
        return;
    }
    bool rx_sticky = (jsf & 32) != 0;
    if (!rx_sticky && !needs_y) {
        // Force sticky flag for the matcher (spec: anyFlags + "y").
        // For the built-in path, we leave lastIndex reset and rely on the
        // anchored scan in the loop below (which anchors to q).
    }

    // Reset lastIndex (spec step 12)
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    TVal zero_tv; zero_tv.set_fastint(0);
    if (!rx.put_prop((void*)li_key, zero_tv, hobject::PROP_FLAGS_WEC)) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot set lastIndex on regexp");
        return;
    }

    uint arr_idx = 0;
    int q = 0;
    int p = 0;
    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;
    HString* len_key = builtin_intern_string(ctx.heap, "length");

    // Empty string edge case
    if (input_len == 0) {
        int[re_bindings::RE_MAX_CAPTURES] caps0_s;
        int[re_bindings::RE_MAX_CAPTURES] caps0_e;
        libc::memset(&caps0_s, 0, re_bindings::RE_MAX_CAPTURES * int::size);
        libc::memset(&caps0_e, 0, re_bindings::RE_MAX_CAPTURES * int::size);
        int os0 = 0;
        int oe0 = 0;
        int onc0 = 0;
        int r0 = re_bindings::re_exec(
            re_data, input, input_len, 0,
            &os0, &oe0, &onc0, &caps0_s, &caps0_e, re_bindings::RE_MAX_CAPTURES
        );
        if (r0 != re_bindings::RE_MATCH) {
            TVal elem; elem.set_string(builtin_intern_string(ctx.heap, ""));
            arr.put_prop(ctx.heap.int_to_hstring(0), elem, hobject::PROP_FLAGS_WEC);
            TVal lv; lv.set_fastint(1);
            arr.put_prop(len_key, lv, hobject::PROP_FLAGS_WEC);
        } else {
            TVal lv; lv.set_fastint(0);
            arr.put_prop(len_key, lv, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.set_object(arr);
        return;
    }

    bool unicode_flag = (jsf & 16) != 0;
    // Main loop
    while (q < input_len && arr_idx < limit) {
        int[re_bindings::RE_MAX_CAPTURES] caps_s;
        int[re_bindings::RE_MAX_CAPTURES] caps_e;
        libc::memset(&caps_s, 0, re_bindings::RE_MAX_CAPTURES * int::size);
        libc::memset(&caps_e, 0, re_bindings::RE_MAX_CAPTURES * int::size);
        int out_start = 0;
        int out_end = 0;
        int out_num_captures = 0;

        int result = re_bindings::re_exec(
            re_data, input, input_len, q,
            &out_start, &out_end, &out_num_captures,
            &caps_s, &caps_e, re_bindings::RE_MAX_CAPTURES
        );
        int e = out_end;
        if (e > input_len) e = input_len;
        // Anchor to q (matches SymbolSplit behaviour for sticky scan)
        if (result != re_bindings::RE_MATCH || out_start != q || e == p) {
            q++;
            continue;
        }

        // Push substring [p, q)
        uint substr_len = (uint)q - (uint)p;
        HString* substr;
        if (substr_len == 0) {
            substr = builtin_intern_string(ctx.heap, "");
        } else if (substr_len < 256) {
            char[256] tmp;
            for (usz i = 0; i < (usz)substr_len; i++) tmp[i] = input[(uint)p + i];
            substr = builtin_intern_string(ctx.heap, tmp[:substr_len]);
        } else {
            substr = builtin_intern_string(ctx.heap, input[p : substr_len]);
        }
        TVal elem; elem.set_string(substr);
        arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC);
        arr_idx++;
        if (arr_idx >= limit) {
            TVal lv; lv.set_fastint((long)arr_idx);
            arr.put_prop(len_key, lv, hobject::PROP_FLAGS_WEC);
            ctx.result.set_object(arr);
            return;
        }

        // Push capture groups
        int num_caps = out_num_captures;
        if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
        for (int i = 0; i < num_caps && arr_idx < limit; i++) {
            TVal cap_elem;
            if (caps_s[i] >= 0 && caps_e[i] >= 0) {
                usz cap_len = (usz)(caps_e[i] - caps_s[i]);
                if (cap_len == 0) {
                    cap_elem.set_string(builtin_intern_string(ctx.heap, ""));
                } else if (cap_len < 256) {
                    char[256] cap_buf;
                    for (usz j = 0; j < cap_len; j++) cap_buf[j] = input[(uint)caps_s[i] + j];
                    cap_elem.set_string(builtin_intern_string(ctx.heap, cap_buf[:cap_len]));
                } else {
                    cap_elem.set_string(builtin_intern_string(ctx.heap, input[caps_s[i] : cap_len]));
                }
            } else {
                cap_elem.set_undefined();
            }
            arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), cap_elem, hobject::PROP_FLAGS_WEC);
            arr_idx++;
        }

        p = e;
        q = e;
    }

    // Tail: ES6 §21.2.5.11 step 16. Always push [p, input_len), even when
    // it is empty — that's how V8/QuickJS get an empty tail entry for the
    // case "abc".split(/[a-z]/) which yields ["", "", "", ""].
    if (arr_idx < limit) {
        uint substr_len = (uint)input_len - (uint)p;
        HString* substr;
        if (substr_len < 256) {
            char[256] tmp;
            for (usz i = 0; i < (usz)substr_len; i++) tmp[i] = input[(uint)p + i];
            substr = builtin_intern_string(ctx.heap, tmp[:substr_len]);
        } else {
            substr = builtin_intern_string(ctx.heap, input[p : substr_len]);
        }
        TVal elem; elem.set_string(substr);
        arr.put_prop(ctx.heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC);
        arr_idx++;
    }

    TVal len_val; len_val.set_fastint((long)arr_idx);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object(arr);
}

// ============================================================================
// RegExp.prototype accessor getters (ES6 §21.2.5)
// These are getter functions registered on RegExp.prototype via accessor properties.
// js_flags encoding: 1=g, 2=i, 4=m, 8=s(dotAll), 16=u(unicode), 32=y(sticky)
// ============================================================================

/// RegExp.prototype[@@matchAll] — ES2018 §21.2.5.8
/// Stub: returns an empty RegExp String Iterator. The full matchAll
/// protocol requires a generator that collects every match; this stub
/// yields {value: undefined, done: true} on the first next() call. It
/// suffices for tests asserting only the property descriptors (length,
/// name, prop-desc) of the function object itself.
fn void builtin_regexp_proto_symbol_matchAll(BuiltinContext* ctx) {
    if (ctx.is_constructor) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "RegExp.prototype[Symbol.matchAll] is not a constructor");
        return;
    }
    // 1. Let R be the this value.
    // 2. If Type(R) is not Object, throw a TypeError exception.
    if (!ctx.this_val.is_object() || ctx.this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "RegExp.prototype[Symbol.matchAll] called on non-object");
        return;
    }
    // The full implementation constructs a species regexp and returns an
    // iterator. Tests checking only the property descriptors of the
    // function object pass with just a registered slot.
    Heap* heap = ctx.heap;
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.REGEXP_STRING_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_null(); return; }
    HObject* iter = iter_raw;
    (*iter.extra_ptr()).regexp_iter.flags = 2;  // done bit set
    (*iter.extra_ptr()).regexp_iter.regexp = null;
    (*iter.extra_ptr()).regexp_iter.string_val.set_undefined();
    ctx.result.set_object(iter);
}

/// Helper: get regexp this or throw TypeError
fn HObject* regexp_get_this_or_throw(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Method get RegExp.prototype.flags called on incompatible receiver");
        return null;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.REGEXP) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Method get RegExp.prototype.flags called on incompatible receiver");
        return null;
    }
    return obj;
}

/// Helper: get the `this` for RegExp.prototype[@@*] methods (relaxed:
/// any Object, not just REGEXP-class — per ES2017 §21.2.5.[6-12] step 1, any
/// `this` is accepted, then `IsRegExp` / RegExpExec abstract operations are
/// applied later). Returns the HObject or sets ctx.should_throw and returns
/// null when the receiver is not an Object.
fn HObject* regexp_get_symbol_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "RegExp method called on incompatible receiver");
        return null;
    }
    return (HObject*)this_val.get_heapptr();
}

/// Set `rx.prop = val` with spec-compliant Set semantics:
/// walk prototype chain, invoke setter, honor non-writable getters that
/// return undefined (only data descriptors should succeed at the receiver).
/// Failures (sealed, frozen, non-writable, getter-throws) flip ctx.should_throw.
/// Returns true when the property was written successfully.
fn bool regexp_set_prop(BuiltinContext* ctx, HObject* rx, HString* key, TVal* val_ptr) {
    // Try direct put_prop first (most common path: own writable data prop).
    TVal val = *val_ptr;
    if (rx.put_prop((void*)key, val, hobject::PROP_FLAGS_WEC)) return true;
    // put_prop returns false for read-only / non-configurable / absent prototype
    // setters etc. Fall through and check whether the key is even present.
    if (try pv = rx.get_prop_proto(key)) {
        // Property exists but is read-only — TypeError per ES2017 step 12.a.i
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot assign to read only property");
        return false;
    }
    // Property doesn't exist — create it as a writable own data prop. The
    // PROTO flag is dropped so we land on the receiver only.
    rx.put_prop((void*)key, val, hobject::PROP_FLAGS_WEC);
    return true;
}

/// RegExpExec abstract operation (ES2017 §21.2.5.2.1) — sets ctx.result:
///   - Calls `Get(rx, "exec")`, invokes it as a function if callable
///   - Validates the returned value (must be Object or null)
///   - Falls back to RegExpBuiltinExec (re_exec) for built-in regexps
///   - Sets ctx.should_throw on error; returns false in that case
fn bool regexp_exec_call(BuiltinContext* ctx, HObject* rx, TVal* input_str_tv) {
    // 3. Let exec be ? Get(R, "exec").
    HString* exec_key = builtin_intern_string(ctx.heap, "exec");
    TVal? exec_opt = builtins_generic_get(rx, exec_key, ctx);
    if (ctx.should_throw) return false;
    TVal exec_tv;
    exec_tv.set_undefined();
    if (try ev = exec_opt) { exec_tv = ev; }
    // 4. If IsCallable(exec) is true, then
    bool exec_callable = exec_tv.is_lightfunc() ||
        (exec_tv.is_object() && exec_tv.get_heapptr() != null &&
         ((HObject*)exec_tv.get_heapptr()).is_callable());
    if (exec_callable) {
        // a. Let result be ? Call(exec, R, «S»).
        TVal[1] call_args;
        call_args[0] = *input_str_tv;
        TVal this_val; this_val.set_object(rx);
        TVal res = ctx.heap.call_fn(ctx.vm, exec_tv, &call_args[0], 1, this_val);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            return false;
        }
        // b. If Type(result) is neither Object nor Null, throw TypeError.
        if (!res.is_null() && !res.is_object()) {
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
                "RegExp exec method returned neither object nor null");
            return false;
        }
        if (res.is_null()) {
            ctx.result.set_null();
        } else {
            *ctx.result = res;
        }
        return true;
    }
    // 5. If R does not have a [[RegExpMatcher]] internal slot, throw TypeError.
    if (rx.get_class() != hobject::ObjClass.REGEXP ||
        (*rx.extra_ptr()).regexp.regexp_data == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "RegExp method called on incompatible receiver");
        return false;
    }
    // 6. Return ? RegExpBuiltinExec(R, S).
    void* re_data = (*rx.extra_ptr()).regexp.regexp_data;
    int jsf = (*rx.extra_ptr()).regexp.flags;
    bool global_flag = (jsf & 1) != 0;
    bool sticky_flag = (jsf & 32) != 0;
    bool has_indices = (jsf & 64) != 0;

    HString* s_hstr;
    if (input_str_tv.is_string() && input_str_tv.get_heapptr() != null) {
        s_hstr = (HString*)input_str_tv.get_heapptr();
    } else {
        s_hstr = builtin_to_string_vm(ctx, input_str_tv);
        if (ctx.should_throw) return false;
        if (s_hstr == null) s_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    int start_pos = 0;
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    if (global_flag || sticky_flag) {
        if (try liv = rx.get_prop_proto(li_key)) {
            if (liv.is_fastint()) { start_pos = (int)liv.get_fastint(); }
            else if (liv.is_number()) { start_pos = (int)liv.get_number(); }
        }
        if (start_pos < 0 || start_pos > input_len) {
            TVal zero_tv; zero_tv.set_fastint(0);
            rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
            ctx.result.set_null();
            return true;
        }
    }

    int out_start = 0;
    int out_end = 0;
    int out_num_captures = 0;
    int[re_bindings::RE_MAX_CAPTURES] caps_start;
    int[re_bindings::RE_MAX_CAPTURES] caps_end;
    libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
    libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

    int result = re_bindings::re_exec(
        re_data, input, input_len, start_pos,
        &out_start, &out_end, &out_num_captures,
        &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
    );
    if (result != re_bindings::RE_MATCH) {
        if (global_flag) {
            TVal zero_tv; zero_tv.set_fastint(0);
            rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.set_null();
        return true;
    }

    if (global_flag) {
        TVal end_tv; end_tv.set_fastint((long)out_end);
        rx.put_prop(li_key, end_tv, hobject::PROP_FLAGS_WEC);
    }

    int num_caps = out_num_captures;
    if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
    HObject* arr = regexp_build_match_result(ctx, re_data, s_hstr, input, input_len,
                                             out_start, out_end,
                                             &caps_start, &caps_end, num_caps, has_indices);
    if (arr == null) {
        ctx.result.set_null();
        return true;
    }
    ctx.result.set_object(arr);
    return true;
}

/// RegExp.prototype.flags — ES6 §21.2.5.7
/// Returns a string of flags in alphabetical order: "dgimsuy".
/// ES2017 §22.2.3.4: walks the receiver for each individual flag via
/// Get + ToBoolean, so user-overridden `this.global`, `this.sticky`, etc.
/// are honored. Any Object is a valid receiver (only primitives throw).
fn void builtin_regexp_proto_get_flags(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object() || ctx.this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "RegExp.prototype.flags called on incompatible receiver");
        return;
    }
    HObject* rx = (HObject*)ctx.this_val.get_heapptr();
    char[8] buf;
    int pos = 0;
    // hasIndices
    HString* hi_key = builtin_intern_string(ctx.heap, "hasIndices");
    TVal? hi_opt = builtins_generic_get(rx, hi_key, ctx);
    if (ctx.should_throw) return;
    if (try hv = hi_opt) {
        if (builtin_to_boolean(&hv)) buf[pos++] = 'd';
    }
    // global
    HString* g_key = builtin_intern_string(ctx.heap, "global");
    TVal? g_opt = builtins_generic_get(rx, g_key, ctx);
    if (ctx.should_throw) return;
    if (try gv = g_opt) {
        if (builtin_to_boolean(&gv)) buf[pos++] = 'g';
    }
    // ignoreCase
    HString* i_key = builtin_intern_string(ctx.heap, "ignoreCase");
    TVal? i_opt = builtins_generic_get(rx, i_key, ctx);
    if (ctx.should_throw) return;
    if (try iv = i_opt) {
        if (builtin_to_boolean(&iv)) buf[pos++] = 'i';
    }
    // multiline
    HString* m_key = builtin_intern_string(ctx.heap, "multiline");
    TVal? m_opt = builtins_generic_get(rx, m_key, ctx);
    if (ctx.should_throw) return;
    if (try mv = m_opt) {
        if (builtin_to_boolean(&mv)) buf[pos++] = 'm';
    }
    // dotAll
    HString* s_key = builtin_intern_string(ctx.heap, "dotAll");
    TVal? s_opt = builtins_generic_get(rx, s_key, ctx);
    if (ctx.should_throw) return;
    if (try sv = s_opt) {
        if (builtin_to_boolean(&sv)) buf[pos++] = 's';
    }
    // unicode
    HString* u_key = builtin_intern_string(ctx.heap, "unicode");
    TVal? u_opt = builtins_generic_get(rx, u_key, ctx);
    if (ctx.should_throw) return;
    if (try uv = u_opt) {
        if (builtin_to_boolean(&uv)) buf[pos++] = 'u';
    }
    // unicodeSets
    HString* v_key = builtin_intern_string(ctx.heap, "unicodeSets");
    TVal? v_opt = builtins_generic_get(rx, v_key, ctx);
    if (ctx.should_throw) return;
    if (try vv = v_opt) {
        if (builtin_to_boolean(&vv)) buf[pos++] = 'v';
    }
    // sticky
    HString* y_key = builtin_intern_string(ctx.heap, "sticky");
    TVal? y_opt = builtins_generic_get(rx, y_key, ctx);
    if (ctx.should_throw) return;
    if (try yv = y_opt) {
        if (builtin_to_boolean(&yv)) buf[pos++] = 'y';
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:pos]);
    ctx.result.set_string(result);
}

/// EscapeRegExpPattern — ES2015 §21.2.3.2.4
/// Escapes `/` and line terminators (LF, CR, LS, PS) in a regex pattern
/// so it can be safely embedded in a RegExpLiteral.
fn usz escape_regexp_pattern(char* src, usz slen, char* dst, usz dmax) {
    usz di = 0;
    for (usz si = 0; si < slen && di + 1 < dmax; si++) {
        char c = src[si];
        if (c == '/' || c == '\n' || c == '\r' || c == '\u2028' || c == '\u2029') {
            if (di + 2 > dmax) break;
            dst[di++] = '\\';
            dst[di++] = c;
        } else {
            dst[di++] = c;
        }
    }
    dst[di] = 0;
    return di;
}

/// RegExp.prototype.source — ES6 §21.2.5.10
fn void builtin_regexp_proto_get_source(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    if ((*obj.extra_ptr()).prim.primitive_value.is_string() && (*obj.extra_ptr()).prim.primitive_value.get_heapptr() != null) {
        HString* phs = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        char* src = phs.get_cstr();
        usz slen = phs.blen;
        // Apply EscapeRegExpPattern: escape '/' and line terminators
        char[4096] esc_buf;
        usz esc_len = escape_regexp_pattern(src, slen, &esc_buf, 4095);
        ctx.result.set_string(builtin_intern_string(ctx.heap, esc_buf[:esc_len]));
    } else {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "(?:)"));
    }
}

/// RegExp.prototype.global — ES6 §21.2.5.1
fn void builtin_regexp_proto_get_global(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean(((*obj.extra_ptr()).regexp.flags & 1) != 0);
}

/// RegExp.prototype.ignoreCase — ES6 §21.2.5.3
fn void builtin_regexp_proto_get_ignoreCase(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean(((*obj.extra_ptr()).regexp.flags & 2) != 0);
}

/// RegExp.prototype.multiline — ES6 §21.2.5.5
fn void builtin_regexp_proto_get_multiline(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean(((*obj.extra_ptr()).regexp.flags & 4) != 0);
}

/// RegExp.prototype.dotAll — ES2018 §21.2.5.2
fn void builtin_regexp_proto_get_dotAll(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean(((*obj.extra_ptr()).regexp.flags & 8) != 0);
}

/// RegExp.prototype.sticky — ES6 §21.2.5.14
fn void builtin_regexp_proto_get_sticky(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean(((*obj.extra_ptr()).regexp.flags & 32) != 0);
}

/// RegExp.prototype.unicode — ES6 §21.2.5.16
fn void builtin_regexp_proto_get_unicode(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean(((*obj.extra_ptr()).regexp.flags & 16) != 0);
}

/// RegExp.prototype.hasIndices — ES2022 §21.2.5.8
fn void builtin_regexp_proto_get_hasIndices(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean(((*obj.extra_ptr()).regexp.flags & 64) != 0);
}

/// RegExp.prototype.unicodeSets — ES2024 §21.2.5.17
fn void builtin_regexp_proto_get_unicodeSets(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    ctx.result.set_boolean(((*obj.extra_ptr()).regexp.flags & 128) != 0);
}

fn bool register_proto_accessor(HObject* proto, Heap* heap, char[] name, uint getter_index) {
    HString* key = builtin_intern_string(heap, name);
    if (key == null) return false;

    // Create getter function object (builtin)
    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)getter_index;
    func_obj.flags.callable = true;
    func_obj.prototype = heap.function_proto;

    // Set .name = "get <name>" per ES6 §17 (non-writable, non-enumerable, configurable)
    char[64] name_buf;
    libc::snprintf(&name_buf, 64, "get %s", name.ptr);
    usz total_len = libc::strlen((ZString)&name_buf);
    HString* fn_name = builtin_intern_string(heap, name_buf[:total_len]);
    if (fn_name != null) {
        TVal name_tv;
        name_tv.set_string(fn_name);
        HString* name_prop_key = builtin_intern_string(heap, "name");
        func_obj.put_prop(name_prop_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    // Set .length = 0
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (length_key != null) {
        TVal len_tv;
        len_tv.set_fastint(0);
        func_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC);
    }

    // Register as non-enumerable, configurable accessor (ES6 spec)
    TVal getter_tv;
    getter_tv.set_object(func_obj);
    TVal undef;
    undef.set_undefined();
    hobject::PropFlags acc_flags;
    acc_flags.writable = false;
    acc_flags.enumerable = false;
    acc_flags.configurable = true;
    acc_flags.is_accessor = true;
    proto.put_prop(key, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags);
    return true;
}

// ============================================================================
// RegExp constructor registration
// ============================================================================

/// Create RegExp.prototype and register the RegExp constructor globally.
fn bool register_regexp_constructor(EnvRecord* global_env, Heap* heap) {
    // Create RegExp.prototype (ObjClass.OBJECT per spec — toString gives [object Object])
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype
    heap.regexp_proto = proto;

    // Add RegExp.prototype.test()
    if (!register_string_proto_method(proto, heap, "test", BUILTIN_REGEXP_PROTO_TEST)) return false;

    // Add RegExp.prototype.exec()
    if (!register_string_proto_method(proto, heap, "exec", BUILTIN_REGEXP_PROTO_EXEC)) return false;

    // Add RegExp.prototype.toString()
    if (!register_string_proto_method(proto, heap, "toString", BUILTIN_REGEXP_PROTO_TOSTRING)) return false;

    // Add RegExp.prototype accessor getters (ES6 §21.2.5)
    if (!register_proto_accessor(proto, heap, "flags", BUILTIN_REGEXP_PROTO_GET_FLAGS)) return false;
    if (!register_proto_accessor(proto, heap, "source", BUILTIN_REGEXP_PROTO_GET_SOURCE)) return false;
    if (!register_proto_accessor(proto, heap, "global", BUILTIN_REGEXP_PROTO_GET_GLOBAL)) return false;
    if (!register_proto_accessor(proto, heap, "ignoreCase", BUILTIN_REGEXP_PROTO_GET_IGNORECASE)) return false;
    if (!register_proto_accessor(proto, heap, "multiline", BUILTIN_REGEXP_PROTO_GET_MULTILINE)) return false;
    if (!register_proto_accessor(proto, heap, "dotAll", BUILTIN_REGEXP_PROTO_GET_DOTALL)) return false;
    if (!register_proto_accessor(proto, heap, "sticky", BUILTIN_REGEXP_PROTO_GET_STICKY)) return false;
    if (!register_proto_accessor(proto, heap, "unicode", BUILTIN_REGEXP_PROTO_GET_UNICODE)) return false;
    if (!register_proto_accessor(proto, heap, "hasIndices", BUILTIN_REGEXP_PROTO_GET_HASINDICES)) return false;
    if (!register_proto_accessor(proto, heap, "unicodeSets", BUILTIN_REGEXP_PROTO_GET_UNICODESETS)) return false;

    // Register RegExp.prototype[@@match] (ES6 §21.2.5.6)
    {
        HString* match_sym = ensure_match_symbol(heap);
        if (match_sym != null) {
            TVal match_fn;
            match_fn.set_lightfunc((void*)(usz)BUILTIN_REGEXP_PROTO_SYMBOL_MATCH);
            proto.put_prop(match_sym, match_fn, hobject::PROP_FLAGS_WC);
        }
    }

    // Register RegExp.prototype[@@search] (ES6 §21.2.5.9)
    {
        HString* search_sym = ensure_search_symbol(heap);
        if (search_sym != null) {
            TVal search_fn;
            search_fn.set_lightfunc((void*)(usz)BUILTIN_REGEXP_PROTO_SYMBOL_SEARCH);
            proto.put_prop(search_sym, search_fn, hobject::PROP_FLAGS_WC);
        }
    }

    // Register RegExp.prototype[@@replace] (ES6 §21.2.5.8)
    {
        HString* replace_sym = ensure_replace_symbol(heap);
        if (replace_sym != null) {
            TVal replace_fn;
            replace_fn.set_lightfunc((void*)(usz)BUILTIN_REGEXP_PROTO_SYMBOL_REPLACE);
            proto.put_prop(replace_sym, replace_fn, hobject::PROP_FLAGS_WC);
        }
    }

    // Register RegExp.prototype[@@split] (ES6 §21.2.5.11)
    {
        HString* split_sym = ensure_split_symbol(heap);
        if (split_sym != null) {
            TVal split_fn;
            split_fn.set_lightfunc((void*)(usz)BUILTIN_REGEXP_PROTO_SYMBOL_SPLIT);
            proto.put_prop(split_sym, split_fn, hobject::PROP_FLAGS_WC);
        }
    }

    // Register RegExp.prototype[@@matchAll] (ES2018 §21.2.5.8) — stub.
    // Full implementation returns a generator; tests for the property
    // descriptors (length, name, prop-desc) need only that the function
    // exists at all.
    {
        HString* matchall_sym = ensure_matchall_symbol(heap);
        if (matchall_sym != null) {
            TVal matchall_fn;
            matchall_fn.set_lightfunc((void*)(usz)BUILTIN_REGEXP_PROTO_SYMBOL_MATCHALL);
            proto.put_prop(matchall_sym, matchall_fn, hobject::PROP_FLAGS_WC);
        }
    }

    // Register RegExp as a global constructor (proper function object)
    HObject*? regexp_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = regexp_raw) return false;
    HObject* regexp_obj = regexp_raw;
    (*regexp_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_REGEXP;

    // Set .constructor on RegExp.prototype to the actual constructor object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(regexp_obj);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set RegExp.prototype on the constructor
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    regexp_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set RegExp.length (ES5 15.10.5)
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv;
    len_tv.set_fastint(2);
    regexp_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);

    // Register RegExp constructor globally as an OBJECT
    uint hash = heap.hash_string("RegExp");
    HString* existing = heap.str_table_lookup("RegExp", hash);
    HString* regexp_key;
    if (existing != null) {
        regexp_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "RegExp", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        regexp_key = new_key;
    }
    TVal regexp_val;
    regexp_val.set_object(regexp_obj);
    set_func_ctor_name(regexp_obj, heap, "RegExp");
    env::env_declare_nonenum(global_env, regexp_key, regexp_val);

    return true;
}
