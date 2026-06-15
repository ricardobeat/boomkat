/// RegExp constructor and RegExp.prototype methods.
module tinyduck::builtins;
import tinyduck::types;
import libc;
import tinyduck::hstring;
import tinyduck::env;

import tinyduck::heap;
import tinyduck::hobject;
import tinyduck::re_bindings;

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
            js_flags |= 16;
        } else if (f == 'y') {
            js_flags |= 32;
        } else {
            // Invalid flag per ES5 §15.10.4.1 — throw SyntaxError
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            HString* msg_str = builtin_intern_string(ctx.heap, "RegExp.prototype.test called on incompatible receiver");
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

    // Get input string
    char* input = "";
    int input_len = 0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        HString* hs;
        if (arg.is_string()) {
            hs = (HString*)arg.get_heapptr();
        } else {
            hs = builtin_to_string(ctx.heap, arg);
        }
        if (hs != null) {
            input = hs.get_cstr();
            input_len = (int)hs.blen;
        }
    }

    // Get the global flag
    HString* global_key = builtin_intern_string(ctx.heap, "global");
    bool global_flag = false;
    if (try gv = obj.get_prop(global_key)) {
        if (gv.is_boolean()) global_flag = gv.get_boolean();
    }

    // Get lastIndex (if global)
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    int start_pos = 0;
    if (global_flag) {
        if (try liv = obj.get_prop(li_key)) {
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

    // Update lastIndex if global
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

/// RegExp.prototype.exec(string) — ES5 §15.10.6.2
fn void builtin_regexp_proto_exec(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this(ctx);
    if (obj == null || (*obj.extra_ptr()).regexp.regexp_data == null) {
        // ES5 §15.10.6.2 step 2: throw TypeError if this is not a RegExp
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            HString* msg_str = builtin_intern_string(ctx.heap, "RegExp.prototype.exec called on incompatible receiver");
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

    // Get input string
    char* input = "";
    int input_len = 0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        HString* hs;
        if (arg.is_string()) {
            hs = (HString*)arg.get_heapptr();
        } else {
            hs = builtin_to_string(ctx.heap, arg);
        }
        if (hs != null) {
            input = hs.get_cstr();
            input_len = (int)hs.blen;
        }
    }

    // Get the global flag (ES5 §15.10.6.2 step 6)
    HString* global_key = builtin_intern_string(ctx.heap, "global");
    bool global_flag = false;
    if (try gv = obj.get_prop(global_key)) {
        if (gv.is_boolean()) global_flag = gv.get_boolean();
    }

    // Get lastIndex (steps 4-5)
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    int start_pos = 0;
    if (global_flag) {
        if (try liv = obj.get_prop(li_key)) {
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
        // Step 9: no match — reset lastIndex to 0 if global
        if (global_flag) {
            TVal zero_tv;
            zero_tv.set_fastint(0);
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.set_null();
        return;
    }

    // Step 10: if global, update lastIndex to end of match
    if (global_flag) {
        TVal end_tv;
        end_tv.set_fastint((long)out_end);
        obj.put_prop(li_key, end_tv, hobject::PROP_FLAGS_WEC);
    }

    // Create result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_null();
        return;
    }
    HObject* arr = arr_raw;

    // Element 0: full match string
    usz match_len = (usz)(out_end - out_start);
    char[1024] buf;
    usz copy_len = match_len < 1024 ? match_len : 1024;
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = input[(usz)out_start + i];
    }
    HString* match_str = builtin_intern_string(ctx.heap, buf[:copy_len]);
    TVal elem;
    elem.set_string(match_str);
    HString* zero_key = builtin_intern_string(ctx.heap, "0");
    arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

    // Elements 1..n: capture groups
    int num_caps = out_num_captures;
    if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
    for (int i = 0; i < num_caps; i++) {
        if (caps_start[i] >= 0 && caps_end[i] >= 0) {
            usz cap_len = (usz)(caps_end[i] - caps_start[i]);
            usz cap_copy = cap_len < 1024 ? cap_len : 1024;
            char[1024] cap_buf;
            for (usz j = 0; j < cap_copy; j++) {
                cap_buf[j] = input[(usz)caps_start[i] + j];
            }
            HString* cap_str = builtin_intern_string(ctx.heap, cap_buf[:cap_copy]);
            TVal cap_elem;
            cap_elem.set_string(cap_str);
            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%d", i + 1);
            HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
            arr.put_prop(idx_key, cap_elem, hobject::PROP_FLAGS_WEC);
        } else {
            // Unmatched capture group -> undefined
            HString* empty_key = builtin_intern_string(ctx.heap, "undefined");
            TVal undef;
            undef.set_undefined();
            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%d", i + 1);
            HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
            arr.put_prop(idx_key, undef, hobject::PROP_FLAGS_WEC);
        }
    }

    // Set index property
    HString* index_key = builtin_intern_string(ctx.heap, "index");
    TVal index_val;
    index_val.set_fastint((long)out_start);
    arr.put_prop(index_key, index_val, hobject::PROP_FLAGS_WEC);

    // Set input property
    HString* input_key = builtin_intern_string(ctx.heap, "input");
    TVal input_val;
    input_val.set_string(builtin_intern_string(ctx.heap, input[:input_len]));
    arr.put_prop(input_key, input_val, hobject::PROP_FLAGS_WEC);

    // Set length
    uint total_elements = 1 + (uint)num_caps;
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_val;
    len_val.set_fastint((long)total_elements);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(arr);
}

/// RegExp.prototype.toString() — ES5 §15.10.6.4
fn void builtin_regexp_proto_toString(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this(ctx);
    if (obj == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }

    // Build "/pattern/flags" string from stored flags
    char* pattern = "";
    usz plen = 0;
    if ((*obj.extra_ptr()).prim.primitive_value.is_string() && (*obj.extra_ptr()).prim.primitive_value.get_heapptr() != null) {
        HString* phs = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        pattern = phs.get_cstr();
        plen = phs.blen;
    }

    int jsf = (*obj.extra_ptr()).regexp.flags;
    char[512] buf;
    int pos = 0;
    buf[pos++] = '/';
    for (usz i = 0; i < plen && pos < 510; i++) {
        buf[pos++] = pattern[i];
    }
    buf[pos++] = '/';
    if ((jsf & 1) != 0 && pos < 511) buf[pos++] = 'g';
    if ((jsf & 2) != 0 && pos < 511) buf[pos++] = 'i';
    if ((jsf & 4) != 0 && pos < 511) buf[pos++] = 'm';
    if ((jsf & 8) != 0 && pos < 511) buf[pos++] = 's';
    if ((jsf & 16) != 0 && pos < 511) buf[pos++] = 'u';
    if ((jsf & 32) != 0 && pos < 511) buf[pos++] = 'y';
    buf[pos] = 0;

    HString* result = builtin_intern_string(ctx.heap, buf[:pos]);
    ctx.result.set_string(result);
}

// ============================================================================
// RegExp.prototype accessor getters (ES6 §21.2.5)
// These are getter functions registered on RegExp.prototype via accessor properties.
// js_flags encoding: 1=g, 2=i, 4=m, 8=s(dotAll), 16=u(unicode), 32=y(sticky)
// ============================================================================

/// Helper: get regexp this or throw TypeError
fn HObject* regexp_get_this_or_throw(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (!this_val.is_object() || this_val.get_heapptr() == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            HString* msg_str = builtin_intern_string(ctx.heap, "Method get RegExp.prototype.flags called on incompatible receiver");
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return null;
    }
    HObject* obj = (HObject*)this_val.get_heapptr();
    if (obj.get_class() != hobject::ObjClass.REGEXP) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            HString* msg_str = builtin_intern_string(ctx.heap, "Method get RegExp.prototype.flags called on incompatible receiver");
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return null;
    }
    return obj;
}

/// RegExp.prototype.flags — ES6 §21.2.5.7
/// Returns a string of flags in alphabetical order: "dgimsuy"
fn void builtin_regexp_proto_get_flags(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    int jsf = (*obj.extra_ptr()).regexp.flags;
    char[8] buf;
    int pos = 0;
    if ((jsf & 1) != 0)  buf[pos++] = 'g';   // global
    if ((jsf & 8) != 0)  buf[pos++] = 'd';   // dotAll
    if ((jsf & 2) != 0)  buf[pos++] = 'i';   // ignoreCase
    if ((jsf & 4) != 0)  buf[pos++] = 'm';   // multiline
    if ((jsf & 16) != 0) buf[pos++] = 'u';   // unicode
    if ((jsf & 32) != 0) buf[pos++] = 'y';   // sticky
    HString* result = builtin_intern_string(ctx.heap, buf[:pos]);
    ctx.result.set_string(result);
}

/// RegExp.prototype.source — ES6 §21.2.5.10
fn void builtin_regexp_proto_get_source(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this_or_throw(ctx);
    if (obj == null) return;
    if ((*obj.extra_ptr()).prim.primitive_value.is_string() && (*obj.extra_ptr()).prim.primitive_value.get_heapptr() != null) {
        HString* phs = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        ctx.result.set_string(phs);
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

fn bool register_proto_accessor(HObject* proto, Heap* heap, char[] name, uint getter_index) {
    HString* key = builtin_intern_string(heap, name);
    if (key == null) return false;

    // Create getter function object (builtin)
    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)getter_index;
    func_obj.flags.callable = true;

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
    proto.put_prop(key, undef, acc_flags);
    int idx = proto.find_prop_idx(key);
    if (idx >= 0) {
        proto.prop_values()[idx].data.getter = getter_tv;
        proto.prop_values()[idx].setter = undef;
    }
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
