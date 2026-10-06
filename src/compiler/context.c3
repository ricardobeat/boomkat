module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import std::io;
import std::collections::list;

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
// Initial capacities for growable compiler arrays.
// These are the starting sizes; the arrays double when full.
const uint INITIAL_CODE        = 512;
const uint INITIAL_CONSTANTS   = 128;
const uint INITIAL_CONST_HASH  = 256;
const uint INITIAL_INNER_FUNCS = 16;

// Hard limits (sanity caps to catch runaway compilation).
const uint MAX_CODE_HARD        = 1 << 22;  // 4M instructions
const uint MAX_CONSTANTS_HARD   = 1 << 20;  // 1M constants
const uint MAX_INNER_FUNCS_HARD = 1 << 16;  // 65K inner functions
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
    // One-based index into CompilerContext.bindings. Zero belongs to markers
    // and safely represents an entry without ledger metadata.
    uint binding_id;
    bool is_captured;
    // True for a `let`/`const` binding that has been declared but whose
    // initialiser has not yet completed (i.e. the `PUTLEX`/`PUTLEX_C` that
    // publishes its value has not been emitted).  While true, the binding
    // is in its temporal dead zone: a read via `resolve_var` would return
    // the bare register (holding `undefined`) and bypass the runtime TDZ
    // sentinel installed in the block's lex_env by `INITTZ`.  Marking it
    // here forces `resolve_var` to return `SCOPE_ERROR` so the read is
    // emitted as `GETVAR` against the env, which throws ReferenceError
    // while the sentinel is still in place.  Cleared by `emit_var_store`
    // after the binding's `PUTLEX`/`PUTLEX_C` is emitted.
    bool is_tdz;
    // True for a formal parameter or a catch parameter, both of which are
    // pushed with kind VAR because they share `var`'s register and env
    // treatment.  The distinction matters only for the §14.1.2 / §14.15.1
    // early error that a body `let`/`const` may not redeclare one: a body
    // `var` of the same name is explicitly allowed (it resolves to the same
    // binding), so `kind` alone cannot tell the two cases apart.
    bool is_param;
    // True for a catch parameter specifically (a subkind of `is_param`).
    // The catch param's binding is published via PUTLEX into the catch's
    // lex_env — above the surrounding var_env — so a body `var` or
    // for-statement head that reuses it must walk the chain (PUTVAR), not
    // write through the register and create a shadow in var_env
    // (B.3.5). For a formal parameter, `is_param` is true but the binding
    // stays in var_env (DECLVAR, not PUTLEX), so the chain walk would still
    // work but would be redundant with the register-resident semantics. A
    // hoisted `var` has neither flag; its binding lives in var_env via
    // DECLVAR_HOIST, register-resident when uncaptured, env-resident when
    // captured by a closure (is_captured carries that signal).
    bool is_catch_param;
    // True for a FunctionDeclaration whose enclosing scope is a Block
    // (force_lexical_fn_decl at compile time), so the binding is BOTH
    // block-scoped lexical (PUTLEX into the block's lex_env) AND hoisted to
    // function scope by B.3.3 (the register this entry holds). A
    // FunctionDeclaration at the top of a function body is var-scope only
    // and leaves this false. has_conflicting_lexical_name and
    // check_var_lex_conflict read it: a top-level `function f` followed by
    // `var f` is two vars (allowed), but `{ function f(){} } { function f(){} }`
    // is a sibling-block conflict that needs the same kind of detection the
    // LET/CONST path provides for `let`/`const`/`class`. Without this flag
    // the engine's only signal would be the VAR kind, which a plain `var f`
    // shares, so the flag is what isolates the block-scope function case.
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

// Tracks a destructured parameter's outer `= default`: `f([x] = [])`.
// Unlike ParamDefault, there is no single identifier/var-env binding, the
// arg slot is a plain register. Recorded during param parsing and emitted
// in a later pass (see emit_destruct_param_defaults) once every parameter's
// arg slot is finalised, so scratch registers can never land on a
// not-yet-consumed argument register.
struct DestructParamDefault {
    ushort arg_slot;          // register holding the (possibly-undefined) argument
    uint    default_func_idx; // index into inner_funcs for the default expression
}

// Destructuring now routes through the single DestructBind model
// (see functions.c3 / emit_destruct_bindings); the former per-context ArrayBind
// and ObjBind structs were removed in the destructuring consolidation.

// ============================================================================
// Compile-error recording (per-lexer; written on fault, read by callers)
// ============================================================================

// Record a compile-error message into the owning Lexer's buffer (first
// writer wins, matching existing error sites).  Position defaults to the
// lexer's current position; callers needing a different position (a just
// consumed token, a backed-up lexer) write err_line/err_col themselves
// before or after.
fn void CompilerContext.record_error(&self, char[] msg) {
    if (self.lexer.err_msg[0] != 0) return;
    self.lexer.err_line = self.lexer.line;
    self.lexer.err_col  = self.lexer.col;
    usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
    mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
    self.lexer.err_msg[copy_len] = 0;
}

// Record a compile-error message without touching the position fields.
// Used by paths (BigInt literals) whose error is not anchored to a token;
// record_error is the position-carrying form.
fn void CompilerContext.set_compile_error(&self, char[] msg) {
    if (self.lexer.err_msg[0] != 0) return;
    usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
    mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
    self.lexer.err_msg[copy_len] = 0;
}

// Compiler debug toggle: when true, finish() skips every peephole pass
// (GETVAR+INC+PUTVAR → INC_VAR, LDCONST+GETPROP → GETPROPC, comparison
// fusion, copy-propagation, dead DECLVAR elision, NOP compaction).
// Set via the CLI `--no-optimize` flag; default off.  Useful when a
// miscompiled pattern reproduces only on optimized builds, narrows
// the bug to either code generation or one of the peephole passes.
bool g_disable_optimize = false;

