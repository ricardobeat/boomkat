/// Global built-in functions: print, parseInt, parseFloat, isNaN, isFinite, eval, URI encoding/decoding.
module duktape::builtins;
import duktape::types;
import duktape::bytecode;
import std::io;
import std::math;
import libc;
import duktape::lexer;
import duktape::compiler;
import duktape::hstring;
import duktape::hobject;

import duktape::heap;
import duktape::env;
import duktape::vm;

/// Print a single TVal using proper JS ToString coercion.
/// For objects, looks up and calls the object's toString() method via call_fn
/// so that Array.prototype.toString (join with commas), Date.prototype.toString,
/// and user-defined toString() all work correctly.
fn void print_tval_ctx(BuiltinContext* ctx, TVal* val) {
    if (val.is_object() && val.get_heapptr() != null && ctx.vm != null && ctx.heap.call_fn != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        // Look up toString on the object (searches prototype chain)
        HString* tostr_key = builtin_intern_string(ctx.heap, "toString");
        if (tostr_key != null) {
            if (try method_val = obj.get_prop_proto(tostr_key)) {
                if (method_val.is_object() || method_val.is_lightfunc()) {
                    TVal str_result = ctx.heap.call_fn(ctx.vm, method_val, null, 0, *val);
                    if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }
                    if (str_result.is_string()) {
                        HString* s = (HString*)str_result.get_heapptr();
                        if (s != null) {
                            hstring::write_cesu8_as_utf8(s.get_data(), &io::putchar);
                            return;
                        }
                    }
                    // toString returned a non-string primitive — fall through to print_tval
                    if (!str_result.is_object()) {
                        print_tval(&str_result);
                        return;
                    }
                }
            }
        }
        // No callable toString found — fall back to generic "[object Object]"
        io::printf("[object Object]");
        return;
    }
    print_tval(val);
}

fn void builtin_print(BuiltinContext* ctx) {
    for (ushort i = 0; i < ctx.argc; i++) {
        if (i > 0) {
            io::putchar(' ');
        }
        print_tval_ctx(ctx, &ctx.regs[ctx.base_reg + i]);
    }
    io::putchar('\n');
    ctx.result.set_undefined();
}

fn void builtin_console_log(BuiltinContext* ctx) {
    for (ushort i = 0; i < ctx.argc; i++) {
        if (i > 0) {
            io::putchar(' ');
        }
        print_tval_ctx(ctx, &ctx.regs[ctx.base_reg + i]);
    }
    io::putchar('\n');
    ctx.result.set_undefined();
}

fn void builtin_parse_int(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_number(double::nan);
        return;
    }
    // ES2015 §18.2.5: parseInt(string, radix) — ToString(string) first.
    // The previous fast-path returned fastints directly (skipping ToString) and
    // bailed to NaN for any non-string input — wrong for Number(-0), Number(NaN),
    // Boolean values, etc. The spec defines parseInt on the string form of the
    // argument regardless of input type.
    TVal* arg = &ctx.regs[ctx.base_reg];
    HString* h;
    if (arg.is_string()) {
        h = (HString*)arg.get_heapptr();
    } else {
        h = builtin_to_string_vm(ctx, arg);
        if (ctx.should_throw) return;
    }
    if (h == null || h.blen == 0) {
        ctx.result.set_number(double::nan);
        return;
    }
    char* cstr = h.get_cstr();
    // Skip leading whitespace
    char* p = cstr;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;

    int radix;
    if (ctx.argc > 1) {
        TVal* rad_arg = &ctx.regs[ctx.base_reg + 1];
        radix = (int)(rad_arg.is_fastint() ? rad_arg.get_fastint() : rad_arg.get_number());
    } else {
        radix = 0;  // auto-detect: 0x/0X = hex; leading 0 = octal via strtol (legacy ES5; not ES2015+ spec)
    }

    char* end;
    long result = libc::strtol(p, &end, radix);
    if (end == cstr) {
        ctx.result.set_number(double::nan);
        return;
    }
    ctx.result.set_fastint(result);
}

fn void builtin_parse_float(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_number(double::nan);
        return;
    }
    // ES2015 §18.2.4: parseFloat(string) — ToString(string) first. The previous
    // direct-call into string_to_double returned NaN for booleans, undefined,
    // null, and objects — wrong because the spec coerces any input type to a
    // string first (e.g. parseFloat(true) is NaN, parseFloat("3.14") is 3.14).
    TVal* arg = &ctx.regs[ctx.base_reg];
    HString* h;
    if (arg.is_string()) {
        h = (HString*)arg.get_heapptr();
    } else {
        h = builtin_to_string_vm(ctx, arg);
        if (ctx.should_throw) return;
    }
    if (h == null || h.blen == 0) {
        ctx.result.set_number(double::nan);
        return;
    }
    char* end;
    double d = libc::strtod((ZString)h.get_cstr(), &end);
    if (end == h.get_cstr()) {
        ctx.result.set_number(double::nan);
        return;
    }
    ctx.result.set_number(d);
}

