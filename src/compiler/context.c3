module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import libc;
import duktape::jit;
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
const uint MAX_CONST_HASH   = 1024;  // Open-addressing hash table for constant dedup
/// Insertion cap keeping at least 25% of slots empty so probes terminate early.
const uint MAX_CONST_HASH_FILL = MAX_CONST_HASH - MAX_CONST_HASH / 4;

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
    SCOPEMARK,   ///< boundary marker pushed by block() to delimit scope
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
    bool   has_default;
    ushort default_val_reg;  // register holding compiled default expression result
    bool   is_resolved;      // for assignment mode: was var resolved locally?
    bool   is_nested;        // true if this binding comes from a nested pattern
    uint   outer_idx;        // the index in the outer RHS array
    uint   inner_idx;        // the index within the nested sub-array
    uint   nest_depth;       // 1 = one level nested, 2 = two levels nested
    uint   depth2_idx;       // for nest_depth==2: index into 2nd-level array
    bool   is_obj_nested;    // true if nested pattern is an object
    uint   obj_key_idx;      // constant index of object property key (used when is_obj_nested)
}

/// Tracks a binding in an object destructuring pattern.
struct ObjBind {
    ushort reg;
    uint   name_idx;
    uint   key_idx;
    bool   has_default;
    ushort default_val_reg;  // register holding compiled default expression result
    bool   is_resolved;      // for assignment mode: was var resolved locally?
    bool   is_nested;
    uint   nested_key_idx;
    bool   is_array_nested;  // true if nested pattern is an array
    uint   arr_nested_idx;   // index within the nested array (used when is_array_nested)
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
    // Hash table for constant deduplication: maps TVal bits → constant index
    ConstHashEntry[MAX_CONST_HASH] const_hash;
    uint const_hash_count;

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
    ushort formal_count;        // params that count toward function.length
                                 // (= num_args, or count before first default/rest)

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

    // Closure tracking — set to true when a nested function is defined in
    // this function's body.  Combined with has_local_bindings to decide
    // needs_env: if the function has var bindings but no nested functions
    // that could capture them, the env can be skipped.
    bool has_closures;

    // Hoisted function declaration names (so main pass can skip recompilation).
    char[][16] hoisted_fn_names;
    ushort hoisted_fn_count;

    // Direct eval tracking — when true, the CALL path must create a fresh env.
    bool has_direct_eval;
    /// Set by primary_expr when the identifier "eval" is resolved; checked and
    /// cleared by emit_call to detect direct eval calls (eval(...) by name).
    bool callee_is_eval;

    // Arrow/async tracking — needed for needs_env computation in finish().
    bool is_arrow;
    bool is_async;

    // Module tracking — true when compiling an ESM module body.
    bool is_module;
    void* current_module;  // ModuleDef* (opaque to avoid import cycle)
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
    self.const_hash_count = 0;
    self.call_prop_obj_reg = MAX_REGISTERS;
    self.pushback_count = 0;

    // Strict-only engine: lexer always in strict mode (affects FutureReservedWord
    // keyword recognition — implements/interface/package/private/protected/public).
    self.lexer.set_strict(true);
}

