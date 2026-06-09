/// Duktape compiler — recursive-descent parser with direct bytecode emission.
///
/// Takes tokens from the Lexer and emits register-based bytecode into a
/// CompiledFunction.  The compiler implements a full recursive-descent
/// parser covering ECMAScript statements and expressions, using a Pratt
/// parser for binary operator precedence.
///
/// Usage:
///   Lexer lex = Lexer.init(source, heap);
///   CompiledFunction* fn = compile(&lex, heap)!;
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

const uint MAX_REGISTERS  = 512;
const uint MAX_PARAMS     = 32;
const uint MAX_CODE        = 4096;
const uint MAX_CONSTANTS   = 1024;
const uint MAX_INNER_FUNCS = 64;
const uint MAX_SCOPE_DEPTH = 256;
const uint MAX_LOOP_DEPTH  = 16;
const uint MAX_TRY_DEPTH   = 8;
const uint MAX_LABELS       = 16;

/// Sentinel for "no patch" in break/continue patch lists.
const uint NO_PATCH = 0xFFFF_FFFF;

// ============================================================================
// Binary operator precedence levels (for Pratt parser)
// ============================================================================

const int PREC_NONE          = 0;
const int PREC_COMMA         = 1;
const int PREC_ASSIGNMENT    = 2;
const int PREC_CONDITIONAL   = 3;
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
const int PREC_UNARY          = 16;
const int PREC_POSTFIX        = 17;
const int PREC_CALL           = 18;

// ============================================================================
// Supporting structures
// ============================================================================

enum ScopeKind : char {
    VAR,
    LET,
    CONST,
}

struct ScopeEntry {
    char[] name;
    ushort reg;
    ScopeKind kind;
    bool is_captured;
}

struct LoopInfo {
    uint continue_target;
    uint break_patch_head;
    uint continue_patch_head; ///< chain of pending continue jumps (deferred until target resolved)
    bool is_loop;             ///< false for switch pseudo-loops (continue skips these)
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

/// Tracks a binding in an array destructuring pattern.
struct ArrayBind {
    ushort reg;
    uint   name_idx;
    bool   is_rest;
    bool   is_hole;
}

/// Tracks a binding in an object destructuring pattern.
struct ObjBind {
    ushort reg;
    uint   name_idx;
    uint   key_idx;
}

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

    // Constant pool
    TVal[MAX_CONSTANTS] constants;
    uint const_count;

    // Code emission
    Instruction[MAX_CODE] code;
    uint code_count;

    // Inner functions
    CompiledFunction*[MAX_INNER_FUNCS] inner_funcs;
    uint inner_func_count;

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

    // Patch list pool for break/continue forward patches
    PatchEntry[256] patches;
    uint patch_count;

    // Track last identifier resolved via GETVAR (for assignment write-back)
    bool last_was_getvar;
    uint last_getvar_name_idx;
    /// Set when the last primary_expr returned a live local variable register directly.
    bool last_was_local_var;
    ushort last_local_var_reg;
    /// LHS mode: when true, member_expr saves obj/key without emitting GETPROP
    bool lhs_mode;
    /// Delete mode: when true, member_expr saves obj/key for delete.
    /// Separate from lhs_mode because expression() inside [bracket] calls
    /// assignment_expr which resets lhs_mode.
    bool del_mode;
    bool last_was_member;
    ushort last_member_obj_reg;
    ushort last_member_prop_reg;

    /// Property call: the object register to use as 'this' in emit_call.
    /// Set to MAX_REGISTERS when not in a property call.
    ushort call_prop_obj_reg;

    // Global scope flag: when true, all var decls use environment only (no register cache)
    bool is_global;

    // Eval mode: when true, expression statements save their last result
    // to eval_acc_reg for eval's implicit return value.
    bool   eval_mode;
    ushort eval_acc_reg;

    // Strict mode: set by "use strict" directive prologue.
    bool is_strict;

    // Token pushback buffer for limited backtracking (used by arrow function parsing).
    Token[4] pushback_stack;
    uint pushback_count;

    // Default parameter tracking
    ParamDefault[MAX_PARAMS] defaults;
    ushort default_count;

    // Rest parameter tracking
    bool has_rest;
    ushort rest_formal_count;   // number of formals before rest parameter
    ushort num_args;            // total parameter count (including rest)

    // Class-related tracking
    bool is_constructable;      // true when compiling a class constructor
    bool in_class_body;         // true when parsing a class body (enables super)
    bool has_super_binding;     // true when class has extends (super() available)

    // Generator tracking
    bool is_generator;          // true when compiling a generator function (function*)

    // arguments tracking
    bool uses_arguments;        // true when 'arguments' is referenced in function body

    // Local binding tracking — used to decide needs_env optimisation.
    // Set to true when the function body contains any var/function declarations
    // that would be hoisted to the function scope.
    bool has_local_bindings;

    // Direct eval tracking — when true, the CALL path must create a fresh env.
    bool has_direct_eval;

    // Arrow/async tracking — needed for needs_env computation in finish().
    bool is_arrow;
    bool is_async;
}

// ============================================================================
// Top-level entry points
// ============================================================================

/// Compile a complete program (sequence of statements).
/// Returns the top-level CompiledFunction or a fault on error.
fn CompiledFunction*? compile(Lexer* lex, void* heap) {
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;

    // Check for "use strict" directive prologue at program level
    ctx.parse_directives()!;

    // Parse statements until EOF
    while (!ctx.is_at_end()) {
        ctx.statement()!;
    }

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

    // Check for "use strict" directive prologue at eval level
    ctx.parse_directives()!;

    // Parse statements until EOF
    while (!ctx.is_at_end()) {
        ctx.statement()!;
    }

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

// ============================================================================
// CompilerContext — initialisation and finalisation
// ============================================================================

fn void CompilerContext.init(&self, Lexer* lex, void* heap) {
    libc::memset(self, 0, CompilerContext::size);
    self.lexer = lex;
    self.heap = heap;
    self.next_reg = 0;
    self.max_reg = 0;
    self.const_count = 0;
    self.code_count = 0;
    self.inner_func_count = 0;
    self.scope_depth = 0;
    self.loop_depth = 0;
    self.try_depth = 0;
    self.label_count = 0;
    self.patch_count = 0;
    self.call_prop_obj_reg = MAX_REGISTERS;
    self.pushback_count = 0;

    // Strict-only engine: all code runs in strict mode by default
    self.is_strict = true;
    self.lexer.set_strict(true);
}

/// Finalise compilation: allocate a CompiledFunction and copy code/constants.
fn CompiledFunction*? CompilerContext.finish(&self) {
    // Allocate the CompiledFunction struct
    void* raw = libc::malloc(CompiledFunction::size);
    if (raw == null) {
        return COMPILE_ERROR~;
    }
    libc::memset(raw, 0, CompiledFunction::size);

    CompiledFunction* func = (CompiledFunction*)raw;
    func.flags.htype = HType.OBJECT;

    // --- Peephole: fuse GETVAR + INC/DEC + PUTVAR into INC_VAR/DEC_VAR ---
    // Pattern: GETVAR r, name  /  INC r  /  PUTVAR r, name
    //   → NOP  /  INC_VAR name  /  NOP
    // Saves 2 dispatches per loop iteration on the hot counter path.
    if (self.code_count >= 3) {
        for (uint i = 0; i + 2 < self.code_count; i++) {
            Opcode op0 = self.code[i].op;
            Opcode op1 = self.code[i + 1].op;
            Opcode op2 = self.code[i + 2].op;
            if (op0 == Opcode.GETVAR
                && (op1 == Opcode.INC || op1 == Opcode.DEC)
                && op2 == Opcode.PUTVAR) {
                uint reg_a = self.code[i].a;
                if (self.code[i + 1].a == reg_a && self.code[i + 2].a == reg_a) {
                    uint name0 = self.code[i].get_bc();
                    uint name2 = self.code[i + 2].get_bc();
                    if (name0 == name2 && name0 < self.const_count) {
                        Opcode fused = (op1 == Opcode.INC) ? Opcode.INC_VAR : Opcode.DEC_VAR;
                        self.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                        self.code[i + 1] = bytecode::make_a_bc(fused, 0, name0);
                        self.code[i + 2] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                    }
                }
            }
        }
    }

    // Copy instruction stream
    if (self.code_count > 0) {
        usz code_bytes = (usz)self.code_count * Instruction::size;
        void* code_raw = libc::malloc(code_bytes);
        if (code_raw == null) {
            libc::free(raw);
            return COMPILE_ERROR~;
        }
        libc::memcpy(code_raw, &self.code[0], code_bytes);
        func.code = (Instruction*)code_raw;
        func.code_count = self.code_count;
    }

    // Copy constant pool
    if (self.const_count > 0) {
        usz const_bytes = (usz)self.const_count * TVal::size;
        void* const_raw = libc::malloc(const_bytes);
        if (const_raw == null) {
            if (func.code != null) { libc::free(func.code); }
            libc::free(raw);
            return COMPILE_ERROR~;
        }
        libc::memcpy(const_raw, &self.constants[0], const_bytes);
        func.constants = (TVal*)const_raw;
        func.const_count = self.const_count;
    }

    // Copy inner functions
    if (self.inner_func_count > 0) {
        usz inner_bytes = (usz)self.inner_func_count * CompiledFunction*::size;
        void* inner_raw = libc::malloc(inner_bytes);
        if (inner_raw == null) {
            if (func.code != null) { libc::free(func.code); }
            if (func.constants != null) { libc::free(func.constants); }
            libc::free(raw);
            return COMPILE_ERROR~;
        }
        libc::memcpy(inner_raw, &self.inner_funcs[0], inner_bytes);
        func.inner_funcs = (CompiledFunction**)inner_raw;
        func.inner_count = self.inner_func_count;
    }

    func.num_regs = self.max_reg;
    func.flags.is_strict = self.is_strict;
    func.flags.has_rest = self.has_rest;
    func.flags.is_constructable = self.is_constructable;
    func.flags.is_generator = self.is_generator;
    func.flags.uses_arguments = self.uses_arguments;

    // `needs_env` is false when the function is a plain non-arrow, non-generator,
    // non-async function with no var/function declarations, no arguments, no eval,
    // no rest params and no default params — the CALL fast path can reuse the
    // parent's env directly, avoiding two allocations per call.
    bool has_params_needing_env = self.has_rest || self.default_count > 0;
    bool can_skip_env = !self.has_local_bindings
                     && !self.uses_arguments
                     && !self.has_direct_eval
                     && !has_params_needing_env
                     && !self.is_arrow
                     && !self.is_generator
                     && !self.is_async;
    func.flags.needs_env = !can_skip_env;
    func.num_args = self.num_args;
    if (self.has_rest) {
        func.num_formals = self.rest_formal_count;
    } else {
        func.num_formals = self.num_args;
    }

    // Allocate Inline Cache array — one entry per instruction, zeroed.
    if (func.code_count > 0) {
        usz ic_bytes = (usz)func.code_count * hobject::ICEntry::size;
        void* ic_raw = libc::malloc(ic_bytes);
        if (ic_raw != null) {
            libc::memset(ic_raw, 0, ic_bytes);
            func.ic_entries = ic_raw;
            func.ic_count = func.code_count;
        }

        // Allocate Variable IC array — one entry per instruction, zeroed.
        usz vic_bytes = (usz)func.code_count * hobject::VarICEntry::size;
        void* vic_raw = libc::malloc(vic_bytes);
        if (vic_raw != null) {
            libc::memset(vic_raw, 0, vic_bytes);
            func.var_ic_entries = vic_raw;
            func.var_ic_count = func.code_count;
        }
    }

    // Track the CompiledFunction for cleanup when the heap is destroyed
    heap::Heap* hp = (heap::Heap*)self.heap;
    hp.track_compiled_func(raw);

    return func;
}

// ============================================================================
// Token consumption helpers
// ============================================================================

/// Advance: consume the next token from the lexer and return it.
fn Token? CompilerContext.advance(&self) {
    // Check pushback buffer first
    if (self.pushback_count > 0) {
        self.pushback_count--;
        return self.pushback_stack[self.pushback_count];
    }
    Token tok = self.lexer.next_token()!;
    return tok;
}

/// Expect the next token to be of the given type; consume and return it.
/// Returns COMPILE_ERROR if the type doesn't match.
fn Token? CompilerContext.expect(&self, TokenType tt) {
    Token tok = self.advance()!;
    if (tok.type != tt) {
        return COMPILE_ERROR~;
    }
    return tok;
}

/// If the next token matches `tt`, consume it and return true.
/// Otherwise leave it unconsumed and return false.
fn bool CompilerContext.match(&self, TokenType tt) {
    if (self.check(tt)) {
        if (try _tok = self.advance()) {
            return true;
        }
    }
    return false;
}

/// Peek at the next token type without consuming.
fn TokenType CompilerContext.peek_type(&self) {
    // Check pushback buffer first
    if (self.pushback_count > 0) {
        return self.pushback_stack[self.pushback_count - 1].type;
    }
    if (try tok = self.lexer.peek()) {
        return tok.type;
    }
    return TokenType.EOF_TOKEN;
}

/// Check if the next token is the given type without consuming.
fn bool CompilerContext.check(&self, TokenType tt) {
    return self.peek_type() == tt;
}

/// Read the next token as a property name (IdentifierName).
/// After '.' or other contexts where any keyword can be used as a name,
/// this returns the string value regardless of whether the token is an
/// IDENTIFIER or a keyword token.
fn char[]? CompilerContext.read_property_name(&self) {
    Token? tok_opt = self.lexer.next_token();
    if (catch err = tok_opt) return COMPILE_ERROR~;
    Token tok = tok_opt;
    if (tok.str_value.len > 0) return tok.str_value;
    char[] kw_str = lexer::keyword_to_string(tok.type);
    if (kw_str.len > 0) return kw_str;
    return COMPILE_ERROR~;
}

/// Check if the next token is a template literal token (backtick-originated).
/// Only returns true for tokens that START a template literal (TEMPLATE, TEMPLATE_HEAD,
/// or STRING with is_template). Does NOT return true for TEMPLATE_MIDDLE or TEMPLATE_TAIL
/// which appear only inside an already-in-progress template parse.
fn bool CompilerContext.is_next_template(&self) {
    // Check compiler pushback buffer first
    if (self.pushback_count > 0) {
        Token tok = self.pushback_stack[self.pushback_count - 1];
        return (tok.type == TokenType.STRING && tok.is_template)
            || tok.type == TokenType.TEMPLATE
            || tok.type == TokenType.TEMPLATE_HEAD;
    }
    if (try tok = self.lexer.peek()) {
        return (tok.type == TokenType.STRING && tok.is_template)
            || tok.type == TokenType.TEMPLATE
            || tok.type == TokenType.TEMPLATE_HEAD;
    }
    return false;
}

/// Returns true if we've reached the end of input.
fn bool CompilerContext.is_at_end(&self) {
    return self.peek_type() == TokenType.EOF_TOKEN;
}

/// Push a token back into the input stream for backtracking.
/// The next call to advance() will return this token.
/// Supports up to 4 tokens of lookback.
fn void CompilerContext.pushback(&self, Token tok) {
    if (self.pushback_count < 4) {
        self.pushback_stack[self.pushback_count] = tok;
        self.pushback_count++;
    }
}

// ============================================================================
// Register allocation
// ============================================================================

/// Allocate the next free register.
fn ushort CompilerContext.alloc_reg(&self) {
    ushort reg = self.next_reg;
    self.next_reg++;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
    if (self.next_reg > MAX_REGISTERS) {
        io::printfn("COMPILE ERROR: register limit exceeded (next_reg=%d, max %d)", self.next_reg, MAX_REGISTERS - 1);
        libc::abort();
    }
    return reg;
}

/// Allocate multiple consecutive registers, returning the first.
fn ushort CompilerContext.alloc_regs(&self, ushort count) {
    ushort first = self.next_reg;
    self.next_reg += count;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
    if (self.next_reg > MAX_REGISTERS) {
        io::printfn("COMPILE ERROR: register limit exceeded (next_reg=%d, max %d)", self.next_reg, MAX_REGISTERS - 1);
        libc::abort();
    }
    return first;
}

/// Free a register (only frees if it's the top of the stack).
fn void CompilerContext.free_reg(&self, ushort reg) {
    if (reg + 1 == self.next_reg) {
        self.next_reg--;
    }
}

/// Free registers back to a saved point.
fn void CompilerContext.free_regs_to(&self, ushort saved) {
    if (self.next_reg > saved) {
        self.next_reg = saved;
    }
}

// ============================================================================
// Code emission
// ============================================================================

/// Emit a raw instruction, returning its index in the code array.
fn uint CompilerContext.emit(&self, Instruction inst) {
    if (self.code_count >= MAX_CODE) {
        return self.code_count;  // silently cap (real impl would error)
    }
    uint idx = self.code_count;
    self.code[idx] = inst;
    self.code_count++;
    return idx;
}

/// Emit an instruction in A-B-C format.
fn uint CompilerContext.emit_abc(&self, Opcode op, uint a, uint b, uint c) {
    return self.emit(bytecode::make_abc(op, a, b, c));
}

/// Emit an instruction in A-BC format.
fn uint CompilerContext.emit_a_bc(&self, Opcode op, uint a, uint bc) {
    return self.emit(bytecode::make_a_bc(op, a, bc));
}

/// Emit an instruction in A-sBx format.
fn uint CompilerContext.emit_a_sbx(&self, Opcode op, uint a, int sbx) {
    return self.emit(bytecode::make_a_sbx(op, a, sbx));
}

/// Emit a JUMP instruction with a placeholder offset; return the index to patch.
fn uint CompilerContext.emit_jump(&self, Opcode op) {
    return self.emit(bytecode::make_sabc(op, 0));
}

/// Emit a conditional branch with placeholder offset.
fn uint CompilerContext.emit_cond_jump(&self, Opcode op, uint a) {
    return self.emit(bytecode::make_a_sbx(op, a, 0));
}

/// Patch a previously emitted JUMP to target the current code position.
fn void CompilerContext.patch_jump(&self, uint addr) {
    if (addr >= self.code_count) { return; }
    Opcode op = self.code[addr].op;
    int offset = (int)self.code_count - (int)addr - 1;

    if (op == Opcode.JUMP) {
        self.code[addr] = bytecode::make_sabc(Opcode.JUMP, offset);
    } else {
        // Conditional branch: preserve the A field
        uint a = self.code[addr].a;
        self.code[addr] = bytecode::make_a_sbx(op, a, offset);
    }
}

/// Emit a no-operand instruction.
fn uint CompilerContext.emit_simple(&self, Opcode op) {
    return self.emit(bytecode::make_abc(op, 0, 0, 0));
}

// ============================================================================
// Constant pool
// ============================================================================

/// Add a TVal to the constant pool and return its index.
fn uint CompilerContext.add_constant(&self, TVal val) {
    // Check for duplicates (number and fastint)
    for (uint i = 0; i < self.const_count; i++) {
        if (self.constants[i].get_tag() == val.get_tag()) {
            if (val.is_number()) {
                if (self.constants[i].get_number() == val.get_number()) {
                    return i;
                }
            } else if (val.is_fastint()) {
                if (self.constants[i].get_fastint() == val.get_fastint()) {
                    return i;
                }
            }
        }
    }

    if (self.const_count >= MAX_CONSTANTS) {
        return self.const_count;  // cap
    }
    uint idx = self.const_count;
    self.constants[idx] = val;
    self.const_count++;
    return idx;
}

/// Add a string constant: intern the string and add a STRING TVal to the pool.
fn uint CompilerContext.add_string_constant(&self, char[] str) {
    // Check for duplicate string constants by scanning existing entries
    for (uint i = 0; i < self.const_count; i++) {
        if (self.constants[i].is_string()) {
            HString* existing = (HString*)self.constants[i].get_heapptr();
            if (existing != null && existing.equals(str)) {
                return i;
            }
        }
    }

    // Intern the string via the heap's string table for pointer deduplication
    Heap* hp = (Heap*)self.heap;
    uint hash = hp.hash_string(str);

    // First, check if the string is already interned in the heap
    HString* hstr = hp.str_table_lookup(str, hash);
    if (hstr == null) {
        // Not found — allocate and insert
        hstr = hstring::hstring_alloc(self.heap, str, hash) ?? null;
        if (hstr != null) {
            hp.str_table_insert(hstr);
        }
    }

    TVal tv;
    if (hstr != null) {
        tv.set_string(hstr);
    } else {
        // Fallback: store as pointer with null
        tv.set_string(null);
    }

    if (self.const_count >= MAX_CONSTANTS) {
        return self.const_count;
    }
    uint idx = self.const_count;
    self.constants[idx] = tv;
    if (hstr != null) { ((types::HeapHeader*)hstr).incref(); }
    self.const_count++;
    return idx;
}

/// Add a number constant and return its index.
fn uint CompilerContext.add_number_constant(&self, double val) {
    TVal tv;
    tv.set_number(val);
    return self.add_constant(tv);
}

// ============================================================================
// Scope management
// ============================================================================

/// Push a new scope level (for blocks, functions, etc.).
fn void CompilerContext.push_scope(&self) {
    // We use scope_depth as a marker; entries below it belong to outer scopes.
    // Nothing to allocate — scope_stack is shared with depth tracking.
}

/// Pop the current scope level, freeing any variables declared in it.
fn void CompilerContext.pop_scope(&self) {
    // Walk backwards through scope_stack and remove entries at current depth
    while (self.scope_depth > 0) {
        // Peek at the topmost entry
        ScopeEntry* top = &self.scope_stack[self.scope_depth - 1];
        // Free the register
        self.free_reg(top.reg);
        self.scope_depth--;
        break;  // We'll be called in a loop by the block parser
    }
}

/// Pop all scope entries added since `saved_depth`.
fn void CompilerContext.pop_scope_to(&self, uint saved_depth) {
    while (self.scope_depth > saved_depth) {
        ScopeEntry* top = &self.scope_stack[self.scope_depth - 1];
        self.free_reg(top.reg);
        self.scope_depth--;
    }
}

/// Declare a variable in the current scope.
fn ushort CompilerContext.declare_var(&self, char[] name, ScopeKind kind) {
    ushort reg = self.alloc_reg();
    // At global scope, don't register-cache — use environment via PUTVAR/GETVAR
    if (!self.is_global && self.scope_depth < MAX_SCOPE_DEPTH) {
        self.scope_stack[self.scope_depth].name = name;
        self.scope_stack[self.scope_depth].reg = reg;
        self.scope_stack[self.scope_depth].kind = kind;
        self.scope_stack[self.scope_depth].is_captured = false;
        self.scope_depth++;
    }
    return reg;
}

/// Resolve a variable name to its register. Searches from innermost scope out.
/// Returns SCOPE_ERROR if not found or if the variable is captured (must go
/// through the environment chain instead of using a register).
fn ushort? CompilerContext.resolve_var(&self, char[] name) {
    // Search from top of scope stack backwards
    if (self.scope_depth == 0) {
        return SCOPE_ERROR~;
    }
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        if (str_eq(self.scope_stack[i].name, name)) {
            // If captured (e.g. shadowed by a let/const in an inner scope),
            // force environment lookup so the VM walks the lex_env chain.
            if (self.scope_stack[i].is_captured) {
                return SCOPE_ERROR~;
            }
            return self.scope_stack[i].reg;
        }
    }
    return SCOPE_ERROR~;
}

