/// Duktape bytecode definitions — instruction encoding, opcodes, and compiled
/// function representation.
///
/// Duktape uses a register-based virtual machine with fixed-width 32-bit
/// instructions.  Each instruction packs an 8-bit opcode and up to three
/// operand fields into a single `uint`:
///
///   ```
///   31       24 23       16 15        8 7         0
///   +---------+-----------+-----------+-----------+
///   |    C    |     B     |     A     |  opcode   |
///   +---------+-----------+-----------+-----------+
///   ```
///
/// Alternative operand layouts share the same 32 bits:
///
///   - **A-BC** : A (8 bits, 8–15) + BC (16 bits, 16–31)
///   - **ABC**  : full 24-bit operand (bits 8–31)
///   - **A-sBx**: A (8 bits) + signed Bx (16 bits, bias-encoded)
///   - **sABC** : signed 24-bit operand (bias-encoded)
///
/// The `Instruction` bitstruct provides both direct field access and
/// convenience methods for every layout.
module duktape::bytecode;

import duktape::types;
import duktape::hobject;

// ============================================================================
// Constants
// ============================================================================

/// Bias applied to a 16-bit signed operand so it can be stored unsigned.
/// Value range: -(2^15) .. +(2^15 - 1)  →  stored as 0 .. 65535.
const uint BC_BIAS  = 0x8000;

/// Bias applied to a 24-bit signed operand.
/// Value range: -(2^23) .. +(2^23 - 1)  →  stored as 0 .. 16777215.
const uint ABC_BIAS = 0x80_0000;

/// Maximum unsigned value that fits in the 8-bit A, B, or C fields.
const uint MAX_A  = 0xFF;
const uint MAX_B  = 0xFF;
const uint MAX_C  = 0xFF;

/// Maximum unsigned value for the 16-bit BC combined field.
const uint MAX_BC  = 0xFFFF;

/// Maximum unsigned value for the 24-bit ABC combined field.
const uint MAX_ABC = 0xFF_FFFF;

/// Maximum positive signed BC value (after removing bias).
const int  MAX_SBC  = 0x7FFF;
/// Minimum (most-negative) signed BC value.
const int  MIN_SBC  = -0x8000;

/// Maximum positive signed ABC value.
const int  MAX_SABC = 0x7F_FFFF;
/// Minimum (most-negative) signed ABC value.
const int  MIN_SABC = -0x80_0000;

// ============================================================================
// Opcode — all virtual-machine operations
// ============================================================================

/// Bytecode operation codes.
///
/// Each opcode is 8 bits wide, giving 256 possible operations.  The enum
/// values are arranged in logical groups: load/store, arithmetic, unary,
/// bitwise, comparison, control flow, property access, object creation,
/// function calls, variable access, closures, iterators, exception
/// handling, and miscellaneous.
enum Opcode : char {
    // ---- Load / Store ----------------------------------------------------

    /// `A = reg[B]`  — register-to-register copy.
    LDREG,
    /// `A = constants[BC]`  — load from the constant pool (A-BC format).
    LDCONST,
    /// `A = (int)sBx`  — load a signed 16-bit immediate (A-sBx format).
    LDINT,
    /// `A = (A << 16) | BC`  — extend a previously loaded integer with
    /// the low 16 bits (A-BC format).
    LDINTX,
    /// `A = undefined`.
    LDUNDEF,
    /// `A = null`.
    LDNULL,
    /// `A = true`.
    LDTRUE,
    /// `A = false`.
    LDFALSE,
    /// `A = this`  — load the current `this` binding.
    LDTHIS,

    // ---- Arithmetic (A = B op C) -----------------------------------------

    /// `A = B + C`.
    ADD,
    /// `A = B - C`.
    SUB,
    /// `A = B * C`.
    MUL,
    /// `A = B / C`.
    DIV,
    /// `A = B % C`.
    MOD,
    /// `A = B ** C`  — exponentiation.
    EXP,

    // ---- Unary (A = op B) ------------------------------------------------

    /// `A = +B`  — unary plus (ToNumber coercion).
    UNP,
    /// `A = -B`  — unary minus.
    UNM,
    /// `A = ~B`  — bitwise NOT.
    BNOT,
    /// `A = !B`  — logical NOT.
    LNOT,
    /// `A = typeof B`.
    TYPEOF,
    /// `A = void B`  — always produces `undefined`.
    VOID,

    // ---- Bitwise (A = B op C) --------------------------------------------

    /// `A = B & C`  — bitwise AND.
    BAND,
    /// `A = B | C`  — bitwise OR.
    BOR,
    /// `A = B ^ C`  — bitwise XOR.
    BXOR,
    /// `A = B << C`  — left shift.
    SHL,
    /// `A = B >> C`  — signed right shift.
    SHR,
    /// `A = B >>> C`  — unsigned right shift.
    USHR,

    // ---- Comparison (A = B op C) -----------------------------------------

    /// `A = (B == C)`  — abstract equality.
    EQ,
    /// `A = (B != C)`  — abstract inequality.
    NEQ,
    /// `A = (B === C)`  — strict equality.
    SEQ,
    /// `A = (B !== C)`  — strict inequality.
    SNEQ,
    /// `A = (B < C)`.
    LT,
    /// `A = (B <= C)`.
    LE,
    /// `A = (B > C)`.
    GT,
    /// `A = (B >= C)`.
    GE,
    /// `A = (B instanceof C)`.
    INSTANCEOF,
    /// `A = (B in C)`.
    IN,

    // ---- Control flow ----------------------------------------------------

    /// `PC += sABC`  — unconditional relative jump (signed 24-bit offset,
    /// sABC format).
    JUMP,
    /// `if (A) PC += sBC`  — branch when truthy (A-sBx format).
    IF_TRUE,
    /// `if (!A) PC += sBC`  — branch when falsy (A-sBx format).
    IF_FALSE,

    // ---- Property access -------------------------------------------------