fn void set_disable_optimize(bool v) { g_disable_optimize = v; }


// ============================================================================
// CompilerContext
// ============================================================================

struct CompilerContext {
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
    // Per-instruction source line, parallel to `code`: line_table[i] is the
    // line of the source token that produced code[i]. Filled by emit(), kept
    // in lockstep with code through ensure_code_cap and finish()'s NOP
    // compaction, then copied into the CompiledFunction so error.stack can
    // report a line per frame.
    uint* line_table;

    // Inner functions (growable)
    CompiledFunction** inner_funcs;
    uint inner_func_count;
    uint inner_func_cap;

    // Scope tracking
    // Heap-allocated so it can grow past any fixed ceiling. It was
    // `ScopeEntry[256]`, then `[1024]` — but CompilerContext is a stack
    // local, so every fixed array here is charged against c3c's 64 KB
    // stack-object budget, and 1024 was already the ceiling. typescript
    // 5.4.5 exceeds it in a single function. Growing on the heap removes the
    // cap entirely; scope_overflow now only fires if an allocation fails.
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
    // `arguments` lives in a register, bound by the VM at call entry, rather
    // than as a binding of the function's variable environment.
    bool arguments_in_reg;
    ushort arguments_reg;

    // Enclosing loops and switches, innermost last.
    List{LoopInfo} loop_stack;
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

    // When true, emit_private_access skips the CHK_BRAND instruction.
    // Used by emit_deferred_target for private field targets in destructuring
    // assignments: per ES2022 §13.15.5.6, the target lref is evaluated before
    // GetV(value, propertyName), but the brand check must NOT run until after
    // the source property is read. The caller (emit_destruct_bindings) emits
    // the deferred CHK_BRAND after the GETPROP.
    bool defer_brand_check;
    // Register holding the deferred CHK_BRAND's brand symbol (set by
    // emit_private_access when defer_brand_check is true). The caller must
    // emit CHK_BRAND with this register and then free it.
    ushort deferred_brand_reg;
    // Constant-pool index for the private name in the deferred CHK_BRAND.
    uint deferred_brand_name_c;
    // Object register for the deferred CHK_BRAND.
    ushort deferred_brand_obj_reg;
    // When not 0xFFFF, emit_private_access uses THIS register for the brand
    // symbol instead of allocating a fresh one. Set by emit_deferred_target
    // before re-parsing a private-field destructuring target so the brand
    // symbol lands in a register pre-allocated BELOW the upcoming GETPROP's
    // result register, invoke_getter writes the getter's callee/this pair
    // at [result_reg, result_reg + 1] before the call even starts, so a
    // register grabbed lazily inside emit_private_access could land at or
    // above result_reg + 1 and get clobbered before the deferred CHK_BRAND
    // reads it.
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

    // Eval mode: when true, expression statements save their last result
    // to eval_acc_reg for eval's implicit return value. Set ONLY on the
    // context compiling the eval source's own top-level statement list,
    // which is also the only context that allocates eval_acc_reg. A nested
    // function or arrow body inside that source has its own completion
    // semantics (its `return`) and must never accumulate into eval_acc_reg,
    // whose register number is meaningless in the nested context's frame.
    bool   eval_mode;
    ushort eval_acc_reg;
    // True for the eval source's top-level context AND for every arrow body
    // lexically nested inside it. An arrow has no [[NewTarget]] of its own
    // and inherits the eval code's, so `new.target`'s eval-context rules
    // (see new_expr in expressions.c3) must keep applying inside the arrow
    // even though the arrow body must NOT accumulate a completion value.
    // This is the "am I lexically inside eval code" half of what eval_mode
    // previously conflated with completion-value accumulation.
    bool   in_eval_code;
    // True iff this is direct-eval code being processed from a
    // non-ArrowFunction's FunctionBody (ES2015 Annex B / §14.2.1):
    // the ONLY context in which `new.target` is a permitted syntax inside
    // the eval source. `false` for indirect eval, eval from script top
    // level, eval from an ArrowFunction, eval from a class constructor,
    // etc., `new_expr()` reads it to decide whether to reject new.target
    // as a SyntaxError. Set by `compile_eval` based on the activation
    // the runtime passes in (see builtin_eval in src/builtins/global.c3).
    bool   eval_direct_in_function;

    // Default parameter tracking
    List{ParamDefault} defaults;

    // Destructured-parameter outer-default tracking (deferred emission)
    List{DestructParamDefault} destruct_defaults;

