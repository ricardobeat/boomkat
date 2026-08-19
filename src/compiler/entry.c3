module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;

// ============================================================================
// Top-level entry points
// ============================================================================

// Compile a complete program (sequence of statements).
// Returns the top-level CompiledFunction or a fault on error.
fn CompiledFunction*? compile(Lexer* lex, void* heap) {
    // Reset error state for this top-level compilation.
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col  = 0;
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;

    // Save lexer state before any pre-processing.
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
    // before any var/function/lexical binding is instantiated.
    ctx.hoist_lexical_tdz_checks()!;
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

    // Restore lexer to beginning for statement parsing.
    lex.pos             = saved_pos;
    lex.line            = saved_line;
    lex.col             = saved_col;
    lex.current         = saved_cur;
    lex.lookahead       = saved_look;
    lex.has_lookahead   = saved_haslk;
    lex.pushed_back     = saved_push;
    lex.has_pushed_back = saved_haspb;
    lex.seen_line_term  = saved_slt;

    // Capture pre-scan for global scripts.
    ctx.pre_scan_captures(false, true);

    // Whole-program primitive-only global proof.
    ctx.pre_scan_prim_globals();

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

// Compile source as eval code (Program, returns last expression value).
//
// `allow_super`: set for direct eval inside a method with a super binding.
// `direct_in_function`: true iff this eval source is being compiled inside a direct-eval
// call from a non-ArrowFunction's FunctionBody (permits `new.target` per ES2015 Annex B / §14.2.1).
// `parent_private_names`: inherited snapshot of caller's PrivateEnvironment (ES2022 §8.7.1).
// `parent_super_name`/`parent_static_super_name`: binding names of caller's super in environment chain.
fn CompiledFunction*? compile_eval(Lexer* lex, void* heap, bool allow_super = false,
                                    bool direct_in_function = false,
                                    void* parent_private_names = null,
                                    uint  parent_private_name_count = 0,
                                    bool  is_direct_eval = false,
                                    bool  parent_super_is_home_object = false,
                                    bool  allow_super_call = false,
                                    bool  caller_forbids_arguments = false,
                                    char[] parent_super_name = {},
                                    char[] parent_static_super_name = {}) {
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col  = 0;
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;
    ctx.eval_mode = true;
    ctx.in_eval_code = true;
    ctx.has_super_binding = allow_super;
    ctx.super_is_home_object = parent_super_is_home_object;
    // Re-intern the caller's numbered super name (e.g. "__super__0") into
    // the eval context's own constant pool so GETVAR resolves the binding
    // that actually exists in the environment chain.
    if (allow_super && parent_super_name.len > 0) {
        ctx.super_name_idx = ctx.add_string_constant(parent_super_name);
    }
    if (allow_super && parent_static_super_name.len > 0) {
        ctx.static_super_name_idx = ctx.add_string_constant(parent_static_super_name);
    }
    // A direct eval inside a derived-class constructor may contain a `super()`
    // call (ES2022 §15.7.3 PerformEval: the eval inherits the caller's
    // GetThisEnvironment, whose FunctionEnvironmentRecord has [[ThisBinding
    // status]] "uninitialized" and a non-null [[FunctionObject]] with a
    // [[ConstructorKind]] of "derived").  is_constructable gates the `super()`
    // production in expressions.c3; without it `eval("super()")` is a spurious
    // SyntaxError even though the runtime env carries __super__ and new.target.
    ctx.is_constructable = allow_super_call;
    ctx.eval_direct_in_function = direct_in_function;
    // Inherit the caller's ContainsArguments restriction (ES2022 §15.7.10
    // step 14 / §PerformEval): a direct eval called from inside a class
    // field/static initializer or static block must reject a bare
    // `arguments` reference in the eval SOURCE at eval-call time, not just
    // in the enclosing initializer's own text.
    ctx.forbid_arguments = is_direct_eval && caller_forbids_arguments;
    ctx.eval_acc_reg = ctx.alloc_reg();

    // Adopt caller's private-name snapshot (ES2022 §8.7.1). When the caller
    // has none (top-level eval or an indirect eval), the fresh empty table
    // from init() stays in place, `#name` then resolves to nothing, which
    // fails compile_private_name with SyntaxError exactly as the spec
    // requires for eval without an enclosing PrivateEnvironment.
    if (parent_private_names != null && parent_private_name_count > 0) {
        // The caller stashed a snapshot whose `name`/`slot_name`/
        // `brand_slot_name` slices point at interned HString data (stable).
        //
        // We COPY the inherited entries into a freshly-allocated table that
        // this context OWNS. Borrowing the snapshot's buffer directly (à la
        // compile_inner_function's adopt_private_names) would corrupt the
        // caller's snapshot if eval declared any new private name, the
        // inherited entries sit at indices [0..parent_count) and a new
        // class body's #x would land at index parent_count via
        // declare_private_name → ensure_private_name_cap → realloc_func,
        // which would move/extend the snapshot's buffer while the caller
        // still references the old address through CompiledFunction.
        // Copy + own avoids that and matches the per-eval PrivateEnvironment
        // of the spec (the eval body's PrivateEnvironment is logically a
        // fresh env chained to the caller's, not literally the same array).
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
            // Reuse ctx's own (init-allocated) PrivateNameTable, swapping in the
            // inherited entries. The table is already owned by ctx, so only the
            // inner entries buffer changes.
            PrivateNameTable* t = ctx.private_name_table;
            if (t.entries != null) h2.free_func(h2.heap_udata, t.entries);
            t.entries = new_table;
            t.count = parent_private_name_count;
            t.cap = new_cap;
            ctx.owns_private_names = true;
        }
        // If alloc fails, leave private_names null, eval will treat every
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

    // Save lexer state before any pre-processing.
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

    // ES2024 §19.2.1.1: an eval's body is a Script, so its
    // LexicallyDeclaredNames must contain no duplicates. Checked here, before
    // any hoisting, so the SyntaxError is atomic like the ones below.
    ctx.check_script_duplicate_lexical_names()!;

    // EvalDeclarationInstantiation must validate every global function/var
    // declaration before creating any binding (ES2015 §18.2.1.2 steps 8/10).
    // Only non-strict indirect eval uses the global Environment Record as its
    // varEnv; direct eval and strict indirect eval get a fresh declarative env.
    // Emit the CanDeclareGlobalFunction/Var checks as a prologue so a failure
    // is atomic (no earlier declaration from the same eval has leaked yet).
    if (!is_direct_eval && !ctx.saw_use_strict) {
        ctx.hoist_global_fn_decls(true)!;
        ctx.hoist_decls(true, true)!;
    }

    // Hoist function declarations at the eval level (ES5 §10.2.1.1).
    ctx.hoist_global_fn_decls()!;

    // Hoist var declarations at the eval level.
    ctx.hoist_decls(true)!;

    // Restore lexer to beginning for statement parsing.
    lex.pos             = saved_pos;
    lex.line            = saved_line;
    lex.col             = saved_col;
    lex.current         = saved_cur;
    lex.lookahead       = saved_look;
    lex.has_lookahead   = saved_haslk;
    lex.pushed_back     = saved_push;
    lex.has_pushed_back = saved_haspb;
    lex.seen_line_term  = saved_slt;

    // Capture pre-scan for eval scripts, same as compile() above.
    ctx.pre_scan_captures(false, true);

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
        // Eval code must NOT get its own scope, var declarations must go
        // to the enclosing scope (global env), not a fresh function scope.
        func.flags.needs_env = false;
    }
    return result;
}