fn void builtin_is_nan(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal num;
    builtin_to_number(&ctx.regs[ctx.base_reg], &num);
    ctx.result.set_boolean((num.is_number()) ? math::is_nan(num.get_number()) : false);
}

fn void builtin_is_finite(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_boolean(false);
        return;
    }
    double d = string_to_double(&ctx.regs[ctx.base_reg]);
    ctx.result.set_boolean(!math::is_nan(d) && !math::is_inf(d));
}

fn void builtin_eval(BuiltinContext* ctx) {
    // ES5 §15.1.2.1: eval(x)
    if (ctx.argc < 1) {
        // No args → return undefined
        ctx.result.set_undefined();
        return;
    }

    TVal* arg = &ctx.regs[ctx.base_reg];

    // If Type(x) is not String, return x unchanged
    if (!arg.is_string()) {
        ctx.heap.tval_copy_ref(ctx.result, arg);
        return;
    }

    HString* source = (HString*)arg.get_heapptr();
    char* src_cstr = source.get_cstr();
    usz src_len = source.blen;

    // Compile the source string as eval code
    Lexer lex = lexer::lexer_init(src_cstr[:src_len], ctx.heap);
    CompiledFunction*? cf = compiler::compile_eval(&lex, ctx.heap);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
        // Compilation failed: throw SyntaxError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.syntax_err_proto;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            HString* msg_str = builtin_intern_string(ctx.heap, "SyntaxError in eval code");
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            TVal err_tv;
            err_tv.set_object(err);
            ctx.throw_value.set_object(err_tv.get_heapptr());
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Create an HObject for the compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    (*func_obj.extra_ptr()).func.comp_func = func;
    (*func_obj.extra_ptr()).func.builtin_fn_index = -1;

    // Determine whether this is a direct eval call by checking the calling
    // activation's ACT_FLAG_DIRECT_EVAL flag (set by the compiler when the
    // function body contains a direct eval(...) call).
    // For direct eval, use the caller's lexical environment (ES5 §10.4.2).
    // For indirect eval, use the global environment.
    //
    // In strict mode (this engine is strict-only per AGENTS.md), the eval'd
    // code's variable and function declarations must be installed in a FRESH
    // declarative environment whose parent is the caller's env (or the global
    // env for indirect eval). This prevents `eval("var x = 1")` from
    // mutating the caller's bindings — instead the declarations live in the
    // eval's own env, which is discarded when the eval call returns.
    // (Sloppy-mode eval would share the caller's env — Annex B legacy —
    // but the engine has no sloppy mode.)
    vm::Vm* eval_vm = (vm::Vm*)ctx.vm;
    usz act_count = eval_vm.activation_count;
    bool is_direct_eval = false;
    EnvRecord* env_for_eval = ctx.global_env;
    if (act_count > 0) {
        vm::Activation* caller_act = &eval_vm.activations[act_count - 1];
        if ((caller_act.flags & vm::ACT_FLAG_DIRECT_EVAL) != 0) {
            is_direct_eval = true;
            env_for_eval = caller_act.lex_env;
        }
    }
    // Create a fresh declarative child env so the eval's DECLVAR writes don't
    // mutate the caller's bindings. `env_create_declarative` already exists
    // and is used for the `needs_lex_bridge` path (vm.c3:5217).
    EnvRecord*? eval_env_raw = env::env_create_declarative(ctx.heap, env_for_eval);
    if (catch err = eval_env_raw) {
        // Allocation failed — fall back to sharing the caller's env (preserves
        // the old behavior on OOM rather than crashing the VM).
        (*func_obj.extra_ptr()).func.var_env = env_for_eval;
        (*func_obj.extra_ptr()).func.lex_env = env_for_eval;
    } else {
        EnvRecord* eval_env = eval_env_raw;
        (*func_obj.extra_ptr()).func.var_env = eval_env;
        (*func_obj.extra_ptr()).func.lex_env = eval_env;
    }

    // Replace the callee slot with the compiled function HObject
    TVal func_tv;
    func_tv.set_object(func_obj);
    ctx.regs[ctx.base_reg - 2] = func_tv;

    // Set this binding per ES6 §18.2.1.2:
    //   - Indirect eval: thisArg = the global object
    //   - Direct eval: thisArg = the calling context's this binding
    // The re-dispatch CALL handler runs the eval'd function with `this`
    // in the (base_reg - 1) slot — we set it here to the appropriate value.
    TVal this_tv;
    if (is_direct_eval && ctx.argc > 0) {
        // For direct eval, the caller's `this` is the same value passed in
        // the re-dispatch slot by the CALL handler. The CALL handler
        // already populated the slot, so we don't override it.
    } else if (ctx.global_env != null && ctx.global_env.bindings != null) {
        // Indirect eval (or no caller): `this` = global object.
        this_tv.set_object(ctx.global_env.bindings);
        ctx.regs[ctx.base_reg - 1] = this_tv;
    }

    // Signal the CALL handler to re-dispatch to the compiled function with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

fn void uri_encode_byte(char* out, usz* offset, char b) {
    out[*offset] = '%';
    out[*offset + 1] = "0123456789ABCDEF"[b >> 4];
    out[*offset + 2] = "0123456789ABCDEF"[b & 0x0F];
    *offset += 3;
}

fn bool uri_is_unreserved(char c) {
    if (c >= 'A' && c <= 'Z') return true;
    if (c >= 'a' && c <= 'z') return true;
    if (c >= '0' && c <= '9') return true;
    if (c == '-' || c == '_' || c == '.' || c == '!') return true;
    if (c == '~' || c == '*' || c == '\'' || c == '(') return true;
    if (c == ')') return true;
    return false;
}

fn int hex_digit_val(char c) {
    if (c >= '0' && c <= '9') return (int)c - '0';
    if (c >= 'A' && c <= 'F') return (int)c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return (int)c - 'a' + 10;
    return -1;
}

/// encodeURI (ES5 §15.1.3.1)
fn void builtin_encode_uri(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        char c = data[i];
        // URI unreserved + reserved + '#' characters (not encoded)
        if (uri_is_unreserved(c)) {
            out[offset++] = c;
            i++;
        } else if (c == ';' || c == ',' || c == '/' || c == '?' || c == ':' ||
                   c == '@' || c == '&' || c == '=' || c == '+' || c == '$' ||
                   c == '-' || c == '_' || c == '.' || c == '!' || c == '~' ||
                   c == '*' || c == '\'' || c == '(' || c == ')' || c == '#') {
            out[offset++] = c;
            i++;
        } else {
            uint b = (uint)c;
            if (b < 0x80) {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            } else if (b >= 0xC2 && b <= 0xF4) {
                uint seq_len;
                if (b < 0xE0) { seq_len = 2; }
                else if (b < 0xF0) { seq_len = 3; }
                else { seq_len = 4; }
                if (i + seq_len > len) {
                    // Incomplete sequence - encode byte
                    uri_encode_byte(&out, &offset, (char)b);
                    i++;
                } else {
                    // Validate continuation bytes
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        uint cb = (uint)data[i + j];
                        if (cb < 0x80 || cb > 0xBF) { valid = false; break; }
                    }
                    if (!valid) {
                        uri_encode_byte(&out, &offset, (char)b);
                        i++;
                    } else {
                        for (uint j = 0; j < seq_len; j++) {
                            uri_encode_byte(&out, &offset, (char)data[i + j]);
                        }
                        i += seq_len;
                    }
                }
            } else {
                // Invalid leading byte (0x80-0xBF, 0xC0-0xC1, 0xF5-0xFF)
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            }
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

/// encodeURIComponent (ES5 §15.1.3.2)
fn void builtin_encode_uri_component(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        char c = data[i];
        if (uri_is_unreserved(c)) {
            out[offset++] = c;
            i++;
        } else {
            uint b = (uint)c;
            if (b < 0x80) {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            } else if (b >= 0xC2 && b <= 0xF4) {
                uint seq_len;
                if (b < 0xE0) { seq_len = 2; }
                else if (b < 0xF0) { seq_len = 3; }
                else { seq_len = 4; }
                if (i + seq_len > len) {
                    uri_encode_byte(&out, &offset, (char)b);
                    i++;
                } else {
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        uint cb = (uint)data[i + j];
                        if (cb < 0x80 || cb > 0xBF) { valid = false; break; }
                    }
                    if (!valid) {
                        uri_encode_byte(&out, &offset, (char)b);
                        i++;
                    } else {
                        for (uint j = 0; j < seq_len; j++) {
                            uri_encode_byte(&out, &offset, (char)data[i + j]);
                        }
                        i += seq_len;
                    }
                }
            } else {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            }
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

/// decodeURI (ES5 §15.1.3.3)
fn void builtin_decode_uri(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        if (data[i] == '%') {
            // Check if this is a reserved character that should NOT be decoded
            if (i + 2 < len) {
                int d1 = hex_digit_val(data[i + 1]);
                int d2 = hex_digit_val(data[i + 2]);
                if (d1 >= 0 && d2 >= 0) {
                    uint cp = (uint)((d1 << 4) | d2);
                    // decodeURI does NOT decode reserved URI characters
                    if (cp == 0x23 || cp == 0x24 || cp == 0x26 || cp == 0x2B ||
                        cp == 0x2C || cp == 0x2F || cp == 0x3A || cp == 0x3B ||
                        cp == 0x3D || cp == 0x3F || cp == 0x40) {
                        out[offset++] = '%';
                        out[offset++] = data[i + 1];
                        out[offset++] = data[i + 2];
                        i += 3;
                        continue;
                    }
                    // Decode the byte
                    char first = (char)cp;
                    if (first < 0x80) {
                        out[offset++] = (char)first;
                        i += 3;
                    } else if (first >= 0xC0 && first <= 0xF4) {
                        // Multi-byte UTF-8 sequence
                        uint seq_len;
                        if (first < 0xE0) { seq_len = 2; }
                        else if (first < 0xF0) { seq_len = 3; }
                        else { seq_len = 4; }
                        if (i + 3 * seq_len > len) {
                            // Incomplete - throw URIError
                            builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
                            return;
                        }
                        char[4] bytes;
                        bytes[0] = (char)first;
                        bool valid = true;
                        for (uint j = 1; j < seq_len; j++) {
                            if (data[i + 3 * j] != '%') { valid = false; break; }
                            int h1 = hex_digit_val(data[i + 3 * j + 1]);
                            int h2 = hex_digit_val(data[i + 3 * j + 2]);
                            if (h1 < 0 || h2 < 0) { valid = false; break; }
                            char b = (char)((h1 << 4) | h2);
                            if (b < 0x80 || b > 0xBF) { valid = false; break; }
                            bytes[j] = (char)b;
                        }
                        if (!valid) {
                            builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
                            return;
                        }
                        for (uint j = 0; j < seq_len; j++) {
                            out[offset++] = bytes[j];
                        }
                        i += 3 * seq_len;
                    } else {
                        // Invalid leading byte for multi-byte sequence
                        builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
                        return;
                    }
                } else {
                    // Invalid hex digits
                    builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
                    return;
                }
            } else {
                // '%' not followed by two hex digits
                builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
                return;
            }
        } else {
            out[offset++] = data[i];
            i++;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

/// decodeURIComponent (ES5 §15.1.3.4)
fn void builtin_decode_uri_component(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, "undefined"));
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.set_string(builtin_intern_string(ctx.heap, ""));
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        if (data[i] == '%') {
            if (i + 2 < len) {
                int d1 = hex_digit_val(data[i + 1]);
                int d2 = hex_digit_val(data[i + 2]);
                if (d1 < 0 || d2 < 0) {
                    builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
                    return;
                }
                char first = (char)((d1 << 4) | d2);
                if (first < 0x80) {
                    out[offset++] = (char)first;
                    i += 3;
                } else if (first >= 0xC0 && first <= 0xF4) {
                    uint seq_len;
                    if (first < 0xE0) { seq_len = 2; }
                    else if (first < 0xF0) { seq_len = 3; }
                    else { seq_len = 4; }
                    if (i + 3 * seq_len > len) {
                        builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
                        return;
                    }
                    char[4] bytes;
                    bytes[0] = (char)first;
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        if (data[i + 3 * j] != '%') { valid = false; break; }
                        int h1 = hex_digit_val(data[i + 3 * j + 1]);
                        int h2 = hex_digit_val(data[i + 3 * j + 2]);
                        if (h1 < 0 || h2 < 0) { valid = false; break; }
                        char b = (char)((h1 << 4) | h2);
                        if (b < 0x80 || b > 0xBF) { valid = false; break; }
                        bytes[j] = (char)b;
                    }
                    if (!valid) {
                        builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
                        return;
                    }
                    for (uint j = 0; j < seq_len; j++) {
                        out[offset++] = bytes[j];
                    }
                    i += 3 * seq_len;
                } else {
                    builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
                    return;
                }
            } else {
                builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
                return;
            }
        } else {
            out[offset++] = data[i];
            i++;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}