    /// `A = B[C]`  — get property.
    GETPROP,
    /// `A = B[K]`  — get property with constant pool key.  Fused LDCONST+GETPROP.
    /// Format ABC: A = dst reg, B = obj reg, C = constant-pool index of property key string.
    GETPROPC,
    /// `A[B] = C`  — put (set) property.
    PUTPROP,
    /// `A = delete B[C]`  — delete property.
    DELPROP,

    // ---- Object / Array creation -----------------------------------------

    /// `A = {}`  — create a new empty plain object.
    NEWOBJ,
    /// `A = []`  — create a new empty array.
    NEWARR,
    /// Set array length: `A.length = BC` (A-BC format).
    SETALEN,

    // ---- Function calls --------------------------------------------------

    /// `A = B(C..C+N)`  — function call.  A = result register,
    /// B = callee register, C = argument count.
    /// Value stack: valstack[B] = callee, valstack[B+1..B+C] = args.
    /// After call: valstack[A] = return value.
    CALL,
    /// `A = B.C(...)`  — method call (receiver is B).
    CALL_PROP,
    /// `A = new B(C...)`  — constructor invocation.
    NEW_OBJ,
    /// Tail-call optimisation: reuses the current stack frame.
    TAILCALL,
    /// `return A`  — return register A's value.
    RET,
    /// `return undefined`  — implicit return.
    RETUNDEF,

    // ---- Variable access -------------------------------------------------

    /// `A = variable[constants[BC]]`  — read a variable by name
    /// looked up in the constant pool (A-BC format).
    GETVAR,
    /// `variable[constants[BC]] = A`  — write a variable by name (A-BC).
    PUTVAR,
    /// `declare variable[constants[BC]] = A`  — declare+initialize a `var` in
    /// the immediate var_env only (does not walk the scope chain).
    DECLVAR,
    /// `A = typeof identifier`  — typeof on a variable name (A-BC format).
    /// Returns "undefined" for unresolvable references per ES5 §11.4.3.
    TYPEOFIDENT,
    /// `A = delete variable[constants[BC]]`  — delete a variable (A-BC).
    DELVAR,

    // ---- Closures --------------------------------------------------------

    /// `A = create_closure(inner_funcs[BC])`  — instantiate an inner
    /// function template as a closure (A-BC format).
    CLOSURE,
    /// `A = outer_scope[BC]`  — read a captured (bound) variable from an
    /// enclosing scope (A-BC format).
    GETBOUND,

    // ---- Iterator / for-in -----------------------------------------------

    /// Initialise a for-in iterator over object A.  B = iterator state
    /// register.
    INITFOR,
    /// `A = next key, B = has_next`  — advance the for-in iterator.
    NEXTFOR,

    // ---- Exception handling ----------------------------------------------

    /// Push a try block; the catch handler is at `PC + BC` (A-BC format).
    TRY,
    /// Pop the current try block.
    ENDTRY,
    /// `throw A`  — throw an exception.
    THROW,
    /// `A = <caught exception>`  — store the caught value.
    CATCH,
    /// Enter the finally block.
    FINALLY,
    /// Exit the finally block (may re-throw or continue).
    ENDFINALLY,

    // ---- Miscellaneous ---------------------------------------------------

    /// No operation.
    NOP,
    /// Trigger a debugger breakpoint.
    DEBUGGER,
    /// `PC += sABC`  — unconditional relative jump for `break` out of
    /// a loop/switch.  Like JUMP but the VM intercepts it when crossing
    /// a try-finally boundary to execute the finally block first.
    BREAK,
    /// `PC += sABC`  — unconditional relative jump for `continue`.
    /// Like JUMP but the VM intercepts it when crossing a try-finally
    /// boundary to execute the finally block first.
    CONTINUE,

    // ---- Special property initialisation ----------------------------------

    /// `A[B] = C`  — initialise a data property without triggering setters.
    INITSET,
    /// Define getter: `Object.defineProperty(A, B, {get: C})`.
    INITGET,
    /// Define setter: `Object.defineProperty(A, B, {set: C})`.
    INITSETI,
    /// Create the `arguments` exotic object for the current activation.
    CSVARI,

    // ---- with statement REMOVED in strict-only mode -----------------------

    // ---- Lexical scoping (let/const) ----------------------------------

    /// Push a new declarative environment record onto `act.lex_env`.
    /// Used at block/function entry to create a lexical scope for
    /// `let` and `const` declarations.
    PUSH_LEX,
    /// Pop the current lexical environment record from `act.lex_env`,
    /// restoring the parent.  Used at block exit.
    POP_LEX,
    /// `lex_env[constants[BC]] = A`  — write a binding into the current
    /// lexical environment (for `let` declarations).  A-BC format.
    PUTLEX,
    /// `lex_env[constants[BC]] = A`  — write a non-writable binding into
    /// the current lexical environment (for `const` declarations).  A-BC format.
    PUTLEX_C,
    /// `lex_env[constants[BC]] = TDZ_SENTINEL` — store the temporal dead zone
    /// sentinel for the variable named by constants[BC] into the current
    /// lexical environment.  Used at block entry to mark `let`/`const`
    /// bindings as uninitialized before their declaration is reached.
    INITTZ,

    /// `A = create_regexp(constants[BC])` — compile a regexp literal
    /// from the raw `/pattern/flags` string stored at constant pool index BC.
    /// Creates a new HObject of class REGEXP with compiled regexp data.
    NEWREGEXP,

    // ---- Spread operator (ES6) -------------------------------------------

    /// `A[B] = spread(C)` — spread elements of array C into target array A
    /// starting at index B.  B is incremented by the number of elements.
    /// ABC format: A=target_arr_reg, B=idx_reg, C=source_reg.
    ARRSPRD,
    /// Spread elements of array C into registers starting at A.
    /// Count written to register B.  ABC format.
    SPREAD_ARG,
    /// `A = call B with nargs from valstack[C]` — function call with
    /// runtime argument count (for spread arguments).
    /// ABC format: A=result_reg, B=callee_reg, C=nargs_reg.
    CALL_S,
    /// `A = spread(C) into object` — copy all own enumerable properties
    /// from source C into target object A.  null/undefined sources are
    /// silently skipped (as in Object.assign).  ABC format:
    /// A=target_obj_reg, B=0 (unused), C=source_reg.
    OBJSPRD,

