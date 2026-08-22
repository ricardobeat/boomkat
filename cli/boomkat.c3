// Plain JavaScript runner: compile a source file and execute it.
//
// For bytecode disassembly, instruction tracing, and inspection flags, use
// `boomkat_debug` (`cli/boomkat_debug.c3`). For test262, use `test262_runner
// --worker` or `python3 scripts/run_test262.py --single <path>`.
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

// Counts rejections reported by cli_rejection_tracker so the process exits
// non-zero when unhandled rejections occur before completion.
int unhandled_rejection_count = 0;

// Heap.set_rejection_tracker callback. Prints one line per unhandled rejection
// after microtasks drain. Formats directly with print_tval_stderr to avoid
// re-entering user JS or throwing in toString.
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
        // rc 1 means the module body threw and the value is on the error
        // channel; report it the way script mode does, so a module failure
        // says WHAT failed instead of only that it did. rc 2 is a structural
        // load/link failure with no thrown value, which has no more to say.
        if (rc == 1 && (mhp.has_error || !mhp.error_value.is_undefined())) {
            print_uncaught(mhp, &mhp.error_value);
        } else if (rc != 0) {
            io::eprintfn("module rc=%d", rc);
        }
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

    // Run TypeScript files with type syntax erased at parse time. Route files
    // with top-level import or export through the ESM pipeline regardless of extension.
    if (has_ts_extension(path)) {
        return run_with_lexer_ts(hp, v, path);
    }
    if (looks_like_module(source)) {
        int rc = esm::run_module_file(hp, v, (char[])path);
        if (rc != 0) io::eprintfn("module rc=%d", rc);
        // When execution throws (rc 1), print the uncaught error from the heap.
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
        // Print uncaught JS throws via print_uncaught. "VM error:" is reserved
        // for internal engine faults without a JS error value attached.
        if (v.heap.has_error) {
            print_uncaught(v.heap, &v.heap.error_value);
        } else {
            io::eprintfn("VM error: %s (at execute)", err);
        }
        return 1;
    }
    // Fail if any unhandled promise rejections were logged.
    return unhandled_rejection_count > 0 ? 1 : 0;
}

// Parse TypeScript source in ts_mode, then execute as script or ESM module.
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

// True if the path ends in `.ts`, `.mts`, or `.cts` (case-sensitive).
fn bool has_ts_extension(String path) {
    if (path.len >= 3 && path[^3..] == ".ts") return true;
    if (path.len >= 4 && path[^4..] == ".mts") return true;
    if (path.len >= 4 && path[^4..] == ".cts") return true;
    return false;
}

// Scan for top-level `import` or `export` at depth 0, skipping whitespace,
// comments, and string/template literals.
//
// Matches `import`/`export` keywords only at nesting depth 0 so object keys
// inside blocks or parens do not trigger module mode.
//
// `import.meta` is valid at any depth and always signals module code.
// Dynamic `import(...)` is valid in scripts and is excluded.
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
        // Skip string and template literal contents.
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
        // Track nesting depth.
        if (c == '{' || c == '(' || c == '[') { depth++; at_stmt_start = false; i++; continue; }
        if (c == '}' || c == ')' || c == ']') { if (depth > 0) depth--; at_stmt_start = false; i++; continue; }
        // `import.meta` at any depth marks module code. Exclude property chains.
        if (i + 6 < src.len && src[i:6] == "import" && src[i+6] == '.'
            && (i == 0 || (!is_ident_cont(src[i-1]) && src[i-1] != '.'))) {
            return true;
        }
        if (at_stmt_start && depth == 0) {
            // Match `import` or `export` as complete words. `import(` is dynamic import.
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

// Report an uncaught JS exception on stderr as a single line.
//
// Values are formatted directly rather than through vm_to_string to prevent
// user getters or toString methods from throwing or re-entering the VM during unwind.
fn void print_uncaught(Heap* hp, TVal* err_val) {
    // Error objects report as `Uncaught <name>: <message>`, the shape every
    // JS shell prints and that test262 harnesses parse to recover the error
    // type of a `negative:` test.
    if (err_val.is_object()) {
        HObject* obj = (HObject*)err_val.get_heapptr();
        if (obj != null) {
            HString* msg_str = error_message_of(hp, obj);
            HString* name_str = msg_str != null ? error_name_of(hp, obj) : null;
            if (name_str != null) {
                io::eprintf("Uncaught ");
                print_hstring_stderr(name_str);
                io::eprintf(": ");
                print_hstring_stderr(msg_str);
                io::eprintf("\n");
                return;
            }
        }
    }
    io::eprintf("Uncaught: ");
    print_tval_stderr(hp, err_val);
    io::eprintf("\n");
}

// The `message` of a thrown object, own or inherited, when it is a string.
// A thrown array or plain object has none: that absence is what distinguishes
// an error-shaped value from any other object, and reporting
// `Uncaught Array: [object]` for one would be noise, not information.
fn HString* error_message_of(Heap* hp, HObject* obj) {
    HString* msg_key = (HString*)hp.strs[heap::BuiltinStr.MESSAGE];
    TVal? msg_opt = obj.get_prop_proto(msg_key, hp);
    if (try msg_tv = msg_opt) {
        if (msg_tv.is_string()) return (HString*)msg_tv.get_heapptr();
    }
    return null;
}

// The error type name of a thrown object: its `name` property, or failing that
// its `constructor.name` (which is what names host error types such as
// Test262Error). Returns null when neither yields a string.
fn HString* error_name_of(Heap* hp, HObject* obj) {
    HString* name_key = (HString*)hp.strs[heap::BuiltinStr.NAME];
    TVal? name_opt = obj.get_prop_proto(name_key, hp);
    if (try name_tv = name_opt) {
        if (name_tv.is_string()) return (HString*)name_tv.get_heapptr();
    }
    HString* ctor_key = (HString*)hp.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal? ctor_opt = obj.get_prop_proto(ctor_key, hp);
    if (try ctor_tv = ctor_opt) {
        if (ctor_tv.is_object()) {
            HObject* ctor = (HObject*)ctor_tv.get_heapptr();
            if (ctor != null) {
                TVal? cname_opt = ctor.get_prop_proto(name_key, hp);
                if (try cname_tv = cname_opt) {
                    if (cname_tv.is_string()) return (HString*)cname_tv.get_heapptr();
                }
            }
        }
    }
    return null;
}

// Format a single TVal for stderr. Objects print their string `message` property
// when present, or a fallback tag.
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
    // Print the message property for error objects.
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
