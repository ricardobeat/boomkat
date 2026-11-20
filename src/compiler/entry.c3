module boomkat::compiler;

import boomkat::features;

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
// than undefined, for hosts that observe it ($262.evalScript, ECMA-262
// ScriptEvaluation). It turns on the same completion-accumulator bookkeeping
// eval uses, but deliberately NOT `in_eval_code`: this is global Script code,
// so declaration instantiation and global binding allocation must behave
// exactly as they do for an ordinary script.
// `non_strict_source` marks a compilation unit whose strictness the spec
// decides by its own directive prologue: a Function() body (ECMA-262
// CreateDynamicFunction compiles it as a non-strict FunctionBody) and an
// indirect eval's Script. It lowers the LEXER's strictness, so a body with no "use strict"
// still scans the sloppy-only lexical forms; the parser's own strictness
// default already covers those units. Top-level scripts take that default
// directly and modules are strict, so neither passes this.
// `strict` compiles the whole Script as strict code, as if its prologue held
// "use strict". The CLI and the embedding API use it for their strict-by-
// default modes; spec-driven callers leave it off. A TypeScript source is
// always strict: TypeScript 6 and later assume strict mode for all code.
fn CompiledFunction*? compile(Lexer* lex, void* heap, bool want_completion = false,
                              bool non_strict_source = false, bool strict = false) {
    $if features::SOURCE_COMPILER:
    // Reset error state for this top-level compilation.
    strict = features::STRICT_ONLY || strict || lex.ts_mode;
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col  = 0;
    ast::AstIndex* cmp = null;
    cmp = ast::index_begin(lex.source, heap, {
        .strict = strict, .ts_mode = lex.ts_mode,
        .defer_functions = defer_functions_allowed(),
    }, lex.source_buf);
    defer if (cmp != null) ast::index_end(cmp);
    require_ast(lex, cmp)!;
    CompilerContext ctx;
    ctx.init(lex, heap);
    defer ctx.cleanup();
    ctx.is_global = true;
    ctx.eval_mode = want_completion;
    // Top-level scripts default to sloppy (ECMA-262 Scripts: script bodies
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
    $else
        return COMPILE_ERROR~;
    $endif
}

