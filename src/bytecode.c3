/// Bytecode definitions: instruction encoding, the opcode set, and the compiled
/// function representation.
///
/// The VM is register-based with fixed-width 32-bit instructions. Each packs an
/// 8-bit opcode and up to three operand fields into one `uint`:
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
///   - **A-BC** : A (8 bits, 8-15) plus BC (16 bits, 16-31)
///   - **ABC**  : one 24-bit operand (bits 8-31)
///   - **A-sBx**: A (8 bits) + signed Bx (16 bits, bias-encoded)
///   - **sABC** : signed 24-bit operand (bias-encoded)
///
/// The `Instruction` bitstruct exposes the raw fields and an accessor for every
/// layout.
///
/// Disassembly lives in `bytecode_disasm.c3` behind the `TRACE_VM` feature:
/// `Instruction.disassemble`, the `OPCODE_NAMES` table, and the `write_*`
/// helpers.
module duktape::bytecode;

import duktape::types;
import duktape::hobject;

// ============================================================================
// Constants
// ============================================================================

/// Bias that lets a 16-bit signed operand be stored unsigned, mapping
/// -(2^15) .. 2^15-1 onto 0 .. 65535.
const uint BC_BIAS  = 0x8000;

/// The same for a 24-bit signed operand, mapping -(2^23) .. 2^23-1 onto
/// 0 .. 16777215.
const uint ABC_BIAS = 0x80_0000;

/// Maximum unsigned value that fits in the 8-bit A, B, or C fields.
const uint MAX_A  = 0xFF;
const uint MAX_B  = 0xFF;
const uint MAX_C  = 0xFF;

/// Maximum positive signed BC value (after removing bias).
const int  MAX_SBC  = 0x7FFF;
/// Minimum (most-negative) signed BC value.
const int  MIN_SBC  = -0x8000;

// ============================================================================
// Opcode: every virtual-machine operation
// ============================================================================

/// The operation codes. Each is 8 bits, so there is room for 256, and they are
/// grouped below by what they do: loads and stores, arithmetic, unary and
/// bitwise operations, comparison, control flow, property access, object
/// creation, calls, variable access, closures, iterators, and exceptions.
enum Opcode : char {
    // ---- Load / Store ----------------------------------------------------

    /// `A = reg[B]`: register-to-register copy.
    LDREG,
    /// `A = constants[BC]`: load from the constant pool (A-BC format).
    LDCONST,
    /// `constants[BC] = A`: write into the constant pool (A-BC format).
    /// Used for tagged-template site caching: the constant pool slot is
    /// shared by every closure instantiated from the same CompiledFunction,
    /// so storing the template object there the first time a tagged
    /// template expression is reached implements the per-call-site
    /// [[TemplateRegistry]] cache (ES2015 §12.2.9.3) without extra state.
    SETCONST,
    /// `A = (int)sBx`: load a signed 16-bit immediate (A-sBx format).
    LDINT,
    /// `A = (A << 16) | BC`: extend a previously loaded integer with
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
    /// `A = this`: load the current `this` binding.
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
    /// `A = B ** C`: exponentiation.
    EXP,
    /// `A = B + imm8`: add small unsigned immediate (fused LDINT+ADD).
    /// C holds an 8-bit unsigned immediate (0..255); B is the source register.
    /// Fastint fast path only; falls back to the same coercion as ADD.
    ADDI,
    /// `A = B - imm8`: subtract small unsigned immediate (fused LDINT+SUB).
    /// C holds an 8-bit unsigned immediate (0..255); B is the source register.
    SUBI,

    // ---- Unary (A = op B) ------------------------------------------------

    /// `A = +B`: unary plus (ToNumber coercion).
    UNP,
    /// `A = -B`: unary minus.
    UNM,
    /// `A = ~B`: bitwise NOT.
    BNOT,
    /// `A = !B`: logical NOT.
    LNOT,
    /// `A = typeof B`.
    TYPEOF,
    /// `A = void B`: always produces `undefined`.
    VOID,

    // ---- Bitwise (A = B op C) --------------------------------------------

    /// `A = B & C`: bitwise AND.
    BAND,
    /// `A = B | C`: bitwise OR.
    BOR,
    /// `A = B ^ C`: bitwise XOR.
    BXOR,
    /// `A = B << C`: left shift.
    SHL,
    /// `A = B >> C`: signed right shift.
    SHR,
    /// `A = B >>> C`: unsigned right shift.
    USHR,

    // ---- Comparison (A = B op C) -----------------------------------------

    /// `A = (B == C)`: abstract equality.
    EQ,
    /// `A = (B != C)`: abstract inequality.
    NEQ,
    /// `A = (B === C)`: strict equality.
    SEQ,
    /// `A = (B !== C)`: strict inequality.
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

    /// `PC += sABC`: unconditional relative jump (signed 24-bit offset,
    /// sABC format).
    JUMP,
    /// `if (A) PC += sBC`: branch when truthy (A-sBx format).
    IF_TRUE,
    /// `if (!A) PC += sBC`: branch when falsy (A-sBx format).
    IF_FALSE,

    // ---- Property access -------------------------------------------------

    /// `A = B[C]`: get property. Coerces C to a property key internally
    /// (ToPropertyKey, §7.1.19) to perform the lookup, but does NOT write
    /// the coerced key back into register C, which is safe for any key
    /// register, including one that aliases a live local variable.
    GETPROP,
    /// `A = B[K]`: get property with constant pool key.  Fused LDCONST+GETPROP.
    /// Format ABC: A = dst reg, B = obj reg, C = constant-pool index of property key string.
    GETPROPC,
    /// `A = B[C]`, and C = ToPropertyKey(C). Identical to GETPROP, but it also
    /// writes the ToPropertyKey-coerced string back into register C so a
    /// follow-up PUTPROP/TOPROPKEY on the same register is idempotent (no
    /// second toString()/Symbol.toPrimitive() invocation on the key), per
    /// §7.1.19. Opt-in: emitted by member_expr for computed (`[expr]`) member
    /// accesses that may later be reused as a compound/logical-assign or
    /// postfix or prefix increment target. See member_expr's LBRACKET branch
    /// in expressions.c3. Plain assignment (`obj[k] = v`) strips this
    /// instruction from the bytecode stream before it ever executes, so the
    /// writeback never interferes with that path's evaluation order. C must
    /// be a compiler-owned temp register (never a caller's local var) at
    /// every such call site. See CompilerContext.shield_computed_key.
    GETPROP_CACHE,
    /// `A[B] = C`: put (set) property.
    PUTPROP,
    /// `A[B] = C` as a fresh non-enumerable data property (writable and
    /// configurable, enumerable false), bypassing the normal [[Set]]
    /// semantics of PUTPROP. Used for the `.raw` property of tagged
    /// template objects (ES2015 §12.2.9.3 GetTemplateObject step 8), which
    /// is a real data property but must not show up in for-in/Object.keys.
    PUTPROP_NE,
    /// `A = delete B[C]`: delete property.
    DELPROP,

    // ---- Object / Array creation -----------------------------------------