    // ---- ES6 Classes -----------------------------------------------------

    /// `A.[[Prototype]] = B` — set the internal [[Prototype]] of object A
    /// to object B (used for `extends` to set `Derived.prototype.__proto__`).
    /// ABC format: A=derived_obj_reg, B=proto_reg.
    SETPROTO,
    /// `A = super(B, C..C+N)` — call superclass constructor.
    /// Uses the current activation's `new.target` as the new object's constructor.
    /// ABC format: A=result_reg, B=super_ctor_reg, C=arg_count.
    SUPER_CALL,
    /// `A = super(B, args[C..])` — same as SUPER_CALL but C is a register
    /// holding the runtime argument count (for spread arguments in default
    /// constructors).  ABC format: A=result_reg, B=super_ctor_reg, C=nargs_reg.
    SUPER_CALL_S,
    /// `A = new.target` — load `new.target` into register A.
    /// Returns undefined if not in a constructor call.
    /// A-only format: A=result_reg, B=0, C=0.
    NEWTARGET,

    // ---- Generators (ES6) ------------------------------------------------

    /// `A = load_resume` — load the value passed to .next() into A.
    /// Emitted by the compiler after every YIELD instruction so that the
    /// yield expression evaluates to the value the caller passed to .next(val).
    /// ABC format: A=result_reg, B=0, C=0.
    LOAD_RESUME,

    /// `yield A` — suspend generator execution and return the value in A.
    /// YIELD saves the current activation state (registers, PC, environments)
    /// to the generator object and returns {value: A, done: false} to the
    /// caller of .next()/.throw()/.return().
    /// ABC format: A=value_reg, B=0, C=0.
    YIELD,

    /// `A = yield* B` — delegate to another generator/iterable.
    /// ABC format: A=result_reg, B=iterable_reg, C=0.
    YIELD_STAR,

    /// `return A` from a generator — marks generator as completed,
    /// wraps result in IteratorResult, and returns.
    /// Same encoding as RET (ABC format).
    RET_GEN,
    /// `return undefined` from a generator.
    /// Same encoding as RETUNDEF (NONE format).
    RETUNDEF_GEN,

    /// `await A` — suspend async function at a thenable value.
    /// Saves register state, enqueues a resume callback via the thenable's
    /// `.then()`, and pops the activation.  The resume callback re-enters
    /// the function at the next instruction (LOAD_RESUME) with the settled value.
    /// ABC format: A=value_reg, B=0, C=0.
    AWAIT,

    // ---- Fastint arithmetic fusion ----------------------------------------

    /// `A = A + 1` (in-place fastint increment). Hot loop counter idiom.
    /// Falls back to `A = A + 1` general path if A is not a fastint.
    /// A-only format: A=target_reg, B=0, C=0.
    INC,
    /// `A = A - 1` (in-place fastint decrement).
    /// A-only format: A=target_reg, B=0, C=0.
    DEC,

    // ---- Variable arithmetic fusion ---------------------------------------

    /// `variable[constants[BC]] = variable[constants[BC]] + 1` — fused
    /// GETVAR + INC + PUTVAR.  Reads a variable by name, increments it,
    /// and writes it back in a single dispatch.  Uses the VarIC for both
    /// read and write.  A-BC format: A=0 (unused), BC=constant pool index.
    INC_VAR,
    /// `variable[constants[BC]] = variable[constants[BC]] - 1` — fused
    /// GETVAR + DEC + PUTVAR.  Same layout as INC_VAR.
    DEC_VAR,

    // ---- Fused compare-and-branch -------------------------------------------

    /// Fused `LT rB, rC` + `IF_FALSE`: branch if NOT (rB < rC).
    /// Format ABC: A = signed 8-bit jump offset (cast via char), B/C = comparison registers.
    /// Offset relative to the instruction after this one (same convention as IF_FALSE).
    /// NaN semantics: !(NaN < x) is true, so the branch IS taken when either operand is NaN.
    JMP_NLT,
    /// Fused `LE rB, rC` + `IF_FALSE`: branch if NOT (rB <= rC).
    JMP_NLE,
    /// Fused `GT rB, rC` + `IF_FALSE`: branch if NOT (rB > rC).
    JMP_NGT,
    /// Fused `GE rB, rC` + `IF_FALSE`: branch if NOT (rB >= rC).
    JMP_NGE,

    // ---- Fused compare-and-branch (branch if TRUE) ---------------------------

    /// Fused `LT rB, rC` + `IF_TRUE`: branch if (rB < rC) is TRUE.
    /// Format ABC: A = signed 8-bit jump offset (cast via char), B/C = comparison registers.
    /// Offset relative to the instruction after this one (same convention as JMP_NLT).
    /// NaN semantics: (NaN < x) is false → no branch taken when either operand is NaN.
    JMP_LT,
    /// Fused `LE rB, rC` + `IF_TRUE`: branch if (rB <= rC) is TRUE.
    JMP_LE,
    /// Fused `GT rB, rC` + `IF_TRUE`: branch if (rB > rC) is TRUE.
    JMP_GT,
    /// Fused `GE rB, rC` + `IF_TRUE`: branch if (rB >= rC) is TRUE.
    JMP_GE,

    /// Fused two-hop property access: A=dst_temp, B=src, C=key1_const_idx.
    /// The second key and final register are stored in the NEXT instruction slot (which becomes NOP).
    /// Format: insn[i]  = GETPROPC2 A=dst_temp, B=src, C=key1
    ///         insn[i+1] = (data: A=dst_final, C=key2, repurposed as storage)
    GETPROPC2,

