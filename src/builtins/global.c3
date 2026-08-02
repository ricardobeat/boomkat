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
        HString* tostr_key = ctx.heap.str(heap::BuiltinStr.TO_STRING);
        if (tostr_key != null) {
            if (try method_val = obj.get_prop_proto(tostr_key)) {
                if (method_val.is_object() || method_val.is_lightfunc()) {
                    TVal str_result = ctx.heap.call_fn(ctx.vm, method_val, null, 0, *val);
                    if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }
                    if (str_result.is_string()) {
                        HString* s = (HString*)str_result.get_heapptr();
                        if (s != null) {
                            hstring::write_cesu8_as_utf8(s.get_data(), &putc_out);
                            return;
                        }
                    }
                    // toString returned a non-string primitive, fall through to print_tval
                    if (!str_result.is_object()) {
                        print_tval(&str_result);
                        return;
                    }
                }
            }
        }
        // No callable toString found, fall back to generic "[object Object]"
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
    // console.dir(obj) renders its FIRST argument only and, unlike the other
    // console methods, applies no specifier substitution: console.dir("%s", x)
    // prints the format string verbatim and drops x. It is also not the
    // bare-string case, so console.dir("x") prints 'x' quoted where
    // console.log("x") prints it bare.
    if (ctx.argc > 0) {
        ConsoleSink sink = { false };
        console_emit_inspect_spec(ctx, sink, &ctx.regs[ctx.base_reg]);
    }
    io::printf("\n");
    ctx.result.set_undefined();
}

/// console.assert(expr, ...msg), if expr is falsy, emit "Assertion failed:" and
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
    // The message arguments are a Formatter input in their own right: the first
    // of them is the format string, so console.assert(false, "x %s", v) prints
    // the substituted form, matching console.log's treatment of its own args.
    console_format_args(ctx, true, 1);
    io::eprintf("\n");
    ctx.result.set_undefined();
}

/// Shared body for console.log/info/debug/trace (stdout) and console.warn/error (stderr).
fn void console_print_args(BuiltinContext* ctx, bool use_stderr) {
    console_format_args(ctx, use_stderr, 0);
    if (use_stderr) {
        io::eprintf("\n");
    } else {
        io::printf("\n");
    }
    ctx.result.set_undefined();
}

// ============================================================================
// console format specifiers
// ============================================================================
//
// The target is the de-facto util.format behaviour shared across JS runtimes,
// NOT the bare WHATWG console Formatter. The two disagree on three points, and
// the de-facto form is the useful one since real-world code is written against
// it:
//
//   - %j     WHATWG has no %j at all; it is JSON.stringify with "[Circular]"
//            substituted for a cyclic structure rather than a throw.
//   - %o/%O  WHATWG says "optimally useful formatting"; %o is an inspect with
//            showHidden/depth:4 and %O a plain inspect.
//   - %c     WHATWG applies CSS; the directive is ignored but still CONSUMES
//            its argument, so it must not fall through to the trailing append.
//
// Two gating rules, both verified against captured reference output rather
// than assumed:
//
//   1. Substitution happens only when the first argument is a STRING and there
//      is at least one further argument. `console.log("a %s b")` prints
//      "a %s b" verbatim, and so does `console.log("pct %% end")` — with no
//      extra args the formatter is never entered, so %% is NOT unescaped.
//      Once any extra arg exists, `console.log("pct %% end", 1)` prints
//      "pct % end 1". %% collapsing is gated on argument count, not on the
//      console-vs-util distinction.
//   2. A specifier with no argument left to consume stays literal:
//      `console.log("%s %s", "A")` prints "A %s".
//
// Arguments not consumed by a specifier are appended space-separated.

/// Byte sink pair for the formatter, so a single implementation serves both the
/// stdout methods (log/info/debug/trace/dir) and the stderr ones (warn/error/
/// assert) instead of the two near-identical mirrors this file used to carry.
struct ConsoleSink {
    bool use_stderr;
}

fn void ConsoleSink.put(&self, char c) {
    if (self.use_stderr) { eputc(c, null); } else { io::putchar(c); }
}

fn void ConsoleSink.write(&self, char[] bytes) {
    for (usz i = 0; i < bytes.len; i++) self.put(bytes[i]);
}

