module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import duktape::peephole;
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
/// Sentinel for "no register" (used by local variables and fields that
/// track an optional register index, e.g. call_prop_obj_reg).
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
const uint MAX_SCOPE_DEPTH = 256;
const uint MAX_CAPTURED_NAMES = 48;
/// Cap on primary_expr recursion depth (nested `[[[`, `((((`, etc). The
/// recursive-descent parser has no other bound and a deeply nested literal
/// overflows the native stack (measured: 500 levels fine, 1000 crashes with
/// SIGSEGV before this guard existed). 256 leaves real headroom below the
/// measured crash point while comfortably covering realistic source.
const uint MAX_EXPR_DEPTH = 256;
const uint MAX_LOOP_DEPTH  = 16;
const uint MAX_TRY_DEPTH   = 8;
const uint MAX_LABELS       = 16;
/// Break/continue forward-patch slots per FUNCTION (8 bytes each, so 16 KB).
/// Not per loop: the pool is never reset mid-function, so this bounds the
/// total number of break/continue statements in one function body.
///
/// Sized to stay within c3c's 64 KB stack-object limit — CompilerContext is a
/// stack local (see entry.c3 / class.c3), so this array's size is charged
/// directly against that budget. 2048 comfortably exceeds MAX_SWITCH_CLAUSES
/// (1024), which is the realistic driver.
const uint MAX_PATCHES      = 2048;
const uint MAX_CONST_HASH   = 1024;  // Open-addressing hash table for constant dedup

/// Sentinel for "no patch" in break/continue patch lists.
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

struct ScopeEntry {
    char[] name;
    ushort reg;
    ScopeKind kind;
    bool is_captured;
    /// True for a `let`/`const` binding that has been declared but whose
    /// initialiser has not yet completed (i.e. the `PUTLEX`/`PUTLEX_C` that
    /// publishes its value has not been emitted).  While true, the binding
    /// is in its temporal dead zone: a read via `resolve_var` would return
    /// the bare register (holding `undefined`) and bypass the runtime TDZ
    /// sentinel installed in the block's lex_env by `INITTZ`.  Marking it
    /// here forces `resolve_var` to return `SCOPE_ERROR` so the read is
    /// emitted as `GETVAR` against the env, which throws ReferenceError
    /// while the sentinel is still in place.  Cleared by `emit_var_store`
    /// after the binding's `PUTLEX`/`PUTLEX_C` is emitted.
    bool is_tdz;
    /// True for a formal parameter or a catch parameter, both of which are
    /// pushed with kind VAR because they share `var`'s register and env
    /// treatment.  The distinction matters only for the §14.1.2 / §14.15.1
    /// early error that a body `let`/`const` may not redeclare one: a body
    /// `var` of the same name is explicitly allowed (it resolves to the same
    /// binding), so `kind` alone cannot tell the two cases apart.
    bool is_param;
    /// SCOPEMARK entries only: true for the marker a function BODY opens, as
    /// opposed to a nested BlockStatement.  The parameter check above sees
    /// through this marker (a body's top-level lexical names collide with the
    /// parameter list) and stops at every other one (a nested block's shadow
    /// it freely).
    bool is_body_mark;
}

struct LoopInfo {
    uint continue_target;
    uint break_patch_head;
    uint continue_patch_head; ///< chain of pending continue jumps (deferred until target resolved)
    bool is_loop;             ///< false for switch pseudo-loops (continue skips these)
    int  saved_lex_depth;     ///< cur_lex_depth at loop entry, break/continue POP_LEX back to this
    int  iter_close_reg;      ///< >= 0: for-of iterator reg, emit ITER_CLOSE on break/return; -1 = none
    bool is_await_loop;       ///< for-await-of: break/return unwind uses ITER_CLOSE_ASYNC (plan 057)
    /// try_depth at loop entry. A break/continue whose target loop was entered
    /// at the same try_depth as the jump site crosses no try/catch/finally
    /// boundary, so it must compile to a plain JUMP: BREAK/CONTINUE ask the VM
    /// to route through the innermost active finally, which for a jump that
    /// stays inside that same finally discards the completion it is carrying
    /// (including a parked exception).
    uint saved_try_depth;
}

struct TryInfo {
    uint catch_addr;
    uint finally_addr;
}

struct LabelInfo {
    char[] name;
    uint loop_index;   ///< index into loop_stack (NO_PATCH if not yet resolved)
    bool is_loop;      ///< true if this label refers to a loop (supports continue)
}

/// Tracks a break/continue patch chain for forward-patching jumps.
struct PatchEntry {
    uint addr;        // instruction index to patch
    uint next;        // index of next in chain, or NO_PATCH
}

/// Tracks a parameter with a default value expression.
struct ParamDefault {
    ushort param_reg;       // register holding the parameter
    uint    param_name_idx; // constant index of the parameter name
    uint    default_func_idx; // index into inner_funcs for the default expression
}

/// Tracks a destructured parameter's outer `= default`: `f([x] = [])`.
/// Unlike ParamDefault, there is no single identifier/var-env binding, the
/// arg slot is a plain register. Recorded during param parsing and emitted
/// in a later pass (see emit_destruct_param_defaults) once every parameter's
/// arg slot is finalised, so scratch registers can never land on a
/// not-yet-consumed argument register.
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

/// Record a compile-error message into the owning Lexer's buffer (first
/// writer wins, matching existing error sites).  Position defaults to the
/// lexer's current position; callers needing a different position (a just
/// consumed token, a backed-up lexer) write err_line/err_col themselves
/// before or after.
fn void CompilerContext.record_error(&self, char[] msg) {
    if (self.lexer.err_msg[0] != 0) return;
    self.lexer.err_line = self.lexer.line;
    self.lexer.err_col  = self.lexer.col;
    usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
    mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
    self.lexer.err_msg[copy_len] = 0;
}

/// Record a compile-error message without touching the position fields.
/// Used by paths (BigInt literals) whose error is not anchored to a token;
/// record_error is the position-carrying form.
fn void CompilerContext.set_compile_error(&self, char[] msg) {
    if (self.lexer.err_msg[0] != 0) return;
    usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
    mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
    self.lexer.err_msg[copy_len] = 0;
}

/// Compiler debug toggle: when true, finish() skips every peephole pass
/// (GETVAR+INC+PUTVAR → INC_VAR, LDCONST+GETPROP → GETPROPC, comparison
/// fusion, copy-propagation, dead DECLVAR elision, NOP compaction).
/// Set via the CLI `--no-optimize` flag; default off.  Useful when a
/// miscompiled pattern reproduces only on optimized builds, narrows
/// the bug to either code generation or one of the peephole passes.
bool g_disable_optimize = false;