    /// `A = {}`: create a new empty plain object.
    NEWOBJ,
    /// `A = []`: create a new empty array.
    NEWARR,
    /// Set array length: `A.length = BC` (A-BC format).
    SETALEN,
    /// `Object.freeze(A)`, ignoring non-objects. Used to freeze tagged
    /// template objects (ES2015 §12.2.9.3 GetTemplateObject).
    FREEZEOBJ,

    // ---- Function calls --------------------------------------------------

    /// `A = B(C..C+N)`: function call.  A = result register,
    /// B = callee register, C = argument count.
    /// Value stack: valstack[B] = callee, valstack[B+1..B+C] = args.
    /// After call: valstack[A] = return value.
    CALL,
    /// `A = B.C(...)`: method call (receiver is B).
    CALL_PROP,
    /// `A = new B(C...)`: constructor invocation.
    NEW_OBJ,
    /// Tail-call optimisation: reuses the current stack frame.
    TAILCALL,
    /// `return A`: return register A's value.
    RET,
    /// `return undefined`: implicit return.
    RETUNDEF,

    // ---- Variable access -------------------------------------------------

    /// `A = variable[constants[BC]]`: read a variable by name
    /// looked up in the constant pool (A-BC format).
    GETVAR,
    /// `A = env chain has a binding named constants[BC]` (A-BC). Captures
    /// strict plain-assignment LHS resolvability BEFORE the RHS runs
    /// (ES2022 §13.15.2 step 1); consumed by THROW_UNRESOLVED after the RHS.
    RESOLVEVAR,
    /// Throw ReferenceError "constants[BC] is not defined" unless register A
    /// holds true (A-BC). Pairs with RESOLVEVAR: an RHS side effect that
    /// creates the global cannot retroactively make the LHS resolvable.
    THROW_UNRESOLVED,
    /// `variable[constants[BC]] = A`: write a variable by name (A-BC).
    /// Initialization store: does NOT perform a TDZ check (used by param sync,
    /// for-loop iteration variables, etc. which legitimately write a binding
    /// that may still hold the TDZ sentinel).
    PUTVAR,
    /// `variable[constants[BC]] = A`: user ASSIGNMENT to a variable by name
    /// (A-BC). Identical to PUTVAR but throws ReferenceError when the target is
    /// a let/const binding still in its temporal dead zone (assignment before
    /// initialization). Emitted only for genuine assignment expressions.
    PUTVAR_ASSIGN,
    /// `declare variable[constants[BC]] = A`: declare+initialize a `var` in
    /// the immediate var_env only (does not walk the scope chain).
    DECLVAR,
    /// `declare variable[constants[BC]]`: the hoisting pass's stub for a `var`
    /// with no initializer (A-BC; A holds undefined). At global scope such a
    /// declaration carries no value, so an existing global property must be left
    /// entirely untouched (CanDeclareGlobalVar steps 4-5), including its value,
    /// which a plain DECLVAR would overwrite with undefined. The distinction is
    /// static (does the declarator have an initializer?), not a runtime test on
    /// the operand: `for (var v of [1, , 3])` legitimately declares undefined on
    /// a hole and must assign it.
    DECLVAR_HOIST,
    /// `declare function[constants[BC]] = A`: instantiate a top-level
    /// FunctionDeclaration's binding (A-BC). Identical to DECLVAR outside a
    /// global Environment Record, but when var_env IS the global env it
    /// follows CreateGlobalFunctionBinding (ES2024 §9.1.1.4.18): an existing
    /// non-configurable own global property keeps its current attributes and
    /// only its value is replaced, while a missing or configurable one is
    /// (re)defined as { writable: true, enumerable: true, configurable: D }
    /// (D = true for eval code, false for Script code). DECLVAR cannot do
    /// this: CreateGlobalVarBinding must leave an existing property entirely
    /// untouched, so the two declaration kinds need distinct opcodes.
    DECLGLOBALFUNC,
    /// `A = global[constants[BC]]`: read a top-level global binding by name
    /// (A-BC). Emitted only at true global scope (no nested lexical env), where
    /// lex_env == global_lex_env and var_env == global_env are both permanent
    /// GC roots. A per-PC inline cache records (bindings, shape_id, prop_idx) so
    /// a hit is a single shape compare + direct indexed load into the global
    /// object's property storage, with no env-chain walk and no generation dependent
    /// load, no name compare. Falls back to the GETVAR slow path on a miss.
    GETGLOBAL,
    /// `global[constants[BC]] = A`: user assignment to a top-level global
    /// binding by name (A-BC). Like PUTVAR_ASSIGN (TDZ + const-assignment
    /// throws) but specialized to the two global objects, with the same slot
    /// inline cache as GETGLOBAL for the write-back.
    PUTGLOBAL,
    /// `A = global[constants[BC]]`: read a top-level global binding that a
    /// whole-program compile-time proof classified as primitive-only (every
    /// assignment anywhere in the unit, including nested functions, stores a
    /// provably-primitive value; no eval/globalThis/Function/with observability).
    /// Because the slot can never hold a heap value at runtime, the read is a
    /// raw `*dst = *slot`: no is_heap check, no refcount, no track_heap_store.
    /// Shares GETGLOBAL's varref slot IC for stable-pointer resolution.
    GETGLOBAL_PRIM,
    /// `global[constants[BC]] = A`: write to a proven primitive-only global
    /// (see GETGLOBAL_PRIM). A raw `*slot = A` with no decref of the overwritten
    /// value (provably primitive) and no incref/track of the stored value.
    PUTGLOBAL_PRIM,
    /// `global[dst] = global[src]`: fused copy between two proven
    /// primitive-only globals (the GETGLOBAL_PRIM + PUTGLOBAL_PRIM pair for a
    /// plain `a = b` assignment). A two-word instruction: this word (A-BC) holds
    /// the destination name index in BC; the immediately-following word (a NOP,
    /// preserved through compaction like TRY's finally slot) holds the source
    /// name index in its BC. The VM reads both words, advances PC by 2, and does
    /// a raw `*dst_slot = *src_slot`: both slots provably primitive, so no
    /// is_heap check, no refcount, no track_heap_store. Uses two adjacent
    /// per-PC VarICEntry slots: pc_off (dst, write IC) and pc_off+1 (src, read
    /// IC); the trailing word's IC slot is otherwise unused.
    MOVE_GG,
    /// `A = typeof identifier`: typeof on a variable name (A-BC format).
    /// Returns "undefined" for unresolvable references per ES5 §11.4.3.
    TYPEOFIDENT,
    /// `A = delete variable[constants[BC]]`: delete a variable (A-BC).
    DELVAR,

    // ---- Closures --------------------------------------------------------

    /// `A = create_closure(inner_funcs[BC])`: instantiate an inner
    /// function template as a closure (A-BC format).
    CLOSURE,
    /// `A = outer_scope[BC]`: read a captured (bound) variable from an
    /// enclosing scope (A-BC format).
    GETBOUND,

    // ---- Iterator / for-in -----------------------------------------------

