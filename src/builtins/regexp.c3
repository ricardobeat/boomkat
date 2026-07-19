/// RegExp constructor and RegExp.prototype methods.
module duktape::builtins;
import duktape::types;
import libc;
import duktape::hstring;
import duktape::env;
import duktape::vm;
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
    TVal pattern_arg;
    pattern_arg.set_undefined();

    if (ctx.argc > 0) {
        pattern_arg = ctx.regs[ctx.base_reg];
        if (pattern_arg.is_object() && pattern_arg.get_heapptr() != null) {
            HObject* obj = (HObject*)pattern_arg.get_heapptr();
            // ES2022 §22.2.3.1 step 1: IsRegExp(pattern) — check @@match to detect
            // regexp-like objects.
            bool pattern_is_regexp = false;
            bool is_actual_regexp = (obj.get_class() == hobject::ObjClass.REGEXP && (*obj.extra_ptr()).regexp.regexp_data != null);
            if (ctx.vm != null) {
                // IsRegExp spec steps 2-3: Get(obj, @@match). If defined, return ToBoolean.
                HString* match_sym = ensure_match_symbol(ctx.heap);
                bool checked_match = false;
                if (match_sym != null) {
                    TVal? match_opt = builtins_generic_get(obj, match_sym, ctx);
                    if (ctx.should_throw) return;
                    if (try mv = match_opt) {
                        if (!mv.is_undefined()) {
                            // @@match is defined: IsRegExp = ToBoolean(@@match)
                            pattern_is_regexp = builtin_to_boolean(&mv);
                            checked_match = true;
                        }
                    }
                }
                // IsRegExp spec step 4: if @@match was undefined and has [[RegExpMatcher]], return true.
                if (!checked_match && is_actual_regexp) {
                    pattern_is_regexp = true;
                }
            } else if (is_actual_regexp) {
                // No VM available: fall back to internal slot check.
                pattern_is_regexp = true;
            }
            if (is_actual_regexp && pattern_is_regexp) {
                // Pattern is an actual RegExp object with truthy @@match — extract its pattern
                is_regexp = true;
                pattern_regexp = obj;
                if ((*obj.extra_ptr()).prim.primitive_value.is_string()) {
                    HString* phs = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
                    pattern_str = phs.get_cstr();
                    pattern_len = phs.blen;
                }
            } else if (pattern_is_regexp) {
                // ES2022 §22.2.3.1 step 6: regexp-like non-RegExp object — extract source and flags.
                is_regexp = true;
                // Step 6a: P = Get(pattern, "source")
                HString* source_key = builtin_intern_string(ctx.heap, "source");
                TVal? src_opt = builtins_generic_get(obj, source_key, ctx);
                if (ctx.should_throw) return;
                if (try sv = src_opt) {
                    if (sv.is_string() && sv.get_heapptr() != null) {
                        HString* src_hs = (HString*)sv.get_heapptr();
                        pattern_str = src_hs.get_cstr();
                        pattern_len = src_hs.blen;
                    } else {
                        HString* src_hs = builtin_to_string_vm(ctx, &sv);
                        if (ctx.should_throw) return;
                        if (src_hs != null) {
                            pattern_str = src_hs.get_cstr();
                            pattern_len = src_hs.blen;
                        }
                    }
                }
                // Step 6c: If flags argument is undefined, F = Get(pattern, "flags")
                bool flags_arg_provided = ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined();
                if (!flags_arg_provided) {
                    HString* flags_key = builtin_intern_string(ctx.heap, "flags");
                    TVal? fl_opt = builtins_generic_get(obj, flags_key, ctx);
                    if (ctx.should_throw) return;
                    if (try fv = fl_opt) {
                        // If Get(pattern, "flags") is undefined, treat as empty string
                        // (RegExpInitialize step 3: if flags is undefined, use "").
                        if (!fv.is_undefined() && !fv.is_null()) {
                            if (fv.is_string() && fv.get_heapptr() != null) {
                                HString* fl_hs = (HString*)fv.get_heapptr();
                                flags_str = fl_hs.get_cstr();
                                flags_len = fl_hs.blen;
                            } else {
                                HString* fl_hs = builtin_to_string_vm(ctx, &fv);
                                if (ctx.should_throw) return;
                                if (fl_hs != null) {
                                    flags_str = fl_hs.get_cstr();
                                    flags_len = fl_hs.blen;
                                }
                            }
                        }
                        // undefined/null flags → flags_str stays "" (empty).
                    }
                }
                // Skip the ToString fallthrough and flags-from-arg below.
            } else {
                // Not a regexp-like object: convert to string for pattern — use vm variant to propagate JS throws.
                if (ctx.vm != null) {
                    HString* phs = builtin_to_string_vm(ctx, &pattern_arg);
                    if (ctx.should_throw) return;
                    if (phs != null) {
                        pattern_str = phs.get_cstr();
                        pattern_len = phs.blen;
                    }
                } else {
                    HString* phs = builtin_to_string(ctx.heap, &pattern_arg);
                    if (phs != null) {
                        pattern_str = phs.get_cstr();
                        pattern_len = phs.blen;
                    }
                }
            }
        } else if (pattern_arg.is_string() && pattern_arg.get_heapptr() != null) {
            HString* phs = (HString*)pattern_arg.get_heapptr();
            pattern_str = phs.get_cstr();
            pattern_len = phs.blen;
        } else if (!pattern_arg.is_undefined()) {
            // ES5 §15.10.4.1: if pattern is undefined, use empty string.
            // Only convert to string when pattern is not undefined.
            HString* phs;
            if (ctx.vm != null) {
                phs = builtin_to_string_vm(ctx, &pattern_arg);
            } else {
                phs = builtin_to_string(ctx.heap, &pattern_arg);
            }
            if (phs != null) {
                pattern_str = phs.get_cstr();
                pattern_len = phs.blen;
            }
        }
        // else: pattern_arg is undefined → use empty pattern (pattern_str = "", pattern_len = 0)
    }

    // Get flags from second argument
    if (ctx.argc > 1) {
        TVal* flags_arg = &ctx.regs[ctx.base_reg + 1];
        if (flags_arg.is_string() && flags_arg.get_heapptr() != null) {
            HString* fhs = (HString*)flags_arg.get_heapptr();
            flags_str = fhs.get_cstr();
            flags_len = fhs.blen;
        } else if (!flags_arg.is_undefined()) {
            HString* fhs;
            if (ctx.vm != null) {
                fhs = builtin_to_string_vm(ctx, flags_arg);
            } else {
                fhs = builtin_to_string(ctx.heap, flags_arg);
            }
            if (fhs != null) {
                flags_str = fhs.get_cstr();
                flags_len = fhs.blen;
            }
        }
    }

    // ES2015 §21.2.3.1 step 4.b: If patternIsRegExp is true and flags is undefined,
    // check SameValue(pattern.constructor, RegExp) and return pattern if true.
    if (is_regexp && flags_len == 0) {
        // Use pattern_regexp (set for actual RegExp) or the original arg (for regexp-like)
        HObject* ctor_check_obj = pattern_regexp;
        if (ctor_check_obj == null && pattern_arg.is_object() && pattern_arg.get_heapptr() != null) {
            ctor_check_obj = (HObject*)pattern_arg.get_heapptr();
        }
        if (ctor_check_obj != null) {
            // Check if the pattern's constructor is the RegExp constructor itself
            HString* ctor_key = builtin_intern_string(ctx.heap, "constructor");
            TVal? ctor_opt = builtins_generic_get(ctor_check_obj, ctor_key, ctx);
            if (ctx.should_throw) return;
            if (try cv = ctor_opt) {
                if (cv.is_object() && cv.get_heapptr() != null) {
                    HObject* ctor_obj = (HObject*)cv.get_heapptr();
                    // Check if ctor_obj is the global RegExp constructor (has builtin_fn_index == Builtin.REGEXP.ordinal)
                    if (ctor_obj.get_class() == hobject::ObjClass.FUNCTION &&
                        (*ctor_obj.extra_ptr()).func.builtin_fn_index == (int)Builtin.REGEXP.ordinal) {
                        // SameValue: same constructor → return the original pattern object
                        *ctx.result = pattern_arg;
                        return;
                    }
                }
            }
        }
        // Constructor mismatch — fall through to create a new RegExp with pattern's source/flags
        // Extract pattern source and flags from the original regexp (if actual RegExp object)
        if (pattern_regexp != null) {
            js_flags = (*pattern_regexp.extra_ptr()).regexp.flags;
            flags_len = 0;  // Clear flags so we don't re-parse
        }
    }

    // Convert JS flags to libregexp flag bits and store JS flags
    // ES2022 §21.2.3.2.2 step 5: if F contains the same code unit more than once, throw SyntaxError.
    int seen_flags = 0;
    for (usz i = 0; i < flags_len; i++) {
        char f = flags_str[i];
        int flag_bit = 0;
        if (f == 'g') {
            flag_bit = 1;
        } else if (f == 'i') {
            flag_bit = 2;
        } else if (f == 'm') {
            flag_bit = 4;
        } else if (f == 's') {
            flag_bit = 8;
        } else if (f == 'u') {
            flag_bit = 16;
        } else if (f == 'y') {
            flag_bit = 32;
        } else if (f == 'd') {
            flag_bit = 64;
        } else if (f == 'v') {
            flag_bit = 128;
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
        // Check for duplicate flag
        if ((seen_flags & flag_bit) != 0) {
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
        seen_flags |= flag_bit;
        js_flags |= flag_bit;
        if (f == 'i') {
            flags |= re_bindings::RE_FLAG_IGNORECASE;
        } else if (f == 'm') {
            flags |= re_bindings::RE_FLAG_MULTILINE;
        } else if (f == 's') {
            flags |= re_bindings::RE_FLAG_DOTALL;
        } else if (f == 'u') {
            flags |= re_bindings::RE_FLAG_UNICODE;
        } else if (f == 'y') {
            flags |= re_bindings::RE_FLAG_STICKY;
        } else if (f == 'd') {
            flags |= re_bindings::RE_FLAG_INDICES;
        } else if (f == 'v') {
            flags |= re_bindings::RE_FLAG_UNICODE_SETS;
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
    obj.prototype = builtin_proto_from_new_target(ctx, ctx.heap.regexp_proto);
    (*obj.extra_ptr()).regexp.regexp_data = compiled;
    (*obj.extra_ptr()).regexp.flags = js_flags;

    // Store pattern string as primitive_value
    HString* pattern_hs = builtin_intern_string(ctx.heap, pattern_str[:pattern_len]);
    (*obj.extra_ptr()).prim.primitive_value.set_string(pattern_hs);

    // Set RegExp.prototype.lastIndex (ES5 §15.10.7.5) — writable, non-enumerable,
    // non-configurable own data property.
    HString* lastindex_key = builtin_intern_string(ctx.heap, "lastIndex");
    TVal lastindex_tv;
    lastindex_tv.set_fastint(0);
    obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WENC);

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

    // Get input string — ES5 §15.10.6.3 step 3: ToString(string).
    // If no argument, ToString(undefined) = "undefined".
    char* input = "undefined";
    int input_len = 9;  // "undefined".length
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (!arg.is_undefined()) {
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
    }

    // Get the global and sticky flags
    // Read directly from internal flags: 1=g, 2=i, 4=m, 8=s, 16=u, 32=y
    int jsf_test = (*obj.extra_ptr()).regexp.flags;
    bool global_flag = (jsf_test & 1) != 0;
    bool sticky_flag = (jsf_test & 32) != 0;

    // ES2022 §22.2.5.2.2 RegExpBuiltinExec steps 4-8:
    // Step 4: Let lastIndex be ToLength(Get(R, "lastIndex")).
    // ToLength always runs (so valueOf on an object lastIndex is called).
    // Step 8: If global and sticky are both false, let lastIndex be 0.
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    int start_pos = 0;
    if (global_flag || sticky_flag) {
        if (try liv = obj.get_prop_proto(li_key)) {
            double li_d = builtin_to_integer_vm(ctx, &liv);
            if (ctx.should_throw) return;
            // ToLength: clamp to [0, 2^53-1]
            if (li_d < 0.0) li_d = 0.0;
            double max53 = 9007199254740991.0;
            if (li_d > max53) li_d = max53;
            // If ToLength(lastIndex) > length, reset to 0 and return false.
            if (li_d > (double)input_len) {
                TVal zero_tv;
                zero_tv.set_fastint(0);
                obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
                ctx.result.set_boolean(false);
                return;
            }
            start_pos = (int)li_d;
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

    if (result != re_bindings::RE_MATCH) {
        // Step 9: no match — reset lastIndex to 0 if global or sticky.
        if (global_flag || sticky_flag) {
            TVal zero_tv;
            zero_tv.set_fastint(0);
            if (!regexp_set_prop(ctx, obj, li_key, &zero_tv)) return;
        }
        ctx.result.set_boolean(false);
        return;
    }

    // Step 10: if global OR sticky, update lastIndex to end of match (= e).
    if (global_flag || sticky_flag) {
        long new_li = (long)hstring::compute_charlen(input[:out_end]);
        TVal end_tv;
        end_tv.set_fastint(new_li);
        obj.put_prop(li_key, end_tv, hobject::PROP_FLAGS_WEC);
    }

    ctx.result.set_boolean(true);
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

    // index property — convert byte offset to character (UTF-16 code unit) index
    long char_index = (long)hstring::compute_charlen(input[:out_start]);
    TVal idx_tv; idx_tv.set_fastint(char_index);
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

            // indices[0] — convert byte offsets to character (UTF-16 code unit) indices
            HObject*? pair0_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try pair0 = pair0_raw) {
                pair0.prototype = ctx.heap.array_proto;
                TVal p0s; p0s.set_fastint((long)hstring::compute_charlen(input[:out_start]));
                TVal p0e; p0e.set_fastint((long)hstring::compute_charlen(input[:out_end]));
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
                    TVal ps; ps.set_fastint((long)hstring::compute_charlen(input[:caps_start[i]]));
                    TVal pe; pe.set_fastint((long)hstring::compute_charlen(input[:caps_end[i]]));
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
                                    TVal ps; ps.set_fastint((long)hstring::compute_charlen(input[:caps_start[gi]]));
                                    TVal pe; pe.set_fastint((long)hstring::compute_charlen(input[:caps_end[gi]]));
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

    // ES5 §15.10.6.2 step 2: Let S be ? ToString(string).
    // If no argument, ToString(undefined) = "undefined".
    char* input = "undefined";
    int input_len = 9;  // "undefined".length
    HString* input_hstr = null;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.is_undefined()) {
            // Already defaults to "undefined"
        } else {
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
    }

    // Get the global and sticky flags (ES2015 §21.2.5.2 steps 4-5)
    // Read directly from internal flags: 1=g, 2=i, 4=m, 8=s, 16=u, 32=y
    int jsf = (*obj.extra_ptr()).regexp.flags;
    bool global_flag = (jsf & 1) != 0;
    bool sticky_flag = (jsf & 32) != 0;

    // ES §22.2.5.2.2 RegExpBuiltinExec steps 4-8:
    // Step 4: Let lastIndex be ? ToLength(? Get(R, "lastIndex")).
    //   ToLength always runs (so valueOf on an object lastIndex is called).
    // Step 8: If global and sticky are both false, let lastIndex be 0.
    //   (The property is NOT modified in this case.)
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    int start_pos = 0;
    {
        TVal? li_opt = builtins_generic_get(obj, li_key, ctx);
        if (ctx.should_throw) return;
        // Always ToLength-coerce (calls valueOf) — spec step 4.
        TVal li_raw; li_raw.set_fastint(0);
        if (try lv = li_opt) { li_raw = lv; }
        double li_d = builtin_to_integer_vm(ctx, &li_raw);
        if (ctx.should_throw) return;
        if (li_d < 0.0) li_d = 0.0;
        if (global_flag || sticky_flag) {
            // lastIndex is a UTF-16 code unit count; convert to CESU-8 byte
            // offset for re_exec (which takes byte offsets). Spec step 7:
            // if lastIndex > length (char-unit length), reset and return null.
            long li_charunit = (long)li_d;
            uint str_charlen = input_hstr != null ? input_hstr.char_length() : 0;
            if (li_charunit < 0 || (ulong)li_charunit > (ulong)str_charlen) {
                TVal zero_tv; zero_tv.set_fastint(0);
                if (!regexp_set_prop(ctx, obj, li_key, &zero_tv)) return;
                ctx.result.set_null();
                return;
            }
            // Convert char-unit index → byte offset.
            if (input_hstr != null) {
                start_pos = (int)input_hstr.char_offset_to_byte_offset((uint)li_charunit);
            }
        }
        // For non-global, non-sticky: start_pos stays 0; don't modify lastIndex.
    }

    // Execute with capture arrays
    int out_start = 0;
    int out_end = 0;
    int out_num_captures = 0;
    int[re_bindings::RE_MAX_CAPTURES] caps_start;
    int[re_bindings::RE_MAX_CAPTURES] caps_end;
    mem::clear(&caps_start, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));
    mem::clear(&caps_end, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));

    int result = re_bindings::re_exec(
        (*obj.extra_ptr()).regexp.regexp_data, input, input_len, start_pos,
        &out_start, &out_end, &out_num_captures,
        &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
    );

    if (result != re_bindings::RE_MATCH) {
        // Step 9: no match — reset lastIndex to 0 if global or sticky.
        // For sticky, Set throws if lastIndex is non-writable (step 9.c.i.1).
        if (global_flag || sticky_flag) {
            TVal zero_tv; zero_tv.set_fastint(0);
            if (!regexp_set_prop(ctx, obj, li_key, &zero_tv)) return;
        }
        ctx.result.set_null();
        return;
    }

    // Step 10: if global OR sticky, update lastIndex to end of match (= e).
    // lastIndex is a UTF-16 code unit index; we store strings as CESU-8,
    // so convert byte offset → code unit count.
    // Per spec (ES2022 §22.2.7.2.2 step 16), we set lastIndex = e without
    // any AdvanceStringIndex here; callers (@@match step 8.g, @@replace step
    // 11.d) handle the empty-match advance so that custom exec overrides work.
    if (global_flag || sticky_flag) {
        long new_li = (long)hstring::compute_charlen(input[:out_end]);
        TVal end_tv; end_tv.set_fastint(new_li);
        if (!regexp_set_prop(ctx, obj, li_key, &end_tv)) return;
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
        // ES2022 §21.2.3.13 step 2: If Type(R) is not Object, throw TypeError.
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "RegExp.prototype.toString called on incompatible receiver");
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
        if (c == '/') {
            buf[pos++] = '\\';
            buf[pos++] = '/';
        } else if (c == '\n') {
            buf[pos++] = '\\';
            buf[pos++] = 'n';
        } else if (c == '\r') {
            buf[pos++] = '\\';
            buf[pos++] = 'r';
        } else if (c == '\u2028') {
            if (pos + 6 > 1020) break;
            buf[pos++] = '\\'; buf[pos++] = 'u';
            buf[pos++] = '2'; buf[pos++] = '0';
            buf[pos++] = '2'; buf[pos++] = '8';
        } else if (c == '\u2029') {
            if (pos + 6 > 1020) break;
            buf[pos++] = '\\'; buf[pos++] = 'u';
            buf[pos++] = '2'; buf[pos++] = '0';
            buf[pos++] = '2'; buf[pos++] = '9';
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
    if (s_tv.is_string() && s_tv.get_heapptr() != null
        && !((HString*)s_tv.get_heapptr()).is_symbol()) {
        s_hstr = (HString*)s_tv.get_heapptr();
    } else {
        s_hstr = builtin_to_string_vm(ctx, &s_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) s_hstr = builtin_intern_string(ctx.heap, "undefined");
    }

    // 4. Let flags be ? ToString(? Get(rx, "flags")).
    // 5. Parse "g" and "u"/"v" from flags (spec steps 5-6).
    // Reading "flags" once avoids triggering "global"/"unicode" getters (which tests poison).
    HString* flags_key_m = builtin_intern_string(ctx.heap, "flags");
    TVal? flags_opt_m = builtins_generic_get(rx, flags_key_m, ctx);
    if (ctx.should_throw) return;
    TVal flags_tv_m; flags_tv_m.set_undefined();
    if (try fvm = flags_opt_m) { flags_tv_m = fvm; }
    HString* flags_hstr_m = builtin_to_string_vm(ctx, &flags_tv_m);
    if (ctx.should_throw) return;
    if (flags_hstr_m == null) { flags_hstr_m = builtin_intern_string(ctx.heap, ""); }
    bool global_flag = false;
    bool full_unicode = false;
    {
        char* fc = flags_hstr_m.get_cstr();
        usz flen = flags_hstr_m.blen;
        for (usz i = 0; i < flen; i++) {
            if (fc[i] == 'g') global_flag = true;
            if (fc[i] == 'u' || fc[i] == 'v') full_unicode = true;
        }
    }

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
    // 8.a. Perform ? Set(rx, "lastIndex", 0, true) — throws TypeError if non-writable.
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    TVal zero_tv; zero_tv.set_fastint(0);
    if (!regexp_set_with_setter(ctx, rx, li_key, zero_tv)) return;

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
        // thisIndex is a UTF-16 code unit count; convert to byte offset to
        // call advance_string_index_byte_len, then back to code units.
        if (match_str.blen == 0) {
            // 8.g.i. Let thisIndex be ? ToLength(? Get(rx, "lastIndex")).
            TVal? li_opt = builtins_generic_get(rx, li_key, ctx);
            if (ctx.should_throw) return;
            TVal li_raw; li_raw.set_fastint(0);
            if (try lv = li_opt) { li_raw = lv; }
            double this_d = builtin_to_integer_vm(ctx, &li_raw);
            if (ctx.should_throw) return;
            if (this_d < 0.0) this_d = 0.0;
            long this_index = (long)this_d;
            char* input = s_hstr.get_cstr();
            int input_len = (int)s_hstr.blen;
            // Convert char-unit index → byte offset, compute the byte advance,
            // then convert the resulting byte offset back to char-unit count.
            uint byte_off = s_hstr.char_offset_to_byte_offset((uint)this_index);
            int adv_bytes = (int)hstring::advance_string_index_byte_len(
                input[:input_len], byte_off, full_unicode);
            uint new_byte_off = byte_off + (uint)adv_bytes;
            long next_index = (long)hstring::compute_charlen(input[:new_byte_off]);
            TVal next_tv; next_tv.set_fastint(next_index);
            // 8.g.iii. Perform ? Set(rx, "lastIndex", nextIndex, true).
            if (!regexp_set_with_setter(ctx, rx, li_key, next_tv)) return;
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
    if (s_tv.is_string() && s_tv.get_heapptr() != null
        && !((HString*)s_tv.get_heapptr()).is_symbol()) {
        s_hstr = (HString*)s_tv.get_heapptr();
    } else {
        s_hstr = builtin_to_string_vm(ctx, &s_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) s_hstr = builtin_intern_string(ctx.heap, "undefined");
    }

    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");

    // 4. Let previousLastIndex be ? Get(rx, "lastIndex").
    TVal? prev_opt = builtins_generic_get(rx, li_key, ctx);
    if (ctx.should_throw) return;
    TVal previous_last_index; previous_last_index.set_undefined();
    if (try p = prev_opt) { previous_last_index = p; }

    // 5. If SameValue(previousLastIndex, 0) is false, Set(rx, "lastIndex", 0, true).
    TVal zero_tv; zero_tv.set_fastint(0);
    if (!same_value(previous_last_index, zero_tv)) {
        if (!regexp_set_with_setter(ctx, rx, li_key, zero_tv)) return;
    }

    // 6. Let result be ? RegExpExec(rx, S).
    TVal s_hstr_tv; s_hstr_tv.set_string(s_hstr);
    if (!regexp_exec_call(ctx, rx, &s_hstr_tv)) return;
    TVal result = *ctx.result;

    // 7. Let currentLastIndex be ? Get(rx, "lastIndex").
    TVal? cur_opt = builtins_generic_get(rx, li_key, ctx);
    if (ctx.should_throw) return;
    TVal current_last_index; current_last_index.set_undefined();
    if (try c = cur_opt) { current_last_index = c; }

    // 8. If SameValue(currentLastIndex, previousLastIndex) is false, restore it.
    if (!same_value(current_last_index, previous_last_index)) {
        if (!regexp_set_with_setter(ctx, rx, li_key, previous_last_index)) return;
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
// RegExp.prototype[@@replace] — ES2022 §22.2.5.8
// ============================================================================

/// GetSubstitution (ES2022 Table 58) using already-ToString'd captures and a
/// TVal namedCaptures (already ToObject'd when not undefined). Returns the
/// substituted string, or null on abrupt completion (ctx.should_throw set).
fn HString* rr_get_substitution(
    BuiltinContext* ctx,
    HString* matched_hs,     // ToString(result[0])
    char* str, int str_len,  // full input string
    int position,            // byte offset of match start
    int match_end,           // byte offset of match end
    HString** captures,      // null=undefined capture at each index
    int num_caps,
    TVal named_captures_tv,  // groups value (object or any type after ToObject)
    bool have_named_captures,// true when groups !== undefined
    HString* replace_hs      // replacement template
) {
    char* rep = replace_hs.get_cstr();
    uint rep_len = replace_hs.blen;
    char[8192] buf;
    usz offset = 0;

    usz i = 0;
    while (i < (usz)rep_len && offset < 8192) {
        char c = rep[i];
        if (c != '$' || i + 1 >= (usz)rep_len) {
            buf[offset++] = c;
            i++;
            continue;
        }
        char next = rep[i + 1];
        if (next == '$') {
            buf[offset++] = '$';
            i += 2;
            continue;
        }
        if (next == '&') {
            char* mp = matched_hs.get_cstr();
            uint mlen = matched_hs.blen;
            for (uint j = 0; j < mlen && offset < 8192; j++) buf[offset++] = mp[j];
            i += 2;
            continue;
        }
        if (next == '`') {
            for (int j = 0; j < position && offset < 8192; j++) buf[offset++] = str[j];
            i += 2;
            continue;
        }
        if (next == '\'') {
            for (int j = match_end; j < str_len && offset < 8192; j++) buf[offset++] = str[j];
            i += 2;
            continue;
        }
        if (next >= '0' && next <= '9') {
            // Try 2-digit index first; fall back to 1-digit.
            int idx1 = next - '0';
            bool use2 = false;
            int idx2 = -1;
            if (i + 2 < (usz)rep_len && rep[i + 2] >= '0' && rep[i + 2] <= '9') {
                idx2 = idx1 * 10 + (rep[i + 2] - '0');
                if (idx2 >= 1 && idx2 <= num_caps) use2 = true;
            }
            int idx = use2 ? idx2 : idx1;
            int consumed = use2 ? 2 : 1;
            if (idx >= 1 && idx <= num_caps) {
                HString* cap = captures[idx - 1];
                if (cap != null) {
                    char* cp = cap.get_cstr();
                    uint cl = cap.blen;
                    for (uint j = 0; j < cl && offset < 8192; j++) buf[offset++] = cp[j];
                }
                i += 1 + (usz)consumed;
                continue;
            }
            // Out of range → emit '$' literally; re-process next char.
            buf[offset++] = '$';
            i++;
            continue;
        }
        if (next == '<') {
            if (!have_named_captures) {
                buf[offset++] = '$';
                buf[offset++] = '<';
                i += 2;
                continue;
            }
            usz name_start = i + 2;
            usz name_end = name_start;
            while (name_end < (usz)rep_len && rep[name_end] != '>') name_end++;
            if (name_end >= (usz)rep_len) {
                // No closing '>' → emit "$<" literally.
                buf[offset++] = '$';
                buf[offset++] = '<';
                i += 2;
                continue;
            }
            usz gname_len = name_end - name_start;
            if (gname_len == 0) {
                // $<> empty group name → empty substitution.
                i = name_end + 1;
                continue;
            }
            HString* gname_hs = builtin_intern_string(ctx.heap, rep[name_start : gname_len]);
            // Get(namedCaptures, groupName).
            if (named_captures_tv.is_object() && named_captures_tv.get_heapptr() != null) {
                HObject* nc_obj = (HObject*)named_captures_tv.get_heapptr();
                TVal? cap_opt = builtins_generic_get(nc_obj, gname_hs, ctx);
                if (ctx.should_throw) return null;
                if (try cap_tv = cap_opt) {
                    if (!cap_tv.is_undefined()) {
                        HString* cs = builtin_to_string_vm(ctx, &cap_tv);
                        if (ctx.should_throw) return null;
                        if (cs != null) {
                            char* cp = cs.get_cstr();
                            uint cl = cs.blen;
                            for (uint j = 0; j < cl && offset < 8192; j++) buf[offset++] = cp[j];
                        }
                    }
                    // undefined capture → empty substitution
                }
            }
            i = name_end + 1;
            continue;
        }
        // Unknown $ sequence → emit '$' literally.
        buf[offset++] = '$';
        i++;
    }
    return builtin_intern_string(ctx.heap, buf[:offset]);
}

/// RegExp.prototype[@@replace] — ES2022 §22.2.5.8
fn void builtin_regexp_proto_symbol_replace(BuiltinContext* ctx) {
    // Step 1-2: rx must be Object.
    HObject* rx = regexp_get_symbol_this(ctx);
    if (rx == null) return;

    Heap* heap = ctx.heap;

    // Step 3: S = ? ToString(string).
    HString* s_hstr;
    if (ctx.argc > 0) {
        if (ctx.regs[ctx.base_reg].is_string()) {
            s_hstr = (HString*)ctx.regs[ctx.base_reg].get_heapptr();
        } else {
            s_hstr = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
            if (ctx.should_throw) return;
        }
    } else {
        s_hstr = builtin_intern_string(heap, "undefined");
    }
    if (s_hstr == null) { ctx.result.set_string(builtin_intern_string(heap, "")); return; }

    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    // Step 5: functionalReplace = IsCallable(replaceValue).
    TVal replace_val;
    replace_val.set_undefined();
    bool replace_is_fn = false;
    if (ctx.argc > 1) {
        replace_val = ctx.regs[ctx.base_reg + 1];
        replace_is_fn = replace_val.is_lightfunc() ||
            (replace_val.is_object() && replace_val.get_heapptr() != null &&
             ((HObject*)replace_val.get_heapptr()).is_callable());
    }

    // Step 6: if not functional → replaceValue = ? ToString(replaceValue).
    HString* replace_str_hstr = null;
    if (!replace_is_fn) {
        if (ctx.argc > 1) {
            replace_str_hstr = builtin_to_string_vm(ctx, &replace_val);
        } else {
            replace_str_hstr = builtin_intern_string(heap, "undefined");
        }
        if (ctx.should_throw) return;
        if (replace_str_hstr == null) replace_str_hstr = builtin_intern_string(heap, "undefined");
    }

    // Step 8: flags = ? ToString(? Get(rx, "flags")).
    HString* flags_key = builtin_intern_string(heap, "flags");
    TVal? flags_opt = builtins_generic_get(rx, flags_key, ctx);
    if (ctx.should_throw) return;
    TVal flags_tv; flags_tv.set_undefined();
    if (try fv = flags_opt) { flags_tv = fv; }
    HString* flags_hstr = builtin_to_string_vm(ctx, &flags_tv);
    if (ctx.should_throw) return;
    if (flags_hstr == null) flags_hstr = builtin_intern_string(heap, "");

    // Parse flags for global, sticky, fullUnicode.
    bool global_flag = false;
    bool rr_full_unicode = false;
    {
        char* fp = flags_hstr.get_cstr();
        uint flen = flags_hstr.blen;
        for (uint fi = 0; fi < flen; fi++) {
            char fc = fp[fi];
            if (fc == 'g') global_flag = true;
            if (fc == 'u' || fc == 'v') rr_full_unicode = true;
        }
    }

    HString* li_key = builtin_intern_string(heap, "lastIndex");

    // Step 11: if global → Set(rx, "lastIndex", 0, true) — throws if non-writable.
    if (global_flag) {
        TVal zero_tv; zero_tv.set_fastint(0);
        if (!regexp_set_prop(ctx, rx, li_key, &zero_tv)) return;
    }

    // Collect all results first, then process (per spec two-pass structure).
    TVal[4096] results_buf;
    int results_count = 0;
    bool done = false;

    while (!done) {
        TVal s_tv2; s_tv2.set_string(s_hstr);
        if (!regexp_exec_call(ctx, rx, &s_tv2)) return;
        TVal match_result = *ctx.result;
        if (match_result.is_null()) {
            done = true;
        } else {
            if (results_count < 4096) {
                results_buf[results_count++] = match_result;
            }
            if (!global_flag) {
                done = true;
            } else {
                if (!match_result.is_object() || match_result.get_heapptr() == null) {
                    done = true;
                } else {
                    HObject* mr = (HObject*)match_result.get_heapptr();
                    HString* zero_key2 = builtin_intern_string(heap, "0");
                    TVal? ms_opt2 = builtins_generic_get(mr, zero_key2, ctx);
                    if (ctx.should_throw) return;
                    TVal ms_raw2; ms_raw2.set_undefined();
                    if (try msv = ms_opt2) { ms_raw2 = msv; }
                    HString* ms_hstr2 = builtin_to_string_vm(ctx, &ms_raw2);
                    if (ctx.should_throw) return;
                    if (ms_hstr2 == null) ms_hstr2 = builtin_intern_string(heap, "undefined");
                    if (ms_hstr2.blen == 0) {
                        // Empty match: AdvanceStringIndex(S, ToLength(lastIndex), fullUnicode).
                        TVal? li_opt2 = builtins_generic_get(rx, li_key, ctx);
                        if (ctx.should_throw) return;
                        TVal li_raw2; li_raw2.set_fastint(0);
                        if (try lv2 = li_opt2) { li_raw2 = lv2; }
                        // ToLength coercion (calls valueOf on objects).
                        double li_d2 = builtin_to_integer_vm(ctx, &li_raw2);
                        if (ctx.should_throw) return;
                        if (li_d2 < 0.0) li_d2 = 0.0;
                        double max53 = 9007199254740991.0;
                        if (li_d2 > max53) li_d2 = max53;
                        long this_li = (long)li_d2;
                        long next_li2;
                        long str_charlen2 = (long)s_hstr.char_length();
                        if (this_li >= str_charlen2) {
                            // AdvanceStringIndex: if thisIndex >= length, return thisIndex + 1.
                            next_li2 = this_li + 1;
                        } else {
                            uint byte_off2 = s_hstr.char_offset_to_byte_offset((uint)this_li);
                            int adv2 = (int)hstring::advance_string_index_byte_len(
                                input[:input_len], byte_off2, rr_full_unicode);
                            long new_byte2 = (long)byte_off2 + adv2;
                            next_li2 = (long)hstring::compute_charlen(input[:(usz)new_byte2]);
                        }
                        TVal next_li_tv2;
                        if (next_li2 >= types::FASTINT_MIN && next_li2 <= types::FASTINT_MAX) {
                            next_li_tv2.set_fastint(next_li2);
                        } else {
                            next_li_tv2.set_number((double)next_li2);
                        }
                        if (!regexp_set_prop(ctx, rx, li_key, &next_li_tv2)) return;
                    }
                }
            }
        }
    }

    // Process collected results to build the output string.
    char[8192] out_buf;
    usz out_off = 0;
    int last_end = 0;

    for (int ri = 0; ri < results_count; ri++) {
        TVal m_tv = results_buf[ri];
        if (!m_tv.is_object() || m_tv.get_heapptr() == null) continue;
        HObject* m = (HObject*)m_tv.get_heapptr();

        // Step 14.a: nCaptures = ToLength(Get(result,"length")) - 1.
        HString* len_key = builtin_intern_string(heap, "length");
        TVal? len_opt = builtins_generic_get(m, len_key, ctx);
        if (ctx.should_throw) return;
        TVal len_raw; len_raw.set_fastint(0);
        if (try lv = len_opt) { len_raw = lv; }
        double len_d = builtin_to_integer_vm(ctx, &len_raw);
        if (ctx.should_throw) return;
        if (len_d < 0.0) len_d = 0.0;
        double max53 = 9007199254740991.0;
        if (len_d > max53) len_d = max53;
        long num_caps_l = (long)len_d - 1;
        if (num_caps_l < 0) num_caps_l = 0;
        int num_caps = (int)num_caps_l;
        if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;

        // Step 14.b: matched = ? ToString(? Get(result, "0")).
        HString* zero_key = builtin_intern_string(heap, "0");
        TVal? z_opt = builtins_generic_get(m, zero_key, ctx);
        if (ctx.should_throw) return;
        TVal z_raw; z_raw.set_undefined();
        if (try zv = z_opt) { z_raw = zv; }
        HString* matched_hstr = builtin_to_string_vm(ctx, &z_raw);
        if (ctx.should_throw) return;
        if (matched_hstr == null) matched_hstr = builtin_intern_string(heap, "undefined");

        // Step 14.e: position = ? ToInteger(? Get(result, "index")), clamped
        // [0,|S|] — |S| is the UTF-16 code-unit length, since "index" is a
        // code-unit index. Convert to a CESU-8 byte offset before using it
        // to slice `input` (which is the raw CESU-8 byte buffer).
        HString* idx_key = builtin_intern_string(heap, "index");
        TVal? idx_opt = builtins_generic_get(m, idx_key, ctx);
        if (ctx.should_throw) return;
        TVal idx_raw; idx_raw.set_fastint(0);
        if (try iv = idx_opt) { idx_raw = iv; }
        double pos_d = builtin_to_integer_vm(ctx, &idx_raw);
        if (ctx.should_throw) return;
        if (pos_d < 0.0) pos_d = 0.0;
        double str_charlen_d = (double)s_hstr.char_length();
        if (pos_d > str_charlen_d) pos_d = str_charlen_d;
        int out_start = (int)s_hstr.char_offset_to_byte_offset((uint)pos_d);
        int out_end = out_start + (int)matched_hstr.blen;
        if (out_end > input_len) out_end = input_len;

        // Step 14.f: coerce each capture to HString* (null = undefined).
        HString*[re_bindings::RE_MAX_CAPTURES] cap_strs;
        for (int ci = 0; ci < num_caps; ci++) {
            HString* cap_key_hs = heap.int_to_hstring((long)(ci + 1));
            TVal? cap_opt = builtins_generic_get(m, cap_key_hs, ctx);
            if (ctx.should_throw) return;
            TVal cap_tv; cap_tv.set_undefined();
            if (try cv = cap_opt) { cap_tv = cv; }
            if (cap_tv.is_undefined()) {
                cap_strs[ci] = null;
            } else {
                HString* cs = builtin_to_string_vm(ctx, &cap_tv);
                if (ctx.should_throw) return;
                cap_strs[ci] = cs != null ? cs : builtin_intern_string(heap, "undefined");
            }
        }

        // Step 14.j: namedCaptures = ? Get(result, "groups").
        HString* groups_key = builtin_intern_string(heap, "groups");
        TVal? groups_opt = builtins_generic_get(m, groups_key, ctx);
        if (ctx.should_throw) return;
        TVal named_captures_tv; named_captures_tv.set_undefined();
        if (try gv = groups_opt) { named_captures_tv = gv; }
        bool have_named_captures = !named_captures_tv.is_undefined();

        if (replace_is_fn) {
            // Step 14.k: functional replace.
            // replacerArgs = [matched, cap1..capN, position, S, ?namedCaptures]
            TVal[38] fn_args;
            int arg_count = 0;
            TVal matched_tv; matched_tv.set_string(matched_hstr);
            fn_args[arg_count++] = matched_tv;
            for (int ci = 0; ci < num_caps && arg_count < 35; ci++) {
                if (cap_strs[ci] != null) {
                    TVal cap_tv; cap_tv.set_string(cap_strs[ci]);
                    fn_args[arg_count++] = cap_tv;
                } else {
                    TVal cap_undef; cap_undef.set_undefined();
                    fn_args[arg_count++] = cap_undef;
                }
            }
            // position argument is the UTF-16 code-unit index (pos_d), not
            // the CESU-8 byte offset (out_start) used for slicing `input`.
            TVal pos_tv; pos_tv.set_fastint((long)pos_d);
            fn_args[arg_count++] = pos_tv;
            TVal str_tv; str_tv.set_string(s_hstr);
            fn_args[arg_count++] = str_tv;
            // Append namedCaptures only if not undefined (step 14.k.iv).
            if (have_named_captures && arg_count < 38) {
                fn_args[arg_count++] = named_captures_tv;
            }
            TVal undef_this; undef_this.set_undefined();
            TVal res = heap.call_fn(ctx.vm, replace_val, &fn_args[0], (uint)arg_count, undef_this);
            if (heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = heap.error_value;
                heap.has_error = false;
                return;
            }
            HString* rep_hs = builtin_to_string_vm(ctx, &res);
            if (ctx.should_throw) return;
            if (rep_hs == null) rep_hs = builtin_intern_string(heap, "undefined");

            if (out_start >= last_end) {
                for (int j = last_end; j < out_start && out_off < 8192; j++) out_buf[out_off++] = input[j];
                char* rp = rep_hs.get_cstr();
                uint rl = rep_hs.blen;
                for (uint j = 0; j < rl && out_off < 8192; j++) out_buf[out_off++] = rp[j];
                last_end = out_end > input_len ? input_len : out_end;
            }
        } else {
            // Step 14.l: string GetSubstitution.
            // If namedCaptures is not undefined, ToObject(namedCaptures).
            if (have_named_captures) {
                if (named_captures_tv.is_null()) {
                    builtin_throw_no_result_change(ctx, heap.type_err_proto,
                        "Cannot convert null namedCaptures to object");
                    return;
                }
                if (!named_captures_tv.is_object()) {
                    // Box primitive as wrapper object for property lookup.
                    if (named_captures_tv.is_string() && named_captures_tv.get_heapptr() != null) {
                        HObject*? box_raw = heap.alloc_object(hobject::ObjClass.STRING);
                        if (try box = box_raw) {
                            box.prototype = heap.string_proto;
                            (*box.extra_ptr()).prim.primitive_value = named_captures_tv;
                            // Set own .length (non-writable, non-enum, non-configurable)
                            HString* str_len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                            TVal str_len_tv;
                            HString* s_hs = (HString*)named_captures_tv.get_heapptr();
                            str_len_tv.set_fastint((long)s_hs.char_length());
                            box.put_prop(str_len_key, str_len_tv, hobject::PROP_FLAGS_NNC);
                            named_captures_tv.set_object(box);
                        }
                    } else if (named_captures_tv.is_fastint() || named_captures_tv.is_number()) {
                        HObject*? box_raw = heap.alloc_object(hobject::ObjClass.NUMBER);
                        if (try box = box_raw) {
                            box.prototype = heap.number_proto;
                            (*box.extra_ptr()).prim.primitive_value = named_captures_tv;
                            named_captures_tv.set_object(box);
                        }
                    } else if (named_captures_tv.is_boolean()) {
                        HObject*? box_raw = heap.alloc_object(hobject::ObjClass.BOOLEAN);
                        if (try box = box_raw) {
                            box.prototype = heap.bool_proto;
                            (*box.extra_ptr()).prim.primitive_value = named_captures_tv;
                            named_captures_tv.set_object(box);
                        }
                    }
                }
            }

            HString* rep_hs = rr_get_substitution(
                ctx,
                matched_hstr,
                input, input_len, out_start, out_end,
                &cap_strs[0], num_caps,
                named_captures_tv, have_named_captures,
                replace_str_hstr
            );
            if (ctx.should_throw) return;
            if (rep_hs == null) rep_hs = builtin_intern_string(heap, "");

            if (out_start >= last_end) {
                for (int j = last_end; j < out_start && out_off < 8192; j++) out_buf[out_off++] = input[j];
                char* rp = rep_hs.get_cstr();
                uint rl = rep_hs.blen;
                for (uint j = 0; j < rl && out_off < 8192; j++) out_buf[out_off++] = rp[j];
                last_end = out_end > input_len ? input_len : out_end;
            }
        }
    }

    // Append tail [last_end, input_len).
    for (int j = last_end; j < input_len && out_off < 8192; j++) out_buf[out_off++] = input[j];
    ctx.result.set_string(builtin_intern_string(heap, out_buf[:out_off]));
}

// ============================================================================
// RegExp.prototype[@@split] — ES2022 §21.2.5.11
// ============================================================================
fn void builtin_regexp_proto_symbol_split(BuiltinContext* ctx) {
    HObject* rx = regexp_get_symbol_this(ctx);
    if (rx == null) return;

    Heap* heap = ctx.heap;
    HString* li_key   = builtin_intern_string(heap, "lastIndex");
    HString* len_key  = builtin_intern_string(heap, "length");

    // Step 3: Let S be ? ToString(string).
    TVal s_tv; s_tv.set_undefined();
    if (ctx.argc > 0) { s_tv = ctx.regs[ctx.base_reg]; }
    HString* s_hstr;
    if (s_tv.is_string() && s_tv.get_heapptr() != null
        && !((HString*)s_tv.get_heapptr()).is_symbol()) {
        HString* tmp_hs = (HString*)s_tv.get_heapptr();
        // Symbols cannot be converted to string — throw TypeError.
        if (tmp_hs.is_symbol()) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto,
                "Cannot convert Symbol to string");
            return;
        }
        s_hstr = tmp_hs;
    } else {
        s_hstr = builtin_to_string_vm(ctx, &s_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) { s_hstr = builtin_intern_string(heap, "undefined"); }
    }

    // Step 4: Let C be ? SpeciesConstructor(rx, %RegExp%).
    // SpeciesConstructor(O, defaultConstructor):
    //   1. C = Get(O, "constructor"); if undefined → return defaultConstructor.
    //   2. If C is not an object → throw TypeError.
    //   3. species = Get(C, @@species); if null/undefined → return defaultConstructor.
    //   4. If species is not a constructor → throw TypeError.
    //   5. Return species.
    // We always track the resolved constructor in species_ctor_tv.
    // For the default path (%RegExp%), look it up from global_env.
    TVal species_ctor_tv; species_ctor_tv.set_undefined();
    {
        // Resolve %RegExp% default constructor.
        // The constructor object is stored on RegExp.prototype as its "constructor"
        // property — this is available directly via heap.regexp_proto.
        TVal default_ctor_tv; default_ctor_tv.set_undefined();
        // Look up %RegExp% from the global environment via the VM's global_env.
        // ctx.global_env is null when the builtin is called via call_fn (internal
        // path), but ctx.vm always holds the Vm* pointer when available.
        EnvRecord* genv = ctx.global_env;
        if (genv == null && ctx.vm != null) {
            genv = ((vm::Vm*)ctx.vm).global_env;
        }
        if (genv != null) {
            HString* regexp_gkey = builtin_intern_string(heap, "RegExp");
            if (regexp_gkey != null) {
                TVal? gv = env::env_get(genv, regexp_gkey);
                if (try rgv = gv) { default_ctor_tv = rgv; }
            }
        }

        HString* ctor_key = builtin_intern_string(heap, "constructor");
        TVal? ctor_opt = builtins_generic_get(rx, ctor_key, ctx);
        if (ctx.should_throw) return;
        TVal ctor_tv; ctor_tv.set_undefined();
        if (try cv = ctor_opt) { ctor_tv = cv; }

        if (ctor_tv.is_undefined()) {
            // Step 4: C is undefined → return defaultConstructor (%RegExp%).
            species_ctor_tv = default_ctor_tv;
        } else {
            if (!ctor_tv.is_object() || ctor_tv.get_heapptr() == null) {
                builtin_throw_no_result_change(ctx, heap.type_err_proto,
                    "constructor is not an object");
                return;
            }
            HObject* ctor_obj = (HObject*)ctor_tv.get_heapptr();
            HString* species_sym = ensure_species_symbol(heap);
            if (species_sym != null) {
                TVal? sp_opt = builtins_generic_get(ctor_obj, species_sym, ctx);
                if (ctx.should_throw) return;
                if (try spv = sp_opt) {
                    if (!spv.is_undefined() && !spv.is_null()) {
                        // Step 5: species is the constructor to use.
                        species_ctor_tv = spv;
                    } else {
                        // species is null/undefined → return defaultConstructor.
                        species_ctor_tv = default_ctor_tv;
                    }
                } else {
                    // @@species not found → return defaultConstructor.
                    species_ctor_tv = default_ctor_tv;
                }
            } else {
                species_ctor_tv = default_ctor_tv;
            }
        }
    }

    // Step 7: Let flags be ? ToString(? Get(rx, "flags")).
    HString* flags_key = builtin_intern_string(heap, "flags");
    TVal? flags_opt = builtins_generic_get(rx, flags_key, ctx);
    if (ctx.should_throw) return;
    TVal flags_tv; flags_tv.set_undefined();
    if (try fv = flags_opt) { flags_tv = fv; }
    HString* flags_str = builtin_to_string_vm(ctx, &flags_tv);
    if (ctx.should_throw) return;
    if (flags_str == null) { flags_str = builtin_intern_string(heap, ""); }

    // Step 8: newFlags = flags; if 'y' not in flags, append 'y'.
    bool has_y = false;
    bool has_u = false;
    char* fp = flags_str.get_cstr();
    uint flen = flags_str.blen;
    for (uint i = 0; i < flen; i++) {
        if (fp[i] == 'y') { has_y = true; }
        if (fp[i] == 'u') { has_u = true; }
    }
    HString* new_flags_str;
    if (has_y) {
        new_flags_str = flags_str;
    } else {
        // Append 'y'.
        char[64] nf_buf;
        uint nf_len = 0;
        for (uint i = 0; i < flen && nf_len < 63; i++) { nf_buf[nf_len++] = fp[i]; }
        if (nf_len < 63) { nf_buf[nf_len++] = 'y'; }
        new_flags_str = builtin_intern_string(heap, nf_buf[:nf_len]);
    }

    // Step 9: Let splitter be ? Construct(C, «rx, newFlags»).
    // If species_ctor_tv is callable and construct_fn is available, use it.
    // Otherwise, fall through to use rx itself as the splitter (built-in path).
    HObject* splitter = null;
    bool have_external_splitter = false;
    if (!species_ctor_tv.is_undefined() && heap.construct_fn != null && ctx.vm != null) {
        TVal rx_tv; rx_tv.set_object(rx);
        TVal new_flags_tv; new_flags_tv.set_string(new_flags_str);
        TVal[2] ctor_args;
        ctor_args[0] = rx_tv;
        ctor_args[1] = new_flags_tv;
        TVal splitter_tv = heap.construct_fn(ctx.vm, species_ctor_tv, &ctor_args[0], 2, species_ctor_tv);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            return;
        }
        if (splitter_tv.is_object() && splitter_tv.get_heapptr() != null) {
            splitter = (HObject*)splitter_tv.get_heapptr();
            have_external_splitter = true;
        } else {
            builtin_throw_no_result_change(ctx, heap.type_err_proto,
                "species constructor did not return an object");
            return;
        }
    }

    // If no external splitter, use rx itself as splitter (built-in fast path).
    if (splitter == null) { splitter = rx; }

    // Step 16: ToLength(limit), or 2^53-1 when undefined.
    // ES2015 spec uses 2^32-1 for @@split limit but later revisions differ;
    // we use 2^32-1 here for compatibility with test262 expectations.
    // NOTE: spec step 17 now says ToLength, not ToUint32 — tests coerce-limit-err
    // require Symbol to throw TypeError. We call builtin_to_integer_vm which
    // propagates Symbol-as-number TypeError.
    ulong limit = 0xFFFFFFFF;  // 2^32-1 default
    if (ctx.argc > 1 && !ctx.regs[ctx.base_reg + 1].is_undefined()) {
        TVal limit_arg = ctx.regs[ctx.base_reg + 1];
        // Symbol as limit must throw TypeError.
        if (limit_arg.is_string() && limit_arg.get_heapptr() != null &&
            ((HString*)limit_arg.get_heapptr()).is_symbol()) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto,
                "Cannot convert Symbol to number");
            return;
        }
        double limit_d = builtin_to_integer_vm(ctx, &limit_arg);
        if (ctx.should_throw) return;
        // ToUint32: wrap modulo 2^32 (handles negatives: -23 → 4294967273).
        // NaN and ±Infinity become 0 per spec (ToUint32 of non-finite is 0).
        if (math::is_nan(limit_d) || !math::is_finite(limit_d)) {
            limit = 0;
        } else {
            double two32 = 4294967296.0;
            double n = limit_d - math::floor(limit_d / two32) * two32;
            limit = (ulong)(uint)n;
        }
    }

    // Create result array.
    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_null(); return; }
    HObject* arr = arr_raw;
    arr.prototype = heap.array_proto;

    if (limit == 0) {
        ctx.result.set_object(arr);
        return;
    }

    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;

    // Step 22: if size = 0, handle empty string case.
    if (input_len == 0) {
        TVal s_tv2; s_tv2.set_string(s_hstr);
        if (!regexp_exec_call(ctx, splitter, &s_tv2)) return;
        TVal z = *ctx.result;
        if (z.is_null()) {
            // No match on empty string — return [S].
            TVal elem; elem.set_string(s_hstr);
            arr.put_prop(heap.int_to_hstring(0), elem, hobject::PROP_FLAGS_WEC);
            TVal lv; lv.set_fastint(1);
            arr.put_prop(len_key, lv, hobject::PROP_FLAGS_WEC);
        }
        // else: match — return [] (empty).
        ctx.result.set_object(arr);
        return;
    }

    ulong arr_idx = 0;
    int q = 0;  // current search position in bytes (CESU-8 byte offset)
    int p = 0;  // start of current substring in bytes

    // Main loop: ES §21.2.5.11 step 24.
    while (q < input_len) {
        // Step 24.a: Set(splitter, "lastIndex", q, true) — q as char-unit index.
        {
            long q_cu = (long)hstring::compute_charlen(input[:q]);
            TVal q_tv; q_tv.set_fastint(q_cu);
            if (!regexp_set_with_setter(ctx, splitter, li_key, q_tv)) return;
        }

        // Step 24.c: Let z be ? RegExpExec(splitter, S).
        TVal s_tv2; s_tv2.set_string(s_hstr);
        if (!regexp_exec_call(ctx, splitter, &s_tv2)) return;
        TVal z = *ctx.result;

        // Step 24.e: If z is null, let q be AdvanceStringIndex(S, q, unicodeMatching).
        if (z.is_null()) {
            int adv = (int)hstring::advance_string_index_byte_len(
                input[:input_len], (uint)q, has_u);
            q += adv;
            continue;
        }

        if (!z.is_object() || z.get_heapptr() == null) {
            // Treat as no match.
            int adv = (int)hstring::advance_string_index_byte_len(
                input[:input_len], (uint)q, has_u);
            q += adv;
            continue;
        }
        HObject* z_obj = (HObject*)z.get_heapptr();

        // Step 24.f.i: Let e be ? ToLength(? Get(splitter, "lastIndex")).
        TVal? li_opt = builtins_generic_get(splitter, li_key, ctx);
        if (ctx.should_throw) return;
        TVal li_raw; li_raw.set_fastint(0);
        if (try lv = li_opt) { li_raw = lv; }
        double e_d = builtin_to_integer_vm(ctx, &li_raw);
        if (ctx.should_throw) return;
        if (e_d < 0.0) { e_d = 0.0; }
        // Clamp e to size.
        if (e_d > (double)input_len) { e_d = (double)input_len; }
        // Convert char-unit index (from lastIndex) back to byte offset.
        // splitter.lastIndex is a char-unit count; convert to byte offset.
        int e_cu = (int)e_d;
        int e_byte;
        if (e_cu <= 0) {
            e_byte = 0;
        } else {
            // Walk s_hstr to find byte offset corresponding to e_cu char units.
            e_byte = (int)s_hstr.char_offset_to_byte_offset((uint)e_cu);
            if (e_byte > input_len) { e_byte = input_len; }
        }
        int e = e_byte;

        // Step 24.f.ii: If e == p, advance q (no forward progress).
        if (e == p) {
            int adv = (int)hstring::advance_string_index_byte_len(
                input[:input_len], (uint)q, has_u);
            q += adv;
            continue;
        }

        // Step 24.f.iv: e != p — we have a real match boundary.
        // Push substring [p, q) as the next result element.
        {
            int sub_len = q - p;
            HString* substr;
            if (sub_len <= 0) {
                substr = builtin_intern_string(heap, "");
            } else {
                substr = builtin_intern_string(heap, input[p : (usz)sub_len]);
            }
            TVal elem; elem.set_string(substr);
            arr.put_prop(heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC);
            arr_idx++;
            if (arr_idx >= limit) {
                TVal lv; lv.set_fastint((long)arr_idx);
                arr.put_prop(len_key, lv, hobject::PROP_FLAGS_WEC);
                ctx.result.set_object(arr);
                return;
            }
        }

        // Step 24.f.iv.7: numberOfCaptures = ToLength(Get(z, "length")) - 1.
        TVal? zlen_opt = builtins_generic_get(z_obj, len_key, ctx);
        if (ctx.should_throw) return;
        TVal zlen_raw; zlen_raw.set_fastint(0);
        if (try zlv = zlen_opt) { zlen_raw = zlv; }
        double zlen_d = builtin_to_integer_vm(ctx, &zlen_raw);
        if (ctx.should_throw) return;
        if (zlen_d < 0.0) { zlen_d = 0.0; }
        int num_caps = (int)zlen_d - 1;
        if (num_caps < 0) { num_caps = 0; }

        // Step 24.f.iv.11: For each capture group i in 1..numberOfCaptures.
        for (int i = 1; i <= num_caps; i++) {
            HString* cap_key = heap.int_to_hstring((long)i);
            TVal? cap_opt = builtins_generic_get(z_obj, cap_key, ctx);
            if (ctx.should_throw) return;
            TVal cap_tv; cap_tv.set_undefined();
            if (try cv = cap_opt) { cap_tv = cv; }
            // Captures are pushed as-is (undefined stays undefined).
            arr.put_prop(heap.int_to_hstring((long)arr_idx), cap_tv, hobject::PROP_FLAGS_WEC);
            arr_idx++;
            if (arr_idx >= limit) {
                TVal lv; lv.set_fastint((long)arr_idx);
                arr.put_prop(len_key, lv, hobject::PROP_FLAGS_WEC);
                ctx.result.set_object(arr);
                return;
            }
        }

        p = e;
        q = e;
    }

    // Tail: push [p, size) as the final element.
    if (arr_idx < limit) {
        int tail_len = input_len - p;
        HString* tail_str;
        if (tail_len <= 0) {
            tail_str = builtin_intern_string(heap, "");
        } else {
            tail_str = builtin_intern_string(heap, input[p : (usz)tail_len]);
        }
        TVal elem; elem.set_string(tail_str);
        arr.put_prop(heap.int_to_hstring((long)arr_idx), elem, hobject::PROP_FLAGS_WEC);
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

/// RegExp.prototype[@@matchAll] — ES2020 §21.2.5.8 (MatchAllIterator)
fn void builtin_regexp_proto_symbol_matchAll(BuiltinContext* ctx) {
    if (ctx.is_constructor) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
            "RegExp.prototype[Symbol.matchAll] is not a constructor");
        return;
    }
    // Step 1: Let R be the this value.
    // Step 2: If Type(R) is not Object, throw a TypeError.
    HObject* rx = regexp_get_symbol_this(ctx);
    if (rx == null) return;

    Heap* heap = ctx.heap;

    // Step 3: Return ? MatchAllIterator(R, string).
    // MatchAllIterator steps:
    // 1. Let S be ? ToString(O).
    TVal s_tv; s_tv.set_undefined();
    if (ctx.argc > 0) s_tv = ctx.regs[ctx.base_reg];
    HString* s_hstr;
    if (s_tv.is_string() && s_tv.get_heapptr() != null
        && !((HString*)s_tv.get_heapptr()).is_symbol()) {
        HString* tmp = (HString*)s_tv.get_heapptr();
        if (tmp.is_symbol()) {
            builtin_throw_no_result_change(ctx, heap.type_err_proto,
                "Cannot convert Symbol to string");
            return;
        }
        s_hstr = tmp;
    } else {
        s_hstr = builtin_to_string_vm(ctx, &s_tv);
        if (ctx.should_throw) return;
        if (s_hstr == null) s_hstr = builtin_intern_string(heap, "undefined");
    }
    s_tv.set_string(s_hstr);

    // 2. If ? IsRegExp(R) is true, and
    //    SameValue(? Get(R, "flags"), undefined) — actually:
    //    IsRegExp just checks @@match on R to determine if it "looks like" a regexp.
    //    The spec doesn't throw here; the Construct call below triggers IsRegExp on rx.

    // 3. Let C be ? SpeciesConstructor(R, %RegExp%).
    TVal species_ctor_tv; species_ctor_tv.set_undefined();
    {
        TVal default_ctor_tv; default_ctor_tv.set_undefined();
        EnvRecord* genv = ctx.global_env;
        if (genv == null && ctx.vm != null) {
            genv = ((vm::Vm*)ctx.vm).global_env;
        }
        if (genv != null) {
            HString* regexp_gkey = builtin_intern_string(heap, "RegExp");
            if (regexp_gkey != null) {
                TVal? gv = env::env_get(genv, regexp_gkey);
                if (try rgv = gv) { default_ctor_tv = rgv; }
            }
        }

        HString* ctor_key = builtin_intern_string(heap, "constructor");
        TVal? ctor_opt = builtins_generic_get(rx, ctor_key, ctx);
        if (ctx.should_throw) return;
        TVal ctor_tv; ctor_tv.set_undefined();
        if (try cv = ctor_opt) { ctor_tv = cv; }

        if (ctor_tv.is_undefined()) {
            species_ctor_tv = default_ctor_tv;
        } else {
            if (!ctor_tv.is_object() || ctor_tv.get_heapptr() == null) {
                builtin_throw_no_result_change(ctx, heap.type_err_proto,
                    "constructor is not an object");
                return;
            }
            HObject* ctor_obj = (HObject*)ctor_tv.get_heapptr();
            HString* species_sym = ensure_species_symbol(heap);
            if (species_sym != null) {
                TVal? sp_opt = builtins_generic_get(ctor_obj, species_sym, ctx);
                if (ctx.should_throw) return;
                if (try spv = sp_opt) {
                    if (!spv.is_undefined() && !spv.is_null()) {
                        species_ctor_tv = spv;
                    } else {
                        species_ctor_tv = default_ctor_tv;
                    }
                } else {
                    species_ctor_tv = default_ctor_tv;
                }
            } else {
                species_ctor_tv = default_ctor_tv;
            }
        }
    }

    // 4. Let flags be ? ToString(? Get(R, "flags")).
    HString* flags_key = builtin_intern_string(heap, "flags");
    TVal? flags_opt = builtins_generic_get(rx, flags_key, ctx);
    if (ctx.should_throw) return;
    HString* flags_str = builtin_intern_string(heap, "");
    if (try fv = flags_opt) {
        if (fv.is_string() && fv.get_heapptr() != null) {
            flags_str = (HString*)fv.get_heapptr();
        } else {
            HString* fs = builtin_to_string_vm(ctx, &fv);
            if (ctx.should_throw) return;
            if (fs != null) flags_str = fs;
        }
    }

    // 5. Let matcher be ? Construct(C, «R, flags»).
    // When C is undefined (SpeciesConstructor failed to resolve), use rx itself.
    HObject* matcher = null;
    if (!species_ctor_tv.is_undefined() && heap.construct_fn != null && ctx.vm != null) {
        TVal rx_tv; rx_tv.set_object(rx);
        TVal flags_tv; flags_tv.set_string(flags_str);
        TVal[2] ctor_args;
        ctor_args[0] = rx_tv;
        ctor_args[1] = flags_tv;
        TVal matcher_tv = heap.construct_fn(ctx.vm, species_ctor_tv, &ctor_args[0], 2, species_ctor_tv);
        if (heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
            heap.has_error = false;
            return;
        }
        if (matcher_tv.is_object() && matcher_tv.get_heapptr() != null) {
            matcher = (HObject*)matcher_tv.get_heapptr();
        } else {
            builtin_throw_no_result_change(ctx, heap.type_err_proto,
                "species constructor did not return an object");
            return;
        }
    }
    if (matcher == null) { matcher = rx; }

    // 6. Let lastIndex be ? ToLength(? Get(R, "lastIndex")).
    HString* li_key = builtin_intern_string(heap, "lastIndex");
    TVal li_raw; li_raw.set_fastint(0);
    {
        TVal? li_opt = builtins_generic_get(rx, li_key, ctx);
        if (ctx.should_throw) return;
        if (try lv = li_opt) { li_raw = lv; }
    }
    double li_d = builtin_to_integer_vm(ctx, &li_raw);
    if (ctx.should_throw) return;
    if (li_d < 0.0) li_d = 0.0;
    TVal li_tv; li_tv.set_fastint((long)li_d);

    // 7. Perform ? Set(matcher, "lastIndex", lastIndex, true).
    if (!regexp_set_with_setter(ctx, matcher, li_key, li_tv)) return;

    // 8. If flags contains "g", let global be true.
    bool global_flag = false;
    bool unicode_flag = false;
    {
        char* fp = flags_str.get_cstr();
        uint flen = flags_str.blen;
        for (uint i = 0; i < flen; i++) {
            if (fp[i] == 'g') global_flag = true;
            if (fp[i] == 'u' || fp[i] == 'v') unicode_flag = true;
        }
    }

    // 9. Return CreateRegExpStringIterator(matcher, S, global, unicode).
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.REGEXP_STRING_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_null(); return; }
    HObject* iter = iter_raw;
    (*iter.extra_ptr()).regexp_iter.string_val = s_tv;
    (*iter.extra_ptr()).regexp_iter.regexp = matcher;
    // flags bits: bit 0 = global, bit 1 = done, bit 2 = unicode
    uint iter_flags = 0;
    if (global_flag) iter_flags |= 1;
    if (unicode_flag) iter_flags |= 4;
    (*iter.extra_ptr()).regexp_iter.flags = iter_flags;
    iter.prototype = heap.iterator_proto;

    // Add .next method as an own property on the iterator object.
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.REGEXP_STRING_ITERATOR_NEXT.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop((void*)next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    ctx.result.set_object(iter);
}

