module boomkat::compiler;

import boomkat::ast;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;
import std::collections::list;
import std::collections::set;

// ============================================================================
// Fault codes
// ============================================================================

faultdef COMPILE_ERROR;
faultdef SCOPE_ERROR;
faultdef REGISTER_OVERFLOW;
faultdef CODE_OVERFLOW;
faultdef CONST_OVERFLOW;

// ============================================================================
// Constants
// ============================================================================

const uint MAX_REGISTERS  = 65535;
const uint MAX_PARAMS     = 32;
// Sentinel for "no register" (used by local variables and fields that
// track an optional register index, e.g. call_prop_obj_reg).
const ushort REG_NONE = 0xFFFF;
// Starting capacities of growable compiler arrays; each doubles when full.
const uint INITIAL_CODE        = 512;
const uint INITIAL_CONSTANTS   = 128;
const uint INITIAL_CONST_HASH  = 256;
const uint INITIAL_INNER_FUNCS = 16;

// Hard limits (sanity caps to catch runaway compilation).
const uint MAX_CODE_HARD        = 1 << 22;  // 4M instructions
const uint MAX_CONSTANTS_HARD   = 1 << 20;  // 1M constants
const uint MAX_INNER_FUNCS_HARD = 1 << 22;  // as many as MAX_CODE_HARD has CLOSUREs
// Native stack the parser keeps free below its deepest check. It covers the
// frames between two checks (one nesting level of a function body runs about
// 50 KB of parser frames) plus the error path that unwinds from the check.
const usz COMPILE_STACK_RESERVE = 256 * 1024;
// Stack a compile may use on a platform that cannot report its stack bounds,
// measured from the first compile on the thread.
const usz COMPILE_STACK_FALLBACK = 512 * 1024;

extern fn uptr boomkat_stack_low();

// Lowest stack address the parser may reach on this thread; 0 until the
// first check computes it. Stack bounds are per thread and fixed for its life.
tlocal uptr g_compile_stack_floor;

// The parser recurses once per nesting level of the source, so deeply nested
// code (`((((`, `{{{{`, `!!!!`, nested functions) would overflow the native
// stack. Every recursive parse entry calls this first and turns an imminent
// overflow into a SyntaxError.
fn void? CompilerContext.check_stack(&self) {
    char marker;
    uptr sp = (uptr)&marker;
    if (g_compile_stack_floor == 0) {
        uptr low = boomkat_stack_low();
        g_compile_stack_floor = low != 0 ? low + COMPILE_STACK_RESERVE
                                         : sp - COMPILE_STACK_FALLBACK;
    }
    if (sp < g_compile_stack_floor) return self.fail("code nested too deeply")~;
}
// Initial capacity of the hoisted-function-name table; grows on the heap from
// here (see ensure_hoisted_fn_cap), so there is no fixed ceiling.
const uint INITIAL_HOISTED_FNS = 128;
// Initial capacity of the deferred-declaration tables, allocated lazily on the
// first body-scope function declaration (see ensure_hoisted_defer_cap).
const uint INITIAL_HOISTED_DEFERS = 8;
// Initial scope-stack capacity; grows on the heap from here (see
// ensure_scope_cap), so there is no fixed ceiling.
const uint INITIAL_SCOPE_DEPTH = 256;



// Sentinel for "no patch" in break/continue patch lists.
const uint NO_PATCH = 0xFFFF_FFFF;

// Hash table entry for constant pool deduplication.
// Maps constant TVal bits to constant pool index via open-addressing.
struct ConstHashEntry {
    ulong hash;   // 0 = empty slot; TVal bits otherwise
    uint  index;  // index into constants array
}

// ============================================================================
// Binary operator precedence levels (for Pratt parser)
// ============================================================================

const int PREC_NONE          = 0;
const int PREC_NULLISH       = 4;
const int PREC_LOGICAL_OR    = 5;
const int PREC_LOGICAL_AND   = 6;
const int PREC_BITWISE_OR    = 7;
const int PREC_BITWISE_XOR   = 8;
const int PREC_BITWISE_AND   = 9;
const int PREC_EQUALITY      = 10;
const int PREC_RELATIONAL    = 11;
const int PREC_SHIFT         = 12;
const int PREC_ADDITIVE      = 13;
const int PREC_MULTIPLICATIVE = 14;
const int PREC_EXPONENTIATION = 15;

// ============================================================================
// Supporting structures
// ============================================================================

enum ScopeKind : char {
    VAR,
    LET,
    CONST,
    SCOPEMARK,   ///< boundary marker pushed by block() to delimit scope
}

// Persistent declaration identity for analyses that run after lexical scopes
// have popped and their registers may have been reused.
struct BindingInfo {
    uint name_idx;
    ushort reg;
    ScopeKind kind;
    bool is_captured;
    bool is_param;
    bool is_catch_param;
}

struct ScopeEntry {
    char[] name;
    ushort reg;
    ScopeKind kind;
    // One past the highest binding register in this entry and every entry
    // below it, so reclaim_stmt_regs needs no walk.
    uint reg_floor;
    // One-based index into CompilerContext.bindings. Zero belongs to markers
    // and safely represents an entry without ledger metadata.
    uint binding_id;
    bool is_captured;
    // True for a let/const whose PUTLEX/PUTLEX_C is not yet emitted (still in its TDZ).
    // resolve_var returns SCOPE_ERROR for it, so reads compile to GETVAR and throw
    // ReferenceError against the INITTZ sentinel. Cleared by emit_var_store.
    bool is_tdz;
    // True for a formal or catch parameter (pushed with kind VAR). Only the early error
    // that a body let/const may not redeclare one needs this: a body var of the same name
    // is allowed, and kind alone cannot tell the two apart.
    bool is_param;
    // True for a catch parameter (a subkind of is_param). Its PUTLEX publishes it into the
    // catch's lex_env, above var_env, so a body var or for-head reusing it must PUTVAR
    // through the chain rather than write a shadow into var_env (B.3.5). Formal parameters
    // stay in var_env (DECLVAR), where a chain walk would be redundant.
    bool is_catch_param;
    // True for a FunctionDeclaration whose enclosing scope is a block (force_lexical_fn_decl).
    // Such a binding is block-scoped (PUTLEX) and also hoisted to function scope by B.3.3,
    // in this entry's register. check_var_lex_conflict reads it: sibling-block `function f`
    // declarations conflict, while a plain `var f` does not. VAR kind alone cannot tell
    // them apart.
    bool is_fn_decl;
    // True for a top-level `var` that a module resolution keeps
    // REGISTER-RESIDENT. Its register is the binding's only storage during
    // the body; the global property is just a mirror synced at end of script.
    // resolve_slot_global uses this to hand reads/writes the home register
    // while a block-shadowing `let`/`const` still resolves to the env.
    bool is_slot_global;
    // SCOPEMARK entries only: true for the marker a function BODY opens, as
    // opposed to a nested BlockStatement.  The parameter check above sees
    // through this marker (a body's top-level lexical names collide with the
    // parameter list) and stops at every other one (a nested block's shadow
    // it freely).
    bool is_body_mark;
}

struct LoopInfo {
    uint continue_target;
    uint break_patch_head;
    uint continue_patch_head; ///< chain of pending continue jumps (deferred until target resolved)
    bool is_loop;             ///< false for switch pseudo-loops (continue skips these)
    int  saved_lex_depth;     ///< cur_lex_depth at loop entry, break/continue POP_LEX back to this
int  saved_with_depth;   ///< cur_with_depth at loop entry, break/continue WITH_END back to this
    int  iter_close_reg;      ///< >= 0: for-of iterator reg, emit ITER_CLOSE on break/return; -1 = none
    bool is_await_loop;       ///< for-await-of: break/return unwind uses ITER_CLOSE_ASYNC (plan 057)
    // A `using` head's iterator close waits for the iteration's release in the
    // loop's own close boundary; every other loop closes at the jump site.
    bool deferred_close;
    // That boundary's "this iteration must close the iterator" flag.
    ushort close_reg;
    // try_depth at loop entry. A break/continue whose target loop was entered
    // at the same try_depth as the jump site crosses no try/catch/finally
    // boundary, so it must compile to a plain JUMP: BREAK/CONTINUE ask the VM
    // to route through the innermost active finally, which for a jump that
    // stays inside that same finally discards the completion it is carrying
    // (including a parked exception).
    uint saved_try_depth;
}

struct LabelInfo {
    char[] name;
    uint loop_index;   ///< index into loop_stack (NO_PATCH if not yet resolved)
    bool is_loop;      ///< true if this label refers to a loop (supports continue)
}

// The resources of the `using` declarations in one scope, and the completion
// in flight when the scope is left.
struct DisposeScope {
    ushort list_reg;      ///< the scope's resource list
    ushort pending_reg;   ///< the failure in flight when the scope is left
    ushort has_error_reg; ///< whether pending_reg holds a failure
    bool is_async;        ///< the scope holds an `await using` resource
}

// Tracks a break/continue patch chain for forward-patching jumps.
struct PatchEntry {
    uint addr;        // instruction index to patch
    uint next;        // index of next in chain, or NO_PATCH
}

// Tracks a parameter with a default value expression.
//
// A default that is a lone literal carries the instruction that loads it, with
// its operands already resolved against this function, instead of a thunk.
struct ParamDefault {
    ushort      param_reg;       // register holding the parameter
    uint        param_name_idx;  // constant index of the parameter name
    uint        default_func_idx; // index into inner_funcs for the default expression
    uint        ast_expr;         // eligible expression emitted in the parameter activation
    bool        is_literal;
    Instruction literal;         // loads the literal; its A operand is replaced by param_reg
}

// Outer `= default` of a destructured parameter, `f([x] = [])`. The arg slot is a plain
// register, not a binding. Recorded while parsing parameters and emitted by
// emit_destruct_param_defaults once every arg slot is final, so scratch registers cannot
// land on an unconsumed argument register.
struct DestructParamDefault {
    ushort arg_slot;          // register holding the (possibly-undefined) argument
    uint    default_func_idx; // index into inner_funcs for the default expression
}

// ============================================================================
// Compile-error recording (per-lexer; written on fault, read by callers)
// ============================================================================

// Record a compile error in the owning Lexer's buffer; the first writer wins. Position
// defaults to the lexer's current position. Callers that need another position set
// err_line/err_col themselves.
fn void CompilerContext.record_error(&self, char[] msg) {
    if (self.lexer.err_msg[0] != 0) return;
    self.lexer.err_line = self.lexer.line;
    self.lexer.err_col  = self.lexer.col;
    usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
    mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
    self.lexer.err_msg[copy_len] = 0;
}

// Record a compile error without touching the position fields. Used by BigInt literal
// paths, whose error is not anchored to a token. record_error is the position-carrying form.
fn void CompilerContext.set_compile_error(&self, char[] msg) {
    if (self.lexer.err_msg[0] != 0) return;
    usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
    mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
    self.lexer.err_msg[copy_len] = 0;
}

// Compiler debug toggle: when true, finish() skips every peephole pass. Set by the CLI
// --no-optimize flag. Useful to tell a code generation bug from a peephole bug.
bool g_disable_optimize = false;

fn void set_disable_optimize(bool v) { g_disable_optimize = v; }


// ============================================================================
// CompilerContext
// ============================================================================

struct FarOffset {
    uint addr;
    uint target;
}

struct CompilerContext {
    uint projection_node;
    uint projection_member;
    uint projection_key;
    uint projection_source;
    ushort projection_source_reg;
    ast::ScalarClass* scalar_fields;
    ushort scalar_first_arg;
    Lexer* lexer;
    void* heap;

    // Current function being compiled
    CompiledFunction* current_func;

    // Register allocation
    ushort next_reg;
    ushort max_reg;

    // Constant pool (growable)
    TVal* constants;
    uint const_count;
    uint const_cap;
    // Hash table for constant deduplication (growable, tracks constants)
    ConstHashEntry* const_hash;
    uint const_hash_count;
    uint const_hash_cap;
    // Insertion cap keeping at least 25% of slots empty so probes terminate early.
    uint const_hash_fill;

    // Code emission (growable)
    Instruction* code;
    uint code_count;
    uint code_cap;
    // Dense during emission so rewinds and NOP compaction preserve attribution.
    // CompiledFunction coalesces positions after bytecode relocation.
    SourcePosition* source_positions;

    // Inner functions (growable)
    CompiledFunction** inner_funcs;
    uint inner_func_count;
    uint inner_func_cap;

    // Scope tracking. Heap-allocated: a fixed array in this stack-local struct would be
    // charged against c3c's 64 KB stack-object budget. scope_overflow only fires if an
    // allocation fails.
    ScopeEntry* scope_stack;
    uint scope_cap;
    uint scope_depth;
    List{BindingInfo} bindings;
    ushort cell_frame_reg;
    bool cell_frame_reserved;
    // What resolution records of `arguments` in the body's own text (outside
    // nested callables): whether it names the identifier at all, whether it
    // sits in a position that could declare a binding of that name, and whether
    // the body contains `with`. reserve_arguments_register reads them.
    bool scan_arguments_mentioned;
    bool scan_arguments_declared;
    bool scan_has_with;
    // `arguments` is read only as the last argument of `f.apply(x, arguments)`,
    // and a parameter is captured by a nested callable or written.
    bool scan_arguments_apply_only;
    bool scan_params_captured;
    bool scan_params_written;
    // `arguments` lives in a register, bound by the VM at call entry, rather
    // than as a binding of the function's variable environment.
    bool arguments_in_reg;
    ushort arguments_reg;
    // The arguments register holds the argument count (CallFlags.forward_args).
    // forward_violation records a read of `arguments` other than APPLY_ARGS,
    // which takes the count form away.
    bool forward_args;
    bool forward_violation;