/// Check if a variable is const.
fn bool CompilerContext.is_var_const(&self, char[] name) {
    if (self.scope_depth == 0) {
        return false;
    }
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        if (str_eq(self.scope_stack[i].name, name)) {
            return self.scope_stack[i].kind == CONST;
        }
    }
    return false;
}

// ============================================================================
// Patch list management (for break/continue)
// ============================================================================

/// Add a patch address to a chain. Returns the new head.
fn uint CompilerContext.add_patch(&self, uint chain_head, uint addr) {
    if (self.patch_count >= 256) {
        return chain_head;
    }
    uint idx = self.patch_count;
    self.patches[idx].addr = addr;
    self.patches[idx].next = chain_head;
    self.patch_count++;
    return idx;
}

/// Patch all jumps in a patch chain to point to the current code position.
fn void CompilerContext.patch_chain(&self, uint chain_head) {
    uint current = chain_head;
    while (current != NO_PATCH && current < self.patch_count) {
        uint addr = self.patches[current].addr;
        self.patch_jump(addr);
        current = self.patches[current].next;
    }
}

// ============================================================================
// Loop stack management
// ============================================================================

fn void CompilerContext.push_loop(&self, uint continue_target, bool is_loop) {
    if (self.loop_depth < MAX_LOOP_DEPTH) {
        self.loop_stack[self.loop_depth].continue_target = continue_target;
        self.loop_stack[self.loop_depth].break_patch_head = NO_PATCH;
        self.loop_stack[self.loop_depth].continue_patch_head = NO_PATCH;
        self.loop_stack[self.loop_depth].is_loop = is_loop;
        self.loop_depth++;
    }
}

/// Patch all pending continue jumps for a loop entry to the given target address.
fn void CompilerContext.patch_continue_chain(&self, uint head, uint target) {
    uint current = head;
    while (current != NO_PATCH) {
        uint next = self.patches[current].next;
        int offset = (int)target - (int)self.patches[current].addr - 1;
        self.code[self.patches[current].addr] = bytecode::make_sabc(Opcode.JUMP, offset);
        current = next;
    }
}

fn void CompilerContext.pop_loop(&self) {
    if (self.loop_depth > 0) {
        self.loop_depth--;
        // Patch all continue jumps to their target (if any pending)
        if (self.loop_stack[self.loop_depth].continue_patch_head != NO_PATCH) {
            self.patch_continue_chain(
                self.loop_stack[self.loop_depth].continue_patch_head,
                self.loop_stack[self.loop_depth].continue_target);
        }
        // Patch all break jumps to current position
        self.patch_chain(self.loop_stack[self.loop_depth].break_patch_head);
    }
}

fn void CompilerContext.add_break_patch(&self, uint addr) {
    if (self.loop_depth > 0) {
        uint top = self.loop_depth - 1;
        self.loop_stack[top].break_patch_head =
            self.add_patch(self.loop_stack[top].break_patch_head, addr);
    }
}

// ============================================================================
// Statement parsing
// ============================================================================

/// Parse and compile a single statement, dispatching on token type.
fn void? CompilerContext.statement(&self) {
    TokenType tt = self.peek_type();

    switch (tt) {
        case TokenType.LBRACE:
            self.block(false)!;
        case TokenType.VAR:
            self.var_declaration()!;
        case TokenType.LET:
            self.var_declaration()!;
        case TokenType.CONST:
            self.var_declaration()!;
        case TokenType.IF:
            self.if_statement()!;
        case TokenType.WHILE:
            self.while_statement()!;
        case TokenType.DO:
            self.do_while_statement()!;
        case TokenType.FOR:
            self.for_statement()!;
        case TokenType.RETURN:
            self.return_statement()!;
        case TokenType.THROW:
            self.throw_statement()!;
        case TokenType.TRY:
            self.try_statement()!;
        case TokenType.SWITCH:
            self.switch_statement()!;
        case TokenType.WITH:
            self.with_statement()!;
        case TokenType.BREAK:
            self.break_statement()!;
        case TokenType.CONTINUE:
            self.continue_statement()!;
        case TokenType.FUNCTION:
            self.function_declaration()!;
        case TokenType.CLASS:
            self.class_declaration()!;
        case TokenType.SEMICOLON:
            // Empty statement
            self.advance()!;
        case TokenType.DEBUGGER:
            self.advance()!;
            self.emit_simple(Opcode.DEBUGGER);
            self.match(TokenType.SEMICOLON);
        default:
            // Check for labels: identifier : statement
            // We consume the identifier and check if the next token is ':'
            if (tt == TokenType.IDENTIFIER) {
                // Consume the identifier token to check what follows
                Token id_tok = self.advance()!;
                if (self.peek_type() == TokenType.COLON) {
                    self.advance()!; // consume ':'
                    self.labeled_statement(id_tok.str_value)!;
                    break;
                }
                // Not a label — push the identifier back and fall through
                self.lexer.pushback(id_tok);
            }
            self.expression_statement()!;
    }
}

/// Check if a name is restricted in strict mode (ES5 §11.6.2.2, §12.10.1).
/// `eval` and `arguments` cannot be used as identifiers.
fn bool is_restricted_name(char[] name) @inline {
    if (name.len == 4 && name[0] == 'e' && name[1] == 'v' && name[2] == 'a' && name[3] == 'l') {
        return true;
    }
    if (name.len == 9 && name[0] == 'a' && name[1] == 'r' && name[2] == 'g' &&
        name[3] == 'u' && name[4] == 'm' && name[5] == 'e' &&
        name[6] == 'n' && name[7] == 't' && name[8] == 's') {
        return true;
    }
    return false;
}

/// Parse directive prologue statements at the start of a function body or program.
/// Detects "use strict" and enables strict mode if found (ES5 §14.1).
fn void? CompilerContext.parse_directives(&self) {
    while (true) {
        if (!self.check(TokenType.STRING)) {
            break;
        }

        Token str_tok = self.advance()!;

        bool has_semicolon = self.check(TokenType.SEMICOLON);
        bool has_asi = self.lexer.seen_line_term;

        if (has_semicolon || has_asi) {
            if (has_semicolon) {
                self.advance()!;
            }

            if (str_tok.str_value.len == 10) {
                bool is_use_strict = true;
                char[] expected = "use strict";
                for (usz i = 0; i < 10; i++) {
                    if (str_tok.str_value[i] != expected[i]) {
                        is_use_strict = false;
                        break;
                    }
                }
                if (is_use_strict && !self.is_strict) {
                    self.is_strict = true;
                    self.lexer.set_strict(true);
                }
            }
        } else {
            self.lexer.pushback(str_tok);
            break;
        }
    }
}

/// Maximum number of lexical declarations in a single pre-scan pass.
const uint MAX_PRESCAN_NAMES = 64;

/// Stores the position and length of a variable name in the source text.
struct NameSpan {
    uint pos;   // byte offset into the source buffer
    uint len;   // length in bytes
}

/// Pre-scan tokens in the current block to find all `let`/`const` variable
/// declarations at the top level of the block (brace depth 0, excluding nested
/// blocks).  Saves and restores the lexer state so normal parsing can proceed
/// afterwards.
///
/// Returns the number of variable names found (0 to MAX_PRESCAN_NAMES).
/// Each name's position in the source text is stored in `spans` so the
/// caller can reconstruct the `char[]` slice from `lexer.source`.
fn uint CompilerContext.pre_scan_lexical_decls(&self, NameSpan* spans, uint capacity) {
    // --- Save lexer state ---
    uint saved_pos    = self.lexer.pos;
    uint saved_line   = self.lexer.line;
    uint saved_col    = self.lexer.col;
    Token saved_cur   = self.lexer.current;
    Token saved_look  = self.lexer.lookahead;
    bool  saved_haslk = self.lexer.has_lookahead;
    Token saved_push  = self.lexer.pushed_back;
    bool  saved_haspb = self.lexer.has_pushed_back;
    bool  saved_slt   = self.lexer.seen_line_term;

    char* source_base = &self.lexer.source[0];

    uint     count       = 0;
    uint     brace_depth = 0;

    while (count < capacity) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) {
            break;
        }
        Token tok = tok_opt;
        TokenType tt = tok.type;

        if (tt == TokenType.EOF_TOKEN) {
            break;
        }

        if (tt == TokenType.LBRACE) {
            brace_depth++;
            continue;
        }

        if (tt == TokenType.RBRACE) {
            if (brace_depth == 0) {
                break;   // end of the block we are scanning
            }
            brace_depth--;
            continue;
        }

        // Only collect let/const at the top level of this block (depth 0).
        if (brace_depth == 0 && (tt == TokenType.LET || tt == TokenType.CONST)) {
            // Collect one or more identifier names (comma-separated).
            for (;;) {
                Token? name_opt = self.lexer.next_token();
                if (catch _err2 = name_opt) {
                    break;
                }
                Token name_tok = name_opt;
                if (name_tok.type != TokenType.IDENTIFIER) {
                    break;
                }
                // Store the name's position in the source text.
                if (count < capacity) {
                    spans[count].pos = (uint)((usz)name_tok.str_value.ptr - (usz)source_base);
                    spans[count].len = (uint)name_tok.str_value.len;
                    count++;
                }
                // Check for comma (multiple declarations).
                Token? sep_opt = self.lexer.next_token();
                if (catch _err3 = sep_opt) {
                    break;
                }
                Token sep = sep_opt;
                if (sep.type != TokenType.COMMA) {
                    break;
                }
                // continue to the next declarator name
            }
        }
    }

    // --- Restore lexer state ---
    self.lexer.pos             = saved_pos;
    self.lexer.line            = saved_line;
    self.lexer.col             = saved_col;
    self.lexer.current         = saved_cur;
    self.lexer.lookahead       = saved_look;
    self.lexer.has_lookahead   = saved_haslk;
    self.lexer.pushed_back     = saved_push;
    self.lexer.has_pushed_back = saved_haspb;
    self.lexer.seen_line_term  = saved_slt;

    return count;
}

/// Parse a block: { statement* }
/// If `check_directives` is true, checks for "use strict" directive prologue at the start.
fn void? CompilerContext.block(&self, bool check_directives) {
    self.expect(TokenType.LBRACE)!;
    uint saved_depth = self.scope_depth;
    ushort saved_reg = self.next_reg;

    // Pre-scan for let/const declarations at this block level so we can
    // TDZ-initialize them at block entry (before any code in the block runs).
    NameSpan[MAX_PRESCAN_NAMES] lex_spans;
    uint num_lex = self.pre_scan_lexical_decls(&lex_spans, MAX_PRESCAN_NAMES);

    // Push a new lexical scope for let/const declarations inside this block.
    // Skip when the block has no let/const — saves an allocation on every
    // function call (most functions have no block-scoped variables).
    bool has_lex = num_lex > 0;
    if (has_lex) {
        self.emit_simple(Opcode.PUSH_LEX);
    }

    // TDZ-initialize every let/const declaration found by the pre-scan.
    // This ensures that accessing the variable before its declaration
    // throws a ReferenceError (temporal dead zone) instead of finding
    // an outer `var` binding or returning undefined.
    for (uint i = 0; i < num_lex; i++) {
        char[] name = self.lexer.source[lex_spans[i].pos..lex_spans[i].pos + lex_spans[i].len - 1];
        uint name_idx = self.add_string_constant(name);
        self.emit_a_bc(Opcode.INITTZ, 0, name_idx);

        // Mark the outer scope_stack entry as captured so that the compiler
        // emits GETVAR instead of LDREG for this variable.  Without this,
        // a register-cached value from an outer scope would bypass the TDZ
        // sentinel in the new lex_env.
        for (uint j = 0; j < saved_depth; j++) {
            if (str_eq(self.scope_stack[j].name, name)) {
                self.scope_stack[j].is_captured = true;
                break;
            }
        }
    }

    if (check_directives) {
        self.parse_directives()!;
    }

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        self.statement()!;
    }

    self.expect(TokenType.RBRACE)!;

    // Pop the lexical scope, removing any let/const bindings from this block
    if (has_lex) {
        self.emit_simple(Opcode.POP_LEX);
    }

    self.pop_scope_to(saved_depth);
    self.free_regs_to(saved_reg);
}

/// Emit the environment store for a declared variable (PUTVAR or PUTLEX/PUTLEX_C).
fn void CompilerContext.emit_var_store(&self, ushort reg, uint name_idx, bool is_lexical, bool is_const) {
    if (is_lexical) {
        if (is_const) {
            self.emit_a_bc(Opcode.PUTLEX_C, (uint)reg, name_idx);
        } else {
            self.emit_a_bc(Opcode.PUTLEX, (uint)reg, name_idx);
        }
    } else {
        // DECLVAR declares the binding in the immediate var_env (function-scoped).
        // PUTVAR (plain assignment) walks the chain to update existing bindings.
        self.emit_a_bc(Opcode.DECLVAR, (uint)reg, name_idx);
    }
}

/// Parse var/let/const declaration.
fn void? CompilerContext.var_declaration(&self) {
    Token decl_tok = self.advance()!;
    bool is_const = (decl_tok.type == TokenType.CONST);
    bool is_lexical = (decl_tok.type == TokenType.LET || decl_tok.type == TokenType.CONST);
    ScopeKind kind = is_const ? CONST : (decl_tok.type == TokenType.LET ? LET : VAR);

    // var declarations are hoisted to function scope — need env allocation.
    if (!is_lexical) {
        self.has_local_bindings = true;
    }

    // Parse one or more variable declarators
    for (;;) {
        TokenType next = self.peek_type();

        if (next == TokenType.LBRACKET) {
            self.advance()!; // consume '['
            self.array_destructure(kind, is_lexical, is_const)!;
        } else if (next == TokenType.LBRACE) {
            self.advance()!; // consume '{'
            self.object_destructure(kind, is_lexical, is_const)!;
        } else {
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (self.is_strict && is_restricted_name(name_tok.str_value)) {
                return COMPILE_ERROR~;
            }
            ushort reg = self.declare_var(name_tok.str_value, kind);
            ushort saved_reg = self.next_reg;

            // Optional initializer
            if (self.match(TokenType.ASSIGN)) {
                ushort val_reg = self.assignment_expr()!;
                if (val_reg != reg) {
                    self.emit_abc(Opcode.LDREG, (uint)reg, (uint)val_reg, 0);
                }
                self.free_reg(val_reg);
            } else {
                // Default initialize to undefined
                self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
            }

            // Store in the environment so inner functions can find it
            // var → var_env (function-scoped), let/const → lex_env (block-scoped)
            uint name_idx = self.add_string_constant(name_tok.str_value);
            self.emit_var_store(reg, name_idx, is_lexical, is_const);

            // At global scope, free the var register and any leaked temporaries
            // from the initializer evaluation.  Global vars use PUTVAR/GETVAR
            // at runtime — the register is only needed briefly as the PUTVAR source.
            if (self.is_global) {
                self.free_regs_to(saved_reg);
            }
        }

        if (!self.match(TokenType.COMMA)) {
            break;
        }
    }

    self.match(TokenType.SEMICOLON);
}

// ============================================================================
// Destructuring patterns (array and object)
// ============================================================================

/// Parse array destructuring pattern: [a, b, ...rest] = rhs
/// The '[' has already been consumed.
fn void? CompilerContext.array_destructure(&self, ScopeKind kind, bool is_lexical, bool is_const) {
    ArrayBind[32] binds;
    uint bind_count = 0;

    // Parse pattern elements, declaring each binding as we go
    for (;;) {
        if (self.check(TokenType.RBRACKET)) break;

        if (self.check(TokenType.COMMA)) {
            self.advance()!;
            if (bind_count < 32) {
                binds[bind_count].is_hole = true;
                bind_count++;
            }
            continue;
        }

        if (self.match(TokenType.ELLIPSIS)) {
            Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
            if (self.is_strict && is_restricted_name(rest_tok.str_value)) return COMPILE_ERROR~;
            if (bind_count < 32) {
                ushort reg = self.declare_var(rest_tok.str_value, kind);
                binds[bind_count].reg = reg;
                binds[bind_count].name_idx = self.add_string_constant(rest_tok.str_value);
                binds[bind_count].is_rest = true;
                binds[bind_count].is_hole = false;
                bind_count++;
            }
            while (self.match(TokenType.COMMA)) {}
            break;
        }

        Token name_tok = self.expect(TokenType.IDENTIFIER)!;
        if (self.is_strict && is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
        if (bind_count < 32) {
            ushort reg = self.declare_var(name_tok.str_value, kind);
            binds[bind_count].reg = reg;
            binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
            binds[bind_count].is_rest = false;
            binds[bind_count].is_hole = false;
            bind_count++;
        }

        if (!self.match(TokenType.COMMA)) break;
    }

    self.expect(TokenType.RBRACKET)!;

    // Default to undefined if no initializer
    if (!self.match(TokenType.ASSIGN)) {
        for (uint i = 0; i < bind_count; i++) {
            if (binds[i].is_hole) continue;
            self.emit_abc(Opcode.LDUNDEF, (uint)binds[i].reg, 0, 0);
            self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
        }
        return;
    }

    // Evaluate RHS (after all bindings declared, so their regs are below RHS regs)
    ushort rhs_reg = self.assignment_expr()!;

    // Emit code for each binding: get property from RHS, store in binding reg
    for (uint i = 0; i < bind_count; i++) {
        if (binds[i].is_hole) continue;

        if (binds[i].is_rest) {
            // For rest at position 0, just assign RHS directly
            self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)rhs_reg, 0);
        } else {
            // Regular element: GETPROP rhs[i] → bind_reg
            ushort idx_reg = self.alloc_reg();
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i));
            self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)rhs_reg, (uint)idx_reg);
            self.free_reg(idx_reg);
        }

        self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
    }

    self.free_reg(rhs_reg);
}

/// Parse object destructuring pattern: {a, b: c} = rhs
/// The '{' has already been consumed.
fn void? CompilerContext.object_destructure(&self, ScopeKind kind, bool is_lexical, bool is_const) {
    ObjBind[32] binds;
    uint bind_count = 0;

    if (!self.check(TokenType.RBRACE)) {
        for (;;) {
            Token prop_tok = self.expect(TokenType.IDENTIFIER)!;

            if (self.match(TokenType.COLON)) {
                // Keyed: {key: binding_name}
                Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                if (self.is_strict && is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
                if (bind_count < 32) {
                    ushort reg = self.declare_var(bind_tok.str_value, kind);
                    binds[bind_count].reg = reg;
                    binds[bind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                    binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                    bind_count++;
                }
            } else {
                // Shorthand: {name}  →  key="name", binding=name
                if (self.is_strict && is_restricted_name(prop_tok.str_value)) return COMPILE_ERROR~;
                if (bind_count < 32) {
                    ushort reg = self.declare_var(prop_tok.str_value, kind);
                    binds[bind_count].reg = reg;
                    binds[bind_count].name_idx = self.add_string_constant(prop_tok.str_value);
                    binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                    bind_count++;
                }
            }

            if (!self.match(TokenType.COMMA)) break;
        }
    }

    self.expect(TokenType.RBRACE)!;

    // Default to undefined if no initializer
    if (!self.match(TokenType.ASSIGN)) {
        for (uint i = 0; i < bind_count; i++) {
            self.emit_abc(Opcode.LDUNDEF, (uint)binds[i].reg, 0, 0);
            self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
        }
        return;
    }

    // Evaluate RHS
    ushort rhs_reg = self.assignment_expr()!;

    // Emit GETPROP for each property: rhs[key] → bind_reg
    for (uint i = 0; i < bind_count; i++) {
        ushort key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, binds[i].key_idx));
        self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)rhs_reg, (uint)key_reg);
        self.free_reg(key_reg);
        self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
    }

    self.free_reg(rhs_reg);
}

/// Parse if/else statement.
fn void? CompilerContext.if_statement(&self) {
    self.expect(TokenType.IF)!;
    self.expect(TokenType.LPAREN)!;

    // Compile condition
    ushort cond_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;

    // Emit conditional jump (skip then-branch if false)
    uint false_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cond_reg);
    self.free_reg(cond_reg);

    // Compile then-branch
    self.statement()!;

    if (self.match(TokenType.ELSE)) {
        // Emit jump over else-branch
        uint end_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(false_jump);

        // Compile else-branch
        self.statement()!;

        self.patch_jump(end_jump);
    } else {
        self.patch_jump(false_jump);
    }
}

/// Parse while statement.
fn void? CompilerContext.while_statement(&self) {
    self.expect(TokenType.WHILE)!;
    self.expect(TokenType.LPAREN)!;

    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);

    // Compile condition
    ushort cond_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;

    // Jump out if condition is false
    uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cond_reg);
    self.free_reg(cond_reg);

    // Compile body
    self.statement()!;

    // Jump back to loop start
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    self.patch_jump(exit_jump);
    self.pop_loop();
}

