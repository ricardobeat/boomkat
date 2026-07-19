/// Duktape C3 port — CLI runner with debug flags.
///
/// Flags (any order, file is the non-flag argument):
///   <js_file>               Run JS file (default)
///   -c, --compile-only       Disassemble bytecode, no execution
///   -t, --trace-vm           Trace every instruction with register values
///   --dump-constants         Include constant pool in bytecode dump
///   -d, --debug              Print stage timing
///   --no-optimize            Disable compiler peephole passes (debug aid)
///   --format json            Structured bytecode output (implies -c)
///   --help                   Show usage
module duktape_c3;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::lexer;
import duktape::bytecode;
import duktape::types;
import duktape::hstring;
import duktape::hobject;
import duktape::esm;
import std::io;
import std::time;

fn void print_usage(String argv0) {
    io::eprintfn("Usage:  %s [flags] <js_file>", argv0);
    io::eprintfn("Flags:");
    io::eprintfn("  -c, --compile-only     Disassemble bytecode, no execution");
    io::eprintfn("  -t, --trace-vm         Trace every instruction (to stderr)");
    io::eprintfn("  --dump-constants       Show constant pool in bytecode dump");
    io::eprintfn("  -d, --debug            Print stage timing");
    io::eprintfn("  -m, --module           Run as ESM module (import/export)");
    io::eprintfn("  --no-optimize          Disable compiler peephole passes (debug aid)");
    io::eprintfn("  --format json          Structured bytecode output (implies -c)");
    io::eprintfn("  --help                 Show this message");
}

fn int main(String[] args) {
    vm::test262_host_enabled = true;
    if (args.len < 2) {
        print_usage(args.len > 0 ? args[0] : "duktape_c3");
        return 1;
    }

    bool debug       = false;
    bool compile_only = false;
    bool trace_vm     = false;
    bool dump_consts  = false;
    bool json_format  = false;
    bool module_mode  = false;
    String? path_opt;

    for (uint i = 1; i < (uint)args.len; i++) {
        String a = args[i];
        if (a == "--help") {
            print_usage(args[0]);
            return 0;
        } else if (a == "-d" || a == "--debug") {
            debug = true;
        } else if (a == "-c" || a == "--compile-only") {
            compile_only = true;
        } else if (a == "-t" || a == "--trace-vm") {
            trace_vm = true;
        } else if (a == "--dump-constants") {
            dump_consts = true;
        } else if (a == "-m" || a == "--module") {
            module_mode = true;
        } else if (a == "--no-optimize") {
            compiler::set_disable_optimize(true);
        } else if (a == "--format" && i + 1 < (uint)args.len && args[i + 1] == "json") {
            json_format = true;
            compile_only = true;
            i++;
        } else if (a == "--format" && i + 1 < (uint)args.len) {
            // Unknown format
            i++;
        } else if (a.len > 0 && a.ptr[0] != '-') {
            path_opt = a;
        } else {
            io::eprintfn("Unknown option: %s", a);
            return 1;
        }
    }

    String path;
    if (try p = path_opt) {
        path = p;
    } else {
        io::eprintfn("No JS file specified\n");
        print_usage(args[0]);
        return 1;
    }

    // ── Load source ──────────────────────────────────────────────────────────
    time::Time t0 = debug ? time::now() : (time::Time)0;
    char[]? source_opt = file::load_temp(path);
    if (catch err = source_opt) {
        io::eprintfn("Failed to read: %s", path);
        return 1;
    }
    char[] source = source_opt;
    if (debug) io::printfn("  load source: %d us", (int)(time::now() - t0));

    // ── Create heap ──────────────────────────────────────────────────────────
    time::Time t1 = debug ? time::now() : (time::Time)0;
    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch err = hp) {
        io::eprintfn("heap::create failed");
        return 1;
    }
    defer hp.destroy();
    if (debug) io::printfn("  heap create: %d us", (int)(time::now() - t1));

    // ── Create VM ────────────────────────────────────────────────────────────
    time::Time t2 = debug ? time::now() : (time::Time)0;
    Vm*? v = vm::vm_create(hp);
    if (catch err = v) {
        io::eprintfn("vm::create failed");
        return 1;
    }
    defer vm::vm_destroy(v);
    v.trace = trace_vm;
    if (debug) io::printfn("  vm create:   %d us", (int)(time::now() - t2));

    // ── Compile ──────────────────────────────────────────────────────────────
    time::Time t3 = debug ? time::now() : (time::Time)0;

    if (module_mode) {
        // ESM module mode: resolve → execute (includes linking)
        char[] module_name = path;
        esm::ModuleDef*? mod_opt = esm::resolve_module(hp, module_name, "");
        if (catch err = mod_opt) {
            // Compile error was already printed by resolve_module; just exit.
            return 1;
        }
        esm::ModuleDef* mod = mod_opt;
        if (mod == null) {
            io::eprintfn("module resolve returned null");
            return 1;
        }

        if (debug) io::printfn("  resolve:     %d us", (int)(time::now() - t3));

        time::Time t4 = debug ? time::now() : (time::Time)0;
        v.trace = trace_vm;
        if (!esm::execute_module(hp, v, mod)) {
            if (v.heap.has_error) {
                print_uncaught_error(v.heap, &v.heap.error_value);
            } else {
                io::eprintfn("module execute failed");
            }
            return 1;
        }
        if (debug) io::printfn("  execute:     %d us", (int)(time::now() - t4));
        return 0;
    }

    Lexer lx = lexer::lexer_init(source, hp);
    bytecode::CompiledFunction*? func = compiler::compile(&lx, hp);
    if (catch err = func) {
        char* msg  = compiler::last_error_msg();
        uint  line = compiler::last_error_line();
        uint  col  = compiler::last_error_col();
        usz   msg_len = (usz)((ZString)msg).len();
        if (msg_len > 0) {
            io::eprintfn("%s: compile error at line %d:%d: %s", path, line, col, (ZString)msg);
        } else {
            io::eprintfn("%s: compile error at line %d:%d", path, line, col);
        }
        return 1;
    }
    if (debug) io::printfn("  compile:     %d us", (int)(time::now() - t3));