/// Result of regexp_get_this_or_throw: the HObject and whether it's the prototype.
struct RegexpThisResult {
    HObject* obj;
    bool is_proto;
}

/// Helper: get regexp this or throw TypeError.
/// Returns obj with is_proto=false for normal RegExp objects, or (RegExp.prototype, true)
/// when `this` is the RegExp prototype itself (for spec-compliant "undefined" returns).
fn RegexpThisResult regexp_get_this_or_throw(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    RegexpThisResult err_result;
    err_result.obj = null;
    err_result.is_proto = false;
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Method get RegExp.prototype.flags called on incompatible receiver");
        return err_result;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.REGEXP) {
        // ES2022 §21.2.5.[flags]: if SameValue(R, %RegExpPrototype%) is true, return undefined.
        if (ctx.heap.regexp_proto != null && obj == ctx.heap.regexp_proto) {
            RegexpThisResult proto_result;
            proto_result.obj = obj;
            proto_result.is_proto = true;
            return proto_result;
        }
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Method get RegExp.prototype.flags called on incompatible receiver");
        return err_result;
    }
    RegexpThisResult ok_result;
    ok_result.obj = obj;
    ok_result.is_proto = false;
    return ok_result;
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

/// Set `rx.prop = val` with spec-compliant strict Set semantics:
/// Throws TypeError if the own property exists but is non-writable.
/// Returns true when the property was written successfully.
fn bool regexp_set_prop(BuiltinContext* ctx, HObject* rx, HString* key, TVal* val_ptr) {
    TVal val = *val_ptr;
    // Check writability of existing own property before writing.
    if (!rx.is_prop_writable((void*)key)) {
        // Own non-writable data property — Set throws TypeError per spec.
        builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto, "Cannot assign to read only property 'lastIndex'");
        return false;
    }
    rx.put_prop((void*)key, val, hobject::PROP_FLAGS_WEC);
    return true;
}