    // Enclosing loops and switches, innermost last.
    List{LoopInfo} loop_stack;
    // The disposal scopes in effect, innermost last. A scope owns the
    // resources of the `using` declarations in one block: the register
    // holding its resource list, the register holding the failure in flight
    // when the block is left, and the register telling whether there is one.
    List{DisposeScope} dispose_scopes;
    // Number of enclosing try statements. A break/continue compares it with its
    // target loop's saved_try_depth to decide whether it crosses a finally.
    uint try_depth;
    // Labels in scope, innermost last.
    List{LabelInfo} labels;
    // Break/continue forward-patch chains for the whole function. Entries are
    // never removed mid-function; each chain links through PatchEntry.next.
    List{PatchEntry} patches;
    // Set when the scope stack overflowed; finish() turns this into a compile
    // error. A dropped scope entry makes a declaration invisible to
    // shadowing/TDZ/duplicate checks rather than reporting anything.
    bool scope_overflow;

    // Track last identifier resolved via GETVAR (for assignment write-back)
    bool last_was_getvar;
    // Set alongside last_was_getvar when the read was emitted as GETGLOBAL
    // (true global scope, no nested lexical env). The assignment write-back
    // then emits PUTGLOBAL instead of PUTVAR_ASSIGN.
    bool last_was_getglobal;
    // Set when the last expression returned a live local variable register directly.
    bool last_was_local_var;
    ushort last_local_var_reg;
    // Set when parsing a parenthesized grouping expression.
    // Prevents call_expr from prematurely freeing call_prop_obj_reg
    // when the next token is not a call (e.g. RPAREN closing the parens).
    bool inside_parens;

    // When true, emit_private_access skips CHK_BRAND. emit_deferred_target sets it for private
    // field targets in destructuring assignment (ECMA-262 DestructuringAssignmentEvaluation):
    // the target is evaluated before GetV(value, key), but the brand check must run only after
    // the source property read. emit_destruct_bindings emits the deferred CHK_BRAND after the
    // GETPROP.
    bool defer_brand_check;
    // Register holding the deferred CHK_BRAND's brand symbol, set by emit_private_access when
    // defer_brand_check is true. The caller emits CHK_BRAND with it, then frees it.
    ushort deferred_brand_reg;
    // Constant-pool index for the private name in the deferred CHK_BRAND.
    uint deferred_brand_name_c;
    // Object register for the deferred CHK_BRAND.
    ushort deferred_brand_obj_reg;
    // When not 0xFFFF, emit_private_access uses this register for the brand symbol instead of
    // allocating one. emit_deferred_target sets it so the symbol sits below the GETPROP result
    // register: invoke_getter writes the getter's callee/this pair at [result_reg, result_reg + 1]
    // before the call, so a lazily allocated register could be clobbered before CHK_BRAND reads it.
    ushort deferred_brand_reg_hint;

    // Property call: the object register to use as 'this' in emit_call.
    // Set to REG_NONE when not in a property call.
    ushort call_prop_obj_reg;

    // Spread call: base of the evaluation region below first_arg that a plain
    // argument following a spread is compiled into, so its temps can never land
    // inside the spread's runtime dest window. Set by begin_spread_args, used
    // by the PUTARG emission sites.
    ushort spread_eval_base;

    // Register allocation ceiling (0xFFFF = no cap). alloc_reg/alloc_regs
    // clamp at it and flag reg_overflow instead of handing out a register at
    // or above it. Holds a spread call's trailing-argument evaluation below
    // the shifted callee; an expression needing more registers than the
    // reserved region is a compile error, never a corrupted argument list.
    ushort reg_cap;

    // Global scope flag: when true, all var decls use environment only (no register cache)
    bool is_global;
    // The AST scope of the function being compiled, set when its captures are
    // indexed; zero before that and for code the resolver did not see.
    uint func_ast_scope;

    // Eval mode: expression statements save their value to eval_acc_reg as eval's completion
    // value. Set only on the eval source's top-level context, the only one that allocates
    // eval_acc_reg. Nested function and arrow bodies have their own completion semantics, and
    // the register number is meaningless in their frame.
    bool   eval_mode;
    ushort eval_acc_reg;
    // True for the eval source's top-level context and for every arrow body nested in it. An
    // arrow inherits [[NewTarget]] from the eval code, so new.target's eval rules (see new_expr
    // in expressions.c3) still apply inside it, even though the arrow must not accumulate a
    // completion value.
    bool   in_eval_code;
    // True for direct eval called from a non-arrow function body, the only context where
    // new.target is allowed in the eval source. False for indirect eval, eval at script top
    // level, eval from an arrow body, or eval from a class constructor. new_expr() reads it to
    // reject new.target as a SyntaxError. Set by compile_eval from the activation that
    // builtin_eval passes in (see src/builtins/global.c3).
    bool   eval_direct_in_function;

    // Default parameter tracking
    List{ParamDefault} defaults;

    // Destructured-parameter outer-default tracking (deferred emission)
    List{DestructParamDefault} destruct_defaults;

    // Set while parsing FormalParameters when a parameter is a destructuring pattern. With
    // has_rest and defaults, this makes IsSimpleParameterList false (see params_are_simple).
    bool ast_param_scope;
    bool has_destructured_param;

    // Rest parameter tracking
    bool has_rest;
    ushort rest_formal_count;   // number of formals before rest parameter
    ushort num_args;            // total parameter count (including rest)
    ushort formal_count;        // params that count toward function.length
                                 // (= num_args, or count before first default/rest)

    // Class-related tracking
    bool is_constructable;      // true when compiling a class constructor
    bool in_class_body;         // true when parsing a class body (enables super)
    // True when the `__super__` binding holds the HomeObject (object-literal methods) rather
    // than a superclass constructor (class bodies). Selects GETPROTO- or .prototype-based
    // `super.x` emission.
    bool super_is_home_object;
    bool has_super_binding;     // true when class has extends (super() available)
    // True while compiling a static class method or accessor. Its HomeObject is the class
    // constructor (ECMA-262 GetSuperBase), so `super.x` resolves via __static_super__ (always
    // GETPROTO on the constructor), not __super__.
    bool super_is_static_method;
    // True while the innermost super-eligible scope is an object literal's method or accessor,
    // not a class body. Object literals bind their HomeObject as "__super__" (super_name_idx),
    // which can be reached while still in_class_body (an object literal nested in a class
    // method), so this flag cannot be inferred from in_class_body.
    bool super_home_is_object_literal;
    // Constant-pool index of the per-class `__super__` binding name. Each class with `extends`
    // gets its own, so classes in one function scope do not share a slot that the last
    // `extends` would clobber. 0xFFFFFFFF means unset (no enclosing class).
    uint super_name_idx;
    // Constant-pool index of the per-class `__static_super__` binding name,
    // mirroring super_name_idx.  0xFFFFFFFF means unset (no enclosing class
    // with static super access).
    uint static_super_name_idx;
    // Constant-pool index of the per-class `__home_object__` binding name. It is always the
    // class's own .prototype (the true [[HomeObject]] for instance methods, ECMA-262
    // GetSuperBase), so instance-method `super.x` reads GETPROTO(__home_object__) at run time.
    // 0xFFFFFFFF means unset (no enclosing class).
    uint home_object_name_idx;
    // Monotonic counter used to generate unique __super__ binding names
    // across classes within the same function scope.
    uint super_class_counter;

    // Private names declared by the open class bodies, shared by every context compiling one
    // class (see PrivateNameTable). The table is heap-allocated and owned by exactly one context
    // (owns_private_names). Growth reallocates entries in place, so borrowers never hold a stale
    // pointer.
    PrivateNameTable* private_name_table;
    // False when the table was borrowed via adopt_private_names; cleanup() must not free it.
    bool owns_private_names;
    // True while compiling a private field initializer body (__field_init__). `arguments` is a
    // SyntaxError there (ECMA-262 class field early errors): the initializer has no arguments
    // object of its own.
    bool forbid_arguments;
    // True while compiling a class static initialization block body. `return` at its own top
    // level is a SyntaxError (ECMA-262 ClassStaticBlockStatementList); nested functions may still
    // return.
    bool forbid_return;
    // True while compiling a class static initialization block body. `await` is always reserved
    // there, and the await operator is a SyntaxError (ECMA-262 ContainsAwait early error). Nested
    // function and arrow bodies get a fresh CompilerContext, so this flag does not carry over.
    bool forbid_await;
    // True while compiling a class static initialization block body. A `yield` reference at the
    // block's own level is a SyntaxError (ECMA-262 ClassStaticBlockStatementList is [~Yield]).
    // Nested function bodies reset it.
    bool forbid_yield;

    // True while parsing FormalParameters. Parameter defaults must reject yield and await
    // expressions, but destructuring defaults in a generator or async body may contain them.
    // compile_default_expr reads this to know which position it is compiling for.
    bool in_formal_params;

    // Generator tracking
    bool is_generator;          // true when compiling a generator function (function*)
                                // OR an async function (async also runs on the
                                // suspend/resume generator machinery via AWAIT).
    // The resolver scope of the function being generated (1 for the root).
    uint ast_fn_scope;
    // The generator inlined into a for-of loop (generator_fusion.c3), or null.
    FuseState* fuse;
    uint fuse_depth;
    bool is_user_generator;     // true only when the function was written with a
                                // syntactic `*` (function*, async function*, or a
                                // `*`/`async *` method). Distinguishes async
                                // generators from plain async functions.

// Lexical environment depth: incremented on each PUSH_LEX (block, for-in/of, class body) and
// decremented on POP_LEX. break/continue emit POP_LEX to unwind back to the loop's depth.
int  cur_lex_depth;

// Number of nested `with` statements. Each pairs with a runtime WITH_START/WITH_END, so an abrupt
// break/continue/return must emit WITH_END for every enclosing one.
int  cur_with_depth;

    // True when this function is compiled lexically inside a `with` body. A closure created
    // there captures the with-env, so every name it touches may resolve to the with object:
    // reads must go through the environment and fused fast paths are skipped. Separate from
    // cur_with_depth, which counts only this function's own with-envs.
    bool outer_with;

    // Per-function strictness. The entry point sets the unit default (sloppy for a script or
    // dynamic Function body, strict for a module). Class bodies are strict, and inner functions
    // inherit until a "use strict" directive is parsed.
    bool is_strict;
    // True only when a "use strict" directive was parsed. Kept separate because some checks need
    // the directive's presence, not the resulting strictness (e.g. directives in
    // non-simple-parameter functions).
    bool saw_use_strict;

    // arguments tracking
    bool uses_arguments;        // true when 'arguments' is referenced in function body

    // Local binding tracking for the needs_env decision. Set when the body declares var or
    // function names hoisted to function scope.
    bool has_local_bindings;
    // Set by declare_var for let/const. Lexical bindings live in PUSH_LEX envs, but a nested
    // closure reads them via the env chain (GETVAR), so a function with lexical bindings and
    // closures keeps its PUTLEX/PUTLEX_C/INITTZ stores and its runtime env.
    bool has_lexical_bindings;

    // Set by alloc_reg/alloc_regs when the register budget is exhausted. Compilation continues
    // with clamped registers to keep the parser in sync; finish() turns the flag into a
    // COMPILE_ERROR so a pathological source fails instead of aborting the host.
    bool reg_overflow;

    // True once a WIDE prefix has been emitted (an operand exceeded 255, so bytecode carries
    // 16-bit register indices). finish() skips every peephole and fusion pass for such
    // functions, since they read raw 8-bit fields.
    bool has_wide;

    // Permanent register floor: parameters and hoisted function-scope slots
    // allocated before body statements begin. Set at each body-compile site
    // (inner/arrow bodies, program/eval/module entry);
    // free_reg / free_regs_to never release registers below it.
    ushort reserved_regs;

    // Closure tracking, set when a nested function is defined in this body. With
    // has_local_bindings this decides needs_env: a function with var bindings and no nested
    // functions can skip its env.
    bool has_closures;
    // True once any local is forced through the environment (let/const shadowing an outer var,
    // catch parameter). Such a function keeps its scope object, since captured locals are read
    // via GETVAR.
    bool has_captured_local;
    // True for a named function expression whose CompiledFunction is tagged is_namebinding
    // (ECMA-262 named function expressions). The VM splices a per-call name env onto
    // var_env.parent, which is only safe on a per-call scope, so these functions never take the
    // needs_env=false path that reuses the shared captured var_env.
    bool is_named_func_expr;
    // The expression's own name is bound in a call-time environment and must
    // not resolve to an enclosing capture.
    char[] named_func_expr_name;

    // Capture publication
    // Names referenced inside nested callable bodies, collected by
    // resolution before the body compiles; declare_var marks matching
    // locals is_captured so all their access goes through the environment.
    List{char[]} captured_names;
    // Treat every local as captured when static resolution cannot name the
    // affected binding precisely, including direct eval and class fields.
    bool capture_all;