    /// Initialise a for-in iterator over object A.  B = iterator state
    /// register.
    INITFOR,
    /// `A = next key, B = has_next`: advance the for-in iterator.
    NEXTFOR,

    // ---- Exception handling ----------------------------------------------

    /// Push a try block; the catch handler is at `PC + BC` (A-BC format).
    TRY,
    /// Pop the current try block.
    ENDTRY,
    /// `throw A`: throw an exception.
    THROW,
    /// Throw a ReferenceError with a constant pool message.
    /// A=unused, B=msg_const_idx. Used for `delete super.x` (always ReferenceError).
    THROW_REF,
    /// Throw a SyntaxError with a constant pool message.
    /// A=unused, B=msg_const_idx. Used for GlobalDeclarationInstantiation
    /// checks (ES6+ §15.1.8) that must surface as a *runtime* throw rather
    /// than a compile-time failure, such as a top-level `let` or `const` colliding
    /// with a restricted global name (`undefined`, `NaN`, `Infinity`).
    THROW_SYNTAX,
    /// `A = <caught exception>`: store the caught value.
    CATCH,
    /// Enter the finally block.
    FINALLY,
    /// Exit the finally block (may re-throw or continue).
    ENDFINALLY,

    /// `A = ToPropertyKey(reg[A])`: in-place coercion of a computed
    /// property-name expression's value to a property key (string/symbol),
    /// per ToPropertyKey (§7.1.19) / ComputedPropertyName evaluation
    /// (§13.2.5.5). Used by object destructuring-assignment computed keys
    /// (`{[expr]: target} = rhs`) to coerce the key at PropertyName-evaluation
    /// time, before the possibly deferred AssignmentTarget is evaluated,
    /// matching KeyedDestructuringAssignmentEvaluation's step ordering without
    /// duplicating the later property read done by GETPROP/PUTPROP (which
    /// idempotently no-ops on an already-string register).
    TOPROPKEY,
    /// `A = ToString(reg[A])`: in-place coercion to string via §7.1.17,
    /// used for template literal substitutions (§13.2.8.1
    /// SubstitutionEvaluation calls ToString directly, unlike the `+`
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
    /// `PC += sABC`: unconditional relative jump for `break` out of
    /// a loop/switch.  Like JUMP but the VM intercepts it when crossing
    /// a try-finally boundary to execute the finally block first.
    BREAK,
    /// `PC += sABC`: unconditional relative jump for `continue`.
    /// Like JUMP but the VM intercepts it when crossing a try-finally
    /// boundary to execute the finally block first.
    CONTINUE,

    // ---- Special property initialisation ----------------------------------

    /// `A[B] = C`: initialise a data property without triggering setters.
    INITSET,
    /// Define getter: `Object.defineProperty(A, B, {get: C})`.
    INITGET,
    /// Define setter: `Object.defineProperty(A, B, {set: C})`.
    INITSETI,
    /// `A[B] = C`: define a data property with WEC flags (overrides any
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
    /// `lex_env[constants[BC]] = A`: write a binding into the current
    /// lexical environment (for `let` declarations).  A-BC format.
    PUTLEX,
    /// `lex_env[constants[BC]] = A`: write a non-writable binding into
    /// the current lexical environment (for `const` declarations).  A-BC format.
    PUTLEX_C,
    /// `lex_env[constants[BC]] = TDZ_SENTINEL`: store the temporal dead zone
    /// sentinel for the variable named by constants[BC] into the current
    /// lexical environment.  Used at block entry to mark `let`/`const`
    /// bindings as uninitialized before their declaration is reached.
    INITTZ,

    /// GlobalDeclarationInstantiation static checks (ES2015 §15.1.11),
    /// emitted only at the top of a global Script/eval so a collision throws
    /// before any binding is instantiated. BC indexes the declared name in
    /// the constant pool; A is unused (A-BC format).
    ///   CHKGLOBALLEX:  a lexical name (let, const, class). Throws SyntaxError
    ///     if the name already has a var binding, a global lexical binding,
    ///     or a restricted (non-configurable, non-plain-data) global property.
    ///   CHKGLOBALVAR:  a var name. Throws SyntaxError if a global lexical
    ///     binding exists; else TypeError if CanDeclareGlobalVar is false.
    ///   CHKGLOBALFUNC: a function name. Throws TypeError if
    ///     CanDeclareGlobalFunction is false.
    CHKGLOBALLEX,
    CHKGLOBALVAR,
    CHKGLOBALFUNC,

    /// `A = create_regexp(constants[BC])`: compile a regexp literal
    /// from the raw `/pattern/flags` string stored at constant pool index BC.
    /// Creates a new HObject of class REGEXP with compiled regexp data.
    NEWREGEXP,

    // ---- Spread operator (ES6) -------------------------------------------

    /// `A[B] = spread(C)`: spread elements of array C into target array A
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
    /// `A = call B with nargs from valstack[C]`: function call with
    /// runtime argument count (for spread arguments).
    /// ABC format: A=result_reg, B=callee_reg, C=nargs_reg.
    CALL_S,
    /// `A = B(C..C+N)` with an implicitly-undefined `this`: identical to
    /// CALL, but the callee's this-binding is taken to be `undefined`
    /// without reading the `callee_reg+1` slot. Emitted by the compiler for
    /// plain (non-method) calls `f(...)`, where the receiver is always
    /// undefined; this elides the per-call `LDUNDEF callee_reg+1` dispatch
    /// that CALL would otherwise depend on. ABC format: A=result register,
    /// B=callee register, C=argument count.
    CALL_UNDEF_THIS,
    /// Fused GETVAR + CALL_UNDEF_THIS: `A = variable[constants[C]](A+2..A+1+B)`.
    /// Loads the callee by name (via the same VarIC path as GETVAR, keyed on
    /// this instruction's own pc) directly into register A, then performs a
    /// plain-undefined-this call, so one dispatch replaces two. Emitted only
    /// when the callee is a bare identifier reference (not a local variable
    /// register) immediately followed by a call with no spread arguments,
    /// and the name's constant-pool index fits in 8 bits (else the compiler
    /// falls back to plain GETVAR + CALL_UNDEF_THIS). ABC format:
    /// A=result/callee register, B=argument count, C=constant pool index
    /// of the callee's name (must be < 256).
    CALL_VAR,
    /// Fused GETGLOBAL + CALL_UNDEF_THIS: `A = global[constants[C]](A+2..A+1+B)`.
    /// The global-scope analog of CALL_VAR. Resolves the callee, a bare
    /// top-level global-function binding, via GETGLOBAL's lean stable-pointer
    /// varref IC (keyed on this instruction's own pc) directly into register A,
    /// then performs a plain-undefined-this call: one dispatch instead of the
    /// GETGLOBAL + CALL_UNDEF_THIS pair. The global object owns the binding, so
    /// the callee is borrowed (no incref/decref) exactly as CALL_VAR does for a
    /// global-resolved callee. Emitted only when the callee read was emitted as
    /// GETGLOBAL (true global slot scope, non-prim binding) immediately before a
    /// plain non-method call with no spread arguments, and the name's constant
    /// index fits in 8 bits (else falls back to GETGLOBAL + CALL_UNDEF_THIS).
    /// ABC format: A=result/callee register, B=argument count, C=constant pool
    /// index of the callee's name (must be < 256).
    CALL_GLOBAL,
    /// `A = spread(C) into object`: copy all own enumerable properties
    /// from source C into target object A.  null/undefined sources are
    /// silently skipped (as in Object.assign).  ABC format:
    /// A=target_obj_reg, B=0 (unused), C=source_reg.
    OBJSPRD,
    /// `A = CopyDataProperties(C, excludedNames=array B)`: object-rest
    /// collection (`{...rest}` in a destructuring pattern), per ES2018
    /// §7.3.24 CopyDataProperties / §13.15.5.6. Like OBJSPRD but skips own
    /// keys present (by ToPropertyKey-coerced value) in the array at B.
    /// ABC format: A=target_obj_reg, B=excluded_names_array_reg, C=source_reg.
    OBJREST,