    /// Specialized GETPROPC: IC is known-warm. Skips ic_base null check and
    /// key comparison. Falls back to GETPROPC if shape_id or prop_alloc changed.
    GETPROPC_CACHED,

    /// Require that the value in register A is coercible to object (not null
    /// or undefined).  Throws TypeError if the value is null or undefined.
    /// Used for destructuring binding patterns.
    REQUIRE_OBJ,

    /// Sentinel — not a real opcode; marks the end of the enum.
    LAST_OP,
}

// ============================================================================
// Opcode metadata
// ============================================================================

/// Describes which operand layout an opcode uses.
enum OpFormat : char {
    /// Standard A, B, C  (three 8-bit operands).
    ABC,
    /// A (8-bit) + BC (16-bit unsigned combined).
    A_BC,
    /// A (8-bit) + sBx (16-bit signed / bias-encoded).
    A_SBX,
    /// Full 24-bit unsigned operand (bits 8–31).
    WIDE_ABC,
    /// Full 24-bit signed operand (bias-encoded).
    WIDE_SABC,
    /// No operands (opcode-only).
    NONE,
}

/// Return the operand format for a given opcode.
fn OpFormat get_op_format(Opcode op) {
    switch (op) {
        // A-BC format (16-bit combined second operand)
        case LDCONST:   return A_BC;
        case LDINTX:    return A_BC;
        case SETALEN:   return A_BC;
        case GETVAR:    return A_BC;
        case TYPEOFIDENT: return A_BC;
        case PUTVAR:    return A_BC;
        case DECLVAR:   return A_BC;
        case DELVAR:    return A_BC;
        case CLOSURE:   return A_BC;
        case GETBOUND:  return A_BC;
        case TRY:       return A_BC;
        case BREAK:     return WIDE_SABC;
        case CONTINUE:  return WIDE_SABC;
case PUTLEX:     return A_BC;
        case PUTLEX_C:   return A_BC;
        case INITTZ:     return A_BC;
        case NEWREGEXP:  return A_BC;
        case ARRSPRD:    return ABC;
        case SPREAD_ARG: return ABC;
        case CALL_S:     return ABC;
        case OBJSPRD:    return ABC;
        case SETPROTO:   return ABC;
        case SUPER_CALL: return ABC;
        case SUPER_CALL_S: return ABC;
        case NEWTARGET:  return ABC;

        case LOAD_RESUME:  return ABC;
        case YIELD:      return ABC;
        case YIELD_STAR: return ABC;
        case GETPROPC_CACHED: return ABC;

        // A-sBx format (signed 16-bit second operand)
        case LDINT:     return A_SBX;
        case IF_TRUE:   return A_SBX;
        case IF_FALSE:  return A_SBX;

        // Full signed 24-bit
        case JUMP:      return WIDE_SABC;

        // No operands
        case NOP:       return NONE;
        case RETUNDEF:  return NONE;
        case RETUNDEF_GEN: return NONE;
        case AWAIT:     return ABC;
        case DEBUGGER:  return NONE;
        case ENDTRY:    return NONE;
        case ENDFINALLY: return NONE;
        case PUSH_LEX:   return NONE;
        case POP_LEX:    return NONE;
        case INC:        return NONE;
        case DEC:        return NONE;
        case INC_VAR:    return A_BC;
        case DEC_VAR:    return A_BC;
        case GETPROPC2:  return ABC;
        case REQUIRE_OBJ: return ABC;

        // Everything else: standard A, B, C
        default:        return ABC;
    }
}

// ============================================================================
// Instruction — the 32-bit encoded instruction word
// ============================================================================

/// A single 32-bit bytecode instruction.
///
/// The bitstruct provides named access to the four 8-bit fields.  Higher-
/// level layouts (A-BC, ABC, A-sBx, sABC) are accessed through methods.
bitstruct Instruction : uint {
    /// Opcode (bits 0–7).
    Opcode op  : 0..7;
    /// A operand — usually the destination register (bits 8–15).
    uint   a   : 8..15;
    /// B operand — source register or constant index (bits 16–23).
    uint   b   : 16..23;
    /// C operand — source register or constant index (bits 24–31).
    uint   c   : 24..31;
}

// ============================================================================
// Instruction — static constructors
// ============================================================================

/// Encode an instruction in standard A-B-C format.
///
/// All three operands are 8 bits wide.
fn Instruction make_abc(Opcode op, uint a, uint b, uint c) {
    return {
        .op = op,
        .a  = a & MAX_A,
        .b  = b & MAX_B,
        .c  = c & MAX_C,
    };
}

/// Encode an instruction in A-BC format.
///
/// A is 8 bits; BC is a 16-bit unsigned value split across the B and C
/// fields (B = low byte, C = high byte of BC).
fn Instruction make_a_bc(Opcode op, uint a, uint bc) {
    return {
        .op = op,
        .a  = a & MAX_A,
        .b  = bc & 0xFF,
        .c  = (bc >> 8) & 0xFF,
    };
}

/// Encode an instruction in the wide ABC format.
///
/// The full 24-bit unsigned operand occupies bits 8–31 (A, B, C fields
/// concatenated).  A = bits 8–15, B = bits 16–23, C = bits 24–31.
fn Instruction make_abc_wide(Opcode op, uint abc) {
    return {
        .op = op,
        .a  = abc & 0xFF,
        .b  = (abc >> 8) & 0xFF,
        .c  = (abc >> 16) & 0xFF,
    };
}

/// Encode an instruction in A-sBx format.
///
/// A is 8 bits; sBx is a signed 16-bit value stored with a bias so that
/// the raw bits are always non-negative.
fn Instruction make_a_sbx(Opcode op, uint a, int sbx) {
    uint bc = (uint)(sbx + (int)BC_BIAS);
    return make_a_bc(op, a, bc);
}