    // Set while parsing FormalParameters when a parameter is a destructuring
    // pattern (`function f([a]) {}` / `function f({a}) {}`). Together with
    // `has_rest` and `defaults` this is IsSimpleParameterList = false
    // (ES §15.1.3) — see `params_are_simple`.
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
    // True when the current `__super__` binding holds the HomeObject itself
    // (object-literal methods) rather than a superclass constructor (class
    // bodies).  Selects GETPROTO- vs .prototype-based `super.x` emission.
    bool super_is_home_object;
    bool has_super_binding;     // true when class has extends (super() available)
    // True while the body being compiled belongs to a static class method
    // (or a static getter/setter). Per §13.3.7.1 GetSuperBase, a static
    // method's HomeObject is the class constructor itself, not its
    // .prototype, so `super.x` there must resolve against __static_super__
    // (always via GETPROTO on the constructor) rather than __super__.
    bool super_is_static_method;
    // True while the innermost enclosing `super`-eligible scope is an object
    // literal's concise method/accessor, not a class body. Object literals
    // bind their HomeObject under the literal name "__super__" (via
    // super_name_idx), never under __home_object__/__static_super__, and
    // that binding can be reached while lexically still `in_class_body`
    // (an object literal nested inside a class method), so emit_super_base
    // needs this explicit flag rather than inferring it from in_class_body.
    bool super_home_is_object_literal;
    // Constant-pool index of the per-class `__super__` binding name (unique
    // per class definition).  Each class with `extends` gets its own binding
    // so that multiple classes in the same function scope don't share a
    // single __super__ slot (which the last `extends` clause would clobber).
    // 0xFFFFFFFF means unset (no enclosing class).
    uint super_name_idx;
    // Constant-pool index of the per-class `__static_super__` binding name,
    // mirroring super_name_idx.  0xFFFFFFFF means unset (no enclosing class
    // with static super access).
    uint static_super_name_idx;
    // Constant-pool index of the per-class `__home_object__` binding name,
    // mirroring super_name_idx.  Always bound to the class's own .prototype
    // (the true [[HomeObject]] for an instance method, ES2022 §13.3.7.1),
    // so instance-method `super.x` reads GETPROTO(__home_object__) dynamically
    // instead of a statically-bound parent-constructor reference.  0xFFFFFFFF
    // means unset (no enclosing class).
    uint home_object_name_idx;
    // Monotonic counter used to generate unique __super__ binding names
    // across classes within the same function scope.
    uint super_class_counter;

    // Private class members (ES2022), name resolution: the declared names of
    // every open class body, with the bodies themselves in
    // PrivateNameTable.scopes. Shared private-name stack (see PrivateNameTable). Every context in one
    // class compile points at the SAME table, so an in-place realloc during
    // growth is visible to all borrowers, no stale `entries` pointer. The
    // table struct itself is heap-allocated and reference-counted-by-ownership:
    // exactly one context (`owns_private_names == true`) frees it.
    PrivateNameTable* private_name_table;
    // False when private_name_table was adopted (borrowed) from an enclosing
    // context via adopt_private_names, such a context must not free the
    // shared table in cleanup().
    bool owns_private_names;
    // True while compiling a private field initializer body (__field_init__).
    // `arguments` is a SyntaxError there (ES2022 §15.7.14): the initializer
    // is its own function body but has no arguments object of its own.
    bool forbid_arguments;
    // True while compiling a class static initialization block body
    // (ES2022 §15.7.11 ClassStaticBlockStatementList[~Return]): `return` at
    // this function's own top level is a SyntaxError, even though the block
    // is otherwise a normal function-like body (nested functions may still
    // return from themselves).
    bool forbid_return;
    // True while compiling a class static initialization block body
    // (ES2022 §15.7.11: ClassStaticBlockStatementList is [~Yield, +Await]
    // unconditionally, unlike field initializers which inherit [?Yield,
    // ?Await] from the enclosing context). `await` is always the reserved
    // keyword here, never usable as an identifier or BindingIdentifier,
    // and the `await` operator itself is a SyntaxError (ContainsAwait early
    // error). Like forbid_arguments/forbid_return, nested function/arrow
    // bodies get a fresh CompilerContext that does not inherit this flag.
    bool forbid_await;
    // True while compiling a class static initialization block body.
    // ClassStaticBlockStatementList is [~Yield], and class code is strict, so
    // a `yield` reference at the block's own level is a SyntaxError. Like
    // forbid_await, resets to false in any nested function/arrow body (fresh
    // CompilerContext).
    bool forbid_yield;

    // True while parsing the enclosing function's FormalParameters. Parameter
    // defaults must reject yield/await EXPRESSIONS (FormalParameters may not
    // Contain them, §14.1.2/§14.7), but destructuring defaults in the BODY of
    // a generator/async fn legally contain them, this flag tells
    // compile_default_expr which position it is compiling for.
    bool in_formal_params;

    // Generator tracking
    bool is_generator;          // true when compiling a generator function (function*)
                                // OR an async function (async also runs on the
                                // suspend/resume generator machinery via AWAIT).
    bool is_user_generator;     // true only when the function was written with a
                                // syntactic `*` (function*, async function*, or a
                                // `*`/`async *` method). Distinguishes async
                                // generators from plain async functions.

// Lexical environment depth: incremented when block() / for-in / for-of /
// class body etc. push a PUSH_LEX, decremented on POP_LEX. Tracked so
// break/continue can emit POP_LEXes to unwind the lex_env stack back to
// the loop's lex_env before jumping.
int  cur_lex_depth;

// Number of `with` statements currently nested. Each is paired with a
// runtime WITH_START/WITH_END; an abrupt break/continue/return must emit
// a matching WITH_END for every enclosing with (otherwise the with-env
// stays on act.lex_env and the jump target reads it as still active).
int  cur_with_depth;

    // True when this function is compiled lexically inside a `with` body. A
    // closure created there captures the with-env in its scope chain even
    // though this function pushes no with-env of its own, so every name it
    // touches may resolve to the with object: reads must go through the
    // environment and the fused register/INC_VAR fast paths must be skipped,
    // exactly as inside the `with` body itself. Kept separate from
    // cur_with_depth, which counts only the with-envs THIS function pushes
    // and is what the break/continue WITH_END accounting compares against.
    bool outer_with;

