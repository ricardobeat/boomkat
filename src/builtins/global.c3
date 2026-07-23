/// Global built-in functions: print, parseInt, parseFloat, isNaN, isFinite, eval, URI encoding/decoding.
module duktape::builtins;
import duktape::types;
import duktape::bytecode;
import std::io;
import std::math;
import duktape::dtoa_bindings;
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
    console_print_args(ctx, false);
}

fn void builtin_console_info(BuiltinContext* ctx) {
    console_print_args(ctx, false);
}

fn void builtin_console_debug(BuiltinContext* ctx) {
    console_print_args(ctx, false);
}

fn void builtin_console_trace(BuiltinContext* ctx) {
    console_print_args(ctx, false);
}

fn void builtin_console_warn(BuiltinContext* ctx) {
    console_print_args(ctx, true);
}

fn void builtin_console_error(BuiltinContext* ctx) {
    console_print_args(ctx, true);
}

fn void builtin_console_dir(BuiltinContext* ctx) {
    // console.dir(obj) — for now identical output to console.log (no util.inspect
    // formatting). Spec only requires this be callable and return undefined.
    console_print_args(ctx, false);
}

/// console.assert(expr, ...msg) — if expr is falsy, emit "Assertion failed:" and
/// the remaining args to stderr. If truthy, produce no output. Returns undefined.
fn void builtin_console_assert(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        io::eprintfn("Assertion failed:");
        ctx.result.set_undefined();
        return;
    }
    if (builtin_to_boolean(&ctx.regs[ctx.base_reg])) {
        ctx.result.set_undefined();
        return;
    }
    io::eprintfn("Assertion failed:");
    for (ushort i = 1; i < ctx.argc; i++) {
        if (i > 1) {
            io::eprintf(" ");
        }
        print_tval_err_ctx(ctx, &ctx.regs[ctx.base_reg + i]);
    }
    io::eprintf("\n");
    ctx.result.set_undefined();
}

/// Shared body for console.log/info/debug/trace (stdout) and console.warn/error (stderr).
fn void console_print_args(BuiltinContext* ctx, bool use_stderr) {
    for (ushort i = 0; i < ctx.argc; i++) {
        if (i > 0) {
            if (use_stderr) {
                io::eprintf(" ");
            } else {
                io::printf(" ");
            }
        }
        if (use_stderr) {
            print_tval_err_ctx(ctx, &ctx.regs[ctx.base_reg + i]);
        } else {
            print_tval_ctx(ctx, &ctx.regs[ctx.base_reg + i]);
        }
    }
    if (use_stderr) {
        io::eprintf("\n");
    } else {
        io::printf("\n");
    }
    ctx.result.set_undefined();
}

/// Stderr byte sink used by write_cesu8_as_utf8.
fn void eputc(char c) {
    io::eprintf("%c", c);
}

/// Mirror of print_tval_ctx that writes to stderr instead of stdout.
fn void print_tval_err_ctx(BuiltinContext* ctx, TVal* val) {
    if (val.is_object() && val.get_heapptr() != null && ctx.vm != null && ctx.heap.call_fn != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        HString* tostr_key = builtin_intern_string(ctx.heap, "toString");
        if (tostr_key != null) {
            if (try method_val = obj.get_prop_proto(tostr_key)) {
                if (method_val.is_object() || method_val.is_lightfunc()) {
                    TVal str_result = ctx.heap.call_fn(ctx.vm, method_val, null, 0, *val);
                    if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }
                    if (str_result.is_string()) {
                        HString* s = (HString*)str_result.get_heapptr();
                        if (s != null) {
                            hstring::write_cesu8_as_utf8(s.get_data(), &eputc);
                            return;
                        }
                    }
                    if (!str_result.is_object()) {
                        print_tval_err(&str_result);
                        return;
                    }
                }
            }
        }
        io::eprint("[object Object]");
        return;
    }
    print_tval_err(val);
}