    // Hoisted function declaration names (so main pass can skip recompilation).
    // Top-level function declarations seen by the hoisting pre-pass. Heap-grown: one scope can
    // declare tens of thousands of functions.
    char[]* hoisted_fn_names;
    uint    hoisted_fn_cap;
    uint    hoisted_fn_count;
    // The same names, for lookup. Initialized with the first name.
    HashSet{String} hoisted_fn_set;
    // Eval code only: the source's var-declared names as constant-pool indices, collected by
    // hoist_one_var_name. Global-scope var entries never reach scope_stack, so this is the only
    // collection point. builtin_eval checks it for the ECMA-262 PerformEval intermediate-binding
    // collision.
    uint*   eval_var_coll_idxs;
    uint    eval_var_coll_cap;
    uint    eval_var_coll_count;

    // Every function declaration a body-scope hoist pass saw at the scope's top level: register,
    // inner function index, and name constant index. block() emits CLOSURE+DECLVAR from these once,
    // just after PUSH_LEX/INITTZ. Emitting in the hoist pass runs before PUSH_LEX, so the closure
    // cannot capture a body lexical binding. Emitting at the declaration's position creates a second
    // function object, so a property set on the binding earlier (`exports.c = c; function c(){}`)
    // would land on an object nothing else references. A repeated name overwrites its entry, leaving
    // the last declaration bound (ECMA-262 FunctionDeclarationInstantiation).
    char[]* hoisted_defer_names;
    ushort* hoisted_defer_regs;
    uint*   hoisted_defer_inner_idxs;
    uint*   hoisted_defer_name_idxs;
    uint    hoisted_defer_cap;
    uint    hoisted_defer_count;
    // Set once emit_hoisted_fn_decls has run, so a nested block cannot emit the declarations again.
    bool    hoisted_defer_emitted;

    // Block-nested function names that the sloppy B.3.3 hoist scan put into this scope. block()
    // checks this on entry, when enclosing lets are visible, to decide the B.3.3.1 step ii
    // exemption (entry init and publish). The scan creates the var entry unconditionally; when
    // block() finds the name exempt it erases that entry, leaving no binding. Heap-grown; freed in
    // cleanup().
    char[]* b33_hoisted_names;
    ushort* b33_hoisted_regs;
    uint*   b33_hoisted_pcs;
    uint    b33_hoisted_cap;
    uint    b33_hoisted_count;

    // Constant-pool indices of the top-level `var` / `function` names this Script unit declares as
    // globals (the names the check prologue guards with CHKGLOBALVAR/CHKGLOBALFUNC). A strict-mode
    // plain assignment to one of these names is statically resolvable, so its RESOLVEVAR/THROW_REF
    // guard is dead and elided. Indices, not slices, are stored: interned constants dedupe by content,
    // so a name maps to one index per context, avoiding the lexer scratch-buffer lifetime hazard.
    // Populated only for Script global scope (not modules, which bind via GETVAR, and not eval).
    // Grows on the thread allocator; freed in cleanup().
    HashSet{uint} declared_global_name_idxs;

    // Constant-pool indices of a module's top-level `var`s that
    // resolution keeps in registers: reads and writes
    // compile to the name's home register, a live slot for the whole body.
    List{uint} slot_global_name_idxs;

    // Direct eval tracking, when true, the CALL path must create a fresh env.
    bool has_direct_eval;
    // Set while compiling a `with` body. Reads/writes inside dynamic scope
    // must walk the env chain at runtime; peephole passes that assume a
    // static binding (INC_VAR/DEC_VAR fusion) skip functions with this set.
    bool has_with_stmt;
    // Code offsets of this function's direct-eval call instructions, ascending (emit_call appends
    // them). has_direct_eval cannot say which call is which, so `eval(x)` and `(0, eval)(x)` in one
    // function need these: builtin_eval looks up the call site it was reached through. finish()
    // copies the list into CompiledFunction.direct_eval_offsets.
    List{uint} direct_eval_offsets;
    // Conditional branches and TRY catch offsets too far for their 16-bit
    // field, by instruction index. widen_far_offsets gives each a WIDE prefix.
    List{FarOffset} far_offsets;

    // Arrow/async tracking, needed for needs_env computation in finish().
    bool is_arrow;
    bool is_async;

    // True for an ArrowFunction with no enclosing [[NewTarget]], i.e. one written directly in global
    // or module code (or nested in such an arrow). new.target there is a SyntaxError (ECMA-262
    // Static Semantics: Early Errors for Scripts). A separate flag, not is_global: is_global also
    // decides where declarations are registered, which would make the arrow's own vars global.
    bool no_new_target;

    // Module tracking, true when compiling an ESM module body.
    bool is_module;
    // Set when an `await` appears in this module's top-level context (ECMA-262 [[HasTLA]]). Module
    // bodies always compile as async, so this is the only sign that one actually suspends.
    bool saw_top_level_await;
    void* current_module;  // ModuleDef* (opaque to avoid import cycle)

    // True when the syntactic goal is Module. Set on the module-body context and propagated into
    // every nested function, arrow and generator. Unlike is_module (module body only), this stays
    // true inside nested functions, so `import.meta` is accepted anywhere in module code. It is also
    // the module half of the [Await] parameter (see await_reserved_here). It never affects `arguments`.
    bool module_goal;

    // Inferred name for the next anonymous function expression (ECMA-262 SetFunctionName). Set by
    // assignment to a plain identifier (`var f = function() {}`) and by object literal keys
    // (`o = { method() {} }`), then used and cleared by function_expr. Token text or a keep_name
    // copy, so it stays valid for the whole compile.
    char[] inferred_name;
    bool has_inferred_name;

    // Optimization toggle: when true, finish() skips the peephole passes. Set from
    // g_disable_optimize in init().
    bool disable_optimize;
}

// Copy a name built outside the source text (a formatted numeric key, a
// "#"-prefixed private name) into the lexer's arena, which lives as long as
// the compile, so it can be held as a slice like token text.
fn char[] CompilerContext.keep_name(&self, char[] name) {
    if (name.len == 0) return {};
    return self.lexer.arena_dup(name.ptr, name.len);
}

// Bracket the parser's inferred-name slot across a NamedEvaluation scope. Use:
//
//   NameEvalFrame _nef = self.save_name_eval();
//   defer self.restore_name_eval(_nef);
//   self.has_inferred_name = true;
//   ... seed the slot for this seed point ...
//   val = self.gen_expr(node, 0)!;
//
// The defer closes the bracket on every exit path (return, fault, panic). Used at all ECMA-262
// SetFunctionName seed points: var init, plain `=`, logical assignment, object-literal key,
// getter/setter body, method body, class field, `export default`.
struct NameEvalFrame {
    bool has;
    char[] name;
}

fn NameEvalFrame CompilerContext.save_name_eval(&self) {
    return {
        .has = self.has_inferred_name,
        .name = self.inferred_name,
    };
}

fn void CompilerContext.restore_name_eval(&self, NameEvalFrame f) {
    self.has_inferred_name = f.has;
    self.inferred_name = f.name;
}

// True when the recorded member is `super.x` / `super[k]`, whose store form is
// PUTPROP_SUPER (receiver = this, not the recorded home-prototype base).


// Base register of the recorded member.


// Property-key register of the recorded member (a private symbol when the
// member is `obj.#x`).


// True when the base is a live local's home register, so it must not be freed
// or reused as a scratch destination.


// ============================================================================
// CompilerContext, generator/async kind predicates
// ============================================================================

// True for an async generator body (`async function*` / `async *m(){}`):
// written with a `*` and async. The single predicate that replaces scattered
// flag-combination checks in the compiler.
macro bool CompilerContext.is_async_gen(&self) {
    return self.is_async && self.is_user_generator;
}

// True for a sync generator body (`function*`, `*m(){}`): a `*` that is not async.
macro bool CompilerContext.is_sync_generator(&self) {
    return self.is_user_generator && !self.is_async;
}

// ============================================================================
// CompilerContext, initialisation and finalisation
// ============================================================================

fn void CompilerContext.init(&self, Lexer* lex, void* heap) {
    mem::clear(self, (sz)(CompilerContext::size));
    self.lexer = lex;
    self.heap = heap;
    self.disable_optimize = g_disable_optimize;
    self.next_reg = 0;
    self.max_reg = 0;
    self.reg_cap = 0xFFFF;
    self.const_count = 0;
    self.code_count = 0;
    self.inner_func_count = 0;
    self.scope_depth = 0;
    self.try_depth = 0;
    self.scope_overflow = false;
    self.const_hash_count = 0;
    self.call_prop_obj_reg = REG_NONE;
    self.deferred_brand_reg_hint = 0xFFFF;
    self.super_name_idx = 0xFFFFFFFF;
    self.static_super_name_idx = 0xFFFFFFFF;
    self.home_object_name_idx = 0xFFFFFFFF;

    // Allocate growable buffers
    Heap* h = (Heap*)heap;
    self.code_cap = INITIAL_CODE;
    self.code = (Instruction*)h.alloc_func(h.heap_udata, (usz)(INITIAL_CODE * Instruction::size));
    self.source_positions = (SourcePosition*)h.alloc_func(h.heap_udata, (usz)(INITIAL_CODE * SourcePosition::size));
    self.scope_cap = INITIAL_SCOPE_DEPTH;
    self.scope_stack = (ScopeEntry*)h.alloc_func(h.heap_udata, (usz)(INITIAL_SCOPE_DEPTH * ScopeEntry::size));
    self.const_cap = INITIAL_CONSTANTS;
    self.constants = (TVal*)h.alloc_func(h.heap_udata, (usz)(INITIAL_CONSTANTS * TVal::size));
    self.const_hash_cap = INITIAL_CONST_HASH;
    self.const_hash_fill = INITIAL_CONST_HASH - INITIAL_CONST_HASH / 4;
    self.const_hash = (ConstHashEntry*)h.alloc_func(h.heap_udata, (usz)(INITIAL_CONST_HASH * ConstHashEntry::size));
    if (self.const_hash != null) {
        mem::clear(self.const_hash, (sz)((usz)(INITIAL_CONST_HASH * ConstHashEntry::size)));
    }
    self.inner_func_cap = INITIAL_INNER_FUNCS;
    self.inner_funcs = (CompiledFunction**)h.alloc_func(h.heap_udata, (usz)(INITIAL_INNER_FUNCS * CompiledFunction*::size));
    self.hoisted_fn_cap = INITIAL_HOISTED_FNS;
    self.hoisted_fn_names = (char[]*)h.alloc_func(h.heap_udata, (usz)(INITIAL_HOISTED_FNS * char[]::size));
    // Unallocated until a body-scope function declaration is actually seen;
    // ensure_hoisted_defer_cap allocates on the first one.
    self.hoisted_defer_cap = 0;
    self.hoisted_defer_names = null;
    self.hoisted_defer_regs = null;
    self.hoisted_defer_inner_idxs = null;
    self.hoisted_defer_name_idxs = null;
    PrivateNameTable* pnt = (PrivateNameTable*)h.alloc_func(h.heap_udata, (usz)PrivateNameTable::size);
    pnt.entries = (PrivateNameEntry*)h.alloc_func(h.heap_udata, (usz)(INITIAL_PRIVATE_NAMES * PrivateNameEntry::size));
    pnt.count = 0;
    pnt.cap = INITIAL_PRIVATE_NAMES;
    pnt.scopes.init(mem);
    self.private_name_table = pnt;
    self.owns_private_names = true;

    // Persistent (non-temp) allocator for the declared-global name-index set so
    // entries survive the whole compile; freed in cleanup().
    self.slot_global_name_idxs.allocator = mem;
    self.direct_eval_offsets.allocator = mem;
    self.far_offsets.allocator = mem;
    self.bindings.allocator = mem;
    self.captured_names.allocator = mem;
    self.defaults.allocator = mem;
    self.destruct_defaults.allocator = mem;
    self.loop_stack.allocator = mem;
    self.labels.allocator = mem;
    self.patches.allocator = mem;

    // Phase 3 (plans/083): do NOT default the lexer to strict mode here. Each
    // compilation entry point (compile/compile_eval/compile_function/etc.) is
    // responsible for setting the lexer's strict_mode to match ctx.is_strict
    // after init. init() runs before ctx.is_strict is meaningful, so trying to
    // mirror it here would either default to the wrong value (false, since
    // mem::clear zeros is_strict) or get clobbered anyway by every caller.
}