    // Per-function strictness. The compilation entry point sets the default
    // for its unit (sloppy for a script or a dynamic Function body, strict for
    // a module); a class body compiles strict and class code counts as strict
    // throughout. Inner functions inherit from the enclosing context until a
    // "use strict" directive raises strictness in the AST.
    bool is_strict;
    // True only when an actual "use strict" directive was parsed. Kept as a
    // separate flag because some downstream checks want the directive's
    // presence rather than the resulting strictness (e.g. forbidding
    // directives in non-simple-parameter functions).
    bool saw_use_strict;

    // arguments tracking
    bool uses_arguments;        // true when 'arguments' is referenced in function body

    // Local binding tracking, used to decide needs_env optimisation.
    // Set to true when the function body contains any var/function declarations
    // that would be hoisted to the function scope.
    bool has_local_bindings;
    // Set by declare_var for let/const declarations. Lexical bindings live in
    // PUSH_LEX block environments, not the function var_env, but a nested
    // closure still reads them via the env chain (GETVAR), so a function with
    // lexical bindings and closures must keep its PUTLEX/PUTLEX_C/INITTZ
    // stores and its runtime env.
    bool has_lexical_bindings;

    // Set by alloc_reg/alloc_regs when the register budget is exhausted.
    // Compilation continues with clamped registers to keep the parser in
    // sync; finish() turns the flag into a COMPILE_ERROR so a pathological
    // source fails the compile instead of aborting the host process.
    bool reg_overflow;

    // True once a WIDE prefix word has been emitted: some operand of this
    // function exceeded 255, so its bytecode carries 16-bit register indices.
    // finish() skips every peephole/fusion pass for such functions (the
    // passes read raw 8-bit fields and would see truncated operands); the
    // code runs unoptimized, which is correct and only matters for the rare
    // over-255-register function.
    bool has_wide;

    // Permanent register floor: parameters and hoisted function-scope slots
    // allocated before body statements begin. Set at each body-compile site
    // (inner/arrow bodies, program/eval/module entry);
    // free_reg / free_regs_to never release registers below it.
    ushort reserved_regs;

    // Closure tracking, set to true when a nested function is defined in
    // this function's body.  Combined with has_local_bindings to decide
    // needs_env: if the function has var bindings but no nested functions
    // that could capture them, the env can be skipped.
    bool has_closures;
    // True once any local in this function is forced through the environment
    // (let/const block shadowing of an outer var, catch parameter). Such a
    // function must keep its scope object, its captured locals are read via
    // GETVAR, so the register-locals env-elision must not fire.
    bool has_captured_local;
    // True for a named function expression whose CompiledFunction will be
    // tagged is_namebinding (ES2015 §14.1.20): the VM splices a fresh name
    // binding env onto var_env.parent at call time. That mutation is only
    // safe on a per-call scope object, so such functions can never take the
    // needs_env=false fast path that reuses the shared captured var_env.
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
    // Top-level function declarations seen by the hoisting pre-pass.
    //
    // Heap-grown rather than fixed: a real bundle declares tens of thousands
    // of functions in one scope (babel 7.24.7 exceeds 512 several times over),
    // and a cap here rejects working code outright.
    char[]* hoisted_fn_names;
    uint    hoisted_fn_cap;
    uint    hoisted_fn_count;
    // Eval code only: the eval source's var-declared names as constant-pool
    // indices (collected by hoist_one_var_name; the global-scope var entries
    // never reach scope_stack, so a hook there is the only collection
    // point). builtin_eval uses the list for the ES2024 §18.2.1.2 step 3.4
    // intermediate-binding collision check.
    uint*   eval_var_coll_idxs;
    uint    eval_var_coll_cap;
    uint    eval_var_coll_count;

    // Every function declaration a body-scope hoist pass saw at the scope's
    // own top level, with its register, inner-function index, and name
    // constant index. block() emits CLOSURE+DECLVAR from these once, just
    // after PUSH_LEX/INITTZ.
    //
    // Neither of the two obvious emission points works. The hoist pass itself
    // runs BEFORE PUSH_LEX, so a closure it emits cannot capture a lexical
    // binding declared in the body (`const t = 1; function K(){ return t; }`).
    // Re-emitting at the declaration's textual position instead creates a
    // SECOND function object, so a property stored on the binding before that
    // point (`exports.c = c; function c(){} c.stat = 1`, the browserify shape)
    // lands on an object nothing else references. block()'s slot is after
    // PUSH_LEX and before any statement, so one emission satisfies both.
    //
    // A repeated name overwrites its entry rather than adding one, leaving the
    // LAST declaration bound as §10.2.11 requires.
    char[]* hoisted_defer_names;
    ushort* hoisted_defer_regs;
    uint*   hoisted_defer_inner_idxs;
    uint*   hoisted_defer_name_idxs;
    uint    hoisted_defer_cap;
    uint    hoisted_defer_count;
    // Set once emit_hoisted_fn_decls has run for this context, so a nested
    // block cannot emit the declarations a second time.
    bool    hoisted_defer_emitted;

    // Block-nested function names the sloppy B.3.3 hoist scan hoisted into
    // this scope (functions.c3 B.3.3 block). block() consults this at
    // block-entry time — when enclosing `let`s are visible — to decide the
    // B.3.3.1 step ii exemption (entry init + publish). The var entry itself
    // is created unconditionally by the scan; when block() finds the name
    // exempt it erases that entry, so no binding exists at all.
    //
    // Heap-grown like hoisted_fn_names; freed in cleanup().
    char[]* b33_hoisted_names;
    ushort* b33_hoisted_regs;
    uint*   b33_hoisted_pcs;
    uint    b33_hoisted_cap;
    uint    b33_hoisted_count;