fn void set_disable_optimize(bool v) { g_disable_optimize = v; }
fn bool get_disable_optimize()       { return g_disable_optimize; }

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

    /// Recursion depth of primary_expr, guarded against MAX_EXPR_DEPTH to
    /// turn a deeply nested literal (`[[[...`, `((((...`) into a catchable
    /// SyntaxError instead of a native stack overflow (SIGSEGV). Incremented
    /// on entry and decremented via `defer` so every exit path, including
    /// error returns, restores it.
    uint expr_depth;

    // Constant pool (growable)
    TVal* constants;
    uint const_count;
    uint const_cap;
    // Hash table for constant deduplication (growable, tracks constants)
    ConstHashEntry* const_hash;
    uint const_hash_count;
    uint const_hash_cap;
    /// Insertion cap keeping at least 25% of slots empty so probes terminate early.
    uint const_hash_fill;

    // Code emission (growable)
    Instruction* code;
    uint code_count;
    uint code_cap;

    // Inner functions (growable)
    CompiledFunction** inner_funcs;
    uint inner_func_count;
    uint inner_func_cap;

    // Scope tracking
    ScopeEntry[MAX_SCOPE_DEPTH] scope_stack;
    uint scope_depth;

    // Loop/break/continue tracking
    LoopInfo[MAX_LOOP_DEPTH] loop_stack;
    uint loop_depth;

    // Try/catch tracking
    TryInfo[MAX_TRY_DEPTH] try_stack;
    uint try_depth;

    // Label tracking
    LabelInfo[MAX_LABELS] labels;
    uint label_count;

    // Patch list pool for break/continue forward patches.
    //
    // This is a per-FUNCTION pool that is never reset mid-function, so the
    // bound is the total number of break/continue statements in one function,
    // not the depth of any single loop. The old bound was 256 and overflowing
    // it made add_patch return SILENTLY: the jump was never recorded, never
    // patched, and stayed `JUMP 0`. A switch with more than 256 clauses
    // therefore fell through to `default` for every arm past the 256th, with
    // no diagnostic — see MAX_PATCHES's use in patches.c3.
    PatchEntry[MAX_PATCHES] patches;
    uint patch_count;
    /// Set when add_patch overflowed; finish() turns this into a compile error.
    bool patch_overflow;

    // Track last identifier resolved via GETVAR (for assignment write-back)
    bool last_was_getvar;
    uint last_getvar_name_idx;
    /// Set when the last primary_expr returned an ArrowFunction. The Pratt parser
    /// uses this to reject `1 + () => 2`, `#x in () => {}`, etc., ArrowFunction
    /// is an AssignmentExpression-level production and must not appear as a
    /// binary operand without parentheses (ES §13.16, §13.15). Cleared by
    /// binary_expr once the unary_expr return is consumed.
    bool last_was_arrow_expr;

    /// Set by unary_expr when it consumed a unary OPERATOR (`-`, `+`, `!`,
    /// `~`, `typeof`, `void`, `delete`, `await`), so the expression it just
    /// returned is a UnaryExpression rather than an UpdateExpression.
    ///
    /// `ExponentiationExpression : UpdateExpression ** ExponentiationExpression`
    /// (ES2024 §13.6) admits only an UpdateExpression on the left, so
    /// `-a ** b` is a SyntaxError: the grammar deliberately refuses to guess
    /// whether `(-a) ** b` or `-(a ** b)` was meant. Parenthesising either way
    /// makes it a PrimaryExpression and so legal again. `a ** -b` is fine —
    /// the RIGHT operand is a full ExponentiationExpression, which does derive
    /// UnaryExpression. Cleared by binary_expr once the unary_expr return is
    /// consumed.
    bool last_was_unary_op;
    /// True when the operand just parsed was a bare `yield` whose operand was
    /// cut off by a line terminator (ES2024 §15.5: `yield [no LineTerminator
    /// here] AssignmentExpression` and `yield [no LineTerminator here] *`).
    /// Such a YieldExpression is complete, and since YieldExpression sits at
    /// AssignmentExpression level it cannot then become the left operand of a
    /// binary operator: `yield \n * 1` must be a SyntaxError rather than
    /// silently reading as `yield` followed by the statement `* 1`. Same
    /// consume-once discipline as last_was_unary_op — binary_expr reads and
    /// clears it right after the unary_expr call that produced it.
    bool last_was_newline_yield;
    /// True when the expression just parsed was an AssignmentExpression whose
    /// top-level operator was `=` or a compound/logical assignment.
    ///
    /// §13.15.1: such an expression has AssignmentTargetType ~invalid~, so
    /// `(a = b) = 1` is a SyntaxError. The ordinary reference markers cannot
    /// carry that: parentheses deliberately PRESERVE AssignmentTargetType
    /// (`(a) = 1` is legal), and a compound assignment's result path sets
    /// last_was_local_var on purpose, to drive the copy-to-temp guard for
    /// `(n *= 0.3) > 0`. So the fact is tracked separately and read by the
    /// invalid-LHS test, which runs once the assignment operator is consumed.
    bool last_was_assignment;
    /// The grammar's `[~In]` parameter: true while parsing an expression that
    /// may not contain a top-level `in` operator. Only the head of a C-style
    /// `for` sets it (`for (Expression[~In] ; ... )`, ES2024 §14.7.4), where an
    /// unparenthesized `in` would be ambiguous with a for-in head.
    ///
    /// `[?In]` propagation is by inheritance: the flag simply stays set down
    /// the left spine (comma → assignment → conditional → binary), and every
    /// construct whose grammar re-fixes the parameter to `[+In]` clears it.
    /// That is every nested grouping — parentheses, brackets, call arguments,
    /// template substitutions — all of which route through
    /// CompilerContext.expression(), which saves and clears it; the for head
    /// itself uses expression_no_in() to enter with it set. The one non-
    /// grouping site is a conditional's middle operand, which the grammar
    /// fixes to `[+In]` (`... ? AssignmentExpression[+In] : ...`), so
    /// `for (a ? b in c : d;;)` is legal while `for (a ? b : c in d;;)` is not.
    bool forbid_in;
    /// Code index of the GETVAR instruction that produced the last identifier
    /// reference (valid whenever last_was_getvar is true). Lets call_expr
    /// fuse a bare-identifier callee's GETVAR into CALL_VAR even though other
    /// instructions (arg setup) are emitted between the GETVAR and the call.
    uint last_getvar_code_pos;
    /// Set alongside last_was_getvar when the read was emitted as GETGLOBAL
    /// (true global scope, no nested lexical env). The assignment write-back
    /// then emits PUTGLOBAL instead of PUTVAR_ASSIGN.
    bool last_was_getglobal;
    /// Set alongside last_was_getglobal when the read was emitted as the
    /// guard-free GETGLOBAL_PRIM (name proven primitive-only). The assignment
    /// write-back then emits PUTGLOBAL_PRIM instead of PUTGLOBAL.
    bool last_was_getglobal_prim;
    /// Set when the last primary_expr returned a live local variable register directly.
    bool last_was_local_var;
    ushort last_local_var_reg;
    /// Set when the expression just parsed has AssignmentTargetType ~invalid~
    /// (ES §13.15.1) even though it left a reference marker behind.
    ///
    /// last_was_local_var carries two independent meanings: "this is a valid
    /// SimpleAssignmentTarget" and "the result lives in a local's home
    /// register, so an enclosing operator must copy it before overwriting"
    /// (the aliasing hint b0fdc49c added for `(u = 45) > 0`). An
    /// AssignmentExpression / UpdateExpression result needs the second but
    /// must not get the first: `(x = y) = 1` and `(x ??= y)++` are early
    /// SyntaxErrors. Clearing the shared flag would silently disable the
    /// copy-to-temp guard and corrupt the target variable's register, so
    /// target-validity is tracked here separately instead. Only the four
    /// SimpleAssignmentTarget checks read it; no codegen path does.
    bool last_target_invalid;
    /// Raw text of the identifier last resolved by primary_expr (getvar or
    /// local var alike). Used by assignment_expr for SetFunctionName
    /// (ES2015 §12.15.4): `x = function(){}` names the RHS "x" when the LHS
    /// is a simple IdentifierReference. Overwritten on every identifier
    /// primary_expr; only meaningful immediately after parsing an
    /// assignment LHS.
    char[128] last_lhs_name_buf;
    ushort last_lhs_name_len;
    /// True when the name in last_lhs_name_buf reached us through a
    /// CoverParenthesizedExpression, as in `(fn) = function(){}`.
    ///
    /// Parentheses change only ONE of the two things the saved name feeds.
    /// NamedEvaluation (§13.15.2 step 1.c) tests IsIdentifierRef, which a
    /// CoverParenthesizedExpression never satisfies, so `(fn) = function(){}`
    /// must not name the function. The strict-mode early error for assigning
    /// to `eval` / `arguments` (§13.15.1) is the opposite: it keys off
    /// AssignmentTargetType, which parentheses PRESERVE, so `(eval) = 1` and
    /// `(eval)++` stay SyntaxErrors. Clearing last_lhs_name_len for the first
    /// rule silently disabled the second, so the two are tracked separately.
    bool last_lhs_name_parenthesized;
    /// LHS mode: when true, member_expr saves obj/key without emitting GETPROP
    bool lhs_mode;
    /// Delete mode: when true, member_expr saves obj/key for delete.
    /// Separate from lhs_mode because expression() inside [bracket] calls
    /// assignment_expr which resets lhs_mode.
    bool del_mode;
    /// Set while parsing a `class ... extends` heritage expression, whose
    /// grammar is LeftHandSideExpression and therefore admits no arrow
    /// function. check_arrow() reports false under this flag so `=>` is left
    /// unconsumed and surfaces as a SyntaxError. Cleared as soon as the
    /// heritage expression is parsed, so arrows nested inside it (e.g. in a
    /// call argument, `extends f(() => 1)`) are unaffected.
    bool no_arrow_head;
    bool last_was_member;
    ushort last_member_obj_reg;
    ushort last_member_prop_reg;
    /// True when last_member_obj_reg is a live local-variable register (the
    /// member base was a bare local, e.g. `d.value`), so it must NOT be
    /// overwritten as a scratch destination, doing so corrupts the variable.
    bool last_member_obj_is_local;
    /// True when the recorded member expression is a `super.x` / `super[x]`
    /// reference, its store form must use PUTPROP_SUPER (receiver = this).
    bool last_member_is_super;
    /// True when the recorded member expression is `obj.#name`, a CHK_BRAND
    /// (own-only presence check) must run before the GETPROP/PUTPROP that
    /// reads/writes last_member_prop_reg (which holds the resolved private
    /// symbol, not a plain string key). `delete obj.#x` is a SyntaxError and
    /// never reaches this flag.
    bool last_member_is_private;

    /// Set when the current expression used optional chaining (?.).
    /// Results of optional chains are never valid assignment targets.
    bool last_was_optional_chain;

    /// Set when parsing a parenthesized grouping expression.
    /// Prevents call_expr from prematurely freeing call_prop_obj_reg
    /// when the next token is not a call (e.g. RPAREN closing the parens).
    bool inside_parens;

    /// Set by a caller immediately before invoking assignment_expr()/expression()
    /// when the produced value is provably discarded (expression statement,
    /// for-update clause, non-final comma operand). assignment_expr reads it
    /// once at its top into a local and clears it, so it never leaks into the
    /// recursive RHS. In void context a plain bare-identifier assignment skips
    /// the result-preservation LDREG copies and writes the LHS directly.
    bool void_ctx;

    /// Set by a caller immediately before invoking expression() when a postfix
    /// ++/-- result at the top of that expression would be provably discarded
    /// (expression statement, for-update clause). postfix_expr reads it once at
    /// its top into a local and clears the field, so it never leaks into any
    /// nested sub-expression (subscripts, call arguments, assignment RHS): the
    /// outermost postfix_expr in the descent consumes it before descending into
    /// call_expr. When the flag is set AND the token immediately after the ++/--
    /// is a statement/clause terminator, the old-value materialization (LDREG +
    /// TONUMERIC) is skipped and the increment compiles like the prefix form.
    bool postfix_void;

    /// When true, emit_private_access skips the CHK_BRAND instruction.
    /// Used by emit_deferred_target for private field targets in destructuring
    /// assignments: per ES2022 §13.15.5.6, the target lref is evaluated before
    /// GetV(value, propertyName), but the brand check must NOT run until after
    /// the source property is read. The caller (emit_destruct_bindings) emits
    /// the deferred CHK_BRAND after the GETPROP.
    bool defer_brand_check;
    /// Register holding the deferred CHK_BRAND's brand symbol (set by
    /// emit_private_access when defer_brand_check is true). The caller must
    /// emit CHK_BRAND with this register and then free it.
    ushort deferred_brand_reg;
    /// Constant-pool index for the private name in the deferred CHK_BRAND.
    uint deferred_brand_name_c;
    /// Object register for the deferred CHK_BRAND.
    ushort deferred_brand_obj_reg;
    /// When not 0xFFFF, emit_private_access uses THIS register for the brand
    /// symbol instead of allocating a fresh one. Set by emit_deferred_target
    /// before re-parsing a private-field destructuring target so the brand
    /// symbol lands in a register pre-allocated BELOW the upcoming GETPROP's
    /// result register, invoke_getter writes the getter's callee/this pair
    /// at [result_reg, result_reg + 1] before the call even starts, so a
    /// register grabbed lazily inside emit_private_access could land at or
    /// above result_reg + 1 and get clobbered before the deferred CHK_BRAND
    /// reads it.
    ushort deferred_brand_reg_hint;

    /// Property call: the object register to use as 'this' in emit_call.
    /// Set to REG_NONE when not in a property call.
    ushort call_prop_obj_reg;

    /// Spread call: base of the evaluation region below first_arg that a plain
    /// argument following a spread is compiled into, so its temps can never land
    /// inside the spread's runtime dest window. Set by begin_spread_args, used
    /// by the PUTARG emission sites.
    ushort spread_eval_base;

    /// Register allocation ceiling (0xFFFF = no cap). alloc_reg/alloc_regs
    /// clamp at it and flag reg_overflow instead of handing out a register at
    /// or above it. Holds a spread call's trailing-argument evaluation below
    /// first_arg; an expression needing more registers than the reserved
    /// region is a compile error, never a corrupted argument list.
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
    /// True for the eval source's top-level context AND for every arrow body
    /// lexically nested inside it. An arrow has no [[NewTarget]] of its own
    /// and inherits the eval code's, so `new.target`'s eval-context rules
    /// (see new_expr in expressions.c3) must keep applying inside the arrow
    /// even though the arrow body must NOT accumulate a completion value.
    /// This is the "am I lexically inside eval code" half of what eval_mode
    /// previously conflated with completion-value accumulation.
    bool   in_eval_code;
    /// True iff this is direct-eval code being processed from a
    /// non-ArrowFunction's FunctionBody (ES2015 Annex B / §14.2.1):
    /// the ONLY context in which `new.target` is a permitted syntax inside
    /// the eval source. `false` for indirect eval, eval from script top
    /// level, eval from an ArrowFunction, eval from a class constructor,
    /// etc., `new_expr()` reads it to decide whether to reject new.target
    /// as a SyntaxError. Set by `compile_eval` based on the activation
    /// the runtime passes in (see builtin_eval in src/builtins/global.c3).
    bool   eval_direct_in_function;

    // Token pushback buffer for limited backtracking (used by arrow function parsing).
    Token[4] pushback_stack;
    uint pushback_count;

    // Default parameter tracking
    ParamDefault[MAX_PARAMS] defaults;
    ushort default_count;

    // Destructured-parameter outer-default tracking (deferred emission)
    DestructParamDefault[MAX_PARAMS] destruct_defaults;
    ushort destruct_default_count;

    /// Set while parsing FormalParameters when a parameter is a destructuring
    /// pattern (`function f([a]) {}` / `function f({a}) {}`). Together with
    /// `has_rest` and `default_count` this is IsSimpleParameterList = false
    /// (ES §15.1.3) — see `params_are_simple`.
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
    /// True when the current `__super__` binding holds the HomeObject itself
    /// (object-literal methods) rather than a superclass constructor (class
    /// bodies).  Selects GETPROTO- vs .prototype-based `super.x` emission.
    bool super_is_home_object;
    /// Source offset of the class element following a consumed `static`
    /// modifier (0xFFFFFFFF when unknown). Set by match_static_modifier so the
    /// class compiler can retain method source text that excludes `static`.
    uint static_elem_src_start;
    bool has_super_binding;     // true when class has extends (super() available)
    /// True while the body being compiled belongs to a static class method
    /// (or a static getter/setter). Per §13.3.7.1 GetSuperBase, a static
    /// method's HomeObject is the class constructor itself, not its
    /// .prototype, so `super.x` there must resolve against __static_super__
    /// (always via GETPROTO on the constructor) rather than __super__.
    bool super_is_static_method;

    // Private class members (ES2022), name resolution.  Stack of declared
    // private names across nested class bodies; private_scope_start marks
    // where each class body's names begin so pop_private_scope can trim
    // back to the enclosing class's names on exit. Growable (a class body
    // may declare arbitrarily many distinct private names).
    /// Shared private-name stack (see PrivateNameTable). Every context in one
    /// class compile points at the SAME table, so an in-place realloc during
    /// growth is visible to all borrowers, no stale `entries` pointer. The
    /// table struct itself is heap-allocated and reference-counted-by-ownership:
    /// exactly one context (`owns_private_names == true`) frees it.
    PrivateNameTable* private_name_table;
    /// False when private_name_table was adopted (borrowed) from an enclosing
    /// context via adopt_private_names, such a context must not free the
    /// shared table in cleanup().
    bool owns_private_names;
    uint[MAX_CLASS_NESTING] private_scope_start;
    /// Compile-time class id per open class body (parallel to
    /// private_scope_start), makes each class's slot binding names unique
    /// ("#priv:<id>:foo") so sibling/nested classes never share bindings.
    uint[MAX_CLASS_NESTING] private_class_id;
    uint private_scope_depth;
    /// True while compiling a private field initializer body (__field_init__).
    /// `arguments` is a SyntaxError there (ES2022 §15.7.14): the initializer
    /// is its own function body but has no arguments object of its own.
    bool forbid_arguments;
    /// True while compiling a class static initialization block body
    /// (ES2022 §15.7.11 ClassStaticBlockStatementList[~Return]): `return` at
    /// this function's own top level is a SyntaxError, even though the block
    /// is otherwise a normal function-like body (nested functions may still
    /// return from themselves).
    bool forbid_return;
    /// True while compiling a class static initialization block body
    /// (ES2022 §15.7.11: ClassStaticBlockStatementList is [~Yield, +Await]
    /// unconditionally, unlike field initializers which inherit [?Yield,
    /// ?Await] from the enclosing context). `await` is always the reserved
    /// keyword here, never usable as an identifier or BindingIdentifier,
    /// and the `await` operator itself is a SyntaxError (ContainsAwait early
    /// error). Like forbid_arguments/forbid_return, nested function/arrow
    /// bodies get a fresh CompilerContext that does not inherit this flag.
    bool forbid_await;
    /// True while compiling a class static initialization block body.
    /// ClassStaticBlockStatementList is [~Yield], and this strict-only
    /// engine treats `yield` as a reserved word (not a plain identifier) in
    /// strict code, so a `yield` reference at the block's own level is a
    /// SyntaxError. Like forbid_await, resets to false in any nested
    /// function/arrow body (fresh CompilerContext).
    bool forbid_yield;

    /// True while the parser sits exactly at the start of an
    /// AssignmentExpression. A YieldExpression *is* an AssignmentExpression
    /// (ES2024 §13.15), so it is only legal in that position: `x = yield` and
    /// `f(yield)` parse, but `!yield`, `1 + yield` and `yield ? a : b` are
    /// SyntaxErrors because there the operand grammar is Unary/Conditional,
    /// which does not derive YieldExpression. assignment_expr sets this and
    /// every tighter-binding level (conditional/binary/unary/postfix) clears
    /// it before recursing, so primary_expr sees it set only when `yield`
    /// really did begin an AssignmentExpression.
    bool yield_ok_here;

    /// The value of `forbid_in` at the AssignmentExpression position marked by
    /// `yield_ok_here`, captured before binary_expr consumes it.
    ///
    /// A YieldExpression's operand keeps the enclosing In parameter —
    /// `yield [no LineTerminator here] AssignmentExpression[?In, +Yield]` —
    /// so `for (yield '' in {}; ; ) ;` is a SyntaxError: the for-init is
    /// `[~In]`, the `?In` passes that down, and the `in` can never be consumed
    /// by the operand.
    ///
    /// A separate field is needed because binary_expr clears forbid_in on
    /// entry (consume-on-entry, so it cannot leak into a nested `[+In]`
    /// construct like `f(a in b)`), and `yield` is handled far below that in
    /// primary_expr. YieldExpression is not one of those nested constructs; it
    /// propagates `?In` rather than forcing `+In`, so it needs the value the
    /// consume threw away. Set alongside yield_ok_here and cleared with it.
    bool yield_forbid_in;

    /// True while parsing the enclosing function's FormalParameters. Parameter
    /// defaults must reject yield/await EXPRESSIONS (FormalParameters may not
    /// Contain them, §14.1.2/§14.7), but destructuring defaults in the BODY of
    /// a generator/async fn legally contain them, this flag tells
    /// compile_default_expr which position it is compiling for.
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

    // Strict mode: the engine is strict-only, so there is no strictness flag.
    // `saw_use_strict` records only that a (no-op) directive was parsed.
    bool saw_use_strict;        // true only when an actual "use strict" directive was parsed
    // Set by the dynamic Function/GeneratorFunction/AsyncFunction constructors
    // so an undefined receiver coerces to globalThis. See
    // FuncFlags.subst_global_this. Cleared by a "use strict" directive.
    bool subst_global_this;

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
    // (parse_function_body, inner/arrow bodies, program/eval/module entry);
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

    // When true, function_declaration() stores its binding via PUTLEX into
    // the current (innermost) lex_env instead of DECLVAR into var_env. Set
    // around compiling a switch CaseBlock's case/default statements so a
    // function/generator/async-function declared directly in a clause is
    // scoped to the switch (ES2015 §14.12 BlockDeclarationInstantiation)
    // rather than leaking to the enclosing function/global scope.
    bool force_lexical_fn_decl;

    // --- Capture pre-scan (plan 045) ---
    // Names referenced inside nested callable bodies, collected by
    // pre_scan_captures before the body compiles; declare_var marks matching
    // locals is_captured so all their access goes through the environment.
    char[64][48] captured_names;
    ushort[48] captured_name_lens;
    uint captured_count;
    // Treat every local as captured: direct eval present, class body seen,
    // or pre-scan capacity overflow.
    bool capture_all;

    // Hoisted function declaration names (so main pass can skip recompilation).
    // Fixed-size, bounded by top-level function count in a single module.
    char[][256] hoisted_fn_names;
    ushort hoisted_fn_count;

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

    // Constant-pool indices of top-level `var`/`function` globals that a
    // whole-program pre-scan proved PRIMITIVE-ONLY: every assignment to the
    // name anywhere in the unit (including nested function bodies) stores a
    // provably-primitive value, and the unit has no eval/globalThis/Function/
    // with observability that could inject a heap value out of the compiler's
    // view. Reads/writes of such a global emit GETGLOBAL_PRIM/PUTGLOBAL_PRIM,
    // which skip the is_heap/refcount machinery entirely. Populated by
    // pre_scan_prim_globals at Script global scope only; empty otherwise so the
    // guarded GETGLOBAL/PUTGLOBAL path is used by default (conservative).
    List{uint} prim_only_name_idxs;

    // Direct eval tracking, when true, the CALL path must create a fresh env.
    bool has_direct_eval;
    /// Set by primary_expr when the identifier "eval" is resolved; checked and
    /// cleared by emit_call to detect direct eval calls (eval(...) by name).
    bool callee_is_eval;

    // Arrow/async tracking, needed for needs_env computation in finish().
    bool is_arrow;
    bool is_async;

    /// True inside an ArrowFunction whose enclosing code has no [[NewTarget]],
    /// i.e. one written directly in global or module code (or nested in such an
    /// arrow).  An arrow inherits new.target from its enclosing function, so
    /// with no enclosing function `new.target` is a SyntaxError there
    /// (§16.1.1), exactly as it is at the top level itself.  A separate flag
    /// rather than propagating is_global, which also governs where declarations
    /// are registered and would wrongly make the arrow body's own `var`s global.
    bool no_new_target;

    // Source offset of the `async` keyword when parsing an async arrow function
    // (`async x => ...` / `async (params) => ...`).  Set by primary_expr before
    // it consumes `async` and re-enters itself; read by parse_arrow_function /
    // parse_arrow_function_reparse to override the src_start so that the retained
    // source text includes the `async` prefix (ES2019 §19.2.3.5).
    // 0xFFFFFFFF means "not pending".
    uint pending_async_arrow_src;

    // Source offset of the `async` keyword when parsing an async function expression
    // (`async function ...` / `async function* ...`). Set by primary_expr before
    // calling function_expr; read by function_expr to override the src_start so
    // that the retained source text includes the `async` prefix (ES2019 §19.2.3.5).
    // 0xFFFFFFFF means "not pending".
    uint pending_async_function_src;

    // Module tracking, true when compiling an ESM module body.
    bool is_module;
    void* current_module;  // ModuleDef* (opaque to avoid import cycle)

    // True when the syntactic goal symbol is Module, set on the module-body
    // context AND propagated into every nested function/arrow/generator context
    // it contains. Unlike `is_module` (module-body only; also gates top-level
    // `await` reservation), this stays true inside nested functions so the
    // `import.meta` meta-property (ES2024 §13.3.12) is accepted anywhere in
    // module code while remaining an early SyntaxError in Script/eval/Function
    // code. It never affects `await`/`arguments` handling.
    bool module_goal;

    /// True only while parsing a statement directly in a Module's top-level
    /// StatementList. An ImportDeclaration / ExportDeclaration is a
    /// ModuleItem (ES2024 §16.2.1), a production that exists nowhere else in
    /// the grammar, so `export` inside a block, a loop or switch body, a
    /// labelled statement or a try/catch/finally is a SyntaxError. The
    /// statement dispatcher clears this before parsing any nested statement,
    /// and nested function/arrow contexts never inherit it (a fresh
    /// CompilerContext leaves it false).
    bool module_top_level;

    /// Set by statement_body() to mark that the statement about to be parsed
    /// sits where the grammar admits a `Statement` but not a
    /// `StatementListItem` — an if/else arm, a loop body or a labelled
    /// statement. Only a Declaration is affected, and every form except
    /// `async function` is already rejected by statement_body()'s own switch
    /// on the leading token; this flag exists for that one form, whose `async`
    /// is a contextual keyword indistinguishable from an identifier until the
    /// statement dispatcher has looked ahead. Consumed exactly once, into a
    /// local, so it cannot leak into a nested statement.
    bool stmt_position_only;

    // Inferred function name for the next anonymous function expression parsed.
    // Set by assignment_expr when LHS is a plain identifier (e.g. `var f = function() {}`)
    // or by object literal property parsing (e.g. `o = { method() {} }`).
    // Used by function_expr / function_expr_body when no explicit function name is given.
    // Cleared after use. Per ES2015 §14.1.20 SetFunctionName.
    char[128] inferred_name_buf;
    ushort inferred_name_len;
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

