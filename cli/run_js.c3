/// Plain JavaScript runner: compile a source file and execute it.
///
/// NOT a test262 harness — no assert/Test262Error/includes handling.
/// For running test262 tests, use `test262_runner --worker` or
/// `test262_runner/run_single_test.sh`.
module run_js;

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
    lex.skip_hashbang();
    CompiledFunction*? func = compiler::compile(&lex, hp);
    CompiledFunction* f;
    if (try ff = func) {
        f = ff;
    } else {
        ZString msg = (ZString)compiler::last_error_msg();
        io::eprintfn("SyntaxError: %s (line %d, col %d)", msg, compiler::last_error_line(), compiler::last_error_col());
        return 1;
    }

    TVal? result = v.execute(f);
    if (catch err = result) {
        io::eprintfn("VM error: %s (at execute)", err);
        if (v.heap.has_error) {
            // Print uncaught error message
            TVal* err_val = &v.heap.error_value;
            if (err_val.is_object()) {
                HObject* err_obj = (HObject*)err_val.get_heapptr();
                if (err_obj != null) {
                    HString* msg_key = (HString*)v.heap.strs[heap::BuiltinStr.MESSAGE];
                    TVal? msg_tv_opt = err_obj.get_prop(msg_key);
                    if (try msg_tv = msg_tv_opt) {
                        if (msg_tv.is_string()) {
                            HString* msg_str = (HString*)msg_tv.get_heapptr();
                            char[] msg_data = msg_str.get_data();
                            io::eprintf("Uncaught: ");
                            for (usz i = 0; i < msg_data.len; i++) io::eprintf("%c", msg_data[i]);
                            io::eprintf("\n");
                        }
                    }
                }
            }
        }
        return 1;
    }
    return 0;
}