    // ---- ES6 Classes -----------------------------------------------------

    /// `A.[[Prototype]] = B`: set the internal [[Prototype]] of object A
    /// to object B (used for `extends` to set `Derived.prototype.__proto__`).
    /// ABC format: A=derived_obj_reg, B=proto_reg.
    SETPROTO,
    /// `A = GetPrototypeOf(B)`: read the internal [[Prototype]] of object B
    /// (routing through the Proxy [[GetPrototypeOf]] trap when B is a proxy).
    /// Yields null for a null prototype and undefined for non-object B.
    /// ABC format: A=dst_reg, B=obj_reg.
    GETPROTO,
    /// `A[B] = C` with the current `this` as receiver. The store form
    /// of `super.x = v` (§13.15.2 SetSuperProperty): the property walk starts
    /// at the super base (A) but accessor setters / new data properties land
    /// on the receiver.  ABC format: A=super_base_reg, B=key_reg, C=val_reg.
    PUTPROP_SUPER,
    /// `A = B[C]`: super property get with correct receiver (§13.5.3 GetValue).
    /// The property lookup starts at super base B with key C, but accessor getters
    /// are invoked with `this` = current activation's this_binding, not B.
    /// ABC format: A=result_reg, B=super_base_reg, C=key_reg.
    GETPROP_SUPER,
    /// `A = super(B, C..C+N)`: call superclass constructor.
    /// Uses the current activation's `new.target` as the new object's constructor.
    /// ABC format: A=result_reg, B=super_ctor_reg, C=arg_count.
    SUPER_CALL,
    /// `A = super(B, args[C..])`: same as SUPER_CALL but C is a register
    /// holding the runtime argument count (for spread arguments in default
    /// constructors).  ABC format: A=result_reg, B=super_ctor_reg, C=nargs_reg.
    SUPER_CALL_S,
    /// `A = new.target`: load `new.target` into register A.
    /// Returns undefined if not in a constructor call.
    /// A-only format: A=result_reg, B=0, C=0.
    NEWTARGET,

    // ---- Generators (ES6) ------------------------------------------------

    /// `A = load_resume`: load the value passed to .next() into A.
    /// Emitted by the compiler after every YIELD instruction so that the
    /// yield expression evaluates to the value the caller passed to .next(val).
    /// ABC format: A=result_reg, B=0, C=0.
    LOAD_RESUME,

    /// `yield A`: suspend generator execution and return the value in A.
    /// YIELD saves the current activation state (registers, PC, environments)
    /// to the generator object and returns {value: A, done: false} to the
    /// caller of .next()/.throw()/.return().
    /// ABC format: A=value_reg, B=0, C=0.
    YIELD,

    /// `A = yield* B`: delegate to another generator/iterable.
    /// ABC format: A=result_reg, B=iterable_reg, C=0.
    YIELD_STAR,

    /// `A = yield* B` inside an *async* generator (ES2018 §14.4.14 async form /
    /// §27.6.3.8). Delegates over the async iterator protocol: every inner
    /// next/throw/return result is Awaited, and each yielded value is Awaited
    /// (AsyncGeneratorYield). Unlike the sync YIELD_STAR, this is a resumable
    /// state machine: each spec Await is a real suspension that re-enters this
    /// opcode (gs.ays_step records the delegation position). Forwards the
    /// consumer's .throw()/.return() completions to the inner iterator's
    /// throw/return methods with the missing-method fallbacks (AsyncIteratorClose
    /// + TypeError for a missing throw; return Completion for a missing return).
    /// ABC format: A=result_reg, B=iterable_reg, C=0.
    YIELD_STAR_ASYNC,

    /// `return A` from a generator, marking it completed,
    /// wraps result in IteratorResult, and returns.
    /// Same encoding as RET (ABC format).
    RET_GEN,
    /// `return undefined` from a generator.
    /// Same encoding as RETUNDEF (NONE format).
    RETUNDEF_GEN,

    /// `await A`: suspend async function at a thenable value.
    /// Saves register state, enqueues a resume callback via the thenable's
    /// `.then()`, and pops the activation.  The resume callback re-enters
    /// the function at the next instruction (LOAD_RESUME) with the settled value.
    /// ABC format: A=value_reg, B=0, C=0.
    AWAIT,

    /// `import(specifier)`: dynamic import expression (ES2020).
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
    /// Used for non-spread arguments that follow a spread, whose position
    /// depends on the runtime spread count, which is not known at compile time.
    /// ABC format: A=base_reg (first_arg register), B=count_reg (running total),
    /// C=src_reg (value to write). Effect: regs[A + regs[B]] = regs[C];
    /// then regs[B]++.
    PUTARG,

    /// `new ctor(...args)` with a spread. Same as NEW_OBJ, but it reads the
    /// runtime argument count from a register (like CALL_S). ABC format:
    /// A=result_reg, B=ctor_reg, C=nargs_reg.
    NEW_OBJ_S,

    // ---- Variable arithmetic fusion ---------------------------------------

    /// `variable[constants[BC]] = variable[constants[BC]] + 1`: fused
    /// GETVAR + INC + PUTVAR.  Reads a variable by name, increments it,
    /// and writes it back in a single dispatch.  Uses the VarIC for both
    /// read and write.  A-BC format: A=0 (unused), BC=constant pool index.
    INC_VAR,
    /// `variable[constants[BC]] = variable[constants[BC]] - 1`: fused
    /// GETVAR + DEC + PUTVAR.  Same layout as INC_VAR.
    DEC_VAR,
    /// Global-scope variants of INC_VAR / DEC_VAR: fused read+op+write against
    /// a top-level global binding, using GETGLOBAL's lean slot IC (single
    /// shape-id compare + direct indexed access, no env/key/search_head/
    /// generation checks). Emitted only at true global scope. A-BC format:
    /// A=result reg, BC=constant pool index of the name.
    INC_GLOBAL,
    DEC_GLOBAL,

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