/// Emit one value the way console renders it outside any specifier: the
/// structured inspect form, with a top-level string emitted bare.
fn void console_emit_value(BuiltinContext* ctx, ConsoleSink sink, TVal* val) {
    StrBuf out;
    out.init(ctx.heap);
    defer out.free();
    if (inspect_root(ctx.heap, ctx.vm, val, &out)) {
        sink.write(out.data[:out.len]);
        return;
    }
    // Out of memory mid-render: fall back to the plain ToString form rather
    // than emitting the half-built buffer.
    if (sink.use_stderr) {
        print_tval_err_ctx(ctx, val);
    } else {
        print_tval_ctx(ctx, val);
    }
}

/// Format `ctx`'s arguments starting at `first`, applying specifier
/// substitution when argument `first` is a string. Does not emit a trailing
/// newline; callers own that.
fn void console_format_args(BuiltinContext* ctx, bool use_stderr, ushort first) {
    ConsoleSink sink = { use_stderr };
    if (first >= ctx.argc) return;

    TVal* fmt_val = &ctx.regs[ctx.base_reg + first];
    // Gate 1: a non-string first argument disables substitution entirely, and so
    // does a lone string with nothing to substitute into it.
    bool substituting = false;
    if (fmt_val.is_string() && (ushort)(first + 1) < ctx.argc) {
        HString* fs = (HString*)fmt_val.get_heapptr();
        // A Symbol is tagged STRING but is not a format string.
        if (fs != null && !fs.is_symbol()) substituting = true;
    }

    ushort next = (ushort)(first + 1);
    if (substituting) {
        HString* fs = (HString*)fmt_val.get_heapptr();
        char[] f = fs.get_data();
        usz i = 0;
        // Run of literal bytes pending emission, flushed as CESU-8 so that
        // non-ASCII in the format string survives unmangled.
        usz lit_start = 0;
        while (i < f.len) {
            if (f[i] != '%' || i + 1 >= f.len) { i++; continue; }
            char spec = f[i + 1];
            if (spec == '%') {
                // Collapse "%%" to a single "%": flush through the first one and
                // resume past the second.
                hstring::write_cesu8_as_utf8(f[lit_start:i + 1 - lit_start], sink.use_stderr ? &eputc : &putc_out);
                i += 2;
                lit_start = i;
                continue;
            }
            bool known = spec == 's' || spec == 'd' || spec == 'i' || spec == 'f'
                      || spec == 'o' || spec == 'O' || spec == 'j' || spec == 'c';
            // Gate 2: an exhausted argument list leaves the specifier literal.
            if (!known || next >= ctx.argc) { i++; continue; }

            hstring::write_cesu8_as_utf8(f[lit_start:i - lit_start], sink.use_stderr ? &eputc : &putc_out);
            TVal* arg = &ctx.regs[ctx.base_reg + next];
            next++;
            console_emit_specifier(ctx, sink, spec, arg);
            if (ctx.should_throw) return;
            i += 2;
            lit_start = i;
        }
        if (lit_start < f.len) {
            hstring::write_cesu8_as_utf8(f[lit_start:f.len - lit_start], sink.use_stderr ? &eputc : &putc_out);
        }
    } else {
        console_emit_value(ctx, sink, fmt_val);
        if (ctx.should_throw) return;
    }

    // Whatever no specifier claimed is appended space-separated.
    for (ushort a = next; a < ctx.argc; a++) {
        sink.put(' ');
        console_emit_value(ctx, sink, &ctx.regs[ctx.base_reg + a]);
        if (ctx.should_throw) return;
    }
}

/// Render a single argument under one specifier.
fn void console_emit_specifier(BuiltinContext* ctx, ConsoleSink sink, char spec, TVal* arg) {
    switch (spec) {
        case 'c':
            // CSS directive: consumed above, renders as nothing.
            return;
        case 's':
            console_emit_string_spec(ctx, sink, arg);
        case 'd':
        case 'i':
        case 'f':
            console_emit_number_spec(ctx, sink, spec, arg);
        case 'j':
            console_emit_json_spec(ctx, sink, arg);
        default:
            // 'o' and 'O', both an inspect. They differ only by the options
            // they imply (%o adds showHidden and depth 4), which this inspect
            // does not vary, so both render the same form a plain argument
            // would — except that a string under %o/%O is QUOTED, since the
            // bare-string rule applies only to a top-level value.
            console_emit_inspect_spec(ctx, sink, arg);
    }
}