// Free the compiler's scratch buffers; the CompiledFunction from finish() owns
// its own copies. The context's owner defers this where it declares the
// context, so an error unwinding past it frees them too.
fn void CompilerContext.cleanup(&self) {
    Heap* h = (Heap*)self.heap;
    if (self.code != null) { h.free_func(h.heap_udata, self.code); self.code = null; }
    if (self.source_positions != null) { h.free_func(h.heap_udata, self.source_positions); self.source_positions = null; }
    if (self.scope_stack != null) { h.free_func(h.heap_udata, self.scope_stack); self.scope_stack = null; }
    if (self.constants != null) { h.free_func(h.heap_udata, self.constants); self.constants = null; }
    if (self.const_hash != null) { h.free_func(h.heap_udata, self.const_hash); self.const_hash = null; }
    if (self.inner_funcs != null) { h.free_func(h.heap_udata, self.inner_funcs); self.inner_funcs = null; }
    if (self.hoisted_fn_names != null) { h.free_func(h.heap_udata, self.hoisted_fn_names); self.hoisted_fn_names = null; }
    if (self.eval_var_coll_idxs != null) { h.free_func(h.heap_udata, self.eval_var_coll_idxs); self.eval_var_coll_idxs = null; }
    if (self.hoisted_defer_names != null) { h.free_func(h.heap_udata, self.hoisted_defer_names); self.hoisted_defer_names = null; }
    if (self.hoisted_defer_regs != null) { h.free_func(h.heap_udata, self.hoisted_defer_regs); self.hoisted_defer_regs = null; }
    if (self.hoisted_defer_inner_idxs != null) { h.free_func(h.heap_udata, self.hoisted_defer_inner_idxs); self.hoisted_defer_inner_idxs = null; }
    if (self.hoisted_defer_name_idxs != null) { h.free_func(h.heap_udata, self.hoisted_defer_name_idxs); self.hoisted_defer_name_idxs = null; }
    if (self.b33_hoisted_names != null) { h.free_func(h.heap_udata, self.b33_hoisted_names); self.b33_hoisted_names = null; }
    if (self.b33_hoisted_regs != null) { h.free_func(h.heap_udata, self.b33_hoisted_regs); self.b33_hoisted_regs = null; }
    if (self.b33_hoisted_pcs != null) { h.free_func(h.heap_udata, self.b33_hoisted_pcs); self.b33_hoisted_pcs = null; }
    if (self.owns_private_names && self.private_name_table != null) {
        if (self.private_name_table.entries != null) {
            h.free_func(h.heap_udata, self.private_name_table.entries);
        }
        self.private_name_table.scopes.free();
        h.free_func(h.heap_udata, self.private_name_table);
    }
    self.private_name_table = null;
    if (self.declared_global_name_idxs.is_initialized()) self.declared_global_name_idxs.free();
    if (self.hoisted_fn_set.is_initialized()) self.hoisted_fn_set.free();
    self.slot_global_name_idxs.free();
    self.direct_eval_offsets.free();
    self.far_offsets.free();
    self.bindings.free();
    foreach (name : self.captured_names) { mem::free(name.ptr); }
    self.captured_names.free();
    self.defaults.free();
    self.destruct_defaults.free();
    self.loop_stack.free();
    self.dispose_scopes.free();
    self.labels.free();
    self.patches.free();
}

// Borrow the private-names table from an enclosing context. Used by methods, default-parameter
// thunks and arrow bodies compiled for a class element, which only resolve private names and never
// declare into the table. Frees this context's own (still-empty) buffer first.
fn void CompilerContext.adopt_private_names(&self, CompilerContext* parent) {
    if (self.owns_private_names && self.private_name_table != null) {
        Heap* h = (Heap*)self.heap;
        if (self.private_name_table.entries != null) {
            h.free_func(h.heap_udata, self.private_name_table.entries);
        }
        self.private_name_table.scopes.free();
        h.free_func(h.heap_udata, self.private_name_table);
    }
    // Share the parent's table by pointer, so growth from a nested class's private declarations
    // (which may reallocate entries) is visible to both.
    self.private_name_table = parent.private_name_table;
    self.owns_private_names = false;
}

// Grow code buffer to accommodate more instructions.
fn void CompilerContext.ensure_code_cap(&self) {
    if (self.code_count < self.code_cap) return;
    uint new_cap = self.code_cap * 2;
    // A silent return would let emit() drop instructions with no recorded error. record_error
    // (not set_compile_error) keeps the current token's line and column.
    if (new_cap > MAX_CODE_HARD) {
        self.record_error("function too large (bytecode limit exceeded)");
        return;
    }
    Heap* h = (Heap*)self.heap;
    void* p = h.realloc_func(h.heap_udata, self.code, (usz)(new_cap * Instruction::size));
    if (p == null) {
        self.record_error("out of memory growing the bytecode buffer");
        return;
    }
    self.code = (Instruction*)p;
    void* lp = h.realloc_func(h.heap_udata, self.source_positions, (usz)(new_cap * SourcePosition::size));
    if (lp == null) {
        self.record_error("out of memory growing source positions");
        return;
    }
    self.source_positions = (SourcePosition*)lp;
    self.code_cap = new_cap;
}

// Grow the scope stack. Unlike the code and constant buffers, this has no hard cap; the depth is
// bounded by the source.
fn void CompilerContext.ensure_scope_cap(&self) {
    if (self.scope_depth < self.scope_cap) return;
    uint new_cap = self.scope_cap * 2;
    Heap* h = (Heap*)self.heap;
    void* p = h.realloc_func(h.heap_udata, self.scope_stack, (usz)(new_cap * ScopeEntry::size));
    if (p == null) {
        self.record_error("out of memory growing the scope stack");
        return;
    }
    self.scope_stack = (ScopeEntry*)p;
    self.scope_cap = new_cap;
}

// Whether a function declaration hoisted into this scope is named `name`.
fn bool CompilerContext.is_hoisted_fn(&self, char[] name) {
    return self.hoisted_fn_count > 0 && self.hoisted_fn_set.contains((String)name);
}

// Record a hoisted function declaration's name; false when it is already there.
fn bool CompilerContext.add_hoisted_fn(&self, char[] name) {
    if (self.is_hoisted_fn(name)) return false;
    self.ensure_hoisted_fn_cap();
    if (self.hoisted_fn_count >= self.hoisted_fn_cap) return true;
    if (!self.hoisted_fn_set.is_initialized()) self.hoisted_fn_set.init(mem);
    self.hoisted_fn_set.add((String)name);
    self.hoisted_fn_names[self.hoisted_fn_count] = name;
    self.hoisted_fn_count++;
    return true;
}

// Grow the hoisted-function-name table.
fn void CompilerContext.ensure_hoisted_fn_cap(&self) {
    if (self.hoisted_fn_count < self.hoisted_fn_cap) return;
    uint new_cap = self.hoisted_fn_cap * 2;
    Heap* h = (Heap*)self.heap;
    void* pn = h.realloc_func(h.heap_udata, self.hoisted_fn_names, (usz)(new_cap * char[]::size));
    if (pn == null) {
        self.record_error("out of memory growing the hoisted function table");
        return;
    }
    self.hoisted_fn_names = (char[]*)pn;
    self.hoisted_fn_cap = new_cap;
}

// Record a B.3.3 entry init: the hoisted name, the register of the LDUNDEF+DECLVAR_HOIST pair, and
// the DECLVAR_HOIST index. When block() proves the block exempt it NOPs that DECLVAR_HOIST and erases
// the scope entry, leaving no var binding. Names are interned: the token borrows lexer scratch that
// later tokens overwrite.
fn void CompilerContext.record_b33_hoist(&self, char[] var_name, uint var_reg, uint hoist_pc) {
    for (uint i = 0; i < self.b33_hoisted_count; i++) {
        if (str_eq(self.b33_hoisted_names[i], var_name)) return;
    }
    if (self.b33_hoisted_count >= self.b33_hoisted_cap) {
        uint new_cap = self.b33_hoisted_cap == 0 ? 8 : self.b33_hoisted_cap * 2;
        Heap* h = (Heap*)self.heap;
        void* pn = h.realloc_func(h.heap_udata, self.b33_hoisted_names, (usz)(new_cap * char[]::size));
        void* pr = h.realloc_func(h.heap_udata, self.b33_hoisted_regs, (usz)(new_cap * ushort::size));
        void* pc = h.realloc_func(h.heap_udata, self.b33_hoisted_pcs, (usz)(new_cap * uint::size));
        if (pn == null || pr == null || pc == null) {
            if (pn != null) self.b33_hoisted_names = (char[]*)pn;
            if (pr != null) self.b33_hoisted_regs = (ushort*)pr;
            if (pc != null) self.b33_hoisted_pcs = (uint*)pc;
            self.record_error("out of memory growing the B.3.3 table");
            return;
        }
        self.b33_hoisted_names = (char[]*)pn;
        self.b33_hoisted_regs = (ushort*)pr;
        self.b33_hoisted_pcs = (uint*)pc;
        self.b33_hoisted_cap = new_cap;
    }
    HString* hs = ((Heap*)self.heap).str_intern(var_name);
    self.b33_hoisted_names[self.b33_hoisted_count] = hs.get_data();
    self.b33_hoisted_regs[self.b33_hoisted_count] = (ushort)var_reg;
    self.b33_hoisted_pcs[self.b33_hoisted_count] = hoist_pc;
    self.b33_hoisted_count++;
}

// The B.3.3 record index for `name`, or -1 when the scan hoisted nothing
// under it into this scope (nested boundary skipped it, or a `var`/param
// entry already covered it).


// Grow the deferred-declaration tables, allocating them on the first body-scope
// function declaration. All four grow together: they are parallel arrays.
fn void CompilerContext.ensure_hoisted_defer_cap(&self) {    if (self.hoisted_defer_cap != 0 && self.hoisted_defer_count < self.hoisted_defer_cap) return;
    uint new_cap = self.hoisted_defer_cap == 0 ? INITIAL_HOISTED_DEFERS : self.hoisted_defer_cap * 2;
    Heap* h = (Heap*)self.heap;
    void* pn = h.realloc_func(h.heap_udata, self.hoisted_defer_names, (usz)(new_cap * char[]::size));
    void* pr = h.realloc_func(h.heap_udata, self.hoisted_defer_regs, (usz)(new_cap * ushort::size));
    void* pi = h.realloc_func(h.heap_udata, self.hoisted_defer_inner_idxs, (usz)(new_cap * uint::size));
    void* px = h.realloc_func(h.heap_udata, self.hoisted_defer_name_idxs, (usz)(new_cap * uint::size));
    if (pn == null || pr == null || pi == null || px == null) {
        // Keep whichever grew: they are only ever read below hoisted_defer_count,
        // which is not advanced when this fails.
        if (pn != null) self.hoisted_defer_names = (char[]*)pn;
        if (pr != null) self.hoisted_defer_regs = (ushort*)pr;
        if (pi != null) self.hoisted_defer_inner_idxs = (uint*)pi;
        if (px != null) self.hoisted_defer_name_idxs = (uint*)px;
        self.record_error("out of memory growing the deferred declaration table");
        return;
    }
    self.hoisted_defer_names = (char[]*)pn;
    self.hoisted_defer_regs = (ushort*)pr;
    self.hoisted_defer_inner_idxs = (uint*)pi;
    self.hoisted_defer_name_idxs = (uint*)px;
    self.hoisted_defer_cap = new_cap;
}

// Grow constant pool and hash table.
fn void CompilerContext.ensure_const_cap(&self) {
    if (self.const_count < self.const_cap) return;
    uint new_cap = self.const_cap * 2;
    // As in ensure_code_cap, a silent return would drop the constant with no recorded error.
    if (new_cap > MAX_CONSTANTS_HARD) {
        self.record_error("too many constants in one function");
        return;
    }
    Heap* h = (Heap*)self.heap;

    // Grow constants array
    void* p = h.realloc_func(h.heap_udata, self.constants, (usz)(new_cap * TVal::size));
    if (p == null) {
        self.record_error("out of memory growing the constant pool");
        return;
    }
    self.constants = (TVal*)p;
    self.const_cap = new_cap;

    // Grow hash table proportionally and rehash
    uint new_hash_cap = new_cap * 2;
    void* hp2 = h.realloc_func(h.heap_udata, self.const_hash, (usz)(new_hash_cap * ConstHashEntry::size));
    if (hp2 == null) return;
    self.const_hash = (ConstHashEntry*)hp2;
    self.const_hash_cap = new_hash_cap;
    self.const_hash_fill = new_hash_cap - new_hash_cap / 4;
    // Rehash: clear and reinsert
    mem::clear(self.const_hash, (sz)((usz)(new_hash_cap * ConstHashEntry::size)));
    self.const_hash_count = 0;
    for (uint i = 0; i < self.const_count; i++) {
        self.insert_constant_hash(self.constants[i].get_raw_bits(), i);
    }
}

// Grow inner functions array.
fn void CompilerContext.ensure_inner_func_cap(&self) {
    if (self.inner_func_count < self.inner_func_cap) return;
    uint new_cap = self.inner_func_cap * 2;
    if (new_cap > MAX_INNER_FUNCS_HARD) {
        self.record_error("function too large (nested function limit exceeded)");
        return;
    }
    Heap* h = (Heap*)self.heap;
    void* p = h.realloc_func(h.heap_udata, self.inner_funcs, (usz)(new_cap * CompiledFunction*::size));
    if (p == null) {
        self.record_error("out of memory growing the nested function table");
        return;
    }
    self.inner_funcs = (CompiledFunction**)p;
    self.inner_func_cap = new_cap;
}

// Grow the private-names table.
fn void CompilerContext.ensure_private_name_cap(&self) {
    PrivateNameTable* t = self.private_name_table;
    if (t.count < t.cap) return;
    uint new_cap = t.cap * 2;
    if (new_cap > MAX_PRIVATE_NAMES_HARD) return;
    Heap* h = (Heap*)self.heap;
    void* p = h.realloc_func(h.heap_udata, t.entries, (usz)(new_cap * PrivateNameEntry::size));
    if (p == null) return;
    // Mutate the SHARED table in place: every borrower reads t.entries/t.cap
    // through the same PrivateNameTable*, so this relocation is seen by all.
    t.entries = (PrivateNameEntry*)p;
    t.cap = new_cap;
}

