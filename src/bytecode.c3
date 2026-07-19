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
///
/// Human-readable disassembly (`Instruction.disassemble`, the
/// `OPCODE_NAMES` table, and the `write_*` buffer-writer helpers) lives
/// in the sibling file `bytecode_disasm.c3` and is gated on the
/// `TRACE_VM` build feature.
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
    /// `constants[BC] = A`  — write into the constant pool (A-BC format).
    /// Used for tagged-template site caching: the constant pool slot is
    /// shared by every closure instantiated from the same CompiledFunction,
    /// so storing the template object there the first time a tagged
    /// template expression is reached implements the per-call-site
    /// [[TemplateRegistry]] cache (ES2015 §12.2.9.3) without extra state.
    SETCONST,
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

    /// `A = B[C]`  — get property. Coerces C to a property key internally
    /// (ToPropertyKey, §7.1.19) to perform the lookup, but does NOT write
    /// the coerced key back into register C — safe to use on any key
    /// register, including one that aliases a live local variable.
    GETPROP,
    /// `A = B[K]`  — get property with constant pool key.  Fused LDCONST+GETPROP.
    /// Format ABC: A = dst reg, B = obj reg, C = constant-pool index of property key string.
    GETPROPC,
    /// `A = B[C]`, and C = ToPropertyKey(C)  — identical to GETPROP, but ALSO
    /// writes the ToPropertyKey-coerced string back into register C so a
    /// follow-up PUTPROP/TOPROPKEY on the same register is idempotent (no
    /// second toString()/Symbol.toPrimitive() invocation on the key), per
    /// §7.1.19. Opt-in: emitted by member_expr for computed (`[expr]`) member
    /// accesses that may later be reused as a compound/logical-assign or
    /// postfix/prefix-increment target — see member_expr's LBRACKET branch
    /// in expressions.c3. Plain assignment (`obj[k] = v`) strips this
    /// instruction from the bytecode stream before it ever executes, so the
    /// writeback never interferes with that path's evaluation order. C must
    /// be a compiler-owned temp register (never a caller's local var) at
    /// every such call site — see CompilerContext.shield_computed_key.
    GETPROP_CACHE,
    /// `A[B] = C`  — put (set) property.
    PUTPROP,
    /// `A[B] = C` as a fresh non-enumerable data property (writable and
    /// configurable, enumerable false) — bypasses the normal [[Set]]
    /// semantics of PUTPROP. Used for the `.raw` property of tagged
    /// template objects (ES2015 §12.2.9.3 GetTemplateObject step 8), which
    /// is a real data property but must not show up in for-in/Object.keys.
    PUTPROP_NE,
    /// `A = delete B[C]`  — delete property.
    DELPROP,

    // ---- Object / Array creation -----------------------------------------

    /// `A = {}`  — create a new empty plain object.
    NEWOBJ,
    /// `A = []`  — create a new empty array.
    NEWARR,
    /// Set array length: `A.length = BC` (A-BC format).
    SETALEN,
    /// `Object.freeze(A)`, ignoring non-objects — used to freeze tagged
    /// template objects (ES2015 §12.2.9.3 GetTemplateObject).
    FREEZEOBJ,

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
    /// Initialization store: does NOT perform a TDZ check (used by param sync,
    /// for-loop iteration variables, etc. which legitimately write a binding
    /// that may still hold the TDZ sentinel).
    PUTVAR,
    /// `variable[constants[BC]] = A`  — user ASSIGNMENT to a variable by name
    /// (A-BC). Identical to PUTVAR but throws ReferenceError when the target is
    /// a let/const binding still in its temporal dead zone (assignment before
    /// initialization). Emitted only for genuine assignment expressions.
    PUTVAR_ASSIGN,
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
    /// Throw a ReferenceError with a constant pool message.
    /// A=unused, B=msg_const_idx. Used for `delete super.x` (always ReferenceError).
    THROW_REF,
    /// Throw a SyntaxError with a constant pool message.
    /// A=unused, B=msg_const_idx. Used for GlobalDeclarationInstantiation
    /// checks (ES6+ §15.1.8) that must surface as a *runtime* throw rather
    /// than a compile-time failure — e.g. a top-level `let`/`const` colliding
    /// with a restricted global name (`undefined`, `NaN`, `Infinity`).
    THROW_SYNTAX,
    /// `A = <caught exception>`  — store the caught value.
    CATCH,
    /// Enter the finally block.
    FINALLY,
    /// Exit the finally block (may re-throw or continue).
    ENDFINALLY,

    /// `A = ToPropertyKey(reg[A])`  — in-place coercion of a computed
    /// property-name expression's value to a property key (string/symbol),
    /// per ToPropertyKey (§7.1.19) / ComputedPropertyName evaluation
    /// (§13.2.5.5). Used by object destructuring-assignment computed keys
    /// (`{[expr]: target} = rhs`) to coerce the key at PropertyName-evaluation
    /// time — before the (possibly deferred) AssignmentTarget is evaluated —
    /// matching KeyedDestructuringAssignmentEvaluation's step ordering without
    /// duplicating the later property read done by GETPROP/PUTPROP (which
    /// idempotently no-ops on an already-string register).
    TOPROPKEY,
    /// `A = ToString(reg[A])`  — in-place coercion to string via §7.1.17,
    /// used for template literal substitutions (§13.2.8.1
    /// SubstitutionEvaluation calls ToString directly — unlike the `+`
    /// operator, which goes through ToPrimitive(default) first). This
    /// distinction is only observable when Symbol.prototype[@@toPrimitive]
    /// has been redefined/removed, since it otherwise always returns the
    /// unwrapped symbol regardless of hint.
    TOSTR,

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
    /// `A[B] = C` — define a data property with WEC flags (overrides any
    /// existing non-writable property, since DefinePropertyOrThrow semantics
    /// allow replacement when the existing property is configurable). Used
    /// for array literal element initialization.
    INITPROP,
    /// Identical to INITPROP, plus SetFunctionName if C is a function with an
    /// empty `.name` (ES2015 §12.2.6.9 step 6). Used for object-literal
    /// computed data properties (`{ [expr]: value }`) whose value is
    /// statically known to be an AnonymousFunctionDefinition.
    /// ABC format: A=object_reg, B=key_reg, C=value_reg.
    INITPROPN,
    /// Define class getter accessor: non-enumerable, configurable.
    /// Per ES2015 §14.5.14 step 9, class accessor descriptors are
    /// {enumerable:false, configurable:true}.
    /// ABC format: A=object_reg, B=key_reg, C=getter_function_reg.
    CLASS_INITGET,
    /// Define class setter accessor: non-enumerable, configurable.
    /// Per ES2015 §14.5.14 step 9, class accessor descriptors are
    /// {enumerable:false, configurable:true}.
    /// ABC format: A=object_reg, B=key_reg, C=setter_function_reg.
    CLASS_INITSET,
    /// Define class method: writable, non-enumerable, configurable.
    /// Per ES2015 §14.5.14 step 9, class method descriptors are
    /// {writable:true, enumerable:false, configurable:true}.
    /// Uses DefinePropertyOrThrow semantics (same as INITPROP).
    /// ABC format: A=object_reg, B=key_reg, C=value_reg.
    CLASS_INITPROP,
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
    /// Push a new variable environment child of the current var_env.
    /// Used when a function body needs a separate var scope from parameters
    /// (§9.2.10 step 27: hasParameterExpressions → separate varEnv for body).
    PUSH_VAR,
    /// Pop the current variable environment, restoring act.var_env to parent.
    POP_VAR,
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

    /// GlobalDeclarationInstantiation static checks (ES2015 §15.1.11),
    /// emitted only at the top of a global Script/eval so a collision throws
    /// before any binding is instantiated. BC indexes the declared name in
    /// the constant pool; A is unused (A-BC format).
    ///   CHKGLOBALLEX  — a lexical name (let/const/class): throws SyntaxError
    ///     if the name already has a var binding, a global lexical binding,
    ///     or a restricted (non-configurable, non-plain-data) global property.
    ///   CHKGLOBALVAR  — a var name: throws SyntaxError if a global lexical
    ///     binding exists; else TypeError if CanDeclareGlobalVar is false.
    ///   CHKGLOBALFUNC — a function name: throws TypeError if
    ///     CanDeclareGlobalFunction is false.
    CHKGLOBALLEX,
    CHKGLOBALVAR,
    CHKGLOBALFUNC,

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
    /// Forward elements of array C directly to argument registers starting
    /// at A without calling @@iterator.  Unlike SPREAD_ARG, this reads
    /// array elements by index (fast path) and does NOT invoke the iterator
    /// protocol.  Used by the default derived constructor to forward args.
    /// Count written to register B.  ABC format.
    FWD_ARGS,
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
    /// `A = GetPrototypeOf(B)` — read the internal [[Prototype]] of object B
    /// (routing through the Proxy [[GetPrototypeOf]] trap when B is a proxy).
    /// Yields null for a null prototype and undefined for non-object B.
    /// ABC format: A=dst_reg, B=obj_reg.
    GETPROTO,
    /// `A[B] = C` with receiver = the current `this` binding — the store form
    /// of `super.x = v` (§13.15.2 SetSuperProperty): the property walk starts
    /// at the super base (A) but accessor setters / new data properties land
    /// on the receiver.  ABC format: A=super_base_reg, B=key_reg, C=val_reg.
    PUTPROP_SUPER,
    /// `A = B[C]` — super property get with correct receiver (§13.5.3 GetValue).
    /// The property lookup starts at super base B with key C, but accessor getters
    /// are invoked with `this` = current activation's this_binding, not B.
    /// ABC format: A=result_reg, B=super_base_reg, C=key_reg.
    GETPROP_SUPER,
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

    /// `import(specifier)` — dynamic import expression (ES2020).
    /// Resolves, links and evaluates the requested module (re-entrantly when a
    /// module body is already running) and stores a Promise in A that fulfills
    /// with the module's namespace object or rejects with the module's
    /// load/evaluation error.
    /// ABC format: A=result_reg, B=specifier_reg, C=0.
    DYN_IMPORT,

    /// Marks the boundary between parameter initialization and the function
    /// body in a generator function.  The compiler emits this once per
    /// generator body, immediately after all parameter default checks and
    /// destructuring are complete.
    ///
    /// On the initial call to a generator function the VM runs the frame
    /// eagerly up to (and including) this instruction, then suspends: it
    /// saves the current register state into the pre-allocated GeneratorState
    /// and returns the generator object to the caller.  This ensures that
    /// FunctionDeclarationInstantiation side effects (throwing defaults,
    /// destructuring errors) happen at call time per ES2022 §27.5.3.2.
    ///
    /// On subsequent resumes this instruction is never reached because
    /// saved_pc already points past it.
    ///
    /// NONE format (no operands).
    GEN_START,

    // ---- Fastint arithmetic fusion ----------------------------------------

    /// `A = A + 1` (in-place fastint increment). Hot loop counter idiom.
    /// Falls back to `A = A + 1` general path if A is not a fastint.
    /// A-only format: A=target_reg, B=0, C=0.
    INC,
    /// `A = A - 1` (in-place fastint decrement).
    /// A-only format: A=target_reg, B=0, C=0.
    DEC,

    /// Write a value into the call-argument area at a runtime-computed slot.
    /// Used for non-spread arguments that follow a spread — their position
    /// depends on the runtime spread count, which is not known at compile time.
    /// ABC format: A=base_reg (first_arg register), B=count_reg (running total),
    /// C=src_reg (value to write). Effect: regs[A + regs[B]] = regs[C];
    /// then regs[B]++.
    PUTARG,

    /// `new ctor(...args)` with a spread — same as NEW_OBJ but reads the
    /// runtime argument count from a register (like CALL_S). ABC format:
    /// A=result_reg, B=ctor_reg, C=nargs_reg.
    NEW_OBJ_S,

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

    /// Require that the value in register A is an Object (Type(result) === Object).
    /// Throws TypeError if the value is not an object (primitives, null, undefined).
    /// Used by for-of to validate the .next() result (ES2022 §14.7.5.6 step 3.b).
    CHKOBJ,

    /// IteratorClose: if the value in A is an object and has a callable
    /// `.return` method, call it with this = A and discard the result. Used
    /// after a pattern walk so destructuring of partially-exhausted
    /// iterators notifies the iterator (ES2015 §13.3.3.8 IteratorClose).
    /// A = iterator register. B = scratch register used to fetch the
    /// .return method (allocated by the VM); B = C on exit.
    ITER_CLOSE,

    /// `IsConstructor(A)` — throw TypeError if register A is not a constructor.
    /// Used at class `extends` time (ES2022 §15.7.14 step 5.f).
    /// A-only format: A=value_reg, B=0, C=0.
    CHKCTOR,

    /// Validate that register A is an Object or Null.
    /// Used after `Get(superclass, "prototype")` in class extends: if the
    /// result is neither Object nor Null, throw TypeError (ES2015 §14.5.14
    /// step 5.g.ii-iv).  A-only format: A=value_reg, B=0, C=0.
    CHK_PROT,

    // ---- Private class members (ES2022) ------------------------------------

    /// Allocate a fresh hidden symbol at class-evaluation time.
    /// A=dst register, BC=constant pool index of the description string
    /// (debugging only). dst := new hidden symbol, unique per execution of
    /// this instruction (per §6.2.4 each class evaluation creates a fresh
    /// PrivateEnvironment).
    NEW_PRIV_SYM,

    /// Stamp brand: A=object, B=register holding the brand symbol.
    /// obj[brand_sym] = true as a non-enumerable own property, bypassing
    /// the extensibility check (PrivateFieldAdd/PrivateBrandAdd have no
    /// [[Extensible]] gate). ABC format.
    ADD_BRAND,

    /// Check brand: A=object, B=register holding the brand symbol,
    /// C=constant pool index of the private name (for the error message).
    /// Throws TypeError unless obj has brand_sym as an OWN property.
    /// Own-only: must NOT walk the prototype chain, otherwise
    /// Object.create(instance).#x would falsely pass. ABC format.
    CHK_BRAND,

    /// Define an own data property bypassing setters AND the extensibility
    /// check (CreateDataProperty semantics without the [[Extensible]] gate,
    /// for private field installation per PrivateFieldAdd).
    /// ABC format: A=object_reg, B=key_reg, C=value_reg.
    INITPROP_PRIV,

    /// `A = ToNumeric(B)` — coercion used by postfix ++/-- to compute the
    /// returned old value.  Unlike UNP (unary plus), a BigInt operand passes
    /// through unchanged rather than throwing (ES2020 §7.1.3 ToNumeric).
    TONUMERIC,

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
        case CHKGLOBALLEX:  return A_BC;
        case CHKGLOBALVAR:  return A_BC;
        case CHKGLOBALFUNC: return A_BC;
        case NEWREGEXP:  return A_BC;
        case ARRSPRD:    return ABC;
        case SPREAD_ARG: return ABC;
        case FWD_ARGS:   return ABC;
        case CALL_S:     return ABC;
        case OBJSPRD:    return ABC;
        case SETPROTO:   return ABC;
        case GETPROTO:   return ABC;
        case PUTPROP_SUPER: return ABC;
        case GETPROP_SUPER: return ABC;
        case THROW_REF:     return A_BC;
        case THROW_SYNTAX:  return A_BC;
        case SUPER_CALL: return ABC;
        case SUPER_CALL_S: return ABC;
        case NEWTARGET:  return ABC;
        case NEW_PRIV_SYM: return A_BC;
        case ADD_BRAND:  return ABC;
        case CHK_BRAND:  return ABC;
        case INITPROP_PRIV: return ABC;

        case LOAD_RESUME:  return ABC;
        case YIELD:      return ABC;
        case YIELD_STAR: return ABC;
        case GETPROPC_CACHED: return ABC;
        case GEN_START:      return NONE;

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
        case DYN_IMPORT: return ABC;
        case DEBUGGER:  return NONE;
        case ENDTRY:    return NONE;
        case ENDFINALLY: return NONE;
        case PUSH_LEX:   return NONE;
        case POP_LEX:    return NONE;
        case PUSH_VAR:   return NONE;
        case POP_VAR:    return NONE;
        case INC:        return NONE;
        case DEC:        return NONE;
        case PUTARG:     return ABC;
        case NEW_OBJ_S:  return ABC;
        case INC_VAR:    return A_BC;
        case DEC_VAR:    return A_BC;
        case GETPROPC2:  return ABC;
        case REQUIRE_OBJ: return ABC;
        case ITER_CLOSE: return ABC;
        case CHKOBJ:     return ABC;
        case CHKCTOR:    return ABC;
        case CHK_PROT:   return ABC;

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
    /// Function is a class constructor (ES2015 §14.5.14 step 25: the
    /// resulting constructor's .prototype is non-configurable, so static
    /// `class.prototype = ...` must throw TypeError).  When false, .prototype
    /// uses PROP_FLAGS_WEC (configurable=true).
    bool  is_class_ctor    : 21;
    /// Function body had a "use strict" directive.
    bool  is_strict        : 22;
    /// Constructor is a derived class constructor (ES2015 §9.2.2 step 13.c):
    /// `return <non-object>` in a derived constructor throws TypeError unless
    /// the value is undefined. Set when has_super_binding is true at compile time.
    bool  is_derived_ctor  : 23;
    /// Function is compiled eval code (compile_eval), not Script/global code.
    /// Per ES2015 §18.2.1.2 EvalDeclarationInstantiation step 16.a,
    /// CreateGlobalVarBinding(vn, true) installs eval-created global var/
    /// function bindings as *configurable* — distinct from a real Script's
    /// GlobalDeclarationInstantiation (§15.1.11 step 18.a), which installs
    /// them non-configurable via CreateGlobalVarBinding(vn, false).
    bool  is_eval          : 24;
    /// The eval SOURCE carried its own "use strict" directive prologue. The
    /// engine executes all code in strict mode (is_strict is always set), but
    /// EvalDeclarationInstantiation's leak semantics depend on the *source's*
    /// own strictness (ES2015 §18.2.1.1 PerformEval step 12): strict eval gets
    /// a fresh varEnv (declarations never escape), non-strict indirect/global
    /// eval installs its `var`/`function` bindings on the global object. Only
    /// meaningful on is_eval functions.
    bool  eval_src_strict  : 25;
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

    // ---- Source-text retention (Function.prototype.toString) ------------
    /// Heap-owned copy of the original source text spanned by this function
    /// (between the function's opening `function` keyword / arrow head and
    /// its closing `}` or expression end). NULL when source was not retained.
    /// Used by builtin_function_proto_toString (ES2019 §19.2.3.5).
    char*           src_ptr;
    /// Length in bytes (no NUL terminator counted).
    uint            src_len;

    // ---- Private class fields (ES2022) -----------------------------------

    /// The hidden `__field_init__` function template compiling every
    /// instance field initializer in source order (see class.c3), or NULL
    /// when the class declares no instance fields. A raw pointer (not an
    /// index into inner_funcs) because __field_init__ is compiled in the
    /// class-enclosing scope's CompilerContext, a different inner-function
    /// table than this constructor's own — see vm_calls.c3
    /// vm_init_private_members for why the VM construct path needs this to
    /// be self-contained rather than pool-index-relative.
    CompiledFunction* field_init_func;
    /// Interned binding name (e.g. "#priv:brand") used to look up the
    /// class's brand symbol in the constructor's lex_env (classScope) at
    /// construction time, or NULL when the class has no private members and
    /// stamps no brand. A raw HString* (not a constant-pool index) for the
    /// same reason as field_init_func.
    void*           brand_name_hstr;
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