/// Finalise compilation: allocate a CompiledFunction and copy code/constants.
fn CompiledFunction*? CompilerContext.finish(&self) {
    Heap* h = (Heap*)self.heap;
    // Allocate the CompiledFunction struct
    void* raw = h.alloc_func(h.heap_udata, CompiledFunction::size);
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
                        self.code[i + 1] = bytecode::make_a_bc(fused, reg_a, name0);
                        self.code[i + 2] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                    }
                }
            }
        }
    }

    // --- Peephole: fuse LDCONST rK, idx + GETPROP ra = rb, rK → NOP + GETPROPC ra = rb, idx ---
    // Saves 1 dispatch per property access.  The key constant-pool index is baked into
    // GETPROPC.c, so jumping into the NOP slot (if rK's LDCONST happened to be a jump
    // target) still produces correct results: NOP falls through to GETPROPC which reads
    // the index from the instruction itself, not from rK.
    // Condition: idx must fit in 8 bits (≤ 255) because GETPROPC.c is 8 bits.
    // Register safety: rK is the freshly-allocated key temp used only as GETPROP.c;
    // the two instructions are adjacent so no other use of rK can appear between them.
    if (self.code_count >= 2) {
        for (uint i = 0; i + 1 < self.code_count; i++) {
            if (self.code[i].op == Opcode.LDCONST && self.code[i + 1].op == Opcode.GETPROP) {
                uint rK = (uint)self.code[i].a;
                uint idx = self.code[i].get_bc();
                // rK must be the key operand of GETPROP, idx must fit in 8 bits,
                // and the constant must be a string (GETPROPC assumes string keys).
                if ((uint)self.code[i + 1].c == rK && idx <= 255 && self.constants[idx].is_string()) {
                    // Safety: rK must not be used by any later instruction.
                    // In LHS (assignment) mode the compiler keeps rK alive for the
                    // PUTPROP/DELPROP that follows (possibly with intervening instructions
                    // for the RHS).  Scan forward from i+2; if any instruction reads rK
                    // before a definite overwrite of rK, the LDCONST is load-bearing and
                    // we must not NOP it.
                    bool rK_used_after = false;
                    for (uint j = i + 2; j < self.code_count; j++) {
                        Instruction jns = self.code[j];
                        Opcode jop2 = jns.op;
                        OpFormat jfmt = bytecode::get_op_format(jop2);
                        // Only ABC-format opcodes have register operands in b and c.
                        // For A_BC (LDCONST, LDINT, GETVAR, PUTVAR, DECLVAR, ...),
                        // A_SBX (IF_TRUE, IF_FALSE, LDINT), and wide/no-operand formats,
                        // only field A is a register; the rest are immediate values or
                        // branch offsets and must NOT be misread as register references.
                        if (jfmt == bytecode::OpFormat.ABC) {
                            // IF_TRUE/IF_FALSE: field A is a READ, not a write.
                            if (jop2 == Opcode.IF_TRUE || jop2 == Opcode.IF_FALSE) {
                                if ((uint)jns.a == rK) { rK_used_after = true; break; }
                                continue;
                            }
                            // If rK is read as b or c (source operands), it's still live.
                            if ((uint)jns.b == rK || (uint)jns.c == rK) {
                                rK_used_after = true;
                                break;
                            }
                        }
                        // If rK is written (a is destination), it is no longer live.
                        // For A_BC/A_SBX/wide formats, A is the only register operand;
                        // for ABC, A is the destination (write) when not IF_TRUE/IF_FALSE.
                        if ((uint)jns.a == rK) { break; }
                    }
                    if (!rK_used_after) {
                        uint ra = (uint)self.code[i + 1].a;
                        uint rb = (uint)self.code[i + 1].b;
                        self.code[i]     = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                        self.code[i + 1] = bytecode::make_abc(Opcode.GETPROPC, ra, rb, idx);
                    }
                }
            }
        }
    }

    // --- Peephole: fuse LT/LE/GT/GE + IF_FALSE/IF_TRUE → JMP_NLT/NLE/NGT/NGE / JMP_LT/LE/GT/GE + NOP ---
    // Saves 1 dispatch and 1 boolean round-trip per loop condition.
    // Rules:
    //   1. code[i] is LT/LE/GT/GE; code[i+1] is IF_FALSE or IF_TRUE.
    //   2. The result register rA (written by compare, read by IF_FALSE/IF_TRUE) is dead after i+1.
    //   3. Slot i+1 (the branch) must NOT be a jump target — landing there after fusion
    //      would fall through the NOP without branching, which is wrong.
    //   4. The adjusted offset (sbx+1) must fit in a signed 8-bit field (-128..127).
    //      Offset math: IF_FALSE/IF_TRUE at slot i+1 reads sbx relative to curr_pc=i+2, landing at
    //      i+2+sbx.  Fused op at slot i has curr_pc=i+1, so fused_offset = (i+2+sbx)-(i+1)
    //      = sbx+1.
    //   Mapping: IF_FALSE → JMP_NLT/NLE/NGT/NGE (branch on false); IF_TRUE → JMP_LT/LE/GT/GE
    //   (branch on true).  Both variants are fully supported.
    if (self.code_count >= 2) {
        // Build a jump-target bit-set: mark every slot that is the destination of a branch.
        // We must NOT fuse when slot i+1 is a target.
        // Sources of static targets:
        //   JUMP (WIDE_SABC): offset = insn.get_sabc(), target = slot+1+offset
        //   IF_TRUE / IF_FALSE (A_SBX): offset = insn.get_sbc(), target = slot+1+offset
        //   TRY (A_BC): catch_offset = insn.get_bc(), target = slot + catch_offset
        //               also reads the adjacent jump-slot for finally_offset
        //   The fused JMP_N* ops added by this pass in the same run: they only appear
        //   in slot i (replacing the compare), never as new targets, so we don't need
        //   to worry about them here.
        bool[MAX_CODE] jump_targets;
        libc::memset(&jump_targets[0], 0, self.code_count);
        for (uint i = 0; i < self.code_count; i++) {
            Instruction ins = self.code[i];
            switch (ins.op) {
                case Opcode.JUMP:
                case Opcode.BREAK:
                case Opcode.CONTINUE: {
                    int off = ins.get_sabc();
                    int tgt = (int)i + 1 + off;
                    if (tgt >= 0 && (uint)tgt < self.code_count) {
                        jump_targets[tgt] = true;
                    }
                }
                case Opcode.IF_TRUE:
                case Opcode.IF_FALSE: {
                    int off = ins.get_sbc();
                    int tgt = (int)i + 1 + off;
                    if (tgt >= 0 && (uint)tgt < self.code_count) {
                        jump_targets[tgt] = true;
                    }
                }
                case Opcode.TRY: {
                    // TRY at slot i: catch target = i + catch_offset (get_bc())
                    // The adjacent instruction (i+1) holds finally_offset in its BC field.
                    uint catch_off = ins.get_bc();
                    uint catch_tgt = i + catch_off;
                    if (catch_tgt < self.code_count) {
                        jump_targets[catch_tgt] = true;
                    }
                    if (i + 1 < self.code_count) {
                        uint finally_off = self.code[i + 1].get_bc();
                        if (finally_off != 0) {
                            uint finally_tgt = i + finally_off;
                            if (finally_tgt < self.code_count) {
                                jump_targets[finally_tgt] = true;
                            }
                        }
                    }
                }
                default: {}
            }
        }

        for (uint i = 0; i + 1 < self.code_count; i++) {
            Opcode cmp_op = self.code[i].op;
            if (cmp_op != Opcode.LT && cmp_op != Opcode.LE
                && cmp_op != Opcode.GT && cmp_op != Opcode.GE) { continue; }
            bool is_if_false = (self.code[i + 1].op == Opcode.IF_FALSE);
            bool is_if_true  = (self.code[i + 1].op == Opcode.IF_TRUE);
            if (!is_if_false && !is_if_true) { continue; }

            // The compare writes rA; IF_FALSE reads rA via its .a field.
            uint rA = (uint)self.code[i].a;
            if ((uint)self.code[i + 1].a != rA) { continue; }

            // Rule 3: IF_FALSE slot must not be a jump target.
            if (jump_targets[i + 1]) { continue; }

            // Rule 2: rA must be dead on BOTH paths after fusion:
            //   (a) fall-through path: from slot i+2 onward — linear scan until rA is
            //       read (live) or overwritten (dead).
            //   (b) branch path: from target T = i+2+sbx — same linear scan.
            //       After fusion the compare instruction is gone, so when the branch fires
            //       rA was never written.  If T reads rA before overwriting it, the fusion
            //       would produce a stale value (e.g. old loop variable instead of 0/1).
            // IMPORTANT: only check b/c as register sources for ABC-format instructions.
            // For JUMP (WIDE_SABC), IF_FALSE/IF_TRUE (A_SBX), and A_BC ops, the b/c bits
            // encode offsets or packed values, not register indices — do not misread them.
            // Each scan is basic-block-local: stop (treat as live) at the first jump target
            // encountered (a new basic block begins — we cannot prove rA dead on all
            // incoming edges).
            int sbx = self.code[i + 1].get_sbc();
            int fused_off = sbx + 1;

            // (a) fall-through scan from i+2: check rA is dead on the sequential path.
            // At each jump target encountered, also verify rA is dead starting from
            // that target (a back-edge or cross-edge may arrive there without our
            // overwrites — if rA is already dead at the target regardless, it's fine).
            bool rA_live = false;
            for (uint j = i + 2; j < self.code_count; j++) {
                if (jump_targets[j]) {
                    // A path from outside arrives at j.  Check if rA is used at j
                    // (or shortly after) before being overwritten on that path.
                    // We do a quick single-instruction look at slot j.  If rA appears
                    // as a source operand there, treat rA as live; otherwise continue
                    // (a more thorough scan would recurse, but a one-instruction probe
                    // handles all common patterns: the INC/ADD that is a loop back-edge
                    // target never reads the compare-result register).
                    Instruction tgt_ins = self.code[j];
                    Opcode tgt_op = tgt_ins.op;
                    bool rA_at_tgt = false;
                    if (tgt_op == Opcode.IF_TRUE || tgt_op == Opcode.IF_FALSE) {
                        rA_at_tgt = ((uint)tgt_ins.a == rA);
                    } else {
                        OpFormat tfmt = bytecode::get_op_format(tgt_op);
                        if (tfmt == OpFormat.ABC) {
                            // GETPROPC: C = constant-pool index, not a register.
                            if (tgt_op == Opcode.GETPROPC) {
                                rA_at_tgt = ((uint)tgt_ins.b == rA);
                            } else {
                                rA_at_tgt = ((uint)tgt_ins.b == rA || (uint)tgt_ins.c == rA);
                            }
                        }
                    }
                    if (rA_at_tgt) { rA_live = true; break; }
                    // rA not read at j — continue the fall-through scan.
                    continue;
                }
                Instruction jns = self.code[j];
                Opcode jop2 = jns.op;
                // Terminal instructions end the fall-through basic block.
                if (jop2 == Opcode.RET || jop2 == Opcode.RETUNDEF
                    || jop2 == Opcode.RET_GEN || jop2 == Opcode.RETUNDEF_GEN
                    || jop2 == Opcode.THROW || jop2 == Opcode.JUMP) {
                    break;
                }
                OpFormat jfmt = bytecode::get_op_format(jop2);
                // IF_TRUE/IF_FALSE use field A as a source (the register being tested),
                // not as a destination.  Check them for reads.
                if (jop2 == Opcode.IF_TRUE || jop2 == Opcode.IF_FALSE) {
                    if ((uint)jns.a == rA) { rA_live = true; break; }
                    continue; // no overwrite possible from A_SBX branch ops
                }
                if (jfmt == OpFormat.ABC) {
                    // GETPROPC: C field is a constant-pool index, not a register.
                    // Only check B for register reads.
                    if (jop2 == Opcode.GETPROPC) {
                        if ((uint)jns.b == rA) { rA_live = true; break; }
                    } else {
                        if ((uint)jns.b == rA || (uint)jns.c == rA) { rA_live = true; break; }
                    }
                }
                // For non-WIDE_SABC/WIDE_ABC formats, field A is the destination (overwrite).
                if (jfmt != OpFormat.WIDE_SABC && jfmt != OpFormat.WIDE_ABC) {
                    if ((uint)jns.a == rA) { break; }
                }
            }
            if (rA_live) { continue; }

            // (b) branch-path scan from target T (= i+2+sbx)
            // After fusion the compare is gone; if the branch fires, rA was never written.
            // Verify rA is dead starting at T.
            //
            // Exception: when rA aliases a source operand (rA == rB or rA == rC),
            // the compare clobbers that operand, but after fusion the register retains
            // its pre-compare value — exactly what the branch target expects.
            // (Example: `LE r3, r3, r0` as a loop condition — r3 must survive as the
            // loop counter, and JMP_LE correctly preserves it.)
            uint rB = (uint)self.code[i].b;
            uint rC = (uint)self.code[i].c;
            bool ra_aliases_src = (rA == rB || rA == rC);
            if (!ra_aliases_src) {
                int tgt_raw = (int)i + 2 + sbx;
                if (tgt_raw >= 0 && (uint)tgt_raw < self.code_count) {
                    bool rA_live_branch = false;
                    for (uint j = (uint)tgt_raw; j < self.code_count; j++) {
                        // Skip jump-target check for slot T itself (it IS a target).
                        if (j != (uint)tgt_raw && jump_targets[j]) { rA_live_branch = true; break; }
                        Instruction jns = self.code[j];
                        Opcode jop2 = jns.op;
                        // Terminal instructions end the branch basic block.
                        if (jop2 == Opcode.RET || jop2 == Opcode.RETUNDEF
                            || jop2 == Opcode.RET_GEN || jop2 == Opcode.RETUNDEF_GEN
                            || jop2 == Opcode.THROW || jop2 == Opcode.JUMP) {
                            break;
                        }
                        OpFormat jfmt = bytecode::get_op_format(jop2);
                        if (jop2 == Opcode.IF_TRUE || jop2 == Opcode.IF_FALSE) {
                            if ((uint)jns.a == rA) { rA_live_branch = true; break; }
                            continue;
                        }
                        if (jfmt == OpFormat.ABC) {
                            // GETPROPC: C = constant-pool index, not a register.
                            if (jop2 == Opcode.GETPROPC) {
                                if ((uint)jns.b == rA) { rA_live_branch = true; break; }
                            } else {
                                if ((uint)jns.b == rA || (uint)jns.c == rA) { rA_live_branch = true; break; }
                            }
                        }
                        if (jfmt != OpFormat.WIDE_SABC && jfmt != OpFormat.WIDE_ABC) {
                            if ((uint)jns.a == rA) { break; }
                        }
                    }
                    if (rA_live_branch) { continue; }
                }
            }

            // Rule 4: adjusted offset must fit in signed 8 bits.
            // (sbx already computed above)
            if (fused_off < -128 || fused_off > 127) { continue; }

            // All checks passed — fuse.
            Opcode fused_op;
            if (is_if_false) {
                switch (cmp_op) {
                    case Opcode.LT: fused_op = Opcode.JMP_NLT;
                    case Opcode.LE: fused_op = Opcode.JMP_NLE;
                    case Opcode.GT: fused_op = Opcode.JMP_NGT;
                    default:        fused_op = Opcode.JMP_NGE;
                }
            } else {
                switch (cmp_op) {
                    case Opcode.LT: fused_op = Opcode.JMP_LT;
                    case Opcode.LE: fused_op = Opcode.JMP_LE;
                    case Opcode.GT: fused_op = Opcode.JMP_GT;
                    default:        fused_op = Opcode.JMP_GE;
                }
            }
            // Store signed offset as unsigned 8-bit in field A.
            self.code[i]     = bytecode::make_abc(fused_op, (uint)(char)fused_off, rB, rC);
            self.code[i + 1] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        }
    }

    // --- Peephole: copy propagation — NOP LDREG rT = rS when immediately followed
    // by a consumer that reads rT as a plain register operand (b or c), rT is dead
    // after the consumer, and rS is not clobbered between them (trivially true since
    // they are adjacent).
    //
    // Supported consumers: JMP_NLT/NLE/NGT/NGE (b/c = register operands),
    //   LT/LE/GT/GE/ADD/SUB/MUL (b/c = register operands in ABC format).
    // GETPROPC is excluded: its c field is a constant-pool index, not a register.
    //
    // Jump-target safety:
    //   - If the LDREG slot is a jump target it becomes a NOP; control falls through
    //     to the consumer which now reads rS directly — correct.
    //   - If the consumer slot is a jump target, a jump landing there would have
    //     expected rT to be loaded.  After substitution the consumer reads rS instead.
    //     rS is the source register (the actual variable), so it still holds the
    //     expected value — correct.
    //   Therefore no jump-target guard is needed for either slot.
    if (self.code_count >= 2) {
        for (uint i = 0; i + 1 < self.code_count; i++) {
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
            // immediately overwritten by the consumer — no scan needed, rT is dead.
            // Note: IF_TRUE/IF_FALSE use field A as a READ (not a write) — handle them
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
    }

    // --- Peephole: NOP dead LDREG rT = rX immediately before INC/DEC rX (or INC_VAR/DEC_VAR) ---
    // Pattern: LDREG rT = rX / INC rX  (postfix i++ in statement position)
    //   → NOP / INC rX
    // The saved value rT is never read — the postfix result is discarded when i++ appears
    // in the for-update slot or as an expression statement.  We verify rT is dead by
    // scanning forward from i+2; if rT never appears as a source (b or c in ABC format)
    // before being overwritten (written as a), it is dead and the LDREG is safe to NOP.
    // Jump-target safety: it is fine to NOP a LDREG that is itself a jump target — the
    // NOP simply falls through to the INC, which is the behaviour we want.
    if (self.code_count >= 2) {
        for (uint i = 0; i + 1 < self.code_count; i++) {
            if (self.code[i].op != Opcode.LDREG) { continue; }
            Opcode next_op = self.code[i + 1].op;
            bool next_is_inc_dec = (next_op == Opcode.INC || next_op == Opcode.DEC
                                    || next_op == Opcode.INC_VAR || next_op == Opcode.DEC_VAR);
            if (!next_is_inc_dec) { continue; }

            uint rT = (uint)self.code[i].a;   // destination of LDREG (the saved value)
            uint rX = (uint)self.code[i].b;   // source of LDREG (the variable)

            // For INC/DEC the operand is in field a; for INC_VAR/DEC_VAR the name idx
            // is in bc and a is 0 — rX must match either way.
            if (next_op == Opcode.INC || next_op == Opcode.DEC) {
                if ((uint)self.code[i + 1].a != rX) { continue; }
            }
            // (For INC_VAR/DEC_VAR we can't directly verify the variable register here,
            //  but in postfix_expr the INC_VAR is only emitted when lhs_was_getvar, and
            //  the LDREG immediately precedes it — the pair is always a unit.)

            // rT must be dead: scan forward from i+2.
            // IF_TRUE/IF_FALSE use field A as a READ — handle them explicitly.
            bool rT_live = false;
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
            if (rT_live) { continue; }

            self.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
        }
    }

    // --- NOP Compaction Pass ---
    // Physically remove NOP instructions and remap all pc-relative offsets.
    // Must run last, after all other peepholes have introduced NOPs.
    //
    // TRY jump slots: TRY is always followed by a NOP whose BC field holds the
    // finally_offset.  The VM unconditionally reads and advances past this word,
    // so it must be preserved even after compaction.  We mark those slots in
    // `keep[]` before building the pc_map.
    if (self.code_count > 0) {
        // Step 1: mark TRY jump slots as non-removable.
        bool[MAX_CODE] nop_keep;
        libc::memset(&nop_keep[0], 0, self.code_count);
        for (uint i = 0; i < self.code_count; i++) {
            if (self.code[i].op == Opcode.TRY && i + 1 < self.code_count) {
                nop_keep[i + 1] = true;
            }
        }

        // Step 2: build pc_map[old_pc] → new_pc.
        // NOP slots that are not kept map to the new_pc of the next kept slot.
        uint[MAX_CODE + 1] pc_map;
        uint new_count = 0;
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
                case Opcode.JMP_GE: {
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

        // Step 4: copy compacted instruction stream (skip non-kept NOPs).
        usz code_bytes = (usz)new_count * Instruction::size;
        void* code_raw = h.alloc_func(h.heap_udata, code_bytes);
        if (code_raw == null) {
            h.free_func(h.heap_udata, raw);
            return COMPILE_ERROR~;
        }
        Instruction* dst_code = (Instruction*)code_raw;
        uint dst_idx = 0;
        for (uint i = 0; i < self.code_count; i++) {
            if (self.code[i].op != Opcode.NOP || nop_keep[i]) {
                dst_code[dst_idx++] = self.code[i];
            }
        }
        func.code = dst_code;
        func.code_count = new_count;
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
        libc::memcpy(const_raw, &self.constants[0], const_bytes);
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
        libc::memcpy(inner_raw, &self.inner_funcs[0], inner_bytes);
        func.inner_funcs = (CompiledFunction**)inner_raw;
        func.inner_count = self.inner_func_count;
    }

    func.num_regs = self.max_reg;
    func.flags.has_rest = self.has_rest;
    func.flags.is_constructable = self.is_constructable;
    func.flags.is_generator = self.is_generator;
    func.flags.is_async = self.is_async;
    func.flags.uses_arguments = self.uses_arguments;

    // `needs_env` controls whether the CALL fast path allocates a fresh
    // env record + bindings object per call (2 allocations).  We only need
    // a fresh env when the function's scope is actually accessed at runtime:
    //   - var bindings captured by a nested closure
    //   - arguments object
    //   - direct eval
    // Functions with var declarations but no closures, eval, or arguments
    // can reuse the parent's env directly.
    bool has_params_needing_env = self.has_rest || self.default_count > 0;
    bool needs_runtime_env = ((self.has_local_bindings || self.num_args > 0) && self.has_closures)
                          || self.uses_arguments
                          || self.has_direct_eval;
    bool can_skip_env = !needs_runtime_env
                     && !has_params_needing_env
                     && !self.is_arrow
                     && !self.is_generator
                     && !self.is_async;
    func.flags.needs_env = !can_skip_env;
    func.flags.is_global = self.is_global;
    func.num_args = self.num_args;
    if (self.has_rest) {
        func.num_formals = self.rest_formal_count;
    } else if (self.default_count > 0) {
        // First default param doesn't count toward .length; formals before it do.
        func.num_formals = self.formal_count;
    } else {
        func.num_formals = self.num_args;
    }

    // Allocate Inline Cache array — one entry per instruction, zeroed.
    if (func.code_count > 0) {
        usz ic_bytes = (usz)func.code_count * hobject::ICEntry::size;
        void* ic_raw = h.alloc_func(h.heap_udata, ic_bytes);
        if (ic_raw != null) {
            libc::memset(ic_raw, 0, ic_bytes);
            func.ic_entries = ic_raw;
            func.ic_count = func.code_count;
        }

        // Allocate Variable IC array — one entry per instruction, zeroed.
        usz vic_bytes = (usz)func.code_count * hobject::VarICEntry::size;
        void* vic_raw = h.alloc_func(h.heap_udata, vic_bytes);
        if (vic_raw != null) {
            libc::memset(vic_raw, 0, vic_bytes);
            func.var_ic_entries = vic_raw;
            func.var_ic_count = func.code_count;
        }
    }

    // Track the CompiledFunction for cleanup when the heap is destroyed
    heap::Heap* hp = (heap::Heap*)self.heap;
    hp.track_compiled_func(raw);

    // Run JIT optimizations (GETPROPC2 chain fusion, etc.)
    jit::jit_scan(func, hp);

    return func;
}

/// Maximum number of lexical declarations in a single pre-scan pass.
const uint MAX_PRESCAN_NAMES = 64;

/// Stores the position and length of a variable name in the source text.
struct NameSpan {
    uint pos;   // byte offset into the source buffer
    uint len;   // length in bytes
}

const uint MAX_CLASS_METHODS = 32;

struct ClassMethod {
    char[] name;
    uint   inner_idx;
    bool   is_static;
    bool   is_getter;
    bool   is_setter;
    uint   computed_key_inner_idx;  // MAX_INNER_FUNCS = not computed
}
