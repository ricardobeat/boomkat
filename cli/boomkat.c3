/// Plain JavaScript runner: compile a source file and execute it.
///
/// This is the normal way to run a `.js` file. For bytecode disassembly,
/// instruction tracing, and other inspection flags, use the `boomkat_debug`
/// binary (`cli/boomkat_debug.c3`). For test262, use `test262_runner
/// --worker` or `python3 scripts/run_test262.py --single <path>`. This binary
/// is NOT a test262 harness (no assert/Test262Error/includes handling).
module boomkat;

import boomkat::compiler;
import boomkat::vm;
import boomkat::heap;
import boomkat::env;
import boomkat::hobject;
import boomkat::hstring;
import boomkat::lexer;
import boomkat::types;
import boomkat::bytecode;
import boomkat::esm;
import std::io;

/// Counts the rejections reported by cli_rejection_tracker, so the exit status
/// can be non-zero for a program that otherwise ran to completion. An async
/// failure nobody caught is still a failure.
int unhandled_rejection_count = 0;

/// Heap.set_rejection_tracker callback: print one line per promise that reached
/// the end of the microtask drain rejected and unwatched.
///
/// The reason is formatted with print_tval_stderr for the same reason
/// print_uncaught uses it: a user `toString` could throw or re-enter the VM,
/// and this runs after the program is over.
fn void cli_rejection_tracker(void* heap_raw, void* vm, TVal promise, TVal reason, void* udata) {
    unhandled_rejection_count++;
    Heap* hp = (Heap*)heap_raw;
    io::eprintf("Unhandled promise rejection: ");
    print_tval_stderr(hp, &reason);
    io::eprintf("\n");
}

fn int main(String[] args) {
    vm::test262_host_enabled = true;
    // `--module <path>` drives the full ESM resolve->link->evaluate pipeline.
    if (args.len > 2 && args[1] == "--module") {
        String mpath = args[2];
        Heap*? mhp = heap::create(null, null, null, null, null);
        if (catch h = mhp) { io::eprintfn("Failed heap"); return 1; }
        defer mhp.destroy();
        Vm*? mv = vm::vm_create(mhp);
        if (catch err = mv) { io::eprintfn("VM failed"); return 1; }
        defer vm::vm_destroy(mv);
        mhp.set_rejection_tracker(&cli_rejection_tracker, null);
        int rc = esm::run_module_file(mhp, mv, (char[])mpath);
        if (rc != 0) io::eprintfn("module rc=%d", rc);
        if (rc == 0 && unhandled_rejection_count > 0) return 1;
        return rc;
    }
    String path = args.len > 1 ? args[1] : "test/simple.js";
    char[]? source = file::load_temp(path);
    if (catch err = source) { io::eprintfn("Failed to read"); return 1; }

    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch h = hp) { io::eprintfn("Failed heap"); return 1; }
    defer hp.destroy();

    Vm*? v = vm::vm_create(hp);
    if (catch err = v) { io::eprintfn("VM failed"); return 1; }
    defer vm::vm_destroy(v);

    hp.set_rejection_tracker(&cli_rejection_tracker, null);

    // A `.ts`/`.mts`/`.cts` file runs in TypeScript mode: type syntax is
    // erased at parse time (plan 042). A file whose top level looks like a
    // module (import/export at statement start) routes through the ESM
    // pipeline regardless of extension.
    if (has_ts_extension(path)) {
        return run_with_lexer_ts(hp, v, path);
    }
    if (looks_like_module(source)) {
        int rc = esm::run_module_file(hp, v, (char[])path);
        if (rc != 0) io::eprintfn("module rc=%d", rc);
        // rc 1 means the module body threw and left the value on the error
        // channel. Reporting it here matches the script path's print_uncaught;
        // without it a module-shaped file failing at runtime printed only
        // "module rc=1", naming neither the error nor where it came from.
        if (rc == 1 && hp.has_error) { print_uncaught(hp, &hp.error_value); }
        if (rc == 0 && unhandled_rejection_count > 0) return 1;
        return rc;
    }

    Lexer lex = lexer::lexer_init(source, hp, (char[])path);
    defer lex.free_arena();
    lex.skip_hashbang();
    CompiledFunction*? func = compiler::compile(&lex, hp);
    CompiledFunction* f;
    if (try ff = func) {
        f = ff;
    } else {
        ZString msg = (ZString)&lex.err_msg[0];
        io::eprintfn("SyntaxError: %s (line %d, col %d)", msg, lex.err_line, lex.err_col);
        return 1;
    }

    TVal? result = v.execute(f);
    hp.drain_microtasks((void*)v);
    if (catch err = result) {
        // An uncaught JS exception (recorded by the THROW opcode or by
        // vm_uncaught_error) and a genuine internal VM fault are different
        // failures, so report exactly one of them: printing both made every
        // ordinary uncaught throw look like an engine crash.
        //
        // "VM error:" is reserved strictly for an internal fault with no JS
        // error attached. Any thrown value, including a non-Error primitive or
        // an object without `.message`, is reported by print_uncaught, so
        // that wording stays a reliable signal of a genuine engine bug.
        if (v.heap.has_error) {
            print_uncaught(v.heap, &v.heap.error_value);
        } else {
            io::eprintfn("VM error: %s (at execute)", err);
        }
        return 1;
    }
    // A program that completed but left a rejected promise nobody watched
    // still failed; cli_rejection_tracker has already said so on stderr.
    return unhandled_rejection_count > 0 ? 1 : 0;
}

