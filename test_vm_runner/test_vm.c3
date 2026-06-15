module test_vm;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::env;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;
import duktape::hstring;
import std::io;
import libc;

fn void dump_func(CompiledFunction* f, int depth) {
    String indent = depth == 0 ? "" : "  ";
    for (int d = 0; d < depth; d++) {
        io::printf("  ");
    }
    io::printfn("=== FUNC depth=%d (%d insns, %d regs, %d consts, %d inner) ===", depth, f.code_count, f.num_regs, f.const_count, f.inner_count);
    for (uint i = 0; i < f.code_count; i++) {
        char[128] buf;
        buf[0] = 0;
        usz len = f.code[i].disassemble(&buf);
        buf[len] = 0;
        for (int d = 0; d < depth; d++) {
            io::printf("  ");
        }
        for (usz j = 0; j < len; j++) { io::putchar(buf[j]); }
        io::putchar('\n');
    }
    for (uint i = 0; i < f.inner_count; i++) {
        CompiledFunction* inner = f.inner_funcs[i];
        dump_func(inner, depth + 1);
    }
}

fn int main(String[] args) {
    String path = args.len > 1 ? args[1] : "test/simple.js";
    char[]? source = file::load_temp(path);
    if (catch err = source) { io::eprintfn("Failed to read"); return 1; }

    Heap*? hp = heap::create();
    if (catch h = hp) { io::eprintfn("Failed heap"); return 1; }
    defer hp.destroy();

    Vm*? v = vm::vm_create(hp);
    if (catch err = v) { io::eprintfn("VM failed"); return 1; }
    defer vm::vm_destroy(v);

    Lexer lex = lexer::lexer_init(source, hp);
    CompiledFunction*? func = compiler::compile(&lex, hp);
    CompiledFunction* f;
    if (try ff = func) { f = ff; } else { io::eprintfn("Compile failed"); return 1; }

    // Dump bytecode recursively
    dump_func(f, 0);

    io::printfn("=== EXECUTING ===");

    TVal? result = v.execute(f);
    if (catch err = result) { io::eprintfn("VM error: %s (at execute)", err); return 1; }
    return 0;
}
