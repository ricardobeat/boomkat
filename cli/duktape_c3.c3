/// Plain JavaScript runner: compile a source file and execute it.
///
/// This is the normal way to run a `.js` file. For bytecode disassembly,
/// instruction tracing, and other inspection flags, use the `duktape_c3_debug`
/// binary (`cli/duktape_c3_debug.c3`). For test262, use `test262_runner
/// --worker` or `python3 scripts/run_test262.py --single <path>` — this binary
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
    // Hidden: exercise the JIT core (emit -> MAP_JIT execute -> fastint add).
    if (args.len > 1 && args[1] == "--jit-selftest") {
        types::TVal[4] regs;
        regs[1].set_fastint(1000);
        regs[2].set_fastint(337);
        ulong r = vm::jit_selftest_add(&regs[0], 1, 2);
        types::TVal rv; rv.bits = r;
        io::printfn("jit add = %d (expect 1337), is_fastint=%s", rv.get_fastint(), rv.is_fastint());
        return 0;
    }
    // Hidden: prove the JIT->C call round-trip by invoking a real compiled fib
    // through vm_call_fn_impl from emitted native code, comparing to the interp.
    if (args.len > 1 && args[1] == "--jit-call-selftest") {
        Heap*? jhp = heap::create(null, null, null, null, null);
        if (catch h = jhp) { io::eprintfn("Failed heap"); return 1; }
        defer jhp.destroy();
        Vm*? jv = vm::vm_create(jhp);
        if (catch err = jv) { io::eprintfn("VM failed"); return 1; }
        defer vm::vm_destroy(jv);
        char[] jsrc = (char[])"function fib(n){ if(n<=1) return n; return fib(n-1)+fib(n-2); } fib(1);";
        Lexer jlex = lexer::lexer_init(jsrc, jhp);
        CompiledFunction*? jfunc = compiler::compile(&jlex, jhp);
        CompiledFunction* jf;
        if (try ff = jfunc) { jf = ff; } else { io::eprintfn("compile failed"); return 1; }
        TVal? jr = jv.execute(jf);
        if (catch e = jr) { io::eprintfn("exec failed"); return 1; }
        // Look up the global `fib` function object.
        HString* fib_key = vm::intern_string(jv, (char[])"fib");
        TVal? fib_tv_opt = jv.global_env.bindings.get_prop((void*)fib_key);
        TVal fib_tv;
        if (try t = fib_tv_opt) { fib_tv = t; } else { io::eprintfn("no fib"); return 1; }
        // Interpreter reference: fib(10) via vm_call_fn_impl directly.
        types::TVal[1] argbuf;
        argbuf[0].set_fastint(10);
        types::TVal undef; undef.set_undefined();
        types::TVal interp_r = vm::vm_call_fn_impl((void*)jv, fib_tv, &argbuf[0], 1, undef);
        // JIT round-trip: same call, but the BLR to vm_call_fn_impl is emitted.
        argbuf[0].set_fastint(10);
        ulong jit_bits = vm::jit_selftest_call((void*)jv, fib_tv.bits, &argbuf[0]);
        types::TVal jit_r; jit_r.bits = jit_bits;
        io::printfn("interp fib(10) = %d ; jit-roundtrip fib(10) = %d ; match=%s",
            interp_r.get_fastint(), jit_r.get_fastint(), interp_r.bits == jit_r.bits);
        return interp_r.bits == jit_r.bits ? 0 : 1;
    }
    // Hidden: compile fib's body to native code and run fib(10) through the
    // JIT'd body, comparing to the interpreter.
    if (args.len > 1 && args[1] == "--jit-fib-selftest") {
        Heap*? jhp = heap::create(null, null, null, null, null);
        if (catch h = jhp) { io::eprintfn("Failed heap"); return 1; }
        defer jhp.destroy();
        Vm*? jv = vm::vm_create(jhp);
        if (catch err = jv) { io::eprintfn("VM failed"); return 1; }
        defer vm::vm_destroy(jv);
        char[] jsrc = (char[])"function fib(n){ if(n<=1) return n; return fib(n-1)+fib(n-2); } fib(1);";
        Lexer jlex = lexer::lexer_init(jsrc, jhp);
        CompiledFunction*? jfunc = compiler::compile(&jlex, jhp);
        CompiledFunction* jf;
        if (try ff = jfunc) { jf = ff; } else { io::eprintfn("compile failed"); return 1; }
        TVal? jr = jv.execute(jf);
        if (catch e = jr) { io::eprintfn("exec failed"); return 1; }
        HString* fib_key = vm::intern_string(jv, (char[])"fib");
        TVal? fib_tv_opt = jv.global_env.bindings.get_prop((void*)fib_key);
        TVal fib_tv;
        if (try t = fib_tv_opt) { fib_tv = t; } else { io::eprintfn("no fib"); return 1; }
        HObject* fib_obj = (HObject*)fib_tv.get_heapptr();
        CompiledFunction* fib_body = (*fib_obj.extra_ptr()).func.comp_func;
        // JIT-compile fib's body.
        vm::JitCode jc = vm::jit_compile(fib_body);
        if (jc.body == null) { io::eprintfn("jit_compile bailed"); return 1; }
        // Interpreter reference.
        types::TVal[1] iargs; iargs[0].set_fastint(10);
        types::TVal undef; undef.set_undefined();
        types::TVal interp_r = vm::vm_call_fn_impl((void*)jv, fib_tv, &iargs[0], 1, undef);
        // JIT body: register file with regs[0]=n. fib_body.num_regs slots.
        types::TVal[64] jregs;
        for (uint i = 0; i < 64; i++) jregs[i].set_undefined();
        jregs[0].set_fastint(10);
        ulong jit_bits = jc.body((void*)jv, &jregs[0], fib_tv.bits);
        types::TVal jit_r; jit_r.bits = jit_bits;
        bool ok = interp_r.bits == jit_r.bits;
        io::printfn("interp fib(10) = %d ; jit-body fib(10) = %d ; match=%s",
            interp_r.get_fastint(), jit_r.is_fastint() ? jit_r.get_fastint() : -999, ok);
        return ok ? 0 : 1;
    }
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
