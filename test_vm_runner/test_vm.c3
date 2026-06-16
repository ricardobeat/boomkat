module test_vm;

import tinyduck::compiler;
import tinyduck::vm;
import tinyduck::heap;
import tinyduck::env;
import tinyduck::lexer;
import tinyduck::types;
import tinyduck::bytecode;
import tinyduck::hstring;
import std::io;
import std::math;
import libc;

// ============================================================================
// Text-format bytecode dump (always available)
// ============================================================================

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

// ============================================================================
// Debug-only helpers (bodies are empty in release builds)
// ============================================================================

/// Print a null-terminated C string.
fn void print_cstr(char* s) {
    usz i = 0;
    while (s[i] != 0) { io::putchar(s[i]); i++; }
}

/// Print a TVal in short human-readable form.
fn void print_tval_value(TVal* v) {
    $if $feature(DEBUG):
    if (v.is_undefined()) {
        io::printf("undefined");
    } else if (v.is_null()) {
        io::printf("null");
    } else if (v.is_boolean()) {
        io::printf(v.get_boolean() ? "true" : "false");
    } else if (v.is_fastint()) {
        io::printf("%d", v.get_fastint());
    } else if (v.is_number()) {
        double d = v.get_number();
        if (math::is_nan(d)) {
            io::printf("NaN");
        } else if (math::is_inf(d)) {
            io::printf(d > 0 ? "Infinity" : "-Infinity");
        } else if (d == (double)(long)d) {
            io::printf("%d", (long)d);
        } else {
            io::printf("%.6g", d);
        }
    } else if (v.is_string()) {
        HString* s = (HString*)v.get_heapptr();
        if (s != null) {
            char[] d = s.get_data();
            usz n = d.len < 48 ? d.len : 48;
            io::putchar('"');
            for (usz _si = 0; _si < n; _si++) io::putchar(d[_si]);
            if (d.len > 48) io::printf("...");
            io::putchar('"');
        } else {
            io::printf("[null]");
        }
    } else if (v.is_object()) {
        io::printf("[object]");
    } else if (v.is_buffer()) {
        io::printf("[buffer]");
    } else if (v.is_pointer()) {
        io::printf("[pointer]");
    } else if (v.is_lightfunc()) {
        io::printf("[lightfunc]");
    } else {
        io::printf("[unknown]");
    }
    $endif
}

/// Recursively print the constant pool for a function tree.
fn void dump_constants(CompiledFunction* f, int depth) {
    $if $feature(DEBUG):
    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printfn("--- CONSTS depth=%d (%d entries) ---", depth, f.const_count);
    for (uint i = 0; i < f.const_count; i++) {
        for (int d = 0; d < depth; d++) io::printf("  ");
        io::printf("  K[%d] = ", i);
        print_tval_value(&f.constants[i]);
        io::printf("\n");
    }
    for (uint i = 0; i < f.inner_count; i++) {
        dump_constants(f.inner_funcs[i], depth + 1);
    }
    $endif
}

/// Return a string name for an operand format.
fn char* op_format_name(OpFormat fmt) {
    switch (fmt) {
        case ABC:       return "ABC";
        case A_BC:      return "A_BC";
        case A_SBX:     return "A_SBX";
        case WIDE_ABC:  return "WIDE_ABC";
        case WIDE_SABC: return "WIDE_SABC";
        case NONE:      return "NONE";
    }
}