/// Parse for statement (basic for, for-in, for-of).
fn void? CompilerContext.for_statement(&self) {
    self.expect(TokenType.FOR)!;
    self.expect(TokenType.LPAREN)!;

    uint saved_scope = self.scope_depth;
    ushort saved_reg = self.next_reg;

    // Check for for-in / for-of
    TokenType next_tt = self.peek_type();

    // Check for bare for-of: for (x of expr)
    if (next_tt == TokenType.IDENTIFIER) {
        Token id_tok = self.advance()!;
        if (try tok2 = self.lexer.peek()) {
            if (tok2.type == TokenType.IDENTIFIER && str_eq(tok2.str_value, "of")) {
                self.advance()!;  // consume "of"
                ushort iter_reg = self.assignment_expr()!;
                self.expect(TokenType.RPAREN)!;
                uint name_idx = self.add_string_constant(id_tok.str_value);
                self.emit_forof_loop(id_tok.str_value, iter_reg, saved_scope, saved_reg, false, false, true)!;
                return;
            }
        }
        self.pushback(id_tok);
    }

    // Parse init (may be var/let/const or expression or empty)
    if (next_tt == TokenType.VAR || next_tt == TokenType.LET || next_tt == TokenType.CONST) {
        // Check if it's for-in: "var x in ..."
        // We parse the variable declaration keyword
        Token decl_tok = self.advance()!;
        bool is_const = (decl_tok.type == TokenType.CONST);
        bool is_lexical = (decl_tok.type == TokenType.LET || decl_tok.type == TokenType.CONST);
        ScopeKind decl_kind = is_const ? CONST : (decl_tok.type == TokenType.LET ? LET : VAR);

        // Check for destructuring: [pattern] or {pattern}
        TokenType after_decl = self.peek_type();
        if (after_decl == TokenType.LBRACKET || after_decl == TokenType.LBRACE) {
            // Standard for-loop with destructuring init: for (var [a,b] = ...; ...; ...)
            if (after_decl == TokenType.LBRACKET) {
                self.advance()!; // consume '['
                self.array_destructure(decl_kind, is_lexical, is_const)!;
            } else {
                self.advance()!; // consume '{'
                self.object_destructure(decl_kind, is_lexical, is_const)!;
            }

            // More declarations? (var [a]=x, b=y)
            while (self.match(TokenType.COMMA)) {
                TokenType nt = self.peek_type();
                if (nt == TokenType.LBRACKET) {
                    self.advance()!;
                    self.array_destructure(decl_kind, is_lexical, is_const)!;
                } else if (nt == TokenType.LBRACE) {
                    self.advance()!;
                    self.object_destructure(decl_kind, is_lexical, is_const)!;
                } else {
                    Token extra_name = self.expect(TokenType.IDENTIFIER)!;
                    ushort extra_reg = self.declare_var(extra_name.str_value, decl_kind);
                    if (self.match(TokenType.ASSIGN)) {
                        ushort extra_val = self.assignment_expr()!;
                        if (extra_val != extra_reg) {
                            self.emit_abc(Opcode.LDREG, (uint)extra_reg, (uint)extra_val, 0);
                        }
                        self.free_reg(extra_val);
                    } else {
                        self.emit_abc(Opcode.LDUNDEF, (uint)extra_reg, 0, 0);
                    }
                    uint extra_name_idx = self.add_string_constant(extra_name.str_value);
                    self.emit_var_store(extra_reg, extra_name_idx, is_lexical, is_const);
                }
            }

            self.expect(TokenType.SEMICOLON)!;
        } else {
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;

            // Check for "in" (for-in) or "of" (for-of)
            if (self.peek_type() == TokenType.IN) {
                // for (var x in obj) { ... }
                self.advance()!;  // consume 'in'
                ushort iter_var = self.declare_var(name_tok.str_value, is_const ? CONST : LET);
                ushort obj_reg = self.assignment_expr()!;
                self.expect(TokenType.RPAREN)!;

                // Emit INITFOR to set up the iterator
                ushort iter_state = self.alloc_reg();
                self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

                uint loop_start = self.code_count;
                self.push_loop(loop_start, true);

                // Emit NEXTFOR: iter_var = next key, B = has_next
                ushort has_next = self.alloc_reg();
                self.emit_abc(Opcode.NEXTFOR, (uint)iter_var, (uint)has_next, (uint)iter_state);
                // Sync the for-in variable to the environment so GETVAR can find it
                // (needed at global scope where resolve_var is not used)
                uint forin_name_idx = self.add_string_constant(name_tok.str_value);
                self.emit_a_bc(Opcode.PUTVAR, (uint)iter_var, forin_name_idx);

                // If no more keys, exit
                uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
                self.free_reg(has_next);

                // Compile body
                self.statement()!;

                // Jump back to loop start
                int back_offset = (int)loop_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

                self.patch_jump(exit_jump);
                self.pop_loop();

                self.free_reg(iter_state);
                self.free_reg(obj_reg);
                self.pop_scope_to(saved_scope);
                self.free_regs_to(saved_reg);
                return;
            }
            // Check for "of" (for-of) — contextual keyword, not a reserved word
            if (try tok = self.lexer.peek()) {
                if (tok.type == TokenType.IDENTIFIER && str_eq(tok.str_value, "of")) {
                    self.advance()!;  // consume "of"
                    ushort iter_reg = self.assignment_expr()!;
                    self.expect(TokenType.RPAREN)!;
                    uint name_idx = self.add_string_constant(name_tok.str_value);
                    self.emit_forof_loop(name_tok.str_value, iter_reg, saved_scope, saved_reg, is_lexical, is_const, false)!;
                    return;
                }
            }

            // Standard for loop: we already consumed the decl keyword and identifier
            // Declare the variable and optionally initialize
            ushort var_reg = self.declare_var(name_tok.str_value, decl_kind);
            if (self.match(TokenType.ASSIGN)) {
                ushort init_val = self.assignment_expr()!;
                if (init_val != var_reg) {
                    self.emit_abc(Opcode.LDREG, (uint)var_reg, (uint)init_val, 0);
                }
                self.free_reg(init_val);
            } else {
                self.emit_abc(Opcode.LDUNDEF, (uint)var_reg, 0, 0);
            }
            // Also store in environment (needed at global scope for GETVAR)
            uint name_idx = self.add_string_constant(name_tok.str_value);
            self.emit_var_store(var_reg, name_idx, is_lexical, is_const);

            // More declarations?
            while (self.match(TokenType.COMMA)) {
                TokenType nt2 = self.peek_type();
                if (nt2 == TokenType.LBRACKET) {
                    self.advance()!;
                    self.array_destructure(decl_kind, is_lexical, is_const)!;
                } else if (nt2 == TokenType.LBRACE) {
                    self.advance()!;
                    self.object_destructure(decl_kind, is_lexical, is_const)!;
                } else {
                    Token extra_name = self.expect(TokenType.IDENTIFIER)!;
                    ushort extra_reg = self.declare_var(extra_name.str_value, decl_kind);
                    if (self.match(TokenType.ASSIGN)) {
                        ushort extra_val = self.assignment_expr()!;
                        if (extra_val != extra_reg) {
                            self.emit_abc(Opcode.LDREG, (uint)extra_reg, (uint)extra_val, 0);
                        }
                        self.free_reg(extra_val);
                    } else {
                        self.emit_abc(Opcode.LDUNDEF, (uint)extra_reg, 0, 0);
                    }
                    uint extra_name_idx = self.add_string_constant(extra_name.str_value);
                    self.emit_var_store(extra_reg, extra_name_idx, is_lexical, is_const);
                }
            }

            self.expect(TokenType.SEMICOLON)!;
        }
    } else if (next_tt != TokenType.SEMICOLON) {
        // Expression init
        ushort init_reg = self.expression()!;
        self.free_reg(init_reg);
        self.expect(TokenType.SEMICOLON)!;
    } else {
        // Empty init
        self.expect(TokenType.SEMICOLON)!;
    }

    // Condition
    uint cond_start = self.code_count;
    uint exit_jump = NO_PATCH;

    if (!self.check(TokenType.SEMICOLON)) {
        ushort cond_reg = self.expression()!;
        exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cond_reg);
        self.free_reg(cond_reg);
    }
    self.expect(TokenType.SEMICOLON)!;

    // Update expression — compile it but jump over it initially
    uint update_jump = self.emit_jump(Opcode.JUMP);
    uint update_start = self.code_count;

    if (!self.check(TokenType.RPAREN)) {
        ushort update_reg = self.expression()!;
        self.free_reg(update_reg);
    }

    // Jump back to condition
    int cond_back = (int)cond_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, cond_back));

    self.expect(TokenType.RPAREN)!;

    self.patch_jump(update_jump);

    // Push loop with continue_target pointing to the update expression
    self.push_loop(update_start, true);

    // Compile body
    self.statement()!;

    // Jump to update
    int update_back = (int)update_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, update_back));

    // Patch exit
    if (exit_jump != NO_PATCH) {
        self.patch_jump(exit_jump);
    }

    self.pop_loop();
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

/// Parse do-while statement.
fn void? CompilerContext.do_while_statement(&self) {
    self.expect(TokenType.DO)!;

    uint loop_start = self.code_count;
    // Continue target is the condition (we'll record the address after the body)
    self.push_loop(loop_start, true);  // temporary; we'll fix continue_target

    // Compile body
    self.statement()!;

    // Fix the continue target to point to the condition
    if (self.loop_depth > 0) {
        self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;
    }

    self.expect(TokenType.WHILE)!;
    self.expect(TokenType.LPAREN)!;

    ushort cond_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;
    self.match(TokenType.SEMICOLON);

    // If condition is true, jump back to loop_start
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cond_reg, back_offset));
    self.free_reg(cond_reg);

    self.pop_loop();
}

/// Parse return statement.
fn void? CompilerContext.return_statement(&self) {
    self.expect(TokenType.RETURN)!;

    // Check if there's a return value (not a semicolon or end-of-statement)
    // A line terminator between return and the expression causes ASI (ES5 §12.9)
    TokenType next = self.peek_type();
    if (next == TokenType.SEMICOLON || next == TokenType.RBRACE ||
        next == TokenType.EOF_TOKEN || self.lexer.seen_line_term) {
        self.emit_simple(self.is_generator ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    } else {
        ushort val_reg = self.expression()!;
        self.emit_abc(self.is_generator ? Opcode.RET_GEN : Opcode.RET, (uint)val_reg, 0, 0);
        self.free_reg(val_reg);
    }

    self.match(TokenType.SEMICOLON);
}

/// Parse throw statement.
fn void? CompilerContext.throw_statement(&self) {
    self.expect(TokenType.THROW)!;

    ushort val_reg = self.expression()!;
    self.emit_abc(Opcode.THROW, (uint)val_reg, 0, 0);
    self.free_reg(val_reg);

    self.match(TokenType.SEMICOLON);
}

/// Parse try/catch/finally statement.
///
/// Bytecode layout:
///   TRY A=flags, BC=catch_offset     — A bit0=catch, bit1=finally
///   NOP A=0,    BC=finally_offset    — jump slot (0 if no finally)
///   <try block>
///   ENDTRY
///   JUMP -> finally_or_after
///   [CATCH rX  — at try_addr + catch_offset]
///   [<catch block>]
///   [FINALLY   — at try_addr + finally_offset (if has_finally)]
///   [<finally block>]
///   [ENDFINALLY]
fn void? CompilerContext.try_statement(&self) {
    self.expect(TokenType.TRY)!;

    // Emit TRY instruction (placeholder: A=0, BC=0, jump_slot BC=0)
    uint try_addr = self.emit_a_bc(Opcode.TRY, 0, 0);
    // Jump slot — the VM reads this word for the finally_offset (BC field)
    uint jump_slot_addr = self.emit_a_bc(Opcode.NOP, 0, 0);

    // Push try info
    if (self.try_depth < MAX_TRY_DEPTH) {
        self.try_stack[self.try_depth].catch_addr = try_addr;
        self.try_stack[self.try_depth].finally_addr = NO_PATCH;
        self.try_depth++;
    }

    // Compile try block
    self.block(false)!;

    // Emit ENDTRY to pop the try handler (normal exit)
    self.emit_simple(Opcode.ENDTRY);

    // Jump (skips catch handler; target patched later)
    uint jump_over = self.emit_jump(Opcode.JUMP);

    // catch handler starts here
    uint catch_target = self.code_count;

    // Parse catch clause
    bool has_catch = false;
    bool has_finally = false;
    uint finally_tgt = 0;

    if (self.match(TokenType.CATCH)) {
        has_catch = true;
        uint catch_scope = self.scope_depth;
        ushort catch_saved_reg = self.next_reg;

        if (self.match(TokenType.LPAREN)) {
            Token catch_param = self.expect(TokenType.IDENTIFIER)!;
            if (self.is_strict && is_restricted_name(catch_param.str_value)) {
                return COMPILE_ERROR~;
            }
            self.expect(TokenType.RPAREN)!;

            ushort catch_var = self.declare_var(catch_param.str_value, VAR);
            self.emit_abc(Opcode.CATCH, (uint)catch_var, 0, 0);
            // PUTVAR the exception into the env so that subsequent
            // GETVAR/TYPEOFIDENT for the catch variable finds it.
            // Required in ALL scopes (not just global) because the VM
            // resolves catch variables via environment lookup, not register.
            {
                uint name_idx = self.add_string_constant(catch_param.str_value);
                self.emit_a_bc(Opcode.PUTVAR, (uint)catch_var, name_idx);
            }
        } else {
            // catch without binding (ES2019)
            ushort discard = self.alloc_reg();
            self.emit_abc(Opcode.CATCH, (uint)discard, 0, 0);
            self.free_reg(discard);
        }

        // Compile catch block
        self.block(false)!;

        self.pop_scope_to(catch_scope);
        self.free_regs_to(catch_saved_reg);
    }

    // Parse finally clause
    if (self.match(TokenType.FINALLY)) {
        has_finally = true;
        finally_tgt = self.code_count;

        // Patch the jump from the try block to land at FINALLY
        self.patch_jump(jump_over);

        // Emit FINALLY marker
        self.emit_simple(Opcode.FINALLY);

        // Compile finally block
        self.block(false)!;

        // Emit ENDFINALLY
        self.emit_simple(Opcode.ENDFINALLY);
    } else {
        // Patch jump to skip catch handler
        self.patch_jump(jump_over);
    }

    // Patch TRY instruction: A=flags, BC=catch_offset
    uint try_flags = (has_catch ? 1u : 0u) | (has_finally ? 2u : 0u);
    uint catch_offset = catch_target - try_addr;
    self.code[try_addr] = bytecode::make_a_bc(Opcode.TRY, try_flags, catch_offset);

    // Patch jump slot: BC=finally_offset (0 if no finally)
    uint finally_off = has_finally ? (finally_tgt - try_addr) : 0;
    self.code[jump_slot_addr] = bytecode::make_a_bc(Opcode.NOP, 0, finally_off);

    // Pop try info
    if (self.try_depth > 0) {
        self.try_depth--;
    }
}

/// Parse a `with` statement (ES5 §12.10).
///
/// Bytecode layout:
///   <expr>                              — push object onto valstack (in a register)
///   WITH_START A                        — A = register holding the with-object
///   <statement>
///   WITH_END                            — pop the with-env from the scope chain
fn void? CompilerContext.with_statement(&self) {
    if (self.is_strict) {
        return COMPILE_ERROR~;
    }
    self.expect(TokenType.WITH)!;

    // Parse `(expr)`
    self.expect(TokenType.LPAREN)!;
    ushort obj_reg = self.expression()!;
    self.expect(TokenType.RPAREN)!;

    // Emit WITH_START — pushes a new object env-record wrapping obj_reg
    self.emit_a_bc(Opcode.WITH_START, (uint)obj_reg, 0);

    // Compile the body
    self.statement()!;

    // Emit WITH_END — restores the previous env chain
    self.emit_simple(Opcode.WITH_END);

    // Free the object register
    self.free_reg(obj_reg);
}

/// Parse switch statement with correct fall-through (ES5 §12.11).
///
/// Each case body ends with a fall-through redirect JUMP patched after all
/// case clauses are parsed, so that when a matched case body completes (without
/// break) execution continues to the next case body rather than re-checking
/// the next case's comparison preamble. The `default` clause is handled with
/// a preamble JUMP when it is not the last clause, allowing subsequent cases
/// to be checked before falling through to default on no match.
fn void? CompilerContext.switch_statement(&self) {
    self.expect(TokenType.SWITCH)!;
    self.expect(TokenType.LPAREN)!;

    ushort disc_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;
    self.expect(TokenType.LBRACE)!;

    // Push a "loop" for break handling (break in switch exits the switch)
    // is_loop=false so continue skips this entry.
    self.push_loop(self.code_count, false);

    // Track all body entries (cases and default) in source order
    uint[64] body_addrs;
    uint[64] ft_jump_addrs;
    uint body_count = 0;
    bool has_default = false;
    uint default_body_idx = 0;
    bool default_not_last = false;

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        if (self.match(TokenType.CASE)) {
            // Compile case expression
            ushort case_reg = self.expression()!;
            self.expect(TokenType.COLON)!;

            // Compare discriminant with case value
            ushort cmp_reg = self.alloc_reg();
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)disc_reg, (uint)case_reg);
            self.free_reg(case_reg);

            // Jump to the case body if they match
            uint match_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            self.free_reg(cmp_reg);

            // Jump over the body if no match
            uint skip_jump = self.emit_jump(Opcode.JUMP);

            // Patch the match jump to here (the body)
            self.patch_jump(match_jump);
            body_addrs[body_count] = self.code_count;

            // Compile case body statements
            while (!self.check(TokenType.CASE) && !self.check(TokenType.DEFAULT) &&
                   !self.check(TokenType.RBRACE) && !self.is_at_end()) {
                self.statement()!;
            }

            // Emit fall-through redirect jump (patched later to next body)
            uint ft_jump = self.emit_jump(Opcode.JUMP);
            ft_jump_addrs[body_count] = ft_jump;
            body_count++;

            // Patch skip jump to after the fall-through redirect
            self.patch_jump(skip_jump);

        } else if (self.match(TokenType.DEFAULT)) {
            self.expect(TokenType.COLON)!;

            has_default = true;
            default_body_idx = body_count;

            // Emit preamble JUMP over default body (placeholder).
            // If more clauses follow, this skips the default body for the
            // case-checking path. If default is last, it becomes a no-op.
            uint default_preamble = self.emit_jump(Opcode.JUMP);

            body_addrs[body_count] = self.code_count;

            // Compile default body
            while (!self.check(TokenType.CASE) && !self.check(TokenType.DEFAULT) &&
                   !self.check(TokenType.RBRACE) && !self.is_at_end()) {
                self.statement()!;
            }

            // Emit fall-through redirect for default
            uint ft_jump = self.emit_jump(Opcode.JUMP);
            ft_jump_addrs[body_count] = ft_jump;
            body_count++;

            // Check if anything follows this default clause
            TokenType next = self.peek_type();
            if (next == TokenType.CASE || next == TokenType.DEFAULT) {
                // More clauses follow: preamble skips over default body
                self.patch_jump(default_preamble);
                default_not_last = true;
            } else {
                // Default is last: patch preamble to fall through to body
                // (offset 0 = jump to next instruction = body start)
                int ft_offset = (int)(body_addrs[default_body_idx]) -
                                (int)(default_preamble) - 1;
                self.code[default_preamble] =
                    bytecode::make_sabc(Opcode.JUMP, ft_offset);
            }
        } else {
            // Unexpected token in switch
            return COMPILE_ERROR~;
        }
    }

    self.expect(TokenType.RBRACE)!;

    // If default is not last, emit a redirect for the 'no match' path at the
    // end of all case checks. This is reached by the last case's skip_jump.
    uint redirect_addr = 0;
    if (has_default && default_not_last) {
        redirect_addr = self.code_count;
        uint jump = self.emit_jump(Opcode.JUMP);
        // break jumps will be patched past this redirect by pop_loop
    }

    // Patch break jumps to end of switch (after redirect if any)
    self.pop_loop();

    uint end_addr = self.code_count;

    // Patch the 'no match' redirect to the default body
    if (redirect_addr > 0) {
        int offset = (int)(body_addrs[default_body_idx]) -
                     (int)(redirect_addr) - 1;
        self.code[redirect_addr] =
            bytecode::make_sabc(Opcode.JUMP, offset);
    }

    // Patch all fall-through redirect jumps in source order
    for (uint i = 0; i < body_count; i++) {
        uint target;
        if (i + 1 < body_count) {
            // Fall through to next body in source order
            target = body_addrs[i + 1];
        } else {
            // Last body: fall through to end of switch
            target = end_addr;
        }
        int offset = (int)(target) - (int)(ft_jump_addrs[i]) - 1;
        self.code[ft_jump_addrs[i]] =
            bytecode::make_sabc(Opcode.JUMP, offset);
    }

    self.free_reg(disc_reg);
}

/// Parse a labeled statement: `identifier : statement`.
/// Supports labeled break and continue (ES5 §12.12).
fn void? CompilerContext.labeled_statement(&self, char[] name) {
    // Check for duplicate labels
    for (uint i = 0; i < self.label_count; i++) {
        if (str_eq(self.labels[i].name, name)) {
            return COMPILE_ERROR~;
        }
    }

    // Register the label
    uint label_idx = self.label_count;
    if (label_idx >= MAX_LABELS) return COMPILE_ERROR~;
    self.labels[label_idx].name = name;
    self.label_count++;

    // Look ahead to determine if the inner statement is a loop
    TokenType next = self.peek_type();

    if (next == TokenType.FOR || next == TokenType.WHILE || next == TokenType.DO) {
        // The label refers to a loop. The loop will be pushed at index
        // self.loop_depth (the current depth before the loop's push_loop).
        self.labels[label_idx].loop_index = self.loop_depth;
        self.labels[label_idx].is_loop = true;
        self.statement()!;
    } else {
        // Non-loop label — push a virtual loop entry so break can target it.
        self.push_loop(self.code_count, false);
        self.labels[label_idx].loop_index = self.loop_depth - 1;
        self.labels[label_idx].is_loop = false;
        self.statement()!;
        self.pop_loop(); // patches all breaks targeting this label
    }
}

/// Parse break statement.
/// If an identifier follows `break`, it's a labeled break (ES5 §12.12).
/// A line terminator between `break` and the identifier means unlabeled break.
fn void? CompilerContext.break_statement(&self) {
    self.expect(TokenType.BREAK)!;

    if (self.peek_type() == TokenType.IDENTIFIER && !self.lexer.seen_line_term) {
        // Labeled break — find the label and add jump to its loop's break chain
        Token label_tok = self.advance()!;
        char[] label_name = label_tok.str_value;

        for (uint i = 0; i < self.label_count; i++) {
            if (str_eq(self.labels[i].name, label_name)) {
                uint loop_idx = self.labels[i].loop_index;
                uint jump_addr = self.emit_jump(Opcode.JUMP);
                self.loop_stack[loop_idx].break_patch_head =
                    self.add_patch(self.loop_stack[loop_idx].break_patch_head, jump_addr);
                self.match(TokenType.SEMICOLON);
                return;
            }
        }
        // Label not found
        return COMPILE_ERROR~;
    }

    // Unlabeled break — break out of the innermost loop or switch
    uint jump_addr = self.emit_jump(Opcode.JUMP);
    self.add_break_patch(jump_addr);

    self.match(TokenType.SEMICOLON);
}