/// Encode an instruction in the signed wide sABC format.
///
/// sABC is a signed 24-bit value stored with a bias.
fn Instruction make_sabc(Opcode op, int sabc) {
    uint abc = (uint)(sabc + (int)ABC_BIAS);
    return make_abc_wide(op, abc);
}

// ============================================================================
// Instruction — field accessors
// ============================================================================

/// Returns the opcode.
macro Opcode Instruction.get_op(&self) {
    return self.op;
}

/// Returns the 8-bit A operand.
macro uint Instruction.get_a(&self) {
    return self.a;
}

/// Returns the 8-bit B operand.
macro uint Instruction.get_b(&self) {
    return self.b;
}

/// Returns the 8-bit C operand.
macro uint Instruction.get_c(&self) {
    return self.c;
}

/// Returns the 16-bit unsigned BC combined operand.
///
/// B is the low byte, C is the high byte:  `BC = C << 8 | B`.
macro uint Instruction.get_bc(&self) {
    return ((uint)self.c << 8) | (uint)self.b;
}

/// Returns the signed 16-bit BC operand (bias-decoded).
macro int Instruction.get_sbc(&self) {
    return (int)self.get_bc() - (int)BC_BIAS;
}

/// Returns the unsigned 24-bit ABC operand (all three fields concatenated).
///
/// `ABC = C << 16 | B << 8 | A`.
macro uint Instruction.get_abc(&self) {
    return ((uint)self.c << 16) | ((uint)self.b << 8) | (uint)self.a;
}

/// Returns the signed 24-bit ABC operand (bias-decoded).
macro int Instruction.get_sabc(&self) {
    return (int)self.get_abc() - (int)ABC_BIAS;
}

// ============================================================================
// Instruction — raw word access
// ============================================================================

/// Returns the raw 32-bit word.
macro uint Instruction.to_raw(&self) {
    return (uint)*self;
}

/// Creates an Instruction from a raw 32-bit word.
macro Instruction from_raw(uint raw) {
    return (Instruction)raw;
}

// ============================================================================
// Instruction — human-readable disassembly (for debugging)
// ============================================================================

/// Writes a one-line textual disassembly of the instruction into `buf`.
/// Returns a slice over the characters that were written.
///
/// Format examples:
///   `ADD       r3 = r1, r2`
///   `LDCONST   r0 = K[42]`
///   `JUMP      +17`
fn usz Instruction.disassemble(&self, char[] buf) {
    if (buf.len == 0) { return 0; }

    Opcode op = self.op;
    OpFormat fmt = get_op_format(op);
    usz pos = 0;

    // Write opcode name (we use the ordinal as a compact representation;
    // a full name table could be added later).
    pos = write_opcode_name(op, buf, pos);

    // Pad to column 14 for alignment.
    while (pos < 14 && pos < buf.len) {
        buf[pos] = ' ';
        pos++;
    }

    switch (fmt) {
        case ABC:
            // Fused compare-branch ops encode A as a signed 8-bit offset, not a register.
            if (op == Opcode.JMP_NLT || op == Opcode.JMP_NLE
                || op == Opcode.JMP_NGT || op == Opcode.JMP_NGE
                || op == Opcode.JMP_LT  || op == Opcode.JMP_LE
                || op == Opcode.JMP_GT  || op == Opcode.JMP_GE) {
                pos = write_int(buf, pos, (int)(ichar)self.a);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.c);
            } else {
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
                pos = write_str(buf, pos, " = r");
                pos = write_uint(buf, pos, self.b);
                pos = write_str(buf, pos, ", r");
                pos = write_uint(buf, pos, self.c);
            }

        case A_BC:
            pos = write_str(buf, pos, "r");
            pos = write_uint(buf, pos, self.a);
            pos = write_str(buf, pos, ", ");
            pos = write_uint(buf, pos, self.get_bc());

        case A_SBX:
            pos = write_str(buf, pos, "r");
            pos = write_uint(buf, pos, self.a);
            pos = write_str(buf, pos, ", ");
            pos = write_int(buf, pos, self.get_sbc());

        case WIDE_SABC:
            pos = write_int(buf, pos, self.get_sabc());

        case WIDE_ABC:
            pos = write_uint(buf, pos, self.get_abc());

        case NONE:
            // For INC/DEC show the target register even though they
            // use no formal operands.
            if (op == Opcode.INC || op == Opcode.DEC) {
                pos = write_str(buf, pos, "r");
                pos = write_uint(buf, pos, self.a);
            }
            break;
    }

    return pos;
}

// ============================================================================
// CompiledFunction — bytecode container
// ============================================================================

/// Flags specific to compiled function templates.
bitstruct FuncFlags : uint {
    /// HeapHeader-compatible type (always HType.OBJECT).
    HType htype         : 0..1;
    /// GC reachable.
    bool  reachable     : 2;
    /// GC temporary root.
    bool  temproot      : 3;
    /// Finaliser present.
    bool  finalizable   : 4;
    /// Finaliser already ran.
    bool  finalized     : 5;
    /// Read-only.
    bool  readonly      : 6;

    // ---- Function-specific flags (bits 7+) ----

    /// Function is a named function expression.
    bool  is_namebinding: 8;
    /// Function has a `...rest` parameter.
    bool  has_rest      : 9;
    /// Function uses `arguments` (needs Arguments exotic object).
    bool  uses_arguments: 10;
    /// Function uses `eval` (may create dynamic bindings).
    bool  uses_eval     : 11;
    /// Function is an arrow function (lexical `this`).
    bool  is_arrow      : 12;
    /// Function is a generator.
    bool  is_generator  : 13;
    /// Function is an async function.
    bool  is_async      : 14;
    /// Function body has direct `eval()` calls — prevents optimisations.
    bool  has_direct_eval: 15;
    /// Function is a constructor method.
    bool  is_constructable: 16;
    /// Function never creates local bindings — the CALL fast path can
    /// skip `env_create_function_scope` and reuse the parent env directly.
    bool  needs_env       : 17;
    bool  is_global       : 18;
    /// Function needs the CALL fast path to create a lex_env bridge
    /// connecting the new activation to the function's captured lex scope.
    /// Required for default parameter thunks capturing a parent param scope.
    bool  needs_lex_bridge: 19;
    /// Function is an ESM module body (top-level import/export).
    bool  is_module        : 20;
}