// Register an inner function and return its index.
fn uint CompilerContext.add_inner_func(&self, CompiledFunction* func) {
    self.resolve_capture_candidates(func);
    self.ensure_inner_func_cap();
    if (self.inner_func_count >= self.inner_func_cap) return 0;
    uint idx = self.inner_func_count;
    self.inner_funcs[idx] = func;
    self.inner_func_count++;
    self.has_closures = true;
    return idx;
}

// Whether a parameter default is a thunk closure. Literal defaults read no
// binding, so they leave the parameter scope unobservable.
fn bool CompilerContext.has_thunk_defaults(&self) {
    if (self.ast_param_scope) return true;
    foreach (d : self.defaults) {
        if (!d.is_literal) return true;
    }
    return false;
}

// Whether the finished code of `func` and its inner functions read `func`'s
// own `this`, apart from direct eval, which the caller rules out. See
// CallFlags.ignores_this for the readers.
fn bool body_ignores_this(CompiledFunction* func) {
    for (uint i = 0; i < func.code_count; i++) {
        switch (func.code[i].op) {
            case Opcode.LDTHIS:
            case Opcode.GETTHISC:
            case Opcode.PUTTHISC:
            case Opcode.GETPROP_SUPER:
            case Opcode.PUTPROP_SUPER:
            case Opcode.SUPER_CALL:
            case Opcode.SUPER_CALL_S:
                return false;
            default:
        }
    }
    for (uint i = 0; i < func.inner_count; i++) {
        if (func.inner_funcs[i] != null && func.inner_funcs[i].is_arrow()) return false;
    }
    return true;
}

// Whether the function's `this` binding is the same for its whole run: an
// arrow takes its binding from the enclosing function, and a derived
// constructor's starts uninitialized until a super() call, possibly from a
// nested arrow or an eval, binds it.
fn bool CompilerContext.this_cannot_change(&self) {
    if (self.is_arrow || self.has_direct_eval) return false;
    for (uint i = 0; i < self.code_count; i++) {
        Opcode op = self.code[i].op;
        if (op == Opcode.SUPER_CALL || op == Opcode.SUPER_CALL_S) return false;
    }
    for (uint i = 0; i < self.inner_func_count; i++) {
        if (self.inner_funcs[i] != null && self.inner_funcs[i].is_arrow()) return false;
    }
    return true;
}