/// Dump a CompiledFunction tree in JSON format.
fn void dump_func_json(CompiledFunction* f, int depth) {
    $if $feature(DEBUG):
    // Indent open
    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("{\n");

    // Header fields
    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("  \"name\": \"");
    if (f.name_ptr != null) {
        for (uint _ni = 0; _ni < f.name_len; _ni++) io::putchar(f.name_ptr[_ni]);
    }
    io::printf("\",\n");

    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("  \"depth\": %d,\n", depth);

    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("  \"code_count\": %d,\n", f.code_count);

    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("  \"num_regs\": %d,\n", f.num_regs);

    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("  \"num_args\": %d,\n", f.num_args);

    // Instructions array
    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("  \"instructions\": [\n");
    for (uint i = 0; i < f.code_count; i++) {
        Instruction insn = f.code[i];
        Opcode op = insn.op;
        OpFormat fmt = bytecode::get_op_format(op);

        for (int d = 0; d < depth + 1; d++) io::printf("  ");
        io::printf("{\"pc\":%d,\"op\":\"", i);
        print_cstr(bytecode::get_opcode_name(op));
        io::printf("\",\"fmt\":\"");
        print_cstr(op_format_name(fmt));
        io::printf("\"");

        if (fmt == ABC) {
            io::printf(",\"a\":%d,\"b\":%d,\"c\":%d",
                       (int)insn.a, (int)insn.b, (int)insn.c);
        } else if (fmt == A_BC) {
            io::printf(",\"a\":%d,\"bc\":%d", (int)insn.a, insn.get_bc());
        } else if (fmt == A_SBX) {
            io::printf(",\"a\":%d,\"sbx\":%d", (int)insn.a, insn.get_sbc());
        } else if (fmt == WIDE_ABC) {
            io::printf(",\"abc\":%d", insn.get_abc());
        } else if (fmt == WIDE_SABC) {
            io::printf(",\"sabc\":%d", insn.get_sabc());
        }

        io::printf("}");
        if (i < f.code_count - 1) io::printf(",");
        io::printf("\n");
    }
    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("  ],\n");

    // Constants array
    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("  \"constants\": [\n");
    for (uint i = 0; i < f.const_count; i++) {
        for (int d = 0; d < depth + 1; d++) io::printf("  ");
        print_tval_value(&f.constants[i]);
        if (i < f.const_count - 1) io::printf(",");
        io::printf("\n");
    }
    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("  ],\n");

    // Inner functions
    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("  \"inner\": [\n");
    for (uint i = 0; i < f.inner_count; i++) {
        dump_func_json(f.inner_funcs[i], depth + 2);
        if (i < f.inner_count - 1) io::printf(",");
        io::printf("\n");
    }
    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("  ]\n");

    // Close
    for (int d = 0; d < depth; d++) io::printf("  ");
    io::printf("}");
    $endif
}

// ============================================================================
// Main
// ============================================================================

fn int main(String[] args) {
    $if $feature(DEBUG):
    // ---- Debug build: full flag parsing ----
    bool compile_only    = false;
    bool trace_vm        = false;
    bool dump_consts     = false;
    String out_format    = "text";
    String path          = "test/simple.js";
    for (uint i = 1; i < args.len; i++) {
        if (args[i] == "--compile-only" || args[i] == "-c") {
            compile_only = true;
        } else if (args[i] == "--trace-vm" || args[i] == "-t") {
            trace_vm = true;
        } else if (args[i] == "--dump-constants") {
            dump_consts = true;
        } else if (args[i] == "--format" && (long)(i + 1) < (long)args.len) {
            i++;
            out_format = args[i];
        } else if (args[i].len > 0 && args[i][0] != '-') {
            path = args[i];
        }
    }
    $else
    // ---- Release build: simple argument ----
    String path = args.len > 1 ? args[1] : "test/simple.js";
    $endif

    // === Create engine ===
    char[]? source = file::load_temp(path);
    if (catch err = source) { io::eprintfn("Failed to read"); return 1; }

    Heap*? hp = heap::create();
    if (catch h = hp) { io::eprintfn("Failed heap"); return 1; }
    defer hp.destroy();

    Vm*? v = vm::vm_create(hp);
    if (catch err = v) { io::eprintfn("VM failed"); return 1; }
    defer vm::vm_destroy(v);

    $if $feature(DEBUG):
    if (trace_vm) v.trace = true;
    $endif

    // === Compile ===
    Lexer lex = lexer::lexer_init(source, hp);
    CompiledFunction*? func = compiler::compile(&lex, hp);
    CompiledFunction* f;
    if (try ff = func) { f = ff; } else { io::eprintfn("Compile failed"); return 1; }

    // === Dump bytecode ===
    $if $feature(DEBUG):
    if (out_format == "json") {
        dump_func_json(f, 0);
        io::printf("\n");
    } else {
        dump_func(f, 0);
    }
    $else
    dump_func(f, 0);
    $endif

    // === Dump constants (text mode only) ===
    $if $feature(DEBUG):
    if (dump_consts && out_format != "json") dump_constants(f, 0);
    $endif

    // === Compile-only ===
    $if $feature(DEBUG):
    if (compile_only) return 0;
    $endif

    // === Execute ===
    io::printfn("=== EXECUTING ===");
    TVal? result = v.execute(f);

    // === Error handling ===
    $if $feature(DEBUG):
    if (catch err = result) {
        vm::vm_dump_state(v);
        io::eprintfn("VM error: %s (at execute)", err);
        return 1;
    }
    $else
    if (catch err = result) { io::eprintfn("VM error: %s (at execute)", err); return 1; }
    $endif

    return 0;
}