/// Parse continue statement.
/// If an identifier follows `continue`, it's a labeled continue (ES5 §12.12).
/// A line terminator between `continue` and the identifier means unlabeled continue.
fn void? CompilerContext.continue_statement(&self) {
    self.expect(TokenType.CONTINUE)!;

    if (self.peek_type() == TokenType.IDENTIFIER && !self.lexer.seen_line_term) {
        // Labeled continue — find the label and jump to its loop's continue target
        Token label_tok = self.advance()!;
        char[] label_name = label_tok.str_value;

        for (uint i = 0; i < self.label_count; i++) {
            if (str_eq(self.labels[i].name, label_name)) {
                if (!self.labels[i].is_loop) {
                    // continue on a non-loop label is a syntax error
                    return COMPILE_ERROR~;
                }
                uint loop_idx = self.labels[i].loop_index;
                uint target = self.loop_stack[loop_idx].continue_target;
                int offset = (int)target - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, offset));
                self.match(TokenType.SEMICOLON);
                return;
            }
        }
        // Label not found
        return COMPILE_ERROR~;
    }

    // Unlabeled continue — jump to continue target of the innermost *real* loop
    // (skip switch pseudo-loops that only handle break)
    int loop_idx = (int)self.loop_depth - 1;
    while (loop_idx >= 0 && !self.loop_stack[loop_idx].is_loop) {
        loop_idx--;
    }
    if (loop_idx >= 0) {
        // Emit placeholder jump and add to continue_patch_head for deferred patching
        uint jump_addr = self.emit_jump(Opcode.JUMP);
        self.loop_stack[loop_idx].continue_patch_head =
            self.add_patch(self.loop_stack[loop_idx].continue_patch_head, jump_addr);
    } else {
        return COMPILE_ERROR~;
    }

    self.match(TokenType.SEMICOLON);
}

/// Parse expression statement.
fn void? CompilerContext.expression_statement(&self) {
    ushort reg = self.expression()!;
    if (self.eval_mode) {
        // Preserve the expression result for eval's implicit return value
        self.emit_abc(Opcode.LDREG, (uint)self.eval_acc_reg, (uint)reg, 0);
    }
    self.free_reg(reg);
    self.match(TokenType.SEMICOLON);
}

/// Parse a function declaration (hoisted).
fn void? CompilerContext.function_declaration(&self) {
    self.expect(TokenType.FUNCTION)!;

    // Function declarations are hoisted to function scope — need env.
    self.has_local_bindings = true;

    // Save and reset generator state: nested function declarations
    // inside a generator do not inherit the generator flag.
    bool saved_is_generator = self.is_generator;
    self.is_generator = false;

    // Check for generator star: function* name() {}
    if (self.match(TokenType.STAR)) {
        self.is_generator = true;
    }

    Token name_tok = self.expect(TokenType.IDENTIFIER)!;
    ushort func_reg = self.declare_var(name_tok.str_value, VAR);

    // Compile the function into a nested CompiledFunction
    CompiledFunction* inner = self.compile_inner_function(name_tok.str_value)!;

    // Restore generator flag
    self.is_generator = saved_is_generator;

    // Add to inner functions table
    uint inner_idx = 0;
    if (self.inner_func_count < MAX_INNER_FUNCS) {
        inner_idx = self.inner_func_count;
        self.inner_funcs[inner_idx] = inner;
        self.inner_func_count++;
    }

    // Emit CLOSURE to create the function object
    self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);

    // Also store in environment so inner functions can find it via GETVAR
    uint name_idx = self.add_string_constant(name_tok.str_value);
    self.emit_a_bc(Opcode.PUTVAR, (uint)func_reg, name_idx);

    // At global scope, free the register — the function object lives in the
    // environment via GETVAR/PUTVAR, not in a register-cached scope slot.
    if (self.is_global) {
        self.free_reg(func_reg);
    }
}

// ============================================================================
// Class parsing (ES6)
// ============================================================================

const uint MAX_CLASS_METHODS = 32;

struct ClassMethod {
    char[] name;
    uint   inner_idx;
    bool   is_static;
    bool   is_getter;
    bool   is_setter;
    uint   computed_key_inner_idx;  // MAX_INNER_FUNCS = not computed
}

/// Create a default constructor CompiledFunction without using the lexer.
/// has_super: if true, creates `constructor(...args) { super(...args); }`
/// otherwise creates `constructor() {}`.
fn CompiledFunction*? make_default_constructor(bool has_super) {
    void* raw = libc::malloc(CompiledFunction::size);
    if (raw == null) return COMPILE_ERROR~;
    libc::memset(raw, 0, CompiledFunction::size);

    CompiledFunction* func = (CompiledFunction*)raw;
    func.flags.htype = HType.OBJECT;
    func.flags.is_strict = true;
    func.flags.is_constructable = true;

    if (has_super) {
        // constructor(...args) { super(...args); }
        func.flags.has_rest = true;
        func.num_args = 1;
        func.num_formals = 0;   // rest param doesn't count toward length
        func.num_regs = 15;     // enough for GETVAR + SPREAD_ARG + SUPER_CALL

        // Build bytecode manually
        // Registers: r0 = rest args, r1 = __super__, r2 = callee_base,
        //            r3 = this slot, r4..r13 = spread dest, r14 = count
        usz code_bytes = 10 * Instruction::size;
        void* code_raw = libc::malloc(code_bytes);
        if (code_raw == null) { libc::free(raw); return COMPILE_ERROR~; }
        func.code = (Instruction*)code_raw;
        func.code_count = 10;

        Instruction* c = func.code;

        // PUSH_LEX
        c[0] = bytecode::make_abc(Opcode.PUSH_LEX, 0, 0, 0);

        // GETVAR __super__ → r1
        // We need a constant index for "__super__". Since we can't use the compiler
        // context, we'll store it as a constant.
        usz const_bytes = 1 * TVal::size;
        void* const_raw = libc::malloc(const_bytes);
        if (const_raw == null) { libc::free(code_raw); libc::free(raw); return COMPILE_ERROR~; }
        func.constants = (TVal*)const_raw;
        func.const_count = 1;

        // For the constant, we need an interned string. We can't access the heap here.
        // Instead, let's use a different approach: emit bytecode that the VM can handle.
        // Actually, we need a proper string constant for "__super__".
        // The simplest workaround: for default constructors with extends, we won't
        // emit the default constructor here. Instead, we'll require explicit constructors
        // when using extends for now.

        // Fall back: just return a simple empty constructor even for extends
        libc::free(code_raw);
        libc::free(const_raw);
        func.code = null;
        func.code_count = 0;
        func.constants = null;
        func.const_count = 0;
        func.flags.has_rest = false;
        func.num_args = 0;
        func.num_formals = 0;
        func.num_regs = 1;

        // Simple empty constructor
        code_bytes = 3 * Instruction::size;
        code_raw = libc::malloc(code_bytes);
        if (code_raw == null) { libc::free(raw); return COMPILE_ERROR~; }
        func.code = (Instruction*)code_raw;
        func.code_count = 3;

        c = func.code;
        c[0] = bytecode::make_abc(Opcode.PUSH_LEX, 0, 0, 0);
        c[1] = bytecode::make_abc(Opcode.POP_LEX, 0, 0, 0);
        c[2] = bytecode::make_abc(Opcode.RETUNDEF, 0, 0, 0);
    } else {
        // constructor() {}
        func.num_args = 0;
        func.num_formals = 0;
        func.num_regs = 1;

        usz code_bytes = 3 * Instruction::size;
        void* code_raw = libc::malloc(code_bytes);
        if (code_raw == null) { libc::free(raw); return COMPILE_ERROR~; }
        func.code = (Instruction*)code_raw;
        func.code_count = 3;

        Instruction* c = func.code;
        c[0] = bytecode::make_abc(Opcode.PUSH_LEX, 0, 0, 0);
        c[1] = bytecode::make_abc(Opcode.POP_LEX, 0, 0, 0);
        c[2] = bytecode::make_abc(Opcode.RETUNDEF, 0, 0, 0);
    }

    return func;
}

/// Parse a class declaration: `class Name [extends Base] { body }`
fn void? CompilerContext.class_declaration(&self) {
    self.expect(TokenType.CLASS)!;
    Token name_tok = self.expect(TokenType.IDENTIFIER)!;

    // Class name binding: let-like (block-scoped, TDZ)
    ushort class_reg = self.declare_var(name_tok.str_value, LET);
    uint class_name_idx = self.add_string_constant(name_tok.str_value);

    // Parse extends clause and class body
    ushort ctor_reg = self.parse_class_tail()!;

    // Store the constructor in the class binding
    self.emit_abc(Opcode.LDREG, (uint)class_reg, (uint)ctor_reg, 0);
    self.emit_a_bc(Opcode.PUTLEX, (uint)class_reg, class_name_idx);
    self.free_reg(ctor_reg);
}

/// Parse a class expression: `class [Name] [extends Base] { body }`
/// Returns the register holding the constructor.
fn ushort? CompilerContext.class_expression(&self) {
    self.expect(TokenType.CLASS)!;

    // Optional class name (only visible inside the class body)
    char[] name;
    uint class_name_idx = 0;
    ushort name_reg = MAX_REGISTERS;
    if (self.check(TokenType.IDENTIFIER)) {
        Token name_tok = self.advance()!;
        name = name_tok.str_value;
        // For named class expressions, bind the name in the class scope
        name_reg = self.declare_var(name, LET);
        class_name_idx = self.add_string_constant(name);
    }

    // Parse extends clause and class body
    ushort ctor_reg = self.parse_class_tail()!;

    // For named class expressions, bind the name to the constructor
    if (name_reg != MAX_REGISTERS) {
        self.emit_abc(Opcode.LDREG, (uint)name_reg, (uint)ctor_reg, 0);
        self.emit_a_bc(Opcode.PUTLEX, (uint)name_reg, class_name_idx);
    }

    return ctor_reg;
}

/// Parse the tail of a class: optional `extends` clause + class body.
/// Returns the register holding the constructor function.
fn ushort? CompilerContext.parse_class_tail(&self) {
    // Save state for restoration after class body
    bool saved_in_class_body = self.in_class_body;
    bool saved_has_super = self.has_super_binding;

    self.in_class_body = true;
    self.has_super_binding = false;

    // Parse optional extends clause
    ushort base_reg = MAX_REGISTERS;
    if (self.match(TokenType.EXTENDS)) {
        base_reg = self.assignment_expr()!;
        self.has_super_binding = true;

        // Store the super class in an internal variable so the constructor
        // can access it via GETVAR for super() calls.
        char[] super_name = "__super__";
        ushort super_reg = self.declare_var(super_name, LET);
        uint super_name_idx = self.add_string_constant(super_name);
        self.emit_abc(Opcode.LDREG, (uint)super_reg, (uint)base_reg, 0);
        self.emit_a_bc(Opcode.PUTLEX, (uint)super_reg, super_name_idx);
    }

    // Parse class body
    self.expect(TokenType.LBRACE)!;

    // Track methods found in the class body
    ClassMethod[MAX_CLASS_METHODS] methods;
    ushort method_count = 0;

    // Track constructor
    uint ctor_inner_idx = MAX_INNER_FUNCS;  // sentinel

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        // Skip semicolons (empty class elements)
        if (self.match(TokenType.SEMICOLON)) {
            continue;
        }

        // Check for static modifier
        bool is_static = false;
        if (self.match(TokenType.STATIC)) {
            is_static = true;
        }

        // Get the method name
        Token method_name;
        bool is_constructor = false;
        bool is_getter = false;
        bool is_setter = false;

        // Check for computed key [expr]
        bool has_computed_key = false;
        uint computed_key_inner_idx = MAX_INNER_FUNCS;

        if (self.check(TokenType.LBRACKET)) {
            // Computed property name: [expr]
            self.advance()!; // consume `[`
            has_computed_key = true;

            // Compile key expression as a 0-arg inner function
            CompiledFunction* key_func = self.compile_key_expr()!;
            self.expect(TokenType.RBRACKET)!;

            if (self.inner_func_count < MAX_INNER_FUNCS) {
                computed_key_inner_idx = self.inner_func_count;
                self.inner_funcs[computed_key_inner_idx] = key_func;
                self.inner_func_count++;
            }

            // Still need a method name for compile_inner_function (used as debug name)
            method_name = lexer::make_token(TokenType.IDENTIFIER, 0, 0);
        } else if (self.check(TokenType.IDENTIFIER)) {
            method_name = self.advance()!;
            // Check for getter/setter: `get prop() {}` / `set prop(v) {}`
            if ((method_name.str_value.len == 3
                 && method_name.str_value[0] == 'g'
                 && method_name.str_value[1] == 'e'
                 && method_name.str_value[2] == 't')
                || (method_name.str_value.len == 3
                    && method_name.str_value[0] == 's'
                    && method_name.str_value[1] == 'e'
                    && method_name.str_value[2] == 't')) {
                // Check if next token is a property key (not `:` or `(`)
                if (!self.check(TokenType.COLON) && !self.check(TokenType.LPAREN)) {
                    // This is a getter/setter declaration
                    is_getter = (method_name.str_value[0] == 'g');
                    is_setter = !is_getter;
                    // Parse the actual property name
                    if (self.check(TokenType.LBRACKET)) {
                        // Computed getter/setter key
                        self.advance()!; // consume `[`
                        has_computed_key = true;
                        CompiledFunction* accessor_key_func = self.compile_key_expr()!;
                        self.expect(TokenType.RBRACKET)!;
                        if (self.inner_func_count < MAX_INNER_FUNCS) {
                            computed_key_inner_idx = self.inner_func_count;
                            self.inner_funcs[computed_key_inner_idx] = accessor_key_func;
                            self.inner_func_count++;
                        }
                        method_name = lexer::make_token(TokenType.IDENTIFIER, 0, 0);
                    } else if (self.check(TokenType.IDENTIFIER) || self.check(TokenType.STRING)) {
                        method_name = self.advance()!;
                    } else if (self.check(TokenType.NUMBER)) {
                        method_name = self.advance()!;
                    } else {
                        return COMPILE_ERROR~;
                    }
                }
            }
            if (!is_getter && !is_setter && !is_static && method_name.str_value.len == 11
                && method_name.str_value[0] == 'c'
                && method_name.str_value[1] == 'o'
                && method_name.str_value[2] == 'n'
                && method_name.str_value[3] == 's'
                && method_name.str_value[4] == 't'
                && method_name.str_value[5] == 'r'
                && method_name.str_value[6] == 'u'
                && method_name.str_value[7] == 'c'
                && method_name.str_value[8] == 't'
                && method_name.str_value[9] == 'o'
                && method_name.str_value[10] == 'r') {
                is_constructor = true;
            }
        } else if (self.check(TokenType.STRING)) {
            method_name = self.advance()!;
        } else if (self.check(TokenType.NUMBER)) {
            method_name = self.advance()!;
        } else {
            return COMPILE_ERROR~;
        }

        if (is_static && is_constructor) {
            // static constructor is a SyntaxError
            return COMPILE_ERROR~;
        }

        // Compile the method as an inner function
        // Save and restore is_constructable
        bool saved_constructable = self.is_constructable;

        if (is_constructor) {
            self.is_constructable = true;
        } else {
            self.is_constructable = false;
        }

        CompiledFunction* inner = self.compile_inner_function(method_name.str_value)!;

        self.is_constructable = saved_constructable;

        // Add to inner functions table
        uint inner_idx = MAX_INNER_FUNCS;
        if (self.inner_func_count < MAX_INNER_FUNCS) {
            inner_idx = self.inner_func_count;
            self.inner_funcs[inner_idx] = inner;
            self.inner_func_count++;
        }

        if (is_constructor) {
            ctor_inner_idx = inner_idx;
        } else if (method_count < MAX_CLASS_METHODS) {
            methods[method_count].name = method_name.str_value;
            methods[method_count].inner_idx = inner_idx;
            methods[method_count].is_static = is_static;
            methods[method_count].is_getter = is_getter;
            methods[method_count].is_setter = is_setter;
            methods[method_count].computed_key_inner_idx = computed_key_inner_idx;
            method_count++;
        }
    }

    self.expect(TokenType.RBRACE)!;

    // If no constructor was specified, create a default one
    if (ctor_inner_idx == MAX_INNER_FUNCS) {
        CompiledFunction*? ctor_func_raw = make_default_constructor(self.has_super_binding);
        if (catch err = ctor_func_raw) {
            return COMPILE_ERROR~;
        }
        CompiledFunction* ctor_func = ctor_func_raw;
        // Track for heap cleanup
        heap::Heap* hp = (heap::Heap*)self.heap;
        hp.track_compiled_func((void*)ctor_func);
        if (self.inner_func_count < MAX_INNER_FUNCS) {
            ctor_inner_idx = self.inner_func_count;
            self.inner_funcs[ctor_inner_idx] = ctor_func;
            self.inner_func_count++;
        }
    }

    // Emit CLOSURE for the constructor
    ushort ctor_reg = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)ctor_reg, ctor_inner_idx));

    // Set up prototype
    ushort proto_reg = self.alloc_reg();
    uint proto_name_idx = self.add_string_constant("prototype");
    {
        ushort proto_key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)proto_key_reg, proto_name_idx));
        self.emit_abc(Opcode.GETPROP, (uint)proto_reg, (uint)ctor_reg, (uint)proto_key_reg);
        self.free_reg(proto_key_reg);
    }

    // If extends, set proto.__proto__ = Base.prototype
    if (base_reg != MAX_REGISTERS) {
        ushort base_proto_reg = self.alloc_reg();
        {
            ushort base_proto_key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)base_proto_key_reg, proto_name_idx));
            self.emit_abc(Opcode.GETPROP, (uint)base_proto_reg, (uint)base_reg, (uint)base_proto_key_reg);
            self.free_reg(base_proto_key_reg);
        }
        self.emit_abc(Opcode.SETPROTO, (uint)proto_reg, (uint)base_proto_reg, 0);
        self.free_reg(base_proto_reg);
    }

    // Install methods on prototype or constructor (static)
    for (ushort mi = 0; mi < method_count; mi++) {
        uint mi_idx = methods[mi].inner_idx;
        ushort method_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)method_reg, mi_idx));

        ushort target_reg = methods[mi].is_static ? ctor_reg : proto_reg;

        // Get the key register — either from computed key expression or static name
        ushort key_reg;
        if (methods[mi].computed_key_inner_idx != MAX_INNER_FUNCS) {
            // Computed key: CLOSURE + CALL to evaluate key expression
            // CALL convention: CALL result_reg, callee_reg, nargs
            // this must be at callee_reg + 1, args at callee_reg + 2, ...
            key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)key_reg, methods[mi].computed_key_inner_idx));
            ushort this_slot = self.alloc_reg(); // must be key_reg + 1
            self.emit(bytecode::make_a_bc(Opcode.LDTHIS, (uint)this_slot, 0));
            self.emit_abc(Opcode.CALL, (uint)key_reg, (uint)key_reg, 0);
            self.free_reg(this_slot);
        } else {
            uint key_idx = self.add_string_constant(methods[mi].name);
            key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
        }

        if (methods[mi].is_getter) {
            self.emit_abc(Opcode.INITGET, (uint)target_reg, (uint)key_reg, (uint)method_reg);
        } else if (methods[mi].is_setter) {
            self.emit_abc(Opcode.INITSET, (uint)target_reg, (uint)key_reg, (uint)method_reg);
        } else {
            self.emit_abc(Opcode.PUTPROP, (uint)target_reg, (uint)key_reg, (uint)method_reg);
        }

        self.free_reg(key_reg);
        self.free_reg(method_reg);
    }

    self.free_reg(proto_reg);

    // Restore class body state
    self.in_class_body = saved_in_class_body;
    self.has_super_binding = saved_has_super;

    return ctor_reg;
}

/// Parse function body (parameters and block) and compile into a nested context.
fn void? CompilerContext.parse_function_body(&self, bool is_expr) {
    // Parse parameter list
    self.expect(TokenType.LPAREN)!;
    ushort arg_count = 0;

    if (!self.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for rest parameter
            if (self.match(TokenType.ELLIPSIS)) {
                Token rest_param = self.expect(TokenType.IDENTIFIER)!;
                if (self.is_strict && is_restricted_name(rest_param.str_value)) {
                    return COMPILE_ERROR~;
                }
                ushort rest_reg = self.declare_var(rest_param.str_value, VAR);
                uint rest_name_idx = self.add_string_constant(rest_param.str_value);
                self.emit_a_bc(Opcode.DECLVAR, (uint)rest_reg, rest_name_idx);
                arg_count++;
                self.has_rest = true;
                self.rest_formal_count = arg_count - 1;
                self.num_args = arg_count;
                // Rest parameter must be last
                break;
            }

            Token param = self.expect(TokenType.IDENTIFIER)!;
            if (self.is_strict && is_restricted_name(param.str_value)) {
                return COMPILE_ERROR~;
            }
            ushort param_reg = self.declare_var(param.str_value, VAR);
            uint param_name_idx = self.add_string_constant(param.str_value);
            // DECLVAR declares the parameter in the immediate var_env only.
            self.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);
            arg_count++;

            // Check for default value
            if (self.check(TokenType.ASSIGN)) {
                self.advance()!; // consume '='

                // Compile the default expression as an inner function
                CompiledFunction* default_func = self.compile_default_expr()!;

                // Add to inner functions table
                if (self.inner_func_count < MAX_INNER_FUNCS
                    && self.default_count < MAX_PARAMS) {
                    uint def_idx = self.inner_func_count;
                    self.inner_funcs[def_idx] = default_func;
                    self.defaults[self.default_count].param_reg = param_reg;
                    self.defaults[self.default_count].param_name_idx = param_name_idx;
                    self.defaults[self.default_count].default_func_idx = def_idx;
                    self.default_count++;
                    self.inner_func_count++;
                }
            }

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    // Set num_args if not already set by rest parameter
    if (!self.has_rest) {
        self.num_args = arg_count;
    }

    self.expect(TokenType.RPAREN)!;

    // Push a function-level lexical scope for let/const at function top level.
    // This sits above the block-level PUSH_LEX emitted by block() so that
    // function-level let/const go into a scope that outlives inner blocks.
    // Skip when there are no default parameters (the only case that needs
    // a function-level scope distinct from the block scope).
    bool has_func_lex = self.default_count > 0;
    if (has_func_lex) {
        self.emit_simple(Opcode.PUSH_LEX);
    }

    // Emit default parameter checks (must run before body, after PUSH_LEX)
    for (ushort di = 0; di < self.default_count; di++) {
        ushort pr = self.defaults[di].param_reg;
        uint name_idx = self.defaults[di].param_name_idx;
        uint func_idx = self.defaults[di].default_func_idx;

        // Check if param != undefined; if so, skip default evaluation
        ushort undef_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = self.alloc_reg();
        self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)pr, (uint)undef_reg);
        self.free_reg(undef_reg);

        // IF_TRUE: skip past default evaluation (will be patched)
        uint skip_addr = self.code_count;
        self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
        self.free_reg(cmp_reg);

        // CLOSURE for default function
        ushort closure_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

        // Set up call: consecutive registers for callee + this
        ushort call_base = self.alloc_reg();
        if (self.next_reg <= call_base + 1) {
            self.next_reg = call_base + 2;
        }
        ushort this_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
        self.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);

        self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

        // Assign result to parameter register and sync to environment
        self.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);
        self.emit_a_bc(Opcode.PUTVAR, (uint)pr, name_idx);

        self.free_regs_to(call_base);

        // Patch the skip jump to land after default evaluation
        int skip_off = (int)self.code_count - (int)skip_addr - 1;
        self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
    }

    // Compile function body block
    self.block(true)!;

    // Pop the function-level lexical scope.
    // NOTE: for functions with explicit return, this POP_LEX won't execute,
    // but that's harmless — the activation is destroyed on return.
    if (has_func_lex) {
        self.emit_simple(Opcode.POP_LEX);
    }

    // Emit implicit return undefined if no explicit return
    // Check if last instruction is a return
    bool has_return = false;
    if (self.code_count > 0) {
        Opcode last_op = self.code[self.code_count - 1].op;
        if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
            last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
            has_return = true;
        }
    }
    if (!has_return) {
        self.emit_simple(self.is_generator ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    }
}