// ============================================================================
// CompilerContext, generator/async kind predicates
// ============================================================================

/// True for an async generator body (`async function*` / `async *m(){}`):
/// written with a `*` and async. The single predicate that replaces scattered
/// flag-combination checks in the compiler.
macro bool CompilerContext.is_async_gen(&self) {
    return self.is_async && self.is_user_generator;
}

/// True for a spec sync GeneratorFunction body (`function*` / `*m(){}`):
/// a syntactic `*` that is NOT async. Equivalent to the historical
/// `is_generator && !is_async` idiom.
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
    self.loop_depth = 0;
    self.try_depth = 0;
    self.label_count = 0;
    self.patch_count = 0;
    self.patch_overflow = false;
    self.const_hash_count = 0;
    self.call_prop_obj_reg = REG_NONE;
    self.deferred_brand_reg_hint = 0xFFFF;
    self.pushback_count = 0;
    self.pending_async_arrow_src = 0xFFFFFFFF;
    self.pending_async_function_src = 0xFFFFFFFF;

    // Allocate growable buffers
    Heap* h = (Heap*)heap;
    self.code_cap = INITIAL_CODE;
    self.code = (Instruction*)h.alloc_func(h.heap_udata, (usz)(INITIAL_CODE * Instruction::size));
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
    PrivateNameTable* pnt = (PrivateNameTable*)h.alloc_func(h.heap_udata, (usz)PrivateNameTable::size);
    pnt.entries = (PrivateNameEntry*)h.alloc_func(h.heap_udata, (usz)(INITIAL_PRIVATE_NAMES * PrivateNameEntry::size));
    pnt.count = 0;
    pnt.cap = INITIAL_PRIVATE_NAMES;
    self.private_name_table = pnt;
    self.owns_private_names = true;

    // Persistent (non-temp) allocator for the declared-global name-index set so
    // entries survive the whole compile; freed in cleanup().
    self.declared_global_name_idxs.allocator = mem;
    self.prim_only_name_idxs.allocator = mem;

    // Strict-only engine: lexer always in strict mode (affects FutureReservedWord
    // keyword recognition, implements/interface/package/private/protected/public).
    self.lexer.set_strict(true);
}