// Compile source as eval code (returns the last expression's value).
//
// `allow_super`: permits `super.x`/`super[x]` in direct eval; the runtime
//   environment chain still enforces HasSuperBinding.
// `parent_super_name` / `parent_static_super_name` / `parent_home_object_name`:
//   caller's numbered super/home binding names, re-interned into this pool.
// `parent_private_names`: snapshot of the caller's PrivateEnvironment (ES2026 §9.2),
//   copied into a table owned by this context for direct eval (null for indirect).
// `direct_in_function`: true for direct eval inside a non-arrow function,
//   permitting `new.target` (ES2026 §15.3).
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
    $if features::SOURCE_COMPILER:
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col  = 0;
    char[][] private_names = mem::new_array(char[], (sz)parent_private_name_count);
    defer mem::free(private_names);
    for (uint i = 0; i < parent_private_name_count; i++) private_names[i] = ((PrivateNameEntry*)parent_private_names)[i].name;
    ast::AstIndex* cmp = null;
    {
        cmp = ast::index_begin(lex.source, heap, {
            .strict = features::STRICT_ONLY || (is_direct_eval && caller_is_strict),
            .ts_mode = lex.ts_mode,
            .in_function = false,
            .allow_new_target = direct_in_function,
            .allow_super_property = allow_super,
            .allow_super_call = allow_super_call,
            .in_class_field_init = is_direct_eval && caller_forbids_arguments,
            .private_names = private_names,
            .defer_functions = defer_functions_allowed(),
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
    // (ES2026 §19.2.1.1 step 12: "Eval code is strict mode code if it
    // begins with a Directive Prologue that contains a Use Strict Directive
    // or if the call to eval is a direct eval that is contained in strict
    // mode code"). An indirect eval always defaults to sloppy; its own
    // prologue can flip strict via `saw_use_strict`. caller_is_strict is
    // masked by is_direct_eval below to honor that.
    ctx.is_strict = features::STRICT_ONLY;
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
    // call (ES2026 §19.2.1.1 PerformEval: the eval inherits the caller's
    // GetThisEnvironment, whose FunctionEnvironmentRecord has [[ThisBinding
    // status]] "uninitialized" and a non-null [[FunctionObject]] with a
    // [[ConstructorKind]] of "derived").  is_constructable gates the `super()`
    // production in expressions.c3; without it `eval("super()")` is a spurious
    // SyntaxError even though the runtime env carries __super__ and new.target.
    ctx.is_constructable = allow_super_call;
    ctx.in_derived_ctor = allow_super_call;
    ctx.eval_direct_in_function = direct_in_function;
    // Inherit the caller's ContainsArguments restriction (ES2026 §19.2.1.1
    // step 14 / §PerformEval): a direct eval called from inside a class
    // field/static initializer or static block must reject a bare
    // `arguments` reference in the eval SOURCE at eval-call time, not just
    // in the enclosing initializer's own text.
    ctx.forbid_arguments = is_direct_eval && caller_forbids_arguments;
    ctx.eval_acc_reg = ctx.alloc_reg();

    // Copy the caller's private-name snapshot (ES2026 §9.2) into a table owned by
    // this context so new private names declared inside eval do not reallocate
    // or mutate the caller's snapshot.
    if (parent_private_names != null && parent_private_name_count > 0) {
        usz inherited_bytes = (usz)parent_private_name_count * PrivateNameEntry::size;
        uint new_cap = INITIAL_PRIVATE_NAMES;
        if ((uint)parent_private_name_count >= new_cap) {
            new_cap = parent_private_name_count * 2;
        }
        usz new_bytes = (usz)new_cap * PrivateNameEntry::size;
        heap::Heap* h2 = (heap::Heap*)ctx.heap;
        PrivateNameEntry* new_table = (PrivateNameEntry*)h2.alloc_func(h2.heap_udata, new_bytes);
        if (new_table != null) {
            mem::copy(new_table, parent_private_names, (sz)(inherited_bytes));
            if ((usz)new_cap * PrivateNameEntry::size > inherited_bytes) {
                mem::clear((char*)new_table + inherited_bytes,
                              (sz)((usz)new_cap * PrivateNameEntry::size - inherited_bytes));
            }
            PrivateNameTable* t = ctx.private_name_table;
            if (t.entries != null) h2.free_func(h2.heap_udata, t.entries);
            t.entries = new_table;
            t.count = parent_private_name_count;
            t.cap = new_cap;
            ctx.owns_private_names = true;
        }
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
    $else
        return COMPILE_ERROR~;
    $endif
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
    $if features::SOURCE_COMPILER:
    lex.err_msg[0] = 0;
    lex.err_line = 0;
    lex.err_col = 0;
    ast::AstIndex* idx = null;
    {
        idx = ast::index_begin(lex.source, heap, {
            .function_body = true,
            .strict = features::STRICT_ONLY,
            .ts_mode = lex.ts_mode,
            .function_flags = (is_generator ? ast::FNF_GENERATOR : 0) | (is_async ? ast::FNF_ASYNC : 0),
        });
    }
    defer if (idx != null) ast::index_end(idx);
    require_ast(lex, idx)!;
    CompilerContext ctx;
    ctx.init(lex, heap);
    defer ctx.cleanup();
    ctx.is_strict = features::STRICT_ONLY;
    ctx.lexer.set_strict(features::STRICT_ONLY);
    ctx.is_generator = is_generator;
    ctx.is_user_generator = is_generator;
    ctx.is_async = is_async;
    ctx.is_constructable = constructable;
    ctx.gen_function(2)!;
    ast::index_end(idx);
    idx = null;
    return ctx.finish()!;
    $else
        return COMPILE_ERROR~;
    $endif
}

// Compile an ESM module body. Parses import/export declarations and
// emits RETUNDEF (modules return undefined, not the last expression).
// `module_name` is used for error messages and relative path resolution.
// `module_def` is an opaque ModuleDef*, the compiler writes import/export
// metadata into it via the void* current_module field.
fn CompiledFunction*? compile_module(Lexer* lex, void* heap, char[] module_name, void* module_def) {
    $if features::SOURCE_COMPILER:
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
    // Modules are always strict (ECMA-262 Modules).
    ctx.is_strict = true;
    // Async-capable module bodies can suspend on top-level await. The sync
    // preset rejects await in the parser and uses an ordinary activation.
    ctx.is_async = features::ASYNC_GENERATORS;
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
        // [[HasTLA]] records actual suspension, separate from async capability.
        func.flags.has_tla = ctx.saw_top_level_await;
    }
    return result;
    $else
        return COMPILE_ERROR~;
    $endif
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