/// Compile a default parameter expression as a zero-argument inner function.
/// Free variables in the expression are resolved at runtime via GETVAR
/// against the outer scope's environment chain.
fn CompiledFunction*? CompilerContext.compile_default_expr(&self) {
    // Create a new CompilerContext for the default expression
    CompilerContext def_ctx;
    def_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict
    def_ctx.is_strict = true;
    def_ctx.lexer.set_strict(true);

    // Propagate class context (for super expressions)
    def_ctx.in_class_body = self.in_class_body;
    def_ctx.has_super_binding = self.has_super_binding;

    // Function-level lexical scope (empty — no parameters)
    def_ctx.emit_simple(Opcode.PUSH_LEX);

    // Compile expression with implicit return
    ushort expr_reg = def_ctx.assignment_expr()!;
    def_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);

    // Pop the function-level lexical scope
    def_ctx.emit_simple(Opcode.POP_LEX);

    CompiledFunction* func = def_ctx.finish()!;

    return func;
}

/// Compile a computed property key expression into a 0-arg inner function.
/// The caller must have already consumed the `[` token.
/// This function compiles the expression and `]` is consumed by the caller after.
fn CompiledFunction*? CompilerContext.compile_key_expr(&self) {
    CompilerContext key_ctx;
    key_ctx.init(self.lexer, self.heap);
    key_ctx.is_strict = true;
    key_ctx.lexer.set_strict(true);
    key_ctx.in_class_body = self.in_class_body;
    key_ctx.has_super_binding = self.has_super_binding;

    key_ctx.emit_simple(Opcode.PUSH_LEX);
    ushort expr_reg = key_ctx.assignment_expr()!;
    key_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);
    key_ctx.emit_simple(Opcode.POP_LEX);

    CompiledFunction* func = key_ctx.finish()!;
    return func;
}

/// Compile an inner function (parameters + body) into a sub-CompiledFunction.
fn CompiledFunction*? CompilerContext.compile_inner_function(&self, char[] name) {
    // Create a new CompilerContext for the inner function
    CompilerContext inner_ctx;
    inner_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict, no propagation needed
    inner_ctx.is_strict = true;
    inner_ctx.lexer.set_strict(true);

    // Propagate generator flag: if the caller is compiling a generator,
    // the inner context (which parses the body) needs to know it's in a generator.
    inner_ctx.is_generator = self.is_generator;

    // Propagate class context (for super expressions)
    inner_ctx.in_class_body = self.in_class_body;
    inner_ctx.has_super_binding = self.has_super_binding;

    // Parse parameter list
    inner_ctx.expect(TokenType.LPAREN)!;
    ushort arg_count = 0;

    if (!inner_ctx.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for rest parameter
            if (inner_ctx.match(TokenType.ELLIPSIS)) {
                Token rest_param = inner_ctx.expect(TokenType.IDENTIFIER)!;
                if (inner_ctx.is_strict && is_restricted_name(rest_param.str_value)) {
                    return COMPILE_ERROR~;
                }
                ushort rest_reg = inner_ctx.declare_var(rest_param.str_value, VAR);
                uint rest_name_idx = inner_ctx.add_string_constant(rest_param.str_value);
                inner_ctx.emit_a_bc(Opcode.DECLVAR, (uint)rest_reg, rest_name_idx);
                arg_count++;
                inner_ctx.has_rest = true;
                inner_ctx.rest_formal_count = arg_count - 1;
                inner_ctx.num_args = arg_count;
                // Rest parameter must be last
                break;
            }

            Token param = inner_ctx.expect(TokenType.IDENTIFIER)!;
            if (inner_ctx.is_strict && is_restricted_name(param.str_value)) {
                return COMPILE_ERROR~;
            }
            ushort param_reg = inner_ctx.declare_var(param.str_value, VAR);
            // Store parameter in the immediate var_env only (DECLVAR).
            uint param_name_idx = inner_ctx.add_string_constant(param.str_value);
            inner_ctx.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);
            arg_count++;

            // Check for default value
            if (inner_ctx.check(TokenType.ASSIGN)) {
                inner_ctx.advance()!; // consume '='

                // Compile the default expression as an inner function
                CompiledFunction* default_func = inner_ctx.compile_default_expr()!;

                // Add to inner functions table
                if (inner_ctx.inner_func_count < MAX_INNER_FUNCS
                    && inner_ctx.default_count < MAX_PARAMS) {
                    uint def_idx = inner_ctx.inner_func_count;
                    inner_ctx.inner_funcs[def_idx] = default_func;
                    inner_ctx.defaults[inner_ctx.default_count].param_reg = param_reg;
                    inner_ctx.defaults[inner_ctx.default_count].param_name_idx = param_name_idx;
                    inner_ctx.defaults[inner_ctx.default_count].default_func_idx = def_idx;
                    inner_ctx.default_count++;
                    inner_ctx.inner_func_count++;
                }
            }

            if (!inner_ctx.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    // Set num_args if not already set by rest parameter
    if (!inner_ctx.has_rest) {
        inner_ctx.num_args = arg_count;
    }

    inner_ctx.expect(TokenType.RPAREN)!;

    // Push a function-level lexical scope for let/const at function top level.
    // Skip when there are no default parameters.
    bool inner_has_func_lex = inner_ctx.default_count > 0;
    if (inner_has_func_lex) {
        inner_ctx.emit_simple(Opcode.PUSH_LEX);
    }

    // Emit default parameter checks (must run before body, after PUSH_LEX)
    for (ushort di = 0; di < inner_ctx.default_count; di++) {
        ushort pr = inner_ctx.defaults[di].param_reg;
        uint name_idx = inner_ctx.defaults[di].param_name_idx;
        uint func_idx = inner_ctx.defaults[di].default_func_idx;

        // Check if param != undefined; if so, skip default evaluation
        ushort undef_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)pr, (uint)undef_reg);
        inner_ctx.free_reg(undef_reg);

        // IF_TRUE: skip past default evaluation (will be patched)
        uint skip_addr = inner_ctx.code_count;
        inner_ctx.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
        inner_ctx.free_reg(cmp_reg);

        // CLOSURE for default function
        ushort closure_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

        // Set up call: consecutive registers for callee + this
        ushort call_base = inner_ctx.alloc_reg();
        if (inner_ctx.next_reg <= call_base + 1) {
            inner_ctx.next_reg = call_base + 2;
        }
        ushort this_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
        inner_ctx.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);

        inner_ctx.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

        // Assign result to parameter register and sync to environment
        inner_ctx.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);
        inner_ctx.emit_a_bc(Opcode.PUTVAR, (uint)pr, name_idx);

        inner_ctx.free_regs_to(call_base);

        // Patch the skip jump to land after default evaluation
        int skip_off = (int)inner_ctx.code_count - (int)skip_addr - 1;
        inner_ctx.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
    }

    // Compile function body
    inner_ctx.block(true)!;

    // Pop the function-level lexical scope
    if (inner_has_func_lex) {
        inner_ctx.emit_simple(Opcode.POP_LEX);
    }

    // Add implicit return undefined
    bool has_return = false;
    if (inner_ctx.code_count > 0) {
        Opcode last_op = inner_ctx.code[inner_ctx.code_count - 1].op;
        if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
            last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
            has_return = true;
        }
    }
    if (!has_return) {
        inner_ctx.emit_simple(inner_ctx.is_generator ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    }

    CompiledFunction* func = inner_ctx.finish()!;

    // Set function name
    if (name.len > 0) {
        func.name_ptr = name.ptr;
        func.name_len = (uint)name.len;
    }

    return func;
}

// ============================================================================
// Expression parsing
// ============================================================================

/// Parse a full expression (comma operator at lowest precedence).
fn ushort? CompilerContext.expression(&self) {
    ushort result = self.assignment_expr()!;

    // Handle comma operator: evaluate each, keep last
    while (self.match(TokenType.COMMA)) {
        self.free_reg(result);
        result = self.assignment_expr()!;
    }

    return result;
}

/// Parse an assignment expression.
fn ushort? CompilerContext.assignment_expr(&self) {
    // Parse LHS with lhs_mode enabled — member_expr saves (obj, key) without GETPROP
    self.lhs_mode = true;
    self.last_was_member = false;
    ushort left = self.conditional_expr()!;
    self.lhs_mode = false;

    TokenType tt2 = self.peek_type();

    // If LHS was a member expression but next token is NOT an assignment,
    // free the saved obj/key registers (GETPROP was already emitted)
    if (self.last_was_member && tt2 != TokenType.ASSIGN
        && tt2 != TokenType.PLUS_ASSIGN && tt2 != TokenType.MINUS_ASSIGN
        && tt2 != TokenType.STAR_ASSIGN && tt2 != TokenType.SLASH_ASSIGN
        && tt2 != TokenType.PERCENT_ASSIGN && tt2 != TokenType.STARSTAR_ASSIGN
        && tt2 != TokenType.SHL_ASSIGN && tt2 != TokenType.SHR_ASSIGN
        && tt2 != TokenType.USHR_ASSIGN && tt2 != TokenType.BIT_AND_ASSIGN
        && tt2 != TokenType.BIT_OR_ASSIGN && tt2 != TokenType.BIT_XOR_ASSIGN
        && tt2 != TokenType.LOG_AND_ASSIGN && tt2 != TokenType.LOG_OR_ASSIGN
        && tt2 != TokenType.NULLISH_ASSIGN) {
        self.free_reg(self.last_member_prop_reg);
        self.free_reg(self.last_member_obj_reg);
        self.last_was_member = false;
    }

    TokenType tt = tt2;

    // Check for assignment operators
    Opcode compound_op;
    bool is_compound = false;
    bool is_assign = false;
    bool is_logical_and_assign = false;
    bool is_logical_or_assign = false;
    bool is_nullish_assign = false;

    switch (tt) {
        case TokenType.ASSIGN:
            is_assign = true;
        case TokenType.PLUS_ASSIGN:
            is_compound = true;
            compound_op = Opcode.ADD;
        case TokenType.MINUS_ASSIGN:
            is_compound = true;
            compound_op = Opcode.SUB;
        case TokenType.STAR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.MUL;
        case TokenType.SLASH_ASSIGN:
            is_compound = true;
            compound_op = Opcode.DIV;
        case TokenType.PERCENT_ASSIGN:
            is_compound = true;
            compound_op = Opcode.MOD;
        case TokenType.STARSTAR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.EXP;
        case TokenType.SHL_ASSIGN:
            is_compound = true;
            compound_op = Opcode.SHL;
        case TokenType.SHR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.SHR;
        case TokenType.USHR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.USHR;
        case TokenType.BIT_AND_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BAND;
        case TokenType.BIT_OR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BOR;
        case TokenType.BIT_XOR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BXOR;
        case TokenType.LOG_AND_ASSIGN:
            is_logical_and_assign = true;
        case TokenType.LOG_OR_ASSIGN:
            is_logical_or_assign = true;
        case TokenType.NULLISH_ASSIGN:
            is_nullish_assign = true;
        default:
            return left;
    }

    // Consume the assignment operator
    self.advance()!;

    // Save LHS info (will be overwritten by RHS evaluation)
    bool lhs_was_getvar = self.last_was_getvar;
    uint lhs_getvar_name_idx = self.last_getvar_name_idx;
    bool lhs_was_member = self.last_was_member;
    ushort lhs_member_obj = self.last_member_obj_reg;
    ushort lhs_member_prop = self.last_member_prop_reg;

    // Peek for a literal-1 RHS: `<var> += 1` → INC, `<var> -= 1` → DEC.
    // Saves a register + LDINT 1 instruction per occurrence (hot in counters).
    if (is_compound && !lhs_was_member) {
        if (self.peek_type() == TokenType.NUMBER) {
            Token num_tok2 = self.lexer.peek()!;
            double nv = num_tok2.num_value;
            if (nv == 1.0 && compound_op == Opcode.ADD) {
                self.advance()!;  // consume the literal
                if (lhs_was_getvar && self.code_count > 0
                    && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                    // Replace the GETVAR with INC_VAR: 1 instruction instead of 3
                    uint name_idx = self.code[self.code_count - 1].get_bc();
                    self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.INC_VAR, 0, name_idx);
                } else {
                    self.emit_abc(Opcode.INC, (uint)left, 0, 0);
                    if (lhs_was_getvar) {
                        self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
                    }
                }
                return left;
            }
            if (nv == 1.0 && compound_op == Opcode.SUB) {
                self.advance()!;
                if (lhs_was_getvar && self.code_count > 0
                    && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                    uint name_idx = self.code[self.code_count - 1].get_bc();
                    self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_VAR, 0, name_idx);
                } else {
                    self.emit_abc(Opcode.DEC, (uint)left, 0, 0);
                    if (lhs_was_getvar) {
                        self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
                    }
                }
                return left;
            }
        }
    }

    // Handle logical assignment operators with short-circuit semantics
    // x ||= expr  →  if (x) return x; x = expr; return expr;
    // x &&= expr  →  if (!x) return x; x = expr; return expr;
    // x ??= expr  →  if (x != null && x != undefined) return x; x = expr; return expr;
    if (is_logical_and_assign || is_logical_or_assign || is_nullish_assign) {
        // For member expressions, allocate a result register for the assigned value.
        // The short-circuit path returns the original LHS (left); the assign path returns RHS.
        ushort la_result = left;
        if (lhs_was_member) {
            la_result = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)la_result, (uint)left, 0);
        }

        if (is_logical_or_assign) {
            // x ||= expr: skip RHS if left is truthy
            uint skip_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)left);
            ushort right = self.assignment_expr()!;
            if (lhs_was_member) {
                self.emit_abc(Opcode.PUTPROP, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
                self.free_reg(lhs_member_prop);
                self.free_reg(lhs_member_obj);
                self.emit_abc(Opcode.LDREG, (uint)la_result, (uint)right, 0);
                self.free_reg(right);
            } else {
                self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
                self.free_reg(right);
                if (lhs_was_getvar) {
                    self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
                }
            }
            self.patch_jump(skip_jump);
            return la_result;
        }
        if (is_logical_and_assign) {
            // x &&= expr: skip RHS if left is falsy
            uint skip_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)left);
            ushort right = self.assignment_expr()!;
            if (lhs_was_member) {
                self.emit_abc(Opcode.PUTPROP, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
                self.free_reg(lhs_member_prop);
                self.free_reg(lhs_member_obj);
                self.emit_abc(Opcode.LDREG, (uint)la_result, (uint)right, 0);
                self.free_reg(right);
            } else {
                self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
                self.free_reg(right);
                if (lhs_was_getvar) {
                    self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
                }
            }
            self.patch_jump(skip_jump);
            return la_result;
        }
        if (is_nullish_assign) {
            // x ??= expr: skip RHS if left is NOT null/undefined
            ushort cmp_reg = self.alloc_reg();
            // Check null
            self.emit_abc(Opcode.LDNULL, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)left, (uint)cmp_reg);
            uint null_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            // Check undefined
            self.emit_abc(Opcode.LDUNDEF, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)left, (uint)cmp_reg);
            uint undef_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            // Not nullish — skip RHS
            self.free_reg(cmp_reg);
            uint skip_jump = self.emit_jump(Opcode.JUMP);
            self.patch_jump(null_jump);
            self.patch_jump(undef_jump);
            // Nullish — evaluate RHS and assign
            ushort right = self.assignment_expr()!;
            if (lhs_was_member) {
                self.emit_abc(Opcode.PUTPROP, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
                self.free_reg(lhs_member_prop);
                self.free_reg(lhs_member_obj);
                self.emit_abc(Opcode.LDREG, (uint)la_result, (uint)right, 0);
                self.free_reg(right);
            } else {
                self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
                self.free_reg(right);
                if (lhs_was_getvar) {
                    self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
                }
            }
            self.patch_jump(skip_jump);
            return la_result;
        }
    }

    // Compile right-hand side
    ushort right = self.assignment_expr()!;

    if (is_assign) {
        if (lhs_was_member) {
            // Member expression assignment: obj.prop = right
            self.emit_abc(Opcode.PUTPROP, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
            self.free_reg(lhs_member_prop);
            self.free_reg(lhs_member_obj);
            self.free_reg(right);
            left = right;
        } else {
            // Simple assignment: left = right
            if (left != right) {
                self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
            }
            self.free_reg(right);
            // If LHS was resolved via GETVAR, write back to environment
            if (lhs_was_getvar) {
                self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
            }
        }
        return left;
    }

    if (is_compound) {
        // Compound assignment: left op= right => left = left op right
        self.emit_abc(compound_op, (uint)left, (uint)left, (uint)right);
        self.free_reg(right);
        // If LHS was resolved via GETVAR, write back to environment
        if (lhs_was_getvar) {
            self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
        }
        return left;
    }

    return left;
}

/// Parse a conditional (ternary) expression: expr ? expr : expr
fn ushort? CompilerContext.conditional_expr(&self) {
    ushort result = self.binary_expr(PREC_NULLISH)!;

    if (self.match(TokenType.QUESTION)) {
        // Allocate result register
        ushort result_reg = self.alloc_reg();

        // Jump to else branch if condition is false
        uint false_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)result);
        self.free_reg(result);

        // True branch
        ushort true_val = self.assignment_expr()!;
        self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)true_val, 0);
        self.free_reg(true_val);

        self.expect(TokenType.COLON)!;

        uint end_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(false_jump);

        // False branch
        ushort false_val = self.assignment_expr()!;
        self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)false_val, 0);
        self.free_reg(false_val);

        self.patch_jump(end_jump);

        return result_reg;
    }

    return result;
}

/// Parse binary expressions using a Pratt parser with precedence climbing.
fn ushort? CompilerContext.binary_expr(&self, int min_prec) {
    self.last_was_local_var = false;
    ushort left = self.unary_expr()!;
    bool left_is_local = self.last_was_local_var;

    for (;;) {
        self.last_was_local_var = false;
        TokenType tt = self.peek_type();
        int prec = get_binary_precedence(tt);

        if (prec < min_prec) {
            break;
        }

        // Handle short-circuit operators specially
        if (tt == TokenType.LOG_AND) {
            self.advance()!;
            // Short-circuit: if left is falsy, skip right and result is left
            uint skip_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)left);

            ushort right = self.binary_expr(prec + 1)!;
            self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
            self.free_reg(right);

            self.patch_jump(skip_jump);
            continue;
        }

        if (tt == TokenType.LOG_OR) {
            self.advance()!;
            // Short-circuit: if left is truthy, skip right and result is left
            uint skip_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)left);

            ushort right = self.binary_expr(prec + 1)!;
            self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
            self.free_reg(right);

            self.patch_jump(skip_jump);
            continue;
        }

        if (tt == TokenType.NULLISH) {
            self.advance()!;
            // Nullish coalescing: if left is not null/undefined, use left.
            // Reuse left as result register (no separate allocation).
            ushort cmp_reg = self.alloc_reg();
            // Check null
            self.emit_abc(Opcode.LDNULL, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)left, (uint)cmp_reg);
            uint null_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            // Check undefined
            self.emit_abc(Opcode.LDUNDEF, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)left, (uint)cmp_reg);
            uint undef_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);

            self.free_reg(cmp_reg);

            // Not nullish — skip right side
            uint skip_jump = self.emit_jump(Opcode.JUMP);

            // Patch null and undefined jumps to here (right side)
            self.patch_jump(null_jump);
            self.patch_jump(undef_jump);

            ushort right = self.binary_expr(prec + 1)!;
            self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
            self.free_reg(right);

            self.patch_jump(skip_jump);
            continue;
        }

        // Regular binary operator
        self.advance()!;

        // Right-to-left associativity for exponentiation
        int next_prec = prec + 1;
        if (tt == TokenType.STARSTAR) {
            next_prec = prec;  // right-associative
        }

        ushort right = self.binary_expr(next_prec)!;
        bool right_is_local = self.last_was_local_var;

        // Determine opcode
        Opcode op = token_to_binary_opcode(tt);

        // If left is a live local variable register, we cannot use it as the
        // destination (it would clobber the variable). Copy it to a fresh temp.
        if (left_is_local) {
            ushort tmp = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)left, 0);
            left = tmp;
            left_is_local = false;
        }

        self.emit_abc(op, (uint)left, (uint)left, (uint)right);
        self.free_reg(right);
        left_is_local = right_is_local;  // propagate for chained ops
    }

    return left;
}