// Finalise compilation: allocate a CompiledFunction and copy code/constants.
fn CompiledFunction*? CompilerContext.finish(&self) {
    // An arrow whose bindings are plain parameters and locals can use its
    // captured environment directly once nothing observes them by name
    // (prune_unobserved_environment_stores drops their declarations, or keeps
    // the scopes if one survives). Keep every case with dynamic lookup or
    // nested closures on the regular scope path.
    bool can_remove_empty_arrow_scopes = self.is_arrow
                                   && !self.has_thunk_defaults()
                                   && self.destruct_defaults.len() == 0
                                   && !self.has_captured_local
                                   && !self.has_direct_eval
                                   && !self.has_with_stmt
                                   && !self.outer_with
                                   && !self.is_generator
                                   && !self.is_async;
    if (self.reg_overflow) {
        return self.fail("register limit exceeded")~;
    }
    if (self.scope_overflow) {
        return self.fail("too many nested scopes or declarations in one function")~;
    }
    // A lex error seen only through peek_type() is swallowed there as a synthetic EOF_TOKEN. Catch it
    // here, at the choke point all compile entry points share, so a lookahead-only error cannot
    // produce a clean EOF and a successful compile.
    if (self.lexer.err_msg[0] != 0) {
        return COMPILE_ERROR~;
    }
    Heap* h = (Heap*)self.heap;
    // Allocate the CompiledFunction struct
    void* raw = h.alloc_func(h.heap_udata, CompiledFunction::size);
    if (raw == null) {
        return COMPILE_ERROR~;
    }
    mem::clear(raw, (sz)(CompiledFunction::size));

    CompiledFunction* func = (CompiledFunction*)raw;
    func.flags.htype = HType.OBJECT;
    func.realm = h.realm;

    // --- True register high-water mark ---
    //
    // max_reg counts only registers the allocator handed out. A call reads a window the allocator
    // never allocated one by one: the callee frame at callee_reg, with `this` at callee_reg+1 and the
    // arguments above it (see reserve_call_frame). The window's top slot can sit at max_reg, one past
    // the last allocated register, so anything sized by max_reg would exclude it (moveelim's bitsets,
    // func.num_regs). Take the mark from the emitted code, where the window is visible.
    uint hw_max = (uint)self.max_reg;
    for (uint hi = 0; hi < self.code_count; hi++) {
        Instruction hins = self.code[hi];
        uint htop = 0;
        switch (hins.op) {
            case Opcode.CALL:
            case Opcode.CALL_UNDEF_THIS:
            case Opcode.NEW_OBJ:
            case Opcode.SUPER_CALL:
                // callee at B, `this` at B+1, then C arguments.
                htop = (uint)hins.b + 1 + (uint)hins.c;
            case Opcode.CALL_VAR:
            case Opcode.CALL_GLOBAL:
                // callee/result at A, then B arguments above `this`.
                htop = (uint)hins.a + 1 + (uint)hins.b;
            case Opcode.CLASS_SCALAR_GUARD:
                htop = (uint)hins.a + 1 + (uint)hins.b;
            default:
                continue;
        }
        if (htop + 1 > hw_max) { hw_max = htop + 1; }
    }
    if (hw_max > MAX_REGISTERS) { hw_max = MAX_REGISTERS; }


    promote_uncaptured_var_bindings(self, h);

    // --- Peephole: fuse GETVAR + INC/DEC + PUTVAR into INC_VAR/DEC_VAR ---
    // GETVAR r, name  /  INC r  /  PUTVAR r, name   →   NOP  /  INC_VAR name  /  NOP
    // Declarative: see src/compiler/fusion.c3 (FUSION_INC_DEC_VAR).
    //
    // Skipped for a function containing `with`: its GETVAR/PUTVAR must walk the env chain at run
    // time, and INC_VAR's fast path writes the cached env slot directly.
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 3 && !self.has_with_stmt) {
        fuse_inc_dec_var(self.code, self.code_count, self.const_count);
    }

    // --- Peephole: fuse LDCONST rK, idx + GETPROP ra = rb, rK → NOP + GETPROPC ra = rb, idx ---
    // GETPROPC.c holds the constant index, so a jump into the NOP slot still reads the right key.
    // A branch to the GETPROPC itself is rejected by the jump-target guard in run_fusion_rule.
    //
    // Declarative: see src/compiler/fusion.c3 (FUSION_GETPROPC). The jump-target bitset needs a
    // code_count-sized bool scratch, allocated here so fusion.c3 stays heap-free.
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 2) {
        bool* gp_jump_targets = (bool*)h.alloc_func(h.heap_udata, (usz)self.code_cap);
        if (gp_jump_targets == null) return COMPILE_ERROR~;
        fuse_getpropc(self.code, self.code_count, gp_jump_targets, self.constants);
        fuse_putpropc(self.code, self.code_count, gp_jump_targets, self.constants);
        fuse_getthisc(self.code, self.code_count, gp_jump_targets);
        if (self.this_cannot_change()) {
            fuse_putthisc(self.code, self.code_count, gp_jump_targets);
        }
        h.free_func(h.heap_udata, gp_jump_targets);
    }

    // --- Peephole: fuse compare (LT/LE/GT/GE/SEQ/SNEQ) + IF_FALSE/IF_TRUE ---
    // Declarative, jump-aware driver in fusion.c3 (run_cmp_branch_fusion): owns
    // the whole-function jump-target bitset, dual-path liveness, bridge/short-
    // circuit corrections and offset math once, table-driven over the compare
    // form. Relational forms fuse to JMP_N*/JMP_*; strict equality to JMP_SEQ/
    // JMP_SNEQ; loose EQ/NEQ to JMP_EQ/JMP_NEQ. LNOT feeding a branch becomes the
    // inverted branch. Needs a code_count-sized bool scratch buffer for the jump-target
    // bitset, allocate it here to keep fusion.c3 free of heap dependencies.
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 2) {
        drop_jumps_to_next(self.code, self.code_count);
        if (has_cmp_branch_pair(self.code, self.code_count)) {
            // Per-instruction live-out and live-in sets, then the three
            // working sets moveelim_compute_liveness needs, in one block.
            usz n = (usz)self.code_cap;
            usz nsets = 2 * n + 3;
            uint words_per_set = (hw_max + 31) / 32;
            if (words_per_set < 1) { words_per_set = 1; }
            bool* jump_targets = (bool*)h.alloc_func(h.heap_udata, n);
            bool* in_try = (bool*)h.alloc_func(h.heap_udata, n);
            RegSet* sets = (RegSet*)h.alloc_func(h.heap_udata, nsets * RegSet::size);
            uint* words = (uint*)h.alloc_func(h.heap_udata, nsets * (usz)words_per_set * uint::size);
            if (jump_targets != null && in_try != null && sets != null && words != null) {
                for (usz i = 0; i < nsets; i++) {
                    sets[i] = { .words = &words[i * words_per_set], .word_count = words_per_set };
                }
                moveelim_mark_jump_targets_and_try_regions(self.code, self.code_count, jump_targets, in_try);
                moveelim_compute_liveness(self.code, self.code_count, sets, &sets[n], true, &sets[2 * n]);
                run_cmp_branch_fusion(self.code, self.code_count, jump_targets, sets, in_try);
            }
            if (jump_targets != null) { h.free_func(h.heap_udata, jump_targets); }
            if (in_try != null) { h.free_func(h.heap_udata, in_try); }
            if (sets != null) { h.free_func(h.heap_udata, sets); }
            if (words == null) return COMPILE_ERROR~;
            h.free_func(h.heap_udata, words);
            if (jump_targets == null || in_try == null || sets == null) return COMPILE_ERROR~;
        }
    }

    // --- Peephole: copy propagation, NOP LDREG rT = rS when immediately followed
    // by a consumer that reads rT as a plain register operand (b or c), rT is dead
    // after the consumer, and rS is not clobbered between them (trivially true since
    // they are adjacent).
    //
    // Supported consumers: the JMP_* compare-branch family (b/c = register
    //   operands; this pass runs before the immediate forms exist),
    //   LT/LE/GT/GE/ADD/SUB/MUL (b/c = register operands in ABC format).
    // GETPROPC is excluded: its c field is a constant-pool index, not a register.
    //
    // Jump-target safety: the consumer slot must not be a jump target.
    //
    // A branch landing on the consumer never executed the LDREG, so it set
    // neither rT nor rS through this pair; it arrived with rT already holding the
    // value it wants. After substitution the consumer reads rS, which that path
    // never wrote. A ternary's join is exactly this shape:
    //
    //       IF_FALSE cond -> false_arm
    //       <true arm>  ... writes rT      JUMP -> join
    //     false_arm:
    //       <false arm> ... writes rS
    //       LDREG rT = rS                  <- this pair
    //     join:
    //       ADD  rD = rD, rT               <- jump target
    //
    // Collapsing that to `ADD rD = rD, rS` makes the true arm's JUMP land on an
    // ADD reading the false arm's scratch, so `5 + (c ? 10 : 20)` yields 25 for
    // every condition, silently and with no error.
    //
    // The LDREG slot itself being a jump target is allowed: control landing there
    // falls through into a consumer reading rS, and every branch targeting a
    // parser-emitted LDREG is a loop back-edge onto a body whose rS is a live
    // local, re-read each iteration, rather than a per-arm scratch. Guarding it
    // would cost the `total = total + i` loop-body copy elision for no
    // correctness gain; golden_bytecode/loop_addi covers that.
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 2) {
        bool* cp_jump_targets = (bool*)h.alloc_func(h.heap_udata, (usz)self.code_cap);
        if (cp_jump_targets == null) return COMPILE_ERROR~;
        build_jump_targets(self.code, self.code_count, cp_jump_targets);
        for (uint i = 0; i + 1 < self.code_count; i++) {
            if (cp_jump_targets[i + 1]) { continue; }
            if (self.code[i].op != Opcode.LDREG) { continue; }

            uint rT = (uint)self.code[i].a;
            uint rS = (uint)self.code[i].b;  // get_bc() lower byte; c is 0 for LDREG

            Instruction consumer = self.code[i + 1];
            Opcode cop = consumer.op;

            // Determine whether this consumer op reads b and/or c as plain registers
            // and whether rT appears in those fields.
            bool cop_reads_b_c = bytecode::is_cmp_branch(cop) ||
                cop == Opcode.LT || cop == Opcode.LE ||
                cop == Opcode.GT || cop == Opcode.GE ||
                cop == Opcode.ADD || cop == Opcode.SUB || cop == Opcode.MUL;

            if (!cop_reads_b_c) { continue; }

            uint cb = (uint)consumer.b;
            uint cc = (uint)consumer.c;
            bool rT_in_b = (cb == rT);
            bool rT_in_c = (cc == rT);
            if (!rT_in_b && !rT_in_c) { continue; }

            // rT must be dead after the consumer: scan forward from i+2.
            // If the consumer itself writes rT (consumer.a == rT), the LDREG value is
            // immediately overwritten by the consumer, no scan needed, rT is dead.
            //
            // Otherwise scan forward for a use of rT before a redefinition. Ending
            // the scan on `A == rT` requires that A really is a write-only
            // destination for that opcode: RET and the IF_TRUE/IF_FALSE family read
            // A instead, so treating them as a kill declares a still-live register
            // dead and NOPs a store the program depends on. That is exactly how
            // `for (o = i + (s = c); ...)` lost its `s = c`: the only later mention
            // of s was the function's own `RET s`, whose A field ended the scan.
            //
            // The write-only test is `moveelim_a_is_write` (src/compiler/moveelim.c3),
            // a positive allow-list of opcodes confirmed to treat A as a pure
            // destination. A deny-list is unsound here: any opcode not reasoned
            // about defaults to "not a kill", so the scan keeps looking and the
            // copy is merely left in place. Over-approximating liveness costs an
            // optimization; under-approximating it miscompiles.
            //
            // The scan is linear over slots, not a CFG walk, so inside the
            // window a conditional branch can skip, the instructions it sees are
            // not guaranteed to execute. A write there kills rT only on the
            // fall-through path, so `join_pc` (the furthest pending branch
            // target) suppresses the kill until the paths rejoin. Without it,
            // `(o=1)-(r=1)<0 && (r=o)` lost its `r=1`: r's only later mention is
            // the conditional `r=o`, whose A field ended the scan, so the copy
            // feeding SUB was propagated away and r stayed undefined on the
            // not-taken path.
            //
            // A loop back-edge re-runs code ahead of the copy, so the forward walk
            // can step over a read that happens on the next iteration: the loop
            // head reads rT, the copy at i sets it, the walk passes the back-edge
            // and stops at a later write. For any branch back to i + 1 or earlier,
            // rT stays live when the re-run stretch reads it before writing it.
            // Mandreel's initPhysics lost a loop-carried value this way.
            bool rT_live = false;
            int back = fusion_branch_target(self.code, i + 1);
            if (back >= 0 && back <= (int)i + 1
                && fusion_reg_read_before_write(self.code, (uint)back, i, rT)) {
                rT_live = true;
            }
            // A compare-and-branch keeps its jump offset in A, which names no register.
            bool consumer_writes_rT = !bytecode::is_cmp_branch(cop) && (uint)consumer.a == rT;
            if (!rT_live && !consumer_writes_rT) {
                // The consumer is itself a conditional branch: its taken path
                // skips the writes just after it, so they kill rT only past
                // its target.
                int join_pc = fusion_conditional_branch_target(self.code, i + 1);
                for (uint j = i + 2; j < self.code_count; j++) {
                    Instruction jns = self.code[j];
                    Opcode jop2 = jns.op;
                    int bt_any = fusion_branch_target(self.code, j);
                    if (bt_any >= 0 && bt_any <= (int)i + 1
                        && fusion_reg_read_before_write(self.code, (uint)bt_any, i, rT)) {
                        rT_live = true;
                        break;
                    }
                    if (jop2 == Opcode.IF_TRUE || jop2 == Opcode.IF_FALSE) {
                        if ((uint)jns.a == rT) { rT_live = true; break; }
                        int t = fusion_conditional_branch_target(self.code, j);
                        if (t > join_pc) { join_pc = t; }
                        continue;
                    }
                    OpFormat jfmt = bytecode::get_op_format(jop2);
                    if (jfmt == OpFormat.ABC) {
                        if ((uint)jns.b == rT || (uint)jns.c == rT) { rT_live = true; break; }
                    }
                    int bt = fusion_conditional_branch_target(self.code, j);
                    if (bt > join_pc) { join_pc = bt; }
                    if ((int)j >= join_pc && jfmt != OpFormat.WIDE_SABC && jfmt != OpFormat.WIDE_ABC) {
                        if ((uint)jns.a == rT) {
                            if (moveelim_a_is_write(jop2)) { break; }
                            rT_live = true;
                            break;
                        }
                    }
                }
            }
            if (rT_live) { continue; }

            // Substitute rS for rT in the consumer's b/c fields.
            uint new_b = rT_in_b ? rS : cb;
            uint new_c = rT_in_c ? rS : cc;
            self.code[i + 1] = bytecode::make_abc(cop, (uint)consumer.a, new_b, new_c);
            self.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        }
        h.free_func(h.heap_udata, cp_jump_targets);
    }

    // --- Peephole: fuse LDINT rK, imm + rD = …,rK → NOP + <op>I rD = rS, imm ---
    // Runs after copy propagation, which NOPs the LDREG moves between an LDINT and its consumer.
    //
    // Declarative: see src/compiler/fusion.c3 (FUSION_IMM_BINOP). The jump-target guard matters: in
    // `5 + (c ? 10 : 20)` the false arm sits next to the join, so without it the false arm's literal
    // would be baked into an immediate that the true arm jumps onto. The bitset needs a code_count-sized
    // bool scratch.
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 2) {
        bool* addi_jump_targets = (bool*)h.alloc_func(h.heap_udata, (usz)self.code_cap);
        if (addi_jump_targets == null) return COMPILE_ERROR~;
        fuse_imm_binop(self.code, self.code_count, addi_jump_targets);
        fuse_null_branch(self.code, self.code_count, addi_jump_targets);
        h.free_func(h.heap_udata, addi_jump_targets);
    }

    // --- Liveness-based move elimination: `producer rT=... ; LDREG rDst=rT`
    // -> retarget producer to write rDst directly, NOP the LDREG.
    // Runs after copy propagation and the fusion passes, so the producer before a surviving LDREG is
    // in final form. Runs before NOP compaction, which removes the NOPs it introduces. See
    // src/compiler/moveelim.c3 for the liveness analysis.
    // Remove unobserved declarations before liveness examines their sources.
    bool scopes_removed = prune_unobserved_environment_stores(self, h, can_remove_empty_arrow_scopes);

    if (!self.disable_optimize && !self.has_wide && self.code_count >= 2) {
        usz bufsz = (usz)self.code_cap;
        bool* me_jump_targets = (bool*)h.alloc_func(h.heap_udata, bufsz);
        bool* me_in_try       = (bool*)h.alloc_func(h.heap_udata, bufsz);
        // live_out/live_in include call-window liveness for the dead-destination check. ret_out/ret_in
        // exclude it and drive producer retargeting (see moveelim.c3).
        //
        // Sized by hw_max, not max_reg: a call window's top slot can sit one past max_reg, and a bitset
        // that excludes it makes moveelim_mark_range clamp the window. A fixed MAX_REGISTERS-wide set
        // would cost 8 KB per instruction, so the sets are sized by the registers this function uses.
        uint words_per_set = (hw_max + 31) / 32;
        if (words_per_set < 1) { words_per_set = 1; }
        usz n = (usz)self.code_cap;
        RegSet* me_live_out = (RegSet*)h.alloc_func(h.heap_udata, n * RegSet::size);
        RegSet* me_live_in  = (RegSet*)h.alloc_func(h.heap_udata, n * RegSet::size);
        RegSet* me_ret_out  = (RegSet*)h.alloc_func(h.heap_udata, n * RegSet::size);
        RegSet* me_ret_in   = (RegSet*)h.alloc_func(h.heap_udata, n * RegSet::size);
        // (4 * n) per-instruction sets + 4 scratch sets + 1 pinned set.
        uint* me_words = (uint*)h.alloc_func(h.heap_udata, (4 * n + 5) * (usz)words_per_set * uint::size);
        if (me_jump_targets == null || me_in_try == null || me_live_out == null || me_live_in == null
            || me_ret_out == null || me_ret_in == null || me_words == null) {
            if (me_jump_targets != null) { h.free_func(h.heap_udata, me_jump_targets); }
            if (me_in_try != null) { h.free_func(h.heap_udata, me_in_try); }
            if (me_live_out != null) { h.free_func(h.heap_udata, me_live_out); }
            if (me_live_in != null) { h.free_func(h.heap_udata, me_live_in); }
            if (me_ret_out != null) { h.free_func(h.heap_udata, me_ret_out); }
            if (me_ret_in != null) { h.free_func(h.heap_udata, me_ret_in); }
            if (me_words != null) { h.free_func(h.heap_udata, me_words); }
            return COMPILE_ERROR~;
        }
        for (usz i = 0; i < n; i++) {
            me_live_out[i].word_count = words_per_set;
            me_live_out[i].words = &me_words[(0 * n + i) * words_per_set];
            me_live_in[i].word_count = words_per_set;
            me_live_in[i].words = &me_words[(1 * n + i) * words_per_set];
            me_ret_out[i].word_count = words_per_set;
            me_ret_out[i].words = &me_words[(2 * n + i) * words_per_set];
            me_ret_in[i].word_count = words_per_set;
            me_ret_in[i].words = &me_words[(3 * n + i) * words_per_set];
        }
        RegSet[4] me_scratch;
        for (usz s = 0; s < 4; s++) {
            me_scratch[s].word_count = words_per_set;
            me_scratch[s].words = &me_words[(4 * n + s) * words_per_set];
        }
        // A mapped `arguments` object aliases parameter slot i (ECMA-262 arguments exotic objects), and
        // the VM reads those slots directly rather than through bytecode, so liveness cannot see the
        // reader. Pin them: otherwise a store whose only observer is `arguments[i]` (`function f(a){ a = 1;
        // return arguments[0]; }`) is removed as a dead destination. The condition mirrors the
        // func.flags.mapped_arguments computation below.
        RegSet me_pinned;
        me_pinned.word_count = words_per_set;
        me_pinned.words = &me_words[(4 * n + 4) * words_per_set];
        me_pinned.clear();
        bool me_has_pinned = false;
        if (!self.is_strict && self.uses_arguments && !self.has_rest
            && !self.ast_param_scope && self.defaults.len() == 0 && self.destruct_defaults.len() == 0
            && !self.has_destructured_param && !self.is_arrow && !self.eval_mode) {
            // Parameters occupy r0..r(num_args-1) in declaration order (see
            // emit_param_prologue).
            for (ushort ai = 0; ai < self.num_args; ai++) {
                me_pinned.set((uint)ai);
                me_has_pinned = true;
            }
        }
        run_move_elimination(self.code, self.code_count, me_jump_targets, me_in_try, me_live_out, me_live_in,
                             me_ret_out, me_ret_in, &me_scratch[0],
                             me_has_pinned ? &me_pinned : null);
        if (eliminate_parameter_aliases(self, me_jump_targets)) {
            run_move_elimination(self.code, self.code_count, me_jump_targets, me_in_try, me_live_out, me_live_in,
                                 me_ret_out, me_ret_in, &me_scratch[0],
                                 me_has_pinned ? &me_pinned : null);
        }
        // Proper tail calls (ECMA-262 tail calls). Runs after move elimination, so retargeted
        // producers already write the call result into its final register. Runs before NOP
        // compaction, which removes the RET this leaves behind. Reuses the jump-target and
        // try-region maps that move elimination built: it only retargets operands and NOPs
        // instructions in place, so they still match.
        moveelim_mark_jump_targets_and_try_regions(self.code, self.code_count,
                                                   me_jump_targets, me_in_try);
        eliminate_join_allocation(self, me_jump_targets, me_in_try,
                                  me_live_out, me_live_in, &me_scratch[0]);
        thread_returns(self.code, self.code_count, me_jump_targets, me_in_try);
        moveelim_mark_jump_targets_and_try_regions(self.code, self.code_count,
                                                   me_jump_targets, me_in_try);
        if (self.is_strict) run_tail_calls(self.code, self.code_count, me_jump_targets, me_in_try);
        h.free_func(h.heap_udata, me_jump_targets);
        h.free_func(h.heap_udata, me_in_try);
        h.free_func(h.heap_udata, me_live_out);
        h.free_func(h.heap_udata, me_live_in);
        h.free_func(h.heap_udata, me_ret_out);
        h.free_func(h.heap_udata, me_ret_in);
        h.free_func(h.heap_udata, me_words);
    }

    // --- NOP Compaction Pass ---
    // Physically remove NOP instructions and remap all pc-relative offsets.
    // Must run last, after all other peepholes have introduced NOPs.
    //
    // TRY is always followed by a NOP whose BC field holds the finally_offset. The VM reads that word
    // unconditionally, so it must survive compaction: mark those slots in keep[] before building pc_map.
    if (self.far_offsets.len() > 0) self.widen_far_offsets()!;
    if (self.code_count > 0) {
        bool* nop_keep = null;
        uint* pc_map = null;
        uint new_count = 0;
        if (!self.disable_optimize) {
            // Step 1: mark TRY jump slots as non-removable.
            nop_keep = (bool*)h.alloc_func(h.heap_udata, (usz)self.code_cap);
            if (nop_keep == null) return COMPILE_ERROR~;
            mem::clear(nop_keep, (sz)((usz)self.code_count));
            for (uint i = 0; i < self.code_count; i++) {
                if (self.code[i].op == Opcode.TRY && i + 1 < self.code_count) {
                    nop_keep[i + 1] = true;
                }
            }
            // A WIDE prefixing a NOP that is about to go would widen the next
            // instruction instead, so it goes too.
            for (uint i = 0; i + 1 < self.code_count; i++) {
                if (self.code[i].op == Opcode.WIDE && self.code[i + 1].op == Opcode.NOP && !nop_keep[i + 1]) {
                    self.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                }
            }

            // Step 2: build pc_map[old_pc] → new_pc.
            // NOP slots that are not kept map to the new_pc of the next kept slot.
            pc_map = (uint*)h.alloc_func(h.heap_udata, (usz)((long)(self.code_cap + 1) * (long)uint::size));
            if (pc_map == null) { h.free_func(h.heap_udata, nop_keep); return COMPILE_ERROR~; }
            for (uint i = 0; i < self.code_count; i++) {
                pc_map[i] = new_count;
                if (self.code[i].op != Opcode.NOP || nop_keep[i]) {
                    new_count++;
                }

            }
            pc_map[self.code_count] = new_count; // sentinel for targets at end

            // Step 3: remap all branch/handler offsets in-place.
            for (uint i = 0; i < self.code_count; i++) {
                Opcode cop = self.code[i].op;
                switch (cop) {
                    case Opcode.JUMP:
                    case Opcode.BREAK:
                    case Opcode.CONTINUE: {
                        // WIDE_SABC: target = (pc+1) + sabc
                        int sabc = self.code[i].get_sabc();
                        int tgt_old = (int)i + 1 + sabc;
                        int tgt_new = (int)pc_map[(uint)tgt_old];
                        int new_sabc = tgt_new - ((int)pc_map[i] + 1);
                        self.code[i] = bytecode::make_sabc(cop, new_sabc);
                    }
                    case Opcode.IF_TRUE:
                    case Opcode.IF_FALSE: {
                        // A_SBX: target = (pc+1) + sbx
                        // The full offset, including a WIDE prefix's bits; NOP
                        // removal only shrinks it, so it still fits.
                        int sbx = (int)bytecode::code_bc(self.code, i) - (int)bytecode::BC_BIAS;
                        int tgt_old = (int)i + 1 + sbx;
                        int tgt_new = (int)pc_map[(uint)tgt_old];
                        int new_sbx = tgt_new - ((int)pc_map[i] + 1);
                        bytecode::set_code_bc(self.code, i, (uint)(new_sbx + (int)bytecode::BC_BIAS));
                    }
                    case Opcode.JMP_NLT..Opcode.JMP_SNEQI: {
                        // ABC: signed 8-bit offset in field A; target = (pc+1) + (int)(char)a
                        // NOP removal only shrinks distances, so the new offset is <= old.
                        int off = (int)(ichar)self.code[i].a;
                        int tgt_old = (int)i + 1 + off;
                        int tgt_new = (int)pc_map[(uint)tgt_old];
                        int new_off = tgt_new - ((int)pc_map[i] + 1);
                        // Offset must still fit in signed 8 bits (removal only shrinks gaps).
                        $assert $defined(new_off);
                        self.code[i].a = (uint)(char)new_off;
                    }
                    case Opcode.TRY: {
                        // A_BC: BC = catch_offset (absolute from TRY instruction).
                        // Adjacent slot i+1 (NOP, kept): the finally offset, same base.
                        uint try_new = pc_map[i];
                        uint catch_off_old = bytecode::code_bc(self.code, i);
                        uint catch_tgt_old = i + catch_off_old;
                        uint new_catch_off = pc_map[catch_tgt_old] - try_new;
                        uint finally_off_old = bytecode::try_finally_offset(self.code[i + 1]);
                        uint new_finally_off = 0;
                        if (finally_off_old != 0) {
                            uint finally_tgt_old = i + finally_off_old;
                            new_finally_off = pc_map[finally_tgt_old] - try_new;
                        }
                        bytecode::set_code_bc(self.code, i, new_catch_off);
                        self.code[i + 1] = bytecode::make_finally_slot(new_finally_off);
                    }
                    default: {}
                }
            }

        }

        // Step 4: copy the (possibly compacted) instruction stream into the
    // CompiledFunction.  When disable_optimize is true we still copy, we
    // just keep every instruction (including the peephole-produced NOPs).
    uint final_count = self.disable_optimize ? self.code_count : new_count;
    usz code_bytes = (usz)final_count * Instruction::size;
    void* code_raw = h.alloc_func(h.heap_udata, code_bytes);
    // Relocation passes need a position for each surviving instruction;
    // finish() coalesces their PC ranges after captured-binding lowering.
    void* source_raw = null;
    if (final_count > 0 && self.source_positions != null) {
        source_raw = h.alloc_func(h.heap_udata, (usz)final_count * SourceEntry::size);
    }
    if (code_raw == null || (final_count > 0 && self.source_positions != null && source_raw == null)) {
        if (source_raw != null) { h.free_func(h.heap_udata, source_raw); }
        if (code_raw != null) { h.free_func(h.heap_udata, code_raw); }
        if (!self.disable_optimize) {
            h.free_func(h.heap_udata, pc_map);
            h.free_func(h.heap_udata, nop_keep);
        }
        h.free_func(h.heap_udata, raw);
        return COMPILE_ERROR~;
    }
    Instruction* dst_code = (Instruction*)code_raw;
    SourceEntry* dst_source = (SourceEntry*)source_raw;
    uint dst_idx = 0;
    if (self.disable_optimize) {
        // Copy everything verbatim, preserves all NOPs introduced by the
        // peephole passes, but the VM treats NOP as no-op so execution is
        // correct.  Useful for debugging: every instruction the peephole
        // produced is visible in the dump.
        for (uint i = 0; i < self.code_count; i++) {
            dst_code[dst_idx] = self.code[i];
            if (dst_source != null) dst_source[dst_idx] = { dst_idx, self.source_positions[i] };
            dst_idx++;
        }
    } else {
        for (uint i = 0; i < self.code_count; i++) {
            if (self.code[i].op != Opcode.NOP || nop_keep[i]) {
                dst_code[dst_idx] = self.code[i];
                if (dst_source != null) dst_source[dst_idx] = { dst_idx, self.source_positions[i] };
                dst_idx++;
            }
        }
    }
    func.code = dst_code;
    func.source_map = dst_source;
    func.source_map_count = dst_source != null ? final_count : 0;
    func.code_count = final_count;

    if (!self.disable_optimize && !self.has_wide && !self.is_async) {
        fuse_threaded_pairs(dst_code, final_count, nop_keep);
    }

    // Direct-eval call sites: copy the offsets emit_call collected, so
    // builtin_eval can tell a direct call from an indirect one made from the
    // same body. The offsets index the pre-compaction stream, so they go
    // through pc_map alongside the jump targets.
    if (self.direct_eval_offsets.len() > 0) {
        uint de_count = (uint)self.direct_eval_offsets.len();
        uint* de_buf = (uint*)h.alloc_func(h.heap_udata, (usz)de_count * uint::size);
        if (de_buf != null) {
            for (uint i = 0; i < de_count; i++) {
                uint off = self.direct_eval_offsets[i];
                de_buf[i] = self.disable_optimize ? off : pc_map[off];
            }
            func.direct_eval_offsets = de_buf;
            func.direct_eval_offset_count = de_count;
        }
        // On alloc failure the array stays null and builtin_eval falls back to
        // treating every eval from this body as direct, which is what the
        // has_direct_eval flag alone says.
    }

    if (!self.disable_optimize) {
        h.free_func(h.heap_udata, pc_map);
        h.free_func(h.heap_udata, nop_keep);
    }
}

    // Copy the source name (a file path, module specifier, or "<eval>") into a
    // heap-owned buffer so it outlives the compile. `mem`, like the function
    // name and retained source text: free_compiled_funcs releases all three
    // with mem::free and cannot tell the allocators apart. Non-fatal on
    // allocation failure, matching how the function name is set.
    {
        char[] src_name = self.lexer.source_name;
        if (src_name.len > 0) {
            char* fname = (char*)alloc::malloc_try(mem, (sz)((usz)src_name.len + 1)) ?? null;
            if (fname != null) {
                for (usz i = 0; i < (usz)src_name.len; i++) fname[i] = src_name[i];
                fname[src_name.len] = 0;
                func.filename_ptr = fname;
                func.filename_len = (uint)src_name.len;
            }
        }
    }

    // Copy constant pool
    if (self.const_count > 0) {
        usz const_bytes = (usz)self.const_count * TVal::size;
        void* const_raw = h.alloc_func(h.heap_udata, const_bytes);
        if (const_raw == null) {
            if (func.code != null) { h.free_func(h.heap_udata, func.code); }
            if (func.source_map != null) { h.free_func(h.heap_udata, func.source_map); }
            if (func.filename_ptr != null) { mem::free(func.filename_ptr); }
            h.free_func(h.heap_udata, raw);
            return COMPILE_ERROR~;
        }
        mem::copy(const_raw, &self.constants[0], (sz)(const_bytes));
        func.constants = (TVal*)const_raw;
        func.const_count = self.const_count;
    }

    // Copy inner functions
    if (self.inner_func_count > 0) {
        usz inner_bytes = (usz)self.inner_func_count * CompiledFunction*::size;
        void* inner_raw = h.alloc_func(h.heap_udata, inner_bytes);
        if (inner_raw == null) {
            if (func.code != null) { h.free_func(h.heap_udata, func.code); }
            if (func.source_map != null) { h.free_func(h.heap_udata, func.source_map); }
            if (func.constants != null) { h.free_func(h.heap_udata, func.constants); }
            if (func.filename_ptr != null) { mem::free(func.filename_ptr); }
            h.free_func(h.heap_udata, raw);
            return COMPILE_ERROR~;
        }
        mem::copy(inner_raw, &self.inner_funcs[0], (sz)(inner_bytes));
        func.inner_funcs = (CompiledFunction**)inner_raw;
        func.inner_count = self.inner_func_count;
    }

    // Sized by hw_max, not max_reg: the VM's register frame must include the
    // whole call window (see the hw_max computation above).
    func.num_regs = (ushort)(hw_max > (uint)self.max_reg ? hw_max : (uint)self.max_reg);
    func.flags.has_rest = self.has_rest;
    func.flags.is_constructable = self.is_constructable;
    // is_class_ctor is NOT derived here: ordinary function expressions nested
    // inside class methods also compile with in_class_body set (for super),
    // so any heuristic on compiler state over-matches.  The class compiler
    // stamps the flag directly on the constructor's CompiledFunction
    // (make_default_constructor and the explicit-ctor path in class.c3).
    func.flags.is_generator = self.is_generator;
    func.flags.is_user_generator = self.is_user_generator;
    func.flags.is_async = self.is_async;
    func.flags.is_arrow = self.is_arrow;
    func.flags.is_strict = self.is_strict;
    // A direct eval's source is opaque at compile time, so it may reference
    // `arguments` even though the enclosing function's own parsed text never
    // does (ECMA-262 PerformEval materializes the caller's arguments
    // binding regardless). Force uses_arguments here for any ordinary
    // function containing a direct eval so the VM creates the arguments
    // object the eval body's runtime GETVAR lookup depends on. Arrows and
    // eval bodies themselves have no `arguments` binding of their own, so
    // this is skipped for them, a direct eval nested in an arrow or in
    // another eval body resolves `arguments` through the nearest enclosing
    // ordinary function's binding instead (arrows propagate has_direct_eval
    // to that enclosing context explicitly; eval re-dispatch always runs
    // with 0 args, so setting this here for eval_mode would create a bogus
    // EMPTY arguments object that shadows the real one).
    func.flags.uses_arguments = self.uses_arguments
                             || (self.has_direct_eval && !self.is_arrow && !self.eval_mode);
    // Mapped arguments (plans/083 Phase 3.1): sloppy + simple parameter list
    // per ECMA-262 arguments exotic objects. Simplicity reads the same three signals
    // params_are_simple() uses (rest, defaults incl. destructured defaults,
    // destructured params). Direct-eval-forced uses_arguments is unmapped:
    // the flag only guarantees an object exists for the eval body, and the
    // eval body is not this function's own parameter scope.
    func.flags.mapped_arguments = !self.is_strict && self.uses_arguments
                             && !self.has_rest && self.defaults.len() == 0
                             && self.destruct_defaults.len() == 0
                             && !self.has_destructured_param
                             && !self.is_arrow && !self.eval_mode;
    // Direct eval must run in the caller's lexical environment: the CALL
    // paths only set ACT_FLAG_DIRECT_EVAL (which builtin_eval checks) when
    // this flag is present on the compiled function.
    func.flags.has_direct_eval = self.has_direct_eval;
    func.flags.has_home_object = self.in_class_body || self.super_is_home_object;
    func.flags.super_is_home_object = self.super_is_home_object;
    func.flags.forbid_arguments = self.forbid_arguments;
    func.call_flags.ignores_this = !self.has_direct_eval && body_ignores_this(func);
    func.call_flags.arguments_in_reg = self.arguments_in_reg;
    func.call_flags.forward_args = self.forward_args && !self.forward_violation;
    func.arguments_reg = self.arguments_reg;

    // `needs_env` controls whether the CALL fast path allocates a fresh
    // env record + bindings object per call (2 allocations).  We only need
    // a fresh env when the function's scope is actually accessed at runtime:
    //   - var bindings captured by a nested closure
    //   - arguments object
    //   - direct eval
    //   - default-valued parameters (parameter expressions need a fresh env
    //     because of ECMA-262 FunctionDeclarationInstantiation: a separate env for params so closures
    //     in default expressions don't see body var declarations)
    // Functions with var declarations but no closures, eval, or arguments
    // can reuse the parent's env directly.
    bool has_params_needing_env = self.ast_param_scope || self.has_rest || self.defaults.len() > 0;
    bool needs_runtime_env = ((self.has_local_bindings || self.has_lexical_bindings || self.num_args > 0) && self.has_closures)
                          || (self.uses_arguments && !self.arguments_in_reg)
                          || self.has_direct_eval;
    // can_skip_env: only for functions that share the parent's environment
    // record, both for var declarations and for closures created inside.
    // A function with `var` declarations (or `let`/`const`/params) must own
    // a fresh env so its DECLVAR/DECLVAR_HOIST/DECLVAR writes land on its
    // own scope rather than the captured parent (e.g. a global record or
    // a `with` object); otherwise a body like `var x = ...` called from
    // inside `with` would walk the chain and write through to the with-env.
    // A function compiled inside a `with` body (outer_with) likewise owns
    // one: every name it touches resolves through the environment (see the
    // outer_with contract above), so its own params/locals must live in an
    // env — with needs_env=false the CALL path reuses the captured parent
    // env and the bindings have nowhere to land.
    bool can_skip_env = !needs_runtime_env
                     && !has_params_needing_env
                     && !self.has_captured_local
                     && !self.has_local_bindings
                     && !self.outer_with
                     && !self.is_arrow
                     && !self.is_generator
                     && !self.is_async
                     && !self.is_named_func_expr;
    if (!can_skip_env && can_reuse_binding_environment(self)) {
        can_skip_env = true;
    }
    func.flags.needs_env = !can_skip_env;
    // An arrow keeps no scope of its own once its scope instructions are gone.
    if (self.is_arrow && can_remove_empty_arrow_scopes && scopes_removed) func.flags.needs_env = false;
    func.flags.is_global = self.is_global;
    // eval_mode only means "accumulate a completion value", which a global
    // Script also asks for ($262.evalScript). Whether this is EVAL code --
    // which makes var/function bindings configurable (env_declare_var's `D`
    // argument) -- is in_eval_code.
    func.flags.is_eval = self.in_eval_code;
    func.flags.eval_src_strict = self.saw_use_strict;
    // Record whether this body may reference new.target, so a direct eval
    // called from it can inherit the permission (see
    // FuncFlags.eval_allows_new_target).
    //
    // Two kinds of body need it. An EVAL body: legal exactly when the eval was
    // direct and its call site sat in a non-arrow function. An ARROW: it has no
    // [[NewTarget]] of its own and inherits the enclosing code's, so it may
    // reference new.target precisely when that enclosing code could -- which is
    // what no_new_target already tracks (true for an arrow in global/module
    // code, false for one inside a function). Without this, the runtime saw
    // only is_arrow() on the caller and rejected every direct eval from inside
    // an arrow, including the legal function > arrow > eval("new.target").
    if (self.in_eval_code) {
        func.flags.eval_allows_new_target = self.eval_direct_in_function;
    } else if (self.is_arrow) {
        func.flags.eval_allows_new_target = !self.no_new_target;
    }
    func.num_args = self.num_args;
    if (func.flags.mapped_arguments && self.num_args != 0) {
        bool any_captured = false;
        foreach (&b : self.bindings) {
            any_captured |= b.is_param && b.is_captured && b.reg < self.num_args;
        }
        if (any_captured) {
            heap::Heap* fh = (heap::Heap*)self.heap;
            uint* names = (uint*)fh.alloc_func(fh.heap_udata, (usz)self.num_args * uint::size);
            if (names != null) {
                for (uint i = 0; i < self.num_args; i++) names[i] = bytecode::NO_FORMAL_NAME;
                foreach (&b : self.bindings) {
                    if (b.is_param && b.is_captured && b.reg < self.num_args) names[b.reg] = b.name_idx;
                }
                func.formal_names = names;
            }
        }
    }
    if (self.has_rest) {
        func.num_formals = self.rest_formal_count;
    } else if (self.defaults.len() > 0 || self.destruct_defaults.len() > 0) {
        // First default param doesn't count toward .length; formals before it do.
        func.num_formals = self.formal_count;
    } else {
        func.num_formals = self.num_args;
    }

    // The inline caches are created on the function's first run
    // (Dispatch.bind_caches), so code that never executes carries none.
    if (func.code_count > 0) {
        // Allocate NEWREGEXP literal compile cache, one ReCompiled* slot per
        // constant-pool entry, keyed by the regexp literal's constant index,
        // zeroed (null = not yet compiled).
        if (func.const_count > 0) {
            usz rec_bytes = (usz)func.const_count * (usz)void*::size;
            void* rec_raw = h.alloc_func(h.heap_udata, rec_bytes);
            if (rec_raw != null) {
                mem::clear(rec_raw, (sz)(rec_bytes));
                func.regexp_cache = (void**)rec_raw;
                func.regexp_cache_count = func.const_count;
            }
        }
    }

    // Track the CompiledFunction for cleanup when the heap is destroyed
    heap::Heap* hp = (heap::Heap*)self.heap;
    hp.track_compiled_func(raw);

    // Direct-eval private-name snapshot (ECMA-262 PrivateEnvironment): if this function has
    // `direct eval` calls AND inherited private names from a parent class body,
    // copy the table into a heap-tracked buffer so builtin_eval can later
    // hand it to compile_eval. cleanup() frees the scratch buffer, and the
    // snapshot needs to outlive this context.
    //
    // Only snapshot when the table was ADOPTED from a parent, `owns_private_names
    // == false` means an outer class compiled the entries. A table owned by
    // this context means WE declared the names here, so direct eval can only
    // see them via the lex env chain (no class scope to inherit), and a
    // snapshot would just duplicate what GETVAR already finds at runtime.
    if (self.has_direct_eval
        && !self.owns_private_names
        && self.private_name_table != null
        && self.private_name_table.count > 0
        && self.private_name_table.entries != null) {
        uint snap_count = self.private_name_table.count;
        usz snap_bytes = (usz)snap_count * PrivateNameEntry::size;
        PrivateNameEntry* snap = (PrivateNameEntry*)h.alloc_func(h.heap_udata, snap_bytes);
        if (snap != null) {
            // memcpy the entire entry table, every entry's name/slot_name/
            // brand_slot_name slices point at interned HString data (stable),
            // so the byte-level copy is safe.
            mem::copy(snap, self.private_name_table.entries, (sz)(snap_bytes));
            func.eval_private_names = (void*)snap;
            func.eval_private_name_count = snap_count;
        }
        // If alloc fails, leave the snapshot null, eval will just not see
        // inherited private names (matches the pre-fix behaviour). Failing
        // the compile here would be worse: a transient alloc hiccup would
        // break every class-body eval test.
    }

    // Super-binding-name snapshot: any function compiled inside a class
    // records the HString* of that class's numbered __super__ binding (e.g.
    // "__super__0"). builtin_eval re-interns it into the eval context's
    // constant pool so direct `eval("super.x")` GETVARs the numbered
    // binding instead of the literal "__super__", which is not in the
    // env chain; Object.setPrototypeOf's class sync (object.c3) writes
    // the new [[Prototype]] under this name.
    if (self.super_name_idx != 0xFFFFFFFF) {
        func.super_binding_name = self.constants[self.super_name_idx].get_heapptr();
    }
    if (self.static_super_name_idx != 0xFFFFFFFF) {
        func.static_super_binding_name = self.constants[self.static_super_name_idx].get_heapptr();
    }
    if (self.home_object_name_idx != 0xFFFFFFFF) {
        func.home_object_binding_name = self.constants[self.home_object_name_idx].get_heapptr();
    }

    build_await_liveness(self, func, hp);
    if (self.has_direct_eval || self.has_with_stmt || self.outer_with) {
        restore_dynamic_capture_names(func);
    }
    self.collect_capture_candidates(func);
    lower_captured_bindings(self, func, hp);
    lower_rest_length(self, func, hp);

    uint source_capacity = func.source_map_count;
    func.compact_source_map();
    if (func.source_map_count > 0 && func.source_map_count < source_capacity) {
        void* compact = hp.realloc_func(hp.heap_udata, func.source_map,
            (usz)func.source_map_count * SourceEntry::size);
        if (compact != null) func.source_map = (SourceEntry*)compact;
    }

    return func;
}