/// A compiled function template — the immutable bytecode representation of
/// an ECMAScript function produced by the compiler.
///
/// One CompiledFunction may be shared by many closures (each with its own
/// set of captured variable bindings).  The struct stores everything the
/// VM needs to execute the function:
///   - The instruction stream (`code`).
///   - The constant pool for literal values (`constants`).
///   - Templates for inner (nested) functions (`inner_funcs`).
///   - Register budget and argument counts.
///   - Source-level metadata for debugging.
struct CompiledFunction {
    // ---- Inline HeapHeader (binary-compatible with HeapHeader*) ----------

    /// Bit-packed flags — HeapHeader-compatible prefix + function metadata.
    FuncFlags       flags;
    /// Next pointer in the heap GC linked list.
    HeapHeader*     next;
    /// Previous pointer in the heap GC linked list.
    HeapHeader*     prev;

    // ---- Bytecode -------------------------------------------------------

    /// The instruction stream.  Each element is a 32-bit encoded
    /// `Instruction`.
    Instruction*    code;
    /// Number of instructions in `code`.
    uint            code_count;

    /// Constant pool — literal values (numbers, strings, etc.) referenced
    /// by LDCONST and friends.
    TVal*           constants;
    /// Number of entries in `constants`.
    uint            const_count;

    /// Inner (nested) function templates.  CLOSURE instructions index
    /// into this array.
    CompiledFunction** inner_funcs;
    /// Number of inner function templates.
    uint            inner_count;

    // ---- Register / argument layout -------------------------------------

    /// Total number of registers the activation record must allocate.
    ushort          num_regs;
    /// Number of formal parameters (used for call-setup).
    ushort          num_args;
    /// "Declared" formal count exposed as `Function.length`.  May differ
    /// from `num_args` when rest parameters are present.
    ushort          num_formals;

    // ---- Source-level debug info ----------------------------------------

    /// First source line covered by this function.
    uint            source_line_start;
    /// Last source line covered by this function.
    uint            source_line_end;

    /// Function name (empty slice for anonymous functions).
    char*           name_ptr;
    /// Length of the function name in bytes.
    uint            name_len;

    /// Source filename from which this function was compiled.
    char*           filename_ptr;
    /// Length of the filename in bytes.
    uint            filename_len;

    /// Optional per-instruction line-number table.  When non-null the
    /// table has `code_count` entries, one per instruction.
    uint*           line_table;

    // ---- Inline Cache (IC) entries ----------------------------------------
    /// Per-GETPROP/PUTPROP site inline cache.  Parallel to the instruction
    /// stream: `ic_entries[pc_offset]` is the cache for the instruction at
    /// `code[pc_offset]`.
    void*           ic_entries;  // ICEntry* (opaque to avoid import cycle)
    uint            ic_count;

    // ---- Variable IC (GETVAR/TYPEOFIDENT) --------------------------------
    /// Per-GETVAR/TYPEOFIDENT site inline cache. Parallel to the instruction
    /// stream: `var_ic_entries[pc_offset]` caches the resolved env + prop_idx
    /// for the GETVAR/TYPEOFIDENT at `code[pc_offset]`.
    void*           var_ic_entries;  // VarICEntry* (opaque)
    uint            var_ic_count;
}

// ============================================================================
// CompiledFunction — HeapHeader compatibility
// ============================================================================

/// Returns a HeapHeader pointer to this compiled function
/// (binary-compatible cast).
macro HeapHeader* CompiledFunction.as_header(&self) {
    return (HeapHeader*)self;
}

// ============================================================================
// CompiledFunction — flag accessors
// ============================================================================

/// Returns `true` when the function is an arrow function.
macro bool CompiledFunction.is_arrow(&self) {
    return self.flags.is_arrow;
}

/// Returns `true` when the function is a generator.
macro bool CompiledFunction.is_generator(&self) {
    return self.flags.is_generator;
}

/// Returns `true` when the function is async.
macro bool CompiledFunction.is_async(&self) {
    return self.flags.is_async;
}

/// Returns `true` when the function can be used as a constructor.
macro bool CompiledFunction.is_constructable(&self) {
    return self.flags.is_constructable;
}

/// Returns `true` when the function has no local bindings and the CALL fast
/// path can skip `env_create_function_scope`.
macro bool CompiledFunction.needs_env(&self) {
    return self.flags.needs_env;
}

/// Returns `true` for the top-level program or eval scope.
macro bool CompiledFunction.is_global_fn(&self) {
    return self.flags.is_global;
}
macro bool CompiledFunction.needs_lex_bridge(&self) {
    return self.flags.needs_lex_bridge;
}

/// Returns `true` when the function uses `arguments`.
macro bool CompiledFunction.uses_arguments(&self) {
    return self.flags.uses_arguments;
}

/// Returns `true` when the function contains direct `eval()` calls.
macro bool CompiledFunction.has_direct_eval(&self) {
    return self.flags.has_direct_eval;
}

/// Returns `true` when the function has a rest parameter.
macro bool CompiledFunction.has_rest(&self) {
    return self.flags.has_rest;
}

// ============================================================================
// CompiledFunction — code access
// ============================================================================

/// Returns the instruction at the given program-counter index.
///
/// No bounds checking is performed — the caller must ensure `pc` is
/// within `[0, code_count)`.
fn Instruction CompiledFunction.get_insn(&self, uint pc) @inline {
    return self.code[pc];
}

/// Returns the constant at the given index in the constant pool.
///
/// No bounds checking — the caller must ensure `idx < const_count`.
fn TVal CompiledFunction.get_const(&self, uint idx) @inline {
    return self.constants[idx];
}