// Compile a function expression or declaration.
// `is_expr` is true for function expressions, false for declarations.
// `dynamic` marks a body built by the Function constructor.
fn CompiledFunction*? compile_function(Lexer* lex, void* heap, bool is_expr, bool dynamic = false) {
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col  = 0;
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.subst_global_this = dynamic;

    // Parse function body
    ctx.parse_function_body(is_expr)!;

    return ctx.finish()!;
}

// Like compile_function but with generator/async flags set for dynamic constructors (ES2019 §19.2.1.1.1).
fn CompiledFunction*? compile_function_kind(Lexer* lex, void* heap, bool is_expr, bool is_generator, bool is_async, bool dynamic = false) {
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col  = 0;
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.subst_global_this = dynamic;
    ctx.is_generator = is_generator;
    ctx.is_user_generator = is_generator;
    ctx.is_async = is_async;
    ctx.is_constructable = false;

    ctx.parse_function_body(is_expr)!;

    return ctx.finish()!;
}

// Compile an ESM module body. Parses import/export declarations and emits RETUNDEF.
fn CompiledFunction*? compile_module(Lexer* lex, void* heap, char[] module_name, void* module_def) {
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col  = 0;
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;
    ctx.is_module = true;
    ctx.module_goal = true;
    ctx.is_async = true;
    ctx.current_module = module_def;

    // Save lexer state before any pre-processing.
    uint saved_pos    = lex.pos;
    uint saved_line   = lex.line;
    uint saved_col    = lex.col;
    Token saved_cur   = lex.current;
    Token saved_look  = lex.lookahead;
    bool  saved_haslk = lex.has_lookahead;
    Token saved_push  = lex.pushed_back;
    bool  saved_haspb = lex.has_pushed_back;
    bool  saved_slt   = lex.seen_line_term;

    // Check for "use strict" directive prologue (accepted but a no-op, modules are always strict)
    ctx.parse_directives()!;

    // Hoist function declarations at the module level.
    ctx.hoist_global_fn_decls()!;

    // Hoist var declarations at the module level.
    ctx.hoist_decls(true)!;

    // §16.2.1.1: the module body's LexicallyDeclaredNames must be unique.
    ctx.check_module_duplicate_lexical_names()!;

    // Restore lexer to beginning for statement parsing.
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
        ctx.module_top_level = true;
        ctx.statement()!;
    }

    // §16.2.1.1: every ExportedBinding must also be declared in this module.
    ctx.check_module_exports_resolvable()!;

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