struct ClassMethod {
    char[] name;
    uint   inner_idx;
    bool   is_static;
    bool   is_getter;
    bool   is_setter;
    bool   name_is_number;          // true when name came from a NUMBER token
    double name_num_value;          // numeric value when name_is_number is true
    bool   name_is_bigint;          // true when name came from a BIGINT token
    char[] name_bigint_src;         // raw literal text (digits) when name_is_bigint is true
    uint   computed_key_inner_idx;  // MAX_INNER_FUNCS = not computed
    // When the enclosing context is a generator/async, computed keys that
    // contain yield/await must be compiled inline (not as a separate inner
    // function) so they interact with the enclosing generator/async.
    // Sentinel value 0xFFFFFFFE means "key expression compiled inline;
    // computed_key_reg holds the result register."
    uint   computed_key_reg;        // register holding inline key result (0xFFFF = none)
    // Private method/accessor (P3/P4): the key register is loaded via GETVAR
    // from this compiler-managed slot binding name (the private symbol),
    // instead of LDCONST from `name`/`computed_key_*`.
    bool   is_private;
    char[] priv_slot_name;          // e.g. "#priv:3:foo", the name's own symbol
}

// ============================================================================
// Private class members, name resolution scope
// ============================================================================

// Initial capacity of the growable private-names table (across all nested
// class bodies) tracked in a single function/program compile; grows via
// ensure_private_name_cap as classes declare more names.
const uint INITIAL_PRIVATE_NAMES = 64;