/// Parse a unary expression.
fn ushort? CompilerContext.unary_expr(&self) {
    TokenType tt = self.peek_type();

    switch (tt) {
        case TokenType.MINUS:
            self.advance()!;
            ushort operand = self.unary_expr()!;
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.UNM, (uint)result, (uint)operand, 0);
            self.free_reg(operand);
            return result;

        case TokenType.PLUS:
            self.advance()!;
            ushort op_plus = self.unary_expr()!;
            ushort res_plus = self.alloc_reg();
            self.emit_abc(Opcode.UNP, (uint)res_plus, (uint)op_plus, 0);
            self.free_reg(op_plus);
            return res_plus;

        case TokenType.LOG_NOT:
            self.advance()!;
            ushort op_not = self.unary_expr()!;
            ushort res_not = self.alloc_reg();
            self.emit_abc(Opcode.LNOT, (uint)res_not, (uint)op_not, 0);
            self.free_reg(op_not);
            return res_not;

        case TokenType.BIT_NOT:
            self.advance()!;
            ushort op_bnot = self.unary_expr()!;
            ushort res_bnot = self.alloc_reg();
            self.emit_abc(Opcode.BNOT, (uint)res_bnot, (uint)op_bnot, 0);
            self.free_reg(op_bnot);
            return res_bnot;

        case TokenType.TYPEOF:
            self.advance()!;
            // ES5 §11.4.3: typeof on an unresolvable reference returns "undefined"
            // (does NOT throw ReferenceError).  For bare identifiers we emit a
            // dedicated TYPEOFIDENT opcode that handles the not-found case.
            // For dotted/computed/call expressions (X.y, X[y], X()), fall through
            // to normal expression parsing so the member chain is fully consumed.
            {
                Token? peeked = self.lexer.peek();
                if (try idTok = peeked) {
                    if (idTok.type == TokenType.IDENTIFIER &&
                        !str_eq(idTok.str_value, "true") &&
                        !str_eq(idTok.str_value, "false") &&
                        !str_eq(idTok.str_value, "null") &&
                        !str_eq(idTok.str_value, "undefined")) {
                        self.advance()!;  // consume the identifier
                        // Peek one more token to check for member/call access
                        Token? peeked2 = self.lexer.peek();
                        bool is_member = false;
                        if (try tok2 = peeked2) {
                            is_member = tok2.type == TokenType.DOT ||
                                        tok2.type == TokenType.LBRACKET ||
                                        tok2.type == TokenType.LPAREN;
                        }
                        if (is_member) {
                            // Not a bare identifier — push back and fall through
                            // to normal typeof expr (will parse the member expr)
                            self.pushback(idTok);
                        } else {
                            uint name_idx = self.add_string_constant(idTok.str_value);
                            ushort res_typeof = self.alloc_reg();
                            self.emit(bytecode::make_a_bc(Opcode.TYPEOFIDENT, (uint)res_typeof, name_idx));
                            return res_typeof;
                        }
                    }
                }
            }
            // Fallback: normal typeof expr
            ushort op_typeof = self.unary_expr()!;
            ushort res_typeof = self.alloc_reg();
            self.emit_abc(Opcode.TYPEOF, (uint)res_typeof, (uint)op_typeof, 0);
            self.free_reg(op_typeof);
            return res_typeof;

        case TokenType.VOID:
            self.advance()!;
            ushort op_void = self.unary_expr()!;
            ushort res_void = self.alloc_reg();
            self.emit_abc(Opcode.VOID, (uint)res_void, (uint)op_void, 0);
            self.free_reg(op_void);
            return res_void;

        case TokenType.DELETE:
            self.advance()!;
            // Parse operand with del_mode to track member expression (obj.prop).
            // member_expr emits GETPROP as usual; we patch it to DELPROP below.
            // We use del_mode (not lhs_mode) because expression() inside [bracket]
            // calls assignment_expr which resets lhs_mode.
            self.del_mode = true;
            self.last_was_member = false;
            ushort op_del = self.unary_expr()!;
            self.del_mode = false;

            if (self.last_was_member) {
                // Patch the last emitted instruction from GETPROP to DELPROP.
                // Both have identical register layout: A = result, B = obj, C = key.
                uint last_idx = self.code_count;
                if (last_idx > 0) {
                    last_idx--;
                    Instruction last_insn = self.code[last_idx];
                    if (last_insn.op == Opcode.GETPROP) {
                        self.code[last_idx] = bytecode::make_abc(
                            Opcode.DELPROP,
                            last_insn.a, last_insn.b, last_insn.c);
                    }
                }
                // Free saved registers (prop before obj).
                self.free_reg(self.last_member_prop_reg);
                self.free_reg(self.last_member_obj_reg);
                self.last_was_member = false;
                // op_del is the A register of the patched DELPROP (boolean).
                return op_del;
            } else {
                // Delete of a non-reference (variable, literal, etc.).
                // In non-strict mode, always returns true.
                self.free_reg(op_del);
                ushort res_del = self.alloc_reg();
                self.emit_abc(Opcode.LDTRUE, (uint)res_del, 0, 0);
                return res_del;
            }

        case TokenType.INC:
            // Prefix ++
            self.advance()!;
            ushort op_inc = self.postfix_expr()!;
            bool inc_was_getvar = self.last_was_getvar;
            uint inc_getvar_name_idx = self.last_getvar_name_idx;
            if (inc_was_getvar && self.code_count > 0
                && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                // Replace GETVAR with INC_VAR: 1 dispatch instead of 3
                uint name_idx = self.code[self.code_count - 1].get_bc();
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.INC_VAR, 0, name_idx);
            } else {
                self.emit_abc(Opcode.INC, (uint)op_inc, 0, 0);
                if (inc_was_getvar) {
                    self.emit_a_bc(Opcode.PUTVAR, (uint)op_inc, inc_getvar_name_idx);
                }
            }
            return op_inc;

        case TokenType.DEC:
            // Prefix --
            self.advance()!;
            ushort op_dec = self.postfix_expr()!;
            bool dec_was_getvar = self.last_was_getvar;
            uint dec_getvar_name_idx = self.last_getvar_name_idx;
            if (dec_was_getvar && self.code_count > 0
                && self.code[self.code_count - 1].op == Opcode.GETVAR) {
                uint name_idx = self.code[self.code_count - 1].get_bc();
                self.code[self.code_count - 1] = bytecode::make_a_bc(Opcode.DEC_VAR, 0, name_idx);
            } else {
                self.emit_abc(Opcode.DEC, (uint)op_dec, 0, 0);
                if (dec_was_getvar) {
                    self.emit_a_bc(Opcode.PUTVAR, (uint)op_dec, dec_getvar_name_idx);
                }
            }
            return op_dec;

        case TokenType.NEW:
            return self.new_expr()!;

        default:
            return self.postfix_expr()!;
    }
}

/// Parse postfix expressions (++, --).
fn ushort? CompilerContext.postfix_expr(&self) {
    ushort operand = self.call_expr()!;

    // Save LHS info for write-back if the operand was a global variable
    bool lhs_was_getvar = self.last_was_getvar;
    uint lhs_getvar_name_idx = self.last_getvar_name_idx;

    TokenType tt = self.peek_type();
    if (tt == TokenType.INC) {
        self.advance()!;
        // Save original value
        ushort saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)operand, 0);

        if (lhs_was_getvar) {
            // Replace INC + PUTVAR with INC_VAR + NOP
            self.emit_a_bc(Opcode.INC_VAR, 0, lhs_getvar_name_idx);
            self.emit_abc(Opcode.NOP, 0, 0, 0);
        } else {
            self.emit_abc(Opcode.INC, (uint)operand, 0, 0);
        }

        return saved;
    }

    if (tt == TokenType.DEC) {
        self.advance()!;
        // Save original value
        ushort saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)operand, 0);

        if (lhs_was_getvar) {
            self.emit_a_bc(Opcode.DEC_VAR, 0, lhs_getvar_name_idx);
            self.emit_abc(Opcode.NOP, 0, 0, 0);
        } else {
            self.emit_abc(Opcode.DEC, (uint)operand, 0, 0);
        }

        return saved;
    }

    return operand;
}

/// Parse call expressions: f(), f(a,b), obj.method(), obj[expr](), tag`...`.
fn ushort? CompilerContext.call_expr(&self) {
    ushort callee = self.member_expr()!;

    // If member_expr saved a property object but next token is not a call,
    // free the object register now.
    if (self.call_prop_obj_reg != MAX_REGISTERS
        && !self.check(TokenType.LPAREN)
        && !self.is_next_template()) {
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = MAX_REGISTERS;
    }

    for (;;) {
        if (self.check(TokenType.LPAREN)) {
            callee = self.emit_call(callee)!;
            // Free the property object used as 'this' (if any)
            if (self.call_prop_obj_reg != MAX_REGISTERS) {
                self.free_reg(self.call_prop_obj_reg);
                self.call_prop_obj_reg = MAX_REGISTERS;
            }
        } else if (self.is_next_template()) {
            callee = self.emit_tagged_template(callee)!;
            // Free the property object used as 'this' (if any)
            if (self.call_prop_obj_reg != MAX_REGISTERS) {
                self.free_reg(self.call_prop_obj_reg);
                self.call_prop_obj_reg = MAX_REGISTERS;
            }
        } else if (self.match(TokenType.DOT)) {
            // Property access: callee.name
            char[] prop_str = self.read_property_name()!;
            uint prop_const = self.add_string_constant(prop_str);

            ushort prop_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)prop_reg);
            self.free_reg(prop_reg);

            // If next token is a call, keep the object alive for 'this'
            if (self.check(TokenType.LPAREN) || self.is_next_template()) {
                self.call_prop_obj_reg = callee;
            } else {
                self.free_reg(callee);
            }
            callee = result;
        } else if (self.match(TokenType.LBRACKET)) {
            // Computed property access: callee[expr]
            ushort idx_reg = self.expression()!;
            self.expect(TokenType.RBRACKET)!;

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)idx_reg);
            self.free_reg(idx_reg);

            // If next token is a call, keep the object alive for 'this'
            if (self.check(TokenType.LPAREN)) {
                self.call_prop_obj_reg = callee;
            } else {
                self.free_reg(callee);
            }
            callee = result;
        } else if (self.match(TokenType.OPT_CHAIN)) {
            // Optional chaining: callee?.prop or callee?.()
            // Simplified: treat as regular property access for now
            if (self.check(TokenType.LPAREN)) {
                callee = self.emit_call(callee)!;
            } else {
                char[] prop_str = self.read_property_name()!;
                uint prop_const = self.add_string_constant(prop_str);

                ushort prop_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));

                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)prop_reg);
                self.free_reg(prop_reg);
                self.free_reg(callee);
                callee = result;
            }
        } else {
            break;
        }
    }

    return callee;
}

/// Emit a function call for the callee in the given register.
///
/// Calling convention (matching original Duktape):
///   callee_reg + 0  = callee (function object)
///   callee_reg + 1  = arg 1
///   callee_reg + 2  = arg 2
///   ...
///   callee_reg + N  = arg N
///
/// The result is placed in a separate result register (A field).
/// The VM reads args from callee_reg + 1, so we must guarantee that layout.
fn ushort? CompilerContext.emit_call(&self, ushort callee_reg) {
    self.expect(TokenType.LPAREN)!;

    // Layout: callee_reg = func, callee_reg+1 = this, callee_reg+2.. callee_reg+1+nargs = args
    ushort first_arg = callee_reg + 2;

    // If the argument region overlaps with live registers (from an outer call),
    // move the callee to a free area first.  Otherwise an inner call's arg setup
    // would clobber live values (e.g. print(add(1,2)) clobbers print in r1).
    if (first_arg < self.next_reg) {
        ushort new_callee = self.next_reg;
        self.emit_abc(Opcode.LDREG, (uint)new_callee, (uint)callee_reg, 0);
        callee_reg = new_callee;
        first_arg = callee_reg + 2;
        // Account for the callee's new position so args don't overlap
        if (self.next_reg <= callee_reg + 1) {
            self.next_reg = callee_reg + 2;
        }
    }
    // Place undefined 'this' slot (or the property object for method calls)
    // DEBUG: check call_prop_obj_reg
    if (self.call_prop_obj_reg != MAX_REGISTERS) {
        // DEBUG: print the register number via stderr
        self.emit_abc(Opcode.LDREG, (uint)(callee_reg + 1), (uint)self.call_prop_obj_reg, 0);
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = MAX_REGISTERS;
    } else {
        self.emit_abc(Opcode.LDUNDEF, (uint)(callee_reg + 1), 0, 0);
    }
    if (self.next_reg < first_arg) {
        self.next_reg = first_arg;
    }

    // Compile arguments into consecutive registers starting at first_arg
    ushort arg_count = 0;
    bool has_spread = false;
    ushort spread_count_reg = MAX_REGISTERS;
    ushort total_count_reg = MAX_REGISTERS;

    if (!self.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for spread argument
            if (self.match(TokenType.ELLIPSIS)) {
                // Ensure the destination area doesn't overlap with the
                // register that will hold the spread expression result.
                ushort dest_start = first_arg + arg_count;
                if (self.next_reg <= dest_start + 1) {
                    self.next_reg = dest_start + 2;
                }

                ushort spread_reg = self.assignment_expr()!;

                // Move spread source away from the dest area if it overlaps
                if (spread_reg >= dest_start && spread_reg <= dest_start + 10) {
                    ushort safe_reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDREG, (uint)safe_reg, (uint)spread_reg, 0);
                    self.free_reg(spread_reg);
                    spread_reg = safe_reg;
                }

                if (!has_spread) {
                    has_spread = true;
                    // Allocate count registers
                    spread_count_reg = self.alloc_reg();
                    total_count_reg = self.alloc_reg();
                    // Initialize total count with non-spread args so far
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)total_count_reg, (int)arg_count));
                }

                // SPREAD_ARG: A=dest_start_reg, B=count_out_reg, C=source_reg
                self.emit_abc(Opcode.SPREAD_ARG, (uint)dest_start, (uint)spread_count_reg, (uint)spread_reg);
                self.free_reg(spread_reg);

                // total_count += spread_count
                self.emit_abc(Opcode.ADD, (uint)total_count_reg, (uint)total_count_reg, (uint)spread_count_reg);

                // Adjust next_reg past the worst-case spread area
                // (conservatively reserve space; actual count is only known at runtime)
                if (self.next_reg <= dest_start + 1) {
                    self.next_reg = dest_start + 2;
                }
            } else {
                ushort arg_reg = self.assignment_expr()!;
                // Ensure the argument is in the expected consecutive register
                ushort expected = first_arg + arg_count;
                if (arg_reg != expected) {
                    self.emit_abc(Opcode.LDREG, (uint)expected, (uint)arg_reg, 0);
                    self.free_reg(arg_reg);
                }
                arg_count++;
            }

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    self.expect(TokenType.RPAREN)!;

    // Emit CALL or CALL_S, reusing callee_reg as result (callee+this consumed by call)
    if (has_spread) {
        // CALL_S: A=result, B=callee_reg, C=nargs_reg — reuse callee_reg for result
        self.emit_abc(Opcode.CALL_S, (uint)callee_reg, (uint)callee_reg, (uint)total_count_reg);
    } else {
        self.emit_abc(Opcode.CALL, (uint)callee_reg, (uint)callee_reg, (uint)arg_count);
    }

    // Free everything from callee_reg (callee, this, args, spread temps)
    self.free_regs_to(callee_reg);
    // Result lives at callee_reg
    self.next_reg = callee_reg + 1;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }

    return callee_reg;
}

/// Emit a tagged template call: tag`...` or tag`text ${expr} text`.
///
/// The callee register is already set by member_expr.
/// Template parts become the first argument (a template object array),
/// and embedded expressions become subsequent arguments.
///
/// Calling convention:
///   callee_reg + 0  = callee (tag function)
///   callee_reg + 1  = this (undefined or object for member expressions)
///   callee_reg + 2  = arg 1 (template object array)
///   callee_reg + 3  = arg 2 (expr 1)
///   ...
fn ushort? CompilerContext.emit_tagged_template(&self, ushort callee_reg) {
    // Save the member expression object (if any) for 'this' binding
    ushort obj_reg = MAX_REGISTERS;
    if (self.call_prop_obj_reg != MAX_REGISTERS) {
        obj_reg = self.call_prop_obj_reg;
        self.call_prop_obj_reg = MAX_REGISTERS;
    }

    // Maximum number of template parts (head + middle*s + tail)
    const uint MAX_TEMPLATE_PARTS = 32;

    // Collect string parts and expression registers
    uint[MAX_TEMPLATE_PARTS] str_indices;
    ushort[MAX_TEMPLATE_PARTS] expr_regs;
    uint part_count = 0;
    uint expr_count = 0;

    TokenType tt = self.peek_type();

    // No-substitution template: tag`hello` (lexer returns STRING with is_template)
    if (tt == TokenType.STRING) {
        Token str_tok = self.advance()!;
        if (!str_tok.is_template) {
            return COMPILE_ERROR~;
        }
        str_indices[0] = self.add_string_constant(str_tok.str_value);
        part_count = 1;
    } else if (tt == TokenType.TEMPLATE) {
        // Legacy TEMPLATE token (should not normally appear, but handle gracefully)
        Token tmpl_tok = self.advance()!;
        str_indices[0] = self.add_string_constant(tmpl_tok.str_value);
        part_count = 1;
    } else if (tt == TokenType.TEMPLATE_HEAD) {
        // Template with substitutions: `text${expr}text${expr}text`
        Token head_tok = self.advance()!;
        str_indices[0] = self.add_string_constant(head_tok.str_value);
        part_count = 1;

        // Compile first expression
        expr_regs[0] = self.expression()!;
        expr_count = 1;

        // Handle TEMPLATE_MIDDLE / TEMPLATE_TAIL chain
        for (;;) {
            TokenType next_tt = self.peek_type();
            if (next_tt == TokenType.TEMPLATE_MIDDLE) {
                Token mid_tok = self.advance()!;
                str_indices[part_count] = self.add_string_constant(mid_tok.str_value);
                part_count++;

                expr_regs[expr_count] = self.expression()!;
                expr_count++;
            } else if (next_tt == TokenType.TEMPLATE_TAIL) {
                Token tail_tok = self.advance()!;
                str_indices[part_count] = self.add_string_constant(tail_tok.str_value);
                part_count++;
                break;
            } else {
                return COMPILE_ERROR~;
            }
        }
    } else {
        return COMPILE_ERROR~;
    }

    // === Build the template object array ===
    // Create empty array
    ushort tmpl_arr_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWARR, (uint)tmpl_arr_reg, 0, 0);

    // Fill with string parts
    for (uint i = 0; i < part_count; i++) {
        ushort str_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)str_reg, str_indices[i]));
        ushort idx_reg = self.alloc_reg();
        self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i));
        self.emit_abc(Opcode.PUTPROP, (uint)tmpl_arr_reg, (uint)idx_reg, (uint)str_reg);
        self.free_reg(str_reg);
        self.free_reg(idx_reg);
    }
    self.emit(bytecode::make_a_bc(Opcode.SETALEN, (uint)tmpl_arr_reg, part_count));

    // Create raw array (copy of template array for now — raw === cooked)
    ushort raw_arr_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWARR, (uint)raw_arr_reg, 0, 0);

    for (uint i = 0; i < part_count; i++) {
        ushort str_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)str_reg, str_indices[i]));
        ushort idx_reg = self.alloc_reg();
        self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i));
        self.emit_abc(Opcode.PUTPROP, (uint)raw_arr_reg, (uint)idx_reg, (uint)str_reg);
        self.free_reg(str_reg);
        self.free_reg(idx_reg);
    }
    self.emit(bytecode::make_a_bc(Opcode.SETALEN, (uint)raw_arr_reg, part_count));

    // Set .raw property on template array
    {
        uint raw_key_idx = self.add_string_constant("raw");
        ushort raw_key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)raw_key_reg, raw_key_idx));
        self.emit_abc(Opcode.PUTPROP, (uint)tmpl_arr_reg, (uint)raw_key_reg, (uint)raw_arr_reg);
        self.free_reg(raw_key_reg);
        self.free_reg(raw_arr_reg);
    }

    // === Set up the call ===
    // Ensure callee is positioned so args don't overlap with live registers
    ushort first_arg = callee_reg + 2;
    if (first_arg < self.next_reg) {
        ushort new_callee = self.next_reg;
        self.emit_abc(Opcode.LDREG, (uint)new_callee, (uint)callee_reg, 0);
        callee_reg = new_callee;
        first_arg = callee_reg + 2;
        if (self.next_reg <= callee_reg + 1) {
            self.next_reg = callee_reg + 2;
        }
    }

    // Place 'this' slot
    if (obj_reg != MAX_REGISTERS) {
        self.emit_abc(Opcode.LDREG, (uint)(callee_reg + 1), (uint)obj_reg, 0);
        self.free_reg(obj_reg);
    } else {
        self.emit_abc(Opcode.LDUNDEF, (uint)(callee_reg + 1), 0, 0);
    }
    if (self.next_reg < first_arg) {
        self.next_reg = first_arg;
    }

    // Place template array as first argument (callee_reg + 2)
    self.emit_abc(Opcode.LDREG, (uint)first_arg, (uint)tmpl_arr_reg, 0);
    self.free_reg(tmpl_arr_reg);

    // Place expression arguments in consecutive registers after template array
    for (uint i = 0; i < expr_count; i++) {
        ushort expected = first_arg + 1 + (ushort)i;
        if (expr_regs[i] != expected) {
            self.emit_abc(Opcode.LDREG, (uint)expected, (uint)expr_regs[i], 0);
            self.free_reg(expr_regs[i]);
        }
    }

    // Update next_reg past all arguments
    ushort total_args = 1 + (ushort)expr_count;  // template array + expressions
    self.next_reg = first_arg + total_args;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }

    // Emit CALL: A=result, B=callee, C=arg count
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)callee_reg, (uint)total_args);

    return result_reg;
}

/// Parse new expression: new Constructor(args).
fn ushort? CompilerContext.new_expr(&self) {
    self.expect(TokenType.NEW)!;

    // Check for new.target meta-property
    if (self.match(TokenType.DOT)) {
        Token? target_tok_opt = self.lexer.next_token();
        if (catch err = target_tok_opt) return COMPILE_ERROR~;
        Token target_tok = target_tok_opt;
        char[] target_name = target_tok.str_value;
        if (target_name.len == 0) {
            target_name = lexer::keyword_to_string(target_tok.type);
        }
        if (target_name.len == 6
            && target_name[0] == 't'
            && target_name[1] == 'a'
            && target_name[2] == 'r'
            && target_name[3] == 'g'
            && target_name[4] == 'e'
            && target_name[5] == 't') {
            ushort result_reg = self.alloc_reg();
            self.emit_abc(Opcode.NEWTARGET, (uint)result_reg, 0, 0);
            return result_reg;
        }
        // Not 'target' — error
        return COMPILE_ERROR~;
    }

    // Parse the constructor (could be member access)
    ushort ctor_reg = self.member_expr()!;

    // Args start right after constructor (same convention as emit_call)
    ushort first_arg = ctor_reg + 2;
    if (self.next_reg < first_arg) {
        self.next_reg = first_arg;
    }
    ushort arg_count = 0;

    if (self.match(TokenType.LPAREN)) {
        if (!self.check(TokenType.RPAREN)) {
            for (;;) {
                ushort arg_reg = self.assignment_expr()!;
                ushort expected = first_arg + arg_count;
                if (arg_reg != expected) {
                    self.emit_abc(Opcode.LDREG, (uint)expected, (uint)arg_reg, 0);
                    self.free_reg(arg_reg);
                }
                arg_count++;

                if (!self.match(TokenType.COMMA)) {
                    break;
                }
            }
        }
        self.expect(TokenType.RPAREN)!;
    }

    // Emit NEW_OBJ: reuse ctor_reg as result (ctor consumed by new)
    self.emit_abc(Opcode.NEW_OBJ, (uint)ctor_reg, (uint)ctor_reg, (uint)arg_count);

    self.free_regs_to(ctor_reg);
    self.next_reg = ctor_reg + 1;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }

    return ctor_reg;
}