    // ---- Fused strict-equality compare-and-branch ----------------------------
    // Strict equality (===/!==) never coerces operands, so unlike the loose
    // EQ/NEQ path these can never call user code or throw, so the fused handler is
    // a pure value compare with no needs_restart/throw dance. Two opcodes cover
    // all four source patterns: SEQ+IF_TRUE and SNEQ+IF_FALSE both branch when
    // the operands are strictly equal (JMP_SEQ); SNEQ+IF_TRUE and SEQ+IF_FALSE
    // both branch when they are not (JMP_SNEQ). Format ABC: A = signed 8-bit
    // offset (cast via char), B/C = operand registers.

    /// Fused strict-equality branch: branch if (rB === rC).
    JMP_SEQ,
    /// Fused strict-inequality branch: branch if (rB !== rC).
    JMP_SNEQ,

    /// Fused `GETGLOBAL_PRIM rC, S` + `JMP_LT off, rB, rC`: branch if
    /// (rB < global[S]), loading the primitive-only global operand inline
    /// instead of round-tripping it through a scratch register.
    /// A two-word instruction mirroring MOVE_GG: this word is ABC (A = signed
    /// 8-bit jump offset, B = the register operand, C unused); the
    /// immediately-following word is a NOP whose BC holds the global's name
    /// index. The VM reads both words and advances PC by 2, so the trailing
    /// word is preserved through NOP compaction via `nop_keep`.
    /// The loaded value never reaches a register, since fusion requires
    /// the original scratch register to be dead after the branch on both the
    /// fall-through and taken paths.
    /// Offset convention matches JMP_LT: relative to the instruction after the
    /// *pair* (pc has already advanced by 2).
    /// Reuses the per-PC VarICEntry slot at pc_off+1 (the trailing word) as the
    /// global's read IC, exactly like MOVE_GG's source-slot IC.
    JMP_LT_G,

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

    /// GetIterator (ES2022 §7.4.2) step 3: validate the @@iterator method
    /// fetched from the source before calling it.  A = the fetched method,
    /// B = the source value it was read from.  Throws a TypeError naming the
    /// source when the method is not callable, distinguishing the two cases
    /// the way the spec's own steps do: an absent (undefined/null) method
    /// means the source is not iterable at all, while a present but
    /// non-callable one is a bad @@iterator value.  Without this the bare CALL
    /// that follows reports "undefined is not a function", which describes the
    /// engine's internal protocol lookup rather than the user's mistake and
    /// implies something was called.
    ///
    /// C selects the mode.  C=1 runs before the @@iterator read, with A = the
    /// source, and rejects a null or undefined source (which has no properties
    /// to read, so the read itself would report "Cannot read properties of
    /// null" and expose the internal key).  C=0 runs after the read, with
    /// A = the fetched method and B = the source.  C=2 runs after the call, with
    /// A = the returned iterator, and requires it to be an Object (step 5).
    CHKITER,

    /// IteratorClose: if the value in A is an object and has a callable
    /// `.return` method, call it with this = A and discard the result. Used
    /// after a pattern walk so destructuring of partially-exhausted
    /// iterators notifies the iterator (ES2015 §13.3.3.8 IteratorClose).
    /// A = iterator register. B = scratch register used to fetch the
    /// .return method (allocated by the VM); B = C on exit.
    ITER_CLOSE,

    /// `A ← GetIterator(reg B, async)` (ES2018 §7.4.2 for-await). Reads
    /// B[@@asyncIterator]; if absent, reads B[@@iterator], calls it, and wraps
    /// the sync iterator in an %AsyncFromSyncIterator% adapter so a plain sync
    /// iterable works under `for await`. Calls the chosen method and stores the
    /// resulting (async) iterator object in A. A-B format (C=0).
    GET_ITER_ASYNC,

    /// AsyncIteratorClose (ES2018 §7.4.11): like ITER_CLOSE but leaves the
    /// `.return()` result in register A so codegen can AWAIT it before
    /// propagating the completion. If A is not an object or has no callable
    /// `.return`, A is set to undefined (nothing to await). B encodes completion
    /// type exactly as ITER_CLOSE (0=non-throw, 1=throw-suppress, 2=auto).
    ITER_CLOSE_ASYNC,

    /// `IsConstructor(A)`: throw TypeError if register A is not a constructor.
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

    /// Boolean brand check for the `#x in obj` ergonomic brand probe
    /// (ES2022 class-fields-private-in). Like CHK_BRAND but sets ra to a
    /// boolean instead of throwing on a miss, since the probe tests presence,
    /// not access. A=object, B=register holding the brand symbol,
    /// C=constant pool index of the private name (for error messages,
    /// not currently used here since this opcode never throws).
    HAS_BRAND,

    /// Define an own data property bypassing setters AND the extensibility
    /// check (CreateDataProperty semantics without the [[Extensible]] gate,
    /// for private field installation per PrivateFieldAdd).
    /// ABC format: A=object_reg, B=key_reg, C=value_reg.
    INITPROP_PRIV,

    /// Private field read: `A = B[C]` bypassing proxy [[Get]] traps.
    /// Same as GETPROP but skips the proxy exotic dispatch, used for
    /// private field/method access (`this.#x`) where spec PrivateFieldGet
    /// does a direct internal-slot lookup, not [[Get]].
    /// Throws TypeError if the private member has no [[Get]] field (set-only
    /// accessor) per PrivateFieldGet step 6b. For assignment-target contexts
    /// (`obj.#m = v`), the compiler strips this opcode entirely so the
    /// read step never runs; CHK_BRAND emitted by emit_private_access (which
    /// runs unconditionally as part of the prelude) still enforces brand
    /// check at PUTPROP time, while [[Set]] handles set-vs-getter correctly.
    /// ABC format: A=dst_reg, B=obj_reg, C=key_reg.
    GETPROP_PRIVATE,

    /// `A = ToNumeric(B)`: coercion used by postfix ++/-- to compute the
    /// returned old value.  Unlike UNP (unary plus), a BigInt operand passes
    /// through unchanged rather than throwing (ES2020 §7.1.3 ToNumeric).
    TONUMERIC,

    /// `import.meta` meta-property (ES2024 §13.3.12). Loads the currently
    /// executing module's import-meta object into A, lazily creating it (an
    /// ordinary null-prototype object carrying a `url` data property) on first
    /// access and caching it on the ModuleDef so every evaluation observes the
    /// same identity. Only emitted in module code, since `import.meta` in script or
    /// eval / Function-body code is an early SyntaxError caught at compile time.
    /// ABC format: A=result_reg, B=0, C=0.
    IMPORT_META,

    /// Prefix word that supplies the high-order operand bits for the
    /// instruction that follows it.  When any operand of an instruction
    /// exceeds 255 (MAX_A/B/C), the compiler emits `WIDE` immediately before
    /// it: the WIDE word's A/B/C fields carry the extension bytes, and the
    /// effective operand of the next instruction's A/B/C field is
    /// `(ext << 8) | field` (16 bits, up to 65535 registers).
    /// Instructions whose operands all fit in 8 bits never get a prefix, so
    /// the common path is byte-identical to the pre-WIDE encoding.  WIDE is
    /// opaque to every peephole pass: a function whose code contains WIDE
    /// skips all of them.
    WIDE,