$if $feature(TRACE_VM):
    // TRACE_VM enabled — disassemble and trace flags work fully. Nothing to do.
$else
    // When -c/-t/--format is requested on a release build, the disassemble
    // bodies and vm trace helpers are no-ops. Notify the user once instead
    // of silently producing empty output.
    if (compile_only || trace_vm || json_format) {
        io::eprintfn("note: -c/-t/--format produce full output only in the trace-enabled CLI.");
        io::eprintfn("      Run `just build-trace` to build `out/duktape_c3_debug` and use that.");
    }
$endif

    if (compile_only && !json_format) {
        io::printn("--- Bytecode ---");
        dump_function(*func);
        for (uint i = 0; i < func.inner_count; i++) {
            dump_inner_tree(func.inner_funcs[i], i, "", dump_consts);
        }
        if (dump_consts) {
            dump_constants_pool(*func);
        }
        io::printn("--- End bytecode ---");
        return 0;
    }

    if (json_format) {
        io::printn("[");
        dump_function_json(*func, 0);
        for (uint i = 0; i < func.inner_count; i++) {
            bytecode::CompiledFunction* inner = func.inner_funcs[i];
            if (inner != null) {
                dump_function_json(*inner, i);
            }
        }
        io::printn("]");
        return 0;
    }

    if (compile_only) {
        // Already handled above
    }

    // ── Execute ──────────────────────────────────────────────────────────────
    time::Time t4 = debug ? time::now() : (time::Time)0;
    TVal? res = v.execute(func);
    if (catch err = res) {
        // If the VM recorded an uncaught JS exception (set by vm_uncaught_error
        // or the THROW opcode), print it as a clean "Uncaught: <message>" line.
        // Otherwise it's a true VM-level fault — show the crash dump.
        if (v.heap.has_error) {
            print_uncaught_error(v.heap, &v.heap.error_value);
        } else {
            io::eprintfn("execute failed: %s", err);
            // Crash dump: dump current instruction and register state
            dump_vm_state(v);
        }
        return 1;
    }
    if (debug) io::printfn("  execute:     %d us", (int)(time::now() - t4));
    return 0;
}

// ============================================================================
// Text bytecode dump
// ============================================================================

/// Dump an inner function and recurse into its own inner functions, labelling
/// each with its dotted path from the top level ("Inner function 1.0.2").
fn void dump_inner_tree(bytecode::CompiledFunction* f, uint idx, String path, bool dump_consts) {
    if (f == null) return;
    char[128] label_buf;
    int n;
    if (path.len == 0) {
        n = (int)(io::bprintf(&label_buf, "%d", idx) ?? label_buf[:0]).len;
    } else {
        n = (int)(io::bprintf(&label_buf, "%s.%d", path, idx) ?? label_buf[:0]).len;
    }
    if (n < 0 || n >= label_buf.len) return;
    String label = (String)label_buf[0:n];
    io::printfn("\n--- Inner function %s ---", label);
    dump_function(*f);
    if (dump_consts) {
        dump_constants_pool(*f);
    }
    for (uint i = 0; i < f.inner_count; i++) {
        dump_inner_tree(f.inner_funcs[i], i, label, dump_consts);
    }
}