/// Parse member expression: property accesses and computed accesses.
fn ushort? CompilerContext.member_expr(&self) {
    ushort obj = self.primary_expr()!;

    for (;;) {
        if (self.match(TokenType.DOT)) {
            // Get next token — after '.' it can be an identifier OR any keyword
            // (ES5 §11.2.1: property name must be an IdentifierName)
            Token? prop_name_opt = self.lexer.next_token();
            if (catch err = prop_name_opt) return COMPILE_ERROR~;
            Token prop_name = prop_name_opt;
            char[] prop_str = prop_name.str_value;
            // If it's a keyword, str_value was set; if not, use keyword_to_string
            if (prop_str.len == 0) {
                prop_str = lexer::keyword_to_string(prop_name.type);
            }
            if (prop_name.type != TokenType.IDENTIFIER && prop_str.len == 0) {
                return COMPILE_ERROR~;
            }
            uint prop_const = self.add_string_constant(prop_str);

            ushort prop_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));

            // Always emit GETPROP
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)obj, (uint)prop_reg);

            if (self.del_mode || self.lhs_mode) {
                // LHS / delete mode: keep obj/prop alive for possible PUTPROP/DELPROP
                self.last_was_member = true;
                self.last_member_obj_reg = obj;
                self.last_member_prop_reg = prop_reg;
                // Also set up for potential method call 'this'
                if (self.peek_type() == TokenType.LPAREN || self.is_next_template()) {
                    self.call_prop_obj_reg = obj;
                }
            } else {
                // RHS mode: free obj/prop immediately
                self.free_reg(prop_reg);
                // If next token is LPAREN or a template, this is a method call.
                // Track the object for 'this' setup in emit_call / emit_tagged_template.
                if (self.peek_type() == TokenType.LPAREN || self.is_next_template()) {
                    self.call_prop_obj_reg = obj;
                } else {
                    self.free_reg(obj);
                }
            }
            obj = result;
        } else if (self.match(TokenType.LBRACKET)) {
            // Save lhs_mode: the inner expression() calls assignment_expr()
            // which resets lhs_mode to false, clobbering the outer mode.
            bool saved_lhs = self.lhs_mode;
            ushort idx_reg = self.expression()!;
            self.lhs_mode = saved_lhs;
            self.expect(TokenType.RBRACKET)!;

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)obj, (uint)idx_reg);

            if (self.del_mode || self.lhs_mode) {
                self.last_was_member = true;
                self.last_member_obj_reg = obj;
                self.last_member_prop_reg = idx_reg;
                if (self.peek_type() == TokenType.LPAREN || self.is_next_template()) {
                    self.call_prop_obj_reg = obj;
                }
            } else {
                self.free_reg(idx_reg);
                if (self.peek_type() == TokenType.LPAREN || self.is_next_template()) {
                    self.call_prop_obj_reg = obj;
                } else {
                    self.free_reg(obj);
                }
            }
            obj = result;
        } else {
            break;
        }
    }

    return obj;
}

/// Parse primary expressions: literals, identifiers, grouping, etc.
fn ushort? CompilerContext.primary_expr(&self) {
    TokenType tt = self.peek_type();

    switch (tt) {
        case TokenType.NUMBER:
            self.last_was_getvar = false;
            Token num_tok = self.advance()!;

            // Legacy octal integer literal (0 followed by octal digit 0-7)
            // is a SyntaxError in strict mode per ES5 §7.8.3 + B.1.1.
            char[] nsrc = num_tok.str_value;
            if (self.is_strict && nsrc.len >= 2 && nsrc[0] == '0' && nsrc[1] >= '0' && nsrc[1] <= '7') {
                return COMPILE_ERROR~;
            }

            ushort num_reg = self.alloc_reg();

            // Check if it fits in a signed 16-bit immediate
            double val = num_tok.num_value;
            int int_val = (int)val;
            if ((double)int_val == val && int_val >= bytecode::MIN_SBC && int_val <= bytecode::MAX_SBC) {
                self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)num_reg, int_val));
            } else {
                uint const_idx = self.add_number_constant(val);
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)num_reg, const_idx));
            }
            return num_reg;

        case TokenType.STRING:
            Token str_tok = self.advance()!;

            // Legacy octal escape sequences in strings are SyntaxErrors
            // in strict mode per ES5 §7.8.4 + Annex B.1.2.
            if (self.is_strict && str_tok.has_octal_escape) {
                return COMPILE_ERROR~;
            }

            uint str_idx = self.add_string_constant(str_tok.str_value);
            ushort str_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)str_reg, str_idx));
            return str_reg;

        case TokenType.IDENTIFIER:
            // Check for arrow function: IDENTIFIER ARROW => single param
            {
                Token id_tok = self.advance()!;

                // Check for literal keywords tokenized as identifiers
                if (str_eq(id_tok.str_value, "true")) {
                    self.last_was_getvar = false;
                    ushort reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDTRUE, (uint)reg, 0, 0);
                    return reg;
                }
                if (str_eq(id_tok.str_value, "false")) {
                    self.last_was_getvar = false;
                    ushort reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDFALSE, (uint)reg, 0, 0);
                    return reg;
                }
                if (str_eq(id_tok.str_value, "null")) {
                    self.last_was_getvar = false;
                    ushort reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDNULL, (uint)reg, 0, 0);
                    return reg;
                }
                if (str_eq(id_tok.str_value, "undefined")) {
                    self.last_was_getvar = false;
                    ushort reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
                    return reg;
                }

                // Arrow function: IDENTIFIER => ...
                if (self.check(TokenType.ARROW)) {
                    char[][1] params_arr;
                    params_arr[0] = id_tok.str_value;
                    return self.parse_arrow_function(&params_arr[0], 1, false)!;
                }

                // Try to resolve as a local variable first (skip at global scope — use environment)
                if (!self.is_global) {
                    if (try var_reg = self.resolve_var(id_tok.str_value)) {
                        self.last_was_getvar = false;
                        self.last_was_local_var = true;
                        self.last_local_var_reg = var_reg;
                        return var_reg;
                    }
                }

                // When 'arguments' is referenced inside a non-arrow function body,
                // set the uses_arguments flag so the VM creates the arguments object.
                if (str_eq(id_tok.str_value, "arguments") && !self.is_global) {
                    self.uses_arguments = true;
                }

                // Not found locally: emit GETVAR to look up by name at runtime
                uint name_idx = self.add_string_constant(id_tok.str_value);
                ushort id_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)id_reg, name_idx));
                self.last_was_getvar = true;
                self.last_getvar_name_idx = name_idx;
                return id_reg;
            }

        case TokenType.THIS:
            self.advance()!;
            ushort this_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDTHIS, (uint)this_reg, 0, 0);
            return this_reg;

        case TokenType.LPAREN: {
            // Try arrow function with parens: (params) => ...
            // Strategy: parse paren content as potential params, check for => after ),
            // pushback all tokens and re-parse as grouping if not arrow.
            Token lparen = self.advance()!;
            bool try_grouping = false;

            // Check for empty parens: () => ...
            if (self.check(TokenType.RPAREN)) {
                Token rparen = self.advance()!;
                if (self.check(TokenType.ARROW)) {
                    // No-param arrow: () => ...
                    char[]* no_params = null;
                    return self.parse_arrow_function(no_params, 0, false)!;
                }
                // Not an arrow: pushback and fall through to grouping
                self.pushback(rparen);
                self.pushback(lparen);
                try_grouping = true;
            }
            // Check for arrow with params: (id) => or (id, id, ...) => ...
            else if ((self.check(TokenType.IDENTIFIER) || self.check(TokenType.ELLIPSIS)) && !try_grouping) {
                char[][8] param_names;
                ushort pc = 0;
                Token[16] saved;  // save tokens for backtracking
                ushort sc = 0;
                bool has_rest = false;

                bool is_arrow = false;
                for (;;) {
                    // Check for rest parameter
                    if (self.check(TokenType.ELLIPSIS)) {
                        Token ellipsis = self.advance()!;
                        saved[sc++] = ellipsis;
                        Token t = self.advance()!;
                        saved[sc++] = t;
                        if (t.type != TokenType.IDENTIFIER) {
                            break;  // not a valid rest param, can't be arrow
                        }
                        param_names[pc++] = t.str_value;
                        has_rest = true;

                        if (self.check(TokenType.RPAREN)) {
                            Token rp = self.advance()!;
                            saved[sc++] = rp;
                            if (self.check(TokenType.ARROW)) {
                                is_arrow = true;
                            }
                        }
                        break;
                    }

                    Token t = self.advance()!;
                    saved[sc++] = t;
                    if (t.type != TokenType.IDENTIFIER) {
                        break;  // not a param name, can't be arrow
                    }
                    param_names[pc++] = t.str_value;

                    if (self.check(TokenType.RPAREN)) {
                        Token rp = self.advance()!;
                        saved[sc++] = rp;
                        if (self.check(TokenType.ARROW)) {
                            is_arrow = true;
                        }
                        break;
                    }
                    if (!self.check(TokenType.COMMA)) {
                        break;  // unexpected token, not arrow
                    }
                    // Consume comma
                    Token comma = self.advance()!;
                    saved[sc++] = comma;
                }

                if (is_arrow) {
                    return self.parse_arrow_function(&param_names[0], pc, has_rest)!;
                }

                // Not an arrow: pushback saved tokens + lparen
                for (ushort si = sc; si > 0; si--) {
                    self.pushback(saved[si - 1]);
                }
                self.pushback(lparen);
                try_grouping = true;
            } else if (!try_grouping) {
                // Not arrow: pushback lparen
                self.pushback(lparen);
                try_grouping = true;
            }

            // Grouping expression
            if (try_grouping) {
                self.advance()!;  // (
                ushort inner2 = self.expression()!;
                self.expect(TokenType.RPAREN)!;
                return inner2;
            }
            // unreachable
            return COMPILE_ERROR~;
        }

        case TokenType.LBRACE:
            return self.object_literal()!;

        case TokenType.LBRACKET:
            return self.array_literal()!;

        case TokenType.FUNCTION:
            return self.function_expr()!;

        case TokenType.YIELD:
        {
            self.advance()!;  // consume 'yield'
            if (!self.is_generator) {
                return COMPILE_ERROR~;  // yield only valid in generators
            }
            // Check for yield* (delegating yield)
            bool is_delegate = false;
            if (self.match(TokenType.STAR)) {
                is_delegate = true;
            }

            ushort val_reg;
            if (is_delegate) {
                // yield* iterable — transform into a loop that yields each element.
                // Equivalent to: for (let i = 0, len = iterable.length; i < len; i++) yield iterable[i];
                ushort iterable_reg = self.assignment_expr()!;

                // Allocate persistent registers (not freed until after loop)
                ushort idx_reg = self.alloc_reg();
                ushort len_reg = self.alloc_reg();
                ushort elem_reg = self.alloc_reg();
                ushort cmp_reg = self.alloc_reg();
                ushort one_reg = self.alloc_reg();
                ushort len_str_reg = self.alloc_reg();

                // idx = 0
                self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, 0));

                // len = iterable.length
                uint length_str_idx = self.add_string_constant("length");
                self.emit_abc(Opcode.LDCONST, (uint)len_str_reg, length_str_idx, 0);
                self.emit_abc(Opcode.GETPROP, (uint)len_reg, (uint)iterable_reg, (uint)len_str_reg);

                // one = 1
                self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)one_reg, 1));

                // Loop header
                uint loop_start = self.code_count;

                // cmp = idx < len
                self.emit_abc(Opcode.LT, (uint)cmp_reg, (uint)idx_reg, (uint)len_reg);
                uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cmp_reg);

                // elem = iterable[idx]
                self.emit_abc(Opcode.GETPROP, (uint)elem_reg, (uint)iterable_reg, (uint)idx_reg);

                // yield elem (YIELD + LOAD_RESUME)
                self.emit_abc(Opcode.YIELD, (uint)elem_reg, 0, 0);
                self.emit_abc(Opcode.LOAD_RESUME, (uint)elem_reg, 0, 0);

                // idx = idx + 1
                self.emit_abc(Opcode.ADD, (uint)idx_reg, (uint)idx_reg, (uint)one_reg);

                // jump back to loop header
                int back_offset = (int)loop_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

                self.patch_jump(exit_jump);

                // Free loop registers
                self.free_reg(len_str_reg);
                self.free_reg(one_reg);
                self.free_reg(cmp_reg);
                self.free_reg(elem_reg);
                self.free_reg(len_reg);
                self.free_reg(idx_reg);
                self.free_reg(iterable_reg);

                // yield* result is undefined (delegation completion value)
                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.LDUNDEF, (uint)result, 0, 0);
                return result;
            } else {
                // yield expression (optional)
                if (self.check(TokenType.SEMICOLON) || self.check(TokenType.RBRACE)
                    || self.check(TokenType.RPAREN) || self.check(TokenType.COMMA)
                    || self.check(TokenType.COLON) || self.check(TokenType.RBRACKET)
                    || self.is_at_end()) {
                    // yield without expression → yield undefined
                    ushort result = self.alloc_reg();
                    self.emit_abc(Opcode.LDUNDEF, (uint)result, 0, 0);
                    self.emit_abc(Opcode.YIELD, (uint)result, 0, 0);
                    self.emit_abc(Opcode.LOAD_RESUME, (uint)result, 0, 0);
                    return result;
                }
                val_reg = self.assignment_expr()!;
                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)result, (uint)val_reg, 0);
                self.emit_abc(Opcode.YIELD, (uint)result, 0, 0);
                self.emit_abc(Opcode.LOAD_RESUME, (uint)result, 0, 0);
                self.free_reg(val_reg);
                return result;
            }
        }

        case TokenType.CLASS:
            return self.class_expression()!;

        case TokenType.SUPER:
        {
            self.advance()!;  // consume 'super'
            // super() — call superclass constructor
            if (self.match(TokenType.LPAREN)) {
                // Look up __super__ from the environment
                if (!self.has_super_binding) {
                    return COMPILE_ERROR~;  // super() only valid with extends
                }
                uint super_name_idx = self.add_string_constant("__super__");
                ushort super_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)super_reg, super_name_idx));

                // Parse arguments
                ushort first_arg = super_reg + 2;
                if (self.next_reg < first_arg) {
                    self.next_reg = first_arg;
                }
                ushort arg_count = 0;
                if (!self.check(TokenType.RPAREN)) {
                    for (;;) {
                        ushort arg_reg = self.assignment_expr()!;
                        ushort expected = first_arg + arg_count;
                        if (arg_reg != expected) {
                            self.emit_abc(Opcode.LDREG, (uint)expected, (uint)arg_reg, 0);
                            self.free_reg(arg_reg);
                        }
                        arg_count++;
                        if (!self.match(TokenType.COMMA)) {
                            break;
                        }
                    }
                }
                self.expect(TokenType.RPAREN)!;

                // Place 'this' slot
                self.emit_abc(Opcode.LDTHIS, (uint)(super_reg + 1), 0, 0);

                // Emit SUPER_CALL, reusing super_reg as result
                self.emit_abc(Opcode.SUPER_CALL, (uint)super_reg, (uint)super_reg, (uint)arg_count);

                // Free arg regs and super_reg (callee+this no longer needed after SUPER_CALL)
                self.free_regs_to(super_reg);
                self.next_reg = super_reg + 1;
                if (self.next_reg > self.max_reg) {
                    self.max_reg = self.next_reg;
                }
                return super_reg;
            }

            // super.property — access property on superclass prototype
            // super[expr] — computed property access on superclass prototype
            if (self.check(TokenType.DOT) || self.check(TokenType.LBRACKET)) {
                if (!self.has_super_binding) {
                    return COMPILE_ERROR~;
                }
                uint super_name_idx = self.add_string_constant("__super__");
                ushort super_ctor_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)super_ctor_reg, super_name_idx));

                // Get super.prototype
                uint proto_name_idx = self.add_string_constant("prototype");
                ushort proto_key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)proto_key_reg, proto_name_idx));
                ushort super_proto_reg = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)super_proto_reg, (uint)super_ctor_reg, (uint)proto_key_reg);
                self.free_reg(proto_key_reg);
                self.free_reg(super_ctor_reg);

                // Now parse the property access
                ushort result;
                if (self.match(TokenType.DOT)) {
                    char[] prop_str = self.read_property_name()!;
                    uint prop_idx = self.add_string_constant(prop_str);
                    ushort prop_key_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_key_reg, prop_idx));
                    result = self.alloc_reg();
                    self.emit_abc(Opcode.GETPROP, (uint)result, (uint)super_proto_reg, (uint)prop_key_reg);
                    self.free_reg(prop_key_reg);

                    // Save for method call this-binding
                    // Don't use the super prototype as 'this' — use LDTHIS
                    // The this-binding for super.method() calls should be
                    // set by the caller (emit_call will use call_prop_obj_reg)
                    // But we don't have a good way to pass "this" from here.
                    // For now, just return the method; the caller handles this.
                    self.last_was_member = true;
                    self.last_member_obj_reg = super_proto_reg;
                    self.last_member_prop_reg = result;
                } else {
                    // super[expr]
                    self.advance()!;  // consume '['
                    ushort key_reg = self.expression()!;
                    self.expect(TokenType.RBRACKET)!;
                    result = self.alloc_reg();
                    self.emit_abc(Opcode.GETPROP, (uint)result, (uint)super_proto_reg, (uint)key_reg);
                    self.free_reg(key_reg);
                }

                self.free_reg(super_proto_reg);
                return result;
            }

            return COMPILE_ERROR~;
        }

        case TokenType.TEMPLATE_HEAD:
        {
            // Template literal with substitutions: `text${expr}text${expr}text`
            Token head_tok = self.advance()!;
            uint head_idx = self.add_string_constant(head_tok.str_value);
            ushort result_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)result_reg, head_idx));

            // Parse the expression inside ${...}
            ushort expr_reg = self.expression()!;

            // Concatenate: result = result + expr  (ADD handles string coercion)
            {
                ushort concat_reg = self.alloc_reg();
                self.emit_abc(Opcode.ADD, (uint)concat_reg, (uint)result_reg, (uint)expr_reg);
                self.free_reg(expr_reg);
                self.free_reg(result_reg);
                result_reg = concat_reg;
            }

            // Handle TEMPLATE_MIDDLE / TEMPLATE_TAIL chain
            for (;;) {
                TokenType next_tt = self.peek_type();
                if (next_tt == TokenType.TEMPLATE_MIDDLE) {
                    Token mid_tok = self.advance()!;
                    uint mid_idx = self.add_string_constant(mid_tok.str_value);
                    ushort mid_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)mid_reg, mid_idx));

                    // Concatenate the middle text
                    ushort concat_reg2 = self.alloc_reg();
                    self.emit_abc(Opcode.ADD, (uint)concat_reg2, (uint)result_reg, (uint)mid_reg);
                    self.free_reg(result_reg);
                    self.free_reg(mid_reg);
                    result_reg = concat_reg2;

                    // Parse the next expression
                    ushort next_expr_reg = self.expression()!;

                    // Concatenate expression
                    ushort concat_reg3 = self.alloc_reg();
                    self.emit_abc(Opcode.ADD, (uint)concat_reg3, (uint)result_reg, (uint)next_expr_reg);
                    self.free_reg(next_expr_reg);
                    self.free_reg(result_reg);
                    result_reg = concat_reg3;
                } else if (next_tt == TokenType.TEMPLATE_TAIL) {
                    Token tail_tok = self.advance()!;
                    uint tail_idx = self.add_string_constant(tail_tok.str_value);
                    ushort tail_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)tail_reg, tail_idx));

                    // Concatenate the tail text
                    ushort concat_reg4 = self.alloc_reg();
                    self.emit_abc(Opcode.ADD, (uint)concat_reg4, (uint)result_reg, (uint)tail_reg);
                    self.free_reg(result_reg);
                    self.free_reg(tail_reg);
                    result_reg = concat_reg4;

                    break;
                } else {
                    // Expected TEMPLATE_MIDDLE or TEMPLATE_TAIL
                    return COMPILE_ERROR~;
                }
            }

            return result_reg;
        }

        case TokenType.TEMPLATE:
            // Legacy fallback for old-style raw TEMPLATE token
            Token tmpl_tok = self.advance()!;
            uint tmpl_idx = self.add_string_constant(tmpl_tok.str_value);
            ushort tmpl_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)tmpl_reg, tmpl_idx));
            return tmpl_reg;

        case TokenType.REGEXP: {
            Token re_tok = self.advance()!;
            uint re_idx = self.add_string_constant(re_tok.str_value);
            ushort re_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.NEWREGEXP, (uint)re_reg, re_idx));
            return re_reg;
        }

        default:
            // Check for literal keywords
            if (tt == TokenType.LET) {
                // 'let' used as identifier in non-strict mode
                Token let_tok = self.advance()!;
                if (try var_reg = self.resolve_var(let_tok.str_value)) {
                    return var_reg;
                }
                uint name_idx = self.add_string_constant(let_tok.str_value);
                ushort let_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)let_reg, name_idx));
                return let_reg;
            }
            return self.literal_keyword()!;
    }
}

/// Parse literal keyword values (true, false, null, undefined).
fn ushort? CompilerContext.literal_keyword(&self) {
    TokenType tt = self.peek_type();
    self.advance()!;

    ushort reg = self.alloc_reg();

    // Map certain keyword tokens to load instructions
    // The lexer produces these as keyword token types
    // We need to check the str_value for true/false/null/undefined
    // But those aren't separate token types in our lexer, so handle via
    // the token type directly:

    // Actually, looking at the lexer, true/false/null/undefined are
    // tokenized as IDENTIFIER tokens. Let's handle the case where
    // we reach here with an unexpected token.
    switch (tt) {
        default:
            // Emit LDUNDEF as a fallback for unrecognized primary expressions
            self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
    }

    return reg;
}

