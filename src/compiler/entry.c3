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

    // ── Save lexer state before any pre-processing ───────────────────
    uint saved_pos    = lex.pos;
    uint saved_line   = lex.line;
    uint saved_col    = lex.col;
    Token saved_cur   = lex.current;
    Token saved_look  = lex.lookahead;
    bool  saved_haslk = lex.has_lookahead;
    Token saved_push  = lex.pushed_back;
    bool  saved_haspb = lex.has_pushed_back;
    bool  saved_slt   = lex.seen_line_term;

    // Check for "use strict" directive prologue at program level
    ctx.parse_directives()!;

    // Hoist function declarations at the global level (ES5 §10.2.1.1).
    ctx.hoist_global_fn_decls()!;

    // Hoist var declarations at the global level.
    ctx.hoist_decls(true)!;

    // ── Restore lexer to beginning for statement parsing ────────────
    lex.pos             = saved_pos;
    lex.line            = saved_line;
    lex.col             = saved_col;
    lex.current         = saved_cur;
    lex.lookahead       = saved_look;
    lex.has_lookahead   = saved_haslk;
    lex.pushed_back     = saved_push;
    lex.has_pushed_back = saved_haspb;
    lex.seen_line_term  = saved_slt;

    // Parse statements until EOF
    while (!ctx.is_at_end()) {
        ctx.statement()!;
    }

    // Free any remaining scope_stack entries (top-level lexical declarations)
    ctx.pop_scope_to(0);

    // Emit implicit "return undefined" at end of program
    ctx.emit_simple(Opcode.RETUNDEF);

    return ctx.finish()!;
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

    // ── Save lexer state before any pre-processing ───────────────────
    uint saved_pos    = lex.pos;
    uint saved_line   = lex.line;
    uint saved_col    = lex.col;
    Token saved_cur   = lex.current;
    Token saved_look  = lex.lookahead;
    bool  saved_haslk = lex.has_lookahead;
    Token saved_push  = lex.pushed_back;
    bool  saved_haspb = lex.has_pushed_back;
    bool  saved_slt   = lex.seen_line_term;

    // Check for "use strict" directive prologue at eval level
    ctx.parse_directives()!;

    // Hoist function declarations at the eval level (ES5 §10.2.1.1).
    ctx.hoist_global_fn_decls()!;

    // Hoist var declarations at the eval level.
    ctx.hoist_decls(true)!;

    // ── Restore lexer to beginning for statement parsing ────────────
    lex.pos             = saved_pos;
    lex.line            = saved_line;
    lex.col             = saved_col;
    lex.current         = saved_cur;
    lex.lookahead       = saved_look;
    lex.has_lookahead   = saved_haslk;
    lex.pushed_back     = saved_push;
    lex.has_pushed_back = saved_haspb;
    lex.seen_line_term  = saved_slt;

    // Parse statements until EOF
    while (!ctx.is_at_end()) {
        ctx.statement()!;
    }

    // Free any remaining scope_stack entries (top-level lexical declarations)
    ctx.pop_scope_to(0);

    // Return the accumulated eval result (or undefined if no expression)
    ctx.emit_a_bc(Opcode.RET, (uint)ctx.eval_acc_reg, 0);

    CompiledFunction*? result = ctx.finish()!;
    if (try func = result) {
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

    return ctx.finish()!;
}

/// Compile an ESM module body. Parses import/export declarations and
/// emits RETUNDEF (modules return undefined, not the last expression).
/// `module_name` is used for error messages and relative path resolution.
/// `module_def` is an opaque ModuleDef* — the compiler writes import/export
/// metadata into it via the void* current_module field.
fn CompiledFunction*? compile_module(Lexer* lex, void* heap, char[] module_name, void* module_def) {
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;
    ctx.is_module = true;
    ctx.current_module = module_def;

    // ── Save lexer state before any pre-processing ───────────────────
    uint saved_pos    = lex.pos;
    uint saved_line   = lex.line;
    uint saved_col    = lex.col;
    Token saved_cur   = lex.current;
    Token saved_look  = lex.lookahead;
    bool  saved_haslk = lex.has_lookahead;
    Token saved_push  = lex.pushed_back;
    bool  saved_haspb = lex.has_pushed_back;
    bool  saved_slt   = lex.seen_line_term;

    // Check for "use strict" directive prologue (accepted but a no-op — modules are always strict)
    ctx.parse_directives()!;

    // Hoist function declarations at the module level.
    ctx.hoist_global_fn_decls()!;

    // Hoist var declarations at the module level.
    ctx.hoist_decls(true)!;

    // ── Restore lexer to beginning for statement parsing ────────────
    lex.pos             = saved_pos;
    lex.line            = saved_line;
    lex.col             = saved_col;
    lex.current         = saved_cur;
    lex.lookahead       = saved_look;
    lex.has_lookahead   = saved_haslk;
    lex.pushed_back     = saved_push;
    lex.has_pushed_back = saved_haspb;
    lex.seen_line_term  = saved_slt;

    // Parse statements until EOF
    while (!ctx.is_at_end()) {
        ctx.statement()!;
    }

    // Free any remaining scope_stack entries (top-level lexical declarations)
    ctx.pop_scope_to(0);

    // Modules return undefined (no implicit last-expression return)
    ctx.emit_simple(Opcode.RETUNDEF);

    CompiledFunction*? result = ctx.finish()!;
    if (try func = result) {
        func.flags.is_module = true;
    }
    return result;
}