fn void dump_function(bytecode::CompiledFunction f) {
$if $feature(TRACE_VM):
    char[200] line_buf;
    for (uint i = 0; i < f.code_count; i++) {
        usz written = f.code[i].disassemble(line_buf[..]);
        uint end = written < (usz)line_buf.len ? (uint)written : line_buf.len;
        String instr = (String)line_buf[0:end];
        io::printfn("[%3d] %s", i, instr);
    }
$else
    // release build: disassemble is stubbed (returns 0), so we just emit
    // the bare instruction index. The CLI main() prints a one-shot notice
    // telling the user to rebuild with TRACE_VM for opcodes.
    (void)f;
$endif
}

// ============================================================================
// JSON bytecode dump
// ============================================================================

fn void dump_function_json(bytecode::CompiledFunction f, uint idx) {
$if $feature(TRACE_VM):
    char[200] line_buf;
    for (uint i = 0; i < f.code_count; i++) {
        bytecode::Instruction ins = f.code[i];
        usz written = ins.disassemble(line_buf[..]);
        uint end = written < (usz)line_buf.len ? (uint)written : line_buf.len;
        String text = (String)line_buf[0:end];

        io::printfn("  {\"idx\":%d,\"op\":%d,\"a\":%d,\"b\":%d,\"c\":%d,\"text\":\"%s\"}%s",
                    i, ins.op.ordinal, ins.a, ins.b, ins.c,
                    text,
                    i + 1 < f.code_count ? "," : "");
    }
    io::printfn("  ],");
$else
    // release build: emit empty `instructions` array. The CLI main() prints
    // a notice telling the user to rebuild with TRACE_VM.
    (void)f; (void)idx;
$endif
}

// ============================================================================
// Constant pool dump
// ============================================================================

fn void dump_constants_pool(bytecode::CompiledFunction f) {
    if (f.const_count == 0) return;
    io::printn("\n--- Constants ---");
    for (uint i = 0; i < f.const_count; i++) {
        io::printf("  K[%d] = ", i);
        print_tval_stdout(&f.constants[i]);
        io::printfn("");
    }
}

fn void print_tval_stdout(TVal* v) {
    switch (v.get_tag()) {
        case types::TValTag.UNDEFINED:  io::printf("undefined");  break;
        case types::TValTag.NULL_VAL:   io::printf("null");       break;
        case types::TValTag.BOOLEAN:    io::printf(v.get_boolean() ? "true" : "false"); break;
        case types::TValTag.FASTINT:    io::printf("%d", v.get_fastint()); break;
        case types::TValTag.NUMBER:     io::printf("%g", v.get_number()); break;
        case types::TValTag.STRING: {
            HString* s = (HString*)v.get_heapptr();
            if (s != null) {
                char[] d = s.get_data();
                io::printf("\"");
                for (usz i = 0; i < d.len; i++) { io::printf("%c", d[i]); }
                io::printf("\"");
            } else { io::printf("(null)"); }
            break;
        }
        case types::TValTag.OBJECT: {
            HObject* o = (HObject*)v.get_heapptr();
            if (o != null) { io::printf("[object %d]", (int)o.flags.obj_class.ordinal); }
            else           { io::printf("(null)"); }
            break;
        }
        default: io::printf("<?>"); break;
    }
}

// ============================================================================
// Crash dump — print VM state on error
// ============================================================================

fn void dump_vm_state(Vm* v) {
    io::eprintf("\n--- VM Crash Dump ---\n");
    io::eprintf("  activation_count: %d\n", v.activation_count);
    if (v.activation_count > 0) {
        uint aidx = v.activation_count - 1;
        vm::Activation* act = &v.activations[aidx];
        if (act.func != null) {
            bytecode::CompiledFunction* f = (bytecode::CompiledFunction*)act.func;
            io::eprintf("  function: %p (code_count=%d, num_regs=%d)\n",
                        (void*)f, f.code_count, f.num_regs);

            bytecode::Instruction* pc = act.curr_pc;
            uint pc_offset = pc != null ? (uint)(pc - f.code) : 0xFFFF;
            io::eprintf("  curr_pc offset: 0x%04X (%d)\n", pc_offset, pc_offset);

            // Dump current instruction
            if (pc != null && pc >= f.code && pc < f.code + f.code_count) {
                char[200] buf;
$if $feature(TRACE_VM):
                usz written = pc.disassemble(buf[..]);
                uint end = written < (usz)buf.len ? (uint)written : buf.len;
                io::eprintf("  instruction: [0x%04X] %s\n",
                            pc_offset, (String)buf[0:end]);
$else
                // release build: disassemble is a no-op stub.
                io::eprintf("  instruction: [0x%04X] (op=%d)\n",
                            pc_offset, pc.op.ordinal);
$endif
            }

            // Dump register file
            TVal* regs = act.bottom;
            uint nregs = f.num_regs;
            io::eprintf("  registers (%d slots):\n", nregs);
            uint cols = 0;
            for (uint i = 0; i < nregs && i < 32; i++) {
                io::eprintf("    r%d=", i);
                print_tval_stderr(&regs[i]);
                cols++;
                if (cols % 4 == 0) { io::eprintf("\n"); }
                else               { io::eprintf("  "); }
            }
            if (nregs > 32) io::eprintf("    ... (%d more)\n", nregs - 32);
        } else {
            io::eprintf("  function: (null)\n");
        }
    }
    io::eprintf("--- End Crash Dump ---\n");
}