    // Constant-pool indices of the top-level `var` / `function` names this
    // Script unit declares as globals (the exact names for which the check-
    // prologue emits CHKGLOBALVAR / CHKGLOBALFUNC). A strict-mode plain
    // assignment whose bare-identifier LHS name interns to one of these indices
    // is statically resolvable, so the RESOLVEVAR/THROW_REF guard is provably
    // dead and elided. Indices (not slices) are stored because interned string
    // constants dedupe by content, so the same name always maps to the same
    // pool index within a context, sidestepping the lexer scratch-buffer
    // lifetime hazard of escaped identifiers. Populated only for Script global
    // scope (not modules, those bind via GETVAR, and not eval). Grows on the
    // thread allocator; freed in cleanup().
    List{uint} declared_global_name_idxs;

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
    // Code offsets of this function's direct-eval call instructions, ascending
    // (emit_call appends them as it emits each call). has_direct_eval is a
    // property of the whole body and cannot answer which call is which, so
    // `eval(x)` and `(0, eval)(x)` in one function need this to be told apart:
    // builtin_eval looks up the call site it was reached through. finish()
    // copies the list into CompiledFunction.direct_eval_offsets.
    List{uint} direct_eval_offsets;

    // Arrow/async tracking, needed for needs_env computation in finish().
    bool is_arrow;
    bool is_async;

    // True inside an ArrowFunction whose enclosing code has no [[NewTarget]],
    // i.e. one written directly in global or module code (or nested in such an
    // arrow).  An arrow inherits new.target from its enclosing function, so
    // with no enclosing function `new.target` is a SyntaxError there
    // (§16.1.1), exactly as it is at the top level itself.  A separate flag
    // rather than propagating is_global, which also governs where declarations
    // are registered and would wrongly make the arrow body's own `var`s global.
    bool no_new_target;

    // Module tracking, true when compiling an ESM module body.
    bool is_module;
    // Set when an `await` is parsed in this module's own top-level context
    // (ECMA-262 [[HasTLA]]). Module bodies always compile as async, so this is
    // the only way to know whether one actually suspends.
    bool saw_top_level_await;
    void* current_module;  // ModuleDef* (opaque to avoid import cycle)

    // True when the syntactic goal symbol is Module, set on the module-body
    // context AND propagated into every nested function/arrow/generator context
    // it contains. Unlike `is_module` (module-body only; also gates top-level
    // `await` reservation), this stays true inside nested functions so the
    // `import.meta` meta-property (ES2024 §13.3.12) is accepted anywhere in
    // module code while remaining an early SyntaxError in Script/eval/Function
    // code. It is also the [Await] grammar parameter's module half (see
    // await_reserved_here): `await` is reserved throughout module code, not
    // just in the module body. It never affects `arguments` handling.
    bool module_goal;

    // Inferred function name for the next anonymous function expression parsed.
    // Set by assignment lowering when LHS is a plain identifier (e.g. `var f = function() {}`)
    // or by object literal property parsing (e.g. `o = { method() {} }`).
    // Used by function_expr / function_expr_body when no explicit function name is given.
    // Cleared after use. Per ES2015 §14.1.20 SetFunctionName.
    // Token text or a keep_name copy, so it stays valid for the whole compile.
    char[] inferred_name;
    bool has_inferred_name;

    // Optimization toggle, when true, finish() skips the peephole passes
    // (GETVAR+INC+PUTVAR → INC_VAR, LDCONST+GETPROP → GETPROPC, comparison
    // fusion, copy-propagation, dead DECLVAR elision, NOP compaction).
    // Useful for debugging the compiler: when a miscompiled pattern works
    // with optimizations off but fails on, the bug is in a peephole pass
    // rather than in code generation.  Mirrors the module-level
    // `g_disable_optimize` so finish() can just read either source; the
    // per-context field is set in init() from the global.
    bool disable_optimize;
}

// Copy a name built outside the source text (a formatted numeric key, a
// "#"-prefixed private name) into the lexer's arena, which lives as long as
// the compile, so it can be held as a slice like token text.
fn char[] CompilerContext.keep_name(&self, char[] name) {
    if (name.len == 0) return {};
    return self.lexer.arena_dup(name.ptr, name.len);
}

// Bracket the parser's inferred-name slot across a NamedEvaluation scope via
// a save/defer-restore helper pair. Use:
//
//   NameEvalFrame _nef = self.save_name_eval();
//   defer self.restore_name_eval(_nef);
//   self.has_inferred_name = true;
//   ... seed the slot for this seed point ...
//   val = self.gen_expr(node, 0)!;
//
// The `defer` is what makes the bracket correct by construction: any exit path
// (normal return, early return, fault, panic) closes the bracket at this
// nesting level. The pattern replaces the prior "must remember to clear the
// slot after the call returns" discipline that leaked through four seed
// sites (`var P = print; P((function(){}).name)` observed the stale "P"
// before that fix). Used at all ES2015 §14.1.20 SetFunctionName seed points:
// var-init, plain `=`, logical-assignment, object-literal key, getter/setter
// body, method-shorthand body, class field, `export default`.
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

// True for a spec sync GeneratorFunction body (`function*` / `*m(){}`):
// a syntactic `*` that is NOT async. Equivalent to the historical
// `is_generator && !is_async` idiom.
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
    self.line_table = (uint*)h.alloc_func(h.heap_udata, (usz)(INITIAL_CODE * uint::size));
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
    self.declared_global_name_idxs.allocator = mem;
    self.slot_global_name_idxs.allocator = mem;
    self.direct_eval_offsets.allocator = mem;
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
    if (self.line_table != null) { h.free_func(h.heap_udata, self.line_table); self.line_table = null; }
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
    self.declared_global_name_idxs.free();
    self.slot_global_name_idxs.free();
    self.direct_eval_offsets.free();
    self.bindings.free();
    foreach (name : self.captured_names) { mem::free(name.ptr); }
    self.captured_names.free();
    self.defaults.free();
    self.destruct_defaults.free();
    self.loop_stack.free();
    self.labels.free();
    self.patches.free();
}