    /// Marks the end of the enum, and is not a real opcode.
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
    /// Full 24-bit unsigned operand (bits 8-31).
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
        case RESOLVEVAR: return A_BC;
        case THROW_UNRESOLVED: return A_BC;
        case TYPEOFIDENT: return A_BC;
        case PUTVAR:    return A_BC;
        case DECLVAR:   return A_BC;
        case DECLVAR_HOIST: return A_BC;
        case DECLGLOBALFUNC: return A_BC;
        case GETGLOBAL: return A_BC;
        case PUTGLOBAL: return A_BC;
        case GETGLOBAL_PRIM: return A_BC;
        case PUTGLOBAL_PRIM: return A_BC;
        case MOVE_GG: return A_BC;
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
        case OBJREST:    return ABC;
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
        case HAS_BRAND: return ABC;
        case INITPROP_PRIV: return ABC;
        case GETPROP_PRIVATE: return ABC;

        case LOAD_RESUME:  return ABC;
        case YIELD:      return ABC;
        case YIELD_STAR: return ABC;
        case YIELD_STAR_ASYNC: return ABC;
        case GETPROPC_CACHED: return ABC;
        case GEN_START:      return NONE;

        // A-sBx format (signed 16-bit second operand)
        case LDINT:     return A_SBX;
        case IF_TRUE:   return A_SBX;
        case IF_FALSE:  return A_SBX;

        // Full signed 24-bit
        case JUMP:      return WIDE_SABC;

        // No operands
        case WIDE:      return NONE;
        case NOP:       return NONE;
        case RETUNDEF:  return NONE;
        case RETUNDEF_GEN: return NONE;
        case AWAIT:     return ABC;
        case DYN_IMPORT: return ABC;
        case IMPORT_META: return ABC;
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
        case INC_GLOBAL: return A_BC;
        case DEC_GLOBAL: return A_BC;
        case GETPROPC2:  return ABC;
        case REQUIRE_OBJ: return ABC;
        case ITER_CLOSE: return ABC;
        case GET_ITER_ASYNC:   return ABC;
        case ITER_CLOSE_ASYNC: return ABC;
        case CHKOBJ:     return ABC;
        case CHKITER:    return ABC;
        case CHKCTOR:    return ABC;
        case CHK_PROT:   return ABC;

        // Everything else: standard A, B, C
        default:        return ABC;
    }
}

// ============================================================================
// Instruction: the 32-bit encoded instruction word
// ============================================================================

/// A single 32-bit bytecode instruction.
///
/// The bitstruct provides named access to the four 8-bit fields.  Higher-
/// level layouts (A-BC, ABC, A-sBx, sABC) are accessed through methods.
bitstruct Instruction : uint {
    /// Opcode (bits 0-7).
    Opcode op  : 0..7;
    /// A operand, usually the destination register (bits 8-15).
    uint   a   : 8..15;
    /// B operand, a source register or constant index (bits 16-23).
    uint   b   : 16..23;
    /// C operand, a source register or constant index (bits 24-31).
    uint   c   : 24..31;
}

// ============================================================================
// Instruction: static constructors
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
/// The 24-bit unsigned operand spans bits 8-31, which is the A, B, and C fields
/// concatenated: A at bits 8-15, B at 16-23, C at 24-31.
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

/// Encode a WIDE prefix word: its A/B/C fields carry the extension bytes for
/// the following instruction's A/B/C fields.  Each extension byte is the
/// high byte of the effective 16-bit operand.
fn Instruction make_wide(uint ext_a, uint ext_b, uint ext_c) {
    return make_abc(Opcode.WIDE, ext_a, ext_b, ext_c);
}

// ============================================================================
// Instruction: field accessors
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
// Instruction: raw word access
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
// DecodedInsn: operand values after WIDE expansion
// ============================================================================

/// An instruction whose operand fields carry their effective values: 16-bit
/// register indices for a WIDE-prefixed instruction, the raw 8-bit field
/// values otherwise (identical for operands that never exceed 255).  The VM
/// builds one per dispatch and passes it to handlers in place of the packed
/// `Instruction`, so a handler reads the widened operands without any
/// per-opcode knowledge of the prefix.  The BC/ABC accessors mirror
/// Instruction's, and are only ever called on opcodes whose extension bytes
/// are zero by construction (the compiler widens exactly the fields that
/// hold register indices, never immediates or combined BC operands).
struct DecodedInsn {
    Opcode op;
    uint   a;
    uint   b;
    uint   c;
}

/// Returns the opcode.
macro Opcode DecodedInsn.get_op(&self) {
    return self.op;
}

/// Returns the effective A operand (16-bit when WIDE-expanded).
macro uint DecodedInsn.get_a(&self) {
    return self.a;
}

/// Returns the effective B operand.
macro uint DecodedInsn.get_b(&self) {
    return self.b;
}

/// Returns the effective C operand.
macro uint DecodedInsn.get_c(&self) {
    return self.c;
}

/// Returns the 16-bit unsigned BC combined operand.
macro uint DecodedInsn.get_bc(&self) {
    return (self.c << 8) | self.b;
}

/// Returns the signed 16-bit BC operand (bias-decoded).
macro int DecodedInsn.get_sbc(&self) {
    return (int)self.get_bc() - (int)BC_BIAS;
}

/// Returns the unsigned 24-bit ABC operand (all three fields concatenated).
macro uint DecodedInsn.get_abc(&self) {
    return (self.c << 16) | (self.b << 8) | self.a;
}

/// Returns the signed 24-bit ABC operand (bias-decoded).
macro int DecodedInsn.get_sabc(&self) {
    return (int)self.get_abc() - (int)ABC_BIAS;
}