/// Extract and print the .message from an uncaught error TVal.
/// If the value is an Error object with a .message string property, prints
/// "Uncaught <ErrorName>: <message>". Otherwise prints a generic message.
fn void print_uncaught_error(heap::Heap* h, TVal* err_val) {
    if (err_val.is_object()) {
        HObject* err_obj = (HObject*)err_val.get_heapptr();
        if (err_obj != null) {
            HString* msg_key = (HString*)h.strs[heap::BuiltinStr.MESSAGE];
            HString* name_key = (HString*)h.strs[heap::BuiltinStr.NAME];

            // Walk the shape chain to find properties by key. The shape
            // stores the key for each property; prop_values() stores the values
            // in the same order. This is the reliable way to look up a
            // property by key when find_prop_idx's hash isn't populated.
            char[64] name_buf = "Error";
            usz name_len = 5;
            char[types::ERROR_MSG_BUF] msg_buf;
            usz msg_len = 0;
            bool found_msg = false;
            bool found_name = false;

            // Walk shape chain (each shape has a range of properties)
            hobject::Shape* sh = err_obj.get_shape();
            uint global_offset = 0;
            TVal* vals = err_obj.prop_values();
            uint val_idx = 0;
            while (sh != null) {
                hobject::ShapeProperty* sp = sh.props();
                for (uint i = 0; i < sh.own_count; i++) {
                    if (val_idx >= err_obj.prop_count) break;
                    TVal* v = &vals[val_idx];
                    if (!found_name && sp[i].key == (void*)name_key && v.is_string()) {
                        HString* s = (HString*)v.get_heapptr();
                        if (s != null) {
                            char[] d = s.get_data();
                            usz copy_len = d.len < (name_buf.len - 1) ? d.len : (name_buf.len - 1);
                            mem::copy(&name_buf[0], &d[0], (sz)(copy_len));
                            name_len = copy_len;
                            found_name = true;
                        }
                    }
                    if (!found_msg && sp[i].key == (void*)msg_key && v.is_string()) {
                        HString* s = (HString*)v.get_heapptr();
                        if (s != null) {
                            char[] d = s.get_data();
                            usz copy_len = d.len < (msg_buf.len - 1) ? d.len : (msg_buf.len - 1);
                            mem::copy(&msg_buf[0], &d[0], (sz)(copy_len));
                            msg_len = copy_len;
                            found_msg = true;
                        }
                    }
                    val_idx++;
                    if (found_name && found_msg) break;
                }
                if (found_name && found_msg) break;
                sh = sh.parent_shape;
            }
            if (found_msg) {
                io::eprintf("Uncaught %s: %s\n", (String)name_buf[:name_len], (String)msg_buf[:msg_len]);
            } else {
                io::eprintfn("Uncaught %s", (String)name_buf[:name_len]);
            }
            return;
        }
    }
    // Non-object throw value (string, number, boolean, etc.)
    io::eprintf("Uncaught: ");
    print_tval_stderr(err_val);
    io::eprintf("\n");
}

fn void print_tval_stderr(TVal* v) {
    switch (v.get_tag()) {
        case types::TValTag.UNDEFINED:  io::eprintf("undef");   break;
        case types::TValTag.NULL_VAL:   io::eprintf("null");    break;
        case types::TValTag.BOOLEAN:    io::eprintf(v.get_boolean() ? "true" : "false"); break;
        case types::TValTag.FASTINT:    io::eprintf("%d", v.get_fastint()); break;
        case types::TValTag.NUMBER:     io::eprintf("%g", v.get_number()); break;
        case types::TValTag.STRING: {
            HString* s = (HString*)v.get_heapptr();
            if (s != null) {
                char[] d = s.get_data();
                io::eprintf("\"");
                for (usz i = 0; i < d.len; i++) { io::eprintf("%c", d[i]); }
                io::eprintf("\"");
            } else { io::eprintf("(null)"); }
            break;
        }
        case types::TValTag.OBJECT: {
            HObject* o = (HObject*)v.get_heapptr();
            if (o != null) { io::eprintf("[object %d]", (int)o.flags.obj_class.ordinal); }
            else           { io::eprintf("(null)"); }
            break;
        }
        default: io::eprintf("<?>"); break;
    }
}

// ============================================================================
// Deprecated — kept for backward compat, not used by new code
// ============================================================================