/// Run a TypeScript source file: parse in ts_mode, then execute the script
/// (or the ESM pipeline when the file is module-shaped).
fn int run_with_lexer_ts(Heap* hp, Vm* v, String path) {
    char[]? source = file::load_temp(path);
    if (catch err = source) { io::eprintfn("Failed to read"); return 1; }
    if (looks_like_module(source)) {
        int rc = esm::run_module_file(hp, v, (char[])path);
        if (rc != 0) io::eprintfn("module rc=%d", rc);
        if (rc == 0 && unhandled_rejection_count > 0) return 1;
        return rc;
    }
    Lexer lex = lexer::lexer_init(source, hp, (char[])path);
    defer lex.free_arena();
    lex.skip_hashbang();
    lex.ts_mode = true;
    CompiledFunction*? func = compiler::compile(&lex, hp);
    CompiledFunction* f;
    if (try ff = func) {
        f = ff;
    } else {
        ZString msg = (ZString)&lex.err_msg[0];
        io::eprintfn("SyntaxError: %s (line %d, col %d)", msg, lex.err_line, lex.err_col);
        return 1;
    }
    TVal? result = v.execute(f);
    hp.drain_microtasks((void*)v);
    if (catch err = result) {
        if (v.heap.has_error) {
            print_uncaught(v.heap, &v.heap.error_value);
        } else {
            io::eprintfn("VM error: %s (at execute)", err);
        }
        return 1;
    }
    return unhandled_rejection_count > 0 ? 1 : 0;
}

/// True if the path ends in `.ts`, `.mts`, or `.cts` (case-sensitive, like
/// TypeScript itself).
fn bool has_ts_extension(String path) {
    if (path.len >= 3 && path[^3..] == ".ts") return true;
    if (path.len >= 4 && path[^4..] == ".mts") return true;
    if (path.len >= 4 && path[^4..] == ".cts") return true;
    return false;
}