// Borrow the private-names table from an enclosing context (a method,
// default-parameter thunk, or arrow body compiled for a class element only
// resolves private names, never declares into the table, see
// declare_private_name's call sites, all of which are reached through
// class.c3's own `self`, never a propagated child context). Frees this
// context's own (still-empty) buffer first so it isn't leaked.
fn void CompilerContext.adopt_private_names(&self, CompilerContext* parent) {
    if (self.owns_private_names && self.private_name_table != null) {
        Heap* h = (Heap*)self.heap;
        if (self.private_name_table.entries != null) {
            h.free_func(h.heap_udata, self.private_name_table.entries);
        }
        self.private_name_table.scopes.free();
        h.free_func(h.heap_udata, self.private_name_table);
    }
    // Borrow the parent's shared table by pointer. A nested class in a field
    // initializer that DECLARES private names grows this same table in place,
    // so the growth (and any realloc of entries) is visible to `parent` too,
    // no stale-pointer desync between borrower and owner.
    self.private_name_table = parent.private_name_table;
    self.owns_private_names = false;
}

// Grow code buffer to accommodate more instructions.
fn void CompilerContext.ensure_code_cap(&self) {
    if (self.code_count < self.code_cap) return;
    uint new_cap = self.code_cap * 2;
    // Returning silently leaves emit() to hit the cap and drop instructions,
    // producing a truncated function with NO recorded error — the CLI then
    // prints "SyntaxError at line 0:0" with an empty message, naming neither
    // the cause nor a position. record_error (not set_compile_error) so the
    // current token's line/col is carried too.
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
    void* lp = h.realloc_func(h.heap_udata, self.line_table, (usz)(new_cap * uint::size));
    if (lp == null) {
        self.record_error("out of memory growing the line table");
        return;
    }
    self.line_table = (uint*)lp;
    self.code_cap = new_cap;
}

// Grow the scope stack. Unlike the code/constant buffers this has no hard
// cap: the depth is bounded by the source, and a real bundle (typescript
// 5.4.5) exceeds any fixed size that fits on the stack.
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