/// Spec-compliant Set(obj, key, val, true) that handles both data properties
/// and accessor setters. Invokes the setter via call_fn when one exists.
/// Propagates throws via ctx.should_throw. Returns false on throw.
fn bool regexp_set_with_setter(BuiltinContext* ctx, HObject* obj, HString* key, TVal val) {
    // Check for accessor setter first.
    AccessorResult acc = obj.find_accessor_proto((void*)key, false);  // false = want setter
    if (acc.found) {
        // Accessor property — invoke setter.
        if (acc.accessor_fn.is_undefined() || acc.accessor_fn.is_null()) {
            // No setter → strict TypeError.
            builtin_throw_no_result_change(ctx, ctx.heap.type_err_proto,
                "Cannot set property — no setter");
            return false;
        }
        if (ctx.heap.call_fn != null && ctx.vm != null) {
            TVal this_tv; this_tv.set_object(obj);
            ctx.heap.call_fn(ctx.vm, acc.accessor_fn, &val, 1, this_tv);
            if (ctx.heap.has_error) {
                ctx.should_throw = true;
                ctx.throw_value = ctx.heap.error_value;
                ctx.heap.has_error = false;
                return false;
            }
        }
        return true;
    }
    // Data property — use regexp_set_prop (checks writable, throws if not).
    return regexp_set_prop(ctx, obj, key, &val);
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
    {
        // Always ToLength(Get(R, "lastIndex")) — spec step 4 (triggers valueOf).
        TVal? li_opt = builtins_generic_get(rx, li_key, ctx);
        if (ctx.should_throw) return false;
        TVal li_raw; li_raw.set_fastint(0);
        if (try lv = li_opt) { li_raw = lv; }
        double li_d = builtin_to_integer_vm(ctx, &li_raw);
        if (ctx.should_throw) return false;
        if (li_d < 0.0) li_d = 0.0;
        if (global_flag || sticky_flag) {
            // lastIndex is a UTF-16 code unit count; convert to CESU-8 byte
            // offset for re_exec. Bounds-check against char-unit length.
            long li_charunit = (long)li_d;
            uint str_charlen = s_hstr.char_length();
            if (li_charunit < 0 || (ulong)li_charunit > (ulong)str_charlen) {
                TVal zero_tv; zero_tv.set_fastint(0);
                if (!regexp_set_prop(ctx, rx, li_key, &zero_tv)) return false;
                ctx.result.set_null();
                return true;
            }
            start_pos = (int)s_hstr.char_offset_to_byte_offset((uint)li_charunit);
        }
        // For non-global/non-sticky: start_pos stays 0; don't modify lastIndex.
    }

    int out_start = 0;
    int out_end = 0;
    int out_num_captures = 0;
    int[re_bindings::RE_MAX_CAPTURES] caps_start;
    int[re_bindings::RE_MAX_CAPTURES] caps_end;
    mem::clear(&caps_start, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));
    mem::clear(&caps_end, (sz)(re_bindings::RE_MAX_CAPTURES * int::size));

    int result = re_bindings::re_exec(
        re_data, input, input_len, start_pos,
        &out_start, &out_end, &out_num_captures,
        &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
    );
    if (result != re_bindings::RE_MATCH) {
        if (global_flag || sticky_flag) {
            TVal zero_tv; zero_tv.set_fastint(0);
            if (!regexp_set_prop(ctx, rx, li_key, &zero_tv)) return false;
        }
        ctx.result.set_null();
        return true;
    }

    if (global_flag || sticky_flag) {
        // ES2017 §21.2.5.2.2 step 16: lastIndex = e (end of match) as a
        // UTF-16 code unit index. For empty matches (e == matchStart) the
        // AdvanceStringIndex step is performed by the *caller* (@@match step
        // 8.g, @@replace step 11.d) so that custom exec overrides are also
        // covered. Do NOT advance here — set lastIndex = charlen(input[:e]).
        long new_li = (long)hstring::compute_charlen(input[:out_end]);
        TVal end_tv; end_tv.set_fastint(new_li);
        if (!regexp_set_prop(ctx, rx, li_key, &end_tv)) return false;
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
    // ES2022 §21.2.3.2.4 step 2: if srcLength = 0, return "(?:)".
    if (slen == 0) {
        if (dmax >= 4) {
            dst[0] = '(';
            dst[1] = '?';
            dst[2] = ':';
            dst[3] = ')';
        }
        dst[4] = 0;
        return 4;
    }
    usz di = 0;
    for (usz si = 0; si < slen && di + 1 < dmax; si++) {
        char c = src[si];
        if (c == '/') {
            if (di + 2 > dmax) break;
            dst[di++] = '\\';
            dst[di++] = '/';
        } else if (c == '\n') {
            // ES2022 §21.2.3.2.4: LF → \n (backslash + letter n)
            if (di + 2 > dmax) break;
            dst[di++] = '\\';
            dst[di++] = 'n';
        } else if (c == '\r') {
            // ES2022 §21.2.3.2.4: CR → \r (backslash + letter r)
            if (di + 2 > dmax) break;
            dst[di++] = '\\';
            dst[di++] = 'r';
        } else if (c == '\u2028') {
            // LS → \u2028
            if (di + 6 > dmax) break;
            dst[di++] = '\\'; dst[di++] = 'u';
            dst[di++] = '2'; dst[di++] = '0';
            dst[di++] = '2'; dst[di++] = '8';
        } else if (c == '\u2029') {
            // PS → \u2029
            if (di + 6 > dmax) break;
            dst[di++] = '\\'; dst[di++] = 'u';
            dst[di++] = '2'; dst[di++] = '0';
            dst[di++] = '2'; dst[di++] = '9';
        } else {
            dst[di++] = c;
        }
    }
    dst[di] = 0;
    return di;
}

