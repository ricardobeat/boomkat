module boomkat::compiler;

import boomkat::types;
import boomkat::lexer;
import boomkat::bytecode;
import boomkat::hstring;
import boomkat::hobject;
import boomkat::heap;
import boomkat::peephole;
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
// Sentinel for "no register" (used by local variables and optional register fields).
const ushort REG_NONE = 0xFFFF;
// Initial capacities for growable compiler arrays.
const uint INITIAL_CODE        = 512;
const uint INITIAL_CONSTANTS   = 128;
const uint INITIAL_CONST_HASH  = 256;
const uint INITIAL_INNER_FUNCS = 16;

// Hard limits (sanity caps to catch runaway compilation).
const uint MAX_CODE_HARD        = 1 << 22;  // 4M instructions
const uint MAX_CONSTANTS_HARD   = 1 << 20;  // 1M constants
const uint MAX_INNER_FUNCS_HARD = 1 << 16;  // 65K inner functions
const uint MAX_CAPTURED_NAMES = 48;
// Cap on primary_expr recursion depth (nested literals).
const uint MAX_EXPR_DEPTH = 256;
const uint MAX_LOOP_DEPTH  = 16;
const uint MAX_TRY_DEPTH   = 8;
const uint MAX_LABELS       = 16;
// Break/continue forward-patch slots per function (sized to fit stack limits).
const uint MAX_PATCHES      = 2048;
// Initial capacity of the hoisted-function-name table.
const uint INITIAL_HOISTED_FNS = 128;
// Initial capacity of the deferred-declaration tables.
const uint INITIAL_HOISTED_DEFERS = 8;
// Initial scope-stack capacity.
const uint INITIAL_SCOPE_DEPTH = 256;
const uint MAX_CONST_HASH   = 1024;  // Open-addressing hash table for constant dedup

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
    SCOPEMARK,   // boundary marker pushed by block() to delimit scope
}

struct ScopeEntry {
    char[] name;
    ushort reg;
    ScopeKind kind;
    bool is_captured;
    // True for a let/const binding whose initializer has not finished.
    // Forces resolve_var to return SCOPE_ERROR so access emits GETVAR and throws ReferenceError (TDZ).
    bool is_tdz;
    // True for formal parameters or catch parameters.
    bool is_param;
    // SCOPEMARK entries only: true for a function body marker vs nested BlockStatement.
    bool is_body_mark;
}

struct LoopInfo {
    uint continue_target;
    uint break_patch_head;
    uint continue_patch_head; // chain of pending continue jumps
    bool is_loop;             // false for switch pseudo-loops (continue skips these)
    int  saved_lex_depth;     // cur_lex_depth at loop entry
    int  iter_close_reg;      // >= 0: for-of iterator reg; -1 = none
    bool is_await_loop;       // for-await-of: uses ITER_CLOSE_ASYNC
    // try_depth at loop entry. Jumps within the same depth emit plain JUMP without finally dispatch.
    uint saved_try_depth;
}

struct TryInfo {
    uint catch_addr;
    uint finally_addr;
}

struct LabelInfo {
    char[] name;
    uint loop_index;   // index into loop_stack (NO_PATCH if not yet resolved)
    bool is_loop;      // true if this label refers to a loop (supports continue)
}

// Tracks a break/continue patch chain for forward-patching jumps.
struct PatchEntry {
    uint addr;        // instruction index to patch
    uint next;        // index of next in chain, or NO_PATCH
}

// Tracks a parameter with a default value expression.
struct ParamDefault {
    ushort param_reg;       // register holding the parameter
    uint    param_name_idx; // constant index of the parameter name
    uint    default_func_idx; // index into inner_funcs for the default expression
}

// Tracks a destructured parameter's outer default value.
struct DestructParamDefault {
    ushort arg_slot;          // register holding the argument
    uint    default_func_idx; // index into inner_funcs for the default expression
}

// Destructuring now routes through the single DestructBind model
// (see functions.c3 / emit_destruct_bindings); the former per-context ArrayBind
// and ObjBind structs were removed in the destructuring consolidation.

// ============================================================================
// Compile-error recording (per-lexer; written on fault, read by callers)
// ============================================================================