/// Cheap top-level detection: scan for `import` or `export` at a
/// statement-start position at brace/paren/bracket depth 0, skipping
/// whitespace and single-line/block comments. Anything false-positive here
/// just routes through the module pipeline, which handles a script-shaped
/// module file (no imports/exports) fine.
///
/// ES module `import`/`export` declarations are only legal at the top level
/// of module code, never inside a brace/paren/bracket nesting, so we track
/// nesting depth (`{` / `(` / `[` openers and closers) and only match the
/// keywords at depth 0. Without that gate, a plain script containing a
/// multi-line object literal with `{ export: 1, import: 2 }` at line starts
/// would route through the ESM pipeline (typescript 5.4.5's bundle).
///
/// `import.meta` is module-only too, but as an expression it is valid at any
/// nesting depth, so it is matched wherever it appears (`import` is a
/// reserved word, so `import` followed by `.` is never legal script syntax;
/// `x.import.meta` property chains are excluded by the preceding-dot check).
///
/// `import` immediately followed by `(` is a dynamic import() expression,
/// legal in classic scripts, and does not make a file a module. String and
/// template literal contents are skipped so quoted text cannot match; regex
/// literals are not lexed (telling them from division needs full expression
/// context), so a regex containing the literal text can still false-positive.
fn bool looks_like_module(char[] src) {
    usz i = 0;
    bool at_stmt_start = true;
    int depth = 0;
    while (i < src.len) {
        char c = src[i];
        if (c == '\n') { at_stmt_start = true; i++; continue; }
        if (c == ' ' || c == '\t' || c == '\r') { i++; continue; }
        // Line comment
        if (i + 1 < src.len && c == '/' && src[i+1] == '/') {
            while (i < src.len && src[i] != '\n') i++;
            continue;
        }
        // Block comment
        if (i + 1 < src.len && c == '/' && src[i+1] == '*') {
            i += 2;
            while (i + 1 < src.len && !(src[i] == '*' && src[i+1] == '/')) i++;
            if (i + 1 < src.len) i += 2;
            continue;
        }
        // String / template literal: skip to the closing quote so its
        // contents cannot match. Escapes are honored; a template's ${}
        // interpolation is skipped wholesale (its code is not scanned).
        if (c == '"' || c == '\'' || c == '`') {
            char quote = c;
            i++;
            while (i < src.len && src[i] != quote) {
                if (src[i] == '\\' && i + 1 < src.len) i++;
                i++;
            }
            if (i < src.len) i++;
            at_stmt_start = false;
            continue;
        }
        // Track nesting so a brace/paren/bracket at statement start does
        // not count as a module-level position. The opener itself is not a
        // statement-start token for `import`/`export`, but the FIRST token
        // inside the new nesting is, and it must be at depth 1, not 0.
        if (c == '{' || c == '(' || c == '[') { depth++; at_stmt_start = false; i++; continue; }
        if (c == '}' || c == ')' || c == ']') { if (depth > 0) depth--; at_stmt_start = false; i++; continue; }
        // `import.meta` at any depth marks module code (see doc comment).
        // A preceding ident char means this is the tail of a longer word;
        // a preceding `.` means an `x.import.meta` property chain.
        if (i + 6 < src.len && src[i:6] == "import" && src[i+6] == '.'
            && (i == 0 || (!is_ident_cont(src[i-1]) && src[i-1] != '.'))) {
            return true;
        }
        if (at_stmt_start && depth == 0) {
            // Check for `import` or `export` as a whole word at this pos.
            // `import` followed by `(` is dynamic import(), legal in scripts.
            if (i + 6 <= src.len && src[i:6] == "import" &&
                (i + 6 == src.len || !is_ident_cont(src[i+6]))) {
                if (i + 6 >= src.len || src[i+6] != '(') return true;
            }
            if (i + 6 <= src.len && src[i:6] == "export" &&
                (i + 6 == src.len || !is_ident_cont(src[i+6]))) return true;
        }
        at_stmt_start = false;
        i++;
    }
    return false;
}

fn bool is_ident_cont(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '$';
}

/// Report an uncaught JS exception on stderr as a single line.
///
/// `throw` accepts any value, so the thrown value is frequently not an Error:
/// a bare string, a number, or a plain object with no `.message`. Those used to
/// fall through to the internal-fault wording, which described an ordinary
/// JS-level throw as an engine crash and, worse, burned the one phrase that
/// signals a real internal fault.
///
/// Values are formatted directly rather than through vm_to_string: this runs on
/// the error path, and a user-supplied `toString`/`get message` could throw or
/// re-enter the VM while it is already unwinding.
fn void print_uncaught(Heap* hp, TVal* err_val) {
    io::eprintf("Uncaught: ");
    print_tval_stderr(hp, err_val);
    io::eprintf("\n");
}

/// Format a single TVal for stderr. Objects print their `message` when they
/// have a string one (the Error shape); anything else gets a terse tag, since
/// this is a diagnostic, not a general-purpose inspector.
fn void print_tval_stderr(Heap* hp, TVal* v) {
    switch (v.get_tag()) {
        case types::TValTag.UNDEFINED: io::eprintf("undefined"); return;
        case types::TValTag.NULL_VAL:  io::eprintf("null");      return;
        case types::TValTag.BOOLEAN:   io::eprintf(v.get_boolean() ? "true" : "false"); return;
        case types::TValTag.FASTINT:   io::eprintf("%d", v.get_fastint()); return;
        case types::TValTag.NUMBER:    io::eprintf("%g", v.get_number()); return;
        case types::TValTag.STRING:    print_hstring_stderr((HString*)v.get_heapptr()); return;
        default: break;
    }
    if (!v.is_object()) {
        io::eprintf("<unknown value>");
        return;
    }
    HObject* obj = (HObject*)v.get_heapptr();
    if (obj == null) {
        io::eprintf("<null object>");
        return;
    }
    // Error-shaped: print the message, matching the long-standing wording for
    // `throw new Error("msg")`.
    HString* msg_key = (HString*)hp.strs[heap::BuiltinStr.MESSAGE];
    TVal? msg_tv_opt = obj.get_prop(msg_key, hp);
    if (try msg_tv = msg_tv_opt) {
        if (msg_tv.is_string()) {
            print_hstring_stderr((HString*)msg_tv.get_heapptr());
            return;
        }
    }
    io::eprintf("[object]");
}

fn void print_hstring_stderr(HString* s) {
    if (s == null) {
        io::eprintf("<null string>");
        return;
    }
    char[] d = s.get_data();
    for (usz i = 0; i < d.len; i++) io::eprintf("%c", d[i]);
}