/// %s uses String(value) semantics, not ToString: a Symbol renders as
/// "Symbol(desc)", where ToString(Symbol) would instead throw a TypeError.
fn void console_emit_string_spec(BuiltinContext* ctx, ConsoleSink sink, TVal* arg) {
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s == null) return;
        if (s.is_symbol()) {
            console_emit_symbol(sink, s);
            return;
        }
        hstring::write_cesu8_as_utf8(s.get_data(), sink.use_stderr ? &eputc : &putc_out);
        return;
    }
    // An object carrying a toString of its own is rendered by it, since that is
    // what the author wrote it for; a function likewise prints its source. An
    // object that merely inherits Object.prototype's toString would stringify
    // to the useless "[object Object]", so it is inspected instead.
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* obj = (HObject*)arg.get_heapptr();
        if (obj.is_callable() || inspect_has_custom_tostring(ctx.heap, obj)) {
            if (sink.use_stderr) { print_tval_err_ctx(ctx, arg); } else { print_tval_ctx(ctx, arg); }
            return;
        }
        // A %s argument is inspected one level shallower than a plain
        // argument, so `{a:{b:{c:1}}}` shows as `{ a: [Object] }` where a plain
        // argument would expand the `b`. Starting two levels in rather than one
        // is what leaves that single level of budget.
        StrBuf out;
        out.init(ctx.heap);
        defer out.free();
        if (inspect_at_depth(ctx.heap, ctx.vm, arg, &out, 2)) {
            sink.write(out.data[:out.len]);
            return;
        }
    }
    console_emit_value(ctx, sink, arg);
}

/// %o and %O, and console.dir's single argument. Unlike a plain argument these
/// are NOT at the root of a console call, so a string renders quoted.
fn void console_emit_inspect_spec(BuiltinContext* ctx, ConsoleSink sink, TVal* arg) {
    StrBuf out;
    out.init(ctx.heap);
    defer out.free();
    if (inspect_nested(ctx.heap, ctx.vm, arg, &out)) {
        sink.write(out.data[:out.len]);
        return;
    }
    console_emit_value(ctx, sink, arg);
}

/// Render a Symbol as "Symbol(desc)". The raw HString bytes carry the 0xFF
/// prefix and description marker, so emitting them directly (as the generic
/// primitive path does) would write the marker bytes into the output.
fn void console_emit_symbol(ConsoleSink sink, HString* sym) {
    sink.write("Symbol(");
    if (symbol_has_description(sym)) {
        hstring::write_cesu8_as_utf8(symbol_description(sym), sink.use_stderr ? &eputc : &putc_out);
    }
    sink.write(")");
}

/// %d, %i and %f map onto three DIFFERENT coercions, not one:
/// %d is Number(v) (so a valueOf() is honoured), %i is parseInt(v) and %f is
/// parseFloat(v) (so both go via the STRING form and stop at the first
/// unparseable character — parseInt(true) is NaN, but Number(true) is 1, and
/// parseFloat([1,2]) is 1 because the array stringifies to "1,2"). A Symbol is
/// NaN under all three rather than the TypeError ToNumber/ToString would raise,
/// and a BigInt keeps its own rendering.
fn void console_emit_number_spec(BuiltinContext* ctx, ConsoleSink sink, char spec, TVal* arg) {
    if (arg.is_bigint()) {
        console_emit_value(ctx, sink, arg);
        return;
    }
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s != null && s.is_symbol()) {
            sink.write("NaN");
            return;
        }
    }

    TVal num;
    if (spec == 'd') {
        double d = builtin_to_number_vm(ctx, arg);
        if (ctx.should_throw) {
            // A throwing valueOf() must not abort the whole console call.
            ctx.should_throw = false;
            ctx.heap.has_error = false;
            sink.write("NaN");
            return;
        }
        num.set_number(d);
    } else {
        // Delegate to the real parseInt/parseFloat rather than reimplementing
        // the StrDecimalLiteral prefix grammar. They read their argument out of
        // regs[base_reg], so hand them a one-argument view of this value.
        TVal arg_copy = *arg;
        BuiltinContext sub = *ctx;
        sub.regs = &arg_copy;
        sub.base_reg = 0;
        sub.argc = 1;
        sub.result = &num;
        sub.should_throw = false;
        if (spec == 'i') {
            builtin_parse_int(&sub);
        } else {
            builtin_parse_float(&sub);
        }
        if (sub.should_throw) {
            ctx.heap.has_error = false;
            sink.write("NaN");
            return;
        }
    }
    console_emit_value(ctx, sink, &num);
}

