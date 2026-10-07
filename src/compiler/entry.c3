module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::ast;
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
// `want_completion` makes the Script evaluate to its completion value rather
// than undefined, for hosts that observe it ($262.evalScript, ES2015 §18.2.1
// ScriptEvaluation). It turns on the same completion-accumulator bookkeeping
// eval uses, but deliberately NOT `in_eval_code`: this is global Script code,
// so declaration instantiation and global binding allocation must behave
// exactly as they do for an ordinary script.
// `non_strict_source` marks a compilation unit whose strictness the spec
// decides by its own directive prologue: a Function() body (ES2024 §20.2.1.1
// step 22 compiles it as a non-strict FunctionBody) and an indirect eval's
// Script. It lowers the LEXER's strictness, so a body with no "use strict"
// still scans the sloppy-only lexical forms; the parser's own strictness
// default already covers those units. Top-level scripts take that default
// directly and modules are strict, so neither passes this.
// `strict` compiles the whole Script as strict code, as if its prologue held
// "use strict". The CLI and the embedding API use it for their strict-by-
// default modes; spec-driven callers leave it off.
fn CompiledFunction*? compile(Lexer* lex, void* heap, bool want_completion = false,
                              bool non_strict_source = false, bool strict = false) {
    // Reset error state for this top-level compilation.
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col  = 0;
    ast::AstIndex* cmp = null;
    cmp = ast::index_begin(lex.source, heap, { .strict = strict, .ts_mode = lex.ts_mode }, lex.source_buf);
    defer if (cmp != null) ast::index_end(cmp);
    require_ast(lex, cmp)!;
    CompilerContext ctx;
    ctx.init(lex, heap);
    defer ctx.cleanup();
    ctx.is_global = true;
    ctx.eval_mode = want_completion;
    // Top-level scripts default to sloppy (ES2024 §16.2.1.1: script bodies
    // are non-strict code unless a Directive Prologue says otherwise).
    // The AST records any "use strict" directive for gen_program().
    ctx.is_strict = strict;
    ctx.lexer.set_strict(strict);
    if (want_completion) {
        ctx.eval_acc_reg = ctx.alloc_reg();
        // Seed the accumulator so an empty Script, or one whose only
        // statements are declarations, completes with undefined.
        ctx.emit_abc(Opcode.LDUNDEF, (uint)ctx.eval_acc_reg, 0, 0);
    }

    ctx.gen_program()!;
    ctx.pop_scope_to(0);
    if (want_completion) { ctx.emit_a_bc(Opcode.RET, (uint)ctx.eval_acc_reg, 0); }
    else { ctx.emit_simple(Opcode.RETUNDEF); }
    ast::index_end(cmp);
    cmp = null;
    return ctx.finish();
}

