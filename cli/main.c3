module tinyduck_cli;

import tinyduck::compiler;
import tinyduck::vm;
import tinyduck::heap;
import tinyduck::lexer;
import tinyduck::bytecode;
import tinyduck::types;
import std::io;
import libc;

fn int main(String[] args) {
    if (args.len < 2) {
        io::eprintfn("usage: tinyduck <script>");
        return 1;
    }
    String path = args[1];

    // Load source
    char[]? src = file::load_temp(path);
    if (catch err = src) {
        io::eprintfn("error: cannot read '%s'", path);
        return 1;
    }

    // Create engine
    Heap*? hp = heap::create();
    if (catch h = hp) {
        io::eprintfn("error: failed to create heap");
        return 1;
    }
    defer hp.destroy();

    Vm*? v = vm::vm_create(hp);
    if (catch err = v) {
        io::eprintfn("error: failed to create VM");
        return 1;
    }
    defer vm::vm_destroy(v);

    // Compile
    Lexer lex = lexer::lexer_init(src, hp);
    CompiledFunction*? func = compiler::compile(&lex, hp);
    CompiledFunction* f;
    if (try ff = func) {
        f = ff;
    } else {
        io::eprintfn("Compile failed");
        return 1;
    }

    // Execute (microtasks are drained inside vm.execute)
    TVal? result = v.execute(f);
    if (catch err = result) {
        io::eprintfn("VM error: %s", err);
        return 1;
    }

    return 0;
}