/// Returns the inner function template at the given index.
///
/// No bounds checking — the caller must ensure `idx < inner_count`.
fn CompiledFunction* CompiledFunction.get_inner(&self, uint idx) @inline {
    return self.inner_funcs[idx];
}

/// Returns the function name as a char slice.
fn char[] CompiledFunction.get_name(&self) {
    if (self.name_ptr == null || self.name_len == 0) {
        char[] empty;
        return empty;
    }
    return self.name_ptr[:self.name_len];
}

/// Returns the source filename as a char slice.
fn char[] CompiledFunction.get_filename(&self) {
    if (self.filename_ptr == null || self.filename_len == 0) {
        char[] empty;
        return empty;
    }
    return self.filename_ptr[:self.filename_len];
}

/// Returns the source line number for the instruction at `pc`.
///
/// If no line table is present, returns 0.
fn uint CompiledFunction.get_line(&self, uint pc) {
    if (self.line_table == null || pc >= self.code_count) {
        return 0;
    }
    return self.line_table[pc];
}

// ============================================================================
// Opcode name table (for disassembly / debugging)
// ============================================================================

/// String names for each opcode, indexed by ordinal.
const char*[Opcode.LAST_OP.ordinal + 1] OPCODE_NAMES = {
    [Opcode.LDREG.ordinal]       = "LDREG",
    [Opcode.LDCONST.ordinal]     = "LDCONST",
    [Opcode.LDINT.ordinal]       = "LDINT",
    [Opcode.LDINTX.ordinal]      = "LDINTX",
    [Opcode.LDUNDEF.ordinal]     = "LDUNDEF",
    [Opcode.LDNULL.ordinal]      = "LDNULL",
    [Opcode.LDTRUE.ordinal]      = "LDTRUE",
    [Opcode.LDFALSE.ordinal]     = "LDFALSE",
    [Opcode.LDTHIS.ordinal]      = "LDTHIS",
    [Opcode.ADD.ordinal]         = "ADD",
    [Opcode.SUB.ordinal]         = "SUB",
    [Opcode.MUL.ordinal]         = "MUL",
    [Opcode.DIV.ordinal]         = "DIV",
    [Opcode.MOD.ordinal]         = "MOD",
    [Opcode.EXP.ordinal]         = "EXP",
    [Opcode.UNP.ordinal]         = "UNP",
    [Opcode.UNM.ordinal]         = "UNM",
    [Opcode.BNOT.ordinal]        = "BNOT",
    [Opcode.LNOT.ordinal]        = "LNOT",
    [Opcode.TYPEOF.ordinal]      = "TYPEOF",
    [Opcode.VOID.ordinal]        = "VOID",
    [Opcode.BAND.ordinal]        = "BAND",
    [Opcode.BOR.ordinal]         = "BOR",
    [Opcode.BXOR.ordinal]        = "BXOR",
    [Opcode.SHL.ordinal]         = "SHL",
    [Opcode.SHR.ordinal]         = "SHR",
    [Opcode.USHR.ordinal]        = "USHR",
    [Opcode.EQ.ordinal]          = "EQ",
    [Opcode.NEQ.ordinal]         = "NEQ",
    [Opcode.SEQ.ordinal]         = "SEQ",
    [Opcode.SNEQ.ordinal]        = "SNEQ",
    [Opcode.LT.ordinal]          = "LT",
    [Opcode.LE.ordinal]          = "LE",
    [Opcode.GT.ordinal]          = "GT",
    [Opcode.GE.ordinal]          = "GE",
    [Opcode.INSTANCEOF.ordinal]  = "INSTANCEOF",
    [Opcode.IN.ordinal]          = "IN",
    [Opcode.JUMP.ordinal]        = "JUMP",
    [Opcode.IF_TRUE.ordinal]     = "IF_TRUE",
    [Opcode.IF_FALSE.ordinal]    = "IF_FALSE",
    [Opcode.GETPROP.ordinal]     = "GETPROP",
    [Opcode.GETPROPC.ordinal]    = "GETPROPC",
    [Opcode.PUTPROP.ordinal]     = "PUTPROP",
    [Opcode.DELPROP.ordinal]     = "DELPROP",
    [Opcode.NEWOBJ.ordinal]      = "NEWOBJ",
    [Opcode.NEWARR.ordinal]      = "NEWARR",
    [Opcode.SETALEN.ordinal]     = "SETALEN",
    [Opcode.CALL.ordinal]        = "CALL",
    [Opcode.CALL_PROP.ordinal]   = "CALL_PROP",
    [Opcode.NEW_OBJ.ordinal]     = "NEW_OBJ",
    [Opcode.TAILCALL.ordinal]    = "TAILCALL",
    [Opcode.RET.ordinal]         = "RET",
    [Opcode.RETUNDEF.ordinal]    = "RETUNDEF",
    [Opcode.GETVAR.ordinal]      = "GETVAR",
    [Opcode.TYPEOFIDENT.ordinal]  = "TYPEOFIDENT",
    [Opcode.PUTVAR.ordinal]      = "PUTVAR",
    [Opcode.DECLVAR.ordinal]     = "DECLVAR",
    [Opcode.DELVAR.ordinal]      = "DELVAR",
    [Opcode.CLOSURE.ordinal]     = "CLOSURE",
    [Opcode.GETBOUND.ordinal]    = "GETBOUND",
    [Opcode.INITFOR.ordinal]     = "INITFOR",
    [Opcode.NEXTFOR.ordinal]     = "NEXTFOR",
    [Opcode.TRY.ordinal]         = "TRY",
    [Opcode.ENDTRY.ordinal]      = "ENDTRY",
    [Opcode.THROW.ordinal]       = "THROW",
    [Opcode.CATCH.ordinal]       = "CATCH",
    [Opcode.FINALLY.ordinal]     = "FINALLY",
    [Opcode.ENDFINALLY.ordinal]  = "ENDFINALLY",
    [Opcode.NOP.ordinal]         = "NOP",
    [Opcode.DEBUGGER.ordinal]    = "DEBUGGER",
    [Opcode.BREAK.ordinal]       = "BREAK",
    [Opcode.CONTINUE.ordinal]    = "CONTINUE",
    [Opcode.INITSET.ordinal]     = "INITSET",
    [Opcode.INITGET.ordinal]     = "INITGET",
    [Opcode.INITSETI.ordinal]    = "INITSETI",
    [Opcode.CSVARI.ordinal]      = "CSVARI",
    [Opcode.PUSH_LEX.ordinal]    = "PUSH_LEX",
    [Opcode.POP_LEX.ordinal]     = "POP_LEX",
    [Opcode.PUTLEX.ordinal]      = "PUTLEX",
    [Opcode.PUTLEX_C.ordinal]    = "PUTLEX_C",
    [Opcode.INITTZ.ordinal]      = "INITTZ",
    [Opcode.NEWREGEXP.ordinal]   = "NEWREGEXP",
    [Opcode.ARRSPRD.ordinal]     = "ARRSPRD",
    [Opcode.SPREAD_ARG.ordinal]  = "SPREAD_ARG",
    [Opcode.CALL_S.ordinal]      = "CALL_S",
    [Opcode.OBJSPRD.ordinal]     = "OBJSPRD",
    [Opcode.SETPROTO.ordinal]    = "SETPROTO",
    [Opcode.SUPER_CALL.ordinal]  = "SUPER_CALL",
    [Opcode.SUPER_CALL_S.ordinal] = "SUPER_CALL_S",
    [Opcode.NEWTARGET.ordinal]   = "NEWTARGET",
    [Opcode.LOAD_RESUME.ordinal] = "LOAD_RESUME",
    [Opcode.YIELD.ordinal]       = "YIELD",
    [Opcode.YIELD_STAR.ordinal]  = "YIELD_STAR",
    [Opcode.RET_GEN.ordinal]     = "RET_GEN",
    [Opcode.RETUNDEF_GEN.ordinal] = "RETUNDEF_GEN",
    [Opcode.AWAIT.ordinal]        = "AWAIT",
    [Opcode.INC.ordinal]          = "INC",
    [Opcode.DEC.ordinal]          = "DEC",
    [Opcode.INC_VAR.ordinal]      = "INC_VAR",
    [Opcode.DEC_VAR.ordinal]      = "DEC_VAR",
    [Opcode.JMP_NLT.ordinal]      = "JMP_NLT",
    [Opcode.JMP_NLE.ordinal]      = "JMP_NLE",
    [Opcode.JMP_NGT.ordinal]      = "JMP_NGT",
    [Opcode.JMP_NGE.ordinal]      = "JMP_NGE",
    [Opcode.JMP_LT.ordinal]       = "JMP_LT",
    [Opcode.JMP_LE.ordinal]       = "JMP_LE",
    [Opcode.JMP_GT.ordinal]       = "JMP_GT",
    [Opcode.JMP_GE.ordinal]       = "JMP_GE",
    [Opcode.GETPROPC2.ordinal]    = "GETPROPC2",
    [Opcode.GETPROPC_CACHED.ordinal] = "GETPROPC_CACHED",
    [Opcode.REQUIRE_OBJ.ordinal] = "REQUIRE_OBJ",
    [Opcode.LAST_OP.ordinal]     = "LAST_OP",
};