/// RegExp.prototype.source — ES6 §21.2.5.10
fn void builtin_regexp_proto_get_source(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    // ES2022 §21.2.5.10 step 3: if SameValue(R, %RegExpPrototype%), return "(?:)".
    if (this_r.is_proto) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "(?:)"));
        return;
    }
    HObject* obj = this_r.obj;
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
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result.set_undefined(); return; }
    ctx.result.set_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 1) != 0);
}

/// RegExp.prototype.ignoreCase — ES6 §21.2.5.3
fn void builtin_regexp_proto_get_ignoreCase(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result.set_undefined(); return; }
    ctx.result.set_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 2) != 0);
}

/// RegExp.prototype.multiline — ES6 §21.2.5.5
fn void builtin_regexp_proto_get_multiline(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result.set_undefined(); return; }
    ctx.result.set_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 4) != 0);
}

/// RegExp.prototype.dotAll — ES2018 §21.2.5.2
fn void builtin_regexp_proto_get_dotAll(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result.set_undefined(); return; }
    ctx.result.set_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 8) != 0);
}

/// RegExp.prototype.sticky — ES6 §21.2.5.14
fn void builtin_regexp_proto_get_sticky(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result.set_undefined(); return; }
    ctx.result.set_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 32) != 0);
}

/// RegExp.prototype.unicode — ES6 §21.2.5.16
fn void builtin_regexp_proto_get_unicode(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result.set_undefined(); return; }
    ctx.result.set_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 16) != 0);
}