// Record a B.3.3 entry init the scan emitted: the hoisted name, the register
// the LDUNDEF+DECLVAR_HOIST pair wrote, and the DECLVAR_HOIST's instruction
// index. When block() proves the block exempt it NOPs that DECLVAR_HOIST and
// erases the scope entry, leaving no var binding at all. Interned names: the
// token borrows lexer scratch that later tokens overwrite.
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
    // Same reasoning as ensure_code_cap: a silent return here leaves the pool
    // full and the resulting failure carries no message or position.
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
    if (new_cap > MAX_INNER_FUNCS_HARD) return;
    Heap* h = (Heap*)self.heap;
    void* p = h.realloc_func(h.heap_udata, self.inner_funcs, (usz)(new_cap * CompiledFunction*::size));
    if (p == null) return;
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
    // A lex error surfaced through `peek_type()` (used by `is_at_end()`,
    // `check()`, etc.) is swallowed there as a synthetic EOF_TOKEN so that
    // ASI-adjacent lookahead logic doesn't have to thread an optional through
    // every callsite; the error message/position was still recorded into
    // `self.lexer.err_msg` at the point of failure. Without this check, a lex
    // error occurring only during lookahead (never during an `advance()`)
    // would let `compile()`'s statement loop see a clean EOF and return
    // success. Catch that here, at the single choke point all compile entry
    // points funnel through.
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

    // --- True register high-water mark ---
    //
    // max_reg is maintained by alloc_reg/alloc_regs alone, so it counts only
    // registers the allocator handed out. A call reads a whole WINDOW the
    // allocator never allocated one-by-one: the VM overlays the callee frame
    // at callee_reg, with `this` at callee_reg+1 and the arguments above it
    // (see reserve_call_frame). The topmost slot of that window can therefore
    // sit AT max_reg -- one past the last allocated register -- and every
    // consumer sized by max_reg then silently excludes it:
    //
    //   * moveelim's per-instruction bitsets are (max_reg + 31) / 32 words, so
    //     the window's top register falls outside and moveelim_mark_range
    //     clamps it away. The `this` slot never looks live, and the LDREG that
    //     loads it is removed as a dead store -- the method then runs with
    //     whatever the register happened to hold. Babel 7.24.7 hit exactly
    //     this: `this.skipSpace()` at max_reg == 32 with the receiver at r32.
    //   * func.num_regs sizes the VM's register frame for the call.
    //
    // So take the mark from the emitted code, which is the only place the
    // window is visible.
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
            default:
                continue;
        }
        if (htop + 1 > hw_max) { hw_max = htop + 1; }
    }
    if (hw_max > MAX_REGISTERS) { hw_max = MAX_REGISTERS; }


    promote_uncaptured_var_bindings(self, h);

    // --- Peephole: fuse GETVAR + INC/DEC + PUTVAR into INC_VAR/DEC_VAR ---
    // Pattern: GETVAR r, name  /  INC r  /  PUTVAR r, name
    //   → NOP  /  INC_VAR name  /  NOP
    // Saves 2 dispatches per loop iteration on the hot counter path.
    //
    // Declarative, see src/compiler/fusion.c3 (FUSION_INC_DEC_VAR rule,
    // run_fusion3_rule driver) for the pattern/guard/rewrite definition.
    // Ported 1:1 from the original hand-written pass; equivalence is checked
    // by the golden-bytecode suite (test/golden_bytecode/, `just
    // test-golden-bytecode`).
    //
    // A `with` body is dynamic scope: every GETVAR/PUTVAR inside it must walk
    // the env chain at runtime (the with-object may own the name), so the
    // read-op-write triple cannot fuse into INC_VAR/DEC_VAR (whose fast path
    // writes the cached env slot directly). Skip the pass for the whole
    // function when it contains a `with` statement.
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 3 && !self.has_with_stmt) {
        fuse_inc_dec_var(self.code, self.code_count, self.const_count);
    }

    // --- Peephole: fuse LDCONST rK, idx + GETPROP ra = rb, rK → NOP + GETPROPC ra = rb, idx ---
    // Saves 1 dispatch per property access.  The key constant-pool index is baked into
    // GETPROPC.c, so jumping into the NOP slot (if rK's LDCONST happened to be a jump
    // target) still produces correct results: NOP falls through to GETPROPC which reads
    // the index from the instruction itself, not from rK.  Control arriving at the
    // GETPROPC *itself* from a branch is a different matter and is rejected by the
    // shared driver's jump-target guard; see run_fusion_rule.
    //
    // Declarative: see src/compiler/fusion.c3 (FUSION_GETPROPC rule) for the
    // pattern, guard, and rewrite, and for the shared NOP-skip, jump-target, and
    // dead-after-liveness driver (run_fusion_rule). The jump-target bitset needs
    // a code_count-sized bool scratch, allocated here so fusion.c3 stays free of
    // heap dependencies.
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
    // JMP_SNEQ. Loose EQ/NEQ are deliberately excluded (they coerce and can
    // throw). Needs a code_count-sized bool scratch buffer for the jump-target
    // bitset, allocate it here to keep fusion.c3 free of heap dependencies.
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 2) {
        drop_jumps_to_next(self.code, self.code_count);
        bool* jump_targets = (bool*)h.alloc_func(h.heap_udata, (usz)self.code_cap);
        if (jump_targets == null) return COMPILE_ERROR~;
        run_cmp_branch_fusion(self.code, self.code_count, jump_targets);
        h.free_func(h.heap_udata, jump_targets);
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
            bool rT_live = false;
            if ((uint)consumer.a != rT) {
                int join_pc = -1;
                for (uint j = i + 2; j < self.code_count; j++) {
                    Instruction jns = self.code[j];
                    Opcode jop2 = jns.op;
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
    // Runs AFTER copy-propagation (above): that pass NOPs the LDREG moves that
    // otherwise sit between an LDINT literal and its arithmetic consumer, so the
    // consumer of rK is now the next NON-NOP instruction.
    //
    // Declarative: see src/compiler/fusion.c3 (FUSION_IMM_BINOP rule) for the
    // pattern, guard, and rewrite, and for the shared NOP-skip, jump-target, and
    // dead-after-liveness driver (run_fusion_rule). The jump-target guard is
    // load-bearing here, since a ternary's false arm sits physically next to the
    // join point in `5 + (c ? 10 : 20)`: without it the false arm's literal is
    // baked into an immediate form the true arm branches straight onto. The bitset needs a
    // code_count-sized bool scratch.
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 2) {
        bool* addi_jump_targets = (bool*)h.alloc_func(h.heap_udata, (usz)self.code_cap);
        if (addi_jump_targets == null) return COMPILE_ERROR~;
        fuse_imm_binop(self.code, self.code_count, addi_jump_targets);
        h.free_func(h.heap_udata, addi_jump_targets);
    }

    // --- Liveness-based move elimination: `producer rT=... ; LDREG rDst=rT`
    // -> retarget producer to write rDst directly, NOP the LDREG.
    // Runs AFTER copy-propagation and every fusion pass above (so the
    // producer immediately preceding a surviving LDREG is in its final
    // form) and BEFORE NOP compaction (so the NOPs it introduces are
    // physically removed). See src/compiler/moveelim.c3 for the liveness
    // analysis and the full safety-condition reasoning.
    // Remove unobserved declarations before liveness examines their sources.
    bool scopes_removed = prune_unobserved_environment_stores(self, h, can_remove_empty_arrow_scopes);

    if (!self.disable_optimize && !self.has_wide && self.code_count >= 2) {
        usz bufsz = (usz)self.code_cap;
        bool* me_jump_targets = (bool*)h.alloc_func(h.heap_udata, bufsz);
        bool* me_in_try       = (bool*)h.alloc_func(h.heap_udata, bufsz);
        // live_out/live_in carry the call-window-inclusive liveness for the
        // dead-destination check; ret_out/ret_in the window-free liveness
        // that drives the producer-retarget decisions (see moveelim.c3).
        //
        // The sets are per-instruction register bitsets. A fixed
        // MAX_REGISTERS-wide set would cost 8 KB per instruction slot, so the
        // four arrays below would be megabytes even for tiny functions; size
        // them by the registers this function actually uses instead.
        //
        // Sized by hw_max, NOT max_reg: a call window's top slot can sit one
        // past the allocator's high-water mark, and a bitset that excludes it
        // makes moveelim_mark_range clamp the window, leaving the receiver
        // slot looking dead. See the hw_max computation above.
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
        // A mapped `arguments` object aliases parameter slot i (ES2024
        // §9.4.4.8), and the VM reads those activation slots directly rather
        // than through bytecode, so the parameter registers have a reader this
        // pass's liveness cannot see. Pin them: without this, a store whose
        // only observer is `arguments[i]` (`function f(a){ a = 1; return
        // arguments[0]; }`) is removed as a dead destination. The condition
        // mirrors the func.flags.mapped_arguments computation below.
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
        // Proper tail calls (ES2015 §14.8). Runs after move elimination, so a
        // retargeted producer has already put the call's result in its final
        // register and the `CALL* rDst; RET rDst` pair is in its final shape,
        // and before NOP compaction, which removes the RET this leaves behind.
        // Reuses the jump-target and try-region maps moveelim just built; both
        // still describe this instruction sequence, since move elimination only
        // retargets operands and NOPs instructions in place.
        moveelim_mark_jump_targets_and_try_regions(self.code, self.code_count,
                                                   me_jump_targets, me_in_try);
        thread_returns(self.code, self.code_count, me_jump_targets, me_in_try);
        moveelim_mark_jump_targets_and_try_regions(self.code, self.code_count,
                                                   me_jump_targets, me_in_try);
        run_tail_calls(self.code, self.code_count, me_jump_targets, me_in_try);
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
    // TRY jump slots: TRY is always followed by a NOP whose BC field holds the
    // finally_offset.  The VM unconditionally reads and advances past this word,
    // so it must be preserved even after compaction.  We mark those slots in
    // `keep[]` before building the pc_map.
    // The guard is on code_count alone, NOT on disable_optimize: Step 4 below
    // is the only place func.code / func.code_count are ever assigned, so
    // skipping this block wholesale left every compiled function with a null
    // code pointer and `--no-optimize` segfaulted on entry to the VM. Steps
    // 1-3 (which only exist to compact NOPs and remap offsets) are gated
    // individually instead, and Step 4 already copies verbatim when
    // disable_optimize is set.
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
                        uint ra = (uint)self.code[i].a;
                        int sbx = self.code[i].get_sbc();
                        int tgt_old = (int)i + 1 + sbx;
                        int tgt_new = (int)pc_map[(uint)tgt_old];
                        int new_sbx = tgt_new - ((int)pc_map[i] + 1);
                        self.code[i] = bytecode::make_a_sbx(cop, ra, new_sbx);
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
                        // Adjacent slot i+1 (NOP, kept): BC = finally_offset (same base).
                        uint try_new = pc_map[i];
                        uint catch_off_old = self.code[i].get_bc();
                        uint catch_tgt_old = i + catch_off_old;
                        uint new_catch_off = pc_map[catch_tgt_old] - try_new;
                        uint finally_off_old = self.code[i + 1].get_bc();
                        uint new_finally_off = 0;
                        if (finally_off_old != 0) {
                            uint finally_tgt_old = i + finally_off_old;
                            new_finally_off = pc_map[finally_tgt_old] - try_new;
                        }
                        self.code[i] = bytecode::make_a_bc(Opcode.TRY, (uint)self.code[i].a, new_catch_off);
                        self.code[i + 1] = bytecode::make_a_bc(Opcode.NOP, 0, new_finally_off);
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
    // The line table stays parallel to code: one entry per final instruction,
    // the source line of the instruction that survived at that slot.
    void* line_raw = null;
    if (final_count > 0 && self.line_table != null) {
        line_raw = h.alloc_func(h.heap_udata, (usz)final_count * uint::size);
    }
    if (code_raw == null || (final_count > 0 && self.line_table != null && line_raw == null)) {
        if (line_raw != null) { h.free_func(h.heap_udata, line_raw); }
        if (code_raw != null) { h.free_func(h.heap_udata, code_raw); }
        if (!self.disable_optimize) {
            h.free_func(h.heap_udata, pc_map);
            h.free_func(h.heap_udata, nop_keep);
        }
        h.free_func(h.heap_udata, raw);
        return COMPILE_ERROR~;
    }
    Instruction* dst_code = (Instruction*)code_raw;
    uint* dst_line = (uint*)line_raw;
    uint dst_idx = 0;
    if (self.disable_optimize) {
        // Copy everything verbatim, preserves all NOPs introduced by the
        // peephole passes, but the VM treats NOP as no-op so execution is
        // correct.  Useful for debugging: every instruction the peephole
        // produced is visible in the dump.
        for (uint i = 0; i < self.code_count; i++) {
            dst_code[dst_idx] = self.code[i];
            if (dst_line != null) dst_line[dst_idx] = self.line_table[i];
            dst_idx++;
        }
    } else {
        for (uint i = 0; i < self.code_count; i++) {
            if (self.code[i].op != Opcode.NOP || nop_keep[i]) {
                dst_code[dst_idx] = self.code[i];
                if (dst_line != null) dst_line[dst_idx] = self.line_table[i];
                dst_idx++;
            }
        }
    }
    func.code = dst_code;
    func.line_table = dst_line;
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
            if (func.line_table != null) { h.free_func(h.heap_udata, func.line_table); }
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
            if (func.line_table != null) { h.free_func(h.heap_udata, func.line_table); }
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
    // does (ES2022 §15.7.10 PerformEval materializes the caller's arguments
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
    // per ES2015 §9.4.4.8. Simplicity reads the same three signals
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
    func.arguments_reg = self.arguments_reg;

    // `needs_env` controls whether the CALL fast path allocates a fresh
    // env record + bindings object per call (2 allocations).  We only need
    // a fresh env when the function's scope is actually accessed at runtime:
    //   - var bindings captured by a nested closure
    //   - arguments object
    //   - direct eval
    //   - default-valued parameters (parameter expressions need a fresh env
    //     because of ES5 §10.4.1.2: a separate env for params so closures
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

    // Direct-eval private-name snapshot (ES2022 §8.7.1): if this function has
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
// Private class members (ES2022), name resolution scope
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