// Record a compile-error message into the owning Lexer's buffer (first writer wins).
// Position defaults to the lexer's current position.
fn void CompilerContext.record_error(&self, char[] msg) {
    if (self.lexer.err_msg[0] != 0) return;
    self.lexer.err_line = self.lexer.line;
    self.lexer.err_col  = self.lexer.col;
    usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
    mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
    self.lexer.err_msg[copy_len] = 0;
}

// Record a compile-error message without touching the position fields.
fn void CompilerContext.set_compile_error(&self, char[] msg) {
    if (self.lexer.err_msg[0] != 0) return;
    usz copy_len = msg.len < (self.lexer.err_msg.len - 1) ? msg.len : (self.lexer.err_msg.len - 1);
    mem::copy(&self.lexer.err_msg[0], msg.ptr, (sz)(copy_len));
    self.lexer.err_msg[copy_len] = 0;
}

// Compiler debug toggle: when true, finish() skips every peephole pass.
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

    // Recursion depth of primary_expr, guarded against MAX_EXPR_DEPTH.
    uint expr_depth;

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
    // Per-instruction source line, parallel to code: line_table[i] is the
    // line of the source token that produced code[i].
    uint* line_table;

    // Inner functions (growable)
    CompiledFunction** inner_funcs;
    uint inner_func_count;
    uint inner_func_cap;

    // Scope tracking (growable)
    ScopeEntry* scope_stack;
    uint scope_cap;
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

    // Patch list pool for break/continue forward patches (per-function pool).
    PatchEntry[MAX_PATCHES] patches;
    uint patch_count;
    // Set when add_patch overflowed; finish() turns this into a compile error.
    bool patch_overflow;
    // Set when the scope stack overflowed; finish() turns this into a compile error.
    bool scope_overflow;

    // Track last identifier resolved via GETVAR (for assignment write-back)
    bool last_was_getvar;
    uint last_getvar_name_idx;
    // Set when the last primary_expr returned an ArrowFunction.
    bool last_was_arrow_expr;

    // Set by unary_expr when it consumed a unary operator (-, +, !, ~, typeof, void, delete, await),
    // so the expression returned is a UnaryExpression rather than an UpdateExpression.
    bool last_was_unary_op;
    // True when the operand just parsed was a bare yield cut off by a newline (ES2024 §15.5).
    bool last_was_newline_yield;
    // True when the expression just parsed was an AssignmentExpression with = or compound assign.
    bool last_was_assignment;
    // The grammar's [~In] parameter: true while parsing an expression that
    // may not contain a top-level in operator (e.g. C-style for head).
    bool forbid_in;
    // Code index of the GETVAR instruction that produced the last identifier reference.
    uint last_getvar_code_pos;
    // Set alongside last_was_getvar when read was emitted as GETGLOBAL.
    bool last_was_getglobal;
    // Set alongside last_was_getglobal when read was emitted as GETGLOBAL_PRIM.
    bool last_was_getglobal_prim;
    // Set when the last primary_expr returned a live local variable register directly.
    bool last_was_local_var;
    ushort last_local_var_reg;
    // Set when the expression just parsed has AssignmentTargetType invalid (ES §13.15.1).
    bool last_target_invalid;
    // Raw text of the identifier last resolved by primary_expr (for SetFunctionName).
    char[128] last_lhs_name_buf;
    ushort last_lhs_name_len;
    // True when the name in last_lhs_name_buf reached us through a CoverParenthesizedExpression.
    bool last_lhs_name_parenthesized;
    // LHS mode: when true, member_expr saves obj/key without emitting GETPROP
    bool lhs_mode;
    // Delete mode: when true, member_expr saves obj/key for delete.
    bool del_mode;
    // Set while parsing a `class ... extends` heritage expression (LeftHandSideExpression).
    bool no_arrow_head;
    bool last_was_member;
    ushort last_member_obj_reg;
    ushort last_member_prop_reg;
    // True when last_member_obj_reg is a live local-variable register.
    bool last_member_obj_is_local;
    // True when recorded member expression is a super.x / super[x] reference (uses PUTPROP_SUPER).
    bool last_member_is_super;
    // True when recorded member expression is obj.#name (runs CHK_BRAND).
    bool last_member_is_private;

    // Set when the current expression used optional chaining (?.).
    bool last_was_optional_chain;

    // Set when parsing a parenthesized grouping expression.
    bool inside_parens;

    // Set by caller when produced value is provably discarded (void context).
    bool void_ctx;

    // Set by caller when postfix ++/-- result is provably discarded.
    bool postfix_void;

    // When true, emit_private_access skips the CHK_BRAND instruction.
    bool defer_brand_check;
    // Register holding the deferred CHK_BRAND's brand symbol.
    ushort deferred_brand_reg;
    // Constant-pool index for the private name in the deferred CHK_BRAND.
    uint deferred_brand_name_c;
    // Object register for the deferred CHK_BRAND.
    ushort deferred_brand_obj_reg;
    // Register hint for brand symbol pre-allocation.
    ushort deferred_brand_reg_hint;

    // Property call: the object register to use as 'this' in emit_call.
    ushort call_prop_obj_reg;

    // Spread call: base of evaluation region below first_arg.
    ushort spread_eval_base;

    // Register allocation ceiling (0xFFFF = no cap).
    ushort reg_cap;

    // Global scope flag: when true, all var decls use environment only (no register cache)
    bool is_global;

    // Eval mode: when true, expression statements save their last result to eval_acc_reg.
    bool   eval_mode;
    ushort eval_acc_reg;
    // True for top-level eval context and every arrow body nested inside it.
    bool   in_eval_code;
    // True for direct-eval inside a non-arrow function body (gates new.target).
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

    // Set when formal parameter is a destructuring pattern (IsSimpleParameterList = false).
    bool has_destructured_param;

    // Rest parameter tracking
    bool has_rest;
    ushort rest_formal_count;   // number of formals before rest parameter
    ushort num_args;            // total parameter count (including rest)
    ushort formal_count;        // params that count toward function.length

    // Class-related tracking
    bool is_constructable;      // true when compiling a class constructor
    bool in_class_body;         // true when parsing a class body (enables super)
    // True when current __super__ binding holds HomeObject (object literals) vs superclass ctor (classes).
    bool super_is_home_object;
    // Source offset of class element following `static` modifier.
    uint static_elem_src_start;
    bool has_super_binding;     // true when class has extends (super() available)
    // True while body belongs to a static class method (HomeObject = constructor).
    bool super_is_static_method;
    // Constant-pool index of per-class __super__ binding name.
    uint super_name_idx;
    // Constant-pool index of per-class __static_super__ binding name.
    uint static_super_name_idx;
    // Monotonic counter used to generate unique __super__ binding names.
    uint super_class_counter;

    // Private class members (ES2022)
    // Shared private-name stack (see PrivateNameTable).
    PrivateNameTable* private_name_table;
    // False when private_name_table was borrowed via adopt_private_names.
    bool owns_private_names;
    uint[MAX_CLASS_NESTING] private_scope_start;
    // Compile-time class id per open class body.
    uint[MAX_CLASS_NESTING] private_class_id;
    uint private_scope_depth;
    // True while compiling private field initializer (__field_init__).
    bool forbid_arguments;
    // True while compiling class static block (return forbidden at top level).
    bool forbid_return;
    // True while compiling class static block (await forbidden).
    bool forbid_await;
    // True while compiling class static block (yield forbidden).
    bool forbid_yield;

    // True while parser sits at the start of an AssignmentExpression (yield legal here).
    bool yield_ok_here;
    // Captured forbid_in at yield_ok_here position.
    bool yield_forbid_in;

    // True while parsing enclosing function's FormalParameters.
    bool in_formal_params;

    // Generator tracking
    bool is_generator;          // true for generator or async function (uses generator machinery)
    bool is_user_generator;     // true for syntactic * (function*, async function*, *method)

    // Lexical environment depth (tracks PUSH_LEX / POP_LEX).
    int  cur_lex_depth;

    // Strict mode: engine is strict-only; saw_use_strict records directive presence.
    bool saw_use_strict;
    // Set by dynamic Function constructors to coerce undefined receiver to globalThis.
    bool subst_global_this;

    // arguments tracking
    bool uses_arguments;

    // Local binding tracking for needs_env optimization.
    bool has_local_bindings;
    bool has_lexical_bindings;

    // Set by alloc_reg when register budget is exhausted.
    bool reg_overflow;

    // True once a WIDE prefix word has been emitted (>255 registers).
    bool has_wide;

    // Permanent register floor for parameters and hoisted slots.
    ushort reserved_regs;

    // Closure tracking
    bool has_closures;
    bool has_captured_local;
    bool is_named_func_expr;

    // Force lexical function declarations in switch blocks.
    bool force_lexical_fn_decl;

    // Names of top-level FunctionDeclarations the current block already instantiated.
    NameSpan* block_fn_spans;
    uint      block_fn_count;

    // Capture pre-scan
    char[64][48] captured_names;
    ushort[48] captured_name_lens;
    uint captured_count;
    bool capture_all;

    // Hoisted function declaration names
    char[]* hoisted_fn_names;
    uint    hoisted_fn_cap;
    uint    hoisted_fn_count;

    // Deferred body-scope function declarations
    char[]* hoisted_defer_names;
    ushort* hoisted_defer_regs;
    uint*   hoisted_defer_inner_idxs;
    uint*   hoisted_defer_name_idxs;
    uint    hoisted_defer_cap;
    uint    hoisted_defer_count;
    bool    hoisted_defer_emitted;

    // Constant-pool indices of declared globals in Script scope.
    List{uint} declared_global_name_idxs;

    // Constant-pool indices of provably primitive-only globals.
    List{uint} prim_only_name_idxs;

    // Direct eval tracking
    bool has_direct_eval;
    // Set by primary_expr when identifier "eval" is resolved.
    bool callee_is_eval;

    // Arrow/async tracking
    bool is_arrow;
    bool is_async;

    // True inside arrow function whose enclosing code has no [[NewTarget]].
    bool no_new_target;

    // Source offset of async keyword for async arrow / function expression.
    uint pending_async_arrow_src;
    uint pending_async_function_src;

    // Module tracking
    bool is_module;
    void* current_module;  // ModuleDef* (opaque to avoid import cycle)
    bool module_goal;
    // True only while parsing a statement directly in a Module's top-level StatementList.
    bool module_top_level;
    // Set when statement sits in Statement position rather than StatementListItem.
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