// ============================================================================
// CompiledFunction: bytecode container
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
    /// The body contains a direct `eval()`, which blocks several optimisations.
    bool  has_direct_eval: 15;
    /// Function is a constructor method.
    bool  is_constructable: 16;
    /// The function accesses its own environment bindings at runtime. When
    /// false, the CALL fast path skips `env_create_function_scope` and reuses
    /// the captured parent env.
    bool  needs_env       : 17;
    bool  is_global       : 18;
    /// Function needs the CALL fast path to create a lex_env bridge
    /// connecting the new activation to the function's captured lex scope.
    /// Required for default parameter thunks capturing a parent param scope.
    bool  needs_lex_bridge: 19;
    /// Function is an ESM module body (top-level import/export).
    bool  is_module        : 20;
    /// A class constructor, whose .prototype is non-configurable per ES2015
    /// §14.5.14 step 25, so `class.prototype = ...` must throw a TypeError.
    /// Other functions get a configurable .prototype.
    bool  is_class_ctor    : 21;
    /// Substitute the global object for an undefined or null `this` receiver
    /// (ES5 §10.4.3 OrdinaryCallBindThis with [[ThisMode]] of global).
    ///
    /// This engine is strict-only, so the flag is not derived from strictness.
    /// It is set only on bodies built by the dynamic Function,
    /// GeneratorFunction, and AsyncFunction constructors, whose [[ThisMode]] the
    /// spec derives from a sloppy enclosing realm rather than from the caller's
    /// scope. That keeps the common UMD idiom `Function('return this')()`
    /// yielding globalThis. A `"use strict"` directive in the dynamic body
    /// clears it.
    bool  subst_global_this: 22;
    /// A derived class constructor. ES2015 §9.2.2 step 13.c makes returning a
    /// non-object from one a TypeError unless the value is undefined. Set when
    /// has_super_binding held at compile time.
    bool  is_derived_ctor  : 23;
    /// Function is compiled eval code (compile_eval), not Script/global code.
    /// Per ES2015 §18.2.1.2 EvalDeclarationInstantiation step 16.a,
    /// CreateGlobalVarBinding(vn, true) installs eval-created global var/
    /// function bindings as configurable, unlike a real Script's
    /// GlobalDeclarationInstantiation (§15.1.11 step 18.a), which installs
    /// them non-configurable via CreateGlobalVarBinding(vn, false).
    bool  is_eval          : 24;
    /// The eval source carried its own "use strict" prologue. Everything here
    /// runs strict, but PerformEval step 12 keys declaration leaking off the
    /// source's own strictness: a strict eval gets a fresh varEnv its
    /// declarations cannot escape, while a non-strict indirect or global eval
    /// installs `var` and `function` bindings on the global object. Only
    /// meaningful when is_eval is set.
    bool  eval_src_strict  : 25;
    /// Function is a method/accessor with a [[HomeObject]] (enables super.x
    /// syntax).  Set at compile time when super_is_home_object is true.
    bool  has_home_object  : 26;
    /// The function's super base is the receiver's [[Prototype]] rather than a
    /// superclass's `.prototype`. That covers object-literal concise methods and
    /// class methods without `extends`, and mirrors
    /// CompilerContext.super_is_home_object at finish() time.
    ///
    /// compile_eval passes it down from the caller, so `super.x` inside an eval
    /// resolves against `Object.getPrototypeOf(homeObject)`, which PerformEval
    /// step 7 requires, rather than `__super__.prototype`.
    ///
    /// has_home_object is broader: it is also set on derived-class methods,
    /// whose super base is the superclass prototype.
    bool  super_is_home_object : 27;
    /// The function was written with a `*`: `function*`, `*m(){}`,
    /// `async function*`, or `async *m(){}`. `is_generator` is broader, since a
    /// plain async function sets it too in order to reuse the YIELD and
    /// LOAD_RESUME suspend machinery through AWAIT. Together they separate the
    /// four kinds:
    ///   plain function     : !is_generator, !is_async, !is_user_generator
    ///   sync generator     :  is_generator, !is_async,  is_user_generator
    ///   async function     :  is_generator,  is_async, !is_user_generator
    ///   async generator    :  is_generator,  is_async,  is_user_generator
    /// See `is_async_gen()`.
    bool  is_user_generator    : 28;
    /// Eval code whose source may reference `new.target`, meaning a direct eval
    /// inside a non-arrow FunctionBody (ES2015 §13.3.5.1 and Annex B). A nested
    /// direct eval inherits the permission from here. Without it the inner
    /// eval's caller reports is_global_fn(), since every eval sets is_global,
    /// and would reject `new.target`.
    bool  eval_allows_new_target : 29;
    /// The body forbids a bare `arguments`, which holds inside a class field or
    /// static initializer and a static block (ES2022 §15.7.10 and §15.7.11). A
    /// direct eval called from such a body inherits the restriction; see
    /// compile_eval's `caller_forbids_arguments` parameter.
    bool  forbid_arguments      : 30;
}

/// A compiled function template: the immutable bytecode representation of
/// an ECMAScript function produced by the compiler.
///
/// Many closures can share one CompiledFunction, each carrying its own captured
/// bindings. It holds everything the VM needs to run the function: the
/// instruction stream, the constant pool, the templates for nested functions,
/// the register budget and argument counts, and source metadata for debugging.
struct CompiledFunction {
    // ---- Inline HeapHeader (binary-compatible with HeapHeader*) ----------

    /// Bit-packed flags: a HeapHeader-compatible prefix plus function metadata.
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

    /// Constant pool holding the literal values, such as numbers and strings,
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
    /// The formal count `Function.length` reports, which differs from
    /// `num_args` when a rest parameter or a default value is present.
    ushort          num_formals;

    // ---- Source-level debug info ----------------------------------------

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

    // ---- NEWREGEXP literal compile cache ---------------------------------
    /// Compiled bytecode for each NEWREGEXP site, parallel to the instruction
    /// stream, so `regexp_cache[pc_offset]` serves the literal at
    /// `code[pc_offset]` and it compiles once rather than on every execution.
    /// The array appears on the first NEWREGEXP execution, and freeing the
    /// function re_frees each entry. RegExp objects borrowing an entry take
    /// their own reference.
    void**          regexp_cache;    // ReCompiled*[] (opaque), or null
    uint            regexp_cache_count;

    // ---- Source-text retention (Function.prototype.toString) ------------
    /// The function's original source text, from the `function` keyword or arrow
    /// head through the closing `}` or end of expression, copied onto the heap.
    /// Null when the source was not retained.
    /// builtin_function_proto_toString reads it (ES2019 §19.2.3.5).
    char*           src_ptr;
    /// Length in bytes (no NUL terminator counted).
    uint            src_len;

    // ---- Private class fields (ES2022) -----------------------------------

    /// The hidden `__field_init__` template holding every instance field
    /// initializer in source order (see class.c3), or null when the class
    /// declares no instance fields.
    ///
    /// It is a raw pointer rather than an inner_funcs index because
    /// __field_init__ is compiled in the class-enclosing scope's
    /// CompilerContext, whose inner-function table is not this constructor's.
    /// vm_calls.c3's vm_init_private_members explains why the construct path
    /// needs it self-contained.
    CompiledFunction* field_init_func;
    /// Interned binding name, such as "#priv:brand", that finds the class's
    /// brand symbol in the constructor's lex_env at construction time. Null when
    /// the class has no private members and stamps no brand. A raw HString*,
    /// for the same reason as field_init_func.
    void*           brand_name_hstr;

