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
///
/// `parent_private_names`/`parent_private_name_count`: ES2022 §8.7.1 says
/// direct eval inherits the calling execution context's PrivateEnvironment.
/// `parent_private_names` is a heap-tracked snapshot of the caller's
/// CompilerContext's private-names table (populated when the caller's
/// CompiledFunction was finished and stashed in `eval_private_names`). When
/// non-null, the eval CompilerContext adopts this table — subsequent
/// `#name` references resolve through it (so `this.#m` inside a class
/// method's eval body finds the class's `#m`). Indirect eval (no caller
/// activation or `ACT_FLAG_DIRECT_EVAL` not set on the caller) leaves the
/// parameter null; `#name` references then correctly throw SyntaxError
/// (no enclosing PrivateEnvironment).
///
/// `direct_in_function`: true iff this eval source is being compiled
/// inside a direct-eval call from a non-ArrowFunction's FunctionBody —
/// the ONLY context that legally permits `new.target` per ES2015 Annex
/// B / §14.2.1 (ScriptedTasks: "It is a Syntax Error if StatementList
/// Contains NewTarget unless the source code containing NewTarget is
/// eval code that is being processed by a direct eval that is contained
/// in function code that is not the function code of an ArrowFunction").
/// Pass false (the default) for indirect eval, eval from script top
/// level, or eval from an arrow function — `new_expr()` then rejects
/// new.target as a SyntaxError.  `allow_super` and
/// `direct_in_function` track the same call-site conditions, so the two
/// are usually equal; they're kept as separate parameters to avoid
/// silently coupling super-reference permission to new.target permission
/// (either can be added independently in the future).
fn CompiledFunction*? compile_eval(Lexer* lex, void* heap, bool allow_super = false,
                                    bool direct_in_function = false,
                                    void* parent_private_names = null,
                                    uint  parent_private_name_count = 0) {
    g_last_err_msg[0] = 0;
    g_last_err_line = 0;
    g_last_err_col  = 0;
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;
    ctx.eval_mode = true;
    ctx.has_super_binding = allow_super;
    ctx.eval_direct_in_function = direct_in_function;
    ctx.eval_acc_reg = ctx.alloc_reg();

    // Adopt caller's private-name snapshot (ES2022 §8.7.1). When the caller
    // has none (top-level eval or an indirect eval), the fresh empty table
    // from init() stays in place — `#name` then resolves to nothing, which
    // fails compile_private_name with SyntaxError exactly as the spec
    // requires for eval without an enclosing PrivateEnvironment.
    if (parent_private_names != null && parent_private_name_count > 0) {
        // The caller stashed a snapshot whose `name`/`slot_name`/
        // `brand_slot_name` slices point at interned HString data (stable).
        //
        // We COPY the inherited entries into a freshly-allocated table that
        // this context OWNS. Borrowing the snapshot's buffer directly (à la
        // compile_inner_function's adopt_private_names) would corrupt the
        // caller's snapshot if eval declared any new private name — the
        // inherited entries sit at indices [0..parent_count) and a new
        // class body's #x would land at index parent_count via
        // declare_private_name → ensure_private_name_cap → realloc_func,
        // which would move/extend the snapshot's buffer while the caller
        // still references the old address through CompiledFunction.
        // Copy + own avoids that and matches the per-eval PrivateEnvironment
        // of the spec (the eval body's PrivateEnvironment is logically a
        // fresh env chained to the caller's, not literally the same array).
        if (ctx.owns_private_names && ctx.private_names != null) {
            // init() allocated an empty table; free it before allocating.
            heap::Heap* h = (heap::Heap*)ctx.heap;
            h.free_func(h.heap_udata, ctx.private_names);
        }
        usz inherited_bytes = (usz)parent_private_name_count * PrivateNameEntry::size;
        // Size for growable: start at INITIAL_PRIVATE_NAMES to leave room for
        // any new private names the eval body might declare (e.g. `class D {
        // #x }` inside eval).
        uint new_cap = INITIAL_PRIVATE_NAMES;
        if ((uint)parent_private_name_count >= new_cap) {
            new_cap = parent_private_name_count * 2;
        }
        usz new_bytes = (usz)new_cap * PrivateNameEntry::size;
        heap::Heap* h2 = (heap::Heap*)ctx.heap;
        PrivateNameEntry* new_table = (PrivateNameEntry*)h2.alloc_func(h2.heap_udata, new_bytes);
        if (new_table != null) {
            mem::copy(new_table, parent_private_names, (sz)(inherited_bytes));
            // Zero the rest so uninitialised entries don't carry garbage.
            if ((usz)new_cap * PrivateNameEntry::size > inherited_bytes) {
                mem::clear((char*)new_table + inherited_bytes,
                              (sz)((usz)new_cap * PrivateNameEntry::size - inherited_bytes));
            }
            ctx.private_names = new_table;
            ctx.private_name_count = parent_private_name_count;
            ctx.private_name_cap = new_cap;
            ctx.owns_private_names = true;
        }
        // If alloc fails, leave private_names null — eval will treat every
        // #x reference as SyntaxError (no inherited names visible). The
        // pre-fix behaviour already did this for top-level eval; matching
        // it here on OOM is the safest fallback.
        // has_lexical_bindings must propagate too: each inherited private
        // name was declared via declare_priv_slot in the class-enclosing
        // context, and the class's PUSH_LEX is what keeps the runtime env
        // alive so PUTLEX/GETVAR can find the binding. Direct eval inherits
        // the env chain, but our compiler emits GETVAR-by-name anyway; the
        // flag's only effect here is on needs_env elision in finish(), and
        // eval always needs its env anyway (var declarations must reach the
        // caller's var_env).
    }

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

    // EvalDeclarationInstantiation must validate every global function/var
    // declaration before creating any binding (ES2015 §18.2.1.2 steps 8/10).
    // Only non-strict indirect eval uses the global Environment Record as its
    // varEnv; direct eval and strict indirect eval get a fresh declarative env.
    // Emit the CanDeclareGlobalFunction/Var checks as a prologue so a failure
    // is atomic (no earlier declaration from the same eval has leaked yet).
    if (!allow_super && !ctx.saw_use_strict) {
        ctx.hoist_global_fn_decls(true)!;
        ctx.hoist_decls(true, true)!;
    }

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
