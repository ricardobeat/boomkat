module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
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

    // Hoist var and function declarations at the global level.
    ctx.hoist_decls(true)!;

    // Parse statements until EOF
    while (!ctx.is_at_end()) {
        ctx.statement()!;
    }

    // Emit implicit "return undefined" at end of program
    ctx.emit_simple(Opcode.RETUNDEF);

    return ctx.finish()!;
}

/// Compile a function expression or declaration.
/// `is_expr` is true for function expressions, false for declarations.
fn CompiledFunction*? compile_function(Lexer* lex, void* heap, bool is_expr) {
    CompilerContext ctx;
    ctx.init(lex, heap);

    // Parse function body
    ctx.parse_function_body(is_expr)!;

    return ctx.finish()!;
}