    // ---- Direct-eval private-name snapshot (ES2022 §8.7.1) ------------------
    //
    // Direct eval inherits the calling context's PrivateEnvironment, but eval
    // compiles against a fresh CompilerContext and cannot know those names. So
    // the function whose body contains the `eval(...)` snapshots its
    // private-name table here before cleanup() frees the scratch buffer. At call
    // time builtin_eval reads the snapshot from the caller's activation and
    // hands it to compile_eval, letting the eval body resolve `#x`.
    //
    // Populated only when the function has_direct_eval and adopted private names
    // from a parent class body, and null otherwise.
    //
    // Heap.free_compiled_funcs frees this alongside the other sub-arrays. Each
    // PrivateNameEntry's strings point at interned HString data that outlives
    // the snapshot, so copying the entry structs is safe.
    //
    // Typed void* because PrivateNameEntry lives in the compiler module, which
    // bytecode.c3 does not import. The compiler and builtin_eval both cast.
    void*           eval_private_names;
    uint            eval_private_name_count;
    /// HString* of this function's enclosing class's `__super__ binding name
    /// (e.g. "__super__0"; each class in a scope gets a unique number).
    /// Two readers: builtin_eval re-interns it into the eval context's
    /// constant pool so direct `eval("super.x")` GETVARs the numbered
    /// binding, and Object.setPrototypeOf's class sync (object.c3) writes
    /// the new [[Prototype]] under this name, keeping the binding in step
    /// with GetSuperConstructor's runtime read. Null outside any class.
    void*           super_binding_name;
    /// HString* of the enclosing class's __static_super__ binding name.
    void*           static_super_binding_name;
}

// ============================================================================
// CompiledFunction: HeapHeader compatibility
// ============================================================================

/// Returns a HeapHeader pointer to this compiled function
/// (binary-compatible cast).
macro HeapHeader* CompiledFunction.as_header(&self) {
    return (HeapHeader*)self;
}

// ============================================================================
// CompiledFunction: flag accessors
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

/// Returns `true` when the function was written with a syntactic `*`
/// (`function*`, `async function*`, or a `*`/`async *` method).
macro bool CompiledFunction.is_user_generator(&self) {
    return self.flags.is_user_generator;
}

/// Returns `true` for an async generator, meaning `async function*` or
/// `async *m(){}`, which is `async` together with a syntactic `*`.
macro bool CompiledFunction.is_async_gen(&self) {
    return self.flags.is_async && self.flags.is_user_generator;
}

/// Returns `true` for a sync GeneratorFunction, meaning `function*` or `*m(){}`:
/// a syntactic `*` without `async`.
macro bool CompiledFunction.is_sync_generator(&self) {
    return self.flags.is_user_generator && !self.flags.is_async;
}

/// Returns `true` when the function can be used as a constructor.
macro bool CompiledFunction.is_constructable(&self) {
    return self.flags.is_constructable;
}

/// Returns `true` for a class constructor, whose .prototype is non-configurable
/// (ES6 §14.5.14 step 25), so redefining it throws a TypeError.
macro bool CompiledFunction.is_class_ctor(&self) {
    return self.flags.is_class_ctor;
}

/// Returns `true` for a derived class constructor, where ES2015 §9.2.2 step 13.c
/// makes returning anything but an object or undefined a TypeError.
macro bool CompiledFunction.is_derived_ctor(&self) {
    return self.flags.is_derived_ctor;
}

/// Returns `true` when the function accesses its own environment bindings, so
/// the CALL fast path must create a scope for it. See FuncFlags.needs_env.
macro bool CompiledFunction.needs_env(&self) {
    return self.flags.needs_env;
}

/// Returns `true` for the top-level program or eval scope.
macro bool CompiledFunction.is_global_fn(&self) {
    return self.flags.is_global;
}

/// Returns `true` when this is compiled eval code (as opposed to Script or
/// module top-level code). See FuncFlags.is_eval.
macro bool CompiledFunction.is_eval_fn(&self) {
    return self.flags.is_eval;
}
/// Returns `true` when this eval CF's own source may reference new.target
/// (direct eval in a non-arrow function body), so a nested eval can
/// inherit new.target legality. See FuncFlags.eval_allows_new_target.
macro bool CompiledFunction.eval_allows_new_target(&self) {
    return self.flags.eval_allows_new_target;
}
/// Returns `true` when the eval source had its own "use strict" directive
/// (see FuncFlags.eval_src_strict). Only meaningful on is_eval functions.
macro bool CompiledFunction.eval_source_is_strict(&self) {
    return self.flags.eval_src_strict;
}
macro bool CompiledFunction.needs_lex_bridge(&self) {
    return self.flags.needs_lex_bridge;
}

/// Returns `true` when an undefined/null `this` receiver must be replaced by
/// the global object. See FuncFlags.subst_global_this.
macro bool CompiledFunction.subst_global_this(&self) {
    return self.flags.subst_global_this;
}

/// Returns `true` when the function uses `arguments`.
macro bool CompiledFunction.uses_arguments(&self) {
    return self.flags.uses_arguments;
}

/// Returns `true` when the function contains direct `eval()` calls.
macro bool CompiledFunction.has_direct_eval(&self) {
    return self.flags.has_direct_eval;
}

/// Returns `true` when the function is a method/accessor with a [[HomeObject]]
/// (enables super.x/super[x] syntax in direct eval).
macro bool CompiledFunction.has_home_object(&self) {
    return self.flags.has_home_object;
}

/// Returns `true` when the super base comes from the [[HomeObject]] itself,
/// as in an object-literal concise method or a class method without `extends`.
/// `has_home_object` is broader, covering derived-class methods whose super base
/// is `superclass.prototype`. `builtin_eval` uses this to decide whether
/// `super.x` in a direct eval resolves through `__super__` or
/// `__super__.prototype`.
macro bool CompiledFunction.super_is_home_object(&self) {
    return self.flags.super_is_home_object;
}

/// Returns `true` when the function has a rest parameter.
macro bool CompiledFunction.has_rest(&self) {
    return self.flags.has_rest;
}

/// Returns `true` for a named function expression, where the
/// VM must bind the function's name to the function object in a fresh
/// lexical environment at call time (ES2015 §14.1.20 NamedEvaluation).
macro bool CompiledFunction.is_namebinding(&self) {
    return self.flags.is_namebinding;
}

/// Returns `true` when the function body forbids a bare `arguments`
/// reference (class field/static initializer, static block). Used to
/// propagate the restriction onto a direct eval called from within.
macro bool CompiledFunction.forbid_arguments(&self) {
    return self.flags.forbid_arguments;
}

// ============================================================================
// CompiledFunction: code access
// ============================================================================

/// Returns the instruction at the given program-counter index.
///
/// No bounds check: the caller must ensure `pc` is
/// within `[0, code_count)`.
fn Instruction CompiledFunction.get_insn(&self, uint pc) @inline {
    return self.code[pc];
}

/// Returns the constant at the given index in the constant pool.
///
/// No bounds check: the caller must ensure `idx < const_count`.
fn TVal CompiledFunction.get_const(&self, uint idx) @inline {
    return self.constants[idx];
}

/// Returns the inner function template at the given index.
///
/// No bounds check: the caller must ensure `idx < inner_count`.
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
// `Instruction.disassemble`, the `OPCODE_NAMES` table, and the `write_*`
// buffer-writer helpers live in `src/bytecode_disasm.c3`, in this same
// `duktape::bytecode` module. That file gates its implementations on the
// `TRACE_VM` feature, so a release build pays no `.text` cost and LLVM drops
// `OPCODE_NAMES` from `.rodata` once nothing reachable references it.
//
// Build the `duktape_c3_debug` target, or pass `-D TRACE_VM`, to get the dump
// helpers and the `-t`, `-c`, and `--format json` CLI options.