/// Stderr counterpart of print_tval (primitives only; objects handled by
/// print_tval_err_ctx, which falls back here for non-string toString results).
fn void print_tval_err(TVal* val) {
    switch (val.get_tag()) {
        case UNDEFINED: io::eprint("undefined");
        case NULL_VAL:  io::eprint("null");
        case BOOLEAN:   io::eprint(val.get_boolean() ? "true" : "false");
        case FASTINT:   io::eprintf("%d", val.get_fastint());
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            if (s != null) {
                char[] d = s.get_data();
                for (usz i = 0; i < d.len; i++) { io::eprintf("%c", d[i]); }
            }
        }
        case NUMBER: {
            double v = val.get_number();
            if (math::is_nan(v)) {
                io::eprint("NaN");
            } else if (math::is_inf(v)) {
                io::eprint(v > 0 ? "Infinity" : "-Infinity");
            } else {
                io::eprintf("%g", v);
            }
        }
        default:
            io::eprint("[object Object]");
    }
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
    // ── Radix coercion (ES2015 §18.2.5 step 7: ToInt32) ────────────────────
    // Done before string scanning; a throwing radix must propagate.
    int radix = 0;
    if (ctx.argc > 1) {
        double r = builtin_to_integer_vm(ctx, &ctx.regs[ctx.base_reg + 1]);
        if (ctx.should_throw) return;
        // ToInt32 modular wrap.
        if (math::is_nan(r) || math::is_inf(r)) {
            radix = 0;
        } else {
            radix = (int)(long)r;  // truncated; large values wrap harmlessly below
        }
    }

    char* cstr = h.get_cstr();
    usz blen = h.blen;
    usz i = 0;

    // ── Step 2: strip leading StrWhiteSpace (WhiteSpace + LineTerminator) ──
    // Covers ASCII ws plus the common Unicode spaces test262 exercises via
    // their UTF-8 encodings (NBSP U+00A0, BOM U+FEFF, various U+2000..U+200A,
    // U+2028/U+2029, U+1680, U+202F, U+205F, U+3000).
    while (i < blen) {
        char c = cstr[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r'
                || c == 0x0B || c == 0x0C) { i++; continue; }
        // Multi-byte UTF-8 whitespace.
        usz adv = utf8_whitespace_len(cstr, blen, i);
        if (adv > 0) { i += adv; continue; }
        break;
    }

    // ── Step 4-5: optional sign ────────────────────────────────────────────
    int sign = 1;
    if (i < blen && (cstr[i] == '+' || cstr[i] == '-')) {
        if (cstr[i] == '-') sign = -1;
        i++;
    }

    // ── Step 8-10: radix normalisation + 0x prefix ─────────────────────────
    bool strip_prefix = false;
    if (radix == 0) {
        radix = 10;
        strip_prefix = true;
    } else if (radix < 2 || radix > 36) {
        ctx.result.set_number(double::nan);
        return;
    } else if (radix == 16) {
        strip_prefix = true;
    }
    if (strip_prefix && i + 1 < blen && cstr[i] == '0'
            && (cstr[i + 1] == 'x' || cstr[i + 1] == 'X')) {
        i += 2;
        radix = 16;
    }

    // ── Step 11-16: consume digits ─────────────────────────────────────────
    double value = 0.0;
    bool saw_digit = false;
    while (i < blen) {
        char c = cstr[i];
        int d;
        if (c >= '0' && c <= '9') { d = c - '0'; }
        else if (c >= 'a' && c <= 'z') { d = c - 'a' + 10; }
        else if (c >= 'A' && c <= 'Z') { d = c - 'A' + 10; }
        else { break; }
        if (d >= radix) break;
        value = value * (double)radix + (double)d;
        saw_digit = true;
        i++;
    }

    if (!saw_digit) {
        ctx.result.set_number(double::nan);
        return;
    }
    value *= (double)sign;
    // Emit a fastint only within its 48-bit payload range; larger exact
    // integers must go through set_number to avoid truncation.
    if (value >= (double)types::FASTINT_MIN && value <= (double)types::FASTINT_MAX
            && value == (double)(long)value) {
        ctx.result.set_fastint((long)value);
    } else {
        ctx.result.set_number(value);
    }
}