// Compile source as eval code (Program, returns last expression value).
// Eval code differs from a regular program in that the value of the last
// expression statement is returned (not undefined).
//
// `allow_super`: true for a direct eval whose calling context may have a
// super binding (§12.3.5 MakeSuperPropertyReference / §13.3.7.1
// MakeSuperPropertyReference read `env.HasSuperBinding()` off the *running*
// execution context, which for direct eval is the caller's). The eval code
// is compiled as an independent unit and has no static knowledge of the
// caller's class/method context, so this just permits the `super.x`/
// `super[x]` syntax to compile; the `__super__` hidden binding lookup it
// emits (GETVAR) still walks the real environment chain at runtime, for
// direct eval that chain IS the caller's, so a genuinely absent binding
// still throws ReferenceError there, same as the spec's HasSuperBinding
// check would.
//
// `parent_super_name`/`parent_static_super_name`: when the caller is inside
// a class body with a numbered __super__ binding (e.g. "__super__0"), these
// pass the binding name so the eval context re-interns it into its own
// constant pool. Without this, eval("super.x") would GETVAR the literal
// "__super__" instead of the numbered name in the environment chain.
//
// `parent_private_names`/`parent_private_name_count`: ES2022 §8.7.1 says
// direct eval inherits the calling execution context's PrivateEnvironment.
// `parent_private_names` is a heap-tracked snapshot of the caller's
// CompilerContext's private-names table (populated when the caller's
// CompiledFunction was finished and stashed in `eval_private_names`). When
// non-null, the eval CompilerContext adopts this table, so subsequent
// `#name` references resolve through it (so `this.#m` inside a class
// method's eval body finds the class's `#m`). Indirect eval (no caller
// activation or `ACT_FLAG_DIRECT_EVAL` not set on the caller) leaves the
// parameter null; `#name` references then correctly throw SyntaxError
// (no enclosing PrivateEnvironment).
//
// `direct_in_function`: true iff this eval source is being compiled
// inside a direct-eval call from a non-ArrowFunction's FunctionBody, so
// the ONLY context that legally permits `new.target` per ES2015 Annex
// B / §14.2.1 (ScriptedTasks: "It is a Syntax Error if StatementList
// Contains NewTarget unless the source code containing NewTarget is
// eval code that is being processed by a direct eval that is contained
// in function code that is not the function code of an ArrowFunction").
// Pass false (the default) for indirect eval, eval from script top
// level, or eval from an arrow function, `new_expr()` then rejects
// new.target as a SyntaxError.  `allow_super` and
// `direct_in_function` track the same call-site conditions, so the two
// are usually equal; they're kept as separate parameters to avoid
// silently coupling super-reference permission to new.target permission
// (either can be added independently in the future).
fn CompiledFunction*? compile_eval(Lexer* lex, void* heap, bool allow_super = false,
                                    bool direct_in_function = false,
                                    void* parent_private_names = null,
                                    uint  parent_private_name_count = 0,
                                    bool  is_direct_eval = false,
                                    bool  parent_super_is_home_object = false,
                                    bool  allow_super_call = false,
                                    bool  caller_forbids_arguments = false,
                                    char[] parent_super_name = {},
                                    char[] parent_static_super_name = {},
                                    char[] parent_home_object_name = {},
                                    bool  parent_super_home_is_object_literal = false,
                                    bool  caller_is_strict = false,
                                    bool  var_env_is_global = false) {
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col  = 0;
    char[][] private_names = mem::new_array(char[], parent_private_name_count);
    defer mem::free(private_names);
    for (uint i = 0; i < parent_private_name_count; i++) private_names[i] = ((PrivateNameEntry*)parent_private_names)[i].name;
    ast::AstIndex* cmp = null;
    {
        cmp = ast::index_begin(lex.source, heap, {
            .strict = is_direct_eval && caller_is_strict,
            .ts_mode = lex.ts_mode,
            .in_function = false,
            .allow_new_target = direct_in_function,
            .allow_super_property = allow_super,
            .allow_super_call = allow_super_call,
            .in_class_field_init = is_direct_eval && caller_forbids_arguments,
            .private_names = private_names,
        });
    }
    defer if (cmp != null) ast::index_end(cmp);
    require_ast(lex, cmp)!;
    CompilerContext ctx;
    ctx.init(lex, heap);
    defer ctx.cleanup();
    ctx.is_global = true;
    ctx.eval_mode = true;
    ctx.in_eval_code = true;
    // Eval inherits the caller's strictness only when the call is direct
    // (ES2024 §19.2.1.1 step 12: "Eval code is strict mode code if it
    // begins with a Directive Prologue that contains a Use Strict Directive
    // or if the call to eval is a direct eval that is contained in strict
    // mode code"). An indirect eval always defaults to sloppy; its own
    // prologue can flip strict via `saw_use_strict`. caller_is_strict is
    // masked by is_direct_eval below to honor that.
    ctx.is_strict = false;
    ctx.has_super_binding = allow_super;
    ctx.super_is_home_object = parent_super_is_home_object;
    // An object-literal caller's HomeObject binding is __super__ (unnumbered,
    // see object_literal's own PUTLEX), not __home_object__ -- propagate this
    // so the eval body's emit_super_base picks the same binding name the
    // caller's environment chain actually has.
    ctx.super_home_is_object_literal = parent_super_home_is_object_literal;
    // Re-intern the caller's numbered super name (e.g. "__super__0") into
    // the eval context's own constant pool so GETVAR resolves the binding
    // that actually exists in the environment chain.
    if (allow_super && parent_super_name.len > 0) {
        ctx.super_name_idx = ctx.add_string_constant(parent_super_name);
    }
    if (allow_super && parent_static_super_name.len > 0) {
        ctx.static_super_name_idx = ctx.add_string_constant(parent_static_super_name);
    }
    if (allow_super && parent_home_object_name.len > 0) {
        ctx.home_object_name_idx = ctx.add_string_constant(parent_home_object_name);
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

    bool eval_strict = (cmp.tree.flags.data[cmp.res.scopes.data[1].node] & ast::PROGRAM_STRICT) != 0;
    ctx.gen_program(var_env_is_global && !eval_strict)!;

    // Collect the eval source's var-declared names (var statements via
    // record_eval_var_name, function declarations via the hoisted-name
    // tables) for the §18.2.1.2 step 3.4 intermediate-binding collision
    // check in builtin_eval. Dedup against the collected list (the hoisted
    // tables were not hooked).
    uint eval_var_count = ctx.eval_var_coll_count;
    for (uint i = 0; i < ctx.hoisted_fn_count; i++) {
        uint ni = ctx.add_string_constant(ctx.hoisted_fn_names[i]);
        bool dup = false;
        for (uint k = 0; k < eval_var_count; k++) {
            if (ctx.eval_var_coll_idxs[k] == ni) { dup = true; break; }
        }
        if (!dup) {
            if (eval_var_count >= ctx.eval_var_coll_cap) {
                uint new_cap = ctx.eval_var_coll_cap == 0 ? 16 : ctx.eval_var_coll_cap * 2;
                void* pn = ((Heap*)heap).realloc_func(((Heap*)heap).heap_udata,
                    ctx.eval_var_coll_idxs, (usz)(new_cap * 4));
                if (pn != null) {
                    ctx.eval_var_coll_idxs = (uint*)pn;
                    ctx.eval_var_coll_cap = new_cap;
                }
            }
            if (eval_var_count < ctx.eval_var_coll_cap) {
                ctx.eval_var_coll_idxs[eval_var_count++] = ni;
            }
        }
    }

    // Free any remaining scope_stack entries (top-level lexical declarations)
    ctx.pop_scope_to(0);

    // Return the accumulated eval result (or undefined if no expression)
    ctx.emit_a_bc(Opcode.RET, (uint)ctx.eval_acc_reg, 0);

    ast::index_end(cmp);
    cmp = null;
    CompiledFunction* func = ctx.finish()!;
    // Eval code must NOT get its own scope, var declarations must go
    // to the enclosing scope (global env), not a fresh function scope.
    func.flags.needs_env = false;
    if (eval_var_count > 0) {
        // The function outlives this context, so it takes its own copy.
        Heap* h = (Heap*)heap;
        uint* idxs = (uint*)h.alloc_func(h.heap_udata, (usz)eval_var_count * 4);
        if (idxs != null) {
            for (uint i = 0; i < eval_var_count; i++) idxs[i] = ctx.eval_var_coll_idxs[i];
            func.eval_var_idxs = idxs;
            func.eval_var_count = eval_var_count;
        }
    }
    return func;
}

// Compile a function expression or declaration.
// `is_expr` is true for function expressions, false for declarations.
// `dynamic` marks a body built by the Function constructor, which is
// always sloppy unless the body carries its own "use strict" directive.
fn CompiledFunction*? compile_function(Lexer* lex, void* heap, bool is_expr, bool dynamic = false) {
    return compile_function_kind(lex, heap, is_expr, false, false, dynamic, true);
}

fn CompiledFunction*? compile_function_kind(Lexer* lex, void* heap, bool is_expr, bool is_generator,
                                           bool is_async, bool dynamic = false, bool constructable = false) {
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col = 0;
    ast::AstIndex* idx = null;
    {
        idx = ast::index_begin(lex.source, heap, {
            .function_body = true,
            .ts_mode = lex.ts_mode,
            .function_flags = (is_generator ? ast::FNF_GENERATOR : 0) | (is_async ? ast::FNF_ASYNC : 0),
        });
    }
    defer if (idx != null) ast::index_end(idx);
    require_ast(lex, idx)!;
    CompilerContext ctx;
    ctx.init(lex, heap);
    defer ctx.cleanup();
    ctx.is_strict = false;
    ctx.lexer.set_strict(false);
    ctx.is_generator = is_generator;
    ctx.is_user_generator = is_generator;
    ctx.is_async = is_async;
    ctx.is_constructable = constructable;
    ctx.gen_function(2)!;
    ast::index_end(idx);
    idx = null;
    return ctx.finish()!;
}

// Compile an ESM module body. Parses import/export declarations and
// emits RETUNDEF (modules return undefined, not the last expression).
// `module_name` is used for error messages and relative path resolution.
// `module_def` is an opaque ModuleDef*, the compiler writes import/export
// metadata into it via the void* current_module field.
fn CompiledFunction*? compile_module(Lexer* lex, void* heap, char[] module_name, void* module_def) {
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col  = 0;
    ast::AstIndex* cmp = null;
    cmp = ast::index_begin(lex.source, heap, { .is_module = true, .ts_mode = lex.ts_mode, .jsx = lex.jsx }, lex.source_buf);
    defer if (cmp != null) ast::index_end(cmp);
    require_ast(lex, cmp)!;
    CompilerContext ctx;
    ctx.init(lex, heap);
    defer ctx.cleanup();
    ctx.is_global = true;
    ctx.is_module = true;
    ctx.module_goal = true;
    // Modules are always strict by spec (ES2015 §16.2.1.1). Set the flag here
    // so plans/083 plumbing reaches the module entry even though it never
    // gets flipped.
    ctx.is_strict = true;
    // A module body may contain top-level `await` (ES2022). Compiling the
    // module as async lets `await` emit AWAIT/LOAD_RESUME and suspend the
    // module activation, exactly like an async function body. Modules with no
    // top-level await simply never emit AWAIT, so this is harmless for them.
    ctx.is_async = true;
    ctx.current_module = module_def;

    ctx.gen_program(false)!;

    // Free any remaining scope_stack entries (top-level lexical declarations)
    ctx.pop_scope_to(0);

    // Modules return undefined (no implicit last-expression return)
    ctx.emit_simple(Opcode.RETUNDEF);

    ast::index_end(cmp);
    cmp = null;
    CompiledFunction*? result = ctx.finish()!;
    if (try func = result) {
        func.flags.is_module = true;
        // ECMA-262 [[HasTLA]]. Module bodies are always compiled async (see
        // ctx.is_async above), so only this records whether one really awaits.
        func.flags.has_tla = ctx.saw_top_level_await;
    }
    return result;
}

fn void? require_ast(Lexer* lex, ast::AstIndex* idx) {
    if (idx.use) return;
    if (!idx.parser.failed) return;
    String message = idx.parser.error_message();
    ast::SourcePos at = idx.tree.position(idx.parser.err_pos);
    usz count = message.len < lex.err_msg.len - 1 ? message.len : lex.err_msg.len - 1;
    mem::copy(&lex.err_msg[0], message.ptr, (sz)count);
    lex.err_msg[count] = 0;
    lex.err_line = at.line;
    lex.err_col = at.col;
    return COMPILE_ERROR~;
}
