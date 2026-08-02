/// Plain JavaScript runner: compile a source file and execute it.
///
/// This is the normal way to run a `.js` file. For bytecode disassembly,
/// instruction tracing, and other inspection flags, use the `duktape_c3_debug`
/// binary (`cli/duktape_c3_debug.c3`). For test262, use `test262_runner
/// --worker` or `python3 scripts/run_test262.py --single <path>`. This binary
/// is NOT a test262 harness (no assert/Test262Error/includes handling).
module duktape_c3;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::env;
import duktape::hobject;
import duktape::hstring;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;
import duktape::esm;
import std::io;

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
        int rc = esm::run_module_file(mhp, mv, (char[])mpath);
        if (rc != 0) io::eprintfn("module rc=%d", rc);
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

    Lexer lex = lexer::lexer_init(source, hp);
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
    return 0;
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