/// Returns `true` when the function is an ES2015 class constructor.  Such
/// functions have a non-configurable .prototype property (ES6 §14.5.14
/// step 25) and must throw TypeError on `Object.defineProperty(ctor, ...)`
/// or static-method redefinition of .prototype.
macro bool CompiledFunction.is_class_ctor(&self) {
    return self.flags.is_class_ctor;
}

/// Returns `true` when this is a derived class constructor.  Per ES2015 §9.2.2
/// step 13.c, returning a non-object non-undefined value from a derived
/// constructor throws TypeError.
macro bool CompiledFunction.is_derived_ctor(&self) {
    return self.flags.is_derived_ctor;
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

/// Returns `true` when this is compiled eval code (as opposed to Script or
/// module top-level code) — see FuncFlags.is_eval.
macro bool CompiledFunction.is_eval_fn(&self) {
    return self.flags.is_eval;
}
/// Returns `true` when the eval source had its own "use strict" directive
/// (see FuncFlags.eval_src_strict). Only meaningful on is_eval functions.
macro bool CompiledFunction.eval_source_is_strict(&self) {
    return self.flags.eval_src_strict;
}
macro bool CompiledFunction.needs_lex_bridge(&self) {
    return self.flags.needs_lex_bridge;
}

/// Returns `true` when the function body had a "use strict" directive.
macro bool CompiledFunction.is_strict(&self) {
    return self.flags.is_strict;
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

/// Returns `true` when the function is a named function expression — the
/// VM must bind the function's name to the function object in a fresh
/// lexical environment at call time (ES2015 §14.1.20 NamedEvaluation).
macro bool CompiledFunction.is_namebinding(&self) {
    return self.flags.is_namebinding;
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
// Disassembler lives in `bytecode_disasm.c3`
// ============================================================================
//
// The human-readable disassembler (`Instruction.disassemble`), the 119-entry
// `OPCODE_NAMES` table, and the small `write_*` buffer-writer helpers all
// live in `src/bytecode_disasm.c3` (same module, `duktape::bytecode`). That
// translation unit gates its real implementations on the `TRACE_VM` build
// feature so that release builds skip the `.text` cost and LLVM drops the
// `OPCODE_NAMES` array from `.rodata` once no reachable code references it.
// Build the `duktape_c3_debug` target (or pass `-D TRACE_VM`) to wire the
// dump helpers and `-t` / `-c` / `--format json` CLI features.