// Hard upper bound on distinct private names, mirroring the other growable
// compiler tables' *_HARD caps.
const uint MAX_PRIVATE_NAMES_HARD = 1 << 20;

// Shared, heap-allocated backing store for the private-names stack. A single
// class compile involves many CompilerContexts (the class-enclosing `self`
// plus per-element field/method/arrow/block bodies), all of which resolve,
// and some of which DECLARE (a nested class inside a field initializer),
// against the SAME logical private-name stack. They share one PrivateNameTable
// through a pointer so that a growth (realloc of `entries`) done by any one of
// them is immediately visible to all the others: growing in place mutates this
// struct, never a per-context copy, so no borrower is left holding a stale
// `entries` pointer into a freed buffer.
struct PrivateNameTable {
    PrivateNameEntry* entries;
    uint count;
    uint cap;
    // Open class bodies, innermost last. Each class pushes one around its body
    // and pops it before the context that pushed it resumes, so every context
    // sharing the table sees the class nesting at its own point in the source.
    List{PrivateScope} scopes;
}

// One open class body: where its names begin in `entries` (pop trims back to
// here) and its compile-time class id, which makes its slot binding names
// ("#priv:<id>:foo") distinct from every sibling and nested class's.
struct PrivateScope {
    uint start;
    uint class_id;
}

// One declared private name (`#foo`) within a class body. `slot` is the
// compiler-managed lexical variable (declared like `__super__`) that holds
// the runtime hidden-symbol value for this name, fresh per class evaluation.
struct PrivateNameEntry {
    char[] name;         // e.g. "foo" (without '#')
    // Lexical binding name of this name's symbol slot, e.g. "#priv:3:foo"
    // (unique per class body via a compile-time class id, so sibling and
    // nested classes never collide). Points at interned HString data,
    // stable storage, so any CompilerContext (method body, __field_init__)
    // can add it to its OWN constant pool: constant indices are context-
    // relative and must never cross function boundaries.
    char[] slot_name;
    // Binding name of the OWNING class's brand slot ("#priv:<id>:brand").
    // Own-property presence of the brand, not of this name's own key, is
    // what CHK_BRAND verifies for `obj.#foo` accesses (the brand is
    // unforgeable and shared by every field on the class; the field's own
    // key is only used for the GETPROP/PUTPROP that follows).
    char[] brand_slot_name;
    bool   is_method;    // declared as a method/accessor (affects write errors), P3/P4
    bool   has_getter;   // P4
    bool   has_setter;   // P4
    bool   is_static;    // P5: static private member, brand_slot_name is the STATIC brand
    // Private INSTANCE method/accessor only (is_method && !is_static): a
    // hidden lexical slot holding the closure object the class-body's
    // prototype-install loop builds (class.c3), so __field_init__ can
    // re-install the SAME closure onto each instance's own
    // [[PrivateElements]], needed when a derived constructor's super()
    // returns an object whose [[Prototype]] chain never reaches the class
    // prototype (return-override; see class.c3's field_init emission for
    // the full rationale). Allocated after private-name declaration (alongside
    // brand_slot_name) so it exists before any member body, which may
    // read `this.#m` in a field initializer, compiles. For a plain
    // method (`#m() {}`) this is the method's own closure slot; for an
    // accessor (`get #x`/`set #x`) this is unused, see
    // getter_closure_slot_name / setter_closure_slot_name instead, since a
    // get/set pair needs TWO independent closures re-installed under one
    // shared key.
    char[] method_closure_slot_name;
    // Private accessor only (is_method && has_getter/has_setter): separate
    // closure slots for the getter and setter halves of a `get #x`/`set #x`
    // pair, each keyword is compiled as its own ClassMethod/CLOSURE even
    // though both merge into this ONE PrivateNameEntry (same slot_name/key).
    // Empty when the corresponding half doesn't exist (set-only or
    // get-only accessor).
    char[] getter_closure_slot_name;
    char[] setter_closure_slot_name;
}
