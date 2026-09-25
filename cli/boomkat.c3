// Plain JavaScript runner: compile a source file and execute it.
//
// For bytecode disassembly, instruction tracing, and inspection flags, use
// `boomkat_debug` (`cli/boomkat_debug.c3`). For test262, use `test262_runner
// --worker` or `python3 scripts/run_test262.py --single <path>`.
module boomkat;

import boomkat::compiler;
import boomkat::vm;
import boomkat::heap;
import boomkat::addon;
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
    bool force_module = false;
    String path = "<stdin>";
    bool stdin_source = true;
    bool option_ended = false;
    // Local fixtures use __detachArrayBuffer; the library leaves host helpers
    // unregistered so embedders can supply their own host surface.
    vm::test262_host_enabled = true;
    usz i = 1;
    if (i < args.len && (args[i] == "--help" || args[i] == "-h")) {
        print_usage();
        return 0;
    }
    if (i < args.len && args[i] == "--version") {
        io::printfn("boomkat %s", CLI_VERSION);
        return 0;
    }
    if (i < args.len && args[i] == "--module") { force_module = true; i++; }
    if (i < args.len && args[i] == "--") { option_ended = true; i++; }
    if (i < args.len) {
        path = args[i++];
        if (!option_ended && path.len > 0 && path[0] == '-' && path != "-") {
            io::eprintfn("boomkat: unknown option %s", path);
            print_usage_error();
            return 2;
        }
        stdin_source = path == "-";
        if (stdin_source) path = "<stdin>";
    }
    if (i < args.len || (force_module && stdin_source)) {
        io::eprintfn("boomkat: expected one filename%s", force_module ? " after --module" : "");
        print_usage_error();
        return 2;
    }
    if (stdin_source && io::stdin().isatty()) {
        print_usage();
        return 0;
    }

    char[] source;
    if (stdin_source) {
        DString input = dstring::temp_with_capacity(4096);
        char[4096] chunk;
        while (true) {
            sz? read_result = io::stdin().read(chunk[0:chunk.len]);
            sz n;
            if (try got = read_result) { n = got; }
            else { io::eprintfn("boomkat: could not read stdin"); return 1; }
            if (n == 0) break;
            input.append_bytes(chunk[:n]);
        }
        source = (char[])input.str_view();
    } else {
        char[]? loaded = file::load_temp(path);
        if (try data = loaded) { source = data; }
        else { io::eprintfn("boomkat: could not read %s", path); return 1; }
    }

    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch h = hp) { io::eprintfn("boomkat: could not create heap"); return 1; }
    defer hp.destroy();

    Vm*? v = vm::vm_create(hp);
    if (catch err = v) { io::eprintfn("boomkat: could not create VM"); return 1; }
    defer vm::vm_destroy(v);

    hp.set_rejection_tracker(&cli_rejection_tracker, null);

    // The CLI is a trusted host, so it exposes loadAddon(). An embedder that
    // wants a sandbox simply does not call this.
    if (v.global_env != null) addon::enable_loading(hp, v.global_env);

    // Run TypeScript files with type syntax erased at parse time. Route files
    // with top-level import or export through the ESM pipeline regardless of extension.
    bool ts_mode = !stdin_source && has_ts_extension(path);
    if (force_module || (!stdin_source && looks_like_module(source))) {
        int rc = esm::run_module_file(hp, v, (char[])path);
        if (rc == 1 && (hp.has_error || !hp.error_value.is_undefined())) {
            print_uncaught(hp, &hp.error_value);
        } else if (rc != 0) {
            io::eprintfn("boomkat: could not load module %s (code %d)", path, rc);
        }
        if (rc == 0 && unhandled_rejection_count > 0) return 1;
        return rc;
    }

    return run_script_source(hp, v, source, path, ts_mode);
}

const String CLI_VERSION = "0.0.0";

fn void print_usage() {
    io::printn("Usage: boomkat [--module] [FILE | -]");
    io::printn("       boomkat --help | --version");
    io::printn("Run a JavaScript or TypeScript file, or read JavaScript from stdin.");
    io::printn("Use --module to run a file as an ECMAScript module.");
}

fn void print_usage_error() {
    io::eprintfn("Try 'boomkat --help' for usage.");
}

// Compile a script source and run it, reporting compile errors and uncaught
// throws. `ts_mode` selects TypeScript type-stripping at parse time.
fn int run_script_source(Heap* hp, Vm* v, char[] source, String path, bool ts_mode) {
    Lexer lex = lexer::lexer_init(source, hp, (char[])path);
    defer lex.free_arena();
    lex.skip_hashbang();
    lex.ts_mode = ts_mode;
    CompiledFunction*? func = compiler::compile(&lex, hp);
    CompiledFunction* f;
    if (try ff = func) {
        f = ff;
    } else {
        ZString msg = (ZString)&lex.err_msg[0];
        io::eprintfn("%s:%d:%d: SyntaxError: %s", path, lex.err_line, lex.err_col, msg);
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
