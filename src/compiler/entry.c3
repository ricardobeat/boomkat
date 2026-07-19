module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import std::io;

// ============================================================================
// Top-level entry points
// ============================================================================

/// Compile a complete program (sequence of statements).
/// Returns the top-level CompiledFunction or a fault on error.
fn CompiledFunction*? compile(Lexer* lex, void* heap) {
    // Reset error state for this top-level compilation.
    g_last_err_msg[0] = 0;
    g_last_err_line = 0;
    g_last_err_col  = 0;
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

    // GlobalDeclarationInstantiation static checks (ES2015 §15.1.11) must run
    // before ANY var/function/lexical binding is instantiated, so a collision
    // throws with no observable side effects. Emit the check prologue for
    // top-level lexical, var, and function names first; the real hoist passes
    // below then instantiate the bindings.
    ctx.hoist_lexical_tdz_checks();
    ctx.hoist_decls(true, true)!;
    ctx.hoist_global_fn_decls(true)!;
    lex.pos             = saved_pos;
    lex.line            = saved_line;
    lex.col             = saved_col;
    lex.current         = saved_cur;
    lex.lookahead       = saved_look;
    lex.has_lookahead   = saved_haslk;
    lex.pushed_back     = saved_push;
    lex.has_pushed_back = saved_haspb;
    lex.seen_line_term  = saved_slt;

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
    ctx.hoist_lexical_tdz();
    ctx.reserved_regs = ctx.next_reg;
    while (!ctx.is_at_end()) {
        ctx.statement()!;
    }

    // Free any remaining scope_stack entries (top-level lexical declarations)
    ctx.pop_scope_to(0);

    // Emit implicit "return undefined" at end of program
    ctx.emit_simple(Opcode.RETUNDEF);

    return ctx.finish()!;;
}

/// Compile source as eval code (Program, returns last expression value).
/// Eval code differs from a regular program in that the value of the last
/// expression statement is returned (not undefined).
///
/// `allow_super`: true for a direct eval whose calling context may have a
/// super binding (§12.3.5 MakeSuperPropertyReference / §13.3.7.1
/// MakeSuperPropertyReference read `env.HasSuperBinding()` off the *running*
/// execution context, which for direct eval is the caller's). The eval code
/// is compiled as an independent unit and has no static knowledge of the
/// caller's class/method context, so this just permits the `super.x`/
/// `super[x]` syntax to compile; the `__super__` hidden binding lookup it
/// emits (GETVAR) still walks the real environment chain at runtime — for
/// direct eval that chain IS the caller's, so a genuinely absent binding
/// still throws ReferenceError there, same as the spec's HasSuperBinding
/// check would.
fn CompiledFunction*? compile_eval(Lexer* lex, void* heap, bool allow_super = false) {
    g_last_err_msg[0] = 0;
    g_last_err_line = 0;
    g_last_err_col  = 0;
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;
    ctx.eval_mode = true;
    ctx.has_super_binding = allow_super;
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
    ctx.hoist_lexical_tdz();
    ctx.reserved_regs = ctx.next_reg;
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
    // Reset error state for this compilation — see `compile`'s matching
    // reset. Without it, a stale `g_last_err_msg` left by a PREVIOUS
    // Function()-constructor SyntaxError makes finish()'s choke-point check
    // (context.c3) fail the very next, otherwise-valid compile too — e.g.
    // register_builtins() compiling Array.prototype.toLocaleString right
    // after an unrelated test threw a SyntaxError, poisoning every
    // subsequent test in the same batch-worker process.
    g_last_err_msg[0] = 0;
    g_last_err_line = 0;
    g_last_err_col  = 0;
    CompilerContext ctx;
    ctx.init(lex, heap);

    // Parse function body
    ctx.parse_function_body(is_expr)!;

    return ctx.finish()!;
}

/// Like compile_function but with generator/async flags set for dynamic
/// GeneratorFunction / AsyncFunction constructor (ES2019 §19.2.1.1.1).
fn CompiledFunction*? compile_function_kind(Lexer* lex, void* heap, bool is_expr, bool is_generator, bool is_async) {
    // See compile_function's matching reset — same stale-flag hazard.
    g_last_err_msg[0] = 0;
    g_last_err_line = 0;
    g_last_err_col  = 0;
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_generator = is_generator;
    ctx.is_async = is_async;
    ctx.is_constructable = false;

    ctx.parse_function_body(is_expr)!;

    return ctx.finish()!;
}

/// Compile an ESM module body. Parses import/export declarations and
/// emits RETUNDEF (modules return undefined, not the last expression).
/// `module_name` is used for error messages and relative path resolution.
/// `module_def` is an opaque ModuleDef* — the compiler writes import/export
/// metadata into it via the void* current_module field.
fn CompiledFunction*? compile_module(Lexer* lex, void* heap, char[] module_name, void* module_def) {
    g_last_err_msg[0] = 0;
    g_last_err_line = 0;
    g_last_err_col  = 0;
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;
    ctx.is_module = true;
    // A module body may contain top-level `await` (ES2022). Compiling the
    // module as async lets `await` emit AWAIT/LOAD_RESUME and suspend the
    // module activation, exactly like an async function body. Modules with no
    // top-level await simply never emit AWAIT, so this is harmless for them.
    ctx.is_async = true;
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
    // Note: module top-level `let`/`const` bindings live in the Module
    // Environment Record, not the Global Environment Record, so the
    // restricted-global SyntaxError check inside hoist_lexical_tdz is
    // skipped for modules (ctx.is_module) — this call cannot actually fail.
    ctx.hoist_lexical_tdz();
    ctx.reserved_regs = ctx.next_reg;
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