/// %j: JSON.stringify, with a cyclic structure rendering as "[Circular]"
/// instead of the TypeError JSON.stringify itself raises. An undefined result
/// (undefined, a function, a symbol) prints "undefined".
fn void console_emit_json_spec(BuiltinContext* ctx, ConsoleSink sink, TVal* arg) {
    // json_serialize_val implements the rule for a value nested inside a
    // structure, where undefined, a function and a Symbol all become "null" (or,
    // for a Symbol, its raw marker bytes, since JSON.stringify filters Symbols
    // out one level up in json_check_property and this path never sees one).
    // At the ROOT, JSON.stringify instead yields undefined for all three.
    if (arg.is_undefined()) { sink.write("undefined"); return; }
    if (arg.is_string()) {
        HString* s = (HString*)arg.get_heapptr();
        if (s != null && s.is_symbol()) { sink.write("undefined"); return; }
    }
    if (arg.is_lightfunc()) { sink.write("undefined"); return; }
    if (arg.is_object() && arg.get_heapptr() != null) {
        HObject* o = (HObject*)arg.get_heapptr();
        if (o.is_callable()) { sink.write("undefined"); return; }
    }
    // Grows to fit, like JSON.stringify's own buffer: %j has no size limit of
    // its own, and a structure too large to render reports failure rather than
    // printing a truncated fragment that looks like valid JSON.
    StrBuf out;
    out.init(ctx.heap);
    defer out.free();
    JsonSerializeCtx jctx;
    jctx.heap = ctx.heap;
    jctx.vm = ctx.vm;
    jctx.out = &out;
    jctx.indent_level = 0;
    jctx.gap = null;
    jctx.gap_len = 0;
    jctx.depth = 0;
    jctx.replacer_func.set_undefined();
    jctx.prop_keys = null;
    jctx.prop_key_count = 0;
    jctx.has_replacer_array = false;
    jctx.error = false;
    jctx.visited_count = 0;

    bool had_error = ctx.heap.has_error;
    int rc = json_serialize_val(&jctx, arg);

    if (jctx.error || ctx.heap.has_error) {
        // The only failure json_serialize_val raises for a well-formed value is
        // the circular-structure TypeError; swallow it and use the marker.
        ctx.heap.has_error = had_error;
        sink.write("[Circular]");
        return;
    }
    if (rc != 0) {
        sink.write("undefined");
        return;
    }
    sink.write(out.bytes());
}

/// Stdout byte sink for write_cesu8_as_utf8. The udata a PutByteFn must accept
/// is unused here: the destination is a fixed stream, not a caller-owned buffer.
fn void putc_out(char c, void* udata) {
    io::putchar(c);
}

/// Stderr byte sink used by write_cesu8_as_utf8.
fn void eputc(char c, void* udata) {
    io::eprintf("%c", c);
}