// True for an async generator body (`async function*` / `async *m(){}`).
macro bool CompilerContext.is_async_gen(&self) {
    return self.is_async && self.is_user_generator;
}

// True for a spec sync GeneratorFunction body (`function*` / `*m(){}`).
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
    self.scope_overflow = false;
    self.const_hash_count = 0;
    self.call_prop_obj_reg = REG_NONE;
    self.deferred_brand_reg_hint = 0xFFFF;
    self.pushback_count = 0;
    self.pending_async_arrow_src = 0xFFFFFFFF;
    self.pending_async_function_src = 0xFFFFFFFF;
    self.super_name_idx = 0xFFFFFFFF;
    self.static_super_name_idx = 0xFFFFFFFF;

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

// Free heap-allocated compiler buffers. Call after finish() or on error.
fn void CompilerContext.cleanup(&self) {
    Heap* h = (Heap*)self.heap;
    if (self.code != null) { h.free_func(h.heap_udata, self.code); self.code = null; }
    if (self.line_table != null) { h.free_func(h.heap_udata, self.line_table); self.line_table = null; }
    if (self.scope_stack != null) { h.free_func(h.heap_udata, self.scope_stack); self.scope_stack = null; }
    if (self.constants != null) { h.free_func(h.heap_udata, self.constants); self.constants = null; }
    if (self.const_hash != null) { h.free_func(h.heap_udata, self.const_hash); self.const_hash = null; }
    if (self.inner_funcs != null) { h.free_func(h.heap_udata, self.inner_funcs); self.inner_funcs = null; }
    if (self.hoisted_fn_names != null) { h.free_func(h.heap_udata, self.hoisted_fn_names); self.hoisted_fn_names = null; }
    if (self.hoisted_defer_names != null) { h.free_func(h.heap_udata, self.hoisted_defer_names); self.hoisted_defer_names = null; }
    if (self.hoisted_defer_regs != null) { h.free_func(h.heap_udata, self.hoisted_defer_regs); self.hoisted_defer_regs = null; }
    if (self.hoisted_defer_inner_idxs != null) { h.free_func(h.heap_udata, self.hoisted_defer_inner_idxs); self.hoisted_defer_inner_idxs = null; }
    if (self.hoisted_defer_name_idxs != null) { h.free_func(h.heap_udata, self.hoisted_defer_name_idxs); self.hoisted_defer_name_idxs = null; }
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

// Borrow the private-names table from an enclosing context.
fn void CompilerContext.adopt_private_names(&self, CompilerContext* parent) {
    if (self.owns_private_names && self.private_name_table != null) {
        Heap* h = (Heap*)self.heap;
        if (self.private_name_table.entries != null) {
            h.free_func(h.heap_udata, self.private_name_table.entries);
        }
        h.free_func(h.heap_udata, self.private_name_table);
    }
    self.private_name_table = parent.private_name_table;
    self.owns_private_names = false;
}

// Grow code buffer to accommodate more instructions.
fn void CompilerContext.ensure_code_cap(&self) {
    if (self.code_count < self.code_cap) return;
    uint new_cap = self.code_cap * 2;
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

// Grow the scope stack.
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

// Grow the deferred-declaration tables.
fn void CompilerContext.ensure_hoisted_defer_cap(&self) {
    if (self.hoisted_defer_cap != 0 && self.hoisted_defer_count < self.hoisted_defer_cap) return;
    uint new_cap = self.hoisted_defer_cap == 0 ? INITIAL_HOISTED_DEFERS : self.hoisted_defer_cap * 2;
    Heap* h = (Heap*)self.heap;
    void* pn = h.realloc_func(h.heap_udata, self.hoisted_defer_names, (usz)(new_cap * char[]::size));
    void* pr = h.realloc_func(h.heap_udata, self.hoisted_defer_regs, (usz)(new_cap * ushort::size));
    void* pi = h.realloc_func(h.heap_udata, self.hoisted_defer_inner_idxs, (usz)(new_cap * uint::size));
    void* px = h.realloc_func(h.heap_udata, self.hoisted_defer_name_idxs, (usz)(new_cap * uint::size));
    if (pn == null || pr == null || pi == null || px == null) {
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
    t.entries = (PrivateNameEntry*)p;
    t.cap = new_cap;
}

// Register an inner function and return its index.
fn uint CompilerContext.add_inner_func(&self, CompiledFunction* func) {
    self.ensure_inner_func_cap();
    if (self.inner_func_count >= self.inner_func_cap) return 0;
    uint idx = self.inner_func_count;
    self.inner_funcs[idx] = func;
    self.inner_func_count++;
    self.has_closures = true;
    return idx;
}

// Parse the optional `= default` initializer on a destructured function parameter.
// Compiles default as an inner function and defers emission until all parameters are parsed.
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

// Emit the deferred outer-default checks recorded by parse_destruct_param_default.
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
        uint skip_addr = self.emit_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0);
        self.free_reg(cmp_reg);

        // Call the default thunk. Result replaces the arg slot in-place.
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

// Finalise compilation: allocate a CompiledFunction and copy code/constants.
fn CompiledFunction*? CompilerContext.finish(&self) {
    if (self.reg_overflow) {
        return self.fail("register limit exceeded")~;
    }
    if (self.patch_overflow) {
        return self.fail("too many break/continue targets in one function")~;
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
        uint* me_words = (uint*)h.alloc_func(h.heap_udata, (4 * n + 4) * (usz)words_per_set * uint::size);
        if (me_jump_targets == null || me_in_try == null || me_live_out == null || me_live_in == null
            || me_ret_out == null || me_ret_in == null || me_words == null) {
            if (me_jump_targets != null) { h.free_func(h.heap_udata, me_jump_targets); }
            if (me_in_try != null) { h.free_func(h.heap_udata, me_in_try); }
            if (me_live_out != null) { h.free_func(h.heap_udata, me_live_out); }
            if (me_live_in != null) { h.free_func(h.heap_udata, me_live_in); }
            if (me_ret_out != null) { h.free_func(h.heap_udata, me_ret_out); }
            if (me_ret_in != null) { h.free_func(h.heap_udata, me_ret_in); }
            if (me_words != null) { h.free_func(h.heap_udata, me_words); }
            self.cleanup();
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
        run_move_elimination(self.code, self.code_count, me_jump_targets, me_in_try, me_live_out, me_live_in,
                             me_ret_out, me_ret_in, &me_scratch[0]);
        h.free_func(h.heap_udata, me_jump_targets);
        h.free_func(h.heap_udata, me_in_try);
        h.free_func(h.heap_udata, me_live_out);
        h.free_func(h.heap_udata, me_live_in);
        h.free_func(h.heap_udata, me_ret_out);
        h.free_func(h.heap_udata, me_ret_in);
        h.free_func(h.heap_udata, me_words);
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

    // Super-binding-name snapshot: any function compiled inside a class
    // records the HString* of that class's numbered __super__ binding (e.g.
    // "__super__0"). builtin_eval re-interns it into the eval context's
    // constant pool so direct `eval("super.x")` GETVARs the numbered
    // binding instead of the literal "__super__" that no longer exists in
    // the env chain; Object.setPrototypeOf's class sync (object.c3) writes
    // the new [[Prototype]] under this name.
    if (self.super_name_idx != 0xFFFFFFFF) {
        func.super_binding_name = self.constants[self.super_name_idx].get_heapptr();
    }
    if (self.static_super_name_idx != 0xFFFFFFFF) {
        func.static_super_binding_name = self.constants[self.static_super_name_idx].get_heapptr();
    }

    // Run bytecode peephole optimizations (GETPROPC2 chain fusion, etc.)
    if (!self.has_wide) { peephole::peephole_scan(func, hp); }

    // Free compiler scratch buffers, the CompiledFunction owns its own copies.
    self.cleanup();

    return func;
}

// Maximum number of lexical declarations in a single pre-scan pass.
const uint MAX_PRESCAN_NAMES = 64;

// Stores the position and length of a variable name in the source text.
struct NameSpan {
    uint pos;   // byte offset into the source buffer
    uint len;   // length in bytes
    // Interned decoded name, used instead of the source span when the
    // identifier contained a unicode escape (\uXXXX). Empty for plain names.
    char[] name;
    // True when this name came from a top-level FunctionDeclaration rather
    // than a let/const/class binding (ES §14.2.11 BlockDeclarationInstantiation).
    bool is_fn;
    // Scan position of the function/async keyword of that declaration.
    LexerPos fn_pos;
}

// A resumable scan position inside the source, taken at a statement boundary.
struct LexerPos {
    uint pos;
    uint line;
    uint col;
    // Both affect how the next token is scanned (ASI and regexp-vs-division).
    bool at_line_start;
    bool force_regex_after_brace;
    bool seen_line_term;
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
    uint   computed_key_reg;        // register holding inline key result (0xFFFF = none)
    bool   is_private;
    char[] priv_slot_name;          // e.g. "#priv:3:foo", the name's own symbol
    bool   is_field_key;
    char[] field_key_slot_name;     // e.g. "#priv:3:fkey0"
}

// ============================================================================
// Private class members (ES2022), name resolution scope
// ============================================================================

// Initial capacity of the growable private-names table.
const uint INITIAL_PRIVATE_NAMES = 64;

// Hard upper bound on distinct private names.
const uint MAX_PRIVATE_NAMES_HARD = 1 << 20;

// Maximum nesting depth of class bodies (for private-name scoping).
const uint MAX_CLASS_NESTING = 16;

// Shared, heap-allocated backing store for the private-names stack.
struct PrivateNameTable {
    PrivateNameEntry* entries;
    uint count;
    uint cap;
}

// One declared private name (`#foo`) within a class body.
struct PrivateNameEntry {
    char[] name;         // e.g. "foo" (without '#')
    // Lexical binding name of this name's symbol slot, e.g. "#priv:3:foo"
    // (unique per class body via a compile-time class id). Points at interned
    // HString data for stable storage across contexts.
    char[] slot_name;
    // Binding name of the owning class's brand slot ("#priv:<id>:brand").
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
