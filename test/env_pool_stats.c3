// Environment-pool accounting harness for plans/085. Runs a JS workload, then
// prints the heap's environment counters so a fixture can observe retention.
// The workload itself lives in a .js file so the same source drives both the
// normal runner and this counter oracle.
module env_pool_stats;

import boomkat::compiler;
import boomkat::vm;
import boomkat::heap;
import boomkat::lexer;
import boomkat::types;
import boomkat::bytecode;
import std::io;

fn int main(String[] args) {
    if (args.len < 2) {
        io::eprintfn("usage: env_pool_stats <js_file>");
        return 1;
    }
    String path = args[1];
    char[]? source_opt = file::load_temp(path);
    if (catch err = source_opt) {
        io::eprintfn("failed to read %s", path);
        return 1;
    }
    char[] source = source_opt;

    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch err = hp) { io::eprintfn("heap create failed"); return 1; }
    defer hp.destroy();

    Vm*? v = vm::vm_create(hp);
    if (catch err = v) { io::eprintfn("vm create failed"); return 1; }
    defer vm::vm_destroy(v);

    Lexer lex = lexer::lexer_init(source, hp, (char[])path);
    defer lex.free_arena();
    lex.skip_hashbang();
    CompiledFunction*? func_opt = compiler::compile(&lex, hp);
    CompiledFunction* f;
    if (try ff = func_opt) {
        f = ff;
    } else {
        io::eprintfn("SyntaxError: %s (line %d)", (ZString)&lex.err_msg[0], lex.err_line);
        return 1;
    }

    TVal? result = v.execute(f);
    hp.drain_microtasks((void*)v);
    if (catch err = result) {
        io::eprintfn("VM error at execute");
        return 1;
    }

    // A quiescent collection proves what the pool still holds after the
    // workload's scopes have all exited.
    hp.safepoint_gc();

    io::printfn("env_alloc_count=%d env_live_cells=%d env_block_count=%d env_bytes_reserved=%d env_peak_bytes_reserved=%d",
        (long)hp.env_alloc_count, (long)hp.env_live_cells, (long)hp.env_block_count,
        (long)hp.env_bytes_reserved, (long)hp.env_peak_bytes_reserved);
    return 0;
}
