module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import duktape::optimizer;
import libc;
import std::io;

// ============================================================================
// Top-level entry points
// ============================================================================

/// Compile a complete program (sequence of statements).
/// Returns the top-level CompiledFunction or a fault on error.
fn CompiledFunction*? compile(Lexer* lex, void* heap) {
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;

    // Check for "use strict" directive prologue at program level
    ctx.parse_directives()!;

    // Hoist var and function declarations at the global level.
    ctx.hoist_decls(true)!;

    // Parse statements until EOF
    while (!ctx.is_at_end()) {
        ctx.statement()!;
    }

    // Emit implicit "return undefined" at end of program
    ctx.emit_simple(Opcode.RETUNDEF);

    CompiledFunction*? result = ctx.finish()!;
    if (try func = result) {
        optimizer::optimize(func);
    }
    return result;
}

/// Compile source as eval code (Program, returns last expression value).
/// Eval code differs from a regular program in that the value of the last
/// expression statement is returned (not undefined).
fn CompiledFunction*? compile_eval(Lexer* lex, void* heap) {
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;
    ctx.eval_mode = true;
    ctx.eval_acc_reg = ctx.alloc_reg();

    // Initialize eval result accumulator to undefined (for empty eval)
    ctx.emit_abc(Opcode.LDUNDEF, (uint)ctx.eval_acc_reg, 0, 0);

    // Check for "use strict" directive prologue at eval level
    ctx.parse_directives()!;

    // Hoist var and function declarations at the eval level.
    ctx.hoist_decls(true)!;

    // Parse statements until EOF
    while (!ctx.is_at_end()) {
        ctx.statement()!;
    }

    // Return the accumulated eval result (or undefined if no expression)
    ctx.emit_a_bc(Opcode.RET, (uint)ctx.eval_acc_reg, 0);

    CompiledFunction*? result = ctx.finish()!;
    if (try func = result) {
        optimizer::optimize(func);
        // Eval code must NOT get its own scope — var declarations must go
        // to the enclosing scope (global env), not a fresh function scope.
        func.flags.needs_env = false;
    }
    return result;
}

/// Compile a function expression or declaration.
/// `is_expr` is true for function expressions, false for declarations.
fn CompiledFunction*? compile_function(Lexer* lex, void* heap, bool is_expr) {
    CompilerContext ctx;
    ctx.init(lex, heap);

    // Parse function body
    ctx.parse_function_body(is_expr)!;

    CompiledFunction*? result = ctx.finish()!;
    if (try func = result) {
        optimizer::optimize(func);
    }
    return result;
}
