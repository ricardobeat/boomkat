module test_vm;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::env;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;
import duktape::esm;
import std::io;
import libc;

fn int main(String[] args) {
    bool module_mode = false;
    String? path_opt;

    for (uint i = 1; i < (uint)args.len; i++) {
        String a = args[i];
        if (a == "-m" || a == "--module") {
            module_mode = true;
        } else if (a.len > 0 && a.ptr[0] != '-') {
            path_opt = a;
        }
    }

    String path;
    if (try p = path_opt) {
        path = p;
    } else {
        path = "test/simple.js";
    }

    char[]? source = file::load_temp(path);
    if (catch err = source) { io::eprintfn("Failed to read"); return 1; }

    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch h = hp) { io::eprintfn("Failed heap"); return 1; }
    defer hp.destroy();

    Vm*? v = vm::vm_create(hp);
    if (catch err = v) { io::eprintfn("VM failed"); return 1; }
    defer vm::vm_destroy(v);

    if (module_mode) {
        char[] module_name = path;
        esm::ModuleDef*? mod_opt = esm::resolve_module(hp, module_name, "");
        if (catch err = mod_opt) { io::eprintfn("module resolve failed"); return 1; }
        esm::ModuleDef* mod = mod_opt;
        if (mod == null) { io::eprintfn("module resolve returned null"); return 1; }
        if (!esm::execute_module(hp, v, mod)) {
            if (v.heap.has_error) {
                // Print uncaught error value
            } else {
                io::eprintfn("module execute failed");
            }
            return 1;
        }
        return 0;
    }

    Lexer lex = lexer::lexer_init(source, hp);
    CompiledFunction*? func = compiler::compile(&lex, hp);
    CompiledFunction* f;
    if (try ff = func) { f = ff; } else { io::eprintfn("Compile failed"); return 1; }

    TVal? result = v.execute(f);
    if (catch err = result) { io::eprintfn("VM error: %s (at execute)", err); return 1; }
    return 0;
}