/// RegExp.prototype.hasIndices — ES2022 §21.2.5.8
fn void builtin_regexp_proto_get_hasIndices(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result.set_undefined(); return; }
    ctx.result.set_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 64) != 0);
}

/// RegExp.prototype.unicodeSets — ES2024 §21.2.5.17
fn void builtin_regexp_proto_get_unicodeSets(BuiltinContext* ctx) {
    RegexpThisResult this_r = regexp_get_this_or_throw(ctx);
    if (this_r.obj == null) return;
    if (this_r.is_proto) { ctx.result.set_undefined(); return; }
    ctx.result.set_boolean(((*this_r.obj.extra_ptr()).regexp.flags & 128) != 0);
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

/// RegExp[@@species] getter — ES2022 §21.2.4.2
/// Returns the this value (the constructor itself).
fn void builtin_regexp_species_getter(BuiltinContext* ctx) {
    *ctx.result = ctx.regs[ctx.base_reg - 1];
}

/// Register RegExp.prototype and the RegExp constructor globally.
fn bool register_regexp_constructor(EnvRecord* global_env, Heap* heap) {
    // Create RegExp.prototype (ObjClass.OBJECT per spec — toString gives [object Object])
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype
    heap.regexp_proto = proto;

    // Add RegExp.prototype.test()
    if (!register_string_proto_method(proto, heap, "test", Builtin.REGEXP_PROTO_TEST.ordinal)) return false;

    // Add RegExp.prototype.exec()
    if (!register_string_proto_method(proto, heap, "exec", Builtin.REGEXP_PROTO_EXEC.ordinal)) return false;

    // Add RegExp.prototype.toString()
    if (!register_string_proto_method(proto, heap, "toString", Builtin.REGEXP_PROTO_TOSTRING.ordinal)) return false;

    // Add RegExp.prototype accessor getters (ES6 §21.2.5)
    if (!register_proto_accessor(proto, heap, "flags", Builtin.REGEXP_PROTO_GET_FLAGS.ordinal)) return false;
    if (!register_proto_accessor(proto, heap, "source", Builtin.REGEXP_PROTO_GET_SOURCE.ordinal)) return false;
    if (!register_proto_accessor(proto, heap, "global", Builtin.REGEXP_PROTO_GET_GLOBAL.ordinal)) return false;
    if (!register_proto_accessor(proto, heap, "ignoreCase", Builtin.REGEXP_PROTO_GET_IGNORECASE.ordinal)) return false;
    if (!register_proto_accessor(proto, heap, "multiline", Builtin.REGEXP_PROTO_GET_MULTILINE.ordinal)) return false;
    if (!register_proto_accessor(proto, heap, "dotAll", Builtin.REGEXP_PROTO_GET_DOTALL.ordinal)) return false;
    if (!register_proto_accessor(proto, heap, "sticky", Builtin.REGEXP_PROTO_GET_STICKY.ordinal)) return false;
    if (!register_proto_accessor(proto, heap, "unicode", Builtin.REGEXP_PROTO_GET_UNICODE.ordinal)) return false;
    if (!register_proto_accessor(proto, heap, "hasIndices", Builtin.REGEXP_PROTO_GET_HASINDICES.ordinal)) return false;
    if (!register_proto_accessor(proto, heap, "unicodeSets", Builtin.REGEXP_PROTO_GET_UNICODESETS.ordinal)) return false;

    // Register RegExp.prototype[@@match] (ES6 §21.2.5.6)
    {
        HString* match_sym = ensure_match_symbol(heap);
        if (match_sym != null) {
            TVal match_fn;
            match_fn.set_lightfunc((void*)(usz)Builtin.REGEXP_PROTO_SYMBOL_MATCH.ordinal);
            proto.put_prop(match_sym, match_fn, hobject::PROP_FLAGS_WC);
        }
    }

    // Register RegExp.prototype[@@search] (ES6 §21.2.5.9)
    {
        HString* search_sym = ensure_search_symbol(heap);
        if (search_sym != null) {
            TVal search_fn;
            search_fn.set_lightfunc((void*)(usz)Builtin.REGEXP_PROTO_SYMBOL_SEARCH.ordinal);
            proto.put_prop(search_sym, search_fn, hobject::PROP_FLAGS_WC);
        }
    }

    // Register RegExp.prototype[@@replace] (ES6 §21.2.5.8)
    {
        HString* replace_sym = ensure_replace_symbol(heap);
        if (replace_sym != null) {
            TVal replace_fn;
            replace_fn.set_lightfunc((void*)(usz)Builtin.REGEXP_PROTO_SYMBOL_REPLACE.ordinal);
            proto.put_prop(replace_sym, replace_fn, hobject::PROP_FLAGS_WC);
        }
    }

    // Register RegExp.prototype[@@split] (ES6 §21.2.5.11)
    {
        HString* split_sym = ensure_split_symbol(heap);
        if (split_sym != null) {
            TVal split_fn;
            split_fn.set_lightfunc((void*)(usz)Builtin.REGEXP_PROTO_SYMBOL_SPLIT.ordinal);
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
            matchall_fn.set_lightfunc((void*)(usz)Builtin.REGEXP_PROTO_SYMBOL_MATCHALL.ordinal);
            proto.put_prop(matchall_sym, matchall_fn, hobject::PROP_FLAGS_WC);
        }
    }

    // Register RegExp as a global constructor (proper function object)
    HObject*? regexp_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = regexp_raw) return false;
    HObject* regexp_obj = regexp_raw;
    (*regexp_obj.extra_ptr()).func.builtin_fn_index = (int)Builtin.REGEXP.ordinal;

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

    // Add @@species accessor (ES2022 §21.2.4.2): getter returns `this`.
    HString* species_sym = ensure_species_symbol(heap);
    if (species_sym != null) {
        HObject*? getter_fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try getter_fn = getter_fn_raw) {
            (*getter_fn.extra_ptr()).func.builtin_fn_index = (int)Builtin.REGEXP_SPECIES_GETTER.ordinal;
            getter_fn.flags.callable = true;
            getter_fn.prototype = heap.function_proto;
            // Set .name = "get [Symbol.species]"
            HString* getter_name = builtin_intern_string(heap, "get [Symbol.species]");
            if (getter_name != null) {
                TVal name_tv; name_tv.set_string(getter_name);
                getter_fn.put_prop((void*)builtin_intern_string(heap, "name"), name_tv, hobject::PROP_FLAGS_NWC);
            }
            // Set .length = 0
            TVal zero_tv; zero_tv.set_fastint(0);
            getter_fn.put_prop(len_key, zero_tv, hobject::PROP_FLAGS_NWC);

            TVal getter_tv; getter_tv.set_object(getter_fn);
            TVal undef; undef.set_undefined();
            hobject::PropFlags acc_flags;
            acc_flags.writable = false;
            acc_flags.enumerable = false;
            acc_flags.configurable = true;
            acc_flags.is_accessor = true;
            regexp_obj.put_prop(species_sym, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags);
        }
    }

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