/// Returns the UTF-8 byte length of a Unicode whitespace/BOM code point at
/// `buf[i]`, or 0 if the code point there is not JS StrWhiteSpace. Handles the
/// 2- and 3-byte sequences ECMAScript treats as whitespace.
fn usz utf8_whitespace_len(char* buf, usz len, usz i) {
    char c0 = buf[i];
    // 2-byte: U+00A0 (C2 A0) NBSP.
    if (i + 1 < len && (uint)(char)c0 == 0xC2 && (uint)(char)buf[i + 1] == 0xA0) {
        return 2;
    }
    // 3-byte sequences.
    if (i + 2 < len && (uint)(char)c0 == 0xE1
            && (uint)(char)buf[i + 1] == 0x9A && (uint)(char)buf[i + 2] == 0x80) {
        return 3; // U+1680
    }
    if (i + 2 < len && (uint)(char)c0 == 0xE2) {
        uint b1 = (uint)(char)buf[i + 1];
        uint b2 = (uint)(char)buf[i + 2];
        // U+2000..U+200A (E2 80 80..8A), U+2028 (E2 80 A8), U+2029 (E2 80 A9),
        // U+202F (E2 80 AF), U+205F (E2 81 9F).
        if (b1 == 0x80 && ((b2 >= 0x80 && b2 <= 0x8A) || b2 == 0xA8 || b2 == 0xA9 || b2 == 0xAF)) {
            return 3;
        }
        if (b1 == 0x81 && b2 == 0x9F) { return 3; } // U+205F
    }
    if (i + 2 < len && (uint)(char)c0 == 0xE3
            && (uint)(char)buf[i + 1] == 0x80 && (uint)(char)buf[i + 2] == 0x80) {
        return 3; // U+3000
    }
    if (i + 2 < len && (uint)(char)c0 == 0xEF
            && (uint)(char)buf[i + 1] == 0xBB && (uint)(char)buf[i + 2] == 0xBF) {
        return 3; // U+FEFF BOM
    }
    return 0;
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

    char* cstr = h.get_cstr();
    usz blen = h.blen;
    usz i = 0;

    // ── Strip leading StrWhiteSpace (WhiteSpace + LineTerminator) ──────────
    while (i < blen) {
        char c = cstr[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r'
                || c == 0x0B || c == 0x0C) { i++; continue; }
        usz adv = utf8_whitespace_len(cstr, blen, i);
        if (adv > 0) { i += adv; continue; }
        break;
    }

    // ── Match the longest StrDecimalLiteral prefix (ES2015 §7.1.3.1 Table 10) ──
    // Grammar: [+-]? (Infinity | DecimalDigits? "." DecimalDigits? Exponent?
    //                  | DecimalDigits Exponent?)
    // Crucially, this does NOT include the "0x"/"0X" hex prefix that
    // StringNumericLiteral (used by ToNumber) accepts — parseFloat rejects hex.
    usz start = i;
    if (i < blen && (cstr[i] == '+' || cstr[i] == '-')) i++;

    if (i + 8 <= blen && mem::equals(&cstr[i], (char*)"Infinity", 8)) {
        double inf = (cstr[start] == '-') ? -double::inf : double::inf;
        ctx.result.set_number(inf);
        return;
    }

    usz digits_start = i;
    while (i < blen && cstr[i] >= '0' && cstr[i] <= '9') i++;
    bool saw_int_digit = (i > digits_start);

    bool saw_frac_digit = false;
    if (i < blen && cstr[i] == '.') {
        i++;
        usz frac_start = i;
        while (i < blen && cstr[i] >= '0' && cstr[i] <= '9') i++;
        saw_frac_digit = (i > frac_start);
    }

    if (!saw_int_digit && !saw_frac_digit) {
        // No digits at all (bare sign, bare '.', or neither) — not a number.
        ctx.result.set_number(double::nan);
        return;
    }

    // Optional exponent — only valid once a mantissa digit was seen.
    if (i < blen && (cstr[i] == 'e' || cstr[i] == 'E')) {
        usz exp_save = i;
        usz j = i + 1;
        if (j < blen && (cstr[j] == '+' || cstr[j] == '-')) j++;
        usz exp_digits_start = j;
        while (j < blen && cstr[j] >= '0' && cstr[j] <= '9') j++;
        if (j > exp_digits_start) {
            i = j;
        } else {
            i = exp_save; // malformed exponent — not part of the literal
        }
    }

    // Copy just the matched StrDecimalLiteral prefix into a bounded, NUL-terminated
    // buffer before handing it to strtod — passing `&cstr[start]` directly would let
    // strtod's own scanner run past our match (e.g. re-parsing "0x1" as a hex float
    // after we correctly stopped at "0"), producing a value parseFloat must reject.
    usz match_len = i - start;
    char[512] lit_buf;
    usz copy_len = (match_len < 511) ? match_len : 511;
    for (usz k = 0; k < copy_len; k++) lit_buf[k] = cstr[start + k];
    lit_buf[copy_len] = 0;

    char* end;
    double d = dtoa_bindings::atod_strtod_compat((ZString)&lit_buf[0], &end);
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

    // Direct eval shares the caller's lexical environment (checked again,
    // and used to pick env_for_eval, below) — including any `__super__`
    // hidden binding, so `super.x`/`super[x]` may legally appear in the
    // source. Detect this before compiling so the eval CompilerContext can
    // permit the syntax (see compile_eval's allow_super doc comment).
    //
    // Per ES2022 §8.7.1, direct eval ALSO inherits the caller's
    // PrivateEnvironment — i.e. private field/method references inside the
    // eval body resolve against the calling class body's declared names.
    // The caller (the function whose body contains `eval(...)`) stashed a
    // snapshot of its private-name table into its CompiledFunction when it
    // finished compiling (see context.c3 CompilerContext.finish). At runtime
    // we read that snapshot here and hand it to compile_eval, which adopts
    // it into the fresh eval CompilerContext — after that the eval body's
    // `this.#m` reference resolves through `resolve_private_name` exactly
    // like a method body's reference would.
    vm::Vm* precheck_vm = (vm::Vm*)ctx.vm;
    usz precheck_act_count = precheck_vm.activation_count;
    vm::Activation* precheck_caller = null;
    bool caller_has_direct_eval = false;
    // ES2015 Annex B: `new.target` is a permitted syntax inside an eval
    // source ONLY when the eval is being processed by direct eval from
    // non-ArrowFunction FunctionBody code. ACT_FLAG_DIRECT_EVAL covers
    // the "direct eval" half (the activation is flagged at compile time
    // when the calling function body contains direct eval calls); we
    // additionally rule out top-level script activation
    // (is_global_fn()==true, the script's CompiledFunction template) and
    // ArrowFunction activations (is_arrow()==true) so global direct eval
    // and arrow direct eval both reject new.target like the spec
    // requires. See compile_eval's `direct_in_function` doc comment.
    bool caller_direct_eval_in_function = false;
    bool caller_eval_allows_super = false;
    void* parent_priv_names = null;
    uint parent_priv_count = 0;
    bool caller_super_is_home_object = false;
    if (precheck_act_count > 0) {
        precheck_caller = &precheck_vm.activations[precheck_act_count - 1];
        caller_has_direct_eval = (precheck_caller.flags & vm::ACT_FLAG_DIRECT_EVAL) != 0;
        if (caller_has_direct_eval) {
            // precheck_caller.func is the caller's CompiledFunction template
            // (for natfunc frames — like this builtin itself — the func slot
            // isn't a CompiledFunction, so guard the cast). For compiled
            // function frames (the only paths that set ACT_FLAG_DIRECT_EVAL),
            // func is always the corresponding CompiledFunction* — see
            // vm_core.c3 act_creation paths and how `target` is read.
            // The cast is safe because has_direct_eval is a function-level
            // flag that's only ever set on compiled function bodies.
            CompiledFunction* caller_cf = (CompiledFunction*)precheck_caller.func;
            if (caller_cf != null) {
                if (!caller_cf.is_arrow() && !caller_cf.is_global_fn()) {
                    caller_direct_eval_in_function = true;
                }
                // super.x/super[x] in eval is only allowed when the calling
                // function is a method with a [[HomeObject]] (ES2022 §15.7.3
                // PerformEval step 7: "If thisEnvRec has a [[HomeObject]]
                // field"). has_home_object is set at compile time when
                // super_is_home_object is true (i.e. the function is a
                // method or accessor in an object literal or class body).
                if (caller_cf.has_home_object()) {
                    caller_eval_allows_super = true;
                }
                caller_super_is_home_object = caller_cf.super_is_home_object();
                parent_priv_names = caller_cf.eval_private_names;
                parent_priv_count = caller_cf.eval_private_name_count;
            }
        }
    }

    // Compile the source string as eval code
    Lexer lex = lexer::lexer_init(src_cstr[:src_len], ctx.heap);
    defer lex.free_arena();
    lex.skip_hashbang();
    CompiledFunction*? cf = compiler::compile_eval(&lex, ctx.heap, caller_eval_allows_super,
                                                    caller_direct_eval_in_function,
                                                    parent_priv_names, parent_priv_count,
                                                    caller_has_direct_eval,
                                                    caller_super_is_home_object);
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
    // function body contains a direct eval(...) call). The environment the
    // eval's own scope is parented on is the caller's lexical environment for
    // direct eval (ES5 §10.4.2), and the global environment for indirect eval.
    vm::Vm* eval_vm = (vm::Vm*)ctx.vm;
    usz act_count = eval_vm.activation_count;
    bool is_direct_eval = false;
    // Indirect eval's lexEnv is NewDeclarativeEnvironment(GlobalEnv), whose
    // outer must be the global Environment Record's DeclarativeRecord (the
    // global lexical env) so the eval sees top-level `let`/`const`/`class`
    // bindings. varEnv stays the global object record. Direct eval overrides
    // both with the caller's envs below.
    EnvRecord* lex_env_for_eval = eval_vm.global_lex_env != null ? eval_vm.global_lex_env : ctx.global_env;
    EnvRecord* var_env_for_eval = ctx.global_env;
    TVal caller_this;
    caller_this.set_undefined();
    // Reuse the activation captured in the precheck above — by the time we
    // get here, the only thing that could have changed is act_count itself
    // (no extra activations can be pushed between the precheck and this
    // block because builtin_eval runs to completion on this thread before
    // any subsequent VM dispatch). The direct-eval decision below is
    // therefore guaranteed consistent with `caller_has_direct_eval`.
    if (caller_has_direct_eval && precheck_caller != null) {
        is_direct_eval = true;
        lex_env_for_eval = precheck_caller.lex_env;
        var_env_for_eval = precheck_caller.var_env;
        caller_this = precheck_caller.this_binding;
    }
    // Declaration-instantiation leak semantics follow the eval SOURCE's own
    // strictness (ES2015 §18.2.1.1 PerformEval step 12), independent of the
    // fact that this engine executes every function in strict mode.
    //
    //   - Strict eval source: varEnv is a FRESH declarative env. A single
    //     fresh env serves as BOTH var_env and lex_env, so `var`/`function`
    //     (DECLVAR) and `let`/`const`/`class` (PUTLEX) all land in one
    //     throwaway scope and nothing escapes when the eval returns.
    //   - Non-strict eval source: `var`/`function` bindings are instantiated
    //     in the enclosing variable environment (the global env for indirect
    //     eval, the caller's var_env for direct eval) so they persist per
    //     EvalDeclarationInstantiation; lex_env is a fresh declarative child
    //     of the call-site's lex_env (chaining through var_env so DECLVAR
    //     writes stay visible to same-eval reads), isolating let/const/class.
    // A direct eval inherits the calling code's strictness (§18.2.1.1 step 12:
    // strictCaller). Every activation in this engine runs strict, so a direct
    // eval is always strict regardless of the eval string's own prologue; an
    // indirect eval's strictness is decided solely by that prologue.
    bool eval_strict = is_direct_eval || func.eval_source_is_strict();
    if (eval_strict) {
        EnvRecord*? eval_env_raw = env::env_create_declarative(ctx.heap, lex_env_for_eval);
        if (catch err = eval_env_raw) {
            (*func_obj.extra_ptr()).func.var_env = lex_env_for_eval;
            (*func_obj.extra_ptr()).func.lex_env = lex_env_for_eval;
        } else {
            (*func_obj.extra_ptr()).func.var_env = eval_env_raw;
            (*func_obj.extra_ptr()).func.lex_env = eval_env_raw;
        }
    } else {
        (*func_obj.extra_ptr()).func.var_env = var_env_for_eval;
        EnvRecord*? lex_env_raw = env::env_create_declarative(ctx.heap, lex_env_for_eval);
        if (catch err = lex_env_raw) {
            (*func_obj.extra_ptr()).func.lex_env = lex_env_for_eval;
        } else {
            (*func_obj.extra_ptr()).func.lex_env = lex_env_raw;
        }
    }

    // Replace the callee slot with the compiled function HObject
    TVal func_tv;
    func_tv.set_object(func_obj);
    ctx.regs[ctx.base_reg - 2] = func_tv;

    // Set this binding per ES6 §18.2.1.2:
    //   - Indirect eval: thisArg = the global object
    //   - Direct eval: thisArg = the calling context's this binding
    // The re-dispatch CALL handler runs the eval'd function with `this`
    // in the (base_reg - 1) slot — we overwrite it here since the CALL
    // handler for a bare `eval(...)` call site always loads `undefined`
    // there (no receiver object precedes a plain identifier callee).
    TVal this_tv;
    if (is_direct_eval) {
        // Ref-counted register write: a raw struct copy would leave the
        // slot holding a heap pointer with no owning reference, so a
        // decref anywhere else along `caller_this`'s existing reference
        // (e.g. the caller popping its own activation) can free the object
        // out from under this register before the re-dispatched CALL
        // handler reads it back into the new activation's this_binding.
        ctx.heap.tval_copy_ref(&ctx.regs[ctx.base_reg - 1], &caller_this);
    } else if (ctx.global_env != null && ctx.global_env.bindings != null) {
        // Indirect eval (or no caller): `this` = global object.
        this_tv.set_object(ctx.global_env.bindings);
        ctx.regs[ctx.base_reg - 1] = this_tv;
    }

    // Signal the CALL handler to re-dispatch to the compiled function with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

/// $262.evalScript(src) — the test262 host hook that runs `src` as an
/// independent global Script (ES2015 §18.2.1 ScriptEvaluation), NOT as an
/// eval call. Unlike `eval`, this is never "direct" or "indirect": the
/// compiled Program always gets a fresh top-level activation whose
/// var_env/lex_env is the real global environment, so `var`/`function`/
/// `let`/`const`/`class` declarations follow ordinary global-code semantics
/// (GlobalDeclarationInstantiation) regardless of what called evalScript.
fn void builtin_eval_script(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }

    TVal* arg = &ctx.regs[ctx.base_reg];
    if (!arg.is_string()) {
        ctx.heap.tval_copy_ref(ctx.result, arg);
        return;
    }

    HString* source = (HString*)arg.get_heapptr();
    char* src_cstr = source.get_cstr();
    usz src_len = source.blen;

    Lexer lex = lexer::lexer_init(src_cstr[:src_len], ctx.heap);
    defer lex.free_arena();
    lex.skip_hashbang();
    CompiledFunction*? cf = compiler::compile(&lex, ctx.heap);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
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

    vm::Vm* eval_vm = (vm::Vm*)ctx.vm;
    bool? ok = eval_vm.execute_module_nested(func, ctx.global_env);
    if (catch err = ok) {
        ctx.result.set_undefined();
        return;
    }
    if (!ok) {
        // Uncaught throw inside the script — propagate it as this builtin's
        // own throw (execute_module_nested left it in heap.error_value).
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        eval_vm.has_error = false;
        return;
    }

    ctx.result.set_undefined();
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