/// Free heap-allocated compiler buffers.  Call after finish() or on error.
fn void CompilerContext.cleanup(&self) {
    Heap* h = (Heap*)self.heap;
    if (self.code != null) { h.free_func(h.heap_udata, self.code); self.code = null; }
    if (self.constants != null) { h.free_func(h.heap_udata, self.constants); self.constants = null; }
    if (self.const_hash != null) { h.free_func(h.heap_udata, self.const_hash); self.const_hash = null; }
    if (self.inner_funcs != null) { h.free_func(h.heap_udata, self.inner_funcs); self.inner_funcs = null; }
    if (self.owns_private_names && self.private_name_table != null) {
        if (self.private_name_table.entries != null) {
            h.free_func(h.heap_udata, self.private_name_table.entries);
        }
        h.free_func(h.heap_udata, self.private_name_table);
    }
    self.private_name_table = null;
    self.declared_global_name_idxs.free();
    self.prim_only_name_idxs.free();
}

/// Borrow the private-names table from an enclosing context (a method,
/// default-parameter thunk, or arrow body compiled for a class element only
/// resolves private names, never declares into the table, see
/// declare_private_name's call sites, all of which are reached through
/// class.c3's own `self`, never a propagated child context). Frees this
/// context's own (still-empty) buffer first so it isn't leaked.
fn void CompilerContext.adopt_private_names(&self, CompilerContext* parent) {
    if (self.owns_private_names && self.private_name_table != null) {
        Heap* h = (Heap*)self.heap;
        if (self.private_name_table.entries != null) {
            h.free_func(h.heap_udata, self.private_name_table.entries);
        }
        h.free_func(h.heap_udata, self.private_name_table);
    }
    // Borrow the parent's shared table by pointer. A nested class in a field
    // initializer that DECLARES private names grows this same table in place,
    // so the growth (and any realloc of entries) is visible to `parent` too,
    // no stale-pointer desync between borrower and owner.
    self.private_name_table = parent.private_name_table;
    self.owns_private_names = false;
}