/// Return the human-readable name for an opcode, or "???" for unknown
/// values.
fn char* get_opcode_name(Opcode op) {
    uint idx = (uint)op.ordinal;
    if (idx <= Opcode.LAST_OP.ordinal) {
        char* name = OPCODE_NAMES[idx];
        if (name != null) {
            return name;
        }
    }
    return "???";
}

// ============================================================================
// Internal helpers for disassembly buffer writing
// ============================================================================

/// Write an opcode name into `buf` starting at `pos`.  Returns new pos.
fn usz write_opcode_name(Opcode op, char[] buf, usz pos) {
    char* name = get_opcode_name(op);
    usz i = 0;
    while (name[i] != 0 && pos < buf.len) {
        buf[pos] = name[i];
        pos++;
        i++;
    }
    return pos;
}

/// Write a C string into `buf` starting at `pos`.  Returns new pos.
fn usz write_str(char[] buf, usz pos, char* s) {
    usz i = 0;
    while (s[i] != 0 && pos < buf.len) {
        buf[pos] = s[i];
        pos++;
        i++;
    }
    return pos;
}

/// Write an unsigned integer (decimal) into `buf` starting at `pos`.
fn usz write_uint(char[] buf, usz pos, uint val) {
    // Small stack buffer for decimal digits (max 10 digits for uint).
    char[12] tmp;
    usz len = 0;

    if (val == 0) {
        if (pos < buf.len) {
            buf[pos] = '0';
            pos++;
        }
        return pos;
    }

    uint v = val;
    while (v > 0) {
        tmp[len] = (char)('0' + (v % 10));
        len++;
        v /= 10;
    }

    // Write in reverse order.
    for (usz i = len; i > 0 && pos < buf.len; ) {
        i--;
        buf[pos] = tmp[i];
        pos++;
    }
    return pos;
}

/// Write a signed integer (decimal) into `buf` starting at `pos`.
fn usz write_int(char[] buf, usz pos, int val) {
    if (val < 0) {
        if (pos < buf.len) {
            buf[pos] = '-';
            pos++;
        }
        // Handle INT_MIN carefully.
        if (val == -2147483647 - 1) {
            return write_uint(buf, pos, (uint)2147483648);
        }
        return write_uint(buf, pos, (uint)(-val));
    }
    if (val > 0) {
        if (pos < buf.len) {
            buf[pos] = '+';
            pos++;
        }
    }
    return write_uint(buf, pos, (uint)val);
}