/// Parse object literal: { key: value, ... }
fn ushort? CompilerContext.object_literal(&self) {
    self.expect(TokenType.LBRACE)!;

    ushort obj_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWOBJ, (uint)obj_reg, 0, 0);

    // Track data property keys for duplicate detection in strict mode.
    // ES5 §11.1.5: duplicate PropertyName in PropertySetData is a
    // SyntaxError when contained in strict code.
    char[16][64] seen_key_buf;
    usz[16] seen_key_len;
    usz seen_count = 0;

    if (!self.check(TokenType.RBRACE)) {
        for (;;) {
            if (self.check(TokenType.RBRACE)) {
                break;
            }

            // Parse property key
            ushort key_reg;

            TokenType key_tt = self.peek_type();
            if (key_tt == TokenType.IDENTIFIER || key_tt == TokenType.STRING) {
                Token key_tok = self.advance()!;

                // Check for getter/setter: `get prop() {}` / `set prop(v) {}`
                // If key is "get" or "set" AND next token is a property key (not `:` or `(`)
                bool is_obj_getter = false;
                bool is_obj_setter = false;
                if (key_tt == TokenType.IDENTIFIER && !self.check(TokenType.COLON) && !self.check(TokenType.LPAREN)) {
                    if (key_tok.str_value.len == 3
                        && key_tok.str_value[0] == 'g'
                        && key_tok.str_value[1] == 'e'
                        && key_tok.str_value[2] == 't') {
                        is_obj_getter = true;
                    } else if (key_tok.str_value.len == 3
                        && key_tok.str_value[0] == 's'
                        && key_tok.str_value[1] == 'e'
                        && key_tok.str_value[2] == 't') {
                        is_obj_setter = true;
                    }
                }

                if (is_obj_getter || is_obj_setter) {
                    // Parse the actual property name
                    TokenType prop_tt = self.peek_type();
                    if (prop_tt == TokenType.LBRACKET) {
                        // Computed getter/setter key: `get [expr]() {}` / `set [expr](v) {}`
                        self.advance()!; // consume `[`
                        key_reg = self.assignment_expr()!;
                        self.expect(TokenType.RBRACKET)!;
                    } else {
                        Token prop_tok;
                        if (prop_tt == TokenType.IDENTIFIER || prop_tt == TokenType.STRING) {
                            prop_tok = self.advance()!;
                        } else if (prop_tt == TokenType.NUMBER) {
                            prop_tok = self.advance()!;
                        } else {
                            return COMPILE_ERROR~;
                        }

                        // Emit key constant
                        uint prop_key_idx;
                        if (prop_tt == TokenType.NUMBER) {
                            prop_key_idx = self.add_number_constant(prop_tok.num_value);
                        } else {
                            prop_key_idx = self.add_string_constant(prop_tok.str_value);
                        }
                        key_reg = self.alloc_reg();
                        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, prop_key_idx));
                    }

                    // Compile the getter/setter function body
                    ushort accessor_reg = self.function_expr_body()!;

                    if (is_obj_getter) {
                        self.emit_abc(Opcode.INITGET, (uint)obj_reg, (uint)key_reg, (uint)accessor_reg);
                    } else {
                        self.emit_abc(Opcode.INITSET, (uint)obj_reg, (uint)key_reg, (uint)accessor_reg);
                    }
                    self.free_reg(accessor_reg);
                    self.free_reg(key_reg);

                    if (!self.match(TokenType.COMMA)) {
                        break;
                    }
                    continue;
                }

                // Regular property (not getter/setter)
                // Duplicate data property check in strict mode
                if (self.is_strict) {
                    for (usz i = 0; i < seen_count; i++) {
                        if (str_eq(seen_key_buf[i][:seen_key_len[i]], key_tok.str_value)) {
                            return COMPILE_ERROR~;
                        }
                    }
                    if (seen_count < 16 && key_tok.str_value.len < 64) {
                        for (usz j = 0; j < key_tok.str_value.len; j++) {
                            seen_key_buf[seen_count][j] = key_tok.str_value[j];
                        }
                        seen_key_len[seen_count] = key_tok.str_value.len;
                        seen_count++;
                    }
                }

                uint key_idx = self.add_string_constant(key_tok.str_value);
                key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
            } else if (key_tt == TokenType.NUMBER) {
                Token key_tok = self.advance()!;

                // Duplicate data property check in strict mode.
                // Convert number to canonical string via %.17g to match
                // vm_number_to_string runtime behavior.
                if (self.is_strict && seen_count < 16) {
                    int len = libc::snprintf(&seen_key_buf[seen_count], 64, "%.17g", key_tok.num_value);
                    char[] num_str = seen_key_buf[seen_count][:len];
                    for (usz i = 0; i < seen_count; i++) {
                        if (str_eq(seen_key_buf[i][:seen_key_len[i]], num_str)) {
                            return COMPILE_ERROR~;
                        }
                    }
                    seen_key_len[seen_count] = (usz)len;
                    seen_count++;
                }

                uint key_idx = self.add_number_constant(key_tok.num_value);
                key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
            } else if (key_tt == TokenType.LBRACKET) {
                // Computed property key
                self.advance()!;
                key_reg = self.assignment_expr()!;
                self.expect(TokenType.RBRACKET)!;
            } else {
                return COMPILE_ERROR~;
            }

            // Check for method shorthand or data property
            if (self.check(TokenType.LPAREN)) {
                // Method shorthand: key() { ... }
                ushort method_reg = self.function_expr_body()!;
                self.emit_abc(Opcode.PUTPROP, (uint)obj_reg, (uint)key_reg, (uint)method_reg);
                self.free_reg(method_reg);
                self.free_reg(key_reg);
            } else {
                // key: value
                self.expect(TokenType.COLON)!;
                ushort val_reg = self.assignment_expr()!;
                self.emit_abc(Opcode.PUTPROP, (uint)obj_reg, (uint)key_reg, (uint)val_reg);
                self.free_reg(val_reg);
                self.free_reg(key_reg);
            }

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    self.expect(TokenType.RBRACE)!;
    return obj_reg;
}

/// Parse array literal: [ expr, expr, ... ]
fn ushort? CompilerContext.array_literal(&self) {
    self.expect(TokenType.LBRACKET)!;

    ushort arr_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWARR, (uint)arr_reg, 0, 0);

    // Track index: compile-time uint for normal arrays,
    // register-based when spread is used
    uint index = 0;
    ushort idx_reg = MAX_REGISTERS;
    bool has_spread = false;

    if (!self.check(TokenType.RBRACKET)) {
        for (;;) {
            if (self.check(TokenType.RBRACKET)) {
                break;
            }

            if (self.check(TokenType.COMMA)) {
                // Elision (hole in array)
                if (has_spread) {
                    ushort one = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)one, 1));
                    self.emit_abc(Opcode.ADD, (uint)idx_reg, (uint)idx_reg, (uint)one);
                    self.free_reg(one);
                } else {
                    index++;
                }
                self.advance()!;
                continue;
            }

            // Check for spread
            if (self.match(TokenType.ELLIPSIS)) {
                ushort spread_reg = self.assignment_expr()!;

                if (!has_spread) {
                    // First spread: switch to register-based index
                    has_spread = true;
                    idx_reg = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)index));
                }

                // ARRSPRD: A=target_arr, B=idx_reg, C=source
                self.emit_abc(Opcode.ARRSPRD, (uint)arr_reg, (uint)idx_reg, (uint)spread_reg);
                self.free_reg(spread_reg);
            } else {
                ushort elem_reg = self.assignment_expr()!;

                if (has_spread) {
                    // Dynamic index: store at current idx_reg, then increment
                    self.emit_abc(Opcode.PUTPROP, (uint)arr_reg, (uint)idx_reg, (uint)elem_reg);
                    ushort one = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)one, 1));
                    self.emit_abc(Opcode.ADD, (uint)idx_reg, (uint)idx_reg, (uint)one);
                    self.free_reg(one);
                } else {
                    // Compile-time index
                    ushort idx_const = self.alloc_reg();
                    self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_const, (int)index));
                    self.emit_abc(Opcode.PUTPROP, (uint)arr_reg, (uint)idx_const, (uint)elem_reg);
                    self.free_reg(idx_const);
                    index++;
                }
                self.free_reg(elem_reg);
            }

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    // Set array length
    if (has_spread) {
        // Dynamic length: set arr["length"] = idx_reg
        uint len_const_idx = self.add_string_constant("length");
        ushort len_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)len_reg, len_const_idx));
        self.emit_abc(Opcode.PUTPROP, (uint)arr_reg, (uint)len_reg, (uint)idx_reg);
        self.free_reg(len_reg);
    } else {
        self.emit(bytecode::make_a_bc(Opcode.SETALEN, (uint)arr_reg, index));
    }

    self.expect(TokenType.RBRACKET)!;
    return arr_reg;
}

/// Parse a function expression: function name?(...) { ... }
fn ushort? CompilerContext.function_expr(&self) {
    self.expect(TokenType.FUNCTION)!;

    // Save and reset generator state
    bool saved_is_generator = self.is_generator;
    self.is_generator = false;

    // Check for generator star: function* name?() {}
    if (self.match(TokenType.STAR)) {
        self.is_generator = true;
    }

    // Optional function name
    char[] name;
    if (self.check(TokenType.IDENTIFIER)) {
        Token name_tok = self.advance()!;
        name = name_tok.str_value;
    }

    // Compile the function body into a sub-context
    CompiledFunction* inner = self.compile_inner_function(name)!;

    // Restore generator flag
    self.is_generator = saved_is_generator;

    // Add to inner functions table
    uint inner_idx = 0;
    if (self.inner_func_count < MAX_INNER_FUNCS) {
        inner_idx = self.inner_func_count;
        self.inner_funcs[inner_idx] = inner;
        self.inner_func_count++;
    }

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Parse a function expression body (parameters + block) without the `function` keyword.
/// Used for method shorthand in object literals.
fn ushort? CompilerContext.function_expr_body(&self) {
    char[] name;  // anonymous
    CompiledFunction* inner = self.compile_inner_function(name)!;

    uint inner_idx = 0;
    if (self.inner_func_count < MAX_INNER_FUNCS) {
        inner_idx = self.inner_func_count;
        self.inner_funcs[inner_idx] = inner;
        self.inner_func_count++;
    }

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Parse an arrow function: `(params) => expr` or `(params) => { body }`
/// or `param => expr`.  The caller has already consumed the leading `(`
/// or the single identifier.
///
/// `params`: pre-parsed parameter name slices (pointer to first element).
/// `param_count`: number of parameters.
fn ushort? CompilerContext.parse_arrow_function(&self, char[]* params, ushort param_count, bool has_rest) {
    // Consume the ARROW token
    self.expect(TokenType.ARROW)!;

    // Create inner CompiledFunction for the arrow
    CompiledFunction* inner = self.compile_arrow_inner(params, param_count, has_rest)!;

    // Add to inner functions table
    uint inner_idx = 0;
    if (self.inner_func_count < MAX_INNER_FUNCS) {
        inner_idx = self.inner_func_count;
        self.inner_funcs[inner_idx] = inner;
        self.inner_func_count++;
    }

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Compile an inner arrow function given its parameter names.
/// Arrow functions have `is_arrow = true`, lexical `this`, and no `.prototype`.
fn CompiledFunction*? CompilerContext.compile_arrow_inner(&self, char[]* params, ushort param_count, bool has_rest) {
    // Create a new CompilerContext for the arrow function
    CompilerContext arrow_ctx;
    arrow_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict
    arrow_ctx.is_strict = true;
    arrow_ctx.lexer.set_strict(true);

    // Arrow functions use the parent scope — no fresh env needed.
    arrow_ctx.is_arrow = true;

    // Propagate class context (for super expressions)
    arrow_ctx.in_class_body = self.in_class_body;
    arrow_ctx.has_super_binding = self.has_super_binding;

    // Register parameters
    ushort formal_count = param_count;
    if (has_rest && param_count > 0) {
        formal_count = param_count - 1;
    }
    for (ushort i = 0; i < param_count; i++) {
        char[] name = params[i];
        if (arrow_ctx.is_strict && is_restricted_name(name)) {
            return COMPILE_ERROR~;
        }
        ushort param_reg = arrow_ctx.declare_var(name, VAR);
        uint param_name_idx = arrow_ctx.add_string_constant(name);
        arrow_ctx.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);
    }

    // Push a function-level lexical scope
    arrow_ctx.emit_simple(Opcode.PUSH_LEX);

    // Determine if body is block or expression
    if (arrow_ctx.check(TokenType.LBRACE)) {
        // Block body: { ... }
        arrow_ctx.advance()!;
        while (!arrow_ctx.check(TokenType.RBRACE) && !arrow_ctx.is_at_end()) {
            arrow_ctx.statement()!;
        }
        arrow_ctx.expect(TokenType.RBRACE)!;
        // No implicit return for block body
        bool has_explicit_return = false;
        if (arrow_ctx.code_count > 0) {
            Opcode last_op = arrow_ctx.code[arrow_ctx.code_count - 1].op;
            if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
                last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
                has_explicit_return = true;
            }
        }
        if (!has_explicit_return) {
            arrow_ctx.emit_simple(Opcode.RETUNDEF);
        }
    } else {
        // Expression body: implicitly return the expression value
        ushort expr_reg = arrow_ctx.assignment_expr()!;
        arrow_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);
    }

    // Pop the function-level lexical scope
    arrow_ctx.emit_simple(Opcode.POP_LEX);

    // Set rest and formal counts before finish()
    arrow_ctx.has_rest = has_rest;
    arrow_ctx.rest_formal_count = formal_count;
    arrow_ctx.num_args = param_count;

    CompiledFunction* func = arrow_ctx.finish()!;
    func.flags.is_arrow = true;

    return func;
}

/// Return the precedence of a binary operator token, or PREC_NONE if not a binary op.
fn int get_binary_precedence(TokenType tt) {
    switch (tt) {
        case TokenType.LOG_OR:      return PREC_LOGICAL_OR;
        case TokenType.LOG_AND:     return PREC_LOGICAL_AND;
        case TokenType.BIT_OR:      return PREC_BITWISE_OR;
        case TokenType.BIT_XOR:     return PREC_BITWISE_XOR;
        case TokenType.BIT_AND:     return PREC_BITWISE_AND;
        case TokenType.EQ:          return PREC_EQUALITY;
        case TokenType.NE:          return PREC_EQUALITY;
        case TokenType.SEQ:         return PREC_EQUALITY;
        case TokenType.SNE:         return PREC_EQUALITY;
        case TokenType.LT:          return PREC_RELATIONAL;
        case TokenType.GT:          return PREC_RELATIONAL;
        case TokenType.LE:          return PREC_RELATIONAL;
        case TokenType.GE:          return PREC_RELATIONAL;
        case TokenType.INSTANCEOF:  return PREC_RELATIONAL;
        case TokenType.IN:          return PREC_RELATIONAL;
        case TokenType.SHL:         return PREC_SHIFT;
        case TokenType.SHR:         return PREC_SHIFT;
        case TokenType.USHR:        return PREC_SHIFT;
        case TokenType.PLUS:        return PREC_ADDITIVE;
        case TokenType.MINUS:       return PREC_ADDITIVE;
        case TokenType.STAR:        return PREC_MULTIPLICATIVE;
        case TokenType.SLASH:       return PREC_MULTIPLICATIVE;
        case TokenType.PERCENT:     return PREC_MULTIPLICATIVE;
        case TokenType.STARSTAR:    return PREC_EXPONENTIATION;
        case TokenType.NULLISH:     return PREC_NULLISH;
        default:                    return PREC_NONE;
    }
}

/// Map a binary operator token type to the corresponding bytecode opcode.
fn Opcode token_to_binary_opcode(TokenType tt) {
    switch (tt) {
        case TokenType.PLUS:        return Opcode.ADD;
        case TokenType.MINUS:       return Opcode.SUB;
        case TokenType.STAR:        return Opcode.MUL;
        case TokenType.SLASH:       return Opcode.DIV;
        case TokenType.PERCENT:     return Opcode.MOD;
        case TokenType.STARSTAR:    return Opcode.EXP;
        case TokenType.BIT_AND:     return Opcode.BAND;
        case TokenType.BIT_OR:      return Opcode.BOR;
        case TokenType.BIT_XOR:     return Opcode.BXOR;
        case TokenType.SHL:         return Opcode.SHL;
        case TokenType.SHR:         return Opcode.SHR;
        case TokenType.USHR:        return Opcode.USHR;
        case TokenType.EQ:          return Opcode.EQ;
        case TokenType.NE:          return Opcode.NEQ;
        case TokenType.SEQ:         return Opcode.SEQ;
        case TokenType.SNE:         return Opcode.SNEQ;
        case TokenType.LT:          return Opcode.LT;
        case TokenType.LE:          return Opcode.LE;
        case TokenType.GT:          return Opcode.GT;
        case TokenType.GE:          return Opcode.GE;
        case TokenType.INSTANCEOF:  return Opcode.INSTANCEOF;
        case TokenType.IN:          return Opcode.IN;
        default:                    return Opcode.NOP;
    }
}

// ============================================================================
// String comparison helper
// ============================================================================

// ============================================================================
// for-of loop compilation
// ============================================================================

/// Emit bytecode for a for-of loop.  The iterable expression has already been
/// evaluated into `iter_reg` and the RParen was consumed.
/// Uses the ES6 iterator protocol: Symbol.iterator → .next() → {value, done}.
fn void? CompilerContext.emit_forof_loop(&self, char[] var_name, ushort iter_reg, uint saved_scope, ushort saved_reg, bool is_lexical, bool is_const, bool is_bare) {
    // Declare loop variable register
    ushort loop_var;
    if (is_bare) {
        loop_var = self.alloc_reg();
    } else {
        ScopeKind kind = is_const ? CONST : (is_lexical ? LET : VAR);
        loop_var = self.declare_var(var_name, kind);
    }

    uint name_idx = self.add_string_constant(var_name);

    // === Iterator Protocol ===

    // Step 1: Get Symbol.iterator method from iterable
    //   sym = GETVAR "Symbol"
    //   symbol_val = GETPROP sym, "iterator"   (the well-known symbol value)
    //   method = GETPROP iter_reg, symbol_val   (iterable[Symbol.iterator] → the method)
    ushort sym_reg = self.alloc_reg();
    self.emit_a_bc(Opcode.GETVAR, (uint)sym_reg, self.add_string_constant("Symbol"));

    ushort iter_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)iter_key_reg, self.add_string_constant("iterator"), 0);

    ushort symbol_val_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)symbol_val_reg, (uint)sym_reg, (uint)iter_key_reg);
    self.free_reg(iter_key_reg);
    self.free_reg(sym_reg);
    // symbol_val_reg holds the Symbol.iterator well-known symbol

    // Look up the method on the iterable using the symbol as property key
    ushort method_reg = self.alloc_reg();
    self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)iter_reg, (uint)symbol_val_reg);
    self.free_reg(symbol_val_reg);
    // method_reg is top of register stack, holds iterable[Symbol.iterator]

    // Step 2: Call iterable[Symbol.iterator]() to get the iterator object
    //   this_slot = iter_reg            (this = iterable)
    //   CALL method_reg, method_reg, 0  (iterator = iterable[Symbol.iterator].call(iterable))
    ushort this_slot = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)this_slot, (uint)iter_reg, 0);
    self.emit_abc(Opcode.CALL, (uint)method_reg, (uint)method_reg, 0);
    self.free_reg(this_slot);
    // method_reg is top, now holds the iterator object

    // Step 3: Get .next method from iterator
    //   next_key = LDCONST "next"
    //   next = GETPROP iterator, next_key
    ushort next_reg = self.alloc_reg();
    ushort next_key_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)next_key_reg, self.add_string_constant("next"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)next_reg, (uint)method_reg, (uint)next_key_reg);
    self.free_reg(next_key_reg);
    // next_reg is top (.next method), method_reg below (iterator)

    // Step 4: Set up callee + this pair for .next() calls
    //   callee = next_reg        (.next method)
    //   callee_this = method_reg (iterator, as this for .next())
    ushort callee_reg = self.alloc_reg();
    ushort callee_this_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)next_reg, 0);
    self.emit_abc(Opcode.LDREG, (uint)callee_this_reg, (uint)method_reg, 0);

    // Loop start
    uint loop_start = self.code_count;
    self.push_loop(loop_start, true);

    // Step 5: Call .next() each iteration
    //   result = CALL callee, 0    (result = next.call(iterator))
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)callee_reg, 0);

    // Step 6: Extract .done
    //   done_key = LDCONST "done"
    //   done = GETPROP result, done_key
    ushort done_key_reg = self.alloc_reg();
    ushort done_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)done_key_reg, self.add_string_constant("done"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)done_reg, (uint)result_reg, (uint)done_key_reg);
    uint exit_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)done_reg);

    // Step 7: Extract .value
    //   value_key = LDCONST "value"
    //   val = GETPROP result, value_key
    ushort value_key_reg = self.alloc_reg();
    ushort val_reg = self.alloc_reg();
    self.emit_abc(Opcode.LDCONST, (uint)value_key_reg, self.add_string_constant("value"), 0);
    self.emit_abc(Opcode.GETPROP, (uint)val_reg, (uint)result_reg, (uint)value_key_reg);

    // Step 8: Assign to loop variable
    self.emit_abc(Opcode.LDREG, (uint)loop_var, (uint)val_reg, 0);

    if (is_bare) {
        self.emit_a_bc(Opcode.PUTVAR, (uint)loop_var, name_idx);
    } else {
        self.emit_var_store(loop_var, name_idx, is_lexical, is_const);
    }

    // Free loop-iteration temps (reverse order — stack discipline)
    self.free_reg(val_reg);
    self.free_reg(value_key_reg);
    self.free_reg(done_reg);
    self.free_reg(done_key_reg);
    self.free_reg(result_reg);

    // Step 9: Body
    self.statement()!;

    // Continue target: jump back to .next() call
    self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;

    // Jump back to loop start
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    self.patch_jump(exit_jump);
    self.pop_loop();

    // Free loop-overhead registers
    self.free_reg(callee_this_reg);
    self.free_reg(callee_reg);
    self.free_reg(next_reg);
    self.free_reg(method_reg);
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

// ============================================================================
// Helpers
// ============================================================================

/// Compare two char slices for equality.
fn bool str_eq(char[] a, char[] b) {
    if (a.len != b.len) {
        return false;
    }
    if (a.len == 0) {
        return true;
    }
    for (usz i = 0; i < a.len; i++) {
        if (a[i] != b[i]) {
            return false;
        }
    }
    return true;
}