/// Grow code buffer to accommodate more instructions.
fn void CompilerContext.ensure_code_cap(&self) {
    if (self.code_count < self.code_cap) return;
    uint new_cap = self.code_cap * 2;
    if (new_cap > MAX_CODE_HARD) return;
    Heap* h = (Heap*)self.heap;
    void* p = h.realloc_func(h.heap_udata, self.code, (usz)(new_cap * Instruction::size));
    if (p == null) return;
    self.code = (Instruction*)p;
    self.code_cap = new_cap;
}

/// Grow constant pool and hash table.
fn void CompilerContext.ensure_const_cap(&self) {
    if (self.const_count < self.const_cap) return;
    uint new_cap = self.const_cap * 2;
    if (new_cap > MAX_CONSTANTS_HARD) return;
    Heap* h = (Heap*)self.heap;

    // Grow constants array
    void* p = h.realloc_func(h.heap_udata, self.constants, (usz)(new_cap * TVal::size));
    if (p == null) return;
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

/// Grow inner functions array.
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

/// Grow the private-names table.
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

/// Register an inner function and return its index.
fn uint CompilerContext.add_inner_func(&self, CompiledFunction* func) {
    self.ensure_inner_func_cap();
    if (self.inner_func_count >= self.inner_func_cap) return 0;
    uint idx = self.inner_func_count;
    self.inner_funcs[idx] = func;
    self.inner_func_count++;
    self.has_closures = true;
    return idx;
}

/// Parse (but do not yet emit) the optional `= default` initializer on a
/// destructured function parameter: `function f([x] = [])` or
/// `function f({x} = {})`. Compiles the default expression as a thunk and
/// records it in `destruct_defaults` for later emission by
/// `emit_destruct_param_defaults`, once every parameter's arg slot is
/// finalised, emitting immediately here would let scratch registers land
/// on the arg slot of a not-yet-parsed parameter later in the list.
///
/// Returns `true` if a default was consumed, `false` and no-op otherwise.
fn bool? CompilerContext.parse_destruct_param_default(&self, ushort arg_slot) {
    bool saved_ifp = self.in_formal_params;
    self.in_formal_params = true;
    defer self.in_formal_params = saved_ifp;

    if (!self.check(TokenType.ASSIGN)) return false;
    self.advance()!; // consume '='

    // Compile the default expression as an inner function (thunk with no args).
    CompiledFunction* default_func = self.compile_default_expr()!;
    uint func_idx = self.add_inner_func(default_func);

    if (self.destruct_default_count < MAX_PARAMS) {
        self.destruct_defaults[self.destruct_default_count].arg_slot = arg_slot;
        self.destruct_defaults[self.destruct_default_count].default_func_idx = func_idx;
        self.destruct_default_count++;
    }

    return true;
}

/// Emit the deferred outer-default checks recorded by
/// `parse_destruct_param_default`. Must run after all parameters (and thus
/// all arg-slot registers) have been parsed, so scratch register allocation
/// here can never clobber a later parameter's live argument.
fn void CompilerContext.emit_destruct_param_defaults(&self) {
    for (ushort di = 0; di < self.destruct_default_count; di++) {
        ushort arg_slot = self.destruct_defaults[di].arg_slot;
        uint func_idx = self.destruct_defaults[di].default_func_idx;

        // Compare the arg slot vs undefined. If equal, take the default.
        ushort undef_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = self.alloc_reg();
        self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)arg_slot, (uint)undef_reg);
        self.free_reg(undef_reg);

        // IF_TRUE: skip past the default-eval block (will patch target after).
        uint skip_addr = self.code_count;
        self.emit_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0);
        self.free_reg(cmp_reg);

        // Call the default thunk. Result replaces the arg slot in-place so
        // the subsequent destructuring emit reads from the updated value.
        ushort closure_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

        ushort call_base = self.alloc_reg();
        self.reserve_call_frame(call_base, 0);
        self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
        self.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);
        self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);
        self.emit_abc(Opcode.LDREG, (uint)arg_slot, (uint)call_base, 0);
        self.free_regs_to(call_base);

        // Patch skip target to land at REQUIRE_OBJ (emitted right after).
        int skip_off = (int)self.code_count - (int)skip_addr - 1;
        self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);

        self.emit_abc(Opcode.REQUIRE_OBJ, (uint)arg_slot, 0, 0);
    }
}