/// Mirror of print_tval_ctx that writes to stderr instead of stdout.
fn void print_tval_err_ctx(BuiltinContext* ctx, TVal* val) {
    if (val.is_object() && val.get_heapptr() != null && ctx.vm != null && ctx.heap.call_fn != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        HString* tostr_key = ctx.heap.str(heap::BuiltinStr.TO_STRING);
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
    // ES2015 §18.2.5: parseInt(string, radix), ToString(string) first.
    // The previous fast-path returned fastints directly (skipping ToString) and
    // bailed to NaN for any non-string input, wrong for Number(-0), Number(NaN),
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
    // Radix coercion (ES2015 §18.2.5 step 7: ToInt32).
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

    // Step 2: strip leading StrWhiteSpace (WhiteSpace + LineTerminator).
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

    // Step 4-5: optional sign.
    int sign = 1;
    if (i < blen && (cstr[i] == '+' || cstr[i] == '-')) {
        if (cstr[i] == '-') sign = -1;
        i++;
    }

    // Step 8-10: radix normalisation + 0x prefix.
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

    // Step 11-16: consume digits.
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
    // ES2015 §18.2.4: parseFloat(string), ToString(string) first. The previous
    // direct-call into string_to_double returned NaN for booleans, undefined,
    // null, and objects, wrong because the spec coerces any input type to a
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

    // Strip leading StrWhiteSpace (WhiteSpace + LineTerminator).
    while (i < blen) {
        char c = cstr[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r'
                || c == 0x0B || c == 0x0C) { i++; continue; }
        usz adv = utf8_whitespace_len(cstr, blen, i);
        if (adv > 0) { i += adv; continue; }
        break;
    }

    // Match the longest StrDecimalLiteral prefix (ES2015 §7.1.3.1 Table 10).
    // Grammar: [+-]? (Infinity | DecimalDigits? "." DecimalDigits? Exponent?
    //                  | DecimalDigits Exponent?)
    // Crucially, this does NOT include the "0x"/"0X" hex prefix that
    // StringNumericLiteral (used by ToNumber) accepts, parseFloat rejects hex.
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
        // No digits at all (bare sign, bare '.', or neither), not a number.
        ctx.result.set_number(double::nan);
        return;
    }

    // Optional exponent, only valid once a mantissa digit was seen.
    if (i < blen && (cstr[i] == 'e' || cstr[i] == 'E')) {
        usz exp_save = i;
        usz j = i + 1;
        if (j < blen && (cstr[j] == '+' || cstr[j] == '-')) j++;
        usz exp_digits_start = j;
        while (j < blen && cstr[j] >= '0' && cstr[j] <= '9') j++;
        if (j > exp_digits_start) {
            i = j;
        } else {
            i = exp_save; // malformed exponent, not part of the literal
        }
    }

    // Copy just the matched StrDecimalLiteral prefix into a bounded, NUL-terminated
    // buffer before handing it to strtod, passing `&cstr[start]` directly would let
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

    // If Type(x) is not String, return x unchanged.
    // eval is registered as a lightfunc (register_simple_builtin), so when
    // it is reached via Heap.call_fn (vm_call_fn_impl's Case 1) rather than
    // an ordinary CALL, `ctx.result` aliases `temp_regs[0]`, which was
    // pre-seeded with a raw, non-incref'd copy of `this`, the same hazard
    // documented on builtin_iterator_proto_symbol_iter. tval_copy_ref would
    // decref that borrowed `this` out from under the caller. A bare incref
    // (nothing to decref: the stale bits were never independently owned)
    // is correct in every dispatch path, including the ordinary CALL path
    // where `*ctx.result` starts undefined (decrefing undefined is already
    // a no-op there, so this is a strict improvement, not just a guard).
    if (!arg.is_string()) {
        if (arg.is_heap_allocated()) {
            void* ptr = arg.get_heapptr();
            if (ptr != null) { ((types::HeapHeader*)ptr).incref(); }
        }
        *ctx.result = *arg;
        return;
    }

    HString* source = (HString*)arg.get_heapptr();
    char* src_cstr = source.get_cstr();
    usz src_len = source.blen;

    // Direct eval shares the caller's lexical environment (checked again,
    // and used to pick env_for_eval, below), including any `__super__`
    // hidden binding, so `super.x`/`super[x]` may legally appear in the
    // source. Detect this before compiling so the eval CompilerContext can
    // permit the syntax (see compile_eval's allow_super doc comment).
    //
    // Per ES2022 §8.7.1, direct eval ALSO inherits the caller's
    // PrivateEnvironment, i.e. private field/method references inside the
    // eval body resolve against the calling class body's declared names.
    // The caller (the function whose body contains `eval(...)`) stashed a
    // snapshot of its private-name table into its CompiledFunction when it
    // finished compiling (see context.c3 CompilerContext.finish). At runtime
    // we read that snapshot here and hand it to compile_eval, which adopts
    // it into the fresh eval CompilerContext, after that the eval body's
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
    bool caller_allows_super_call = false;
    void* parent_priv_names = null;
    uint parent_priv_count = 0;
    bool caller_super_is_home_object = false;
    bool caller_forbids_arguments = false;
    if (precheck_act_count > 0) {
        precheck_caller = &precheck_vm.activations[precheck_act_count - 1];
        caller_has_direct_eval = (precheck_caller.flags & vm::ACT_FLAG_DIRECT_EVAL) != 0;
        if (caller_has_direct_eval) {
            // precheck_caller.func is the caller's CompiledFunction template
            // (for natfunc frames, like this builtin itself, the func slot
            // isn't a CompiledFunction, so guard the cast). For compiled
            // function frames (the only paths that set ACT_FLAG_DIRECT_EVAL),
            // func is always the corresponding CompiledFunction*, see
            // vm_core.c3 act_creation paths and how `target` is read.
            // The cast is safe because has_direct_eval is a function-level
            // flag that's only ever set on compiled function bodies.
            CompiledFunction* caller_cf = (CompiledFunction*)precheck_caller.func;
            if (caller_cf != null) {
                if (caller_cf.is_eval_fn()) {
                    // Nested direct eval: the immediate caller is itself an
                    // eval body (which always sets is_global). new.target is
                    // legal in the inner eval exactly when it was legal in the
                    // enclosing eval, inherit that recorded permission rather
                    // than mis-classifying the eval CF as global code.
                    caller_direct_eval_in_function = caller_cf.eval_allows_new_target();
                } else if (!caller_cf.is_arrow() && !caller_cf.is_global_fn()) {
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
                // super() (not super.x) is additionally permitted only when the
                // enclosing function is a derived-class constructor, its
                // FunctionEnvironmentRecord carries __super__ (the superclass
                // constructor) and an uninitialised this-binding. See
                // compile_eval's allow_super_call parameter.
                if (caller_cf.is_derived_ctor()) {
                    caller_allows_super_call = true;
                }
                caller_super_is_home_object = caller_cf.super_is_home_object();
                parent_priv_names = caller_cf.eval_private_names;
                parent_priv_count = caller_cf.eval_private_name_count;
                // ContainsArguments (ES2022 §15.7.10 step 14): a direct eval
                // called from a class field/static initializer or static
                // block, or from another eval body that itself inherited
                // the restriction (forbid_arguments is stamped on every
                // compiled body, including nested eval CFs), must reject a
                // bare `arguments` in its own source at eval-call time.
                caller_forbids_arguments = caller_cf.forbid_arguments();
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
                                                    caller_super_is_home_object,
                                                    caller_allows_super_call,
                                                    caller_forbids_arguments);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
        // Compilation failed: throw SyntaxError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.syntax_err_proto;
            HString* msg_key = ctx.heap.str(heap::BuiltinStr.MESSAGE);
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
    // Reuse the activation captured in the precheck above, by the time we
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
    // in the (base_reg - 1) slot, we overwrite it here since the CALL
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

/// $262.evalScript(src), the test262 host hook that runs `src` as an
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
            HString* msg_key = ctx.heap.str(heap::BuiltinStr.MESSAGE);
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
    HObject* pending = null;
    bool? ok = eval_vm.execute_module_nested(func, ctx.global_env, &pending);
    if (catch err = ok) {
        ctx.result.set_undefined();
        return;
    }
    if (!ok) {
        // Uncaught throw inside the script, propagate it as this builtin's
        // own throw (execute_module_nested left it in heap.error_value).
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        eval_vm.has_error = false;
        return;
    }
    if (pending != null) {
        // The evaluated script suspended on top-level await and this call
        // could not pump the microtask queue to completion because it was
        // itself reached from inside a drain (e.g. $262.evalScript invoked
        // from a .then() callback). Nothing here needs to observe its
        // eventual settlement, the pinning reference handed off is simply
        // released, matching the not-draining path's own transient pin.
        ctx.heap.decref(pending.as_header());
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

alias UriExtraUnreservedFn = fn bool(char);

/// Shared Encode (ES §19.2.6.5) body driving both encodeURI and
/// encodeURIComponent, they differ only in which ASCII punctuation passes
/// through unescaped (`extra_unreserved`). Walks `str` by UTF-16 code unit
/// (internal storage is CESU-8: every surrogate half is its own 3-byte
/// sequence, see hstring's CESU-8 utilities), pairs surrogates back into
/// astral codepoints, UTF-8-encodes each codepoint's bytes as %XX triplets,
/// and throws URIError on any lone (unpaired) surrogate, Encode is defined
/// over Unicode code points, and a lone surrogate is not one.
fn void uri_encode(BuiltinContext* ctx, HString* str, UriExtraUnreservedFn extra_unreserved) {
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65500) {
        char c = data[i];
        if (c < 0x80 && (uri_is_unreserved(c) || extra_unreserved(c))) {
            out[offset++] = c;
            i++;
            continue;
        }
        uint seq_len = hstring::utf16_unit_byte_len(data, i);
        uint cp = hstring::decode_codepoint(data, i);
        if (hstring::is_high_surrogate(cp)) {
            if (i + seq_len < len) {
                uint next_len = hstring::utf16_unit_byte_len(data, i + seq_len);
                uint low = hstring::decode_codepoint(data, i + seq_len);
                if (hstring::is_low_surrogate(low)) {
                    uint astral = hstring::surrogates_to_codepoint(cp, low);
                    char[4] obuf;
                    uint n = hstring::encode_codepoint(astral, obuf[:4]);
                    for (uint k = 0; k < n; k++) uri_encode_byte(&out, &offset, obuf[k]);
                    i += seq_len + next_len;
                    continue;
                }
            }
            builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
            return;
        }
        if (hstring::is_low_surrogate(cp)) {
            builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
            return;
        }
        char[4] obuf;
        uint n = hstring::encode_codepoint(cp, obuf[:4]);
        for (uint k = 0; k < n; k++) uri_encode_byte(&out, &offset, obuf[k]);
        i += seq_len;
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

fn bool uri_extra_reserved(char c) {
    return c == ';' || c == ',' || c == '/' || c == '?' || c == ':' ||
           c == '@' || c == '&' || c == '=' || c == '+' || c == '$' || c == '#';
}

fn bool uri_extra_none(char c) {
    return false;
}

/// encodeURI (ES §19.2.6.5)
fn void builtin_encode_uri(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(ctx.heap.str(heap::BuiltinStr.UNDEFINED));
        return;
    }
    HString* str = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
    if (ctx.should_throw) return;
    if (str == null) {
        ctx.result.set_string(ctx.heap.str(heap::BuiltinStr.EMPTY));
        return;
    }
    uri_encode(ctx, str, &uri_extra_reserved);
}

/// encodeURIComponent (ES §19.2.6.5)
fn void builtin_encode_uri_component(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(ctx.heap.str(heap::BuiltinStr.UNDEFINED));
        return;
    }
    HString* str = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
    if (ctx.should_throw) return;
    if (str == null) {
        ctx.result.set_string(ctx.heap.str(heap::BuiltinStr.EMPTY));
        return;
    }
    uri_encode(ctx, str, &uri_extra_none);
}

/// Decode a single %XX-escaped UTF-8 sequence starting at `data[i]` (which
/// must be '%') into a Unicode code point. Validates continuation bytes,
/// rejects overlong encodings, out-of-range code points (> U+10FFFF), and
/// lone surrogates (a valid code point can never be a surrogate half, RFC
/// 3629 / ES §19.2.6.6 Decode step 7.f-g). On success, sets `*cp` and
/// `*consumed` (number of source bytes eaten, i.e. 3 * byte-sequence-length)
/// and returns true. On any malformed input returns false and leaves the
/// outputs unspecified, the caller throws URIError.
fn bool uri_decode_sequence(char[] data, uint i, uint len, uint* cp, uint* consumed) {
    if (i + 2 >= len) return false;
    int d1 = hex_digit_val(data[i + 1]);
    int d2 = hex_digit_val(data[i + 2]);
    if (d1 < 0 || d2 < 0) return false;
    uint first = (uint)((d1 << 4) | d2);
    if (first < 0x80) {
        *cp = first;
        *consumed = 3;
        return true;
    }
    if (first < 0xC2 || first > 0xF4) return false;  // continuation byte or invalid lead
    uint seq_len;
    if (first < 0xE0) { seq_len = 2; }
    else if (first < 0xF0) { seq_len = 3; }
    else { seq_len = 4; }
    if (i + 3 * seq_len > len) return false;
    char[4] bytes;
    bytes[0] = (char)first;
    for (uint j = 1; j < seq_len; j++) {
        if (data[i + 3 * j] != '%') return false;
        int h1 = hex_digit_val(data[i + 3 * j + 1]);
        int h2 = hex_digit_val(data[i + 3 * j + 2]);
        if (h1 < 0 || h2 < 0) return false;
        char b = (char)((h1 << 4) | h2);
        if (b < 0x80 || b > 0xBF) return false;
        bytes[j] = b;
    }
    // Continuation bytes are already structurally valid at this point, so
    // decode_codepoint can only differ from a genuine decode by rejecting an
    // overlong encoding (which it also reports as UNICODE_REPLACEMENT, the
    // same sentinel a *legitimately* decoded U+FFFD would produce). Detect
    // overlong directly instead of relying on that sentinel, so decoding an
    // actual "%EF%BF%BD" (U+FFFD) is not mistaken for malformed input.
    uint decoded = ((first & (0xFF >> seq_len)) << (6 * (seq_len - 1)));
    for (uint j = 1; j < seq_len; j++) {
        decoded |= ((uint)bytes[j] & 0x3F) << (6 * (seq_len - 1 - j));
    }
    uint min_cp = (seq_len == 2) ? 0x80u : (seq_len == 3) ? 0x800u : 0x1_0000u;
    if (decoded < min_cp || decoded > 0x10_FFFF) return false;  // overlong / out-of-range
    if (hstring::is_surrogate(decoded)) return false;  // not a valid code point
    *cp = decoded;
    *consumed = 3 * seq_len;
    return true;
}

/// Write `cp` into `out` at `*offset` as a CESU-8-canonical UTF-16 code-unit
/// sequence: astral code points split into a surrogate pair (each half its
/// own 3-byte sequence), everything else via plain UTF-8, matching the
/// storage format every interned HString must be in.
fn void uri_decode_emit(char* out, usz* offset, uint cp) {
    char[6] buf;
    uint n = hstring::encode_codepoint_cesu8(cp, buf[:6]);
    for (uint k = 0; k < n; k++) out[(*offset)++] = buf[k];
}

/// Shared Decode (ES §19.2.6.6) body for decodeURI/decodeURIComponent. They
/// differ only in which percent-triplets are left un-decoded (reserved URI
/// characters, decodeURI only).
fn void uri_decode(BuiltinContext* ctx, HString* str, bool preserve_reserved) {
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65500) {
        if (data[i] != '%') {
            out[offset++] = data[i];
            i++;
            continue;
        }
        if (preserve_reserved) {
            // Peek the raw byte value without full sequence validation, to
            // decide whether this triplet is a reserved URI character that
            // decodeURI must leave un-decoded (as literal "%XX" text).
            if (i + 2 < len) {
                int d1 = hex_digit_val(data[i + 1]);
                int d2 = hex_digit_val(data[i + 2]);
                if (d1 >= 0 && d2 >= 0) {
                    uint raw = (uint)((d1 << 4) | d2);
                    if (raw == 0x23 || raw == 0x24 || raw == 0x26 || raw == 0x2B ||
                        raw == 0x2C || raw == 0x2F || raw == 0x3A || raw == 0x3B ||
                        raw == 0x3D || raw == 0x3F || raw == 0x40) {
                        out[offset++] = '%';
                        out[offset++] = data[i + 1];
                        out[offset++] = data[i + 2];
                        i += 3;
                        continue;
                    }
                }
            }
        }
        uint cp;
        uint consumed;
        if (!uri_decode_sequence(data, i, len, &cp, &consumed)) {
            builtin_throw_no_result_change(ctx, ctx.heap.uri_err_proto, "URI malformed");
            return;
        }
        uri_decode_emit(&out, &offset, cp);
        i += consumed;
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.set_string(result);
}

/// decodeURI (ES §19.2.6.6)
fn void builtin_decode_uri(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(ctx.heap.str(heap::BuiltinStr.UNDEFINED));
        return;
    }
    HString* str = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
    if (ctx.should_throw) return;
    if (str == null) {
        ctx.result.set_string(ctx.heap.str(heap::BuiltinStr.EMPTY));
        return;
    }
    uri_decode(ctx, str, true);
}

/// decodeURIComponent (ES §19.2.6.6)
fn void builtin_decode_uri_component(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_string(ctx.heap.str(heap::BuiltinStr.UNDEFINED));
        return;
    }
    HString* str = builtin_to_string_vm(ctx, &ctx.regs[ctx.base_reg]);
    if (ctx.should_throw) return;
    if (str == null) {
        ctx.result.set_string(ctx.heap.str(heap::BuiltinStr.EMPTY));
        return;
    }
    uri_decode(ctx, str, false);
}