/// Finalise compilation: allocate a CompiledFunction and copy code/constants.
fn CompiledFunction*? CompilerContext.finish(&self) {
    if (self.reg_overflow) {
        return self.fail("register limit exceeded")~;
    }
    if (self.patch_overflow) {
        return self.fail("too many break/continue targets in one function")~;
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
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 3) {
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
        if (gp_jump_targets == null) { self.cleanup(); return COMPILE_ERROR~; }
        fuse_getpropc(self.code, self.code_count, gp_jump_targets, self.constants);
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
        bool* jump_targets = (bool*)h.alloc_func(h.heap_udata, (usz)self.code_cap);
        if (jump_targets == null) { self.cleanup(); return COMPILE_ERROR~; }
        run_cmp_branch_fusion(self.code, self.code_count, jump_targets);
        h.free_func(h.heap_udata, jump_targets);
    }

    // --- Peephole: copy propagation, NOP LDREG rT = rS when immediately followed
    // by a consumer that reads rT as a plain register operand (b or c), rT is dead
    // after the consumer, and rS is not clobbered between them (trivially true since
    // they are adjacent).
    //
    // Supported consumers: JMP_NLT/NLE/NGT/NGE (b/c = register operands),
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
        if (cp_jump_targets == null) { self.cleanup(); return COMPILE_ERROR~; }
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
            bool cop_reads_b_c =
                cop == Opcode.JMP_NLT || cop == Opcode.JMP_NLE ||
                cop == Opcode.JMP_NGT || cop == Opcode.JMP_NGE ||
                cop == Opcode.JMP_LT  || cop == Opcode.JMP_LE  ||
                cop == Opcode.JMP_GT  || cop == Opcode.JMP_GE  ||
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
            // Note: IF_TRUE/IF_FALSE use field A as a READ (not a write), handle them
            // explicitly so they are not mistaken for an overwrite of rT.
            bool rT_live = false;
            if ((uint)consumer.a != rT) {
                for (uint j = i + 2; j < self.code_count; j++) {
                    Instruction jns = self.code[j];
                    Opcode jop2 = jns.op;
                    if (jop2 == Opcode.IF_TRUE || jop2 == Opcode.IF_FALSE) {
                        if ((uint)jns.a == rT) { rT_live = true; break; }
                        continue;
                    }
                    OpFormat jfmt = bytecode::get_op_format(jop2);
                    if (jfmt == OpFormat.ABC) {
                        if ((uint)jns.b == rT || (uint)jns.c == rT) { rT_live = true; break; }
                    }
                    if (jfmt != OpFormat.WIDE_SABC && jfmt != OpFormat.WIDE_ABC) {
                        if ((uint)jns.a == rT) { break; }
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

    // --- Peephole: fuse LDINT rK, imm + ADD/SUB rD = …,rK → NOP + ADDI/SUBI rD = rS, imm ---
    // Runs AFTER copy-propagation (above): that pass NOPs the LDREG moves that
    // otherwise sit between an LDINT literal and its arithmetic consumer, so the
    // consumer of rK is now the next NON-NOP instruction.
    //
    // Declarative: see src/compiler/fusion.c3 (FUSION_ADDI_SUBI rule) for the
    // pattern, guard, and rewrite, and for the shared NOP-skip, jump-target, and
    // dead-after-liveness driver (run_fusion_rule). The jump-target guard is
    // load-bearing here, since a ternary's false arm sits physically next to the
    // join point in `5 + (c ? 10 : 20)`: without it the false arm's literal is
    // baked into an ADDI the true arm branches straight onto. The bitset needs a
    // code_count-sized bool scratch.
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 2) {
        bool* addi_jump_targets = (bool*)h.alloc_func(h.heap_udata, (usz)self.code_cap);
        if (addi_jump_targets == null) { self.cleanup(); return COMPILE_ERROR~; }
        fuse_addi_subi(self.code, self.code_count, addi_jump_targets);
        h.free_func(h.heap_udata, addi_jump_targets);
    }

    // --- Liveness-based move elimination: `producer rT=... ; LDREG rDst=rT`
    // -> retarget producer to write rDst directly, NOP the LDREG.
    // Runs AFTER copy-propagation and every fusion pass above (so the
    // producer immediately preceding a surviving LDREG is in its final
    // form) and BEFORE NOP compaction (so the NOPs it introduces are
    // physically removed). See src/compiler/moveelim.c3 for the liveness
    // analysis and the full safety-condition reasoning.
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 2) {
        usz bufsz = (usz)self.code_cap;
        bool* me_jump_targets = (bool*)h.alloc_func(h.heap_udata, bufsz);
        bool* me_in_try       = (bool*)h.alloc_func(h.heap_udata, bufsz);
        usz regsetsz = (usz)self.code_cap * RegSet::size;
        // live_out/live_in carry the call-window-inclusive liveness for the
        // dead-destination check; ret_out/ret_in the window-free liveness
        // that drives the producer-retarget decisions (see moveelim.c3).
        RegSet* me_live_out = (RegSet*)h.alloc_func(h.heap_udata, regsetsz);
        RegSet* me_live_in  = (RegSet*)h.alloc_func(h.heap_udata, regsetsz);
        RegSet* me_ret_out  = (RegSet*)h.alloc_func(h.heap_udata, regsetsz);
        RegSet* me_ret_in   = (RegSet*)h.alloc_func(h.heap_udata, regsetsz);
        if (me_jump_targets == null || me_in_try == null || me_live_out == null || me_live_in == null
            || me_ret_out == null || me_ret_in == null) {
            if (me_jump_targets != null) { h.free_func(h.heap_udata, me_jump_targets); }
            if (me_in_try != null) { h.free_func(h.heap_udata, me_in_try); }
            if (me_live_out != null) { h.free_func(h.heap_udata, me_live_out); }
            if (me_live_in != null) { h.free_func(h.heap_udata, me_live_in); }
            if (me_ret_out != null) { h.free_func(h.heap_udata, me_ret_out); }
            if (me_ret_in != null) { h.free_func(h.heap_udata, me_ret_in); }
            self.cleanup();
            return COMPILE_ERROR~;
        }
        run_move_elimination(self.code, self.code_count, me_jump_targets, me_in_try, me_live_out, me_live_in,
                             me_ret_out, me_ret_in);
        h.free_func(h.heap_udata, me_jump_targets);
        h.free_func(h.heap_udata, me_in_try);
        h.free_func(h.heap_udata, me_live_out);
        h.free_func(h.heap_udata, me_live_in);
        h.free_func(h.heap_udata, me_ret_out);
        h.free_func(h.heap_udata, me_ret_in);
    }

    // --- Register-resident locals: elide dead env ops when no scope is needed ---
    // Must run BEFORE the NOP compaction below so the NOPs we introduce here are
    // physically removed too. When this function needs no runtime scope object
    // (no closures / eval / arguments / default-or-rest params, and not an
    // arrow/generator/async), nothing can ever read its scope, all of its
    // non-captured locals live purely in registers (reads already use registers;
    // see resolve_var). The env *writes* below are therefore dead, so we NOP
    // them; this lets the VM skip allocating the scope HObject per call (the
    // dominant cost in call-heavy code). NOP is a valid jump target → layout-safe.
    //
    // PUTLEX_C is intentionally NOT in the elide list: a `const` binding must
    // install its non-writable flag in the lex_env so a register-only write
    // compiled to PUTVAR_ASSIGN / INC_VAR / DEC_VAR (the const-guard sites
    // added by plan 062 group H) can throw TypeError on assignment. NOP'ing
    // PUTLEX_C silently drops that flag and lets the assignment succeed.
    // INITTZ stays in the list (it only matters for the typeof special case
    // handled below).
    //
    // Invariant: elision must agree with resolve_var in scope.c3, any binding
    // whose reads are forced through the env (is_captured=true on its scope
    // entry) MUST keep its env writes (DECLVAR/INITTZ/PUTLEX), because NOP'ing
    // them would leave the env without the binding and cause ReferenceError on
    // the next GETVAR. The has_captured_local flag is the indicator maintained
    // for this check; sites that set is_captured=true manually (after
    // declare_var) must also set has_captured_local=true. See the for-in head
    // in statements.c3 (the iter-var entry) for the canonical example.
    {
        bool elide_has_params_needing_env = self.has_rest || self.default_count > 0;
        bool elide_needs_runtime_env = ((self.has_local_bindings || self.has_lexical_bindings || self.num_args > 0) && self.has_closures)
                              || self.uses_arguments
                              || self.has_direct_eval;
        bool elide_ok = !elide_needs_runtime_env
                     && !elide_has_params_needing_env
                     && !self.has_captured_local
                     && !self.is_global   // global/eval vars are env-resident (resolve_var skips global scope)
                     && !self.is_arrow
                     && !self.is_generator
                     && !self.is_async;
        if (!self.disable_optimize && !self.has_wide && elide_ok) {
            // TYPEOFIDENT relies on the INITTZ sentinel in the block env to
            // throw for `typeof x` inside x's temporal dead zone, collect the
            // name indices it references so those sentinels are kept.
            uint[64] typeof_names;
            uint typeof_name_count = 0;
            for (uint i = 0; i < self.code_count; i++) {
                if (self.code[i].op == Opcode.TYPEOFIDENT && typeof_name_count < 64) {
                    typeof_names[typeof_name_count++] = self.code[i].get_bc();
                }
            }
            for (uint i = 0; i < self.code_count; i++) {
                Opcode dop = self.code[i].op;
                // Declarations always target the function's own immediate scope.
                // PUTLEX_C is intentionally excluded, see the comment above the
                // elision block for why const env writes must survive.
                if (dop == Opcode.DECLVAR || dop == Opcode.DECLVAR_HOIST
                    || dop == Opcode.PUTLEX
                    || dop == Opcode.INITTZ) {
                    if (dop == Opcode.INITTZ) {
                        bool keep_tdz = false;
                        for (uint k = 0; k < typeof_name_count; k++) {
                            if (typeof_names[k] == self.code[i].get_bc()) { keep_tdz = true; break; }
                        }
                        if (keep_tdz) { continue; }
                    }
                    self.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                    continue;
                }
                // Loop-variable env sync: an adjacent `PUTVAR rX,n` + `GETVAR rX,n`
                // pair with identical register AND name (for_statement writes the
                // final loop counter back to the env). A genuine parent/global
                // access never produces this same-reg/same-name adjacent pair.
                if (dop == Opcode.PUTVAR && i + 1 < self.code_count
                    && self.code[i + 1].op == Opcode.GETVAR
                    && self.code[i].get_a() == self.code[i + 1].get_a()
                    && self.code[i].get_bc() == self.code[i + 1].get_bc()) {
                    self.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                    self.code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                    i++;
                }
            }
        }
    }

    // --- Peephole: fuse GETGLOBAL_PRIM + PUTGLOBAL_PRIM -> MOVE_GG ---
    // A plain `a = b` between two proven primitive-only globals compiles to a
    // GETGLOBAL_PRIM rX,S / PUTGLOBAL_PRIM rX,D pair (scratch round-trip, two
    // dispatches). Fuse the adjacent pair into one two-word MOVE_GG (dst name in
    // word 1's BC, src name in a kept trailing NOP's BC), halving the op count.
    // Runs after every register-elision pass so the pair is in its final form,
    // and before the NOP compaction pass so the trailing word is protected by
    // nop_keep[] (see below) exactly like TRY's finally slot. Needs a
    // code_count-sized bool scratch for the jump-target bitset.
    if (!self.disable_optimize && !self.has_wide && self.code_count >= 2) {
        bool* mgg_jump_targets = (bool*)h.alloc_func(h.heap_udata, (usz)self.code_cap);
        if (mgg_jump_targets == null) { self.cleanup(); return COMPILE_ERROR~; }
        run_move_gg_fusion(self.code, self.code_count, mgg_jump_targets);
        // Fuse GETGLOBAL_PRIM + JMP_LT -> JMP_LT_G (loop-bound compare). Runs
        // after compare-branch fusion has already installed the JMP_LT, and
        // before NOP compaction so the trailing name word is kept.
        run_jmp_lt_g_fusion(self.code, self.code_count, mgg_jump_targets);
        h.free_func(h.heap_udata, mgg_jump_targets);
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
            if (nop_keep == null) { self.cleanup(); return COMPILE_ERROR~; }
            mem::clear(nop_keep, (sz)((usz)self.code_count));
            for (uint i = 0; i < self.code_count; i++) {
                if (self.code[i].op == Opcode.TRY && i + 1 < self.code_count) {
                    nop_keep[i + 1] = true;
                }
                // MOVE_GG's trailing word (a NOP holding the source name index in
                // its BC) is read by the VM as the second half of the two-word
                // instruction; keep it through compaction like TRY's finally slot.
                if (self.code[i].op == Opcode.MOVE_GG && i + 1 < self.code_count) {
                    nop_keep[i + 1] = true;
                }
                // JMP_LT_G's trailing word (a NOP holding the global's name index
                // in its BC) is the second half of the two-word instruction.
                if (self.code[i].op == Opcode.JMP_LT_G && i + 1 < self.code_count) {
                    nop_keep[i + 1] = true;
                }
            }

            // Step 2: build pc_map[old_pc] → new_pc.
            // NOP slots that are not kept map to the new_pc of the next kept slot.
            pc_map = (uint*)h.alloc_func(h.heap_udata, (usz)((long)(self.code_cap + 1) * (long)uint::size));
            if (pc_map == null) { h.free_func(h.heap_udata, nop_keep); self.cleanup(); return COMPILE_ERROR~; }
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
                    case Opcode.JMP_NLT:
                    case Opcode.JMP_NLE:
                    case Opcode.JMP_NGT:
                    case Opcode.JMP_NGE:
                    case Opcode.JMP_LT:
                    case Opcode.JMP_LE:
                    case Opcode.JMP_GT:
                    case Opcode.JMP_GE:
                    case Opcode.JMP_SEQ:
                    case Opcode.JMP_SNEQ: {
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
                    case Opcode.JMP_LT_G: {
                        // Two-word ABC: signed 8-bit offset in field A, applied by
                        // the VM after BOTH words are consumed, so the target is
                        // (pc + 2) + off, and the new base is likewise the slot
                        // after the kept trailing word.
                        int off = (int)(ichar)self.code[i].a;
                        int tgt_old = (int)i + 2 + off;
                        int tgt_new = (int)pc_map[(uint)tgt_old];
                        int new_off = tgt_new - ((int)pc_map[i] + 2);
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
    if (code_raw == null) {
        if (!self.disable_optimize) {
            h.free_func(h.heap_udata, pc_map);
            h.free_func(h.heap_udata, nop_keep);
        }
        h.free_func(h.heap_udata, raw);
        return COMPILE_ERROR~;
    }
    Instruction* dst_code = (Instruction*)code_raw;
    uint dst_idx = 0;
    if (self.disable_optimize) {
        // Copy everything verbatim, preserves all NOPs introduced by the
        // peephole passes, but the VM treats NOP as no-op so execution is
        // correct.  Useful for debugging: every instruction the peephole
        // produced is visible in the dump.
        for (uint i = 0; i < self.code_count; i++) {
            dst_code[dst_idx++] = self.code[i];
        }
    } else {
        for (uint i = 0; i < self.code_count; i++) {
            if (self.code[i].op != Opcode.NOP || nop_keep[i]) {
                dst_code[dst_idx++] = self.code[i];
            }
        }
    }
    func.code = dst_code;
    func.code_count = final_count;
    if (!self.disable_optimize) {
        h.free_func(h.heap_udata, pc_map);
        h.free_func(h.heap_udata, nop_keep);
    }
}

    // Copy constant pool
    if (self.const_count > 0) {
        usz const_bytes = (usz)self.const_count * TVal::size;
        void* const_raw = h.alloc_func(h.heap_udata, const_bytes);
        if (const_raw == null) {
            if (func.code != null) { h.free_func(h.heap_udata, func.code); }
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
            if (func.constants != null) { h.free_func(h.heap_udata, func.constants); }
            h.free_func(h.heap_udata, raw);
            return COMPILE_ERROR~;
        }
        mem::copy(inner_raw, &self.inner_funcs[0], (sz)(inner_bytes));
        func.inner_funcs = (CompiledFunction**)inner_raw;
        func.inner_count = self.inner_func_count;
    }

    func.num_regs = self.max_reg;
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
    func.flags.subst_global_this = self.subst_global_this;
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
    // Direct eval must run in the caller's lexical environment: the CALL
    // paths only set ACT_FLAG_DIRECT_EVAL (which builtin_eval checks) when
    // this flag is present on the compiled function.
    func.flags.has_direct_eval = self.has_direct_eval;
    func.flags.has_home_object = self.in_class_body || self.super_is_home_object;
    func.flags.super_is_home_object = self.super_is_home_object;
    func.flags.forbid_arguments = self.forbid_arguments;

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
    bool has_params_needing_env = self.has_rest || self.default_count > 0;
    bool needs_runtime_env = ((self.has_local_bindings || self.has_lexical_bindings || self.num_args > 0) && self.has_closures)
                          || self.uses_arguments
                          || self.has_direct_eval;
    bool can_skip_env = !needs_runtime_env
                     && !has_params_needing_env
                     && !self.has_captured_local
                     && !self.is_arrow
                     && !self.is_generator
                     && !self.is_async
                     && !self.is_named_func_expr;
    func.flags.needs_env = !can_skip_env;
    func.flags.is_global = self.is_global;
    func.flags.is_eval = self.eval_mode;
    func.flags.eval_src_strict = self.saw_use_strict;
    // Record whether this eval body may itself reference new.target, so a
    // nested direct eval inside it can inherit the permission (see
    // FuncFlags.eval_allows_new_target).
    func.flags.eval_allows_new_target = self.in_eval_code && self.eval_direct_in_function;
    func.num_args = self.num_args;
    if (self.has_rest) {
        func.num_formals = self.rest_formal_count;
    } else if (self.default_count > 0) {
        // First default param doesn't count toward .length; formals before it do.
        func.num_formals = self.formal_count;
    } else {
        func.num_formals = self.num_args;
    }

    // Allocate Inline Cache array, one entry per instruction, zeroed.
    if (func.code_count > 0) {
        usz ic_bytes = (usz)func.code_count * hobject::ICEntry::size;
        void* ic_raw = h.alloc_func(h.heap_udata, ic_bytes);
        if (ic_raw != null) {
            mem::clear(ic_raw, (sz)(ic_bytes));
            func.ic_entries = ic_raw;
            func.ic_count = func.code_count;
        }

        // Allocate Variable IC array, one entry per instruction, zeroed.
        usz vic_bytes = (usz)func.code_count * hobject::VarICEntry::size;
        void* vic_raw = h.alloc_func(h.heap_udata, vic_bytes);
        if (vic_raw != null) {
            mem::clear(vic_raw, (sz)(vic_bytes));
            func.var_ic_entries = vic_raw;
            func.var_ic_count = func.code_count;
        }

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
    // hand it to compile_eval. cleanup() below would otherwise free the
    // scratch buffer; the snapshot needs to outlive this context.
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

    // Run bytecode peephole optimizations (GETPROPC2 chain fusion, etc.)
    if (!self.has_wide) { peephole::peephole_scan(func, hp); }

    // Free compiler scratch buffers, the CompiledFunction owns its own copies.
    self.cleanup();

    return func;
}

/// Maximum number of lexical declarations in a single pre-scan pass.
const uint MAX_PRESCAN_NAMES = 64;

/// Stores the position and length of a variable name in the source text.
struct NameSpan {
    uint pos;   // byte offset into the source buffer
    uint len;   // length in bytes
    // Interned decoded name, used instead of the source span when the
    // identifier contained a unicode escape (\uXXXX): the lexer decodes such
    // names into a reused scratch buffer, so str_value points neither into
    // the source nor at stable storage. Empty for plain (unescaped) names.
    char[] name;
}

const uint MAX_CLASS_METHODS = 32;

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
    // Public computed-key FIELD (P7): pseudo-entry, not a method. The install
    // loop evaluates the key once at class-definition time (in source order,
    // interleaved with method-key evaluation) and PUTLEXes it into this
    // hidden slot; __field_init__/__static_init__ reads it back per instance
    // via GETVAR. Only computed_key_inner_idx/computed_key_reg are meaningful.
    bool   is_field_key;
    char[] field_key_slot_name;     // e.g. "#priv:3:fkey0"
}

// ============================================================================
// Private class members (ES2022), name resolution scope
// ============================================================================

/// Initial capacity of the growable private-names table (across all nested
/// class bodies) tracked in a single function/program compile; grows via
/// ensure_private_name_cap as classes declare more names.
const uint INITIAL_PRIVATE_NAMES = 64;

/// Hard upper bound on distinct private names, mirroring the other growable
/// compiler tables' *_HARD caps.
const uint MAX_PRIVATE_NAMES_HARD = 1 << 20;

/// Maximum nesting depth of class bodies (for private-name scoping).
const uint MAX_CLASS_NESTING = 16;

/// Shared, heap-allocated backing store for the private-names stack. A single
/// class compile involves many CompilerContexts (the class-enclosing `self`
/// plus per-element field/method/arrow/block bodies), all of which resolve,
/// and some of which DECLARE (a nested class inside a field initializer),
/// against the SAME logical private-name stack. They share one PrivateNameTable
/// through a pointer so that a growth (realloc of `entries`) done by any one of
/// them is immediately visible to all the others: growing in place mutates this
/// struct, never a per-context copy, so no borrower is left holding a stale
/// `entries` pointer into a freed buffer.
struct PrivateNameTable {
    PrivateNameEntry* entries;
    uint count;
    uint cap;
}

/// One declared private name (`#foo`) within a class body. `slot` is the
/// compiler-managed lexical variable (declared like `__super__`) that holds
/// the runtime hidden-symbol value for this name, fresh per class evaluation.
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
    // the full rationale). Allocated right after prescan (alongside
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
